#!/bin/bash
#
# OpenIPC | version 2025.02.09
# A simple script for quick and complete recompilation of a package
#
# Usage: ./package.sh [package] [device]
# The firmware tree is openipc-<device>/ (see builder.sh). Without a device,
# the only openipc-*/ tree is used, falling back to a legacy ./openipc.

LANG=C
PACKAGE="${1:-busybox}"
DEVICE="$2"

if [ -n "$DEVICE" ]; then
    FIRMWARE_DIR="openipc-${DEVICE}"
else
    TREES=$(ls -d openipc-*/ 2>/dev/null)
    if [ $(echo "$TREES" | grep -c .) -eq 1 ]; then
        FIRMWARE_DIR="${TREES%/}"
    elif [ -z "$TREES" ] && [ -d openipc ]; then
        FIRMWARE_DIR=openipc
    else
        echo "Several firmware trees, name the device: $0 $PACKAGE <device>"
        echo "$TREES"
        exit 1
    fi
fi
[ -d "$FIRMWARE_DIR/output" ] || { echo "No build in $FIRMWARE_DIR"; exit 1; }

rm -rfv \
    ${FIRMWARE_DIR}/output/per-package/${PACKAGE} \
    ${FIRMWARE_DIR}/output/build/${PACKAGE}*

make -C ${FIRMWARE_DIR}/output ${PACKAGE}-{dirclean,rebuild}

exit 0
