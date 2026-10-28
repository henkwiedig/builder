#!/bin/sh
# Post-image hook (BR2_ROOTFS_POST_IMAGE_SCRIPT): wraps Buildroot's
# rootfs.ubifs into rootfs.ubi for this board's rootfs0/rootfs1 partitions,
# the same ubinize run Buildroot's fs/ubi does with the options this board
# used to set (BR2_TARGET_ROOTFS_UBI, SUBSIZE 2048, the custom
# ubinize-hi3516cv6xx.cfg).
#
# Done here rather than by BR2_TARGET_ROOTFS_UBI because firmware's repack
# (OpenIPC/firmware f4b87e7, "a NOR+NAND build packages its NAND image") now
# packages a NAND tgz for every UBI build whose family has no nand-fit.its,
# and that package is a uImage plus rootfs.ubi. This board boots a FIT and
# has no uImage, so the repack failed ("stat: cannot statx ... uImage", CI
# run 40649240952), and it would rename rootfs.ubi to rootfs.ubi.<soc> under
# the pack hook and usbburn.py --images besides. Nothing else reads the
# option: rootfs_script.sh only acts on it with a nand-fit.its, which this
# board deliberately doesn't name its .its.

set -e

BINARIES_DIR="$1"
HOST_DIR="${HOST_DIR:-$(dirname "$BINARIES_DIR")/host}"
CFG="$(dirname "$0")/ubifs/ubinize-hi3516cv6xx.cfg"
OUT="${BINARIES_DIR}/rootfs.ubi"

UBINIZE="${HOST_DIR}/sbin/ubinize"
[ -x "$UBINIZE" ] || {
	echo "make-rootfs-ubi: ERROR: $UBINIZE not found" >&2
	exit 1
}
[ -f "${BINARIES_DIR}/rootfs.ubifs" ] || {
	echo "make-rootfs-ubi: ERROR: ${BINARIES_DIR}/rootfs.ubifs not found" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

sed "s;BR2_ROOTFS_UBIFS_PATH;${BINARIES_DIR}/rootfs.ubifs;;s;BINARIES_DIR;${BINARIES_DIR};" \
	"$CFG" > "$WORK/ubinize.cfg"
"$UBINIZE" -o "$OUT" -m 0x800 -p 0x20000 -s 2048 "$WORK/ubinize.cfg"
echo "make-rootfs-ubi: wrote $OUT ($(stat -c%s "$OUT") bytes)"
