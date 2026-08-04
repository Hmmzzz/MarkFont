#import "FMProfileEngine.h"

#import <errno.h>
#import <limits.h>
#import <stdlib.h>
#import <sys/stat.h>

#import "FMDataModel.h"
#import "FMFileStore.h"

NSString *const FMProfileEngineErrorDomain = @"com.hmmzzz.fontmanager.profileengine";
NSInteger const FMProfileEngineNoFaultInjection = -1;

static NSError *FMProfileEngineError(FMProfileEngineErrorCode code,
                                     NSString *message,
                                     NSError *underlying) {
    NSMutableDictionary *userInfo =
        [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:FMProfileEngineErrorDomain code:code userInfo:userInfo];
}

static BOOL FMProfileEngineFail(NSError **error,
                                FMProfileEngineErrorCode code,
                                NSString *message,
                                NSError *underlying) {
    if (error != NULL) {
        *error = FMProfileEngineError(code, message, underlying);
    }
    return NO;
}

NSDictionary<NSString *, id> *FMCreateInitialState(NSString *systemBuild) {
    return @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"systemBuild" : systemBuild,
        @"confirmedProfileID" : NSNull.null,
        @"workingProfileID" : NSNull.null,
        @"restartRequired" : @NO,
        @"refreshReason" : NSNull.null,
        @"mirrorState" : @"clean",
        @"autoMount" : @YES,
        @"autoRespring" : @NO,
    };
}

BOOL FMConfirmWorkingProfileAtStatePath(NSString *statePath, NSError **error) {
    NSError *readError = nil;
    id stateObject = FMReadJSONObjectAtPath(statePath, &readError);
    NSError *validationError = nil;
    if (stateObject == nil || !FMValidateStateDocument(stateObject, &validationError)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidState,
                                   @"Persistent state is unavailable or invalid.",
                                   validationError ?: readError);
    }

    NSDictionary<NSString *, id> *state = stateObject;
    if (![state[@"mirrorState"] isEqual:@"clean"]) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidTransition,
                                   @"Profile confirmation requires mirrorState=clean.", nil);
    }

    NSMutableDictionary<NSString *, id> *confirmedState = [state mutableCopy];
    confirmedState[@"confirmedProfileID"] = state[@"workingProfileID"];
    confirmedState[@"restartRequired"] = @NO;
    confirmedState[@"refreshReason"] = NSNull.null;
    NSError *writeError = nil;
    if (!FMWriteJSONObjectAtomically(confirmedState, statePath, 0600, &writeError)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorCommitFailed,
                                   @"Unable to persist confirmed Profile state.", writeError);
    }
    return YES;
}

static NSString *FMCanonicalDirectory(NSString *path,
                                      NSString *purpose,
                                      NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) {
        int savedError = errno != 0 ? errno : ENOTDIR;
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil];
        FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                            [NSString stringWithFormat:@"%@ must be an existing directory: %@",
                                                       purpose, path],
                            underlying);
        return nil;
    }

    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved) == NULL) {
        int savedError = errno;
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil];
        FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                            [NSString stringWithFormat:@"Unable to resolve %@: %@", purpose, path],
                            underlying);
        return nil;
    }
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved
                                                                      length:strlen(resolved)];
}

static BOOL FMPathIsInsideRoot(NSString *path, NSString *root) {
    if ([path isEqualToString:root]) {
        return YES;
    }
    NSString *prefix = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static BOOL FMValidateRegularFile(NSString *path, NSString *purpose, NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        int savedError = errno;
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil];
        return FMProfileEngineFail(error, FMProfileEngineErrorPreflightFailed,
                                   [NSString stringWithFormat:@"%@ is unavailable: %@", purpose,
                                                              path],
                                   underlying);
    }
    if (!S_ISREG(info.st_mode)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorPreflightFailed,
                                   [NSString stringWithFormat:@"%@ is not a regular file: %@",
                                                              purpose, path],
                                   nil);
    }
    return YES;
}

static BOOL FMProfileIDsEqual(id left, id right) {
    BOOL leftIsStock = left == nil || left == NSNull.null;
    BOOL rightIsStock = right == nil || right == NSNull.null;
    if (leftIsStock || rightIsStock) {
        return leftIsStock && rightIsStock;
    }
    return [left isEqual:right];
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
FMReplacementMap(NSDictionary<NSString *, id> *profile) {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *result =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *replacement in profile[@"replacements"]) {
        result[replacement[@"relativePath"]] = replacement;
    }
    return result;
}

