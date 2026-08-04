#import "FMDeviceMountEngine.h"

#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <roothide.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/stdio.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMEnvironmentProbe.h"
#import "FMFileStore.h"
#import "FMMirrorPreparation.h"
#import "FMMountCoordinator.h"
#import "FMMountBackendCompatibility.h"
#import "FMMountBackendExecutor.h"
#import "FMMountInspection.h"
#import "FMMountPaths.h"
#import "FMSecureDirectory.h"

NSString *const FMDeviceMountEngineErrorDomain =
    @"com.hmmzzz.fontmanager.devicemountengine";

static NSString *const FMMountStagingName =
    @".Fonts.fontmanager-staging";
static NSString *const FMBaselineRootLogicalPath =
    @"/var/lib/fontmanager/baseline";
static NSString *const FMStockSnapshotRootLogicalPath =
    @"/var/lib/fontmanager/stock";
static NSString *const FMStateLogicalPath = @"/var/lib/fontmanager/state.json";

static NSString *FMBaselineStagingName(NSString *systemBuild) {
    return [NSString stringWithFormat:@".%@.fontmanager-staging", systemBuild];
}

static BOOL FMDeviceMountEngineFail(NSError **error,
                                    NSInteger code,
                                    NSString *description,
                                    NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) {
            userInfo[NSUnderlyingErrorKey] = underlying;
        }
        *error = [NSError errorWithDomain:FMDeviceMountEngineErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMRequireAbsentPath(NSString *path,
                                NSString *description,
                                NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        return FMDeviceMountEngineFail(error, 4, description, nil);
    }
    if (errno != ENOENT) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 4, @"A preparation path could not be inspected.", underlying);
    }
    return YES;
}

static BOOL FMRequireSecureSharedMountRoot(NSString *mountRoot,
                                           NSError **error) {
    int descriptor = open(mountRoot.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 4, @"The reusable bindfs storage root could not be opened.",
            underlying);
    }
    struct stat info = {0};
    int inspectResult = fstat(descriptor, &info);
    if (inspectResult != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        int savedError = inspectResult != 0 ? errno : EPERM;
        close(descriptor);
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:savedError
                            userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 4, @"The reusable bindfs storage root has unsafe metadata.",
            underlying);
    }

    if (close(descriptor) != 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 4, @"The shared bindfs storage root could not be closed safely.",
            underlying);
    }
    return YES;
}

static BOOL FMRequireFreshOrReusableMountStorage(
    NSString *mountRoot,
    BOOL *reused,
    NSError **error) {
    struct stat rootInfo = {0};
    errno = 0;
    if (lstat(mountRoot.fileSystemRepresentation, &rootInfo) != 0) {
        if (errno != ENOENT) {
            NSError *underlying =
                [NSError errorWithDomain:NSPOSIXErrorDomain
                                    code:errno
                                userInfo:nil];
            return FMDeviceMountEngineFail(
                error, 4, @"The bindfs storage root could not be inspected.",
                underlying);
        }
        if (reused != NULL) *reused = NO;
        return YES;
    }

    NSError *storageError = nil;
    // `/bindfs` is a shared logical namespace and may contain bindfs sources
    // for unrelated targets. MarkFont validates the shared root and only owns
    // its exact Fonts subtree; it never requires an external alias.
    if (!FMRequireSecureSharedMountRoot(mountRoot, &storageError)) {
        return FMDeviceMountEngineFail(
            error, 4,
            @"Existing shared bindfs storage is unsafe.", storageError);
    }
    if (reused != NULL) *reused = YES;
    return YES;
}

static BOOL FMRequireReadOnlyStockDirectory(NSString *stockPath, NSError **error) {
    struct stat info = {0};
    if (lstat(stockPath.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode)) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno ?: ENOTDIR
                                               userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 3, @"The immutable Stock font directory is unavailable.", underlying);
    }
    struct statfs filesystem = {0};
    if (statfs(stockPath.fileSystemRepresentation, &filesystem) != 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 3, @"The Stock font filesystem could not be inspected.", underlying);
    }
    if ((filesystem.f_flags & MNT_RDONLY) == 0) {
        return FMDeviceMountEngineFail(
            error, 3, @"The Stock font source is not on a read-only filesystem.", nil);
    }
    return YES;
}

static NSString *FMPhysicalDirectoryPath(NSString *path, NSError **error) {
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (resolved == NULL) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        FMDeviceMountEngineFail(error, 3,
                                @"A secure directory anchor could not be resolved.",
                                underlying);
        return nil;
    }
    NSString *result = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:resolved
                                     length:strlen(resolved)];
    free(resolved);
    if (result.length == 0) {
        FMDeviceMountEngineFail(error, 3,
                                @"A secure directory anchor is invalid.", nil);
        return nil;
    }
    return result;
}

static BOOL FMFilesystemCapacity(NSString *path,
                                 unsigned long long *availableBytes,
                                 NSError **error) {
    struct statfs filesystem = {0};
    if (statfs(path.fileSystemRepresentation, &filesystem) != 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 3, @"The destination filesystem could not be inspected.",
            underlying);
    }
    if ((filesystem.f_flags & MNT_RDONLY) != 0) {
        return FMDeviceMountEngineFail(
            error, 3, @"The current jbroot filesystem is read-only.", nil);
    }
    unsigned long long blocks = (unsigned long long)filesystem.f_bavail;
    unsigned long long blockSize = (unsigned long long)filesystem.f_bsize;
    if (blockSize != 0 && blocks > ULLONG_MAX / blockSize) {
        return FMDeviceMountEngineFail(
            error, 3, @"The destination capacity could not be represented.", nil);
    }
    if (availableBytes != NULL) {
        *availableBytes = blocks * blockSize;
    }
    return YES;
}

