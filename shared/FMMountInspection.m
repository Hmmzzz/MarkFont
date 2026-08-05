#import "FMMountInspection.h"

#import <errno.h>
#import <limits.h>
#import <roothide.h>
#import <sys/mount.h>
#import <sys/stat.h>

#import "FMEnvironmentProbe.h"
#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMProfileMirrorMatcher.h"
#import "FMMountBackendCompatibility.h"
#import "FMMountBackendExecutor.h"
#import "FMMountCoordinator.h"
#import "FMMountPaths.h"
#import "FMTreeManifest.h"

NSString *const FMMountInspectionErrorDomain =
    @"com.hmmzzz.fontmanager.mount-inspection";

static NSError *FMInspectionError(NSString *description) {
    return [NSError errorWithDomain:FMMountInspectionErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

static NSNumber *FMJSONBoolean(BOOL value) {
    return value ? @YES : @NO;
}

static BOOL FMPhysicalDirectoryReadable(NSString *path) {
    struct stat info = {0};
    return lstat(path.fileSystemRepresentation, &info) == 0 &&
           S_ISDIR(info.st_mode) && access(path.fileSystemRepresentation, R_OK) == 0;
}

static BOOL FMPathIsInsideRoot(NSString *path, NSString *root) {
    NSString *standardPath = path.stringByStandardizingPath;
    NSString *standardRoot = root.stringByStandardizingPath;
    if ([standardPath isEqual:standardRoot]) {
        return YES;
    }
    NSString *prefix = [standardRoot stringByAppendingString:@"/"];
    return [standardPath hasPrefix:prefix];
}

static NSString *FMMirrorKind(NSString *mirrorPath, NSError **error) {
    struct stat info = {0};
    if (lstat(mirrorPath.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) {
            return @"missing";
        }
        if (error != NULL) {
            *error = FMInspectionError(@"Unable to inspect the managed mirror path.");
        }
        return nil;
    }
    if (!S_ISDIR(info.st_mode)) {
        return @"present";
    }
    NSError *contentsError = nil;
    NSArray *contents = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:mirrorPath
                            error:&contentsError];
    if (contents == nil) {
        if (error != NULL) {
            *error = FMInspectionError(@"Unable to enumerate the managed mirror.");
        }
        return nil;
    }
    return contents.count == 0 ? @"empty" : @"present";
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *FMEntriesByPath(
    NSDictionary<NSString *, id> *manifest) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *entry in manifest[@"entries"]) {
        NSString *relativePath = entry[@"relativePath"];
        if ([relativePath isKindOfClass:NSString.class]) {
            result[relativePath] = entry;
        }
    }
    return result;
}

static BOOL FMMetadataMatches(NSDictionary<NSString *, id> *stock,
                              NSDictionary<NSString *, id> *mirror) {
    return [stock[@"mode"] isEqual:mirror[@"mode"]] &&
           [stock[@"uid"] isEqual:mirror[@"uid"]] &&
           [stock[@"gid"] isEqual:mirror[@"gid"]];
}

static NSDictionary<NSString *, id> *FMStockManifestForEvidence(
    NSString *systemBuild,
    NSString *stockPath,
    NSError **error) {
    NSString *baselinePath = [[jbroot(@"/var/lib/fontmanager/baseline")
        stringByAppendingPathComponent:systemBuild]
        stringByAppendingPathComponent:@"manifest.json"];
    struct stat baselineInfo = {0};
    if (lstat(baselinePath.fileSystemRepresentation, &baselineInfo) == 0) {
        NSError *baselineError = nil;
        id baseline = S_ISREG(baselineInfo.st_mode)
            ? FMReadJSONObjectAtPath(baselinePath, &baselineError)
            : nil;
        if (![baseline isKindOfClass:NSDictionary.class] ||
            !FMValidateManifestDocument(baseline, &baselineError)) {
            if (error != NULL) {
                *error = baselineError ?:
                    FMInspectionError(@"The saved Stock manifest is invalid.");
            }
            return nil;
        }
        return baseline;
    }
    if (errno != ENOENT) {
        if (error != NULL) {
            *error = FMInspectionError(@"The saved Stock manifest could not be inspected.");
        }
        return nil;
    }
    return FMCreateTreeManifestAtPath(stockPath, error);
}

