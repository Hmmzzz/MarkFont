#import "FMProviderPaths.h"

#import <errno.h>
#import <roothide.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMProviderAutoMountPolicy.h"

NSString *const FMProviderPackageIdentifier = @"com.nan.bindfs";
NSString *const FMProviderExecutableLogicalPath = @"/usr/bin/mount_bindfs";
NSString *const FMProviderPreferenceLogicalPath =
    @"/var/mobile/Library/Preferences/com.nan.auto-bindfs.plist";
NSString *const FMProviderDefaultRootLogicalPath = @"/bindfs";
NSString *const FMProviderAliasLogicalPath = @"/.bindfs";
NSString *const FMProviderSystemFontsLogicalPath = @"/System/Library/Fonts";
NSString *const FMProviderRootfsFontsLogicalPath = @"/rootfs/System/Library/Fonts";

NSString *const FMProviderPathsErrorDomain = @"com.hmmzzz.fontmanager.providerpaths";

static BOOL FMProviderPathsFail(NSError **error,
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
        *error = [NSError errorWithDomain:FMProviderPathsErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static void FMProviderPathsSetUnderlyingError(NSError **error,
                                              NSInteger code,
                                              NSString *description,
                                              NSError *underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
        description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:FMProviderPathsErrorDomain
                                 code:code
                             userInfo:userInfo];
}

static NSDictionary<NSString *, id> *_Nullable FMProviderLoadPreference(
    BOOL *present,
    NSPropertyListFormat *format,
    struct stat *metadata,
    NSError **error) {
    if (present == NULL) {
        FMProviderPathsFail(error, 1,
                            @"Provider preference output is required.", 0);
        return nil;
    }
    NSString *path = jbroot(FMProviderPreferenceLogicalPath);
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) {
            *present = NO;
            return @{};
        }
        int savedError = errno;
        *present = NO;
        FMProviderPathsFail(error, 2,
                            @"The Provider preference could not be inspected.",
                            savedError);
        return nil;
    }
    *present = YES;
    if (!S_ISREG(info.st_mode)) {
        FMProviderPathsFail(error, 2,
                            @"The Provider preference is not a regular file.",
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
        FMProviderPathsSetUnderlyingError(
            error, 2, @"The Provider preference is not a valid dictionary.",
            readError);
        return nil;
    }
    if (format != NULL) *format = detectedFormat;
    if (metadata != NULL) *metadata = info;
    return object;
}