static NSArray<NSString *> *FMValidatedManagedPaths(NSArray<NSString *> *paths,
                                                     NSError **error) {
    if (![paths isKindOfClass:NSArray.class]) {
        FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                            @"Managed paths must be an array.", nil);
        return nil;
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSString *> *validated = [NSMutableArray arrayWithCapacity:paths.count];
    for (id object in paths) {
        NSError *pathError = nil;
        if (![object isKindOfClass:NSString.class] ||
            !FMValidateRelativePath(object, &pathError)) {
            FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                                @"Managed path is invalid.", pathError);
            return nil;
        }
        NSString *path = object;
        if ([seen containsObject:path]) {
            FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                                @"Managed paths contain a duplicate.", nil);
            return nil;
        }
        [seen addObject:path];
        [validated addObject:path];
    }
    [validated sortUsingSelector:@selector(compare:)];
    return validated;
}

BOOL FMMarkProfileRepairRequiredAtStatePath(
    NSString *statePath,
    NSArray<NSString *> *managedRelativePaths,
    NSError **error) {
    NSError *validationError = nil;
    NSArray<NSString *> *managedPaths =
        FMValidatedManagedPaths(managedRelativePaths, &validationError);
    if (managedPaths == nil) {
        if (error != NULL) *error = validationError;
        return NO;
    }
    NSError *readError = nil;
    id stateObject = FMReadJSONObjectAtPath(statePath, &readError);
    if (stateObject == nil || !FMValidateStateDocument(stateObject, &validationError)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidState,
                                   @"Persistent state is unavailable or invalid.",
                                   validationError ?: readError);
    }
    NSMutableDictionary<NSString *, id> *repairState = [stateObject mutableCopy];
    repairState[@"mirrorState"] = @"repairRequired";
    repairState[@"restartRequired"] = @NO;
    repairState[@"refreshReason"] = NSNull.null;
    repairState[@"transitionManagedPaths"] = managedPaths;
    NSError *writeError = nil;
    if (!FMWriteJSONObjectAtomically(repairState, statePath, 0600, &writeError)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorCommitFailed,
                                   @"Unable to persist repair-required state.", writeError);
    }
    return YES;
}

static BOOL FMMarkRepairRequired(NSMutableDictionary<NSString *, id> *transitionState,
                                 NSString *statePath,
                                 NSError *operationError,
                                 NSError **error) {
    transitionState[@"mirrorState"] = @"repairRequired";
    transitionState[@"restartRequired"] = @NO;
    transitionState[@"refreshReason"] = NSNull.null;
    NSError *stateError = nil;
    if (!FMWriteJSONObjectAtomically(transitionState, statePath, 0600, &stateError)) {
        NSString *message = [NSString
            stringWithFormat:@"%@ State also could not be marked repairRequired: %@",
                             operationError.localizedDescription,
                             stateError.localizedDescription];
        return FMProfileEngineFail(error, FMProfileEngineErrorCommitFailed, message,
                                   operationError);
    }
    if (error != NULL) {
        *error = operationError;
    }
    return NO;
}

