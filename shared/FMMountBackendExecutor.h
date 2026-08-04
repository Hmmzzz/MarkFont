#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMMountBackendIdentifier;
FOUNDATION_EXPORT NSString *const FMMountBackendVersion;
FOUNDATION_EXPORT NSString *const FMMountBackendExecutableLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountBackendRuntimeLibraryLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountBackendExecutorErrorDomain;

// Invokes the MarkFont-owned fixed mount operation. No executable, source,
// target, mount flag, or environment value is accepted from callers.
NSDictionary<NSString *, id> * _Nullable
FMInvokeMountBackendForPreparedSystemFonts(NSError **error);

// Detaches only the exact managed read-only Fonts mapping for an explicit
// package lifecycle operation. The isolated backend performs the final mapping
// ownership check before using MNT_FORCE.
NSDictionary<NSString *, id> * _Nullable
FMDetachManagedSystemFontsForPackageLifecycle(NSError **error);

// Refreshes the exact managed mapping after verified mirror updates by running
// the fixed force-detach followed by the fixed read-only mount operation.
NSDictionary<NSString *, id> * _Nullable
FMRefreshMountBackendForPreparedSystemFonts(NSError **error);

NS_ASSUME_NONNULL_END
