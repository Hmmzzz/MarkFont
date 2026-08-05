ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME ?= roothide

ifeq ($(filter $(THEOS_PACKAGE_SCHEME),rootless roothide),)
$(error MarkFont supports only THEOS_PACKAGE_SCHEME=rootless or roothide)
endif

# roothide.h deliberately exposes the same jbroot/rootfs API to both schemes.
# RootHide uses the dynamic libroothide runtime; conventional rootless builds
# use the libroot compatibility implementation that Theos links automatically.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
MARKFONT_PATH_LIBRARIES := roothide
MARKFONT_PATH_CFLAGS :=
else
MARKFONT_PATH_LIBRARIES :=
# The cross-scheme roothide stub currently leaves the fd argument of its
# static jbrootat_alloc shim unused. Keep project warnings enabled while
# suppressing only that vendor-header diagnostic for conventional rootless.
MARKFONT_PATH_CFLAGS := -Wno-unused-parameter
endif

# Keep symbols while the project is under active development.
DEBUG := 1
