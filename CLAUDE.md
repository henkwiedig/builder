# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

OpenIPC **builder** is a thin Buildroot *overlay* layer for building OpenIPC IP-camera
firmware for specific, named consumer devices. It contains **only the per-device deltas**
(a defconfig, a first-boot customizer, a rootfs exclude list, occasional sensor/board
files). Everything common — the actual Buildroot tree, packages, kernels, toolchains — lives
in [`OpenIPC/firmware`](https://github.com/openipc/firmware), which `builder.sh` clones fresh
on every run. This repo is never built in isolation; it is layered on top of a firmware
checkout.

## Build commands

```sh
./builder.sh                       # interactive whiptail menu of all devices
./builder.sh <device>              # build one device non-interactively
```

`<device>` is the directory name under `devices/` (minus the `_defconfig` suffix on its
config), e.g. `hi3518ev200_lite_switcam-hs303`. It is passed straight through as
`make BOARD=<device>`. There is no separate test/lint suite — "passing" means the firmware
image builds and (ideally) boots on hardware.

What `builder.sh <device>` does, in order:
1. `git pull` (self-update the builder repo).
2. `rm -rf openipc` then clone `OpenIPC/firmware` — HEAD by default, or the ref in
   `$OPENIPC_FW_REV` if set (used for cross-repo bisects; see build-one.yml).
3. `copy_extra_packages` — copy `package/*` into `openipc/general/package/` and append a
   `source "...Config.in"` line for each into the external tree's `Config.in`.
4. Copy `devices/<device>/*` over the firmware tree (defconfig, overlay, excludes, board).
5. `make BOARD=<device>` then best-effort `make BOARD=<device> size-report`.
6. `copy_to_archive` → `archive/<device>/<timestamp>/`. For `hi3518ev200_lite` it also runs
   `autoup_rootfs` to wrap the images as `autoupdate-*.img` via `mkimage`.

`openipc/`, `archive/`, `cache/`, `output/` are all gitignored build artifacts.

### Other scripts
- `repack.sh [uboot] [firmware] [ssid] [pass]` — does **not** build. Downloads a prebuilt
  release `.tgz` + u-boot from GitHub releases, optionally bakes in WiFi creds via
  `fw_setenv`, and `dd`s a flashable NOR image. Needs `squashfs-tools`.
- `package.sh [pkg]` — force a full rebuild of one Buildroot package inside an existing
  `openipc/` tree (`dirclean` + `rebuild`; defaults to `busybox`).
- `devices/hi3516cv6xx_fpv_caddx-ascent-lite/scripts/pack-caddx-ascent.py` — repacks a finished
  build's `fitImage`/`rootfs.ubi`/`usrdata.ubi` into the vendor's undocumented "ASW" 5-slot
  container format (magic `0x575341`, no signature check — reverse-engineered and
  round-trip-verified against a real stock image; see the script's own docstring for the
  format), so the stock Windows `CADDX_PCTool` flasher can write it. `boot_image.bin`/
  `nand_env.bin` (proprietary vendor SPL/U-Boot + env) are never committed here — the script
  slices them out of a stock `Ascent_H_Sky_*.img`, same spirit as `repack.sh` sourcing vendor
  binaries at use-time rather than shipping them. Its sibling `fetch-vendor-img.sh` downloads
  that stock image from Google Drive (scrapes the large-file confirm-token interstitial —
  fragile if Google changes that page) into `cache/vendor-images/` and caches it there across
  builds; also reused by `package/ascent-vendor-firmware/extract.py` below. Not yet
  verified on real hardware.

  Auto-run at the end of this device's own `BR2_ROOTFS_POST_IMAGE_SCRIPT` (in its defconfig),
  after the shared SoC `post-image.sh` (fitImage) and `make-usrdata-image.sh` (usrdata.ubi), by
  `general/scripts/pack-caddx-ascent-hook.sh` — ordinary Buildroot-copied overlay content
  (unlike the two scripts above, which need `cache/vendor-images/` to survive builder.sh's
  `rm -rf openipc` between builds, so they're invoked from the long-lived builder checkout by
  absolute path rather than copied into the ephemeral firmware clone the way `general/scripts/*`
  normally is). The hook derives the builder checkout's path from `BINARIES_DIR` and always
  exits 0 (a nonzero post-image script fails `make` outright), so a broken Drive scrape just
  skips the ASW repack with a warning. Drops the result straight into `BINARIES_DIR`
  (`output/images/hi3516cv6xx_fpv_caddx-ascent-lite-asw.img`) — `builder.sh` does not archive
  it, it just sits in `output/images/`. In practice the vendor image is often already cached by
  the time this runs: `package/ascent-vendor-firmware`'s build step downloads the same
  file earlier in the same build, and `fetch-vendor-img.sh` is a no-op on a warm cache.

## Device anatomy

Device directory names encode `<soc>_<flavor>_<vendor>-<model>[-<version>]`:
- **soc** — OpenIPC SoC name: `hi3518ev200`, `ssc337de`, `t31`, `gk7205v200`, …
- **flavor** — firmware track: `lite` (default, the vast majority), `ultimate`, `fpv`,
  `rubyfpv`, `apfpv`. Prefer `lite` for new devices unless flash size forces otherwise.

The minimal required files for a registered device (per README "Requirements"):
```
devices/<device>/br-ext-chip-<vendor>/configs/<device>_defconfig
devices/<device>/general/overlay/usr/share/openipc/customizer.sh
devices/<device>/general/scripts/excludes/<soc>_<flavor>.list
```
- **`br-ext-chip-<vendor>/`** — the chip-vendor folder mirrors firmware's `BR2_EXTERNAL`
  layout. One of: `br-ext-chip-hisilicon`, `br-ext-chip-sigmastar`, `br-ext-chip-goke`,
  `br-ext-chip-ingenic` (Ingenic = the T-series SoCs). The defconfig inside selects
  toolchain/kernel/SoC drivers and majestic/webui packages; it references `$(OPENIPC_*)`
  and `$(EXTERNAL_VENDOR)` macros resolved by the firmware Makefile, not by this repo.
- **`customizer.sh`** — runs on first boot. Applies device-specific runtime config:
  `fw_setenv` (upgrade URL, `wlandev`, `ptz` profile, WiFi) and `cli -s .<path> <value>`
  to seed majestic's config (sensor ini, IR-cut/backlight GPIO pins, codec, fps).
- **`<soc>_<flavor>.list`** — paths to **delete** from the rootfs (unused sensor `.so`/`.ini`,
  unused WiFi `.ko`, etc.) so the image fits NOR flash. This is the main lever for the
  "doesn't fit in 8M NOR" problem.

Optional per-device files: extra `general/overlay/...` payload (a sensor `libsns_*.so`, a
sensor `.ini`, a patched `load_hisilicon`), or a custom kernel config at
`br-ext-chip-<vendor>/board/<family>/<soc>.generic.config`.

### `devices/common/`
Generic, non-device-specific defconfigs (`*_fpv`, `*_venc`, `*_lte`, `*_mini`) plus their
shared kernel configs and exclude lists. These are the matrix entries with a single
underscore (`hi3516ev200_fpv`, `hi3518ev200_mini`). The CI artifact-naming logic keys off
this: `COMMON = (underscore count) - 1`; when `COMMON == 1` the firmware's canonically-named
image is uploaded as-is, otherwise the compound `<soc>_<flavor>_<vendor>-<model>` image is
renamed to `<device>-nor.tgz` / `-nand.tgz` to avoid release-asset collisions.

## Adding a new device

The fastest correct path is to clone the closest existing device — **same SoC and same
flavor** — and edit the deltas. Identify the target's SoC, image sensor, WiFi chip, and flash
size first (the README device table lists all of these for existing boards).

1. **Copy a sibling.** `cp -r devices/<soc>_<flavor>_<other> devices/<soc>_<flavor>_<vendor>-<model>`.
   The new directory name *is* the `BOARD`/`<device>` token; keep it
   `<soc>_<flavor>_<vendor>-<model>[-<version>]`, lowercase, hyphen-separated vendor/model.
2. **Rename + edit the defconfig.** It lives at
   `br-ext-chip-<vendor>/configs/<device>_defconfig` and its filename must match the new
   directory name exactly (this is what `make BOARD=` looks up). Inside, the lines you
   typically change:
   - WiFi driver — the `BR2_PACKAGE_<chip>_OPENIPC=y` line (e.g. `RTL8188FU`, `RTL8189FS`,
     `ATBM…`). Pick the one matching the device's WiFi module.
   - `BR2_OPENIPC_FLASH_SIZE="8"` / `"16"` to match the NOR/NAND size.
   - Leave `BR2_OPENIPC_SOC_*`, `BR2_OPENIPC_VARIANT`, the toolchain/kernel block, and the
     `*_OSDRV_*` sensor-driver package alone unless the SoC/flavor actually differs.
3. **Edit `general/overlay/usr/share/openipc/customizer.sh`** (runs on first boot):
   - `fw_setenv upgrade '…/releases/download/latest/<device>-nor.tgz'` — the filename **must**
     equal `<device>-nor.tgz`, because that is exactly what CI renames the artifact to (see
     the `COMMON` logic above). Getting this wrong breaks self-update.
   - `fw_setenv wlandev <driver-profile>`; optional `fw_setenv ptz <profile>`.
   - `cli -s .<path> <value>` to seed majestic — IR-cut / backlight / light-sensor GPIO pins,
     codec, fps. Only set `.isp.sensorConfig /etc/sensors/<sensor>.ini` when the sensor needs
     a non-default config (most boards don't — it's the exception, e.g. MIPI sensors).
4. **Trim the exclude list.** Keep the filename `<soc>_<flavor>.list` (it is named after
   soc+flavor, **not** the full device name — do not rename it to the device). Remove from the
   list the sensor `.so`/`.ini` and WiFi `.ko` that *this* board actually uses, so they survive
   into the rootfs; everything else listed gets stripped to fit flash. Sibling devices on the
   same `<soc>_<flavor>` often share an identical list — diff against them.
5. **Optional payload.** Add files under `general/overlay/…` only when required (a
   `libsns_<sensor>.so` not provided by the SoC osdrv, a patched `load_hisilicon`, a sensor
   `.ini`), or a custom kernel config at `br-ext-chip-<vendor>/board/<family>/<soc>.generic.config`.
   Keep the file count minimal — anything reusable belongs upstream in `OpenIPC/firmware`.
6. **Register for nightly CI.** Add `- <device>` to the matrix in
   `.github/workflows/master.yml` under the matching group (SoC/APFPV/FPV/Ruby/etc.). This
   matrix is the *only* build registry — a device not listed here is never built or released.
7. **Document it.** Add a row to the device table in `README.md` (and the clones table if it's
   a rebrand of an existing board).
8. **Build & verify locally.** `./builder.sh <device>`, then check
   `archive/<device>/<timestamp>/` for the image and confirm it fits the flash size. Use
   `package.sh <pkg>` to iterate on a single package without a full re-clone.

## `package/` — builder-local Buildroot packages

Standard Buildroot packages (`Config.in` + `<name>.mk` + `src/` and/or `files/`) that aren't
(yet) upstream in firmware. `copy_extra_packages` in `builder.sh` injects them at build time.
Examples: `kc110-board-support` (a device-specific C PTZ/IR binary + init scripts, installed
via `SITE_METHOD = local`), `demo-openipc`. Read the package `Config.in` help text — e.g.
`kc110-board-support` documents the device's exact GPIO/pinmux map.

`ar8030`/`ascent-vendor-firmware`/`waybeam` together show several patterns worth reusing elsewhere:
- **`BR2_ROOTFS_PRE_BUILD_SCRIPT` does not work in this project** — looks like the obvious way
  to "run this before the build starts," but nothing `make BOARD=...` actually runs depends on
  Buildroot's internal `prepare` target (which is what fires that hook) except `sdk`/
  `prepare-sdk`; `openipc/Makefile`'s own `build:` target calls `$(BR_MAKE) all` directly.
  Confirmed via `make -n all` against a real `.config` — zero mentions of `prepare` in the
  entire ~12k-line dry-run trace. Setting it produces no error, just silently never runs.
- Fetching proprietary vendor binaries at build time instead of committing them, so they never
  enter git history (this repo is public): a `_PRE_BUILD_HOOKS` entry runs a fetch script that
  downloads/extracts the binary fresh every build and, on failure (no network, an upstream
  format change), just installs without it rather than failing. Plain config (`ar8030.json`)
  still ships committed; only actual binary blobs are treated this way. Fetched artifacts also
  get archived into `$(BINARIES_DIR)` (e.g. `output/images/ar8030.img`) alongside
  `fitImage`/`rootfs.ubi`/etc — any package can do this, `$(BINARIES_DIR)` is a plain global
  Buildroot variable, not something reserved for `BR2_ROOTFS_POST_IMAGE_SCRIPT`.
- Keeping a reusable package vendor-agnostic by pushing vendor-specific logic out to the
  *device*: neither `package/ar8030/ar8030.mk` nor `package/waybeam/waybeam.mk` contains any
  CADDX-specific code — each runs whatever script the device's own defconfig names in its own
  `BR2_PACKAGE_*_FETCH_SCRIPT` (a string Kconfig option, same shape as
  `BR2_ROOTFS_POST_IMAGE_SCRIPT`/`BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE`; `ar8030` for the
  baseband image, `waybeam` for sensor tuning), plus an optional matching
  `BR2_PACKAGE_*_FETCH_DEPENDENCY` naming an extra package to build first (see the next bullet).
  So a different AR8030 board, or a different sensor/vendor waybeam is built against, points its
  own fetch script at its own vendor's firmware without touching either package. Note `waybeam`
  is *only* vendor-agnostic for this one piece — `WAYBEAM_SOC_BUILD`, `CV610_SENSOR_PLUGIN`, the
  installed `libsns_os02k10.so` path etc. are still hardcoded CADDX/cv610/os02k10 throughout;
  genericizing those would be a much larger, separate change. `$(BINARIES_DIR)` (not
  `$(TOPDIR)`) is the reliable way such a script finds the long-lived builder checkout from
  inside a build recipe — `$(TOPDIR)` is the extracted *buildroot source* directory (e.g.
  `openipc/output/buildroot-2024.02.10`), whose depth relative to the checkout root isn't a
  build-system-wide invariant; a first attempt at this got that wrong and broke on a clean
  rebuild.
- Sharing one expensive fetch between multiple packages via a real Buildroot dependency, since
  `BR2_ROOTFS_PRE_BUILD_SCRIPT` can't do it: `package/ascent-vendor-firmware` is a
  `generic-package` with `SITE_METHOD = local` and no real source (`SITE` just points at its own
  `PKGDIR`, with the trailing slash `PKGDIR` always carries stripped via `$(patsubst %/,%,...)`
  — `SITE` rejects one outright) whose `BUILD_CMDS` fetches+extracts CADDX's vendor image once,
  writing `ar8030.img`/`sensors/*.bin` straight into `$(BINARIES_DIR)` rather than an
  intermediate cache — only the raw vendor zip/img itself (`cache/vendor-images/`) is expensive
  enough to be worth persistent caching across builds; `$(BINARIES_DIR)` is wiped every
  `builder.sh` run regardless (it's under `openipc/`), and `extract.py`'s own `BUILD_CMDS` only
  ever runs once per build anyway (standard `.stamp_built` behavior), so a second cache layer
  for the cheap extraction step would just be complexity with no payoff. Both `ar8030` and
  `waybeam` name it in their own `_FETCH_DEPENDENCY` string (set in this device's defconfig,
  keeping both packages' `.mk` files vendor-agnostic), so Buildroot's own scheduler guarantees
  it has already built — a genuine ordering guarantee, unlike hoping two packages' independent
  fetches don't race under `-jN`. Gotcha: Buildroot's
  `CHECK_ONE_DEPENDENCY` (`BR_FORCE_CHECK_DEPENDENCIES = YES`, always on) hard-errors if a
  *target*-type package named in `_DEPENDENCIES` isn't itself Kconfig-enabled — a plain `.mk`
  with no `Config.in` bool isn't enough; this device's defconfig sets
  `BR2_PACKAGE_ASCENT_VENDOR_FIRMWARE=y` directly. Lives in top-level `package/` (not
  `devices/<device>/general/package/`), same as `kc110-board-support`, even though it is
  genuinely single-device-specific: `copy_extra_packages` in `builder.sh` only auto-sources a
  `Config.in` for top-level `package/*` — a device-local `general/package/` entry only works for
  *patching* an already-upstream package (see `hisilicon-opensdk` under this device's tree, a
  patch with no `Config.in` of its own), not for introducing a brand new one, unless `builder.sh`
  itself is extended to also scan device-owned `general/package/*` (tried once, reverted — not
  worth the extra `builder.sh` surface for this).
- Reading a UBI image (`ubireader_extract_files`, used by `extract.py` above) is a plain **host
  prerequisite**, not a Buildroot dependency: `pip install --user ubi_reader` if you want it.
  Deliberately not vendored as a hermetic Buildroot host package — that would need current PyPI
  `ubi_reader`'s `lzallright`, a Rust pyo3 extension with no existing Buildroot package (dragging
  in a full `host-rust` toolchain for what's otherwise a small pure-Python tool). Missing it is a
  silent, best-effort skip (no `ar8030.img`, no sensor tuning that build), never a build failure
  — see `extract.py`'s own `warn()` calls.
- The Google Drive file id of CADDX's vendor zip is owned by `ascent-vendor-firmware.mk`
  (`ASCENT_VENDOR_FIRMWARE_VENDOR_FILE_ID`), not hardcoded in `fetch-vendor-img.sh` — the .mk
  passes it to `extract.py` as an argument, which threads it through to the shell script via a
  `FILE_ID` env var. `fetch-vendor-img.sh` still keeps that same value as its own `${FILE_ID:-…}`
  fallback default, purely so it stays independently runnable by hand (per its own docstring)
  and so `pack-caddx-ascent-hook.sh` (a separate, unrelated feature) doesn't need to know about
  it. Bumping to a newer CADDX release, or pointing at a different vendor image, means editing
  one line in the `.mk`.
- Not every fetched-not-committed binary needs the CADDX flow's full weight: `waybeam.mk`'s
  `libbin.so` (Hisilicon's proprietary ISP tuning-bin import/export lib, needed for the
  `isp.sensorBin` config path and `/api/v1/iq/export_bin` API — absent, they just warn and
  no-op, everything else still boots) is a single `curl --fail` from a pinned commit of a
  fork's `raw.githubusercontent.com` URL, SHA256-verified (no magic-byte format to sanity-check
  against, unlike the ASW/UBI vendor images), wired via `WAYBEAM_POST_INSTALL_TARGET_HOOKS` and
  gated on `$(OPENIPC_SOC_VENDOR)` (the exported, qstripped form of `BR2_OPENIPC_SOC_VENDOR` —
  already exported by `general/external.mk`, e.g. `EXTERNAL_VENDOR`'s own definition; use that,
  not the raw quoted Kconfig var, inside a package `.mk`). Best-effort throughout, same as
  everything else in this list — a failed fetch or hash mismatch just skips installing the file.

## CI (`.github/workflows/`)

- **master.yml** ("Build") — nightly cron (03:00 UTC) + manual dispatch. Builds the full
  device matrix; it always rebuilds (the input that actually changes is firmware HEAD /
  toolchain / kernel, all *outside* this repo, so there is no skip-gate). Caches ccache and
  Buildroot's `BR2_DL_DIR` at `/tmp/builder-dl` (outside `openipc/` because `builder.sh`
  `rm -rf`s that tree each run). Uploads each image to three release tags: dated
  `nightly-YYYYMMDD-<sha>`, rolling `nightly`, and legacy `latest`; pushes the NOR build to
  Telegram.
- **build-one.yml** — dispatch one platform at a chosen builder `commit` and/or firmware
  `firmware_ref`. Built for `git bisect run` across either repo; publishes to
  `nightly-bisect-*`.
- **manifest.yml** — after Build finishes (success *or* partial failure), regenerates
  `manifest.json` + `manifest.flat` on the `gh-pages` branch via
  `.github/scripts/enrich_manifest.py`.
- **cleanup.yml** — weekly prune of dated `nightly-*` releases beyond the newest 90.

### Moving-ref cache caveat
The monthly `builder-dl` cache can freeze packages pinned to a moving ref (VERSION = HEAD /
branch, or the `majestic-webui` `dist` asset) because they download under a constant
`<pkg>-<ref>.tar.gz` filename. Both build workflows have a "Refresh moving-ref package
downloads" step that deletes `*-HEAD/master/main/dist.tar.gz` from the cache so Buildroot
re-fetches them each run. If you add a package pinned to a branch, make sure its tarball name
matches that glob or it will go stale silently.

## Project memory (kaeru)

Device-specific build/runtime gotchas, recovery procedures, and hardware quirks are recorded
in the **kaeru** `builder` initiative — query it before debugging a board (e.g. the
"overlay wipe removes ssh authorized_keys", "busybox `ip` has no `br` flag", and
generic→builder migration notes already there). Put new technical findings in kaeru, not here.
