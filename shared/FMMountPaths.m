#import "FMMountPaths.h"

#import <errno.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMLegacyProviderAutoMountPolicy.h"
#import "FMSystemFontLayout.h"

NSString *const FMLegacyProviderPreferenceLogicalPath =
    @"/var/mobile/Library/Preferences/com.nan.auto-bindfs.plist";
NSString *const FMMountStorageRootLogicalPath = @"/bindfs";
NSString *const FMMountSystemFontsLogicalPath = @"/System/Library/Fonts";
NSString *const FMMountRootfsFontsLogicalPath = @"/System/Library/Fonts";
NSString *const FMMountFontServicesCorePrivateLogicalPath =
    @"/System/Library/PrivateFrameworks/FontServices.framework/CorePrivate";
NSString *const FMMountFontServicesCorePrivateMirrorLogicalPath =
    @"/bindfs/System/Library/PrivateFrameworks/FontServices.framework/CorePrivate";

NSString *const FMMountPathsErrorDomain =
    @"com.hmmzzz.fontmanager.mount-paths";

static BOOL FMMountPathsFail(NSError **error,
                                NSInteger code,
                                NSString *description,
                                int errorNumber) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (errorNumber != 0) {
            userInfo[NSUnderlyingErrorKey] =
                [NSError errorWithDomain:NSPOSIXErrorDomain
                                    code:errorNumber
                                userInfo:nil];
        }
        *error = [NSError errorWithDomain:FMMountPathsErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static void FMMountPathsSetUnderlyingError(NSError **error,
                                              NSInteger code,
                                              NSString *description,
                                              NSError *underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
        description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:FMMountPathsErrorDomain
                                 code:code
                             userInfo:userInfo];
}

static NSDictionary<NSString *, id> *_Nullable FMLegacyProviderLoadPreference(
    BOOL *present,
    NSPropertyListFormat *format,
    struct stat *metadata,
    NSError **error) {
    if (present == NULL) {
        FMMountPathsFail(error, 1,
                            @"legacy Provider preference output is required.", 0);
        return nil;
    }
    NSString *path =
        FMMountResolvedMobileDataPath(FMLegacyProviderPreferenceLogicalPath);
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) {
            *present = NO;
            return @{};
        }
        int savedError = errno;
        *present = NO;
        FMMountPathsFail(error, 2,
                            @"The legacy Provider preference could not be inspected.",
                            savedError);
        return nil;
    }
    *present = YES;
    if (!S_ISREG(info.st_mode)) {
        FMMountPathsFail(error, 2,
                            @"The legacy Provider preference is not a regular file.",
                            EINVAL);
        return nil;
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path
                                         options:0
                                           error:&readError];
    NSPropertyListFormat detectedFormat = NSPropertyListXMLFormat_v1_0;
    id object = data != nil
        ? [NSPropertyListSerialization propertyListWithData:data
                                                    options:NSPropertyListImmutable
                                                     format:&detectedFormat
                                                      error:&readError]
        : nil;
    if (![object isKindOfClass:NSDictionary.class]) {
        FMMountPathsSetUnderlyingError(
            error, 2, @"The legacy Provider preference is not a valid dictionary.",
            readError);
        return nil;
    }
    if (format != NULL) *format = detectedFormat;
    if (metadata != NULL) *metadata = info;
    return object;
}

NSDictionary<NSString *, id> *FMLegacyProviderAutoMountConfiguration(
    NSError **error) {
    BOOL present = NO;
    NSDictionary *preference = FMLegacyProviderLoadPreference(
        &present, NULL, NULL, error);
    if (preference == nil) return nil;
    if (!present) {
        return @{
            @"preferencePresent" : @NO,
            @"enabled" : @NO,
            @"pathsValid" : @YES,
            @"paths" : @[],
            @"fontsConfigured" : @NO,
            @"conflictsWithFonts" : @NO,
            @"rootSupported" : @YES,
        };
    }
    NSMutableDictionary *configuration =
        [FMAnalyzeLegacyProviderAutoMountPreference(preference) mutableCopy];
    configuration[@"preferencePresent"] = @YES;
    return configuration;
}

