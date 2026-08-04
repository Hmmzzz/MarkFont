#import "FMProfileAdoption.h"

#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/stdio.h>
#import <unistd.h>

#import "FMProfileAdoptionValidator.h"

NSString *const FMProfileAdoptionErrorDomain =
    @"com.hmmzzz.fontmanager.profile-adoption";

typedef NS_ENUM(NSInteger, FMProfileAdoptionErrorCode) {
    FMProfileAdoptionErrorInvalidInput = 1,
    FMProfileAdoptionErrorUnsafeDestination = 2,
    FMProfileAdoptionErrorCopyFailed = 3,
    FMProfileAdoptionErrorVerificationFailed = 4,
    FMProfileAdoptionErrorPublishFailed = 5,
};

static BOOL FMProfileAdoptionFail(NSError **error,
                                  FMProfileAdoptionErrorCode code,
                                  NSString *description,
                                  NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMProfileAdoptionErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *FMAdoptionPOSIXError(int errorNumber) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errorNumber userInfo:nil];
}

static NSString *FMAdoptionHexDigest(
    const unsigned char digest[CC_SHA256_DIGEST_LENGTH]) {
    NSMutableString *result =
        [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

static BOOL FMAdoptionPathAbsent(NSString *path, NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorUnsafeDestination,
                                     @"A Profile publication path already exists.", nil);
    }
    if (errno != ENOENT) {
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorUnsafeDestination,
                                     @"A Profile publication path could not be inspected.",
                                     FMAdoptionPOSIXError(errno));
    }
    return YES;
}

static BOOL FMAdoptionValidateDestinationRoot(NSString *path,
                                              uid_t owner,
                                              gid_t group,
                                              NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode) || info.st_uid != owner || info.st_gid != group ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        NSError *underlying = errno != 0 ? FMAdoptionPOSIXError(errno) : nil;
        return FMProfileAdoptionFail(
            error, FMProfileAdoptionErrorUnsafeDestination,
            @"The privileged Profile root has unsafe type, ownership, or permissions.",
            underlying);
    }
    return YES;
}

static BOOL FMAdoptionValidatePublishedMetadata(
    NSDictionary<NSString *, id> *preview,
    uid_t owner,
    gid_t group,
    NSError **error) {
    NSArray<NSDictionary<NSString *, id> *> *paths = @[
        @{ @"path" : preview[@"profileDirectory"], @"directory" : @YES },
        @{ @"path" : preview[@"replacementsDirectory"], @"directory" : @YES },
        @{ @"path" : preview[@"profilePath"], @"directory" : @NO },
    ];
    NSMutableArray<NSDictionary<NSString *, id> *> *records = [paths mutableCopy];
    for (NSDictionary *target in preview[@"targets"]) {
        [records addObject:@{
            @"path" : [preview[@"replacementsDirectory"]
                stringByAppendingPathComponent:target[@"fileName"]],
            @"directory" : @NO,
        }];
    }
    for (NSDictionary *record in records) {
        struct stat info = {0};
        errno = 0;
        BOOL directory = [record[@"directory"] boolValue];
        mode_t expectedMode = directory ? 0700 : 0600;
        if (lstat([record[@"path"] fileSystemRepresentation], &info) != 0 ||
            (directory ? !S_ISDIR(info.st_mode) : !S_ISREG(info.st_mode)) ||
            info.st_uid != owner || info.st_gid != group ||
            (info.st_mode & 0777) != expectedMode) {
            NSError *underlying = errno != 0 ? FMAdoptionPOSIXError(errno) : nil;
            return FMProfileAdoptionFail(
                error, FMProfileAdoptionErrorUnsafeDestination,
                @"A privileged Profile path has unsafe metadata.", underlying);
        }
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMAdoptionReport(
    NSDictionary<NSString *, id> *preview,
    NSString *status,
    BOOL published,
    BOOL mutated) {
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"adoptProfile",
        @"status" : status,
        @"systemBuild" : preview[@"profileDocument"][@"systemBuild"],
        @"profileID" : preview[@"profileID"],
        @"profileName" : preview[@"profileName"],
        @"profileJSONSHA256" : preview[@"profileJSONSHA256"],
        @"replacementCount" : preview[@"replacementCount"],
        @"replacementBytes" : preview[@"replacementBytes"],
        @"relativePaths" : preview[@"relativePaths"],
        @"profilePublished" : published ? @YES : @NO,
        @"profileAlreadyPresent" : published ? @NO : @YES,
        @"filesystemMutated" : mutated ? @YES : @NO,
        @"sourceModified" : @NO,
        @"mirrorChanged" : @NO,
        @"stateChanged" : @NO,
        @"mountBackendInvoked" : @NO,
        @"restartRequested" : @NO,
    };
}

static BOOL FMAdoptionSecureDirectory(NSString *path,
                                      uid_t owner,
                                      gid_t group,
                                      NSError **error) {
    if (mkdir(path.fileSystemRepresentation, 0700) != 0) {
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                     @"Unable to create a privileged Profile directory.",
                                     FMAdoptionPOSIXError(errno));
    }
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        int savedError = errno;
        rmdir(path.fileSystemRepresentation);
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                     @"Unable to open a new privileged Profile directory.",
                                     FMAdoptionPOSIXError(savedError));
    }
    BOOL success = fchown(descriptor, owner, group) == 0 &&
                   fchmod(descriptor, 0700) == 0 &&
                   (fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP);
    int savedError = success ? 0 : errno;
    if (close(descriptor) != 0 && success) {
        success = NO;
        savedError = errno;
    }
    if (!success) {
        rmdir(path.fileSystemRepresentation);
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                     @"Unable to secure a privileged Profile directory.",
                                     FMAdoptionPOSIXError(savedError));
    }
    return YES;
}

