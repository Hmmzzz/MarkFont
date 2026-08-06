#import <Foundation/Foundation.h>

#import "FMDataModel.h"
#import "FMFontCatalog.h"

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

        printf("PASS: iOS 16/17 build-bound Stock filename catalog\n");
    }
    return 0;
}
