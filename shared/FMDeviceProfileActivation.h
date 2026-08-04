#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceProfileActivationErrorDomain;

// Root-helper read-only gate for the first imported Profile activation. It
// verifies an exact managed Stock mapping, the build-bound catalog, App-owned
// Profile metadata/files, and destination capacity. If an identical privileged
// copy already exists, it validates and reports that copy for idempotent retry.
// It never adopts the Profile, writes the mirror/state, invokes the Provider,
// or restarts userspace.
NSDictionary<NSString *, id> *_Nullable FMCreateDeviceProfileActivationPreflight(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSError **error);

NS_ASSUME_NONNULL_END
