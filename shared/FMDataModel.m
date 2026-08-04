#import "FMDataModel.h"

#import <CoreFoundation/CoreFoundation.h>

NSInteger const FMDataSchemaVersion = 2;
NSInteger const FMBaselineIdentitySchemaVersion = 3;
NSString *const FMDataErrorDomain = @"com.hmmzzz.fontmanager.data";

static BOOL FMDataFail(NSError **error, FMDataErrorCode code, NSString *message) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:FMDataErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey : message}];
    }
    return NO;
}

static BOOL FMIsJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL FMIsNonemptyString(id value) {
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0;
}

static BOOL FMStringContainsNUL(NSString *value) {
    unichar nul = 0;
    NSString *needle = [NSString stringWithCharacters:&nul length:1];
    return [value rangeOfString:needle].location != NSNotFound;
}

static BOOL FMHasSchemaVersionTwo(NSDictionary *document) {
    id value = document[@"schemaVersion"];
    return [value isKindOfClass:NSNumber.class] && !FMIsJSONBoolean(value) &&
           [value integerValue] == FMDataSchemaVersion;
}

static BOOL FMIsSafeIdentifier(id value) {
    if (!FMIsNonemptyString(value)) {
        return NO;
    }
    NSString *identifier = value;
    if (identifier.length > 128 || [identifier isEqualToString:@"."] ||
        [identifier isEqualToString:@".."]) {
        return NO;
    }
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"._-"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL FMIsProfileIDOrNull(id value) {
    return value == NSNull.null || FMIsSafeIdentifier(value);
}

static BOOL FMIsSortedUniqueRelativePathArray(id value) {
    if (![value isKindOfClass:NSArray.class]) return NO;
    NSString *previous = nil;
    for (id object in value) {
        if (![object isKindOfClass:NSString.class] ||
            !FMValidateRelativePath(object, nil) ||
            (previous != nil && [previous compare:object] != NSOrderedAscending)) {
            return NO;
        }
        previous = object;
    }
    return YES;
}

static BOOL FMIsLowercaseSHA256(id value) {
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] != 64) {
        return NO;
    }
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [(NSString *)value rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static BOOL FMIsNonnegativeInteger(id value) {
    if (![value isKindOfClass:NSNumber.class] || FMIsJSONBoolean(value)) {
        return NO;
    }
    NSNumber *number = value;
    double raw = number.doubleValue;
    long long integer = number.longLongValue;
    return raw >= 0.0 && raw == (double)integer;
}

static BOOL FMIsPositiveInteger(id value) {
    return FMIsNonnegativeInteger(value) && [(NSNumber *)value unsignedLongLongValue] > 0;
}

BOOL FMValidateRelativePath(NSString *relativePath, NSError **error) {
    if (![relativePath isKindOfClass:NSString.class] || relativePath.length == 0 ||
        relativePath.isAbsolutePath || FMStringContainsNUL(relativePath)) {
        return FMDataFail(error, FMDataErrorInvalidPath,
                          @"Relative path must be nonempty and non-absolute.");
    }

    NSArray<NSString *> *components = relativePath.pathComponents;
    if (components.count == 0) {
        return FMDataFail(error, FMDataErrorInvalidPath, @"Relative path has no components.");
    }
    for (NSString *component in components) {
        if (component.length == 0 || [component isEqualToString:@"."] ||
            [component isEqualToString:@".."] || [component isEqualToString:@"/"]) {
            return FMDataFail(error, FMDataErrorInvalidPath,
                              @"Relative path contains an unsafe component.");
        }
    }

    if (![relativePath.stringByStandardizingPath isEqualToString:relativePath]) {
        return FMDataFail(error, FMDataErrorInvalidPath,
                          @"Relative path must already be normalized.");
    }
    return YES;
}

BOOL FMValidateBaselineIdentity(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Baseline identity root must be a dictionary.");
    }
    NSDictionary *document = object;
    id schemaValue = document[@"schemaVersion"];
    if (![schemaValue isKindOfClass:NSNumber.class] ||
        FMIsJSONBoolean(schemaValue)) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Unsupported baseline identity schema version.");
    }

    for (NSString *key in @[
             @"productType", @"productVersion", @"productBuildVersion", @"createdAt"
         ]) {
        if (!FMIsNonemptyString(document[key])) {
            return FMDataFail(error, FMDataErrorInvalidDocument,
                              [NSString stringWithFormat:@"Invalid baseline field: %@", key]);
        }
    }
    if (![document[@"sourceLogicalPath"] isEqual:@"/System/Library/Fonts"]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Baseline is bound to an unexpected source.");
    }

    NSInteger schemaVersion = [schemaValue integerValue];
    BOOL legacyIdentity = schemaVersion == FMDataSchemaVersion &&
        [document[@"providerPackage"] isEqual:@"com.nan.bindfs"] &&
        FMIsNonemptyString(document[@"providerVersion"]);
    BOOL builtInIdentity = schemaVersion == FMBaselineIdentitySchemaVersion &&
        [document[@"mountBackend"] isEqual:@"markfont-bindfs"] &&
        FMIsNonemptyString(document[@"mountBackendVersion"]) &&
        [document[@"mirrorLogicalPath"]
            isEqual:@"/bindfs/System/Library/Fonts"];
    if (!legacyIdentity && !builtInIdentity) {
        return FMDataFail(
            error, FMDataErrorInvalidDocument,
            @"Baseline is bound to an unsupported mount backend.");
    }
    return YES;
}

