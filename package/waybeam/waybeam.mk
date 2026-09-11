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
# libbin.so (fetched at build time on Hisilicon boards, see near the end
# of this file) is a third-party proprietary Hisilicon binary, not ours
# and not MIT -- named here rather than quietly widening MIT to cover it.
WAYBEAM_LICENSE = MIT, PROPRIETARY (libbin.so)
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
WAYBEAM_DEPENDENCIES = hisilicon-opensdk hisilicon-osdrv-hi3516cv6xx \
	$(call qstrip,$(BR2_PACKAGE_WAYBEAM_SENSOR_FETCH_DEPENDENCY))

WAYBEAM_SENSOR_FETCH_SCRIPT = $(call qstrip,$(BR2_PACKAGE_WAYBEAM_SENSOR_FETCH_SCRIPT))
ifneq ($(WAYBEAM_SENSOR_FETCH_SCRIPT),)
# Runs the device-configured fetch script (BR2_PACKAGE_WAYBEAM_SENSOR_
# FETCH_SCRIPT, set in the device's own defconfig -- see this package's
# Config.in) before the package builds, so it can populate $(@D)/
# vendor-sensors/ with this board's sensor tuning presets -- see that
# Config.in entry for the full contract and devices/hi3516cv6xx_fpv_caddx-
# ascent-lite/general/scripts/fetch-vendor-sensors.py for a worked
# example (CADDX's vendor image, shared with package/ar8030's own
# baseband-firmware fetch via the same pattern). Deliberately not this
# package's own concern: a different board/sensor sources tuning presets
# from a different vendor in a different format, and $(BINARIES_DIR) is
# the one stable way such a script finds the long-lived builder checkout
# from inside a build recipe -- see package/ar8030/ar8030.mk's own
# comment on why $(TOPDIR) is NOT stable enough for this.
#
# BR2_PACKAGE_WAYBEAM_SENSOR_FETCH_DEPENDENCY above (also device-set,
# also optional) is what actually gets this fetch script's own
# dependencies built before this hook runs, with a genuine Buildroot-
# scheduler guarantee. The fetch script can still legitimately produce
# nothing (no network, an upstream format change), in which case
# WAYBEAM_INSTALL_TARGET_CMDS below just installs without any sensor
# tuning rather than failing the build -- the sensor plugin degrades to
# whatever default tuning it carries built in.
define WAYBEAM_FETCH_VENDOR_SENSORS
	$(BR2_EXTERNAL)/$(WAYBEAM_SENSOR_FETCH_SCRIPT) $(BINARIES_DIR) $(@D)/vendor-sensors
endef
WAYBEAM_PRE_BUILD_HOOKS += WAYBEAM_FETCH_VENDOR_SENSORS
endif

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

# Most of these come from out/cv610/ (populated by `stage`, not scattered
# source-tree paths): S95waybeam here is init.d/S95waybeam.cv610 (NOT the
# generic init.d/S95waybeam — that one has no PLATFORM_CONFIG or
# CV610_SENSOR_PROFILE handling). waybeam.json is the exception: it's this
# package's own files/waybeam.json below, not upstream's staged
# config/waybeam.default.cv610.json — this repo's copy is what's actually
# live at /etc/waybeam.json, so board-specific defaults (fps, isp.sensorBin,
# etc.) belong there, not in a comment claiming it's unused.
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
	if [ -d $(@D)/vendor-sensors ] && [ -n "$$(ls -A $(@D)/vendor-sensors 2>/dev/null)" ]; then \
		$(INSTALL) -d -m 0755 $(TARGET_DIR)/etc/sensors $(BINARIES_DIR)/sensors; \
		$(INSTALL) -m 0644 -t $(TARGET_DIR)/etc/sensors $(@D)/vendor-sensors/*.bin; \
		$(INSTALL) -m 0644 -t $(BINARIES_DIR)/sensors $(@D)/vendor-sensors/*.bin; \
	else \
		echo "waybeam: no vendor sensor tuning fetched this build -- /etc/sensors will be empty" >&2; \
	fi
	$(WAYBEAM_INSTALL_JSON_CLI)
endef

ifeq ($(OPENIPC_SOC_VENDOR),hisilicon)
# libbin.so: Hisilicon's proprietary PQ (picture-quality) ISP tuning bin
# import/export library (OT_PQ_BIN_Import/ExportBinData et al, linked
# against hisilicon-opensdk's ss_mpi_isp_*/ss_mpi_vi_* symbols) -- without
# it, waybeam's isp.sensorBin config path and /api/v1/iq/export_bin API
# just warn and no-op; the rest of the image still boots and streams
# fine. Not committed here (proprietary Hisilicon binary, this repo is
# public) -- fetched at build time from a pinned commit of a fork that
# already carries it (upstream OpenIPC/waybeam_venc doesn't ship it),
# same spirit as package/ascent-vendor-firmware's CADDX fetches. SHA256-
# pinned since, unlike the CADDX flow, there's no magic-byte format to
# sanity-check the download against.
#
# Gated on the SoC vendor, not folded into WAYBEAM_INSTALL_TARGET_CMDS
# above: that whole block is already Hisilicon-cv610-specific in this
# package as currently written, but this guard keeps the fetch correctly
# scoped if a non-Hisilicon backend (SigmaStar, say) is ever added here.
WAYBEAM_LIBBIN_SO_URL = https://raw.githubusercontent.com/snokvist/firmware/f293f585006b15397f17b31753c233a20e2726c7/general/package/waybeam/files/libbin.so
WAYBEAM_LIBBIN_SO_SHA256 = 71eada7288dabef2dc8bf07ae94b8693f02c13281171a362defb101feeb4cd75

define WAYBEAM_FETCH_LIBBIN_SO
	if curl -sL --fail -o $(@D)/libbin.so.tmp "$(WAYBEAM_LIBBIN_SO_URL)" && \
	   echo "$(WAYBEAM_LIBBIN_SO_SHA256)  $(@D)/libbin.so.tmp" | sha256sum -c - >/dev/null 2>&1; then \
		$(INSTALL) -D -m 0755 $(@D)/libbin.so.tmp $(TARGET_DIR)/usr/lib/libbin.so; \
	else \
		echo "waybeam: could not fetch libbin.so -- ISP tuning bin import/export will no-op" >&2; \
	fi
	rm -f $(@D)/libbin.so.tmp
endef
WAYBEAM_POST_INSTALL_TARGET_HOOKS += WAYBEAM_FETCH_LIBBIN_SO
endif

$(eval $(generic-package))
