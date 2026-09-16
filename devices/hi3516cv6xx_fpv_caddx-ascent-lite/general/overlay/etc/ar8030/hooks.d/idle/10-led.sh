#!/bin/sh
#
# Board LED on "idle" (this unit has never been paired): solid red,
# ending any pairing-blink loop a prior "pairing" hook may have started
# (e.g. a re-pair attempt that failed and fell back to passive waiting
# isn't expected on this path today, but costs nothing to guard against).
GPIO_RED=63
GPIO_GREEN=8
BLINK_PIDFILE=/tmp/ar8030-led-blink.pid

if [ -f "$BLINK_PIDFILE" ]; then
	kill "$(cat "$BLINK_PIDFILE")" 2>/dev/null
	rm -f "$BLINK_PIDFILE"
fi

echo 0 >"/sys/class/gpio/gpio$GPIO_GREEN/value" 2>/dev/null
echo 1 >"/sys/class/gpio/gpio$GPIO_RED/value" 2>/dev/null
