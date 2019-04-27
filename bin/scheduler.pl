#!/usr/bin/perl -w
use strict;
use warnings;
use v5.10;

use Data::Dumper;
use File::Basename qw();
use File::Copy ();
use Time::Local qw();
use Config::General qw();
use Getopt::Long qw();
use Clone qw(clone);
use POSIX;
use Time::HiRes qw(time sleep);
use Scalar::Util qw(looks_like_number);
use Storable qw();
use IO::Socket::UNIX qw(SOCK_STREAM);
use IO::Socket::INET qw(SOCK_STREAM);
use IO::Select;

STDOUT->autoflush;
STDERR->autoflush;

my $unixDate       = 0;
my $previousCheck  = 0;
my $timeTillSwitch = 0;
my $previousPlot   = 0;
my $previous       = {};

my $min  = 60;
my $hour = 60 * $min;
my $day  = 24 * $hour;

my $next  = {};
my $event = {};
my $date  = '';

my $plan                   = [];
my $scheduleFileModifiedAt = 0;
my $status                 = {};
my $cycleStart             = time();

my $verbose            = undef;
my $isVerboseEnabled0  = 0;
my $isVerboseEnabled1  = 0;
my $isVerboseEnabled2  = 0;
my $isVerboseEnabled3  = 0;
my $isVerboseEnabled4  = 0;
my $isVerboseEnabled5  = 0;
my $streamSwitchOffset = 0;

sub usage() {
    return qq{
$0 OPTION+

OPTIONS
--config         configuration file defining stations (key,title,url1,url2,alias)
--daemon         start scheduler as daemon, logging to configured log file
--verbose LEVEL  set verbose level (1..6), overrides config file
--help           this help
};
}

sub updateTime() {
    print "\n" if $isVerboseEnabled2;
    $unixDate       = time();
    $date           = timeToDatetime($unixDate);
    $timeTillSwitch = $next->{epoch} - $unixDate - $streamSwitchOffset
      if defined $next->{epoch};
}

sub getCaller() {
    my ( $package, $filename, $line, $subroutine ) = caller(2);
    return undef unless defined $subroutine;
    $subroutine =~ s/main\:\://;
    return "$subroutine()";
}

sub info ($) {
    my $message = shift;

    my $caller = getCaller();
    my $date   = timeToDatetime();
    my $pid    = $$;
    my $line   = "$date\t$pid\tINFO";
    $line .= sprintf( "\t%-16s", $caller ) if defined $caller;
    $message =~ s/\n/\\n/g;
    $message =~ s/\r/\\r/g;
    $line .= "\t$message";
    print $line. "\n";
}

sub warning($;$) {
    my $message    = shift;
    my $onlyToFile = shift;

    my $now  = time();
    my $date = timeToDatetime($now);
    my $pid  = $$;
    $message =~ s/\n/\\n/g;
    $message =~ s/\r/\\r/g;
    print "$date\t$pid\tWARN\t$message\n";
    $status->{warnings}->{$message} = $now unless defined $onlyToFile;
}

sub error ( $) {
    my $message = shift;

    my $now  = time();
    my $date = timeToDatetime($now);
    my $pid  = $$;
    print "$date\t$pid\tERROR\t$message\n";
    $status->{warnings}->{$message} = $now;
}

sub exitOnError($) {
    my $message = shift;
    my $caller  = getCaller();

    my $now  = time();
    my $date = timeToDatetime($now);
    my $pid  = $$;
    print STDERR "$date\t$pid\tERROR\t$caller\t$message\n";
    $status->{warnings}->{$message} = $now;
    exit;
}

sub getConfig($) {
    my $filename = shift;

    exitOnError "config file '$filename' does not exist"
      unless -e $filename;

    exitOnError "cannot read config '$filename'"
      unless -r $filename;

    my $configuration = new Config::General($filename);
    my $config        = $configuration->{DefaultConfig};

    my $stations = $config->{stations}->{station};
    $stations = [$stations] if ref($stations) eq 'HASH';

    exitOnError 'No stations configured!' unless defined $stations;

    exitOnError 'configured stations should be a list!'
      unless ref($stations) eq 'ARRAY';

    exitOnError 'There should be configured at least one station!'
      if scalar @$stations == 0;

    my $manditoryAttributes = [ 'alias', 'url1', 'url2' ];
    for my $station (@$stations) {
        for my $attr (@$manditoryAttributes) {
            $station->{$attr} = '' unless defined $station->{$attr};
        }
    }
    $config->{stations} = $stations;

    return $config;
}

sub getFileLastModified($) {
    my $file = shift;
    my @stat = stat($file);
    return $stat[9];
}

sub writePidFile() {
    my $pidFile = '/var/run/stream-schedule/stream-schedule.pid';
    my $pid     = $$;
    saveFile( 'pid file', $pidFile, $pid );
}

sub checkWritePermissions($$) {
    my $label    = $_[0];
    my $filename = $_[1];

    # check file permissions of scheduler file
    if ( -e $filename ) {
        unless ( -w $filename ) {
            warning "cannot write $label to '$filename'! " . "Please check file permissions!";
            return 0;
        }
    }

    # check permissions of scheduler files directory
    my $dir = File::Basename::dirname($filename);
    unless ( -w $dir ) {
        warning "cannot write $label to dir $dir! " . "Please check file permissions!";
        return 0;
    }
    return 1;
}

