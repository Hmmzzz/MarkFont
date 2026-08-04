#import "FMAutomaticRespringPolicy.h"

#import <CoreFoundation/CoreFoundation.h>

static BOOL FMAutomaticRespringPolicyBoolean(id value, BOOL expected) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() &&
        [value boolValue] == expected;
}

BOOL FMLateAutomaticMountNeedsRestartEvidenceForReport(
    NSDictionary<NSString *, id> *report,
    BOOL exactLaunchdInvocation,
    BOOL launchdService) {
    return [report isKindOfClass:NSDictionary.class] &&
        exactLaunchdInvocation && launchdService &&
        [report[@"status"] isEqual:@"mounted"] &&
        [report[@"systemBuild"] isKindOfClass:NSString.class] &&
        [report[@"systemBuild"] length] > 0 &&
        [report[@"workingProfileID"] isKindOfClass:NSString.class] &&
        [report[@"workingProfileID"] length] > 0 &&
        FMAutomaticRespringPolicyBoolean(report[@"autoMountEnabled"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"mountBackendInvoked"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"mountBackendReportedSuccess"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"mappingChanged"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"mappingActive"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"mappingReadOnly"], YES) &&
        FMAutomaticRespringPolicyBoolean(
            report[@"lateAutomaticMountPending"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"activationRefreshRequired"], YES) &&
        FMAutomaticRespringPolicyBoolean(
            report[@"springBoardObservationAvailable"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"springBoardWasRunning"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"restartRequested"], NO);
}

BOOL FMAutomaticRespringEligibleForReport(
    NSDictionary<NSString *, id> *report,
    BOOL exactLaunchdInvocation,
    BOOL launchdService) {
    return FMLateAutomaticMountNeedsRestartEvidenceForReport(
               report, exactLaunchdInvocation, launchdService) &&
        FMAutomaticRespringPolicyBoolean(report[@"autoRespringEnabled"], YES);
}
