#import "FMMirrorPreparation.h"

#import <copyfile.h>
#import <errno.h>
#import <fcntl.h>
#import <fts.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/stdio.h>
#import <unistd.h>

#import "FMTreeManifest.h"

NSString *const FMMirrorPreparationErrorDomain =
    @"com.hmmzzz.fontmanager.mirrorpreparation";

static NSError *FMMirrorError(FMMirrorPreparationErrorCode code,
                              NSString *description,
                              NSError *underlying) {
    NSMutableDictionary *userInfo =
        [NSMutableDictionary dictionaryWithObject:description
                                           forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:FMMirrorPreparationErrorDomain
                               code:code
                           userInfo:userInfo];
}

static BOOL FMMirrorFail(NSError **error,
                         FMMirrorPreparationErrorCode code,
                         NSString *description,
                         NSError *underlying) {
    if (error != NULL) {
        *error = FMMirrorError(code, description, underlying);
    }
    return NO;
}

static NSError *FMPOSIXError(int errorNumber) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errorNumber userInfo:nil];
}

static BOOL FMPhysicalDirectory(NSString *path,
                                struct stat *result,
                                NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPreflightFailed,
                            @"A required directory is unavailable.", FMPOSIXError(errno));
    }
    if (!S_ISDIR(info.st_mode)) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPreflightFailed,
                            @"A required path is not a physical directory.", nil);
    }
    if (result != NULL) {
        *result = info;
    }
    return YES;
}

static BOOL FMPathDoesNotExist(NSString *path, NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPreflightFailed,
                            @"A destination path already exists.", nil);
    }
    if (errno != ENOENT) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPreflightFailed,
                            @"A destination path could not be inspected.",
                            FMPOSIXError(errno));
    }
    return YES;
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *FMEntriesByPath(
    NSDictionary<NSString *, id> *manifest) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *entry in manifest[@"entries"]) {
        result[entry[@"relativePath"]] = entry;
    }
    return result;
}

static BOOL FMRootMetadataMatches(NSString *stockRoot,
                                  NSString *stagingRoot,
                                  NSError **error) {
    struct stat stock = {0};
    struct stat staging = {0};
    if (!FMPhysicalDirectory(stockRoot, &stock, error) ||
        !FMPhysicalDirectory(stagingRoot, &staging, error)) {
        return NO;
    }
    if ((stock.st_mode & 07777) != (staging.st_mode & 07777) ||
        stock.st_uid != staging.st_uid || stock.st_gid != staging.st_gid) {
        return FMMirrorFail(error, FMMirrorPreparationErrorVerificationFailed,
                            @"The staging root metadata differs from Stock.", nil);
    }
    return YES;
}

static BOOL FMEntryMatches(NSDictionary<NSString *, id> *stock,
                           NSDictionary<NSString *, id> *staging) {
    if (![stock[@"type"] isEqual:staging[@"type"]] ||
        ![stock[@"mode"] isEqual:staging[@"mode"]] ||
        ![stock[@"uid"] isEqual:staging[@"uid"]] ||
        ![stock[@"gid"] isEqual:staging[@"gid"]]) {
        return NO;
    }
    if ([stock[@"type"] isEqual:@"regular"]) {
        return [stock[@"size"] isEqual:staging[@"size"]] &&
               [stock[@"sha256"] isEqual:staging[@"sha256"]];
    }
    if ([stock[@"type"] isEqual:@"symlink"]) {
        return [stock[@"linkTarget"] isEqual:staging[@"linkTarget"]];
    }
    return [stock[@"type"] isEqual:@"directory"];
}

static BOOL FMVerifyMirror(NSString *stockRoot,
                           NSString *stagingRoot,
                           NSDictionary<NSString *, id> **stockManifestResult,
                           NSError **error) {
    if (!FMRootMetadataMatches(stockRoot, stagingRoot, error)) {
        return NO;
    }
    NSError *manifestError = nil;
    NSDictionary *stockManifest = FMCreateTreeManifestAtPath(stockRoot, &manifestError);
    NSDictionary *stagingManifest = FMCreateTreeManifestAtPath(stagingRoot, &manifestError);
    if (stockManifest == nil || stagingManifest == nil) {
        return FMMirrorFail(error, FMMirrorPreparationErrorVerificationFailed,
                            @"Unable to create a complete mirror manifest.", manifestError);
    }

    NSDictionary *stockEntries = FMEntriesByPath(stockManifest);
    NSDictionary *stagingEntries = FMEntriesByPath(stagingManifest);
    if (stockEntries.count != stagingEntries.count) {
        return FMMirrorFail(error, FMMirrorPreparationErrorVerificationFailed,
                            @"The staging mirror entry count differs from Stock.", nil);
    }
    for (NSString *relativePath in stockEntries) {
        NSDictionary *staging = stagingEntries[relativePath];
        if (staging == nil || !FMEntryMatches(stockEntries[relativePath], staging)) {
            return FMMirrorFail(error, FMMirrorPreparationErrorVerificationFailed,
                                @"The staging mirror differs from Stock.", nil);
        }
    }
    if (stockManifestResult != NULL) {
        *stockManifestResult = stockManifest;
    }
    return YES;
}

static BOOL FMSyncDescriptor(int descriptor, NSError **error) {
    if (fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP) {
        return YES;
    }
    return FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                        @"Unable to flush a staging entry.", FMPOSIXError(errno));
}

