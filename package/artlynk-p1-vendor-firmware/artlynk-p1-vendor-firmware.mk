################################################################################
#
# artlynk-p1-vendor-firmware
#
################################################################################

# No upstream source: BUILD_CMDS extracts from the stock P1 SKY image (see
# extract.py) -- a locally supplied one, else fetched from Google Drive into
# cache/vendor-images/ -- same pattern as ascent-vendor-firmware.
ARTLYNK_P1_VENDOR_FIRMWARE_SITE_METHOD = local
ARTLYNK_P1_VENDOR_FIRMWARE_SITE = $(patsubst %/,%,$(ARTLYNK_P1_VENDOR_FIRMWARE_PKGDIR))
ARTLYNK_P1_VENDOR_FIRMWARE_LICENSE = PROPRIETARY (extracts BetaFPV/Artosyn vendor firmware; nothing here is committed)
# unsquashfs for reading the stock rootfs
ARTLYNK_P1_VENDOR_FIRMWARE_DEPENDENCIES = host-squashfs

ARTLYNK_P1_VENDOR_FIRMWARE_OUT = $(BINARIES_DIR)/artlynk-p1

# The stock P1 SKY release the build is based on, and the Google Drive file
# id of BetaFPV's copy (support.betafpv.com, "Firmware for P1 Air Unit HD
# VTX"). extract.py takes cache/vendor-images/<release>.img, which
# devices/ar9311_artosyn_artlynk-p1/scripts/fetch-vendor-img.sh downloads
# when it is missing; the OpenIPC image built in its layout is named after
# it (board/ar9311/post-image.sh). Bumping the vendor release means editing
# these two lines. 2.1.2 has the same SPL and U-Boot code as 2.0.5, which
# ar9311-usbboot.py's patches were made against.
ARTLYNK_P1_VENDOR_FIRMWARE_VENDOR_FILE_ID = 13ZIuxdk9z28mb-lvGbnurUiUTMFCLZlp
ARTLYNK_P1_VENDOR_FIRMWARE_VENDOR_RELEASE = P1_SKY_v2.1.2_20260817_1c34cf1

define ARTLYNK_P1_VENDOR_FIRMWARE_BUILD_CMDS
	python3 $(ARTLYNK_P1_VENDOR_FIRMWARE_PKGDIR)/extract.py $(BINARIES_DIR) $(HOST_DIR) \
		$(ARTLYNK_P1_VENDOR_FIRMWARE_VENDOR_FILE_ID) $(ARTLYNK_P1_VENDOR_FIRMWARE_VENDOR_RELEASE)
endef

define ARTLYNK_P1_VENDOR_FIRMWARE_INSTALL_ONE
	if [ -f $(ARTLYNK_P1_VENDOR_FIRMWARE_OUT)/$(1) ]; then \
		$(INSTALL) -D -m 0644 $(ARTLYNK_P1_VENDOR_FIRMWARE_OUT)/$(1) $(TARGET_DIR)/lib/firmware/$(2); \
	fi
endef

define ARTLYNK_P1_VENDOR_FIRMWARE_INSTALL_TARGET_CMDS
	$(call ARTLYNK_P1_VENDOR_FIRMWARE_INSTALL_ONE,wave521c_k3_codec_fw.bin,cnm/wave521c_k3_codec_fw.bin)
	$(call ARTLYNK_P1_VENDOR_FIRMWARE_INSTALL_ONE,nt99235-tuning-preview-fpv.bin,artosyn/nt99235-tuning-preview-fpv.bin)
	$(call ARTLYNK_P1_VENDOR_FIRMWARE_INSTALL_ONE,bb_config_air.json,ar8030/bb_config_air.json)
endef

$(eval $(generic-package))
