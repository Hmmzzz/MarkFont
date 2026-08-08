#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontProfileStoreErrorDomain;

// Selects representative, process-local preview files by their target role.
// The Chinese sample prefers either build-specific PingFangUI.ttc or
// PingFang.ttc while Latin and ordinary 0-9 samples prefer SFUI. Symbol,
// emoji, keycap, and phone fonts are never used as generic text previews.
NSDictionary<NSString *, NSString *> *FMFontProfilePreviewPaths(
    NSDictionary<NSString *, id> *profile,
    NSString *replacementsDirectory);

// App-owned Profile library. The caller supplies a current-build directory;
// these functions never read or write the managed mirror, state.json, rootfs,
// or any mount configuration.
NSArray<NSDictionary<NSString *, id> *> * _Nullable FMListFontProfilesAtRoot(
    NSString *profilesRoot,
    NSString *systemBuild,
    NSError **error);

NSDictionary<NSString *, id> * _Nullable FMFontProfileDetailsAtRoot(
    NSString *profilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    NSError **error);

// Revalidates the selected package, copies only unambiguous matched fonts into
// a hidden staging directory, publishes one complete Profile directory, and
// returns a small summary. The source package is never modified or retained.
NSDictionary<NSString *, id> * _Nullable FMImportFontPackageProfile(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *catalog,
    NSString *profilesRoot,
    NSString *profileID,
    NSString *profileName,
    NSError **error);

// Deletes one validated imported draft from the app-owned Profile library.
// Activation state must be checked by the caller before this is used once
// device Profile activation is implemented.
BOOL FMDeleteFontProfileAtRoot(NSString *profilesRoot,
                               NSString *profileID,
                               NSString *systemBuild,
                               NSError **error);

NS_ASSUME_NONNULL_END
