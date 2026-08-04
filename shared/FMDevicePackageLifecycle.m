#import "FMDevicePackageLifecycle.h"

#import <errno.h>
#import <fcntl.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMDeviceAutoMount.h"
#import "FMDeviceLegacyFontTakeover.h"
#import "FMDeviceMountEngine.h"
#import "FMDeviceProfileAdoption.h"
#import "FMDeviceProfileStage.h"
#import "FMEnvironmentProbe.h"
#import "FMFileStore.h"
#import "FMOperationLock.h"
#import "FMProfileEngine.h"
#import "FMProviderExecutor.h"
#import "FMProviderInspection.h"
#import "FMProviderPaths.h"
#import "FMSecureDirectory.h"
#import "FMTreeManifest.h"

NSString *const FMDevicePackageLifecycleErrorDomain =
    @"com.hmmzzz.fontmanager.device-package-lifecycle";

static NSString *const FMEngineRootLogicalPath = @"/var/lib/fontmanager";
static NSString *const FMStateLogicalPath = @"/var/lib/fontmanager/state.json";
static NSString *const FMDisableMountLogicalPath =
    @"/var/lib/fontmanager/disable-mount";
static NSString *const FMRemovalReadyLogicalPath =
    @"/var/lib/fontmanager/.package-removal-ready";
static NSString *const FMOwnershipLogicalPath =
    @"/var/lib/fontmanager/.package-owned";
static NSString *const FMMirrorOwnershipLogicalPath =
    @"/var/lib/fontmanager/.mirror-owned";

typedef NS_ENUM(NSInteger, FMFontTargetDisposition) {
    FMFontTargetDispositionInactive = 0,
    FMFontTargetDispositionManaged = 1,
    FMFontTargetDispositionUnexpected = 2,
};

static BOOL FMPackageLifecycleFail(NSError **error,
                                   NSInteger code,
                                   NSString *description,
                                   NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMDevicePackageLifecycleErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSError *FMPackagePOSIXError(int errorNumber) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:errorNumber
                           userInfo:nil];
}

static BOOL FMPackageRequireManagerRoot(NSError **error) {
    return (getuid() == 0 && geteuid() == 0) ||
        FMPackageLifecycleFail(
            error, 1,
            @"Package lifecycle operations require a real root package-manager caller.",
            nil);
}

static BOOL FMPackageSafeBuild(NSString *systemBuild) {
    return [systemBuild isKindOfClass:NSString.class] &&
        systemBuild.length > 0 && systemBuild.length <= 32 &&
        !systemBuild.isAbsolutePath && systemBuild.pathComponents.count == 1 &&
        [systemBuild.lastPathComponent isEqual:systemBuild] &&
        ![systemBuild isEqual:@"."] && ![systemBuild isEqual:@".."];
}

