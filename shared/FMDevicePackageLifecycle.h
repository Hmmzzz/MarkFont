#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDevicePackageLifecycleErrorDomain;

// Idempotent dpkg postinst entry point. A genuinely empty installation is
// initialized from the immutable current-build Stock tree. Existing managed
// state is preserved and never migrated or reset.
NSDictionary<NSString *, id> *_Nullable FMConfigureInstalledDevicePackage(
    NSError **error);

// Idempotent dpkg prerm entry point. For an owned active mapping it first
// restores the verified Stock mirror, then attempts only unmount(target, 0).
// A successful result publishes a root-owned marker that authorizes postrm to
// remove MarkFont-owned persistent data. External Provider data is preserved.
NSDictionary<NSString *, id> *_Nullable FMPrepareDevicePackageRemoval(
    NSError **error);

NS_ASSUME_NONNULL_END