BOOL FMLegacyProviderAutoMountConflictsWithSystemFonts(BOOL *conflicts,
                                                 NSError **error) {
    if (conflicts == NULL) {
        return FMMountPathsFail(
            error, 1, @"legacy Provider automatic-mount conflict output is required.", 0);
    }
    NSDictionary *configuration = FMLegacyProviderAutoMountConfiguration(error);
    if (configuration == nil) {
        *conflicts = YES;
        return NO;
    }
    *conflicts = [configuration[@"conflictsWithFonts"] boolValue];
    return YES;
}

NSDictionary<NSString *, id> *FMDisableLegacyProviderAutoMountForSystemFonts(
    NSError **error) {
    if (getuid() != 0 || geteuid() != 0) {
        FMMountPathsFail(
            error, 7,
            @"Changing legacy Provider automatic mounting requires a real root caller.",
            EPERM);
        return nil;
    }

    BOOL present = NO;
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    struct stat metadata = {0};
    NSDictionary *preference = FMLegacyProviderLoadPreference(
        &present, &format, &metadata, error);
    if (preference == nil) return nil;
    NSDictionary *before = present
        ? FMAnalyzeLegacyProviderAutoMountPreference(preference)
        : FMLegacyProviderAutoMountConfiguration(error);
    if (before == nil) return nil;
    if (!present || ![before[@"conflictsWithFonts"] boolValue]) {
        return @{
            @"preferencePresent" : present ? @YES : @NO,
            @"changed" : @NO,
            @"conflictedBefore" : @NO,
            @"conflictsAfter" : @NO,
            @"remainingPaths" : before[@"paths"] ?: @[],
            @"enabledAfter" : before[@"enabled"] ?: @NO,
        };
    }
    if (![before[@"rootSupported"] boolValue]) {
        FMMountPathsFail(
            error, 7,
            @"The legacy Provider root is unsupported for automatic Fonts takeover.",
            EINVAL);
        return nil;
    }

    BOOL changed = NO;
    NSError *policyError = nil;
    NSDictionary *updated =
        FMLegacyProviderAutoMountPreferenceByRemovingSystemFonts(
            preference, &changed, &policyError);
    if (updated == nil || !changed) {
        FMMountPathsSetUnderlyingError(
            error, 7,
            @"The legacy Provider Fonts automatic-mount entry could not be removed.",
            policyError);
        return nil;
    }

    NSPropertyListFormat outputFormat =
        format == NSPropertyListBinaryFormat_v1_0
            ? NSPropertyListBinaryFormat_v1_0
            : NSPropertyListXMLFormat_v1_0;
    NSError *writeError = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:updated
                      format:outputFormat
                     options:0
                       error:&writeError];
    NSString *path =
        FMMountResolvedMobileDataPath(FMLegacyProviderPreferenceLogicalPath);
    if (data == nil ||
        ![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        FMMountPathsSetUnderlyingError(
            error, 7,
            @"The legacy Provider preference could not be updated atomically.",
            writeError);
        return nil;
    }
    if (chown(path.fileSystemRepresentation, metadata.st_uid, metadata.st_gid) != 0 ||
        chmod(path.fileSystemRepresentation, metadata.st_mode & 0777) != 0) {
        FMMountPathsFail(
            error, 7,
            @"The updated legacy Provider preference metadata could not be preserved.",
            errno);
        return nil;
    }

    NSDictionary *after = FMLegacyProviderAutoMountConfiguration(&writeError);
    if (after == nil || [after[@"conflictsWithFonts"] boolValue]) {
        FMMountPathsSetUnderlyingError(
            error, 7,
            @"legacy Provider Fonts automatic mounting remained enabled after update.",
            writeError);
        return nil;
    }
    return @{
        @"preferencePresent" : @YES,
        @"changed" : @YES,
        @"conflictedBefore" : @YES,
        @"conflictsAfter" : @NO,
        @"remainingPaths" : after[@"paths"],
        @"enabledAfter" : after[@"enabled"],
    };
}

