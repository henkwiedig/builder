################################################################################
#
# ar8030-transport-tx
#
################################################################################

# ar8030-transport is not pushed yet, so this download will 404 until
# `git push origin master` to https://github.com/henkwiedig/ar8030-transport.
# To build against a working tree instead (no push needed, picks up
# uncommitted edits), same mechanism this project's own waybeam package
# uses (see package/waybeam/waybeam.mk for the general caveats):
#
#   echo 'AR8030_TRANSPORT_TX_OVERRIDE_SRCDIR = /home/henk/Dokumente/fpv/OpenIPC/ar8030-transport' \
#       >> $(O)/local.mk
#
# or as a plain environment variable to builder.sh/make.
AR8030_TRANSPORT_TX_VERSION = 98bc176edc4dded1d1b02122967079b2a28205c1
AR8030_TRANSPORT_TX_SITE = https://github.com/henkwiedig/ar8030-transport.git
AR8030_TRANSPORT_TX_SITE_METHOD = git
AR8030_TRANSPORT_TX_LICENSE = MIT
AR8030_TRANSPORT_TX_LICENSE_FILES = LICENSE

# Needs the ar8030 package's already-built libar8030_client.so + headers
# (staged to $(STAGING_DIR)/usr/include/ar8030 and .../usr/lib -- see
# package/ar8030/ar8030.mk's AR8030_INSTALL_STAGING_CMDS) and its 0008
# datagram-mode-symmetry patch (see this package's Config.in help).
# cjson: lifecycled/ (pairing/tuning persistence, lifecycle_pair.c/
# lifecycle_tuning.c) links it directly, same as ar8030's own bb_pair.
AR8030_TRANSPORT_TX_DEPENDENCIES = ar8030 cjson

# tx/Makefile is a standalone Makefile (also usable outside Buildroot --
# see ar8030-transport's own README), so this just invokes it with the
# cross compiler and the ar8030 package's staging paths instead of
# folding the build into Buildroot's own machinery. linkctl/ and
# lifecycled/ (see their own README sections) are built the same way --
# neither is tied to tx specifically, but this package is the natural
# place to build+install the air-side copies since it already stages
# against this same ar8030 dependency.
#
# `make clean` before each: when built via AR8030_TRANSPORT_TX_OVERRIDE_
# SRCDIR (see this file's header comment), $(@D) is an `rsync -au` copy of
# the *live* ar8030-transport working tree, mtimes preserved -- and that
# same tree is also the OVERRIDE_SRCDIR for sbc-groundstations' ar8030-
# transport-rx package (AArch64 groundstation, a different repo), built
# from the same linkctl/lifecycled directories with the same default
# build/ and ar8030-linkctl/ar8030-lifecycled output names. Without a
# clean first, a binary/object left over from whichever side built more
# recently rsyncs in looking newer than its .c source, and Make silently
# reuses it unrebuilt for the wrong architecture -- confirmed: an
# AArch64 ar8030-linkctl survived into an ARM build this way and failed
# Buildroot's post-install arch check.
define AR8030_TRANSPORT_TX_BUILD_CMDS
	$(MAKE) -C $(@D)/tx clean
	$(MAKE) -C $(@D)/tx \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		AR8030_SDK_INC=$(STAGING_DIR)/usr/include/ar8030 \
		AR8030_SDK_LIB=$(STAGING_DIR)/usr/lib
	$(MAKE) -C $(@D)/linkctl clean
	$(MAKE) -C $(@D)/linkctl \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		AR8030_SDK_INC=$(STAGING_DIR)/usr/include/ar8030 \
		AR8030_SDK_LIB=$(STAGING_DIR)/usr/lib
	$(MAKE) -C $(@D)/lifecycled clean
	$(MAKE) -C $(@D)/lifecycled \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		AR8030_SDK_INC=$(STAGING_DIR)/usr/include/ar8030 \
		AR8030_SDK_LIB=$(STAGING_DIR)/usr/lib
