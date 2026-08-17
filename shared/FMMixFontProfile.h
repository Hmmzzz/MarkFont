#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMMixFontProfileErrorDomain;

typedef NS_ENUM(NSInteger, FMMixFontProfileErrorCode) {
    FMMixFontProfileErrorInvalidInput = 1,
    FMMixFontProfileErrorFilesystem = 2,
    FMMixFontProfileErrorInvalidProfile = 3,
    FMMixFontProfileErrorEmptyResult = 4,
};

// Read-only merge preview. slotAssignments maps a slot identifier from
// FMFontSlotCatalog to the source Profile ID that should govern that slot;
// fallbackProfileID (nil = keep Stock) supplies every remaining replacement.
// The result never touches the filesystem beyond reading source Profiles.
// Shape:
//   slots: [{ slotID, name, assignedProfileID, assignedProfileName,
//             replacedRelativePaths, fallbackRelativePaths, stockRelativePaths }]
//   fallbackProfileID / fallbackProfileName (NSNull when none)
//   fallbackReplacementCount, replacementCount
NSDictionary<NSString *, id> * _Nullable FMMixFontProfilePreviewAtRoot(
    NSString *profilesRoot,
    NSDictionary<NSString *, id> *catalog,
    NSDictionary<NSString *, NSString *> *slotAssignments,
    NSString * _Nullable fallbackProfileID,
    NSError **error);

// Materializes the same merge as a brand-new app-owned Profile (staging
// directory, per-file SHA-256 verification, atomic publish) and records the
// recipe under the extra "mixRecipe" key of profile.json. profileID must start
// with "import-mix-" so the result stays deletable and adoptable. At least one
// merged replacement is required.
NSDictionary<NSString *, id> * _Nullable FMCreateMixedFontProfileAtRoot(
    NSString *profilesRoot,
    NSDictionary<NSString *, id> *catalog,
    NSDictionary<NSString *, NSString *> *slotAssignments,
    NSString * _Nullable fallbackProfileID,
    NSString *profileID,
    NSString *profileName,
    NSError **error);

NS_ASSUME_NONNULL_END
