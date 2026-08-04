#import "FMOperationLock.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const FMOperationLockErrorDomain =
    @"com.hmmzzz.fontmanager.operation-lock";

static BOOL FMOperationLockFail(NSError **error,
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
        *error = [NSError errorWithDomain:FMOperationLockErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

int FMAcquireExclusiveDirectoryLock(NSString *directoryPath,
                                    uid_t expectedUID,
                                    gid_t expectedGID,
                                    NSError **error) {
    if (directoryPath.length == 0) {
        FMOperationLockFail(error, 1, @"The operation lock path is invalid.", 0);
        return -1;
    }
    int descriptor = open(directoryPath.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        FMOperationLockFail(error, 2,
                            @"The operation lock directory could not be opened.", errno);
        return -1;
    }
    struct stat info = {0};
    int inspectResult = fstat(descriptor, &info);
    if (inspectResult != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != expectedUID || info.st_gid != expectedGID ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        int savedError = inspectResult == 0 ? 0 : errno;
        close(descriptor);
        FMOperationLockFail(error, 3,
                            @"The operation lock directory has unsafe metadata.",
                            savedError);
        return -1;
    }
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        int savedError = errno;
        close(descriptor);
        FMOperationLockFail(
            error, savedError == EWOULDBLOCK ? 4 : 5,
            savedError == EWOULDBLOCK
                ? @"Another Font Manager engine operation is already running."
                : @"The operation lock could not be acquired.",
            savedError);
        return -1;
    }
    return descriptor;
}

BOOL FMReleaseExclusiveDirectoryLock(int descriptor, NSError **error) {
    if (descriptor < 0) {
        return FMOperationLockFail(error, 1,
                                   @"The operation lock descriptor is invalid.", 0);
    }
    int unlockResult = flock(descriptor, LOCK_UN);
    int unlockError = unlockResult == 0 ? 0 : errno;
    int closeResult = close(descriptor);
    int closeError = closeResult == 0 ? 0 : errno;
    if (unlockResult != 0 || closeResult != 0) {
        return FMOperationLockFail(error, 6,
                                   @"The operation lock could not be released cleanly.",
                                   unlockError != 0 ? unlockError : closeError);
    }
    return YES;
}
