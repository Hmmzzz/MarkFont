include ../Config.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = fontmanagerd

fontmanagerd_FILES = main.m \
    ../shared/FMStatusContract.m ../shared/FMEnvironmentProbe.m \
    ../shared/FMDataModel.m ../shared/FMFileStore.m \
    ../shared/FMTreeManifest.m ../shared/FMProfileEngine.m \
    ../shared/FMFontCatalog.m ../shared/FMDeviceFontCatalog.m \
    ../shared/FMProfileAdoptionValidator.m \
    ../shared/FMProfileAdoption.m \
    ../shared/FMProfileMirrorMatcher.m \
    ../shared/FMProfileStagePlanner.m \
    ../shared/FMOperationLock.m \
    ../shared/FMDeviceProfileActivation.m \
    ../shared/FMDeviceProfileAdoption.m \
    ../shared/FMDeviceProfileStage.m \
    ../shared/FMDeviceSupplementalFontWorkspace.m \
    ../shared/FMRestartRequest.m \
    ../shared/FMDeviceRestartCoordinator.m \
    ../shared/FMDeviceStockSnapshot.m \
    ../shared/FMAutomaticRespringPolicy.m \
    ../shared/FMDeviceAutoMount.m \
    ../shared/FMDeviceMountTopology.m \
    ../shared/FMLegacyFontProfileImport.m \
    ../shared/FMDeviceLegacyFontTakeover.m \
    ../shared/FMDevicePackageLifecycle.m \
    ../shared/FMMountCoordinator.m ../shared/FMMountInspection.m \
    ../shared/FMMountBackendCompatibility.m \
    ../shared/FMLegacyProviderAutoMountPolicy.m \
    ../shared/FMSystemFontLayout.m \
    ../shared/FMMountPaths.m \
    ../shared/FMMountBackendExecutor.m \
    ../shared/FMMirrorPreparation.m ../shared/FMSecureDirectory.m \
    ../shared/FMDeviceMountEngine.m
fontmanagerd_LIBRARIES = $(MARKFONT_PATH_LIBRARIES)
fontmanagerd_CFLAGS = -fobjc-arc -Wall -Wextra $(MARKFONT_PATH_CFLAGS)
fontmanagerd_CODESIGN_FLAGS = -Sentitlements.plist
fontmanagerd_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