static BOOL FMConvergeProfile(BOOL isRepair,
                              NSString *stockRoot,
                              NSString *mirrorRoot,
                              NSDictionary<NSString *, id> *profileDocument,
                              NSString *profileDirectory,
                              NSArray<NSString *> *stockRestoreRelativePaths,
                              NSString *statePath,
                              NSInteger faultAfterCommittedFiles,
                              NSError **error) {
    if (faultAfterCommittedFiles < FMProfileEngineNoFaultInjection) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                                   @"Fault injection value is invalid.", nil);
    }
    BOOL wantsStock = profileDocument == nil;
    if (wantsStock != (profileDirectory == nil)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                                   @"Profile document and directory must be supplied together.", nil);
    }

    NSError *validationError = nil;
    if (!wantsStock && !FMValidateProfileDocument(profileDocument, &validationError)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                                   @"Profile document is invalid.", validationError);
    }
    NSArray<NSString *> *stockRestorePaths =
        FMValidatedManagedPaths(stockRestoreRelativePaths, &validationError);
    if (stockRestorePaths == nil) {
        if (error != NULL) {
            *error = validationError;
        }
        return NO;
    }

    NSError *readError = nil;
    id stateObject = FMReadJSONObjectAtPath(statePath, &readError);
    if (stateObject == nil || !FMValidateStateDocument(stateObject, &validationError)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidState,
                                   @"Persistent state is unavailable or invalid.",
                                   validationError ?: readError);
    }
    NSDictionary<NSString *, id> *state = stateObject;
    NSString *systemBuild = state[@"systemBuild"];
    if (!wantsStock && ![profileDocument[@"systemBuild"] isEqual:systemBuild]) {
        return FMProfileEngineFail(error, FMProfileEngineErrorBuildMismatch,
                                   @"Profile system build does not match persistent state.", nil);
    }

    NSString *mirrorState = state[@"mirrorState"];
    id targetProfileID = wantsStock ? NSNull.null : profileDocument[@"id"];
    if (!isRepair && ![mirrorState isEqual:@"clean"]) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidTransition,
                                   @"A normal stage requires mirrorState=clean.", nil);
    }
    if (isRepair && ![mirrorState isEqual:@"updating"] &&
        ![mirrorState isEqual:@"repairRequired"]) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidTransition,
                                   @"Repair requires updating or repairRequired state.", nil);
    }
    if (isRepair && !FMProfileIDsEqual(state[@"workingProfileID"], targetProfileID)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidTransition,
                                   @"Repair Profile does not match the target stored in state.", nil);
    }
    NSString *canonicalStock = FMCanonicalDirectory(stockRoot, @"Stock root", &validationError);
    NSString *canonicalMirror = FMCanonicalDirectory(mirrorRoot, @"mirror root", &validationError);
    if (canonicalStock == nil || canonicalMirror == nil) {
        if (error != NULL) {
            *error = validationError;
        }
        return NO;
    }
    if ([canonicalStock isEqualToString:canonicalMirror]) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidInput,
                                   @"Stock and mirror roots must be different directories.", nil);
    }

    NSString *canonicalReplacements = nil;
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *replacementMap = @{};
    if (!wantsStock) {
        NSString *canonicalProfile =
            FMCanonicalDirectory(profileDirectory, @"Profile directory", &validationError);
        if (canonicalProfile == nil) {
            if (error != NULL) {
                *error = validationError;
            }
            return NO;
        }
        NSString *replacementDirectory =
            [canonicalProfile stringByAppendingPathComponent:@"replacements"];
        canonicalReplacements =
            FMCanonicalDirectory(replacementDirectory, @"Profile replacements", &validationError);
        if (canonicalReplacements == nil) {
            if (error != NULL) {
                *error = validationError;
            }
            return NO;
        }
        replacementMap = FMReplacementMap(profileDocument);
    }

    NSArray<NSString *> *applyPaths =
        [replacementMap.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableSet<NSString *> *managedSet =
        [NSMutableSet setWithArray:stockRestorePaths];
    [managedSet addObjectsFromArray:applyPaths];
    NSArray<NSString *> *managedPaths =
        [managedSet.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (isRepair && ![state[@"transitionManagedPaths"] isEqual:managedPaths]) {
        return FMProfileEngineFail(error, FMProfileEngineErrorInvalidTransition,
                                   @"Repair paths do not match the persisted transition.", nil);
    }

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *plan =
        [NSMutableArray arrayWithCapacity:stockRestorePaths.count + applyPaths.count];
    NSArray<NSDictionary<NSString *, id> *> *phases = @[
        @{
            @"name" : @"restoreStock",
            @"paths" : stockRestorePaths,
        },
        @{
            @"name" : @"applyProfile",
            @"paths" : applyPaths,
        },
    ];
    for (NSDictionary<NSString *, id> *phase in phases) {
        for (NSString *relativePath in phase[@"paths"]) {
            NSDictionary<NSString *, id> *replacement =
                [phase[@"name"] isEqual:@"applyProfile"]
                    ? replacementMap[relativePath]
                    : nil;
            NSString *stockPath = [canonicalStock stringByAppendingPathComponent:relativePath];
            NSString *targetPath = [canonicalMirror stringByAppendingPathComponent:relativePath];
            NSString *sourcePath = stockPath;
            NSString *expectedHash = nil;
            if (replacement != nil) {
                sourcePath = [canonicalReplacements
                    stringByAppendingPathComponent:replacement[@"fileName"]];
                expectedHash = replacement[@"sha256"];
            }

            NSString *targetParent = targetPath.stringByDeletingLastPathComponent;
            NSString *canonicalTargetParent =
                FMCanonicalDirectory(targetParent, @"mirror target parent", &validationError);
            if (canonicalTargetParent == nil ||
                !FMPathIsInsideRoot(canonicalTargetParent, canonicalMirror)) {
                return FMProfileEngineFail(error, FMProfileEngineErrorPreflightFailed,
                                           @"Mirror target parent escapes the mirror root.",
                                           validationError);
            }
            if (!FMValidateRegularFile(stockPath, @"Stock metadata source", &validationError) ||
                !FMValidateRegularFile(sourcePath, @"desired source", &validationError) ||
                !FMValidateRegularFile(targetPath, @"mirror target", &validationError)) {
                if (error != NULL) {
                    *error = validationError;
                }
                return NO;
            }

            NSError *hashError = nil;
            NSString *actualHash = FMSHA256ForFileAtPath(sourcePath, &hashError);
            if (actualHash == nil) {
                return FMProfileEngineFail(error, FMProfileEngineErrorPreflightFailed,
                                           @"Unable to hash a desired source.", hashError);
            }
            if (expectedHash != nil && ![actualHash isEqualToString:expectedHash]) {
                return FMProfileEngineFail(
                    error, FMProfileEngineErrorPreflightFailed,
                    @"Profile replacement SHA-256 does not match profile.json.", nil);
            }
            [plan addObject:@{
                @"source" : sourcePath,
                @"metadata" : stockPath,
                @"target" : targetPath,
                @"sha256" : actualHash,
                @"relativePath" : relativePath,
            }];
        }
    }

    NSMutableDictionary<NSString *, id> *transitionState = [state mutableCopy];
    transitionState[@"workingProfileID"] = targetProfileID;
    transitionState[@"restartRequired"] = @NO;
    transitionState[@"refreshReason"] = NSNull.null;
    transitionState[@"mirrorState"] = @"updating";
    transitionState[@"transitionManagedPaths"] = managedPaths;
    NSError *stateError = nil;
    if (!FMWriteJSONObjectAtomically(transitionState, statePath, 0600, &stateError)) {
        return FMProfileEngineFail(error, FMProfileEngineErrorCommitFailed,
                                   @"Unable to persist the updating state.", stateError);
    }

    if (faultAfterCommittedFiles == 0) {
        NSError *injected = FMProfileEngineError(FMProfileEngineErrorInjectedFailure,
                                                  @"Injected failure before the first file commit.",
                                                  nil);
        return FMMarkRepairRequired(transitionState, statePath, injected, error);
    }

    NSInteger committedFiles = 0;
    for (NSDictionary<NSString *, NSString *> *item in plan) {
        NSError *copyError = nil;
        if (!FMCopyRegularFileAtomically(
                item[@"source"], item[@"metadata"], item[@"target"],
                item[@"sha256"], &copyError)) {
            NSError *commitError = FMProfileEngineError(
                FMProfileEngineErrorCommitFailed,
                [NSString stringWithFormat:@"Failed to commit managed path %@.",
                                           item[@"relativePath"]],
                copyError);
            return FMMarkRepairRequired(transitionState, statePath, commitError, error);
        }
        committedFiles++;
        if (faultAfterCommittedFiles >= 0 && committedFiles == faultAfterCommittedFiles) {
            NSError *injected = FMProfileEngineError(
                FMProfileEngineErrorInjectedFailure,
                [NSString stringWithFormat:@"Injected failure after %ld file commit(s).",
                                           (long)committedFiles],
                nil);
            return FMMarkRepairRequired(transitionState, statePath, injected, error);
        }
    }

    NSMutableDictionary<NSString *, id> *cleanState = [transitionState mutableCopy];
    cleanState[@"mirrorState"] = @"clean";
    cleanState[@"restartRequired"] =
        FMProfileIDsEqual(cleanState[@"confirmedProfileID"], targetProfileID) ? @NO : @YES;
    cleanState[@"refreshReason"] = [cleanState[@"restartRequired"] boolValue]
        ? @"profileChange" : NSNull.null;
    [cleanState removeObjectForKey:@"transitionManagedPaths"];
    if (!FMWriteJSONObjectAtomically(cleanState, statePath, 0600, &stateError)) {
        NSError *commitError = FMProfileEngineError(FMProfileEngineErrorCommitFailed,
                                                     @"Files converged but clean state could not be persisted.",
                                                     stateError);
        return FMMarkRepairRequired(transitionState, statePath, commitError, error);
    }
    return YES;
}

BOOL FMStageProfileAtRoots(NSString *stockRoot,
                           NSString *mirrorRoot,
                           NSDictionary<NSString *, id> *profileDocument,
                           NSString *profileDirectory,
                           NSArray<NSString *> *stockRestoreRelativePaths,
                           NSString *statePath,
                           NSInteger faultAfterCommittedFiles,
                           NSError **error) {
    return FMConvergeProfile(NO, stockRoot, mirrorRoot, profileDocument, profileDirectory,
                             stockRestoreRelativePaths, statePath,
                             faultAfterCommittedFiles, error);
}

BOOL FMRepairProfileAtRoots(NSString *stockRoot,
                            NSString *mirrorRoot,
                            NSDictionary<NSString *, id> *profileDocument,
                            NSString *profileDirectory,
                            NSArray<NSString *> *stockRestoreRelativePaths,
                            NSString *statePath,
                            NSInteger faultAfterCommittedFiles,
                            NSError **error) {
    return FMConvergeProfile(YES, stockRoot, mirrorRoot, profileDocument, profileDirectory,
                             stockRestoreRelativePaths, statePath,
                             faultAfterCommittedFiles, error);
}
