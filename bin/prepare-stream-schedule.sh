#!/bin/sh

#pkill -9 -f "/usr/bin/scheduler.pl"

[ -d /var/run/stream-schedule ] || mkdir /var/run/stream-schedule
chmod 775 /var/run/stream-schedule
chown audiostream /var/run/stream-schedule

[ -f /var/run/stream-schedule/stream-schedule.pid ] && rm /var/run/stream-schedule/stream-schedule.pid

[ -d /var/log/stream-schedule/ ] || mkdir /var/log/stream-schedule/
chmod 755 /var/log/stream-schedule
chown audiostream:www-data /var/log/stream-schedule/
[ -f /var/log/stream-schedule/scheduler.log ] && chmod 664 /var/log/stream-schedule/scheduler.log
[ -f /var/log/stream-schedule/scheduler.log ] && chown audiostream:www-data /var/log/stream-schedule/scheduler.log

exit 0
