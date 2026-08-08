#import <Foundation/Foundation.h>

#import "FMCoordinatorFixtures.h"
#import "FMMountCoordinator.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary<NSString *, id> *FMFixtureNamed(NSString *identifier) {
    for (NSDictionary<NSString *, id> *fixture in FMCoordinatorFixtures()) {
        if ([fixture[@"id"] isEqual:identifier]) {
            return fixture;
        }
    }
    return nil;
}

int main(void) {
    @autoreleasepool {
        NSArray<NSDictionary<NSString *, id> *> *fixtures = FMCoordinatorFixtures();
        FMRequire(fixtures.count == 12, @"unexpected fixture count");

        NSUInteger fixedMountCount = 0;
        for (NSDictionary<NSString *, id> *fixture in fixtures) {
            NSError *error = nil;
            NSDictionary<NSString *, id> *decision =
                FMCoordinateMountInspection(fixture[@"inspection"], &error);
            FMRequire(decision != nil && error == nil,
                      [NSString stringWithFormat:@"decision failed for %@", fixture[@"id"]]);
            FMRequire([decision[@"classification"] isEqual:fixture[@"expectedClassification"]],
                      [NSString stringWithFormat:@"classification mismatch for %@",
                                                 fixture[@"id"]]);
            FMRequire([decision[@"readOnly"] isEqual:@YES] &&
                          [decision[@"executionPolicy"] isEqual:@"previewOnly"],
                      @"decision is not explicitly preview-only");

            for (NSDictionary<NSString *, id> *operation in decision[@"operations"]) {
                FMRequire([operation[@"dryRun"] isEqual:@YES],
                          @"operation is not marked dry-run");
                NSArray<NSString *> *arguments = operation[@"arguments"];
                FMRequire(![arguments containsObject:@"--copy"] &&
                              ![arguments containsObject:@"--skip-copy"],
                          @"a legacy Provider argument entered a Coordinator plan");
                if ([arguments containsObject:@"mount-fonts"]) {
                    fixedMountCount += 1;
                    NSDictionary *manifest = fixture[@"inspection"][@"manifest"];
                    BOOL initializesVerifiedStaging =
                        [fixture[@"id"] isEqual:@"empty"];
                    BOOL reusesCompleteMirror =
                        [manifest[@"scanState"] isEqual:@"complete"] &&
                        [manifest[@"stockEntryCount"] isEqual:
                            manifest[@"mirrorEntryCount"]];
                    FMRequire(initializesVerifiedStaging || reusesCompleteMirror,
                              @"fixed mount lacks complete-mirror evidence");
                }
            }
        }
        FMRequire(fixedMountCount == 4, @"unexpected fixed-mount plan count");
        FMRequire([fixtures.firstObject[@"inspection"][@"mountBackend"][@"version"]
                      isEqual:@"2"] &&
                      [fixtures.firstObject[@"inspection"][@"mountBackend"]
                          [@"recognition"] isEqual:@"known"],
                  @"built-in backend fixture lost its version identity");

        NSDictionary<NSString *, id> *managedInactive =
            FMFixtureNamed(@"managed-inactive");
        NSError *autoMountError = nil;
        NSDictionary<NSString *, id> *autoMountDecision =
            FMCoordinateMountInspection(managedInactive[@"inspection"],
                                           &autoMountError);
        FMRequire(autoMountDecision != nil && autoMountError == nil,
                  @"managed-inactive fixture failed");
        FMRequire([autoMountDecision[@"recommendedAction"]
                      isEqual:@"mountManagedMirror"] &&
                      [autoMountDecision[@"requiresConfirmation"] isEqual:@NO] &&
                      [autoMountDecision[@"allowedActions"]
                          isEqual:@[ @"mountManagedMirror" ]] &&
                      [autoMountDecision[@"operations"] count] == 1,
                  @"managed-inactive did not produce one automatic mount plan");
        NSDictionary *autoMountOperation =
            [autoMountDecision[@"operations"] firstObject];
        FMRequire([autoMountOperation[@"arguments"]
                      isEqual:@[ @"mount-fonts" ]],
                  @"automatic mount plan is not the fixed backend operation");

        NSDictionary<NSString *, id> *manualMounted = FMFixtureNamed(@"manual-mounted");
        NSError *manualError = nil;
        NSDictionary<NSString *, id> *manualDecision =
            FMCoordinateMountInspection(manualMounted[@"inspection"], &manualError);
        FMRequire(manualDecision != nil && manualError == nil,
                  @"mounted manual fixture failed");
        FMRequire([manualDecision[@"recommendedAction"]
                      isEqual:@"importExistingDifferences"],
                  @"mounted manual changes were not preserved");
        for (NSDictionary<NSString *, id> *operation in manualDecision[@"operations"]) {
            FMRequire(![operation[@"kind"] isEqual:@"mountBackendCommand"],
                      @"mounted manual mirror planned a redundant backend command");
        }

        NSMutableDictionary<NSString *, id> *unsafeInspection =
            [FMFixtureNamed(@"empty")[@"inspection"] mutableCopy];
        NSMutableDictionary<NSString *, id> *unsafeManifest =
            [unsafeInspection[@"manifest"] mutableCopy];
        unsafeManifest[@"changedPaths"] = @[ @"../escape.ttf" ];
        unsafeInspection[@"manifest"] = unsafeManifest;
        NSError *unsafeError = nil;
        FMRequire(FMCoordinateMountInspection(unsafeInspection, &unsafeError) == nil &&
                      [unsafeError.domain isEqual:FMMountCoordinatorErrorDomain],
                  @"unsafe relative path was accepted");

        printf("PASS: mount Coordinator fixture matrix (12 scenarios)\n");
    }
    return 0;
}
