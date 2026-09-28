################################################################################
#
# artlynk-p1-vendor-firmware
#
################################################################################

# No upstream source: BUILD_CMDS extracts from a locally supplied stock
# P1 SKY image (see extract.py), same pattern as ascent-vendor-firmware.
ARTLYNK_P1_VENDOR_FIRMWARE_SITE_METHOD = local
ARTLYNK_P1_VENDOR_FIRMWARE_SITE = $(patsubst %/,%,$(ARTLYNK_P1_VENDOR_FIRMWARE_PKGDIR))
ARTLYNK_P1_VENDOR_FIRMWARE_LICENSE = PROPRIETARY (extracts BetaFPV/Artosyn vendor firmware; nothing here is committed)
# unsquashfs for reading the stock rootfs
ARTLYNK_P1_VENDOR_FIRMWARE_DEPENDENCIES = host-squashfs

ARTLYNK_P1_VENDOR_FIRMWARE_OUT = $(BINARIES_DIR)/artlynk-p1

define ARTLYNK_P1_VENDOR_FIRMWARE_BUILD_CMDS
	python3 $(ARTLYNK_P1_VENDOR_FIRMWARE_PKGDIR)/extract.py $(BINARIES_DIR) $(HOST_DIR)
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
	$(call ARTLYNK_P1_VENDOR_FIRMWARE_INSTALL_ONE,p1_ascent_air.json,ar8030/p1_ascent_air.json)
endef

$(eval $(generic-package))
