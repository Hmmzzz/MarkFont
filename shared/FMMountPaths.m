#import "FMMountPaths.h"

#import <errno.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMLegacyProviderAutoMountPolicy.h"

NSString *const FMLegacyProviderPreferenceLogicalPath =
    @"/var/mobile/Library/Preferences/com.nan.auto-bindfs.plist";
NSString *const FMMountStorageRootLogicalPath = @"/bindfs";
NSString *const FMMountSystemFontsLogicalPath = @"/System/Library/Fonts";
NSString *const FMMountRootfsFontsLogicalPath = @"/System/Library/Fonts";

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

BOOL FMMountManagedMappingIsActive(NSError **error) {
    BOOL rootSupported = NO;
    NSString *mirrorLogicalPath =
        FMMountResolvedMirrorLogicalPath(&rootSupported, NULL);
    struct statfs mapping = {0};
    if (!rootSupported ||
        statfs(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
               &mapping) != 0) {
        return FMMountPathsFail(
            error, 6, @"The active font mapping could not be inspected.",
            rootSupported ? errno : 0);
    }

    NSString *filesystemType =
        [NSString stringWithUTF8String:mapping.f_fstypename];
    NSString *target = [NSString stringWithUTF8String:mapping.f_mntonname];
    NSString *source = [NSString stringWithUTF8String:mapping.f_mntfromname];
    NSString *mirrorPath = jbroot(mirrorLogicalPath);
    BOOL exact = filesystemType != nil && source != nil &&
        [filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame &&
        [target isEqual:FMMountSystemFontsLogicalPath] &&
        [source.stringByResolvingSymlinksInPath
            isEqual:mirrorPath.stringByResolvingSymlinksInPath] &&
        (mapping.f_flags & MNT_RDONLY) != 0;
    return exact || FMMountPathsFail(
        error, 6, @"The active font mapping is not the managed read-only mirror.", 0);
}
