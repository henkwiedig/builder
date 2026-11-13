#!/bin/sh
#
# Brings up ar_net0 (the AR8030's native net_device, see
# /etc/network/interfaces.d/ar_net0) now that a real link is up: ifup
# opens the chip-side bb socket. Nothing brings it up before there is an
# actual link to carry it -- this hook is what calls ifup. ifup is
# idempotent (a no-op if already up), so safe even if this fires more
# than once.
#
# ifupdown's state can outlive the interface: S65 stop's rmmod unregisters
# ar_net0 without an ifdown (lifecycled is already gone, so no dropped hook
# runs), and after the next start the plain ifup only says "already
# configured" and leaves the new ar_net0 down, with no address. An ar_net0
# without its IPv4 address gets that stale state cleared first.
#
# Best-effort: a no-op if the driver didn't register the interface
# (artosyn_drv loaded with native_net=0).
[ -e /sys/class/net/ar_net0 ] || exit 0
ip -o -4 addr show ar_net0 | grep -q inet || ifdown -f ar_net0 >/dev/null 2>&1
ifup ar_net0 2>&1 | logger -t ar8030-lifecycled-hook
