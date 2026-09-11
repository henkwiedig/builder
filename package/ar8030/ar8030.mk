################################################################################
#
# ar8030
#
################################################################################

# No releases and no tags upstream, so pin the commit. The tarball name is
# derived from this, which also keeps the CI BR2_DL_DIR cache honest (see the
# "moving-ref cache caveat" in ../../CLAUDE.md).
AR8030_VERSION = 3bb948de118b94d2ede751d55f1b28b7e0b9ab62
AR8030_SITE = https://git.topxgun.com/czdu/yz_host_drv.git
AR8030_SITE_METHOD = git
AR8030_LICENSE = GPL-2.0 (kernel driver), PROPRIETARY (host SDK)
AR8030_INSTALL_STAGING = YES

# bb_pair (0006-*.patch) links libcjson via pkg-config to persist a paired
# peer into the on-disk baseband config; nothing else in this package needs it.
AR8030_DEPENDENCIES = $(if $(BR2_PACKAGE_AR8030_PAIR_TOOL),cjson) \
	$(if $(BR2_PACKAGE_AR8030_FIRMWARE),$(call qstrip,$(BR2_PACKAGE_AR8030_FIRMWARE_FETCH_DEPENDENCY)))

AR8030_VENDOR_FETCH_SCRIPT = $(call qstrip,$(BR2_PACKAGE_AR8030_FIRMWARE_FETCH_SCRIPT))
ifneq ($(AR8030_VENDOR_FETCH_SCRIPT),)
# Runs the device-configured fetch script (BR2_PACKAGE_AR8030_FIRMWARE_
# FETCH_SCRIPT, set in the device's own defconfig -- see this package's
# Config.in) before the package builds, so it can populate $(@D)/
# vendor-firmware/ with this board's own ar8030.img -- see that Config.in
# entry for the full contract and devices/hi3516cv6xx_fpv_caddx-ascent-
# lite/general/scripts/fetch-vendor-firmware.py for a worked example.
# Deliberately not this package's own concern: a different AR8030 board
# sources this from a different vendor in a different format, and
# $(BINARIES_DIR) is the one stable way such a script finds the
# long-lived builder checkout from inside a build recipe -- $(TOPDIR) is
# NOT stable enough (it's the extracted *buildroot source* directory,
# whose depth relative to the checkout root isn't a build-system-wide
# invariant the way $(BINARIES_DIR) is; got this wrong once already).
#
# BR2_PACKAGE_AR8030_FIRMWARE_FETCH_DEPENDENCY above (also device-set,
# also optional) is what actually gets this fetch script's own
# dependencies -- e.g. a package that does the real vendor download --
# built before this hook runs, with a genuine Buildroot-scheduler
# guarantee. But the fetch script can still legitimately produce nothing
# (no network, an upstream format change), in which case
# AR8030_INSTALL_FIRMWARE below just installs without ar8030.img rather
# than failing the build.
define AR8030_FETCH_VENDOR_FIRMWARE
	$(BR2_EXTERNAL)/$(AR8030_VENDOR_FETCH_SCRIPT) $(BINARIES_DIR) $(@D)/vendor-firmware
endef
AR8030_PRE_BUILD_HOOKS += AR8030_FETCH_VENDOR_FIRMWARE
endif

#
# Kernel driver (driver/linux, out-of-tree, built by the kernel's own kbuild).
#
# The vendor Makefile pulls its per-bus switches out of driver/linux/config.mk,
# which hardcodes both buses to y. Passing them on the command line overrides
# that (command-line variables beat file assignments, and make propagates them
# to the kbuild sub-make). DRV_DIR is what the KERNELRELEASE branch of that
# Makefile uses to find config.mk and its own -I paths; nothing sets it when
# kbuild is entered directly the way buildroot does.
#
AR8030_MODULE_SUBDIRS = driver/linux

AR8030_MODULE_MAKE_OPTS = \
	DRV_DIR=$(@D)/driver/linux \
	CONFIG_BUS_USB=$(if $(BR2_PACKAGE_AR8030_BUS_SDIO_ONLY),n,y) \
	CONFIG_BUS_SDIO=$(if $(BR2_PACKAGE_AR8030_BUS_USB_ONLY),n,y)

