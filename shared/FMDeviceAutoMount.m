#import "FMDeviceAutoMount.h"

#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <roothide.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMOperationLock.h"
#import "FMMountBackendExecutor.h"
#import "FMMountPaths.h"
#import "FMSecureDirectory.h"

NSString *const FMDeviceAutoMountErrorDomain =
    @"com.hmmzzz.fontmanager.device-auto-mount";

static NSString *const FMEngineRootLogicalPath = @"/var/lib/fontmanager";
static NSString *const FMStateLogicalPath = @"/var/lib/fontmanager/state.json";
static NSString *const FMDisableMountLogicalPath =
    @"/var/lib/fontmanager/disable-mount";
static NSString *const FMRootHideSafeModeLogicalPath = @"/basebin/.safe_mode";
static NSString *const FMLegacyProviderGlobalDisableLogicalPath =
    @"/rootfs/var/mobile/.not_auto_mount";
static NSString *const FMSpringBoardProcessPath =
    @"/System/Library/CoreServices/SpringBoard.app/SpringBoard";

// libproc is available through libSystem on iOS, but the public SDK used by
// this RootHide build does not ship its declarations.
extern int proc_listpids(uint32_t type,
                         uint32_t typeinfo,
                         void *buffer,
                         int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static uint32_t const FMProcAllPIDs = 1;

static void FMAutoMountSetError(NSError **error,
                                NSInteger code,
                                NSString *description,
                                NSError *underlying) {
    if (error == NULL) return;
    NSMutableDictionary *userInfo =
        [NSMutableDictionary dictionaryWithObject:description
                                           forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    *error = [NSError errorWithDomain:FMDeviceAutoMountErrorDomain
                                 code:code
                             userInfo:userInfo];
}

static NSError *FMAutoMountPOSIXError(int errorNumber) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:errorNumber
                           userInfo:nil];
}

static BOOL FMAutoMountMarkerExists(NSString *path,
                                    BOOL *present,
                                    NSError **error) {
    if (path.length == 0 || present == NULL) {
        FMAutoMountSetError(error, 1,
                            @"An automatic-mount gate path is invalid.", nil);
        return NO;
    }
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        *present = YES;
        return YES;
    }
    if (errno == ENOENT) {
        *present = NO;
        return YES;
    }
    int savedError = errno;
    *present = NO;
    FMAutoMountSetError(error, 1,
                        @"An automatic-mount gate could not be inspected.",
                        FMAutoMountPOSIXError(savedError));
    return NO;
}

static NSDictionary<NSString *, id> *FMAutoMountSkippedReport(
    NSString *status,
    NSString *reason) {
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"automaticMount",
        @"status" : status,
        @"reason" : reason,
        @"jailbreakSession" : @(jbrand()),
        @"mountBackendInvoked" : @NO,
        @"copyPerformed" : @NO,
        @"filesystemMutated" : @NO,
        @"mappingChanged" : @NO,
        @"stateChanged" : @NO,
        @"restartRequested" : @NO,
    };
}

static NSDictionary<NSString *, id> *_Nullable FMAutoMountGateReport(
    NSError **error) {
    BOOL safeMode = NO;
    BOOL disabled = NO;
    BOOL legacyProviderDisabled = NO;
    if (!FMAutoMountMarkerExists(jbroot(FMRootHideSafeModeLogicalPath),
                                 &safeMode, error) ||
        !FMAutoMountMarkerExists(jbroot(FMDisableMountLogicalPath),
                                 &disabled, error) ||
        !FMAutoMountMarkerExists(jbroot(FMLegacyProviderGlobalDisableLogicalPath),
                                 &legacyProviderDisabled, error)) {
        return nil;
    }
    if (safeMode) {
        return FMAutoMountSkippedReport(@"safeMode", @"rootHideSafeMode");
    }
    if (disabled) {
        return FMAutoMountSkippedReport(@"disabled", @"fontManagerDisableMarker");
    }
    if (legacyProviderDisabled) {
        return FMAutoMountSkippedReport(@"disabled", @"legacyProviderGlobalDisableMarker");
    }
    return @{};
}

