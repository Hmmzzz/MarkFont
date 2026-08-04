include ../Config.mk
include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FontManager

FontManager_FILES = main.m FMAppDelegate.m FMDeviceProfileWorkspace.m \
    UI/FMFloatingActionDockView.m UI/FMProfileLabViewController.m \
    UI/FMFontLibraryViewController.m \
    UI/FMSettingsViewController.m UI/FMCompatibilityViewController.m \
    ../shared/FMStatusContract.m ../shared/FMDataModel.m \
    ../shared/FMFontCatalog.m ../shared/FMFontPackageMatcher.m \
    ../shared/FMFontPackageAnalyzer.m ../shared/FMFontPackageImportSession.m \
    ../shared/FMFontProfileStore.m \
    ../shared/FMFileStore.m ../shared/FMHelperClient.m
FontManager_FRAMEWORKS = UIKit QuartzCore CoreText UniformTypeIdentifiers
FontManager_LIBRARIES = roothide
FontManager_CFLAGS = -fobjc-arc -Wall -Wextra -I../shared -IUI
FontManager_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