NSString *FMMountResolvedStorageRootLogicalPath(BOOL *supported,
                                                BOOL *preferencePresent) {
    if (supported != NULL) {
        *supported = YES;
    }
    if (preferencePresent != NULL) {
        struct stat info = {0};
        *preferencePresent = lstat(
            FMMountResolvedMobileDataPath(
                FMLegacyProviderPreferenceLogicalPath).fileSystemRepresentation,
            &info) == 0;
    }
    return FMMountStorageRootLogicalPath;
}

NSString *FMMountResolvedMirrorLogicalPath(BOOL *supported,
                                           BOOL *preferencePresent) {
    NSString *root = FMMountResolvedStorageRootLogicalPath(supported,
                                                       preferencePresent);
    return [root stringByAppendingPathComponent:@"System/Library/Fonts"];
}

NSString *FMMountResolvedOriginalRootfsPath(NSString *logicalRootfsPath) {
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    NSString *rootHideLogicalPath =
        [@"/rootfs" stringByAppendingString:logicalRootfsPath];
    return jbroot(rootHideLogicalPath);
#else
    return logicalRootfsPath;
#endif
}

// Locates the FontManager app's data container. The conventional rootless app
// is sandboxed into a randomized UUID container, so its Application Support
// tree never sits at the fixed /var/mobile path the daemon historically used.
// The container UUID is stable for the lifetime of a process, so the result is
// cached. RootHide does not use this: it resolves /var/mobile through jbroot.
#if !defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
static NSString *FMMountFindAppDataContainer(void) {
    static NSString *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *containersRoot = @"/var/mobile/Containers/Data/Application";
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSArray<NSString *> *entries =
            [fileManager contentsOfDirectoryAtPath:containersRoot error:NULL];
        if (entries == nil) {
            cached = nil;
            return;
        }
        NSString *preferred = nil;
        NSDate *preferredDate = nil;
        for (NSString *entry in entries) {
            if (entry.length < 2 || [entry hasPrefix:@"."]) continue;
            NSString *containerPath =
                [containersRoot stringByAppendingPathComponent:entry];
            NSString *metadataPath = [containerPath
                stringByAppendingPathComponent:
                    @".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *metadata =
                [NSDictionary dictionaryWithContentsOfFile:metadataPath];
            if (![metadata[@"MCMMetadataIdentifier"]
                    isEqualToString:@"com.hmmzzz.fontmanager"]) {
                continue;
            }
            // A reinstall can leave both the old and new FontManager containers
            // present momentarily. Prefer the most recently modified one so the
            // fresh install wins over stale data.
            NSString *appSupport = [[[containerPath
                stringByAppendingPathComponent:@"Library"]
                stringByAppendingPathComponent:@"Application Support"]
                stringByAppendingPathComponent:@"com.hmmzzz.fontmanager"];
            NSDictionary *attributes =
                [fileManager attributesOfItemAtPath:appSupport error:NULL];
            NSDate *date = attributes[NSFileModificationDate];
            if (preferred == nil ||
                (date != nil &&
                 [date compare:preferredDate] == NSOrderedDescending)) {
                preferred = containerPath;
                preferredDate = date;
            }
        }
        if (preferred == nil) {
            NSLog(@"MarkFont could not locate the FontManager data container "
                  @"below /var/mobile/Containers/Data/Application; app data "
                  @"paths will not resolve to the sandbox.");
        }
        cached = preferred;
    });
    return cached;
}
#endif

NSString *FMMountResolvedAppContainerPath(NSString *suffix) {
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    // RootHide maps /var/mobile through jbroot directly; its FontManager app
    // data lives at that fixed path and never needs container discovery. Keep
    // this identical to the historical resolver so existing installs are
    // unaffected, and reserve the container scan for conventional rootless.
    return jbroot([@"/var/mobile" stringByAppendingString:suffix]);
#else
    NSString *containerPath = FMMountFindAppDataContainer();
    if (containerPath.length == 0) return @"";
    return [containerPath stringByAppendingString:suffix];
#endif
}

NSString *FMMountResolvedMobileDataPath(NSString *logicalMobilePath) {
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
    return jbroot(logicalMobilePath);
#else
    return logicalMobilePath;
#endif
}

NSString *FMMountResolvedStockFontsPath(void) {
    return FMMountResolvedOriginalRootfsPath(FMMountRootfsFontsLogicalPath);
}

