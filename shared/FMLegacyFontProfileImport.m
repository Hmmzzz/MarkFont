#import "FMLegacyFontProfileImport.h"

#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/stdio.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMProfileAdoptionValidator.h"
#import "FMTreeManifest.h"

NSString *const FMLegacyFontProfileImportErrorDomain =
    @"com.hmmzzz.fontmanager.legacy-font-profile-import";

typedef NS_ENUM(NSInteger, FMLegacyFontProfileImportErrorCode) {
    FMLegacyFontProfileImportErrorInvalidInput = 1,
    FMLegacyFontProfileImportErrorFilesystem = 2,
    FMLegacyFontProfileImportErrorProfile = 3,
};

static BOOL FMLegacyImportFail(
    NSError **error,
    FMLegacyFontProfileImportErrorCode code,
    NSString *description,
    NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMLegacyFontProfileImportErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *FMLegacyImportPOSIXError(int errorNumber) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:errorNumber
                           userInfo:nil];
}

static BOOL FMLegacyImportSafeProfileID(NSString *profileID) {
    NSDictionary *probe = @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"id" : profileID ?: @"",
        @"name" : @"Profile",
        @"systemBuild" : @"BUILD",
        @"replacements" : @[],
    };
    return [profileID hasPrefix:@"import-"] &&
        FMValidateProfileDocument(probe, nil);
}

static BOOL FMLegacyImportRequireDirectory(NSString *path,
                                           uid_t owner,
                                           gid_t group,
                                           NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode) || info.st_uid != owner ||
        info.st_gid != group ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        int savedError = errno != 0 ? errno : EPERM;
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"The Profile library has unsafe type, ownership, or permissions.",
            FMLegacyImportPOSIXError(savedError));
    }
    return YES;
}

static BOOL FMLegacyImportRequireSourceRoot(NSString *path,
                                            NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode)) {
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A font-tree source is unavailable.",
            FMLegacyImportPOSIXError(errno != 0 ? errno : ENOTDIR));
    }
    return YES;
}

static BOOL FMLegacyImportPathAbsent(NSString *path, NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A Profile publication path already exists.", nil);
    }
    if (errno != ENOENT) {
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A Profile publication path could not be inspected.",
            FMLegacyImportPOSIXError(errno));
    }
    return YES;
}

static BOOL FMLegacyImportCreateDirectory(NSString *path,
                                          uid_t owner,
                                          gid_t group,
                                          NSError **error) {
    if (mkdir(path.fileSystemRepresentation, 0700) != 0) {
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A Profile staging directory could not be created.",
            FMLegacyImportPOSIXError(errno));
    }
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        int savedError = errno;
        rmdir(path.fileSystemRepresentation);
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A new Profile directory could not be opened.",
            FMLegacyImportPOSIXError(savedError));
    }
    BOOL success = fchown(descriptor, owner, group) == 0 &&
        fchmod(descriptor, 0700) == 0;
    int savedError = success ? 0 : errno;
    if (close(descriptor) != 0 && success) {
        success = NO;
        savedError = errno;
    }
    if (!success) {
        rmdir(path.fileSystemRepresentation);
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A new Profile directory could not be secured.",
            FMLegacyImportPOSIXError(savedError));
    }
    return YES;
}