# Everything the driver links against has to be built *in*, not modular. This
# kernel's Module.symvers carries vmlinux exports only, so a symbol coming from
# a =m subsystem cannot be resolved: artosyn_drv.ko then links with e.g.
# request_firmware/release_firmware undefined — modpost only warns — and the
# failure surfaces much later as an insmod-time "Unknown symbol".
# hi3516cv6xx ships CONFIG_FW_LOADER=m, which hits exactly that.
#
# KCONFIG_ENABLE_OPT is not enough here: it treats an existing =m as already
# enabled and leaves it alone. KCONFIG_SET_OPT forces the value.
define AR8030_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_SET_OPT,CONFIG_FW_LOADER,y)
	$(call KCONFIG_SET_OPT,CONFIG_PROC_FS,y)
	$(call KCONFIG_SET_OPT,CONFIG_NET,y)
	$(if $(BR2_PACKAGE_AR8030_BUS_SDIO_ONLY),,$(call KCONFIG_SET_OPT,CONFIG_USB,y))
	$(if $(BR2_PACKAGE_AR8030_BUS_USB_ONLY),,$(call KCONFIG_SET_OPT,CONFIG_MMC,y))
endef

#
# Userspace (CMake).
#
# USING_8030DRV is the driver-backed transport: the daemon reaches the chip
# through /dev/ar_mdev<N> (created by our out-of-tree kernel driver, built
# above) via oal_mdev.c's per-write-skb-allocation/multiplexing-for-8-devices
# architecture -- confirmed on real hardware to plateau around 5-7Mbps
# regardless of link bandwidth/MCS. USING_8030SDIO is daemon/main.c's
# INTF_TYPE_SDIO path: it opens /dev/artosyn_sdio directly
# (daemon/dev8030/sdio8030/sdio_dev.c) and expects a much thinner kernel
# interface -- open/poll/read/write, no multiplexing -- to do all SDIO bus
# handling. This used to require the vendor's own closed artosyn_sdio.ko;
# 0011-sdio-add-direct-artosyn_sdio-chardev.patch (see driver/linux/bus/
# sdio.c) implements that same /dev/artosyn_sdio interface directly in our
# own driver instead, on top of the SDIO bus code this package already
# builds -- confirmed with the vendor's own daemon/artosyn_sdio.ko as a
# proof of concept to reach ~18Mbps unmodified. Both DEV_8030_DRV and
# DEV_8030_SDIO compile into the same daemon binary (main.c's reg_8030_dev()
# gates each behind its own #ifdef, not an #elif) -- runtime -i selects
# between them (3=drv, 1=sdio), so enabling SDIO here doesn't remove the
# DRV fallback. USING_8030USB/UART stay off -- alternatives to the driver
# entirely, not related to this choice (0001-* teaches the CMakeLists that
# DRV/SDIO without USB/UART is a valid choice; upstream rejects it).
#
# OpenIPC's rootfs_script.sh deletes /usr/lib/libstdc++* on musl builds, so the
# handful of C++ tools have to carry it statically. Buildroot's toolchainfile
# only defaults CMAKE_EXE_LINKER_FLAGS when it is not already defined, and
# CONF_OPTS is appended last, so setting it here is safe.
#
AR8030_CONF_OPTS = \
	-DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++" \
	-DUSING_8030DRV=ON \
	-DUSING_8030USB=OFF \
	-DUSING_8030SDIO=ON \
	-DUSING_8030UART=OFF \
	-DUSING_XDS_HDR=ON \
	-DENABLE_UDS=ON \
	-DENABLE_PYTHON=OFF \
	-DENABLE_JAVA=OFF \
	-DDAEMON_STATIC_LIB=OFF \
	-DAPP_STATIC_LIB=OFF \
	-DBUILD_ARTOSYN_EXAMPLE=OFF \
	-DBUILD_RAM_INIT=OFF \
	-DBUILD_TUNTAP=OFF \
	-DBUILD_BW_UPDATE_DEMO=OFF \
	-DBUILD_IMG_UPGRADE=OFF \
	-DBUILD_XDATA_TEST=OFF \
	-DBUILD_REPEATER_TEST=OFF \
	-DBUILD_BB_TEST=OFF \
	-DBUILD_WORK_MODE_CFG=OFF \
	-DBUILD_UART_CFG_TEST=OFF \
	-DBUILD_BB_PAIR=$(if $(BR2_PACKAGE_AR8030_PAIR_TOOL),ON,OFF) \
	-DBUILD_USB_TEST_TOOL=$(if $(BR2_PACKAGE_AR8030_USB_LOADER),ON,OFF) \
	-DBUILD_CMD_DBG=$(if $(BR2_PACKAGE_AR8030_TOOLS),ON,OFF) \
	-DBUILD_OTA_UPGRADE=$(if $(BR2_PACKAGE_AR8030_TOOLS),ON,OFF) \
	-DBUILD_TEST_APP=$(if $(BR2_PACKAGE_AR8030_TOOLS),ON,OFF) \
	-DBUILD_NET_DEV_DEMO=$(if $(BR2_PACKAGE_AR8030_TOOLS),ON,OFF)

