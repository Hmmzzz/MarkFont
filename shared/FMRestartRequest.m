#import "FMRestartRequest.h"

#import <CoreFoundation/CoreFoundation.h>

NSInteger const FMRestartRequestSchemaVersion = 1;
NSString *const FMRestartRequestErrorDomain =
    @"com.hmmzzz.fontmanager.restart-request";

static BOOL FMRestartRequestFail(NSError **error,
                                 NSInteger code,
                                 NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:FMRestartRequestErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey : description}];
    }
    return NO;
}

static BOOL FMIsIntegerNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
           !CFNumberIsFloatType((__bridge CFNumberRef)value);
}

BOOL FMValidateRestartBootEvidence(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMRestartRequestFail(error, 1,
                                    @"Restart boot evidence must be a dictionary.");
    }
    NSDictionary *evidence = object;
    NSNumber *seconds = evidence[@"bootTimeSeconds"];
    NSNumber *microseconds = evidence[@"bootTimeMicroseconds"];
    NSString *sessionUUID = evidence[@"bootSessionUUID"];
    if (!FMIsIntegerNumber(seconds) || seconds.longLongValue <= 0 ||
        !FMIsIntegerNumber(microseconds) || microseconds.longLongValue < 0 ||
        microseconds.longLongValue >= 1000000 ||
        ![sessionUUID isKindOfClass:NSString.class] || sessionUUID.length == 0) {
        return FMRestartRequestFail(error, 1,
                                    @"Restart boot evidence is invalid.");
    }
    id userspaceObject = evidence[@"userspaceSession"];
    if (userspaceObject == nil) return YES;
    if (![userspaceObject isKindOfClass:NSDictionary.class]) {
        return FMRestartRequestFail(error, 1,
                                    @"Restart userspace evidence must be a dictionary.");
    }
    NSDictionary *userspace = userspaceObject;
    NSString *process = userspace[@"process"];
    NSNumber *pid = userspace[@"pid"];
    if (![process isKindOfClass:NSString.class] || process.length == 0 ||
        !FMIsIntegerNumber(pid) || pid.longLongValue <= 0) {
        return FMRestartRequestFail(error, 1,
                                    @"Restart userspace evidence is invalid.");
    }
    return YES;
}

NSDictionary<NSString *, id> *FMCreateRestartRequestDocument(
    NSString *systemBuild,
    id workingProfileID,
    NSDictionary<NSString *, id> *bootEvidence,
    NSError **error) {
    BOOL validWorkingProfile = workingProfileID == NSNull.null ||
        ([workingProfileID isKindOfClass:NSString.class] &&
         [workingProfileID length] > 0);
    if (![systemBuild isKindOfClass:NSString.class] || systemBuild.length == 0 ||
        !validWorkingProfile) {
        FMRestartRequestFail(error, 2,
                             @"Restart request identity is invalid.");
        return nil;
    }
    if (!FMValidateRestartBootEvidence(bootEvidence, error)) {
        return nil;
    }
    return @{
        @"schemaVersion" : @(FMRestartRequestSchemaVersion),
        @"systemBuild" : systemBuild,
        @"workingProfileID" : workingProfileID,
        @"requestedBootEvidence" : [bootEvidence copy],
    };
}

BOOL FMValidateRestartRequestDocument(id object, NSError **error) {
    if (![object isKindOfClass:NSDictionary.class]) {
        return FMRestartRequestFail(error, 3,
                                    @"Restart request must be a dictionary.");
    }
    NSDictionary *request = object;
    NSNumber *schemaVersion = request[@"schemaVersion"];
    NSString *systemBuild = request[@"systemBuild"];
    id workingProfileID = request[@"workingProfileID"];
    if (!FMIsIntegerNumber(schemaVersion) ||
        schemaVersion.integerValue != FMRestartRequestSchemaVersion ||
        ![systemBuild isKindOfClass:NSString.class] || systemBuild.length == 0 ||
        !(workingProfileID == NSNull.null ||
          ([workingProfileID isKindOfClass:NSString.class] &&
           [workingProfileID length] > 0))) {
        return FMRestartRequestFail(error, 3,
                                    @"Restart request identity is invalid.");
    }
    return FMValidateRestartBootEvidence(request[@"requestedBootEvidence"], error);
}

BOOL FMRestartRequestObservedRestart(
    NSDictionary<NSString *, id> *request,
    NSDictionary<NSString *, id> *currentBootEvidence,
    BOOL *observed,
    NSError **error) {
    if (observed == NULL) {
        return FMRestartRequestFail(error, 4,
                                    @"Restart comparison output is required.");
    }
    *observed = NO;
    if (!FMValidateRestartRequestDocument(request, error) ||
        !FMValidateRestartBootEvidence(currentBootEvidence, error)) {
        return NO;
    }

    NSDictionary *requested = request[@"requestedBootEvidence"];
    NSString *requestedSession = requested[@"bootSessionUUID"];
    NSString *currentSession = currentBootEvidence[@"bootSessionUUID"];
    if (![requestedSession isEqual:currentSession]) {
        *observed = YES;
        return YES;
    }

    NSDictionary *requestedUserspace = requested[@"userspaceSession"];
    NSDictionary *currentUserspace = currentBootEvidence[@"userspaceSession"];
    if ([requestedUserspace isKindOfClass:NSDictionary.class] &&
        [currentUserspace isKindOfClass:NSDictionary.class]) {
        NSString *requestedProcess = requestedUserspace[@"process"];
        NSString *currentProcess = currentUserspace[@"process"];
        if (![requestedProcess isEqual:currentProcess]) {
            return FMRestartRequestFail(error, 4,
                                        @"Restart userspace processes do not match.");
        }
        *observed = ![requestedUserspace[@"pid"]
            isEqual:currentUserspace[@"pid"]];
        return YES;
    }

    long long requestedSeconds = [requested[@"bootTimeSeconds"] longLongValue];
    long long currentSeconds = [currentBootEvidence[@"bootTimeSeconds"] longLongValue];
    long long requestedMicroseconds =
        [requested[@"bootTimeMicroseconds"] longLongValue];
    long long currentMicroseconds =
        [currentBootEvidence[@"bootTimeMicroseconds"] longLongValue];
    *observed = currentSeconds > requestedSeconds ||
        (currentSeconds == requestedSeconds &&
         currentMicroseconds > requestedMicroseconds);
    return YES;
}
