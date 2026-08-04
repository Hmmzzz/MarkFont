#import "FMProviderPaths.h"

#import <errno.h>
#import <roothide.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>

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

BOOL FMProviderPreferenceExists(BOOL *present, NSError **error) {
    if (present == NULL) {
        return FMProviderPathsFail(error, 1,
                                   @"Provider preference output is required.", 0);
    }
    struct stat info = {0};
    if (lstat(jbroot(FMProviderPreferenceLogicalPath).fileSystemRepresentation,
              &info) == 0) {
        *present = YES;
        return YES;
    }
    if (errno == ENOENT) {
        *present = NO;
        return YES;
    }
    *present = NO;
    return FMProviderPathsFail(error, 2,
                               @"The Provider preference could not be inspected.",
                               errno);
}

NSString *FMProviderResolvedRootLogicalPath(BOOL *supported,
                                            BOOL *preferencePresent) {
    BOOL localSupported = NO;
    BOOL localPreferencePresent = NO;
    NSString *preferencePath = jbroot(FMProviderPreferenceLogicalPath);
    struct stat info = {0};
    if (lstat(preferencePath.fileSystemRepresentation, &info) != 0) {
        localSupported = errno == ENOENT;
    } else {
        localPreferencePresent = YES;
        if (S_ISREG(info.st_mode)) {
            NSDictionary *preference =
                [NSDictionary dictionaryWithContentsOfFile:preferencePath];
            NSString *configuredRoot =
                [preference[@"root"] isKindOfClass:NSString.class]
                    ? preference[@"root"]
                    : nil;
            localSupported = [configuredRoot isEqual:@".jbroot/bindfs"];
        }
    }
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
