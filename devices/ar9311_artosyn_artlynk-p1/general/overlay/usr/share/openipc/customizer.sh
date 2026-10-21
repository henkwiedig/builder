#!/bin/sh
#
# BetaFPV P1 SKY (Artosyn AR9311) -- first-boot settings
#

#
# Set custom upgrade url
#
fw_setenv upgrade 'https://github.com/OpenIPC/builder/releases/download/latest/ar9311_artosyn_artlynk-p1-nand.tgz'

#
# No wlandev: the downlink is the AR8030 baseband on SDIO, driven by
# ar8030-transport-tx's artosyn_drv.ko + ar8030d from
# /etc/init.d/S65ar8030-transport-tx, not a WiFi dongle.
#
# No majestic/waybeam: the NT99235 camera and the Wave521C encoder are V4L2
# devices on this kernel; there is no OpenIPC encoder app for them yet.
#

exit 0
