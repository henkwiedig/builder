#!/bin/bash
#
# Fetch the stock CADDX "Ascent H Sky" OTA image and cache it locally, so
# pack-caddx-ascent.py has something to slice boot_image.bin/nand_env.bin
# out of. Only the vendor's SPL/U-Boot and env are ever taken from this file
# (see pack-caddx-ascent.py's docstring) -- OpenIPC's own kernel/rootfs/
# usrdata replace the rest.
#
# The vendor only publishes this as a ~350MB Google Drive zip bundling all
# four Ascent variants' .img files plus CADDX_PCTool itself
# (Ascent_V<ver>.zip: Ascent_H_Sky_*.img, Ascent_L_Gnd_*.img,
# Ascent_G_Gnd_*.img, Ascent_VRX_Pro_*.img, CADDX_PCTool_*_win_Setup.exe) --
# this downloads the whole zip and extracts just the H_Sky (air unit) image
# we need, then discards the rest.
#
# Google Drive has no stable API for this; a file this size always serves a
# "can't scan this file for viruses" interstitial first, which this script
# walks through the same way every other gdrive-wget/curl snippet does
# (grab the id/confirm/uuid hidden form fields, then GET
# drive.usercontent.google.com/download with them). If Google changes that
# page again, this will start failing -- download the zip by hand from
# DRIVE_URL below, extract the H_Sky .img, and pass it directly to
# pack-caddx-ascent.py via --vendor-img instead.

set -euo pipefail

# Overridable via the environment -- package/ascent-vendor-firmware owns
# the canonical value (ASCENT_VENDOR_FIRMWARE_VENDOR_FILE_ID in its .mk)
# and passes it through extract.py; this default is only for standalone/
# manual use (e.g. running this script by hand ahead of pack-caddx-
# ascent.py) and pack-caddx-ascent-hook.sh, which doesn't set it either.
FILE_ID="${FILE_ID:-1_IXl5OaJPVny78kg80CSn3FpWzYXQg3U}"
DRIVE_URL="https://drive.google.com/file/d/${FILE_ID}/view"

OUT="${1:?usage: fetch-vendor-img.sh <output-path>}"

if [ -s "$OUT" ]; then
    echo "Using cached vendor image: $OUT"
    exit 0
fi

fail() {
    echo "$1" >&2
    echo "Google Drive's download page probably changed -- download the zip by hand from:" >&2
    echo "  $DRIVE_URL" >&2
    echo "extract the Ascent_H_Sky_*.img inside, and pass it directly via" >&2
    echo "pack-caddx-ascent.py --vendor-img." >&2
    exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
COOKIES="$WORK/cookies.txt"
INTERSTITIAL="$WORK/interstitial.html"
ZIP="$WORK/vendor.zip"

curl -sL --cookie-jar "$COOKIES" \
    "https://drive.google.com/uc?export=download&id=${FILE_ID}" \
    -o "$INTERSTITIAL"

UUID=$(grep -o 'name="uuid" value="[^"]*"' "$INTERSTITIAL" | sed -E 's/.*value="([^"]*)"/\1/')
[ -n "$UUID" ] || fail "Could not find the download confirmation token."

curl -sL --cookie "$COOKIES" \
    "https://drive.usercontent.google.com/download?id=${FILE_ID}&export=download&confirm=t&uuid=${UUID}" \
    -o "$ZIP"

unzip -l "$ZIP" >/dev/null 2>&1 || fail "Downloaded file isn't a valid zip."

IMG_ENTRY=$(unzip -Z1 "$ZIP" | grep -m1 '/Ascent_H_Sky_.*\.img$') \
    || fail "No Ascent_H_Sky_*.img found inside the downloaded zip."

mkdir -p "$WORK/extracted" "$(dirname "$OUT")"
unzip -j -o "$ZIP" "$IMG_ENTRY" -d "$WORK/extracted"

EXTRACTED="$WORK/extracted/$(basename "$IMG_ENTRY")"
MAGIC=$(head -c4 "$EXTRACTED" | od -An -tx1 | tr -d ' \n')
[ "$MAGIC" = "41535700" ] || fail "Extracted file has bad magic (${MAGIC:-empty}), not an ASW image."

mv "$EXTRACTED" "$OUT"
echo "Downloaded vendor image to: $OUT"
