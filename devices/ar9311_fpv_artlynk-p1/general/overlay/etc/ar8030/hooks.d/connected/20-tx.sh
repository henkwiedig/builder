#!/bin/sh
#
# Starts ar8030-transport-tx (the video bridge) now that a real link is
# up. Full symmetry with the LED hook (10-led.sh) and ar_net0's own
# ifup/ifdown hooks (30-ifup.sh/30-ifdown.sh): nothing runs the video
# process at all while there is no link for it to carry. tx_start_action
# is idempotent -- safe even if this fires more than once in a row (e.g.
# a warm restart that observes a link already up).
#
# Best-effort: a no-op if this package isn't installed on a given board.
[ -x /etc/init.d/S65ar8030-transport-tx ] || exit 0
/etc/init.d/S65ar8030-transport-tx tx-start