static BOOL FMRequireJBRootRoundTrip(NSString *logicalPath, NSError **error) {
    NSString *physicalPath = jbroot(logicalPath);
    NSString *convertedBack = rootfs(physicalPath);
    if (![convertedBack isEqualToString:logicalPath]) {
        return FMDeviceMountEngineFail(
            error, 3, @"A RootHide logical path failed its round-trip check.", nil);
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMPreflightInspection(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (geteuid() != 0) {
        FMDeviceMountEngineFail(error, 2,
                                @"Stock mirror preparation requires uid 0.", nil);
        return nil;
    }
    if (confirmedSystemBuild.length == 0 || confirmedSystemBuild.length > 32 ||
        confirmedSystemBuild.pathComponents.count != 1) {
        FMDeviceMountEngineFail(error, 1,
                                @"The confirmed system build is invalid.", nil);
        return nil;
    }

    NSError *inspectionError = nil;
    NSDictionary *inspection =
        FMCreateDeviceMountInspection(&inspectionError);
    NSDictionary *decision = inspection != nil
        ? FMCoordinateMountInspection(inspection, &inspectionError)
        : nil;
    if (inspection == nil || decision == nil) {
        FMDeviceMountEngineFail(error, 3,
                                @"The read-only mount preflight failed.",
                                inspectionError);
        return nil;
    }

    NSDictionary *backend = inspection[@"mountBackend"];
    NSDictionary *fonts = inspection[@"fonts"];
    NSDictionary *mapping = inspection[@"mapping"];
    NSDictionary *state = inspection[@"state"];
    NSArray *issues = decision[@"issues"];
    BOOL exactEmptyState =
        [inspection[@"evidenceMode"] isEqual:@"deviceReadOnly"] &&
        [inspection[@"systemBuild"] isEqual:confirmedSystemBuild] &&
        [decision[@"classification"] isEqual:@"initializeEmptyMirror"] &&
        [decision[@"recommendedAction"] isEqual:@"initializeMirror"] &&
        [decision[@"allowedActions"] isEqual:@[ @"initializeMirror" ]] &&
        [issues isKindOfClass:NSArray.class] && issues.count == 0 &&
        FMMountBackendEvidenceSatisfiesCompatibilityContract(backend) &&
        [fonts[@"mirrorKind"] isEqual:@"missing"] &&
        [fonts[@"mirrorLogicalPath"]
            isEqual:FMMountResolvedMirrorLogicalPath(NULL, NULL)] &&
        [fonts[@"systemReadable"] boolValue] &&
        [fonts[@"rootfsReadable"] boolValue] &&
        [fonts[@"mirrorInsideJBRoot"] boolValue] &&
        [fonts[@"rootfsDistinctFromMirror"] boolValue] &&
        ![mapping[@"active"] boolValue] &&
        ![state[@"present"] boolValue] &&
        ![state[@"valid"] boolValue];
    if (!exactEmptyState) {
        FMDeviceMountEngineFail(
            error, 3,
            @"The device no longer matches the confirmed empty-mirror baseline.", nil);
        return nil;
    }
    return inspection;
}

static NSDictionary<NSString *, id> *FMValidatedPreparationPreflight(
    NSString *confirmedSystemBuild,
    NSDictionary<NSString *, id> **inspectionResult,
    NSError **error) {
    NSDictionary *inspection =
        FMPreflightInspection(confirmedSystemBuild, error);
    if (inspection == nil) {
        return nil;
    }

    NSString *stockRoot = jbroot(FMMountRootfsFontsLogicalPath);
    NSString *mountStorageRoot = jbroot(FMMountStorageRootLogicalPath);
    NSString *mountStorageParent = jbroot(@"/bindfs/System/Library");
    NSString *stagingRoot =
        [mountStorageParent stringByAppendingPathComponent:FMMountStagingName];
    NSString *finalMirrorRoot =
        [mountStorageParent stringByAppendingPathComponent:@"Fonts"];
    NSString *baselineBuildPath = [jbroot(FMBaselineRootLogicalPath)
        stringByAppendingPathComponent:confirmedSystemBuild];
    NSString *baselineStagingPath = [jbroot(FMBaselineRootLogicalPath)
        stringByAppendingPathComponent:FMBaselineStagingName(confirmedSystemBuild)];
    NSString *stockSnapshotPath = [jbroot(FMStockSnapshotRootLogicalPath)
        stringByAppendingPathComponent:confirmedSystemBuild];
    NSString *stockSnapshotStagingPath = [jbroot(FMStockSnapshotRootLogicalPath)
        stringByAppendingPathComponent:FMBaselineStagingName(confirmedSystemBuild)];

    BOOL mountStorageReused = NO;

    if (!FMRequireReadOnlyStockDirectory(stockRoot, error) ||
        !FMRequireFreshOrReusableMountStorage(
            mountStorageRoot, &mountStorageReused, error) ||
        !FMRequireAbsentPath(stagingRoot,
                             @"A preserved Stock-mirror staging directory already exists.",
                             error) ||
        !FMRequireAbsentPath(finalMirrorRoot,
                             @"The final managed mirror already exists.", error) ||
        !FMRequireAbsentPath(baselineBuildPath,
                             @"A baseline for this system build already exists.", error) ||
        !FMRequireAbsentPath(baselineStagingPath,
                             @"A preserved baseline staging directory already exists.",
                             error) ||
        !FMRequireAbsentPath(stockSnapshotPath,
                             @"A Stock snapshot for this build already exists.", error) ||
        !FMRequireAbsentPath(stockSnapshotStagingPath,
                             @"A Stock snapshot staging directory already exists.",
                             error)) {
        return nil;
    }

    NSString *bootstrapRoot = FMPhysicalDirectoryPath(jbroot(@"/"), error);
    NSString *varLibrary = FMPhysicalDirectoryPath(jbroot(@"/var/lib"), error);
    if (bootstrapRoot == nil || varLibrary == nil ||
        [bootstrapRoot isEqualToString:@"/"] ||
        !FMRequireJBRootRoundTrip(@"/var/lib", error) ||
        !FMEnsureSecureDirectoryTree(bootstrapRoot, @[], 0, 0, 0755, error) ||
        !FMEnsureSecureDirectoryTree(varLibrary, @[], 0, 0, 0755, error)) {
        if (error != NULL && *error == nil) {
            FMDeviceMountEngineFail(error, 3,
                                    @"A preparation anchor is invalid.", nil);
        }
        return nil;
    }

    unsigned long long availableBytes = 0;
    if (!FMFilesystemCapacity(bootstrapRoot, &availableBytes, error)) {
        return nil;
    }
    unsigned long long stockBytes =
        [inspection[@"manifest"][@"stockRegularBytes"] unsignedLongLongValue];
    unsigned long long reserve = MAX(stockBytes / 10, 64ULL * 1024ULL * 1024ULL);
    if (stockBytes == 0 || stockBytes > ULLONG_MAX / 2 ||
        ULLONG_MAX - (stockBytes * 2) < reserve ||
        availableBytes < (stockBytes * 2) + reserve) {
        FMDeviceMountEngineFail(
            error, 3, @"The current jbroot does not have enough safe free space.", nil);
        return nil;
    }
    if (inspectionResult != NULL) {
        *inspectionResult = inspection;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"preflightStockMirror",
        @"status" : @"eligible",
        @"systemBuild" : confirmedSystemBuild,
        @"stockEntryCount" : inspection[@"manifest"][@"stockEntryCount"],
        @"stockRegularBytes" : @(stockBytes),
        @"availableBytes" : @(availableBytes),
        @"mountBackendVersion" : inspection[@"mountBackend"][@"version"],
        @"mirrorLogicalPath" : FMMountResolvedMirrorLogicalPath(NULL, NULL),
        @"mountStorageReused" : mountStorageReused ? @YES : @NO,
        @"readOnly" : @YES,
        @"mountBackendInvoked" : @NO,
        @"filesystemMutated" : @NO,
        @"mappingChanged" : @NO,
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMCreateDeviceStockMirrorPreflight(
    NSString *confirmedSystemBuild,
    NSError **error) {
    return FMValidatedPreparationPreflight(confirmedSystemBuild, NULL, error);
}

static BOOL FMWriteBaseline(NSDictionary<NSString *, id> *identity,
                            NSDictionary<NSString *, id> *manifest,
                            NSString *systemBuild,
                            NSError **error) {
    NSError *validationError = nil;
    if (!FMValidateBaselineIdentity(identity, &validationError) ||
        !FMValidateManifestDocument(manifest, &validationError)) {
        return FMDeviceMountEngineFail(error, 6,
                                       @"The generated Stock baseline is invalid.",
                                       validationError);
    }

    NSString *varLibrary = FMPhysicalDirectoryPath(jbroot(@"/var/lib"), error);
    NSString *bootstrapRoot = FMPhysicalDirectoryPath(jbroot(@"/"), error);
    if (varLibrary == nil || bootstrapRoot == nil ||
        [bootstrapRoot isEqualToString:@"/"] ||
        !FMRequireJBRootRoundTrip(@"/var/lib", error)) {
        return FMDeviceMountEngineFail(
            error, 6, @"The baseline anchor is invalid for the current jbroot.", nil);
    }
    NSString *stagingName = FMBaselineStagingName(systemBuild);
    if (!FMCreateSecureLeafDirectory(varLibrary,
                                     @[ @"fontmanager", @"baseline" ],
                                     stagingName, 0, 0, 0755, error)) {
        return NO;
    }

    NSString *baselineParent = [[varLibrary
        stringByAppendingPathComponent:@"fontmanager"]
        stringByAppendingPathComponent:@"baseline"];
    NSString *stagingDirectory =
        [baselineParent stringByAppendingPathComponent:stagingName];
    NSString *baselineDirectory =
        [baselineParent stringByAppendingPathComponent:systemBuild];
    NSString *manifestPath =
        [stagingDirectory stringByAppendingPathComponent:@"manifest.json"];
    NSString *identityPath =
        [stagingDirectory stringByAppendingPathComponent:@"identity.json"];
    if (!FMWriteJSONObjectAtomically(manifest, manifestPath, 0644, error) ||
        !FMWriteJSONObjectAtomically(identity, identityPath, 0644, error)) {
        return NO;
    }

    NSError *readbackError = nil;
    NSDictionary *writtenManifest = FMReadJSONObjectAtPath(manifestPath, &readbackError);
    NSDictionary *writtenIdentity = FMReadJSONObjectAtPath(identityPath, &readbackError);
    if (![writtenManifest isEqual:manifest] || ![writtenIdentity isEqual:identity] ||
        !FMValidateManifestDocument(writtenManifest, &readbackError) ||
        !FMValidateBaselineIdentity(writtenIdentity, &readbackError)) {
        return FMDeviceMountEngineFail(
            error, 6, @"The staged baseline failed its readback verification.",
            readbackError);
    }
    if (renamex_np(stagingDirectory.fileSystemRepresentation,
                   baselineDirectory.fileSystemRepresentation,
                   RENAME_EXCL) != 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 6, @"The verified baseline could not be atomically published.",
            underlying);
    }
    int parentDescriptor = open(baselineParent.fileSystemRepresentation,
                                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parentDescriptor < 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 6, @"The baseline parent could not be opened after publication.",
            underlying);
    }
    int syncResult = fsync(parentDescriptor);
    int syncError = errno;
    int closeResult = close(parentDescriptor);
    if ((syncResult != 0 && syncError != EINVAL && syncError != ENOTSUP) ||
        closeResult != 0) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:syncResult != 0 ? syncError : errno
                                               userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 6, @"The published baseline directory could not be flushed.",
            underlying);
    }
    return YES;
}

