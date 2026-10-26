#!/bin/sh
#
# The P1's front end on every link (see /usr/sbin/p1-fem): covers a lifecycled
# start that links at once (no "idle") and a chip that reset under a running
# lifecycled. Already set up, it changes nothing.
exec /usr/sbin/p1-fem
