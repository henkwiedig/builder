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
# Passing WAYBEAM_OVERRIDE_SRCDIR as a plain environment variable to
# builder.sh/make also works (buildroot picks up any <PKG>_OVERRIDE_SRCDIR
# it finds in its variable space, env included) and does not require
# local.mk. Either way: the rsync from OVERRIDE_SRCDIR only runs once per
# `output/build/waybeam-custom/.stamp_rsynced` — standard buildroot
# behaviour, not specific to this package. Local edits made *after* the
# first sync are invisible to subsequent builds until you force a fresh
# sync with `make waybeam-dirclean` (or `make waybeam-rsync`) first.
#
WAYBEAM_VERSION = da68d285abbf1927939d7a87231e906d520170ef
WAYBEAM_SITE = https://github.com/henkwiedig/waybeam_venc.git
WAYBEAM_SITE_METHOD = git
WAYBEAM_LICENSE = MIT
WAYBEAM_LICENSE_FILES = LICENSE

# The working tree carries ~1.7 GB of downloaded cross-toolchains and a build
# output dir. Neither is wanted (buildroot supplies the compiler) and rsyncing
# them on every OVERRIDE_SRCDIR build would dwarf the 21 MB of actual source.
#
# Also exclude the sensor plugins' own generated .o/.d/.so: sensors/cv610/*
# builds in-tree (Makefile writes objects next to the sources, not to an
# isolated build dir) with -MMD, so its .d files hardcode absolute paths to
# hisilicon-opensdk's checkout at generation time. hisilicon-opensdk tracks a
# moving ref (see general/openipc.fragment's own moving-ref cache handling)
# and its resolved commit can change between builds; when it does, a synced
# stale .d survives and points `-include`d rules at a directory that no
# longer exists ("No rule to make target ... needed by sensor_common.o").
# Bit us in practice: both this build tree's own output/build/waybeam-custom
# *and* the WAYBEAM_OVERRIDE_SRCDIR working tree itself had picked up stale
# ones from building locally against an older opensdk checkout.
#
# Scoped to sensors/*/*/ specifically, NOT a bare "*.d": rsync's exclude glob
# matches directories too, and a bare "*.d" also matches the init.d/
# directory itself (anything ending in ".d", file or dir) — excluded the
# whole init.d/ tree, S95waybeam included, the first time this was tried.
WAYBEAM_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude toolchain --exclude out \
	--exclude 'sensors/*/*/*.o' --exclude 'sensors/*/*/*.d' --exclude 'sensors/*/*/*.so'

WAYBEAM_SOC_BUILD = cv610

# waybeam's own Makefile defaults CV610_SDK_INC/CV610_SDK_LIB to a sibling
# `../openhisilicon` checkout and `../firmware/output/target/usr/lib`, neither
# of which exist inside a buildroot build tree — that default is for building
# waybeam_venc standalone against a manually-cloned SDK. Point both at this
# build's actual hisilicon-opensdk package dir (headers) and the rootfs
# staging dir (the closed-source .so blobs hisilicon-osdrv-hi3516cv6xx
# installs), and depend on both so they exist before waybeam's build step
# runs. Confirmed on the bench: without this, every cv610_*.c TU fails at
# `#include "ot_common.h"` — waybeam falls back to its own default, which
# 404s to a directory that was never created in this tree.
WAYBEAM_DEPENDENCIES = hisilicon-opensdk hisilicon-osdrv-hi3516cv6xx

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
	CC_CV610_BIN=$(TARGET_CC) \
	CV610_SENSOR_PLUGIN=os02k10 \
	CV610_SDK_INC=$(HISILICON_OPENSDK_DIR) \
	CV610_SDK_LIB=$(TARGET_DIR)/usr/lib

ifeq ($(BR2_PACKAGE_WAYBEAM_JSON_CLI),y)
define WAYBEAM_BUILD_JSON_CLI
	$(WAYBEAM_MAKE_ENV) $(MAKE) -C $(@D) $(WAYBEAM_MAKE_OPTS) json_cli
