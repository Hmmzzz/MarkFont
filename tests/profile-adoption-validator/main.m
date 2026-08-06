#import <Foundation/Foundation.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMProfileAdoptionValidator.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary<NSString *, id> *FMCatalogFileForPath(
    NSDictionary<NSString *, id> *catalog,
    NSString *relativePath) {
    for (NSDictionary<NSString *, id> *file in catalog[@"files"]) {
        if ([file[@"relativePath"] isEqual:relativePath]) return file;
    }
    return nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        FMRequire(argc == 2, @"fixture path argument is required");
        NSString *fixtureRoot = [NSString stringWithUTF8String:argv[1]];
        NSString *profilesRoot = [fixtureRoot stringByAppendingPathComponent:@"profiles"];
        NSString *profileID = @"import-validator-test";
        NSString *profileDirectory = [profilesRoot stringByAppendingPathComponent:profileID];
        NSString *replacementsDirectory =
            [profileDirectory stringByAppendingPathComponent:@"replacements"];
        NSError *error = nil;
        FMRequire([NSFileManager.defaultManager
                      createDirectoryAtPath:replacementsDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error],
                  [NSString stringWithFormat:@"fixture directory failed: %@", error]);

        NSData *alpha = [@"replacement-alpha" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *beta = [@"replacement-beta" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *alphaPath =
            [replacementsDirectory stringByAppendingPathComponent:@"replacement-0001.ttf"];
        NSString *betaPath =
            [replacementsDirectory stringByAppendingPathComponent:@"replacement-0002.ttc"];
        FMRequire([alpha writeToFile:alphaPath options:0 error:&error] &&
                      [beta writeToFile:betaPath options:0 error:&error],
                  [NSString stringWithFormat:@"replacement fixture write failed: %@", error]);
        NSString *alphaHash = FMSHA256ForFileAtPath(alphaPath, &error);
        NSString *betaHash = FMSHA256ForFileAtPath(betaPath, &error);
        FMRequire(alphaHash != nil && betaHash != nil, @"fixture hashing failed");

        NSDictionary *manifest = @{
            @"schemaVersion" : @2,
            @"entries" : @[
                @{
                    @"relativePath" : @"Core/Alpha.ttf",
                    @"type" : @"regular",
                    @"mode" : @0644,
                    @"uid" : @0,
                    @"gid" : @0,
                    @"size" : @100,
                    @"sha256" : @"1111111111111111111111111111111111111111111111111111111111111111",
                },
                @{
                    @"relativePath" : @"Language/Beta.ttc",
                    @"type" : @"regular",
                    @"mode" : @0644,
                    @"uid" : @0,
                    @"gid" : @0,
                    @"size" : @200,
                    @"sha256" : @"2222222222222222222222222222222222222222222222222222222222222222",
                },
            ],
        };
        NSDictionary *catalog = FMCreateFontCatalogFromManifest(
            manifest, @"TEST-BUILD",
            @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &error);
        FMRequire(catalog != nil,
                  [NSString stringWithFormat:@"catalog fixture failed: %@", error]);
        NSDictionary *alphaCatalog = FMCatalogFileForPath(catalog, @"Core/Alpha.ttf");
        NSDictionary *betaCatalog = FMCatalogFileForPath(catalog, @"Language/Beta.ttc");
        FMRequire(alphaCatalog != nil && betaCatalog != nil, @"catalog paths are missing");

        NSDictionary *profile = @{
            @"schemaVersion" : @2,
            @"id" : profileID,
            @"name" : @"Validator Test",
            @"systemBuild" : @"TEST-BUILD",
            @"replacements" : @[
                @{
                    @"fontFileID" : alphaCatalog[@"id"],
                    @"relativePath" : @"Core/Alpha.ttf",
                    @"fileName" : @"replacement-0001.ttf",
                    @"sha256" : alphaHash,
                },
                @{
                    @"fontFileID" : betaCatalog[@"id"],
                    @"relativePath" : @"Language/Beta.ttc",
                    @"fileName" : @"replacement-0002.ttc",
                    @"sha256" : betaHash,
                },
            ],
        };
        NSString *profilePath = [profileDirectory stringByAppendingPathComponent:@"profile.json"];
        FMRequire(FMWriteJSONObjectAtomically(profile, profilePath, 0600, &error),
                  [NSString stringWithFormat:@"profile fixture write failed: %@", error]);

        NSString *profileHashBefore = FMSHA256ForFileAtPath(profilePath, &error);
        NSDictionary *preview = FMCreateProfileAdoptionPreviewAtRoot(
            profilesRoot, profileID, @"TEST-BUILD", catalog, &error);
        FMRequire(preview != nil &&
                      [preview[@"replacementCount"] unsignedIntegerValue] == 2 &&
                      [preview[@"replacementBytes"] unsignedLongLongValue] ==
                          alpha.length + beta.length &&
                      [preview[@"relativePaths"] isEqual:@[
                          @"Core/Alpha.ttf", @"Language/Beta.ttc"
                      ]] &&
                      [preview[@"profileJSONSHA256"] isEqual:profileHashBefore] &&
                      [preview[@"readOnly"] boolValue],
                  [NSString stringWithFormat:@"valid adoption preview failed: %@", error]);
        FMRequire([FMSHA256ForFileAtPath(profilePath, nil) isEqual:profileHashBefore] &&
                      [FMSHA256ForFileAtPath(alphaPath, nil) isEqual:alphaHash] &&
                      [FMSHA256ForFileAtPath(betaPath, nil) isEqual:betaHash],
                  @"adoption preview changed a source file");

        FMRequire(FMCreateProfileAdoptionPreviewAtRoot(
                      profilesRoot, profileID, @"OTHER-BUILD", catalog, nil) == nil,
                  @"adoption preview accepted a build mismatch");
        FMRequire(FMCreateProfileAdoptionPreviewAtRoot(
                      profilesRoot, @"../unsafe", @"TEST-BUILD", catalog, nil) == nil,
                  @"adoption preview accepted an unsafe Profile identifier");

        NSData *tampered = [@"tampered" dataUsingEncoding:NSUTF8StringEncoding];
        FMRequire([tampered writeToFile:alphaPath options:0 error:&error],
                  @"tamper fixture write failed");
        FMRequire(FMCreateProfileAdoptionPreviewAtRoot(
                      profilesRoot, profileID, @"TEST-BUILD", catalog, nil) == nil,
                  @"adoption preview accepted a changed replacement hash");
        FMRequire([alpha writeToFile:alphaPath options:0 error:&error],
                  @"replacement fixture restore failed");

        NSString *unexpectedPath =
            [replacementsDirectory stringByAppendingPathComponent:@"unexpected.ttf"];
        FMRequire([alpha writeToFile:unexpectedPath options:0 error:&error],
                  @"unexpected fixture write failed");
        FMRequire(FMCreateProfileAdoptionPreviewAtRoot(
                      profilesRoot, profileID, @"TEST-BUILD", catalog, nil) == nil,
                  @"adoption preview accepted an undeclared replacement file");
        FMRequire([NSFileManager.defaultManager removeItemAtPath:unexpectedPath error:&error],
                  @"unexpected fixture cleanup failed");

        FMRequire([NSFileManager.defaultManager removeItemAtPath:betaPath error:&error] &&
                      symlink(alphaPath.fileSystemRepresentation,
                              betaPath.fileSystemRepresentation) == 0,
                  @"symlink fixture creation failed");
        FMRequire(FMCreateProfileAdoptionPreviewAtRoot(
                      profilesRoot, profileID, @"TEST-BUILD", catalog, nil) == nil,
                  @"adoption preview accepted a symlink replacement");
        FMRequire([NSFileManager.defaultManager removeItemAtPath:betaPath error:&error] &&
                      [beta writeToFile:betaPath options:0 error:&error],
                  @"symlink fixture restore failed");

        NSMutableDictionary *mismatchedProfile = [profile mutableCopy];
        NSMutableArray *mismatchedReplacements =
            [profile[@"replacements"] mutableCopy];
        NSMutableDictionary *mismatchedReplacement =
            [mismatchedReplacements[0] mutableCopy];
        mismatchedReplacement[@"fontFileID"] = betaCatalog[@"id"];
        mismatchedReplacements[0] = mismatchedReplacement;
        mismatchedProfile[@"replacements"] = mismatchedReplacements;
        FMRequire(FMWriteJSONObjectAtomically(mismatchedProfile, profilePath, 0600, &error),
                  @"catalog mismatch fixture write failed");
        FMRequire(FMCreateProfileAdoptionPreviewAtRoot(
                      profilesRoot, profileID, @"TEST-BUILD", catalog, nil) == nil,
                  @"adoption preview accepted a catalog ID/path mismatch");
        FMRequire(FMWriteJSONObjectAtomically(profile, profilePath, 0600, &error),
                  @"profile fixture final restore failed");

        printf("PASS: imported Profile adoption validation is exact and read-only\n");
        return 0;
    }
}
