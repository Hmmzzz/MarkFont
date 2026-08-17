#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierChinese;
FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierLatin;
FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierLockScreen;

// Resolves the mix-and-match slots against one validated device catalog.
// Each returned slot is @{ slotID, name, relativePaths } where relativePaths
// lists only files that actually exist in the catalog; slots with no matching
// file are omitted so the UI never offers an empty slot. Slot file sets are
// disjoint: a catalog file belongs to the first declared slot that claims it.
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

// Returns the owning slot identifier for a catalog relative path, or nil when
// the path is governed by the mix fallback instead of a main slot.
NSString * _Nullable FMFontSlotIdentifierForRelativePath(
    NSArray<NSDictionary<NSString *, id> *> *resolvedSlots,
    NSString *relativePath);

NS_ASSUME_NONNULL_END
