#import <Foundation/Foundation.h>

#import "FMDataModel.h"
#import "FMFontCatalog.h"
#import "FMSystemFontLayout.h"

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

static NSDictionary<NSString *, id> *FMManifestFixture(void) {
    return @{
        @"schemaVersion" : @2,
        @"entries" : @[
            FMRegularEntry(
                @"Core/HelveLTMM",
                @"0000000000000000000000000000000000000000000000000000000000000000",
                @100),
            FMRegularEntry(
                @"Core/SFUI.ttf",
                @"1111111111111111111111111111111111111111111111111111111111111111",
                @200),
            FMRegularEntry(
                @"LanguageSupport/PingFang.ttc",
                @"2222222222222222222222222222222222222222222222222222222222222222",
                @300),
        ],
    };
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        FMRequire(
            FMSystemFontLayoutForProductVersion(@"16.0") ==
                    FMSystemFontLayoutPrimaryFonts &&
                FMSystemFontLayoutForProductVersion(@"17.7.1") ==
                    FMSystemFontLayoutPrimaryFonts &&
                FMSystemFontLayoutForProductVersion(@"18.0") ==
                    FMSystemFontLayoutFontServicesCorePrivate &&
                FMSystemFontLayoutForProductVersion(@"26.5") ==
                    FMSystemFontLayoutFontServicesCorePrivate,
            @"supported iOS versions selected the wrong font layout");
        FMRequire(
            FMSystemFontLayoutForProductVersion(@"15.8") ==
                    FMSystemFontLayoutUnsupported &&
                FMSystemFontLayoutForProductVersion(@"27.0") ==
                    FMSystemFontLayoutUnsupported &&
                FMSystemFontLayoutForProductVersion(@"18beta") ==
                    FMSystemFontLayoutUnsupported &&
                FMSystemFontLayoutForProductVersion(@"18..1") ==
                    FMSystemFontLayoutUnsupported,
            @"unsupported or malformed iOS version did not fail closed");

        FMRequire(FMIsSupportedFontCatalogRelativePath(@"Core/SFUI.ttf") &&
                      FMIsSupportedFontCatalogRelativePath(@"Core/FONT.TTC") &&
                      FMIsSupportedFontCatalogRelativePath(@"Core/LastResort.otf") &&
                      !FMIsSupportedFontCatalogRelativePath(@"Core/HelveLTMM") &&
                      !FMIsSupportedFontCatalogRelativePath(@"Metadata/fonts.plist") &&
                      !FMIsSupportedFontCatalogRelativePath(@"../escape.ttf"),
                  @"supported Stock font path filter is inconsistent");

        NSDictionary *manifest = FMManifestFixture();
        FMRequire(FMValidateManifestDocument(manifest, &error),
                  [NSString stringWithFormat:@"valid manifest rejected: %@", error]);
        NSDictionary *catalog = FMCreateFontCatalogFromManifest(
            manifest, @"21D61",
            @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            &error);
        FMRequire(catalog != nil,
                  [NSString stringWithFormat:@"catalog generation failed: %@", error]);
        FMRequire(FMValidateFontCatalogDocument(catalog, &error),
                  [NSString stringWithFormat:@"generated catalog rejected: %@", error]);
        FMRequire([catalog[@"matchingMode"] isEqual:@"stockFileName"] &&
                      [catalog[@"sourceRegularFileCount"] unsignedIntegerValue] == 3 &&
                      [catalog[@"files"] count] == 2 &&
                      [catalog[@"excludedRegularPaths"]
                          isEqual:@[ @"Core/HelveLTMM" ]],
                  @"catalog did not preserve the simple filename-matching boundary");
        NSDictionary *firstFile = catalog[@"files"][0];
        FMRequire([firstFile[@"fileName"] isEqual:@"SFUI.ttf"] &&
                      [firstFile[@"relativePath"] isEqual:@"Core/SFUI.ttf"] &&
                      [firstFile[@"stockSHA256"] length] == 64,
                  @"catalog file identity is inconsistent");
        FMRequire([FMFontCatalogPreviewRelativePaths(catalog)
                      isEqual:@[ @"LanguageSupport/PingFang.ttc", @"Core/SFUI.ttf" ]],
                  @"legacy Stock preview did not select PingFang.ttc");

        NSDictionary *preview = @{
            @"schemaVersion" : @1,
            @"operation" : @"inspectFontCatalog",
            @"status" : @"reviewRequired",
            @"systemBuild" : @"21D61",
            @"matchingMode" : @"stockFileName",
            @"sourceManifestSHA256" : catalog[@"sourceManifestSHA256"],
            @"sourceRegularFileCount" : catalog[@"sourceRegularFileCount"],
            @"fontFileCount" : @([catalog[@"files"] count]),
            @"excludedRegularFileCount" : @([catalog[@"excludedRegularPaths"] count]),
            @"excludedRegularPaths" : catalog[@"excludedRegularPaths"],
            @"readOnly" : @YES,
            @"filesystemMutated" : @NO,
            @"mappingChanged" : @NO,
            @"stateChanged" : @NO,
            @"restartRequested" : @NO,
            @"catalog" : catalog,
        };
        FMRequire(FMValidateFontCatalogPreviewDocument(preview, @"21D61", &error),
                  [NSString stringWithFormat:@"valid preview rejected: %@", error]);
        FMRequire(!FMValidateFontCatalogPreviewDocument(preview, @"OTHER", nil),
                  @"font catalog preview accepted the wrong build");
        NSMutableDictionary *mutatingPreview = [preview mutableCopy];
        mutatingPreview[@"filesystemMutated"] = @YES;
        FMRequire(!FMValidateFontCatalogPreviewDocument(mutatingPreview, @"21D61", nil),
                  @"font catalog preview accepted a mutation report");

        NSMutableDictionary *nameMismatch = [catalog mutableCopy];
        NSMutableDictionary *badFile = [catalog[@"files"][0] mutableCopy];
        badFile[@"fileName"] = @"Other.ttf";
        nameMismatch[@"files"] = @[ badFile, catalog[@"files"][1] ];
        FMRequire(!FMValidateFontCatalogDocument(nameMismatch, nil),
                  @"catalog accepted a filename/path mismatch");

        NSMutableDictionary *badCount = [catalog mutableCopy];
        badCount[@"sourceRegularFileCount"] = @4;
        FMRequire(!FMValidateFontCatalogDocument(badCount, nil),
                  @"catalog accepted an inconsistent source file count");

        NSDictionary *duplicateNameManifest = @{
            @"schemaVersion" : @2,
            @"entries" : @[
                FMRegularEntry(
                    @"Core/A.ttf",
                    @"3333333333333333333333333333333333333333333333333333333333333333",
                    @100),
                FMRegularEntry(
                    @"CoreUI/A.ttf",
                    @"4444444444444444444444444444444444444444444444444444444444444444",
                    @100),
            ],
        };
        FMRequire(FMValidateManifestDocument(duplicateNameManifest, &error),
                  @"duplicate basename fixture should remain a valid tree manifest");
        FMRequire(FMCreateFontCatalogFromManifest(
                      duplicateNameManifest, @"21D61",
                      @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                      nil) == nil,
                  @"catalog accepted ambiguous Stock filenames");

        NSDictionary *ios16ShapeManifest = @{
            @"schemaVersion" : @2,
            @"entries" : @[
                FMRegularEntry(
                    @"Core/LastResort.otf",
                    @"5555555555555555555555555555555555555555555555555555555555555555",
                    @100),
                FMRegularEntry(
                    @"Core/SFUI.ttf",
                    @"6666666666666666666666666666666666666666666666666666666666666666",
                    @200),
                FMRegularEntry(
                    @"CoreUI/SFUISoft.ttc",
                    @"7777777777777777777777777777777777777777777777777777777777777777",
                    @300),
                FMRegularEntry(
                    @"LanguageSupport/PingFang.ttc",
                    @"8888888888888888888888888888888888888888888888888888888888888888",
                    @400),
            ],
        };
        NSDictionary *ios16ShapeCatalog = FMCreateFontCatalogFromManifest(
            ios16ShapeManifest, @"20G81",
            @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            &error);
        FMRequire(ios16ShapeCatalog != nil &&
                      [ios16ShapeCatalog[@"systemBuild"] isEqual:@"20G81"] &&
                      [ios16ShapeCatalog[@"files"] count] == 4 &&
                      [ios16ShapeCatalog[@"files"][2][@"relativePath"]
                          isEqual:@"CoreUI/SFUISoft.ttc"],
                  @"an iOS 16-shaped Stock tree did not produce a complete build-bound catalog");

        NSDictionary *ios18PrimaryManifest = @{
            @"schemaVersion" : @2,
            @"entries" : @[
                FMRegularEntry(
                    @"Core/SFUI.ttf",
                    @"9999999999999999999999999999999999999999999999999999999999999999",
                    @200),
            ],
        };
        NSDictionary *ios18FontServicesManifest = @{
            @"schemaVersion" : @2,
            @"entries" : @[
                FMRegularEntry(
                    @"PingFangUI.ttc",
                    @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    @400),
            ],
        };
        NSDictionary *ios18ShapeCatalog = FMCreateFontCatalogFromManifests(
            ios18PrimaryManifest, ios18FontServicesManifest, @"22A3354",
            @"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            @"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            &error);
        FMRequire(ios18ShapeCatalog != nil &&
                      [ios18ShapeCatalog[@"files"][1][@"relativePath"]
                          isEqual:@"FontServicesCorePrivate/PingFangUI.ttc"] &&
                      [ios18ShapeCatalog[@"catalogVersion"] integerValue] == 2 &&
                      [FMFontCatalogPreviewRelativePaths(ios18ShapeCatalog)
                          isEqual:@[ @"FontServicesCorePrivate/PingFangUI.ttc",
                                     @"Core/SFUI.ttf" ]],
                  @"the iOS 18-26 FontServices source did not select PingFangUI.ttc");
        NSDictionary *ambiguousChineseCatalog = FMCreateFontCatalogFromManifests(
            manifest, ios18FontServicesManifest, @"AMBIGUOUS-BUILD",
            @"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            @"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            &error);
        FMRequire(ambiguousChineseCatalog != nil &&
                      [FMFontCatalogPreviewRelativePaths(ambiguousChineseCatalog)
                          isEqual:@[ @"Core/SFUI.ttf" ]],
                  @"an ambiguous Chinese catalog was treated as a filename fallback");
        FMRequire(FMFontCatalogPreviewRelativePaths(@{}).count == 0,
                  @"Stock preview selector accepted an invalid catalog");

        printf("PASS: iOS 16-26 build-bound Stock filename catalog\n");
    }
    return 0;
}
