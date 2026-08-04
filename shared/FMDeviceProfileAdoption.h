#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceProfileAdoptionErrorDomain;

// Fixed-path root-helper operation. It publishes only a verified App-owned
// imported Profile into /var/lib/fontmanager/profiles. It never changes the
// Provider mirror, state.json, mount state, or userspace lifecycle.
NSDictionary<NSString *, id> *_Nullable FMAdoptDeviceProfile(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSError **error);

NS_ASSUME_NONNULL_END