static NSString *_Nullable FMAutoMountPhysicalDirectory(
    NSString *path,
    NSError **error) {
    char resolved[PATH_MAX] = {0};
    errno = 0;
    if (realpath(path.fileSystemRepresentation, resolved) == NULL) {
        int savedError = errno;
        FMAutoMountSetError(error, 3,
                            @"A required automatic-mount directory is unavailable.",
                            FMAutoMountPOSIXError(savedError));
        return nil;
    }
    NSString *physical = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:resolved
                                     length:strlen(resolved)];
    struct stat info = {0};
    if (lstat(physical.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode)) {
        int savedError = errno != 0 ? errno : ENOTDIR;
        FMAutoMountSetError(error, 3,
                            @"A required automatic-mount path is not a directory.",
                            FMAutoMountPOSIXError(savedError));
        return nil;
    }
    return physical;
}

static BOOL FMAutoMountSafeComponent(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length > 0 &&
        value.length <= 128 && !value.isAbsolutePath &&
        value.pathComponents.count == 1 &&
        [value.lastPathComponent isEqual:value] &&
        ![value isEqual:@"."] && ![value isEqual:@".."];
}

static BOOL FMAutoMountProfileIDsEqual(id left, id right) {
    BOOL leftStock = left == nil || left == NSNull.null;
    BOOL rightStock = right == nil || right == NSNull.null;
    return leftStock || rightStock ? leftStock && rightStock : [left isEqual:right];
}

static NSString *_Nullable FMAutoMountSystemBuild(NSError **error) {
    NSDictionary *version = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    NSString *systemBuild = [version[@"ProductBuildVersion"]
        isKindOfClass:NSString.class] ? version[@"ProductBuildVersion"] : nil;
    if (!FMAutoMountSafeComponent(systemBuild)) {
        FMAutoMountSetError(error, 3,
                            @"The current system build is unavailable.", nil);
        return nil;
    }
    return systemBuild;
}

