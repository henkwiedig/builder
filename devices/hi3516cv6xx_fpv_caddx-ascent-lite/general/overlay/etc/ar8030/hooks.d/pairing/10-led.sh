#!/bin/sh
#
# Board LED on "pairing": fast green blink -- "binding mode", distinct
# from the slow green "searching" blink (hooks.d/idle and
# hooks.d/dropped's own 10-led.sh) so a user standing at the board can
# tell "actively trying to bind a new peer right now" apart from
# "waiting for our already-known peer to come back". Only ever fired by
# ar8030-lifecycled's own physical bind-button watcher
# (lifecycle_bind.c, ar8030-transport/lifecycled/ -- started when this
# board's /etc/default/ar8030-transport-tx passes --bind-gpio), never
# by the passive reconnect-follower (lifecycle.c stays a passive
# follower once a unit has been paired, matching stock's own
# ar_ldy_gnd behavior). That watcher dispatches this hook and moves on
# immediately without waiting for it (fire-and-forget, same convention
# as lc_hooks_dispatch()), so the actual blinking has to keep running
# on its own after this script exits: forks a detached background
# loop, remembers its pid in BLINK_PIDFILE so the "connected"/"idle"/
# "dropped" hooks can stop it later, and returns right away.
GPIO_RED=63
GPIO_GREEN=8
BLINK_PIDFILE=/tmp/ar8030-led-blink.pid
FAST_INTERVAL=0.15

if [ -f "$BLINK_PIDFILE" ]; then
	kill "$(cat "$BLINK_PIDFILE")" 2>/dev/null
fi

echo 0 >"/sys/class/gpio/gpio$GPIO_RED/value" 2>/dev/null

(
	v=1
	while true; do
		echo "$v" >"/sys/class/gpio/gpio$GPIO_GREEN/value" 2>/dev/null
		v=$((1 - v))
		sleep "$FAST_INTERVAL"
	done
) </dev/null >/dev/null 2>&1 &
echo $! >"$BLINK_PIDFILE"