BOOL FMBaselineIdentityUsesLegacyProvider(id object) {
    if (![object isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *document = object;
    id schemaValue = document[@"schemaVersion"];
    return [schemaValue isKindOfClass:NSNumber.class] &&
        !FMIsJSONBoolean(schemaValue) &&
        [schemaValue integerValue] == FMDataSchemaVersion &&
        [document[@"providerPackage"] isEqual:@"com.nan.bindfs"] &&
        FMIsNonemptyString(document[@"providerVersion"]);
}

NSDictionary<NSString *, id> *FMMigrateBaselineIdentityToBuiltInBackend(
    id object,
    NSError **error) {
    if (!FMValidateBaselineIdentity(object, error)) return nil;
    NSDictionary *document = object;
    if (!FMBaselineIdentityUsesLegacyProvider(document)) {
        return document;
    }

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDictionary *migrated = @{
        @"schemaVersion" : @(FMBaselineIdentitySchemaVersion),
        @"productType" : document[@"productType"],
        @"productVersion" : document[@"productVersion"],
        @"productBuildVersion" : document[@"productBuildVersion"],
        @"sourceLogicalPath" : @"/System/Library/Fonts",
        @"mirrorLogicalPath" : @"/bindfs/System/Library/Fonts",
        @"mountBackend" : @"markfont-bindfs",
        @"mountBackendVersion" : @"1",
        @"createdAt" : document[@"createdAt"],
        @"migration" : @{
            @"fromSchemaVersion" : @(FMDataSchemaVersion),
            @"fromMountBackend" : document[@"providerPackage"],
            @"fromMountBackendVersion" : document[@"providerVersion"],
            @"migratedAt" : [formatter stringFromDate:NSDate.date],
        },
    };
    return FMValidateBaselineIdentity(migrated, error) ? migrated : nil;
}

static BOOL FMValidateReplacementFileName(id value, NSError **error) {
    if (!FMIsNonemptyString(value)) {
        return FMDataFail(error, FMDataErrorInvalidPath,
                          @"Replacement filename must be nonempty.");
    }
    NSString *fileName = value;
    if (fileName.isAbsolutePath || fileName.pathComponents.count != 1 ||
        [fileName isEqualToString:@"."] || [fileName isEqualToString:@".."] ||
        ![fileName.lastPathComponent isEqualToString:fileName] ||
        FMStringContainsNUL(fileName)) {
        return FMDataFail(error, FMDataErrorInvalidPath,
                          @"Replacement filename must be one safe path component.");
    }
    return YES;
}

BOOL FMValidateProfileDocument(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Profile root must be a dictionary.");
    }
    NSDictionary *document = object;
    if (!FMHasSchemaVersionTwo(document) || !FMIsSafeIdentifier(document[@"id"]) ||
        !FMIsNonemptyString(document[@"name"]) ||
        !FMIsNonemptyString(document[@"systemBuild"]) ||
        ![document[@"replacements"] isKindOfClass:NSArray.class]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Profile identity or replacements are invalid.");
    }

    NSMutableSet<NSString *> *relativePaths = [NSMutableSet set];
    NSMutableSet<NSString *> *fileIDs = [NSMutableSet set];
    for (id objectEntry in document[@"replacements"]) {
        if (![objectEntry isKindOfClass:NSDictionary.class]) {
            return FMDataFail(error, FMDataErrorInvalidDocument,
                              @"Replacement entry must be a dictionary.");
        }
        NSDictionary *entry = objectEntry;
        NSString *fileID = entry[@"fontFileID"];
        NSString *relativePath = entry[@"relativePath"];
        NSError *pathError = nil;
        if (!FMIsSafeIdentifier(fileID) ||
            !FMValidateRelativePath(relativePath, &pathError) ||
            !FMValidateReplacementFileName(entry[@"fileName"], &pathError)) {
            if (error != NULL) {
                *error = pathError ?: [NSError errorWithDomain:FMDataErrorDomain
                                                           code:FMDataErrorInvalidDocument
                                                       userInfo:@{
                                                           NSLocalizedDescriptionKey :
                                                               @"Invalid replacement identity."
                                                       }];
            }
            return NO;
        }
        if (!FMIsLowercaseSHA256(entry[@"sha256"])) {
            return FMDataFail(error, FMDataErrorInvalidHash,
                              @"Replacement SHA-256 must be 64 lowercase hexadecimal digits.");
        }
        if ([relativePaths containsObject:relativePath] || [fileIDs containsObject:fileID]) {
            return FMDataFail(error, FMDataErrorDuplicateEntry,
                              @"Profile contains a duplicate file ID or relative path.");
        }
        [relativePaths addObject:relativePath];
        [fileIDs addObject:fileID];
    }
    return YES;
}

BOOL FMValidateStateDocument(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"State root must be a dictionary.");
    }
    NSDictionary *document = object;
    NSSet<NSString *> *allowedStates =
        [NSSet setWithArray:@[ @"clean", @"updating", @"repairRequired" ]];
    NSString *mirrorState = document[@"mirrorState"];
    id transitionManagedPaths = document[@"transitionManagedPaths"];
    BOOL transitionPathsValid = [mirrorState isEqual:@"clean"]
        ? transitionManagedPaths == nil
        : FMIsSortedUniqueRelativePathArray(transitionManagedPaths);
    id automaticRespring = document[@"autoRespring"];
    BOOL automaticRespringValid = automaticRespring == nil ||
        FMIsJSONBoolean(automaticRespring);
    id refreshReason = document[@"refreshReason"];
    NSSet<NSString *> *allowedRefreshReasons = [NSSet setWithArray:@[
        @"profileChange", @"lateAutomaticMount"
    ]];
    BOOL refreshReasonValid = refreshReason == nil || refreshReason == NSNull.null ||
        ([refreshReason isKindOfClass:NSString.class] &&
         [allowedRefreshReasons containsObject:refreshReason]);
    BOOL refreshReasonConsistent =
        [document[@"restartRequired"] boolValue] ||
        refreshReason == nil || refreshReason == NSNull.null;
    if (!FMHasSchemaVersionTwo(document) || !FMIsNonemptyString(document[@"systemBuild"]) ||
        !FMIsProfileIDOrNull(document[@"confirmedProfileID"]) ||
        !FMIsProfileIDOrNull(document[@"workingProfileID"]) ||
        !FMIsJSONBoolean(document[@"restartRequired"]) ||
        ![mirrorState isKindOfClass:NSString.class] ||
        ![allowedStates containsObject:mirrorState] || !transitionPathsValid ||
        !FMIsJSONBoolean(document[@"autoMount"]) ||
        !automaticRespringValid || !refreshReasonValid ||
        !refreshReasonConsistent) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"State schema, identity, booleans, or mirror state is invalid.");
    }
    return YES;
}

