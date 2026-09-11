################################################################################
#
# ascent-vendor-firmware
#
################################################################################

# No real upstream source -- this package exists purely so ar8030 and
# waybeam (both AR8030_DEPENDENCIES/WAYBEAM_DEPENDENCIES on it) get a real,
# Buildroot-scheduler-enforced guarantee that CADDX's vendor image has
# already been fetched and extracted before either of them starts
# building, instead of each independently racing its own copy of that work
# -- see extract.py's docstring for the full story, including why
# BR2_ROOTFS_PRE_BUILD_SCRIPT doesn't work for this in this project.
ASCENT_VENDOR_FIRMWARE_SITE_METHOD = local
# PKGDIR always carries a trailing slash; SITE (unlike PKGDIR-derived paths
# used elsewhere, e.g. BUILD_CMDS below) rejects one outright.
ASCENT_VENDOR_FIRMWARE_SITE = $(patsubst %/,%,$(ASCENT_VENDOR_FIRMWARE_PKGDIR))
ASCENT_VENDOR_FIRMWARE_LICENSE = PROPRIETARY (fetches CADDX vendor firmware; nothing here is committed)

# Google Drive file id of CADDX's "Ascent H Sky" OTA image zip -- the
# canonical value lives here (not hardcoded in fetch-vendor-img.sh, which
# only keeps it as a standalone/manual-use fallback default), so bumping
# it to a newer CADDX release, or repointing at a different vendor image
# entirely, only ever means editing this one line.
ASCENT_VENDOR_FIRMWARE_VENDOR_FILE_ID = 1_IXl5OaJPVny78kg80CSn3FpWzYXQg3U

# No Buildroot dependency for reading the UBI image -- extract.py just
# shells out to `ubireader_extract_files` if it happens to be on PATH
# (pip install --user ubi_reader) and best-effort skips (no ar8030.img,
# no sensor tuning that build) if it isn't. See extract.py's docstring
# for why this isn't a hermetic host-* package dependency.

define ASCENT_VENDOR_FIRMWARE_BUILD_CMDS
	python3 $(ASCENT_VENDOR_FIRMWARE_PKGDIR)/extract.py $(BINARIES_DIR) $(ASCENT_VENDOR_FIRMWARE_VENDOR_FILE_ID)
endef

# Nothing installs to the target from this package directly -- ar8030 and
# waybeam each copy what they need out of $(BINARIES_DIR) (see extract.py)
# into their own build dirs and install it themselves.
define ASCENT_VENDOR_FIRMWARE_INSTALL_TARGET_CMDS
endef

$(eval $(generic-package))
