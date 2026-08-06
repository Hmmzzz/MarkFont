#import <Foundation/Foundation.h>

#import "FMStatusContract.h"

static void FMTestRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary *FMValidFixture(void) {
    return @{
        @"apiVersion" : @2,
        @"mode" : @"readOnlyFoundation",
        @"generatedAt" : @"2026-08-02T12:00:00Z",
        @"engineState" : @"notInitialized",
        @"system" : @{
            @"productType" : @"iPhone16,1",
            @"productVersion" : @"17.3.1",
            @"productBuildVersion" : @"21D61",
            @"environment" : @"device",
        },
        @"mountBackend" : @{
            @"identifier" : @"markfont-bindfs",
            @"version" : @"1",
            @"executablePresent" : @YES,
            @"executableLogicalPath" : @"/usr/libexec/markfont-bindfs",
            @"runtimeLibraryLogicalPath" : @"/basebin/libjailbreak.dylib",
            @"runtimeLibraryPresent" : @YES,
            @"runtimeLibrarySecure" : @YES,
            @"contractVersion" : @1,
            @"recognition" : @"known",
            @"compatibility" : @"compatible",
            @"compatible" : @YES,
            @"executableSecure" : @YES,
            @"machOExecutable" : @YES,
            @"supportsReadOnlyMount" : @YES,
            @"supportsForceUnmount" : @YES,
        },
        @"fonts" : @{
            @"systemDirectoryReadable" : @YES,
            @"rootfsDirectoryReadable" : @YES,
            @"mountStorageSupported" : @YES,
            @"mountStorageShared" : @YES,
            @"legacyProviderPreferencePresent" : @NO,
            @"legacyProviderAutoMountConflictsWithFonts" : @NO,
            @"mirrorPresent" : @NO,
            @"mappingActive" : @NO,
            @"mappingManaged" : @NO,
            @"stockSnapshotPresent" : @NO,
            @"targetFilesystemType" : @"apfs",
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
        @"issues" : @[ @"state.notInitialized" ],
    };
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        NSDictionary *fixture = FMValidFixture();
        FMTestRequire(FMValidateStatusDocument(fixture, &error),
                      error.localizedDescription ?: @"valid fixture rejected");

        NSMutableDictionary *invalidVersion = [fixture mutableCopy];
        invalidVersion[@"apiVersion"] = @99;
        error = nil;
        FMTestRequire(!FMValidateStatusDocument(invalidVersion, &error),
                      @"unsupported API version accepted");

        NSMutableDictionary *invalidIssues = [fixture mutableCopy];
        invalidIssues[@"issues"] = @[ @1 ];
        error = nil;
        FMTestRequire(!FMValidateStatusDocument(invalidIssues, &error),
                      @"non-string issue code accepted");

        NSMutableDictionary *numericBoolean = [fixture mutableCopy];
        NSMutableDictionary *numericBackend = [fixture[@"mountBackend"] mutableCopy];
        numericBackend[@"runtimeLibraryPresent"] = @1;
        numericBoolean[@"mountBackend"] = numericBackend;
        error = nil;
        FMTestRequire(!FMValidateStatusDocument(numericBoolean, &error),
                      @"numeric non-boolean accepted by status contract");

        NSMutableDictionary *missingPolicy = [fixture mutableCopy];
        NSMutableDictionary *missingPolicyState = [fixture[@"state"] mutableCopy];
        [missingPolicyState removeObjectForKey:@"autoRespring"];
        missingPolicy[@"state"] = missingPolicyState;
        error = nil;
        FMTestRequire(!FMValidateStatusDocument(missingPolicy, &error),
                      @"status without autoRespring summary was accepted");

        NSString *human = FMStatusHumanReadableText(fixture);
        FMTestRequire([human containsString:@"engine: notInitialized"],
                      @"human output omitted engine state");
        FMTestRequire([human containsString:@"auto-mount=no"],
                      @"human output omitted automatic-mount policy");
        FMTestRequire([human containsString:@"auto-respring=no"],
                      @"human output omitted automatic-Respring policy");
        FMTestRequire([human containsString:@"markfont-bindfs"],
                      @"human output omitted the built-in backend identity");

        NSDictionary *backend = fixture[@"mountBackend"];
        NSDictionary *fonts = fixture[@"fonts"];
        NSDictionary *state = fixture[@"state"];
        FMTestRequire([FMEngineStateForFacts(backend, fonts, state) isEqual:@"notInitialized"],
                      @"empty managed state should be notInitialized");

        NSMutableDictionary *existingMirror = [fonts mutableCopy];
        existingMirror[@"mirrorPresent"] = @YES;
        FMTestRequire([FMEngineStateForFacts(backend, existingMirror, state)
                          isEqual:@"attentionRequired"],
                      @"unmanaged mirror should require attention");

        NSMutableDictionary *missingBackend = [backend mutableCopy];
        missingBackend[@"executablePresent"] = @NO;
        FMTestRequire([FMEngineStateForFacts(missingBackend, fonts, state) isEqual:@"unavailable"],
                      @"missing mount backend executable should be unavailable");

        NSMutableDictionary *incompatibleBackend = [backend mutableCopy];
        incompatibleBackend[@"compatible"] = @NO;
        incompatibleBackend[@"compatibility"] = @"incompatible";
        FMTestRequire([FMEngineStateForFacts(incompatibleBackend, fonts, state)
                          isEqual:@"unavailable"],
                      @"incompatible mount backend should be unavailable");

        NSMutableDictionary *readyFonts = [fonts mutableCopy];
        readyFonts[@"mirrorPresent"] = @YES;
        readyFonts[@"mappingActive"] = @YES;
        NSMutableDictionary *readyState = [state mutableCopy];
        readyState[@"present"] = @YES;
        readyState[@"valid"] = @YES;
        readyState[@"mirrorState"] = @"clean";
        FMTestRequire([FMEngineStateForFacts(backend, readyFonts, readyState) isEqual:@"ready"],
                      @"consistent managed state should be ready");

        printf("PASS: status contract\n");
    }
    return 0;
}
