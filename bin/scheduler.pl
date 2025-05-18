#!/usr/bin/perl -w
use strict;
use warnings;
use v5.10;
use File::Basename  qw();
use File::Copy      ();
use Time::Local     qw();
use Config::General qw();
use Getopt::Long    qw();
use Clone           qw(clone);
use POSIX;
use Time::HiRes      qw(time sleep);
use Scalar::Util     qw(looks_like_number);
use Storable         qw();
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

sub timeToDatetime {
    my @time = localtime($_[0] // time);
    return sprintf '%04d-%02d-%02d %02d:%02d:%02d',
        $time[5] + 1900, $time[4] + 1, $time[3], $time[2], $time[1], $time[0];
}

sub updateTime {
    print "\n" if $isVerboseEnabled2;
    $unixDate       = time();
    $date           = timeToDatetime($unixDate);
    $timeTillSwitch = $next->{epoch} - $unixDate - $streamSwitchOffset
        if defined $next->{epoch};
}

sub getCaller {
    my ($package, $filename, $line, $subroutine) = caller(2);
    return undef unless defined $subroutine;
    $subroutine =~ s/main\:\://;
    return "$subroutine()";
}

sub info {
    my ($message) = @_;
    my $caller = getCaller();
    $message =~ s/([\n\r])\\/\\$1/g;
    print join("\t", timeToDatetime(), $$, "INFO",  ($caller ? sprintf("\t%-16s", $caller) : ()), "$message\n");
}

sub warning {
    my ($message, $onlyToFile) = @_;
    $message =~ s/([\n\r])\\/\\$1/g;
    print join("\t", timeToDatetime(), $$, "WARN", "$message\n");
    $status->{warnings}->{$message} = time unless defined $onlyToFile;
}

sub error {
    my ($message) = @_;
    print join("\t", timeToDatetime(), $$, "ERROR", "$message\n");
    $status->{warnings}->{$message} = time;
}

sub exitOnError {
    my ($message) = @_;
    print STDERR join("\t", timeToDatetime(), $$, "ERROR", getCaller(), "$message\n");
    $status->{warnings}->{$message} = time;
    exit;
}

sub datetimeToEpoch {
    my $datetime = shift || '';
    if ($datetime =~ /(\d\d\d\d)\-(\d+)\-(\d+)[T\s](\d+)\:(\d+)(\:(\d+))?/) {
        my $year   = $1;
        my $month  = $2 - 1;
        my $day    = $3;
        my $hour   = $4;
        my $minute = $5;
        my $second = $7 || '00';
        return Time::Local::timelocal($second, $minute, $hour, $day, $month, $year);
    }
    warning("no valid date time found! ($datetime)" . 'onlyToFile');
    return -1;
}

sub getConfig {
    my ($filename) = @_;
    exitOnError("config file '$filename' does not exist") unless -e $filename;
    exitOnError("cannot read config '$filename'") unless -r $filename;
    my $configuration = new Config::General($filename);
    my $config        = $configuration->{DefaultConfig};
    my $stations = $config->{stations}->{station};
    $stations = [$stations] if ref($stations) eq 'HASH';
    exitOnError('No stations configured!') unless defined $stations;
    exitOnError('configured stations should be a list!') unless ref($stations) eq 'ARRAY';
    exitOnError('There should be configured at least one station!') unless @$stations;
    my $manditoryAttributes = ['alias', 'url1', 'url2'];
    for my $station (@$stations) {
        $station->{$_} //= '' for qw(alias url1 url2);
    }
    $config->{stations} = $stations;
    return $config;
}

sub getFileLastModified {
    return (stat(shift))[9];
}

sub writePidFile {
    saveFile('pid file', '/var/run/stream-schedule/stream-schedule.pid', $$);
}

sub checkWritePermissions {
    my ($label, $filename) = @_;
    if (-e $filename && !-w $filename) {
        warning("cannot write $label to '$filename'! Please check file permissions!");
        return 0;
    }
    my $dir = File::Basename::dirname($filename);
    unless (-w $dir) {
        warning("cannot write $label to dir $dir! Please check file permissions!");
        return 0;
    }
    return 1;
}

sub saveFile {
    my ($label, $filename, $content) = @_;
    return unless checkWritePermissions($label, $filename) == 1;
    open my $fh, ">", $filename or exitOnError(
        "cannot write $label to file '$filename'! Please check file permissions!"
    );
    print $fh $content;
    close $fh;
    info("saved $label to '$filename'") if $isVerboseEnabled0;
}

sub daemonize {
    my $log = shift;
    saveFile('log file', $log, '') unless -e $log;
    setFilePermissions($log);
    open STDOUT, ">>", $log or die "Can't write to '$log': $!";
    open STDERR, ">>", $log or die "Can't write to '$log': $!";
    umask 0;
    writePidFile();
}

sub readStations {
    my $stations = shift;
    info("") if $isVerboseEnabled2;
    my $results = {};
    for my $station (@$stations) {
        my $id = $station->{id};
        $results->{lc($id)} = $station;
        for my $name (split(/\s*,\s*/, $station->{alias})) {
            $results->{lc($name)} = $station;
        }
    }
    if ($verbose > 1) {
        info("supported stations") if $isVerboseEnabled1;
        for my $key (sort keys %$results) {
            info(sprintf("%-12s\t'%s'\t'%s'",
                $key, $results->{$key}->{url1}, $results->{$key}->{url2}
            ));
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
if (defined $params->{help}) {
    print usage;
    exit;
}
my $telnetSocket  = undef;
my $socketTimeout = 1;
my $minRms        = -36;
$minRms *= -1 if $minRms < 0;
# get config file
if ($params->{config} eq '') {
    my $configFile = '/etc/stream-schedule/stream-schedule.conf';
    $params->{config} = $configFile if -e $configFile;
}
# read config
my $config = getConfig($params->{config});
$verbose = $config->{scheduler}->{verbose} unless defined $verbose;
$verbose = 1                               unless defined $verbose;
$isVerboseEnabled0 = (defined $verbose) && ($verbose >= 0);
$isVerboseEnabled1 = (defined $verbose) && ($verbose >= 1);
$isVerboseEnabled2 = (defined $verbose) && ($verbose >= 2);
$isVerboseEnabled3 = (defined $verbose) && ($verbose >= 3);
$isVerboseEnabled4 = (defined $verbose) && ($verbose >= 4);
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
info("INIT") if $isVerboseEnabled0;
# plot interval in seconds
my $plotInterval = 1 * 60;
# write rms status in seconds
my $rmsInterval = 60;
my $maxRestartInterval = 1 * 60;
my $maxSyncInterval    = 3 * 60;
my $previousSync       = time();
if (-e $scheduleFile) {
    $previousSync = getFileLastModified($scheduleFile);
} else {
    $previousSync -= $maxSyncInterval;
}
my $lastStatusUpdate = time();
my $stations         = readStations($config->{stations});

sub getEvents {
    info("") if $isVerboseEnabled2;
    $plan = loadAgenda($scheduleFile, $unixDate);
    if (@$plan) {
        ($event, $next) = getNextEvent($plan);
        unless (defined $event) {
            warning('empty schedule!', 'onlyToFile');
            $state = 'sleep';
        }
    } else {
        warning('empty schedule !');
        $state = 'sleep';
    }
}

sub checkRunning {
    my $entry = shift;
    info("") if $isVerboseEnabled2;
    updateTime();
    if (defined $entry->{date} && $entry->{date} lt $date) {
        info("running '$entry->{name}' since $entry->{date}") if $isVerboseEnabled2;
        $entry->{epoch} = datetimeToEpoch($entry->{date});
        playStation($entry);
    }
    $previousCheck = $unixDate;
}

sub checkStreamSwitch {
    my $timeTillSwitch = shift;
    info("") if $isVerboseEnabled2;
    if ($timeTillSwitch <= 0) {
        playStation($next);
        my $sleep = $streamSwitchOffset + 1;
        info("sleep $sleep secs (offset)") if $isVerboseEnabled1;
        sleep($sleep);
        ($event, $next) = getNextEvent($plan);
    }
}

sub checkSleep {
    my $state = shift;
    my $cycleDuration = time() - $cycleStart;
    my $sleep         = 30 - $cycleDuration;
    $sleep = 0 if $sleep < 0;
    updateTime();
    if ($state eq 'sleep') {
        info(sprintf('sleep %0.2f seconds', $sleep)) if $isVerboseEnabled1;
        sleep($sleep);
    } elsif ($timeTillSwitch < 0) {
        info(sprintf('sleep %0.2f seconds', $sleep)) if $isVerboseEnabled1;
        sleep($sleep);
    } elsif ($timeTillSwitch > 50) {
        info(sprintf('sleep %0.2f seconds', $sleep)) if $isVerboseEnabled1;
        sleep($sleep);
    } elsif ($timeTillSwitch > 30) {
        info(sprintf('sleep %0.2f seconds', $sleep)) if $isVerboseEnabled1;
        sleep(10);
    } elsif (($timeTillSwitch > 5) && ($timeTillSwitch <= 30)) {
        my $sleep = $timeTillSwitch - 5;
        info(sprintf('sleep %0.2f seconds', $sleep)) if $isVerboseEnabled0;
        sleep($sleep);
    } elsif ($timeTillSwitch > 0) {
        my $sleep = $timeTillSwitch;
        info(sprintf('sleep %0.2f seconds', $sleep)) if $isVerboseEnabled1;
        sleep($sleep);
    } else {
        info("sleep 1 second") if $isVerboseEnabled1;
        sleep(1);
    }
}

sub getNextEvent {
    my ($plan) = @_;
    updateTime();
    my $current = $plan->[0];
    for my $entry (@$plan) {
        if ($entry->{epoch} >= $unixDate) {
            info("found next $entry->{name} at $entry->{date} " . getStationinfo($entry->{station}))
                if $isVerboseEnabled2;
            $state = 'next in';
            return ($current, $entry);
        }
        $current = $entry;
    }
    warning('no future entries found in schedule!');
    if (@$plan) {
        my $entry = $plan->[-1];
        info("found next $entry->{name} at $entry->{date} " . getStationinfo($entry->{station}))
            if $isVerboseEnabled2;
        $state = 'last since';
        return ($entry, $entry);
    }
    return undef;
}

sub getStationinfo {
    my $station = shift;
    return join("\t", grep { defined } ($station->{url1}, $station->{url2}));
}

sub checkRestartLiquidsoap {
    if ($triggerRestartFile eq '') {
        info("skip restart, trigger file $triggerRestartFile is not configured")
            if $isVerboseEnabled0;
        return;
    }
    unless (-e $triggerRestartFile) {
        info("skip restart, trigger file $triggerRestartFile does not exist")
            if $isVerboseEnabled0;
        return;
    }
    unless (unlink $triggerRestartFile) {
        info("skip restart, cannot remove trigger file $triggerRestartFile")
            if $isVerboseEnabled0;
        return;
    }
    warning("restart");
    liquidsoapCmd('restart');
}

sub syncSchedule {
    my $now = time();
    if ($now - $previousSync < $maxSyncInterval) {
        info("skip sync, has been done shortly before at "
            . timeToDatetime($previousSync)
            . ", age:"
            . int($now - $previousSync)
        ) if $isVerboseEnabled0;
        return;
    }
    # Ensure schedule file exists
    unless (-e $scheduleFile) {
        saveFile(' schedule file ', $scheduleFile, "");
        unless (-e $scheduleFile) {
            warning("could not write $scheduleFile! Please check permissions");
            return;
        }
    }
    # skip sync if trigger file is missing
    unless (-e $triggerSyncFile) {
        info("skip sync, trigger file $triggerSyncFile does not exist")
            if $isVerboseEnabled0;
        return;
    }
    # skip if schedule file is up to date
    my $scheduleFileAge    = getFileLastModified($scheduleFile)    || 0;
    my $triggerSyncFileAge = getFileLastModified($triggerSyncFile) || 0;
    if ($scheduleFileAge > $triggerSyncFileAge) {
        info("skip sync, schedule file is up to date, lastModified="
            . timeToDatetime($scheduleFileAge)
            . ", lastTrigger="
            . timeToDatetime($triggerSyncFileAge)
            ) if $isVerboseEnabled0;
        return;
    }
    info("execute: $syncCommand") if $isVerboseEnabled1;
    clearErrorStatus();
    my $result   = `$syncCommand 2>&1`;
    my $exitCode = $? >> 8;
    warning("error in synchronization!") if $exitCode != 0;
    info($result)                        if $isVerboseEnabled0;
    $previousSync = time();
}

sub parseAgendaLine {
    my ($plan, $line) = @_;
    if (
        $line =~ /^(\d{4}\-\d{2}\-\d{2})[T\s\;](\d{2}\:\d{2}(\:\d{2})?)[\s\;]+([^\;]+)[\s\;]*(\S+)?[\s\;]?/
    ) {
        my $eventDate = "$1 $2";
        my $event1    = $4 || '';
        my $event2    = $5 || '';
        info("event: '$eventDate' - '$event1' - '$event2'") if $isVerboseEnabled4;
        $eventDate .= ':00' if length($eventDate) <= 16;
        my $eventUnixDate = datetimeToEpoch($eventDate);
        #remove whitespaces from start and end
        $event1 =~ s/^\s+//g;
        $event1 =~ s/[\;\s]+$//g;
        $event2 =~ s/^\s+//g;
        $event2 =~ s/[\;\s]+$//g;
        my %eventStation = ();
        if (defined $stations->{lc($event1)}) {
            #predefined station
            %eventStation = %{$stations->{lc($event1)}};
        } else {
            #build station from url
            %eventStation = (
                title => $event1,
                url1  => $event1,
                url2  => $event2
            );
        }
        #save last event before current unix date
        if ($eventUnixDate < $unixDate) {
            $plan->[0] = {
                name    => $event1,
                station => \%eventStation,
                date    => $eventDate,
                epoch   => $eventUnixDate
            };
        } else {
            push @$plan, {
                name    => $event1,
                station => \%eventStation,
                date    => $eventDate,
                epoch   => $eventUnixDate
            };
        }
    }
}

sub loadAgenda {
    my $filename = shift;
    info("load '$filename'") if $isVerboseEnabled2;
    my $timestamp = getFileLastModified($filename) || 0;
    info("lastModified "
        . timeToDatetime($timestamp) . " ("
        . timeToDatetime($scheduleFileModifiedAt) . ")"
        ) if $isVerboseEnabled2;
    if ($timestamp == $scheduleFileModifiedAt) {
        info("skip, file '$filename' has not changed") if $isVerboseEnabled1;
        return $plan;
    }
    $scheduleFileModifiedAt = $timestamp;
    info("reload schedule $filename") if $isVerboseEnabled0;
    my $plan = [];
    unless (-e $filename) {
        warning("schedule file '$filename' does not exist!");
        return $plan;
    }
    unless (-r $filename) {
        warning("cannot read schedule '$filename'!");
        return $plan;
    }
    open my $file, "<",
        $filename or exitOnError("cannot open schedule '$filename' for read!");
    while (<$file>) {
        parseAgendaLine($plan, $_);
    }
    close $file;
    return $plan;
}

sub playStation($) {
    my $event = shift;
    info(sprintf("play '%s'", $event->{name} // '')) if $isVerboseEnabled2;
    setStream(1, $event->{station}->{'url1'});
    setStream(2, $event->{station}->{'url2'});
    updateTime();
}

sub setStream {
    my ($channel, $url) = @_;
    $url ||= '';
    my $station = "station$channel";
    if (($url =~ /^https?\:\/\//)) {
        my $status = getStreamStatus($station, $url) or return;
        unless ($status =~ /^connected/) {
            info("reconnect '$url'") if $isVerboseEnabled1;
            liquidsoapCmd($station . '.url ' . $url);
            liquidsoapCmd($station . '.stop');
            sleep(1);
            info("liquidsoap " . $station . ".url: " . $url)
                if $isVerboseEnabled1;
            liquidsoapCmd($station . '.start');
            sleep(1);
            getStreamStatus($station, $url);
        }
    } else {
        $status->{liquidsoap}->{$station}->{error} = '';
        if (($channel eq '1') && ($url ne '')) {
            my $msg = "invalid stream URL '$url'!";
            warning($msg, 'onlyToFile');
            $status->{liquidsoap}->{$station}->{error} = "warning(: $msg";
        }
        info("liquidsoap " . $station . ".stop") if $isVerboseEnabled0;
        my $status = liquidsoapCmd($station . '.url http://127.0.0.1/invalidStreamUrl');
        return unless defined $status;
        liquidsoapCmd($station . '.stop');
        sleep(1);
        getStreamStatus($station, $url);
    }
}

sub printOnChange($$) {
    my ($key, $message) = @_;
    return if $message ne ($previous->{$key} || '');
    info($message);
    $previous->{$key} = $message;
}
#station: 1,2
#url: target url to be played

sub getStreamStatus($;$) {
    my ($station, $url) = @_;
    $url //= 'unknown';
    my $streamStatus = liquidsoapCmd($station . '.status');
    unless (defined $streamStatus) {
        $status->{liquidsoap}->{$station}->{url} = 'unknown';
        return undef;
    }
    printOnChange("play-$station", "liquidsoap $station : $streamStatus")
        if $isVerboseEnabled1;
    $status->{liquidsoap}->{$station}->{url} = $streamStatus;
    $streamStatus =~ s/^connected //g;
    $streamStatus .= '/' if ($streamStatus =~ /\:\d+$/) && ($url =~ /\/$/);
    if ($url eq $streamStatus) {
        info("status $station: '$url' -> $streamStatus -> connected") if $isVerboseEnabled2;
        return "connected";
    } else {
        info("status $station: '$url' -> $streamStatus -> not connected") if $isVerboseEnabled2;
        return "not connected";
    }
}

# read audio levels from log file, then update status and plot
# format: peak in L, peak in R, rms in L, rms in R, peak out L, peak out R, rms out L, rms out R

sub measureLevels {
    my ($status) = @_;
    info("") if $isVerboseEnabled2;
    my $plotDir = $config->{scheduler}->{plotDir};
    return unless -d $plotDir;

    my $date = strftime("%F", localtime($unixDate));
    my $filename = $plotDir . "monitor-$date.log";
    my $line = qx{tail -1 $filename};
    (my $datetime,
        $status->{'measure-in'}->{peakLeft},  $status->{'measure-in'}->{peakRight},
        $status->{'measure-in'}->{rmsLeft},   $status->{'measure-in'}->{rmsRight},
        $status->{'measure-out'}->{peakLeft}, $status->{'measure-out'}->{peakRight},
        $status->{'measure-out'}->{rmsLeft},  $status->{'measure-out'}->{rmsRight}
    ) = split /\t/, $line;
    info("RMS values measured") if $isVerboseEnabled2;

    $status->{warnings}->{"there is silence"} = time() if
           $status->{'measure-in'}->{rmsLeft} < -60
        && $status->{'measure-in'}->{rmsRight} < -60;

    $previousPlot = $unixDate;
    plot($filename, $date);
}

sub setFilePermissions {
    my $path    = shift;
    my $userId  = getpwnam('audiostream');
    my $groupId = getgrnam('www-data');
    return unless defined $userId && defined $groupId;
    chown($userId, $groupId, $path);
}

sub buildDataFile {
    my ($rmsFile) = @_;
    info("parse $rmsFile");
    open my $file, "< ", $rmsFile or return warn("cannot read from $rmsFile");
    my @lines = ();
    while (<$file>) {
        if ($_ =~ /^#/) {
            push  @lines, $_;
            next;
        }
        my @vals = split /\t/, $_;
        if (scalar @vals >= 5) {
            push @lines, join ("\t", $vals[0], map {
                $_ <= -100 ? '-' : $minRms - abs(($_ < -$minRms ? -$minRms : $_))
            } @vals[1..8]);
        }
    }
    close $file;
    return join("\n", @lines)."\n";
}

sub plot {
    my ($filename, $date) = @_;

    my $plotDir = $config->{scheduler}->{plotDir};
    my $gnuplot = $config->{scheduler}->{gnuplot};

    return warning("plotDir not found") unless -d $plotDir;
    return warning("gnuplot binary not found") unless -e $gnuplot;
    return warning("skip plot, $filename does not exist") unless -e $filename;

    my $base = File::Basename::basename($filename);
    my $dataFile = "/tmp/$base.plot";

    open my $out, ">", $dataFile or return warning("Cannot write to $dataFile");
    print $out join("\n", buildDataFile($filename)) . "\n";
    close $out;

    return warning("skip plot, data file missing after build") unless -e $dataFile;

    info("") if $isVerboseEnabled2;
    $filename = $dataFile;

    my @ytics = ();
    for (my $i = 0; $i <= $minRms; $i += 8) {
        unshift @ytics, '"-' . ($minRms - abs(-$i)) . '" ' . (-$i);
        push @ytics, '"-' . ($minRms - abs($i)) . '" ' . ($i);
    }
    my $ytics = join(", ", @ytics);

    my $tempImageFile = "/tmp/monitor.svg";
    info("gnuplot save to $tempImageFile");
    my $plot = <<"PLOT";
set terminal svg size 2000,600 linewidth 1 background rgb 'black'
set output "| cat > $tempImageFile"
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
set bmargin 2
set lmargin 10
set rmargin 3
set xrange ["$date 00:00:00Z":"$date 23:59:59Z"]

set ylabel "Input in dB" tc rgb "#f0f0f0"
set ytics ($ytics)
set yrange [-$minRms:$minRms]
plot \\
    $minRms-20 notitle lc rgb "#50999999", \\
   -$minRms+20 notitle lc rgb "#50999999", \\
    $minRms-1  notitle lc rgb "#50999999", \\
   -$minRms+1  notitle lc rgb "#50999999", \\
   "$filename" using 1:( \$4) notitle lc rgb "#50eecccc" w filledcurves y1=0, \\
   "$filename" using 1:(-\$5) notitle lc rgb "#50cceecc" w filledcurves y1=0, \\
   "$filename" using 1:( \$2) notitle lc rgb "#50ff0000" w filledcurves y1=0, \\
   "$filename" using 1:(-\$3) notitle lc rgb "#5000ff00" w filledcurves y1=0

set ylabel "Gain in dB" tc rgb "#f0f0f0"
set yrange [-24:24]
set ytics border mirror norotate autofreq
plot \\
    0 notitle lc rgb "#50999999", \\
   "$filename" using 1:(0+(\$6)-(\$2)) notitle lc rgb "#50ff0000" smooth freq, \\
   "$filename" using 1:(0+(\$7)-(\$3)) notitle lc rgb "#5000ff00" smooth freq

set ylabel "Output in dB" tc rgb "#f0f0f0"
set ytics ($ytics)
set yrange [-$minRms:$minRms]
plot \\
    $minRms-20 notitle lc rgb "#00999999", \\
   -$minRms+20 notitle lc rgb "#00999999", \\
    $minRms-1  notitle lc rgb "#00999999", \\
   -$minRms+1  notitle lc rgb "#00999999", \\
   "$filename" using 1:( \$8) notitle lc rgb "#50eecccc" w filledcurves y1=0, \\
   "$filename" using 1:(-\$9) notitle lc rgb "#50cceecc" w filledcurves y1=0, \\
   "$filename" using 1:( \$6) notitle lc rgb "#50ff0000" w filledcurves y1=0, \\
   "$filename" using 1:(-\$7) notitle lc rgb "#5000ff00" w filledcurves y1=0
PLOT

    open my $gp, "|-", $gnuplot or return warning("Cannot open pipe to gnuplot");
    print $gp $plot;
    close $gp;
    my $exitCode = $? >> 8;
    return warning("plot finished with exit code $exitCode") if $?;

    my $imageFile = "$plotDir/monitor-$date.svg";
    File::Copy::copy($tempImageFile, $imageFile) or return warning("cannot copy image");
    setFilePermissions($imageFile);
    info("plot finished successfully") if $isVerboseEnabled2;
}

sub liquidsoapCmd ($) {
    my $command = shift;
    return warning("neither liquidsoap unix socket is configured nor telnet host and port")
        unless (defined $liquidsoapHost && defined $liquidsoapPort);
    my $result = liquidsoapTelnetCmd($telnetSocket, $command) or return;
    if ($result =~ /Connection timed out/) {
        closeSocket($telnetSocket);
        info("retry ...") if $isVerboseEnabled1;
        $result = liquidsoapTelnetCmd($telnetSocket, $command);
    }
    return $result;
}

sub closeSocket {
    my $socket = shift;
    return unless defined $socket;
    info("close socket $socket") if $isVerboseEnabled3;
    my $select = IO::Select->new();
    $select->add($socket);
    print $socket "exit\n" if $select->can_write($socketTimeout);
    close $socket;
    $socket = undef;
}

sub openTelnetSocket {
    my $socket = shift;
    unless (defined $socket) {
        info("open telnet socket to $liquidsoapHost:$liquidsoapPort") if $isVerboseEnabled3;
        $socket = IO::Socket::INET->new(
            PeerAddr => $liquidsoapHost,
            PeerPort => $liquidsoapPort,
            Proto    => "tcp",
            Type     => SOCK_STREAM,
            Timeout  => $socketTimeout,
        );
        info("opened $socket") if defined $socket && $isVerboseEnabled3;
    }
    my $message = "liquidsoap is not available! "
        . "Cannot connect to telnet $liquidsoapHost:$liquidsoapPort";
    unless (defined $socket) {
        $status->{liquidsoap}->{cli} = $message;
        error($message);
        return undef;
    }
    if (defined $status->{liquidsoap}  && defined $status->{liquidsoap}->{cli}) {
        $status->{liquidsoap}->{cli} = '' if $status->{liquidsoap}->{cli} eq $message;
    }
    return $socket;
}

sub writeSocket {
    my ($socket, $command) = @_;
    my $select = IO::Select->new();
    $select->add($socket);
    my $stopTime = time() + $socketTimeout;
    my $data     = $command . "\n";
    while (length($data) > 0) {
        for my $handle ($select->can_write($socketTimeout)) {
            info("syswrite '$data'") if $isVerboseEnabled3;
            my $rc = syswrite $handle, $data;
            if ($rc > 0) {
                info("syswrite ok, length=$rc") if $isVerboseEnabled3;
                substr($data, 0, $rc) = '';
            } elsif ($! == EWOULDBLOCK) {
                info("syswrite would block") if $isVerboseEnabled3;
            } else {
                warning("syswrite error for command=$command");
                closeSocket($socket);
                return 0;
            }
        }
        if (time() > $stopTime) {
            warning("syswrite timeout for command=$command");
            closeSocket($socket);
            return 0;
        }
    }
    return 1;
}

sub readSocket {
    my $socket = $_[0];
    my $lines  = '';
    my $stopTime = time() + $socketTimeout;
    my $select   = IO::Select->new();
    $select->add($socket);
    while (1) {
        for my $handle ($select->can_read($socketTimeout)) {
            my $data = '';
            my $rc   = sysread $handle, $data, 60000;
            if (defined $rc) {
                if ($rc > 0) {
                    info("sysread ok: $data") if $isVerboseEnabled3;
                    $lines .= $data;
                } else {
                    info("sysread end of line") if $isVerboseEnabled3;
                    closeSocket($socket);
                }
            } elsif ($! == EWOULDBLOCK) {
                info("sysread would block") if $isVerboseEnabled3;
            } else {
                warning("sysread error");
                closeSocket($socket);
            }
        }
        last if $lines =~ /\r\nEND\r\n/;
        if (time() > $stopTime) {
            warning("sysread timeout");
            closeSocket($socket);
            last;
        }
    }
    info("result:'$lines'") if $isVerboseEnabled3;
    return $lines;
}

sub parseLiquidsoapResponse {
    my ($command, $lines) = @_;
    my $result = '';
    if (defined $lines) {
        for my $line (split(/\r\n/, $lines)) {
            next unless defined $line;
            next                 if $line eq $command;
            last                 if $line =~ /^END/;
            info("line:" . $line) if $isVerboseEnabled3;
            $result .= $line . "\n";
        }
    }
    $result =~ s/\s+$//;
    info("result:'$result'") if $isVerboseEnabled3;
    return $result;
}

sub liquidsoapTelnetCmd {
    my ($socket, $command) = @_;
    info("send command '$command' to $liquidsoapHost:$liquidsoapPort") if $isVerboseEnabled2;
    $socket = openTelnetSocket($socket);
    return '' unless defined $socket;
    writeSocket($socket, $command) or return '';
    my $lines  = readSocket($socket);
    my $result = parseLiquidsoapResponse($command, $lines);
    return $result;
}

sub writeStatusFile {
    my $filename = shift;
    info("") if $isVerboseEnabled2;
    for my $key (keys %{$status->{warnings}}) {
        my $time = $status->{warnings}->{$key};
        delete $status->{warnings}->{$key}
            if (defined $time) && $time < $lastStatusUpdate;
    }
    my $entry = {
        schedule   => $plan,
        current    => clone($event),
        next       => clone($next),
        liquidsoap => $status->{liquidsoap},
        stations   => $stations,
        warnings   => $status->{warnings}
    };
    warning("status file '$filename' does not exist!") unless -w $filename;
    return unless checkWritePermissions('status file', $filename);
    Storable::nstore($entry, $filename);
    $lastStatusUpdate = time();
    setFilePermissions($filename);
}

sub printStatus {
    return unless $isVerboseEnabled0;
    my $line = $state;
    $line .= " " . formatTime($timeTillSwitch) if defined $timeTillSwitch;
    $line .= ", " . $next->{name} . ' at ' . $next->{date} if defined $next->{date};
    info($line);
}

sub formatTime {
    my $time = shift;
    $time = -$time if $time < 0;
    my $s = '';
    if ($time > $day) {
        my $days = int($time / $day);
        $time -= $days * $day;
        $s .= $days . " days, ";
    }
    if ($time > $hour) {
        my $hours = int($time / $hour);
        $time -= $hours * $hour;
        $s .= $hours . " hours, ";
    }
    if ($time > $min) {
        my $mins = int($time / $min);
        $time -= $mins * $min;
        $s .= $mins . " mins, ";
    }
    $s .= sprintf('%.02f', $time) . " secs";
    return $s;
}

sub clearErrorStatus() {
    $status->{warnings}                        = {};
    $status->{liquidsoap}->{station1}->{error} = '';
    $status->{liquidsoap}->{station2}->{error} = '';
}

$SIG{INT} = sub {
    info("received INT signal, cleanup and quit") if $isVerboseEnabled0;
    closeSocket($telnetSocket);
    exit;
};
$SIG{TERM} = sub {
    info("received TERM signal, cleanup and quit") if $isVerboseEnabled0;
    closeSocket($telnetSocket);
    exit;
};
$SIG{HUP} = sub {
    info("received HUP signal, reload configuration (toBeDone, workaround=quit") if $isVerboseEnabled0;
    closeSocket($telnetSocket);
    exit;
};
$SIG{PIPE} = sub {
    info("connection lost to liquidsoap (broken pipe), close sockets") if $isVerboseEnabled0;
    closeSocket($telnetSocket);
};

END {
    closeSocket($telnetSocket);
}

while (1) {
    updateTime();
    $cycleStart = $unixDate;
    info("$unixDate - $previousCheck = " . ($unixDate - $previousCheck) . " > $reload ?") if $isVerboseEnabled3;
    $state = 'check' if $unixDate - $previousCheck > $reload;
    checkRestartLiquidsoap();
    syncSchedule();
    getEvents() if $state eq 'check';
    checkRunning($event);
    printStatus();
    checkStreamSwitch($timeTillSwitch);
    eval {measureLevels($status);};
    writeStatusFile($schedulerStatusFile) if $schedulerStatusFile ne '';
    $status->{liquidsoap}->{cli} = '';
    checkSleep($state);
}
