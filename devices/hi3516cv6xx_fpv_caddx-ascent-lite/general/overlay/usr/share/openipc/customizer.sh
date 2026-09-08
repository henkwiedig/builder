#!/bin/sh
#
# Caddx Ascent Lite (Hi3516CV610) — first-boot settings
#

#
# Set custom upgrade url
#
fw_setenv upgrade 'https://github.com/OpenIPC/builder/releases/download/latest/hi3516cv6xx_fpv_caddx-ascent-lite-nor.tgz'

#
# No wlandev: the downlink is the Artosyn AR8030 baseband (SDIO), driven by
# artosyn_drv.ko + ar8030d from /etc/init.d/S60ar8030, not a WiFi dongle.
#

#
# No majestic here, so no `cli -s .isp.*` seeding — the encoder is waybeam and
# its runtime config is /etc/waybeam.json (fixed path, no -c flag), shipped by
# the waybeam package and edited with json_cli. Its own S95waybeam handles the
# boot-time fixups.
#
# Sensor: OmniVision OS02K10 (vendor module id "cv2004"), MIPI 2-lane 10-bit,
# 1080p. Nothing to seed yet — waybeam's own os02k10 sensor plugin does the
# real I2C register programming; the cv6xx osdrv's own sensor list
# (gc4023, os04d10, sc4336p, sc450ai, sc500ai, sc431hai) is unrelated.
#

exit 0
