#import "FMProviderCoordinator.h"

#import <CoreFoundation/CoreFoundation.h>

#import "FMProviderCompatibility.h"

NSInteger const FMProviderInspectionSchemaVersion = 2;
NSInteger const FMProviderDecisionVersion = 4;
NSString *const FMProviderCoordinatorErrorDomain = @"com.hmmzzz.fontmanager.providercoordinator";

static BOOL FMCoordinatorFail(NSError **error, NSString *message) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:FMProviderCoordinatorErrorDomain
                                     code:FMProviderCoordinatorErrorInvalidInspection
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

static BOOL FMIsNullOrString(id value) {
    return value == NSNull.null || [value isKindOfClass:NSString.class];
}

static BOOL FMIsLowercaseSHA256(id value) {
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] != 64) {
        return NO;
    }
    NSCharacterSet *hex =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [(NSString *)value rangeOfCharacterFromSet:hex.invertedSet].location ==
           NSNotFound;
}

static BOOL FMRequireDictionary(NSDictionary *root,
                                NSString *key,
                                NSDictionary **result,
                                NSError **error) {
    id value = root[key];
    if (![value isKindOfClass:NSDictionary.class]) {
        return FMCoordinatorFail(error,
                                 [NSString stringWithFormat:@"Missing dictionary: %@", key]);
    }
    if (result != NULL) {
        *result = value;
    }
    return YES;
}

static BOOL FMRequireBool(NSDictionary *root, NSString *key, NSError **error) {
    if (!FMIsJSONBoolean(root[key])) {
        return FMCoordinatorFail(error,
                                 [NSString stringWithFormat:@"Missing boolean: %@", key]);
    }
    return YES;
}

static BOOL FMValidatePathArray(id value, NSString *key, NSError **error) {
    if (![value isKindOfClass:NSArray.class]) {
        return FMCoordinatorFail(error,
                                 [NSString stringWithFormat:@"%@ must be an array.", key]);
    }
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in value) {
        if (!FMIsNonemptyString(item) || [(NSString *)item isAbsolutePath] ||
            ![[(NSString *)item stringByStandardizingPath] isEqual:item] ||
            [[(NSString *)item pathComponents] containsObject:@"."] ||
            [[(NSString *)item pathComponents] containsObject:@".."] ||
            [seen containsObject:item]) {
            return FMCoordinatorFail(error,
                                     [NSString stringWithFormat:@"%@ contains an unsafe or duplicate path.",
                                                                key]);
        }
        [seen addObject:item];
    }
    return YES;
}

