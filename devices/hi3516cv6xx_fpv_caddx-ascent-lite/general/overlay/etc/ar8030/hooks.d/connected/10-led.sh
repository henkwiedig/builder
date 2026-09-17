#!/bin/sh
#
# Board LED (RED=gpio63, GREEN=gpio8 -- see general/scripts/muxes.sh,
# already exported by S30customizer before ar8030-lifecycled ever runs)
# on a real CONNECT: solid green, "all ok" -- ending whichever blink
# loop (the slow "searching" one from idle/dropped, or the fast
# "binding mode" one from pairing) happened to be running.
GPIO_RED=63
GPIO_GREEN=8
BLINK_PIDFILE=/tmp/ar8030-led-blink.pid

if [ -f "$BLINK_PIDFILE" ]; then
	kill "$(cat "$BLINK_PIDFILE")" 2>/dev/null
	rm -f "$BLINK_PIDFILE"
fi

echo 0 >"/sys/class/gpio/gpio$GPIO_RED/value" 2>/dev/null
echo 1 >"/sys/class/gpio/gpio$GPIO_GREEN/value" 2>/dev/null