sub saveFile($$$) {
    my $label    = $_[0];
    my $filename = $_[1];
    my $content  = $_[2];

    return unless checkWritePermissions( $label, $filename ) == 1;

    # write file
    open my $file, ">", $filename
      || exitOnError "cannot write $label to file '$filename'! " . "Please check file permissions!";
    if ( defined $file ) {
        print $file $content;
        close $file;
    }
    info "saved $label to '$filename'" if $isVerboseEnabled0;
}

# daemonize process,
# not needed for upstart
sub daemonize($) {
    my $log = shift;

    saveFile( 'log file', $log, '' ) unless -e $log;
    setFilePermissions($log);

    open STDOUT, ">>$log" or die "Can't write to '$log': $!";
    open STDERR, ">>$log" or die "Can't write to '$log': $!";
    umask 0;
    writePidFile();
}

sub readStations($) {
    my $stations = shift;
    info "" if $isVerboseEnabled2;

    my $results = {};
    for my $station (@$stations) {

        # make station accessable by id
        my $id = $station->{id};
        $results->{ lc($id) } = $station;

        # make station accessable by aliases
        my @alias = split( /\s*,\s*/, $station->{alias} );
        for my $name (@alias) {
            $results->{ lc($name) } = $station;
        }
    }

    if ( $verbose > 1 ) {
        info "supported stations" if $isVerboseEnabled1;
        for my $key ( sort keys %$results ) {
            info sprintf
              "%-12s\t'%s'\t'%s'",
              $key,
              $results->{$key}->{url1},
              $results->{$key}->{url2};
        }
    }
    return $results;
}

updateTime();

my $params = {
    config   => '',
    schedule => '',
};

Getopt::Long::GetOptions(
    "config=s"  => \$params->{config},
    "daemon"    => \$params->{daemon},
    "h|help"    => \$params->{help},
    "verbose=s" => \$verbose
);

if ( defined $params->{help} ) {
    print usage;
    exit;
}

my $telnetSocket  = undef;
my $socketTimeout = 1;
my $minRms        = -36;

$minRms *= -1 if $minRms < 0;

# get config file
if ( $params->{config} eq '' ) {
    my $configFile = '/etc/stream-schedule/stream-schedule.conf';
    $params->{config} = $configFile if -e $configFile;
}

# read config
my $config = getConfig( $params->{config} );

$verbose = $config->{scheduler}->{verbose} unless defined $verbose;
$verbose = 1 unless defined $verbose;

$isVerboseEnabled0 = ( defined $verbose ) && ( $verbose >= 0 );
$isVerboseEnabled1 = ( defined $verbose ) && ( $verbose >= 1 );
$isVerboseEnabled2 = ( defined $verbose ) && ( $verbose >= 2 );
$isVerboseEnabled3 = ( defined $verbose ) && ( $verbose >= 3 );
$isVerboseEnabled4 = ( defined $verbose ) && ( $verbose >= 4 );

my $log = $config->{scheduler}->{log};
daemonize($log) if defined $params->{daemon};

my $syncCommand = $config->{scheduler}->{syncCommand};

# current schedule
my $scheduleFile = $config->{scheduler}->{scheduleFile};

# touch this file to trigger update
my $triggerSyncFile = $config->{scheduler}->{triggerSyncFile};

# touch this file to trigger restart
my $triggerRestartFile = $config->{scheduler}->{triggerRestartFile} || '';

# write current status to file
my $schedulerStatusFile = $config->{scheduler}->{statusFile};

# sleep interval in seconds
my $longSleep = $config->{scheduler}->{sleep};

# switch offset in seconds to network, buffer
$streamSwitchOffset = $config->{scheduler}->{switchOffset};

# reload schedule interval in seconds
my $reload = $config->{scheduler}->{reload};

# liquidsoap telnet config
my $liquidsoapHost = $config->{liquidsoap}->{host};
my $liquidsoapPort = $config->{liquidsoap}->{port};

my $state = 'check';

info "INIT" if $isVerboseEnabled0;

# plot interval in seconds
my $plotInterval = 1 * 60;

# write rms status in seconds
my $rmsInterval = 60;

my $maxRestartInterval = 1 * 60;
my $maxSyncInterval    = 3 * 60;
my $previousSync       = time();

if ( -e $scheduleFile ) {
    $previousSync = getFileLastModified($scheduleFile);
} else {
    $previousSync -= $maxSyncInterval;
}

my $lastStatusUpdate = time();
my $stations         = readStations( $config->{stations} );

sub getEvents() {
    info "" if $isVerboseEnabled2;
    $plan = loadAgenda( $scheduleFile, $unixDate );
    if ( scalar @$plan > 0 ) {

        #get next station
        ( $event, $next ) = getNextEvent($plan);
        if ( defined $event ) {

            #checkRunning($plan);
        } else {
            warning 'empty schedule!', 'onlyToFile';
            $state = 'sleep';
        }
    } else {
        warning 'empty schedule !';
        $state = 'sleep';
    }
}

