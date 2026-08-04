#import "FMDeviceRestartCoordinator.h"

#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <roothide.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMEnvironmentProbe.h"
#import "FMFileStore.h"
#import "FMOperationLock.h"
#import "FMProfileEngine.h"
#import "FMMountBackendCompatibility.h"
#import "FMMountBackendExecutor.h"
#import "FMMountPaths.h"
#import "FMRestartRequest.h"

NSString *const FMDeviceRestartCoordinatorErrorDomain =
    @"com.hmmzzz.fontmanager.device-restart";
NSString *const FMRestartRequestLogicalPath =
    @"/var/lib/fontmanager/restart-request.json";
NSString *const FMUserspaceRebootExecutableLogicalPath = @"/basebin/jbctl";
NSString *const FMRespringExecutableLogicalPath = @"/usr/bin/sbreload";

static NSString *const FMEngineRootLogicalPath = @"/var/lib/fontmanager";
static NSString *const FMStateLogicalPath = @"/var/lib/fontmanager/state.json";
static NSString *const FMUserspaceSessionProcessPath =
    @"/System/Library/CoreServices/SpringBoard.app/SpringBoard";

// libproc is part of libSystem on iOS, but its declarations are omitted from
// the public iPhoneOS SDK headers used by this RootHide toolchain.
extern int proc_listpids(uint32_t type,
                         uint32_t typeinfo,
                         void *buffer,
                         int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static uint32_t const FMProcAllPIDs = 1;

static BOOL FMDeviceRestartFail(NSError **error,
                                NSInteger code,
                                NSString *description,
                                NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMDeviceRestartCoordinatorErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMDeviceRestartBuildIsSafe(NSString *systemBuild) {
    return [systemBuild isKindOfClass:NSString.class] &&
           systemBuild.length > 0 && systemBuild.length <= 32 &&
           !systemBuild.isAbsolutePath && systemBuild.pathComponents.count == 1 &&
           [systemBuild.lastPathComponent isEqual:systemBuild];
}

static BOOL FMDeviceRestartProfileIDsEqual(id left, id right) {
    BOOL leftIsStock = left == nil || left == NSNull.null;
    BOOL rightIsStock = right == nil || right == NSNull.null;
    return leftIsStock || rightIsStock
        ? leftIsStock && rightIsStock
        : [left isEqual:right];
}

static BOOL FMDeviceRestartValidateCallerAndBuild(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (geteuid() != 0) {
        return FMDeviceRestartFail(
            error, 1, @"Font activation refresh requires effective uid 0.", nil);
    }
    if (!FMDeviceRestartBuildIsSafe(confirmedSystemBuild)) {
        return FMDeviceRestartFail(
            error, 2, @"The confirmed system build is invalid.", nil);
    }
    NSDictionary *version = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    if (![version[@"ProductBuildVersion"] isEqual:confirmedSystemBuild]) {
        return FMDeviceRestartFail(
            error, 2, @"The confirmed system build does not match this device.", nil);
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMDeviceRestartUserspaceSessionEvidence(
    NSError **error) {
    int requiredBytes = proc_listpids(FMProcAllPIDs, 0, NULL, 0);
    int reserveBytes = (int)(64 * sizeof(pid_t));
    if (requiredBytes <= 0 || requiredBytes > INT_MAX - reserveBytes) {
        int savedError = errno != 0 ? errno : EOVERFLOW;
        FMDeviceRestartFail(
            error, 4, @"The current userspace process list could not be read.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError
                            userInfo:nil]);
        return nil;
    }

    int capacity = requiredBytes + reserveBytes;
    NSMutableData *pidData = [NSMutableData dataWithLength:(NSUInteger)capacity];
    int actualBytes = proc_listpids(FMProcAllPIDs, 0,
                                    pidData.mutableBytes, capacity);
    if (actualBytes <= 0 || actualBytes > capacity) {
        int savedError = errno != 0 ? errno : EIO;
        FMDeviceRestartFail(
            error, 4, @"The current userspace process list could not be read.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError
                            userInfo:nil]);
        return nil;
    }

    pid_t *pids = pidData.mutableBytes;
    NSUInteger count = (NSUInteger)actualBytes / sizeof(pid_t);
    for (NSUInteger index = 0; index < count; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) continue;
        char path[PATH_MAX] = {0};
        int pathLength = proc_pidpath(pid, path, (uint32_t)sizeof(path));
        if (pathLength <= 0 ||
            strcmp(path, FMUserspaceSessionProcessPath.UTF8String) != 0) {
            continue;
        }

        return @{
            @"process" : FMUserspaceSessionProcessPath,
            @"pid" : @(pid),
        };
    }

    FMDeviceRestartFail(
        error, 4, @"The current SpringBoard userspace session was not found.",
        [NSError errorWithDomain:NSPOSIXErrorDomain code:ESRCH userInfo:nil]);
    return nil;
}

static NSDictionary<NSString *, id> *FMDeviceRestartReadState(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSError *stateError = nil;
    id state = FMReadJSONObjectAtPath(jbroot(FMStateLogicalPath), &stateError);
    if (![state isKindOfClass:NSDictionary.class] ||
        !FMValidateStateDocument(state, &stateError) ||
        ![state[@"systemBuild"] isEqual:confirmedSystemBuild]) {
        FMDeviceRestartFail(error, 3,
                            @"Persistent Profile state is unavailable or invalid.",
                            stateError);
        return nil;
    }
    return state;
}

static NSDictionary<NSString *, id> *FMDeviceRestartBootEvidence(NSError **error) {
    struct timeval bootTime = {0};
    size_t bootTimeSize = sizeof(bootTime);
    if (sysctlbyname("kern.boottime", &bootTime, &bootTimeSize, NULL, 0) != 0 ||
        bootTimeSize != sizeof(bootTime) || bootTime.tv_sec <= 0) {
        int savedError = errno != 0 ? errno : EIO;
        FMDeviceRestartFail(
            error, 4, @"The current boot time could not be read.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil]);
        return nil;
    }

    size_t sessionSize = 0;
    if (sysctlbyname("kern.bootsessionuuid", NULL, &sessionSize, NULL, 0) != 0 ||
        sessionSize == 0 || sessionSize > 256) {
        int savedError = errno != 0 ? errno : EIO;
        FMDeviceRestartFail(
            error, 4, @"The current boot session could not be read.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil]);
        return nil;
    }
    NSMutableData *sessionBuffer = [NSMutableData dataWithLength:sessionSize + 1];
    size_t readSize = sessionSize;
    if (sysctlbyname("kern.bootsessionuuid", sessionBuffer.mutableBytes,
                     &readSize, NULL, 0) != 0) {
        int savedError = errno;
        FMDeviceRestartFail(
            error, 4, @"The current boot session could not be read.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil]);
        return nil;
    }
    NSString *sessionUUID = [NSString stringWithUTF8String:sessionBuffer.bytes];
    NSDictionary *userspaceSession =
        FMDeviceRestartUserspaceSessionEvidence(error);
    NSDictionary *evidence = sessionUUID.length > 0 && userspaceSession != nil
        ? @{
            @"bootTimeSeconds" : @((long long)bootTime.tv_sec),
            @"bootTimeMicroseconds" : @((long long)bootTime.tv_usec),
            @"bootSessionUUID" : sessionUUID,
            @"userspaceSession" : userspaceSession,
        }
        : nil;
    NSError *validationError = nil;
    if (evidence == nil || !FMValidateRestartBootEvidence(evidence, &validationError)) {
        FMDeviceRestartFail(error, 4,
                            @"The current boot evidence is invalid.",
                            validationError);
        return nil;
    }
    return evidence;
}

static NSDictionary<NSString *, id> *_Nullable FMDeviceRestartReadRequest(
    NSString *confirmedSystemBuild,
    BOOL *missing,
    NSError **error) {
    if (missing != NULL) *missing = NO;
    NSString *requestPath = jbroot(FMRestartRequestLogicalPath);
    struct stat requestInfo = {0};
    errno = 0;
    if (lstat(requestPath.fileSystemRepresentation, &requestInfo) != 0) {
        int savedError = errno;
        if (savedError == ENOENT) {
            if (missing != NULL) *missing = YES;
            return nil;
        }
        FMDeviceRestartFail(
            error, 11, @"The restart request marker could not be inspected.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError
                            userInfo:nil]);
        return nil;
    }

    BOOL metadataValid = S_ISREG(requestInfo.st_mode) &&
        requestInfo.st_uid == 0 &&
        (requestInfo.st_mode & 0777) == 0600;
    if (!metadataValid) {
        FMDeviceRestartFail(
            error, 11, @"The restart request marker is invalid.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:EPERM
                            userInfo:nil]);
        return nil;
    }

    NSError *readError = nil;
    id requestObject = FMReadJSONObjectAtPath(requestPath, &readError);
    NSError *validationError = nil;
    if (![requestObject isKindOfClass:NSDictionary.class] ||
        !FMValidateRestartRequestDocument(requestObject, &validationError) ||
        ![requestObject[@"systemBuild"] isEqual:confirmedSystemBuild]) {
        FMDeviceRestartFail(
            error, 11, @"The restart request marker is invalid.",
            validationError ?: readError);
        return nil;
    }
    return requestObject;
}

static BOOL FMDeviceRestartRequireExecutable(NSError **error) {
    NSString *path = jbroot(FMUserspaceRebootExecutableLogicalPath);
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_uid != 0 ||
        (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0) {
        int savedError = errno != 0 ? errno : ENOENT;
        return FMDeviceRestartFail(
            error, 5, @"The RootHide userspace reboot tool is unavailable.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil]);
    }
    return YES;
}

static BOOL FMDeviceRestartRequireRespringExecutable(NSError **error) {
    NSString *path = jbroot(FMRespringExecutableLogicalPath);
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_uid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
        (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0) {
        int savedError = errno != 0 ? errno : ENOENT;
        return FMDeviceRestartFail(
            error, 5, @"The fixed Respring tool is unavailable or unsafe.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil]);
    }
    return YES;
}

static BOOL FMDeviceRestartRequireStockSnapshot(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSString *path = [jbroot(@"/var/lib/fontmanager/stock")
        stringByAppendingPathComponent:confirmedSystemBuild];
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode) || info.st_uid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        int savedError = errno != 0 ? errno : ENOENT;
        return FMDeviceRestartFail(
            error, 5,
            @"A verified Stock snapshot is required before refreshing a staged font change.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil]);
    }
    return YES;
}

NSDictionary<NSString *, id> *FMCreateDeviceUserspaceRebootPreflight(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (!FMDeviceRestartValidateCallerAndBuild(confirmedSystemBuild, error)) {
        return nil;
    }
    NSDictionary *state = FMDeviceRestartReadState(confirmedSystemBuild, error);
    if (state == nil) return nil;
    if (![state[@"mirrorState"] isEqual:@"clean"] ||
        ![state[@"restartRequired"] boolValue]) {
        FMDeviceRestartFail(
            error, 7, @"There is no clean pending font change to restart for.", nil);
        return nil;
    }
    id workingProfileID = state[@"workingProfileID"];
    NSError *compatibilityError = nil;
    NSDictionary *mountBackendCompatibility =
        FMInspectMountBackendCompatibilityAtPath(
            jbroot(FMMountBackendExecutableLogicalPath), &compatibilityError);
    if (mountBackendCompatibility == nil ||
        ![mountBackendCompatibility[@"compatible"] boolValue]) {
        FMDeviceRestartFail(
            error, 6,
            @"The built-in mount backend does not satisfy its capability contract.",
            compatibilityError);
        return nil;
    }
    if (!FMMountManagedMappingIsActive(error) ||
        !FMDeviceRestartRequireExecutable(error) ||
        !FMDeviceRestartRequireStockSnapshot(confirmedSystemBuild, error)) {
        return nil;
    }
    NSDictionary *bootEvidence = FMDeviceRestartBootEvidence(error);
    if (bootEvidence == nil) return nil;
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"preflightUserspaceReboot",
        @"status" : @"eligible",
        @"systemBuild" : confirmedSystemBuild,
        @"workingProfileID" : workingProfileID,
        @"bootEvidence" : bootEvidence,
        @"executableLogicalPath" : FMUserspaceRebootExecutableLogicalPath,
        @"arguments" : @[ @"reboot_userspace" ],
        @"mountBackendCompatibility" : mountBackendCompatibility[@"compatibility"],
        @"mappingVerified" : @YES,
        @"mirrorContentScanned" : @NO,
        @"workingStateVerified" : @YES,
        @"filesystemMutated" : @NO,
        @"stateChanged" : @NO,
        @"mountBackendInvoked" : @NO,
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMArmDeviceUserspaceReboot(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        FMDeviceRestartFail(error, 8,
                            @"Another font operation is already running.",
                            lockError);
        return nil;
    }

    NSError *operationError = nil;
    NSDictionary *preflight = FMCreateDeviceUserspaceRebootPreflight(
        confirmedSystemBuild, &operationError);
    NSDictionary *backendRefresh = preflight != nil
        ? FMRefreshMountBackendForPreparedSystemFonts(&operationError)
        : nil;
    BOOL mappingRefreshed = backendRefresh != nil &&
        FMMountManagedMappingIsActive(&operationError);
    NSDictionary *request = mappingRefreshed
        ? FMCreateRestartRequestDocument(
            confirmedSystemBuild, preflight[@"workingProfileID"],
            preflight[@"bootEvidence"], &operationError)
        : nil;
    BOOL wroteRequest = request != nil &&
        FMWriteJSONObjectAtomically(request, jbroot(FMRestartRequestLogicalPath),
                                    0600, &operationError);
    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (!wroteRequest || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"requestUserspaceReboot",
        @"status" : @"armed",
        @"systemBuild" : confirmedSystemBuild,
        @"workingProfileID" : request[@"workingProfileID"],
        @"requestedBootEvidence" : request[@"requestedBootEvidence"],
        @"executableLogicalPath" : FMUserspaceRebootExecutableLogicalPath,
        @"arguments" : @[ @"reboot_userspace" ],
        @"filesystemMutated" : @YES,
        @"stateChanged" : @NO,
        @"mountBackendInvoked" : @YES,
        @"mountBackendCompatibility" : preflight[@"mountBackendCompatibility"],
        @"mappingRefreshed" : @YES,
        @"restartRequested" : @YES,
    };
}

static BOOL FMDeviceRestartRemoveRequest(NSError **error) {
    NSString *path = jbroot(FMRestartRequestLogicalPath);
    if (unlink(path.fileSystemRepresentation) != 0 && errno != ENOENT) {
        return FMDeviceRestartFail(
            error, 9, @"The restart request marker could not be removed.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    }
    int directory = open(jbroot(FMEngineRootLogicalPath).fileSystemRepresentation,
                         O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory >= 0) {
        int syncResult = fsync(directory);
        int savedError = syncResult == 0 ? 0 : errno;
        close(directory);
        if (syncResult != 0 && savedError != EINVAL && savedError != ENOTSUP) {
            return FMDeviceRestartFail(
                error, 9, @"The restart request removal could not be synced.",
                [NSError errorWithDomain:NSPOSIXErrorDomain
                                    code:savedError
                                userInfo:nil]);
        }
    }
    return YES;
}

BOOL FMExecuteDeviceUserspaceReboot(NSError **error) {
    if (geteuid() != 0) {
        return FMDeviceRestartFail(
            error, 1, @"Userspace restart requires effective uid 0.", nil);
    }
    NSString *path = jbroot(FMUserspaceRebootExecutableLogicalPath);
    char *const arguments[] = {
        (char *)path.fileSystemRepresentation,
        (char *)"reboot_userspace",
        NULL,
    };
    execv(path.fileSystemRepresentation, arguments);
    int savedError = errno;
    NSError *cleanupError = nil;
    FMDeviceRestartRemoveRequest(&cleanupError);
    return FMDeviceRestartFail(
        error, 10, @"The RootHide userspace reboot tool could not be started.",
        cleanupError ?: [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:savedError
                                         userInfo:nil]);
}

static NSDictionary<NSString *, id> *_Nullable
FMCreateDeviceRespringPreflight(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (!FMDeviceRestartValidateCallerAndBuild(confirmedSystemBuild, error)) {
        return nil;
    }
    NSDictionary *state = FMDeviceRestartReadState(confirmedSystemBuild, error);
    if (state == nil || ![state[@"mirrorState"] isEqual:@"clean"] ||
        ![state[@"restartRequired"] boolValue]) {
        if (state != nil) {
            FMDeviceRestartFail(
                error, 7, @"There is no clean pending font refresh to Respring for.",
                nil);
        }
        return nil;
    }

    id workingProfileID = state[@"workingProfileID"];
    BOOL profilesEqual = FMDeviceRestartProfileIDsEqual(
        state[@"confirmedProfileID"], workingProfileID);
    NSString *refreshReason = [state[@"refreshReason"]
        isKindOfClass:NSString.class] ? state[@"refreshReason"] : nil;
    BOOL lateAutomaticMount = profilesEqual &&
        [workingProfileID isKindOfClass:NSString.class] &&
        (refreshReason == nil ||
         [refreshReason isEqual:@"lateAutomaticMount"]);
    BOOL stagedProfileChange = !profilesEqual &&
        (refreshReason == nil || [refreshReason isEqual:@"profileChange"]);
    if (!lateAutomaticMount && !stagedProfileChange) {
        FMDeviceRestartFail(
            error, 7,
            @"The pending font refresh is not a staged change or a late custom-font mount.",
            nil);
        return nil;
    }

    NSDictionary *mountBackendCompatibility = nil;
    if (stagedProfileChange) {
        NSError *compatibilityError = nil;
        mountBackendCompatibility = FMInspectMountBackendCompatibilityAtPath(
            jbroot(FMMountBackendExecutableLogicalPath), &compatibilityError);
        if (mountBackendCompatibility == nil ||
            ![mountBackendCompatibility[@"compatible"] boolValue]) {
            FMDeviceRestartFail(
                error, 6,
                @"The built-in mount backend does not satisfy its capability contract.",
                compatibilityError);
            return nil;
        }
        if (!FMDeviceRestartRequireStockSnapshot(confirmedSystemBuild, error)) {
            return nil;
        }
    }
    if (!FMMountManagedMappingIsActive(error) ||
        !FMDeviceRestartRequireRespringExecutable(error)) {
        return nil;
    }
    NSDictionary *bootEvidence = FMDeviceRestartBootEvidence(error);
    if (bootEvidence == nil) return nil;
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"preflightRespring",
        @"status" : @"eligible",
        @"systemBuild" : confirmedSystemBuild,
        @"workingProfileID" : workingProfileID,
        @"bootEvidence" : bootEvidence,
        @"activationMode" : stagedProfileChange
            ? @"stagedProfileChange" : @"lateAutomaticMount",
        @"mappingRefreshRequired" : stagedProfileChange ? @YES : @NO,
        @"mountBackendCompatibility" : mountBackendCompatibility != nil
            ? mountBackendCompatibility[@"compatibility"] : @"notRequired",
        @"executableLogicalPath" : FMRespringExecutableLogicalPath,
        @"arguments" : @[],
        @"mappingVerified" : @YES,
        @"mirrorContentScanned" : @NO,
        @"workingStateVerified" : @YES,
        @"filesystemMutated" : @NO,
        @"stateChanged" : @NO,
        @"mountBackendInvoked" : @NO,
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMArmDeviceRespring(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        FMDeviceRestartFail(error, 8,
                            @"Another font operation is already running.",
                            lockError);
        return nil;
    }

    NSError *operationError = nil;
    NSDictionary *preflight = FMCreateDeviceRespringPreflight(
        confirmedSystemBuild, &operationError);
    BOOL mappingRefreshRequired =
        [preflight[@"mappingRefreshRequired"] boolValue];
    NSDictionary *backendRefresh = preflight != nil && mappingRefreshRequired
        ? FMRefreshMountBackendForPreparedSystemFonts(&operationError)
        : nil;
    BOOL mappingReady = preflight != nil &&
        (!mappingRefreshRequired || backendRefresh != nil) &&
        FMMountManagedMappingIsActive(&operationError);
    NSDictionary *request = mappingReady
        ? FMCreateRestartRequestDocument(
            confirmedSystemBuild, preflight[@"workingProfileID"],
            preflight[@"bootEvidence"], &operationError)
        : nil;
    BOOL wroteRequest = request != nil &&
        FMWriteJSONObjectAtomically(request, jbroot(FMRestartRequestLogicalPath),
                                    0600, &operationError);

    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (!wroteRequest || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"requestRespring",
        @"status" : @"armed",
        @"systemBuild" : confirmedSystemBuild,
        @"workingProfileID" : request[@"workingProfileID"],
        @"requestedBootEvidence" : request[@"requestedBootEvidence"],
        @"activationMode" : preflight[@"activationMode"],
        @"executableLogicalPath" : FMRespringExecutableLogicalPath,
        @"arguments" : @[],
        @"filesystemMutated" : @YES,
        @"stateChanged" : @NO,
        @"mountBackendInvoked" : mappingRefreshRequired ? @YES : @NO,
        @"mountBackendCompatibility" : preflight[@"mountBackendCompatibility"],
        @"mappingRefreshed" : mappingRefreshRequired ? @YES : @NO,
        @"restartRequested" : @YES,
    };
}

static BOOL FMDeviceRestartRestoreArmedRespringWithExistingLock(
    NSDictionary<NSString *, id> *state,
    NSDictionary<NSString *, id> *request,
    NSError **error) {
    NSError *stateError = nil;
    BOOL restoredState = FMWriteJSONObjectAtomically(
        state, jbroot(FMStateLogicalPath), 0600, &stateError);
    NSError *requestError = nil;
    BOOL restoredRequest = FMWriteJSONObjectAtomically(
        request, jbroot(FMRestartRequestLogicalPath), 0600, &requestError);
    if (!restoredState || !restoredRequest) {
        return FMDeviceRestartFail(
            error, 13, @"The armed Respring state could not be restored.",
            stateError ?: requestError);
    }
    return YES;
}

BOOL FMExecuteDeviceRespring(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (!FMDeviceRestartValidateCallerAndBuild(confirmedSystemBuild, error) ||
        !FMDeviceRestartRequireRespringExecutable(error)) {
        return NO;
    }

    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        return FMDeviceRestartFail(
            error, 8, @"Another font operation is already running.", lockError);
    }

    NSError *operationError = nil;
    BOOL requestMissing = NO;
    NSDictionary *request = FMDeviceRestartReadRequest(
        confirmedSystemBuild, &requestMissing, &operationError);
    if (request == nil) {
        if (requestMissing) {
            FMDeviceRestartFail(
                &operationError, 11,
                @"Respring execution requires an armed request.", nil);
        }
        NSError *releaseError = nil;
        FMReleaseExclusiveDirectoryLock(lock, &releaseError);
        if (error != NULL) *error = operationError ?: releaseError;
        return NO;
    }

    NSDictionary *state = FMDeviceRestartReadState(
        confirmedSystemBuild, &operationError);
    BOOL stateMatchesRequest = state != nil &&
        [state[@"mirrorState"] isEqual:@"clean"] &&
        [state[@"restartRequired"] boolValue] &&
        FMDeviceRestartProfileIDsEqual(
            state[@"workingProfileID"], request[@"workingProfileID"]);
    if (state != nil && !stateMatchesRequest) {
        FMDeviceRestartFail(
            &operationError, 12,
            @"The armed Profile changed before Respring execution.", nil);
    }
    BOOL mappingReady = stateMatchesRequest &&
        FMMountManagedMappingIsActive(&operationError);
    NSDictionary *originalState = stateMatchesRequest ? [state copy] : nil;
    NSDictionary *originalRequest = stateMatchesRequest ? [request copy] : nil;
    BOOL confirmed = mappingReady && FMConfirmWorkingProfileAtStatePath(
        jbroot(FMStateLogicalPath), &operationError);
    if (!confirmed) {
        NSError *releaseError = nil;
        FMReleaseExclusiveDirectoryLock(lock, &releaseError);
        if (error != NULL) *error = operationError ?: releaseError;
        return NO;
    }

    if (!FMDeviceRestartRemoveRequest(&operationError)) {
        NSError *restoreError = nil;
        FMDeviceRestartRestoreArmedRespringWithExistingLock(
            originalState, originalRequest, &restoreError);
        NSError *releaseError = nil;
        FMReleaseExclusiveDirectoryLock(lock, &releaseError);
        if (error != NULL) {
            *error = restoreError ?: operationError ?: releaseError;
        }
        return NO;
    }

    // The operation-lock descriptor is O_CLOEXEC. A successful exec therefore
    // releases the lock as the helper becomes sbreload; a failed exec returns
    // here with the lock still held so the pending state can be restored.
    NSString *path = jbroot(FMRespringExecutableLogicalPath);
    char *const arguments[] = {
        (char *)path.fileSystemRepresentation,
        NULL,
    };
    execv(path.fileSystemRepresentation, arguments);
    int savedError = errno;

    NSError *restoreError = nil;
    FMDeviceRestartRestoreArmedRespringWithExistingLock(
        originalState, originalRequest, &restoreError);
    NSError *releaseError = nil;
    FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    return FMDeviceRestartFail(
        error, 10, @"The fixed Respring tool could not be started.",
        restoreError ?: releaseError ?:
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError
                            userInfo:nil]);
}

static NSDictionary<NSString *, id> *FMDeviceRestartNoopReport(
    NSString *status,
    NSString *confirmedSystemBuild,
    BOOL restartObserved) {
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"reconcileAfterRestart",
        @"status" : status,
        @"systemBuild" : confirmedSystemBuild,
        @"restartObserved" : restartObserved ? @YES : @NO,
        @"filesystemMutated" : @NO,
        @"stateChanged" : @NO,
        @"mountBackendInvoked" : @NO,
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMReconcileDeviceAfterRestart(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (!FMDeviceRestartValidateCallerAndBuild(confirmedSystemBuild, error)) {
        return nil;
    }
    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        FMDeviceRestartFail(error, 8,
                            @"Another font operation is already running.",
                            lockError);
        return nil;
    }

    NSError *operationError = nil;
    NSDictionary *result = nil;
    BOOL requestMissing = NO;
    NSDictionary *request = FMDeviceRestartReadRequest(
        confirmedSystemBuild, &requestMissing, &operationError);
    if (requestMissing) {
        result = FMDeviceRestartNoopReport(
            @"notRequested", confirmedSystemBuild, NO);
    } else if (request != nil) {
        NSDictionary *bootEvidence = FMDeviceRestartBootEvidence(&operationError);
        BOOL restartObserved = NO;
        BOOL compared = bootEvidence != nil && FMRestartRequestObservedRestart(
            request, bootEvidence, &restartObserved, &operationError);
        if (compared) {
            if (!restartObserved) {
                result = FMDeviceRestartNoopReport(
                    @"waitingForRestart", confirmedSystemBuild, NO);
            } else {
                NSDictionary *state = FMDeviceRestartReadState(
                    confirmedSystemBuild, &operationError);
                id expectedProfileID = request[@"workingProfileID"];
                if (state != nil &&
                    (![state[@"mirrorState"] isEqual:@"clean"] ||
                     !FMDeviceRestartProfileIDsEqual(
                         state[@"workingProfileID"], expectedProfileID))) {
                    FMDeviceRestartFail(
                        &operationError, 12,
                        @"The pending Profile changed before restart reconciliation.", nil);
                } else if (state != nil && ![state[@"restartRequired"] boolValue]) {
                    if (!FMDeviceRestartProfileIDsEqual(
                            state[@"confirmedProfileID"], expectedProfileID) ||
                        !FMDeviceRestartRemoveRequest(&operationError)) {
                        if (operationError == nil) {
                            FMDeviceRestartFail(
                                &operationError, 12,
                                @"The confirmed Profile does not match the restart request.",
                                nil);
                        }
                    } else {
                        result = @{
                            @"schemaVersion" : @1,
                            @"operation" : @"reconcileAfterRestart",
                            @"status" : @"alreadyReconciled",
                            @"systemBuild" : confirmedSystemBuild,
                            @"workingProfileID" : expectedProfileID,
                            @"restartObserved" : @YES,
                            @"filesystemMutated" : @YES,
                            @"stateChanged" : @NO,
                            @"mountBackendInvoked" : @NO,
                            @"restartRequested" : @NO,
                        };
                    }
                } else if (state != nil &&
                           FMMountManagedMappingIsActive(&operationError) &&
                           FMConfirmWorkingProfileAtStatePath(
                               jbroot(FMStateLogicalPath), &operationError) &&
                           FMDeviceRestartRemoveRequest(&operationError)) {
                    result = @{
                        @"schemaVersion" : @1,
                        @"operation" : @"reconcileAfterRestart",
                        @"status" : @"reconciled",
                        @"systemBuild" : confirmedSystemBuild,
                        @"workingProfileID" : expectedProfileID,
                        @"restartObserved" : @YES,
                        @"filesystemMutated" : @YES,
                        @"stateChanged" : @YES,
                        @"mountBackendInvoked" : @NO,
                        @"restartRequested" : @NO,
                    };
                }
            }
        }
    }

    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (result == nil || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }
    return result;
}