static BOOL FMAdoptionWriteAll(int descriptor,
                               const void *bytes,
                               size_t length,
                               NSError **error) {
    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            return FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                         @"Unable to write a privileged Profile file.",
                                         FMAdoptionPOSIXError(written < 0 ? errno : EIO));
        }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    return YES;
}

static BOOL FMAdoptionCopyExclusive(NSString *sourcePath,
                                    NSString *destinationPath,
                                    NSString *expectedSHA256,
                                    uid_t owner,
                                    gid_t group,
                                    NSError **error) {
    int source = open(sourcePath.fileSystemRepresentation,
                      O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (source < 0) {
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                     @"Unable to open an imported Profile file.",
                                     FMAdoptionPOSIXError(errno));
    }
    struct stat sourceInfo = {0};
    if (fstat(source, &sourceInfo) != 0 || !S_ISREG(sourceInfo.st_mode) ||
        sourceInfo.st_size <= 0) {
        int savedError = errno;
        close(source);
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                     @"An imported Profile source is not a nonempty regular file.",
                                     savedError != 0 ? FMAdoptionPOSIXError(savedError) : nil);
    }

    int destination = open(destinationPath.fileSystemRepresentation,
                           O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                           0600);
    if (destination < 0) {
        int savedError = errno;
        close(source);
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                     @"Unable to create a privileged Profile file.",
                                     FMAdoptionPOSIXError(savedError));
    }

    CC_SHA256_CTX context;
    BOOL success = CC_SHA256_Init(&context) == 1;
    if (!success) {
        FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                              @"Unable to initialize adoption SHA-256.", nil);
    }
    uint8_t buffer[64 * 1024];
    while (success) {
        ssize_t count = read(source, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            success = FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                            @"Unable to read an imported Profile file.",
                                            FMAdoptionPOSIXError(errno));
            break;
        }
        if (count == 0) break;
        if (CC_SHA256_Update(&context, buffer, (CC_LONG)count) != 1) {
            success = FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                            @"Unable to update adoption SHA-256.", nil);
            break;
        }
        success = FMAdoptionWriteAll(destination, buffer, (size_t)count, error);
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    if (success && CC_SHA256_Final(digest, &context) != 1) {
        success = FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                        @"Unable to finalize adoption SHA-256.", nil);
    }
    if (success && ![FMAdoptionHexDigest(digest) isEqual:expectedSHA256]) {
        success = FMProfileAdoptionFail(error, FMProfileAdoptionErrorVerificationFailed,
                                        @"Imported Profile bytes changed during adoption.", nil);
    }
    if (success && (fchown(destination, owner, group) != 0 ||
                    fchmod(destination, 0600) != 0 || fsync(destination) != 0)) {
        success = FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                        @"Unable to secure a privileged Profile file.",
                                        FMAdoptionPOSIXError(errno));
    }
    if (close(source) != 0 && success) {
        success = FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                        @"Unable to close an imported Profile file.",
                                        FMAdoptionPOSIXError(errno));
    }
    if (close(destination) != 0 && success) {
        success = FMProfileAdoptionFail(error, FMProfileAdoptionErrorCopyFailed,
                                        @"Unable to close a privileged Profile file.",
                                        FMAdoptionPOSIXError(errno));
    }
    if (!success) unlink(destinationPath.fileSystemRepresentation);
    return success;
}