static NSDictionary<NSString *, id> *FMManifestEvidence(
    NSString *systemBuild,
    NSString *stockPath,
    NSString *mirrorPath,
    NSString *mirrorKind,
    NSDictionary<NSString *, id> *state,
    NSError **error) {
    NSError *stockError = nil;
    NSDictionary *stockManifest = FMStockManifestForEvidence(
        systemBuild, stockPath, &stockError);
    if (stockManifest == nil) {
        if (error != NULL) {
            *error = stockError ?: FMInspectionError(@"Unable to create the Stock manifest.");
        }
        return nil;
    }
    NSArray *stockEntries = stockManifest[@"entries"];
    NSString *stockManifestSHA256 =
        FMSHA256ForJSONObject(stockManifest, &stockError);
    if (stockManifestSHA256 == nil) {
        if (error != NULL) {
            *error = stockError ?: FMInspectionError(@"Unable to hash the Stock manifest.");
        }
        return nil;
    }
    unsigned long long stockRegularBytes = 0;
    for (NSDictionary<NSString *, id> *entry in stockEntries) {
        if (![entry[@"type"] isEqual:@"regular"]) {
            continue;
        }
        unsigned long long size = [entry[@"size"] unsignedLongLongValue];
        if (ULLONG_MAX - stockRegularBytes < size) {
            if (error != NULL) {
                *error = FMInspectionError(@"The Stock font byte count overflowed.");
            }
            return nil;
        }
        stockRegularBytes += size;
    }
    if (![mirrorKind isEqual:@"present"]) {
        return @{
            @"scanState" : @"notApplicable",
            @"systemBuild" : systemBuild,
            @"stockEntryCount" : @(stockEntries.count),
            @"stockRegularBytes" : @(stockRegularBytes),
            @"stockManifestSHA256" : stockManifestSHA256,
            @"mirrorManifestSHA256" : NSNull.null,
            @"mirrorEntryCount" : @0,
            @"changedPaths" : @[],
            @"missingPaths" : @[],
            @"unknownPaths" : @[],
            @"typeChangedPaths" : @[],
            @"matchesWorkingProfile" : @NO,
        };
    }

    NSError *mirrorError = nil;
    NSDictionary *mirrorManifest = FMCreateTreeManifestAtPath(mirrorPath, &mirrorError);
    if (mirrorManifest == nil) {
        if (error != NULL) {
            *error = mirrorError ?: FMInspectionError(@"Unable to create the mirror manifest.");
        }
        return nil;
    }

    NSDictionary *stockByPath = FMEntriesByPath(stockManifest);
    NSDictionary *mirrorByPath = FMEntriesByPath(mirrorManifest);
    NSString *mirrorManifestSHA256 =
        FMSHA256ForJSONObject(mirrorManifest, &mirrorError);
    if (mirrorManifestSHA256 == nil) {
        if (error != NULL) {
            *error = mirrorError ?: FMInspectionError(@"Unable to hash the mirror manifest.");
        }
        return nil;
    }
    NSMutableArray<NSString *> *changed = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSMutableArray<NSString *> *unknown = [NSMutableArray array];
    NSMutableArray<NSString *> *structurallyChanged = [NSMutableArray array];

    for (NSString *relativePath in stockByPath) {
        NSDictionary *stock = stockByPath[relativePath];
        NSDictionary *mirror = mirrorByPath[relativePath];
        if (mirror == nil) {
            [missing addObject:relativePath];
            continue;
        }
        if (![stock[@"type"] isEqual:mirror[@"type"]] ||
            !FMMetadataMatches(stock, mirror)) {
            [structurallyChanged addObject:relativePath];
            continue;
        }
        if ([stock[@"type"] isEqual:@"regular"] &&
            ![stock[@"sha256"] isEqual:mirror[@"sha256"]]) {
            [changed addObject:relativePath];
        } else if ([stock[@"type"] isEqual:@"symlink"] &&
                   ![stock[@"linkTarget"] isEqual:mirror[@"linkTarget"]]) {
            [changed addObject:relativePath];
        }
    }
    for (NSString *relativePath in mirrorByPath) {
        if (stockByPath[relativePath] == nil) {
            [unknown addObject:relativePath];
        }
    }
    for (NSMutableArray<NSString *> *paths in
         @[ changed, missing, unknown, structurallyChanged ]) {
        [paths sortUsingSelector:@selector(compare:)];
    }

    BOOL complete = missing.count == 0 && unknown.count == 0 &&
                    structurallyChanged.count == 0;
    BOOL validWorkingState = [state[@"present"] boolValue] &&
                             [state[@"valid"] boolValue];
    id workingProfileID = state[@"workingProfileID"];
    BOOL matchesWorkingProfile = NO;
    if (validWorkingState && complete && workingProfileID == NSNull.null) {
        matchesWorkingProfile = changed.count == 0;
    } else if (validWorkingState && complete &&
               [workingProfileID isKindOfClass:NSString.class]) {
        NSError *catalogError = nil;
        NSDictionary *catalog = FMCreateFontCatalogFromManifest(
            stockManifest, systemBuild, stockManifestSHA256, &catalogError);
        matchesWorkingProfile = catalog != nil &&
            FMManifestsMatchWorkingProfile(
                stockManifest, mirrorManifest,
                jbroot(@"/var/lib/fontmanager/profiles"), workingProfileID,
                systemBuild, catalog, &catalogError);
    }
    return @{
        @"scanState" : complete ? @"complete" : @"incomplete",
        @"systemBuild" : systemBuild,
        @"stockEntryCount" : @(stockByPath.count),
        @"stockRegularBytes" : @(stockRegularBytes),
        @"stockManifestSHA256" : stockManifestSHA256,
        @"mirrorManifestSHA256" : mirrorManifestSHA256,
        @"mirrorEntryCount" : @(mirrorByPath.count),
        @"changedPaths" : changed,
        @"missingPaths" : missing,
        @"unknownPaths" : unknown,
        @"typeChangedPaths" : structurallyChanged,
        @"matchesWorkingProfile" : FMJSONBoolean(matchesWorkingProfile),
    };
}