endef

define AR8030_TRANSPORT_TX_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/tx/ar8030-transport-tx \
		$(TARGET_DIR)/usr/bin/ar8030-transport-tx
	$(INSTALL) -D -m 0755 $(@D)/linkctl/ar8030-linkctl \
		$(TARGET_DIR)/usr/bin/ar8030-linkctl
	$(INSTALL) -D -m 0755 $(@D)/lifecycled/ar8030-lifecycled \
		$(TARGET_DIR)/usr/bin/ar8030-lifecycled
	$(INSTALL) -D -m 0755 $(AR8030_TRANSPORT_TX_PKGDIR)/files/etc/init.d/S65ar8030-transport-tx \
		$(TARGET_DIR)/etc/init.d/S65ar8030-transport-tx
	$(INSTALL) -D -m 0644 $(AR8030_TRANSPORT_TX_PKGDIR)/files/etc/default/ar8030-transport-tx \
		$(TARGET_DIR)/etc/default/ar8030-transport-tx
endef

#
# Kernel module (kmod/, out-of-tree, built by the kernel's own kbuild) --
# this package's own clean-room replacement for the vendor's closed
# artosyn_sdio.ko, see kmod/artosyn_sdio.c's header comment and this repo's
# README "Clean-room rewrite" section for the full story of why it exists
# and what it does/doesn't implement (SDIO-mode chardev plus the native
# ar_net0 net_device, kmod/artosyn_net.c / doc/native-netdev.md; no
# DRV-mode /dev/ar_mdev).
#
# AR8030_SDK_DRIVER_INC reaches directly into the ar8030 package's own
# extracted+patched source tree for the shared ioctl/protocol header
# (driver/linux/bus/sdio.h) -- $(AR8030_DIR) is Buildroot's own
# auto-generated <PKG>_DIR variable, a standard cross-package reference
# (see package/ar8030/ar8030.mk's AR8030_INSTALL_STAGING_CMDS comment,
# which documents this same reasoning from the other side). That source
# tree already has to exist for the ar8030 package's own build, and this
# package already depends on ar8030, so Buildroot's scheduler guarantees
# it is extracted (and patched) before this module builds against it.
AR8030_TRANSPORT_TX_MODULE_SUBDIRS = kmod

AR8030_TRANSPORT_TX_MODULE_MAKE_OPTS = \
	AR8030_SDK_DRIVER_INC=$(AR8030_DIR)/driver/linux/bus

# Only the subset of the old ar8030.mk's own AR8030_LINUX_CONFIG_FIXUPS
# that this module still actually needs: CONFIG_FW_LOADER for
# request_firmware() (the boot-ROM firmware push), CONFIG_MMC for the
# SDIO bus itself and CONFIG_NET for the native ar_net0 net_device
# (kmod/artosyn_net.c). CONFIG_PROC_FS/CONFIG_USB were only ever needed by
# the old combined driver's proc-file/USB-bus code, which this module
# doesn't have.
define AR8030_TRANSPORT_TX_LINUX_CONFIG_FIXUPS
	$(call KCONFIG_SET_OPT,CONFIG_FW_LOADER,y)
	$(call KCONFIG_SET_OPT,CONFIG_MMC,y)
	$(call KCONFIG_SET_OPT,CONFIG_NET,y)
endef

# kernel-module must be $(eval)'d *before* generic-package: $(eval ...)
# expands and fixes a rule's prerequisite list (e.g. the order-only wait
# on this package's own DEPENDENCIES) the moment it runs, and it's
# kernel-module's own eval that appends "linux" to DEPENDENCIES -- doing
# this the other way around silently drops that wait (the variable
# itself still ends up correct for anyone who inspects it afterward, so
# this is easy to get backwards without noticing: confirmed on a genuine
# from-scratch build, where it raced against the kernel's own build and
# failed with "scripts/mod/modpost: not found").
$(eval $(kernel-module))
$(eval $(generic-package))
