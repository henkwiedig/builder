#!/usr/bin/env python3
"""
This device's BR2_PACKAGE_AR8030_FIRMWARE_FETCH_SCRIPT (see
package/ar8030/Config.in for the contract): copies into the directory
AR8030_INSTALL_FIRMWARE reads from
  - ar8030.img: the Caddx Ascent air baseband image, extracted into
    BINARIES_DIR by package/ascent-vendor-firmware;
  - ar8030.json: the P1's own config, p1_ascent_air.json, generated into
    BINARIES_DIR/artlynk-p1/ by package/artlynk-p1-vendor-firmware -- under
    the name every tool defaults to, so ar8030-pair persists the peer into
    the config the chip loads.
Both packages are this device's BR2_PACKAGE_AR8030_FIRMWARE_FETCH_DEPENDENCY,
so they have already run.

The P1 runs the Ascent firmware rather than its stock one so that it links
with Ascent ground units (see devices/ar9311_artosyn_artlynk-p1/README.md).
Never fails the build.
"""
import shutil
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fetch-ascent-ar8030-firmware.py <binaries-dir> <out-dir>", file=sys.stderr)
        return 0
    src = Path(sys.argv[1], "ar8030.img")
    if not src.is_file():
        print(f"fetch-ascent-ar8030-firmware: {src} not found (ascent-vendor-firmware fetch "
              f"failed this build?) -- no ar8030.img this build", file=sys.stderr)
        return 0
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, out / "ar8030.img")
    print(f"fetch-ascent-ar8030-firmware: copied {src}")

    cfg = Path(sys.argv[1], "artlynk-p1", "p1_ascent_air.json")
    if not cfg.is_file():
        print(f"fetch-ascent-ar8030-firmware: WARNING: {cfg} not found (no stock P1 image?) -- "
              f"installing the plain Ascent ar8030.json, without the P1's power section "
              f"and PA calibration", file=sys.stderr)
        return 0
    shutil.copyfile(cfg, out / "ar8030.json")
    print(f"fetch-ascent-ar8030-firmware: copied {cfg} as ar8030.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