NSDictionary<NSString *, id> *FMCreateDeviceMountInspection(NSError **error) {
    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSDictionary *system = environment[@"system"];
    NSDictionary *backendStatus = environment[@"mountBackend"];
    NSDictionary *stateStatus = environment[@"state"];
    NSString *systemBuild = system[@"productBuildVersion"];
    if (![systemBuild isKindOfClass:NSString.class] || systemBuild.length == 0) {
        if (error != NULL) {
            *error = FMInspectionError(@"System build identity is unavailable.");
        }
        return nil;
    }

    BOOL mountStorageSupported = NO;
    BOOL legacyProviderPreferencePresent = NO;
    NSString *mountStorageRootLogicalPath =
        FMMountResolvedStorageRootLogicalPath(&mountStorageSupported,
                                          &legacyProviderPreferencePresent);
    NSError *legacyProviderPreferenceError = nil;
    NSDictionary *legacyProviderAutoMount =
        FMLegacyProviderAutoMountConfiguration(&legacyProviderPreferenceError);
    if (legacyProviderAutoMount == nil) {
        if (error != NULL) *error = legacyProviderPreferenceError;
        return nil;
    }
    BOOL legacyProviderAutoMountConflictsWithFonts =
        [legacyProviderAutoMount[@"conflictsWithFonts"] boolValue];
    NSString *mountStorageRootPath = jbroot(mountStorageRootLogicalPath);
    NSString *mirrorPath = [mountStorageRootPath
        stringByAppendingPathComponent:@"System/Library/Fonts"];
    NSString *stockPath = FMMountResolvedStockFontsPath();
    NSString *jbrootPath = jbroot(@"/");

    NSError *mirrorKindError = nil;
    NSString *mirrorKind = FMMirrorKind(mirrorPath, &mirrorKindError);
    if (mirrorKind == nil) {
        if (error != NULL) {
            *error = mirrorKindError;
        }
        return nil;
    }

    struct stat stockInfo = {0};
    struct stat mirrorInfo = {0};
    BOOL stockStatAvailable = lstat(stockPath.fileSystemRepresentation, &stockInfo) == 0;
    BOOL mirrorStatAvailable = lstat(mirrorPath.fileSystemRepresentation, &mirrorInfo) == 0;
    BOOL distinctTrees = !mirrorStatAvailable || !stockStatAvailable ||
                         stockInfo.st_dev != mirrorInfo.st_dev ||
                         stockInfo.st_ino != mirrorInfo.st_ino;

    struct statfs mappingInfo = {0};
    BOOL mappingInfoAvailable = statfs(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
                                       &mappingInfo) == 0;
    NSString *filesystemType = mappingInfoAvailable
        ? [NSString stringWithUTF8String:mappingInfo.f_fstypename]
        : nil;
    BOOL mappingActive = filesystemType != nil &&
        [filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame;
    NSString *mappingTarget = mappingInfoAvailable
        ? [NSString stringWithUTF8String:mappingInfo.f_mntonname]
        : nil;
    NSString *mappingSource = mappingInfoAvailable
        ? [NSString stringWithUTF8String:mappingInfo.f_mntfromname]
        : nil;
    NSString *canonicalMirror = mirrorPath.stringByResolvingSymlinksInPath;
    NSString *canonicalSource = mappingSource.stringByResolvingSymlinksInPath;

    NSString *backendExecutablePath =
        jbroot(FMMountBackendExecutableLogicalPath);
    NSError *compatibilityError = nil;
    NSDictionary *compatibility =
        FMInspectMountBackendCompatibilityAtPath(
            backendExecutablePath, &compatibilityError);
    if (compatibility == nil) {
        if (error != NULL) *error = compatibilityError;
        return nil;
    }
    NSString *backendVersion =
        [backendStatus[@"version"] isKindOfClass:NSString.class]
            ? backendStatus[@"version"] : nil;
    BOOL backendCompatible = backendVersion.length > 0 &&
        [compatibility[@"compatible"] boolValue] &&
        [backendStatus[@"runtimeLibraryPresent"] boolValue] &&
        [backendStatus[@"runtimeLibrarySecure"] boolValue] &&
        mountStorageSupported && !legacyProviderAutoMountConflictsWithFonts;

    BOOL statePresent = [stateStatus[@"present"] boolValue];
    BOOL stateValid = [stateStatus[@"valid"] boolValue];
    NSDictionary *state = @{
        @"present" : FMJSONBoolean(statePresent),
        @"valid" : FMJSONBoolean(stateValid),
        @"systemBuild" : stateStatus[@"systemBuild"] ?: NSNull.null,
        @"mirrorState" : statePresent
            ? (stateStatus[@"mirrorState"] ?: @"none")
            : @"none",
        @"workingProfileID" : stateStatus[@"workingProfileID"] ?: NSNull.null,
    };

    NSDictionary *manifest = FMManifestEvidence(systemBuild, stockPath, mirrorPath,
                                                 mirrorKind, state, error);
    if (manifest == nil) {
        return nil;
    }

    NSDictionary *inspection = @{
        @"schemaVersion" : @(FMMountInspectionSchemaVersion),
        @"evidenceMode" : @"deviceReadOnly",
        @"systemBuild" : systemBuild,
        @"mountBackend" : @{
            @"identifier" : FMMountBackendIdentifier,
            @"version" : backendVersion ?: NSNull.null,
            @"executablePresent" : FMJSONBoolean(
                [backendStatus[@"executablePresent"] boolValue]),
            @"runtimeLibraryPresent" : FMJSONBoolean(
                [backendStatus[@"runtimeLibraryPresent"] boolValue]),
            @"runtimeLibrarySecure" : FMJSONBoolean(
                [backendStatus[@"runtimeLibrarySecure"] boolValue]),
            @"contractVersion" : compatibility[@"contractVersion"],
            @"recognition" :
                FMMountBackendRecognitionForVersion(backendVersion),
            @"compatibility" : backendCompatible
                ? @"compatible" : @"incompatible",
            @"compatible" : FMJSONBoolean(backendCompatible),
            @"executableSecure" : compatibility[@"executableSecure"],
            @"machOExecutable" : compatibility[@"machOExecutable"],
            @"supportsReadOnlyMount" :
                compatibility[@"supportsReadOnlyMount"],
            @"supportsForceUnmount" :
                compatibility[@"supportsForceUnmount"],
            @"storageSupported" : FMJSONBoolean(mountStorageSupported),
            @"legacyProviderPreferencePresent" :
                FMJSONBoolean(legacyProviderPreferencePresent),
            @"legacyProviderAutoMountConflictsWithFonts" :
                FMJSONBoolean(legacyProviderAutoMountConflictsWithFonts),
        },
        @"fonts" : @{
            @"systemReadable" : FMJSONBoolean(
                FMPhysicalDirectoryReadable(FMMountSystemFontsLogicalPath)),
            @"rootfsReadable" : FMJSONBoolean(
                FMPhysicalDirectoryReadable(stockPath)),
            @"mirrorKind" : mirrorKind,
            @"mirrorInsideJBRoot" : FMJSONBoolean(
                mountStorageSupported && FMPathIsInsideRoot(mirrorPath, jbrootPath)),
            @"rootfsDistinctFromMirror" : FMJSONBoolean(distinctTrees),
            @"mirrorLogicalPath" : [mountStorageRootLogicalPath
                stringByAppendingPathComponent:@"System/Library/Fonts"],
        },
        @"mapping" : @{
            @"active" : FMJSONBoolean(mappingActive),
            @"targetMatches" : FMJSONBoolean(
                mappingActive &&
                    [mappingTarget isEqual:FMMountSystemFontsLogicalPath]),
            @"sourceMatchesMirror" : FMJSONBoolean(
                mappingActive && [canonicalSource isEqual:canonicalMirror]),
            @"readOnly" : FMJSONBoolean(
                mappingActive && (mappingInfo.f_flags & MNT_RDONLY) != 0),
            @"filesystemType" : mappingActive ? filesystemType : NSNull.null,
        },
        @"manifest" : manifest,
        @"state" : state,
    };

    NSError *validationError = nil;
    if (!FMValidateMountInspection(inspection, &validationError)) {
        if (error != NULL) {
            *error = validationError ?:
                FMInspectionError(@"Mount backend inspection is invalid.");
        }
        return nil;
    }
    return inspection;
}