static NSDictionary<NSString *, id> *_Nullable FMPackageTargetFacts(
    NSError **error) {
    BOOL rootSupported = NO;
    NSString *mirrorLogicalPath =
        FMProviderResolvedMirrorLogicalPath(&rootSupported, NULL);
    struct statfs filesystem = {0};
    if (!rootSupported ||
        statfs(FMProviderSystemFontsLogicalPath.fileSystemRepresentation,
               &filesystem) != 0) {
        int savedError = rootSupported ? errno : 0;
        FMPackageLifecycleFail(
            error, 2, @"The system font target could not be inspected.",
            savedError != 0 ? FMPackagePOSIXError(savedError) : nil);
        return nil;
    }

    NSString *filesystemType =
        [NSString stringWithUTF8String:filesystem.f_fstypename];
    NSString *target = [NSString stringWithUTF8String:filesystem.f_mntonname];
    NSString *source = [NSString stringWithUTF8String:filesystem.f_mntfromname];
    BOOL bindfs = filesystemType != nil &&
        [filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame;
    BOOL dedicated = [target isEqual:FMProviderSystemFontsLogicalPath];
    NSString *mirrorPath = jbroot(mirrorLogicalPath);
    BOOL managed = bindfs && dedicated && source.length > 0 &&
        [source.stringByResolvingSymlinksInPath
            isEqual:mirrorPath.stringByResolvingSymlinksInPath] &&
        (filesystem.f_flags & MNT_RDONLY) != 0;
    FMFontTargetDisposition disposition = managed
        ? FMFontTargetDispositionManaged
        : (dedicated || bindfs)
            ? FMFontTargetDispositionUnexpected
            : FMFontTargetDispositionInactive;
    return @{
        @"disposition" : @(disposition),
        @"filesystemType" : filesystemType ?: NSNull.null,
        @"dedicated" : dedicated ? @YES : @NO,
        @"managed" : managed ? @YES : @NO,
    };
}

static BOOL FMPackageEngineRootPresent(BOOL *present, NSError **error) {
    if (present == NULL) {
        return FMPackageLifecycleFail(
            error, 2, @"The package engine-root result is unavailable.", nil);
    }
    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    struct stat info = {0};
    errno = 0;
    if (lstat(engineRoot.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) {
            *present = NO;
            return YES;
        }
        int savedError = errno;
        *present = NO;
        return FMPackageLifecycleFail(
            error, 2, @"The package engine root could not be inspected.",
            FMPackagePOSIXError(savedError));
    }
    if (!S_ISDIR(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        *present = NO;
        return FMPackageLifecycleFail(
            error, 2, @"The package engine root has unsafe metadata.", nil);
    }
    *present = YES;
    return YES;
}

static BOOL FMPackageRequirePhysicalStockTarget(NSError **error) {
    int descriptor = open(FMProviderSystemFontsLogicalPath.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return FMPackageLifecycleFail(
            error, 3, @"The exposed Stock font directory could not be opened.",
            FMPackagePOSIXError(errno));
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
        return FMPackageLifecycleFail(
            error, 3, @"The exposed Stock font directory has unsafe metadata.",
            FMPackagePOSIXError(savedError));
    }
    return YES;
}

static BOOL FMPackageRequireSecureManagedMirror(NSError **error) {
    BOOL rootSupported = NO;
    NSString *mirrorLogicalPath =
        FMProviderResolvedMirrorLogicalPath(&rootSupported, NULL);
    NSString *mirrorPath = rootSupported ? jbroot(mirrorLogicalPath) : nil;
    struct stat info = {0};
    errno = 0;
    if (!rootSupported ||
        lstat(mirrorPath.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        int savedError = errno != 0 ? errno : EPERM;
        return FMPackageLifecycleFail(
            error, 3,
            @"The existing managed mirror cannot be claimed safely.",
            FMPackagePOSIXError(savedError));
    }
    return YES;
}

static BOOL FMPackageRequireSecureRegularFile(NSString *path,
                                              NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        int savedError = errno != 0 ? errno : EPERM;
        return FMPackageLifecycleFail(
            error, 3, @"A package lifecycle record has unsafe metadata.",
            FMPackagePOSIXError(savedError));
    }
    return YES;
}

static BOOL FMPackageEnsureMarker(NSString *logicalPath,
                                  NSString *purpose,
                                  NSString *systemBuild,
                                  NSError **error) {
    NSString *path = jbroot(logicalPath);
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        NSError *markerError = nil;
        id object = FMPackageRequireSecureRegularFile(path, &markerError)
            ? FMReadJSONObjectAtPath(path, &markerError) : nil;
        if (![object isKindOfClass:NSDictionary.class] ||
            ![object[@"schemaVersion"] isEqual:@1] ||
            ![object[@"purpose"] isEqual:purpose] ||
            ![object[@"systemBuild"] isEqual:systemBuild]) {
            return FMPackageLifecycleFail(
                error, 3, @"A package lifecycle marker is invalid.",
                markerError);
        }
        return YES;
    }
    if (errno != ENOENT) {
        return FMPackageLifecycleFail(
            error, 3, @"A package lifecycle marker could not be inspected.",
            FMPackagePOSIXError(errno));
    }
    NSDictionary *record = @{
        @"schemaVersion" : @1,
        @"purpose" : purpose,
        @"systemBuild" : systemBuild,
    };
    NSError *writeError = nil;
    if (!FMWriteJSONObjectAtomicallyIfAbsent(record, path, 0600, &writeError) ||
        !FMPackageRequireSecureRegularFile(path, &writeError)) {
        return FMPackageLifecycleFail(
            error, 3, @"A package lifecycle marker could not be published.",
            writeError);
    }
    return YES;
}

static BOOL FMPackageMarkerPresent(NSString *logicalPath,
                                   NSString *purpose,
                                   NSString *systemBuild,
                                   BOOL *present,
                                   NSError **error) {
    if (present == NULL) {
        return FMPackageLifecycleFail(
            error, 3, @"A package marker presence result is unavailable.", nil);
    }
    NSString *path = jbroot(logicalPath);
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) {
            *present = NO;
            return YES;
        }
        *present = NO;
        return FMPackageLifecycleFail(
            error, 3, @"A package marker could not be inspected.",
            FMPackagePOSIXError(errno));
    }
    *present = YES;
    NSError *markerError = nil;
    id object = FMPackageRequireSecureRegularFile(path, &markerError)
        ? FMReadJSONObjectAtPath(path, &markerError) : nil;
    if (![object isKindOfClass:NSDictionary.class] ||
        ![object[@"schemaVersion"] isEqual:@1] ||
        ![object[@"purpose"] isEqual:purpose] ||
        ![object[@"systemBuild"] isEqual:systemBuild]) {
        return FMPackageLifecycleFail(
            error, 3, @"A package marker is invalid.", markerError);
    }
    return YES;
}

static BOOL FMPackageClaimEmptyInitialization(NSString *systemBuild,
                                              NSError **error) {
    NSString *varLibrary = jbroot(@"/var/lib");
    NSError *claimError = nil;
    BOOL engineRootPresent = NO;
    if (!FMPackageEngineRootPresent(&engineRootPresent, &claimError)) {
        if (error != NULL) *error = claimError;
        return NO;
    }
    if (engineRootPresent) {
        BOOL packageOwned = NO;
        if (!FMPackageMarkerPresent(
                FMOwnershipLogicalPath, @"packageOwned", systemBuild,
                &packageOwned, &claimError) || !packageOwned) {
            return FMPackageLifecycleFail(
                error, 3,
                @"An unowned engine root blocks first-install initialization.",
                claimError);
        }
        return YES;
    }
    if (!FMEnsureSecureDirectoryTree(
            varLibrary, @[ @"fontmanager" ], 0, 0, 0755, &claimError) ||
        !FMPackageEnsureMarker(
            FMOwnershipLogicalPath, @"packageOwned", systemBuild,
            &claimError)) {
        return FMPackageLifecycleFail(
            error, 3,
            @"The empty installation could not claim its private data root.",
            claimError);
    }
    return YES;
}

