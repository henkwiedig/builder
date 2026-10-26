#!/bin/sh
#
# The P1's front end after a chip start (see /usr/sbin/p1-fem). "idle" fires
# when lifecycled starts without a link; when the chip links at once,
# connected/05-fem.sh does the same instead.
exec /usr/sbin/p1-fem