static NSString *FMLegacyImportHexDigest(
    const unsigned char digest[CC_SHA256_DIGEST_LENGTH]) {
    NSMutableString *result =
        [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

static NSString *FMLegacyImportCopyFile(NSString *sourcePath,
                                        NSString *destinationPath,
                                        uid_t owner,
                                        gid_t group,
                                        NSError **error) {
    int source = open(sourcePath.fileSystemRepresentation,
                      O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (source < 0) {
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A changed legacy font could not be opened.",
            FMLegacyImportPOSIXError(errno));
        return nil;
    }
    struct stat sourceInfo = {0};
    if (fstat(source, &sourceInfo) != 0 || !S_ISREG(sourceInfo.st_mode) ||
        sourceInfo.st_size <= 0) {
        int savedError = errno != 0 ? errno : EINVAL;
        close(source);
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A changed legacy font is not a nonempty regular file.",
            FMLegacyImportPOSIXError(savedError));
        return nil;
    }

    int destination = open(destinationPath.fileSystemRepresentation,
                           O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                           0600);
    if (destination < 0) {
        int savedError = errno;
        close(source);
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A Profile replacement file could not be created.",
            FMLegacyImportPOSIXError(savedError));
        return nil;
    }

    CC_SHA256_CTX context;
    BOOL success = CC_SHA256_Init(&context) == 1;
    int savedError = success ? 0 : EIO;
    uint8_t buffer[64 * 1024];
    while (success) {
        ssize_t count = read(source, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            success = NO;
            savedError = errno;
            break;
        }
        if (count == 0) break;
        if (CC_SHA256_Update(&context, buffer, (CC_LONG)count) != 1) {
            success = NO;
            savedError = EIO;
            break;
        }
        const uint8_t *cursor = buffer;
        size_t remaining = (size_t)count;
        while (remaining > 0) {
            ssize_t written = write(destination, cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                success = NO;
                savedError = written < 0 ? errno : EIO;
                break;
            }
            cursor += (size_t)written;
            remaining -= (size_t)written;
        }
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    if (success && CC_SHA256_Final(digest, &context) != 1) {
        success = NO;
        savedError = EIO;
    }
    if (success &&
        (fchown(destination, owner, group) != 0 ||
         fchmod(destination, 0600) != 0 || fsync(destination) != 0)) {
        success = NO;
        savedError = errno;
    }
    if (close(source) != 0 && success) {
        success = NO;
        savedError = errno;
    }
    if (close(destination) != 0 && success) {
        success = NO;
        savedError = errno;
    }
    if (!success) {
        unlink(destinationPath.fileSystemRepresentation);
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A changed legacy font could not be copied into the Profile.",
            FMLegacyImportPOSIXError(savedError));
        return nil;
    }
    return FMLegacyImportHexDigest(digest);
}

static BOOL FMLegacyImportSetFileIdentity(NSString *path,
                                          uid_t owner,
                                          gid_t group,
                                          NSError **error) {
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"Profile metadata could not be opened.",
            FMLegacyImportPOSIXError(errno));
    }
    BOOL success = fchown(descriptor, owner, group) == 0 &&
        fchmod(descriptor, 0600) == 0 && fsync(descriptor) == 0;
    int savedError = success ? 0 : errno;
    if (close(descriptor) != 0 && success) {
        success = NO;
        savedError = errno;
    }
    return success || FMLegacyImportFail(
        error, FMLegacyFontProfileImportErrorFilesystem,
        @"Profile metadata ownership could not be set.",
        FMLegacyImportPOSIXError(savedError));
}

static BOOL FMLegacyImportSyncDirectory(NSString *path, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A Profile publication directory could not be opened.",
            FMLegacyImportPOSIXError(errno));
    }
    int syncResult = fsync(descriptor);
    int savedError = syncResult == 0 ? 0 : errno;
    int closeResult = close(descriptor);
    if ((syncResult != 0 && savedError != EINVAL && savedError != ENOTSUP) ||
        closeResult != 0) {
        return FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"A Profile publication directory could not be synchronized.",
            FMLegacyImportPOSIXError(syncResult != 0 ? savedError : errno));
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMLegacyImportExistingProfile(
    NSString *profilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    NSError *previewError = nil;
    NSDictionary *preview = FMCreateProfileAdoptionPreviewAtRoot(
        profilesRoot, profileID, systemBuild, catalog, &previewError);
    if (preview == nil) {
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorProfile,
            @"The existing installation-time Profile is invalid.", previewError);
        return nil;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"importLegacyFontProfile",
        @"status" : @"alreadyImported",
        @"systemBuild" : systemBuild,
        @"profileCreated" : @YES,
        @"profileID" : profileID,
        @"profileName" : preview[@"profileName"],
        @"replacementCount" : preview[@"replacementCount"],
        @"replacementBytes" : preview[@"replacementBytes"],
        @"stockCompared" : @YES,
        @"filesystemMutated" : @NO,
    };
}