static NSDictionary<NSString *, id> *_Nullable FMPackageReadState(
    NSString *systemBuild,
    BOOL *present,
    NSError **error) {
    if (present == NULL) {
        FMPackageLifecycleFail(
            error, 3, @"The package state-presence result is unavailable.", nil);
        return nil;
    }
    NSString *statePath = jbroot(FMStateLogicalPath);
    struct stat info = {0};
    errno = 0;
    if (lstat(statePath.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) {
            *present = NO;
            return @{};
        }
        int savedError = errno;
        *present = NO;
        FMPackageLifecycleFail(
            error, 3, @"Persistent package state could not be inspected.",
            FMPackagePOSIXError(savedError));
        return nil;
    }
    *present = YES;
    NSError *stateError = nil;
    id state = FMPackageRequireSecureRegularFile(statePath, &stateError)
        ? FMReadJSONObjectAtPath(statePath, &stateError)
        : nil;
    if (![state isKindOfClass:NSDictionary.class] ||
        !FMValidateStateDocument(state, &stateError) ||
        ![state[@"systemBuild"] isEqual:systemBuild]) {
        FMPackageLifecycleFail(
            error, 3,
            @"Persistent package state is invalid or belongs to another system build.",
            stateError);
        return nil;
    }
    return state;
}

static BOOL FMPackageLegacyTakeoverJournalPresent(BOOL *present,
                                                   NSError **error) {
    if (present == NULL) {
        return FMPackageLifecycleFail(
            error, 3, @"The takeover-journal result is unavailable.", nil);
    }
    struct stat info = {0};
    errno = 0;
    if (lstat(jbroot(FMLegacyFontTakeoverJournalLogicalPath)
                  .fileSystemRepresentation,
              &info) == 0) {
        *present = YES;
        return YES;
    }
    if (errno == ENOENT) {
        *present = NO;
        return YES;
    }
    *present = NO;
    return FMPackageLifecycleFail(
        error, 3, @"The takeover journal could not be inspected.",
        FMPackagePOSIXError(errno));
}

static BOOL FMPackageStateIDsEqual(id left, id right) {
    BOOL leftStock = left == nil || left == NSNull.null;
    BOOL rightStock = right == nil || right == NSNull.null;
    return leftStock || rightStock ? leftStock && rightStock
                                   : [left isEqual:right];
}

static NSDictionary<NSString *, id> *_Nullable
FMPackageFinishLegacyProfileLocked(
    NSString *systemBuild,
    NSDictionary<NSString *, id> *takeover,
    NSError **error) {
    BOOL imported = [takeover[@"profileCreated"] boolValue];
    BOOL wasActive = [takeover[@"mappingWasActive"] boolValue];
    NSString *profileID = imported &&
            [takeover[@"profileID"] isKindOfClass:NSString.class]
        ? takeover[@"profileID"] : nil;
    BOOL statePresent = NO;
    NSError *operationError = nil;
    NSDictionary *state = FMPackageReadState(
        systemBuild, &statePresent, &operationError);
    NSDictionary *targetFacts = state != nil && statePresent
        ? FMPackageTargetFacts(&operationError) : nil;
    FMFontTargetDisposition disposition = targetFacts != nil
        ? [targetFacts[@"disposition"] integerValue]
        : FMFontTargetDispositionUnexpected;
    if (state == nil || !statePresent ||
        ![state[@"mirrorState"] isEqual:@"clean"] ||
        disposition == FMFontTargetDispositionUnexpected) {
        FMPackageLifecycleFail(
            error, 8,
            @"The initialized workspace cannot activate the imported legacy Profile.",
            operationError);
        return nil;
    }

    BOOL providerInvoked = NO;
    BOOL mappingChanged = NO;
    if (disposition == FMFontTargetDispositionInactive) {
        NSDictionary *mount =
            FMInvokeProviderForPreparedSystemFonts(&operationError);
        if (mount == nil || ![mount[@"reportedSuccess"] boolValue] ||
            !FMProviderManagedMappingIsActive(&operationError)) {
            FMPackageLifecycleFail(
                error, 8,
                @"The initialized font mapping could not be restored.",
                operationError);
            return nil;
        }
        providerInvoked = YES;
        mappingChanged = YES;
    }

    if (!imported || !wasActive) {
        if (!FMCompleteLegacyFontTakeover(systemBuild, error)) return nil;
        return @{
            @"profileImported" : imported ? @YES : @NO,
            @"profileActivated" : @NO,
            @"profileID" : profileID ?: NSNull.null,
            @"providerInvoked" : providerInvoked ? @YES : @NO,
            @"mappingChanged" : mappingChanged ? @YES : @NO,
            @"stateChanged" : @NO,
        };
    }

    BOOL alreadyConfirmed =
        FMPackageStateIDsEqual(state[@"confirmedProfileID"], profileID) &&
        FMPackageStateIDsEqual(state[@"workingProfileID"], profileID) &&
        ![state[@"restartRequired"] boolValue];
    BOOL pendingImportedProfile =
        state[@"confirmedProfileID"] == NSNull.null &&
        [state[@"workingProfileID"] isEqual:profileID] &&
        [state[@"restartRequired"] boolValue];
    BOOL stillStock = state[@"confirmedProfileID"] == NSNull.null &&
        state[@"workingProfileID"] == NSNull.null &&
        ![state[@"restartRequired"] boolValue];
    BOOL stageChanged = NO;
    if (!alreadyConfirmed && !pendingImportedProfile) {
        if (!stillStock) {
            FMPackageLifecycleFail(
                error, 8,
                @"Another font selection conflicts with first-install legacy activation.",
                nil);
            return nil;
        }
        NSDictionary *adoption = FMAdoptDeviceProfile(
            systemBuild, profileID, &operationError);
        NSDictionary *stage = adoption != nil
            ? FMStageDeviceProfileWithExistingLock(
                systemBuild, profileID, &operationError)
            : nil;
        if (adoption == nil || stage == nil) {
            FMPackageLifecycleFail(
                error, 8,
                @"The imported legacy Profile could not be staged.",
                operationError);
            return nil;
        }
        stageChanged = [stage[@"stateChanged"] boolValue] ||
            [stage[@"mirrorChanged"] boolValue];
    }

    if (!alreadyConfirmed) {
        NSDictionary *refresh =
            FMRefreshProviderForPreparedSystemFonts(&operationError);
        if (refresh == nil ||
            !FMProviderManagedMappingIsActive(&operationError) ||
            !FMConfirmWorkingProfileAtStatePath(
                jbroot(FMStateLogicalPath), &operationError)) {
            FMPackageLifecycleFail(
                error, 8,
                @"The imported legacy Profile could not replace the old mapping.",
                operationError);
            return nil;
        }
        providerInvoked = YES;
        mappingChanged = YES;
    }

    BOOL finalStatePresent = NO;
    NSDictionary *finalState = FMPackageReadState(
        systemBuild, &finalStatePresent, &operationError);
    BOOL finalReady = finalStatePresent && finalState != nil &&
        [finalState[@"mirrorState"] isEqual:@"clean"] &&
        [finalState[@"confirmedProfileID"] isEqual:profileID] &&
        [finalState[@"workingProfileID"] isEqual:profileID] &&
        ![finalState[@"restartRequired"] boolValue];
    if (!finalReady ||
        !FMCompleteLegacyFontTakeover(systemBuild, &operationError)) {
        FMPackageLifecycleFail(
            error, 8,
            @"The imported legacy Profile state could not be completed.",
            operationError);
        return nil;
    }
    return @{
        @"profileImported" : @YES,
        @"profileActivated" : @YES,
        @"profileID" : profileID,
        @"providerInvoked" : providerInvoked ? @YES : @NO,
        @"mappingChanged" : mappingChanged ? @YES : @NO,
        @"stateChanged" : stageChanged || !alreadyConfirmed ? @YES : @NO,
    };
}

