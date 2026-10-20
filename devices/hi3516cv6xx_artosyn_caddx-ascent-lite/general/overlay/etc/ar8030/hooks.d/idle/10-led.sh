#!/bin/sh
#
# Board LED on "idle" -- fired exactly once by ar8030-lifecycled, the
# first time its main loop settles without ever having observed a
# CONNECT (see lifecycle.c's ctx->idle_hook_fired latch). That single
# event covers two different real situations the daemon itself does not
# distinguish, so this script tells them apart the same way
# lc_pair_has_been_paired() does -- by checking for the on-disk ".paired"
# marker next to the chip's cfg json:
#
#   - never bound at all (no marker): solid red, doing nothing, waiting
#     for someone to press the bind button.
#   - bound before, but not connected right now (marker present -- e.g.
#     right after boot, before the chip's firmware has re-locked to its
#     configured peer on its own): slow green blink, same "searching"
#     indication as a "dropped" hook (see hooks.d/dropped/10-led.sh) --
#     from the LED's point of view this is the same situation, just
#     reached from startup instead of from a live drop.
#
# Also (re-)run directly by ar8030-lifecycled's own physical bind-button
# watcher (lifecycle_bind.c) after a failed bind attempt, since the
# passive reconnect-follower's idle_hook_fired latch means it will not
# fire this again on its own -- the marker check above is what makes
# that safe to call more than once: a failed re-bind of an already-paired
# unit correctly falls back to "searching" (green blink), not "never
# bound" (red), and if the old link is actually still up, the
# reconnect-follower's own "connected" hook corrects the LED again
# within a few seconds regardless (LC_CONNECT_CONFIRM_TICKS).
GPIO_RED=63
GPIO_GREEN=8
BLINK_PIDFILE=/tmp/ar8030-led-blink.pid
CFG=/lib/firmware/ar8030/ar8030.json

if [ -f "$BLINK_PIDFILE" ]; then
	kill "$(cat "$BLINK_PIDFILE")" 2>/dev/null
	rm -f "$BLINK_PIDFILE"
fi

if [ -f "$CFG.paired" ]; then
	# Searching: bound before, no link right now.
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
else
	# Never bound: solid red, waiting for the bind button.
	echo 0 >"/sys/class/gpio/gpio$GPIO_GREEN/value" 2>/dev/null
	echo 1 >"/sys/class/gpio/gpio$GPIO_RED/value" 2>/dev/null
fi
