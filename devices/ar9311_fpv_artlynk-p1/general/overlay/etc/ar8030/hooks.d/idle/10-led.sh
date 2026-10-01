#!/bin/sh
#
# Status LED on "idle": fired once when ar8030-lifecycled settles without
# a link, and again after a failed bind. Tells the two cases apart by the
# ".paired" marker lifecycled writes next to the active config:
#   - never bound: solid red, waiting for the bind button;
#   - bound before, no link right now: slow green blink, "searching".
# The config name comes from /etc/default/ar8030-transport-tx, like
# S65ar8030-transport-tx's own.
AR8030_CFG_NAME=ar8030/ar8030.json
[ -r /etc/default/ar8030-transport-tx ] && . /etc/default/ar8030-transport-tx

if [ -f "/lib/firmware/$AR8030_CFG_NAME.paired" ]; then
	exec /usr/share/openipc/p1-led.sh blink 0.5
fi
exec /usr/share/openipc/p1-led.sh red
