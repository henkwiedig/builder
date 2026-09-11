#!/usr/bin/env python3
"""
This device's BR2_PACKAGE_AR8030_FIRMWARE_FETCH_SCRIPT (set in this
device's defconfig; see package/ar8030/Config.in for the generic contract
package/ar8030/ar8030.mk's AR8030_PRE_BUILD_HOOKS calls this under).

Thin on purpose: the actual fetch+extract of CADDX's vendor firmware
happens once, shared with waybeam, in the ascent-vendor-firmware package
(package/ascent-vendor-firmware/extract.py), which writes ar8030.img
straight into BINARIES_DIR -- this device's defconfig also sets
BR2_PACKAGE_AR8030_FIRMWARE_FETCH_DEPENDENCY="ascent-vendor-firmware" so
Buildroot's own scheduler guarantees that package has already built (and
so BINARIES_DIR/ar8030.img already exists) by the time this runs. This
just copies it into the directory AR8030_INSTALL_FIRMWARE reads from.
"""

import shutil
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fetch-vendor-firmware.py <binaries-dir> <out-dir>", file=sys.stderr)
        return 0

    binaries_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])

    src = binaries_dir / "ar8030.img"
    if not src.is_file():
        print(f"fetch-vendor-firmware: {src} not found (ascent-vendor-firmware fetch "
              f"failed this build?) -- no ar8030.img this build", file=sys.stderr)
        return 0

    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, out_dir / "ar8030.img")
    print(f"fetch-vendor-firmware: copied {out_dir}/ar8030.img from {binaries_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