BOOL FMValidateManifestDocument(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Manifest root must be a dictionary.");
    }
    NSDictionary *document = object;
    NSArray *entries = document[@"entries"];
    if (!FMHasSchemaVersionTwo(document) || ![entries isKindOfClass:NSArray.class]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Manifest schema or entries are invalid.");
    }

    NSSet<NSString *> *allowedTypes =
        [NSSet setWithArray:@[ @"regular", @"directory", @"symlink", @"other" ]];
    NSString *previousPath = nil;
    for (id objectEntry in entries) {
        if (![objectEntry isKindOfClass:NSDictionary.class]) {
            return FMDataFail(error, FMDataErrorInvalidDocument,
                              @"Manifest entry must be a dictionary.");
        }
        NSDictionary *entry = objectEntry;
        NSString *relativePath = entry[@"relativePath"];
        NSString *type = entry[@"type"];
        NSError *pathError = nil;
        if (!FMValidateRelativePath(relativePath, &pathError)) {
            if (error != NULL) {
                *error = pathError;
            }
            return NO;
        }
        if (previousPath != nil && [previousPath compare:relativePath] != NSOrderedAscending) {
            return FMDataFail(error, FMDataErrorDuplicateEntry,
                              @"Manifest paths must be unique and sorted.");
        }
        previousPath = relativePath;

        if (![type isKindOfClass:NSString.class] || ![allowedTypes containsObject:type] ||
            !FMIsNonnegativeInteger(entry[@"mode"]) || [entry[@"mode"] integerValue] > 07777 ||
            !FMIsNonnegativeInteger(entry[@"uid"]) ||
            !FMIsNonnegativeInteger(entry[@"gid"]) ||
            !FMIsNonnegativeInteger(entry[@"size"])) {
            return FMDataFail(error, FMDataErrorInvalidDocument,
                              @"Manifest entry metadata is invalid.");
        }
        if ([type isEqual:@"regular"] && !FMIsLowercaseSHA256(entry[@"sha256"])) {
            return FMDataFail(error, FMDataErrorInvalidHash,
                              @"Regular manifest entry is missing a valid SHA-256.");
        }
        if ([type isEqual:@"symlink"] && !FMIsNonemptyString(entry[@"linkTarget"])) {
            return FMDataFail(error, FMDataErrorInvalidDocument,
                              @"Symlink manifest entry is missing its link target.");
        }
    }
    return YES;
}

