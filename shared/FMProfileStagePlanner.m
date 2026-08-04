#import "FMProfileStagePlanner.h"

#import <errno.h>
#import <limits.h>
#import <sys/stat.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMProfileAdoptionValidator.h"

NSString *const FMProfileStagePlannerErrorDomain =
    @"com.hmmzzz.fontmanager.profile-stage-planner";

static BOOL FMStagePlanFail(NSError **error,
                            FMProfileStagePlannerErrorCode code,
                            NSString *description,
                            NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMProfileStagePlannerErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSDictionary<NSString *, id> *FMStagePlanPreview(
    NSString *profilesRoot,
    id profileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    if (profileID == nil || profileID == NSNull.null) return nil;
    if (![profileID isKindOfClass:NSString.class]) {
        FMStagePlanFail(error, FMProfileStagePlannerErrorInvalidProfile,
                        @"A working Profile identifier is invalid.", nil);
        return nil;
    }
    NSError *previewError = nil;
    NSDictionary *preview = FMCreateProfileAdoptionPreviewAtRoot(
        profilesRoot, profileID, systemBuild, catalog, &previewError);
    if (preview == nil) {
        FMStagePlanFail(error, FMProfileStagePlannerErrorInvalidProfile,
                        @"A privileged Profile is unavailable or invalid.", previewError);
    }
    return preview;
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *FMStagePlanTargetsByPath(
    NSDictionary<NSString *, id> *preview) {
    if (preview == nil) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSDictionary *target in preview[@"targets"]) {
        result[target[@"relativePath"]] = target;
    }
    return result;
}

static BOOL FMStagePlanRequireDirectory(NSString *path,
                                        NSString *purpose,
                                        NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)) {
        return YES;
    }
    NSError *underlying = errno != 0
        ? [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]
        : nil;
    return FMStagePlanFail(
        error, FMProfileStagePlannerErrorInvalidInput,
        [NSString stringWithFormat:@"%@ is not an ordinary directory.", purpose],
        underlying);
}

static BOOL FMStagePlanProfileIDsEqual(id left, id right) {
    BOOL leftIsStock = left == nil || left == NSNull.null;
    BOOL rightIsStock = right == nil || right == NSNull.null;
    if (leftIsStock || rightIsStock) return leftIsStock && rightIsStock;
    return [left isEqual:right];
}

