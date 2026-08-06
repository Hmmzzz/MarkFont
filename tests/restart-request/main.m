#import <Foundation/Foundation.h>

#import "FMRestartRequest.h"

static void FMTestRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary *FMBootEvidence(long long seconds,
                                    long long microseconds,
                                    NSString *sessionUUID) {
    return @{
        @"bootTimeSeconds" : @(seconds),
        @"bootTimeMicroseconds" : @(microseconds),
        @"bootSessionUUID" : sessionUUID,
    };
}

static NSDictionary *FMBootEvidenceWithUserspace(
    long long bootSeconds,
    NSString *sessionUUID,
    int pid) {
    return @{
        @"bootTimeSeconds" : @(bootSeconds),
        @"bootTimeMicroseconds" : @0,
        @"bootSessionUUID" : sessionUUID,
        @"userspaceSession" : @{
            @"process" : @"SpringBoard",
            @"pid" : @(pid),
        },
    };
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        NSDictionary *before = FMBootEvidence(1785717726, 7752, @"SESSION-A");
        NSDictionary *request = FMCreateRestartRequestDocument(
            @"21D61", @"profile-a", before, &error);
        FMTestRequire(request != nil, error.localizedDescription ?: @"request rejected");
        FMTestRequire(FMValidateRestartRequestDocument(request, &error),
                      error.localizedDescription ?: @"request validation failed");

        BOOL observed = YES;
        FMTestRequire(FMRestartRequestObservedRestart(request, before, &observed, &error) &&
                          !observed,
                      @"unchanged boot evidence reported a restart");

        NSDictionary *laterBoot =
            FMBootEvidence(1785718000, 125, @"SESSION-A");
        FMTestRequire(FMRestartRequestObservedRestart(request, laterBoot, &observed, &error) &&
                          observed,
                      @"later boot time did not report a restart");

        NSDictionary *newSession =
            FMBootEvidence(1785717000, 1, @"SESSION-B");
        FMTestRequire(FMRestartRequestObservedRestart(request, newSession, &observed, &error) &&
                          observed,
                      @"new boot session did not report a restart");

        NSDictionary *earlierSameSession =
            FMBootEvidence(1785717000, 1, @"SESSION-A");
        FMTestRequire(FMRestartRequestObservedRestart(
                          request, earlierSameSession, &observed, &error) && !observed,
                      @"earlier time in the same session reported a restart");

        NSDictionary *userspaceBefore = FMBootEvidenceWithUserspace(
            1785717726, @"SESSION-A", 600);
        NSDictionary *userspaceRequest = FMCreateRestartRequestDocument(
            @"21D61", @"profile-a", userspaceBefore, &error);
        FMTestRequire(userspaceRequest != nil,
                      error.localizedDescription ?: @"userspace request rejected");
        FMTestRequire(FMRestartRequestObservedRestart(
                          userspaceRequest, userspaceBefore, &observed, &error) &&
                          !observed,
                      @"unchanged userspace session reported a restart");

        NSDictionary *userspaceAfter = FMBootEvidenceWithUserspace(
            1785717726, @"SESSION-A", 1217);
        FMTestRequire(FMRestartRequestObservedRestart(
                          userspaceRequest, userspaceAfter, &observed, &error) &&
                          observed,
                      @"new userspace session did not report a restart");

        NSMutableDictionary *partialUserspace = [before mutableCopy];
        partialUserspace[@"userspaceSession"] = @{ @"process" : @"SpringBoard" };
        FMTestRequire(!FMValidateRestartBootEvidence(partialUserspace, &error),
                      @"partial userspace evidence was accepted");

        NSDictionary *stockRequest = FMCreateRestartRequestDocument(
            @"21D61", NSNull.null, before, &error);
        FMTestRequire(stockRequest != nil &&
                          stockRequest[@"workingProfileID"] == NSNull.null,
                      @"Stock restart request was rejected");

        NSMutableDictionary *invalid = [request mutableCopy];
        invalid[@"schemaVersion"] = @2;
        FMTestRequire(!FMValidateRestartRequestDocument(invalid, &error),
                      @"unsupported restart request schema was accepted");

        printf("PASS: restart request evidence\n");
    }
    return 0;
}