NSDictionary<NSString *, id> *FMProviderAutoMountConfiguration(
    NSError **error) {
    BOOL present = NO;
    NSDictionary *preference = FMProviderLoadPreference(
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
        [FMAnalyzeProviderAutoMountPreference(preference) mutableCopy];
    configuration[@"preferencePresent"] = @YES;
    return configuration;
}

BOOL FMProviderAutoMountConflictsWithSystemFonts(BOOL *conflicts,
                                                 NSError **error) {
    if (conflicts == NULL) {
        return FMProviderPathsFail(
            error, 1, @"Provider automatic-mount conflict output is required.", 0);
    }
    NSDictionary *configuration = FMProviderAutoMountConfiguration(error);
    if (configuration == nil) {
        *conflicts = YES;
        return NO;
    }
    *conflicts = [configuration[@"conflictsWithFonts"] boolValue];
    return YES;
}

NSDictionary<NSString *, id> *FMDisableProviderAutoMountForSystemFonts(
    NSError **error) {
    if (getuid() != 0 || geteuid() != 0) {
        FMProviderPathsFail(
            error, 7,
            @"Changing Provider automatic mounting requires a real root caller.",
            EPERM);
        return nil;
    }

    BOOL present = NO;
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
    struct stat metadata = {0};
    NSDictionary *preference = FMProviderLoadPreference(
        &present, &format, &metadata, error);
    if (preference == nil) return nil;
    NSDictionary *before = present
        ? FMAnalyzeProviderAutoMountPreference(preference)
        : FMProviderAutoMountConfiguration(error);
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
        FMProviderPathsFail(
            error, 7,
            @"The Provider root is unsupported for automatic Fonts takeover.",
            EINVAL);
        return nil;
    }

    BOOL changed = NO;
    NSError *policyError = nil;
    NSDictionary *updated =
        FMProviderAutoMountPreferenceByRemovingSystemFonts(
            preference, &changed, &policyError);
    if (updated == nil || !changed) {
        FMProviderPathsSetUnderlyingError(
            error, 7,
            @"The Provider Fonts automatic-mount entry could not be removed.",
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
    NSString *path = jbroot(FMProviderPreferenceLogicalPath);
    if (data == nil ||
        ![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        FMProviderPathsSetUnderlyingError(
            error, 7,
            @"The Provider preference could not be updated atomically.",
            writeError);
        return nil;
    }
    if (chown(path.fileSystemRepresentation, metadata.st_uid, metadata.st_gid) != 0 ||
        chmod(path.fileSystemRepresentation, metadata.st_mode & 0777) != 0) {
        FMProviderPathsFail(
            error, 7,
            @"The updated Provider preference metadata could not be preserved.",
            errno);
        return nil;
    }

    NSDictionary *after = FMProviderAutoMountConfiguration(&writeError);
    if (after == nil || [after[@"conflictsWithFonts"] boolValue]) {
        FMProviderPathsSetUnderlyingError(
            error, 7,
            @"Provider Fonts automatic mounting remained enabled after update.",
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

NSString *FMProviderResolvedRootLogicalPath(BOOL *supported,
                                            BOOL *preferencePresent) {
    NSDictionary *configuration = FMProviderAutoMountConfiguration(NULL);
    BOOL localSupported = [configuration[@"rootSupported"] boolValue];
    BOOL localPreferencePresent =
        [configuration[@"preferencePresent"] boolValue];
    if (supported != NULL) {
        *supported = localSupported;
    }
    if (preferencePresent != NULL) {
        *preferencePresent = localPreferencePresent;
    }
    return FMProviderDefaultRootLogicalPath;
}

NSString *FMProviderResolvedMirrorLogicalPath(BOOL *supported,
                                              BOOL *preferencePresent) {
    NSString *root = FMProviderResolvedRootLogicalPath(supported,
                                                       preferencePresent);
    return [root stringByAppendingPathComponent:@"System/Library/Fonts"];
}

static NSString *FMRealPath(NSString *path) {
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (resolved == NULL) {
        return nil;
    }
    NSString *result = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:resolved
                                     length:strlen(resolved)];
    free(resolved);
    return result;
}

BOOL FMValidateProviderAlias(BOOL requirePresent,
                             BOOL *present,
                             NSError **error) {
    BOOL rootSupported = NO;
    NSString *rootLogicalPath =
        FMProviderResolvedRootLogicalPath(&rootSupported, NULL);
    if (!rootSupported) {
        if (present != NULL) {
            *present = NO;
        }
        return FMProviderPathsFail(error, 3,
                                   @"The Provider root configuration is unsupported.",
                                   0);
    }

    NSString *aliasPath = jbroot(FMProviderAliasLogicalPath);
    struct stat aliasInfo = {0};
    if (lstat(aliasPath.fileSystemRepresentation, &aliasInfo) != 0) {
        if (errno == ENOENT) {
            if (present != NULL) {
                *present = NO;
            }
            return requirePresent
                ? FMProviderPathsFail(error, 4,
                                      @"The required Provider alias is missing.", 0)
                : YES;
        }
        if (present != NULL) {
            *present = NO;
        }
        return FMProviderPathsFail(error, 4,
                                   @"The Provider alias could not be inspected.",
                                   errno);
    }
    if (present != NULL) {
        *present = YES;
    }
    if (!S_ISLNK(aliasInfo.st_mode)) {
        return FMProviderPathsFail(error, 5,
                                   @"The Provider alias is not a symbolic link.", 0);
    }

    NSString *rootPath = jbroot(rootLogicalPath);
    struct stat rootInfo = {0};
    if (lstat(rootPath.fileSystemRepresentation, &rootInfo) != 0 ||
        !S_ISDIR(rootInfo.st_mode)) {
        return FMProviderPathsFail(error, 5,
                                   @"The Provider storage root is unavailable.",
                                   errno != 0 ? errno : ENOTDIR);
    }
    NSString *resolvedAlias = FMRealPath(aliasPath);
    NSString *resolvedRoot = FMRealPath(rootPath);
    if (resolvedAlias.length == 0 || resolvedRoot.length == 0 ||
        ![resolvedAlias isEqual:resolvedRoot]) {
        return FMProviderPathsFail(error, 5,
                                   @"The Provider alias does not resolve to its storage root.",
                                   0);
    }
    return YES;
}

BOOL FMProviderManagedMappingIsActive(NSError **error) {
    BOOL rootSupported = NO;
    NSString *mirrorLogicalPath =
        FMProviderResolvedMirrorLogicalPath(&rootSupported, NULL);
    struct statfs mapping = {0};
    if (!rootSupported ||
        statfs(FMProviderSystemFontsLogicalPath.fileSystemRepresentation,
               &mapping) != 0) {
        return FMProviderPathsFail(
            error, 6, @"The active font mapping could not be inspected.",
            rootSupported ? errno : 0);
    }

    NSString *filesystemType =
        [NSString stringWithUTF8String:mapping.f_fstypename];
    NSString *target = [NSString stringWithUTF8String:mapping.f_mntonname];
    NSString *source = [NSString stringWithUTF8String:mapping.f_mntfromname];
    NSString *mirrorPath = jbroot(mirrorLogicalPath);
    BOOL exact =
        [filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame &&
        [target isEqual:FMProviderSystemFontsLogicalPath] &&
        [source.stringByResolvingSymlinksInPath
            isEqual:mirrorPath.stringByResolvingSymlinksInPath] &&
        (mapping.f_flags & MNT_RDONLY) != 0;
    return exact || FMProviderPathsFail(
        error, 6, @"The active font mapping is not the managed read-only mirror.", 0);
}
