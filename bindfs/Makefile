include ../Config.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = markfont-bindfs

markfont-bindfs_FILES = main.m
markfont-bindfs_LIBRARIES = roothide
markfont-bindfs_CFLAGS = -fobjc-arc -Wall -Wextra
markfont-bindfs_CODESIGN_FLAGS = -Sentitlements.plist
markfont-bindfs_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
