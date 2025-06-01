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
use Time::HiRes     qw(time sleep);
use Scalar::Util    qw(looks_like_number);
use Storable        qw();
use POSIX;
STDOUT->autoflush;

my $now                       = 0;
my $checked_at                = 0;
my $time_until_switch         = 0;
my $previousPlot              = 0;
my $previous                  = {};
my $next                      = {};
my $event                     = {};
my $date                      = '';
my $plan                      = [];
my $schedule_file_modified_at = 0;
my $status                    = {};
my $cycle_start               = time();
my $stream_switch_offset      = 0;

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

package time {
    use warnings;
    use strict;

    sub dt_to_epoch {
        my ($datetime) = @_;
        $datetime //= '';
        if ($datetime =~ /(\d\d\d\d)\-(\d+)\-(\d+)[T\s](\d+)\:(\d+)(\:(\d+))?/)
        {
            my $year   = $1;
            my $month  = $2 - 1;
            my $day    = $3;
            my $hour   = $4;
            my $minute = $5;
            my $second = $7 || '00';
            return Time::Local::timelocal($second, $minute, $hour, $day,
                $month, $year);
        }
        warn("no valid date time found! ($datetime) at" . log::subroutine(2));
        return -1;
    }

    sub format {
        my $time  = abs shift;
        my $min   = 60;
        my $hour  = 60 * $min;
        my $day   = 24 * $hour;
        my @units = ([$day, "days"], [$hour, "hours"], [$min, "mins"]);
        my @parts;
        for (@units) {
            my ($unit, $label) = @$_;
            push @parts, int($time / $unit) . " $label" if $time >= $unit;
            $time %= $unit;
        }
        push @parts, sprintf('%.02f secs', $time);
        return join(', ', @parts);
    }

    sub epoch_to_dt {
        my @time = localtime($_[0] // time);
        return sprintf '%04d-%02d-%02d %02d:%02d:%02d',
          $time[5] + 1900, $time[4] + 1, $time[3], $time[2], $time[1], $time[0];
    }

};    #end package time

package log {
    use warnings;
    use strict;
    my $verbose0 = 0;
    my $verbose1 = 0;
    my $verbose2 = 0;
    my $verbose3 = 0;

    sub subroutine {
        my ($level) = @_;
        my ($package, $filename, $line, $subroutine) = caller($level // 2);
        return undef unless defined $subroutine;
        $subroutine =~ s/main\:\://;
        return "$subroutine()";
    }

    sub info {
        my ($message) = @_;
        my $caller = subroutine();
        $message =~ s/([\n\r])\\/\\$1/g;
        print join("\t",
            time::epoch_to_dt(), $$, "INFO",
            ($caller ? sprintf("\t%-16s", $caller) : ()), "$message\n");
        return;
    }

    sub warning {
        my ($message, $onlyToFile) = @_;
        $message =~ s/([\n\r])\\/\\$1/g;
        print join("\t", time::epoch_to_dt(), $$, "WARN", "$message\n");
        $status->{warnings}->{$message} = time unless defined $onlyToFile;
        return;
    }

    sub error {
        my ($message) = @_;
        print join("\t", time::epoch_to_dt(), $$, "ERROR", "$message\n");
        $status->{warnings}->{$message} = time;
        return;
    }

    sub fatal {
        my ($message) = @_;
        print STDERR join("\t",
            time::epoch_to_dt(), $$, "ERROR", subroutine(), "$message\n");
        $status->{warnings}->{$message} = time;
        exit;
    }
}

package file {

    sub last_modified {
        return (stat(shift))[9];
    }

    sub set_writable {
        my $path    = shift;
        my $userId  = getpwnam('audiostream');
        my $groupId = getgrnam('www-data');
        return unless defined $userId && defined $groupId;
        chown($userId, $groupId, $path);
    }

    sub check_permissions {
        my ($label, $filename) = @_;
        return log::warning(
            "cannot write $label to '$filename'! Please check file permissions!"
        ) if -e $filename && !-w $filename;
        my $dir = File::Basename::dirname($filename);
        return log::warning(
            "cannot write $label to dir $dir! Please check file permissions!")
          unless -w $dir;
        return 1;
    }

    sub save {
        my ($label, $filename, $content) = @_;
        open my $fh, ">", $filename
          or log::fatal(
"cannot write $label to file '$filename'! Please check file permissions!"
          );
        print $fh $content;
        close $fh;
        log::info("saved $label to '$filename'") if $log::verbose0;
    }

    sub load {
        my ($filename) = @_;
        open my $file, "<", $filename
          or log::fatal("cannot read '$filename'!, $!");
        local $/;
        my $content = <$file>;
        close $file or log::fatal("close error '$filename'");
        return $content;
    }
}    # end package file

package liquidsoap {
    use warnings;
    use strict;
    use IO::Socket::UNIX qw(SOCK_STREAM);
    use IO::Socket::INET qw(SOCK_STREAM);
    use IO::Select;
    use POSIX;

    our $host;
    our $port;
    our $triggerRestartFile;

    my $socket;
    my $socket_timeout = 1;

    sub run {
        my ($command) = @_;
        return log::warning("missing config for liquidsoap unix socket")
          unless $host;
        return log::warning("missing config for liquidsoap port") unless $port;
        my $result = socket_cmd($command) or return;
        if ($result =~ /Connection timed out/) {
            close_socket();
            log::info("retry ...") if $log::verbose1;
            $result = socket_cmd($command);
        }
        return $result;
    }

    sub restart {
        return log::info(
            "skip restart, trigger file $triggerRestartFile is not configured")
          if $triggerRestartFile eq '';
        return log::info(
            "skip restart, trigger file $triggerRestartFile does not exist")
          unless -e $triggerRestartFile;
        unlink $triggerRestartFile
          or return log::info(
            "skip restart, cannot remove trigger file $triggerRestartFile");
        log::warning("restart");
        liquidsoap::run('restart');
    }

    sub close_socket {
        return unless $socket;
        log::info("close socket $socket") if $log::verbose3;
        print $socket "exit\n" if IO::Select->new($socket)->can_write($socket_timeout);
        close $socket if defined $socket;
        $socket = undef;
    }

    sub open_socket {
        return $socket if $socket;
        log::info("open connection to liquidsoap $host:$port")
          if $log::verbose3;
        $socket = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => $port,
            Proto    => 'tcp',
            Type     => SOCK_STREAM,
            Timeout  => $socket_timeout,
        );
        unless ($socket) {
            my $msg =
              "liquidsoap is not available! Cannot connect to $host:$port";
            $status->{liquidsoap}->{cli} = $msg;
            log::error($msg);
            return;
        }
        log::info("opened $socket") if $log::verbose3;
        $status->{liquidsoap}->{cli} = ''
          if ($status->{liquidsoap}->{cli}//'') =~ /Cannot connect/;
        return $socket;
    }

    sub write_socket {
        my ($command) = @_;

        my $select   = IO::Select->new($socket);
        my $deadline = time() + $socket_timeout;
        my $data     = $command . "\n";
        while (length $data) {
            if (time() > $deadline){
                log::warning("syswrite timeout for command=$command");
                return 0;
            }
            for my $handle ($select->can_write($socket_timeout)) {
                log::info(sprintf "syswrite '%s'", $data =~ s/\n/\\n/gr)
                  if $log::verbose3;
                my $rc = syswrite($handle, $data);
                unless (defined $rc) {
                    next if $! == EWOULDBLOCK;
                    log::warning("syswrite error for command=$command");
                    close_socket();
                    return 0;
                }
                log::info("syswrite ok, length=$rc") if $log::verbose3;
                $data = substr($data, $rc);
            }
        }
        return 1;
    }

    sub read_socket {
        my $lines    = '';
        my $deadline = time() + $socket_timeout;
        my $select   = IO::Select->new($socket);
        while (time() <= $deadline) {
            for my $handle ($select->can_read($socket_timeout)) {
                my $data;
                my $rc = sysread($handle, $data, 60000);
                unless (defined $rc) {
                    next if $! == EWOULDBLOCK;
                    log::warning("sysread error");
                    close_socket();
                    return $lines;
                }
                if ($rc == 0) {
                    close_socket();
                    return $lines;
                }
                $lines .= $data;
                return $lines if $lines =~ /\r\nEND\r\n/;
            }
        }
        log::warning("sysread timeout");
        close_socket();
        log::info("result: '$lines'") if $log::verbose3;
        return $lines;
    }

    sub socket_cmd {
        my ($command) = @_;
        log::info("send command '$command' to $host:$port") if $log::verbose2;
        $socket = open_socket() or return '';
        write_socket($command)  or return;
        my $lines  = read_socket() or return;
        my @lines  = split(/\r\n/, $lines);
        my $result = '';
        for my $line (@lines) {
            next if $line eq $command;
            last if $line =~ /^END/;
            $result .= "$line\n";
        }
        $result =~ s/\s+$//;
        log::info("result: '$result'") if $log::verbose3;
        return $result;
    }
}    # end package liquidsoap

sub daemonize {
    my ($log) = @_;
    file::save('log file', $log, '') unless -e $log;
    file::set_writable($log);
    open STDOUT, ">>", $log or die "Can't write to '$log': $!";
    open STDERR, ">>", $log or die "Can't write to '$log': $!";
    umask 0;
    file::save('pid file', '/var/run/stream-schedule/stream-schedule.pid', $$);
}

sub update_time {
    $now               = time();
    $date              = time::epoch_to_dt($now);
    $time_until_switch = $next->{epoch} - $now - $stream_switch_offset
      if defined $next->{epoch};
}

sub read_config {
    my ($filename) = @_;
    log::fatal("config file '$filename' does not exist") unless -e $filename;
    log::fatal("cannot read config '$filename'")         unless -r $filename;
    my $configuration = new Config::General($filename);
    my $config        = $configuration->{DefaultConfig};
    my $stations      = $config->{stations}->{station};
    $stations = [$stations] if ref($stations) eq 'HASH';
    log::fatal('No stations configured!') unless defined $stations;
    log::fatal('configured stations should be a list!')
      unless ref($stations) eq 'ARRAY';
    log::fatal('There should be configured at least one station!')
      unless @$stations;
    my $manditoryAttributes = ['alias', 'url1', 'url2'];
    for my $station (@$stations) {
        $station->{$_} //= '' for qw(alias url1 url2);
    }
    $config->{stations} = $stations;
    return $config;
}

sub read_stations {
    my ($stations, $verbose) = @_;
    log::info("") if $log::verbose2;
    my $results = {};
    for my $station (@$stations) {
        my $id = $station->{id};
        $results->{lc($id)} = $station;
        for my $name (split(/\s*,\s*/, $station->{alias})) {
            $results->{lc($name)} = $station;
        }
    }
    return $results;
}

update_time();
my $params = {
    config   => '',
    schedule => '',
};
my $verbose;
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
my $socket = undef;
my $minRms = -36;
$minRms *= -1 if $minRms < 0;
# get config file
if ($params->{config} eq '') {
    my $configFile = '/etc/stream-schedule/stream-schedule.conf';
    $params->{config} = $configFile if -e $configFile;
}
# read config
my $config = read_config($params->{config});
$verbose //= ($config->{scheduler}->{verbose} // 1);
$log::verbose0 = $verbose >= 0;
$log::verbose1 = $verbose >= 1;
$log::verbose2 = $verbose >= 2;
$log::verbose3 = $verbose >= 3;

my $logFile = $config->{scheduler}->{log};
daemonize($logFile) if defined $params->{daemon};
# liquidsoap socket config
$liquidsoap::host = $config->{liquidsoap}->{host};
$liquidsoap::port = $config->{liquidsoap}->{port};
# touch this file to trigger restart
$liquidsoap::triggerRestartFile =
  $config->{scheduler}->{triggerRestartFile} || '';

my $sync_cmd = $config->{scheduler}->{syncCommand};
# current schedule
my $schedule_file = $config->{scheduler}->{scheduleFile};
# touch this file to trigger update
my $trigger_sync_file = $config->{scheduler}->{triggerSyncFile};
# write current status to file
my $status_file = $config->{scheduler}->{statusFile};
# sleep interval in seconds
my $long_sleep = $config->{scheduler}->{sleep};
# switch offset in seconds to network, buffer
$stream_switch_offset = $config->{scheduler}->{switchOffset};
# reload schedule interval in seconds
my $reload = $config->{scheduler}->{reload};
my $state  = 'check';
log::info("INIT") if $log::verbose0;
# plot interval in seconds
my $plot_interval = 1 * 60;
# write rms status in seconds
my $rms_interval         = 60;
my $max_restart_interval = 1 * 60;
my $max_sync_interval    = 3 * 60;
my $previous_sync        = time();
if (-e $schedule_file) {
    $previous_sync = file::last_modified($schedule_file);
} else {
    $previous_sync -= $max_sync_interval;
}
my $last_status_update = time();
my $stations           = read_stations($config->{stations}, $verbose);

# read audio levels from log file, then update status and plot
# format: peak in L, peak in R, rms in L, rms in R, peak out L, peak out R, rms out L, rms out R

sub measure_levels {
    my ($status) = @_;
    my $plotDir = $config->{scheduler}->{plotDir}
      or log::warn("schedulee::plotDir not configured");
    return unless -d $plotDir;
    log::info("") if $log::verbose2;

    my $date     = strftime("%F", localtime($now));
    my $filename = $plotDir . "monitor-$date.log";
    my $line     = qx{tail -1 $filename};
    (
        my $datetime,
        $status->{'measure-in'}->{peakLeft},
        $status->{'measure-in'}->{peakRight},
        $status->{'measure-in'}->{rmsLeft},
        $status->{'measure-in'}->{rmsRight},
        $status->{'measure-out'}->{peakLeft},
        $status->{'measure-out'}->{peakRight},
        $status->{'measure-out'}->{rmsLeft},
        $status->{'measure-out'}->{rmsRight}
    ) = split /\t/, $line;
    log::info("RMS values measured") if $log::verbose2;

    $status->{warnings}->{"there is silence"} = time()
      if ($status->{'measure-in'}->{rmsLeft}//0) < -60
      && ($status->{'measure-in'}->{rmsRight}//0) < -60;

    $previousPlot = $now;
    plot($filename, $date);
}

sub build_plot_data {
    my ($rms_file) = @_;
    log::info("parse $rms_file");
    open my $file, "< ", $rms_file
      or return warn("cannot read from $rms_file, $!");
    my @lines = ();
    while (<$file>) {
        if ($_ =~ /^#/) {
            push @lines, $_;
            next;
        }
        my @vals = split /\t/, $_;
        if (scalar @vals >= 5) {
            push @lines, join(
                "\t",
                $vals[0],
                map {
                    $_ <= -100
                      ? '-'
                      : $minRms -
                      abs(($_ < -$minRms ? -$minRms : $_))
                } @vals[1 .. 8]
            );
        }
    }
    close $file;
    return join("\n", @lines) . "\n";
}

sub plot {
    my ($filename, $date) = @_;

    my $plotDir = $config->{scheduler}->{plotDir};
    my $gnuplot = $config->{scheduler}->{gnuplot};

    return log::warning("plotDir not found")        unless -d $plotDir;
    return log::warning("gnuplot binary not found") unless -e $gnuplot;
    return log::warning("skip plot, $filename does not exist")
      unless -e $filename;
    log::info("");

    my $base      = File::Basename::basename($filename);
    my $data_file = "/tmp/$base.plot";
    file::save('data file', $data_file, build_plot_data($filename));
    return log::warning("skip plot, data file missing") unless -e $data_file;

    $filename = $data_file;
    my @ytics = ();
    for (my $i = 0; $i <= $minRms; $i += 8) {
        unshift @ytics, '"-' . ($minRms - abs(-$i)) . '" ' . (-$i);
        push @ytics, '"-' . ($minRms - abs($i)) . '" ' . ($i);
    }
    my $ytics = join(", ", @ytics);

    #my $style = "smooth bezier w filledcurves y1=0";
    my $style = "w filledcurves y1=0";
    my $gray       = q{"#50999999"};
    #my $peakLeft   = q{"#50ffaaaa"};
    #my $peakRight  = q{"#50aaffaa"};
    #my $rmsLeft    = q{"#50ff0000"};
    #my $rmsRight   = q{"#5000ff00"};
    my $peakLeft   = q{"#86A7FC"};
    my $peakRight  = q{"#FFDD95"};
    my $rmsLeft    = q{"#3468C0"};
    my $rmsRight   = q{"#FF9843"};

    my $temp_image = "/tmp/monitor.svg";
    log::info("gnuplot save to $temp_image");
    my $plot = <<"PLOT";
set terminal svg size 2000,600 linewidth 1 background rgb 'black'
set output "| cat > $temp_image"
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
    $minRms-20 notitle lc rgb $gray, \\
   -$minRms+20 notitle lc rgb $gray, \\
    $minRms-1  notitle lc rgb $gray, \\
   -$minRms+1  notitle lc rgb $gray, \\
   "$filename" using 1:( \$4) notitle lc rgb $peakLeft $style, \\
   "$filename" using 1:(-\$5) notitle lc rgb $peakRight $style, \\
   "$filename" using 1:( \$2) notitle lc rgb $rmsLeft $style, \\
   "$filename" using 1:(-\$3) notitle lc rgb $rmsRight $style

set ylabel "Gain in dB" tc rgb "#f0f0f0"
set yrange [-24:24]
set ytics border mirror norotate autofreq
plot \\
    0 notitle lc rgb $gray, \\
   "$filename" using 1:(0+(\$6)-(\$2)) notitle lc rgb $rmsLeft $style, \\
   "$filename" using 1:(0+(\$7)-(\$3)) notitle lc rgb $rmsRight $style

set ylabel "Output in dB" tc rgb "#f0f0f0"
set ytics ($ytics)
set yrange [-$minRms:$minRms]
plot \\
    $minRms-20 notitle lc rgb $gray, \\
   -$minRms+20 notitle lc rgb $gray, \\
    $minRms-1  notitle lc rgb $gray, \\
   -$minRms+1  notitle lc rgb $gray, \\
   "$filename" using 1:( \$8) notitle lc rgb $peakLeft $style, \\
   "$filename" using 1:(-\$9) notitle lc rgb $peakRight $style, \\
   "$filename" using 1:( \$6) notitle lc rgb $rmsLeft $style, \\
   "$filename" using 1:(-\$7) notitle lc rgb $rmsRight $style
PLOT

    # w filledcurves y1=0

    open my $gp, "|-", $gnuplot
      or return log::warning("Cannot open pipe to gnuplot");
    print $gp $plot;
    close $gp;
    my $exit_code = $? >> 8;
    return log::warning("plot finished with exit code $exit_code") if $?;

    my $image = "$plotDir/monitor-$date.svg";
    File::Copy::copy($temp_image, $image)
      or return log::warning("cannot copy image");
    file::set_writable($image);
    log::info("plot finished successfully") if $log::verbose2;
}

sub clear_errors() {
    $status->{warnings}                        = {};
    $status->{liquidsoap}->{station1}->{error} = '';
    $status->{liquidsoap}->{station2}->{error} = '';
}

sub sync_schedule {
    my $now = time();
    if ($now - $previous_sync < $max_sync_interval) {
        log::info("skip sync, has been done shortly before at "
              . time::epoch_to_dt($previous_sync)
              . ", age:"
              . int($now - $previous_sync))
          if $log::verbose0;
        return;
    }
    # Ensure schedule file exists
    unless (-e $schedule_file) {
        file::save(' schedule file ', $schedule_file, "");
        unless (-e $schedule_file) {
            log::warning(
                "could not write $schedule_file! Please check permissions");
            return;
        }
    }
    # skip sync if trigger file is missing
    unless (-e $trigger_sync_file) {
        log::info("skip sync, trigger file $trigger_sync_file does not exist")
          if $log::verbose0;
        return;
    }
    # skip if schedule file is up to date
    my $schedule_fileAge     = file::last_modified($schedule_file)     || 0;
    my $trigger_sync_fileAge = file::last_modified($trigger_sync_file) || 0;
    if ($schedule_fileAge > $trigger_sync_fileAge) {
        log::info("skip sync, schedule file is up to date, lastModified="
              . time::epoch_to_dt($schedule_fileAge)
              . ", lastTrigger="
              . time::epoch_to_dt($trigger_sync_fileAge))
          if $log::verbose0;
        return;
    }
    log::info("execute: $sync_cmd") if $log::verbose1;
    clear_errors();
    my $result    = `$sync_cmd 2>&1`;
    my $exit_code = $? >> 8;
    log::warning("error in synchronization!") if $exit_code != 0;
    log::info($result)                        if $log::verbose0;
    $previous_sync = time();
}

sub parse_agenda_line {
    my ($plan, $line) = @_;
    if ($line =~
/^(\d{4}\-\d{2}\-\d{2})[T\s\;](\d{2}\:\d{2}(\:\d{2})?)[\s\;]+([^\;]+)[\s\;]*(\S+)?[\s\;]?/
      )
    {
        my $event_date = "$1 $2";
        my $event1     = $4 || '';
        my $event2     = $5 || '';
        log::info("event: '$event_date' - '$event1' - '$event2'")
          if $log::verbose0;
        $event_date .= ':00' if length($event_date) <= 16;
        my $event_epoch = time::dt_to_epoch($event_date);
        #remove whitespaces from start and end
        $event1 =~ s/^\s+//g;
        $event1 =~ s/[\;\s]+$//g;
        $event2 =~ s/^\s+//g;
        $event2 =~ s/[\;\s]+$//g;
        my %event_station = ();
        if (defined $stations->{lc($event1)}) {
            #predefined station
            %event_station = %{$stations->{lc($event1)}};
        } else {
            #build station from url
            %event_station = (
                title => $event1,
                url1  => $event1,
                url2  => $event2
            );
        }
        #save last event before current unix date
        if ($event_epoch < $now) {
            $plan->[0] = {
                name    => $event1,
                station => \%event_station,
                date    => $event_date,
                epoch   => $event_epoch
            };
        } else {
            push @$plan,
              {
                name    => $event1,
                station => \%event_station,
                date    => $event_date,
                epoch   => $event_epoch
              };
        }
    }
}

sub load_agenda {
    my $filename = shift;
    log::info("load '$filename'") if $log::verbose2;
    my $timestamp = file::last_modified($filename) || 0;
    log::info("lastModified "
          . time::epoch_to_dt($timestamp) . " ("
          . time::epoch_to_dt($schedule_file_modified_at) . ")")
      if $log::verbose2;
    if ($timestamp == $schedule_file_modified_at) {
        log::info("skip, file '$filename' has not changed") if $log::verbose1;
        return $plan;
    }
    $schedule_file_modified_at = $timestamp;
    log::info("reload schedule $filename") if $log::verbose0;
    my $plan = [];
    unless (-e $filename) {
        log::warning("schedule file '$filename' does not exist!");
        return $plan;
    }
    unless (-r $filename) {
        log::warning("cannot read schedule '$filename'!");
        return $plan;
    }
    for my $line (split /\n/, file::load($filename)) {
        parse_agenda_line($plan, $line);
    }
    return $plan;
}

sub station_info {
    my $station = shift;
    return join("\t", grep {defined} ($station->{url1}, $station->{url2}));
}

sub next_event {
    my ($plan) = @_;
    update_time();
    my $current = $plan->[0];
    for my $entry (@$plan) {
        if ($entry->{epoch} >= $now) {
            log::info("found next $entry->{name} at $entry->{date} "
                  . station_info($entry->{station}))
              if $log::verbose2;
            $state = 'next in';
            return ($current, $entry);
        }
        $current = $entry;
    }
    log::warning('no future entries found in schedule!');
    if (@$plan) {
        my $entry = $plan->[-1];
        log::info("found next $entry->{name} at $entry->{date} "
              . station_info($entry->{station}))
          if $log::verbose2;
        $state = 'last since';
        return ($entry, $entry);
    }
    return undef;
}

sub parse_events {
    log::info("") if $log::verbose2;
    $plan = load_agenda($schedule_file, $now);
    if (@$plan) {
        ($event, $next) = next_event($plan);
        unless (defined $event) {
            log::warning('no future event in schedule!', 'onlyToFile');
            $state = 'sleep';
        }
    } else {
        log::warning('empty schedule !');
        $state = 'sleep';
    }
}

sub set_stream {
    my ($channel, $url) = @_;
    $url ||= '';
    my $station = "station$channel";
    if (($url =~ /^https?\:\/\//)) {
        my $status = get_stream_status($station, $url) or return;
        unless ($status =~ /^connected/) {
            log::info("reconnect '$url'") if $log::verbose1;
            liquidsoap::run($station . '.url ' . $url);
            liquidsoap::run($station . '.stop');
            sleep(1);
            log::info("liquidsoap " . $station . ".url: " . $url)
              if $log::verbose1;
            liquidsoap::run($station . '.start');
            sleep(1);
            get_stream_status($station, $url);
        }
    } else {
        $status->{liquidsoap}->{$station}->{error} = '';
        if (($channel eq '1') && ($url ne '')) {
            my $msg = "invalid stream URL '$url'!";
            log::warning($msg, 'onlyToFile');
            $status->{liquidsoap}->{$station}->{error} = "log::warning(: $msg";
        }
        log::info("liquidsoap " . $station . ".stop") if $log::verbose0;
        liquidsoap::run($station . '.url http://127.0.0.1/invalidStreamUrl')
          or return;
        liquidsoap::run($station . '.stop');
        sleep(1);
        get_stream_status($station, $url);
    }
}

sub play_station {
    my ($event) = @_;
    log::info(sprintf("play '%s'", $event->{name} // '')) if $log::verbose2;
    set_stream(1, $event->{station}->{'url1'});
    set_stream(2, $event->{station}->{'url2'});
    update_time();
}

sub check_running {
    my ($entry) = @_;
    log::info("") if $log::verbose2;
    update_time();
    if (defined $entry->{date} && $entry->{date} lt $date) {
        log::info("running '$entry->{name}' since $entry->{date}")
          if $log::verbose2;
        $entry->{epoch} = time::dt_to_epoch($entry->{date});
        play_station($entry);
    }
    $checked_at = $now;
}

sub switch_station {
    my $time_until_switch = shift;
    log::info("") if $log::verbose2;
    if ($time_until_switch <= 0) {
        play_station($next);
        my $sleep = $stream_switch_offset + 1;
        log::info("sleep $sleep secs (offset)") if $log::verbose1;
        sleep($sleep);
        ($event, $next) = next_event($plan);
    }
}

sub sleeep {
    my $state          = shift;
    my $cycle_duration = time() - $cycle_start;
    my $sleep          = 30 - $cycle_duration;
    $sleep = 0 if $sleep < 0;
    update_time();
    if ($state eq 'sleep') {
        log::info(sprintf('sleep %0.2f seconds', $sleep)) if $log::verbose1;
        sleep($sleep);
    } elsif ($time_until_switch < 0) {
        log::info(sprintf('sleep %0.2f seconds', $sleep)) if $log::verbose1;
        sleep($sleep);
    } elsif ($time_until_switch > 50) {
        log::info(sprintf('sleep %0.2f seconds', $sleep)) if $log::verbose1;
        sleep($sleep);
    } elsif ($time_until_switch > 30) {
        log::info(sprintf('sleep %0.2f seconds', $sleep)) if $log::verbose1;
        sleep(10);
    } elsif (($time_until_switch > 5) && ($time_until_switch <= 30)) {
        my $sleep = $time_until_switch - 5;
        log::info(sprintf('sleep %0.2f seconds', $sleep)) if $log::verbose0;
        sleep($sleep);
    } elsif ($time_until_switch > 0) {
        my $sleep = $time_until_switch;
        log::info(sprintf('sleep %0.2f seconds', $sleep)) if $log::verbose1;
        sleep($sleep);
    } else {
        log::info("sleep 1 second") if $log::verbose1;
        sleep(1);
    }
}

sub bounce_print {
    my ($key, $message) = @_;
    return if $message ne ($previous->{$key} || '');
    log::info($message);
    $previous->{$key} = $message;
}
#station: 1,2
#url: target url to be played

sub get_stream_status {
    my ($station, $url) = @_;
    $url //= 'unknown';
    my $stream_status = liquidsoap::run($station . '.status');
    unless (defined $stream_status) {
        $status->{liquidsoap}->{$station}->{url} = 'unknown';
        return undef;
    }
    bounce_print("play-$station", "liquidsoap $station : $stream_status")
      if $log::verbose1;
    $status->{liquidsoap}->{$station}->{url} = $stream_status;
    $stream_status =~ s/^connected //g;
    $stream_status .= '/' if ($stream_status =~ /\:\d+$/) && ($url =~ /\/$/);
    if ($url eq $stream_status) {
        log::info("status $station: '$url' -> $stream_status -> connected")
          if $log::verbose2;
        return "connected";
    } else {
        log::info("status $station: '$url' -> $stream_status -> not connected")
          if $log::verbose2;
        return "not connected";
    }
}

sub write_status_file {
    my $filename = shift;
    log::info("") if $log::verbose2;
    for my $key (keys %{$status->{warnings}}) {
        my $time = $status->{warnings}->{$key};
        delete $status->{warnings}->{$key}
          if (defined $time) && $time < $last_status_update;
    }
    my $entry = {
        schedule   => $plan,
        current    => clone($event),
        next       => clone($next),
        liquidsoap => $status->{liquidsoap},
        stations   => $stations,
        warnings   => $status->{warnings}
    };
    log::warning("status file '$filename' does not exist!") unless -w $filename;
    return unless file::check_permissions('status file', $filename);
    Storable::nstore($entry, $filename);
    $last_status_update = time();
    file::set_writable($filename);
}

$SIG{INT} = sub {
    log::info("received INT signal, cleanup and quit") if $log::verbose0;
    liquidsoap::close_socket();
    exit;
};
$SIG{TERM} = sub {
    log::info("received TERM signal, cleanup and quit") if $log::verbose0;
    liquidsoap::close_socket();
    exit;
};
$SIG{HUP} = sub {
    log::info(
        "received HUP signal, reload configuration (toBeDone, workaround=quit")
      if $log::verbose0;
    liquidsoap::close_socket();
    exit;
};
$SIG{PIPE} = sub {
    log::info("connection lost to liquidsoap (broken pipe), close sockets")
      if $log::verbose0;
    liquidsoap::close_socket();
};

END {
    liquidsoap::close_socket();
    write_status_file($status_file);
}

while (1) {
    clear_errors();
    update_time();
    $cycle_start = $now;
    log::info("$now - $checked_at = " . ($now - $checked_at) . " > $reload ?")
      if $log::verbose3;
    $state = 'check' if $now - $checked_at > $reload;
    liquidsoap::restart();
    sync_schedule();
    parse_events() if $state eq 'check';
    check_running($event);
    log::info(
            $state
          . ($time_until_switch ? " " . time::format($time_until_switch) : '')
          . (
            $next->{date} ? ", " . $next->{name} . ' at ' . $next->{date} : ''
          )
    ) if $log::verbose2;
    switch_station($time_until_switch);
    measure_levels($status);
    write_status_file($status_file) if $status_file ne '';
    $status->{liquidsoap}->{cli} = '';
    sleeep($state);
}
