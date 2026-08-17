#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierChinese;
FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierLatin;
FOUNDATION_EXPORT NSString *const FMFontSlotIdentifierLockScreen;

// Resolves the mix-and-match slots against one validated device catalog.
// Each returned slot is @{ slotID, name, relativePaths } where relativePaths
// lists only files that actually exist in the catalog. Slot target sets are
// disjoint, and slots with no matching target are omitted so the UI never
// offers an empty slot. A slot may also expose sharedStyleRelativePaths and
// sharedStyleOwnerSlotID as UI-only metadata. These describe styles that can
// affect the visible role but are physically owned by another slot; they are
// never materialized by this slot. For example, the SF Pro lock-screen clock
// shares SFUI.ttf with system Latin text and therefore follows the Latin slot.
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
// the path is governed only by the mix fallback.
NSString * _Nullable FMFontSlotIdentifierForRelativePath(
    NSArray<NSDictionary<NSString *, id> *> *resolvedSlots,
    NSString *relativePath);

NS_ASSUME_NONNULL_END