NSDictionary<NSString *, id> *FMPrepareDeviceStockMirror(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSDictionary *inspection = nil;
    NSDictionary *preflight = FMValidatedPreparationPreflight(
        confirmedSystemBuild, &inspection, error);
    if (preflight == nil || inspection == nil) {
        return nil;
    }

    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSDictionary *system = environment[@"system"];
    NSDictionary *backend = inspection[@"mountBackend"];
    if (![system[@"productBuildVersion"] isEqual:confirmedSystemBuild]) {
        FMDeviceMountEngineFail(error, 3,
                                @"System identity changed after mount preflight.", nil);
        return nil;
    }

    NSString *stockRoot = jbroot(FMMountRootfsFontsLogicalPath);
    NSString *mountStorageParent = jbroot(@"/bindfs/System/Library");
    NSString *stagingRoot =
        [mountStorageParent stringByAppendingPathComponent:FMMountStagingName];
    NSString *finalMirrorRoot =
        [mountStorageParent stringByAppendingPathComponent:@"Fonts"];
    NSString *bootstrapRoot = FMPhysicalDirectoryPath(jbroot(@"/"), error);
    if (bootstrapRoot == nil || [bootstrapRoot isEqualToString:@"/"] ||
        !FMEnsureSecureDirectoryTree(bootstrapRoot,
                                     @[ @"bindfs", @"System", @"Library" ],
                                     0, 0, 0755, error)) {
        return nil;
    }

    NSError *preparationError = nil;
    NSDictionary *stockManifest =
        FMBuildVerifiedStockMirror(stockRoot, stagingRoot, &preparationError);
    if (stockManifest == nil) {
        FMDeviceMountEngineFail(
            error, 5,
            @"Stock copy or complete staging verification failed. Staging was preserved.",
            preparationError);
        return nil;
    }
    if (!FMPublishVerifiedStockMirror(stockRoot, stagingRoot, finalMirrorRoot,
                                      &preparationError)) {
        FMDeviceMountEngineFail(
            error, 5,
            @"Verified Stock mirror publication failed. Staging was preserved.",
            preparationError);
        return nil;
    }

    NSDictionary *postInspection =
        FMCreateDeviceMountInspection(&preparationError);
    NSDictionary *postDecision = postInspection != nil
        ? FMCoordinateMountInspection(postInspection, &preparationError)
        : nil;
    NSDictionary *postManifest = postInspection[@"manifest"];
    BOOL postcondition = postInspection != nil && postDecision != nil &&
        [postDecision[@"classification"] isEqual:@"adoptStockMirror"] &&
        [postDecision[@"issues"] count] == 0 &&
        [postInspection[@"systemBuild"] isEqual:confirmedSystemBuild] &&
        [postInspection[@"fonts"][@"mirrorKind"] isEqual:@"present"] &&
        ![postInspection[@"mapping"][@"active"] boolValue] &&
        ![postInspection[@"state"][@"present"] boolValue] &&
        [postManifest[@"scanState"] isEqual:@"complete"] &&
        [postManifest[@"changedPaths"] count] == 0 &&
        [postManifest[@"missingPaths"] count] == 0 &&
        [postManifest[@"unknownPaths"] count] == 0 &&
        [postManifest[@"typeChangedPaths"] count] == 0;
    if (!postcondition) {
        FMDeviceMountEngineFail(
            error, 5,
            @"The published mirror failed the independent read-only post-check.",
            preparationError);
        return nil;
    }

    NSString *varLibrary = FMPhysicalDirectoryPath(jbroot(@"/var/lib"), error);
    NSString *stockSnapshotParent = jbroot(FMStockSnapshotRootLogicalPath);
    NSString *stockSnapshotStaging = [stockSnapshotParent
        stringByAppendingPathComponent:FMBaselineStagingName(confirmedSystemBuild)];
    NSString *stockSnapshotRoot = [stockSnapshotParent
        stringByAppendingPathComponent:confirmedSystemBuild];
    if (varLibrary == nil ||
        !FMEnsureSecureDirectoryTree(varLibrary, @[ @"fontmanager", @"stock" ],
                                     0, 0, 0755, error)) {
        return nil;
    }
    NSDictionary *snapshotManifest = FMBuildVerifiedStockMirror(
        finalMirrorRoot, stockSnapshotStaging, &preparationError);
    if (snapshotManifest == nil || ![snapshotManifest isEqual:stockManifest] ||
        !FMPublishVerifiedStockMirror(
            finalMirrorRoot, stockSnapshotStaging, stockSnapshotRoot,
            &preparationError)) {
        FMDeviceMountEngineFail(
            error, 5,
            @"The durable Stock snapshot could not be copied and verified.",
            preparationError);
        return nil;
    }

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDictionary *identity = @{
        @"schemaVersion" : @(FMBaselineIdentitySchemaVersion),
        @"productType" : system[@"productType"],
        @"productVersion" : system[@"productVersion"],
        @"productBuildVersion" : system[@"productBuildVersion"],
        @"sourceLogicalPath" : @"/System/Library/Fonts",
        @"mirrorLogicalPath" : @"/bindfs/System/Library/Fonts",
        @"mountBackend" : FMMountBackendIdentifier,
        @"mountBackendVersion" : backend[@"version"],
        @"createdAt" : [formatter stringFromDate:NSDate.date],
    };
    if (!FMWriteBaseline(identity, stockManifest, confirmedSystemBuild, error)) {
        return nil;
    }

    NSString *manifestPath = [[jbroot(FMBaselineRootLogicalPath)
        stringByAppendingPathComponent:confirmedSystemBuild]
        stringByAppendingPathComponent:@"manifest.json"];
    NSString *manifestHash = FMSHA256ForFileAtPath(manifestPath, &preparationError);
    if (manifestHash == nil) {
        FMDeviceMountEngineFail(error, 6,
                                @"The committed baseline manifest could not be verified.",
                                preparationError);
        return nil;
    }

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"prepareStockMirror",
        @"status" : @"prepared",
        @"systemBuild" : confirmedSystemBuild,
        @"mirrorLogicalPath" : FMMountResolvedMirrorLogicalPath(NULL, NULL),
        @"baselineLogicalPath" : [FMBaselineRootLogicalPath
            stringByAppendingPathComponent:confirmedSystemBuild],
        @"stockSnapshotLogicalPath" : [FMStockSnapshotRootLogicalPath
            stringByAppendingPathComponent:confirmedSystemBuild],
        @"stockEntryCount" : @([stockManifest[@"entries"] count]),
        @"baselineManifestSHA256" : manifestHash,
        @"mountBackendInvoked" : @NO,
        @"mappingChanged" : @NO,
        @"stateCreated" : @NO,
        @"restartRequested" : @NO,
        @"nextClassification" : postDecision[@"classification"],
    };
}

