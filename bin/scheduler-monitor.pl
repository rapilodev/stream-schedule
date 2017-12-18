#!/usr/bin/perl
use warnings;
use strict;
use Data::Dumper;
use POSIX;

$|=1;
my $log='/var/log/wunderbox/scheduler-monitor.log';

`touch $log` unless(-e $log);
`chown radioadmin $log`;
open STDOUT, '>>', $log;
open STDERR, '>>', $log;

my $status_file		= '/home/radioadmin/radio/scheduler/status/scheduler_status';
my $restart_timeout	= 10*60;
my $sleep		= 1*60;

my $restart_for_station = {
	piradio	=> 0,
	ansage	=> 0,
	colabo  => 0,
	frapo	=> 1,
};

my $time=time();
my $c=0;

my $outage_start=undef;
my $url1='';
my $prev_url1='';

while(1==1){
	unless(-e $log){
		`touch $log`;
		`chown radioadmin $log`;
		open STDOUT, '>>', $log;
		open STDERR, '>>', $log;
	}
	if($c>0){
#		print_info("sleep");
		sleep $sleep;
	}
	$c++;
	my $status=do $status_file;

	my $current=$status->{current};
	my $station_id=$current->{station}->{id};
	my $liquidsoap=$status->{liquidsoap};

	$prev_url1=$url1;
	$url1=$liquidsoap->{station1}->{url}||'';

	#skip on empty url
	if (defined $url1 eq''){
		print_info("could not get status");
		$outage_start=undef;
		next;
	}

	#check if url has changed
	if ($url1 ne $prev_url1){
		print_info("url has changed: '$liquidsoap->{station1}->{url}'");
		$outage_start=undef;
		next;
	}

	#no outage or outage ended
	unless($liquidsoap->{station1}->{url}=~/^polling/){
		if(defined $outage_start){
			print_info("outage end: '$liquidsoap->{station1}->{url}'");
		}
		$outage_start=undef;
		next;
	}

	#outage started
	unless(defined $outage_start){
		$outage_start=time();
		print_info("outage start: '$liquidsoap->{station1}->{url}'");
		next;
	}

	#outage ongoing
	print_info("outage for : ".(time()-$outage_start)." seconds on station '$station_id'");
	#check if station is marked for restart on error
	if ($restart_for_station->{$station_id}ne'1'){
		print_info("restart will not be triggered for this station");
		next;
	}

	#restart liquidsoap
	if (time()-$outage_start > $restart_timeout){
		print_info("restart liquidsoap: '$liquidsoap->{station1}->{url}'");
		execute('restart liquidsoap');
		$outage_start=undef;
		next;
	}
}

sub print_info{
	my $message=$_[0];
	my $time=POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime);
	print $time."\t".$message."\n";
}

sub execute{
	my $cmd=$_[0];
	print_info('EXEC: '.$cmd);
	print `$cmd`;
}

