#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMProfileAdoptionErrorDomain;

// Copies one already validated imported Profile into a new privileged staging
// directory, verifies the copied bytes, then publishes it with RENAME_EXCL.
// Source files are never modified. The destination root must already be a
// physical directory owned by destinationUID/destinationGID.
NSDictionary<NSString *, id> *_Nullable FMPublishProfileAdoptionAtRoots(
    NSString *sourceProfilesRoot,
    NSString *destinationProfilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    uid_t destinationUID,
    gid_t destinationGID,
    NSError **error);

NS_ASSUME_NONNULL_END