static BOOL FMPathIsWithinPhysicalRoot(NSString *path, NSString *root) {
    NSString *standardPath = path.stringByStandardizingPath;
    NSString *standardRoot = root.stringByStandardizingPath;
    if ([standardPath isEqual:standardRoot]) {
        return YES;
    }
    return [standardPath hasPrefix:[standardRoot stringByAppendingString:@"/"]];
}

static BOOL FMRequireSecureRegularFile(NSString *path, NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceMountEngineFail(error, 7,
                                       @"A required activation record is missing.",
                                       underlying);
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return FMDeviceMountEngineFail(
            error, 7, @"A required activation record has unsafe metadata.", nil);
    }
    return YES;
}

static BOOL FMRequirePhysicalSystemTarget(NSError **error) {
    int descriptor = open(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno
                                               userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 7, @"The inactive system font mount point is unavailable.",
            underlying);
    }
    struct stat info = {0};
    errno = 0;
    int statResult = fstat(descriptor, &info);
    if (statResult != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        int savedError = statResult != 0 ? errno : EPERM;
        close(descriptor);
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:savedError
                                               userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 7, @"The inactive system font target has unsafe metadata.",
            underlying);
    }
    if (close(descriptor) != 0) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno
                                               userInfo:nil];
        return FMDeviceMountEngineFail(
            error, 7, @"The inactive system font target could not be closed.",
            underlying);
    }
    return YES;
}