# Upstream's install rules scatter binaries over bin/ and a dev_helper/ prefix
# and call them "daemon", "app" and "ota", so pick the artifacts out of the
# build tree by hand instead.
define AR8030_INSTALL_STAGING_CMDS
	$(INSTALL) -d -m 0755 $(STAGING_DIR)/usr/include/ar8030
	$(INSTALL) -m 0644 $(@D)/com/bb_api.h $(@D)/com/bb_config.h \
		$(@D)/com/list.h $(STAGING_DIR)/usr/include/ar8030
	$(INSTALL) -m 0644 $(@D)/app/ar8030/*.h $(STAGING_DIR)/usr/include/ar8030
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/app/ar8030/libar8030_client.so \
		$(STAGING_DIR)/usr/lib/libar8030_client.so
endef

ifeq ($(BR2_PACKAGE_AR8030_PAIR_TOOL),y)
define AR8030_INSTALL_PAIR_TOOL
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/dev_helper/bb_pair/bb_pair \
		$(TARGET_DIR)/usr/bin/ar8030-pair
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_USB_LOADER),y)
define AR8030_INSTALL_USB_LOADER
	$(INSTALL) -D -m 0755 \
		$(AR8030_BUILDDIR)/dev_helper/ar8030_usb_test_tool/ar8030_usb_test_tool \
		$(TARGET_DIR)/usr/bin/ar8030-usb-loader
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_TOOLS),y)
define AR8030_INSTALL_TOOLS
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/dev_helper/cmd_dbg/cmd_dbg \
		$(TARGET_DIR)/usr/bin/ar8030-cmd-dbg
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/dev_helper/ota_upgrade/ota \
		$(TARGET_DIR)/usr/bin/ar8030-ota
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/app/test/app \
		$(TARGET_DIR)/usr/bin/ar8030-test
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/app/net_dev_demo/net_dev_demo \
		$(TARGET_DIR)/usr/bin/ar8030-netdev-demo
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_FIRMWARE),y)
# ar8030.json (plain config) is committed and always installed. ar8030.img
# is an unlicensed vendor binary blob -- not committed -- so it's only
# installed when AR8030_FETCH_VENDOR_FIRMWARE (above) managed to fetch one
# this build; S60ar8030 already omits fw_name= gracefully when it's
# absent. Sensor/camera tuning is NOT this package's concern -- see
# package/waybeam for that, on boards where waybeam is what needs it.
#
# Also archived into $(BINARIES_DIR) (output/images/ar8030.img) alongside
# fitImage/rootfs.ubi/etc, purely for inspection/reuse -- copy_to_archive
# in builder.sh doesn't special-case it, it just rides along with
# everything else under output/images/.
define AR8030_INSTALL_FIRMWARE
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/lib/firmware/ar8030
	$(INSTALL) -m 0644 $(AR8030_PKGDIR)/files/lib/firmware/ar8030/ar8030.json \
		$(TARGET_DIR)/lib/firmware/ar8030
	if [ -f $(@D)/vendor-firmware/ar8030.img ]; then \
		$(INSTALL) -m 0644 $(@D)/vendor-firmware/ar8030.img $(TARGET_DIR)/lib/firmware/ar8030; \
		$(INSTALL) -D -m 0644 $(@D)/vendor-firmware/ar8030.img $(BINARIES_DIR)/ar8030.img; \
	else \
		echo "ar8030: no vendor ar8030.img fetched this build -- baseband will boot without a fw_name=" >&2; \
	fi
endef
endif

ifeq ($(BR2_PACKAGE_AR8030_INIT),y)
define AR8030_INSTALL_INIT
	$(INSTALL) -D -m 0755 $(AR8030_PKGDIR)/files/etc/init.d/S60ar8030 \
		$(TARGET_DIR)/etc/init.d/S60ar8030
endef
endif

define AR8030_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/app/ar8030/libar8030_client.so \
		$(TARGET_DIR)/usr/lib/libar8030_client.so
	$(INSTALL) -D -m 0755 $(AR8030_BUILDDIR)/daemon/daemon \
		$(TARGET_DIR)/usr/bin/ar8030d
	$(AR8030_INSTALL_PAIR_TOOL)
	$(AR8030_INSTALL_USB_LOADER)
	$(AR8030_INSTALL_TOOLS)
	$(AR8030_INSTALL_FIRMWARE)
	$(AR8030_INSTALL_INIT)
	$(INSTALL) -D -m 0644 $(AR8030_PKGDIR)/files/etc/network/interfaces.d/ar_net0 \
		$(TARGET_DIR)/etc/network/interfaces.d/ar_net0
endef

$(eval $(kernel-module))
$(eval $(cmake-package))
