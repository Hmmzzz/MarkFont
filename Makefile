_THEOS_PLATFORM_DPKG_DEB := $(CURDIR)/scripts/fontmanager-dpkg-deb
export FONTMANAGER_UPSTREAM_DM := $(THEOS)/vendor/dm.pl/dm.pl
# Theos normalizes Debian control metadata with BSD sed. Keep that byte-oriented
# so UTF-8 package descriptions are copied safely on macOS hosts.
export LC_ALL := C

include Config.mk
include $(THEOS)/makefiles/common.mk

SUBPROJECTS += app
SUBPROJECTS += bindfs
SUBPROJECTS += daemon
SUBPROJECTS += cli

include $(THEOS_MAKE_PATH)/aggregate.mk

.PHONY: package-roothide package-rootless package-all

package-roothide:
	./scripts/build-packages roothide

package-rootless:
	./scripts/build-packages rootless

package-all:
	./scripts/build-packages roothide rootless
