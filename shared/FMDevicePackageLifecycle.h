#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDevicePackageLifecycleErrorDomain;

// Idempotent dpkg postinst entry point. A genuinely empty installation is
// initialized from the immutable current-build Stock tree. Existing managed
// state is preserved and never reset; only legacy baseline backend metadata is
// migrated in place.
NSDictionary<NSString *, id> *_Nullable FMConfigureInstalledDevicePackage(
    NSError **error);

// Idempotent dpkg prerm entry point. For an owned active mapping it first
// restores the verified Stock mirror, then invokes the fixed mount backend detach
// operation and proves that the original Stock tree is exposed. A successful
// result publishes a root-owned marker that authorizes postrm to remove
// MarkFont-owned persistent data. Unrelated legacy Provider preferences are
// preserved.
NSDictionary<NSString *, id> *_Nullable FMPrepareDevicePackageRemoval(
    NSError **error);

NS_ASSUME_NONNULL_END
