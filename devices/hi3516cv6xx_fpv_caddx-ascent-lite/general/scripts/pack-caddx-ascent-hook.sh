#!/bin/sh
# Post-image hook (BR2_ROOTFS_POST_IMAGE_SCRIPT): repacks this build's
# fitImage/rootfs.ubi/usrdata.ubi into the vendor's undocumented "ASW"
# container format, so the stock Windows CADDX_PCTool flasher can write it.
# Listed last in the defconfig's BR2_ROOTFS_POST_IMAGE_SCRIPT, after
# post-image.sh (fitImage) and make-usrdata-image.sh (usrdata.ubi), so all
# three inputs already exist in BINARIES_DIR by the time this runs. Drops
# the result directly into BINARIES_DIR (output/images/), same as
# package/ar8030's fetch-vendor-firmware.py does for ar8030.img/sensors/ --
# builder.sh's copy_to_archive does not pick it up (not asked for), it just
# sits in output/images/ alongside fitImage/rootfs.ubi/etc.
#
# The actual packer and vendor-image fetcher live outside the firmware tree,
# in the builder repo itself (devices/hi3516cv6xx_fpv_caddx-ascent-lite/
# scripts/{pack-caddx-ascent.py,fetch-vendor-img.sh}) rather than here under
# general/scripts/ like this file -- they need a persistent cache directory
# (cache/vendor-images/) that survives builder.sh's `rm -rf openipc` between
# builds, and only the long-lived builder checkout can hold that, not this
# ephemeral firmware clone. This hook locates that checkout from BINARIES_DIR
# (always <builder-repo>/openipc/output/images -- builder.sh clones firmware
# to ./openipc and never overrides O=) and calls out to it. In practice the
# vendor image is often already cached by then: package/ar8030's own
# pre-build fetch (when BR2_PACKAGE_AR8030_FIRMWARE=y) downloads the same
# file earlier in the same build, and fetch-vendor-img.sh is a no-op on a
# warm cache.
#
# Best-effort: a broken Google Drive scrape (see fetch-vendor-img.sh) or a
# missing python3 must not fail the whole device build, so this always
# exits 0 -- Buildroot fails `make` outright on a nonzero post-image script.

BINARIES_DIR="$1"
BUILDER_DIR=$(cd "${BINARIES_DIR}/../../.." && pwd)
DEVICE_SCRIPTS="${BUILDER_DIR}/devices/hi3516cv6xx_fpv_caddx-ascent-lite/scripts"
VENDOR_IMG="${BUILDER_DIR}/cache/vendor-images/Ascent_H_Sky.img"

# The device's own upgrade daemon never inspects a transferred file's bytes
# unless its NAME starts with "Ascent_H_Sky", immediately followed by
# "_<sdk>_<app>_<qa>" matching the currently-installed firmware's version,
# then ".img" (see pack-caddx-ascent.py's module docstring --
# AR_FPV_UPGRADE_SearchImgFile / AR_FPV_UPGARDE_ParseImgNameVersion, found by
# disassembling ar_fpvhs_upgrade after a wrongly-named image polled at
# Percent=0,Status=0 for ~5 minutes and was never even looked at). Confirmed
# on real hardware that anything between the version and ".img" is free-form
# and ignored by the device, so a build identifier goes there. Read sdk/app/qa
# from the same cached vendor image pack-caddx-ascent.py slices
# boot_image.bin/nand_env.bin out of, so this can't drift from what that
# script embeds in the header.
VER=$("${DEVICE_SCRIPTS}/fetch-vendor-img.sh" "$VENDOR_IMG" >&2 && python3 -c "
import struct, sys
_, _, sdk, app, qa = struct.unpack('<IIIII', open(sys.argv[1], 'rb').read(20))
print(f'{sdk}_{app}_{qa}')
" "$VENDOR_IMG" 2>/dev/null)
BUILD_ID=$(git -C "$BUILDER_DIR" rev-parse --short HEAD 2>/dev/null)
OUT="${BINARIES_DIR}/Ascent_H_Sky_${VER:-0_0_0}_OpenIPC_${BUILD_ID:-unknown}.img"

if [ -n "$VER" ] && \
   python3 "${DEVICE_SCRIPTS}/pack-caddx-ascent.py" \
       --vendor-img "$VENDOR_IMG" \
       --kernel "${BINARIES_DIR}/fitImage" \
       --rootfs "${BINARIES_DIR}/rootfs.ubi" \
       --usrdata "${BINARIES_DIR}/usrdata.ubi" \
       -o "$OUT"
then
    echo "pack-caddx-ascent-hook: wrote $OUT"
else
    echo "pack-caddx-ascent-hook: ASW packing failed (see above) -- not yet" >&2
    echo "verified on hardware anyway; flash via the usual OpenIPC method instead." >&2
fi

exit 0
