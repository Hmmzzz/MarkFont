#import "FMDeviceProfileStage.h"

#import <errno.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMDeviceFontCatalog.h"
#import "FMDeviceSupplementalFontWorkspace.h"
#import "FMEnvironmentProbe.h"
#import "FMFileStore.h"
#import "FMOperationLock.h"
#import "FMProfileAdoptionValidator.h"
#import "FMProfileEngine.h"
#import "FMProfileStagePlanner.h"
#import "FMMountPaths.h"

NSString *const FMDeviceProfileStageErrorDomain =
    @"com.hmmzzz.fontmanager.device-profile-stage";

static BOOL FMDeviceStageFail(NSError **error,
                              NSInteger code,
                              NSString *description,
                              NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMDeviceProfileStageErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMDeviceStageBuildIsSafe(NSString *systemBuild) {
    return [systemBuild isKindOfClass:NSString.class] &&
           systemBuild.length > 0 && systemBuild.length <= 32 &&
           !systemBuild.isAbsolutePath && systemBuild.pathComponents.count == 1 &&
           [systemBuild.lastPathComponent isEqual:systemBuild];
}

static BOOL FMDeviceStageRequireDirectory(NSString *path,
                                          NSString *purpose,
                                          NSError **error) {
    struct stat info = {0};
    int inspectResult = lstat(path.fileSystemRepresentation, &info);
    if (inspectResult == 0 && S_ISDIR(info.st_mode)) {
        return YES;
    }
    int savedError = inspectResult == 0 ? ENOTDIR : errno;
    return FMDeviceStageFail(
        error, 3, [NSString stringWithFormat:@"%@ is unavailable.", purpose],
        [NSError errorWithDomain:NSPOSIXErrorDomain
                            code:savedError
                        userInfo:nil]);
}

static BOOL FMDeviceStageRequireRegularFile(NSString *path,
                                            NSString *purpose,
                                            NSError **error) {
    struct stat info = {0};
    int inspectResult = lstat(path.fileSystemRepresentation, &info);
    if (inspectResult == 0 && S_ISREG(info.st_mode)) {
        return YES;
    }
    int savedError = inspectResult == 0 ? EINVAL : errno;
    return FMDeviceStageFail(
        error, 3, [NSString stringWithFormat:@"%@ is unavailable.", purpose],
        [NSError errorWithDomain:NSPOSIXErrorDomain
                            code:savedError
                        userInfo:nil]);
}

static NSDictionary<NSString *, id> *FMDeviceStageReadState(
    NSString *statePath,
    NSString *systemBuild,
    NSError **error) {
    NSError *stateError = nil;
    id stateObject = FMReadJSONObjectAtPath(statePath, &stateError);
    if (![stateObject isKindOfClass:NSDictionary.class] ||
        !FMValidateStateDocument(stateObject, &stateError) ||
        ![stateObject[@"systemBuild"] isEqual:systemBuild]) {
        FMDeviceStageFail(error, 3,
                          @"Persistent Profile state is unavailable or invalid.",
                          stateError);
        return nil;
    }
    return stateObject;
}

static NSDictionary<NSString *, id> *FMDeviceStageCreateBaseContext(
    NSString *confirmedSystemBuild,
    BOOL requireCleanState,
    NSError **error) {
    if (geteuid() != 0) {
        FMDeviceStageFail(error, 1,
                          @"Profile engine operations require effective uid 0.", nil);
        return nil;
    }
    if (!FMDeviceStageBuildIsSafe(confirmedSystemBuild)) {
        FMDeviceStageFail(error, 2, @"The confirmed system build is invalid.", nil);
        return nil;
    }

    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSDictionary *system = environment[@"system"];
    NSDictionary *fonts = environment[@"fonts"];
    NSDictionary *environmentState = environment[@"state"];
    if (![system[@"productBuildVersion"] isEqual:confirmedSystemBuild] ||
        ![fonts[@"mappingActive"] boolValue] ||
        ![fonts[@"mirrorPresent"] boolValue] ||
        ![fonts[@"rootfsDirectoryReadable"] boolValue] ||
        ![fonts[@"systemDirectoryReadable"] boolValue] ||
        ![fonts[@"mountStorageSupported"] boolValue] ||
        ![fonts[@"targetFilesystemType"] isEqual:@"bindfs"] ||
        ![environmentState[@"present"] boolValue] ||
        ![environmentState[@"valid"] boolValue] ||
        ![environmentState[@"systemBuild"] isEqual:confirmedSystemBuild]) {
        FMDeviceStageFail(error, 3,
                          @"The managed font mirror is not ready.", nil);
        return nil;
    }

    BOOL mountStorageSupported = NO;
    NSString *mirrorLogicalPath = FMMountResolvedMirrorLogicalPath(
        &mountStorageSupported, NULL);
    if (!mountStorageSupported) {
        FMDeviceStageFail(error, 3,
                          @"The managed mirror location is unavailable.", nil);
        return nil;
    }
    NSString *mirrorRoot = jbroot(mirrorLogicalPath);
    NSString *stockRoot = [jbroot(@"/var/lib/fontmanager/stock")
        stringByAppendingPathComponent:confirmedSystemBuild];
    if (!FMDeviceStageRequireDirectory(mirrorRoot, @"The font mirror", error) ||
        !FMDeviceStageRequireDirectory(stockRoot, @"The Stock font source", error) ||
        !FMMountManagedMappingIsActive(error)) {
        return nil;
    }

    struct stat stockInfo = {0};
    struct stat mirrorInfo = {0};
    if (lstat(stockRoot.fileSystemRepresentation, &stockInfo) != 0 ||
        lstat(mirrorRoot.fileSystemRepresentation, &mirrorInfo) != 0 ||
        (stockInfo.st_dev == mirrorInfo.st_dev &&
         stockInfo.st_ino == mirrorInfo.st_ino)) {
        FMDeviceStageFail(error, 3,
                          @"Stock and mirror font directories are not distinct.", nil);
        return nil;
    }

    struct statfs mirrorFilesystem = {0};
    if (statfs(mirrorRoot.fileSystemRepresentation, &mirrorFilesystem) != 0 ||
        (mirrorFilesystem.f_flags & MNT_RDONLY) != 0) {
        FMDeviceStageFail(error, 3,
                          @"The underlying font mirror is not writable.", nil);
        return nil;
    }

    NSString *statePath = jbroot(@"/var/lib/fontmanager/state.json");
    if (!FMDeviceStageRequireRegularFile(statePath, @"Profile state", error)) {
        return nil;
    }
    NSDictionary *state = FMDeviceStageReadState(
        statePath, confirmedSystemBuild, error);
    if (state == nil) return nil;
    NSString *mirrorState = state[@"mirrorState"];
    if (requireCleanState) {
        if (![mirrorState isEqual:@"clean"] ||
            [state[@"restartRequired"] boolValue]) {
            FMDeviceStageFail(
                error, 3,
                @"Finish or repair the current font change before switching again.", nil);
            return nil;
        }
    } else if (![mirrorState isEqual:@"updating"] &&
               ![mirrorState isEqual:@"repairRequired"]) {
        FMDeviceStageFail(error, 3,
                          @"There is no interrupted font change to repair.", nil);
        return nil;
    }

    NSError *catalogError = nil;
    NSDictionary *catalog = FMCreateDeviceFontCatalogForBuild(
        confirmedSystemBuild, &catalogError);
    if (catalog == nil) {
        FMDeviceStageFail(error, 3,
                          @"The current-build font catalog is unavailable.",
                          catalogError);
        return nil;
    }

    NSString *profilesRoot = jbroot(@"/var/lib/fontmanager/profiles");
    if (!FMDeviceStageRequireDirectory(
            profilesRoot, @"The adopted Profile library", error)) {
        return nil;
    }
    NSString *supplementalMirrorRoot =
        catalog[@"supplementalSource"] != nil
            ? FMMountResolvedFontServicesCorePrivateMirrorPath() : nil;
    if (supplementalMirrorRoot != nil &&
        !FMDeviceStageRequireDirectory(
            supplementalMirrorRoot, @"The supplemental font mirror", error)) {
        return nil;
    }
    return @{
        @"systemBuild" : confirmedSystemBuild,
        @"state" : state,
        @"statePath" : statePath,
        @"catalog" : catalog,
        @"stockRoot" : stockRoot,
        @"mirrorRoot" : mirrorRoot,
        @"supplementalMirrorRoot" :
            supplementalMirrorRoot ?: NSNull.null,
        @"profilesRoot" : profilesRoot,
        @"availableBytes" : @(
            (unsigned long long)mirrorFilesystem.f_bavail *
            (unsigned long long)mirrorFilesystem.f_bsize),
    };
}

static NSDictionary<NSString *, id> *FMDeviceStageCreateProfilePreview(
    NSDictionary<NSString *, id> *context,
    NSString *profileID,
    NSError **error) {
    NSError *previewError = nil;
    NSDictionary *preview = FMCreateProfileAdoptionPreviewAtRoot(
        context[@"profilesRoot"], profileID, context[@"systemBuild"],
        context[@"catalog"], &previewError);
    if (preview == nil) {
        FMDeviceStageFail(error, 4,
                          @"The adopted Profile is unavailable or invalid.",
                          previewError);
    }
    return preview;
}

static NSDictionary<NSString *, id> *FMDeviceStageCreatePreflight(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSDictionary<NSString *, id> **contextResult,
    NSDictionary<NSString *, id> **previewResult,
    NSError **error) {
    NSDictionary *context = FMDeviceStageCreateBaseContext(
        confirmedSystemBuild, YES, error);
    if (context == nil) return nil;
    NSDictionary *preview = profileID != nil
        ? FMDeviceStageCreateProfilePreview(context, profileID, error)
        : nil;
    if (profileID != nil && preview == nil) return nil;

    NSError *planError = nil;
    NSString *supplementalMirrorRoot =
        context[@"supplementalMirrorRoot"] == NSNull.null
            ? nil : context[@"supplementalMirrorRoot"];
    NSDictionary *plan =
        FMCreateProfileStagePlanAtRootsWithSupplementalMirror(
        context[@"stockRoot"], context[@"mirrorRoot"], supplementalMirrorRoot,
        context[@"profilesRoot"],
        profileID, context[@"statePath"], confirmedSystemBuild,
        context[@"catalog"], &planError);
    if (plan == nil) {
        FMDeviceStageFail(error, 5,
                          @"The files involved in this font change are not ready.",
                          planError);
        return nil;
    }

    unsigned long long largestWrite = 0;
    for (NSDictionary *action in plan[@"actions"]) {
        largestWrite = MAX(largestWrite,
                           [action[@"targetBytes"] unsignedLongLongValue]);
    }
    if ([context[@"availableBytes"] unsignedLongLongValue] < largestWrite) {
        FMDeviceStageFail(error, 5,
                          @"There is not enough space for the largest font file.", nil);
        return nil;
    }

    NSMutableDictionary *report = [plan mutableCopy];
    report[@"profileName"] = preview != nil ? preview[@"profileName"] : @"系统默认";
    report[@"profileJSONSHA256"] =
        preview != nil ? preview[@"profileJSONSHA256"] : NSNull.null;
    report[@"profileAlreadyAdopted"] = preview != nil ? @YES : @NO;
    report[@"availableBytes"] = context[@"availableBytes"];
    report[@"largestWriteBytes"] = @(largestWrite);
    report[@"mappingActive"] = @YES;
    report[@"mappingReadOnly"] = @YES;
    if (contextResult != NULL) *contextResult = context;
    if (previewResult != NULL) *previewResult = preview;
    return report;
}

NSDictionary<NSString *, id> *FMCreateDeviceProfileStagePreflight(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSError **error) {
    return FMDeviceStageCreatePreflight(
        confirmedSystemBuild, profileID, NULL, NULL, error);
}

static BOOL FMDeviceStageWorkingProfileMatches(
    NSDictionary<NSString *, id> *state,
    id expectedProfileID) {
    return [state[@"mirrorState"] isEqual:@"clean"] &&
           [state[@"workingProfileID"] isEqual:expectedProfileID];
}

static NSDictionary<NSString *, id> *FMStageDeviceProfileLocked(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSError **error) {
    NSError *supplementalError = nil;
    if (FMEnsureDeviceSupplementalFontWorkspaceWithExistingLock(
            confirmedSystemBuild, &supplementalError) == nil) {
        FMDeviceStageFail(
            error, 5,
            @"The current-build supplemental font workspace is unavailable.",
            supplementalError);
        return nil;
    }
    NSDictionary<NSString *, id> *context = nil;
    NSDictionary<NSString *, id> *preview = nil;
    NSDictionary *preflight = FMDeviceStageCreatePreflight(
        confirmedSystemBuild, profileID, &context, &preview, error);
    if (preflight == nil) return nil;
    id targetProfileID = profileID ?: NSNull.null;
    NSString *operation = profileID != nil ? @"stageProfile" : @"stageStock";
    if ([preflight[@"currentWorkingProfileID"] isEqual:targetProfileID]) {
        return @{
            @"schemaVersion" : @1,
            @"operation" : operation,
            @"status" : @"alreadyStaged",
            @"systemBuild" : confirmedSystemBuild,
            @"profileID" : targetProfileID,
            @"profileName" : preflight[@"profileName"],
            @"managedPathCount" : @([preflight[@"managedRelativePaths"] count]),
            @"filesystemMutated" : @NO,
            @"mirrorChanged" : @NO,
            @"stateChanged" : @NO,
            @"mountBackendInvoked" : @NO,
            @"restartRequired" : @NO,
            @"restartRequested" : @NO,
        };
    }

    NSError *engineError = nil;
    NSString *supplementalMirrorRoot =
        context[@"supplementalMirrorRoot"] == NSNull.null
            ? nil : context[@"supplementalMirrorRoot"];
    if (!FMStageProfileAtRootsWithSupplementalMirror(
            context[@"stockRoot"], context[@"mirrorRoot"], supplementalMirrorRoot,
            preview != nil ? preview[@"profileDocument"] : nil,
            preview != nil ? preview[@"profileDirectory"] : nil,
            preflight[@"stockRestoreRelativePaths"], context[@"statePath"],
            FMProfileEngineNoFaultInjection, &engineError)) {
        FMDeviceStageFail(error, 6,
                          @"The font change stopped and can be repaired safely.",
                          engineError);
        return nil;
    }

    NSError *postError = nil;
    NSDictionary *postState = FMDeviceStageReadState(
        context[@"statePath"], confirmedSystemBuild, &postError);
    if (postState == nil ||
        !FMDeviceStageWorkingProfileMatches(postState, targetProfileID)) {
        NSError *markError = nil;
        FMMarkProfileRepairRequiredAtStatePath(
            context[@"statePath"], preflight[@"managedRelativePaths"], &markError);
        FMDeviceStageFail(error, 7,
                          @"The font change needs one repair pass.",
                          markError ?: postError);
        return nil;
    }
    BOOL mirrorChanged = [preflight[@"writeCount"] unsignedIntegerValue] > 0;
    return @{
        @"schemaVersion" : @1,
        @"operation" : operation,
        @"status" : @"staged",
        @"systemBuild" : confirmedSystemBuild,
        @"profileID" : targetProfileID,
        @"profileName" : preflight[@"profileName"],
        @"profileJSONSHA256" : preflight[@"profileJSONSHA256"],
        @"managedPathCount" : @([preflight[@"managedRelativePaths"] count]),
        @"stockRestoreCount" : preflight[@"stockRestoreCount"],
        @"replacementCount" : preflight[@"replacementCount"],
        @"plannedWriteCount" : preflight[@"writeCount"],
        @"plannedWriteBytes" : preflight[@"writeBytes"],
        @"filesystemMutated" : @YES,
        @"mirrorChanged" : mirrorChanged ? @YES : @NO,
        @"stateChanged" : @YES,
        @"mountBackendInvoked" : @NO,
        @"restartRequired" : postState[@"restartRequired"],
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMStageDeviceProfileWithExistingLock(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSError **error) {
    return FMStageDeviceProfileLocked(confirmedSystemBuild, profileID, error);
}

NSDictionary<NSString *, id> *FMStageDeviceProfile(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSError **error) {
    NSString *engineRoot = jbroot(@"/var/lib/fontmanager");
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        FMDeviceStageFail(error, 8,
                          @"Another font operation is already running.", lockError);
        return nil;
    }
    NSError *operationError = nil;
    NSDictionary *result = FMStageDeviceProfileLocked(
        confirmedSystemBuild, profileID, &operationError);
    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (result == nil || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }
    return result;
}

static NSDictionary<NSString *, id> *FMRepairDeviceWorkingProfileLocked(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSError *supplementalError = nil;
    if (FMEnsureDeviceSupplementalFontWorkspaceWithExistingLock(
            confirmedSystemBuild, &supplementalError) == nil) {
        FMDeviceStageFail(
            error, 9,
            @"The supplemental font workspace could not be restored for repair.",
            supplementalError);
        return nil;
    }
    NSDictionary *context = FMDeviceStageCreateBaseContext(
        confirmedSystemBuild, NO, error);
    if (context == nil) return nil;
    NSDictionary *state = context[@"state"];
    NSArray<NSString *> *managedPaths = state[@"transitionManagedPaths"];
    id workingProfileID = state[@"workingProfileID"];
    NSDictionary *preview = nil;
    if ([workingProfileID isKindOfClass:NSString.class]) {
        preview = FMDeviceStageCreateProfilePreview(
            context, workingProfileID, error);
        if (preview == nil) return nil;
    } else if (workingProfileID != NSNull.null) {
        FMDeviceStageFail(error, 9,
                          @"The saved repair target is invalid.", nil);
        return nil;
    }

    NSMutableSet<NSString *> *catalogPaths = [NSMutableSet set];
    for (NSDictionary *file in context[@"catalog"][@"files"]) {
        [catalogPaths addObject:file[@"relativePath"]];
    }
    for (NSString *relativePath in managedPaths) {
        if (![catalogPaths containsObject:relativePath]) {
            FMDeviceStageFail(error, 9,
                              @"A saved repair path is not in this build's catalog.", nil);
            return nil;
        }
    }

    NSError *repairError = nil;
    NSString *supplementalMirrorRoot =
        context[@"supplementalMirrorRoot"] == NSNull.null
            ? nil : context[@"supplementalMirrorRoot"];
    if (!FMRepairProfileAtRootsWithSupplementalMirror(
            context[@"stockRoot"], context[@"mirrorRoot"], supplementalMirrorRoot,
            preview[@"profileDocument"], preview[@"profileDirectory"], managedPaths,
            context[@"statePath"], FMProfileEngineNoFaultInjection, &repairError)) {
        FMDeviceStageFail(error, 10,
                          @"The interrupted font change could not be repaired.",
                          repairError);
        return nil;
    }

    NSError *postError = nil;
    NSDictionary *postState = FMDeviceStageReadState(
        context[@"statePath"], confirmedSystemBuild, &postError);
    if (postState == nil ||
        !FMDeviceStageWorkingProfileMatches(postState, workingProfileID)) {
        FMDeviceStageFail(error, 11,
                          @"The repaired state could not be confirmed.", postError);
        return nil;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"repairWorkingProfile",
        @"status" : @"repaired",
        @"systemBuild" : confirmedSystemBuild,
        @"workingProfileID" : workingProfileID,
        @"managedPathCount" : @(managedPaths.count),
        @"mirrorState" : @"clean",
        @"filesystemMutated" : @YES,
        @"mirrorChanged" : managedPaths.count > 0 ? @YES : @NO,
        @"stateChanged" : @YES,
        @"mountBackendInvoked" : @NO,
        @"restartRequired" : postState[@"restartRequired"],
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMRepairDeviceWorkingProfile(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSString *engineRoot = jbroot(@"/var/lib/fontmanager");
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        FMDeviceStageFail(error, 8,
                          @"Another font operation is already running.", lockError);
        return nil;
    }
    NSError *operationError = nil;
    NSDictionary *result = FMRepairDeviceWorkingProfileLocked(
        confirmedSystemBuild, &operationError);
    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (result == nil || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }
    return result;
}
