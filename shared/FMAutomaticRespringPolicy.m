#import "FMAutomaticRespringPolicy.h"

#import <CoreFoundation/CoreFoundation.h>

static BOOL FMAutomaticRespringPolicyBoolean(id value, BOOL expected) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() &&
        [value boolValue] == expected;
}

static BOOL FMAutomaticMountPolicyProfileIDIsValid(id profileID) {
    return profileID == NSNull.null ||
        ([profileID isKindOfClass:NSString.class] &&
         [profileID length] > 0);
}

static BOOL FMAutomaticMountPolicyProfileIDsEqual(id left, id right) {
    BOOL leftIsStock = left == NSNull.null;
    BOOL rightIsStock = right == NSNull.null;
    return leftIsStock || rightIsStock
        ? leftIsStock && rightIsStock
        : [left isEqual:right];
}

BOOL FMAutomaticMountStateHasPendingProfileChange(
    NSDictionary<NSString *, id> *state) {
    if (![state isKindOfClass:NSDictionary.class]) return NO;
    id confirmedProfileID = state[@"confirmedProfileID"];
    id workingProfileID = state[@"workingProfileID"];
    id refreshReason = state[@"refreshReason"];
    return FMAutomaticMountPolicyProfileIDIsValid(confirmedProfileID) &&
        FMAutomaticMountPolicyProfileIDIsValid(workingProfileID) &&
        !FMAutomaticMountPolicyProfileIDsEqual(
            confirmedProfileID, workingProfileID) &&
        FMAutomaticRespringPolicyBoolean(state[@"restartRequired"], YES) &&
        (refreshReason == nil ||
         [refreshReason isEqual:@"profileChange"]);
}

BOOL FMAutomaticMountStateAllowsTrustedMirror(
    NSDictionary<NSString *, id> *state) {
    if (![state isKindOfClass:NSDictionary.class] ||
        ![state[@"mirrorState"] isEqual:@"clean"]) {
        return NO;
    }
    id confirmedProfileID = state[@"confirmedProfileID"];
    id workingProfileID = state[@"workingProfileID"];
    if (!FMAutomaticMountPolicyProfileIDIsValid(confirmedProfileID) ||
        !FMAutomaticMountPolicyProfileIDIsValid(workingProfileID)) {
        return NO;
    }
    BOOL profilesEqual = FMAutomaticMountPolicyProfileIDsEqual(
        confirmedProfileID, workingProfileID);
    id refreshReason = state[@"refreshReason"];
    BOOL confirmedMirror = profilesEqual &&
        FMAutomaticRespringPolicyBoolean(state[@"restartRequired"], NO) &&
        (refreshReason == nil || refreshReason == NSNull.null);
    BOOL lateAutomaticMount = profilesEqual &&
        [workingProfileID isKindOfClass:NSString.class] &&
        FMAutomaticRespringPolicyBoolean(state[@"restartRequired"], YES) &&
        (refreshReason == nil ||
         [refreshReason isEqual:@"lateAutomaticMount"]);
    return confirmedMirror || lateAutomaticMount ||
        FMAutomaticMountStateHasPendingProfileChange(state);
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
