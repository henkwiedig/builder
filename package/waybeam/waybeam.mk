################################################################################
#
# waybeam
#
################################################################################

# HEAD of the `ascent` branch (M0-M4 of the Hi3516CV610 backend).
#
# NOTE: that branch is not pushed yet — the fork only carries `master` and
# `flip-mirror` — so this download will 404 until you `git push origin ascent`.
# To build against a working tree instead, point buildroot at it (no push
# needed, picks up uncommitted edits):
#
#   echo 'WAYBEAM_OVERRIDE_SRCDIR = /home/henk/Dokumente/fpv/OpenIPC/waybeam_venc' \
#       >> $(O)/local.mk
#
WAYBEAM_VERSION = da68d285abbf1927939d7a87231e906d520170ef
WAYBEAM_SITE = https://github.com/henkwiedig/waybeam_venc.git
WAYBEAM_SITE_METHOD = git
WAYBEAM_LICENSE = MIT
WAYBEAM_LICENSE_FILES = LICENSE

# The working tree carries ~1.7 GB of downloaded cross-toolchains and a build
# output dir. Neither is wanted (buildroot supplies the compiler) and rsyncing
# them on every OVERRIDE_SRCDIR build would dwarf the 21 MB of actual source.
WAYBEAM_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude toolchain --exclude out

WAYBEAM_SOC_BUILD = hi3516cv610

# CFLAGS/LDFLAGS have to arrive through the *environment*, not as command-line
# variables. Upstream's Makefile does `CFLAGS += $(COMMON_CFLAGS) ...`, and a
# command-line assignment beats `+=` outright — that would silently drop
# -Iinclude, the forced include of ssc338q_compat.h and -DVENC_VERSION. From
# the environment, `+=` appends the way it is meant to.
WAYBEAM_MAKE_ENV = \
	$(TARGET_MAKE_ENV) \
	CFLAGS="$(TARGET_CFLAGS)" \
	LDFLAGS="$(TARGET_LDFLAGS)"

# HI3516CV610_CC is the compiler the cv610 branch of the Makefile picks up.
# CC_CV610_BIN is separate: it is what the `toolchain-hi3516cv610` prerequisite
# probes with `test -x` before wget'ing OpenIPC's toolchain tarball. Point both
# at buildroot's cross gcc so nothing is downloaded and the build uses the same
# toolchain as the rest of the image.
WAYBEAM_MAKE_OPTS = \
	SOC_BUILD=$(WAYBEAM_SOC_BUILD) \
	HI3516CV610_CC=$(TARGET_CC) \
	CC_CV610_BIN=$(TARGET_CC)

ifeq ($(BR2_PACKAGE_WAYBEAM_JSON_CLI),y)
define WAYBEAM_BUILD_JSON_CLI
	$(WAYBEAM_MAKE_ENV) $(MAKE) -C $(@D) $(WAYBEAM_MAKE_OPTS) json_cli
endef
define WAYBEAM_INSTALL_JSON_CLI
	$(INSTALL) -D -m 0755 $(@D)/out/$(WAYBEAM_SOC_BUILD)/json_cli \
		$(TARGET_DIR)/usr/bin/json_cli
endef
endif

define WAYBEAM_BUILD_CMDS
	$(WAYBEAM_MAKE_ENV) $(MAKE) -C $(@D) $(WAYBEAM_MAKE_OPTS) build
	$(WAYBEAM_BUILD_JSON_CLI)
endef

define WAYBEAM_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/out/$(WAYBEAM_SOC_BUILD)/waybeam \
		$(TARGET_DIR)/usr/bin/waybeam
	$(INSTALL) -D -m 0755 $(@D)/init.d/S95waybeam \
		$(TARGET_DIR)/etc/init.d/S95waybeam
	$(INSTALL) -D -m 0644 $(@D)/config/waybeam.default.json \
		$(TARGET_DIR)/etc/waybeam.json
	$(WAYBEAM_INSTALL_JSON_CLI)
endef

$(eval $(generic-package))
