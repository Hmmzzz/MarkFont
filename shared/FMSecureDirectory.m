#import "FMSecureDirectory.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const FMSecureDirectoryErrorDomain =
    @"com.hmmzzz.fontmanager.securedirectory";

static BOOL FMSecureDirectoryFail(NSError **error,
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
        *error = [NSError errorWithDomain:FMSecureDirectoryErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMIsSafeComponent(NSString *component) {
    if (![component isKindOfClass:NSString.class] || component.length == 0 ||
        [component isEqualToString:@"."] || [component isEqualToString:@".."] ||
        component.isAbsolutePath || component.pathComponents.count != 1 ||
        ![component.lastPathComponent isEqualToString:component]) {
        return NO;
    }
    unichar nul = 0;
    NSString *nulString = [NSString stringWithCharacters:&nul length:1];
    return [component rangeOfString:nulString].location == NSNotFound &&
           component.fileSystemRepresentation != NULL;
}

static BOOL FMSyncDirectoryDescriptor(int descriptor, NSError **error) {
    if (fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP) {
        return YES;
    }
    return FMSecureDirectoryFail(error, 5, @"Unable to flush a directory.", errno);
}

static BOOL FMValidateDirectoryDescriptor(int descriptor,
                                          uid_t expectedUID,
                                          gid_t expectedGID,
                                          NSString *description,
                                          NSError **error) {
    struct stat info = {0};
    if (fstat(descriptor, &info) != 0) {
        return FMSecureDirectoryFail(error, 3,
                                     @"Unable to inspect a secure directory.", errno);
    }
    if (!S_ISDIR(info.st_mode)) {
        return FMSecureDirectoryFail(error, 3,
                                     @"A secure path component is not a directory.", 0);
    }
    if (info.st_uid != expectedUID || info.st_gid != expectedGID) {
        return FMSecureDirectoryFail(
            error, 3,
            [NSString stringWithFormat:@"%@ has an unexpected owner.", description], 0);
    }
    if ((info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return FMSecureDirectoryFail(
            error, 3,
            [NSString stringWithFormat:@"%@ is writable by an unsafe principal.",
                                       description],
            0);
    }
    return YES;
}

static int FMOpenSecureDirectoryTree(NSString *anchorPath,
                                     NSArray<NSString *> *components,
                                     uid_t expectedUID,
                                     gid_t expectedGID,
                                     mode_t creationMode,
                                     BOOL createMissing,
                                     NSError **error) {
    if (anchorPath.length == 0 || (creationMode & ~0777) != 0) {
        FMSecureDirectoryFail(error, 1, @"Secure directory arguments are invalid.", 0);
        return -1;
    }
    for (NSString *component in components) {
        if (!FMIsSafeComponent(component)) {
            FMSecureDirectoryFail(error, 1,
                                  @"A secure directory component is invalid.", 0);
            return -1;
        }
    }

    int current = open(anchorPath.fileSystemRepresentation,
                       O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (current < 0) {
        FMSecureDirectoryFail(error, 2,
                              @"Unable to open the secure directory anchor.", errno);
        return -1;
    }
    if (!FMValidateDirectoryDescriptor(current, expectedUID, expectedGID,
                                       @"The secure directory anchor", error)) {
        close(current);
        return -1;
    }

    for (NSString *component in components) {
        const char *name = component.fileSystemRepresentation;
        BOOL created = NO;
        if (createMissing) {
            created = mkdirat(current, name, creationMode & 0777) == 0;
        }
        if (createMissing && !created && errno != EEXIST) {
            int savedError = errno;
            close(current);
            FMSecureDirectoryFail(error, 2,
                                  @"Unable to create a secure directory component.",
                                  savedError);
            return -1;
        }

        int next = openat(current, name,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) {
            int savedError = errno;
            close(current);
            FMSecureDirectoryFail(error, 3,
                                  @"Unable to open a secure directory component.",
                                  savedError);
            return -1;
        }
        if (created) {
            if (fchown(next, expectedUID, expectedGID) != 0 ||
                fchmod(next, creationMode & 0777) != 0 ||
                !FMSyncDirectoryDescriptor(next, error) ||
                !FMSyncDirectoryDescriptor(current, error)) {
                int savedError = errno;
                close(next);
                close(current);
                if (error != NULL && *error == nil) {
                    FMSecureDirectoryFail(error, 4,
                                          @"Unable to secure a new directory component.",
                                          savedError);
                }
                return -1;
            }
        }
        if (!FMValidateDirectoryDescriptor(next, expectedUID, expectedGID,
                                           @"A secure directory component", error)) {
            close(next);
            close(current);
            return -1;
        }
        close(current);
        current = next;
    }
    return current;
}

BOOL FMEnsureSecureDirectoryTree(NSString *anchorPath,
                                 NSArray<NSString *> *components,
                                 uid_t expectedUID,
                                 gid_t expectedGID,
                                 mode_t creationMode,
                                 NSError **error) {
    int descriptor = FMOpenSecureDirectoryTree(anchorPath, components, expectedUID,
                                                expectedGID, creationMode, YES, error);
    if (descriptor < 0) {
        return NO;
    }
    if (close(descriptor) != 0) {
        return FMSecureDirectoryFail(error, 5,
                                     @"Unable to close a secure directory.", errno);
    }
    return YES;
}

BOOL FMValidateSecureDirectoryTree(NSString *anchorPath,
                                   NSArray<NSString *> *components,
                                   uid_t expectedUID,
                                   gid_t expectedGID,
                                   NSError **error) {
    int descriptor = FMOpenSecureDirectoryTree(anchorPath, components, expectedUID,
                                                expectedGID, 0755, NO, error);
    if (descriptor < 0) {
        return NO;
    }
    if (close(descriptor) != 0) {
        return FMSecureDirectoryFail(error, 5,
                                     @"Unable to close a secure directory.", errno);
    }
    return YES;
}

BOOL FMCreateSecureLeafDirectory(NSString *anchorPath,
                                 NSArray<NSString *> *parentComponents,
                                 NSString *leafComponent,
                                 uid_t expectedUID,
                                 gid_t expectedGID,
                                 mode_t creationMode,
                                 NSError **error) {
    if (!FMIsSafeComponent(leafComponent)) {
        return FMSecureDirectoryFail(error, 1,
                                     @"The secure leaf component is invalid.", 0);
    }
    int parent = FMOpenSecureDirectoryTree(anchorPath, parentComponents, expectedUID,
                                           expectedGID, creationMode, YES, error);
    if (parent < 0) {
        return NO;
    }
    if (mkdirat(parent, leafComponent.fileSystemRepresentation,
                creationMode & 0777) != 0) {
        int savedError = errno;
        close(parent);
        return FMSecureDirectoryFail(
            error, 6,
            savedError == EEXIST
                ? @"The secure leaf directory already exists."
                : @"Unable to create the secure leaf directory.",
            savedError);
    }

    int leaf = openat(parent, leafComponent.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (leaf < 0) {
        int savedError = errno;
        close(parent);
        return FMSecureDirectoryFail(error, 4,
                                     @"Unable to open the new secure leaf directory.",
                                     savedError);
    }
    BOOL success = fchown(leaf, expectedUID, expectedGID) == 0 &&
                   fchmod(leaf, creationMode & 0777) == 0;
    if (!success) {
        FMSecureDirectoryFail(error, 4,
                              @"Unable to secure the new leaf directory.", errno);
    }
    if (success) {
        success = FMValidateDirectoryDescriptor(leaf, expectedUID, expectedGID,
                                                @"The new secure leaf directory", error) &&
                  FMSyncDirectoryDescriptor(leaf, error) &&
                  FMSyncDirectoryDescriptor(parent, error);
    }
    int leafCloseResult = close(leaf);
    int parentCloseResult = close(parent);
    if (success && (leafCloseResult != 0 || parentCloseResult != 0)) {
        return FMSecureDirectoryFail(error, 5,
                                     @"Unable to close a new secure directory.", errno);
    }
    return success;
}
