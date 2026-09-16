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
# lc_pair_has_been_paired()/ar8030-lifecycled's own re-pair path gate on
# (see dev_helper/ar8030-lifecycled/lifecycle_pair.c) -- this script
# itself doesn't need to do anything more once ar8030-pair succeeds.
#
# Used to also call `S65ar8030-transport-tx reset` here on success (a
# full module reload + hardware reset), needed under the OLD shell-
# watchdog architecture because a fresh pair could leave ar8030d's own
# SDIO worker desynced from the chip's still-running RTOS session. That
# is no longer this script's problem: ar8030-lifecycled already owns the
# chip's hardware reset (at its own startup) and is subscribed to the
# daemon's BB_EVENT_LINK_STATE the whole time it's running, so a fresh
# CONNECT from this button's own ar8030-pair call is picked up on its
# own via lifecycle.c's "observed CONNECT, following" path -- no reset
# needed, and forcing one here now would just reboot the chip right
# after a pair that already succeeded, tearing the just-established link
# back down for no reason.

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
		logger -t ar8030-bind-button "pair succeeded, ar8030-lifecycled will pick up the new link on its own"
	else
		logger -t ar8030-bind-button "pair failed (rc=$pair_rc), leaving current link alone"
	fi

	# Ignore further presses for a bit rather than re-triggering on any
	# residual bounce right after we already acted.
	sleep "$LOCKOUT_S"
done
