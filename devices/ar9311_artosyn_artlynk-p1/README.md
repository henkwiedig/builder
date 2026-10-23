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
| Rootfs | `rootfs.cpio.gz` for RAM boot; `rootfs.ubi` for the NAND install: a UBIFS `rootfs` volume and an empty `rootfs_data` overlay (`board/ar9311/ubinize.cfg`) |
| Update image | `P1_SKY_<release>_OpenIPC_<builder sha>.img`: BetaFPV's update format with the stock SPL, vendor partition and U-Boot, and `uImage.ar9311`, `proxima-9311-air.dtb` (flash boot command line) and `rootfs.ubi`; for `sysupgrade` / `ar9311-install.py` (see below). Sizes are checked against the partitions |
| AR8030 firmware | the **Caddx Ascent air** baseband image (`package/ascent-vendor-firmware`, from the Ascent vendor image), not the stock P1 one -- see "Radio link" below |
| Video | waybeam's `ar9311` backend (NT99235 camera through the MissingLynk V4L2 chain, H.265 on wave5, into `frame-shm://venc_frames` for `ar8030-transport-tx`), from waybeam_venc's `ar9311` branch, which `package/waybeam/waybeam.mk` pins separately from the cv610 backend |
| Vendor blobs | `package/artlynk-p1-vendor-firmware` extracts them from the stock `P1_SKY_*.img` (put it in `cache/vendor-images/` or point `ARTLYNK_P1_VENDOR_IMG` at it): the P1 RF power/PA calibration (for the generated `p1_ascent_air.json`), Wave521C codec firmware, NT99235 ISP tuning, stock SPL/U-Boot/DDR firmware for USB boot |

## RAM boot (no flash needed)

```sh
devices/ar9311_artosyn_artlynk-p1/scripts/ar9311-usbboot.py linux
devices/ar9311_artosyn_artlynk-p1/scripts/ar9311-usbboot.py linux --serial /dev/ttyUSB0 --root-password <pw>
```

Board in mask-ROM USB mode (`5343:0200`): a board without NAND lands there
by itself; a board with NAND does when its SPI-NAND CLK line is held to
ground while it powers up (the boot ROM then finds no SPL). Start the script
within ~10 s of power-on. The script patches the stock SPL to
train DDR from a virtual flash in SRAM, re-enters the ROM's USB loader for a
second session into DDR, loads U-Boot, kernel, initramfs and DTB, and
patches U-Boot (skip its USB-upgrade loop, default env with a `bootm` of the
loaded images) so it autoboots -- no UART needed. `--serial` (1152000 baud,
nothing else holding the port) shows the boot log and, with
`--root-password`, claims the fresh system. How and why: see the script's
docstring. Networking: RNDIS gadget, board at 192.168.3.104.

## NAND install and updates

```sh
S=devices/ar9311_artosyn_artlynk-p1/scripts
$S/ar9311-usbboot.py linux                  # mask ROM -> RAM boot, the NAND untouched
ssh root@192.168.3.104                       # once per RAM boot: set the root password
$S/ar9311-install.py backup ~/p1-backup      # every partition + the whole chip, md5-checked
$S/ar9311-install.py install openipc/output/images/P1_SKY_<release>_OpenIPC_<sha>.img --backup ~/p1-backup
# then power-cycle (without the CLK short)
```

The build's update image, `P1_SKY_<release>_OpenIPC_<builder sha>.img`, is
BetaFPV's own update format (Artosyn "ARTO", `scripts/ar9311-image.py`):
built on the stock image `package/artlynk-p1-vendor-firmware` uses, with its
SPL, vendor partition and signed U-Boot, and this build's kernel, dtb and
rootfs. Its SHA-256 is its own and its RSA signature empty, so the stock
flasher refuses it; `sysupgrade` on the board takes it and BetaFPV's
`P1_SKY_*.img` alike:

```sh
sysupgrade --image=/tmp/P1_SKY_..._OpenIPC_<sha>.img      # OpenIPC, settings carried over
sysupgrade --image=/tmp/P1_SKY_v2.0.5_20260330_a22d901.img --set-password=PASS   # back to stock
```

The flash has two slots, the env/uboot/kernel/dtb/userapp pairs; the stock
SPL boots the one the GPT marks active (attribute bit 47; the GPT lives in
`gpt0` or `gpt1`, whichever the last update wrote,
`openipc-bsel`). `sysupgrade` writes the slot not running and then switches
to it, so the previous firmware stays one `openipc-bsel switch` away. It
refuses an image whose SPL or vendor partition differs from the unit's (both
slots share them: the stock flasher's job), and leaves `factory`, `usr_data`
and `usr_log` alone, so stock comes back with its own settings and pairing.
An OpenIPC image gets the running system's U-Boot variables and its overlay's
passwords, ssh keys, AR8030 pairing and `/etc/default` (`-n`: none of it).
`--set-password` sets root's password on what is flashed; for stock, whose
`/etc/passwd` is on a read-only squashfs, through stock's own
`/usrdata/run_dbg.sh` hook (see the script).

Without SSH: the stock U-Boot's USB upgrade takes these images too. It
checks BetaFPV's RSA signature but does not enforce it, writes the slot not
active (plus all four SPL copies and the GPT) and makes it the active one;
nothing carries over. From a unit running stock (or switched to a slot with
stock in it):

```sh
$S/ar9311-usbburn.py flash P1_SKY_<release>_OpenIPC_<sha>.img --from-stock   # ~7 min upload, then power-cycle
```

