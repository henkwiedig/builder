#!/bin/sh
#
# Bind button held 5 s (ar8030-lifecycled, lifecycle_bind.c): toggle the USB
# port between RNDIS and the CADDX PC tool updater mode. See
# /usr/sbin/pctool-mode.
exec /usr/sbin/pctool-mode toggle
