#!/bin/sh
#
# Caddx Ascent (Hi3516CV610) — first-boot settings
#

#
# Set custom upgrade url
#
fw_setenv upgrade 'https://github.com/OpenIPC/builder/releases/download/latest/hi3516cv6xx_fpv_caddx-ascent-nor.tgz'

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
# Sensor: SmartSens SC850SL (module id "cv2004"), MIPI 2-lane 10-bit, 8 MP.
# Nothing to seed yet — the cv6xx osdrv only ships gc4023, os04d10, sc4336p,
# sc450ai, sc500ai, sc431hai, os02m10/sp2308, so there is no libsns_sc850sl.so
# for either encoder to bind to.
#

exit 0
