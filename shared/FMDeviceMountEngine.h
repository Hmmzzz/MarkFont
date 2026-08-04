#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceMountEngineErrorDomain;

// Runs every device/path/provider gate used by preparation, but performs no
// filesystem mutation. This is the required real-device dry run.
NSDictionary<NSString *, id> * _Nullable
FMCreateDeviceStockMirrorPreflight(NSString *confirmedSystemBuild, NSError **error);

// Root-only, device-specific first stage. It copies immutable Stock fonts into
// a fixed jbroot staging path, verifies the complete tree, atomically publishes
// the Provider mirror, and records the build baseline. It does not invoke the
// Provider, create managed state, mount anything, or request a restart.
NSDictionary<NSString *, id> * _Nullable
FMPrepareDeviceStockMirror(NSString *confirmedSystemBuild, NSError **error);

// Revalidates the prepared mirror, build-bound baseline, Provider adapter,
// alias policy, and current mapping without changing any filesystem state.
NSDictionary<NSString *, id> * _Nullable
FMCreateDevicePreparedStockMountPreflight(NSString *confirmedSystemBuild,
                                          NSError **error);

// Root-only activation of an already prepared and independently verified Stock
// mirror. When no mapping exists it invokes the fixed Provider operation; when
// the exact read-only mapping already exists it recovers by creating only the
// missing Stock state. It never unmounts or requests a restart.
NSDictionary<NSString *, id> * _Nullable
FMMountPreparedDeviceStock(NSString *confirmedSystemBuild, NSError **error);

NS_ASSUME_NONNULL_END