static NSDictionary<NSString *, id> *_Nullable
FMPackageConfigureFreshInstallation(NSString *systemBuild, NSError **error) {
    NSError *operationError = nil;
    if (!FMPackageClaimEmptyInitialization(systemBuild, &operationError)) {
        FMPackageLifecycleFail(
            error, 6, @"The first installation could not claim its private state.",
            operationError);
        return nil;
    }

    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &operationError);
    if (lock < 0) {
        FMPackageLifecycleFail(error, 9,
                               @"Another MarkFont operation is still running.",
                               operationError);
        return nil;
    }

    NSDictionary<NSString *, id> *result = nil;
    NSString *failureDescription = nil;
    NSInteger failureCode = 6;
    do {
        NSDictionary *takeover =
            FMPerformLegacyFontTakeover(systemBuild, &operationError);
        if (takeover == nil) {
            failureDescription =
                @"An existing font mirror could not be preserved and detached safely.";
            break;
        }

        // The takeover has now proven that the exact mirror path is either
        // absent or already ours. Claim it before preparation so a crash after
        // publishing the new Stock mirror cannot make the next configure pass
        // preserve that new mirror as if it were legacy user data.
        if (!FMPackageEnsureMarker(FMMirrorOwnershipLogicalPath,
                                   @"markFontMirrorOwned", systemBuild,
                                   &operationError)) {
            failureDescription =
                @"The MarkFont mirror path could not be claimed safely.";
            break;
        }

        NSDictionary *environment = FMCreateEnvironmentStatus();
        BOOL mirrorPresent = [environment[@"fonts"][@"mirrorPresent"] boolValue];
        NSDictionary *preparation = nil;
        if (!mirrorPresent) {
            NSDictionary *preflight = FMCreateDeviceStockMirrorPreflight(
                systemBuild, &operationError);
            if (preflight == nil) {
                failureDescription =
                    @"The first-install Stock mirror preflight did not pass.";
                break;
            }
            preparation = FMPrepareDeviceStockMirror(systemBuild, &operationError);
            if (preparation == nil) {
                failureDescription =
                    @"The first-install Stock mirror could not be prepared safely.";
                break;
            }
        }

        NSDictionary *mountPreflight = FMCreateDevicePreparedStockMountPreflight(
            systemBuild, &operationError);
        NSDictionary *activation = mountPreflight != nil
            ? FMMountPreparedDeviceStock(systemBuild, &operationError)
            : nil;
        if (mountPreflight == nil || activation == nil) {
            failureCode = 7;
            failureDescription =
                @"The first-install Stock mapping could not be activated safely.";
            break;
        }

        NSDictionary *legacyActivation = FMPackageFinishLegacyProfileLocked(
            systemBuild, takeover, &operationError);
        if (legacyActivation == nil) {
            failureCode = 8;
            failureDescription =
                @"The installation-time legacy Profile could not be completed.";
            break;
        }

        BOOL legacyImported = [takeover[@"profileCreated"] boolValue];
        BOOL legacyAttempted = ![takeover[@"status"] isEqual:@"notNeeded"];
        result = @{
            @"schemaVersion" : @1,
            @"operation" : @"packageConfigure",
            @"status" : legacyImported
                ? @"initializedAfterLegacyImport" : @"initialized",
            @"systemBuild" : systemBuild,
            @"initializationAttempted" : @YES,
            @"existingStatePreserved" : @NO,
            @"legacyTakeoverAttempted" : legacyAttempted ? @YES : @NO,
            @"legacyProfileCreated" : legacyImported ? @YES : @NO,
            @"legacyProfileActivated" :
                legacyActivation[@"profileActivated"],
            @"legacyProfileID" : legacyActivation[@"profileID"],
            @"legacyReplacementCount" : takeover[@"replacementCount"],
            @"legacySourceRemoved" : takeover[@"legacySourceRemoved"],
            @"legacyContentCompared" : takeover[@"contentCompared"],
            @"mirrorPrepared" : preparation != nil ? @YES : @NO,
            @"providerInvoked" :
                [activation[@"providerInvoked"] boolValue] ||
                    [legacyActivation[@"providerInvoked"] boolValue] ||
                    [takeover[@"providerInvoked"] boolValue]
                ? @YES : @NO,
            @"filesystemMutated" : @YES,
            @"mappingChanged" :
                [activation[@"mappingChanged"] boolValue] ||
                    [legacyActivation[@"mappingChanged"] boolValue]
                ? @YES : @NO,
            @"stateChanged" : @YES,
            @"restartRequired" : @NO,
            @"restartRequested" : @NO,
        };
    } while (NO);

    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (result == nil || !released) {
        FMPackageLifecycleFail(
            error, result == nil ? failureCode : 9,
            result == nil ? (failureDescription ?: @"First installation failed.")
                          : @"The first-install operation lock could not be released.",
            operationError ?: releaseError);
        return nil;
    }
    return result;
}

