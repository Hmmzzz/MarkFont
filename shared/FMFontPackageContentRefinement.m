#import "FMFontPackageContentRefinement.h"

#import <CoreText/CoreText.h>

NSString *const FMFontContentSelectionReasonLegacyChinesePunctuationCompact =
    @"legacyChinesePunctuationCompact";

static NSString *const FMContentProbeHasLegacyPingFangRegular =
    @"hasLegacyPingFangRegular";
static NSString *const FMContentProbeCommaAdvanceRatio = @"commaAdvanceRatio";

static NSString *const FMLegacyChineseStockFileName = @"PingFang.ttc";
static NSString *const FMModernChineseStockFileName = @"PingFangUI.ttc";
static NSString *const FMLegacyChineseRegularFaceName = @"PingFangSC-Regular";

static BOOL FMRefinementIsDictionary(id value) {
    return [value isKindOfClass:NSDictionary.class];
}

static BOOL FMRefinementIsArray(id value) {
    return [value isKindOfClass:NSArray.class];
}

static NSDictionary<NSString *, id> * _Nullable FMRefinementLegacyChineseTarget(
    NSDictionary<NSString *, id> *catalog) {
    if (!FMRefinementIsDictionary(catalog)) return nil;
    NSArray<NSDictionary<NSString *, id> *> *files = catalog[@"files"];
    if (!FMRefinementIsArray(files)) return nil;
    NSDictionary<NSString *, id> *legacy = nil;
    BOOL hasModern = NO;
    for (id object in files) {
        if (!FMRefinementIsDictionary(object)) continue;
        NSDictionary<NSString *, id> *file = object;
        if ([file[@"fileName"] isEqual:FMLegacyChineseStockFileName] &&
            [file[@"id"] isKindOfClass:NSString.class] &&
            [file[@"relativePath"] isKindOfClass:NSString.class]) {
            legacy = file;
        }
        if ([file[@"fileName"] isEqual:FMModernChineseStockFileName]) {
            hasModern = YES;
        }
    }
    return (legacy != nil && !hasModern) ? legacy : nil;
}

static NSDictionary<NSString *, id> * _Nullable FMRefinementMatchForTarget(
    NSDictionary<NSString *, id> *matching,
    NSString *targetFileID) {
    NSArray<NSDictionary<NSString *, id> *> *matches = matching[@"matches"];
    if (!FMRefinementIsArray(matches)) return nil;
    for (id object in matches) {
        if (FMRefinementIsDictionary(object) &&
            [((NSDictionary<NSString *, id> *)object)[@"targetFileID"]
                isEqual:targetFileID]) {
            return object;
        }
    }
    return nil;
}

static BOOL FMRefinementTargetHasConflict(
    NSDictionary<NSString *, id> *matching,
    NSString *targetFileID) {
    NSArray<NSDictionary<NSString *, id> *> *conflicts = matching[@"conflicts"];
    if (!FMRefinementIsArray(conflicts)) return NO;
    for (id object in conflicts) {
        if (FMRefinementIsDictionary(object) &&
            [((NSDictionary<NSString *, id> *)object)[@"targetFileID"]
                isEqual:targetFileID]) {
            return YES;
        }
    }
    return NO;
}

static double FMRefinementProbeCommaRatio(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *probesByPath,
    NSString *path) {
    NSDictionary<NSString *, id> *probe = probesByPath[path];
    if (!FMRefinementIsDictionary(probe) ||
        ![probe[FMContentProbeHasLegacyPingFangRegular] boolValue]) {
        return 1.0;
    }
    id ratio = probe[FMContentProbeCommaAdvanceRatio];
    double value = [ratio isKindOfClass:NSNumber.class] ? [ratio doubleValue] : 1.0;
    return value > 0.0 ? value : 1.0;
}

