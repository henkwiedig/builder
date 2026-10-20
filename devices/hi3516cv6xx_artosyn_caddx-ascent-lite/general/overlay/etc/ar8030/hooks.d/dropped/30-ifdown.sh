#!/bin/sh
#
# Takes ar_net0 back down on a real link drop (closes the chip-side bb
# socket) -- see connected/30-ifup.sh. ifdown is idempotent too (a no-op
# if already down).
#
# Best-effort: a no-op if the driver didn't register the interface.
[ -e /sys/class/net/ar_net0 ] || exit 0
ifdown ar_net0 2>&1 | logger -t ar8030-lifecycled-hook