static NSDictionary<NSString *, id> *FMPackageReportWithProviderAdjustment(
    NSDictionary<NSString *, id> *report,
    NSDictionary<NSString *, id> *adjustment) {
    if (report == nil || adjustment == nil) return report;
    NSMutableDictionary *result = [report mutableCopy];
    result[@"providerPreferencePresent"] = adjustment[@"preferencePresent"];
    result[@"providerFontsAutoMountChanged"] = adjustment[@"changed"];
    result[@"providerFontsAutoMountConflictedBefore"] =
        adjustment[@"conflictedBefore"];
    result[@"providerAutoMountEnabledAfter"] = adjustment[@"enabledAfter"];
    result[@"providerAutoMountRemainingPathCount"] =
        @([adjustment[@"remainingPaths"] count]);
    return result;
}

NSDictionary<NSString *, id> *FMConfigureInstalledDevicePackage(
    NSError **error) {
    if (!FMPackageRequireManagerRoot(error)) return nil;

    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSString *systemBuild = environment[@"system"][@"productBuildVersion"];
    if (!FMPackageSafeBuild(systemBuild)) {
        FMPackageLifecycleFail(error, 2,
                               @"The current system build is unavailable.", nil);
        return nil;
    }

    NSError *inspectionError = nil;
    NSDictionary *providerAdjustment =
        FMDisableProviderAutoMountForSystemFonts(&inspectionError);
    if (providerAdjustment == nil) {
        FMPackageLifecycleFail(
            error, 2,
            @"Provider automatic mounting for the system Fonts tree could not be disabled.",
            inspectionError);
        return nil;
    }

    BOOL statePresent = NO;
    NSDictionary *state = FMPackageReadState(
        systemBuild, &statePresent, &inspectionError);
    if (state == nil) {
        if (error != NULL) *error = inspectionError;
        return nil;
    }
    BOOL takeoverPending = NO;
    if (!FMPackageLegacyTakeoverJournalPresent(
            &takeoverPending, &inspectionError)) {
        if (error != NULL) *error = inspectionError;
        return nil;
    }
    if (statePresent && takeoverPending) {
        NSDictionary *targetFacts = FMPackageTargetFacts(&inspectionError);
        BOOL targetSupported = targetFacts != nil &&
            [targetFacts[@"disposition"] integerValue] !=
                FMFontTargetDispositionUnexpected;
        BOOL mirrorOwnershipPresent = NO;
        if (!targetSupported ||
            !FMPackageRequireSecureManagedMirror(&inspectionError) ||
            !FMPackageMarkerPresent(
                FMMirrorOwnershipLogicalPath, @"markFontMirrorOwned",
                systemBuild, &mirrorOwnershipPresent, &inspectionError) ||
            !mirrorOwnershipPresent) {
            FMPackageLifecycleFail(
                error, 4,
                @"An interrupted legacy import does not have its managed workspace.",
                inspectionError);
            return nil;
        }

        NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
        int lock = FMAcquireExclusiveDirectoryLock(
            engineRoot, 0, 0, &inspectionError);
        if (lock < 0) {
            FMPackageLifecycleFail(
                error, 9, @"Another MarkFont operation is still running.",
                inspectionError);
            return nil;
        }
        NSDictionary *takeover = FMPerformLegacyFontTakeover(
            systemBuild, &inspectionError);
        NSDictionary *legacyActivation = takeover != nil
            ? FMPackageFinishLegacyProfileLocked(
                systemBuild, takeover, &inspectionError)
            : nil;
        NSError *releaseError = nil;
        BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
        if (takeover == nil || legacyActivation == nil || !released) {
            FMPackageLifecycleFail(
                error, 8,
                @"The interrupted legacy Profile import could not be resumed.",
                inspectionError ?: releaseError);
            return nil;
        }
        return FMPackageReportWithProviderAdjustment(@{
            @"schemaVersion" : @1,
            @"operation" : @"packageConfigure",
            @"status" : @"legacyImportResumed",
            @"systemBuild" : systemBuild,
            @"initializationAttempted" : @YES,
            @"existingStatePreserved" : @YES,
            @"legacyTakeoverAttempted" : @YES,
            @"legacyProfileCreated" : takeover[@"profileCreated"],
            @"legacyProfileActivated" :
                legacyActivation[@"profileActivated"],
            @"legacyProfileID" : legacyActivation[@"profileID"],
            @"legacyReplacementCount" : takeover[@"replacementCount"],
            @"legacySourceRemoved" : takeover[@"legacySourceRemoved"],
            @"legacyContentCompared" : takeover[@"contentCompared"],
            @"providerInvoked" :
                [legacyActivation[@"providerInvoked"] boolValue] ||
                    [takeover[@"providerInvoked"] boolValue]
                ? @YES : @NO,
            @"filesystemMutated" : @YES,
            @"mappingChanged" : legacyActivation[@"mappingChanged"],
            @"stateChanged" : legacyActivation[@"stateChanged"],
            @"restartRequired" : @NO,
            @"restartRequested" : @NO,
        }, providerAdjustment);
    }
    if (statePresent) {
        NSDictionary *targetFacts = FMPackageTargetFacts(&inspectionError);
        if (targetFacts == nil ||
            [targetFacts[@"disposition"] integerValue] ==
                FMFontTargetDispositionUnexpected) {
            FMPackageLifecycleFail(
                error, 4, @"An unexpected mapping covers the system font target.",
                inspectionError);
            return nil;
        }
        BOOL mappingManaged =
            [targetFacts[@"disposition"] integerValue] ==
                FMFontTargetDispositionManaged;
        BOOL mirrorOwnershipPresent = NO;
        if (!FMPackageRequireSecureManagedMirror(&inspectionError) ||
            !FMPackageMarkerPresent(FMMirrorOwnershipLogicalPath,
                                    @"markFontMirrorOwned", systemBuild,
                                    &mirrorOwnershipPresent, &inspectionError) ||
            !FMPackageEnsureMarker(FMMirrorOwnershipLogicalPath,
                                   @"markFontMirrorOwned", systemBuild,
                                   &inspectionError)) {
            FMPackageLifecycleFail(
                error, 4, @"Existing managed mirror ownership could not be recorded.",
                inspectionError);
            return nil;
        }
        NSDictionary *autoMountReport = nil;
        if (!mappingManaged && [state[@"autoMount"] boolValue] &&
            [state[@"mirrorState"] isEqual:@"clean"] &&
            ![state[@"restartRequired"] boolValue]) {
            autoMountReport = FMAutomountManagedDeviceFonts(&inspectionError);
            if (autoMountReport == nil) {
                FMPackageLifecycleFail(
                    error, 5,
                    @"Existing managed state could not restore its font mapping.",
                    inspectionError);
                return nil;
            }
            mappingManaged = [autoMountReport[@"status"] isEqual:@"mounted"] ||
                [autoMountReport[@"status"] isEqual:@"alreadyMounted"];
        }
        return FMPackageReportWithProviderAdjustment(@{
            @"schemaVersion" : @1,
            @"operation" : @"packageConfigure",
            @"status" : mappingManaged ? @"alreadyConfigured"
                                        : @"existingStatePreserved",
            @"systemBuild" : systemBuild,
            @"initializationAttempted" : @NO,
            @"existingStatePreserved" : @YES,
            @"providerInvoked" : autoMountReport != nil
                ? autoMountReport[@"providerInvoked"] : @NO,
            @"filesystemMutated" : mirrorOwnershipPresent ? @NO : @YES,
            @"mappingChanged" : autoMountReport != nil
                ? autoMountReport[@"mappingChanged"] : @NO,
            @"stateChanged" : @NO,
            @"restartRequested" : @NO,
        }, providerAdjustment);
    }
    return FMPackageReportWithProviderAdjustment(
        FMPackageConfigureFreshInstallation(systemBuild, error),
        providerAdjustment);
}

