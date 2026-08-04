#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceStockSnapshotErrorDomain;

// Read-only assessment for the one-time migration of an already mounted
// device. No mount, mirror, state, or snapshot path is changed.
NSDictionary<NSString *, id> *_Nullable FMCreateDeviceStockSnapshotPreflight(
    NSString *confirmedSystemBuild,
    NSError **error);

// One-time maintenance operation: attempts a non-force unmount, verifies the
// exposed immutable Stock tree against the saved baseline, copies a durable
// snapshot, then remounts the unchanged mirror through the fixed mount backend.
NSDictionary<NSString *, id> *_Nullable FMCaptureDeviceStockSnapshot(
    NSString *confirmedSystemBuild,
    NSError **error);

NS_ASSUME_NONNULL_END
