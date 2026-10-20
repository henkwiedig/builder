#!/bin/sh
#
# Starts a UDP forwarder now that ar_net0 is up (30-ifup.sh runs first):
# anything sent to local port 5601 is relayed to the ground station at
# 192.168.100.2:5600 over the AR8030 link. One-way (-u) with a single
# UDP4-RECV socket -- one process for the whole stream, rather than
# UDP4-RECVFROM,fork's one child per packet. Stopped again by
# dropped/40-socat.sh. start-stop-daemon -S is a no-op if the pidfile's
# process is still alive, so safe even if this fires more than once.
#
# Best-effort: a no-op if socat isn't installed.
SOCAT=/usr/bin/socat
PIDFILE=/var/run/ar8030-socat.pid

[ -x "$SOCAT" ] || exit 0
start-stop-daemon -S -q -b -m -p "$PIDFILE" -x "$SOCAT" -- \
	-u UDP4-RECV:5601 UDP4-SENDTO:192.168.100.2:5600