`ar9311-install.py install` checks the backup is this unit's (its `factory`
partition, the unit's RF calibration), uploads the image and runs the board's
`sysupgrade`; it works from a RAM boot and from an installed system.
`ar9311-usbboot.py linux --nand-root` boots the RAM kernel against slot B's
rootfs.

## Status

Working (hardware-tested, RAM boot):

- boot to OpenIPC login, SSH over the USB RNDIS gadget
- AR8030 bring-up: reset via gpiolib, firmware upload, RTOS (`4152:8031`),
  `ar8030d` + `ar8030-lifecycled` with events, ioctls answered, `ar_net0`
- **pairing and link with a Caddx Ascent ground unit** (`ar8030-pair` on
  both, slot 0 `CONNECT`)
- video: 1080p60 H.265 from the P1 camera over the link to an Ascent ground
  unit (waybeam's `ar9311` backend: auto-exposure, cyclic intra refresh,
  picture controls on `/api/v1/iq`; restarts within a boot stream clean
  video since waybeam 0.86.1)
- bind button and status LED; msposd OSD forwarding with the SoC temperature

- `S65ar8030-transport-tx stop`/`restart`: lifecycled and ar8030d are
  waited for before `rmmod`, the module load waits for the old RTOS SDIO
  card to go after the gpiolib reset, and the link is back ~18 s later
  with the persisted peer
- PI bitrate controller (`ar8030-transport-tx -C pi -n 1000`: 1000 kbps ->
  ~22 Mbit/s at MCS 12, link-side delay 8-14 ms), stock link policy
  (`--link-policy 2`), RF path B off (`--rf-path-b-off`)
- heat protection, see "Heat" below
- `sysupgrade` both ways: OpenIPC into the other slot with the settings
  carried over, and BetaFPV's `P1_SKY_v2.0.5_20260330_a22d901.img` back
  with `--set-password` (stock 2.0.5 then answers ssh at 192.168.3.99, not
  .100); from stock, a static `openipc-bsel set` switches back
- **NAND install and boot from flash** (slot B): the stock SPL loads
  `kernel1`/`dtb1` itself, the kernel mounts `userapp1`'s rootfs read-only
  with the `rootfs_data` overlay and boots to the login prompt with RNDIS
  up; root mounted 1.1 s after the kernel starts

Taken over from the Ascent, not yet tested on the P1 (no FC on the bench):
10 dBm standby while the FC is disarmed (msposd -> `armed.sh` ->
lifecycled `--standby-dbm 10`).

### Heat

Without airflow the P1 overheats fast: from 63 to over 100 degC SoC in
about two minutes on the bench (MissingLynk's notes say the same). With a
fan on, settled SoC temperatures by what is running: 53 degC streaming,
47 with waybeam stopped, 40 with the camera chain unloaded too, 34 with
the AR8030 held in reset as well -- waybeam, the camera chain (clocked as
long as its modules are loaded) and the AR8030 are about a third each.
wave5 idle costs nothing measurable.

Two stages, both hardware-tested without airflow:

- lifecycled `--overheat-c 105` (`p1-temp`): `video-pause` stops waybeam,
  unloads the camera chain and puts ar8030-still's "VTX OVERHEAT" frame on
  the link; the radio drops to 10 dBm. Back at 95. Without airflow that
  takes the SoC from 106 to ~100 degC, after which it creeps up again
  (+1 degC / 30 s).
- `heat-guard` (S96, `/etc/default/heat-guard`) at 110: the AR8030 goes off
  too (S65 stop, held in reset), the link drops; back at 90. Without
  airflow: 112 -> 89 degC in 80 s.

### Radio link

The stock P1 baseband firmware (2026-03, unchanged up to P1 v2.1.2) cannot
link with Ascent ground units: its MAC frame header is an older format
(`0x58`, 8-bit checksum, ...) that the Ascent firmware rejects as
`bb_mac_rx_proc: version <n>`. It also frames SDIO transfers with a
`{ flags, type, len }` trailer, which artosyn_drv does not speak (a
`link_trailer=1` mode for it was package/ar8030-transport-tx
`0002-kmod-link-trailer-mode-for-sdio-framed-firmware.patch`, dropped once
the P1 ran the Ascent firmware; see git history), and has no project dispatch layer
(`BB_SET_PRJ_DISPATCH` -> -4; package/ar8030 `0036-*.patch` falls back to
the standard pair API).

The Ascent air firmware runs on the P1 radio as is, so this target uses it,
with its own config, generated as `p1_ascent_air.json` and installed as
`/lib/firmware/ar8030/ar8030.json` (the name every tool defaults to, so
`ar8030-pair` persists the peer into the config the chip loads): the Ascent
air config (AP, full 42-entry channel table) plus the P1's power section and
PA calibration. Things that matter:

- broadcast `tx_mode` must stay `2TX_STBC`: the P1 has only RF port A
  fitted (FEM GSR5755, port B unpopulated) and under the Ascent firmware
  `1TX` transmits on port B. Path B is switched off at runtime instead
  (`ar8030-lifecycled --rf-path-b-off`, the firmware's RF path control),
  exactly as on the Ascent Lite, which has the same single path
- the channel table must match the ground's (42 entries), or the ground
  logs `chan tab: X not match Y` and never pairs
- the stock P1 `bb_config_air.json` does not boot the Ascent firmware
- startup power is capped to 200 mW (22 dBm) via `--default-power`, the
  stock P1 configs top out at 22-23 dBm

Not working yet:

- a warm `reboot` resets the SoC, but the SPL then often hangs reading the
  kernel (`spi_load_image_os 114`, no `Uncompressing Firmware`) until a power
  cycle; not analysed yet
