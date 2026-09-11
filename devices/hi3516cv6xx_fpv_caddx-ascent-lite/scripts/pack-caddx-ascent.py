#!/usr/bin/env python3
"""
Pack an OpenIPC build of hi3516cv6xx_fpv_caddx-ascent-lite into the vendor
"ASW" container format so the stock CADDX_PCTool Windows flasher can write it.

Why this works: CADDX_PCTool does not verify a signature over the image (only
a 4-byte magic), and the container is a fixed, 5-slot format keyed by index,
not content. This script builds a byte-identical container shape to the
vendor's own OTA image (verified by round-tripping a real
"Ascent_H_Sky_*.img" back through this same slot layout and diffing byte-for-
byte against the original), substituting OpenIPC's kernel/rootfs/usrdata for
the vendor's own and copying the vendor's boot_image.bin/nand_env.bin
through unchanged.

boot_image.bin (SPL/U-Boot + this exact board's DDR3 timing table) and
nand_env.bin (U-Boot env: mtdparts, bootargs, the vendor's `fpvboot`
bootcmd) are NOT committed to this repo -- they are proprietary vendor
binaries. Point --vendor-img at a stock "Ascent_H_Sky_*.img" you already
downloaded/own (e.g. from the official CADDX release) and this script slices
those two sub-images out of it directly; nothing else from that file is
used.

Format reference (reverse-engineered, not vendor-documented):

    offset 0x00  IMG_HEAD_INFO_EX, 128 bytes
      u32 magic            0x00575341 ("ASW", 3 bytes + NUL, little-endian)
      u32 board_type
      u32 sdk_version
      u32 app_version
      u32 qa_version
      IMG_SUB_IMG_INFO_T subImgInfo[5]   12 bytes each:
        s8  img_type
        s8  upgrade
        s8  dual_part
        s8  reserved
        u32 flash_offset       (vendor bookkeeping; NOT this file's byte
                                 offset -- copied through unchanged)
        u32 sub_img_offset     (this file's byte offset -- recomputed here)
      u8  reserved[40]
      u64 build_time
    offset 0x80  sub-image 0: boot_image.bin
                 sub-image 1: nand_env.bin
                 sub-image 2: uImage           (a FIT image, not legacy uImage
                                                 despite the name -- OpenIPC's
                                                 fitImage drops in directly)
                 sub-image 3: rootfs ubifs
                 sub-image 4: usrdata ubifs
    (no padding/alignment between sub-images or after the header)

CAVEAT -- not yet verified on hardware: this produces a structurally correct
container and boot_image.bin/nand_env.bin are untouched vendor binaries, but
nobody has flashed an OpenIPC-packed image with this tool through the stock
PC tool yet. nand_env.bin's bootargs still say `mem=64m` (vendor's cap, not
this board's real 128MB) and its `fpvboot` bootcmd is the vendor's own --
review devices/hi3516cv6xx_fpv_caddx-ascent-lite before trusting this for
anything you can't recover from a bad flash. The BootROM UART pad (see
ASCENT_LITE_PLUS_RECOVERY.md) is the recovery path if a flash goes wrong.
"""

import argparse
import struct
import sys
import time
from pathlib import Path

MAGIC = 0x575341
HEADER_SIZE = 0x80
SUB_IMAGE_NAMES = [
    "boot_image.bin",
    "nand_env.bin",
    "uImage",
    "rootfs_hi3516cv610_2k_128k_16M.ubifs",
    "rootfs_usrdata_2k_128k_32M.ubifs",
]


