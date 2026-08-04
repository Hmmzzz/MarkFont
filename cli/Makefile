include ../Config.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = fontmanagerctl

fontmanagerctl_FILES = main.m ../shared/FMStatusContract.m ../shared/FMDataModel.m \
    ../shared/FMHelperClient.m
fontmanagerctl_LIBRARIES = roothide
fontmanagerctl_CFLAGS = -fobjc-arc -Wall -Wextra
fontmanagerctl_CODESIGN_FLAGS = -Sentitlements.plist
fontmanagerctl_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
