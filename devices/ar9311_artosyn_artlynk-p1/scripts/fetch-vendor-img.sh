#!/bin/bash
#
# Fetch BetaFPV's stock P1 SKY OTA image (P1_SKY_v<ver>_*.img, Artosyn
# "OTRA" container) and cache it locally, so package/artlynk-p1-vendor-
# firmware/extract.py has something to take the AR8030/codec/ISP firmware
# and the stock SPL/U-Boot/DDR firmware (for ar9311-usbboot.py) out of.
#
# BetaFPV publishes the image as a plain .img on Google Drive (no zip,
# ~24MB). Files that size usually download directly with confirm=t; if
# Google serves its "can't scan this file for viruses" interstitial
# instead, this walks through it the same way as the Ascent's
# fetch-vendor-img.sh (grab the hidden uuid form field, then GET
# drive.usercontent.google.com/download with it). If Google changes that
# page, this starts failing -- download the image by hand from DRIVE_URL
# below and put it at cache/vendor-images/P1_SKY_*.img (or point
# ARTLYNK_P1_VENDOR_IMG at it).

set -euo pipefail

# Overridable via the environment -- package/artlynk-p1-vendor-firmware
# owns the canonical value (ARTLYNK_P1_VENDOR_FIRMWARE_VENDOR_FILE_ID in its
# .mk) and passes it through extract.py; this default only keeps the script
# runnable by hand. v2.0.5 is the SPL version ar9311-usbboot.py's patches
# were made against.
FILE_ID="${FILE_ID:-1JZ17WKLQK0cysCFlLsHTg7nyBegQhUWG}"
DRIVE_URL="https://drive.google.com/file/d/${FILE_ID}/view"

OUT="${1:?usage: fetch-vendor-img.sh <output-path>}"

if [ -s "$OUT" ]; then
    echo "Using cached vendor image: $OUT"
    exit 0
fi

fail() {
    echo "$1" >&2
    echo "Download the stock image by hand from:" >&2
    echo "  $DRIVE_URL" >&2
    echo "and put it at cache/vendor-images/P1_SKY_*.img (or set ARTLYNK_P1_VENDOR_IMG)." >&2
    exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
COOKIES="$WORK/cookies.txt"
IMG="$WORK/vendor.img"

is_otra() {
    [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "4f545241" ]
}

# direct download first
curl -sL --cookie-jar "$COOKIES" \
    "https://drive.usercontent.google.com/download?id=${FILE_ID}&export=download&confirm=t" \
    -o "$IMG" || true

if ! is_otra "$IMG"; then
    # interstitial page: scrape the uuid and retry
    UUID=$(grep -ao 'name="uuid" value="[^"]*"' "$IMG" | sed -E 's/.*value="([^"]*)"/\1/' || true)
    [ -n "$UUID" ] || fail "Neither the image nor a download confirmation token came back."
    curl -sL --cookie "$COOKIES" \
        "https://drive.usercontent.google.com/download?id=${FILE_ID}&export=download&confirm=t&uuid=${UUID}" \
        -o "$IMG"
fi

is_otra "$IMG" || fail "Downloaded file isn't an OTRA image (magic $(head -c4 "$IMG" | od -An -tx1 | tr -d ' \n'))."

mkdir -p "$(dirname "$OUT")"
mv "$IMG" "$OUT"
echo "Downloaded vendor image to: $OUT"
