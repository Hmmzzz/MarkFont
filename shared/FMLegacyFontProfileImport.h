#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMLegacyFontProfileImportErrorDomain;

// Converts the supported font files that differ from Stock into the same
// build-bound, differential Profile format used by normal App imports. The
// legacy tree is read in place and is never modified by this function.
NSDictionary<NSString *, id> *_Nullable FMImportLegacyFontTreeAsProfile(
    NSString *legacyRoot,
    NSString *stockRoot,
    NSString *profilesRoot,
    NSString *systemBuild,
    NSString *profileID,
    NSString *profileName,
    uid_t owner,
    gid_t group,
    NSError **error);

NS_ASSUME_NONNULL_END