static BOOL FMPackageRemovalInspectionIsExactStock(
    NSDictionary<NSString *, id> *inspection,
    NSString *systemBuild,
    BOOL statePresent) {
    NSDictionary *fonts = inspection[@"fonts"];
    NSDictionary *mapping = inspection[@"mapping"];
    NSDictionary *manifest = inspection[@"manifest"];
    NSDictionary *state = inspection[@"state"];
    BOOL stateExact = statePresent
        ? [state[@"present"] boolValue] && [state[@"valid"] boolValue] &&
          [state[@"systemBuild"] isEqual:systemBuild] &&
          [state[@"mirrorState"] isEqual:@"clean"] &&
          state[@"workingProfileID"] == NSNull.null
        : ![state[@"present"] boolValue];
    return [inspection[@"evidenceMode"] isEqual:@"deviceReadOnly"] &&
        [inspection[@"systemBuild"] isEqual:systemBuild] &&
        stateExact &&
        [fonts[@"mirrorKind"] isEqual:@"present"] &&
        [fonts[@"mirrorInsideJBRoot"] boolValue] &&
        [fonts[@"rootfsDistinctFromMirror"] boolValue] &&
        [mapping[@"active"] boolValue] &&
        [mapping[@"targetMatches"] boolValue] &&
        [mapping[@"sourceMatchesMirror"] boolValue] &&
        [mapping[@"readOnly"] boolValue] &&
        [mapping[@"filesystemType"] isEqual:@"bindfs"] &&
        [manifest[@"scanState"] isEqual:@"complete"] &&
        [manifest[@"stockEntryCount"] integerValue] > 0 &&
        [manifest[@"stockEntryCount"] isEqual:manifest[@"mirrorEntryCount"]] &&
        [manifest[@"changedPaths"] count] == 0 &&
        [manifest[@"missingPaths"] count] == 0 &&
        [manifest[@"unknownPaths"] count] == 0 &&
        [manifest[@"typeChangedPaths"] count] == 0 &&
        [manifest[@"matchesWorkingProfile"] boolValue];
}

static BOOL FMPackageVerifyExposedStock(NSString *systemBuild,
                                        NSError **error) {
    if (!FMPackageRequirePhysicalStockTarget(error)) return NO;
    NSString *baselinePath = [[jbroot(@"/var/lib/fontmanager/baseline")
        stringByAppendingPathComponent:systemBuild]
        stringByAppendingPathComponent:@"manifest.json"];
    NSError *manifestError = nil;
    id baseline = FMPackageRequireSecureRegularFile(baselinePath, &manifestError)
        ? FMReadJSONObjectAtPath(baselinePath, &manifestError)
        : nil;
    NSDictionary *exposed = FMCreateTreeManifestAtPath(
        FMProviderSystemFontsLogicalPath, &manifestError);
    if (![baseline isKindOfClass:NSDictionary.class] ||
        !FMValidateManifestDocument(baseline, &manifestError) ||
        exposed == nil || ![exposed isEqual:baseline]) {
        return FMPackageLifecycleFail(
            error, 8,
            @"The exposed system font tree does not match the saved Stock baseline.",
            manifestError);
    }
    return YES;
}

