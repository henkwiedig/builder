#!/bin/bash
#
# fitImage (zImage + this board's DTB) for kernel0/kernel1, which fpvboot
# boots. Firmware's cv6xx post-image.sh and fit-image.its built the same until
# OpenIPC/firmware 97d1c26 moved the family to the split NOR layout; this NAND
# board kept the FIT, so they live here now.
#
# firmware.bin (the FIT, then the squashfs at the next 64 KiB) is nothing this
# board flashes. It is what firmware's repack packages (the -split .tgz CI
# publishes), and the repack measures the FIT at its start against
# BR2_OPENIPC_NOR_KERNEL_READ_SIZE in the defconfig.
set -e

BINARIES_DIR=$1
BOARD_DIR="$(dirname "$0")"
ITS_SOURCE="fit-image.its"

ERASEBLOCK_SIZE=$((64 * 1024))

cp ${BINARIES_DIR}/hi35*.dtb ${BINARIES_DIR}/fdt.dtb
cp ${BOARD_DIR}/${ITS_SOURCE} ${BINARIES_DIR}/
mkimage -f ${BINARIES_DIR}/${ITS_SOURCE} ${BINARIES_DIR}/fitImage

FIT_SIZE=$(stat -c%s "${BINARIES_DIR}/fitImage")
OFFSET_BLOCKS=$(( (FIT_SIZE + ERASEBLOCK_SIZE - 1) / ERASEBLOCK_SIZE ))

cp ${BINARIES_DIR}/fitImage ${BINARIES_DIR}/firmware.bin

dd if=${BINARIES_DIR}/rootfs.squashfs of=${BINARIES_DIR}/firmware.bin \
   bs=${ERASEBLOCK_SIZE} seek=${OFFSET_BLOCKS} conv=notrunc

truncate -s %${ERASEBLOCK_SIZE} ${BINARIES_DIR}/firmware.bin
