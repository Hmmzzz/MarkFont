#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMProfileAdoption.h"
#import "FMProfileEngine.h"
#import "FMProfileMirrorMatcher.h"
#import "FMProfileStagePlanner.h"
#import "FMTreeManifest.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static void FMWriteFixture(NSString *path, NSString *contents, mode_t mode) {
    NSData *data = [contents dataUsingEncoding:NSUTF8StringEncoding];
    FMRequire([data writeToFile:path atomically:NO], @"fixture write failed");
    FMRequire(chmod(path.fileSystemRepresentation, mode) == 0,
              @"fixture chmod failed");
}

static NSDictionary<NSString *, id> *FMCatalogFile(
    NSDictionary<NSString *, id> *catalog,
    NSString *relativePath) {
    for (NSDictionary *file in catalog[@"files"]) {
        if ([file[@"relativePath"] isEqual:relativePath]) return file;
    }
    return nil;
}

static NSDictionary<NSString *, id> *FMManifestEntry(NSString *relativePath,
                                                       NSString *path) {
    struct stat info = {0};
    FMRequire(lstat(path.fileSystemRepresentation, &info) == 0,
              @"fixture stat failed");
    NSString *hash = FMSHA256ForFileAtPath(path, nil);
    FMRequire(hash != nil, @"fixture hash failed");
    return @{
        @"relativePath" : relativePath,
        @"type" : @"regular",
        @"mode" : @(info.st_mode & 07777),
        @"uid" : @(info.st_uid),
        @"gid" : @(info.st_gid),
        @"size" : @(info.st_size),
        @"sha256" : hash,
    };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        FMRequire(argc == 2, @"fixture root argument is required");
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        NSString *stock = [root stringByAppendingPathComponent:@"stock"];
        NSString *mirror = [root stringByAppendingPathComponent:@"mirror"];
        NSString *sourceProfiles = [root stringByAppendingPathComponent:@"app-profiles"];
        NSString *destinationProfiles =
            [root stringByAppendingPathComponent:@"privileged-profiles"];
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        for (NSString *directory in @[ stock, mirror, sourceProfiles, destinationProfiles ]) {
            FMRequire([files createDirectoryAtPath:directory
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:&error],
                      error.localizedDescription ?: @"fixture directory failed");
            FMRequire(chmod(directory.fileSystemRepresentation, 0700) == 0,
                      @"fixture directory chmod failed");
            FMRequire(chown(directory.fileSystemRepresentation, getuid(), getgid()) == 0,
                      @"fixture directory owner failed");
        }
        for (NSString *rootDirectory in @[ stock, mirror ]) {
            NSString *core = [rootDirectory stringByAppendingPathComponent:@"Core"];
            FMRequire([files createDirectoryAtPath:core
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:&error],
                      @"Core fixture directory failed");
            FMWriteFixture([core stringByAppendingPathComponent:@"Alpha.ttf"],
                           @"stock-alpha", 0644);
            FMWriteFixture([core stringByAppendingPathComponent:@"Beta.ttc"],
                           @"stock-beta", 0644);
            FMWriteFixture([core stringByAppendingPathComponent:@"Gamma.otf"],
                           @"stock-gamma", 0644);
        }

        NSDictionary *manifest = @{
            @"schemaVersion" : @2,
            @"entries" : @[
                FMManifestEntry(@"Core/Alpha.ttf",
                                [stock stringByAppendingPathComponent:@"Core/Alpha.ttf"]),
                FMManifestEntry(@"Core/Beta.ttc",
                                [stock stringByAppendingPathComponent:@"Core/Beta.ttc"]),
                FMManifestEntry(@"Core/Gamma.otf",
                                [stock stringByAppendingPathComponent:@"Core/Gamma.otf"]),
            ],
        };
        NSDictionary *catalog = FMCreateFontCatalogFromManifest(
            manifest, @"TEST-BUILD",
            @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &error);
        FMRequire(catalog != nil,
                  error.localizedDescription ?: @"catalog fixture failed");
        NSDictionary *alphaCatalog = FMCatalogFile(catalog, @"Core/Alpha.ttf");
        NSDictionary *betaCatalog = FMCatalogFile(catalog, @"Core/Beta.ttc");
        FMRequire(alphaCatalog != nil && betaCatalog != nil,
                  @"catalog targets are missing");

        NSString *profileID = @"import-pipeline-test";
        NSString *sourceProfile =
            [sourceProfiles stringByAppendingPathComponent:profileID];
        NSString *sourceReplacements =
            [sourceProfile stringByAppendingPathComponent:@"replacements"];
        FMRequire([files createDirectoryAtPath:sourceReplacements
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&error],
                  @"source Profile fixture failed");
        NSString *alphaReplacement =
            [sourceReplacements stringByAppendingPathComponent:@"custom-alpha.ttf"];
        NSString *betaReplacement =
            [sourceReplacements stringByAppendingPathComponent:@"custom-beta.ttc"];
        FMWriteFixture(alphaReplacement, @"custom-alpha", 0600);
        FMWriteFixture(betaReplacement, @"custom-beta", 0600);
        NSDictionary *profile = @{
            @"schemaVersion" : @2,
            @"id" : profileID,
            @"name" : @"Pipeline Test",
            @"systemBuild" : @"TEST-BUILD",
            @"replacements" : @[
                @{
                    @"fontFileID" : alphaCatalog[@"id"],
                    @"relativePath" : @"Core/Alpha.ttf",
                    @"fileName" : @"custom-alpha.ttf",
                    @"sha256" : FMSHA256ForFileAtPath(alphaReplacement, nil),
                },
                @{
                    @"fontFileID" : betaCatalog[@"id"],
                    @"relativePath" : @"Core/Beta.ttc",
                    @"fileName" : @"custom-beta.ttc",
                    @"sha256" : FMSHA256ForFileAtPath(betaReplacement, nil),
                },
            ],
        };
        NSString *sourceProfileJSON =
            [sourceProfile stringByAppendingPathComponent:@"profile.json"];
        FMRequire(FMWriteJSONObjectAtomically(profile, sourceProfileJSON, 0600, &error),
                  @"source profile JSON failed");
        NSString *sourceProfileHash = FMSHA256ForFileAtPath(sourceProfileJSON, nil);
        NSString *sourceAlphaHash = FMSHA256ForFileAtPath(alphaReplacement, nil);
        NSString *sourceBetaHash = FMSHA256ForFileAtPath(betaReplacement, nil);

        NSDictionary *adoption = FMPublishProfileAdoptionAtRoots(
            sourceProfiles, destinationProfiles, profileID, @"TEST-BUILD", catalog,
            getuid(), getgid(), &error);
        FMRequire(adoption != nil && [adoption[@"status"] isEqual:@"adopted"] &&
                      [adoption[@"replacementCount"] unsignedIntegerValue] == 2 &&
                      [adoption[@"profilePublished"] boolValue] &&
                      ![adoption[@"mirrorChanged"] boolValue] &&
                      ![adoption[@"stateChanged"] boolValue],
                  error.localizedDescription ?: @"Profile adoption failed");
        NSString *finalProfile =
            [destinationProfiles stringByAppendingPathComponent:profileID];
        NSString *staging = [destinationProfiles stringByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.fontmanager-staging", profileID]];
        FMRequire([files fileExistsAtPath:finalProfile] &&
                      ![files fileExistsAtPath:staging],
                  @"Profile publication paths are incorrect");
        FMRequire([FMSHA256ForFileAtPath(sourceProfileJSON, nil)
                      isEqual:sourceProfileHash] &&
                      [FMSHA256ForFileAtPath(alphaReplacement, nil)
                          isEqual:sourceAlphaHash] &&
                      [FMSHA256ForFileAtPath(betaReplacement, nil)
                          isEqual:sourceBetaHash],
                  @"Profile adoption changed App-owned source files");

        struct stat finalDirectoryInfo = {0};
        struct stat finalFileInfo = {0};
        NSString *finalProfileJSON =
            [finalProfile stringByAppendingPathComponent:@"profile.json"];
        FMRequire(lstat(finalProfile.fileSystemRepresentation, &finalDirectoryInfo) == 0 &&
                      (finalDirectoryInfo.st_mode & 0777) == 0700 &&
                      lstat(finalProfileJSON.fileSystemRepresentation, &finalFileInfo) == 0 &&
                      (finalFileInfo.st_mode & 0777) == 0600,
                  @"Published Profile permissions are incorrect");
        NSString *publishedHash = FMSHA256ForFileAtPath(finalProfileJSON, nil);
        error = nil;
        NSDictionary *repeatedAdoption = FMPublishProfileAdoptionAtRoots(
            sourceProfiles, destinationProfiles, profileID, @"TEST-BUILD", catalog,
            getuid(), getgid(), &error);
        FMRequire(repeatedAdoption != nil &&
                      [repeatedAdoption[@"status"] isEqual:@"alreadyAdopted"] &&
                      ![repeatedAdoption[@"filesystemMutated"] boolValue] &&
                      [FMSHA256ForFileAtPath(finalProfileJSON, nil) isEqual:publishedHash],
                  @"A repeated adoption was not idempotent");

        NSString *statePath = [root stringByAppendingPathComponent:@"state.json"];
        NSDictionary *stockState = @{
            @"schemaVersion" : @2,
            @"systemBuild" : @"TEST-BUILD",
            @"confirmedProfileID" : NSNull.null,
            @"workingProfileID" : NSNull.null,
            @"restartRequired" : @NO,
            @"mirrorState" : @"clean",
            @"autoMount" : @NO,
        };
        FMRequire(FMWriteJSONObjectAtomically(stockState, statePath, 0600, &error),
                  @"Stock state fixture failed");
        NSString *stateHash = FMSHA256ForFileAtPath(statePath, nil);
        NSString *mirrorAlpha = [mirror stringByAppendingPathComponent:@"Core/Alpha.ttf"];
        NSString *mirrorBeta = [mirror stringByAppendingPathComponent:@"Core/Beta.ttc"];
        NSString *mirrorAlphaHash = FMSHA256ForFileAtPath(mirrorAlpha, nil);
        NSString *mirrorBetaHash = FMSHA256ForFileAtPath(mirrorBeta, nil);

        NSDictionary *stagePlan = FMCreateProfileStagePlanAtRoots(
            stock, mirror, destinationProfiles, profileID, statePath, @"TEST-BUILD",
            catalog, &error);
        FMRequire(stagePlan != nil &&
                      [stagePlan[@"writeCount"] unsignedIntegerValue] == 2 &&
                      [stagePlan[@"replacementCount"] unsignedIntegerValue] == 2 &&
                      [stagePlan[@"stockRestoreCount"] unsignedIntegerValue] == 0 &&
                      [stagePlan[@"restartWouldBeRequired"] boolValue] &&
                      [stagePlan[@"readOnly"] boolValue] &&
                      ![stagePlan[@"filesystemMutated"] boolValue],
                  error.localizedDescription ?: @"first Profile stage plan failed");
        FMRequire([FMSHA256ForFileAtPath(statePath, nil) isEqual:stateHash] &&
                      [FMSHA256ForFileAtPath(mirrorAlpha, nil) isEqual:mirrorAlphaHash] &&
                      [FMSHA256ForFileAtPath(mirrorBeta, nil) isEqual:mirrorBetaHash],
                  @"Profile stage plan changed state or mirror files");

        NSDictionary *stockTree = FMCreateTreeManifestAtPath(stock, &error);
        NSDictionary *stockMirrorTree = FMCreateTreeManifestAtPath(mirror, &error);
        FMRequire(stockTree != nil && stockMirrorTree != nil &&
                      FMManifestsMatchWorkingProfile(
                          stockTree, stockMirrorTree, destinationProfiles, NSNull.null,
                          @"TEST-BUILD", catalog, &error),
                  error.localizedDescription ?: @"Stock working mirror match failed");

        NSDictionary *publishedDocument = FMReadJSONObjectAtPath(finalProfileJSON, &error);
        FMRequire([publishedDocument isKindOfClass:NSDictionary.class] &&
                      FMStageProfileAtRoots(
                          stock, mirror, publishedDocument, finalProfile,
                          stagePlan[@"stockRestoreRelativePaths"], statePath,
                          FMProfileEngineNoFaultInjection, &error),
                  error.localizedDescription ?: @"adopted Profile stage failed");
        NSDictionary *customState = FMReadJSONObjectAtPath(statePath, &error);
        FMRequire([customState[@"workingProfileID"] isEqual:profileID] &&
                      [customState[@"mirrorState"] isEqual:@"clean"] &&
                      [customState[@"restartRequired"] boolValue],
                  @"adopted Profile stage wrote incorrect state");

        NSDictionary *customMirrorTree = FMCreateTreeManifestAtPath(mirror, &error);
        FMRequire(customMirrorTree != nil &&
                      FMManifestsMatchWorkingProfile(
                          stockTree, customMirrorTree, destinationProfiles, profileID,
                          @"TEST-BUILD", catalog, &error) &&
                      !FMManifestsMatchWorkingProfile(
                          stockTree, customMirrorTree, destinationProfiles, NSNull.null,
                          @"TEST-BUILD", catalog, nil),
                  error.localizedDescription ?: @"custom working mirror match failed");

        NSDictionary *samePlan = FMCreateProfileStagePlanAtRoots(
            stock, mirror, destinationProfiles, profileID, statePath, @"TEST-BUILD",
            catalog, &error);
        FMRequire(samePlan != nil &&
                      [samePlan[@"writeCount"] unsignedIntegerValue] == 0 &&
                      [samePlan[@"restartWouldBeRequired"] boolValue],
                  @"same-Profile plan should require no writes");
        NSDictionary *stockPlan = FMCreateProfileStagePlanAtRoots(
            stock, mirror, destinationProfiles, nil, statePath, @"TEST-BUILD", catalog,
            &error);
        FMRequire(stockPlan != nil &&
                      [stockPlan[@"writeCount"] unsignedIntegerValue] == 2 &&
                      [stockPlan[@"replacementCount"] unsignedIntegerValue] == 0 &&
                      [stockPlan[@"stockRestoreCount"] unsignedIntegerValue] == 2 &&
                      ![stockPlan[@"restartWouldBeRequired"] boolValue],
                  error.localizedDescription ?: @"Stock restore plan failed");

        FMWriteFixture(mirrorAlpha, @"unexpected-mirror-change", 0644);
        NSString *unexpectedMirrorHash = FMSHA256ForFileAtPath(mirrorAlpha, nil);
        error = nil;
        NSDictionary *repairingStockPlan = FMCreateProfileStagePlanAtRoots(
            stock, mirror, destinationProfiles, nil, statePath, @"TEST-BUILD",
            catalog, &error);
        FMRequire(repairingStockPlan != nil &&
                      [repairingStockPlan[@"stockRestoreCount"] unsignedIntegerValue] == 2 &&
                      [FMSHA256ForFileAtPath(mirrorAlpha, nil)
                          isEqual:unexpectedMirrorHash],
                  @"stage planner did not allow deterministic Stock recovery");

        NSString *fallbackStatePath =
            [root stringByAppendingPathComponent:@"fallback-state.json"];
        NSDictionary *fallbackState = @{
            @"schemaVersion" : @2,
            @"systemBuild" : @"TEST-BUILD",
            @"confirmedProfileID" : NSNull.null,
            @"workingProfileID" : @"import-missing-profile",
            @"restartRequired" : @NO,
            @"mirrorState" : @"clean",
            @"autoMount" : @NO,
        };
        FMRequire(FMWriteJSONObjectAtomically(
                      fallbackState, fallbackStatePath, 0600, &error),
                  @"fallback state fixture failed");
        NSDictionary *fallbackPlan = FMCreateProfileStagePlanAtRoots(
            stock, mirror, destinationProfiles, nil, fallbackStatePath,
            @"TEST-BUILD", catalog, &error);
        FMRequire(fallbackPlan != nil &&
                      [fallbackPlan[@"restoreMode"] isEqual:@"fullStockFallback"] &&
                      [fallbackPlan[@"stockRestoreCount"] unsignedIntegerValue] == 3,
                  @"missing current Profile did not select full Stock fallback");

        NSString *publishedReplacements =
            [finalProfile stringByAppendingPathComponent:@"replacements"];
        NSString *publishedAlpha = [publishedReplacements
            stringByAppendingPathComponent:@"custom-alpha.ttf"];
        FMWriteFixture(publishedAlpha, @"tampered-published-copy", 0600);
        NSString *tamperedPublishedHash = FMSHA256ForFileAtPath(publishedAlpha, nil);
        error = nil;
        FMRequire(FMPublishProfileAdoptionAtRoots(
                      sourceProfiles, destinationProfiles, profileID, @"TEST-BUILD",
                      catalog, getuid(), getgid(), &error) == nil &&
                      [FMSHA256ForFileAtPath(publishedAlpha, nil)
                          isEqual:tamperedPublishedHash] &&
                      ![files fileExistsAtPath:staging],
                  @"adoption overwrote or cleaned an existing mismatched Profile");

        printf("PASS: privileged Profile adoption and stage planning are atomic/read-only\n");
        return 0;
    }
}
