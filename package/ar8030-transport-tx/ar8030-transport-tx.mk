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
AR8030_TRANSPORT_TX_VERSION = master
AR8030_TRANSPORT_TX_SITE = https://github.com/henkwiedig/ar8030-transport.git
AR8030_TRANSPORT_TX_SITE_METHOD = git
AR8030_TRANSPORT_TX_LICENSE = MIT
AR8030_TRANSPORT_TX_LICENSE_FILES = LICENSE

# Needs the ar8030 package's already-built libar8030_client.so + headers
# (staged to $(STAGING_DIR)/usr/include/ar8030 and .../usr/lib -- see
# package/ar8030/ar8030.mk's AR8030_INSTALL_STAGING_CMDS) and its 0008
# datagram-mode-symmetry patch (see this package's Config.in help).
AR8030_TRANSPORT_TX_DEPENDENCIES = ar8030

# tx/Makefile is a standalone Makefile (also usable outside Buildroot --
# see ar8030-transport's own README), so this just invokes it with the
# cross compiler and the ar8030 package's staging paths instead of
# folding the build into Buildroot's own machinery. linkctl/ (see its
# own README section) is built the same way -- it's a separate binary,
# not tied to tx specifically, but this package is the natural place to
# build+install the air-side copy since it already stages against this
# same ar8030 dependency.
#
# `make clean` before each: when built via AR8030_TRANSPORT_TX_OVERRIDE_
# SRCDIR (see this file's header comment), $(@D) is an `rsync -au` copy of
# the *live* ar8030-transport working tree, mtimes preserved -- and that
# same tree is also the OVERRIDE_SRCDIR for sbc-groundstations' ar8030-
# transport-rx package (AArch64 groundstation, a different repo), built
# from the same linkctl/ directory with the same default build/ and
# ar8030-linkctl output names. Without a clean first, a binary/object left
# over from whichever side built more recently rsyncs in looking newer
# than its .c source, and Make silently reuses it unrebuilt for the wrong
# architecture -- confirmed: an AArch64 ar8030-linkctl survived into an
# ARM build this way and failed Buildroot's post-install arch check.
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
endef

define AR8030_TRANSPORT_TX_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/tx/ar8030-transport-tx \
		$(TARGET_DIR)/usr/bin/ar8030-transport-tx
	$(INSTALL) -D -m 0755 $(@D)/linkctl/ar8030-linkctl \
		$(TARGET_DIR)/usr/bin/ar8030-linkctl
	$(INSTALL) -D -m 0755 $(AR8030_TRANSPORT_TX_PKGDIR)/files/etc/init.d/S65ar8030-transport-tx \
		$(TARGET_DIR)/etc/init.d/S65ar8030-transport-tx
	$(INSTALL) -D -m 0644 $(AR8030_TRANSPORT_TX_PKGDIR)/files/etc/default/ar8030-transport-tx \
		$(TARGET_DIR)/etc/default/ar8030-transport-tx
endef

$(eval $(generic-package))
