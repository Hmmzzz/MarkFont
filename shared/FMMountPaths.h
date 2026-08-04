#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMLegacyProviderPreferenceLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountStorageRootLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountSystemFontsLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountRootfsFontsLogicalPath;

FOUNDATION_EXPORT NSString *const FMMountPathsErrorDomain;

// Resolves MarkFont's fixed logical storage namespace. It never consults a
// third-party preference and never persists the randomized physical jbroot.
NSString *FMMountResolvedStorageRootLogicalPath(BOOL * _Nullable supported,
                                                BOOL * _Nullable legacyPreferencePresent);
NSString *FMMountResolvedMirrorLogicalPath(BOOL * _Nullable supported,
                                           BOOL * _Nullable legacyPreferencePresent);

// Reads the legacy Provider plist according to its actual Enable/path semantics.
// A present preference is compatible when it does not currently auto-mount a
// target overlapping /System/Library/Fonts.
NSDictionary<NSString *, id> *_Nullable
FMLegacyProviderAutoMountConfiguration(NSError **error);
BOOL FMLegacyProviderAutoMountConflictsWithSystemFonts(BOOL *conflicts,
                                                 NSError **error);

// Package-install takeover helper. Removes only automatic-mount targets that
// overlap the managed Fonts tree, preserving all unrelated legacy Provider targets.
// If no targets remain, the preference is retained with Enable=false.
NSDictionary<NSString *, id> *_Nullable
FMDisableLegacyProviderAutoMountForSystemFonts(NSError **error);

// Cheap runtime check used by normal Profile and restart operations. It reads
// only mount metadata; it never walks or hashes the font mirror.
BOOL FMMountManagedMappingIsActive(NSError **error);

NS_ASSUME_NONNULL_END
