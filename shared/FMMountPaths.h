#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMLegacyProviderPreferenceLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountStorageRootLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountSystemFontsLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountRootfsFontsLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountFontServicesCorePrivateLogicalPath;
FOUNDATION_EXPORT NSString *const FMMountFontServicesCorePrivateMirrorLogicalPath;

FOUNDATION_EXPORT NSString *const FMMountPathsErrorDomain;

// Resolves MarkFont's fixed logical storage namespace. It never consults a
// third-party preference and never persists the randomized physical jbroot.
NSString *FMMountResolvedStorageRootLogicalPath(BOOL * _Nullable supported,
                                                BOOL * _Nullable legacyPreferencePresent);
NSString *FMMountResolvedMirrorLogicalPath(BOOL * _Nullable supported,
                                           BOOL * _Nullable legacyPreferencePresent);

// Resolves a path on the original iOS root filesystem for direct file access.
// RootHide reaches that namespace through its jbroot-based /rootfs view;
// conventional rootless processes already see these paths directly.
NSString *FMMountResolvedOriginalRootfsPath(NSString *logicalRootfsPath);

// Resolves app-owned data below /var/mobile. RootHide retains its established
// jbroot mapping, while conventional rootless must use the rootfs path directly.
NSString *FMMountResolvedMobileDataPath(NSString *logicalMobilePath);

// Resolves FontManager's own sandboxed data. `suffix` is appended verbatim to
// the resolved root (e.g. @"/Library/Application Support/com.hmmzzz.fontmanager").
// Under conventional rootless the app is sandboxed into a randomized UUID
// container, so its data never sits at the fixed /var/mobile path the daemon
// historically used; when no such container is found this returns @"". Under
// RootHide, /var/mobile is mapped through jbroot directly, so this always
// returns that fixed path and never returns @"". Never infers the target from
// the contents of the logical path.
NSString *FMMountResolvedAppContainerPath(NSString *suffix);

// Resolves the original system Fonts tree in the current path namespace.
// RootHide exposes it through /rootfs; conventional rootless uses /System.
// Callers must not persist the returned physical path.
NSString *FMMountResolvedStockFontsPath(void);

// iOS 18-26 moved PingFangUI.ttc out of /System/Library/Fonts and into the
// private FontServices CorePrivate directory. These resolvers keep that second
// fixed target in the same RootHide/conventional-rootless path boundary as the
// primary Fonts tree. Callers must first pass FMSystemFontLayout's version
// policy and then prove the exact path exists on the current build.
NSString *FMMountResolvedStockFontServicesCorePrivatePath(void);
NSString *FMMountResolvedFontServicesCorePrivateMirrorPath(void);

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
// only mount metadata; it never walks or hashes either font mirror. The
// FontServices mapping is required only after its fixed mirror has been
// prepared, preserving the single-mapping behavior of iOS 16-17 workspaces.
BOOL FMMountManagedMappingIsActive(NSError **error);

NS_ASSUME_NONNULL_END
