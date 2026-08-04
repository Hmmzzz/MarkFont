#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMProviderInspectionErrorDomain;

// Produces the device evidence contract consumed by FMProviderCoordinator.
// The implementation is strictly read-only: it hashes the Stock/mirror trees
// when present but never creates a directory, invokes Provider commands, or
// writes persistent state.
NSDictionary<NSString *, id> * _Nullable
FMCreateDeviceProviderInspection(NSError **error);

NS_ASSUME_NONNULL_END