NSArray<NSString *> *FMContentSelectionProbeRelativePaths(
    NSDictionary<NSString *, id> *matching,
    NSDictionary<NSString *, id> *catalog) {
    if (!FMRefinementIsDictionary(matching)) return @[];
    NSDictionary<NSString *, id> *target =
        FMRefinementLegacyChineseTarget(catalog);
    if (target == nil) return @[];
    NSString *targetFileID = target[@"id"];
    if (FMRefinementTargetHasConflict(matching, targetFileID)) return @[];

    NSArray<NSDictionary<NSString *, id> *> *unmatched = matching[@"unmatched"];
    if (!FMRefinementIsArray(unmatched)) return @[];

    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (id object in unmatched) {
        if (!FMRefinementIsDictionary(object)) continue;
        NSString *path =
            ((NSDictionary<NSString *, id> *)object)[@"sourceRelativePath"];
        if ([path isKindOfClass:NSString.class] && path.length > 0) {
            [paths addObject:path];
        }
    }
    if (paths.count == 0) return @[];

    NSDictionary<NSString *, id> *match =
        FMRefinementMatchForTarget(matching, targetFileID);
    NSString *matchedPath = match[@"selectedSourceRelativePath"];
    if ([matchedPath isKindOfClass:NSString.class] && matchedPath.length > 0) {
        [paths addObject:matchedPath];
    }
    return [paths.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

NSDictionary<NSString *, id> * _Nullable FMProbeFontDataForContentSelection(
    NSData *fontData) {
    if (![fontData isKindOfClass:NSData.class] || fontData.length == 0) return nil;
    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromData(
        (__bridge CFDataRef)fontData);
    if (descriptors == NULL) return nil;

    NSDictionary<NSString *, id> *result = nil;
    NSArray *descriptorArray = (__bridge NSArray *)descriptors;
    for (id object in descriptorArray) {
        if (CFGetTypeID((__bridge CFTypeRef)object) !=
            CTFontDescriptorGetTypeID()) {
            continue;
        }
        CTFontDescriptorRef descriptor = (__bridge CTFontDescriptorRef)object;
        CFStringRef name = CTFontDescriptorCopyAttribute(descriptor,
                                                         kCTFontNameAttribute);
        if (name == NULL) continue;
        BOOL isRegularFace = [(__bridge NSString *)name
            isEqualToString:FMLegacyChineseRegularFaceName];
        CFRelease(name);
        if (!isRegularFace) continue;

        NSNumber *commaRatio = nil;
        CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 100.0, NULL);
        if (font != NULL) {
            UniChar comma = 0xFF0C;
            CGGlyph glyph = 0;
            if (CTFontGetGlyphsForCharacters(font, &comma, &glyph, 1) &&
                glyph != 0) {
                CGFloat advance = CTFontGetAdvancesForGlyphs(
                    font, kCTFontOrientationDefault, &glyph, NULL, 1);
                if (advance > 0.0) commaRatio = @(advance / 100.0);
            }
            CFRelease(font);
        }
        result = @{
            FMContentProbeHasLegacyPingFangRegular : @YES,
            FMContentProbeCommaAdvanceRatio : commaRatio ?: @1.0,
        };
        break;
    }
    CFRelease(descriptors);
    if (result != nil) return result;
    return @{ FMContentProbeHasLegacyPingFangRegular : @NO };
}

NSDictionary<NSString *, id> *FMRefineLegacyChineseTargetSelection(
    NSDictionary<NSString *, id> *matching,
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *probesByPath,
    NSDictionary<NSString *, id> *catalog) {
    if (!FMRefinementIsDictionary(matching) ||
        !FMRefinementIsDictionary(catalog) ||
        !FMRefinementIsDictionary(probesByPath)) {
        return matching;
    }
    NSDictionary<NSString *, id> *target =
        FMRefinementLegacyChineseTarget(catalog);
    if (target == nil) return matching;
    NSString *targetFileID = target[@"id"];
    if (FMRefinementTargetHasConflict(matching, targetFileID)) return matching;

    // Candidate: the exact-name source already matched to the target.
    NSDictionary<NSString *, id> *incumbent =
        FMRefinementMatchForTarget(matching, targetFileID);
    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    NSMutableArray<NSString *> *incumbentDisplacedPaths = [NSMutableArray array];
    if (incumbent != nil) {
        NSArray<NSString *> *duplicates =
            incumbent[@"duplicateSourceRelativePaths"];
        if (FMRefinementIsArray(duplicates)) {
            [incumbentDisplacedPaths addObjectsFromArray:duplicates];
        }
        [candidates addObject:@{
            @"sourceRelativePath" : incumbent[@"selectedSourceRelativePath"],
            @"sourceSHA256" : incumbent[@"sourceSHA256"],
            @"fileSize" : incumbent[@"fileSize"],
            @"exactFileName" : @YES,
            @"displacedPaths" : [incumbentDisplacedPaths copy],
        }];
    }

    // Additional candidates: unmatched sources whose probe qualifies.
    NSArray<NSDictionary<NSString *, id> *> *unmatched = matching[@"unmatched"];
    NSMutableArray<NSDictionary<NSString *, id> *> *remainingUnmatched =
        [NSMutableArray array];
    if (FMRefinementIsArray(unmatched)) {
        for (id object in unmatched) {
            if (!FMRefinementIsDictionary(object)) continue;
            NSDictionary<NSString *, id> *source = object;
            NSString *path = source[@"sourceRelativePath"];
            NSDictionary<NSString *, id> *probe = probesByPath[path];
            if ([path isKindOfClass:NSString.class] &&
                FMRefinementIsDictionary(probe) &&
                [probe[FMContentProbeHasLegacyPingFangRegular] boolValue]) {
                [candidates addObject:@{
                    @"sourceRelativePath" : path,
                    @"sourceSHA256" : source[@"sourceSHA256"],
                    @"fileSize" : source[@"fileSize"],
                    @"exactFileName" : @NO,
                    @"displacedPaths" : @[],
                }];
            } else {
                [remainingUnmatched addObject:source];
            }
        }
    }
    if (candidates.count == 0) return matching;

    // Rank: smallest comma ratio, then exact stock filename, then path order.
    [candidates sortUsingComparator:^NSComparisonResult(
                                 NSDictionary<NSString *, id> *left,
                                 NSDictionary<NSString *, id> *right) {
        double leftRatio = FMRefinementProbeCommaRatio(
            probesByPath, left[@"sourceRelativePath"]);
        double rightRatio = FMRefinementProbeCommaRatio(
            probesByPath, right[@"sourceRelativePath"]);
        if (leftRatio != rightRatio) {
            return leftRatio < rightRatio ? NSOrderedAscending : NSOrderedDescending;
        }
        BOOL leftExact = [left[@"exactFileName"] boolValue];
        BOOL rightExact = [right[@"exactFileName"] boolValue];
        if (leftExact != rightExact) {
            return leftExact ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left[@"sourceRelativePath"] compare:right[@"sourceRelativePath"]];
    }];

    NSDictionary<NSString *, id> *winner = candidates.firstObject;
    if (incumbent != nil &&
        [winner[@"sourceRelativePath"]
            isEqual:incumbent[@"selectedSourceRelativePath"]]) {
        return matching;
    }

    // Displaced sources go back to "unmatched" under their own filenames.
    NSMutableArray<NSDictionary<NSString *, id> *> *finalUnmatched =
        [NSMutableArray arrayWithArray:remainingUnmatched];
    NSMutableArray<NSDictionary<NSString *, id> *> *summaryCandidates =
        [NSMutableArray arrayWithCapacity:candidates.count];
    for (NSDictionary<NSString *, id> *candidate in candidates) {
        NSString *winnerPath = winner[@"sourceRelativePath"];
        BOOL isSelected =
            [candidate[@"sourceRelativePath"] isEqual:winnerPath];
        if (!isSelected) {
            NSMutableArray<NSString *> *paths =
                [NSMutableArray arrayWithObject:candidate[@"sourceRelativePath"]];
            [paths addObjectsFromArray:candidate[@"displacedPaths"]];
            for (NSString *displacedPath in paths) {
                [finalUnmatched addObject:@{
                    @"fileName" : displacedPath.lastPathComponent,
                    @"sourceRelativePath" : displacedPath,
                    @"sourceSHA256" : candidate[@"sourceSHA256"],
                    @"fileSize" : candidate[@"fileSize"],
                }];
            }
        }
        [summaryCandidates addObject:@{
            @"sourceRelativePath" : candidate[@"sourceRelativePath"],
            @"commaAdvanceRatio" : @(FMRefinementProbeCommaRatio(
                probesByPath, candidate[@"sourceRelativePath"])),
            @"exactFileName" : candidate[@"exactFileName"],
            @"selected" : @(isSelected),
        }];
    }
    [finalUnmatched sortUsingComparator:^NSComparisonResult(
                                 NSDictionary<NSString *, id> *left,
                                 NSDictionary<NSString *, id> *right) {
        NSComparisonResult nameResult =
            [left[@"fileName"] compare:right[@"fileName"]];
        return nameResult == NSOrderedSame
            ? [left[@"sourceRelativePath"] compare:right[@"sourceRelativePath"]]
            : nameResult;
    }];

    NSMutableArray<NSDictionary<NSString *, id> *> *finalMatches =
        [NSMutableArray array];
    NSArray<NSDictionary<NSString *, id> *> *matches = matching[@"matches"];
    if (FMRefinementIsArray(matches)) {
        for (id object in matches) {
            if (!FMRefinementIsDictionary(object)) continue;
            if ([((NSDictionary<NSString *, id> *)object)[@"targetFileID"]
                    isEqual:targetFileID]) {
                continue;
            }
            [finalMatches addObject:object];
        }
    }
    [finalMatches addObject:@{
        @"fileName" : target[@"fileName"],
        @"targetFileID" : targetFileID,
        @"targetRelativePath" : target[@"relativePath"],
        @"selectedSourceRelativePath" : winner[@"sourceRelativePath"],
        @"sourceSHA256" : winner[@"sourceSHA256"],
        @"fileSize" : winner[@"fileSize"],
        @"duplicateSourceRelativePaths" : winner[@"displacedPaths"],
        @"selectionReason" :
            FMFontContentSelectionReasonLegacyChinesePunctuationCompact,
    }];
    [finalMatches sortUsingComparator:^NSComparisonResult(
                                 NSDictionary<NSString *, id> *left,
                                 NSDictionary<NSString *, id> *right) {
        NSComparisonResult nameResult =
            [left[@"fileName"] compare:right[@"fileName"]];
        return nameResult == NSOrderedSame
            ? [left[@"targetRelativePath"] compare:right[@"targetRelativePath"]]
            : nameResult;
    }];

    NSMutableDictionary<NSString *, id> *refined =
        [NSMutableDictionary dictionaryWithDictionary:matching];
    refined[@"matches"] = finalMatches;
    refined[@"unmatched"] = finalUnmatched;
    refined[@"matchedTargetCount"] = @(finalMatches.count);
    refined[@"unmatchedSourceCount"] = @(finalUnmatched.count);
    refined[@"contentSelection"] = @{
        @"targetFileID" : targetFileID,
        @"targetRelativePath" : target[@"relativePath"],
        @"selectedSourceRelativePath" : winner[@"sourceRelativePath"],
        @"selectionReason" :
            FMFontContentSelectionReasonLegacyChinesePunctuationCompact,
        @"candidates" : summaryCandidates,
    };
    return refined;
}
