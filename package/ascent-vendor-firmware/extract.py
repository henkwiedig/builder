#!/usr/bin/env python3
"""
BUILD_CMDS for the ascent-vendor-firmware package (see the sibling .mk).
Fetches CADDX's stock "Ascent H Sky" OTA image and extracts everything this
device's other packages need out of it -- ar8030's baseband demo firmware
and waybeam's os02k10 camera tuning set -- ONCE, straight into BINARIES_DIR
(output/images/ar8030.img, output/images/sensors/*.bin), the same directory
fitImage/rootfs.ubi/etc already live in for this build.

Why a whole package just for this: ar8030 and waybeam both need pieces of
the same vendor image, and neither should re-download/re-extract it
independently (slow, and a real chance of two packages racing a `mkdir -p`
on the same temp dir under `-jN`). Making this a real Buildroot package and
having both of those packages list it in their DEPENDENCIES gets a genuine,
scheduler-enforced "runs before, exactly once" guarantee -- unlike
BR2_ROOTFS_PRE_BUILD_SCRIPT, which looks like the obvious tool for this but
turns out to be dead in this project's build (nothing depends on Buildroot's
internal `prepare` target except `sdk`; `openipc/Makefile`'s `build:` calls
`all` directly, so a script set there would silently never run -- confirmed
via `make -n all` against a real .config, zero mentions of `prepare`).

Only the raw vendor zip/img (fetch-vendor-img.sh's own cache/vendor-images/
Ascent_H_Sky.img) is worth persisting across builds -- it's the genuinely
expensive part (a ~350MB Google Drive fetch). The UBI extraction itself is
fast and this package's BUILD_CMDS only ever runs once per build anyway
(standard Buildroot .stamp_built behavior), so there's no benefit to a
separate persistent cache for the *extracted* ar8030.img/sensor files --
BINARIES_DIR is wiped and regenerated every builder.sh run regardless
(it's under openipc/, which gets `rm -rf`'d), so writing straight there
is simpler than an intermediate cache/vendor-firmware/ that would just get
recomputed just as often.

ar8030's and waybeam's own fetch scripts (devices/hi3516cv6xx_fpv_caddx-
ascent-lite/general/scripts/fetch-vendor-{firmware,sensors}.py) are thin:
they just copy the relevant piece out of BINARIES_DIR into their own
package's $(@D), which is how those packages' respective INSTALL steps
pick them up (this package's own DEPENDENCIES edge guarantees this has
already run by then).

Best-effort throughout: no network, Google Drive's scrape breaking (see
fetch-vendor-img.sh), no `ubireader_extract_files` on PATH -- any failure
here just leaves BINARIES_DIR without whichever artifact couldn't be
produced and prints a warning; it must never fail the build.

`ubireader_extract_files` (reads files out of the raw UBI image) is a
plain host prerequisite here, NOT a Buildroot dependency: install it with
`pip install --user ubi_reader` if you want ar8030.img/sensor tuning
fetched automatically. Deliberately not vendored as a hermetic host-*
package (that would need PyPI's current `ubi_reader` release's
`lzallright`, a Rust pyo3 extension with no existing Buildroot package --
dragging in a full host-rust toolchain for what is otherwise a small
pure-Python tool). Missing it just means this build skips both artifacts.
"""

import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ASW_MAGIC = 0x575341
USRDATA_SUB_IMAGE_INDEX = 4

VENDOR_FIRMWARE_IMG = "bb_demo_sky_3v3.img"
VENDOR_SENSOR_GLOB = "cam_os02k10_*.bin"


def warn(msg: str) -> None:
    print(f"ascent-vendor-firmware: {msg}", file=sys.stderr)


def slice_usrdata(vendor_img: Path) -> bytes:
    data = vendor_img.read_bytes()
    magic = struct.unpack("<I", data[:4])[0]
    if magic != ASW_MAGIC:
        raise ValueError(f"bad ASW magic 0x{magic:x}")
    offsets = []
    off = 20
    for _ in range(5):
        _, _, _, _, _, sub_img_offset = struct.unpack("<bbbbII", data[off:off + 12])
        offsets.append(sub_img_offset)
        off += 12
    start = offsets[USRDATA_SUB_IMAGE_INDEX]
    end = len(data)
    return data[start:end]


def find_one(root: Path, name: str) -> Path:
    matches = list(root.rglob(name))
    if not matches:
        raise FileNotFoundError(name)
    return matches[0]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract.py <binaries-dir> <vendor-file-id>", file=sys.stderr)
        return 0

    # See this file's docstring: BINARIES_DIR (always <builder-repo>/
    # openipc/output/images) is the one stable way to find the long-lived
    # builder checkout from inside a build recipe -- $(TOPDIR) is NOT
    # stable enough (it's the extracted *buildroot source* directory,
    # whose depth relative to the checkout root isn't a build-system-wide
    # invariant).
    binaries_dir = Path(sys.argv[1])
    vendor_file_id = sys.argv[2]
    builder_dir = (binaries_dir / ".." / ".." / "..").resolve()

    device_dir = builder_dir / "devices" / "hi3516cv6xx_fpv_caddx-ascent-lite"
    fetch_script = device_dir / "scripts" / "fetch-vendor-img.sh"
    vendor_img = builder_dir / "cache" / "vendor-images" / "Ascent_H_Sky.img"

    sensors_out = binaries_dir / "sensors"

    ubireader = shutil.which("ubireader_extract_files")
    if ubireader is None:
        warn("ubireader_extract_files not found on PATH (pip install --user ubi_reader)")
        return 0

    try:
        subprocess.run(
            [str(fetch_script), str(vendor_img)],
            check=True, env={**os.environ, "FILE_ID": vendor_file_id},
        )
    except subprocess.CalledProcessError:
        warn("could not fetch the vendor image")
        return 0

    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        try:
            usrdata = slice_usrdata(vendor_img)
        except (ValueError, IndexError, struct.error) as e:
            warn(f"could not parse the vendor image ({e})")
            return 0

        usrdata_path = work / "usrdata.bin"
        usrdata_path.write_bytes(usrdata)

        extracted = work / "extracted"
        try:
            subprocess.run(
                [ubireader, "-o", str(extracted), str(usrdata_path)],
                check=True, capture_output=True, text=True,
            )
        except subprocess.CalledProcessError as e:
            warn(f"ubireader_extract_files failed ({e.stderr.strip()[-200:]})")
            return 0

        binaries_dir.mkdir(parents=True, exist_ok=True)

        try:
            fw_img = find_one(extracted, VENDOR_FIRMWARE_IMG)
        except FileNotFoundError as e:
            warn(f"{e} not found in the extracted usrdata volume -- no ar8030.img this build")
        else:
            shutil.copyfile(fw_img, binaries_dir / "ar8030.img")
            print(f"ascent-vendor-firmware: wrote {binaries_dir}/ar8030.img")

        sensor_files = sorted(extracted.rglob(VENDOR_SENSOR_GLOB))
        if not sensor_files:
            warn(f"no {VENDOR_SENSOR_GLOB} found in the extracted usrdata volume -- no sensor tuning this build")
        else:
            sensors_out.mkdir(parents=True, exist_ok=True)
            for f in sensor_files:
                shutil.copyfile(f, sensors_out / f.name)
            print(f"ascent-vendor-firmware: wrote {len(sensor_files)} sensor tuning file(s) to {sensors_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
