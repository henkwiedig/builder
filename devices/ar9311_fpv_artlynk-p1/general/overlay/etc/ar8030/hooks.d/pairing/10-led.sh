#!/bin/sh
#
# Status LED on "pairing" (bind button pressed): fast green blink, distinct
# from the slow "searching" one so it is clear the unit is in bind mode.
exec /usr/share/openipc/p1-led.sh blink 0.15