static BOOL FMSyncTree(NSString *rootPath, NSError **error) {
    char *root = strdup(rootPath.fileSystemRepresentation);
    if (root == NULL) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                            @"Unable to allocate the staging traversal.",
                            FMPOSIXError(ENOMEM));
    }
    char *paths[] = {root, NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) {
        int savedError = errno;
        free(root);
        return FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                            @"Unable to traverse the staging mirror.",
                            FMPOSIXError(savedError));
    }

    BOOL success = YES;
    FTSENT *entry = NULL;
    while (success && (entry = fts_read(tree)) != NULL) {
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR ||
            entry->fts_info == FTS_NS) {
            success = FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                                   @"Unable to inspect a staging entry.",
                                   FMPOSIXError(entry->fts_errno ?: EIO));
            break;
        }
        BOOL shouldSync = entry->fts_info == FTS_F || entry->fts_info == FTS_DP;
        if (!shouldSync) {
            continue;
        }
        int flags = O_RDONLY | O_CLOEXEC;
        if (entry->fts_info == FTS_DP) {
            flags |= O_DIRECTORY;
        } else {
            flags |= O_NOFOLLOW;
        }
        int descriptor = open(entry->fts_path, flags);
        if (descriptor < 0) {
            success = FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                                   @"Unable to open a staging entry for flush.",
                                   FMPOSIXError(errno));
            break;
        }
        success = FMSyncDescriptor(descriptor, error);
        int closeResult = close(descriptor);
        if (success && closeResult != 0) {
            success = FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                                   @"Unable to close a flushed staging entry.",
                                   FMPOSIXError(errno));
        }
    }
    int closeTreeResult = fts_close(tree);
    free(root);
    if (success && closeTreeResult != 0) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                            @"Unable to close the staging traversal.",
                            FMPOSIXError(errno));
    }
    return success;
}

NSDictionary<NSString *, id> *FMBuildVerifiedStockMirror(NSString *stockRoot,
                                                           NSString *stagingRoot,
                                                           NSError **error) {
    if (stockRoot.length == 0 || stagingRoot.length == 0 ||
        [stockRoot isEqual:stagingRoot]) {
        FMMirrorFail(error, FMMirrorPreparationErrorInvalidPath,
                     @"Stock and staging paths must be distinct.", nil);
        return nil;
    }
    NSString *stagingParent = stagingRoot.stringByDeletingLastPathComponent;
    if (!FMPhysicalDirectory(stockRoot, NULL, error) ||
        !FMPhysicalDirectory(stagingParent, NULL, error) ||
        !FMPathDoesNotExist(stagingRoot, error)) {
        return nil;
    }

    copyfile_flags_t flags = COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE |
                             COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST |
                             COPYFILE_EXCL;
    if (copyfile(stockRoot.fileSystemRepresentation,
                 stagingRoot.fileSystemRepresentation, NULL, flags) != 0) {
        FMMirrorFail(error, FMMirrorPreparationErrorCopyFailed,
                     @"Unable to copy Stock into the staging mirror.",
                     FMPOSIXError(errno));
        return nil;
    }

    NSDictionary *stockManifest = nil;
    if (!FMVerifyMirror(stockRoot, stagingRoot, &stockManifest, error)) {
        return nil;
    }
    return stockManifest;
}

BOOL FMPublishVerifiedStockMirror(NSString *stockRoot,
                                  NSString *stagingRoot,
                                  NSString *finalMirrorRoot,
                                  NSError **error) {
    if (stockRoot.length == 0 || stagingRoot.length == 0 || finalMirrorRoot.length == 0 ||
        [stockRoot isEqual:stagingRoot] || [stockRoot isEqual:finalMirrorRoot] ||
        [stagingRoot isEqual:finalMirrorRoot]) {
        return FMMirrorFail(error, FMMirrorPreparationErrorInvalidPath,
                            @"Stock, staging, and final paths must be distinct.", nil);
    }
    NSString *stagingParent = stagingRoot.stringByDeletingLastPathComponent;
    NSString *finalParent = finalMirrorRoot.stringByDeletingLastPathComponent;
    if (![stagingParent isEqual:finalParent]) {
        return FMMirrorFail(error, FMMirrorPreparationErrorInvalidPath,
                            @"Staging and final mirror must share one parent.", nil);
    }
    struct stat stagingParentInfo = {0};
    struct stat finalParentInfo = {0};
    if (!FMPhysicalDirectory(stagingParent, &stagingParentInfo, error) ||
        !FMPhysicalDirectory(finalParent, &finalParentInfo, error) ||
        !FMPathDoesNotExist(finalMirrorRoot, error)) {
        return NO;
    }
    if (stagingParentInfo.st_dev != finalParentInfo.st_dev) {
        return FMMirrorFail(error, FMMirrorPreparationErrorInvalidPath,
                            @"Staging and final mirror are not on the same volume.", nil);
    }
    if (!FMVerifyMirror(stockRoot, stagingRoot, NULL, error) ||
        !FMSyncTree(stagingRoot, error)) {
        return NO;
    }
    if (renamex_np(stagingRoot.fileSystemRepresentation,
                   finalMirrorRoot.fileSystemRepresentation,
                   RENAME_EXCL) != 0) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                            @"Unable to atomically publish the verified mirror.",
                            FMPOSIXError(errno));
    }
    int parentDescriptor = open(finalParent.fileSystemRepresentation,
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parentDescriptor < 0) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                            @"Unable to open the mirror parent after publish.",
                            FMPOSIXError(errno));
    }
    BOOL success = FMSyncDescriptor(parentDescriptor, error);
    int closeResult = close(parentDescriptor);
    if (success && closeResult != 0) {
        return FMMirrorFail(error, FMMirrorPreparationErrorPublishFailed,
                            @"Unable to close the mirror parent after publish.",
                            FMPOSIXError(errno));
    }
    return success;
}
