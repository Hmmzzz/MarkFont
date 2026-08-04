#import "FMFileStore.h"

#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const FMFileStoreErrorDomain = @"com.hmmzzz.fontmanager.filestore";

static NSError *FMFileStorePOSIXError(NSString *operation, NSString *path, int errorNumber) {
    NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:errorNumber userInfo:nil];
    return [NSError errorWithDomain:FMFileStoreErrorDomain
                               code:FMFileStoreErrorFilesystem
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   [NSString stringWithFormat:@"%@ failed for %@: %@",
                                                              operation, path,
                                                              underlying.localizedDescription],
                               NSUnderlyingErrorKey : underlying,
                           }];
}

static BOOL FMFileStoreFail(NSError **error,
                            FMFileStoreErrorCode code,
                            NSString *message) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:FMFileStoreErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey : message}];
    }
    return NO;
}

static BOOL FMSetPOSIXError(NSError **error,
                            NSString *operation,
                            NSString *path,
                            int errorNumber) {
    if (error != NULL) {
        *error = FMFileStorePOSIXError(operation, path, errorNumber);
    }
    return NO;
}

static BOOL FMWriteAll(int descriptor,
                       const void *bytes,
                       size_t length,
                       NSString *path,
                       NSError **error) {
    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            int savedError = written < 0 ? errno : EIO;
            return FMSetPOSIXError(error, @"write", path, savedError);
        }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    return YES;
}

static BOOL FMSyncDirectory(NSString *directoryPath, NSError **error) {
    int descriptor = open(directoryPath.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0) {
        return FMSetPOSIXError(error, @"open directory", directoryPath, errno);
    }
    if (fsync(descriptor) != 0) {
        int savedError = errno;
        close(descriptor);
        if (savedError == EINVAL || savedError == ENOTSUP) {
            return YES;
        }
        return FMSetPOSIXError(error, @"fsync directory", directoryPath, savedError);
    }
    if (close(descriptor) != 0) {
        return FMSetPOSIXError(error, @"close directory", directoryPath, errno);
    }
    return YES;
}

static BOOL FMIsLowercaseSHA256(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 64) {
        return NO;
    }
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [value rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static NSString *FMHexDigest(const unsigned char digest[CC_SHA256_DIGEST_LENGTH]) {
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

id FMReadJSONObjectAtPath(NSString *path, NSError **error) {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (data == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:FMFileStoreErrorDomain
                                         code:FMFileStoreErrorFilesystem
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             [NSString stringWithFormat:@"Unable to read JSON at %@.",
                                                                        path],
                                         NSUnderlyingErrorKey : readError,
                                     }];
        }
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (object == nil && error != NULL) {
        *error = [NSError errorWithDomain:FMFileStoreErrorDomain
                                     code:FMFileStoreErrorJSON
                                 userInfo:@{
                                     NSLocalizedDescriptionKey :
                                         [NSString stringWithFormat:@"Invalid JSON at %@.", path],
                                     NSUnderlyingErrorKey : jsonError,
                                 }];
    }
    return object;
}

