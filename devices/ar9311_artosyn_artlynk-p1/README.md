# ar9311_artosyn_artlynk-p1 — BetaFPV P1 SKY (Artosyn PROXIMA 9311 / AR9311)

Air unit: quad Cortex-A53, 256 MiB DDR, 128 MiB SPI-NAND, AR8030 baseband on
SDIO (mmc0, reset GPIO23), NT99235 camera, dwc2 USB, no Ethernet PHY.

## What the build produces

| | |
|---|---|
| Kernel | mainline 6.18.36 + MissingLynk's open BSP ([ml-kernel](https://github.com/Missing-Lynk/ml-kernel), board `betafpv-vr04-air` = P1_SKY), applied by `general/linux/linux-ext-ml-kernel.mk`; `board/ar9311/openipc.config` adds what the OpenIPC userland needs |
| Kernel image | `uImage.ar9311`: OTRA + LZ4 legacy uImage, the only format the stock U-Boot/SPL boot (`board/ar9311/post-image.sh`) |
| Modules | ml-kernel's out-of-tree Artosyn drivers (`package/ml-kernel-modules`) + `artosyn_drv` (ar8030-transport-tx); in-tree modules pruned to ml-kernel's own set |
| Userland | the Ascent (`hi3516cv6xx_artosyn_caddx-ascent-lite`) set minus everything HiSilicon-only; musl, built by Buildroot for Cortex-A53 |
| Rootfs | `rootfs.ubi` (standard OpenIPC `rootfs` + `rootfs_data` UBI, also as `firmware.bin`), `rootfs.cpio.gz` for RAM boot |
| AR8030 firmware | the **Caddx Ascent air** baseband image (`package/ascent-vendor-firmware`, from the Ascent vendor image), not the stock P1 one -- see "Radio link" below |
| Video | waybeam's `ar9311` backend (NT99235 camera through the MissingLynk V4L2 chain, H.265 on wave5, into `frame-shm://venc_frames` for `ar8030-transport-tx`); the waybeam pin predates it, so build with `WAYBEAM_OVERRIDE_SRCDIR=/path/to/waybeam_venc` (branch `ar9311`) |
| Vendor blobs | `package/artlynk-p1-vendor-firmware` extracts them from the stock `P1_SKY_*.img` (put it in `cache/vendor-images/` or point `ARTLYNK_P1_VENDOR_IMG` at it): the P1 RF power/PA calibration (for the generated `p1_ascent_air.json`), Wave521C codec firmware, NT99235 ISP tuning, stock SPL/U-Boot/DDR firmware for USB boot |

## RAM boot (no flash needed)

```sh
devices/ar9311_artosyn_artlynk-p1/scripts/ar9311-usbboot.py linux
devices/ar9311_artosyn_artlynk-p1/scripts/ar9311-usbboot.py linux --serial /dev/ttyUSB0 --root-password <pw>
```

Board in mask-ROM USB mode (`5343:0200`, e.g. with no bootable NAND); start
the script within ~10 s of power-on. The script patches the stock SPL to
train DDR from a virtual flash in SRAM, re-enters the ROM's USB loader for a
second session into DDR, loads U-Boot, kernel, initramfs and DTB, and
patches U-Boot (skip its USB-upgrade loop, default env with a `bootm` of the
loaded images) so it autoboots -- no UART needed. `--serial` (1152000 baud,
nothing else holding the port) shows the boot log and, with
`--root-password`, claims the fresh system. How and why: see the script's
docstring. Networking: RNDIS gadget, board at 192.168.3.104.

## Status

Working (hardware-tested, RAM boot):

- boot to OpenIPC login, SSH over the USB RNDIS gadget
- AR8030 bring-up: reset via gpiolib, firmware upload, RTOS (`4152:8031`),
  `ar8030d` + `ar8030-lifecycled` with events, ioctls answered, `ar_net0`
- **pairing and link with a Caddx Ascent ground unit** (`ar8030-pair` on
  both, slot 0 `CONNECT`); video over the link not tested yet (no encoder
  app, see below)

### Radio link

The stock P1 baseband firmware (2026-03, unchanged up to P1 v2.1.2) cannot
link with Ascent ground units: its MAC frame header is an older format
(`0x58`, 8-bit checksum, ...) that the Ascent firmware rejects as
`bb_mac_rx_proc: version <n>`. It also frames SDIO transfers with a
`{ flags, type, len }` trailer (`artosyn_drv link_trailer=1`, package/
ar8030-transport-tx `0002-*.patch`) and has no project dispatch layer
(`BB_SET_PRJ_DISPATCH` -> -4; package/ar8030 `0036-*.patch` falls back to
the standard pair API).

The Ascent air firmware runs on the P1 radio as is, so this target uses it,
with `p1_ascent_air.json`: the Ascent air config (AP, full 42-entry channel
table) plus the P1's power section and PA calibration. Things that matter:

- broadcast `tx_mode` must stay `2TX_STBC`: the P1 has only RF port A
  fitted (FEM GSR5755, port B unpopulated) and under the Ascent firmware
  `1TX` transmits on port B
- the channel table must match the ground's (42 entries), or the ground
  logs `chan tab: X not match Y` and never pairs
- the stock P1 `bb_config_air.json` does not boot the Ascent firmware
- startup power is capped to 200 mW (22 dBm) via `--default-power`, the
  stock P1 configs top out at 22-23 dBm

Not working yet:

- `S65ar8030-transport-tx stop` leaves `ar8030-lifecycled` running.
- Video: waybeam encodes 1080p60 H.265 (bench-tested over RTP); not yet
  tested end to end over the radio. No auto-exposure yet (fixed sensor
  exposure/gain). Restarting waybeam without a reboot can leave the wave5
  encoder emitting noise (firmware state survives the encoder instance;
  waybeam_venc `docs/AR9311_BACKEND.md`).
- NAND install not done (MissingLynk writes slot B: `kernel1`, `dtb1`,
  `userapp1` = mtd18).