sub checkRunning($) {
    my $entry = shift;
    info "" if $isVerboseEnabled2;
    updateTime();
    if ( defined $entry->{date} ) {
        if ( $entry->{date} lt $date ) {
            info "running '" . $entry->{name} . "' since " . $entry->{date}
              if $isVerboseEnabled2;
            $entry->{epoch} = datetimeToEpoch( $entry->{date} );
            playStation($entry);
        }
    }
    $previousCheck = $unixDate;
}

sub checkStreamSwitch ($) {
    my $timeTillSwitch = shift;

    info "" if $isVerboseEnabled2;
    if ( $timeTillSwitch <= 0 ) {
        playStation($next);
        my $sleep = $streamSwitchOffset + 1;
        info "sleep " . $sleep . " secs (offset)" if $isVerboseEnabled1;
        sleep($sleep);
        ( $event, $next ) = getNextEvent($plan);
    }
}

sub checkSleep($) {
    my $state = shift;

    my $cycleDuration = time() - $cycleStart;
    my $sleep         = 30 - $cycleDuration;
    $sleep = 0 if $sleep < 0;

    updateTime();
    if ( $state eq 'sleep' ) {
        info sprintf( 'sleep %0.2f seconds', $sleep )
          if $isVerboseEnabled1;
        sleep($sleep);
    } elsif ( $timeTillSwitch < 0 ) {
        info sprintf( 'sleep %0.2f seconds', $sleep )
          if $isVerboseEnabled1;
        sleep($sleep);
    } elsif ( $timeTillSwitch > 50 ) {
        info sprintf( 'sleep %0.2f seconds', $sleep )
          if $isVerboseEnabled1;
        sleep($sleep);
    } elsif ( $timeTillSwitch > 30 ) {
        info sprintf( 'sleep %0.2f seconds', $sleep )
          if $isVerboseEnabled1;
        sleep(10);
    } elsif ( ( $timeTillSwitch > 5 ) && ( $timeTillSwitch <= 30 ) ) {
        my $sleep = $timeTillSwitch - 5;
        info sprintf( 'sleep %0.2f seconds', $sleep )
          if $isVerboseEnabled0;
        sleep($sleep);
    } elsif ( $timeTillSwitch > 0 ) {
        my $sleep = $timeTillSwitch;
        info sprintf( 'sleep %0.2f seconds', $sleep )
          if $isVerboseEnabled1;
        sleep($sleep);
    } else {
        info "sleep 1 second" if $isVerboseEnabled1;
        sleep(1);
    }
}

sub getNextEvent($) {
    my $plan = $_[0];
    updateTime();

    #return current and next
    my $current = $plan->[0];
    for my $entry (@$plan) {
        if ( $entry->{epoch} >= $unixDate ) {
            info "found next $entry->{name} at " . $entry->{date} . " " . getStationInfo $entry->{station}
              if $isVerboseEnabled2;
            $state = 'next in';
            return ( $current, $entry );
        }
        $current = $entry;
    }
    warning 'no future entries found in schedule!';

    #return last entry, if all events are over
    if ( scalar @$plan > 0 ) {
        my $entry = $plan->[-1];
        info "found next $entry->{name} at " . $entry->{date} . " " . getStationInfo $entry->{station}
          if $isVerboseEnabled2;
        $state = 'last since';
        return ( $entry, $entry );
    }

    return undef;
}

sub getStationInfo ($) {
    my $station = shift;
    my $info    = '';
    $info .= "\t" . $station->{url1} if defined $station->{url1};
    $info .= "\t" . $station->{url2} if defined $station->{url2};
    return $info;
}

sub checkRestartLiquidsoap() {
    if ( $triggerRestartFile eq '' ) {
        info "skip restart, trigger file $triggerRestartFile is not configured"
          if $isVerboseEnabled0;
        return;
    }
    unless ( -e $triggerRestartFile ) {
        info "skip restart, trigger file $triggerRestartFile does not exist"
          if $isVerboseEnabled0;
        return;
    }
    unless ( unlink $triggerRestartFile ) {
        info "skip restart, cannot remove trigger file $triggerRestartFile"
          if $isVerboseEnabled0;
        return;
    }
    warning "restart";
    liquidsoapCmd('restart');
}

