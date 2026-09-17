#!/bin/sh
# Post-image hook (BR2_ROOTFS_POST_IMAGE_SCRIPT): builds the blank,
# pre-formatted UBI image for this board's usrdata0/usrdata1 partitions
# (32MiB each, one per A/B bank), used as the /overlay writable store by
# general/overlay/init's mount_usrdata_overlay(). Runs on every build,
# alongside board/hi3516cv6xx/post-image.sh, and drops
# $BINARIES_DIR/usrdata.ubi next to rootfs.ubi/fitImage — flash the same
# file to both usrdata0 and usrdata1 (it's bank-agnostic).
#
# This has to ship pre-formatted rather than being formatted at first
# boot: the rootfs carries busybox's ubiattach/ubimkvol applets (via
# BR2_TARGET_ROOTFS_UBI) but not mkfs.ubifs — busybox doesn't implement
# it, and it wasn't worth adding the real mtd-utils package just for a
# one-time provisioning step. A raw UBI volume with no UBIFS superblock
# ever written to it fails to mount ("Invalid argument"), so mkfs.ubifs
# has to run somewhere — here, at build time, using the host tool
# Buildroot already built for the rootfs.ubi step.
#
# The image formats a single dynamic volume named "ubifs" — matching both
# this board's own rootfs volume name (see ubinize-hi3516cv6xx.cfg's own
# comment on that) and, empirically, what CADDX's stock usrdata image uses
# too, so a bank never ends up with a usrdata volume general/overlay/init
# doesn't recognize by name (mount_usrdata_overlay() there discovers the
# volume name rather than assuming one, but "ubifs" is what it creates from
# nothing, so producing the same name here means a fresh OpenIPC-only ASW
# flash and a stock CADDX one leave the exact same thing behind). Minimally
# sized (mkfs.ubifs needs ~14 LEBs / 1.7MiB even for an empty filesystem),
# with autoresize so it grows to fill whatever's actually free on the 32MiB
# partition (bad-block reserve aside) the first time UBI attaches it —
# same pattern as the rootfs_data volume in ubinize-hi3516cv6xx.cfg.

set -e

BINARIES_DIR="$1"
HOST_DIR="${HOST_DIR:-$(dirname "$BINARIES_DIR")/host}"
OUT="${BINARIES_DIR}/usrdata.ubi"

MKFS_UBIFS="${HOST_DIR}/sbin/mkfs.ubifs"
UBINIZE="${HOST_DIR}/sbin/ubinize"
[ -x "$MKFS_UBIFS" ] && [ -x "$UBINIZE" ] || {
	echo "make-usrdata-image: ERROR: $MKFS_UBIFS / $UBINIZE not found" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/empty"

"$MKFS_UBIFS" -d "$WORK/empty" -e 0x1f000 -c 2048 -m 0x800 -x lzo -o "$WORK/data.ubifs"

cat > "$WORK/usrdata.cfg" <<EOF
[data]
mode=ubi
vol_id=0
vol_type=dynamic
vol_name=ubifs
vol_alignment=1
image=$WORK/data.ubifs
vol_flags=autoresize
EOF

"$UBINIZE" -o "$OUT" -m 0x800 -p 0x20000 -s 2048 "$WORK/usrdata.cfg"
echo "make-usrdata-image: wrote $OUT ($(stat -c%s "$OUT") bytes)"
