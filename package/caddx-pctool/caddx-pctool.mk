################################################################################
#
# caddx-pctool
#
################################################################################

CADDX_PCTOOL_SITE_METHOD = local
CADDX_PCTOOL_SITE = $(CADDX_PCTOOL_PKGDIR)/src
CADDX_PCTOOL_LICENSE = GPL-2.0+

define CADDX_PCTOOL_BUILD_CMDS
	$(MAKE) CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS)" -C $(@D)
endef

# tools/pctool-client.py is a host-side test client, not installed.
define CADDX_PCTOOL_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/pctoold $(TARGET_DIR)/usr/bin/pctoold
	$(INSTALL) -D -m 0755 $(CADDX_PCTOOL_PKGDIR)/files/usr/sbin/pctool-mode \
		$(TARGET_DIR)/usr/sbin/pctool-mode
	$(INSTALL) -D -m 0644 $(CADDX_PCTOOL_PKGDIR)/files/etc/default/pctoold \
		$(TARGET_DIR)/etc/default/pctoold
endef

$(eval $(generic-package))
