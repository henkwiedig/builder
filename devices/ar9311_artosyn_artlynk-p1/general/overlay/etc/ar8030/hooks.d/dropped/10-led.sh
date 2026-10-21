#!/bin/sh
#
# Status LED on "dropped": slow green blink, searching for the known peer.
# Only reached from a connected state, so the unit is necessarily bound.
exec /usr/share/openipc/p1-led.sh blink 0.5
