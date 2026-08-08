#import "FMDeviceSupplementalFontWorkspace.h"

#import <errno.h>
#import <fcntl.h>
#import <roothide.h>
#import <stdlib.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMMirrorPreparation.h"
#import "FMMountBackendExecutor.h"
#import "FMMountPaths.h"
#import "FMSecureDirectory.h"
#import "FMSystemFontLayout.h"
#import "FMTreeManifest.h"

NSString *const FMDeviceSupplementalFontWorkspaceErrorDomain =
    @"com.hmmzzz.fontmanager.device-supplemental-font-workspace";

static BOOL FMSupplementalFail(NSError **error,
                               NSInteger code,
                               NSString *description,
                               NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:
            FMDeviceSupplementalFontWorkspaceErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *FMSupplementalPOSIXError(int errorNumber) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:errorNumber
                           userInfo:nil];
}

static BOOL FMSupplementalBuildIsSafe(NSString *systemBuild) {
    return [systemBuild isKindOfClass:NSString.class] &&
        systemBuild.length > 0 && systemBuild.length <= 32 &&
        !systemBuild.isAbsolutePath && systemBuild.pathComponents.count == 1 &&
        [systemBuild.lastPathComponent isEqual:systemBuild] &&
        ![systemBuild isEqual:@"."] && ![systemBuild isEqual:@".."];
}

static NSString *FMSupplementalPhysicalDirectory(NSString *path,
                                                 NSError **error) {
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (resolved == NULL) {
        FMSupplementalFail(
            error, 2, @"A supplemental workspace anchor could not be resolved.",
            FMSupplementalPOSIXError(errno));
        return nil;
    }
    NSString *result = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:resolved
                                     length:strlen(resolved)];
    free(resolved);
    return result;
}

static BOOL FMSupplementalRequireSecureDirectory(NSString *path,
                                                 NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return FMSupplementalFail(
            error, 2, @"A supplemental workspace directory has unsafe metadata.",
            FMSupplementalPOSIXError(errno ?: EPERM));
    }
    return YES;
}

static BOOL FMSupplementalRequireSecureManifestFile(NSString *path,
                                                    NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return FMSupplementalFail(
            error, 2, @"The supplemental Stock manifest has unsafe metadata.",
            FMSupplementalPOSIXError(errno ?: EPERM));
    }
    return YES;
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
FMSupplementalEntriesByPath(NSDictionary<NSString *, id> *manifest) {
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *entry in manifest[@"entries"]) {
        entries[entry[@"relativePath"]] = entry;
    }
    return entries;
}

static BOOL FMSupplementalMirrorStructureMatches(
    NSDictionary<NSString *, id> *stockManifest,
    NSDictionary<NSString *, id> *mirrorManifest) {
    NSDictionary *stock = FMSupplementalEntriesByPath(stockManifest);
    NSDictionary *mirror = FMSupplementalEntriesByPath(mirrorManifest);
    if (stock.count != mirror.count) return NO;
    for (NSString *relativePath in stock) {
        NSDictionary *left = stock[relativePath];
        NSDictionary *right = mirror[relativePath];
        if (right == nil || ![left[@"type"] isEqual:right[@"type"]] ||
            ![left[@"mode"] isEqual:right[@"mode"]] ||
            ![left[@"uid"] isEqual:right[@"uid"]] ||
            ![left[@"gid"] isEqual:right[@"gid"]]) {
            return NO;
        }
        if ([left[@"type"] isEqual:@"symlink"] &&
            ![left[@"linkTarget"] isEqual:right[@"linkTarget"]]) {
            return NO;
        }
    }
    return YES;
}