static BOOL FMInspectionHasExactPreparedStockEvidence(
    NSDictionary<NSString *, id> *inspection,
    NSDictionary<NSString *, id> *decision,
    NSString *confirmedSystemBuild) {
    NSDictionary *backend = inspection[@"mountBackend"];
    NSDictionary *fonts = inspection[@"fonts"];
    NSDictionary *mapping = inspection[@"mapping"];
    NSDictionary *manifest = inspection[@"manifest"];
    NSDictionary *state = inspection[@"state"];
    NSArray *issues = decision[@"issues"];
    BOOL mappingActive = [mapping[@"active"] boolValue];
    BOOL mappingExact = mappingActive
        ? [mapping[@"targetMatches"] boolValue] &&
          [mapping[@"sourceMatchesMirror"] boolValue] &&
          [mapping[@"readOnly"] boolValue] &&
          [mapping[@"filesystemType"] isEqual:@"bindfs"]
        : ![mapping[@"targetMatches"] boolValue] &&
          ![mapping[@"sourceMatchesMirror"] boolValue] &&
          ![mapping[@"readOnly"] boolValue] &&
          mapping[@"filesystemType"] == NSNull.null;
    NSString *stockManifestHash = manifest[@"stockManifestSHA256"];
    NSString *mirrorManifestHash = manifest[@"mirrorManifestSHA256"];

    return [inspection[@"evidenceMode"] isEqual:@"deviceReadOnly"] &&
        [inspection[@"systemBuild"] isEqual:confirmedSystemBuild] &&
        [decision[@"classification"] isEqual:@"adoptStockMirror"] &&
        [decision[@"recommendedAction"] isEqual:@"adoptStockMirror"] &&
        [decision[@"allowedActions"] isEqual:@[ @"adoptStockMirror" ]] &&
        [issues isKindOfClass:NSArray.class] && issues.count == 0 &&
        FMMountBackendEvidenceSatisfiesCompatibilityContract(backend) &&
        [fonts[@"mirrorKind"] isEqual:@"present"] &&
        [fonts[@"mirrorLogicalPath"]
            isEqual:FMMountResolvedMirrorLogicalPath(NULL, NULL)] &&
        [fonts[@"systemReadable"] boolValue] &&
        [fonts[@"rootfsReadable"] boolValue] &&
        [fonts[@"mirrorInsideJBRoot"] boolValue] &&
        [fonts[@"rootfsDistinctFromMirror"] boolValue] &&
        mappingExact &&
        [manifest[@"scanState"] isEqual:@"complete"] &&
        [manifest[@"systemBuild"] isEqual:confirmedSystemBuild] &&
        [manifest[@"stockEntryCount"] integerValue] > 0 &&
        [manifest[@"stockEntryCount"] isEqual:manifest[@"mirrorEntryCount"]] &&
        [stockManifestHash isKindOfClass:NSString.class] &&
        [stockManifestHash isEqual:mirrorManifestHash] &&
        [manifest[@"changedPaths"] count] == 0 &&
        [manifest[@"missingPaths"] count] == 0 &&
        [manifest[@"unknownPaths"] count] == 0 &&
        [manifest[@"typeChangedPaths"] count] == 0 &&
        ![manifest[@"matchesWorkingProfile"] boolValue] &&
        ![state[@"present"] boolValue] &&
        ![state[@"valid"] boolValue] &&
        state[@"workingProfileID"] == NSNull.null;
}

