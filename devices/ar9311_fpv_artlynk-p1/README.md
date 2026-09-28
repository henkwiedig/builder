# ar9311_fpv_artlynk-p1 — BetaFPV P1 SKY (Artosyn PROXIMA 9311 / AR9311)

Air unit: quad Cortex-A53, 256 MiB DDR, 128 MiB SPI-NAND, AR8030 baseband on
SDIO (mmc0, reset GPIO23), NT99235 camera, dwc2 USB, no Ethernet PHY.

## What the build produces

| | |
|---|---|
| Kernel | mainline 6.18.36 + MissingLynk's open BSP ([ml-kernel](https://github.com/Missing-Lynk/ml-kernel), board `betafpv-vr04-air` = P1_SKY), applied by `general/linux/linux-ext-ml-kernel.mk`; `board/ar9311/openipc.config` adds what the OpenIPC userland needs |
| Kernel image | `uImage.ar9311`: OTRA + LZ4 legacy uImage, the only format the stock U-Boot/SPL boot (`board/ar9311/post-image.sh`) |
| Modules | ml-kernel's out-of-tree Artosyn drivers (`package/ml-kernel-modules`) + `artosyn_drv` (ar8030-transport-tx); in-tree modules pruned to ml-kernel's own set |
| Userland | the Ascent (`hi3516cv6xx_fpv_caddx-ascent-lite`) set minus everything HiSilicon-only; musl, built by Buildroot for Cortex-A53 |
| Rootfs | `rootfs.ubi` (standard OpenIPC `rootfs` + `rootfs_data` UBI, also as `firmware.bin`), `rootfs.cpio.gz` for RAM boot |
| Vendor blobs | `package/artlynk-p1-vendor-firmware` extracts them from the stock `P1_SKY_*.img` (put it in `cache/vendor-images/` or point `ARTLYNK_P1_VENDOR_IMG` at it): AR8030 firmware, Wave521C codec firmware, NT99235 ISP tuning, stock SPL/U-Boot/DDR firmware for USB boot |

## RAM boot (no flash needed)

```sh
devices/ar9311_fpv_artlynk-p1/scripts/ar9311-usbboot.py linux --root-password <pw>
```

Board in mask-ROM USB mode (`5343:0200`, e.g. with no bootable NAND),
serial console on `/dev/ttyUSB0` (1152000 baud, nothing else holding it).
The script patches the stock SPL to train DDR from a virtual flash in SRAM,
re-enters the ROM's USB loader for a second session into DDR, loads U-Boot,
kernel, initramfs and DTB, and boots them from the U-Boot prompt. How and
why: see the script's docstring. Networking: RNDIS gadget, board at
192.168.3.104.

## Status

Working (hardware-tested, RAM boot):

- boot to OpenIPC login, SSH over the USB RNDIS gadget
- AR8030 bring-up: reset via gpiolib, firmware upload, RTOS (`4152:8031`),
  `ar8030d` + `ar8030-lifecycled` with events, ioctls answered, `ar_net0`
- the P1 baseband frames every SDIO transfer with a
  `{ flags, type, len }` link trailer; `artosyn_drv link_trailer=1`
  (package/ar8030-transport-tx `0002-*.patch`, set via
  `AR8030_MODULE_ARGS` in `/etc/default/ar8030-transport-tx`)

Not working yet:

- **No RF link with an Ascent ground unit.** Stock P1 air units are DEVs
  (the goggle is the AP); this target runs the P1 as AP with the Ascent link
  settings (`p1_ascent_air.json`, generated at build time). With both units
  forced onto one common channel and each other's hardware MACs (the chips
  use their own, e.g. P1 `e51153e2`; the `mac` fields in the JSON are not
  used) no link came up. The Ascent ground logged `bb_mac_rx_proc: version
  31/27` rejections once: the P1 baseband (2026-03) may speak an older link
  protocol than the Ascent one (2026-08). The Caddx baseband image does not
  boot on the P1 radio board.
- **Pairing**: the P1 firmware has no project dispatch layer
  (`BB_SET_PRJ_DISPATCH` → -4). `ar8030-pair` falls back to the standard
  `BB_SET_PAIR_MODE` (package/ar8030 `0036-*.patch`); accepted by the chip,
  no peer found yet (see above).
- `ar8030-lifecycled` asks for 26 dBm; the P1 PA is calibrated to 22 dBm
  (`BB_SET_POWER` → -4).
- An `EIO` from `/dev/artosyn_sdio` (no TX grant within 2 s) makes `ar8030d`
  drop the device until the stack is restarted.
- `S65ar8030-transport-tx stop` leaves `ar8030-lifecycled` running.
- No encoder app: camera (NT99235 → ISP) and codec (wave5) are V4L2 devices
  on this kernel.
- NAND install not done (MissingLynk writes slot B: `kernel1`, `dtb1`,
  `userapp1` = mtd18).
