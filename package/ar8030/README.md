# ar8030 — Artosyn AR8030 baseband host support

Packages the vendor "yz_host_drv" SDK (<https://git.topxgun.com/czdu/yz_host_drv>,
pinned to commit `3bb948de`) into three pieces of the OpenIPC rootfs:

| Artifact | Installed as | What it is |
|---|---|---|
| `artosyn_drv.ko` | `/lib/modules/<ver>/extra/` | out-of-tree host driver, USB and/or SDIO |
| `daemon` | `/usr/bin/ar8030d` | RPC daemon; owns the char device, serves clients |
| `libar8030_client.so` | `/usr/lib/` | `bb_*` client API (+ headers in staging) |
| `bb_pair` | `/usr/bin/ar8030-pair` | pair/bind utility (optional, default on) |
| `ar8030_usb_test_tool` | `/usr/bin/ar8030-usb-loader` | rom-code fw loader (optional, default off) |
| `cmd_dbg`, `ota`, `app`, `net_dev_demo` | `/usr/bin/ar8030-*` | vendor demos (optional, default off) |

## Runtime shape

```
AR8030  ──USB/SDIO──  artosyn_drv.ko  ──/dev/ar_mdev0──  ar8030d  ──TCP 127.0.0.1──  clients
                            │                                     └─unix socket ./1
                            ├─ /proc/<mod>            (debug)
                            └─ netdev                 (IP over the baseband link)
```

`ar8030d` is not optional: the char device is single-open and everything
linking `libar8030_client` reaches the baseband through the daemon's RPC, not
through the device node. `S60ar8030` starts it after loading the module.

Firmware download happens in the **driver**, via `request_firmware()` driven by
the `fw_name=` / `cfg_name=` module parameters (both default to NULL, i.e. no
download — the chip is assumed to have booted from its own flash). The
`BR2_PACKAGE_AR8030_FIRMWARE` option drops the SDK's demo image and configs
into `/lib/firmware/ar8030` and `S60ar8030` wires them up. The alternative
userspace path — mdev hotplug on VID:PID `4152:8030` calling `autoload`, which
shells out to `ar8030_usb_test_tool` — is *not* packaged; only the loader
binary itself is available, behind `BR2_PACKAGE_AR8030_USB_LOADER`.

## Kernel requirements

The package's `LINUX_CONFIG_FIXUPS` force `CONFIG_FW_LOADER`, `CONFIG_PROC_FS`,
`CONFIG_NET`, and `CONFIG_USB` / `CONFIG_MMC` for the selected buses. Note
`FW_LOADER` must be **built in, not modular**: the driver calls
`request_firmware()` unconditionally, and with `CONFIG_FW_LOADER=m` (what
`hi3516cv6xx` ships by default) the symbol is missing from the kernel's
`Module.symvers`, so `artosyn_drv.ko` links with `request_firmware` /
`release_firmware` undefined — modpost only *warns*, and the failure surfaces
as an insmod-time "Unknown symbol".

Still your problem, because a fixup cannot supply them:

- a USB **host controller** driver, if the AR8030 hangs off USB
- an **SDIO-capable** MMC host controller driver, if it hangs off SDIO
  (`CONFIG_MMC_SDHCI` and friends — `CONFIG_MMC` alone is not enough; the
  `hi3516cv100` config, for instance, has `CONFIG_MMC=y` with every host
  controller disabled)

**The driver needs Linux 4.x or newer.** Its version shims bottom out around
3.10 and the netdev/USB paths are written against 4.x APIs. Concretely, within
OpenIPC that rules out the old HiSilicon BSP kernels — `hi3516cv100` is on
3.0.8 — and includes `hi3516cv6xx` (5.10.221), which is the family the Caddx
Ascent's Hi3516CV610 belongs to.

## Patches

- `0001-cmake-allow-a-driver-only-transport.patch` — upstream's CMakeLists
  aborts unless one of `USING_8030USB/SDIO/UART` is on, ignoring
  `USING_8030DRV`. Talking to the chip *through the kernel driver* is exactly
  what we want, and it is the only combination that does not also drag in the
  bundled libusb.
- `0002-cmake-make-the-dev_helper-tools-optional.patch` — `dev_helper` builds
  `ar8030_usb_test_tool` (and its vendored libusb), `ota_upgrade` and `cmd_dbg`
  unconditionally. Gated behind options so a minimal image does not carry them.

## Notes / gotchas

- The daemon writes its `daemon_log/` directory and its unix socket relative to
  `$PWD`. On a read-only squashfs it must be started from somewhere writable;
  `S60ar8030` uses `/tmp/ar8030`.
- OpenIPC's `rootfs_script.sh` deletes `/usr/lib/libstdc++*` on musl builds, so
  the C++ tools (`bb_pair`, `cmd_dbg`, `ota`, the USB loader) are linked with
  `-static-libstdc++`.
- Upstream binary names (`daemon`, `app`, `ota`, `cmd_dbg`) are too generic to
  drop into a shared `/usr/bin`; everything is installed with an `ar8030`
  prefix. The vendor docs refer to the original names.
- Size: roughly 350 KB of binaries plus ~340 KB for the demo firmware,
  uncompressed. That does not fit an 8 MB NOR `lite` image without trimming
  something else — check `sizes.*.json` after a build.