NSDictionary<NSString *, id> *FMImportLegacyFontTreeAsProfile(
    NSString *legacyRoot,
    NSString *stockRoot,
    NSString *profilesRoot,
    NSString *systemBuild,
    NSString *profileID,
    NSString *profileName,
    uid_t owner,
    gid_t group,
    NSError **error) {
    NSString *name = [profileName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (legacyRoot.length == 0 || stockRoot.length == 0 ||
        profilesRoot.length == 0 || systemBuild.length == 0 ||
        !FMLegacyImportSafeProfileID(profileID) || name.length == 0 ||
        name.length > 80 || [legacyRoot isEqual:stockRoot]) {
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorInvalidInput,
            @"Legacy Profile import inputs are invalid.", nil);
        return nil;
    }
    if (!FMLegacyImportRequireSourceRoot(legacyRoot, error) ||
        !FMLegacyImportRequireSourceRoot(stockRoot, error) ||
        !FMLegacyImportRequireDirectory(profilesRoot, owner, group, error)) {
        return nil;
    }

    NSError *catalogError = nil;
    NSDictionary *stockManifest = FMCreateTreeManifestAtPath(stockRoot, &catalogError);
    NSString *manifestHash = stockManifest != nil
        ? FMSHA256ForJSONObject(stockManifest, &catalogError) : nil;
    NSDictionary *catalog = manifestHash != nil
        ? FMCreateFontCatalogFromManifest(
            stockManifest, systemBuild, manifestHash, &catalogError)
        : nil;
    if (catalog == nil) {
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorProfile,
            @"A Stock font catalog could not be created for legacy import.",
            catalogError);
        return nil;
    }

    NSString *finalDirectory =
        [profilesRoot stringByAppendingPathComponent:profileID];
    struct stat finalInfo = {0};
    errno = 0;
    if (lstat(finalDirectory.fileSystemRepresentation, &finalInfo) == 0) {
        if (S_ISDIR(finalInfo.st_mode)) {
            return FMLegacyImportExistingProfile(
                profilesRoot, profileID, systemBuild, catalog, error);
        }
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"The final Profile path is not a directory.", nil);
        return nil;
    }
    if (errno != ENOENT) {
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"The final Profile path could not be inspected.",
            FMLegacyImportPOSIXError(errno));
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *changes =
        [NSMutableArray array];
    for (NSDictionary<NSString *, id> *stockFile in catalog[@"files"]) {
        NSString *relativePath = stockFile[@"relativePath"];
        NSString *legacyPath = [legacyRoot stringByAppendingPathComponent:relativePath];
        struct stat legacyInfo = {0};
        if (lstat(legacyPath.fileSystemRepresentation, &legacyInfo) != 0 ||
            !S_ISREG(legacyInfo.st_mode) || legacyInfo.st_size <= 0) {
            continue;
        }
        NSError *hashError = nil;
        NSString *legacyHash = FMSHA256ForFileAtPath(legacyPath, &hashError);
        if (legacyHash == nil) {
            FMLegacyImportFail(
                error, FMLegacyFontProfileImportErrorFilesystem,
                @"A legacy font could not be compared with Stock.", hashError);
            return nil;
        }
        if (![legacyHash isEqual:stockFile[@"stockSHA256"]]) {
            [changes addObject:@{
                @"sourcePath" : legacyPath,
                @"fontFileID" : stockFile[@"id"],
                @"relativePath" : relativePath,
            }];
        }
    }

    if (changes.count == 0) {
        return @{
            @"schemaVersion" : @1,
            @"operation" : @"importLegacyFontProfile",
            @"status" : @"noChanges",
            @"systemBuild" : systemBuild,
            @"profileCreated" : @NO,
            @"profileID" : NSNull.null,
            @"profileName" : name,
            @"replacementCount" : @0,
            @"replacementBytes" : @0,
            @"stockCompared" : @YES,
            @"filesystemMutated" : @NO,
        };
    }

    NSString *stagingName =
        [NSString stringWithFormat:@".%@.fontmanager-staging", profileID];
    NSString *stagingDirectory =
        [profilesRoot stringByAppendingPathComponent:stagingName];
    NSString *replacementsDirectory =
        [stagingDirectory stringByAppendingPathComponent:@"replacements"];
    if (!FMLegacyImportPathAbsent(stagingDirectory, error) ||
        !FMLegacyImportCreateDirectory(stagingDirectory, owner, group, error)) {
        return nil;
    }
    if (!FMLegacyImportCreateDirectory(replacementsDirectory, owner, group,
                                       error)) {
        [NSFileManager.defaultManager removeItemAtPath:stagingDirectory error:nil];
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *replacements =
        [NSMutableArray arrayWithCapacity:changes.count];
    unsigned long long replacementBytes = 0;
    NSError *writeError = nil;
    for (NSUInteger index = 0; index < changes.count; index++) {
        NSDictionary<NSString *, id> *change = changes[index];
        NSString *extension = [change[@"relativePath"] pathExtension].lowercaseString;
        NSString *fileName = [NSString stringWithFormat:@"replacement-%04lu.%@",
                                                        (unsigned long)(index + 1),
                                                        extension];
        NSString *destinationPath =
            [replacementsDirectory stringByAppendingPathComponent:fileName];
        NSString *copiedHash = FMLegacyImportCopyFile(
            change[@"sourcePath"], destinationPath, owner, group, &writeError);
        struct stat copiedInfo = {0};
        if (copiedHash == nil ||
            lstat(destinationPath.fileSystemRepresentation, &copiedInfo) != 0 ||
            !S_ISREG(copiedInfo.st_mode)) {
            [NSFileManager.defaultManager removeItemAtPath:stagingDirectory error:nil];
            FMLegacyImportFail(
                error, FMLegacyFontProfileImportErrorFilesystem,
                @"A changed legacy font could not be stored in the Profile.",
                writeError);
            return nil;
        }
        replacementBytes += (unsigned long long)copiedInfo.st_size;
        [replacements addObject:@{
            @"fontFileID" : change[@"fontFileID"],
            @"relativePath" : change[@"relativePath"],
            @"fileName" : fileName,
            @"sha256" : copiedHash,
        }];
    }

    NSDictionary<NSString *, id> *profile = @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"id" : profileID,
        @"name" : name,
        @"systemBuild" : systemBuild,
        @"replacements" : replacements,
    };
    NSString *profilePath =
        [stagingDirectory stringByAppendingPathComponent:@"profile.json"];
    NSError *profileError = nil;
    if (!FMValidateProfileDocument(profile, &profileError) ||
        !FMWriteJSONObjectAtomically(profile, profilePath, 0600, &profileError) ||
        !FMLegacyImportSetFileIdentity(profilePath, owner, group, &profileError) ||
        !FMLegacyImportSyncDirectory(replacementsDirectory, &profileError) ||
        !FMLegacyImportSyncDirectory(stagingDirectory, &profileError)) {
        [NSFileManager.defaultManager removeItemAtPath:stagingDirectory error:nil];
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorProfile,
            @"The installation-time Profile could not be generated.", profileError);
        return nil;
    }
    if (renamex_np(stagingDirectory.fileSystemRepresentation,
                   finalDirectory.fileSystemRepresentation, RENAME_EXCL) != 0) {
        int savedError = errno;
        [NSFileManager.defaultManager removeItemAtPath:stagingDirectory error:nil];
        FMLegacyImportFail(
            error, FMLegacyFontProfileImportErrorFilesystem,
            @"The installation-time Profile could not be published.",
            FMLegacyImportPOSIXError(savedError));
        return nil;
    }
    if (!FMLegacyImportSyncDirectory(profilesRoot, error)) return nil;

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"importLegacyFontProfile",
        @"status" : @"imported",
        @"systemBuild" : systemBuild,
        @"profileCreated" : @YES,
        @"profileID" : profileID,
        @"profileName" : name,
        @"replacementCount" : @(replacements.count),
        @"replacementBytes" : @(replacementBytes),
        @"stockCompared" : @YES,
        @"filesystemMutated" : @YES,
    };
}
