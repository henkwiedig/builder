#!/bin/sh
#
# P1 status LED for the ar8030-lifecycled hooks (hooks.d/*/10-led.sh),
# the same scheme as the Caddx Ascent's:
#
#   p1-led.sh red          never bound: solid red, waiting for the button
#   p1-led.sh green        connected: solid green
#   p1-led.sh blink 0.5    searching for the known peer: slow green blink
#   p1-led.sh blink 0.15   bind button pressed, pairing: fast green blink
#
# Red = GPIO0, green = GPIO1, exported by muxes.sh, both ACTIVE LOW. They
# share one series resistor, so only one is ever lit. A blink is a
# detached loop (hooks are fire-and-forget); every call stops the previous
# one first.
RED=/sys/class/gpio/gpio0/value
GREEN=/sys/class/gpio/gpio1/value
BLINK_PIDFILE=/tmp/ar8030-led-blink.pid

if [ -f "$BLINK_PIDFILE" ]; then
	kill "$(cat "$BLINK_PIDFILE")" 2>/dev/null
	rm -f "$BLINK_PIDFILE"
fi

case "$1" in
red)
	echo 1 >"$GREEN" 2>/dev/null
	echo 0 >"$RED" 2>/dev/null
	;;
green)
	echo 1 >"$RED" 2>/dev/null
	echo 0 >"$GREEN" 2>/dev/null
	;;
blink)
	echo 1 >"$RED" 2>/dev/null
	(
		v=0
		while true; do
			echo "$v" >"$GREEN" 2>/dev/null
			v=$((1 - v))
			sleep "${2:-0.5}"
		done
	) </dev/null >/dev/null 2>&1 &
	echo $! >"$BLINK_PIDFILE"
	;;
*)
	echo "usage: $0 red|green|blink [interval_s]" >&2
	exit 2
	;;
esac
