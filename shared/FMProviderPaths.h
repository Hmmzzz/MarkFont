#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMProviderPackageIdentifier;
FOUNDATION_EXPORT NSString *const FMProviderExecutableLogicalPath;
FOUNDATION_EXPORT NSString *const FMProviderPreferenceLogicalPath;
FOUNDATION_EXPORT NSString *const FMProviderDefaultRootLogicalPath;
FOUNDATION_EXPORT NSString *const FMProviderAliasLogicalPath;
FOUNDATION_EXPORT NSString *const FMProviderSystemFontsLogicalPath;
FOUNDATION_EXPORT NSString *const FMProviderRootfsFontsLogicalPath;

FOUNDATION_EXPORT NSString *const FMProviderPathsErrorDomain;

// Resolves the storage namespace understood by the verified Provider adapter.
// The current adapter accepts either no preference file or the Provider's
// explicit `.jbroot/bindfs` value. Unsupported or malformed preferences are
// reported through `supported`; the returned path remains the inert default so
// status code can describe existing data without trusting that configuration.
NSString *FMProviderResolvedRootLogicalPath(BOOL * _Nullable supported,
                                            BOOL * _Nullable preferencePresent);
NSString *FMProviderResolvedMirrorLogicalPath(BOOL * _Nullable supported,
                                              BOOL * _Nullable preferencePresent);

// Distinguishes an absent preference from an unreadable filesystem error.
BOOL FMProviderPreferenceExists(BOOL *present, NSError **error);

// Validates the Provider-created alias without exposing or persisting the
// randomized physical jbroot. A missing alias is acceptable only when
// `requirePresent` is false; any existing object must be the exact symlink to
// the supported Provider root.
BOOL FMValidateProviderAlias(BOOL requirePresent,
                             BOOL * _Nullable present,
                             NSError **error);

// Cheap runtime check used by normal Profile and restart operations. It reads
// only mount metadata; it never walks or hashes the font mirror.
BOOL FMProviderManagedMappingIsActive(NSError **error);

NS_ASSUME_NONNULL_END