static NSDictionary<NSString *, id> *FMValidatedPreparedStockMountPreflight(
    NSString *confirmedSystemBuild,
    NSDictionary<NSString *, id> **inspectionResult,
    NSError **error) {
    if (geteuid() != 0) {
        FMDeviceMountEngineFail(error, 2,
                                @"Prepared Stock activation requires uid 0.", nil);
        return nil;
    }
    if (confirmedSystemBuild.length == 0 || confirmedSystemBuild.length > 32 ||
        confirmedSystemBuild.pathComponents.count != 1) {
        FMDeviceMountEngineFail(error, 1,
                                @"The confirmed system build is invalid.", nil);
        return nil;
    }

    NSError *inspectionError = nil;
    NSDictionary *inspection = FMCreateDeviceMountInspection(&inspectionError);
    NSDictionary *decision = inspection != nil
        ? FMCoordinateMountInspection(inspection, &inspectionError)
        : nil;
    if (inspection == nil || decision == nil ||
        !FMInspectionHasExactPreparedStockEvidence(
            inspection, decision, confirmedSystemBuild)) {
        FMDeviceMountEngineFail(
            error, 7,
            @"The device no longer matches the verified prepared-Stock state.",
            inspectionError);
        return nil;
    }

    BOOL autoMountConflict = NO;
    if (!FMLegacyProviderAutoMountConflictsWithSystemFonts(
            &autoMountConflict, &inspectionError) || autoMountConflict) {
        FMDeviceMountEngineFail(
            error, 7,
            @"legacy Provider automatic mounting must not target Fonts during activation.",
            inspectionError);
        return nil;
    }
    BOOL mappingActive = [inspection[@"mapping"][@"active"] boolValue];

    NSString *stockPath = jbroot(FMMountRootfsFontsLogicalPath);
    if (!FMRequireReadOnlyStockDirectory(stockPath, error)) {
        return nil;
    }
    NSString *bootstrapRoot = FMPhysicalDirectoryPath(jbroot(@"/"), error);
    NSString *varLibrary = FMPhysicalDirectoryPath(jbroot(@"/var/lib"), error);
    NSString *mirrorLogicalPath = FMMountResolvedMirrorLogicalPath(NULL, NULL);
    NSString *mirrorPath = jbroot(mirrorLogicalPath);
    NSString *resolvedMirror = FMPhysicalDirectoryPath(mirrorPath, error);
    if (bootstrapRoot == nil || varLibrary == nil || resolvedMirror == nil ||
        [bootstrapRoot isEqualToString:@"/"] ||
        !FMPathIsWithinPhysicalRoot(resolvedMirror, bootstrapRoot) ||
        !FMRequireJBRootRoundTrip(mirrorLogicalPath, error) ||
        !FMValidateSecureDirectoryTree(
            bootstrapRoot,
            @[ @"bindfs", @"System", @"Library", @"Fonts" ],
            0, 0, error) ||
        !FMValidateSecureDirectoryTree(
            varLibrary,
            @[ @"fontmanager", @"baseline", confirmedSystemBuild ],
            0, 0, error) ||
        !FMValidateSecureDirectoryTree(
            varLibrary,
            @[ @"fontmanager", @"stock", confirmedSystemBuild ],
            0, 0, error)) {
        if (error != NULL && *error == nil) {
            FMDeviceMountEngineFail(
                error, 7, @"A prepared activation path is unsafe.", nil);
        }
        return nil;
    }

    struct stat stockInfo = {0};
    struct stat mirrorInfo = {0};
    if (lstat(stockPath.fileSystemRepresentation, &stockInfo) != 0 ||
        lstat(mirrorPath.fileSystemRepresentation, &mirrorInfo) != 0 ||
        !S_ISDIR(stockInfo.st_mode) || !S_ISDIR(mirrorInfo.st_mode) ||
        (stockInfo.st_dev == mirrorInfo.st_dev &&
         stockInfo.st_ino == mirrorInfo.st_ino) ||
        (stockInfo.st_mode & 07777) != (mirrorInfo.st_mode & 07777) ||
        stockInfo.st_uid != mirrorInfo.st_uid || stockInfo.st_gid != mirrorInfo.st_gid ||
        (mirrorInfo.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        FMDeviceMountEngineFail(
            error, 7, @"The prepared mirror root metadata is no longer safe.", nil);
        return nil;
    }

    NSString *mirrorStagingPath = [jbroot(@"/bindfs/System/Library")
        stringByAppendingPathComponent:FMMountStagingName];
    NSString *baselineRoot = jbroot(FMBaselineRootLogicalPath);
    NSString *baselineBuildPath =
        [baselineRoot stringByAppendingPathComponent:confirmedSystemBuild];
    NSString *baselineStagingPath = [baselineRoot
        stringByAppendingPathComponent:FMBaselineStagingName(confirmedSystemBuild)];
    NSString *stockSnapshotStagingPath = [jbroot(FMStockSnapshotRootLogicalPath)
        stringByAppendingPathComponent:FMBaselineStagingName(confirmedSystemBuild)];
    NSString *identityPath =
        [baselineBuildPath stringByAppendingPathComponent:@"identity.json"];
    NSString *manifestPath =
        [baselineBuildPath stringByAppendingPathComponent:@"manifest.json"];
    NSString *statePath = jbroot(FMStateLogicalPath);
    if (!FMRequireAbsentPath(mirrorStagingPath,
                             @"A mirror staging directory blocks activation.", error) ||
        !FMRequireAbsentPath(baselineStagingPath,
                             @"A baseline staging directory blocks activation.", error) ||
        !FMRequireAbsentPath(stockSnapshotStagingPath,
                             @"A Stock snapshot staging directory blocks activation.",
                             error) ||
        !FMRequireAbsentPath(statePath,
                             @"Persistent state appeared during activation preflight.", error) ||
        !FMRequireSecureRegularFile(identityPath, error) ||
        !FMRequireSecureRegularFile(manifestPath, error)) {
        return nil;
    }

    NSDictionary *identity = FMReadJSONObjectAtPath(identityPath, &inspectionError);
    NSDictionary *baselineManifest =
        FMReadJSONObjectAtPath(manifestPath, &inspectionError);
    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSDictionary *system = environment[@"system"];
    NSDictionary *backend = inspection[@"mountBackend"];
    NSDictionary *manifest = inspection[@"manifest"];
    if (identity == nil || baselineManifest == nil ||
        !FMValidateBaselineIdentity(identity, &inspectionError) ||
        !FMValidateManifestDocument(baselineManifest, &inspectionError) ||
        ![identity[@"productType"] isEqual:system[@"productType"]] ||
        ![identity[@"productVersion"] isEqual:system[@"productVersion"]] ||
        ![identity[@"productBuildVersion"] isEqual:confirmedSystemBuild] ||
        [baselineManifest[@"entries"] count] !=
            [manifest[@"stockEntryCount"] unsignedIntegerValue]) {
        FMDeviceMountEngineFail(
            error, 7, @"The prepared Stock baseline identity is invalid or stale.",
            inspectionError);
        return nil;
    }
    NSString *baselineManifestHash =
        FMSHA256ForFileAtPath(manifestPath, &inspectionError);
    if (baselineManifestHash == nil ||
        ![baselineManifestHash isEqual:manifest[@"stockManifestSHA256"]] ||
        ![baselineManifestHash isEqual:manifest[@"mirrorManifestSHA256"]]) {
        FMDeviceMountEngineFail(
            error, 7,
            @"The baseline, immutable Stock tree, and prepared mirror no longer agree.",
            inspectionError);
        return nil;
    }
    if (!mappingActive && !FMRequirePhysicalSystemTarget(error)) {
        return nil;
    }

    if (inspectionResult != NULL) {
        *inspectionResult = inspection;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"preflightPreparedStockMount",
        @"status" : @"eligible",
        @"systemBuild" : confirmedSystemBuild,
        @"mountBackendVersion" : backend[@"version"],
        @"baselineMountBackendVersion" :
            identity[@"mountBackendVersion"] ?: identity[@"providerVersion"],
        @"mountBackendRecognition" : backend[@"recognition"],
        @"mountBackendCompatibility" : backend[@"compatibility"],
        @"mirrorLogicalPath" : mirrorLogicalPath,
        @"stockEntryCount" : manifest[@"stockEntryCount"],
        @"baselineManifestSHA256" : baselineManifestHash,
        @"mappingAlreadyActive" : @(mappingActive),
        @"mountBackendWouldBeInvoked" : mappingActive ? @NO : @YES,
        @"readOnly" : @YES,
        @"mountBackendInvoked" : @NO,
        @"filesystemMutated" : @NO,
        @"mappingChanged" : @NO,
        @"stateCreated" : @NO,
        @"restartRequested" : @NO,
    };
}

NSDictionary<NSString *, id> *FMCreateDevicePreparedStockMountPreflight(
    NSString *confirmedSystemBuild,
    NSError **error) {
    return FMValidatedPreparedStockMountPreflight(
        confirmedSystemBuild, NULL, error);
}

static BOOL FMWriteInitialStockState(NSString *confirmedSystemBuild,
                                     NSError **error) {
    NSDictionary *state = @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"systemBuild" : confirmedSystemBuild,
        @"confirmedProfileID" : NSNull.null,
        @"workingProfileID" : NSNull.null,
        @"restartRequired" : @NO,
        @"refreshReason" : NSNull.null,
        @"mirrorState" : @"clean",
        @"autoMount" : @YES,
        @"autoRespring" : @NO,
    };
    NSError *stateError = nil;
    if (!FMValidateStateDocument(state, &stateError)) {
        return FMDeviceMountEngineFail(error, 8,
                                       @"The initial Stock state is invalid.",
                                       stateError);
    }
    NSString *varLibrary = FMPhysicalDirectoryPath(jbroot(@"/var/lib"), error);
    if (varLibrary == nil ||
        !FMValidateSecureDirectoryTree(varLibrary, @[ @"fontmanager" ],
                                       0, 0, error)) {
        return NO;
    }
    NSString *statePath = jbroot(FMStateLogicalPath);
    if (!FMRequireAbsentPath(statePath,
                             @"Persistent state appeared before publication.", error) ||
        !FMWriteJSONObjectAtomicallyIfAbsent(state, statePath, 0644, &stateError)) {
        return FMDeviceMountEngineFail(
            error, 8, @"The initial Stock state could not be atomically published.",
            stateError);
    }
    if (!FMRequireSecureRegularFile(statePath, &stateError)) {
        return FMDeviceMountEngineFail(
            error, 8, @"The published Stock state has unsafe metadata.", stateError);
    }
    NSDictionary *readback = FMReadJSONObjectAtPath(statePath, &stateError);
    if (![readback isEqual:state] ||
        !FMValidateStateDocument(readback, &stateError)) {
        return FMDeviceMountEngineFail(
            error, 8, @"The published Stock state failed readback verification.",
            stateError);
    }
    return YES;
}

