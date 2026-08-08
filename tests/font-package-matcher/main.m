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
                      [legacyBoth[@"compatibilityAlternateSourceCount"] unsignedIntegerValue] == 1 &&
                      [legacyBoth[@"conflictTargetCount"] unsignedIntegerValue] == 0 &&
                      [legacyBoth[@"deduplicatedSourceCount"] unsignedIntegerValue] == 1,
                  @"legacy dual-name matching counts are inconsistent");
        NSDictionary *pingFangMatch = legacyBoth[@"matches"][0];
        NSDictionary *sfuiMatch = legacyBoth[@"matches"][1];
        NSDictionary *legacyAlternate = legacyBoth[@"compatibilityAlternates"][0];
        FMRequire([pingFangMatch[@"targetRelativePath"]
                       isEqual:@"LanguageSupport/PingFang.ttc"] &&
                      [pingFangMatch[@"selectedSourceRelativePath"]
                          isEqual:@"PingFang.ttc"] &&
                      [sfuiMatch[@"targetRelativePath"] isEqual:@"Core/SFUI.ttf"] &&
                      [sfuiMatch[@"duplicateSourceRelativePaths"]
                          isEqual:@[ @"CoreUI/SFUI.ttf" ]] &&
                      [legacyBoth[@"unmatched"][0][@"fileName"] isEqual:@"Unknown.otf"] &&
                      [legacyAlternate[@"fileName"] isEqual:@"PingFangUI.ttc"] &&
                      [legacyAlternate[@"currentTargetFileName"] isEqual:@"PingFang.ttc"] &&
                      [[NSSet setWithArray:legacyAlternate.allKeys]
                          isEqual:[NSSet setWithArray:@[
                              @"fileName", @"sourceRelativePath",
                              @"currentTargetFileName"
                          ]]],
                  @"iOS 14-17 exact Chinese file did not win over the modern alternate");

        NSDictionary *modernCatalog =
            FMCatalogWithChineseFile(@"PingFangUI.ttc", @"22A3354", &error);
        FMRequire(modernCatalog != nil,
                  [NSString stringWithFormat:@"modern catalog setup failed: %@", error]);
        NSDictionary *modernBoth = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"PingFang.ttc", legacyChineseHash),
            FMPackageEntry(@"PingFangUI.ttc", modernChineseHash),
        ], modernCatalog, &error);
        FMRequire([modernBoth[@"matchedTargetCount"] unsignedIntegerValue] == 1 &&
                      [modernBoth[@"compatibilityAlternateSourceCount"] unsignedIntegerValue] == 1 &&
                      [modernBoth[@"conflictTargetCount"] unsignedIntegerValue] == 0 &&
                      [modernBoth[@"matches"][0][@"targetRelativePath"]
                          isEqual:@"FontServicesCorePrivate/PingFangUI.ttc"] &&
                      [modernBoth[@"matches"][0][@"selectedSourceRelativePath"]
                          isEqual:@"PingFangUI.ttc"] &&
                      [modernBoth[@"compatibilityAlternates"][0][@"fileName"]
                          isEqual:@"PingFang.ttc"],
                  @"iOS 18-26 exact Chinese file did not win over the legacy alternate");

        NSDictionary *legacyFallback = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"PingFangUI.ttc", modernChineseHash),
        ], legacyCatalog, &error);
        FMRequire([legacyFallback[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                      [legacyFallback[@"compatibilityAlternateSourceCount"] unsignedIntegerValue] == 1 &&
                      [legacyFallback[@"compatibilityAlternates"][0][@"fileName"]
                          isEqual:@"PingFangUI.ttc"],
                  @"modern package name was not safely ignored on a legacy build");

        NSDictionary *modernFallback = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"PingFang.ttc", legacyChineseHash),
        ], modernCatalog, &error);
        FMRequire([modernFallback[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                      [modernFallback[@"compatibilityAlternateSourceCount"] unsignedIntegerValue] == 1 &&
                      [modernFallback[@"compatibilityAlternates"][0][@"fileName"]
                          isEqual:@"PingFang.ttc"],
                  @"legacy package name was not safely ignored on a modern build");

        NSDictionary *caseMismatch = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"LanguageSupport/pingfang.ttc", legacyChineseHash),
        ], legacyCatalog, &error);
        FMRequire([caseMismatch[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                      [caseMismatch[@"compatibilityAlternateSourceCount"]
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

        printf("PASS: exact build-bound PingFang matching and package duplicate handling\n");
    }
    return 0;
}