BOOL FMValidateProviderInspection(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMCoordinatorFail(error, @"Inspection root must be a dictionary.");
    }
    NSDictionary *inspection = object;
    id schemaVersion = inspection[@"schemaVersion"];
    NSSet<NSString *> *evidenceModes =
        [NSSet setWithArray:@[ @"simulatorFixture", @"deviceReadOnly" ]];
    if (![schemaVersion isKindOfClass:NSNumber.class] || FMIsJSONBoolean(schemaVersion) ||
        [schemaVersion integerValue] != FMProviderInspectionSchemaVersion ||
        ![evidenceModes containsObject:inspection[@"evidenceMode"]] ||
        !FMIsNonemptyString(inspection[@"systemBuild"])) {
        return FMCoordinatorFail(error, @"Invalid inspection identity.");
    }

    NSDictionary *provider = nil;
    NSDictionary *fonts = nil;
    NSDictionary *mapping = nil;
    NSDictionary *manifest = nil;
    NSDictionary *state = nil;
    if (!FMRequireDictionary(inspection, @"provider", &provider, error) ||
        !FMRequireDictionary(inspection, @"fonts", &fonts, error) ||
        !FMRequireDictionary(inspection, @"mapping", &mapping, error) ||
        !FMRequireDictionary(inspection, @"manifest", &manifest, error) ||
        !FMRequireDictionary(inspection, @"state", &state, error)) {
        return NO;
    }

    if (![provider[@"packageID"] isEqual:@"com.nan.bindfs"] ||
        !FMIsNullOrString(provider[@"version"]) ||
        ![provider[@"contractVersion"] isKindOfClass:NSNumber.class] ||
        FMIsJSONBoolean(provider[@"contractVersion"]) ||
        [provider[@"contractVersion"] integerValue] !=
            FMProviderCapabilityContractVersion ||
        ![@[ @"known", @"unknown" ]
            containsObject:provider[@"recognition"]] ||
        ![@[ @"compatible", @"incompatible" ]
            containsObject:provider[@"compatibility"]] ||
        !FMRequireBool(provider, @"packageInstalled", error) ||
        !FMRequireBool(provider, @"executablePresent", error) ||
        !FMRequireBool(provider, @"compatible", error) ||
        !FMRequireBool(provider, @"executableSecure", error) ||
        !FMRequireBool(provider, @"boundedTextWrapper", error) ||
        !FMRequireBool(provider, @"shellWrapper", error) ||
        !FMRequireBool(provider, @"supportsCopy", error) ||
        !FMRequireBool(provider, @"supportsSkipCopy", error) ||
        !FMRequireBool(provider, @"supportsUnmount", error) ||
        !FMRequireBool(provider, @"rootConfigurationSupported", error) ||
        !FMRequireBool(provider, @"preferencePresent", error)) {
        return error == NULL || *error == nil
                   ? FMCoordinatorFail(error, @"Invalid Provider evidence.")
                   : NO;
    }
    BOOL compatibilityConsistent = [provider[@"compatible"] boolValue]
        ? [provider[@"compatibility"] isEqual:@"compatible"] &&
          FMProviderEvidenceSatisfiesCompatibilityContract(provider)
        : [provider[@"compatibility"] isEqual:@"incompatible"];
    if (!compatibilityConsistent) {
        return FMCoordinatorFail(error, @"Inconsistent Provider compatibility evidence.");
    }

    NSSet<NSString *> *mirrorKinds =
        [NSSet setWithArray:@[ @"missing", @"empty", @"present" ]];
    if (![mirrorKinds containsObject:fonts[@"mirrorKind"]] ||
        !FMRequireBool(fonts, @"systemReadable", error) ||
        !FMRequireBool(fonts, @"rootfsReadable", error) ||
        !FMRequireBool(fonts, @"mirrorInsideJBRoot", error) ||
        !FMRequireBool(fonts, @"rootfsDistinctFromMirror", error)) {
        return error == NULL || *error == nil
                   ? FMCoordinatorFail(error, @"Invalid font path evidence.")
                   : NO;
    }

    if (!FMRequireBool(mapping, @"active", error) ||
        !FMRequireBool(mapping, @"targetMatches", error) ||
        !FMRequireBool(mapping, @"sourceMatchesMirror", error) ||
        !FMRequireBool(mapping, @"readOnly", error) ||
        !FMIsNullOrString(mapping[@"filesystemType"])) {
        return error == NULL || *error == nil
                   ? FMCoordinatorFail(error, @"Invalid mapping evidence.")
                   : NO;
    }

    NSSet<NSString *> *scanStates =
        [NSSet setWithArray:@[ @"notApplicable", @"complete", @"incomplete", @"unsafe" ]];
    id stockCount = manifest[@"stockEntryCount"];
    id mirrorCount = manifest[@"mirrorEntryCount"];
    if (![scanStates containsObject:manifest[@"scanState"]] ||
        !FMIsNonemptyString(manifest[@"systemBuild"]) ||
        ![stockCount isKindOfClass:NSNumber.class] || FMIsJSONBoolean(stockCount) ||
        [stockCount integerValue] < 0 ||
        ![mirrorCount isKindOfClass:NSNumber.class] || FMIsJSONBoolean(mirrorCount) ||
        [mirrorCount integerValue] < 0 ||
        !FMRequireBool(manifest, @"matchesWorkingProfile", error) ||
        !FMValidatePathArray(manifest[@"changedPaths"], @"changedPaths", error) ||
        !FMValidatePathArray(manifest[@"missingPaths"], @"missingPaths", error) ||
        !FMValidatePathArray(manifest[@"unknownPaths"], @"unknownPaths", error) ||
        !FMValidatePathArray(manifest[@"typeChangedPaths"], @"typeChangedPaths", error)) {
        return error == NULL || *error == nil
                   ? FMCoordinatorFail(error, @"Invalid manifest evidence.")
                   : NO;
    }
    id stockManifestHash = manifest[@"stockManifestSHA256"];
    id mirrorManifestHash = manifest[@"mirrorManifestSHA256"];
    if ((stockManifestHash != nil && !FMIsLowercaseSHA256(stockManifestHash)) ||
        (mirrorManifestHash != nil && mirrorManifestHash != NSNull.null &&
         !FMIsLowercaseSHA256(mirrorManifestHash))) {
        return FMCoordinatorFail(error, @"Invalid manifest digest evidence.");
    }

    NSSet<NSString *> *mirrorStates =
        [NSSet setWithArray:@[ @"none", @"clean", @"updating", @"repairRequired" ]];
    if (!FMRequireBool(state, @"present", error) ||
        !FMRequireBool(state, @"valid", error) ||
        !FMIsNullOrString(state[@"systemBuild"]) ||
        ![mirrorStates containsObject:state[@"mirrorState"]]) {
        return error == NULL || *error == nil
                   ? FMCoordinatorFail(error, @"Invalid persistent state evidence.")
                   : NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMOperation(NSString *kind,
                                                  NSString *title,
                                                  NSArray<NSString *> *arguments) {
    return @{
        @"kind" : kind,
        @"title" : title,
        @"dryRun" : @YES,
        @"executable" : [kind isEqual:@"providerCommand"] ? @"mount_bindfs" : NSNull.null,
        @"arguments" : arguments,
    };
}

static void FMAddIssue(NSMutableArray<NSString *> *issues, NSString *issue) {
    if (![issues containsObject:issue]) {
        [issues addObject:issue];
    }
}

NSDictionary<NSString *, id> *FMCoordinateProviderInspection(
    NSDictionary<NSString *, id> *inspection,
    NSError **error) {
    if (!FMValidateProviderInspection(inspection, error)) {
        return nil;
    }

    NSDictionary *provider = inspection[@"provider"];
    NSDictionary *fonts = inspection[@"fonts"];
    NSDictionary *mapping = inspection[@"mapping"];
    NSDictionary *manifest = inspection[@"manifest"];
    NSDictionary *state = inspection[@"state"];
    NSString *systemBuild = inspection[@"systemBuild"];
    BOOL mappingActive = [mapping[@"active"] boolValue];
    NSString *mirrorKind = fonts[@"mirrorKind"];

    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    NSMutableArray<NSString *> *allowedActions = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *operations = [NSMutableArray array];
    NSString *classification = @"blocked";
    NSString *recommendedAction = @"reviewEvidence";
    BOOL requiresConfirmation = NO;

    if (![provider[@"packageInstalled"] boolValue] ||
        ![provider[@"executablePresent"] boolValue]) {
        classification = @"unavailable";
        recommendedAction = @"installProvider";
        FMAddIssue(issues, @"providerUnavailable");
    } else if (!FMProviderEvidenceSatisfiesCompatibilityContract(provider)) {
        classification = @"unavailable";
        recommendedAction = @"updateProviderAdapter";
        FMAddIssue(issues, @"providerCapabilityMismatch");
    } else if (![fonts[@"systemReadable"] boolValue] ||
               ![fonts[@"rootfsReadable"] boolValue]) {
        classification = @"unavailable";
        recommendedAction = @"repairRootfsAccess";
        FMAddIssue(issues, @"fontSourceUnavailable");
    } else {
        if (![fonts[@"mirrorInsideJBRoot"] boolValue]) {
            FMAddIssue(issues, @"mirrorOutsideJBRoot");
        }
        if (![fonts[@"rootfsDistinctFromMirror"] boolValue]) {
            FMAddIssue(issues, @"rootfsMirrorAliased");
        }
        if (mappingActive && (![mapping[@"targetMatches"] boolValue] ||
                              ![mapping[@"sourceMatchesMirror"] boolValue] ||
                              ![mapping[@"readOnly"] boolValue] ||
                              ![mapping[@"filesystemType"] isEqual:@"bindfs"])) {
            FMAddIssue(issues, @"unexpectedActiveMapping");
        }
        if (![manifest[@"systemBuild"] isEqual:systemBuild]) {
            FMAddIssue(issues, @"manifestBuildMismatch");
        }
        if ([state[@"present"] boolValue] &&
            (![state[@"valid"] boolValue] ||
             ![state[@"systemBuild"] isEqual:systemBuild])) {
            FMAddIssue(issues, @"stateInvalidOrBuildMismatch");
        }

        if (issues.count == 0 && [state[@"present"] boolValue]) {
            if (![state[@"mirrorState"] isEqual:@"clean"] ||
                ![manifest[@"matchesWorkingProfile"] boolValue]) {
                FMAddIssue(issues, @"repairRequired");
                recommendedAction = @"repairMirror";
                [allowedActions addObject:@"repairMirror"];
            } else if (![mirrorKind isEqual:@"present"] ||
                       ![manifest[@"scanState"] isEqual:@"complete"]) {
                FMAddIssue(issues, @"managedStateEvidenceMismatch");
            } else if (!mappingActive) {
                classification = @"managedInactive";
                recommendedAction = @"mountManagedMirror";
                [allowedActions addObject:@"mountManagedMirror"];
                [operations addObject:FMOperation(
                    @"providerCommand",
                    @"Remount the verified managed mirror without copying",
                    @[ @"--skip-copy", @"/System/Library/Fonts" ])];
            } else {
                classification = @"managedReady";
                recommendedAction = @"none";
            }
        } else if (issues.count == 0 && ![state[@"present"] boolValue]) {
            BOOL mirrorMissingOrEmpty =
                [mirrorKind isEqual:@"missing"] || [mirrorKind isEqual:@"empty"];
            if (mirrorMissingOrEmpty) {
                if (mappingActive) {
                    FMAddIssue(issues, @"activeMappingWithoutMirror");
                } else if (![manifest[@"scanState"] isEqual:@"notApplicable"]) {
                    FMAddIssue(issues, @"unexpectedEmptyMirrorManifest");
                } else {
                    classification = @"initializeEmptyMirror";
                    recommendedAction = @"initializeProvider";
                    requiresConfirmation = YES;
                    [allowedActions addObject:@"initializeProvider"];
                    [operations addObject:FMOperation(@"coordinator",
                                                     @"Capture Stock baseline manifest",
                                                     @[])];
                    [operations addObject:FMOperation(@"coordinator",
                                                     @"Build and verify Stock mirror in staging",
                                                     @[])];
                    [operations addObject:FMOperation(@"coordinator",
                                                     @"Atomically publish verified Stock mirror",
                                                     @[])];
                    [operations addObject:FMOperation(@"providerCommand",
                                                     @"Mount verified Stock mirror without copying",
                                                     @[ @"--skip-copy", @"/System/Library/Fonts" ])];
                    [operations addObject:FMOperation(@"coordinator",
                                                     @"Verify mapping and published mirror",
                                                     @[])];
                    [operations addObject:FMOperation(@"coordinator",
                                                     @"Create Stock state",
                                                     @[])];
                }
            } else if (![manifest[@"scanState"] isEqual:@"complete"] ||
                       [manifest[@"missingPaths"] count] > 0 ||
                       [manifest[@"unknownPaths"] count] > 0 ||
                       [manifest[@"typeChangedPaths"] count] > 0 ||
                       [manifest[@"stockEntryCount"] integerValue] !=
                           [manifest[@"mirrorEntryCount"] integerValue]) {
                FMAddIssue(issues, @"mirrorIncompleteOrUnsafe");
                recommendedAction = @"reviewMirrorDifferences";
                [allowedActions addObject:@"reviewMirrorDifferences"];
            } else if ([manifest[@"changedPaths"] count] == 0) {
                classification = @"adoptStockMirror";
                recommendedAction = @"adoptStockMirror";
                [allowedActions addObject:@"adoptStockMirror"];
                [operations addObject:FMOperation(@"coordinator",
                                                 @"Capture Stock baseline manifest",
                                                 @[])];
                if (!mappingActive) {
                    [operations addObject:FMOperation(@"providerCommand",
                                                     @"Mount verified mirror without copying",
                                                     @[ @"--skip-copy", @"/System/Library/Fonts" ])];
                }
                [operations addObject:FMOperation(@"coordinator",
                                                 @"Create Stock state",
                                                 @[])];
            } else {
                classification = @"adoptManualChanges";
                recommendedAction = @"importExistingDifferences";
                requiresConfirmation = YES;
                [allowedActions addObjectsFromArray:@[
                    @"importExistingDifferences", @"restoreStockWithConfirmation"
                ]];
                [operations addObject:FMOperation(@"coordinator",
                                                 @"Create Profile from verified changed files",
                                                 @[])];
                if (!mappingActive) {
                    [operations addObject:FMOperation(@"providerCommand",
                                                     @"Mount adopted mirror without copying",
                                                     @[ @"--skip-copy", @"/System/Library/Fonts" ])];
                }
                [operations addObject:FMOperation(@"coordinator",
                                                 @"Create adopted Profile state",
                                                 @[])];
            }
        }
    }

    if (issues.count > 0 && ![classification isEqual:@"unavailable"]) {
        classification = @"blocked";
    }

    return @{
        @"decisionVersion" : @(FMProviderDecisionVersion),
        @"evidenceMode" : inspection[@"evidenceMode"],
        @"readOnly" : @YES,
        @"executionPolicy" : @"previewOnly",
        @"classification" : classification,
        @"recommendedAction" : recommendedAction,
        @"requiresConfirmation" : @(requiresConfirmation),
        @"allowedActions" : allowedActions,
        @"operations" : operations,
        @"issues" : issues,
        @"changedPaths" : manifest[@"changedPaths"],
    };
}

NSString *FMProviderDecisionText(NSDictionary<NSString *, id> *decision) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:@[
        [NSString stringWithFormat:@"Classification: %@", decision[@"classification"]],
        [NSString stringWithFormat:@"Recommended: %@", decision[@"recommendedAction"]],
        [NSString stringWithFormat:@"Evidence: %@ (dry-run)", decision[@"evidenceMode"]],
    ]];

    NSArray<NSString *> *issues = decision[@"issues"];
    [lines addObject:issues.count == 0
                         ? @"Issues: none"
                         : [NSString stringWithFormat:@"Issues: %@",
                                                      [issues componentsJoinedByString:@", "]]];
    NSArray<NSString *> *actions = decision[@"allowedActions"];
    [lines addObject:actions.count == 0
                         ? @"Allowed actions: none"
                         : [NSString stringWithFormat:@"Allowed actions: %@",
                                                      [actions componentsJoinedByString:@", "]]];

    NSArray<NSDictionary<NSString *, id> *> *operations = decision[@"operations"];
    if (operations.count == 0) {
        [lines addObject:@"Plan: no operation"];
    } else {
        [lines addObject:@"Plan:"];
        [operations enumerateObjectsUsingBlock:^(NSDictionary<NSString *, id> *operation,
                                                  NSUInteger index,
                                                  BOOL *stop) {
            (void)stop;
            NSString *suffix = @"";
            if ([operation[@"kind"] isEqual:@"providerCommand"]) {
                suffix = [NSString stringWithFormat:@"\n    argv: %@ %@",
                                                    operation[@"executable"],
                                                    [operation[@"arguments"]
                                                        componentsJoinedByString:@" "]];
            }
            [lines addObject:[NSString stringWithFormat:@"%lu. %@%@",
                                                        (unsigned long)(index + 1),
                                                        operation[@"title"], suffix]];
        }];
    }
    return [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}
