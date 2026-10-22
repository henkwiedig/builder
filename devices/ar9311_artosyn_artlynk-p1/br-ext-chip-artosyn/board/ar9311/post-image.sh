#!/bin/sh
#
# ar9311_artosyn_artlynk-p1 post-image.
#
# uImage.ar9311: the arm64 Image in the container the stock SPL/U-Boot boot
# (it rejects a raw `booti`), same layout as the stock kernel0/kernel1
# partitions (see MissingLynk's glue/flash/mkkernel.py):
#   64 B OTRA header: "OTRA", +0x0c load address, +0x10 size of what
#        follows padded to 256 B, +0x20 byte sum over it (bootm ignores the
#        sum; it is filled in as in the stock kernel0, for the SPL's flash boot)
#   legacy uImage, comp=lz4, load/entry 0x200a0000
#   LZ4 frame with independent 4 MiB blocks and a content checksum -- the
#        lz4 CLI's defaults with -B7; U-Boot rejects linked blocks
#
# The NAND install: P1_SKY_<release>_OpenIPC_<builder sha>.img, BetaFPV's
# update image layout (scripts/ar9311-image.py) with this build's kernel, dtb
# and rootfs.ubi (ubinize.cfg) in it, which /usr/sbin/sysupgrade flashes into
# the slot not running. The stock SPL boots the active slot itself (Falcon):
# it loads kernelN and dtbN and takes the kernel command line from the dtb,
# rewriting ubi.mtd= to the slot's userapp (17 for userapp0, 18 for userapp1)
# in place, so the number must stay numeric.
# init=/init runs OpenIPC's /init, which puts the rootfs_data overlay over the
# read-only rootfs before /sbin/init. RAM boot is unaffected: U-Boot's bootargs
# replace the dtb's.
#
# No firmware.bin: firmware's repack takes one for a NOR split image
# (uImage + squashfs) now. BR2_TARGET_ROOTFS_UBI stays off for the same
# reason (its repack wants a uImage of at most 4 MiB); rootfs.ubi is built
# here from Buildroot's rootfs.ubifs instead.

set -e
LOAD=0x200a0000
BOARD_DIR=$(dirname "$0")
BOOTARGS="earlycon console=ttyS0,1152000 ubi.mtd=18 root=ubi0:rootfs rootfstype=ubifs ro init=/init"
SOC=ar9311
DTB=proxima-9311-air.dtb

cd "${BINARIES_DIR}"

"${HOST_DIR}/bin/lz4" -B7 -9 -f -q Image Image.lz4
"${HOST_DIR}/bin/mkimage" -A arm64 -O linux -T kernel -C lz4 \
	-a ${LOAD} -e ${LOAD} -n Sirius -d Image.lz4 uImage.lz4 >/dev/null

size=$(stat -c %s uImage.lz4)
padded=$(( (size + 255) / 256 * 256 ))
head -c $((padded - size)) /dev/zero >> uImage.lz4
python3 - ${LOAD} uImage.lz4 <<'PY' > uImage.${SOC}
import struct, sys
load, body = int(sys.argv[1], 0), open(sys.argv[2], "rb").read()
h = bytearray(0x40)
h[0:4] = b"OTRA"
struct.pack_into("<II", h, 0x0c, load, len(body))
struct.pack_into("<I", h, 0x20, sum(body) & 0xFFFFFFFF)
sys.stdout.buffer.write(bytes(h) + body)
PY
rm -f Image.lz4 uImage.lz4

"${HOST_DIR}/bin/fdtput" -t s ${DTB} /chosen bootargs "${BOOTARGS}"

"${HOST_DIR}/sbin/ubinize" -o rootfs.ubi -p 0x20000 -m 2048 -s 2048 \
	"${BOARD_DIR}/ubinize.cfg"

# Against the slot-B partitions. userapp1 holds 360 PEBs; UBI keeps 24 of them
# (see ubinize.cfg), and a bad block takes one more.
check() {
	file=$1 limit=$2
	size=$(stat -c %s "$file")
	echo "- $file: [$((size / 1024))KB/$((limit / 1024))KB]"
	if [ "$size" -gt "$limit" ]; then
		echo "-- does not fit its partition by $((size - limit)) bytes"
		exit 1
	fi
	if [ $((limit - size)) -lt 65536 ]; then
		echo "-- headroom warning: $(((limit - size) / 1024))KB left"
	fi
}
check uImage.${SOC} $((0x600000))
check ${DTB} $((0x60000))
check rootfs.ubi $((336 * 0x20000))

# On the stock image package/artlynk-p1-vendor-firmware used (its path and
# release name in artlynk-p1/stock-image). Best-effort like those blobs:
# without the stock image or python-lzo there is no update image.
BUILDER_DIR=$(cd "${BINARIES_DIR}/../../.." && pwd)
rm -f P1_SKY_*_OpenIPC_*.img
if [ -f artlynk-p1/stock-image ]; then
	sha=$(git -C "${BUILDER_DIR}" rev-parse --short HEAD 2>/dev/null)
	python3 "${BUILDER_DIR}/devices/ar9311_artosyn_artlynk-p1/scripts/ar9311-image.py" pack \
		--base "$(sed -n 1p artlynk-p1/stock-image)" --kernel uImage.${SOC} --dtb ${DTB} \
		--userapp rootfs.ubi --out "$(sed -n 2p artlynk-p1/stock-image)_OpenIPC_${sha:-unknown}.img" ||
		echo "post-image: WARNING: no OpenIPC update image (python-lzo installed?)"
else
	echo "post-image: WARNING: no stock P1 image to build the OpenIPC update image on"
fi