BOOL FMWriteJSONObjectAtomically(id object, NSString *path, mode_t mode, NSError **error) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return FMFileStoreFail(error, FMFileStoreErrorJSON,
                               @"Object is not a valid JSON document.");
    }
    if (path.length == 0 || path.lastPathComponent.length == 0) {
        return FMFileStoreFail(error, FMFileStoreErrorInvalidArgument,
                               @"JSON target path is invalid.");
    }

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (data == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:FMFileStoreErrorDomain
                                         code:FMFileStoreErrorJSON
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @"Unable to serialize JSON.",
                                         NSUnderlyingErrorKey : jsonError,
                                     }];
        }
        return NO;
    }

    NSString *directoryPath = path.stringByDeletingLastPathComponent;
    if (directoryPath.length == 0) {
        directoryPath = @".";
    }
    struct stat directoryInfo = {0};
    if (lstat(directoryPath.fileSystemRepresentation, &directoryInfo) != 0 ||
        !S_ISDIR(directoryInfo.st_mode)) {
        int savedError = errno != 0 ? errno : ENOTDIR;
        return FMSetPOSIXError(error, @"validate parent directory", directoryPath, savedError);
    }

    struct stat targetInfo = {0};
    int inspectResult = lstat(path.fileSystemRepresentation, &targetInfo);
    if (inspectResult == 0 && !S_ISREG(targetInfo.st_mode)) {
        return FMFileStoreFail(error, FMFileStoreErrorUnsupportedFile,
                               @"JSON target exists but is not a regular file.");
    }
    if (inspectResult != 0 && errno != ENOENT) {
        return FMSetPOSIXError(error, @"inspect JSON target", path, errno);
    }

    NSString *temporaryPath = [directoryPath
        stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.tmp",
                                                                   path.lastPathComponent,
                                                                   NSUUID.UUID.UUIDString]];
    int descriptor = open(temporaryPath.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          mode & 0777);
    if (descriptor < 0) {
        return FMSetPOSIXError(error, @"create temporary JSON", temporaryPath, errno);
    }

    BOOL success = FMWriteAll(descriptor, data.bytes, data.length, temporaryPath, error);
    if (success && fchmod(descriptor, mode & 0777) != 0) {
        success = FMSetPOSIXError(error, @"chmod temporary JSON", temporaryPath, errno);
    }
    if (success && fsync(descriptor) != 0) {
        success = FMSetPOSIXError(error, @"fsync temporary JSON", temporaryPath, errno);
    }
    if (close(descriptor) != 0 && success) {
        success = FMSetPOSIXError(error, @"close temporary JSON", temporaryPath, errno);
    }
    if (!success) {
        unlink(temporaryPath.fileSystemRepresentation);
        return NO;
    }

    if (rename(temporaryPath.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        int savedError = errno;
        unlink(temporaryPath.fileSystemRepresentation);
        return FMSetPOSIXError(error, @"rename temporary JSON", path, savedError);
    }
    return FMSyncDirectory(directoryPath, error);
}

BOOL FMWriteJSONObjectAtomicallyIfAbsent(id object,
                                         NSString *path,
                                         mode_t mode,
                                         NSError **error) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return FMFileStoreFail(error, FMFileStoreErrorJSON,
                               @"Object is not a valid JSON document.");
    }
    if (path.length == 0 || path.lastPathComponent.length == 0) {
        return FMFileStoreFail(error, FMFileStoreErrorInvalidArgument,
                               @"JSON target path is invalid.");
    }

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (data == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:FMFileStoreErrorDomain
                                         code:FMFileStoreErrorJSON
                                     userInfo:@{
                                         NSLocalizedDescriptionKey : @"Unable to serialize JSON.",
                                         NSUnderlyingErrorKey : jsonError,
                                     }];
        }
        return NO;
    }

    NSString *directoryPath = path.stringByDeletingLastPathComponent;
    if (directoryPath.length == 0) {
        directoryPath = @".";
    }
    struct stat directoryInfo = {0};
    if (lstat(directoryPath.fileSystemRepresentation, &directoryInfo) != 0 ||
        !S_ISDIR(directoryInfo.st_mode)) {
        int savedError = errno != 0 ? errno : ENOTDIR;
        return FMSetPOSIXError(error, @"validate parent directory", directoryPath,
                               savedError);
    }

    NSString *temporaryPath = [directoryPath
        stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.tmp",
                                                                   path.lastPathComponent,
                                                                   NSUUID.UUID.UUIDString]];
    int descriptor = open(temporaryPath.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          mode & 0777);
    if (descriptor < 0) {
        return FMSetPOSIXError(error, @"create temporary JSON", temporaryPath, errno);
    }

    BOOL success = FMWriteAll(descriptor, data.bytes, data.length, temporaryPath, error);
    if (success && fchmod(descriptor, mode & 0777) != 0) {
        success = FMSetPOSIXError(error, @"chmod temporary JSON", temporaryPath, errno);
    }
    if (success && fsync(descriptor) != 0) {
        success = FMSetPOSIXError(error, @"fsync temporary JSON", temporaryPath, errno);
    }
    if (close(descriptor) != 0 && success) {
        success = FMSetPOSIXError(error, @"close temporary JSON", temporaryPath, errno);
    }
    if (!success) {
        unlink(temporaryPath.fileSystemRepresentation);
        return NO;
    }

    if (renamex_np(temporaryPath.fileSystemRepresentation,
                   path.fileSystemRepresentation, RENAME_EXCL) != 0) {
        int savedError = errno;
        unlink(temporaryPath.fileSystemRepresentation);
        return FMSetPOSIXError(error, @"publish exclusive JSON", path, savedError);
    }
    return FMSyncDirectory(directoryPath, error);
}

