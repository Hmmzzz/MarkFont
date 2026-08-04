#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMProfileAdoptionValidatorErrorDomain;

// Validates one App-owned imported Profile against the current build catalog.
// The caller supplies an already fixed Profile-library root. This function is
// strictly read-only: it does not create the privileged Profile copy, touch the
// managed mirror, or update state.json.
NSDictionary<NSString *, id> *_Nullable FMCreateProfileAdoptionPreviewAtRoot(
    NSString *profilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

// Same validation for a staging directory whose leaf name differs from the
// Profile identifier stored in profile.json. This remains strictly read-only
// and is used to verify a complete privileged copy before atomic publication.
NSDictionary<NSString *, id> *_Nullable FMCreateProfileAdoptionPreviewAtDirectory(
    NSString *profilesRoot,
    NSString *directoryName,
    NSString *profileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

NS_ASSUME_NONNULL_END
