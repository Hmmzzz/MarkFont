#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMMountInspectionErrorDomain;

// Produces the device evidence contract consumed by FMMountCoordinator.
// The implementation is strictly read-only: it hashes the Stock/mirror trees
// when present but never creates a directory, invokes backend commands, or
// writes persistent state.
NSDictionary<NSString *, id> * _Nullable
FMCreateDeviceMountInspection(NSError **error);

NS_ASSUME_NONNULL_END
