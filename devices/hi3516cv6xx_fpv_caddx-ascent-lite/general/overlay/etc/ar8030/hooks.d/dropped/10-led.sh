#!/bin/sh
#
# Board LED on "dropped": slow green blink -- "searching", we're trying
# to find our already-known peer again. Only ever reached from
# LC_STATE_CONNECTED (see lifecycle.c), so this unit is necessarily
# paired already; no need for the ".paired" marker check
# hooks.d/idle/10-led.sh does for its own two different cases. Same slow
# (0.5s) blink rate as that "searching" case there, and deliberately
# NOT the same pattern as hooks.d/pairing/10-led.sh's fast blink -- that
# one means "actively in bind mode" (user pressed the button), a
# different situation from "waiting for our own already-known peer to
# come back".
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
