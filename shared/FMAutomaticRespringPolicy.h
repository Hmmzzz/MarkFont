#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure, side-effect-free decision used after automatic mounting. Both caller
// facts are supplied separately so command parsing and launchd provenance
// cannot be inferred from mutable report content.
BOOL FMAutomaticRespringEligibleForReport(
    NSDictionary<NSString *, id> *_Nullable report,
    BOOL exactLaunchdInvocation,
    BOOL launchdService);

NS_ASSUME_NONNULL_END
