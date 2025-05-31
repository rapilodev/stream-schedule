#!/usr/bin/perl -w
use strict;
use warnings;
use File::Basename  qw(basename);
use File::Copy      qw(copy);
use Config::General qw();
use Getopt::Long    qw();
use POSIX           qw(strftime);
STDOUT->autoflush;

sub usage() {
    return qq{
$0 OPTION+
OPTIONS
--config         path to config file
--daemon         start scheduler as daemon, logging to configured log file
--help           this help
};
}

sub info {
    my $message = $_[0];
    my $time    = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime);
    print $time. "\t" . $message . "\n";
}

package file {

    sub set_writable {
        my $path    = shift;
        my $userId  = getpwnam('audiostream');
        my $groupId = getgrnam('www-data');
        return unless defined $userId && defined $groupId;
        chown($userId, $groupId, $path);
    }

    sub save {
        my ($label, $filename, $content) = @_;
        open my $fh, ">", $filename
          or die("cannot write $label to file '$filename'!");
        print $fh $content;
        close $fh;
        main::info("saved $label to '$filename'");
    }
}    # end package file

sub daemonize {
    my ($log) = @_;
    file::save('log file', $log, '') unless -e $log;
    file::set_writable($log);
    open STDOUT, ">>", $log or die "Can't write to '$log': $!";
    open STDERR, ">>", $log or die "Can't write to '$log': $!";
    umask 0;
    file::save('pid file', '/var/run/stream-schedule/stream-schedule-plot.pid',
        $$);
}

sub read_config {
    my ($filename) = @_;
    die("config file '$filename' does not exist") unless -e $filename;
    die("cannot read config '$filename'")         unless -r $filename;
    my $configuration = new Config::General($filename);
    my $config        = $configuration->{DefaultConfig};
    return $config;
}

my $params = {config => '',};
Getopt::Long::GetOptions(
    "config=s" => \$params->{config},
    "daemon"   => \$params->{daemon},
    "h|help"   => \$params->{help},
);
if (defined $params->{help}) {
    print usage;
    exit;
}

my $minRms = -36;
$minRms *= -1 if $minRms < 0;

if ($params->{config} eq '') {
    my $configFile = '/etc/stream-schedule/stream-schedule.conf';
    $params->{config} = $configFile if -e $configFile;
}
my $config = read_config($params->{config});

sub build_plot_data {
    my ($rms_file) = @_;
    info("parse $rms_file");
    open my $file, "< ", $rms_file
      or warn("cannot read from $rms_file, $!");
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

    die("plotDir not found")        unless -d $plotDir;
    die("gnuplot binary not found") unless -e $gnuplot;
    die("skip plot, $filename does not exist")
      unless -e $filename;

    my $base      = basename($filename);
    my $data_file = "/tmp/$base.plot";
    file::save('data file', $data_file, build_plot_data($filename));
    return warn("skip plot, data file missing") unless -e $data_file;

    $filename = $data_file;
    my @ytics = ();
    for (my $i = 0; $i <= $minRms; $i += 8) {
        unshift @ytics, '"-' . ($minRms - abs(-$i)) . '" ' . (-$i);
        push @ytics, '"-' . ($minRms - abs($i)) . '" ' . ($i);
    }
    my $ytics = join(", ", @ytics);

    #my $style = "smooth bezier w filledcurves y1=0";
    my $style = "w filledcurves y1=0";
    my $gray  = q{"#50999999"};
    #my $peakLeft   = q{"#50ffaaaa"};
    #my $peakRight  = q{"#50aaffaa"};
    #my $rmsLeft    = q{"#50ff0000"};
    #my $rmsRight   = q{"#5000ff00"};
    my $peakLeft  = q{"#86A7FC"};
    my $peakRight = q{"#FFDD95"};
    my $rmsLeft   = q{"#3468C0"};
    my $rmsRight  = q{"#FF9843"};

    my $temp_image = "/tmp/monitor.svg";
    info("gnuplot save to $temp_image\n");
    my $plot = <<"PLOT";
set terminal svg size 2000,600 linewidth 1 background "#ffffffff"
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

    open my $gp, "|-", $gnuplot
      or return die("Cannot open pipe to gnuplot");
    print $gp $plot;
    close $gp;
    my $exit_code = $? >> 8;
    return die("plot finished with exit code $exit_code") if $?;

    my $image = "$plotDir/monitor-$date.svg";
    copy($temp_image, $image)
      or return die("cannot copy image");
    file::set_writable($image);
    info("plot finished successfully");
}

my $plotDir = $config->{scheduler}->{plotDir}
  or die("schedulee::plotDir not configured");
while (1) {
    if (-d $plotDir) {
        my $date     = strftime("%F", localtime(time));
        my $filename = $plotDir . "monitor-$date.log";
        plot($filename, $date);
    }
    sleep 10;
}
