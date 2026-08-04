#import "FMEnvironmentProbe.h"

#import <TargetConditionals.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMMountBackendCompatibility.h"
#import "FMMountBackendExecutor.h"
#import "FMMountPaths.h"
#import "FMStatusContract.h"

static NSString *const FMStateLogicalPath = @"/var/lib/fontmanager/state.json";
static NSString *const FMRespringExecutableLogicalPath = @"/usr/bin/sbreload";

static id FMNullUnlessString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : NSNull.null;
}

static void FMAddIssue(NSMutableArray<NSString *> *issues, NSString *issue) {
    if (![issues containsObject:issue]) {
        [issues addObject:issue];
    }
}

static NSString *FMHardwareMachine(void) {
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) {
        return @"unknown";
    }

    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (sysctlbyname("hw.machine", buffer.mutableBytes, &size, NULL, 0) != 0) {
        return @"unknown";
    }

    NSString *machine = [NSString stringWithUTF8String:buffer.bytes];
    return machine.length > 0 ? machine : @"unknown";
}

static NSDictionary<NSString *, NSString *> *FMSystemIdentity(void) {
    NSDictionary *version = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    NSString *productVersion = [version[@"ProductVersion"] isKindOfClass:NSString.class]
                                   ? version[@"ProductVersion"]
                                   : @"unknown";
    NSString *productBuildVersion = [version[@"ProductBuildVersion"] isKindOfClass:NSString.class]
                                        ? version[@"ProductBuildVersion"]
                                        : @"unknown";
#if TARGET_OS_SIMULATOR
    NSString *environment = @"simulator";
#else
    NSString *environment = @"device";
#endif
    return @{
        @"productType" : FMHardwareMachine(),
        @"productVersion" : productVersion,
        @"productBuildVersion" : productBuildVersion,
        @"environment" : environment,
    };
}

static BOOL FMReadableDirectoryAtPath(NSString *path) {
    BOOL isDirectory = NO;
    BOOL pathExists = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory];
    return pathExists && isDirectory && access(path.fileSystemRepresentation, R_OK) == 0;
}

