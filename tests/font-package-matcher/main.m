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

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        NSDictionary *manifest = @{
            @"schemaVersion" : @2,
            @"entries" : @[
                FMRegularEntry(
                    @"Core/SFUI.ttf",
                    @"1111111111111111111111111111111111111111111111111111111111111111"),
                FMRegularEntry(
                    @"LanguageSupport/PingFang.ttc",
                    @"2222222222222222222222222222222222222222222222222222222222222222"),
            ],
        };
        NSDictionary *catalog = FMCreateFontCatalogFromManifest(
            manifest, @"21D61",
            @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            &error);
        FMRequire(catalog != nil,
                  [NSString stringWithFormat:@"catalog setup failed: %@", error]);

        NSString *customHash =
            @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        NSDictionary *result = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(@"Core/SFUI.ttf", customHash),
            FMPackageEntry(@"CoreUI/SFUI.ttf", customHash),
            FMPackageEntry(
                @"PingFang.ttc",
                @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
            FMPackageEntry(
                @"PingFangUI.ttc",
                @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"),
        ], catalog, &error);
        FMRequire(result != nil,
                  [NSString stringWithFormat:@"package matching failed: %@", error]);
        FMRequire([result[@"packageFontFileCount"] unsignedIntegerValue] == 4 &&
                      [result[@"matchedTargetCount"] unsignedIntegerValue] == 2 &&
                      [result[@"unmatchedSourceCount"] unsignedIntegerValue] == 1 &&
                      [result[@"conflictTargetCount"] unsignedIntegerValue] == 0 &&
                      [result[@"deduplicatedSourceCount"] unsignedIntegerValue] == 1,
                  @"simple filename matching counts are inconsistent");
        NSDictionary *pingFangMatch = result[@"matches"][0];
        NSDictionary *sfuiMatch = result[@"matches"][1];
        FMRequire([pingFangMatch[@"targetRelativePath"]
                       isEqual:@"LanguageSupport/PingFang.ttc"] &&
                      [sfuiMatch[@"targetRelativePath"] isEqual:@"Core/SFUI.ttf"] &&
                      [sfuiMatch[@"duplicateSourceRelativePaths"]
                          isEqual:@[ @"CoreUI/SFUI.ttf" ]] &&
                      [result[@"unmatched"][0][@"fileName"] isEqual:@"PingFangUI.ttc"],
                  @"filename matching selected the wrong package or Stock path");

        NSDictionary *conflict = FMMatchFontPackageFilesToCatalog(@[
            FMPackageEntry(
                @"Core/SFUI.ttf",
                @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
            FMPackageEntry(
                @"CoreUI/SFUI.ttf",
                @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        ], catalog, &error);
        FMRequire([conflict[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                      [conflict[@"conflictTargetCount"] unsignedIntegerValue] == 1,
                  @"different same-name package files were not blocked as a conflict");

        FMRequire(FMMatchFontPackageFilesToCatalog(@[
                      FMPackageEntry(
                          @"../SFUI.ttf",
                          @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
                  ], catalog, nil) == nil,
                  @"package matcher accepted a traversal path");

        printf("PASS: package-to-Stock filename matching and duplicate handling\n");
    }
    return 0;
}
