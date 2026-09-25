################################################################################
#
# msposd
#
################################################################################

# Replaces firmware's general/package/msposd (copy_extra_packages overwrites
# it in place) until hi3516cv6xx support is upstream in OpenIPC/msposd and
# OpenIPC/firmware. Every other family builds exactly as upstream's .mk does.
#
# Upstream falls through to star6e for any family it doesn't list, so without
# this override a hi3516cv6xx build silently produced a SigmaStar binary.
#
# NOTE: the `hi3516cv6xx` branch has to be pushed to the fork before this
# download works -- and then MSPOSD_VERSION should be pinned to its commit
# SHA (a branch name gets frozen by CI's builder-dl cache, see CLAUDE.md's
# "Moving-ref cache caveat"). To build against a working tree instead:
#
#   echo 'MSPOSD_OVERRIDE_SRCDIR = /home/henk/Dokumente/fpv/OpenIPC/msposd' \
#       >> $(O)/local.mk
#
# or pass MSPOSD_OVERRIDE_SRCDIR in the environment. As with waybeam, the
# rsync only runs once per .stamp_rsynced; `make msposd-dirclean` to resync.
MSPOSD_VERSION = 1aae90305b869cda828f77110114b311543ae6b9
MSPOSD_SITE = https://github.com/OpenIPC/msposd.git
MSPOSD_SITE_METHOD = git
MSPOSD_LICENSE = GPL-3.0
MSPOSD_LICENSE_FILES = LICENSE
MSPOSD_DEPENDENCIES = libevent-openipc

# The working tree may carry downloaded toolchains and SDK/firmware clones
# from standalone ./build.sh runs; none of them are needed here.
MSPOSD_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS = \
	--exclude toolchain --exclude firmware --exclude openhisilicon

ifeq ($(OPENIPC_SOC_FAMILY),gk7205v200)
	MSPOSD_FAMILY = goke
	MSPOSD_OSDRV = $(GOKE_OSDRV_GK7205V200_PKGDIR)
else ifeq ($(OPENIPC_SOC_FAMILY),hi3516ev200)
	MSPOSD_FAMILY = hisi
	MSPOSD_OSDRV = $(HISILICON_OSDRV_HI3516EV200_PKGDIR)
else ifeq ($(OPENIPC_SOC_FAMILY),hi3516cv6xx)
	# Headers from openhisilicon (hisilicon-opensdk's source tree, same as
	# waybeam's CV610_SDK_INC); libss_mpi*.so from the osdrv package, which
	# also installs them into the rootfs.
	MSPOSD_FAMILY = hi3516cv6xx
	MSPOSD_OSDRV = $(HISILICON_OSDRV_HI3516CV6XX_PKGDIR)
	MSPOSD_DEPENDENCIES += hisilicon-opensdk hisilicon-osdrv-hi3516cv6xx
	MSPOSD_MAKE_OPTS += OPENHISILICON=$(HISILICON_OPENSDK_DIR)
else ifeq ($(OPENIPC_SOC_FAMILY),infinity6b0)
	MSPOSD_FAMILY = star6b0
	MSPOSD_OSDRV = $(SIGMASTAR_OSDRV_INFINITY6B0_PKGDIR)
else ifeq ($(OPENIPC_SOC_FAMILY),infinity6c)
	MSPOSD_FAMILY = star6c
	MSPOSD_OSDRV = $(SIGMASTAR_OSDRV_INFINITY6C_PKGDIR)
else
	MSPOSD_FAMILY = star6e
	MSPOSD_OSDRV = $(SIGMASTAR_OSDRV_INFINITY6E_PKGDIR)
endif

define MSPOSD_BUILD_CMDS
	$(MAKE) CC=$(TARGET_CC) TOOLCHAIN=$(STAGING_DIR) DRV=$(MSPOSD_OSDRV)/files/lib \
		$(MSPOSD_MAKE_OPTS) $(MSPOSD_FAMILY) OUTPUT=$(@D)/msposd -C $(@D)
endef

define MSPOSD_INSTALL_TARGET_CMDS
	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/bin
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin $(@D)/msposd
	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin $(@D)/safeboot.sh

	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/share/fonts
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/share/fonts $(@D)/fonts/font_inav.png
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/share/fonts $(@D)/fonts/font_inav_hd.png
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/share/fonts $(@D)/fonts/font_btfl.png
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/share/fonts $(@D)/fonts/font_btfl_hd.png
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/share/fonts $(@D)/fonts/font_ardu.png
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/share/fonts $(@D)/fonts/font_ardu_hd.png
	$(INSTALL) -m 644 -t $(TARGET_DIR)/etc $(@D)/vtxmenu.ini
endef

define MSPOSD_INSTALL_LIBRARIES
	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/lib
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/lib $(MSPOSD_OSDRV)/files/lib/libcam_os_wrapper.so
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/lib $(MSPOSD_OSDRV)/files/lib/libmi_rgn.so
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/lib $(MSPOSD_OSDRV)/files/lib/libmi_sys.so
endef

ifeq ($(OPENIPC_SOC_VENDOR),sigmastar)
MSPOSD_POST_INSTALL_TARGET_HOOKS += MSPOSD_INSTALL_LIBRARIES
endif

# Status text ("Waiting for data on ...", air unit messages) is rendered
# from this TrueType font, normally installed by majestic-fonts. Images
# without majestic (e.g. waybeam boards) need msposd to bring it along,
# or every text message silently draws nothing.
define MSPOSD_INSTALL_TRUETYPE_FONT
	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/share/fonts/truetype
	$(INSTALL) -m 644 -t $(TARGET_DIR)/usr/share/fonts/truetype $(@D)/fonts/UbuntuMono-Regular.ttf
endef

ifneq ($(BR2_PACKAGE_MAJESTIC_FONTS),y)
MSPOSD_POST_INSTALL_TARGET_HOOKS += MSPOSD_INSTALL_TRUETYPE_FONT
endif

$(eval $(generic-package))