static BOOL FMPostMountInspectionIsExactStock(
    NSDictionary<NSString *, id> *inspection,
    NSDictionary<NSString *, id> *decision,
    NSString *confirmedSystemBuild,
    NSString *baselineManifestHash) {
    NSDictionary *mapping = inspection[@"mapping"];
    NSDictionary *manifest = inspection[@"manifest"];
    NSDictionary *state = inspection[@"state"];
    return [inspection[@"systemBuild"] isEqual:confirmedSystemBuild] &&
        [decision[@"classification"] isEqual:@"adoptStockMirror"] &&
        [decision[@"issues"] count] == 0 &&
        [mapping[@"active"] boolValue] &&
        [mapping[@"targetMatches"] boolValue] &&
        [mapping[@"sourceMatchesMirror"] boolValue] &&
        [mapping[@"readOnly"] boolValue] &&
        [mapping[@"filesystemType"] isEqual:@"bindfs"] &&
        [manifest[@"scanState"] isEqual:@"complete"] &&
        [manifest[@"stockEntryCount"] isEqual:manifest[@"mirrorEntryCount"]] &&
        [manifest[@"stockManifestSHA256"] isEqual:baselineManifestHash] &&
        [manifest[@"mirrorManifestSHA256"] isEqual:baselineManifestHash] &&
        [manifest[@"changedPaths"] count] == 0 &&
        [manifest[@"missingPaths"] count] == 0 &&
        [manifest[@"unknownPaths"] count] == 0 &&
        [manifest[@"typeChangedPaths"] count] == 0 &&
        ![state[@"present"] boolValue];
}

