#import <Foundation/Foundation.h>

#import "FMAutomaticRespringPolicy.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary<NSString *, id> *FMEligibleReport(void) {
    return @{
        @"status" : @"mounted",
        @"systemBuild" : @"21D61",
        @"workingProfileID" : @"custom-font",
        @"autoMountEnabled" : @YES,
        @"autoRespringEnabled" : @YES,
        @"mountBackendInvoked" : @YES,
        @"mountBackendReportedSuccess" : @YES,
        @"mappingChanged" : @YES,
        @"mappingActive" : @YES,
        @"mappingReadOnly" : @YES,
        @"stateChanged" : @YES,
        @"lateAutomaticMountPending" : @YES,
        @"activationRefreshRequired" : @YES,
        @"springBoardObservationAvailable" : @YES,
        @"springBoardWasRunning" : @YES,
        @"restartRequested" : @NO,
    };
}

int main(void) {
    @autoreleasepool {
        NSDictionary *confirmedState = @{
            @"confirmedProfileID" : @"custom-font",
            @"workingProfileID" : @"custom-font",
            @"restartRequired" : @NO,
            @"refreshReason" : NSNull.null,
            @"mirrorState" : @"clean",
        };
        FMRequire(FMAutomaticMountStateAllowsTrustedMirror(confirmedState),
                  @"confirmed clean mirror was rejected");

        NSMutableDictionary *lateState = [confirmedState mutableCopy];
        lateState[@"restartRequired"] = @YES;
        lateState[@"refreshReason"] = @"lateAutomaticMount";
        FMRequire(FMAutomaticMountStateAllowsTrustedMirror(lateState),
                  @"late custom-font refresh was rejected");

        NSMutableDictionary *pendingCustom = [confirmedState mutableCopy];
        pendingCustom[@"confirmedProfileID"] = NSNull.null;
        pendingCustom[@"restartRequired"] = @YES;
        pendingCustom[@"refreshReason"] = @"profileChange";
        FMRequire(FMAutomaticMountStateHasPendingProfileChange(pendingCustom) &&
                      FMAutomaticMountStateAllowsTrustedMirror(pendingCustom),
                  @"reboot-interrupted custom Profile was rejected");

        NSMutableDictionary *pendingStock = [pendingCustom mutableCopy];
        pendingStock[@"confirmedProfileID"] = @"custom-font";
        pendingStock[@"workingProfileID"] = NSNull.null;
        FMRequire(FMAutomaticMountStateHasPendingProfileChange(pendingStock) &&
                      FMAutomaticMountStateAllowsTrustedMirror(pendingStock),
                  @"reboot-interrupted Stock selection was rejected");

        for (NSDictionary *blockedState in @[
                 @{
                     @"confirmedProfileID" : NSNull.null,
                     @"workingProfileID" : @"custom-font",
                     @"restartRequired" : @NO,
                     @"refreshReason" : NSNull.null,
                     @"mirrorState" : @"clean",
                 },
                 @{
                     @"confirmedProfileID" : NSNull.null,
                     @"workingProfileID" : @"custom-font",
                     @"restartRequired" : @YES,
                     @"refreshReason" : @"lateAutomaticMount",
                     @"mirrorState" : @"clean",
                 },
                 @{
                     @"confirmedProfileID" : NSNull.null,
                     @"workingProfileID" : @"custom-font",
                     @"restartRequired" : @YES,
                     @"refreshReason" : @"profileChange",
                     @"mirrorState" : @"repairRequired",
                 },
             ]) {
            FMRequire(!FMAutomaticMountStateAllowsTrustedMirror(blockedState),
                      @"unsafe pending mirror state was accepted");
        }

        NSDictionary *eligible = FMEligibleReport();
        FMRequire(FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      eligible, YES, YES),
                  @"exact late launchd mount did not request restart evidence");
        FMRequire(FMAutomaticRespringEligibleForReport(eligible, YES, YES),
                  @"exact late launchd mount was rejected");
        FMRequire(!FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      eligible, NO, YES),
                  @"non-exact command invocation requested restart evidence");
        FMRequire(!FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      eligible, YES, NO),
                  @"non-launchd invocation requested restart evidence");
        FMRequire(!FMAutomaticRespringEligibleForReport(eligible, NO, YES),
                  @"non-exact command invocation was accepted");
        FMRequire(!FMAutomaticRespringEligibleForReport(eligible, YES, NO),
                  @"non-launchd invocation was accepted");

        for (NSString *key in @[
                 @"autoMountEnabled",
                 @"mountBackendInvoked", @"mountBackendReportedSuccess",
                 @"mappingChanged", @"mappingActive", @"mappingReadOnly",
                 @"lateAutomaticMountPending", @"activationRefreshRequired",
                 @"springBoardObservationAvailable", @"springBoardWasRunning"
             ]) {
            NSMutableDictionary *blocked = [eligible mutableCopy];
            blocked[key] = @NO;
            FMRequire(!FMLateAutomaticMountNeedsRestartEvidenceForReport(
                          blocked, YES, YES),
                      [NSString stringWithFormat:
                          @"false %@ evidence gate was accepted", key]);
            FMRequire(!FMAutomaticRespringEligibleForReport(blocked, YES, YES),
                      [NSString stringWithFormat:@"false %@ gate was accepted", key]);
        }

        NSMutableDictionary *manualRefresh = [eligible mutableCopy];
        manualRefresh[@"autoRespringEnabled"] = @NO;
        FMRequire(FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      manualRefresh, YES, YES),
                  @"late mount evidence incorrectly depended on auto-Respring");
        FMRequire(!FMAutomaticRespringEligibleForReport(
                      manualRefresh, YES, YES),
                  @"disabled auto-Respring was still eligible for execution");

        NSMutableDictionary *existingPending = [eligible mutableCopy];
        existingPending[@"stateChanged"] = @NO;
        FMRequire(FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      existingPending, YES, YES),
                  @"an existing late-mount state could not refresh its evidence");
        FMRequire(FMAutomaticRespringEligibleForReport(
                      existingPending, YES, YES),
                  @"an existing late-mount state could not auto-Respring");

        NSMutableDictionary *alreadyMounted = [eligible mutableCopy];
        alreadyMounted[@"status"] = @"alreadyMounted";
        FMRequire(!FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      alreadyMounted, YES, YES),
                  @"an existing mapping could rewrite restart evidence");
        FMRequire(!FMAutomaticRespringEligibleForReport(alreadyMounted, YES, YES),
                  @"an existing mapping could trigger a repeated Respring");

        NSMutableDictionary *recoveredProfile = [eligible mutableCopy];
        recoveredProfile[@"lateAutomaticMountPending"] = @NO;
        recoveredProfile[@"pendingProfileChange"] = @YES;
        recoveredProfile[@"staleRestartEvidenceCleared"] = @YES;
        recoveredProfile[@"manualRespringRequired"] = @YES;
        FMRequire(!FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      recoveredProfile, YES, YES),
                  @"recovered Profile attempted to arm evidence automatically");
        FMRequire(!FMAutomaticRespringEligibleForReport(
                      recoveredProfile, YES, YES),
                  @"ordinary Profile recovery triggered automatic Respring");

        NSMutableDictionary *stock = [eligible mutableCopy];
        stock[@"workingProfileID"] = NSNull.null;
        FMRequire(!FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      stock, YES, YES),
                  @"Stock mounting could request restart evidence");
        FMRequire(!FMAutomaticRespringEligibleForReport(stock, YES, YES),
                  @"Stock mounting could trigger an automatic Respring");
        NSMutableDictionary *alreadyRequested = [eligible mutableCopy];
        alreadyRequested[@"restartRequested"] = @YES;
        FMRequire(!FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      alreadyRequested, YES, YES),
                  @"an existing restart request could be replaced");
        FMRequire(!FMAutomaticRespringEligibleForReport(
                      alreadyRequested, YES, YES),
                  @"an already-requested refresh could repeat");
        NSMutableDictionary *numericBoolean = [eligible mutableCopy];
        numericBoolean[@"mappingChanged"] = @1;
        FMRequire(!FMLateAutomaticMountNeedsRestartEvidenceForReport(
                      numericBoolean, YES, YES),
                  @"a numeric pseudo-boolean bypassed an evidence gate");
        FMRequire(!FMAutomaticRespringEligibleForReport(
                      numericBoolean, YES, YES),
                  @"a numeric pseudo-boolean bypassed a launch gate");

        puts("PASS: automatic Respring launch policy");
    }
    return 0;
}
