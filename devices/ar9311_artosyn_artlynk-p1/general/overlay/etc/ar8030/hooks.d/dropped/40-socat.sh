#!/bin/sh
#
# Stops the UDP forwarder started by connected/40-socat.sh on a real
# link drop. Idempotent -- a no-op if it isn't running.
PIDFILE=/var/run/ar8030-socat.pid

[ -f "$PIDFILE" ] || exit 0
start-stop-daemon -K -q -p "$PIDFILE"
rm -f "$PIDFILE"