static BOOL FMAdoptionSyncDirectory(NSString *path, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorPublishFailed,
                                     @"Unable to open a Profile directory for synchronization.",
                                     FMAdoptionPOSIXError(errno));
    }
    BOOL success = fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP;
    int savedError = success ? 0 : errno;
    if (close(descriptor) != 0 && success) {
        success = NO;
        savedError = errno;
    }
    if (!success) {
        return FMProfileAdoptionFail(error, FMProfileAdoptionErrorPublishFailed,
                                     @"Unable to synchronize a Profile directory.",
                                     FMAdoptionPOSIXError(savedError));
    }
    return YES;
}

static void FMAdoptionCleanupUnpublished(NSString *stagingDirectory,
                                         NSString *replacementsDirectory,
                                         NSArray<NSString *> *createdFiles) {
    for (NSString *path in createdFiles.reverseObjectEnumerator) {
        unlink(path.fileSystemRepresentation);
    }
    rmdir(replacementsDirectory.fileSystemRepresentation);
    rmdir(stagingDirectory.fileSystemRepresentation);
}

NSDictionary<NSString *, id> *FMPublishProfileAdoptionAtRoots(
    NSString *sourceProfilesRoot,
    NSString *destinationProfilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    uid_t destinationUID,
    gid_t destinationGID,
    NSError **error) {
    if (sourceProfilesRoot.length == 0 || destinationProfilesRoot.length == 0 ||
        [sourceProfilesRoot isEqual:destinationProfilesRoot]) {
        FMProfileAdoptionFail(error, FMProfileAdoptionErrorInvalidInput,
                              @"Profile adoption roots are invalid.", nil);
        return nil;
    }
    NSError *validationError = nil;
    NSDictionary *sourcePreview = FMCreateProfileAdoptionPreviewAtRoot(
        sourceProfilesRoot, profileID, systemBuild, catalog, &validationError);
    if (sourcePreview == nil ||
        !FMAdoptionValidateDestinationRoot(destinationProfilesRoot, destinationUID,
                                           destinationGID, &validationError)) {
        if (error != NULL) *error = validationError;
        return nil;
    }

    NSString *stagingName =
        [NSString stringWithFormat:@".%@.fontmanager-staging", profileID];
    NSString *stagingDirectory =
        [destinationProfilesRoot stringByAppendingPathComponent:stagingName];
    NSString *finalDirectory =
        [destinationProfilesRoot stringByAppendingPathComponent:profileID];
    if (!FMAdoptionPathAbsent(stagingDirectory, error)) {
        return nil;
    }
    struct stat finalInfo = {0};
    errno = 0;
    int finalResult = lstat(finalDirectory.fileSystemRepresentation, &finalInfo);
    int finalError = errno;
    if (finalResult == 0) {
        NSDictionary *existingPreview = S_ISDIR(finalInfo.st_mode)
            ? FMCreateProfileAdoptionPreviewAtRoot(
                destinationProfilesRoot, profileID, systemBuild, catalog,
                &validationError)
            : nil;
        BOOL existingMatches = existingPreview != nil &&
            [existingPreview[@"profileJSONSHA256"]
                isEqual:sourcePreview[@"profileJSONSHA256"]] &&
            [existingPreview[@"targets"] isEqual:sourcePreview[@"targets"]] &&
            FMAdoptionValidatePublishedMetadata(existingPreview, destinationUID,
                                                destinationGID, &validationError);
        if (!existingMatches) {
            FMProfileAdoptionFail(
                error, FMProfileAdoptionErrorUnsafeDestination,
                @"An existing privileged Profile does not exactly match the imported source.",
                validationError);
            return nil;
        }
        return FMAdoptionReport(existingPreview, @"alreadyAdopted", NO, NO);
    }
    if (finalError != ENOENT) {
        FMProfileAdoptionFail(error, FMProfileAdoptionErrorUnsafeDestination,
                              @"The final privileged Profile path could not be inspected.",
                              FMAdoptionPOSIXError(finalError));
        return nil;
    }

    NSString *stagingReplacements =
        [stagingDirectory stringByAppendingPathComponent:@"replacements"];
    NSMutableArray<NSString *> *createdFiles = [NSMutableArray array];
    if (!FMAdoptionSecureDirectory(stagingDirectory, destinationUID,
                                   destinationGID, error)) {
        return nil;
    }
    if (!FMAdoptionSecureDirectory(stagingReplacements, destinationUID,
                                   destinationGID, error)) {
        rmdir(stagingDirectory.fileSystemRepresentation);
        return nil;
    }

    NSString *destinationProfilePath =
        [stagingDirectory stringByAppendingPathComponent:@"profile.json"];
    if (!FMAdoptionCopyExclusive(sourcePreview[@"profilePath"], destinationProfilePath,
                                 sourcePreview[@"profileJSONSHA256"], destinationUID,
                                 destinationGID, error)) {
        FMAdoptionCleanupUnpublished(stagingDirectory, stagingReplacements, createdFiles);
        return nil;
    }
    [createdFiles addObject:destinationProfilePath];

    NSString *sourceReplacements = sourcePreview[@"replacementsDirectory"];
    for (NSDictionary *target in sourcePreview[@"targets"]) {
        NSString *fileName = target[@"fileName"];
        NSString *sourcePath = [sourceReplacements stringByAppendingPathComponent:fileName];
        NSString *destinationPath =
            [stagingReplacements stringByAppendingPathComponent:fileName];
        if (!FMAdoptionCopyExclusive(sourcePath, destinationPath, target[@"sha256"],
                                     destinationUID, destinationGID, error)) {
            FMAdoptionCleanupUnpublished(stagingDirectory, stagingReplacements, createdFiles);
            return nil;
        }
        [createdFiles addObject:destinationPath];
    }

    NSDictionary *stagingPreview = FMCreateProfileAdoptionPreviewAtDirectory(
        destinationProfilesRoot, stagingName, profileID, systemBuild, catalog,
        &validationError);
    NSDictionary *sourceAfterCopy = FMCreateProfileAdoptionPreviewAtRoot(
        sourceProfilesRoot, profileID, systemBuild, catalog, &validationError);
    BOOL copiesMatch = stagingPreview != nil && sourceAfterCopy != nil &&
        [stagingPreview[@"profileJSONSHA256"]
            isEqual:sourcePreview[@"profileJSONSHA256"]] &&
        [stagingPreview[@"targets"] isEqual:sourcePreview[@"targets"]] &&
        [sourceAfterCopy[@"profileJSONSHA256"]
            isEqual:sourcePreview[@"profileJSONSHA256"]] &&
        [sourceAfterCopy[@"targets"] isEqual:sourcePreview[@"targets"]];
    if (!copiesMatch) {
        FMAdoptionCleanupUnpublished(stagingDirectory, stagingReplacements, createdFiles);
        FMProfileAdoptionFail(error, FMProfileAdoptionErrorVerificationFailed,
                              @"The privileged Profile copy failed final verification.",
                              validationError);
        return nil;
    }
    if (!FMAdoptionSyncDirectory(stagingReplacements, error) ||
        !FMAdoptionSyncDirectory(stagingDirectory, error)) {
        FMAdoptionCleanupUnpublished(stagingDirectory, stagingReplacements, createdFiles);
        return nil;
    }

    if (renamex_np(stagingDirectory.fileSystemRepresentation,
                   finalDirectory.fileSystemRepresentation, RENAME_EXCL) != 0) {
        int savedError = errno;
        FMAdoptionCleanupUnpublished(stagingDirectory, stagingReplacements, createdFiles);
        FMProfileAdoptionFail(error, FMProfileAdoptionErrorPublishFailed,
                              @"Unable to atomically publish the privileged Profile.",
                              FMAdoptionPOSIXError(savedError));
        return nil;
    }
    if (!FMAdoptionSyncDirectory(destinationProfilesRoot, error)) return nil;

    NSDictionary *finalPreview = FMCreateProfileAdoptionPreviewAtRoot(
        destinationProfilesRoot, profileID, systemBuild, catalog, &validationError);
    if (finalPreview == nil ||
        ![finalPreview[@"profileJSONSHA256"]
            isEqual:sourcePreview[@"profileJSONSHA256"]] ||
        ![finalPreview[@"targets"] isEqual:sourcePreview[@"targets"]] ||
        !FMAdoptionValidatePublishedMetadata(finalPreview, destinationUID,
                                             destinationGID, &validationError)) {
        FMProfileAdoptionFail(error, FMProfileAdoptionErrorVerificationFailed,
                              @"Published privileged Profile verification failed.",
                              validationError);
        return nil;
    }

    return FMAdoptionReport(finalPreview, @"adopted", YES, YES);
}
