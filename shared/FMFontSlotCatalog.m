#import "FMFontSlotCatalog.h"

#import "FMDataModel.h"
#import "FMLocalization.h"

NSString *const FMFontSlotIdentifierChinese = @"chinese";
NSString *const FMFontSlotIdentifierLatin = @"latin";
NSString *const FMFontSlotIdentifierLockScreen = @"lockscreen";

// Declaration order is used to keep slot file sets disjoint. The Chinese and
// lock-screen entries are placeholders; their single targets are resolved by
// build-specific policies instead of a broad file-name lookup.
static NSArray<NSDictionary<NSString *, id> *> *FMFontSlotDefinitions(void) {
    return @[
        @{
            @"slotID" : FMFontSlotIdentifierChinese,
            @"name" : @"中文字体",
            @"chinesePolicy" : @YES,
        },
        @{
            @"slotID" : FMFontSlotIdentifierLatin,
            @"name" : @"英文字体",
            @"fileNames" : @[
                @"SFUI.ttf",
                @"SFUIItalic.ttf",
                @"SFUISoft.ttc",
                @"SFUIRounded.ttf",
                @"SFUIMono.ttf",
                @"SFUIMonoItalic.ttf",
            ],
        },
        @{
            @"slotID" : FMFontSlotIdentifierLockScreen,
            @"name" : @"锁屏时间字体",
            // iOS 16 PosterKit uses ADTTime. iOS 17+ uses ADTNumeric (which
            // itself moves from Watch/ to Core/ on iOS 18), while ADTTime
            // remains installed for Watch time faces. Prefer ADTNumeric when
            // both exist; LockClock.ttf is not the PosterKit time face.
            @"dedicatedClockPolicy" : @YES,
            // PosterKit's default SF Pro and Rounded clock styles are backed
            // by the same physical files as system Latin text. Surface that
            // relationship to the UI without making the paths overlap.
            @"sharedStyleFileNames" : @[ @"SFUI.ttf", @"SFUIRounded.ttf" ],
            @"sharedStyleOwnerSlotID" : FMFontSlotIdentifierLatin,
        },
    ];
}

NSArray<NSDictionary<NSString *, id> *> *FMResolvedFontSlotsForCatalog(
    NSDictionary<NSString *, id> *catalog) {
    if (!FMValidateFontCatalogDocument(catalog, nil)) return @[];
    NSMutableArray<NSString *> *relativePaths = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *file in catalog[@"files"]) {
        if ([file[@"relativePath"] isKindOfClass:NSString.class]) {
            [relativePaths addObject:file[@"relativePath"]];
        }
    }
    return FMResolvedFontSlotsForRelativePaths(relativePaths);
}

NSArray<NSDictionary<NSString *, id> *> *FMResolvedFontSlotsForRelativePaths(
    NSArray<NSString *> *relativePaths) {
    if (![relativePaths isKindOfClass:NSArray.class]) return @[];

    NSMutableDictionary<NSString *, NSString *> *relativePathByFileName =
        [NSMutableDictionary dictionary];
    for (NSString *relativePath in relativePaths) {
        if (![relativePath isKindOfClass:NSString.class] ||
            relativePath.pathComponents.count == 0) {
            continue;
        }
        NSString *fileName = relativePath.lastPathComponent;
        if (relativePathByFileName[fileName] == nil) {
            relativePathByFileName[fileName] = relativePath;
        }
    }

    NSMutableArray<NSMutableDictionary<NSString *, id> *> *slots =
        [NSMutableArray array];
    NSMutableSet<NSString *> *claimedPaths = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *definition in FMFontSlotDefinitions()) {
        NSMutableArray<NSString *> *fileNames = [NSMutableArray array];
        if ([definition[@"chinesePolicy"] boolValue]) {
            // Mirror the device catalog's exact-one-Chinese-target contract;
            // an ambiguous catalog yields no Chinese slot at all.
            NSString *modern = relativePathByFileName[@"PingFangUI.ttc"];
            NSString *legacy = relativePathByFileName[@"PingFang.ttc"];
            if (modern != nil && legacy == nil) {
                [fileNames addObject:@"PingFangUI.ttc"];
            } else if (legacy != nil && modern == nil) {
                [fileNames addObject:@"PingFang.ttc"];
            }
        } else if ([definition[@"dedicatedClockPolicy"] boolValue]) {
            // ADTTime and ADTNumeric legitimately coexist on iOS 17+. The
            // Numeric collection owns PosterKit there; Time is the iOS 16
            // fallback when Numeric is absent.
            NSString *legacy = relativePathByFileName[@"ADTTime.ttc"];
            NSString *modern = relativePathByFileName[@"ADTNumeric.ttc"];
            if (modern != nil) {
                [fileNames addObject:@"ADTNumeric.ttc"];
            } else if (legacy != nil) {
                [fileNames addObject:@"ADTTime.ttc"];
            }
        } else {
            [fileNames addObjectsFromArray:definition[@"fileNames"]];
        }

        NSMutableArray<NSString *> *slotRelativePaths = [NSMutableArray array];
        for (NSString *fileName in fileNames) {
            NSString *relativePath = relativePathByFileName[fileName];
            if (relativePath == nil || [claimedPaths containsObject:relativePath]) {
                continue;
            }
            [slotRelativePaths addObject:relativePath];
            [claimedPaths addObject:relativePath];
        }
        if (slotRelativePaths.count == 0) continue;
        NSMutableDictionary<NSString *, id> *slot = [@{
            @"slotID" : definition[@"slotID"],
            @"name" : FMLocalized(definition[@"name"]),
            @"relativePaths" : slotRelativePaths,
        } mutableCopy];
        NSArray<NSString *> *sharedStyleFileNames =
            [definition[@"sharedStyleFileNames"] isKindOfClass:NSArray.class]
                ? definition[@"sharedStyleFileNames"]
                : @[];
        NSMutableArray<NSString *> *sharedStyleRelativePaths =
            [NSMutableArray array];
        for (NSString *fileName in sharedStyleFileNames) {
            NSString *relativePath = relativePathByFileName[fileName];
            if (relativePath != nil) {
                [sharedStyleRelativePaths addObject:relativePath];
            }
        }
        if (sharedStyleRelativePaths.count > 0) {
            slot[@"sharedStyleRelativePaths"] = sharedStyleRelativePaths;
            slot[@"sharedStyleOwnerSlotID"] =
                definition[@"sharedStyleOwnerSlotID"];
        }
        [slots addObject:slot];
    }
    return slots;
}

NSString *FMFontSlotIdentifierForRelativePath(
    NSArray<NSDictionary<NSString *, id> *> *resolvedSlots,
    NSString *relativePath) {
    if (![relativePath isKindOfClass:NSString.class]) return nil;
    for (NSDictionary<NSString *, id> *slot in resolvedSlots) {
        NSArray<NSString *> *paths =
            [slot[@"relativePaths"] isKindOfClass:NSArray.class]
                ? slot[@"relativePaths"]
                : nil;
        if ([paths containsObject:relativePath]) return slot[@"slotID"];
    }
    return nil;
}
