#import "FMStatusContract.h"

#import <CoreFoundation/CoreFoundation.h>

NSInteger const FMStatusAPIVersion = 2;
NSString *const FMStatusErrorDomain = @"com.hmmzzz.fontmanager.status";

static BOOL FMStatusFail(NSError **error, NSString *message) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:FMStatusErrorDomain
                                     code:FMStatusErrorInvalidDocument
                                 userInfo:@{NSLocalizedDescriptionKey : message}];
    }
    return NO;
}

static BOOL FMIsStringOrNull(id value) {
    return [value isKindOfClass:NSString.class] || value == NSNull.null;
}

static BOOL FMRequireDictionary(NSDictionary *document,
                                NSString *key,
                                NSDictionary **result,
                                NSError **error) {
    id value = document[key];
    if (![value isKindOfClass:NSDictionary.class]) {
        return FMStatusFail(error, [NSString stringWithFormat:@"Missing dictionary: %@", key]);
    }
    if (result != NULL) {
        *result = value;
    }
    return YES;
}

static BOOL FMRequireBool(NSDictionary *document, NSString *key, NSError **error) {
    id value = document[key];
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        return FMStatusFail(error, [NSString stringWithFormat:@"Missing boolean: %@", key]);
    }
    return YES;
}

BOOL FMValidateStatusDocument(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMStatusFail(error, @"Status root must be a dictionary.");
    }

    NSDictionary *document = object;
    NSNumber *apiVersion = document[@"apiVersion"];
    if (![apiVersion isKindOfClass:NSNumber.class] || apiVersion.integerValue != FMStatusAPIVersion) {
        return FMStatusFail(error, @"Unsupported status API version.");
    }

    if (![document[@"mode"] isEqual:@"readOnlyFoundation"] ||
        ![document[@"generatedAt"] isKindOfClass:NSString.class]) {
        return FMStatusFail(error, @"Invalid status mode or timestamp.");
    }

    NSString *engineState = document[@"engineState"];
    NSSet<NSString *> *allowedEngineStates = [NSSet setWithArray:@[
        @"unavailable", @"notInitialized", @"attentionRequired", @"ready"
    ]];
    if (![engineState isKindOfClass:NSString.class] ||
        ![allowedEngineStates containsObject:engineState]) {
        return FMStatusFail(error, @"Invalid engine state.");
    }

    NSDictionary *system = nil;
    NSDictionary *mountBackend = nil;
    NSDictionary *fonts = nil;
    NSDictionary *state = nil;
    NSDictionary *capabilities = nil;
    if (!FMRequireDictionary(document, @"system", &system, error) ||
        !FMRequireDictionary(document, @"mountBackend", &mountBackend, error) ||
        !FMRequireDictionary(document, @"fonts", &fonts, error) ||
        !FMRequireDictionary(document, @"state", &state, error) ||
        !FMRequireDictionary(document, @"capabilities", &capabilities, error)) {
        return NO;
    }

    for (NSString *key in @[ @"productType", @"productVersion", @"productBuildVersion", @"environment" ]) {
        if (![system[key] isKindOfClass:NSString.class]) {
            return FMStatusFail(error, [NSString stringWithFormat:@"Invalid system field: %@", key]);
        }
    }

    if (![mountBackend[@"identifier"] isKindOfClass:NSString.class] ||
        ![mountBackend[@"version"] isKindOfClass:NSString.class] ||
        ![mountBackend[@"executableLogicalPath"] isKindOfClass:NSString.class] ||
        ![mountBackend[@"runtimeLibraryLogicalPath"] isKindOfClass:NSString.class] ||
        ![mountBackend[@"contractVersion"] isKindOfClass:NSNumber.class] ||
        [mountBackend[@"contractVersion"] integerValue] <= 0 ||
        ![@[ @"known", @"unknown" ]
            containsObject:mountBackend[@"recognition"]] ||
        ![@[ @"compatible", @"incompatible" ]
            containsObject:mountBackend[@"compatibility"]]) {
        return FMStatusFail(error, @"Invalid mount backend identity fields.");
    }
    if (!FMRequireBool(mountBackend, @"executablePresent", error) ||
        !FMRequireBool(mountBackend, @"runtimeLibraryPresent", error) ||
        !FMRequireBool(mountBackend, @"runtimeLibrarySecure", error) ||
        !FMRequireBool(mountBackend, @"compatible", error) ||
        !FMRequireBool(mountBackend, @"executableSecure", error) ||
        !FMRequireBool(mountBackend, @"machOExecutable", error) ||
        !FMRequireBool(mountBackend, @"supportsReadOnlyMount", error) ||
        !FMRequireBool(mountBackend, @"supportsForceUnmount", error)) {
        return NO;
    }
    if ([mountBackend[@"compatible"] boolValue] !=
        [mountBackend[@"compatibility"] isEqual:@"compatible"]) {
        return FMStatusFail(
            error, @"Inconsistent mount backend compatibility status.");
    }

    for (NSString *key in @[
             @"systemDirectoryReadable", @"rootfsDirectoryReadable",
             @"mountStorageSupported", @"mountStorageShared",
             @"legacyProviderPreferencePresent",
             @"legacyProviderAutoMountConflictsWithFonts",
             @"mirrorPresent", @"mappingActive", @"mappingManaged",
             @"stockSnapshotPresent"
         ]) {
        if (!FMRequireBool(fonts, key, error)) {
            return NO;
        }
    }
    if (!FMIsStringOrNull(fonts[@"targetFilesystemType"])) {
        return FMStatusFail(error, @"Invalid target filesystem type.");
    }
    for (NSString *key in @[
             @"present", @"valid", @"restartRequired", @"autoMount",
             @"autoRespring"
         ]) {
        if (!FMRequireBool(state, key, error)) {
            return NO;
        }
    }
    if (!FMIsStringOrNull(state[@"schemaVersion"]) ||
        !FMIsStringOrNull(state[@"systemBuild"]) ||
        !FMIsStringOrNull(state[@"confirmedProfileID"]) ||
        !FMIsStringOrNull(state[@"workingProfileID"]) ||
        !FMIsStringOrNull(state[@"refreshReason"]) ||
        ![state[@"mirrorState"] isKindOfClass:NSString.class]) {
        return FMStatusFail(error, @"Invalid persistent state summary.");
    }

    for (NSString *key in @[
             @"readOnlyStatus", @"initializeMirror", @"stageProfile", @"stageStock",
             @"repair", @"safeUnmount", @"respring", @"userspaceReboot"
         ]) {
        if (!FMRequireBool(capabilities, key, error)) {
            return NO;
        }
    }

    NSArray *issues = document[@"issues"];
    if (![issues isKindOfClass:NSArray.class]) {
        return FMStatusFail(error, @"Issues must be an array.");
    }
    for (id issue in issues) {
        if (![issue isKindOfClass:NSString.class]) {
            return FMStatusFail(error, @"Issue codes must be strings.");
        }
    }

    return YES;
}

