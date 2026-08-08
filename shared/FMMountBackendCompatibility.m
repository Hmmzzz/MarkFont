#import "FMMountBackendCompatibility.h"

#import <errno.h>
#import <fcntl.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <sys/stat.h>
#import <unistd.h>

NSInteger const FMMountBackendCapabilityContractVersion = 1;
NSString *const FMMountBackendCompatibilityErrorDomain =
    @"com.hmmzzz.fontmanager.mount-backend-compatibility";

static BOOL FMMountBackendCompatibilityFail(NSError **error,
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
        *error = [NSError errorWithDomain:FMMountBackendCompatibilityErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

NSDictionary<NSString *, id> *FMMountBackendAnalyzeExecutablePrefix(
    NSData *prefix) {
    uint32_t magic = 0;
    if (prefix.length >= sizeof(magic)) {
        [prefix getBytes:&magic length:sizeof(magic)];
    }
    BOOL machO = magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
        magic == FAT_MAGIC || magic == FAT_CIGAM ||
        magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
    return @{
        @"contractVersion" : @(FMMountBackendCapabilityContractVersion),
        @"machOExecutable" : @(machO),
        @"supportsReadOnlyMount" : @(machO),
        @"supportsForceUnmount" : @(machO),
    };
}

static NSDictionary<NSString *, id> *FMMountBackendUnavailableReport(
    BOOL present,
    NSString *reason) {
    return @{
        @"contractVersion" : @(FMMountBackendCapabilityContractVersion),
        @"compatibility" : @"incompatible",
        @"compatible" : @NO,
        @"executablePresent" : @(present),
        @"executableSecure" : @NO,
        @"machOExecutable" : @NO,
        @"supportsReadOnlyMount" : @NO,
        @"supportsForceUnmount" : @NO,
        @"reason" : reason,
    };
}

NSDictionary<NSString *, id> *FMInspectMountBackendCompatibilityAtPath(
    NSString *path,
    NSError **error) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) {
        FMMountBackendCompatibilityFail(
            error, 1, @"The mount backend path is invalid.", EINVAL);
        return nil;
    }

    struct stat pathInfo = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &pathInfo) != 0) {
        if (errno == ENOENT) {
            return FMMountBackendUnavailableReport(NO, @"missing");
        }
        int savedError = errno;
        FMMountBackendCompatibilityFail(
            error, 2, @"The mount backend could not be inspected.", savedError);
        return nil;
    }
    BOOL secure = S_ISREG(pathInfo.st_mode) && pathInfo.st_uid == 0 &&
        (pathInfo.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID)) == 0 &&
        (pathInfo.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
    if (!secure) {
        return FMMountBackendUnavailableReport(YES, @"unsafeMetadata");
    }

    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        int savedError = errno;
        FMMountBackendCompatibilityFail(
            error, 2, @"The mount backend could not be opened safely.",
            savedError);
        return nil;
    }
    struct stat openedInfo = {0};
    uint32_t magic = 0;
    ssize_t bytesRead = read(descriptor, &magic, sizeof(magic));
    int readError = bytesRead < 0 ? errno : 0;
    int inspectResult = fstat(descriptor, &openedInfo);
    int inspectError = inspectResult != 0 ? errno : 0;
    int closeResult = close(descriptor);
    int closeError = closeResult != 0 ? errno : 0;
    if (bytesRead != sizeof(magic) || inspectResult != 0 ||
        openedInfo.st_dev != pathInfo.st_dev ||
        openedInfo.st_ino != pathInfo.st_ino || closeResult != 0) {
        int savedError = readError != 0 ? readError
            : inspectError != 0 ? inspectError
            : closeError != 0 ? closeError : EIO;
        FMMountBackendCompatibilityFail(
            error, 2, @"The mount backend changed during inspection.",
            savedError);
        return nil;
    }

    NSData *prefix = [NSData dataWithBytes:&magic length:sizeof(magic)];
    NSDictionary *analysis = FMMountBackendAnalyzeExecutablePrefix(prefix);
    BOOL compatible = [analysis[@"machOExecutable"] boolValue];
    return @{
        @"contractVersion" : @(FMMountBackendCapabilityContractVersion),
        @"compatibility" : compatible ? @"compatible" : @"incompatible",
        @"compatible" : @(compatible),
        @"executablePresent" : @YES,
        @"executableSecure" : @YES,
        @"machOExecutable" : analysis[@"machOExecutable"],
        @"supportsReadOnlyMount" : analysis[@"supportsReadOnlyMount"],
        @"supportsForceUnmount" : analysis[@"supportsForceUnmount"],
        @"reason" : compatible ? @"builtIn" : @"notMachO",
    };
}

NSString *FMMountBackendRecognitionForVersion(NSString *version) {
    return ([version isEqualToString:@"1"] ||
            [version isEqualToString:@"2"])
        ? @"known" : @"unknown";
}

BOOL FMMountBackendEvidenceSatisfiesCompatibilityContract(
    NSDictionary<NSString *, id> *backendEvidence) {
    return [backendEvidence[@"contractVersion"] isKindOfClass:NSNumber.class] &&
        [backendEvidence[@"contractVersion"] integerValue] ==
            FMMountBackendCapabilityContractVersion &&
        [backendEvidence[@"compatible"] boolValue] &&
        [backendEvidence[@"executablePresent"] boolValue] &&
        [backendEvidence[@"runtimeLibraryPresent"] boolValue] &&
        [backendEvidence[@"runtimeLibrarySecure"] boolValue] &&
        [backendEvidence[@"executableSecure"] boolValue] &&
        [backendEvidence[@"machOExecutable"] boolValue] &&
        [backendEvidence[@"supportsReadOnlyMount"] boolValue] &&
        [backendEvidence[@"supportsForceUnmount"] boolValue];
}
