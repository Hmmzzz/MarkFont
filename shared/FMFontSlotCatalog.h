#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierChinese;
FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierLatin;
FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierLockScreen;

// Resolves the mix-and-match slots against one validated device catalog.
// Each returned slot is @{ slotID, name, relativePaths, sharedRelativePaths,
// mergePriority } where relativePaths lists only files that actually exist in
// the catalog; slots with no matching file are omitted so the UI never offers
// an empty slot. Some system files serve more than one visible role (notably
// SFUI.ttf for Latin UI and the SF Pro lock-screen clock). Those paths appear
// in both slots, are listed in sharedRelativePaths, and are resolved by the
// higher mergePriority when both slots provide a replacement.
// The Chinese slot follows the same layout policy as the device catalog: it
// resolves to PingFangUI.ttc only when PingFang.ttc is absent, to PingFang.ttc
// only when PingFangUI.ttc is absent, and to nothing when both or neither are
// present.
NSArray<NSDictionary<NSString *, id> *> *FMResolvedFontSlotsForCatalog(
    NSDictionary<NSString *, id> *catalog);

// Same resolution from a plain list of managed relative paths (for example
// FMProfileWorkspace.managedRelativePaths), so product UI never needs the
// catalog document itself.
NSArray<NSDictionary<NSString *, id> *> *FMResolvedFontSlotsForRelativePaths(
    NSArray<NSString *> *relativePaths);

// Returns the highest-priority owning slot identifier for a catalog relative
// path, or nil when the path is governed only by the mix fallback.
NSString * _Nullable FMFontSlotIdentifierForRelativePath(
    NSArray<NSDictionary<NSString *, id> *> *resolvedSlots,
    NSString *relativePath);

NS_ASSUME_NONNULL_END
