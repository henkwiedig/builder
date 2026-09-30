#!/usr/bin/env python3
"""
This device's BR2_PACKAGE_AR8030_FIRMWARE_FETCH_SCRIPT (see
package/ar8030/Config.in for the contract): copies the Caddx Ascent air
baseband image, extracted into BINARIES_DIR by package/ascent-vendor-firmware
(this device's BR2_PACKAGE_AR8030_FIRMWARE_FETCH_DEPENDENCY, so it has
already run), into the directory AR8030_INSTALL_FIRMWARE reads from.

The P1 runs the Ascent firmware rather than its stock one so that it links
with Ascent ground units (see devices/ar9311_fpv_artlynk-p1/README.md).
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