sub syncSchedule() {
    my $now = time();
    if ( $now - $previousSync < $maxSyncInterval ) {
        info "skip sync, has been done shortly before at "
          . timeToDatetime($previousSync)
          . ", age:"
          . int( $now - $previousSync )
          if $isVerboseEnabled0;
        return;
    }

    # create empty schedule file if not existing
    unless ( -e $scheduleFile ) {
        saveFile( ' schedule file ', $scheduleFile, "" );
        unless ( -e $scheduleFile ) {
            warning "could not write $scheduleFile! Please check permissions";
            return;
        }
    }

    # skip if trigger file does not exist
    unless ( -e $triggerSyncFile ) {
        info "skip sync, trigger file $triggerSyncFile does not exist"
          if $isVerboseEnabled0;
        return;
    }

    # skip if schedule file is up to date
    my $scheduleFileAge    = getFileLastModified($scheduleFile)    || 0;
    my $triggerSyncFileAge = getFileLastModified($triggerSyncFile) || 0;
    if ( $scheduleFileAge > $triggerSyncFileAge ) {
        info "skip sync, schedule file is up to date, lastModified="
          . timeToDatetime($scheduleFileAge)
          . ", lastTrigger="
          . timeToDatetime($triggerSyncFileAge)
          if $isVerboseEnabled0;
        return;
    }

    info "execute: $syncCommand" if $isVerboseEnabled1;
    clearErrorStatus();
    my $result   = `$syncCommand 2>&1`;
    my $exitCode = $? >> 8;
    warning "error in synchronization!" if $exitCode != 0;
    info $result if $isVerboseEnabled0;

    $previousSync = time();
}

sub parseAgendaLine($$) {
    my $plan = shift;
    my $line = shift;

    if ( $line =~ /^(\d{4}\-\d{2}\-\d{2})[T\s\;](\d{2}\:\d{2}(\:\d{2})?)[\s\;]+([^\;]+)[\s\;]*(\S+)?[\s\;]?/ ) {
        my $eventDate = $1 . ' ' . $2;
        my $event1    = $4 || '';
        my $event2    = $5 || '';
        info "event: '$eventDate' - '$event1' - '$event2'"
          if $isVerboseEnabled4;
        $eventDate .= ':00' if length($eventDate) <= 16;
        my $eventUnixDate = datetimeToEpoch($eventDate);

        #remove whitespaces from start and end
        $event1 =~ s/^\s+//g;
        $event1 =~ s/[\;\s]+$//g;
        $event2 =~ s/^\s+//g;
        $event2 =~ s/[\;\s]+$//g;
        my %eventStation = ();

        if ( defined $stations->{ lc($event1) } ) {

            #predefined station
            %eventStation = %{ $stations->{ lc($event1) } };
        } else {

            #build station from url
            %eventStation = (
                title => $event1,
                url1  => $event1,
                url2  => $event2
            );
        }

        #save last event before current unix date
        if ( $eventUnixDate < $unixDate ) {
            $plan->[0] = {
                name    => $event1,
                station => \%eventStation,
                date    => $eventDate,
                epoch   => $eventUnixDate
            };
        } else {
            push @$plan,
              {
                name    => $event1,
                station => \%eventStation,
                date    => $eventDate,
                epoch   => $eventUnixDate
              };
        }
    }

}

sub loadAgenda($) {
    my $filename = shift;

    info "load '$filename'" if $isVerboseEnabled2;

    my $timestamp = getFileLastModified($filename) || 0;
    info "lastModified " . timeToDatetime($timestamp) . " (" . timeToDatetime($scheduleFileModifiedAt) . ")"
      if $isVerboseEnabled2;

    if ( $timestamp == $scheduleFileModifiedAt ) {
        info "skip, file '$filename' has not changed" if $isVerboseEnabled1;
        return $plan;
    }
    $scheduleFileModifiedAt = $timestamp;
    info "reload schedule $filename" if $isVerboseEnabled0;

    my $plan = [];
    unless ( -e $filename ) {
        warning "schedule file '$filename' does not exist!";
        return $plan;
    }
    unless ( -r $filename ) {
        warning "cannot read schedule '$filename'!";
        return $plan;
    }
    open my $file, "<", $filename || exitOnError "cannot open schedule '$filename' for read!";

    while (<$file>) {
        parseAgendaLine( $plan, $_ );
    }
    close $file;
    return $plan;
}

sub playStation($) {
    my $event = shift;

    info sprintf( "play '%s'", $event->{name} || '' ) if $isVerboseEnabled2;
    setStream( 1, $event->{station}->{'url1'} );
    setStream( 2, $event->{station}->{'url2'} );
    updateTime();
}

