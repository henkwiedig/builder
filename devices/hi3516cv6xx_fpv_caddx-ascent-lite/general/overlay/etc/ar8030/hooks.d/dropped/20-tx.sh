#!/bin/sh
#
# Stops ar8030-transport-tx on a real link drop -- see
# connected/20-tx.sh for why (full symmetry with ifup/ifdown). Note this
# also fires on every drop during a flapping link, restarting the video
# process each time it reconnects rather than letting it ride the drop
# out on its own (which it can -- tx already waits internally for the
# next CONNECT); that tradeoff was a deliberate choice made with the
# person who owns this hardware, not an oversight.
#
# Best-effort: a no-op if this package isn't installed on a given board.
[ -x /etc/init.d/S65ar8030-transport-tx ] || exit 0
/etc/init.d/S65ar8030-transport-tx tx-stop