BOOL FMValidateFontCatalogDocument(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Font catalog root must be a dictionary.");
    }
    NSDictionary *document = object;
    NSArray *files = document[@"files"];
    NSArray *excludedRegularPaths = document[@"excludedRegularPaths"];
    if (!FMHasSchemaVersionTwo(document) ||
        ![document[@"catalogVersion"] isKindOfClass:NSNumber.class] ||
        FMIsJSONBoolean(document[@"catalogVersion"]) ||
        [document[@"catalogVersion"] integerValue] != 1 ||
        ![document[@"matchingMode"] isEqual:@"stockFileName"] ||
        !FMIsNonemptyString(document[@"systemBuild"]) ||
        ![document[@"sourceLogicalPath"] isEqual:@"/System/Library/Fonts"] ||
        !FMIsLowercaseSHA256(document[@"sourceManifestSHA256"]) ||
        !FMIsNonemptyString(document[@"generatedAt"]) ||
        !FMIsPositiveInteger(document[@"sourceRegularFileCount"]) ||
        ![excludedRegularPaths isKindOfClass:NSArray.class] ||
        ![files isKindOfClass:NSArray.class] || files.count == 0 ||
        [document[@"sourceRegularFileCount"] unsignedLongLongValue] !=
            files.count + excludedRegularPaths.count) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Font catalog identity or files are invalid.");
    }

    NSMutableSet<NSString *> *fileIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *fileNames = [NSMutableSet set];
    NSMutableSet<NSString *> *relativePaths = [NSMutableSet set];
    NSString *previousRelativePath = nil;

    for (id objectFile in files) {
        if (![objectFile isKindOfClass:NSDictionary.class]) {
            return FMDataFail(error, FMDataErrorInvalidDocument,
                              @"Font catalog file must be a dictionary.");
        }
        NSDictionary *file = objectFile;
        NSString *fileID = file[@"id"];
        NSString *fileName = file[@"fileName"];
        NSString *relativePath = file[@"relativePath"];
        NSError *pathError = nil;
        if (!FMIsSafeIdentifier(fileID) ||
            !FMValidateReplacementFileName(fileName, &pathError) ||
            !FMValidateRelativePath(relativePath, &pathError) ||
            ![relativePath.lastPathComponent isEqual:fileName] ||
            !FMIsLowercaseSHA256(file[@"stockSHA256"]) ||
            !FMIsPositiveInteger(file[@"fileSize"])) {
            if (error != NULL) {
                *error = pathError ?: [NSError errorWithDomain:FMDataErrorDomain
                                                           code:FMDataErrorInvalidDocument
                                                       userInfo:@{
                    NSLocalizedDescriptionKey : @"A font catalog file is invalid."
                }];
            }
            return NO;
        }
        if ([fileIDs containsObject:fileID] ||
            [fileNames containsObject:fileName] ||
            [relativePaths containsObject:relativePath] ||
            (previousRelativePath != nil &&
             [previousRelativePath compare:relativePath] != NSOrderedAscending)) {
            return FMDataFail(error, FMDataErrorDuplicateEntry,
                              @"Font catalog IDs, filenames, and paths must be unique and sorted.");
        }
        previousRelativePath = relativePath;
        [fileIDs addObject:fileID];
        [fileNames addObject:fileName];
        [relativePaths addObject:relativePath];
    }

    previousRelativePath = nil;
    for (id objectPath in excludedRegularPaths) {
        NSError *pathError = nil;
        if (![objectPath isKindOfClass:NSString.class] ||
            !FMValidateRelativePath(objectPath, &pathError)) {
            if (error != NULL) {
                *error = pathError;
            }
            return NO;
        }
        NSString *relativePath = objectPath;
        if ([relativePaths containsObject:relativePath] ||
            (previousRelativePath != nil &&
             [previousRelativePath compare:relativePath] != NSOrderedAscending)) {
            return FMDataFail(error, FMDataErrorDuplicateEntry,
                              @"Excluded Stock paths must be unique and sorted.");
        }
        previousRelativePath = relativePath;
        [relativePaths addObject:relativePath];
    }
    return YES;
}

