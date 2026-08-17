#import <Foundation/Foundation.h>

#import "FMFontCatalog.h"
#import "FMFontPackageMatcher.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary<NSString *, id> *FMRegularEntry(NSString *relativePath,
                                                      NSString *sha256) {
    return @{
        @"relativePath" : relativePath,
        @"type" : @"regular",
        @"mode" : @0644,
        @"uid" : @0,
        @"gid" : @0,
        @"size" : @100,
        @"sha256" : sha256,
    };
}

static NSDictionary<NSString *, id> *FMPackageEntry(NSString *relativePath,
                                                      NSString *sha256) {
    return @{
        @"relativePath" : relativePath,
        @"sha256" : sha256,
        @"fileSize" : @100,
    };
}

static NSDictionary<NSString *, id> *FMCatalogWithChineseFile(
    NSString *fileName,
    NSString *systemBuild,
    NSError **error) {
    NSMutableArray *primaryEntries = [NSMutableArray arrayWithObject:
        FMRegularEntry(
            @"Core/SFUI.ttf",
            @"1111111111111111111111111111111111111111111111111111111111111111")];
    NSDictionary *supplementalManifest = nil;
    if ([fileName isEqual:@"PingFangUI.ttc"]) {
        supplementalManifest = @{
            @"schemaVersion" : @2,
            @"entries" : @[
                FMRegularEntry(
                    @"PingFangUI.ttc",
                    @"2222222222222222222222222222222222222222222222222222222222222222"),
            ],
        };
    } else {
        [primaryEntries addObject:FMRegularEntry(
            [@"LanguageSupport" stringByAppendingPathComponent:fileName],
            @"2222222222222222222222222222222222222222222222222222222222222222")];
    }
    NSDictionary *manifest = @{
        @"schemaVersion" : @2,
        @"entries" : primaryEntries,
    };
    return FMCreateFontCatalogFromManifests(
        manifest, supplementalManifest, systemBuild,
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        supplementalManifest != nil
            ? @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            : nil,
        error);
}

