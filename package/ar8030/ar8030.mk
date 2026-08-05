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
# USING_8030DRV alone is the driver-backed transport: the daemon reaches the
# chip through /dev/ar_mdev<N> instead of driving USB itself with libusb. The
# other USING_* backends are alternatives to the kernel driver, not additions
# to it, so they stay off (0001-* teaches the CMakeLists that DRV on its own
# is a valid choice; upstream rejects it).
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
	-DUSING_8030SDIO=OFF \
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
define AR8030_INSTALL_FIRMWARE
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/lib/firmware/ar8030
	$(INSTALL) -m 0644 $(@D)/dev_helper/autoload/img/bb_demo.img \
		$(@D)/dev_helper/autoload/img/bb_config.json \
		$(@D)/dev_helper/autoload/img/usr_ap.json \
		$(@D)/dev_helper/autoload/img/usr_dev.json \
		$(@D)/dev_helper/autoload/img/usr_master.json \
		$(@D)/dev_helper/autoload/img/usr_slave.json \
		$(TARGET_DIR)/lib/firmware/ar8030
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
endef

$(eval $(kernel-module))
$(eval $(cmake-package))