static BOOL FMSupplementalManifestContainsPingFangUI(
    NSDictionary<NSString *, id> *manifest) {
    for (NSDictionary<NSString *, id> *entry in manifest[@"entries"]) {
        if ([entry[@"relativePath"] isEqual:@"PingFangUI.ttc"] &&
            [entry[@"type"] isEqual:@"regular"] &&
            [entry[@"size"] unsignedLongLongValue] > 0) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSString *, id> *FMSupplementalReadManifest(
    NSString *path,
    NSError **error) {
    if (!FMSupplementalRequireSecureManifestFile(path, error)) return nil;
    NSError *readError = nil;
    id manifest = FMReadJSONObjectAtPath(path, &readError);
    if (![manifest isKindOfClass:NSDictionary.class] ||
        !FMValidateManifestDocument(manifest, &readError) ||
        !FMSupplementalManifestContainsPingFangUI(manifest)) {
        FMSupplementalFail(error, 3,
                           @"The supplemental Stock manifest is invalid.",
                           readError);
        return nil;
    }
    return manifest;
}

static BOOL FMSupplementalSourceIsEligible(NSString *sourceRoot,
                                           BOOL *present,
                                           NSError **error) {
    if (present == NULL) {
        return FMSupplementalFail(
            error, 1, @"The supplemental source result is unavailable.", nil);
    }
    NSString *fontPath = [sourceRoot stringByAppendingPathComponent:@"PingFangUI.ttc"];
    struct stat fontInfo = {0};
    errno = 0;
    if (lstat(fontPath.fileSystemRepresentation, &fontInfo) != 0) {
        if (errno == ENOENT) {
            *present = NO;
            return YES;
        }
        *present = NO;
        return FMSupplementalFail(
            error, 2, @"The supplemental Stock font could not be inspected.",
            FMSupplementalPOSIXError(errno));
    }
    if (!S_ISREG(fontInfo.st_mode) || fontInfo.st_size <= 0) {
        *present = NO;
        return FMSupplementalFail(
            error, 2, @"The supplemental Stock font is not a regular file.", nil);
    }
    struct stat rootInfo = {0};
    struct statfs filesystem = {0};
    if (lstat(sourceRoot.fileSystemRepresentation, &rootInfo) != 0 ||
        !S_ISDIR(rootInfo.st_mode) ||
        statfs(sourceRoot.fileSystemRepresentation, &filesystem) != 0 ||
        (filesystem.f_flags & MNT_RDONLY) == 0) {
        *present = NO;
        return FMSupplementalFail(
            error, 2,
            @"The supplemental Stock source is not an immutable directory.",
            FMSupplementalPOSIXError(errno ?: EPERM));
    }
    *present = YES;
    return YES;
}

static BOOL FMSupplementalTargetIsInactive(NSError **error) {
    struct statfs filesystem = {0};
    if (statfs(FMMountFontServicesCorePrivateLogicalPath.fileSystemRepresentation,
               &filesystem) != 0) {
        return FMSupplementalFail(
            error, 2, @"The supplemental system target could not be inspected.",
            FMSupplementalPOSIXError(errno));
    }
    NSString *target = [NSString stringWithUTF8String:filesystem.f_mntonname];
    NSString *type = [NSString stringWithUTF8String:filesystem.f_fstypename];
    if ([target isEqual:FMMountFontServicesCorePrivateLogicalPath] ||
        [type caseInsensitiveCompare:@"bindfs"] == NSOrderedSame) {
        return FMSupplementalFail(
            error, 2,
            @"An active mapping blocks supplemental Stock preparation.", nil);
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMSupplementalValidatePreparedWorkspace(
    NSString *manifestPath,
    NSString *stockSnapshotRoot,
    NSString *mirrorRoot,
    NSError **error) {
    NSDictionary *baseline = FMSupplementalReadManifest(manifestPath, error);
    if (baseline == nil ||
        !FMSupplementalRequireSecureDirectory(stockSnapshotRoot, error) ||
        !FMSupplementalRequireSecureDirectory(mirrorRoot, error)) {
        return nil;
    }
    NSError *manifestError = nil;
    NSDictionary *snapshot = FMCreateTreeManifestAtPath(
        stockSnapshotRoot, &manifestError);
    NSDictionary *mirror = FMCreateTreeManifestAtPath(mirrorRoot, &manifestError);
    if (![snapshot isEqual:baseline] || mirror == nil ||
        !FMSupplementalMirrorStructureMatches(baseline, mirror)) {
        FMSupplementalFail(
            error, 3,
            @"The supplemental Stock snapshot or mirror no longer matches its baseline.",
            manifestError);
        return nil;
    }
    return baseline;
}

NSDictionary<NSString *, id> *
FMEnsureDeviceSupplementalFontWorkspaceWithExistingLock(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (geteuid() != 0 || !FMSupplementalBuildIsSafe(confirmedSystemBuild)) {
        FMSupplementalFail(
            error, 1, @"Supplemental font preparation requires root and a safe build.", nil);
        return nil;
    }

    NSError *layoutError = nil;
    FMSystemFontLayout layout = FMCurrentSystemFontLayout(
        confirmedSystemBuild, &layoutError);
    if (layout == FMSystemFontLayoutUnsupported) {
        FMSupplementalFail(
            error, 1, @"The current system font layout is unsupported.",
            layoutError);
        return nil;
    }
    if (layout == FMSystemFontLayoutPrimaryFonts) {
        return @{
            @"schemaVersion" : @1,
            @"operation" : @"ensureSupplementalFontWorkspace",
            @"status" : @"notRequired",
            @"systemBuild" : confirmedSystemBuild,
            @"workspaceCreated" : @NO,
            @"mappingChanged" : @NO,
        };
    }

    NSString *sourceRoot = FMMountResolvedStockFontServicesCorePrivatePath();
    NSString *mirrorRoot = FMMountResolvedFontServicesCorePrivateMirrorPath();
    NSString *mirrorParent = mirrorRoot.stringByDeletingLastPathComponent;
    NSString *mirrorStaging = [mirrorParent
        stringByAppendingPathComponent:@".CorePrivate.fontmanager-staging"];
    NSString *stockBuildRoot = [jbroot(@"/var/lib/fontmanager/stock")
        stringByAppendingPathComponent:confirmedSystemBuild];
    NSString *stockSnapshotRoot = [stockBuildRoot
        stringByAppendingPathComponent:FMFontCatalogFontServicesCorePrivatePrefix];
    NSString *stockStaging = [stockBuildRoot
        stringByAppendingPathComponent:@".FontServicesCorePrivate.fontmanager-staging"];
    NSString *baselineBuildRoot = [jbroot(@"/var/lib/fontmanager/baseline")
        stringByAppendingPathComponent:confirmedSystemBuild];
    NSString *manifestPath = [baselineBuildRoot
        stringByAppendingPathComponent:@"fontservices-coreprivate-manifest.json"];

    struct stat manifestInfo = {0};
    errno = 0;
    BOOL manifestPresent =
        lstat(manifestPath.fileSystemRepresentation, &manifestInfo) == 0;
    if (!manifestPresent && errno != ENOENT) {
        FMSupplementalFail(
            error, 2, @"The supplemental baseline could not be inspected.",
            FMSupplementalPOSIXError(errno));
        return nil;
    }

    BOOL sourcePresent = NO;
    if (!manifestPresent &&
        !FMSupplementalSourceIsEligible(sourceRoot, &sourcePresent, error)) {
        return nil;
    }
    if (!manifestPresent && !sourcePresent) {
        FMSupplementalFail(
            error, 2,
            @"The confirmed iOS 18-26 PingFangUI Stock source is unavailable.",
            nil);
        return nil;
    }

    BOOL workspaceCreated = NO;
    if (!manifestPresent) {
        if (!FMSupplementalTargetIsInactive(error)) return nil;
        NSString *bootstrapRoot =
            FMSupplementalPhysicalDirectory(jbroot(@"/"), error);
        if (bootstrapRoot == nil ||
            !FMSupplementalRequireSecureDirectory(stockBuildRoot, error) ||
            !FMSupplementalRequireSecureDirectory(baselineBuildRoot, error) ||
            !FMEnsureSecureDirectoryTree(
                bootstrapRoot,
                @[ @"bindfs", @"System", @"Library", @"PrivateFrameworks",
                   @"FontServices.framework" ],
                0, 0, 0755, error)) {
            return nil;
        }

        NSError *manifestError = nil;
        NSDictionary *sourceManifest =
            FMCreateTreeManifestAtPath(sourceRoot, &manifestError);
        if (sourceManifest == nil ||
            !FMSupplementalManifestContainsPingFangUI(sourceManifest)) {
            FMSupplementalFail(
                error, 3, @"The supplemental Stock tree is invalid.", manifestError);
            return nil;
        }

        struct stat mirrorInfo = {0};
        errno = 0;
        BOOL mirrorPresent = lstat(mirrorRoot.fileSystemRepresentation,
                                   &mirrorInfo) == 0;
        if (!mirrorPresent && errno != ENOENT) {
            FMSupplementalFail(error, 3,
                               @"The supplemental mirror could not be inspected.",
                               FMSupplementalPOSIXError(errno));
            return nil;
        }
        if (!mirrorPresent) {
            NSDictionary *built = FMBuildVerifiedStockMirror(
                sourceRoot, mirrorStaging, &manifestError);
            if (![built isEqual:sourceManifest] ||
                !FMPublishVerifiedStockMirror(
                    sourceRoot, mirrorStaging, mirrorRoot, &manifestError)) {
                FMSupplementalFail(
                    error, 4,
                    @"The supplemental mirror could not be copied and published safely.",
                    manifestError);
                return nil;
            }
            workspaceCreated = YES;
        } else {
            NSDictionary *existing = FMCreateTreeManifestAtPath(
                mirrorRoot, &manifestError);
            if (![existing isEqual:sourceManifest]) {
                FMSupplementalFail(
                    error, 4,
                    @"An unclaimed supplemental mirror differs from Stock.",
                    manifestError);
                return nil;
            }
        }

        struct stat snapshotInfo = {0};
        errno = 0;
        BOOL snapshotPresent = lstat(stockSnapshotRoot.fileSystemRepresentation,
                                     &snapshotInfo) == 0;
        if (!snapshotPresent && errno != ENOENT) {
            FMSupplementalFail(error, 4,
                               @"The supplemental Stock snapshot could not be inspected.",
                               FMSupplementalPOSIXError(errno));
            return nil;
        }
        if (!snapshotPresent) {
            NSDictionary *built = FMBuildVerifiedStockMirror(
                sourceRoot, stockStaging, &manifestError);
            if (![built isEqual:sourceManifest] ||
                !FMPublishVerifiedStockMirror(
                    sourceRoot, stockStaging, stockSnapshotRoot, &manifestError)) {
                FMSupplementalFail(
                    error, 4,
                    @"The supplemental Stock snapshot could not be published safely.",
                    manifestError);
                return nil;
            }
            workspaceCreated = YES;
        } else {
            NSDictionary *existing = FMCreateTreeManifestAtPath(
                stockSnapshotRoot, &manifestError);
            if (![existing isEqual:sourceManifest]) {
                FMSupplementalFail(
                    error, 4,
                    @"The existing supplemental Stock snapshot differs from rootfs.",
                    manifestError);
                return nil;
            }
        }

        if (!FMWriteJSONObjectAtomically(
                sourceManifest, manifestPath, 0644, &manifestError)) {
            FMSupplementalFail(
                error, 4,
                @"The supplemental Stock baseline could not be saved atomically.",
                manifestError);
            return nil;
        }
    }

    if (FMSupplementalValidatePreparedWorkspace(
            manifestPath, stockSnapshotRoot, mirrorRoot, error) == nil) {
        return nil;
    }

    BOOL mappingWasActive = FMMountManagedMappingIsActive(NULL);
    NSError *mountError = nil;
    NSDictionary *mount = FMInvokeMountBackendForPreparedSystemFonts(&mountError);
    if (mount == nil || ![mount[@"reportedSuccess"] boolValue] ||
        !FMMountManagedMappingIsActive(&mountError)) {
        FMSupplementalFail(
            error, 5,
            @"The supplemental read-only mapping could not be activated.",
            mountError);
        return nil;
    }

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"ensureSupplementalFontWorkspace",
        @"status" : workspaceCreated ? @"prepared" : @"alreadyPrepared",
        @"systemBuild" : confirmedSystemBuild,
        @"workspaceCreated" : workspaceCreated ? @YES : @NO,
        @"mappingChanged" : mappingWasActive ? @NO : @YES,
        @"mirrorLogicalPath" : FMMountFontServicesCorePrivateMirrorLogicalPath,
        @"targetLogicalPath" : FMMountFontServicesCorePrivateLogicalPath,
    };
}