NSString *FMEngineStateForFacts(NSDictionary<NSString *, id> *mountBackend,
                                NSDictionary<NSString *, id> *fonts,
                                NSDictionary<NSString *, id> *state) {
    BOOL systemReadable = [fonts[@"systemDirectoryReadable"] boolValue];
    BOOL rootfsReadable = [fonts[@"rootfsDirectoryReadable"] boolValue];
    BOOL backendExecutablePresent =
        [mountBackend[@"executablePresent"] boolValue];
    BOOL backendCompatible = [mountBackend[@"compatible"] boolValue];
    if (!systemReadable || !rootfsReadable || !backendExecutablePresent ||
        !backendCompatible) {
        return @"unavailable";
    }

    BOOL statePresent = [state[@"present"] boolValue];
    BOOL mirrorPresent = [fonts[@"mirrorPresent"] boolValue];
    BOOL mappingActive = [fonts[@"mappingActive"] boolValue];
    if (!statePresent) {
        return mirrorPresent || mappingActive ? @"attentionRequired" : @"notInitialized";
    }

    if (![state[@"valid"] boolValue] || ![state[@"mirrorState"] isEqual:@"clean"] ||
        !mirrorPresent || !mappingActive) {
        return @"attentionRequired";
    }
    return @"ready";
}

static NSString *FMStatusString(id value, NSString *fallback) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : fallback;
}

static NSString *FMStatusYesNo(id value) {
    return [value isKindOfClass:NSNumber.class] && [value boolValue] ? @"yes" : @"no";
}

NSString *FMStatusHumanReadableText(NSDictionary<NSString *, id> *document) {
    NSDictionary *system = document[@"system"];
    NSDictionary *mountBackend = document[@"mountBackend"];
    NSDictionary *fonts = document[@"fonts"];
    NSDictionary *state = document[@"state"];
    NSArray<NSString *> *issues = document[@"issues"];

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:@[
        @"Font Manager status",
        [NSString stringWithFormat:@"engine: %@", FMStatusString(document[@"engineState"], @"unknown")],
        [NSString stringWithFormat:@"system: %@ / iOS %@ (%@)",
                                   FMStatusString(system[@"productType"], @"unknown"),
                                   FMStatusString(system[@"productVersion"], @"unknown"),
                                   FMStatusString(system[@"productBuildVersion"], @"unknown")],
        [NSString stringWithFormat:@"mount backend: id=%@ executable=%@ runtime=%@ compatible=%@ version=%@ recognition=%@",
                                   FMStatusString(mountBackend[@"identifier"], @"unknown"),
                                   FMStatusYesNo(mountBackend[@"executablePresent"]),
                                   FMStatusYesNo(mountBackend[@"runtimeLibraryPresent"]),
                                   FMStatusYesNo(mountBackend[@"compatible"]),
                                   FMStatusString(mountBackend[@"version"], @"unknown"),
                                   FMStatusString(mountBackend[@"recognition"], @"unknown")],
        [NSString stringWithFormat:@"fonts: system=%@ rootfs=%@ mirror=%@ mapping=%@ filesystem=%@",
                                   FMStatusYesNo(fonts[@"systemDirectoryReadable"]),
                                   FMStatusYesNo(fonts[@"rootfsDirectoryReadable"]),
                                   FMStatusYesNo(fonts[@"mirrorPresent"]),
                                   FMStatusYesNo(fonts[@"mappingActive"]),
                                   FMStatusString(fonts[@"targetFilesystemType"], @"unknown")],
        [NSString stringWithFormat:@"state: present=%@ valid=%@ mirror=%@ restart=%@ refresh=%@ auto-mount=%@ auto-respring=%@",
                                   FMStatusYesNo(state[@"present"]),
                                   FMStatusYesNo(state[@"valid"]),
                                   FMStatusString(state[@"mirrorState"], @"unknown"),
                                   FMStatusYesNo(state[@"restartRequired"]),
                                   FMStatusString(state[@"refreshReason"], @"none"),
                                   FMStatusYesNo(state[@"autoMount"]),
                                   FMStatusYesNo(state[@"autoRespring"])],
    ]];

    if (issues.count == 0) {
        [lines addObject:@"issues: none"];
    } else {
        [lines addObject:[NSString stringWithFormat:@"issues: %@", [issues componentsJoinedByString:@", "]]];
    }
    [lines addObject:@"capability: read-only status only"];
    return [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}