NSString *FMSHA256ForFileAtPath(NSString *path, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        FMSetPOSIXError(error, @"open for SHA-256", path, errno);
        return nil;
    }

    struct stat info = {0};
    if (fstat(descriptor, &info) != 0) {
        int savedError = errno;
        close(descriptor);
        FMSetPOSIXError(error, @"fstat for SHA-256", path, savedError);
        return nil;
    }
    if (!S_ISREG(info.st_mode)) {
        close(descriptor);
        FMFileStoreFail(error, FMFileStoreErrorUnsupportedFile,
                        @"SHA-256 source must be a regular file.");
        return nil;
    }

    CC_SHA256_CTX context;
    if (CC_SHA256_Init(&context) != 1) {
        close(descriptor);
        FMFileStoreFail(error, FMFileStoreErrorFilesystem,
                        @"Unable to initialize SHA-256.");
        return nil;
    }

    uint8_t buffer[64 * 1024];
    while (YES) {
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            int savedError = errno;
            close(descriptor);
            FMSetPOSIXError(error, @"read for SHA-256", path, savedError);
            return nil;
        }
        if (count == 0) {
            break;
        }
        if (CC_SHA256_Update(&context, buffer, (CC_LONG)count) != 1) {
            close(descriptor);
            FMFileStoreFail(error, FMFileStoreErrorFilesystem,
                            @"Unable to update SHA-256.");
            return nil;
        }
    }
    if (close(descriptor) != 0) {
        FMSetPOSIXError(error, @"close SHA-256 source", path, errno);
        return nil;
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (CC_SHA256_Final(digest, &context) != 1) {
        FMFileStoreFail(error, FMFileStoreErrorFilesystem,
                        @"Unable to finalize SHA-256.");
        return nil;
    }
    return FMHexDigest(digest);
}

NSString *FMSHA256ForJSONObject(id object, NSError **error) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        FMFileStoreFail(error, FMFileStoreErrorJSON,
                        @"Object is not a valid JSON document.");
        return nil;
    }
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingSortedKeys
                                                     error:&jsonError];
    if (data == nil || data.length > UINT_MAX) {
        if (error != NULL) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
                data == nil ? @"Unable to serialize JSON for SHA-256."
                            : @"JSON is too large for SHA-256."
                forKey:NSLocalizedDescriptionKey];
            if (jsonError != nil) {
                userInfo[NSUnderlyingErrorKey] = jsonError;
            }
            *error = [NSError errorWithDomain:FMFileStoreErrorDomain
                                         code:FMFileStoreErrorJSON
                                     userInfo:userInfo];
        }
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (CC_SHA256(data.bytes, (CC_LONG)data.length, digest) == NULL) {
        FMFileStoreFail(error, FMFileStoreErrorFilesystem,
                        @"Unable to hash the JSON document.");
        return nil;
    }
    return FMHexDigest(digest);
}

static BOOL FMValidateRegularPath(NSString *path,
                                  NSString *purpose,
                                  struct stat *result,
                                  NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        return FMSetPOSIXError(error, purpose, path, errno);
    }
    if (!S_ISREG(info.st_mode)) {
        return FMFileStoreFail(error, FMFileStoreErrorUnsupportedFile,
                               [NSString stringWithFormat:@"%@ must be a regular file: %@",
                                                          purpose, path]);
    }
    if (result != NULL) {
        *result = info;
    }
    return YES;
}

