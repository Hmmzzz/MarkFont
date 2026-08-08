#import "FMDeviceFontCatalog.h"

#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMEnvironmentProbe.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMMountPaths.h"
#import "FMSystemFontLayout.h"

NSString *const FMDeviceFontCatalogErrorDomain =
    @"com.hmmzzz.fontmanager.devicefontcatalog";

static BOOL FMDeviceCatalogFail(NSError **error,
                                NSString *description,
                                NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) {
            userInfo[NSUnderlyingErrorKey] = underlying;
        }
        *error = [NSError errorWithDomain:FMDeviceFontCatalogErrorDomain
                                     code:1
                                 userInfo:userInfo];
    }
    return NO;
}

static NSDictionary<NSString *, id> *FMDeviceCatalogSingleFontManifest(
    NSString *fontPath,
    NSString *relativePath,
    NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(fontPath.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) return nil;
        FMDeviceCatalogFail(
            error, @"The supplemental Stock font could not be inspected.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return nil;
    }
    if (!S_ISREG(info.st_mode) || info.st_size <= 0) {
        FMDeviceCatalogFail(error,
                            @"The supplemental Stock font is not a regular file.", nil);
        return nil;
    }
    NSError *hashError = nil;
    NSString *hash = FMSHA256ForFileAtPath(fontPath, &hashError);
    if (hash.length == 0) {
        FMDeviceCatalogFail(error,
                            @"The supplemental Stock font could not be hashed.", hashError);
        return nil;
    }
    NSDictionary *manifest = @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"entries" : @[@{
            @"relativePath" : relativePath,
            @"type" : @"regular",
            @"mode" : @((NSUInteger)info.st_mode & 07777),
            @"uid" : @(info.st_uid),
            @"gid" : @(info.st_gid),
            @"size" : @((unsigned long long)info.st_size),
            @"sha256" : hash,
        }],
    };
    NSError *validationError = nil;
    if (!FMValidateManifestDocument(manifest, &validationError)) {
        FMDeviceCatalogFail(error,
                            @"The supplemental Stock manifest is invalid.",
                            validationError);
        return nil;
    }
    return manifest;
}

