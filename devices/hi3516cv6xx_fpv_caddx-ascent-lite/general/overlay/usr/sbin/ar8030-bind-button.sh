#!/bin/sh
#
# Polls the Caddx Ascent Lite's physical bind button and calls ar8030-pair
# on press-release, so binding to a new ground unit doesn't need an SSH
# session. gpio0 confirmed by hand on real hardware: idle=1, pressed=0
# (general/overlay/usr/share/openipc/muxes.sh exports it as an input at
# boot; no devicetree gpio-keys node exists for it, and this board has no
# libgpiod/gpiomon in its image, so a plain sysfs poll loop is what's
# actually available -- see ar8030-transport/README.md for the fuller
# reasoning). Run as a background daemon from S66ar8030-bind-button.
#
# A fresh pair writes the on-disk config + the ".paired" marker
# S65ar8030-transport-tx's own autoreconnect() loop gates on (see
# 0007-bb_pair-auto-reconnect-on-boot.patch) -- but that gate is only
# checked once, at S65's own start() time. If this is the unit's
# first-ever pair (marker didn't exist at boot), or the button is used to
# switch to a different peer than the one already connected, S65 has to
# be told to notice.
#
# S65's own "restart" (rmmod+modprobe the host driver, restart ar8030d)
# is NOT enough: confirmed live -- it left ar8030d's own SDIO worker
# desynced from the chip's still-running RTOS session ("sdio_write err
# = -1" then a forced device detach in ar8030d's log), so
# ar8030-linkctl reported "no AR8030 device known to the daemon" until
# a real "reset" (same stop/start, but also pulses the chip's own
# hardware reset line via the devmem pokes at 0x11097020 first) was run
# by hand. Use "reset", not "restart", here for exactly that reason.
# This necessarily interrupts any video stream already in progress --
# expected for a physical bind button.

GPIO_VALUE=/sys/class/gpio/gpio0/value
CFG=/lib/firmware/ar8030/ar8030.json
POLL_MS=100
DEBOUNCE_MS=50
LOCKOUT_S=5

read_gpio() {
	cat "$GPIO_VALUE" 2>/dev/null
}

while true; do
	usleep $((POLL_MS * 1000))
	[ "$(read_gpio)" = "0" ] || continue

	# Debounce: confirm it's still pressed after a short settle, not switch
	# bounce or a transient glitch.
	usleep $((DEBOUNCE_MS * 1000))
	[ "$(read_gpio)" = "0" ] || continue

	logger -t ar8030-bind-button "button pressed, waiting for release"
	while [ "$(read_gpio)" = "0" ]; do
		usleep $((POLL_MS * 1000))
	done

	logger -t ar8030-bind-button "button released, pairing"
	pair_out=$(ar8030-pair -c "$CFG" 2>&1)
	pair_rc=$?
	echo "$pair_out" | logger -t ar8030-bind-button
	if [ "$pair_rc" -eq 0 ]; then
		logger -t ar8030-bind-button "pair succeeded, resetting ar8030-transport-tx"
		/etc/init.d/S65ar8030-transport-tx reset
	else
		logger -t ar8030-bind-button "pair failed (rc=$pair_rc), leaving current link alone"
	fi

	# Ignore further presses for a bit rather than re-triggering on any
	# residual bounce right after we already acted.
	sleep "$LOCKOUT_S"
done