BOOL FMCopyRegularFileAtomically(NSString *sourcePath,
                                 NSString *metadataSourcePath,
                                 NSString *targetPath,
                                 NSString *expectedSHA256,
                                 NSError **error) {
    if (!FMIsLowercaseSHA256(expectedSHA256)) {
        return FMFileStoreFail(error, FMFileStoreErrorInvalidArgument,
                               @"Expected SHA-256 is invalid.");
    }

    struct stat metadataInfo = {0};
    if (!FMValidateRegularPath(sourcePath, @"validate copy source", NULL, error) ||
        !FMValidateRegularPath(metadataSourcePath, @"validate metadata source", &metadataInfo,
                               error) ||
        !FMValidateRegularPath(targetPath, @"validate mirror target", NULL, error)) {
        return NO;
    }

    NSString *directoryPath = targetPath.stringByDeletingLastPathComponent;
    NSString *temporaryPath = [directoryPath
        stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.tmp",
                                                                   targetPath.lastPathComponent,
                                                                   NSUUID.UUID.UUIDString]];
    int sourceDescriptor = open(sourcePath.fileSystemRepresentation,
                                O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (sourceDescriptor < 0) {
        return FMSetPOSIXError(error, @"open copy source", sourcePath, errno);
    }
    int temporaryDescriptor = open(temporaryPath.fileSystemRepresentation,
                                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                   metadataInfo.st_mode & 07777);
    if (temporaryDescriptor < 0) {
        int savedError = errno;
        close(sourceDescriptor);
        return FMSetPOSIXError(error, @"create temporary mirror file", temporaryPath,
                               savedError);
    }

    CC_SHA256_CTX context;
    BOOL success = CC_SHA256_Init(&context) == 1;
    if (!success) {
        FMFileStoreFail(error, FMFileStoreErrorFilesystem,
                        @"Unable to initialize copy SHA-256.");
    }
    uint8_t buffer[64 * 1024];
    while (success) {
        ssize_t count = read(sourceDescriptor, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            success = FMSetPOSIXError(error, @"read copy source", sourcePath, errno);
            break;
        }
        if (count == 0) break;
        if (CC_SHA256_Update(&context, buffer, (CC_LONG)count) != 1) {
            success = FMFileStoreFail(error, FMFileStoreErrorFilesystem,
                                      @"Unable to update copy SHA-256.");
            break;
        }
        success = FMWriteAll(temporaryDescriptor, buffer, (size_t)count,
                             temporaryPath, error);
    }

    unsigned char copiedDigest[CC_SHA256_DIGEST_LENGTH];
    if (success && CC_SHA256_Final(copiedDigest, &context) != 1) {
        success = FMFileStoreFail(error, FMFileStoreErrorFilesystem,
                                  @"Unable to finalize copy SHA-256.");
    }
    if (success && ![FMHexDigest(copiedDigest) isEqualToString:expectedSHA256]) {
        success = FMFileStoreFail(error, FMFileStoreErrorHashMismatch,
                                  @"Bytes copied into the temporary file changed unexpectedly.");
    }

    struct stat temporaryInfo = {0};
    if (success && fstat(temporaryDescriptor, &temporaryInfo) != 0) {
        success = FMSetPOSIXError(error, @"inspect temporary mirror file",
                                  temporaryPath, errno);
    }
    if (success &&
        (temporaryInfo.st_uid != metadataInfo.st_uid ||
         temporaryInfo.st_gid != metadataInfo.st_gid) &&
        fchown(temporaryDescriptor, metadataInfo.st_uid, metadataInfo.st_gid) != 0) {
        success = FMSetPOSIXError(error, @"chown temporary mirror file",
                                  temporaryPath, errno);
    }
    if (success && fchmod(temporaryDescriptor, metadataInfo.st_mode & 07777) != 0) {
        success = FMSetPOSIXError(error, @"chmod temporary mirror file",
                                  temporaryPath, errno);
    }
    if (success && fsync(temporaryDescriptor) != 0) {
        success = FMSetPOSIXError(error, @"fsync temporary mirror file",
                                  temporaryPath, errno);
    }

    if (close(sourceDescriptor) != 0 && success) {
        success = FMSetPOSIXError(error, @"close copy source", sourcePath, errno);
    }
    if (close(temporaryDescriptor) != 0 && success) {
        success = FMSetPOSIXError(error, @"close temporary mirror file",
                                  temporaryPath, errno);
    }
    if (!success) {
        unlink(temporaryPath.fileSystemRepresentation);
        return NO;
    }

    if (rename(temporaryPath.fileSystemRepresentation,
               targetPath.fileSystemRepresentation) != 0) {
        int savedError = errno;
        unlink(temporaryPath.fileSystemRepresentation);
        return FMSetPOSIXError(error, @"rename temporary mirror file",
                               targetPath, savedError);
    }
    if (!FMSyncDirectory(directoryPath, error)) return NO;

    NSError *hashError = nil;
    NSString *targetHash = FMSHA256ForFileAtPath(targetPath, &hashError);
    if (targetHash == nil) {
        if (error != NULL) {
            *error = hashError;
        }
        return NO;
    }
    if (![targetHash isEqualToString:expectedSHA256]) {
        return FMFileStoreFail(error, FMFileStoreErrorHashMismatch,
                               @"Committed mirror target SHA-256 verification failed.");
    }
    return YES;
}
