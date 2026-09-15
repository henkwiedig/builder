#!/bin/sh
# Post-build hook (BR2_ROOTFS_POST_BUILD_SCRIPT): embeds a blank,
# pre-formatted UBIFS image into the rootfs itself, at
# /usr/share/openipc/usrdata-blank.ubifs, so general/overlay/init's
# mount_usrdata_overlay() can self-heal a corrupted or never-provisioned
# usrdataN volume at boot via `ubiupdatevol`, with no network/host
# dependency.
#
# Why this matters here specifically: this board is an FPV air unit —
# normal shutdown IS a power cut (no graceful reboot before landing/crash).
# UBIFS's own journal replay handles most unclean shutdowns, but a write
# torn mid-multi-page can still leave a volume UBIFS can't recover
# ("ubifs_recover_leb: corruption", bad CRC). Without a way to reformat,
# that's a dead overlay and a read-only, completely full rootfs for every
# boot after — unacceptable for a device that power-cuts by design. This
# runs at build time (not first boot) for the same reason
# general/scripts/make-usrdata-image.sh does: the rootfs ships busybox's
# ubiattach/ubimkvol/ubiupdatevol applets, not mkfs.ubifs.
#
# The embedded file is 1.7MiB raw, but it's almost entirely padding (an
# empty UBIFS filesystem), so it costs only a few KiB once compressed into
# the parent rootfs.ubifs (built with -x lzo) — cheap, for not bricking the
# overlay on a routine power cut.
#
# Runs after the general/overlay rsync (Buildroot's target-finalize order),
# so it can't be clobbered by overlay content and needs no overlay/ entry
# of its own.

set -e

TARGET_DIR="$1"
HOST_DIR="${HOST_DIR:-$(dirname "$TARGET_DIR")/host}"

MKFS_UBIFS="${HOST_DIR}/sbin/mkfs.ubifs"
[ -x "$MKFS_UBIFS" ] || {
	echo "embed-usrdata-blank: ERROR: $MKFS_UBIFS not found" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/empty"

mkdir -p "${TARGET_DIR}/usr/share/openipc"
"$MKFS_UBIFS" -d "$WORK/empty" -e 0x1f000 -c 2048 -m 0x800 -x lzo \
	-o "${TARGET_DIR}/usr/share/openipc/usrdata-blank.ubifs"
echo "embed-usrdata-blank: wrote ${TARGET_DIR}/usr/share/openipc/usrdata-blank.ubifs ($(stat -c%s "${TARGET_DIR}/usr/share/openipc/usrdata-blank.ubifs") bytes)"