NSString *FMMountResolvedStockFontServicesCorePrivatePath(void) {
    return FMMountResolvedOriginalRootfsPath(
        FMMountFontServicesCorePrivateLogicalPath);
}

NSString *FMMountResolvedFontServicesCorePrivateMirrorPath(void) {
    return jbroot(FMMountFontServicesCorePrivateMirrorLogicalPath);
}

static BOOL FMMountExactReadOnlyMapping(NSString *targetLogicalPath,
                                        NSString *mirrorPath,
                                        BOOL *inspectionAvailable) {
    struct statfs mapping = {0};
    if (statfs(targetLogicalPath.fileSystemRepresentation, &mapping) != 0) {
        if (inspectionAvailable != NULL) *inspectionAvailable = NO;
        return NO;
    }
    if (inspectionAvailable != NULL) *inspectionAvailable = YES;

    NSString *filesystemType =
        [NSString stringWithUTF8String:mapping.f_fstypename];
    NSString *target = [NSString stringWithUTF8String:mapping.f_mntonname];
    NSString *source = [NSString stringWithUTF8String:mapping.f_mntfromname];
    return filesystemType != nil && source != nil &&
        [filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame &&
        [target isEqual:targetLogicalPath] &&
        [source.stringByResolvingSymlinksInPath
            isEqual:mirrorPath.stringByResolvingSymlinksInPath] &&
        (mapping.f_flags & MNT_RDONLY) != 0;
}

BOOL FMMountManagedMappingIsActive(NSError **error) {
    NSError *layoutError = nil;
    FMSystemFontLayout layout = FMCurrentSystemFontLayout(nil, &layoutError);
    if (layout == FMSystemFontLayoutUnsupported) {
        FMMountPathsSetUnderlyingError(
            error, 6, @"The current system font layout is unsupported.",
            layoutError);
        return NO;
    }

    BOOL rootSupported = NO;
    NSString *mirrorLogicalPath =
        FMMountResolvedMirrorLogicalPath(&rootSupported, NULL);
    BOOL primaryInspectionAvailable = NO;
    BOOL primaryExact = rootSupported && FMMountExactReadOnlyMapping(
        FMMountSystemFontsLogicalPath, jbroot(mirrorLogicalPath),
        &primaryInspectionAvailable);
    if (!rootSupported || !primaryInspectionAvailable) {
        return FMMountPathsFail(
            error, 6, @"The active font mapping could not be inspected.",
            rootSupported ? errno : 0);
    }

    if (layout == FMSystemFontLayoutPrimaryFonts) {
        return primaryExact || FMMountPathsFail(
            error, 6,
            @"The active font mapping is not the managed read-only mirror.", 0);
    }

    NSString *supplementalMirror =
        FMMountResolvedFontServicesCorePrivateMirrorPath();
    struct stat supplementalMirrorInfo = {0};
    errno = 0;
    int supplementalMirrorResult =
        lstat(supplementalMirror.fileSystemRepresentation,
              &supplementalMirrorInfo);
    if (supplementalMirrorResult != 0 && errno != ENOENT) {
        return FMMountPathsFail(
            error, 6, @"The supplemental font mirror could not be inspected.",
            errno);
    }
    BOOL supplementalExpected = supplementalMirrorResult == 0;
    if (supplementalExpected && !S_ISDIR(supplementalMirrorInfo.st_mode)) {
        return FMMountPathsFail(
            error, 6, @"The supplemental font mirror is not a directory.", 0);
    }

    BOOL supplementalInspectionAvailable = YES;
    BOOL supplementalExact = !supplementalExpected || FMMountExactReadOnlyMapping(
        FMMountFontServicesCorePrivateLogicalPath, supplementalMirror,
        &supplementalInspectionAvailable);
    if (!supplementalInspectionAvailable) {
        return FMMountPathsFail(
            error, 6, @"The supplemental font mapping could not be inspected.", errno);
    }
    return (primaryExact && supplementalExact) || FMMountPathsFail(
        error, 6,
        @"The active font mappings are not the managed read-only mirrors.", 0);
}
