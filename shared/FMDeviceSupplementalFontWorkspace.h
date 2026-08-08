#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceSupplementalFontWorkspaceErrorDomain;

// Confirms the system layout before touching any supplemental path. iOS 16-17
// return status=notRequired without probing, creating, or mounting FontServices.
// On iOS 18-26 this ensures the fixed CorePrivate Stock snapshot, writable
// mirror, saved manifest, and read-only mapping, and requires the exact
// PingFangUI.ttc rootfs source. The caller must already hold MarkFont's
// exclusive engine lock. No caller-provided path is accepted.
NSDictionary<NSString *, id> * _Nullable
FMEnsureDeviceSupplementalFontWorkspaceWithExistingLock(
    NSString *confirmedSystemBuild,
    NSError **error);

NS_ASSUME_NONNULL_END
