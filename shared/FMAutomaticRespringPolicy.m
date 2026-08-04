#import "FMAutomaticRespringPolicy.h"

#import <CoreFoundation/CoreFoundation.h>

static BOOL FMAutomaticRespringPolicyBoolean(id value, BOOL expected) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() &&
        [value boolValue] == expected;
}

BOOL FMAutomaticRespringEligibleForReport(
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
        FMAutomaticRespringPolicyBoolean(report[@"autoRespringEnabled"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"providerInvoked"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"providerReportedSuccess"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"mappingChanged"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"mappingActive"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"mappingReadOnly"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"stateChanged"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"activationRefreshRequired"], YES) &&
        FMAutomaticRespringPolicyBoolean(
            report[@"springBoardObservationAvailable"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"springBoardWasRunning"], YES) &&
        FMAutomaticRespringPolicyBoolean(report[@"restartRequested"], NO);
}
