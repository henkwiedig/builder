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
import zlib
from pathlib import Path

ASW_MAGIC = 0x575341
USRDATA_SUB_IMAGE_INDEX = 4

# Stock's own /usrdata/fpv/boot_ar8030/boot_ar8030.sh picks between several
# fw_name/cfg_name pairs based on a board_type read from an ADC-strapped GPIO
# (fpv_run_by_type.sh), persisted to /usrdata/fpv/fpv_board_type. Confirmed
# live on this project's actual air hardware: that file reads "472", and
# stock's own dmesg firmware-download log shows a 430080-byte transfer --
# exactly bb_demo_sky_cx472.img's size, not the 428544-byte bb_demo_sky_3v3.img
# this used to hardcode. Booting stock and OUR firmware side by side at the
# same channel and physical position (no hardware moved) showed a real gap
# at the identical reported mcs=12/bandwidth=20M -- stock: snr=1406,
# throughput=36688 kbps; ours (3v3 firmware+config on cx472 hardware):
# snr=722, throughput=25933 kbps -- with everything else (RF chip firmware
# ioctl surface, JSON schema, channel, distance) ruled out first. cx472 also
# needs bb_config_sky_cx472.json (see package/ar8030/files/.../ar8030.json,
# a static copy, not fetched here) instead of the generic bb_config_sky.json
# -- board_ver is hardcoded to 16 (v1.0) in every stock run script that
# reaches this board type, so it's cx472.json, not the _v11 variant.
VENDOR_FIRMWARE_IMG = "bb_demo_sky_cx472.img"
VENDOR_SENSOR_GLOB = "cam_os02k10_*.bin"

# Colortrans variants of the sensor set: every stock .bin also gets a
# <name>_colortrans.bin whose ISP gamma LUT is squeezed into
# 0.15 + g(x) / 2.5, the exact inverse of what PixelPilot's live colortrans
# (--live-colortrans, gain 2.5 / offset -0.15) applies on the ground as a
# per-channel RGB gamma LUT. Low-contrast video costs the encoder fewer bits,
# so it holds its bitrate target better on a bad link. Applied on the gamma
# LUT (RGB) rather than the CSC, the round trip is exact up to quantization.
#
# Layout of these HiSilicon PQTools .bin files (all 24 CADDX ones, confirmed
# against a live ss_mpi_isp_get_gamma_attr() and a waybeam export_bin):
# three sections, each followed by the CRC32 of its bytes --
# [4, 131092), [131096, 139304), [139308, 143420) -- and the 1025-node
# u16 gamma LUT at offset 25880, inside the first.
COLORTRANS_GAIN = 2.5
COLORTRANS_OFFSET = 0.15
PQ_BIN_SIZE = 144774
PQ_GAMMA_OFFSET = 25880
PQ_GAMMA_NODES = 1025
PQ_CRC_SECTIONS = ((4, 131092), (131096, 139304), (139308, 143420))


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


def colortrans_bin(data: bytes) -> bytes:
    """Stock PQ .bin -> colortrans variant (see COLORTRANS_GAIN above)."""
    if len(data) != PQ_BIN_SIZE:
        raise ValueError(f"size {len(data)}, expected {PQ_BIN_SIZE}")
    for start, end in PQ_CRC_SECTIONS:
        if zlib.crc32(data[start:end]) != struct.unpack_from("<I", data, end)[0]:
            raise ValueError(f"CRC mismatch on section [{start}, {end})")
    lut = struct.unpack_from(f"<{PQ_GAMMA_NODES}H", data, PQ_GAMMA_OFFSET)
    if lut[0] != 0 or lut[-1] != 4095 or any(a > b for a, b in zip(lut, lut[1:])):
        raise ValueError("no gamma LUT at the expected offset")
    out = bytearray(data)
    squeezed = [min(4095, round((v / 4095 / COLORTRANS_GAIN + COLORTRANS_OFFSET) * 4095)) for v in lut]
    struct.pack_into(f"<{PQ_GAMMA_NODES}H", out, PQ_GAMMA_OFFSET, *squeezed)
    start, end = next(s for s in PQ_CRC_SECTIONS if s[0] <= PQ_GAMMA_OFFSET < s[1])
    struct.pack_into("<I", out, end, zlib.crc32(out[start:end]))
    return bytes(out)


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
            n_ct = 0
            for f in sensor_files:
                shutil.copyfile(f, sensors_out / f.name)
                try:
                    ct = colortrans_bin(f.read_bytes())
                except ValueError as e:
                    warn(f"{f.name}: no colortrans variant ({e})")
                    continue
                (sensors_out / f"{f.stem}_colortrans.bin").write_bytes(ct)
                n_ct += 1
            print(f"ascent-vendor-firmware: wrote {len(sensor_files)} sensor tuning file(s) "
                  f"+ {n_ct} colortrans variant(s) to {sensors_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
