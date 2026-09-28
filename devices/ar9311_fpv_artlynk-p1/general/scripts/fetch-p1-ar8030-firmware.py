#!/usr/bin/env python3
"""
This device's BR2_PACKAGE_AR8030_FIRMWARE_FETCH_SCRIPT (see
package/ar8030/Config.in for the contract): copies the stock P1 AR8030
baseband image, extracted by package/artlynk-p1-vendor-firmware (named as
this device's BR2_PACKAGE_AR8030_FIRMWARE_FETCH_DEPENDENCY, so it has
already run), into the directory AR8030_INSTALL_FIRMWARE reads from.
Never fails the build.
"""
import shutil
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fetch-p1-ar8030-firmware.py <binaries-dir> <out-dir>", file=sys.stderr)
        return 0
    src = Path(sys.argv[1], "artlynk-p1", "ar8030.img")
    if not src.is_file():
        print(f"fetch-p1-ar8030-firmware: {src} not found -- no ar8030.img this build", file=sys.stderr)
        return 0
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, out / "ar8030.img")
    print(f"fetch-p1-ar8030-firmware: copied {src}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