NSDictionary<NSString *, id> *FMMountPreparedDeviceStock(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSDictionary *preInspection = nil;
    NSDictionary *preflight = FMValidatedPreparedStockMountPreflight(
        confirmedSystemBuild, &preInspection, error);
    if (preflight == nil || preInspection == nil) {
        return nil;
    }
    BOOL mappingAlreadyActive =
        [preInspection[@"mapping"][@"active"] boolValue];
    NSDictionary *backendReport = @{
        @"processStarted" : @NO,
        @"exitedNormally" : @NO,
        @"exitStatus" : NSNull.null,
        @"terminatingSignal" : NSNull.null,
        @"reportedSuccess" : @NO,
        @"mountBackendCompatibility" : preflight[@"mountBackendCompatibility"],
    };
    if (!mappingAlreadyActive) {
        NSError *backendError = nil;
        backendReport = FMInvokeMountBackendForPreparedSystemFonts(&backendError);
        if (backendReport == nil) {
            FMDeviceMountEngineFail(
                error, 9,
                @"The fixed mount backend activation operation could not complete.",
                backendError);
            return nil;
        }
    }

    NSError *postError = nil;
    BOOL autoMountConflict = NO;
    NSDictionary *postInspection = FMCreateDeviceMountInspection(&postError);
    NSDictionary *postDecision = postInspection != nil
        ? FMCoordinateMountInspection(postInspection, &postError)
        : nil;
    BOOL pathsValid =
        FMLegacyProviderAutoMountConflictsWithSystemFonts(
            &autoMountConflict, &postError) &&
        !autoMountConflict;
    if (!pathsValid || postInspection == nil || postDecision == nil ||
        !FMPostMountInspectionIsExactStock(
            postInspection, postDecision, confirmedSystemBuild,
            preflight[@"baselineManifestSHA256"])) {
        FMDeviceMountEngineFail(
            error, 9,
            @"mount backend activation did not produce the exact verified read-only mapping; no state was created.",
            postError);
        return nil;
    }

    if (!FMWriteInitialStockState(confirmedSystemBuild, error)) {
        return nil;
    }

    NSDictionary *finalInspection = FMCreateDeviceMountInspection(&postError);
    NSDictionary *finalDecision = finalInspection != nil
        ? FMCoordinateMountInspection(finalInspection, &postError)
        : nil;
    NSDictionary *finalManifest = finalInspection[@"manifest"];
    NSDictionary *finalState = finalInspection[@"state"];
    NSDictionary *status = FMCreateEnvironmentStatus();
    BOOL finalValid = finalInspection != nil && finalDecision != nil &&
        [finalDecision[@"classification"] isEqual:@"managedReady"] &&
        [finalDecision[@"issues"] count] == 0 &&
        [finalManifest[@"matchesWorkingProfile"] boolValue] &&
        [finalManifest[@"stockManifestSHA256"]
            isEqual:preflight[@"baselineManifestSHA256"]] &&
        [finalManifest[@"mirrorManifestSHA256"]
            isEqual:preflight[@"baselineManifestSHA256"]] &&
        [finalState[@"present"] boolValue] &&
        [finalState[@"valid"] boolValue] &&
        [finalState[@"systemBuild"] isEqual:confirmedSystemBuild] &&
        [finalState[@"mirrorState"] isEqual:@"clean"] &&
        finalState[@"workingProfileID"] == NSNull.null &&
        [status[@"engineState"] isEqual:@"ready"];
    if (!finalValid) {
        FMDeviceMountEngineFail(
            error, 10,
            @"The activated Stock mapping or persistent state failed final verification.",
            postError);
        return nil;
    }

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"mountPreparedStock",
        @"status" : @"managedReady",
        @"systemBuild" : confirmedSystemBuild,
        @"mirrorLogicalPath" : preflight[@"mirrorLogicalPath"],
        @"baselineManifestSHA256" : preflight[@"baselineManifestSHA256"],
        @"stockEntryCount" : finalManifest[@"stockEntryCount"],
        @"mountBackendInvoked" : mappingAlreadyActive ? @NO : @YES,
        @"mountBackendVersion" : finalInspection[@"mountBackend"][@"version"],
        @"baselineMountBackendVersion" :
            preflight[@"baselineMountBackendVersion"],
        @"mountBackendRecognition" : preflight[@"mountBackendRecognition"],
        @"mountBackendCompatibility" : preflight[@"mountBackendCompatibility"],
        @"mountBackendReportedSuccess" : backendReport[@"reportedSuccess"],
        @"mountBackendExitStatus" : backendReport[@"exitStatus"],
        @"mappingChanged" : mappingAlreadyActive ? @NO : @YES,
        @"mappingActive" : @YES,
        @"mappingReadOnly" : @YES,
        @"stateCreated" : @YES,
        @"restartRequested" : @NO,
        @"recoveryMode" : @(mappingAlreadyActive),
    };
}