NSDictionary<NSString *, id> *FMCreateProfileStagePlanAtRoots(
    NSString *stockRoot,
    NSString *mirrorRoot,
    NSString *profilesRoot,
    NSString *targetProfileID,
    NSString *statePath,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    NSError *validationError = nil;
    if (stockRoot.length == 0 || mirrorRoot.length == 0 || profilesRoot.length == 0 ||
        statePath.length == 0 || systemBuild.length == 0 ||
        [stockRoot isEqual:mirrorRoot] ||
        !FMValidateFontCatalogDocument(catalog, &validationError) ||
        ![catalog[@"systemBuild"] isEqual:systemBuild] ||
        !FMStagePlanRequireDirectory(stockRoot, @"Stock root", &validationError) ||
        !FMStagePlanRequireDirectory(mirrorRoot, @"mirror root", &validationError) ||
        !FMStagePlanRequireDirectory(profilesRoot, @"privileged Profile root",
                                     &validationError)) {
        if (error != NULL) {
            *error = validationError ?: [NSError errorWithDomain:FMProfileStagePlannerErrorDomain
                                                              code:FMProfileStagePlannerErrorInvalidInput
                                                          userInfo:@{
                NSLocalizedDescriptionKey : @"Profile stage plan inputs are invalid."
            }];
        }
        return nil;
    }

    NSError *stateError = nil;
    id stateObject = FMReadJSONObjectAtPath(statePath, &stateError);
    if (![stateObject isKindOfClass:NSDictionary.class] ||
        !FMValidateStateDocument(stateObject, &validationError)) {
        FMStagePlanFail(error, FMProfileStagePlannerErrorInvalidState,
                        @"Persistent state is unavailable or invalid.",
                        validationError ?: stateError);
        return nil;
    }
    NSDictionary<NSString *, id> *state = stateObject;
    if (![state[@"systemBuild"] isEqual:systemBuild] ||
        ![state[@"mirrorState"] isEqual:@"clean"]) {
        FMStagePlanFail(error, FMProfileStagePlannerErrorInvalidState,
                        @"A stage plan requires clean state for the current build.", nil);
        return nil;
    }

    id currentProfileID = state[@"workingProfileID"];
    NSDictionary *currentPreview = FMStagePlanPreview(
        profilesRoot, currentProfileID, systemBuild, catalog, NULL);
    BOOL fullStockFallback = currentProfileID != NSNull.null &&
        currentPreview == nil;
    NSDictionary *targetPreview = FMStagePlanPreview(
        profilesRoot, targetProfileID, systemBuild, catalog, &validationError);
    if (targetProfileID != nil && targetPreview == nil) {
        if (error != NULL) *error = validationError;
        return nil;
    }

    NSDictionary *currentTargets = FMStagePlanTargetsByPath(currentPreview);
    NSDictionary *targetTargets = FMStagePlanTargetsByPath(targetPreview);

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *catalogByPath =
        [NSMutableDictionary dictionary];
    for (NSDictionary *file in catalog[@"files"]) {
        catalogByPath[file[@"relativePath"]] = file;
    }

    id normalizedTargetID = targetProfileID ?: NSNull.null;
    BOOL sameSelection = FMStagePlanProfileIDsEqual(
        currentProfileID, normalizedTargetID);
    NSArray<NSString *> *stockRestorePaths = sameSelection
        ? @[]
        : fullStockFallback
            ? [catalogByPath.allKeys sortedArrayUsingSelector:@selector(compare:)]
            : [currentTargets.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSString *> *applyPaths = sameSelection
        ? @[]
        : [targetTargets.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableSet<NSString *> *managedSet =
        [NSMutableSet setWithArray:stockRestorePaths];
    [managedSet addObjectsFromArray:applyPaths];
    NSArray<NSString *> *managedPaths =
        [managedSet.allObjects sortedArrayUsingSelector:@selector(compare:)];

    NSMutableArray<NSDictionary<NSString *, id> *> *actions = [NSMutableArray array];
    unsigned long long writeBytes = 0;
    for (NSString *relativePath in managedPaths) {
        NSDictionary *catalogFile = catalogByPath[relativePath];
        if (catalogFile == nil) {
            FMStagePlanFail(error, FMProfileStagePlannerErrorInvalidProfile,
                            @"A managed path is missing from the current catalog.", nil);
            return nil;
        }

        NSString *stockPath = [stockRoot stringByAppendingPathComponent:relativePath];
        NSString *mirrorPath = [mirrorRoot stringByAppendingPathComponent:relativePath];
        struct stat stockInfo = {0};
        struct stat mirrorInfo = {0};
        if (lstat(stockPath.fileSystemRepresentation, &stockInfo) != 0 ||
            lstat(mirrorPath.fileSystemRepresentation, &mirrorInfo) != 0 ||
            !S_ISREG(stockInfo.st_mode) || !S_ISREG(mirrorInfo.st_mode)) {
            FMStagePlanFail(error, FMProfileStagePlannerErrorMirrorMismatch,
                            @"A managed Stock source or mirror target is not a regular file.",
                            nil);
            return nil;
        }

        NSError *hashError = nil;
        NSString *stockHash = FMSHA256ForFileAtPath(stockPath, &hashError);
        if (![stockHash isEqual:catalogFile[@"stockSHA256"]]) {
            FMStagePlanFail(error, FMProfileStagePlannerErrorMirrorMismatch,
                            @"A Stock recovery source no longer matches the build catalog.",
                            hashError);
            return nil;
        }
    }

    for (NSString *relativePath in stockRestorePaths) {
        NSDictionary *catalogFile = catalogByPath[relativePath];
        unsigned long long targetBytes =
            [catalogFile[@"fileSize"] unsignedLongLongValue];
        if (ULLONG_MAX - writeBytes < targetBytes) {
            FMStagePlanFail(error, FMProfileStagePlannerErrorInvalidProfile,
                            @"Profile stage byte count overflowed.", nil);
            return nil;
        }
        writeBytes += targetBytes;
        [actions addObject:@{
            @"relativePath" : relativePath,
            @"phase" : @"restoreStock",
            @"operation" : @"restoreStock",
            @"targetSHA256" : catalogFile[@"stockSHA256"],
            @"targetBytes" : @(targetBytes),
        }];
    }

    for (NSString *relativePath in applyPaths) {
        NSDictionary *target = targetTargets[relativePath];
        unsigned long long targetBytes =
            [target[@"fileBytes"] unsignedLongLongValue];
        if (ULLONG_MAX - writeBytes < targetBytes) {
            FMStagePlanFail(error, FMProfileStagePlannerErrorInvalidProfile,
                            @"Profile stage byte count overflowed.", nil);
            return nil;
        }
        writeBytes += targetBytes;
        [actions addObject:@{
            @"relativePath" : relativePath,
            @"phase" : @"applyProfile",
            @"operation" : @"replace",
            @"targetSHA256" : target[@"sha256"],
            @"targetBytes" : @(targetBytes),
        }];
    }

    BOOL restartWouldBeRequired =
        !FMStagePlanProfileIDsEqual(state[@"confirmedProfileID"], normalizedTargetID);
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"preflightProfileStage",
        @"status" : @"eligible",
        @"systemBuild" : systemBuild,
        @"currentWorkingProfileID" : currentProfileID,
        @"targetProfileID" : normalizedTargetID,
        @"restoreMode" : sameSelection
            ? @"none"
            : fullStockFallback ? @"fullStockFallback" : @"currentProfile",
        @"stockRestoreRelativePaths" : stockRestorePaths,
        @"applyRelativePaths" : applyPaths,
        @"managedRelativePaths" : managedPaths,
        @"actions" : actions,
        @"writeCount" : @(actions.count),
        @"replacementCount" : @(applyPaths.count),
        @"stockRestoreCount" : @(stockRestorePaths.count),
        @"writeBytes" : @(writeBytes),
        @"restartWouldBeRequired" : restartWouldBeRequired ? @YES : @NO,
        @"readOnly" : @YES,
        @"filesystemMutated" : @NO,
        @"mirrorChanged" : @NO,
        @"stateChanged" : @NO,
        @"providerInvoked" : @NO,
        @"restartRequested" : @NO,
    };
}
