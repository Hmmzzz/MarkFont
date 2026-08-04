#import "FMEnvironmentProbe.h"

#import <TargetConditionals.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMProviderCompatibility.h"
#import "FMProviderPaths.h"
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

static BOOL FMPathIsSymbolicLink(NSString *path) {
    struct stat info = {0};
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISLNK(info.st_mode);
}

static BOOL FMSecureRootExecutableAtPath(NSString *path) {
    struct stat info = {0};
    return lstat(path.fileSystemRepresentation, &info) == 0 &&
        S_ISREG(info.st_mode) && info.st_uid == 0 &&
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 &&
        (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
}

static NSDictionary<NSString *, NSString *> *FMParseDebianStanza(NSString *stanza) {
    NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
    for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
        NSRange separator = [line rangeOfString:@":"];
        if (separator.location == NSNotFound || separator.location == 0) {
            continue;
        }
        NSString *key = [line substringToIndex:separator.location];
        NSString *value = [[line substringFromIndex:separator.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (key.length > 0 && value.length > 0) {
            fields[key] = value;
        }
    }
    return fields;
}

static NSDictionary<NSString *, id> *FMProviderPackageMetadata(void) {
    NSArray<NSString *> *logicalStatusPaths = @[ @"/var/lib/dpkg/status", @"/Library/dpkg/status" ];
    for (NSString *logicalPath in logicalStatusPaths) {
        NSString *resolvedPath = jbroot(logicalPath);
        NSData *data = [NSData dataWithContentsOfFile:resolvedPath];
        if (data.length == 0) {
            continue;
        }

        NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (contents == nil) {
            contents = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }
        contents = [contents stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];

        for (NSString *stanza in [contents componentsSeparatedByString:@"\n\n"]) {
            NSDictionary<NSString *, NSString *> *fields = FMParseDebianStanza(stanza);
            if (![fields[@"Package"] isEqualToString:FMProviderPackageIdentifier]) {
                continue;
            }
            BOOL installed = [fields[@"Status"] isEqualToString:@"install ok installed"];
            return @{
                @"installed" : @(installed),
                @"version" : FMNullUnlessString(fields[@"Version"]),
                @"architecture" : FMNullUnlessString(fields[@"Architecture"]),
            };
        }
    }

    return @{
        @"installed" : @NO,
        @"version" : NSNull.null,
        @"architecture" : NSNull.null,
    };
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

    NSString *providerExecutablePath = jbroot(FMProviderExecutableLogicalPath);
    BOOL providerExecutablePresent =
        [NSFileManager.defaultManager isExecutableFileAtPath:providerExecutablePath];
    NSError *providerCompatibilityError = nil;
    NSDictionary *providerCompatibility =
        FMInspectProviderExecutableCompatibilityAtPath(
            providerExecutablePath, &providerCompatibilityError);
    if (providerCompatibility == nil) {
        providerCompatibility = @{
            @"contractVersion" : @(FMProviderCapabilityContractVersion),
            @"compatibility" : @"incompatible",
            @"compatible" : @NO,
            @"executableSecure" : @NO,
            @"boundedTextWrapper" : @NO,
            @"shellWrapper" : @NO,
            @"supportsSkipCopy" : @NO,
            @"supportsUnmount" : @NO,
        };
    }
    NSDictionary<NSString *, id> *packageMetadata = FMProviderPackageMetadata();
    BOOL packageInstalled = [packageMetadata[@"installed"] boolValue];

    BOOL providerRootSupported = NO;
    BOOL providerPreferencePresent = NO;
    NSString *mirrorLogicalPath =
        FMProviderResolvedMirrorLogicalPath(&providerRootSupported,
                                            &providerPreferencePresent);
    BOOL systemReadable = FMReadableDirectoryAtPath(FMProviderSystemFontsLogicalPath);
    BOOL rootfsReadable =
        FMReadableDirectoryAtPath(jbroot(FMProviderRootfsFontsLogicalPath));
    BOOL mirrorReadable = providerRootSupported &&
        FMReadableDirectoryAtPath(jbroot(mirrorLogicalPath));
    BOOL providerRootIsSymlink =
        FMPathIsSymbolicLink(jbroot(FMProviderAliasLogicalPath));
    BOOL providerCompatible = packageInstalled && providerExecutablePresent &&
        [packageMetadata[@"version"] isKindOfClass:NSString.class] &&
        [packageMetadata[@"version"] length] > 0 &&
        [providerCompatibility[@"compatible"] boolValue] &&
        providerRootSupported && !providerPreferencePresent;

    struct statfs filesystem = {0};
    BOOL statfsAvailable =
        statfs(FMProviderSystemFontsLogicalPath.fileSystemRepresentation,
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
    NSString *mirrorPath = providerRootSupported ? jbroot(mirrorLogicalPath) : nil;
    BOOL mappingManaged = mappingActive &&
        [mappingTarget isEqual:FMProviderSystemFontsLogicalPath] &&
        [mappingSource.stringByResolvingSymlinksInPath
            isEqual:mirrorPath.stringByResolvingSymlinksInPath] &&
        (filesystem.f_flags & MNT_RDONLY) != 0;

    if (!systemReadable) {
        FMAddIssue(issues, @"fonts.systemDirectoryUnavailable");
    }
    if (!rootfsReadable) {
        FMAddIssue(issues, @"fonts.rootfsDirectoryUnavailable");
    }
    if (!providerExecutablePresent) {
        FMAddIssue(issues, @"provider.executableMissing");
    } else if (!packageInstalled) {
        FMAddIssue(issues, @"provider.packageMetadataUnavailable");
    } else if (!providerCompatible) {
        FMAddIssue(issues, @"provider.capabilityContractMismatch");
    }
    if (!providerRootSupported) {
        FMAddIssue(issues, @"provider.rootConfigurationUnsupported");
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

    NSDictionary<NSString *, id> *providerFacts = @{
        @"executablePresent" : @(providerExecutablePresent),
        @"compatible" : @(providerCompatible),
    };
    NSDictionary<NSString *, id> *fontFacts = @{
        @"systemDirectoryReadable" : @(systemReadable),
        @"rootfsDirectoryReadable" : @(rootfsReadable),
        @"mirrorPresent" : @(mirrorReadable),
        @"mappingActive" : @(mappingManaged),
    };
    NSString *engineState = FMEngineStateForFacts(providerFacts, fontFacts, state);
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
        @"provider" : @{
            @"packageID" : FMProviderPackageIdentifier,
            @"packageInstalled" : @(packageInstalled),
            @"version" : packageMetadata[@"version"],
            @"architecture" : packageMetadata[@"architecture"],
            @"executablePresent" : @(providerExecutablePresent),
            @"executableLogicalPath" : FMProviderExecutableLogicalPath,
            @"contractVersion" : providerCompatibility[@"contractVersion"],
            @"recognition" : FMProviderRecognitionForVersion(
                [packageMetadata[@"version"] isKindOfClass:NSString.class]
                    ? packageMetadata[@"version"] : nil),
            @"compatibility" : providerCompatible
                ? @"compatible" : @"incompatible",
            @"compatible" : @(providerCompatible),
            @"executableSecure" : providerCompatibility[@"executableSecure"],
            @"boundedTextWrapper" :
                providerCompatibility[@"boundedTextWrapper"],
            @"shellWrapper" : providerCompatibility[@"shellWrapper"],
            @"supportsSkipCopy" : providerCompatibility[@"supportsSkipCopy"],
            @"supportsUnmount" : providerCompatibility[@"supportsUnmount"],
        },
        @"fonts" : @{
            @"systemTargetLogicalPath" : FMProviderSystemFontsLogicalPath,
            @"rootfsLogicalPath" : FMProviderRootfsFontsLogicalPath,
            @"mirrorLogicalPath" : mirrorLogicalPath,
            @"systemDirectoryReadable" : @(systemReadable),
            @"rootfsDirectoryReadable" : @(rootfsReadable),
            @"providerRootSupported" : @(providerRootSupported),
            @"providerRootShared" : @YES,
            @"providerPreferencePresent" : @(providerPreferencePresent),
            @"providerRootIsSymlink" : @(providerRootIsSymlink),
            @"mirrorPresent" : @(mirrorReadable),
            @"mappingActive" : @(mappingActive),
            @"mappingManaged" : @(mappingManaged),
            @"stockSnapshotPresent" : @(stockSnapshotPresent),
            @"targetFilesystemType" : FMNullUnlessString(filesystemType),
        },
        @"state" : state,
        @"capabilities" : @{
            @"readOnlyStatus" : @YES,
            @"initializeProvider" : @NO,
            @"stageProfile" : canStageSelection ? @YES : @NO,
            @"stageStock" : canStageSelection ? @YES : @NO,
            @"repair" : @NO,
            @"safeUnmount" : @NO,
            @"respring" : respringExecutableSecure ? @YES : @NO,
            @"userspaceReboot" : stockSnapshotPresent && providerCompatible
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
            @"provider" : @{
                @"packageID" : FMProviderPackageIdentifier,
                @"packageInstalled" : @NO,
                @"version" : NSNull.null,
                @"architecture" : NSNull.null,
                @"executablePresent" : @NO,
                @"contractVersion" : @(FMProviderCapabilityContractVersion),
                @"recognition" : @"unknown",
                @"compatibility" : @"incompatible",
                @"compatible" : @NO,
                @"executableSecure" : @NO,
                @"boundedTextWrapper" : @NO,
                @"shellWrapper" : @NO,
                @"supportsSkipCopy" : @NO,
                @"supportsUnmount" : @NO,
            },
            @"fonts" : @{
                @"systemDirectoryReadable" : @NO,
                @"rootfsDirectoryReadable" : @NO,
                @"providerRootShared" : @YES,
                @"providerRootIsSymlink" : @NO,
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
                @"initializeProvider" : @NO,
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
