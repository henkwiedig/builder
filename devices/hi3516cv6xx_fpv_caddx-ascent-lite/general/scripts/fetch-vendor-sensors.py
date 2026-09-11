#!/usr/bin/env python3
"""
This device's BR2_PACKAGE_WAYBEAM_SENSOR_FETCH_SCRIPT (set in this
device's defconfig; see package/waybeam/Config.in for the generic
contract package/waybeam/waybeam.mk's WAYBEAM_PRE_BUILD_HOOKS calls this
under) -- copies the os02k10 camera tuning set into this package's own
build dir, for its INSTALL_TARGET_CMDS to install into /etc/sensors.

Thin on purpose: the actual fetch+extract of CADDX's vendor firmware
happens once, shared with ar8030, in the ascent-vendor-firmware package
(package/ascent-vendor-firmware/extract.py), which writes the sensor set
straight into BINARIES_DIR/sensors/ -- this device's defconfig also sets
BR2_PACKAGE_WAYBEAM_SENSOR_FETCH_DEPENDENCY="ascent-vendor-firmware" so
Buildroot's own scheduler guarantees that package has already built (and
so BINARIES_DIR/sensors/ already exists) by the time this runs.
"""

import shutil
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: fetch-vendor-sensors.py <binaries-dir> <out-dir>", file=sys.stderr)
        return 0

    binaries_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])

    src_dir = binaries_dir / "sensors"
    if not src_dir.is_dir() or not any(src_dir.iterdir()):
        print(f"fetch-vendor-sensors: {src_dir} empty or missing (ascent-vendor-firmware "
              f"fetch failed this build?) -- no sensor tuning this build", file=sys.stderr)
        return 0

    out_dir.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(src_dir.glob("*.bin")):
        shutil.copyfile(f, out_dir / f.name)
        n += 1
    print(f"fetch-vendor-sensors: copied {n} sensor tuning file(s) to {out_dir} from {src_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