def parse_header(data: bytes):
    if len(data) < HEADER_SIZE:
        raise ValueError("truncated header")
    magic, board_type, sdk, app, qa = struct.unpack("<IIIII", data[:20])
    if magic != MAGIC:
        raise ValueError(f"bad magic 0x{magic:x} (expected 0x{MAGIC:x})")
    subs = []
    off = 20
    for _ in range(5):
        t, u, dp, res, fo, sio = struct.unpack("<bbbbII", data[off:off + 12])
        subs.append(dict(type=t, upgrade=u, dual_part=dp, reserved=res,
                          flash_offset=fo, sub_img_offset=sio))
        off += 12
    reserved = data[off:off + 40]
    off += 40
    build_time = struct.unpack("<Q", data[off:off + 8])[0]
    return dict(magic=magic, board_type=board_type, sdk_version=sdk,
                app_version=app, qa_version=qa, subs=subs,
                reserved=reserved, build_time=build_time)


def slice_vendor_boot_and_env(vendor_img: Path):
    """Pull boot_image.bin and nand_env.bin (slots 0/1) out of a real vendor
    OTA image, using its own header to find their exact extents."""
    data = vendor_img.read_bytes()
    hdr = parse_header(data)
    starts = [s["sub_img_offset"] for s in hdr["subs"]]
    boot = data[starts[0]:starts[1]]
    env = data[starts[1]:starts[2]]
    return boot, env, hdr


def build_image(boot_image: bytes, nand_env: bytes, kernel: bytes,
                 rootfs: bytes, usrdata: bytes, vendor_hdr: dict) -> bytes:
    files = [boot_image, nand_env, kernel, rootfs, usrdata]

    offsets = []
    cur = HEADER_SIZE
    for f in files:
        offsets.append(cur)
        cur += len(f)

    out = bytearray()
    out += struct.pack("<IIIII", MAGIC, vendor_hdr["board_type"],
                        vendor_hdr["sdk_version"], vendor_hdr["app_version"],
                        vendor_hdr["qa_version"])
    for i, s in enumerate(vendor_hdr["subs"]):
        out += struct.pack("<bbbbII", s["type"], s["upgrade"], s["dual_part"],
                            s["reserved"], s["flash_offset"], offsets[i])
    out += b"\x00" * 40  # reserved
    out += struct.pack("<Q", int(time.strftime("%Y%m%d%H%M")))
    assert len(out) == HEADER_SIZE

    for f in files:
        out += f

    return bytes(out)


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--vendor-img", required=True, type=Path,
                    help="A stock Ascent_H_Sky_*.img you already own; "
                         "boot_image.bin/nand_env.bin are sliced out of it.")
    p.add_argument("--kernel", required=True, type=Path,
                    help="OpenIPC's output/images/fitImage")
    p.add_argument("--rootfs", required=True, type=Path,
                    help="OpenIPC's output/images/rootfs.ubi")
    p.add_argument("--usrdata", required=True, type=Path,
                    help="OpenIPC's output/images/usrdata.ubi")
    p.add_argument("-o", "--output", required=True, type=Path)
    args = p.parse_args()

    boot_image, nand_env, vendor_hdr = slice_vendor_boot_and_env(args.vendor_img)
    print(f"Sliced boot_image.bin ({len(boot_image)} bytes) and "
          f"nand_env.bin ({len(nand_env)} bytes) from {args.vendor_img.name}")

    kernel = args.kernel.read_bytes()
    rootfs = args.rootfs.read_bytes()
    usrdata = args.usrdata.read_bytes()

    out = build_image(boot_image, nand_env, kernel, rootfs, usrdata, vendor_hdr)
    args.output.write_bytes(out)

    print(f"\nWrote {args.output} ({len(out)} bytes)\n")
    print(f"{'slot':<5}{'name':<40}{'size':>10}")
    names = ["boot_image.bin (vendor)", "nand_env.bin (vendor)",
             "fitImage (OpenIPC)", "rootfs.ubi (OpenIPC)",
             "usrdata.ubi (OpenIPC)"]
    for i, (name, f) in enumerate(zip(names, [boot_image, nand_env, kernel,
                                               rootfs, usrdata])):
        print(f"{i:<5}{name:<40}{len(f):>10}")

    print("\nNot yet verified on hardware -- see the caveat in this script's "
          "module docstring before flashing a device you can't recover.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
