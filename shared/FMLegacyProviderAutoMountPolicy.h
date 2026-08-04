#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMLegacyProviderAutoMountPolicyErrorDomain;

// Pure preference analysis shared by device code and host-side regression tests.
// `conflictsWithFonts` is true only when automatic mounting is enabled and at
// least one configured target overlaps /System/Library/Fonts.
NSDictionary<NSString *, id> *FMAnalyzeLegacyProviderAutoMountPreference(
    NSDictionary<NSString *, id> *preference);

// Removes only targets that overlap /System/Library/Fonts. Other legacy Provider
// targets and the configured storage root are preserved. When no targets
// remain, Enable is set to false so the legacy Provider launch job becomes inert.
NSDictionary<NSString *, id> *_Nullable
FMLegacyProviderAutoMountPreferenceByRemovingSystemFonts(
    NSDictionary<NSString *, id> *preference,
    BOOL *changed,
    NSError **error);

NS_ASSUME_NONNULL_END
