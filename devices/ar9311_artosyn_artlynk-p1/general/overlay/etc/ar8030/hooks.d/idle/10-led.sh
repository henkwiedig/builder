#!/bin/sh
#
# Status LED on "idle": fired once when ar8030-lifecycled settles without
# a link, and again after a failed bind. Tells the two cases apart by the
# ".paired" marker lifecycled writes next to the active config:
#   - never bound: solid red, waiting for the bind button;
#   - bound before, no link right now: slow green blink, "searching".
CFG=/lib/firmware/ar8030/ar8030.json

if [ -f "$CFG.paired" ]; then
	exec /usr/share/openipc/p1-led.sh blink 0.5
fi
exec /usr/share/openipc/p1-led.sh red
