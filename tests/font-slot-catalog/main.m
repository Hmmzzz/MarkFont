#import <Foundation/Foundation.h>

#import "FMDataModel.h"
#import "FMFontCatalog.h"
#import "FMFontSlotCatalog.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary<NSString *, id> *FMRegularEntry(NSString *relativePath,
                                                    NSString *sha256,
                                                    NSNumber *size) {
    return @{
        @"relativePath" : relativePath,
        @"type" : @"regular",
        @"mode" : @0644,
        @"uid" : @0,
        @"gid" : @0,
        @"size" : size,
        @"sha256" : sha256,
    };
}

static NSDictionary<NSString *, id> *FMManifest(NSArray<NSString *> *paths) {
    // The manifest contract requires unique, sorted relative paths.
    NSArray<NSString *> *sortedPaths =
        [paths sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
    for (NSString *path in sortedPaths) {
        [entries addObject:FMRegularEntry(
            path,
            [NSString stringWithFormat:@"%064lu", (unsigned long)entries.count],
            @100)];
    }
    return @{ @"schemaVersion" : @2, @"entries" : entries };
}

static NSDictionary<NSString *, id> *FMCatalog(NSArray<NSString *> *paths);

static NSDictionary<NSString *, id> *FMCatalogWithSupplement(
    NSArray<NSString *> *primaryPaths, NSArray<NSString *> *supplementPaths) {
    NSError *error = nil;
    NSDictionary<NSString *, id> *supplement =
        supplementPaths == nil ? nil : FMManifest(supplementPaths);
    NSDictionary<NSString *, id> *catalog = FMCreateFontCatalogFromManifests(
        FMManifest(primaryPaths), supplement, @"21D61",
        @"1111111111111111111111111111111111111111111111111111111111111111",
        @"2222222222222222222222222222222222222222222222222222222222222222",
        &error);
    FMRequire(catalog != nil,
              [@"fixture catalog could not be built: "
                  stringByAppendingString:error.localizedDescription ?: @"?"]);
    return catalog;
}

static NSDictionary<NSString *, id> *FMCatalog(NSArray<NSString *> *paths) {
    return FMCatalogWithSupplement(paths, nil);
}

static NSDictionary<NSString *, id> *FMSlot(
    NSArray<NSDictionary<NSString *, id> *> *slots, NSString *slotID) {
    for (NSDictionary<NSString *, id> *slot in slots) {
        if ([slot[@"slotID"] isEqual:slotID]) return slot;
    }
    return nil;
}

int main(void) {
    @autoreleasepool {
        NSArray<NSString *> *ios16Paths = @[
            @"Core/SFUI.ttf",
            @"CoreUI/SFUIRounded.ttf",
            @"LanguageSupport/PingFang.ttc",
            @"AppFonts/LockClock.ttf",
            @"Watch/ADTTime.ttc",
        ];
        NSArray<NSDictionary<NSString *, id> *> *slots =
            FMResolvedFontSlotsForCatalog(FMCatalog(ios16Paths));
        FMRequire(slots.count == 3, @"iOS 16 layout should resolve three slots");
        NSDictionary<NSString *, id> *chinese =
            FMSlot(slots, FMFontSlotIdentifierChinese);
        NSDictionary<NSString *, id> *latin = FMSlot(slots, FMFontSlotIdentifierLatin);
        NSDictionary<NSString *, id> *lock = FMSlot(slots, FMFontSlotIdentifierLockScreen);
        FMRequire([lock[@"relativePaths"] isEqual:@[ @"Watch/ADTTime.ttc" ]],
                  @"iOS 16 lock slot must resolve only ADTTime");
        FMRequire([lock[@"sharedStyleRelativePaths"] isEqual:@[
                          @"Core/SFUI.ttf", @"CoreUI/SFUIRounded.ttf"
                      ]] &&
                      [lock[@"sharedStyleOwnerSlotID"]
                          isEqual:FMFontSlotIdentifierLatin],
                  @"iOS 16 shared clock styles must point to the Latin owner");
        FMRequire(
            [FMFontSlotIdentifierForRelativePath(slots, @"Watch/ADTTime.ttc")
                isEqual:FMFontSlotIdentifierLockScreen] &&
                FMFontSlotIdentifierForRelativePath(
                    slots, @"AppFonts/LockClock.ttf") == nil,
            @"ADTTime must own the iOS 16 slot while LockClock stays outside it");

        NSArray<NSString *> *ios17Paths = @[
            @"Core/SFUI.ttf",
            @"Core/SFUIItalic.ttf",
            @"Core/SFUIMono.ttf",
            @"Core/NewYork.ttf",
            @"Core/SFArabic.ttf",
            @"Core/SFHebrew.ttf",
            @"CoreUI/SFUIRounded.ttf",
            @"LanguageSupport/PingFang.ttc",
            @"AppFonts/LockClock.ttf",
            @"CoreAddition/AppleColorEmoji-160px.ttc",
            @"Watch/ADTNumeric.ttc",
            @"Watch/SFCompact.ttf",
            @"Watch/SFCompactRounded.ttf",
        ];
        slots = FMResolvedFontSlotsForCatalog(FMCatalog(ios17Paths));
        FMRequire(slots.count == 3, @"iOS 17 layout should resolve three slots");
        chinese = FMSlot(slots, FMFontSlotIdentifierChinese);
        latin = FMSlot(slots, FMFontSlotIdentifierLatin);
        lock = FMSlot(slots, FMFontSlotIdentifierLockScreen);
        FMRequire([chinese[@"relativePaths"] isEqual:@[ @"LanguageSupport/PingFang.ttc" ]],
                  @"Chinese slot must resolve to the legacy PingFang target");
        FMRequire([latin[@"relativePaths"]
                      isEqual:@[ @"Core/SFUI.ttf", @"Core/SFUIItalic.ttf",
                                 @"CoreUI/SFUIRounded.ttf",
                                 @"Core/SFUIMono.ttf" ]],
                  @"Latin slot must resolve to the SF UI family");
        FMRequire([lock[@"relativePaths"] isEqual:@[ @"Watch/ADTNumeric.ttc" ]],
                  @"iOS 17 lock slot must resolve only ADTNumeric");
        FMRequire([lock[@"sharedStyleRelativePaths"] isEqual:@[
                          @"Core/SFUI.ttf", @"CoreUI/SFUIRounded.ttf"
                      ]] &&
                      [lock[@"sharedStyleOwnerSlotID"]
                          isEqual:FMFontSlotIdentifierLatin],
                  @"shared SF UI clock styles must point to the Latin owner");

        FMRequire(
            [FMFontSlotIdentifierForRelativePath(
                 slots, @"LanguageSupport/PingFang.ttc")
                isEqual:FMFontSlotIdentifierChinese] &&
                [FMFontSlotIdentifierForRelativePath(slots, @"Core/SFUI.ttf")
                    isEqual:FMFontSlotIdentifierLatin] &&
                [FMFontSlotIdentifierForRelativePath(slots, @"Core/SFUIItalic.ttf")
                    isEqual:FMFontSlotIdentifierLatin] &&
                [FMFontSlotIdentifierForRelativePath(slots, @"Watch/ADTNumeric.ttc")
                    isEqual:FMFontSlotIdentifierLockScreen] &&
                FMFontSlotIdentifierForRelativePath(
                    slots, @"AppFonts/LockClock.ttf") == nil &&
                FMFontSlotIdentifierForRelativePath(
                    slots, @"CoreAddition/AppleColorEmoji-160px.ttc") == nil,
            @"slot lookup must map slot paths and leave other paths to fallback");

        // The modern layout swaps the Chinese target into the FontServices
        // virtual namespace and hides the legacy file entirely.
        slots = FMResolvedFontSlotsForCatalog(FMCatalogWithSupplement(
            @[
                @"Core/ADTNumeric.ttc",
                @"Core/SFUI.ttf",
                @"CoreUI/SFUISoft.ttc",
                @"CoreUI/SFUIRounded.ttf",
                @"AppFonts/LockClock.ttf",
            ],
            @[ @"PingFangUI.ttc" ]));
        chinese = FMSlot(slots, FMFontSlotIdentifierChinese);
        latin = FMSlot(slots, FMFontSlotIdentifierLatin);
        lock = FMSlot(slots, FMFontSlotIdentifierLockScreen);
        FMRequire(chinese != nil &&
                      [chinese[@"relativePaths"]
                          isEqual:@[ @"FontServicesCorePrivate/PingFangUI.ttc" ]],
                  @"modern layout must resolve the Chinese slot through CorePrivate");
        FMRequire(latin != nil &&
                      [latin[@"relativePaths"]
                          isEqual:@[ @"Core/SFUI.ttf", @"CoreUI/SFUISoft.ttc",
                                     @"CoreUI/SFUIRounded.ttf" ]],
                  @"modern Latin slot must include the soft variant");
        FMRequire(lock != nil &&
                      [lock[@"relativePaths"] isEqual:@[ @"Core/ADTNumeric.ttc" ]] &&
                      [lock[@"sharedStyleRelativePaths"] isEqual:@[
                      @"Core/SFUI.ttf", @"CoreUI/SFUIRounded.ttf"
                  ]], @"modern lock slot must contain only Core ADTNumeric");

        // An ambiguous catalog (both Chinese targets) yields no Chinese slot.
        slots = FMResolvedFontSlotsForCatalog(FMCatalogWithSupplement(
            @[ @"Core/SFUI.ttf", @"LanguageSupport/PingFang.ttc" ],
            @[ @"PingFangUI.ttc" ]));
        FMRequire(FMSlot(slots, FMFontSlotIdentifierChinese) == nil,
                  @"ambiguous Chinese targets must suppress the Chinese slot");

        // A mixed-version catalog is not a valid basis for choosing a clock
        // target. As with the Chinese exact-one policy, fail closed.
        slots = FMResolvedFontSlotsForCatalog(FMCatalog(@[
            @"Core/SFUI.ttf",
            @"LanguageSupport/PingFang.ttc",
            @"Watch/ADTTime.ttc",
            @"Watch/ADTNumeric.ttc",
        ]));
        FMRequire(FMSlot(slots, FMFontSlotIdentifierLockScreen) == nil,
                  @"ambiguous ADT targets must suppress the lock slot");

        // Shared lock-screen styles and LockClock alone do not create an
        // independently replaceable lock slot.
        slots = FMResolvedFontSlotsForCatalog(FMCatalog(@[
            @"Core/SFUI.ttf",
            @"Core/SFUIItalic.ttf",
            @"LanguageSupport/PingFang.ttc",
            @"AppFonts/LockClock.ttf",
        ]));
        FMRequire(slots.count == 2 &&
                      FMSlot(slots, FMFontSlotIdentifierLockScreen) == nil,
                  @"catalog without a dedicated clock target must hide the lock slot");
        FMRequire(FMResolvedFontSlotsForRelativePaths(@[]).count == 0,
                  @"empty path list must resolve no slots");
        FMRequire(FMResolvedFontSlotsForCatalog(@{ @"schemaVersion" : @2 })
                      .count == 0,
                  @"invalid catalog must fail closed to no slots");

        // The plain-path variant agrees with the catalog variant.
        slots = FMResolvedFontSlotsForRelativePaths(ios17Paths);
        FMRequire([FMSlot(slots, FMFontSlotIdentifierChinese)[@"relativePaths"]
                      isEqual:@[ @"LanguageSupport/PingFang.ttc" ]] &&
                      [FMSlot(slots, FMFontSlotIdentifierLockScreen)
                              [@"relativePaths"] containsObject:@"Watch/ADTNumeric.ttc"] &&
                      [FMFontSlotIdentifierForRelativePath(slots, @"Core/SFUI.ttf")
                          isEqual:FMFontSlotIdentifierLatin],
                  @"path-list resolution must agree with catalog resolution");

        printf("PASS: clock slot matches the current ADT target and excludes LockClock/shared Latin styles\n");
        return 0;
    }
}
