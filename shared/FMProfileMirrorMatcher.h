#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMProfileMirrorMatcherErrorDomain;

// Compares a complete mirror manifest with Stock plus the replacement hashes
// declared by workingProfileID (nil/NSNull means Stock). No filesystem data is
// modified; a valid but mismatching mirror returns NO without an error.
BOOL FMManifestsMatchWorkingProfile(
    NSDictionary<NSString *, id> *stockManifest,
    NSDictionary<NSString *, id> *mirrorManifest,
    NSString *profilesRoot,
    id workingProfileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

NS_ASSUME_NONNULL_END
