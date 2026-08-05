#import "FMDeviceStockSnapshot.h"

#import <errno.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMEnvironmentProbe.h"
#import "FMFileStore.h"
#import "FMMirrorPreparation.h"
#import "FMOperationLock.h"
#import "FMMountBackendExecutor.h"
#import "FMMountPaths.h"
#import "FMSecureDirectory.h"
#import "FMTreeManifest.h"

NSString *const FMDeviceStockSnapshotErrorDomain =
    @"com.hmmzzz.fontmanager.device-stock-snapshot";

static NSString *const FMEngineRootLogicalPath = @"/var/lib/fontmanager";
static NSString *const FMStateLogicalPath = @"/var/lib/fontmanager/state.json";
static NSString *const FMBaselineRootLogicalPath = @"/var/lib/fontmanager/baseline";
static NSString *const FMStockRootLogicalPath = @"/var/lib/fontmanager/stock";

static NSString *FMStockStagingName(NSString *systemBuild) {
    return [NSString stringWithFormat:@".%@.fontmanager-staging", systemBuild];
}

static BOOL FMStockSnapshotFail(NSError **error,
                                NSInteger code,
                                NSString *description,
                                NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMDeviceStockSnapshotErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMStockBuildIsSafe(NSString *systemBuild) {
    return [systemBuild isKindOfClass:NSString.class] &&
           systemBuild.length > 0 && systemBuild.length <= 32 &&
           !systemBuild.isAbsolutePath && systemBuild.pathComponents.count == 1 &&
           [systemBuild.lastPathComponent isEqual:systemBuild];
}

static BOOL FMStockPathIsAbsent(NSString *path,
                                NSString *description,
                                NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        return FMStockSnapshotFail(error, 4, description, nil);
    }
    if (errno != ENOENT) {
        return FMStockSnapshotFail(
            error, 4, @"A Stock snapshot path could not be inspected.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    }
    return YES;
}

static unsigned long long FMStockRegularBytes(
    NSDictionary<NSString *, id> *manifest) {
    unsigned long long total = 0;
    for (NSDictionary *entry in manifest[@"entries"]) {
        if ([entry[@"type"] isEqual:@"regular"]) {
            total += [entry[@"size"] unsignedLongLongValue];
        }
    }
    return total;
}

static BOOL FMStockTargetHasDedicatedMount(BOOL *hasDedicatedMount,
                                           NSError **error) {
    if (hasDedicatedMount == NULL) {
        return FMStockSnapshotFail(
            error, 3, @"The font mount inspection output is unavailable.", nil);
    }
    struct statfs filesystem = {0};
    if (statfs(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
               &filesystem) != 0) {
        return FMStockSnapshotFail(
            error, 3, @"The system font mount could not be inspected.",
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                 code:errno
                             userInfo:nil]);
    }
    NSString *mountTarget =
        [NSString stringWithUTF8String:filesystem.f_mntonname];
    *hasDedicatedMount =
        [mountTarget isEqual:FMMountSystemFontsLogicalPath];
    return YES;
}

static NSDictionary<NSString *, id> *FMStockSnapshotCreateContext(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (geteuid() != 0) {
        FMStockSnapshotFail(
            error, 1, @"Stock snapshot maintenance requires effective uid 0.", nil);
        return nil;
    }
    if (!FMStockBuildIsSafe(confirmedSystemBuild)) {
        FMStockSnapshotFail(error, 2,
                            @"The confirmed system build is invalid.", nil);
        return nil;
    }
    NSDictionary *environment = FMCreateEnvironmentStatus();
    if (![environment[@"system"][@"productBuildVersion"]
            isEqual:confirmedSystemBuild]) {
        FMStockSnapshotFail(error, 2,
                            @"The confirmed build does not match this device.", nil);
        return nil;
    }

    NSError *stateError = nil;
    id state = FMReadJSONObjectAtPath(jbroot(FMStateLogicalPath), &stateError);
    if (![state isKindOfClass:NSDictionary.class] ||
        !FMValidateStateDocument(state, &stateError) ||
        ![state[@"systemBuild"] isEqual:confirmedSystemBuild] ||
        ![state[@"mirrorState"] isEqual:@"clean"]) {
        FMStockSnapshotFail(
            error, 3, @"Managed Profile state is unavailable or not clean.", stateError);
        return nil;
    }

    NSDictionary *fonts = environment[@"fonts"];
    BOOL mappingActive = [fonts[@"mappingActive"] boolValue];
    BOOL targetHasDedicatedMount = NO;
    if (![fonts[@"mirrorPresent"] boolValue] ||
        ![fonts[@"mountStorageSupported"] boolValue] ||
        ![fonts[@"systemDirectoryReadable"] boolValue] ||
        ![fonts[@"rootfsDirectoryReadable"] boolValue] ||
        !FMStockTargetHasDedicatedMount(&targetHasDedicatedMount, error)) {
        if (error == NULL || *error == nil) {
            FMStockSnapshotFail(
                error, 3, @"The managed font workspace is unavailable.", nil);
        }
        return nil;
    }
    if (mappingActive || targetHasDedicatedMount) {
        FMStockSnapshotFail(
            error, 3,
            @"Create the Stock snapshot before mounting the font mirror.", nil);
        return nil;
    }

    NSError *inspectionError = nil;
    BOOL autoMountConflict = NO;
    if (!FMLegacyProviderAutoMountConflictsWithSystemFonts(
            &autoMountConflict, &inspectionError) || autoMountConflict) {
        FMStockSnapshotFail(
            error, 3,
            @"Legacy Provider automatic mounting must not target the system Fonts tree.",
            inspectionError);
        return nil;
    }

    NSString *baselinePath = [[jbroot(FMBaselineRootLogicalPath)
        stringByAppendingPathComponent:confirmedSystemBuild]
        stringByAppendingPathComponent:@"manifest.json"];
    id baseline = FMReadJSONObjectAtPath(baselinePath, &inspectionError);
    if (![baseline isKindOfClass:NSDictionary.class] ||
        !FMValidateManifestDocument(baseline, &inspectionError)) {
        FMStockSnapshotFail(error, 3,
                            @"The saved Stock baseline is unavailable or invalid.",
                            inspectionError);
        return nil;
    }

    NSString *snapshotParent = jbroot(FMStockRootLogicalPath);
    NSString *snapshotRoot = [snapshotParent
        stringByAppendingPathComponent:confirmedSystemBuild];
    NSString *stagingRoot = [snapshotParent
        stringByAppendingPathComponent:FMStockStagingName(confirmedSystemBuild)];
    if (!FMStockPathIsAbsent(
            snapshotRoot, @"A Stock snapshot already exists for this build.", error) ||
        !FMStockPathIsAbsent(
            stagingRoot, @"An interrupted Stock snapshot staging path exists.", error)) {
        return nil;
    }

    struct statfs capacity = {0};
    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    if (statfs(engineRoot.fileSystemRepresentation, &capacity) != 0) {
        FMStockSnapshotFail(
            error, 3, @"Available snapshot storage could not be inspected.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return nil;
    }
    unsigned long long availableBytes =
        (unsigned long long)capacity.f_bavail *
        (unsigned long long)capacity.f_bsize;
    unsigned long long stockBytes = FMStockRegularBytes(baseline);
    unsigned long long reserve = MAX(stockBytes / 10, 64ULL * 1024ULL * 1024ULL);
    if (stockBytes == 0 || availableBytes < stockBytes + reserve) {
        FMStockSnapshotFail(error, 3,
                            @"There is not enough free space for the Stock snapshot.", nil);
        return nil;
    }

    return @{
        @"systemBuild" : confirmedSystemBuild,
        @"state" : state,
        @"baseline" : baseline,
        @"stockBytes" : @(stockBytes),
        @"availableBytes" : @(availableBytes),
        @"snapshotRoot" : snapshotRoot,
        @"snapshotStagingRoot" : stagingRoot,
    };
}

NSDictionary<NSString *, id> *FMCreateDeviceStockSnapshotPreflight(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSDictionary *context = FMStockSnapshotCreateContext(
        confirmedSystemBuild, error);
    if (context == nil) return nil;
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"preflightStockSnapshot",
        @"status" : @"eligible",
        @"systemBuild" : confirmedSystemBuild,
        @"stockEntryCount" : @([context[@"baseline"][@"entries"] count]),
        @"stockRegularBytes" : context[@"stockBytes"],
        @"availableBytes" : context[@"availableBytes"],
        @"unmountFlags" : @0,
        @"forceUnmount" : @NO,
        @"mappingWasActive" : @NO,
        @"unmountRequired" : @NO,
        @"mountBackendWouldBeInvoked" : @YES,
        @"mirrorContentScanned" : @NO,
        @"filesystemMutated" : @NO,
        @"mappingChanged" : @NO,
        @"stateChanged" : @NO,
        @"restartRequested" : @NO,
    };
}

static BOOL FMStockSourceIsReadOnly(NSString *stockRoot, NSError **error) {
    struct statfs filesystem = {0};
    if (statfs(stockRoot.fileSystemRepresentation, &filesystem) != 0 ||
        (filesystem.f_flags & MNT_RDONLY) == 0) {
        int savedError = errno != 0 ? errno : EROFS;
        return FMStockSnapshotFail(
            error, 6, @"The exposed Stock source is not read-only.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil]);
    }
    return YES;
}

static BOOL FMStockRemountManagedMirror(NSError **error) {
    NSError *backendError = nil;
    NSDictionary *backendReport = FMInvokeMountBackendForPreparedSystemFonts(
        &backendError);
    if (backendReport == nil ||
        ![backendReport[@"reportedSuccess"] boolValue]) {
        return FMStockSnapshotFail(
            error, 7, @"The unchanged font mirror could not be remounted.",
            backendError);
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMCaptureDeviceStockSnapshotLocked(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSDictionary *context = FMStockSnapshotCreateContext(
        confirmedSystemBuild, error);
    if (context == nil) return nil;

    NSError *operationError = nil;
    NSString *stockRoot = FMMountResolvedStockFontsPath();
    BOOL sourceReady = FMStockSourceIsReadOnly(stockRoot, &operationError);
    NSString *varLibrary = jbroot(@"/var/lib").stringByResolvingSymlinksInPath;
    BOOL parentReady = sourceReady && FMEnsureSecureDirectoryTree(
        varLibrary, @[ @"fontmanager", @"stock" ], 0, 0, 0755,
        &operationError);
    NSDictionary *copiedManifest = parentReady
        ? FMBuildVerifiedStockMirror(
            stockRoot, context[@"snapshotStagingRoot"], &operationError)
        : nil;
    if (copiedManifest != nil &&
        ![copiedManifest isEqual:context[@"baseline"]]) {
        FMStockSnapshotFail(
            &operationError, 6,
            @"The copied Stock snapshot does not match the saved baseline.", nil);
    }
    BOOL snapshotPublished = copiedManifest != nil &&
        [copiedManifest isEqual:context[@"baseline"]] &&
        FMPublishVerifiedStockMirror(
            stockRoot, context[@"snapshotStagingRoot"],
            context[@"snapshotRoot"], &operationError);

    NSError *remountError = nil;
    BOOL remounted = FMStockRemountManagedMirror(&remountError);
    if (!snapshotPublished || !remounted) {
        if (error != NULL) *error = remountError ?: operationError;
        return nil;
    }

    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSDictionary *finalState = environment[@"state"];
    if (![environment[@"engineState"] isEqual:@"ready"] ||
        ![finalState[@"valid"] boolValue] ||
        ![finalState[@"systemBuild"] isEqual:confirmedSystemBuild] ||
        ![finalState[@"mirrorState"] isEqual:@"clean"] ||
        !FMMountManagedMappingIsActive(error)) {
        if (error == NULL || *error == nil) {
            FMStockSnapshotFail(
                error, 8, @"The managed font mapping was not restored.", nil);
        }
        return nil;
    }

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"captureStockSnapshot",
        @"status" : @"captured",
        @"systemBuild" : confirmedSystemBuild,
        @"stockEntryCount" : @([context[@"baseline"][@"entries"] count]),
        @"stockRegularBytes" : context[@"stockBytes"],
        @"snapshotLogicalPath" : [FMStockRootLogicalPath
            stringByAppendingPathComponent:confirmedSystemBuild],
        @"forceUnmount" : @NO,
        @"mappingWasActive" : @NO,
        @"unmountPerformed" : @NO,
        @"mountBackendInvoked" : @YES,
        @"mappingActive" : @YES,
        @"mappingReadOnly" : @YES,
        @"sourceAndSnapshotVerified" : @YES,
        @"mirrorContentScanned" : @NO,
        @"filesystemMutated" : @YES,
        @"stateChanged" : @NO,
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMCaptureDeviceStockSnapshot(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSString *engineRoot = jbroot(FMEngineRootLogicalPath);
    NSError *lockError = nil;
    int lock = FMAcquireExclusiveDirectoryLock(engineRoot, 0, 0, &lockError);
    if (lock < 0) {
        FMStockSnapshotFail(error, 9,
                            @"Another font operation is already running.",
                            lockError);
        return nil;
    }
    NSError *operationError = nil;
    NSDictionary *result = FMCaptureDeviceStockSnapshotLocked(
        confirmedSystemBuild, &operationError);
    NSError *releaseError = nil;
    BOOL released = FMReleaseExclusiveDirectoryLock(lock, &releaseError);
    if (result == nil || !released) {
        if (error != NULL) *error = operationError ?: releaseError;
        return nil;
    }
    return result;
}