sub setStream($;$) {
    my $channel = shift;
    my $url = shift || '';

    my $station = 'station' . $channel;
    if ( ( defined $url ) && ( $url =~ /^https?\:\/\// ) ) {

        my $status = getStreamStatus( $station, $url );

        # return on no connection
        return unless defined $status;

        unless ( $status =~ /^connected/ ) {
            info "reconnect '$url'" if $isVerboseEnabled1;

            # set stream
            liquidsoapCmd( $station . '.url ' . $url );
            liquidsoapCmd( $station . '.stop' );
            sleep(1);
            info "liquidsoap " . $station . ".url: " . $url
              if $isVerboseEnabled1;
            liquidsoapCmd( $station . '.start' );
            sleep(1);
            getStreamStatus( $station, $url );
        }
    } else {

        #mute channel
        $status->{liquidsoap}->{$station}->{error} = '';
        if ( ( $channel eq '1' ) && ( $url ne '' ) ) {
            my $msg = "invalid stream URL '$url'!";
            warning $msg, 'onlyToFile';
            $status->{liquidsoap}->{$station}->{error} = "WARNING : $msg";
        }

        # return on no connection
        info "liquidsoap " . $station . ".stop" if $isVerboseEnabled0;
        my $status = liquidsoapCmd( $station . '.url http://127.0.0.1/invalidStreamUrl' );
        return unless defined $status;

        liquidsoapCmd( $station . '.stop' );
        sleep(1);
        getStreamStatus( $station, $url );
    }
}

sub printOnChange($$) {
    my $key     = shift;
    my $message = shift;

    return if $message ne ( $previous->{$key} || '' );
    info $message;
    $previous->{$key} = $message;
}

#station: 1,2
#url: target url to be played

sub getStreamStatus($;$) {
    my $station = shift;
    my $url = shift || 'unknown';

    my $streamStatus = liquidsoapCmd( $station . '.status' );
    unless ( defined $streamStatus ) {
        $status->{liquidsoap}->{$station}->{url} = 'unknown';
        return undef;
    }

    printOnChange( "play-$station", "liquidsoap $station : $streamStatus" ) if $isVerboseEnabled1;
    $status->{liquidsoap}->{$station}->{url} = $streamStatus;

    $streamStatus =~ s/^connected //g;
    $streamStatus .= '/' if ( $streamStatus =~ /\:\d+$/ ) && ( $url =~ /\/$/ );

    if ( $url eq $streamStatus ) {
        info "status $station: '$url' -> $streamStatus -> connected"
          if $isVerboseEnabled2;
        return "connected";
    } else {
        info "status $station: '$url' -> $streamStatus -> not connected"
          if $isVerboseEnabled2;
        return "not connected";
    }
}

sub addMeasureToFile($$) {
    my $plotDir = shift;
    my $line    = shift;

    my @data = split( /\s/, $line );
    for my $i ( 0 .. 7 ) {
        $data[$i] = rmsToDb( $data[$i] );
    }

    my @localtime = localtime($unixDate);
    my @line = ( strftime( "%F %T", @localtime ), @data );
    $line = join( "\t ", @line ) . "\n";

    #print data to file
    my $filename = $plotDir . 'monitor' . '-' . strftime( "%F", @localtime ) . '.log';
    if ( -e $filename ) {
        my $result = open my $file, ">> ", $filename;
        if ( defined $result ) {
            print $file $line if defined $file;
            close $file if defined $file;
        } else {
            warning "cannot write plot log";
        }
    } else {
        my $result = open my $file, "> ", $filename;
        if ( defined $result ) {
            print $file $line;
            close $file;
            setFilePermissions($filename);
        }
    }
    info "RMS values measured" if $isVerboseEnabled2;

    #plot file
    $previousPlot = $unixDate;
    my $date = strftime( "%F", @localtime );
    plot( $filename, $date );

    # set status
    $status->{'measure-in'}->{peakLeft}   = $data[0];
    $status->{'measure-in'}->{peakRight}  = $data[1];
    $status->{'measure-in'}->{rmsLeft}    = $data[2];
    $status->{'measure-in'}->{rmsRight}   = $data[3];
    $status->{'measure-out'}->{peakLeft}  = $data[4];
    $status->{'measure-out'}->{peakRight} = $data[5];
    $status->{'measure-out'}->{rmsLeft}   = $data[6];
    $status->{'measure-out'}->{rmsRight}  = $data[7];

    if (   ( $status->{'measure-in'}->{rmsLeft} < -60 )
        && ( $status->{'measure-in'}->{rmsRight} < -60 ) )
    {
        my $message = "there is silence";
        $status->{warnings}->{$message} = time();
    }

}

sub measureLevels($) {
    my $status = shift;

    info "" if $isVerboseEnabled2;

    my $plotDir = $config->{scheduler}->{plotDir};
    return unless -e $plotDir;
    return unless -d $plotDir;

    my $remoteDuration = liquidsoapCmd('var.get duration');
    return unless defined $remoteDuration;

    $remoteDuration = 0.0 unless looks_like_number($remoteDuration);
    liquidsoapCmd( 'var.set duration=' . $rmsInterval )
      if $remoteDuration != $rmsInterval;

    #get data
    my $line = liquidsoapCmd('measure');
    addMeasureToFile( $plotDir, $line );

}

sub getUserId {
    my $userName = shift;
    my $userId   = getpwnam($userName);
    return $userId;
}

sub getGroupId($) {
    my $groupName = shift;
    my $groupId   = getgrnam($groupName);
    return $groupId;
}

sub setFilePermissions($) {
    my $path    = shift;
    my $userId  = getUserId('audiostream');
    my $groupId = getGroupId('www-data');
    return unless defined $userId;
    return unless defined $groupId;
    chown( $userId, $groupId, $path );
}

sub buildDataFile($$) {
    my $rmsFile  = shift;
    my $dataFile = shift;

    unlink $dataFile if -e $dataFile;
    info "parse $rmsFile";
    open my $file, "< ", $rmsFile or warn("cannot read from $rmsFile");

    my $content = '';
    while (<$file>) {
        my $line = $_;
        $line =~ s/\n//g;
        my @vals = split( /\t/, $line );
        if ( $line =~ /^#/ ) {
            $content .= $line . "\n";
            next;
        }
        next if scalar(@vals) < 5;

        for my $i ( 1 .. scalar(@vals) - 1 ) {
            my $val = $vals[$i];

            # silence detection
            if ( $val <= -100 ) {
                $vals[$i] = '-';
                next;
            }

            # cut off signal lower than minRMS
            $val = -$minRms if $val < -$minRms;

            # get absolute value
            $val = abs($val);

            # inverse value for plot (minRMS-val= plotVal)
            $val = $minRms - $val;
            $vals[$i] = $val;
        }
        $content .= join( "\t ", @vals ) . "\n";
    }
    close $file;

    info "plot $dataFile";
    open my $outFile, "> ", $dataFile or warn("cannot write to $dataFile");
    print $outFile $content;
    close $outFile;
}

sub plot($$) {
    my $filename = shift;
    my $date     = shift;

    my $plotDir = $config->{scheduler}->{plotDir};
    return unless -e $plotDir;
    return unless -d $plotDir;

    my $gnuplot = $config->{scheduler}->{gnuplot};
    return unless -e $gnuplot;

    unless ( -e $filename ) {
        warning("skip plot, $filename does not exist");
        return;
    }

    my $dataFile = '/tmp/' . File::Basename::basename($filename) . '.plot';
    buildDataFile( $filename, $dataFile );
    $filename = $dataFile;

    unless ( -e $filename ) {
        warning("skip plot, $filename does not exist");
        return;
    }

    info("") if $isVerboseEnabled2;

    my @ytics = ();
    for ( my $i = 0 ; $i <= $minRms ; $i += 8 ) {
        unshift @ytics, '"-' . ( $minRms - abs( -$i ) ) . '" ' . ( -$i );
        push @ytics, '"-' . ( $minRms - abs($i) ) . '" ' . ($i);
    }
    my $ytics = join( ", ", @ytics );

    my $plot = qq{
set terminal svg size 2000,600 linewidth 1 background rgb 'black'
set multiplot layout 3, 1        
set xdata time
set timefmt "%Y-%m-%d %H:%M:%S"
set datafile separator "\t"
set format x "%H-%M"

set border lc rgb '#f0f0f0f0'
set style fill transparent solid 0.3
set style data lines

unset border
set grid
set tmargin 1
set bmargin 1
set lmargin 10
set rmargin 3

set xrange ["} . $date . q{ 00:00:00Z":"} . $date . qq{ 23:59:59Z"]
      
} . qq{
set ylabel "input in dB" tc rgb "#f0f0f0"
set ytics ($ytics)
set yrange [-$minRms:$minRms]
    
plot \\
$minRms-20  notitle lc rgb "#50999999", \\
-$minRms+20 notitle lc rgb "#50999999", \\
$minRms-1   notitle lc rgb "#50999999", \\
-$minRms+1  notitle lc rgb "#50999999", \\
"}
      . $filename . q{" using 1:( $4) notitle lc rgb "#50eecccc" w filledcurves y1=0, \
"}
      . $filename . q{" using 1:(-$5) notitle lc rgb "#50cceecc" w filledcurves y1=0, \
"}
      . $filename . q{" using 1:( $2) notitle lc rgb "#50ff0000" w filledcurves y1=0, \
"}
      . $filename . q{" using 1:(-$3) notitle lc rgb "#5000ff00" w filledcurves y1=0

set ylabel "gain in dB" tc rgb "#f0f0f0"
set yrange [-24:24]
set ytics border mirror norotate autofreq
} . qq{
plot \\
0 notitle lc rgb "#50999999", \\
"}
      . $filename . qq{" using 1:(.0+(\$6)-(\$2)) notitle lc rgb "#50ff0000" smooth freq, \\
"}
      . $filename . qq{" using 1:(.0+(\$7)-(\$3)) notitle lc rgb "#5000ff00" smooth freq\\

} . qq{
set ylabel "output in dB" tc rgb "#f0f0f0"
set ytics ($ytics)
set yrange [-$minRms:$minRms]

plot \\
$minRms-20  notitle lc rgb "#00999999", \\
-$minRms+20 notitle lc rgb "#00999999", \\
$minRms-1   notitle lc rgb "#00999999", \\
-$minRms+1  notitle lc rgb "#00999999", \\
"}
      . $filename . q{" using 1:( $8) notitle lc rgb "#50eecccc" w filledcurves y1=0, \
"}
      . $filename . q{" using 1:(-$9) notitle lc rgb "#50cceecc" w filledcurves y1=0, \
"}
      . $filename . q{" using 1:( $6) notitle lc rgb "#50ff0000" w filledcurves y1=0, \
"}
      . $filename . q{" using 1:(-$7) notitle lc rgb "#5000ff00" w filledcurves y1=0

};
    my $plotFile = "/tmp/monitor.plot";
    open my $file, '>', $plotFile;
    print $file $plot;
    close $file;

    my $tempImageFile = "/tmp/monitor.svg";
    my $imageFile     = "$plotDir/monitor-$date.svg";
    my $command       = "$gnuplot '$plotFile' > '$tempImageFile'";
    info($command);
    `$command`;
    my $exitCode = $? >> 8;
    if ( $exitCode != 0 ) {
        warning("plot finished with $exitCode");
    } else {
        File::Copy::copy( $tempImageFile, $imageFile );
        info("plot finished with $exitCode") if $isVerboseEnabled2;
    }

    setFilePermissions($imageFile);

    #unlink $plotFile;
}

sub liquidsoapCmd ($) {
    my $command = shift;

    if ( ( defined $liquidsoapHost ) && ( defined $liquidsoapPort ) ) {
        my $result = liquidsoapTelnetCmd( $telnetSocket, $command );
        return undef unless defined $result;
        if ( $result =~ /Connection timed out/ ) {
            closeSocket($telnetSocket);
            info "retry ..." if $isVerboseEnabled1;
            $result = liquidsoapTelnetCmd( $telnetSocket, $command );
        }
        return $result;
    }
    warning "neither liquidsoap unix socket is configured nor telnet host and port";
}

sub closeSocket($) {
    my $socket = shift;
    return unless defined $socket;

    info "close socket $socket" if $isVerboseEnabled3;
    if ( defined $socket ) {
        my $select = IO::Select->new();
        $select->add($socket);
        print $socket "exit\n" if $select->can_write($socketTimeout);
    }
    close $socket if defined $socket;
    $socket = undef;
}

sub openTelnetSocket ($) {
    my $socket = $_[0];

    unless ( defined $socket ) {
        info "open telnet socket to $liquidsoapHost:$liquidsoapPort"
          if $isVerboseEnabled3;
        $socket = IO::Socket::INET->new(
            PeerAddr => $liquidsoapHost,
            PeerPort => $liquidsoapPort,
            Proto    => "tcp",
            Type     => SOCK_STREAM,
            Timeout  => $socketTimeout,
        );
        info "opened $socket" if ( defined $socket ) && $isVerboseEnabled3;
    }

    my $message = "liquidsoap is not available! " . "Cannot connect to telnet $liquidsoapHost:$liquidsoapPort";

    unless ( defined $socket ) {
        $status->{liquidsoap}->{cli} = $message;
        error $message;
        return undef;
    }

    if (   ( defined $status->{liquidsoap} )
        && ( defined $status->{liquidsoap}->{cli} ) )
    {
        $status->{liquidsoap}->{cli} = ''
          if $status->{liquidsoap}->{cli} eq $message;
    }
    return $socket;
}

sub writeSocket($$) {
    my $socket  = $_[0];
    my $command = $_[1];

    my $select = IO::Select->new();
    $select->add($socket);

    my $stopTime = time() + $socketTimeout;
    my $data     = $command . "\n";
    while ( length($data) > 0 ) {
        for my $handle ( $select->can_write($socketTimeout) ) {
            info "syswrite '$data'" if $isVerboseEnabled3;
            my $rc = syswrite $handle, $data;
            if ( $rc > 0 ) {
                info "syswrite ok, length=$rc" if $isVerboseEnabled3;
                substr( $data, 0, $rc ) = '';
            } elsif ( $! == EWOULDBLOCK ) {
                info "syswrite would block" if $isVerboseEnabled3;

            } else {
                warning "syswrite error for command=$command";
                closeSocket($socket);
                return 0;
            }
        }
        if ( time() > $stopTime ) {
            warning "syswrite timeout for command=$command";
            closeSocket($socket);
            return 0;
        }
    }
    return 1;

}

sub readSocket($) {
    my $socket = $_[0];
    my $lines  = '';

    my $stopTime = time() + $socketTimeout;
    my $select   = IO::Select->new();
    $select->add($socket);
    while (1) {
        for my $handle ( $select->can_read($socketTimeout) ) {
            my $data = '';
            my $rc = sysread $handle, $data, 60000;
            if ( defined $rc ) {
                if ( $rc > 0 ) {
                    info "sysread ok: $data" if $isVerboseEnabled3;
                    $lines .= $data;
                } else {
                    info "sysread end of line" if $isVerboseEnabled3;
                    closeSocket($socket);
                }
            } elsif ( $! == EWOULDBLOCK ) {

                # would block
                info "sysread would block" if $isVerboseEnabled3;
            } else {

                #error
                warning "sysread error";
                closeSocket($socket);
            }
        }
        last if $lines =~ /\r\nEND\r\n/;
        if ( time() > $stopTime ) {
            warning "sysread timeout";
            closeSocket($socket);
            last;
        }
    }
    info "result:'$lines'" if $isVerboseEnabled3;
    return $lines;

}

sub parseLiquidsoapResponse($$) {
    my $command = $_[0];
    my $lines   = $_[1];

    my $result = '';
    if ( defined $lines ) {
        for my $line ( split( /\r\n/, $lines ) ) {
            next unless defined $line;
            next                 if $line eq $command;
            last                 if $line =~ /^END/;
            info "line:" . $line if $isVerboseEnabled3;
            $result .= $line . "\n";
        }
    }
    $result =~ s/\s+$//;
    info "result:'$result'" if $isVerboseEnabled3;
    return $result;
}

sub liquidsoapTelnetCmd ($$) {
    my $socket  = $_[0];
    my $command = $_[1];

    info "send command '$command' to $liquidsoapHost:$liquidsoapPort"
      if $isVerboseEnabled2;
    $socket = openTelnetSocket($socket);
    return '' unless defined $socket;
    writeSocket( $socket, $command ) || return '';
    my $lines = readSocket($socket);
    my $result = parseLiquidsoapResponse( $command, $lines );

    return $result;

}

sub timeToDatetime($) {
    my $time = shift;

    $time = time() unless ( defined $time ) && ( $time ne '' );
    ( my $sec, my $min, my $hour, my $day, my $month, my $year ) = localtime($time);
    my $datetime = sprintf( "%4d-%02d-%02d %02d:%02d:%02d", $year + 1900, $month + 1, $day, $hour, $min, $sec );
    return $datetime;
}

sub datetimeToEpoch($) {
    my $datetime = shift || '';
    if ( $datetime =~ /(\d\d\d\d)\-(\d+)\-(\d+)[T\s](\d+)\:(\d+)(\:(\d+))?/ ) {
        my $year   = $1;
        my $month  = $2 - 1;
        my $day    = $3;
        my $hour   = $4;
        my $minute = $5;
        my $second = $7 || '00';
        return Time::Local::timelocal( $second, $minute, $hour, $day, $month, $year );

    } else {
        warning "no valid date time found! ($datetime)", 'onlyToFile';
        return -1;
    }
}

sub writeStatusFile($) {
    my $filename = shift;

    info "" if $isVerboseEnabled2;
    for my $key ( keys %{ $status->{warnings} } ) {
        my $time = $status->{warnings}->{$key};
        delete $status->{warnings}->{$key}
          if ( defined $time ) && $time < $lastStatusUpdate;
    }

    my $entry = {
        schedule   => $plan,
        current    => clone($event),
        next       => clone($next),
        liquidsoap => $status->{liquidsoap},
        stations   => $stations,
        warnings   => $status->{warnings}
    };

    warning "status file '$filename' does not exist!" unless -w $filename;
    return unless checkWritePermissions( 'status file', $filename );
    Storable::nstore( $entry, $filename );
    $lastStatusUpdate = time();

    setFilePermissions($filename);
}

sub printStatus() {
    my $line = $state;
    $line .= " " . formatTime($timeTillSwitch) if defined $timeTillSwitch;
    $line .= ", " . $next->{name} . ' at ' . $next->{date}
      if defined $next->{date};
    info $line if $isVerboseEnabled0;
}

sub formatTime($) {
    my $time = shift;
    $time = -$time if $time < 0;

    my $s = '';
    if ( $time > $day ) {
        my $days = int( $time / $day );
        $time -= $days * $day;
        $s .= $days . " days, ";
    }
    if ( $time > $hour ) {
        my $hours = int( $time / $hour );
        $time -= $hours * $hour;
        $s .= $hours . " hours, ";
    }
    if ( $time > $min ) {
        my $mins = int( $time / $min );
        $time -= $mins * $min;
        $s .= $mins . " mins, ";
    }
    $s .= sprintf( '%.02f', $time ) . " secs";

    return $s;
}

sub clearErrorStatus() {
    $status->{warnings}                        = {};
    $status->{liquidsoap}->{station1}->{error} = '';
    $status->{liquidsoap}->{station2}->{error} = '';
}

#full scale to DB
sub rmsToDb($) {
    my $val = $_[0];
    if ( ( looks_like_number($val) ) && ( $val > 0.0 ) ) {
        my $val = 20.0 * log($val) / log(10.0);
        return sprintf( "%.02f", $val );
    } else {
        return -100.0;
    }
}

$SIG{INT} = sub {
    info "received INT signal, cleanup and quit" if $isVerboseEnabled0;
    closeSocket($telnetSocket);
    exit;
};

$SIG{TERM} = sub {
    info "received TERM signal, cleanup and quit" if $isVerboseEnabled0;
    closeSocket($telnetSocket);
    exit;
};

$SIG{HUP} = sub {
    info "received HUP signal, reload configuration (toBeDone, workaround=quit"
      if $isVerboseEnabled0;
    closeSocket($telnetSocket);
    exit;
};

$SIG{PIPE} = sub {
    info "connection lost to liquidsoap (broken pipe), close sockets"
      if $isVerboseEnabled0;
    closeSocket($telnetSocket);
};

END {
    closeSocket($telnetSocket);
}

while (1) {
    updateTime();
    $cycleStart = $unixDate;
    info "$unixDate - $previousCheck = " . ( $unixDate - $previousCheck ) . " > $reload ?"
      if $isVerboseEnabled3;
    $state = 'check' if $unixDate - $previousCheck > $reload;

    checkRestartLiquidsoap();
    syncSchedule();
    getEvents() if $state eq 'check';
    checkRunning($event);
    printStatus();
    checkStreamSwitch($timeTillSwitch);
    eval { measureLevels($status); };
    writeStatusFile($schedulerStatusFile) if $schedulerStatusFile ne '';

    $status->{liquidsoap}->{cli} = '';
    checkSleep($state);
}
