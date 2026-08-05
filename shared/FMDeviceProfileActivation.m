#import "FMDeviceProfileActivation.h"

#import <errno.h>
#import <limits.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMEnvironmentProbe.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMProfileAdoptionValidator.h"
#import "FMMountPaths.h"

NSString *const FMDeviceProfileActivationErrorDomain =
    @"com.hmmzzz.fontmanager.device-profile-activation";

typedef NS_ENUM(NSInteger, FMDeviceProfileActivationErrorCode) {
    FMDeviceProfileActivationErrorInvalidInput = 1,
    FMDeviceProfileActivationErrorPrivilege = 2,
    FMDeviceProfileActivationErrorEnvironment = 3,
    FMDeviceProfileActivationErrorProfile = 4,
    FMDeviceProfileActivationErrorCapacity = 5,
};

static BOOL FMDeviceProfileFail(NSError **error,
                                FMDeviceProfileActivationErrorCode code,
                                NSString *description,
                                NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMDeviceProfileActivationErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMDeviceProfileIDIsSafe(NSString *profileID) {
    if (![profileID isKindOfClass:NSString.class] ||
        ![profileID hasPrefix:@"import-"]) {
        return NO;
    }
    NSDictionary *probe = @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"id" : profileID,
        @"name" : @"Profile",
        @"systemBuild" : @"BUILD",
        @"replacements" : @[],
    };
    return FMValidateProfileDocument(probe, nil);
}

static BOOL FMRequireOwnedPath(NSString *path,
                               BOOL directory,
                               uid_t owner,
                               gid_t group,
                               mode_t permissions,
                               NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        (directory ? !S_ISDIR(info.st_mode) : !S_ISREG(info.st_mode)) ||
        info.st_uid != owner || info.st_gid != group ||
        (info.st_mode & 0777) != permissions) {
        NSError *underlying = errno != 0
            ? [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]
            : nil;
        return FMDeviceProfileFail(
            error, FMDeviceProfileActivationErrorProfile,
            @"An App-owned Profile path has unexpected type, ownership, or permissions.",
            underlying);
    }
    return YES;
}

static BOOL FMRequireRootRecord(NSString *path, NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        NSError *underlying = errno != 0
            ? [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]
            : nil;
        return FMDeviceProfileFail(
            error, FMDeviceProfileActivationErrorEnvironment,
            @"The saved Stock baseline record has unsafe metadata.", underlying);
    }
    return YES;
}

static BOOL FMRequireAbsent(NSString *path, NSError **error) {
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        return FMDeviceProfileFail(
            error, FMDeviceProfileActivationErrorProfile,
            @"A privileged Profile or staging path already exists for this identifier.", nil);
    }
    if (errno != ENOENT) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMDeviceProfileFail(
            error, FMDeviceProfileActivationErrorEnvironment,
            @"A privileged Profile path could not be inspected.", underlying);
    }
    return YES;
}