static NSDictionary<NSString *, id> *_Nullable FMPackageMarkInactiveRemovalReady(
    NSString *systemBuild,
    NSError **error) {
    NSError *markerError = nil;
    if (!FMPackageEnsureMarker(FMDisableMountLogicalPath,
                               @"packageRemovalInProgress", systemBuild,
                               &markerError)) {
        if (error != NULL) *error = markerError;
        return nil;
    }

    NSDictionary *targetFacts = FMPackageTargetFacts(&markerError);
    if (targetFacts == nil ||
        [targetFacts[@"disposition"] integerValue] !=
            FMFontTargetDispositionInactive ||
        !FMPackageRequirePhysicalStockTarget(&markerError)) {
        FMPackageLifecycleFail(
            error, 8,
            @"The system font target became active while removal was being prepared.",
            markerError);
        return nil;
    }
    if (!FMPackageEnsureMarker(FMRemovalReadyLogicalPath,
                               @"packageRemovalReady", systemBuild, error)) {
        return nil;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"packagePrepareRemoval",
        @"status" : @"ready",
        @"systemBuild" : systemBuild,
        @"engineDataOwned" : @YES,
        @"stockRestored" : @YES,
        @"mappingWasActive" : @NO,
        @"mappingChanged" : @NO,
        @"unmountAttempted" : @NO,
        @"unmountMethod" : @"notRequired",
        @"providerDetachMayForce" : @NO,
        @"providerInvoked" : @NO,
        @"cleanupAuthorized" : @YES,
        @"filesystemMutated" : @YES,
        @"stateChanged" : @NO,
        @"restartRequested" : @NO,
    };
}

static NSDictionary<NSString *, id> *FMPackageExternalDataPreserved(
    NSString *systemBuild,
    BOOL mappingActive) {
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"packagePrepareRemoval",
        @"status" : @"externalDataPreserved",
        @"systemBuild" : systemBuild,
        @"engineDataOwned" : @NO,
        @"stockRestored" : mappingActive ? @NO : @YES,
        @"mappingWasActive" : mappingActive ? @YES : @NO,
        @"mappingChanged" : @NO,
        @"unmountAttempted" : @NO,
        @"unmountMethod" : @"notRequired",
        @"providerDetachMayForce" : @NO,
        @"providerInvoked" : @NO,
        @"cleanupAuthorized" : @NO,
        @"filesystemMutated" : @NO,
        @"stateChanged" : @NO,
        @"restartRequested" : @NO,
    };
}