BOOL FMValidateFontCatalogPreviewDocument(id object,
                                          NSString *expectedSystemBuild,
                                          NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Font catalog preview root must be a dictionary.");
    }
    NSDictionary *document = object;
    NSDictionary *catalog = document[@"catalog"];
    NSArray *excludedPaths = document[@"excludedRegularPaths"];
    id schemaVersion = document[@"schemaVersion"];
    if (![schemaVersion isKindOfClass:NSNumber.class] || FMIsJSONBoolean(schemaVersion) ||
        [schemaVersion integerValue] != 1 ||
        ![document[@"operation"] isEqual:@"inspectFontCatalog"] ||
        ![document[@"status"] isEqual:@"reviewRequired"] ||
        !FMIsNonemptyString(expectedSystemBuild) ||
        ![document[@"systemBuild"] isEqual:expectedSystemBuild] ||
        ![document[@"matchingMode"] isEqual:@"stockFileName"] ||
        !FMIsLowercaseSHA256(document[@"sourceManifestSHA256"]) ||
        !FMIsPositiveInteger(document[@"sourceRegularFileCount"]) ||
        !FMIsPositiveInteger(document[@"fontFileCount"]) ||
        !FMIsNonnegativeInteger(document[@"excludedRegularFileCount"]) ||
        ![excludedPaths isKindOfClass:NSArray.class] ||
        !FMIsJSONBoolean(document[@"readOnly"]) ||
        ![document[@"readOnly"] boolValue] ||
        !FMIsJSONBoolean(document[@"filesystemMutated"]) ||
        [document[@"filesystemMutated"] boolValue] ||
        !FMIsJSONBoolean(document[@"mappingChanged"]) ||
        [document[@"mappingChanged"] boolValue] ||
        !FMIsJSONBoolean(document[@"stateChanged"]) ||
        [document[@"stateChanged"] boolValue] ||
        !FMIsJSONBoolean(document[@"restartRequested"]) ||
        [document[@"restartRequested"] boolValue]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Font catalog preview identity is invalid.");
    }
    if (!FMValidateFontCatalogDocument(catalog, error)) {
        return NO;
    }

    if (![catalog[@"systemBuild"] isEqual:expectedSystemBuild] ||
        ![catalog[@"matchingMode"] isEqual:document[@"matchingMode"]] ||
        ![catalog[@"sourceManifestSHA256"]
            isEqual:document[@"sourceManifestSHA256"]] ||
        ![catalog[@"sourceRegularFileCount"]
            isEqual:document[@"sourceRegularFileCount"]] ||
        [catalog[@"files"] count] != [document[@"fontFileCount"] unsignedIntegerValue] ||
        [catalog[@"excludedRegularPaths"] count] !=
            [document[@"excludedRegularFileCount"] unsignedIntegerValue] ||
        ![catalog[@"excludedRegularPaths"] isEqual:excludedPaths]) {
        return FMDataFail(error, FMDataErrorInvalidDocument,
                          @"Font catalog preview and catalog disagree.");
    }
    return YES;
}
