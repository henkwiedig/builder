#!/bin/sh
#
# Drives the two status LEDs (RED=gpio63, GREEN=gpio8 -- see muxes.sh)
# to reproduce the vendor stock firmware's own indicator behavior,
# reverse-engineered from ar_ldyhs_sky's LED state machine (a 100ms-tick
# timer callback) via Ghidra -- see ar8030-transport/README.md for the
# full writeup. Reimplemented against our own link-state signals rather
# than the vendor's internal flags, since we don't have those:
#
#   connected + tx alive       -> GREEN solid              (vendor: same)
#   connected, tx not alive    -> GREEN blink, 1000ms/half  (vendor: same,
#                                  vendor's real gate is its own venc
#                                  stream-flag; "is ar8030-transport-tx's
#                                  process alive" is the closest thing we
#                                  can observe from here)
#   not connected (searching)  -> RED/GREEN alternating, 200ms/half
#                                  (vendor: same)
#
# The vendor machine also has two more states (a boot-fault pattern, and
# two flows -- gctx+0x133/+0x134 -- whose actual trigger the RE pass
# couldn't pin down) that aren't reproduced here: nothing in this
# project's own boot sequence corresponds to them, and the ambiguous
# ones are visually identical to "searching" anyway, so leaving them out
# loses nothing an operator would notice.

GPIO_RED=63
GPIO_GREEN=8
TX_PIDFILE=/tmp/ar8030/ar8030-transport-tx.pid
POLL_MS=200
SLOW_BLINK_TICKS=5 # 5 * 200ms = 1000ms per half-cycle, matching the vendor's

led() {
	echo "$2" >"/sys/class/gpio/gpio$1/value" 2>/dev/null
}

connected() {
	ar8030-linkctl status 2>/dev/null | grep -q ' CONNECT '
}

tx_alive() {
	pid=$(cat "$TX_PIDFILE" 2>/dev/null)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

tick=0
alt=0
while true; do
	if connected; then
		alt=0
		if tx_alive; then
			led "$GPIO_GREEN" 1
			led "$GPIO_RED" 0
		else
			if [ "$((tick % (SLOW_BLINK_TICKS * 2)))" -lt "$SLOW_BLINK_TICKS" ]; then
				led "$GPIO_GREEN" 1
			else
				led "$GPIO_GREEN" 0
			fi
			led "$GPIO_RED" 0
		fi
	else
		if [ "$alt" = 0 ]; then
			led "$GPIO_RED" 1
			led "$GPIO_GREEN" 0
			alt=1
		else
			led "$GPIO_RED" 0
			led "$GPIO_GREEN" 1
			alt=0
		fi
	fi
	tick=$((tick + 1))
	usleep $((POLL_MS * 1000))
done