static BOOL FMAutoMountSpringBoardIsRunning(BOOL *observationAvailable) {
    if (observationAvailable != NULL) *observationAvailable = NO;
    int requiredBytes = proc_listpids(FMProcAllPIDs, 0, NULL, 0);
    int reserveBytes = (int)(64 * sizeof(pid_t));
    if (requiredBytes <= 0 || requiredBytes > INT_MAX - reserveBytes) {
        return NO;
    }

    int capacity = requiredBytes + reserveBytes;
    NSMutableData *pidData = [NSMutableData dataWithLength:(NSUInteger)capacity];
    int actualBytes = proc_listpids(FMProcAllPIDs, 0,
                                    pidData.mutableBytes, capacity);
    if (actualBytes <= 0 || actualBytes > capacity) return NO;
    if (observationAvailable != NULL) *observationAvailable = YES;

    pid_t *pids = pidData.mutableBytes;
    NSUInteger count = (NSUInteger)actualBytes / sizeof(pid_t);
    for (NSUInteger index = 0; index < count; index++) {
        pid_t pid = pids[index];
        if (pid <= 0) continue;
        char path[PATH_MAX] = {0};
        int pathLength = proc_pidpath(pid, path, (uint32_t)sizeof(path));
        if (pathLength > 0 &&
            strcmp(path, FMSpringBoardProcessPath.UTF8String) == 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL FMAutoMountRequireSecureRegularFile(NSString *path,
                                                NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        int savedError = errno != 0 ? errno : EPERM;
        FMAutoMountSetError(
            error, 3,
            @"The persistent automatic-mount state has unsafe metadata.",
            FMAutoMountPOSIXError(savedError));
        return NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> *_Nullable FMAutoMountReadValidatedState(
    NSString *systemBuild,
    NSError **error) {
    NSString *statePath = jbroot(FMStateLogicalPath);
    NSError *stateError = nil;
    id object = FMAutoMountRequireSecureRegularFile(statePath, &stateError)
        ? FMReadJSONObjectAtPath(statePath, &stateError)
        : nil;
    if (![object isKindOfClass:NSDictionary.class] ||
        !FMValidateStateDocument(object, &stateError) ||
        ![object[@"systemBuild"] isEqual:systemBuild]) {
        FMAutoMountSetError(
            error, 3,
            @"The persistent automatic-mount state is unavailable or invalid.",
            stateError);
        return nil;
    }
    return object;
}

static NSDictionary<NSString *, id> *_Nullable FMAutoMountReadState(
    NSString *systemBuild,
    NSError **error) {
    NSDictionary *object = FMAutoMountReadValidatedState(systemBuild, error);
    if (object == nil) return nil;
    BOOL profilesEqual = [object isKindOfClass:NSDictionary.class] &&
        FMAutoMountProfileIDsEqual(object[@"confirmedProfileID"],
                                    object[@"workingProfileID"]);
    BOOL refreshOnlyPending = profilesEqual &&
        [object[@"restartRequired"] boolValue] &&
        [object[@"workingProfileID"] isKindOfClass:NSString.class];
    if (![object[@"mirrorState"] isEqual:@"clean"] ||
        !profilesEqual ||
        ([object[@"restartRequired"] boolValue] && !refreshOnlyPending)) {
        FMAutoMountSetError(
            error, 3,
            @"Automatic mounting requires a clean, confirmed current-build mirror.",
            nil);
        return nil;
    }
    return object;
}

static BOOL FMAutoMountValidateWorkspace(NSError **error) {
    NSString *bootstrapRoot = FMAutoMountPhysicalDirectory(jbroot(@"/"), error);
    if (bootstrapRoot == nil || [bootstrapRoot isEqual:@"/"]) {
        if (error != NULL && *error == nil) {
            FMAutoMountSetError(error, 3,
                                @"The RootHide bootstrap root is unavailable.", nil);
        }
        return NO;
    }

    NSError *directoryError = nil;
    if (!FMValidateSecureDirectoryTree(
            bootstrapRoot,
            @[ @"bindfs", @"System", @"Library", @"Fonts" ],
            0, 0, &directoryError)) {
        FMAutoMountSetError(
            error, 3,
            @"The managed working mirror path is unsafe.",
            directoryError);
        return NO;
    }

    NSString *mirrorPath = jbroot(FMMountResolvedMirrorLogicalPath(NULL, NULL));
    NSArray<NSString *> *topLevelEntries = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:mirrorPath error:&directoryError];
    if (topLevelEntries == nil || topLevelEntries.count == 0) {
        FMAutoMountSetError(error, 3,
                            @"The managed working mirror is empty or unreadable.",
                            directoryError);
        return NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> *_Nullable FMAutoMountTargetFacts(
    NSError **error) {
    BOOL rootSupported = NO;
    NSString *mirrorLogicalPath =
        FMMountResolvedMirrorLogicalPath(&rootSupported, NULL);
    struct statfs filesystem = {0};
    if (!rootSupported ||
        statfs(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
               &filesystem) != 0) {
        int savedError = rootSupported ? errno : 0;
        FMAutoMountSetError(
            error, 3, @"The system font mount target could not be inspected.",
            savedError != 0 ? FMAutoMountPOSIXError(savedError) : nil);
        return nil;
    }
    NSString *filesystemType =
        [NSString stringWithUTF8String:filesystem.f_fstypename];
    NSString *target = [NSString stringWithUTF8String:filesystem.f_mntonname];
    NSString *source = [NSString stringWithUTF8String:filesystem.f_mntfromname];
    NSString *mirrorPath = jbroot(mirrorLogicalPath);
    BOOL dedicated = [target isEqual:FMMountSystemFontsLogicalPath];
    BOOL bindfs = filesystemType != nil &&
        [filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame;
    BOOL managed = bindfs && dedicated &&
        [source.stringByResolvingSymlinksInPath
            isEqual:mirrorPath.stringByResolvingSymlinksInPath] &&
        (filesystem.f_flags & MNT_RDONLY) != 0;
    return @{
        @"filesystemType" : filesystemType ?: NSNull.null,
        @"dedicated" : dedicated ? @YES : @NO,
        @"bindfs" : bindfs ? @YES : @NO,
        @"managed" : managed ? @YES : @NO,
    };
}

static BOOL FMAutoMountRequirePhysicalTarget(NSError **error) {
    int descriptor = open(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        FMAutoMountSetError(
            error, 3, @"The inactive system font target could not be opened.",
            FMAutoMountPOSIXError(errno));
        return NO;
    }
    struct stat info = {0};
    int inspectResult = fstat(descriptor, &info);
    int inspectError = inspectResult == 0 ? 0 : errno;
    BOOL safe = inspectResult == 0 && S_ISDIR(info.st_mode) &&
        info.st_uid == 0 && info.st_gid == 0 &&
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
    int closeResult = close(descriptor);
    if (!safe || closeResult != 0) {
        int savedError = inspectError != 0
            ? inspectError
            : closeResult != 0 ? errno : EPERM;
        FMAutoMountSetError(
            error, 3, @"The inactive system font target has unsafe metadata.",
            FMAutoMountPOSIXError(savedError));
        return NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> *_Nullable FMAutoMountLocked(
    NSError **error) {
    NSString *systemBuild = FMAutoMountSystemBuild(error);
    if (systemBuild == nil) return nil;

    NSDictionary *state = FMAutoMountReadState(systemBuild, error);
    if (state == nil) {
        return nil;
    }
    if (![state[@"autoMount"] boolValue]) {
        NSMutableDictionary<NSString *, id> *disabled =
            [FMAutoMountSkippedReport(@"disabled", @"statePolicyDisabled")
                mutableCopy];
        disabled[@"autoRespringEnabled"] =
            [state[@"autoRespring"] boolValue] ? @YES : @NO;
        return disabled;
    }
    if (!FMAutoMountValidateWorkspace(error)) {
        return nil;
    }
    NSError *inspectionError = nil;

    NSDictionary *targetFacts = FMAutoMountTargetFacts(&inspectionError);
    if (targetFacts == nil) {
        if (error != NULL) *error = inspectionError;
        return nil;
    }
    BOOL mappingWasManaged = [targetFacts[@"managed"] boolValue];
    if (!mappingWasManaged &&
        ([targetFacts[@"dedicated"] boolValue] ||
         [targetFacts[@"bindfs"] boolValue])) {
        FMAutoMountSetError(
            error, 3,
            @"An unexpected dedicated or bindfs mapping already covers the font target.",
            nil);
        return nil;
    }
    if (!mappingWasManaged && !FMAutoMountRequirePhysicalTarget(error)) {
        return nil;
    }

    BOOL springBoardObservationAvailable = YES;
    BOOL springBoardWasRunning = NO;
    BOOL customWorkingProfile =
        [state[@"workingProfileID"] isKindOfClass:NSString.class];
    BOOL lateAutomaticMountPending = customWorkingProfile &&
        [state[@"restartRequired"] boolValue] &&
        [state[@"refreshReason"] isEqual:@"lateAutomaticMount"];
    if (!mappingWasManaged && customWorkingProfile &&
        (![state[@"restartRequired"] boolValue] ||
         lateAutomaticMountPending)) {
        springBoardWasRunning = FMAutoMountSpringBoardIsRunning(
            &springBoardObservationAvailable);
    }
    BOOL activationRefreshRequired =
        [state[@"restartRequired"] boolValue] ||
        (!mappingWasManaged && customWorkingProfile &&
         (!springBoardObservationAvailable || springBoardWasRunning));

    NSDictionary *backendReport = nil;
    if (!mappingWasManaged) {
        backendReport = FMInvokeMountBackendForPreparedSystemFonts(&inspectionError);
        if (backendReport == nil ||
            ![backendReport[@"reportedSuccess"] boolValue]) {
            FMAutoMountSetError(
                error, 5,
                @"The fixed mount backend operation operation did not succeed.",
                inspectionError);
            return nil;
        }
    }

    NSDictionary *postMountFacts = FMAutoMountTargetFacts(&inspectionError);
    BOOL finalAutoMountConflict = NO;
    BOOL mappingExact = postMountFacts != nil &&
        [postMountFacts[@"managed"] boolValue] &&
        FMLegacyProviderAutoMountConflictsWithSystemFonts(
            &finalAutoMountConflict, &inspectionError) &&
        !finalAutoMountConflict;
    if (!mappingExact) {
        FMAutoMountSetError(
            error, 6,
            @"Mount backend completion did not produce the exact managed read-only mapping.",
            inspectionError);
        return nil;
    }

    NSDictionary *currentState =
        FMAutoMountReadState(systemBuild, &inspectionError);
    if (currentState == nil || ![currentState isEqual:state]) {
        FMAutoMountSetError(
            error, 6,
            @"Persistent state changed during automatic mounting.",
            inspectionError);
        return nil;
    }

    BOOL stateChanged = NO;
    if (activationRefreshRequired &&
        ![currentState[@"restartRequired"] boolValue]) {
        NSMutableDictionary<NSString *, id> *pendingState =
            [currentState mutableCopy];
        pendingState[@"restartRequired"] = @YES;
        pendingState[@"refreshReason"] = @"lateAutomaticMount";
        if (!FMWriteJSONObjectAtomically(pendingState, jbroot(FMStateLogicalPath),
                                         0600, &inspectionError)) {
            FMAutoMountSetError(
                error, 6,
                @"The late automatic mount could not record its required Respring.",
                inspectionError);
            return nil;
        }
        NSDictionary *publishedState =
            FMAutoMountReadState(systemBuild, &inspectionError);
        if (publishedState == nil || ![publishedState isEqual:pendingState]) {
            FMAutoMountSetError(
                error, 6,
                @"The required Respring state was not published exactly.",
                inspectionError);
            return nil;
        }
        stateChanged = YES;
        lateAutomaticMountPending = YES;
    }

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"automaticMount",
        @"status" : mappingWasManaged ? @"alreadyMounted" : @"mounted",
        @"systemBuild" : systemBuild,
        @"workingProfileID" : state[@"workingProfileID"],
        @"jailbreakSession" : @(jbrand()),
        @"mountBackendInvoked" : mappingWasManaged ? @NO : @YES,
        @"mountBackendCompatibility" : mappingWasManaged
            ? @"notRequired"
            : backendReport[@"mountBackendCompatibility"],
        @"mountBackendReportedSuccess" : mappingWasManaged
            ? @YES
            : backendReport[@"reportedSuccess"],
        @"copyPerformed" : @NO,
        @"contentScanned" : @NO,
        @"contentVerified" : @NO,
        @"validationMode" : @"trustedCleanMirror",
        @"mappingChanged" : mappingWasManaged ? @NO : @YES,
        @"mappingActive" : @YES,
        @"mappingReadOnly" : @YES,
        @"autoMountEnabled" : @YES,
        @"autoRespringEnabled" :
            [state[@"autoRespring"] boolValue] ? @YES : @NO,
        @"springBoardWasRunning" : springBoardWasRunning ? @YES : @NO,
        @"springBoardObservationAvailable" :
            springBoardObservationAvailable ? @YES : @NO,
        @"activationRefreshRequired" :
            activationRefreshRequired ? @YES : @NO,
        @"lateAutomaticMountPending" :
            lateAutomaticMountPending ? @YES : @NO,
        @"filesystemMutated" : @NO,
        @"stateChanged" : stateChanged ? @YES : @NO,
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMAutomountManagedDeviceFonts(
    NSError **error) {
    if (getuid() != 0 || geteuid() != 0) {
        FMAutoMountSetError(
            error, 2,
            @"Automatic mounting requires a root launchd caller, not a setuid transition.",
            nil);
        return nil;
    }

    NSDictionary *gateReport = FMAutoMountGateReport(error);
    if (gateReport == nil || gateReport.count > 0) {
        return gateReport;
    }

    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        FMAutoMountSetError(error, 8,
                            @"Another Font Manager operation is running.",
                            lockError);
        return nil;
    }

    NSError *operationError = nil;
    NSDictionary *result = FMAutoMountLocked(&operationError);
    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (result == nil || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }
    return result;
}

static BOOL FMAutoMountSecurePublishedState(NSString *statePath,
                                            NSError **error) {
    int descriptor = open(statePath.fileSystemRepresentation,
                          O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        FMAutoMountSetError(
            error, 7, @"The automatic Respring policy could not be secured.",
            FMAutoMountPOSIXError(errno));
        return NO;
    }

    struct stat info = {0};
    BOOL secured = fstat(descriptor, &info) == 0 && S_ISREG(info.st_mode) &&
        fchown(descriptor, 0, 0) == 0 && fchmod(descriptor, 0600) == 0 &&
        fsync(descriptor) == 0;
    int savedError = secured ? 0 : (errno != 0 ? errno : EPERM);
    if (close(descriptor) != 0 && secured) {
        secured = NO;
        savedError = errno;
    }
    if (!secured) {
        FMAutoMountSetError(
            error, 7, @"The automatic Respring policy could not be secured.",
            FMAutoMountPOSIXError(savedError));
    }
    return secured;
}

NSDictionary<NSString *, id> *FMSetAutomaticRespringEnabled(
    NSString *confirmedSystemBuild,
    BOOL enabled,
    NSError **error) {
    if (geteuid() != 0) {
        FMAutoMountSetError(
            error, 2,
            @"Changing the automatic Respring policy requires effective uid 0.",
            nil);
        return nil;
    }
    NSError *validationError = nil;
    NSString *currentBuild = FMAutoMountSystemBuild(&validationError);
    if (!FMAutoMountSafeComponent(confirmedSystemBuild) ||
        currentBuild == nil || ![currentBuild isEqual:confirmedSystemBuild]) {
        FMAutoMountSetError(
            error, 3,
            @"The confirmed system build does not match this device.",
            validationError);
        return nil;
    }

    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        FMAutoMountSetError(error, 8,
                            @"Another Font Manager operation is running.",
                            lockError);
        return nil;
    }

    NSError *operationError = nil;
    NSDictionary<NSString *, id> *state =
        FMAutoMountReadValidatedState(confirmedSystemBuild, &operationError);
    BOOL currentEnabled = [state[@"autoRespring"] boolValue];
    BOOL stateChanged = state != nil && currentEnabled != enabled;
    if (stateChanged) {
        NSMutableDictionary<NSString *, id> *updatedState = [state mutableCopy];
        updatedState[@"autoRespring"] = enabled ? @YES : @NO;
        NSString *statePath = jbroot(FMStateLogicalPath);
        BOOL wrote = FMValidateStateDocument(updatedState, &operationError) &&
            FMWriteJSONObjectAtomically(updatedState, statePath, 0600,
                                        &operationError) &&
            FMAutoMountSecurePublishedState(statePath, &operationError);
        NSDictionary *readback = wrote
            ? FMAutoMountReadValidatedState(confirmedSystemBuild, &operationError)
            : nil;
        if (readback == nil || ![readback isEqual:updatedState]) {
            state = nil;
            if (operationError == nil) {
                FMAutoMountSetError(
                    &operationError, 7,
                    @"The automatic Respring policy failed exact readback.", nil);
            }
        } else {
            state = readback;
        }
    }

    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (state == nil || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }

    NSString *status = enabled
        ? (stateChanged ? @"enabled" : @"alreadyEnabled")
        : (stateChanged ? @"disabled" : @"alreadyDisabled");
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"setAutomaticRespring",
        @"status" : status,
        @"systemBuild" : confirmedSystemBuild,
        @"enabled" : enabled ? @YES : @NO,
        @"filesystemMutated" : stateChanged ? @YES : @NO,
        @"stateChanged" : stateChanged ? @YES : @NO,
        @"mountBackendInvoked" : @NO,
        @"restartRequested" : @NO,
    };
}