static NSDictionary<NSString *, id> *FMCatalogWithClockFile(
    NSString *fileName,
    NSString *systemBuild,
    NSError **error) {
    NSString *relativePath = [fileName isEqual:@"ADTTime.ttc"]
        ? @"Watch/ADTTime.ttc"
        : @"Core/ADTNumeric.ttc";
    NSArray<NSDictionary<NSString *, id> *> *entries = [@[
        FMRegularEntry(
            @"Core/SFUI.ttf",
            @"1111111111111111111111111111111111111111111111111111111111111111"),
        FMRegularEntry(
            relativePath,
            @"3333333333333333333333333333333333333333333333333333333333333333"),
    ] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                       NSDictionary *right) {
        return [left[@"relativePath"] compare:right[@"relativePath"]];
    }];
    NSDictionary *manifest = @{
        @"schemaVersion" : @2,
        @"entries" : entries,
    };
    return FMCreateFontCatalogFromManifest(
        manifest, systemBuild,
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        error);
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        NSDictionary *legacyCatalog =
            FMCatalogWithChineseFile(@"PingFang.ttc", @"21D61", &error);
        FMRequire(legacyCatalog != nil,
                  [NSString stringWithFormat:@"legacy catalog setup failed: %@", error]);

        NSString *customHash =
            @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        NSString *legacyChineseHash =
            @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
        NSString *modernChineseHash =
            @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
        NSDictionary *legacyBoth = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"Core/SFUI.ttf", customHash),
            FMPackageEntry(@"CoreUI/SFUI.ttf", customHash),
            FMPackageEntry(@"PingFang.ttc", legacyChineseHash),
            FMPackageEntry(@"PingFangUI.ttc", modernChineseHash),
            FMPackageEntry(@"Extras/Unknown.otf", customHash),
        ], legacyCatalog, &error);
        FMRequire(legacyBoth != nil,
                  [NSString stringWithFormat:@"legacy dual-name matching failed: %@", error]);
        FMRequire([legacyBoth[@"packageFontFileCount"] unsignedIntegerValue] == 5 &&
                      [legacyBoth[@"matchedTargetCount"] unsignedIntegerValue] == 2 &&
                      [legacyBoth[@"unmatchedSourceCount"] unsignedIntegerValue] == 1 &&
                      [legacyBoth[@"otherSystemVersionSourceCount"] unsignedIntegerValue] == 1 &&
                      [legacyBoth[@"conflictTargetCount"] unsignedIntegerValue] == 0 &&
                      [legacyBoth[@"deduplicatedSourceCount"] unsignedIntegerValue] == 1,
                  @"legacy dual-name matching counts are inconsistent");
        NSDictionary *pingFangMatch = legacyBoth[@"matches"][0];
        NSDictionary *sfuiMatch = legacyBoth[@"matches"][1];
        NSDictionary *legacyOtherVersion = legacyBoth[@"otherSystemVersionSources"][0];
        FMRequire([pingFangMatch[@"targetRelativePath"]
                       isEqual:@"LanguageSupport/PingFang.ttc"] &&
                      [pingFangMatch[@"selectedSourceRelativePath"]
                          isEqual:@"PingFang.ttc"] &&
                      [sfuiMatch[@"targetRelativePath"] isEqual:@"Core/SFUI.ttf"] &&
                      [sfuiMatch[@"duplicateSourceRelativePaths"]
                          isEqual:@[ @"CoreUI/SFUI.ttf" ]] &&
                      [legacyBoth[@"unmatched"][0][@"fileName"] isEqual:@"Unknown.otf"] &&
                      [legacyOtherVersion[@"fileName"] isEqual:@"PingFangUI.ttc"] &&
                      [[NSSet setWithArray:legacyOtherVersion.allKeys]
                          isEqual:[NSSet setWithArray:@[
                              @"fileName", @"sourceRelativePath"
                          ]]],
                  @"iOS 14-17 did not isolate the modern Chinese source from all targets");

        NSDictionary *modernCatalog =
            FMCatalogWithChineseFile(@"PingFangUI.ttc", @"22A3354", &error);
        FMRequire(modernCatalog != nil,
                  [NSString stringWithFormat:@"modern catalog setup failed: %@", error]);
        NSDictionary *modernBoth = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"PingFang.ttc", legacyChineseHash),
            FMPackageEntry(@"PingFangUI.ttc", modernChineseHash),
        ], modernCatalog, &error);
        NSDictionary *modernOtherVersion = modernBoth[@"otherSystemVersionSources"][0];
        FMRequire([modernBoth[@"matchedTargetCount"] unsignedIntegerValue] == 1 &&
                      [modernBoth[@"otherSystemVersionSourceCount"] unsignedIntegerValue] == 1 &&
                      [modernBoth[@"conflictTargetCount"] unsignedIntegerValue] == 0 &&
                      [modernBoth[@"matches"][0][@"targetRelativePath"]
                          isEqual:@"FontServicesCorePrivate/PingFangUI.ttc"] &&
                      [modernBoth[@"matches"][0][@"selectedSourceRelativePath"]
                          isEqual:@"PingFangUI.ttc"] &&
                      [modernOtherVersion[@"fileName"] isEqual:@"PingFang.ttc"] &&
                      [[NSSet setWithArray:modernOtherVersion.allKeys]
                          isEqual:[NSSet setWithArray:@[
                              @"fileName", @"sourceRelativePath"
                          ]]],
                  @"iOS 18-26 did not isolate the legacy Chinese source from all targets");

        NSDictionary *legacyOtherVersionOnly = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"PingFangUI.ttc", modernChineseHash),
        ], legacyCatalog, &error);
        FMRequire([legacyOtherVersionOnly[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                      [legacyOtherVersionOnly[@"otherSystemVersionSourceCount"] unsignedIntegerValue] == 1 &&
                      [legacyOtherVersionOnly[@"otherSystemVersionSources"][0][@"fileName"]
                          isEqual:@"PingFangUI.ttc"],
                  @"modern package name was not safely ignored on a legacy build");

        NSDictionary *modernOtherVersionOnly = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"PingFang.ttc", legacyChineseHash),
        ], modernCatalog, &error);
        FMRequire([modernOtherVersionOnly[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                      [modernOtherVersionOnly[@"otherSystemVersionSourceCount"] unsignedIntegerValue] == 1 &&
                      [modernOtherVersionOnly[@"otherSystemVersionSources"][0][@"fileName"]
                          isEqual:@"PingFang.ttc"],
                  @"legacy package name was not safely ignored on a modern build");

        NSString *legacyClockHash =
            @"abababababababababababababababababababababababababababababababab";
        NSString *modernClockHash =
            @"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";
        NSDictionary *ios16ClockCatalog =
            FMCatalogWithClockFile(@"ADTTime.ttc", @"20C65", &error);
        FMRequire(ios16ClockCatalog != nil,
                  [NSString stringWithFormat:@"iOS 16 clock catalog setup failed: %@",
                                             error]);
        NSDictionary *ios16ClockBoth = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"Clock/ADTTime.ttc", legacyClockHash),
            FMPackageEntry(@"Clock/ADTNumeric.ttc", modernClockHash),
            FMPackageEntry(@"Clock/LockClock.ttf", customHash),
        ], ios16ClockCatalog, &error);
        FMRequire([ios16ClockBoth[@"matchedTargetCount"] unsignedIntegerValue] == 1 &&
                      [ios16ClockBoth[@"otherSystemVersionSourceCount"]
                          unsignedIntegerValue] == 1 &&
                      [ios16ClockBoth[@"unmatchedSourceCount"] unsignedIntegerValue] == 1 &&
                      [ios16ClockBoth[@"matches"][0][@"targetRelativePath"]
                          isEqual:@"Watch/ADTTime.ttc"] &&
                      [ios16ClockBoth[@"matches"][0][@"selectedSourceRelativePath"]
                          isEqual:@"Clock/ADTTime.ttc"] &&
                      [ios16ClockBoth[@"otherSystemVersionSources"][0][@"fileName"]
                          isEqual:@"ADTNumeric.ttc"] &&
                      [ios16ClockBoth[@"unmatched"][0][@"fileName"]
                          isEqual:@"LockClock.ttf"],
                  @"iOS 16 must match ADTTime and isolate ADTNumeric/LockClock");

        NSDictionary *modernClockCatalog =
            FMCatalogWithClockFile(@"ADTNumeric.ttc", @"22A3354", &error);
        FMRequire(modernClockCatalog != nil,
                  [NSString stringWithFormat:@"modern clock catalog setup failed: %@",
                                             error]);
        NSDictionary *modernClockBoth = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"Clock/ADTTime.ttc", legacyClockHash),
            FMPackageEntry(@"Clock/ADTNumeric.ttc", modernClockHash),
        ], modernClockCatalog, &error);
        FMRequire([modernClockBoth[@"matchedTargetCount"] unsignedIntegerValue] == 1 &&
                      [modernClockBoth[@"otherSystemVersionSourceCount"]
                          unsignedIntegerValue] == 1 &&
                      [modernClockBoth[@"unmatchedSourceCount"] unsignedIntegerValue] == 0 &&
                      [modernClockBoth[@"matches"][0][@"targetRelativePath"]
                          isEqual:@"Core/ADTNumeric.ttc"] &&
                      [modernClockBoth[@"matches"][0][@"selectedSourceRelativePath"]
                          isEqual:@"Clock/ADTNumeric.ttc"] &&
                      [modernClockBoth[@"otherSystemVersionSources"][0][@"fileName"]
                          isEqual:@"ADTTime.ttc"],
                  @"newer builds must match ADTNumeric and isolate ADTTime");

        NSDictionary *caseMismatch = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"LanguageSupport/pingfang.ttc", legacyChineseHash),
        ], legacyCatalog, &error);
        FMRequire([caseMismatch[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                      [caseMismatch[@"otherSystemVersionSourceCount"]
                          unsignedIntegerValue] == 0 &&
                      [caseMismatch[@"unmatchedSourceCount"] unsignedIntegerValue] == 1,
                  @"case-mismatched Chinese filename was not rejected");

        NSDictionary *conflict = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(
                @"Core/SFUI.ttf",
                @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
            FMPackageEntry(
                @"CoreUI/SFUI.ttf",
                @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        ], modernCatalog, &error);
        FMRequire([conflict[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                      [conflict[@"conflictTargetCount"] unsignedIntegerValue] == 1,
                  @"different same-name package files were not blocked as a conflict");

        FMRequire(FMMatchFontPackageFilesToCatalog(@[
                      FMPackageEntry(
                          @"../SFUI.ttf",
                          @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
                  ], modernCatalog, nil) == nil,
                  @"package matcher accepted a traversal path");

        printf("PASS: exact build-bound PingFang/ADT matching and package duplicate handling\n");
    }
    return 0;
}