endef
define WAYBEAM_INSTALL_JSON_CLI
	$(INSTALL) -D -m 0755 $(@D)/out/$(WAYBEAM_SOC_BUILD)/json_cli \
		$(TARGET_DIR)/usr/bin/json_cli
endef
endif

# `stage` (not a manual `build` + `sensor-cv610`) is upstream's own cv610
# packaging target — `stage: build qr-decode` already pulls in `build`, then
# for SOC_BUILD=cv610 stages the sensor .so, the cv610-flavored init script
# and json default, and two files no prior version of this .mk installed at
# all (load-cv610-online, waybeam-cv610.conf) — see the Makefile's own
# `stage` recipe. Building `sensor-cv610` by hand only produced the .so
# in-place under sensors/cv610/os02k10/, never staged into out/cv610/ where
# the install step below reads from — that gap is what the "no rule to make
# .../libsns_os02k10.so" failure downstream of the .d-file fix above traced
# back to.
define WAYBEAM_BUILD_CMDS
	$(WAYBEAM_MAKE_ENV) $(MAKE) -C $(@D) $(WAYBEAM_MAKE_OPTS) stage
	$(WAYBEAM_BUILD_JSON_CLI)
endef

# All of these come from out/cv610/ (populated by `stage`, not scattered
# source-tree paths): S95waybeam here is init.d/S95waybeam.cv610 (NOT the
# generic init.d/S95waybeam — that one has no PLATFORM_CONFIG or
# CV610_SENSOR_PROFILE handling), and waybeam.json is
# config/waybeam.default.cv610.json, not this package's own files/waybeam.json
# (now unused — kept only as a reference for what a from-scratch default
# looked like before the cv610 backend had its own).
#
# qr_decode: star6e_luma_tap.c execl()s /usr/bin/qr_decode for the (optional,
# degrades gracefully if absent) QR-pairing scan — install it so the feature
# actually works instead of silently degrading on every camera.
#
# load-cv610-online / waybeam-cv610.conf: S95waybeam.cv610 hard-depends on
# both — LOADER=/usr/bin/load-cv610-online (execed to bring the MPP modules
# up before the daemon starts) and PLATFORM_CONFIG=/etc/waybeam-cv610.conf
# (sourced for the sensor profile / audio knobs). Neither was installed by
# any prior version of this .mk; the service would have failed at boot.
define WAYBEAM_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/out/$(WAYBEAM_SOC_BUILD)/waybeam \
		$(TARGET_DIR)/usr/bin/waybeam
	$(INSTALL) -D -m 0755 $(@D)/out/$(WAYBEAM_SOC_BUILD)/qr_decode \
		$(TARGET_DIR)/usr/bin/qr_decode
	$(INSTALL) -D -m 0755 $(@D)/out/$(WAYBEAM_SOC_BUILD)/load-cv610-online \
		$(TARGET_DIR)/usr/bin/load-cv610-online
	$(INSTALL) -D -m 0755 $(@D)/out/$(WAYBEAM_SOC_BUILD)/S95waybeam \
		$(TARGET_DIR)/etc/init.d/S95waybeam
	$(INSTALL) -D -m 0644 $(WAYBEAM_PKGDIR)files/waybeam.json \
		$(TARGET_DIR)/etc/waybeam.json
	$(INSTALL) -D -m 0644 $(WAYBEAM_PKGDIR)config/waybeam-cv610.conf \
		$(TARGET_DIR)/etc/waybeam-cv610.conf
	$(INSTALL) -D -m 0755 $(@D)/out/$(WAYBEAM_SOC_BUILD)/sensors/libsns_os02k10.so \
		$(TARGET_DIR)/usr/lib/sensors/libsns_os02k10.so
	$(WAYBEAM_INSTALL_JSON_CLI)
endef

$(eval $(generic-package))
