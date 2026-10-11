# caddx-pctool

`pctoold` lets CADDX's Windows PC tool (CADDX_PCTool, seen with V2.2.9_C) flash an
Ascent air unit that runs OpenIPC, the same way it flashes one running the stock
firmware. On stock, `/usrdata/fpv/ar_fpvhs_upgrade` does this.

## Protocol

Decoded from a USBPcap capture of the PC tool flashing a stock Ascent Lite+ with
`Ascent_H_Sky_18_21_10.img`. Every frame's CRC was checked against the capture,
the data chunks against the real file.

Transport: CDC-ACM, stock gadget ids 1D76:0101 ("Vendor" / "SerialGadget", serial
"CX24" for board type 472). The PC tool picks its device by vendor id 1D76 alone.

Header, 36 bytes, 9 × u32 little endian:

| off | field | host → device | device → host |
|---|---|---|---|
| 0x00 | magic | 0x4152544f ("OTRA") | same |
| 0x04 | direction | 0x00010cdc | 0x00020cdc |
| 0x08 | tag | 0xabcd0000 | 0 |
| 0x0c | cmd | | echoed |
| 0x10 | fmt | 2 | 2 |
| 0x14 | payload length | | |
| 0x18 | seq | host counts up | echoed |
| 0x1c | – | 0 | 0 |
| 0x20 | crc | zlib CRC-32 of header (crc = 0) + payload | same |

The host sends header and payload as two writes; the device answers in one.
`status[64]` below is a NUL-padded string, "OK" on success.

| cmd | host payload | device reply |
|---|---|---|
| 0x3c info | – | 300 B: u32 max chunk (0x100000) @0, SDK version[32] @0x04 (empty), name[64] @0x24 ("Ascent_lite_plus"), u32 temp °C @0x64, fw[64] @0x68 ("Ascent_H_Sky_18_21_10"), sn[32] @0xa8, hw[32] @0xc8 ("FPV-Ascent-Sky-472-V1.3-1.0"), u32 0 @0xe8, status[64] @0xec |
| 0x03 reboot | mode[32] ("clean") | 68 B: u32 result, status[64]. Stock then reboots into a stripped-down system; the PC tool waits 11.5 s and reopens the port. |
| 0x72 connect | – | 68 B: u32 result, status[64] |
| 0x73 start | 328 B: md5 hex[64] @0, u32 size @0x40, u32 1 @0x44, device path[128] @0x48 (stock: /tmp/pc/<name>), host path[128] @0xc8 | 68 B |
| 0x74 data | ≤ max chunk bytes | 80 B: u32 result, u32 received so far, u32 total, u32 0, status[64] |
| 0x75 done | – | 80 B, same layout, after the md5 check |
| 0x76 status | – | 72 B: u32 percent, u32 state, status[64]; polled about once a second |

States seen from stock: 2 = upgrading, 3 = done (the device reboots right after).
pctoold reports 4 for a failed upgrade; whether the PC tool reads 4 as failure is
not confirmed. If it doesn't, it gives up after about 200 polls and reports a timeout.

## On the air unit

The package installs `pctoold`, `/etc/default/pctoold` and `/usr/sbin/pctool-mode`.
`pctool-mode on|off|toggle` is the only way into updater mode and the only thing that
starts `pctoold`; nothing runs at boot. The board provides:

- `/usr/bin/usb-gadget` with `mode rndis|pctool` (`mode` alone prints the current one).
  In pctool mode it is a copy of stock's serial gadget, ids 1D76:0101.
- `/usr/sbin/pctool-hook clean|restore|reboot|rndis|enter|leave`: its policy. "clean"
  stops what the board can spare for the flash and drops the gadget off the bus for a
  second instead of rebooting; "enter"/"leave" are for LEDs.
- its own `/etc/default/pctoold`: name, hardware string and firmware prefix the PC tool
  shows (stock's values for the board). Per unit, `fw_setenv pctool_fw|pctool_hw|pctool_sn`.
- whatever triggers `pctool-mode toggle`.

On hi3516cv6xx_fpv_caddx-ascent-lite (`devices/.../general/overlay`):

- The USB port does RNDIS (default) **or** the PC tool's serial port, never both: the
  cv610's DWC3 has 3 IN endpoints besides ep0 and each function needs 2 (`acm: can't
  bind, err -19` when composed together). Stock has the same limit.
- Holding the bind button 5 s (ar8030-lifecycled → `hooks.d/longpress`) toggles updater
  mode; LEDs alternate red/green while it is on. Another long press, the PC tool's
  `0x3a`, or a reboot goes back to RNDIS.
- Removing the serial function blocks in the kernel while anything holds `/dev/ttyGS0`
  open, so `usb-gadget` stops `pctoold` first.
- The upload goes to `/tmp/pctool.asw`. sysupgrade streams the parts from it straight
  into the inactive bank, verifies them, mounts the new rootfs, then switches the bank.
  Logs: `logread | grep pctoold`, `/tmp/pctool-upgrade.log`.

## Linux hosts

In updater mode the air is a plain CDC-ACM device (`/dev/ttyACM0`). ModemManager probes
new ACM ports; keep it away with
`ATTRS{idVendor}=="1d76", ATTRS{idProduct}=="0101", ENV{ID_MM_DEVICE_IGNORE}="1"`.

`tools/pctool-client.py` plays the PC tool's
side (`info`, `flash`, `rndis`) from Linux.
