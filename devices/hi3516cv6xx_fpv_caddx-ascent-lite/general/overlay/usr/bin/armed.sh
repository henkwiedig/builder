#!/bin/sh
#
# msposd's FC arm-state hook: armed.sh 1|0|lost. msposd runs it with the
# FC's own arm flag (MSP_STATUS) on the first reply, on every change and
# every 10 s. Hands the state to ar8030-lifecycled, whose low-power mode
# (--standby-dbm) and overheat pause (--overheat-c) follow it -- see
# /etc/default/ar8030-transport-tx.
#
# "lost" (the FC stopped answering): keep the last state. After a crash
# the FC has usually reported disarmed before it went quiet; a UART glitch
# in flight keeps "armed", i.e. full power and live video.

case "$1" in
0 | 1)
	wget -q -T 2 -O /dev/null --post-data '' "http://127.0.0.1:8899/api/v1/armed?state=$1"
	;;
lost)
	logger -t armed.sh "FC stopped answering MSP_STATUS, keeping the last arm state"
	;;
esac