static NSDictionary<NSString *, id> *FMDeviceCatalogSupplementalManifest(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSString *baselinePath = [[[jbroot(@"/var/lib/fontmanager/baseline")
        stringByAppendingPathComponent:confirmedSystemBuild]
        stringByAppendingPathComponent:@"fontservices-coreprivate-manifest.json"]
        stringByStandardizingPath];
    struct stat baselineInfo = {0};
    errno = 0;
    if (lstat(baselinePath.fileSystemRepresentation, &baselineInfo) == 0) {
        if (!S_ISREG(baselineInfo.st_mode) || baselineInfo.st_uid != 0 ||
            (baselineInfo.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
            FMDeviceCatalogFail(error,
                                @"The saved supplemental Stock catalog is unsafe.", nil);
            return nil;
        }
        NSError *readError = nil;
        id manifest = FMReadJSONObjectAtPath(baselinePath, &readError);
        if (![manifest isKindOfClass:NSDictionary.class] ||
            !FMValidateManifestDocument(manifest, &readError)) {
            FMDeviceCatalogFail(error,
                                @"The saved supplemental Stock catalog is invalid.",
                                readError);
            return nil;
        }
        return manifest;
    }
    if (errno != ENOENT) {
        FMDeviceCatalogFail(
            error, @"The saved supplemental Stock catalog could not be inspected.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return nil;
    }

    // Before the second mirror is first prepared, read the immutable rootfs
    // file directly. Once a mirror exists, a missing baseline is an interrupted
    // preparation and must never be inferred from possibly modified content.
    struct stat mirrorInfo = {0};
    errno = 0;
    if (lstat(FMMountResolvedFontServicesCorePrivateMirrorPath()
                  .fileSystemRepresentation,
              &mirrorInfo) == 0) {
        FMDeviceCatalogFail(error,
                            @"The supplemental mirror has no saved Stock baseline.", nil);
        return nil;
    }
    if (errno != ENOENT) {
        FMDeviceCatalogFail(
            error, @"The supplemental mirror could not be inspected.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return nil;
    }

    NSString *sourceRoot = FMMountResolvedStockFontServicesCorePrivatePath();
    NSString *fontPath = [sourceRoot stringByAppendingPathComponent:@"PingFangUI.ttc"];
    struct stat fontInfo = {0};
    errno = 0;
    if (lstat(fontPath.fileSystemRepresentation, &fontInfo) != 0 && errno == ENOENT) {
        return nil;
    }

    struct statfs filesystem = {0};
    if (statfs(sourceRoot.fileSystemRepresentation, &filesystem) != 0) {
        FMDeviceCatalogFail(
            error, @"The supplemental Stock filesystem could not be inspected.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return nil;
    }
    NSString *filesystemType =
        [NSString stringWithUTF8String:filesystem.f_fstypename];
    NSString *mountTarget =
        [NSString stringWithUTF8String:filesystem.f_mntonname];
    if ([filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame &&
        [mountTarget isEqual:FMMountFontServicesCorePrivateLogicalPath]) {
        FMDeviceCatalogFail(error,
                            @"The active supplemental mapping has no saved Stock baseline.",
                            nil);
        return nil;
    }
    return FMDeviceCatalogSingleFontManifest(
        fontPath, @"PingFangUI.ttc", error);
}

NSDictionary<NSString *, id> *FMCreateDeviceFontCatalogForBuild(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (geteuid() != 0 || confirmedSystemBuild.length == 0 ||
        confirmedSystemBuild.length > 32 ||
        confirmedSystemBuild.pathComponents.count != 1) {
        FMDeviceCatalogFail(error, @"The device or system build is unavailable.", nil);
        return nil;
    }

    NSError *layoutError = nil;
    FMSystemFontLayout layout = FMCurrentSystemFontLayout(
        confirmedSystemBuild, &layoutError);
    if (layout == FMSystemFontLayoutUnsupported) {
        FMDeviceCatalogFail(error,
                            @"The current system font layout is unsupported.",
                            layoutError);
        return nil;
    }

    NSString *baselinePath = [[jbroot(@"/var/lib/fontmanager/baseline")
        stringByAppendingPathComponent:confirmedSystemBuild]
        stringByAppendingPathComponent:@"manifest.json"];
    struct stat baselineInfo = {0};
    if (lstat(baselinePath.fileSystemRepresentation, &baselineInfo) != 0 ||
        !S_ISREG(baselineInfo.st_mode) || baselineInfo.st_uid != 0 ||
        (baselineInfo.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        FMDeviceCatalogFail(error, @"The saved Stock catalog is unavailable.", nil);
        return nil;
    }
    NSError *baselineError = nil;
    NSDictionary *baselineManifest = FMReadJSONObjectAtPath(baselinePath, &baselineError);
    NSString *baselineHash = baselineManifest != nil &&
            FMValidateManifestDocument(baselineManifest, &baselineError)
        ? FMSHA256ForJSONObject(baselineManifest, &baselineError)
        : nil;
    if (baselineHash.length == 0) {
        FMDeviceCatalogFail(error,
                            @"The saved Stock catalog is invalid.", baselineError);
        return nil;
    }

    NSError *supplementalError = nil;
    NSDictionary *supplementalManifest = nil;
    if (layout == FMSystemFontLayoutFontServicesCorePrivate) {
        supplementalManifest = FMDeviceCatalogSupplementalManifest(
            confirmedSystemBuild, &supplementalError);
        if (supplementalManifest == nil) {
            FMDeviceCatalogFail(
                error,
                @"The iOS 18-26 PingFangUI Stock catalog is unavailable.",
                supplementalError);
            return nil;
        }
    }
    NSString *supplementalHash = supplementalManifest != nil
        ? FMSHA256ForJSONObject(supplementalManifest, &supplementalError) : nil;
    if (supplementalManifest != nil && supplementalHash.length == 0) {
        FMDeviceCatalogFail(error,
                            @"The supplemental Stock catalog could not be hashed.",
                            supplementalError);
        return nil;
    }

    NSError *catalogError = nil;
    NSDictionary *catalog = FMCreateFontCatalogFromManifests(
        baselineManifest, supplementalManifest, confirmedSystemBuild,
        baselineHash, supplementalHash, &catalogError);
    if (catalog == nil) {
        FMDeviceCatalogFail(error,
                            @"The Stock filename catalog could not be generated.",
                            catalogError);
        return nil;
    }

    NSString *requiredChineseFileName =
        layout == FMSystemFontLayoutPrimaryFonts
            ? @"PingFang.ttc" : @"PingFangUI.ttc";
    NSString *forbiddenChineseFileName =
        layout == FMSystemFontLayoutPrimaryFonts
            ? @"PingFangUI.ttc" : @"PingFang.ttc";
    BOOL requiredTargetPresent = NO;
    BOOL forbiddenTargetPresent = NO;
    for (NSDictionary<NSString *, id> *file in catalog[@"files"]) {
        requiredTargetPresent = requiredTargetPresent ||
            [file[@"fileName"] isEqual:requiredChineseFileName];
        forbiddenTargetPresent = forbiddenTargetPresent ||
            [file[@"fileName"] isEqual:forbiddenChineseFileName];
    }
    if (!requiredTargetPresent || forbiddenTargetPresent) {
        FMDeviceCatalogFail(
            error,
            @"The Stock catalog does not match the confirmed iOS font layout.",
            nil);
        return nil;
    }
    return catalog;
}

NSDictionary<NSString *, id> *FMCreateDeviceFontCatalogPreview(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (geteuid() != 0 || confirmedSystemBuild.length == 0 ||
        confirmedSystemBuild.length > 32 ||
        confirmedSystemBuild.pathComponents.count != 1) {
        FMDeviceCatalogFail(error, @"The device or system build is unavailable.", nil);
        return nil;
    }

    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSDictionary *state = environment[@"state"];
    if (![environment[@"engineState"] isEqual:@"ready"] ||
        ![environment[@"system"][@"productBuildVersion"]
            isEqual:confirmedSystemBuild] ||
        ![state[@"present"] boolValue] || ![state[@"valid"] boolValue] ||
        ![state[@"systemBuild"] isEqual:confirmedSystemBuild] ||
        ![state[@"mirrorState"] isEqual:@"clean"] ||
        !FMMountManagedMappingIsActive(error)) {
        if (error == NULL || *error == nil) {
            FMDeviceCatalogFail(error,
                                @"The managed font workspace is unavailable.", nil);
        }
        return nil;
    }

    NSError *catalogError = nil;
    NSDictionary *catalog = FMCreateDeviceFontCatalogForBuild(
        confirmedSystemBuild, &catalogError);
    if (catalog == nil) {
        FMDeviceCatalogFail(error, @"The Stock filename catalog could not be generated.",
                            catalogError);
        return nil;
    }

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"inspectFontCatalog",
        @"status" : @"reviewRequired",
        @"systemBuild" : confirmedSystemBuild,
        @"sourceManifestSHA256" : catalog[@"sourceManifestSHA256"],
        @"matchingMode" : catalog[@"matchingMode"],
        @"sourceRegularFileCount" : catalog[@"sourceRegularFileCount"],
        @"fontFileCount" : @([catalog[@"files"] count]),
        @"excludedRegularFileCount" : @([catalog[@"excludedRegularPaths"] count]),
        @"excludedRegularPaths" : catalog[@"excludedRegularPaths"],
        @"readOnly" : @YES,
        @"mirrorContentScanned" : @NO,
        @"filesystemMutated" : @NO,
        @"mappingChanged" : @NO,
        @"stateChanged" : @NO,
        @"restartRequested" : @NO,
        @"catalog" : catalog,
    };
}
