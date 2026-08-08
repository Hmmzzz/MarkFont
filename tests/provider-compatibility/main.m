#import <Foundation/Foundation.h>

#import <mach-o/loader.h>

#import "FMMountBackendCompatibility.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        uint32_t magic = MH_MAGIC_64;
        NSData *machOPrefix = [NSData dataWithBytes:&magic length:sizeof(magic)];
        NSDictionary *analysis =
            FMMountBackendAnalyzeExecutablePrefix(machOPrefix);
        FMRequire([analysis[@"machOExecutable"] boolValue] &&
                      [analysis[@"supportsReadOnlyMount"] boolValue] &&
                      [analysis[@"supportsForceUnmount"] boolValue],
                  @"Mach-O backend did not satisfy the fixed capability contract");

        FMRequire([FMMountBackendRecognitionForVersion(@"1") isEqual:@"known"] &&
                      [FMMountBackendRecognitionForVersion(@"2")
                          isEqual:@"known"] &&
                      [FMMountBackendRecognitionForVersion(@"3")
                          isEqual:@"unknown"],
                  @"backend version recognition is incorrect");

        NSMutableDictionary *evidence = [analysis mutableCopy];
        [evidence addEntriesFromDictionary:@{
            @"identifier" : @"markfont-bindfs",
            @"version" : @"2",
            @"executablePresent" : @YES,
            @"runtimeLibraryPresent" : @YES,
            @"runtimeLibrarySecure" : @YES,
            @"recognition" : @"known",
            @"compatibility" : @"compatible",
            @"compatible" : @YES,
            @"executableSecure" : @YES,
            @"storageSupported" : @YES,
            @"legacyProviderPreferencePresent" : @NO,
            @"legacyProviderAutoMountConflictsWithFonts" : @NO,
        }];
        FMRequire(FMMountBackendEvidenceSatisfiesCompatibilityContract(evidence),
                  @"valid built-in backend evidence was rejected");

        evidence[@"runtimeLibrarySecure"] = @NO;
        FMRequire(!FMMountBackendEvidenceSatisfiesCompatibilityContract(evidence),
                  @"unsafe runtime library was accepted");

        NSData *scriptPrefix =
            [@"#!/bin/sh\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *scriptAnalysis =
            FMMountBackendAnalyzeExecutablePrefix(scriptPrefix);
        FMRequire(![scriptAnalysis[@"machOExecutable"] boolValue] &&
                      ![scriptAnalysis[@"supportsReadOnlyMount"] boolValue],
                  @"a shell wrapper was accepted as the built-in backend");

        printf("PASS: built-in mount backend capability contract\n");
    }
    return 0;
}
