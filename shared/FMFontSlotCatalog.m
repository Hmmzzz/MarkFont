#import "FMFontSlotCatalog.h"

#import "FMDataModel.h"
#import "FMLocalization.h"

NSString *const FMFontSlotIdentifierChinese = @"chinese";
NSString *const FMFontSlotIdentifierLatin = @"latin";
NSString *const FMFontSlotIdentifierLockScreen = @"lockscreen";

// Declaration order is the precedence order used to keep slot file sets
// disjoint. The Chinese entry is a placeholder; its single target is resolved
// by the build-specific layout policy instead of a plain file-name lookup.
static NSArray<NSDictionary<NSString *, id> *> *FMFontSlotDefinitions(void) {
    return @[
        @{
            @"slotID" : FMFontSlotIdentifierChinese,
            @"name" : @"中文字体",
            @"chinesePolicy" : @YES,
            @"mergePriority" : @300,
        },
        @{
            @"slotID" : FMFontSlotIdentifierLatin,
            @"name" : @"英文字体",
            @"mergePriority" : @100,
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
            // iOS 16-26 PosterKit time-font identifiers resolve into these
            // catalog files. SFUI/SFUIRounded are shared with general UI text;
            // ADTNumeric and SFCompact move from Watch/ to Core/ on iOS 18,
            // but filename-based catalog resolution remains stable.
            @"mergePriority" : @200,
            @"fileNames" : @[
                @"SFUI.ttf",
                @"SFUIRounded.ttf",
                @"ADTNumeric.ttc",
                @"NewYork.ttf",
                @"SFArabic.ttf",
                @"SFArabicRounded.ttf",
                @"SFHebrew.ttf",
                @"SFHebrewRounded.ttf",
                @"SFCompact.ttf",
                @"SFCompactRounded.ttf",
                @"LockClock.ttf",
            ],
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
        } else {
            [fileNames addObjectsFromArray:definition[@"fileNames"]];
        }

        NSMutableArray<NSString *> *relativePaths = [NSMutableArray array];
        for (NSString *fileName in fileNames) {
            NSString *relativePath = relativePathByFileName[fileName];
            if (relativePath == nil) continue;
            [relativePaths addObject:relativePath];
        }
        if (relativePaths.count == 0) continue;
        [slots addObject:[@{
            @"slotID" : definition[@"slotID"],
            @"name" : FMLocalized(definition[@"name"]),
            @"relativePaths" : relativePaths,
            @"mergePriority" : definition[@"mergePriority"] ?: @0,
        } mutableCopy]];
    }

    NSMutableDictionary<NSString *, NSNumber *> *pathUseCounts =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *slot in slots) {
        for (NSString *relativePath in slot[@"relativePaths"]) {
            pathUseCounts[relativePath] = @([pathUseCounts[relativePath]
                unsignedIntegerValue] + 1);
        }
    }
    for (NSMutableDictionary<NSString *, id> *slot in slots) {
        NSMutableArray<NSString *> *sharedPaths = [NSMutableArray array];
        for (NSString *relativePath in slot[@"relativePaths"]) {
            if ([pathUseCounts[relativePath] unsignedIntegerValue] > 1) {
                [sharedPaths addObject:relativePath];
            }
        }
        slot[@"sharedRelativePaths"] = sharedPaths;
    }
    return slots;
}

NSString *FMFontSlotIdentifierForRelativePath(
    NSArray<NSDictionary<NSString *, id> *> *resolvedSlots,
    NSString *relativePath) {
    if (![relativePath isKindOfClass:NSString.class]) return nil;
    NSString *owner = nil;
    NSInteger ownerPriority = NSIntegerMin;
    for (NSDictionary<NSString *, id> *slot in resolvedSlots) {
        NSArray<NSString *> *paths =
            [slot[@"relativePaths"] isKindOfClass:NSArray.class]
                ? slot[@"relativePaths"]
                : nil;
        NSInteger priority = [slot[@"mergePriority"] integerValue];
        if ([paths containsObject:relativePath] &&
            (owner == nil || priority > ownerPriority)) {
            owner = slot[@"slotID"];
            ownerPriority = priority;
        }
    }
    return owner;
}
