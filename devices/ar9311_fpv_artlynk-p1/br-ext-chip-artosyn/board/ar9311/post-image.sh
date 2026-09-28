#!/bin/sh
#
# ar9311_fpv_artlynk-p1 post-image.
#
# uImage.ar9311: the arm64 Image in the container the stock SPL/U-Boot boot
# (it rejects a raw `booti`), same layout as the stock kernel0/kernel1
# partitions (see MissingLynk's glue/flash/mkkernel.py):
#   64 B OTRA header: "OTRA", +0x0c load address, +0x10 size of what
#        follows padded to 256 B (+0x20 checksum: not checked by bootm)
#   legacy uImage, comp=lz4, load/entry 0x200a0000
#   LZ4 frame with independent 4 MiB blocks and a content checksum -- the
#        lz4 CLI's defaults with -B7; U-Boot rejects linked blocks
#
# firmware.bin: rootfs.ubi (for the "userapp" partition). The firmware
# Makefile's repack step size-checks firmware.bin when a board produces
# one; its generic UBI branch would size-check a 4 MiB uImage instead.

set -e
LOAD=0x200a0000

cd "${BINARIES_DIR}"

"${HOST_DIR}/bin/lz4" -B7 -9 -f -q Image Image.lz4
"${HOST_DIR}/bin/mkimage" -A arm64 -O linux -T kernel -C lz4 \
	-a ${LOAD} -e ${LOAD} -n Sirius -d Image.lz4 uImage.lz4 >/dev/null

size=$(stat -c %s uImage.lz4)
padded=$(( (size + 255) / 256 * 256 ))
python3 - "$padded" ${LOAD} <<'PY' > uImage.ar9311
import struct, sys
padded, load = int(sys.argv[1]), int(sys.argv[2], 0)
h = bytearray(0x40)
h[0:4] = b"OTRA"
struct.pack_into("<II", h, 0x0c, load, padded)
sys.stdout.buffer.write(bytes(h))
PY
cat uImage.lz4 >> uImage.ar9311
head -c $((padded - size)) /dev/zero >> uImage.ar9311
rm -f Image.lz4 uImage.lz4

cp rootfs.ubi firmware.bin