NSDictionary<NSString *, id> *FMCreateDeviceProfileActivationPreflight(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSError **error) {
    if (geteuid() != 0) {
        FMDeviceProfileFail(error, FMDeviceProfileActivationErrorPrivilege,
                            @"Profile activation preflight requires effective uid 0.", nil);
        return nil;
    }
    if (confirmedSystemBuild.length == 0 || confirmedSystemBuild.length > 32 ||
        confirmedSystemBuild.pathComponents.count != 1 ||
        !FMDeviceProfileIDIsSafe(profileID)) {
        FMDeviceProfileFail(error, FMDeviceProfileActivationErrorInvalidInput,
                            @"The confirmed build or Profile identifier is invalid.", nil);
        return nil;
    }

    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSDictionary *environmentState = environment[@"state"];
    if (![environment[@"engineState"] isEqual:@"ready"] ||
        ![environment[@"system"][@"productBuildVersion"]
            isEqual:confirmedSystemBuild] ||
        ![environmentState[@"present"] boolValue] ||
        ![environmentState[@"valid"] boolValue] ||
        ![environmentState[@"systemBuild"] isEqual:confirmedSystemBuild] ||
        ![environmentState[@"mirrorState"] isEqual:@"clean"] ||
        !FMMountManagedMappingIsActive(error)) {
        FMDeviceProfileFail(
            error, FMDeviceProfileActivationErrorEnvironment,
            @"The managed font workspace is unavailable.",
            error != NULL ? *error : nil);
        return nil;
    }

    NSString *baselineDirectory = [[jbroot(@"/var/lib/fontmanager/baseline")
        stringByAppendingPathComponent:confirmedSystemBuild] copy];
    NSString *manifestPath =
        [baselineDirectory stringByAppendingPathComponent:@"manifest.json"];
    if (!FMRequireRootRecord(manifestPath, error)) return nil;

    NSError *baselineError = nil;
    NSDictionary *baselineManifest = FMReadJSONObjectAtPath(manifestPath, &baselineError);
    NSString *baselineHash = baselineManifest != nil &&
            FMValidateManifestDocument(baselineManifest, &baselineError)
        ? FMSHA256ForJSONObject(baselineManifest, &baselineError)
        : nil;
    if (baselineHash.length == 0) {
        FMDeviceProfileFail(error, FMDeviceProfileActivationErrorEnvironment,
                            @"The saved Stock baseline is invalid.",
                            baselineError);
        return nil;
    }
    NSDictionary *catalog = FMCreateFontCatalogFromManifest(
        baselineManifest, confirmedSystemBuild, baselineHash, &baselineError);
    if (catalog == nil) {
        FMDeviceProfileFail(error, FMDeviceProfileActivationErrorEnvironment,
                            @"The current-build font catalog could not be generated.",
                            baselineError);
        return nil;
    }

    NSString *libraryBase = FMMountResolvedMobileDataPath(
        @"/var/mobile/Library/Application Support/com.hmmzzz.fontmanager");
    NSString *profileLibrary = [libraryBase stringByAppendingPathComponent:@"ProfileLibrary"];
    NSString *buildLibrary =
        [profileLibrary stringByAppendingPathComponent:confirmedSystemBuild];
    NSString *profilesRoot = [buildLibrary stringByAppendingPathComponent:@"profiles"];
    NSString *profileDirectory = [profilesRoot stringByAppendingPathComponent:profileID];
    NSString *replacementsDirectory =
        [profileDirectory stringByAppendingPathComponent:@"replacements"];
    for (NSString *directory in @[
             libraryBase, profileLibrary, buildLibrary, profilesRoot,
             profileDirectory, replacementsDirectory
         ]) {
        if (!FMRequireOwnedPath(directory, YES, 501, 501, 0700, error)) return nil;
    }

    NSDictionary *preview = FMCreateProfileAdoptionPreviewAtRoot(
        profilesRoot, profileID, confirmedSystemBuild, catalog, &baselineError);
    if (preview == nil) {
        FMDeviceProfileFail(error, FMDeviceProfileActivationErrorProfile,
                            @"The imported Profile failed read-only adoption validation.",
                            baselineError);
        return nil;
    }
    if (!FMRequireOwnedPath(preview[@"profilePath"], NO, 501, 501, 0600, error)) {
        return nil;
    }
    for (NSString *fileName in preview[@"replacementFileNames"]) {
        NSString *path = [replacementsDirectory stringByAppendingPathComponent:fileName];
        if (!FMRequireOwnedPath(path, NO, 501, 501, 0600, error)) return nil;
    }

    NSString *privilegedProfilesRoot = jbroot(@"/var/lib/fontmanager/profiles");
    NSString *privilegedProfile =
        [privilegedProfilesRoot stringByAppendingPathComponent:profileID];
    NSString *privilegedStaging = [privilegedProfilesRoot
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.fontmanager-staging", profileID]];
    if (!FMRequireAbsent(privilegedStaging, error)) {
        return nil;
    }
    BOOL privilegedProfilePresent = NO;
    struct stat privilegedInfo = {0};
    errno = 0;
    if (lstat(privilegedProfile.fileSystemRepresentation, &privilegedInfo) == 0) {
        privilegedProfilePresent = YES;
        NSDictionary *privilegedPreview = S_ISDIR(privilegedInfo.st_mode)
            ? FMCreateProfileAdoptionPreviewAtRoot(
                privilegedProfilesRoot, profileID, confirmedSystemBuild, catalog,
                &baselineError)
            : nil;
        BOOL privilegedMatches = privilegedPreview != nil &&
            [privilegedPreview[@"profileJSONSHA256"]
                isEqual:preview[@"profileJSONSHA256"]] &&
            [privilegedPreview[@"targets"] isEqual:preview[@"targets"]] &&
            FMRequireOwnedPath(privilegedProfilesRoot, YES, 0, 0, 0755, error) &&
            FMRequireOwnedPath(privilegedProfile, YES, 0, 0, 0700, error) &&
            FMRequireOwnedPath(privilegedPreview[@"replacementsDirectory"],
                               YES, 0, 0, 0700, error) &&
            FMRequireOwnedPath(privilegedPreview[@"profilePath"], NO, 0, 0, 0600,
                               error);
        if (privilegedMatches) {
            for (NSString *fileName in privilegedPreview[@"replacementFileNames"]) {
                NSString *path = [privilegedPreview[@"replacementsDirectory"]
                    stringByAppendingPathComponent:fileName];
                if (!FMRequireOwnedPath(path, NO, 0, 0, 0600, error)) {
                    privilegedMatches = NO;
                    break;
                }
            }
        }
        if (!privilegedMatches) {
            if (error != NULL && *error == nil) {
                FMDeviceProfileFail(
                    error, FMDeviceProfileActivationErrorProfile,
                    @"The privileged Profile does not exactly match the imported source.",
                    baselineError);
            }
            return nil;
        }
    } else if (errno != ENOENT) {
        FMDeviceProfileFail(error, FMDeviceProfileActivationErrorEnvironment,
                            @"The privileged Profile path could not be inspected.",
                            [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno
                                            userInfo:nil]);
        return nil;
    }

    NSString *persistentRoot = jbroot(@"/var/lib/fontmanager");
    struct statfs filesystem = {0};
    if (statfs(persistentRoot.fileSystemRepresentation, &filesystem) != 0 ||
        (filesystem.f_flags & MNT_RDONLY) != 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        FMDeviceProfileFail(error, FMDeviceProfileActivationErrorCapacity,
                            @"The privileged Profile filesystem is unavailable or read-only.",
                            underlying);
        return nil;
    }
    unsigned long long availableBytes =
        (unsigned long long)filesystem.f_bavail * (unsigned long long)filesystem.f_bsize;
    unsigned long long replacementBytes = [preview[@"replacementBytes"] unsignedLongLongValue];
    unsigned long long reserve = 64ULL * 1024ULL * 1024ULL;
    if (!privilegedProfilePresent &&
        (replacementBytes > ULLONG_MAX - reserve ||
         availableBytes < replacementBytes + reserve)) {
        FMDeviceProfileFail(error, FMDeviceProfileActivationErrorCapacity,
                            @"There is not enough safe free space to adopt this Profile.", nil);
        return nil;
    }

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"preflightProfileActivation",
        @"status" : @"eligible",
        @"systemBuild" : confirmedSystemBuild,
        @"profileID" : profileID,
        @"profileName" : preview[@"profileName"],
        @"profileJSONSHA256" : preview[@"profileJSONSHA256"],
        @"replacementCount" : preview[@"replacementCount"],
        @"replacementBytes" : preview[@"replacementBytes"],
        @"relativePaths" : preview[@"relativePaths"],
        @"targets" : preview[@"targets"],
        @"catalogFileCount" : @([catalog[@"files"] count]),
        @"baselineManifestSHA256" : baselineHash,
        @"availableBytes" : @(availableBytes),
        @"currentWorkingProfileID" : NSNull.null,
        @"currentConfirmedProfileID" : NSNull.null,
        @"mappingActive" : @YES,
        @"mappingReadOnly" : @YES,
        @"sourceLibraryValidated" : @YES,
        @"privilegedProfilePresent" : privilegedProfilePresent ? @YES : @NO,
        @"profileAlreadyAdopted" : privilegedProfilePresent ? @YES : @NO,
        @"readOnly" : @YES,
        @"filesystemMutated" : @NO,
        @"profileAdopted" : @NO,
        @"mirrorChanged" : @NO,
        @"stateChanged" : @NO,
        @"mountBackendInvoked" : @NO,
        @"restartRequested" : @NO,
    };
}
