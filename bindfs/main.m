#import <Foundation/Foundation.h>

#import <dlfcn.h>
#import <errno.h>
#import <roothide.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "../shared/FMMountBackendProtocol.h"

typedef int (*FMRootStealUcredFunction)(uint64_t ucredToSteal,
                                        uint64_t *originalUcred);

static NSString *const FMLibJailbreakLogicalPath =
    @"/basebin/libjailbreak.dylib";
static NSString *const FMMirrorRootLogicalPath = @"/bindfs";
static NSString *const FMMirrorSystemLogicalPath = @"/bindfs/System";
static NSString *const FMMirrorLibraryLogicalPath = @"/bindfs/System/Library";
static NSString *const FMMirrorLogicalPath = @"/bindfs/System/Library/Fonts";
static const char *const FMSystemFontsPath = "/System/Library/Fonts";

static int FMExitStatusForErrno(int errorNumber) {
    if (errorNumber > 0 &&
        errorNumber <= FMMountBackendProcessMaximumEncodedErrno) {
        return FMMountBackendProcessExitErrnoBase + errorNumber;
    }
    return FMMountBackendProcessExitUnknownSyscall;
}

static BOOL FMRootOwnedSecureRegularFile(NSString *path) {
    struct stat info = {0};
    return path.length > 0 &&
        lstat(path.fileSystemRepresentation, &info) == 0 &&
        S_ISREG(info.st_mode) && info.st_uid == 0 &&
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static BOOL FMRootOwnedSecureDirectory(NSString *path) {
    struct stat info = {0};
    return path.length > 0 &&
        lstat(path.fileSystemRepresentation, &info) == 0 &&
        S_ISDIR(info.st_mode) && info.st_uid == 0 && info.st_gid == 0 &&
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static BOOL FMValidateFixedMirror(NSString **mirrorPath) {
    NSArray<NSString *> *logicalPaths = @[
        FMMirrorRootLogicalPath,
        FMMirrorSystemLogicalPath,
        FMMirrorLibraryLogicalPath,
        FMMirrorLogicalPath,
    ];
    for (NSString *logicalPath in logicalPaths) {
        if (!FMRootOwnedSecureDirectory(jbroot(logicalPath))) {
            return NO;
        }
    }

    struct stat targetInfo = {0};
    if (lstat(FMSystemFontsPath, &targetInfo) != 0 ||
        !S_ISDIR(targetInfo.st_mode)) {
        return NO;
    }
    if (mirrorPath != NULL) {
        *mirrorPath = jbroot(FMMirrorLogicalPath);
    }
    return YES;
}

static BOOL FMMappingIsExact(NSString *mirrorPath,
                             BOOL *dedicatedMappingPresent,
                             BOOL *inspectionAvailable) {
    struct statfs mapping = {0};
    if (statfs(FMSystemFontsPath, &mapping) != 0) {
        if (inspectionAvailable != NULL) {
            *inspectionAvailable = NO;
        }
        if (dedicatedMappingPresent != NULL) {
            *dedicatedMappingPresent = NO;
        }
        return NO;
    }
    if (inspectionAvailable != NULL) {
        *inspectionAvailable = YES;
    }

    NSString *target = [NSString stringWithUTF8String:mapping.f_mntonname];
    BOOL dedicated = [target isEqualToString:
        [NSString stringWithUTF8String:FMSystemFontsPath]];
    if (dedicatedMappingPresent != NULL) {
        *dedicatedMappingPresent = dedicated;
    }
    if (!dedicated) {
        return NO;
    }

    NSString *filesystemType =
        [NSString stringWithUTF8String:mapping.f_fstypename];
    NSString *source = [NSString stringWithUTF8String:mapping.f_mntfromname];
    return filesystemType != nil && source != nil &&
        [filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame &&
        [source.stringByResolvingSymlinksInPath
            isEqualToString:mirrorPath.stringByResolvingSymlinksInPath] &&
        (mapping.f_flags & MNT_RDONLY) != 0;
}

static void *FMLoadCredentialFunction(FMRootStealUcredFunction *function) {
    NSString *libraryPath = jbroot(FMLibJailbreakLogicalPath);
    if (!FMRootOwnedSecureRegularFile(libraryPath)) {
        return NULL;
    }

    void *handle = dlopen(libraryPath.fileSystemRepresentation,
                          RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        return NULL;
    }

    void *symbol = dlsym(handle, "jbclient_root_steal_ucred");
    if (symbol == NULL) {
        dlclose(handle);
        return NULL;
    }
    *function = (FMRootStealUcredFunction)symbol;
    return handle;
}

static int FMRunMountOperation(BOOL forceUnmount,
                               FMRootStealUcredFunction credentialFunction) {
    NSString *mirrorPath = nil;
    if (!FMValidateFixedMirror(&mirrorPath)) {
        return FMMountBackendProcessExitUnsafeState;
    }

    BOOL dedicatedMappingPresent = NO;
    BOOL inspectionAvailable = NO;
    BOOL exactMapping = FMMappingIsExact(
        mirrorPath, &dedicatedMappingPresent, &inspectionAvailable);
    if (!inspectionAvailable) {
        return FMMountBackendProcessExitUnsafeState;
    }
    if (forceUnmount) {
        if (!exactMapping) {
            return dedicatedMappingPresent
                ? FMMountBackendProcessExitUnsafeState : FMMountBackendProcessExitNotMounted;
        }
    } else {
        if (exactMapping) {
            return 0;
        }
        if (dedicatedMappingPresent) {
            return FMMountBackendProcessExitUnsafeState;
        }
    }

    uint64_t originalCredential = 0;
    int borrowResult = credentialFunction(0, &originalCredential);
    if (borrowResult != 0 || originalCredential == 0) {
        return FMMountBackendProcessExitCredentialBorrow;
    }

    errno = 0;
    int operationResult = forceUnmount
        ? unmount(FMSystemFontsPath, MNT_FORCE)
        : mount("bindfs", FMSystemFontsPath, MNT_RDONLY,
                (void *)mirrorPath.fileSystemRepresentation);
    int operationError = operationResult == 0 ? 0 : errno;

    int restoreResult = credentialFunction(originalCredential, NULL);
    if (restoreResult != 0) {
        return FMMountBackendProcessExitCredentialRestore;
    }
    if (operationResult != 0) {
        errno = operationError;
        return FMExitStatusForErrno(operationError);
    }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--version") == 0) {
            fputs("markfont-bindfs 1\n", stdout);
            return 0;
        }
        if (argc != 2 ||
            (strcmp(argv[1], "probe") != 0 &&
             strcmp(argv[1], "mount-fonts") != 0 &&
             strcmp(argv[1], "force-unmount-fonts") != 0)) {
            return FMMountBackendProcessExitUsage;
        }
        if (geteuid() != 0) {
            return FMMountBackendProcessExitPermission;
        }

        FMRootStealUcredFunction credentialFunction = NULL;
        void *libraryHandle = FMLoadCredentialFunction(&credentialFunction);
        if (libraryHandle == NULL || credentialFunction == NULL) {
            return FMMountBackendProcessExitUnavailable;
        }

        int result = 0;
        if (strcmp(argv[1], "probe") != 0) {
            result = FMRunMountOperation(
                strcmp(argv[1], "force-unmount-fonts") == 0,
                credentialFunction);
        }
        dlclose(libraryHandle);
        return result;
    }
}
