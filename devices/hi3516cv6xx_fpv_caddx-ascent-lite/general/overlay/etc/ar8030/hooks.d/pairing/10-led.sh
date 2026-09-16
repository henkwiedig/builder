#!/bin/sh
#
# Board LED while pairing: blinking green. ar8030-lifecycled dispatches
# this hook and moves on immediately (fire-and-forget, SIGCHLD ignored --
# see lifecycle_hooks.c) without waiting for it, so the actual blinking
# has to keep running on its own after this script exits: forks a
# detached background loop, remembers its pid in BLINK_PIDFILE so the
# "connected"/"idle" hooks can stop it later, and returns right away.
GPIO_RED=63
GPIO_GREEN=8
BLINK_PIDFILE=/tmp/ar8030-led-blink.pid

if [ -f "$BLINK_PIDFILE" ]; then
	kill "$(cat "$BLINK_PIDFILE")" 2>/dev/null
fi

echo 0 >"/sys/class/gpio/gpio$GPIO_RED/value" 2>/dev/null

(
	v=1
	while true; do
		echo "$v" >"/sys/class/gpio/gpio$GPIO_GREEN/value" 2>/dev/null
		v=$((1 - v))
		sleep 0.5
	done
) </dev/null >/dev/null 2>&1 &
echo $! >"$BLINK_PIDFILE"