static BOOL FMSecureRootExecutableAtPath(NSString *path) {
    struct stat info = {0};
    return lstat(path.fileSystemRepresentation, &info) == 0 &&
        S_ISREG(info.st_mode) && info.st_uid == 0 &&
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 &&
        (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
}

static BOOL FMSecureRootRegularFileAtPath(NSString *path) {
    struct stat info = {0};
    return lstat(path.fileSystemRepresentation, &info) == 0 &&
        S_ISREG(info.st_mode) && info.st_uid == 0 &&
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static NSDictionary<NSString *, id> *FMReadPersistentState(NSString *systemBuild,
                                                            NSMutableArray<NSString *> *issues) {
    NSString *statePath = jbroot(FMStateLogicalPath);
    BOOL stateExists = [NSFileManager.defaultManager fileExistsAtPath:statePath];
    NSDictionary *emptyState = @{
        @"present" : @NO,
        @"valid" : @NO,
        @"schemaVersion" : NSNull.null,
        @"systemBuild" : NSNull.null,
        @"confirmedProfileID" : NSNull.null,
        @"workingProfileID" : NSNull.null,
        @"restartRequired" : @NO,
        @"refreshReason" : NSNull.null,
        @"autoMount" : @NO,
        @"autoRespring" : @NO,
        @"mirrorState" : @"unknown",
    };
    if (!stateExists) {
        FMAddIssue(issues, @"state.notInitialized");
        return emptyState;
    }

    NSData *data = [NSData dataWithContentsOfFile:statePath];
    NSError *jsonError = nil;
    id object = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
    if (![object isKindOfClass:NSDictionary.class]) {
        FMAddIssue(issues, @"state.invalid");
        return @{
            @"present" : @YES,
            @"valid" : @NO,
            @"schemaVersion" : NSNull.null,
            @"systemBuild" : NSNull.null,
            @"confirmedProfileID" : NSNull.null,
            @"workingProfileID" : NSNull.null,
            @"restartRequired" : @NO,
            @"refreshReason" : NSNull.null,
            @"autoMount" : @NO,
            @"autoRespring" : @NO,
            @"mirrorState" : @"unknown",
        };
    }

    NSDictionary *raw = object;
    NSNumber *schemaVersion = raw[@"schemaVersion"];
    NSString *stateBuild = raw[@"systemBuild"];
    id confirmedProfileID = raw[@"confirmedProfileID"] ?: NSNull.null;
    id workingProfileID = raw[@"workingProfileID"] ?: NSNull.null;
    NSNumber *restartRequired = raw[@"restartRequired"];
    id refreshReason = raw[@"refreshReason"];
    NSNumber *autoMount = raw[@"autoMount"];
    NSNumber *autoRespring = raw[@"autoRespring"];
    NSString *mirrorState = raw[@"mirrorState"];
    NSError *stateValidationError = nil;
    BOOL valid = FMValidateStateDocument(raw, &stateValidationError);

    if (valid && ![stateBuild isEqualToString:systemBuild]) {
        valid = NO;
        FMAddIssue(issues, @"state.systemBuildMismatch");
    } else if (!valid) {
        FMAddIssue(issues, @"state.invalid");
    }

    return @{
        @"present" : @YES,
        @"valid" : @(valid),
        @"schemaVersion" : [schemaVersion isKindOfClass:NSNumber.class]
            ? schemaVersion.stringValue
            : NSNull.null,
        @"systemBuild" : FMNullUnlessString(stateBuild),
        @"confirmedProfileID" : valid ? confirmedProfileID : NSNull.null,
        @"workingProfileID" : valid ? workingProfileID : NSNull.null,
        @"restartRequired" : [restartRequired isKindOfClass:NSNumber.class] ? restartRequired : @NO,
        @"refreshReason" : valid && [refreshReason isKindOfClass:NSString.class]
            ? refreshReason : NSNull.null,
        @"autoMount" : valid ? autoMount : @NO,
        @"autoRespring" : valid && [autoRespring isKindOfClass:NSNumber.class]
            ? autoRespring : @NO,
        @"mirrorState" : [mirrorState isKindOfClass:NSString.class] ? mirrorState : @"unknown",
    };
}

NSDictionary<NSString *, id> *FMCreateEnvironmentStatus(void) {
    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    NSDictionary<NSString *, NSString *> *system = FMSystemIdentity();

    NSString *backendExecutablePath =
        jbroot(FMMountBackendExecutableLogicalPath);
    BOOL backendExecutablePresent =
        [NSFileManager.defaultManager isExecutableFileAtPath:backendExecutablePath];
    NSError *backendCompatibilityError = nil;
    NSDictionary *backendCompatibility =
        FMInspectMountBackendCompatibilityAtPath(
            backendExecutablePath, &backendCompatibilityError);
    if (backendCompatibility == nil) {
        backendCompatibility = @{
            @"contractVersion" : @(FMMountBackendCapabilityContractVersion),
            @"compatibility" : @"incompatible",
            @"compatible" : @NO,
            @"executablePresent" : @NO,
            @"executableSecure" : @NO,
            @"machOExecutable" : @NO,
            @"supportsReadOnlyMount" : @NO,
            @"supportsForceUnmount" : @NO,
        };
    }
    NSString *runtimeLibraryPath =
        jbroot(FMMountBackendRuntimeLibraryLogicalPath);
    BOOL runtimeLibraryPresent =
        [NSFileManager.defaultManager fileExistsAtPath:runtimeLibraryPath];
    BOOL runtimeLibrarySecure =
        FMSecureRootRegularFileAtPath(runtimeLibraryPath);

    BOOL mountStorageSupported = NO;
    BOOL legacyProviderPreferencePresent = NO;
    NSString *mirrorLogicalPath =
        FMMountResolvedMirrorLogicalPath(&mountStorageSupported,
                                            &legacyProviderPreferencePresent);
    NSError *legacyProviderPreferenceError = nil;
    NSDictionary *legacyProviderAutoMount =
        FMLegacyProviderAutoMountConfiguration(&legacyProviderPreferenceError);
    BOOL legacyProviderAutoMountConflictsWithFonts = legacyProviderAutoMount == nil ||
        [legacyProviderAutoMount[@"conflictsWithFonts"] boolValue];
    BOOL systemReadable = FMReadableDirectoryAtPath(FMMountSystemFontsLogicalPath);
    BOOL rootfsReadable =
        FMReadableDirectoryAtPath(jbroot(FMMountRootfsFontsLogicalPath));
    BOOL mirrorReadable = mountStorageSupported &&
        FMReadableDirectoryAtPath(jbroot(mirrorLogicalPath));
    BOOL backendCompatible = backendExecutablePresent &&
        [backendCompatibility[@"compatible"] boolValue] &&
        runtimeLibraryPresent && runtimeLibrarySecure &&
        mountStorageSupported && !legacyProviderAutoMountConflictsWithFonts;

    struct statfs filesystem = {0};
    BOOL statfsAvailable =
        statfs(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
               &filesystem) == 0;
    NSString *filesystemType = statfsAvailable
                                   ? [NSString stringWithUTF8String:filesystem.f_fstypename]
                                   : nil;
    BOOL mappingActive = filesystemType != nil &&
                         [filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame;
    NSString *mappingTarget = statfsAvailable
        ? [NSString stringWithUTF8String:filesystem.f_mntonname]
        : nil;
    NSString *mappingSource = statfsAvailable
        ? [NSString stringWithUTF8String:filesystem.f_mntfromname]
        : nil;
    NSString *mirrorPath = mountStorageSupported ? jbroot(mirrorLogicalPath) : nil;
    BOOL mappingManaged = mappingActive &&
        [mappingTarget isEqual:FMMountSystemFontsLogicalPath] &&
        [mappingSource.stringByResolvingSymlinksInPath
            isEqual:mirrorPath.stringByResolvingSymlinksInPath] &&
        (filesystem.f_flags & MNT_RDONLY) != 0;

    if (!systemReadable) {
        FMAddIssue(issues, @"fonts.systemDirectoryUnavailable");
    }
    if (!rootfsReadable) {
        FMAddIssue(issues, @"fonts.rootfsDirectoryUnavailable");
    }
    if (!backendExecutablePresent) {
        FMAddIssue(issues, @"mountBackend.executableMissing");
    } else if (![backendCompatibility[@"compatible"] boolValue]) {
        FMAddIssue(issues, @"mountBackend.capabilityContractMismatch");
    }
    if (!runtimeLibraryPresent || !runtimeLibrarySecure) {
        FMAddIssue(issues, @"mountBackend.runtimeUnavailable");
    }
    if (!mountStorageSupported) {
        FMAddIssue(issues, @"mountStorage.unavailable");
    }
    if (legacyProviderPreferenceError != nil) {
        FMAddIssue(issues, @"legacyProvider.preferenceInvalid");
    } else if (legacyProviderAutoMountConflictsWithFonts) {
        FMAddIssue(issues, @"legacyProvider.fontsAutoMountConflict");
    }

    NSDictionary<NSString *, id> *state =
        FMReadPersistentState(system[@"productBuildVersion"], issues);
    NSString *stockSnapshotPath = [jbroot(@"/var/lib/fontmanager/stock")
        stringByAppendingPathComponent:system[@"productBuildVersion"]];
    BOOL stockSnapshotPresent = FMReadableDirectoryAtPath(stockSnapshotPath);
    BOOL respringExecutableSecure = FMSecureRootExecutableAtPath(
        jbroot(FMRespringExecutableLogicalPath));
    BOOL statePresent = [state[@"present"] boolValue];
    BOOL stateValid = [state[@"valid"] boolValue];

    if (!statePresent && (mirrorReadable || mappingActive)) {
        FMAddIssue(issues, @"mirror.existingUnmanagedContent");
    }
    if (statePresent && stateValid && ![state[@"mirrorState"] isEqual:@"clean"]) {
        FMAddIssue(issues, @"state.repairRequired");
    }
    if (statePresent && stateValid && !mirrorReadable) {
        FMAddIssue(issues, @"mirror.missing");
    }
    if (statePresent && stateValid && !mappingManaged) {
        FMAddIssue(issues, mappingActive ? @"mapping.unmanaged" : @"mapping.inactive");
    }

    NSDictionary<NSString *, id> *backendFacts = @{
        @"executablePresent" : @(backendExecutablePresent),
        @"compatible" : @(backendCompatible),
    };
    NSDictionary<NSString *, id> *fontFacts = @{
        @"systemDirectoryReadable" : @(systemReadable),
        @"rootfsDirectoryReadable" : @(rootfsReadable),
        @"mirrorPresent" : @(mirrorReadable),
        @"mappingActive" : @(mappingManaged),
    };
    NSString *engineState = FMEngineStateForFacts(backendFacts, fontFacts, state);
    BOOL canStageSelection = [engineState isEqual:@"ready"] &&
        stockSnapshotPresent && statePresent && stateValid &&
        ![state[@"restartRequired"] boolValue];

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;

    NSDictionary<NSString *, id> *document = @{
        @"apiVersion" : @(FMStatusAPIVersion),
        @"mode" : @"readOnlyFoundation",
        @"generatedAt" : [formatter stringFromDate:NSDate.date],
        @"engineState" : engineState,
        @"system" : system,
        @"mountBackend" : @{
            @"identifier" : FMMountBackendIdentifier,
            @"version" : FMMountBackendVersion,
            @"executablePresent" : @(backendExecutablePresent),
            @"executableLogicalPath" : FMMountBackendExecutableLogicalPath,
            @"runtimeLibraryLogicalPath" :
                FMMountBackendRuntimeLibraryLogicalPath,
            @"runtimeLibraryPresent" : @(runtimeLibraryPresent),
            @"runtimeLibrarySecure" : @(runtimeLibrarySecure),
            @"contractVersion" : backendCompatibility[@"contractVersion"],
            @"recognition" : FMMountBackendRecognitionForVersion(
                FMMountBackendVersion),
            @"compatibility" : backendCompatible
                ? @"compatible" : @"incompatible",
            @"compatible" : @(backendCompatible),
            @"executableSecure" : backendCompatibility[@"executableSecure"],
            @"machOExecutable" : backendCompatibility[@"machOExecutable"],
            @"supportsReadOnlyMount" :
                backendCompatibility[@"supportsReadOnlyMount"],
            @"supportsForceUnmount" :
                backendCompatibility[@"supportsForceUnmount"],
        },
        @"fonts" : @{
            @"systemTargetLogicalPath" : FMMountSystemFontsLogicalPath,
            @"rootfsLogicalPath" : FMMountRootfsFontsLogicalPath,
            @"mirrorLogicalPath" : mirrorLogicalPath,
            @"systemDirectoryReadable" : @(systemReadable),
            @"rootfsDirectoryReadable" : @(rootfsReadable),
            @"mountStorageSupported" : @(mountStorageSupported),
            @"mountStorageShared" : @YES,
            @"legacyProviderPreferencePresent" : @(legacyProviderPreferencePresent),
            @"legacyProviderAutoMountConflictsWithFonts" :
                @(legacyProviderAutoMountConflictsWithFonts),
            @"mirrorPresent" : @(mirrorReadable),
            @"mappingActive" : @(mappingActive),
            @"mappingManaged" : @(mappingManaged),
            @"stockSnapshotPresent" : @(stockSnapshotPresent),
            @"targetFilesystemType" : FMNullUnlessString(filesystemType),
        },
        @"state" : state,
        @"capabilities" : @{
            @"readOnlyStatus" : @YES,
            @"initializeMirror" : @NO,
            @"stageProfile" : canStageSelection ? @YES : @NO,
            @"stageStock" : canStageSelection ? @YES : @NO,
            @"repair" : @NO,
            @"safeUnmount" : @NO,
            @"respring" : respringExecutableSecure ? @YES : @NO,
            @"userspaceReboot" : stockSnapshotPresent && backendCompatible
                ? @YES : @NO,
        },
        @"issues" : issues,
    };

    NSError *contractError = nil;
    if (!FMValidateStatusDocument(document, &contractError)) {
        return @{
            @"apiVersion" : @(FMStatusAPIVersion),
            @"mode" : @"readOnlyFoundation",
            @"generatedAt" : [formatter stringFromDate:NSDate.date],
            @"engineState" : @"unavailable",
            @"system" : system,
            @"mountBackend" : @{
                @"identifier" : FMMountBackendIdentifier,
                @"version" : FMMountBackendVersion,
                @"executablePresent" : @NO,
                @"executableLogicalPath" :
                    FMMountBackendExecutableLogicalPath,
                @"runtimeLibraryLogicalPath" :
                    FMMountBackendRuntimeLibraryLogicalPath,
                @"runtimeLibraryPresent" : @NO,
                @"runtimeLibrarySecure" : @NO,
                @"contractVersion" :
                    @(FMMountBackendCapabilityContractVersion),
                @"recognition" : @"unknown",
                @"compatibility" : @"incompatible",
                @"compatible" : @NO,
                @"executableSecure" : @NO,
                @"machOExecutable" : @NO,
                @"supportsReadOnlyMount" : @NO,
                @"supportsForceUnmount" : @NO,
            },
            @"fonts" : @{
                @"systemDirectoryReadable" : @NO,
                @"rootfsDirectoryReadable" : @NO,
                @"mountStorageSupported" : @NO,
                @"mountStorageShared" : @YES,
                @"legacyProviderPreferencePresent" : @NO,
                @"legacyProviderAutoMountConflictsWithFonts" : @NO,
                @"mirrorPresent" : @NO,
                @"mappingActive" : @NO,
                @"mappingManaged" : @NO,
                @"stockSnapshotPresent" : @NO,
                @"targetFilesystemType" : NSNull.null,
            },
            @"state" : @{
                @"present" : @NO,
                @"valid" : @NO,
                @"schemaVersion" : NSNull.null,
                @"systemBuild" : NSNull.null,
                @"confirmedProfileID" : NSNull.null,
                @"workingProfileID" : NSNull.null,
                @"restartRequired" : @NO,
                @"refreshReason" : NSNull.null,
                @"autoMount" : @NO,
                @"autoRespring" : @NO,
                @"mirrorState" : @"unknown",
            },
            @"capabilities" : @{
                @"readOnlyStatus" : @YES,
                @"initializeMirror" : @NO,
                @"stageProfile" : @NO,
                @"stageStock" : @NO,
                @"repair" : @NO,
                @"safeUnmount" : @NO,
                @"respring" : @NO,
                @"userspaceReboot" : @NO,
            },
            @"issues" : @[ @"status.internalContractFailure" ],
        };
    }
    return document;
}