static NSDictionary<NSString *, id> *_Nullable
FMPackageMarkExternalRemovalReady(NSString *systemBuild,
                                  NSError **error) {
    NSError *markerError = nil;
    if (!FMPackageEnsureMarker(FMDisableMountLogicalPath,
                               @"packageRemovalInProgress", systemBuild,
                               &markerError) ||
        !FMPackageEnsureMarker(FMRemovalReadyLogicalPath,
                               @"packageRemovalReadyEngineOnly", systemBuild,
                               &markerError)) {
        if (error != NULL) *error = markerError;
        return nil;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"packagePrepareRemoval",
        @"status" : @"externalDataPreserved",
        @"systemBuild" : systemBuild,
        @"engineDataOwned" : @YES,
        @"mirrorDataOwned" : @NO,
        @"stockRestored" : @NO,
        @"mappingWasActive" : @NO,
        @"mappingChanged" : @NO,
        @"unmountAttempted" : @NO,
        @"unmountMethod" : @"notRequired",
        @"providerDetachMayForce" : @NO,
        @"providerInvoked" : @NO,
        @"cleanupAuthorized" : @YES,
        @"filesystemMutated" : @YES,
        @"stateChanged" : @NO,
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMPrepareDevicePackageRemoval(
    NSError **error) {
    if (!FMPackageRequireManagerRoot(error)) return nil;

    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSString *systemBuild = environment[@"system"][@"productBuildVersion"];
    if (!FMPackageSafeBuild(systemBuild)) {
        FMPackageLifecycleFail(error, 2,
                               @"The current system build is unavailable.", nil);
        return nil;
    }

    NSError *operationError = nil;
    BOOL engineRootPresent = NO;
    if (!FMPackageEngineRootPresent(&engineRootPresent, &operationError)) {
        if (error != NULL) *error = operationError;
        return nil;
    }
    BOOL engineOwned = NO;
    if (engineRootPresent &&
        (!FMPackageMarkerPresent(
             FMOwnershipLogicalPath, @"packageOwned", systemBuild,
             &engineOwned, &operationError) || !engineOwned)) {
        FMPackageLifecycleFail(
            error, 3,
            @"Removal stopped because the engine root is not owned by this MarkFont installation.",
            operationError);
        return nil;
    }
    NSDictionary *providerAdjustment = nil;
    if (engineOwned) {
        BOOL mirrorOwned = NO;
        if (!FMPackageMarkerPresent(FMMirrorOwnershipLogicalPath,
                                    @"markFontMirrorOwned", systemBuild,
                                    &mirrorOwned, &operationError)) {
            if (error != NULL) *error = operationError;
            return nil;
        }
        if (!mirrorOwned) {
            return FMPackageMarkExternalRemovalReady(systemBuild, error);
        }
    }
    NSDictionary *targetFacts = FMPackageTargetFacts(&operationError);
    if (targetFacts == nil) {
        if (!engineOwned) {
            return FMPackageExternalDataPreserved(systemBuild, YES);
        }
        if (!FMPackageEnsureMarker(
                FMDisableMountLogicalPath, @"packageRemovalInProgress",
                systemBuild, &operationError)) {
            if (error != NULL) *error = operationError;
            return nil;
        }
        FMPackageLifecycleFail(
            error, 4,
            @"Removal was refused because the font target could not be inspected; automatic mounting is now disabled.",
            operationError);
        return nil;
    }
    FMFontTargetDisposition targetDisposition =
        [targetFacts[@"disposition"] integerValue];
    if (!engineOwned) {
        return FMPackageExternalDataPreserved(
            systemBuild, targetDisposition != FMFontTargetDispositionInactive);
    }
    if (!FMPackageEnsureMarker(FMDisableMountLogicalPath,
                               @"packageRemovalInProgress", systemBuild,
                               &operationError)) {
        if (error != NULL) *error = operationError;
        return nil;
    }
    providerAdjustment =
        FMDisableProviderAutoMountForSystemFonts(&operationError);
    if (providerAdjustment == nil) {
        FMPackageLifecycleFail(
            error, 3,
            @"Provider automatic mounting for Fonts could not be disabled before removal.",
            operationError);
        return nil;
    }
    if (targetDisposition == FMFontTargetDispositionUnexpected) {
        FMPackageLifecycleFail(
            error, 4,
            @"Removal was refused because an unexpected mapping covers the font target; automatic mounting is now disabled.",
            nil);
        return nil;
    }
    if (targetDisposition == FMFontTargetDispositionInactive) {
        return FMPackageReportWithProviderAdjustment(
            FMPackageMarkInactiveRemovalReady(systemBuild, error),
            providerAdjustment);
    }

    BOOL statePresent = NO;
    NSDictionary *state = FMPackageReadState(
        systemBuild, &statePresent, &operationError);
    if (state == nil) {
        FMPackageLifecycleFail(
            error, 5,
            @"Managed state is not safe to restore. Reboot, re-jailbreak, and retry removal; automatic mounting is now disabled.",
            operationError);
        return nil;
    }
    BOOL stockStagePerformed = NO;
    BOOL stateChanged = NO;
    if (statePresent) {
        BOOL workingStock = state[@"workingProfileID"] == NSNull.null;
        if (![state[@"mirrorState"] isEqual:@"clean"] ||
            (!workingStock && [state[@"restartRequired"] boolValue])) {
            FMPackageLifecycleFail(
                error, 5,
                @"Finish the pending font operation or reboot and retry removal; automatic mounting is now disabled.",
                nil);
            return nil;
        }
        if (!workingStock) {
            NSDictionary *stage = FMStageDeviceProfile(
                systemBuild, nil, &operationError);
            if (stage == nil) {
                FMPackageLifecycleFail(
                    error, 5,
                    @"Stock fonts could not be restored before removal. Reboot and retry; automatic mounting is now disabled.",
                    operationError);
                return nil;
            }
            stockStagePerformed = YES;
            stateChanged = [stage[@"stateChanged"] boolValue];
        }
    }

    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    int lock = FMAcquireExclusiveDirectoryLock(
        engineRoot, 0, 0, &operationError);
    if (lock < 0) {
        FMPackageLifecycleFail(
            error, 6, @"Another Font Manager operation is still running.",
            operationError);
        return nil;
    }

    NSDictionary *inspection = FMCreateDeviceProviderInspection(&operationError);
    BOOL exactStock = inspection != nil &&
        FMPackageRemovalInspectionIsExactStock(
            inspection, systemBuild, statePresent);
    if (!exactStock) {
        FMReleaseExclusiveDirectoryLock(lock, NULL);
        FMPackageLifecycleFail(
            error, 6,
            @"The managed mirror is not exact Stock, so removal cannot detach it safely.",
            operationError);
        return nil;
    }

    NSDictionary *providerDetachment =
        FMDetachProviderSystemFontsForPackageLifecycle(&operationError);
    if (providerDetachment == nil) {
        FMReleaseExclusiveDirectoryLock(lock, NULL);
        FMPackageLifecycleFail(
            error, 7,
            @"The verified Provider could not detach the Stock font mapping for removal.",
            operationError);
        return nil;
    }

    NSDictionary *postFacts = FMPackageTargetFacts(&operationError);
    BOOL postInactive = postFacts != nil &&
        [postFacts[@"disposition"] integerValue] ==
            FMFontTargetDispositionInactive;
    BOOL exposedStock = postInactive &&
        FMPackageVerifyExposedStock(systemBuild, &operationError);
    BOOL markerReady = exposedStock &&
        FMPackageEnsureMarker(FMRemovalReadyLogicalPath,
                              @"packageRemovalReady", systemBuild,
                              &operationError);
    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (!markerReady || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }

    return FMPackageReportWithProviderAdjustment(@{
        @"schemaVersion" : @1,
        @"operation" : @"packagePrepareRemoval",
        @"status" : @"ready",
        @"systemBuild" : systemBuild,
        @"engineDataOwned" : @YES,
        @"stockRestored" : @YES,
        @"mappingWasActive" : @YES,
        @"mappingChanged" : @YES,
        @"stockStagePerformed" : stockStagePerformed ? @YES : @NO,
        @"unmountAttempted" : @YES,
        @"unmountMethod" : @"providerFixedUnmount",
        @"providerDetachMayForce" :
            providerDetachment[@"providerDetachMayForce"],
        @"providerInvoked" : @YES,
        @"providerDetachReportedSuccess" :
            providerDetachment[@"reportedSuccess"],
        @"cleanupAuthorized" : @YES,
        @"filesystemMutated" : @YES,
        @"stateChanged" : stateChanged ? @YES : @NO,
        @"restartRequested" : @NO,
    }, providerAdjustment);
}
