#import <Foundation/Foundation.h>
#import <sys/stat.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMProfileEngine.h"
#import "FMTreeManifest.h"

static void FMTestRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static void FMTestRequireSuccess(BOOL success, NSError *error, NSString *context) {
    FMTestRequire(success,
                  [NSString stringWithFormat:@"%@: %@", context,
                                             error.localizedDescription ?: @"unknown error"]);
}

static void FMCreateDirectory(NSString *path) {
    NSError *error = nil;
    BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:path
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                  error:&error];
    FMTestRequireSuccess(success, error, [NSString stringWithFormat:@"create %@", path]);
}

static void FMWriteText(NSString *path, NSString *text) {
    FMCreateDirectory(path.stringByDeletingLastPathComponent);
    NSError *error = nil;
    BOOL success = [text writeToFile:path
                          atomically:NO
                            encoding:NSUTF8StringEncoding
                               error:&error];
    FMTestRequireSuccess(success, error, [NSString stringWithFormat:@"write %@", path]);
}

static NSString *FMReadText(NSString *path) {
    NSError *error = nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:&error];
    FMTestRequire(text != nil,
                  [NSString stringWithFormat:@"read %@: %@", path,
                                             error.localizedDescription]);
    return text;
}

static NSString *FMHash(NSString *path) {
    NSError *error = nil;
    NSString *hash = FMSHA256ForFileAtPath(path, &error);
    FMTestRequire(hash != nil,
                  [NSString stringWithFormat:@"hash %@: %@", path,
                                             error.localizedDescription]);
    return hash;
}

static NSDictionary<NSString *, id> *FMProfile(NSString *profileID,
                                                NSString *profileDirectory,
                                                NSArray<NSDictionary<NSString *, NSString *> *> *specs) {
    NSString *replacementsDirectory =
        [profileDirectory stringByAppendingPathComponent:@"replacements"];
    FMCreateDirectory(replacementsDirectory);
    NSMutableArray<NSDictionary<NSString *, id> *> *replacements = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *spec in specs) {
        NSString *filePath =
            [replacementsDirectory stringByAppendingPathComponent:spec[@"fileName"]];
        [replacements addObject:@{
            @"fontFileID" : spec[@"fontFileID"],
            @"relativePath" : spec[@"relativePath"],
            @"fileName" : spec[@"fileName"],
            @"sha256" : FMHash(filePath),
        }];
    }
    return @{
        @"schemaVersion" : @2,
        @"id" : profileID,
        @"name" : [NSString stringWithFormat:@"Profile %@", profileID],
        @"systemBuild" : @"21D61",
        @"replacements" : replacements,
    };
}

static NSDictionary<NSString *, id> *FMReadDictionary(NSString *path) {
    NSError *error = nil;
    id object = FMReadJSONObjectAtPath(path, &error);
    FMTestRequire([object isKindOfClass:NSDictionary.class],
                  [NSString stringWithFormat:@"read dictionary %@: %@", path,
                                             error.localizedDescription]);
    return object;
}

static NSDictionary<NSString *, id> *FMManifestEntry(NSDictionary<NSString *, id> *manifest,
                                                       NSString *relativePath) {
    for (NSDictionary<NSString *, id> *entry in manifest[@"entries"]) {
        if ([entry[@"relativePath"] isEqual:relativePath]) {
            return entry;
        }
    }
    return nil;
}

static void FMAssertNoTemporaryFiles(NSString *root) {
    NSDirectoryEnumerator<NSString *> *enumerator =
        [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString *relativePath in enumerator) {
        FMTestRequire(![relativePath.lastPathComponent hasSuffix:@".tmp"],
                      [NSString stringWithFormat:@"temporary file leaked: %@", relativePath]);
    }
}

static void FMTestSchemas(void) {
    NSDictionary *identity = @{
        @"schemaVersion" : @2,
        @"productType" : @"iPhone16,1",
        @"productVersion" : @"17.3.1",
        @"productBuildVersion" : @"21D61",
        @"sourceLogicalPath" : @"/System/Library/Fonts",
        @"providerPackage" : @"com.nan.bindfs",
        @"providerVersion" : @"0.5.5-1",
        @"createdAt" : @"2026-08-02T12:00:00Z",
    };
    NSError *error = nil;
    FMTestRequire(FMValidateBaselineIdentity(identity, &error),
                  error.localizedDescription ?: @"valid baseline rejected");
    FMTestRequire(FMBaselineIdentityUsesLegacyProvider(identity),
                  @"legacy Provider baseline was not recognized");

    NSDictionary *migrated =
        FMMigrateBaselineIdentityToBuiltInBackend(identity, &error);
    FMTestRequire(migrated != nil,
                  error.localizedDescription ?: @"baseline migration failed");
    FMTestRequire(FMValidateBaselineIdentity(migrated, &error),
                  error.localizedDescription ?: @"migrated baseline rejected");
    FMTestRequire(!FMBaselineIdentityUsesLegacyProvider(migrated),
                  @"migrated baseline still uses the legacy Provider");
    FMTestRequire([migrated[@"schemaVersion"] isEqual:@3] &&
                      [migrated[@"mountBackend"]
                          isEqual:@"markfont-bindfs"] &&
                      [migrated[@"mountBackendVersion"] isEqual:@"1"] &&
                      [migrated[@"mirrorLogicalPath"]
                          isEqual:@"/bindfs/System/Library/Fonts"],
                  @"baseline migration changed the backend contract");
    FMTestRequire([migrated[@"createdAt"] isEqual:identity[@"createdAt"]] &&
                      [migrated[@"productBuildVersion"]
                          isEqual:identity[@"productBuildVersion"]],
                  @"baseline migration did not preserve device identity");

    NSDictionary *builtInIdentity = @{
        @"schemaVersion" : @3,
        @"productType" : @"iPhone16,1",
        @"productVersion" : @"17.3.1",
        @"productBuildVersion" : @"21D61",
        @"sourceLogicalPath" : @"/System/Library/Fonts",
        @"mirrorLogicalPath" : @"/bindfs/System/Library/Fonts",
        @"mountBackend" : @"markfont-bindfs",
        @"mountBackendVersion" : @"1",
        @"createdAt" : @"2026-08-02T12:00:00Z",
    };
    FMTestRequire(FMValidateBaselineIdentity(builtInIdentity, &error),
                  error.localizedDescription ?:
                      @"built-in backend baseline rejected");
    NSDictionary *unchanged =
        FMMigrateBaselineIdentityToBuiltInBackend(builtInIdentity, &error);
    FMTestRequire([unchanged isEqual:builtInIdentity],
                  @"current baseline was unexpectedly rewritten");

    NSMutableDictionary *wrongSource = [identity mutableCopy];
    wrongSource[@"sourceLogicalPath"] = @"/tmp/Fonts";
    FMTestRequire(!FMValidateBaselineIdentity(wrongSource, nil),
                  @"unexpected baseline source accepted");

    NSDictionary *state = FMCreateInitialState(@"21D61");
    FMTestRequire(FMValidateStateDocument(state, &error),
                  error.localizedDescription ?: @"valid state rejected");
    FMTestRequire([state[@"autoMount"] isEqual:@YES],
                  @"new state does not enable automatic mounting by default");
    FMTestRequire([state[@"autoRespring"] isEqual:@NO],
                  @"new state enables automatic Respring without opt-in");
    FMTestRequire(state[@"refreshReason"] == NSNull.null,
                  @"new state has a pending refresh reason");
    NSMutableDictionary *legacyState = [state mutableCopy];
    [legacyState removeObjectForKey:@"autoRespring"];
    FMTestRequire(FMValidateStateDocument(legacyState, &error),
                  error.localizedDescription ?:
                      @"state without optional autoRespring was rejected");
    NSMutableDictionary *numericAutoRespring = [state mutableCopy];
    numericAutoRespring[@"autoRespring"] = @0;
    FMTestRequire(!FMValidateStateDocument(numericAutoRespring, nil),
                  @"numeric non-boolean accepted as autoRespring");
    NSMutableDictionary *automaticState = [state mutableCopy];
    automaticState[@"autoMount"] = @NO;
    FMTestRequire(FMValidateStateDocument(automaticState, &error),
                  error.localizedDescription ?: @"autoMount=false rejected");
    NSMutableDictionary *numericAutoMount = [state mutableCopy];
    numericAutoMount[@"autoMount"] = @0;
    FMTestRequire(!FMValidateStateDocument(numericAutoMount, nil),
                  @"numeric non-boolean accepted as autoMount");
    NSMutableDictionary *numericBoolean = [state mutableCopy];
    numericBoolean[@"restartRequired"] = @0;
    FMTestRequire(!FMValidateStateDocument(numericBoolean, nil),
                  @"numeric non-boolean accepted as a state boolean");
    NSMutableDictionary *reasonWithoutRestart = [state mutableCopy];
    reasonWithoutRestart[@"refreshReason"] = @"profileChange";
    FMTestRequire(!FMValidateStateDocument(reasonWithoutRestart, nil),
                  @"refresh reason without restartRequired was accepted");
    NSMutableDictionary *profileRefresh = [state mutableCopy];
    profileRefresh[@"restartRequired"] = @YES;
    profileRefresh[@"refreshReason"] = @"profileChange";
    FMTestRequire(FMValidateStateDocument(profileRefresh, &error),
                  error.localizedDescription ?: @"profile refresh state rejected");
    profileRefresh[@"refreshReason"] = @"unknownReason";
    FMTestRequire(!FMValidateStateDocument(profileRefresh, nil),
                  @"unknown refresh reason was accepted");
    NSMutableDictionary *updatingWithoutPaths = [state mutableCopy];
    updatingWithoutPaths[@"mirrorState"] = @"updating";
    FMTestRequire(!FMValidateStateDocument(updatingWithoutPaths, nil),
                  @"updating state without repair paths was accepted");
    NSMutableDictionary *updatingState = [updatingWithoutPaths mutableCopy];
    updatingState[@"transitionManagedPaths"] = @[ @"Core/A.ttf", @"Core/B.ttf" ];
    FMTestRequire(FMValidateStateDocument(updatingState, &error),
                  error.localizedDescription ?: @"valid updating state rejected");
    NSMutableDictionary *unsortedUpdatingState = [updatingState mutableCopy];
    unsortedUpdatingState[@"transitionManagedPaths"] =
        @[ @"Core/B.ttf", @"Core/A.ttf" ];
    FMTestRequire(!FMValidateStateDocument(unsortedUpdatingState, nil),
                  @"unsorted transition paths were accepted");
    NSMutableDictionary *cleanWithPaths = [state mutableCopy];
    cleanWithPaths[@"transitionManagedPaths"] = @[ @"Core/A.ttf" ];
    FMTestRequire(!FMValidateStateDocument(cleanWithPaths, nil),
                  @"clean state retained transition repair paths");

    NSString *validHash = [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
    NSDictionary *profile = @{
        @"schemaVersion" : @2,
        @"id" : @"profile-a",
        @"name" : @"A",
        @"systemBuild" : @"21D61",
        @"replacements" : @[
            @{
                @"fontFileID" : @"font-a",
                @"relativePath" : @"Core/A.ttf",
                @"fileName" : @"A.ttf",
                @"sha256" : validHash,
            }
        ],
    };
    FMTestRequire(FMValidateProfileDocument(profile, &error),
                  error.localizedDescription ?: @"valid profile rejected");
    NSMutableDictionary *traversalProfile = [profile mutableCopy];
    NSMutableDictionary *traversalEntry = [profile[@"replacements"][0] mutableCopy];
    traversalEntry[@"relativePath"] = @"../A.ttf";
    traversalProfile[@"replacements"] = @[ traversalEntry ];
    FMTestRequire(!FMValidateProfileDocument(traversalProfile, nil),
                  @"relative path traversal accepted");

    NSMutableDictionary *duplicateProfile = [profile mutableCopy];
    NSMutableDictionary *duplicateEntry = [profile[@"replacements"][0] mutableCopy];
    duplicateEntry[@"fontFileID"] = @"font-b";
    duplicateEntry[@"fileName"] = @"B.ttf";
    duplicateProfile[@"replacements"] = @[ profile[@"replacements"][0], duplicateEntry ];
    FMTestRequire(!FMValidateProfileDocument(duplicateProfile, nil),
                  @"duplicate replacement path accepted");

    FMTestRequire(FMValidateRelativePath(@"Core/A.ttf", &error),
                  error.localizedDescription ?: @"valid relative path rejected");
    FMTestRequire(!FMValidateRelativePath(@"Core//A.ttf", nil),
                  @"non-normalized relative path accepted");
    printf("PASS: schema v2 state and schema v3 baseline contracts\n");
}

static void FMTestStoreAndManifest(NSString *testRoot) {
    NSString *storeRoot = [testRoot stringByAppendingPathComponent:@"store"];
    FMCreateDirectory(storeRoot);
    NSString *jsonPath = [storeRoot stringByAppendingPathComponent:@"state.json"];
    NSError *error = nil;
    FMTestRequireSuccess(FMWriteJSONObjectAtomically(@{ @"value" : @1 }, jsonPath, 0600, &error),
                         error, @"initial atomic JSON write");
    error = nil;
    FMTestRequireSuccess(FMWriteJSONObjectAtomically(@{ @"value" : @2 }, jsonPath, 0600, &error),
                         error, @"replacement atomic JSON write");
    FMTestRequire([FMReadDictionary(jsonPath)[@"value"] isEqual:@2],
                  @"atomic JSON replacement returned stale data");
    struct stat jsonInfo = {0};
    FMTestRequire(lstat(jsonPath.fileSystemRepresentation, &jsonInfo) == 0 &&
                      (jsonInfo.st_mode & 0777) == 0600,
                  @"atomic JSON mode is not 0600");

    NSString *exclusivePath =
        [storeRoot stringByAppendingPathComponent:@"exclusive.json"];
    NSDictionary *exclusiveDocument = @{ @"alpha" : @1, @"beta" : @2 };
    error = nil;
    FMTestRequireSuccess(FMWriteJSONObjectAtomicallyIfAbsent(
                             exclusiveDocument, exclusivePath, 0600, &error),
                         error, @"exclusive atomic JSON write");
    NSString *documentHash = FMSHA256ForJSONObject(exclusiveDocument, &error);
    FMTestRequire(documentHash != nil &&
                      [documentHash isEqual:FMHash(exclusivePath)],
                  @"canonical JSON digest differs from written JSON");
    error = nil;
    FMTestRequire(!FMWriteJSONObjectAtomicallyIfAbsent(
                       @{ @"alpha" : @3 }, exclusivePath, 0600, &error),
                  @"exclusive JSON writer overwrote an existing target");
    FMTestRequire([FMReadDictionary(exclusivePath) isEqual:exclusiveDocument],
                  @"failed exclusive write changed the original JSON");

    NSString *treeRoot = [testRoot stringByAppendingPathComponent:@"manifest-tree"];
    NSString *fontPath = [treeRoot stringByAppendingPathComponent:@"Core/A.ttf"];
    FMWriteText(fontPath, @"stock-a");
    NSString *linkPath = [treeRoot stringByAppendingPathComponent:@"Alias.ttf"];
    FMTestRequire(symlink("Core/A.ttf", linkPath.fileSystemRepresentation) == 0,
                  @"create manifest symlink");

    NSDictionary *first = FMCreateTreeManifestAtPath(treeRoot, &error);
    FMTestRequire(first != nil,
                  [NSString stringWithFormat:@"create manifest: %@", error.localizedDescription]);
    NSDictionary *second = FMCreateTreeManifestAtPath(treeRoot, &error);
    FMTestRequire([first isEqual:second], @"manifest output is not deterministic");
    FMTestRequire(FMValidateManifestDocument(first, &error),
                  error.localizedDescription ?: @"generated manifest rejected");

    NSDictionary *fontEntry = FMManifestEntry(first, @"Core/A.ttf");
    NSDictionary *directoryEntry = FMManifestEntry(first, @"Core");
    NSDictionary *linkEntry = FMManifestEntry(first, @"Alias.ttf");
    FMTestRequire([fontEntry[@"type"] isEqual:@"regular"] &&
                      [fontEntry[@"sha256"] isEqual:FMHash(fontPath)],
                  @"regular manifest entry is incorrect");
    FMTestRequire([directoryEntry[@"type"] isEqual:@"directory"],
                  @"directory manifest entry is incorrect");
    FMTestRequire([linkEntry[@"type"] isEqual:@"symlink"] &&
                      [linkEntry[@"linkTarget"] isEqual:@"Core/A.ttf"],
                  @"symlink manifest entry is incorrect");

    NSString *copySource =
        [treeRoot stringByAppendingPathComponent:@"Core/Source.ttf"];
    FMWriteText(copySource, @"replacement-with-a-different-size");
    struct stat beforeCopy = {0};
    struct stat afterCopy = {0};
    FMTestRequire(lstat(fontPath.fileSystemRepresentation, &beforeCopy) == 0,
                  @"inspect atomic copy target before copy");
    error = nil;
    FMTestRequireSuccess(FMCopyRegularFileAtomically(
                             copySource, fontPath, fontPath,
                             FMHash(copySource), &error),
                         error, @"atomically publish mirror file");
    FMTestRequire(lstat(fontPath.fileSystemRepresentation, &afterCopy) == 0 &&
                      beforeCopy.st_dev == afterCopy.st_dev &&
                      beforeCopy.st_ino != afterCopy.st_ino &&
                      [FMHash(fontPath) isEqual:FMHash(copySource)],
                  @"atomic copy did not replace the target inode and bytes");
    FMWriteText(copySource, @"short");
    beforeCopy = afterCopy;
    error = nil;
    FMTestRequireSuccess(FMCopyRegularFileAtomically(
                             copySource, fontPath, fontPath,
                             FMHash(copySource), &error),
                         error, @"atomically publish shorter mirror file");
    FMTestRequire(lstat(fontPath.fileSystemRepresentation, &afterCopy) == 0 &&
                      beforeCopy.st_dev == afterCopy.st_dev &&
                      beforeCopy.st_ino != afterCopy.st_ino &&
                      [FMReadText(fontPath) isEqual:@"short"],
                  @"short atomic copy left stale trailing bytes or reused the inode");
    FMAssertNoTemporaryFiles(testRoot);
    printf("PASS: atomic/exclusive JSON, canonical digest, and tree manifest\n");
}

static void FMCopyStockFixture(NSString *stockRoot,
                               NSString *mirrorRoot,
                               NSArray<NSString *> *relativePaths) {
    for (NSString *relativePath in relativePaths) {
        NSString *stockPath = [stockRoot stringByAppendingPathComponent:relativePath];
        NSString *mirrorPath = [mirrorRoot stringByAppendingPathComponent:relativePath];
        FMWriteText(mirrorPath, FMReadText(stockPath));
        chmod(mirrorPath.fileSystemRepresentation, 0644);
    }
}

static void FMAssertState(NSString *statePath,
                          NSString *mirrorState,
                          id workingProfileID,
                          BOOL restartRequired) {
    NSDictionary *state = FMReadDictionary(statePath);
    NSError *validationError = nil;
    FMTestRequire(FMValidateStateDocument(state, &validationError),
                  [NSString stringWithFormat:@"engine wrote invalid state: %@ / %@",
                                             validationError.localizedDescription, state]);
    FMTestRequire([state[@"mirrorState"] isEqual:mirrorState],
                  @"unexpected mirrorState");
    FMTestRequire([state[@"workingProfileID"] isEqual:workingProfileID],
                  @"unexpected workingProfileID");
    FMTestRequire([state[@"restartRequired"] boolValue] == restartRequired,
                  @"unexpected restartRequired");
    FMTestRequire(restartRequired
                      ? [state[@"refreshReason"] isEqual:@"profileChange"]
                      : state[@"refreshReason"] == NSNull.null,
                  @"unexpected refreshReason");
    if ([mirrorState isEqual:@"clean"]) {
        FMTestRequire(state[@"transitionManagedPaths"] == nil,
                      @"clean state retained transition paths");
    } else {
        FMTestRequire([state[@"transitionManagedPaths"] isKindOfClass:NSArray.class],
                      @"non-clean state lost transition paths");
    }
}

static void FMAssertConfirmedProfile(NSString *statePath, id confirmedProfileID) {
    NSDictionary *state = FMReadDictionary(statePath);
    FMTestRequire([state[@"confirmedProfileID"] isEqual:confirmedProfileID],
                  @"unexpected confirmedProfileID");
}

static void FMTestProfileEngine(NSString *testRoot) {
    NSString *engineRoot = [testRoot stringByAppendingPathComponent:@"engine"];
    NSString *stockRoot = [engineRoot stringByAppendingPathComponent:@"stock"];
    NSString *mirrorRoot = [engineRoot stringByAppendingPathComponent:@"mirror"];
    NSString *profilesRoot = [engineRoot stringByAppendingPathComponent:@"profiles"];
    NSString *statePath = [engineRoot stringByAppendingPathComponent:@"state.json"];
    NSArray<NSString *> *allPaths = @[ @"Core/A.ttf", @"Core/B.ttf", @"Core/C.ttf" ];

    FMWriteText([stockRoot stringByAppendingPathComponent:@"Core/A.ttf"], @"stock-a");
    FMWriteText([stockRoot stringByAppendingPathComponent:@"Core/B.ttf"], @"stock-b");
    FMWriteText([stockRoot stringByAppendingPathComponent:@"Core/C.ttf"], @"stock-c");
    chmod([stockRoot stringByAppendingPathComponent:@"Core/A.ttf"].fileSystemRepresentation,
          0640);
    FMCopyStockFixture(stockRoot, mirrorRoot, allPaths);
    FMCreateDirectory(profilesRoot);

    NSString *profileADirectory = [profilesRoot stringByAppendingPathComponent:@"profile-a"];
    FMWriteText([profileADirectory stringByAppendingPathComponent:@"replacements/A.custom"],
                @"custom-a1");
    FMWriteText([profileADirectory stringByAppendingPathComponent:@"replacements/B.custom"],
                @"custom-b1");
    NSDictionary *profileA = FMProfile(@"profile-a", profileADirectory, @[
        @{
            @"fontFileID" : @"font-a",
            @"relativePath" : @"Core/A.ttf",
            @"fileName" : @"A.custom",
        },
        @{
            @"fontFileID" : @"font-b-a",
            @"relativePath" : @"Core/B.ttf",
            @"fileName" : @"B.custom",
        },
    ]);

    NSString *profileBDirectory = [profilesRoot stringByAppendingPathComponent:@"profile-b"];
    FMWriteText([profileBDirectory stringByAppendingPathComponent:@"replacements/B.custom"],
                @"custom-b2");
    FMWriteText([profileBDirectory stringByAppendingPathComponent:@"replacements/C.custom"],
                @"custom-c2");
    NSDictionary *profileB = FMProfile(@"profile-b", profileBDirectory, @[
        @{
            @"fontFileID" : @"font-b-b",
            @"relativePath" : @"Core/B.ttf",
            @"fileName" : @"B.custom",
        },
        @{
            @"fontFileID" : @"font-c",
            @"relativePath" : @"Core/C.ttf",
            @"fileName" : @"C.custom",
        },
    ]);

    NSError *error = nil;
    FMTestRequireSuccess(FMWriteJSONObjectAtomically(FMCreateInitialState(@"21D61"), statePath,
                                                     0600, &error),
                         error, @"write initial engine state");
    error = nil;
    FMTestRequireSuccess(FMStageProfileAtRoots(stockRoot, mirrorRoot, profileA,
                                               profileADirectory,
                                               @[], statePath,
                                               FMProfileEngineNoFaultInjection, &error),
                         error, @"stage Profile A");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/A.ttf"])
                      isEqual:@"custom-a1"],
                  @"Profile A did not replace A");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/B.ttf"])
                      isEqual:@"custom-b1"],
                  @"Profile A did not replace B");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/C.ttf"])
                      isEqual:@"stock-c"],
                  @"Profile A changed an unmanaged path");
    struct stat stagedInfo = {0};
    lstat([mirrorRoot stringByAppendingPathComponent:@"Core/A.ttf"].fileSystemRepresentation,
          &stagedInfo);
    FMTestRequire((stagedInfo.st_mode & 0777) == 0640,
                  @"replacement did not inherit Stock mode");
    FMAssertState(statePath, @"clean", @"profile-a", YES);
    FMAssertConfirmedProfile(statePath, NSNull.null);

    error = nil;
    FMTestRequireSuccess(FMConfirmWorkingProfileAtStatePath(statePath, &error), error,
                         @"confirm Profile A after simulated restart");
    FMAssertState(statePath, @"clean", @"profile-a", NO);
    FMAssertConfirmedProfile(statePath, @"profile-a");

    error = nil;
    FMTestRequireSuccess(FMStageProfileAtRoots(stockRoot, mirrorRoot, profileB,
                                               profileBDirectory,
                                               @[ @"Core/A.ttf", @"Core/B.ttf" ], statePath,
                                               FMProfileEngineNoFaultInjection, &error),
                         error, @"stage Profile B");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/A.ttf"])
                      isEqual:@"stock-a"],
                  @"A was not restored from Stock during A to B");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/B.ttf"])
                      isEqual:@"custom-b2"],
                  @"Profile B did not replace B");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/C.ttf"])
                      isEqual:@"custom-c2"],
                  @"Profile B did not replace C");
    FMAssertState(statePath, @"clean", @"profile-b", YES);
    FMAssertConfirmedProfile(statePath, @"profile-a");

    error = nil;
    FMTestRequireSuccess(FMConfirmWorkingProfileAtStatePath(statePath, &error), error,
                         @"confirm Profile B after simulated restart");
    FMAssertState(statePath, @"clean", @"profile-b", NO);
    FMAssertConfirmedProfile(statePath, @"profile-b");

    error = nil;
    FMTestRequireSuccess(FMStageProfileAtRoots(
                                               stockRoot, mirrorRoot, nil, nil,
                                               @[ @"Core/B.ttf", @"Core/C.ttf" ],
                                               statePath, FMProfileEngineNoFaultInjection, &error),
                         error, @"stage Stock");
    for (NSString *relativePath in allPaths) {
        FMTestRequire([FMHash([mirrorRoot stringByAppendingPathComponent:relativePath])
                          isEqual:FMHash([stockRoot stringByAppendingPathComponent:relativePath])],
                      [NSString stringWithFormat:@"Stock restore failed for %@", relativePath]);
    }
    FMAssertState(statePath, @"clean", NSNull.null, YES);
    FMAssertConfirmedProfile(statePath, @"profile-b");

    error = nil;
    FMTestRequireSuccess(FMConfirmWorkingProfileAtStatePath(statePath, &error), error,
                         @"confirm Stock after simulated restart");
    FMAssertState(statePath, @"clean", NSNull.null, NO);
    FMAssertConfirmedProfile(statePath, NSNull.null);

    NSMutableDictionary *badHashProfile = [profileA mutableCopy];
    NSMutableArray *badReplacements = [NSMutableArray array];
    for (NSDictionary *entry in profileA[@"replacements"]) {
        [badReplacements addObject:[entry mutableCopy]];
    }
    badReplacements[0][@"sha256"] =
        [@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0];
    badHashProfile[@"replacements"] = badReplacements;
    NSData *stateBeforePreflight = [NSData dataWithContentsOfFile:statePath];
    NSString *aBeforePreflight =
        FMHash([mirrorRoot stringByAppendingPathComponent:@"Core/A.ttf"]);
    error = nil;
    FMTestRequire(!FMStageProfileAtRoots(stockRoot, mirrorRoot, badHashProfile,
                                         profileADirectory,
                                         @[], statePath,
                                         FMProfileEngineNoFaultInjection, &error),
                  @"bad replacement hash unexpectedly staged");
    FMTestRequire([stateBeforePreflight isEqual:[NSData dataWithContentsOfFile:statePath]],
                  @"preflight failure changed persistent state");
    FMTestRequire([aBeforePreflight
                      isEqual:FMHash([mirrorRoot stringByAppendingPathComponent:@"Core/A.ttf"])],
                  @"preflight failure changed mirror content");

    NSString *missingReplacement =
        [profileADirectory stringByAppendingPathComponent:@"replacements/A.custom"];
    FMTestRequire([NSFileManager.defaultManager removeItemAtPath:missingReplacement error:&error],
                  @"remove replacement for missing-source test");
    NSData *stateBeforeMissingSource = [NSData dataWithContentsOfFile:statePath];
    error = nil;
    FMTestRequire(!FMStageProfileAtRoots(stockRoot, mirrorRoot, profileA,
                                         profileADirectory,
                                         @[], statePath,
                                         FMProfileEngineNoFaultInjection, &error),
                  @"missing replacement source unexpectedly staged");
    FMTestRequire([stateBeforeMissingSource isEqual:[NSData dataWithContentsOfFile:statePath]],
                  @"missing-source preflight changed persistent state");
    FMWriteText(missingReplacement, @"custom-a1");

    NSMutableDictionary *wrongBuildProfile = [profileA mutableCopy];
    wrongBuildProfile[@"systemBuild"] = @"21C62";
    error = nil;
    FMTestRequire(!FMStageProfileAtRoots(stockRoot, mirrorRoot, wrongBuildProfile,
                                         profileADirectory,
                                         @[], statePath,
                                         FMProfileEngineNoFaultInjection, &error) &&
                      error.code == FMProfileEngineErrorBuildMismatch,
                  @"system-build mismatch was not rejected");

    error = nil;
    FMTestRequire(!FMStageProfileAtRoots(stockRoot, mirrorRoot, profileB, profileBDirectory,
                                         @[], statePath, 1, &error),
                  @"fault-injected stage unexpectedly succeeded");
    FMTestRequire(error.code == FMProfileEngineErrorInjectedFailure,
                  @"fault injection returned the wrong error");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/B.ttf"])
                      isEqual:@"custom-b2"],
                  @"first fault-injected commit was not completed");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/C.ttf"])
                      isEqual:@"stock-c"],
                  @"fault injection committed too many files");
    FMAssertState(statePath, @"repairRequired", @"profile-b", NO);

    error = nil;
    FMTestRequire(!FMRepairProfileAtRoots(stockRoot, mirrorRoot, profileB,
                                          profileBDirectory, allPaths, statePath,
                                          FMProfileEngineNoFaultInjection, &error) &&
                      error.code == FMProfileEngineErrorInvalidTransition,
                  @"repair accepted paths different from the persisted transition");
    FMAssertState(statePath, @"repairRequired", @"profile-b", NO);

    error = nil;
    FMTestRequireSuccess(FMRepairProfileAtRoots(stockRoot, mirrorRoot, profileB,
                                                profileBDirectory,
                                                @[ @"Core/B.ttf", @"Core/C.ttf" ], statePath,
                                                FMProfileEngineNoFaultInjection, &error),
                         error, @"repair Profile B");
    FMTestRequire([FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/B.ttf"])
                      isEqual:@"custom-b2"] &&
                      [FMReadText([mirrorRoot stringByAppendingPathComponent:@"Core/C.ttf"])
                          isEqual:@"custom-c2"],
                  @"repair did not converge Profile B");
    FMAssertState(statePath, @"clean", @"profile-b", YES);

    error = nil;
    FMTestRequireSuccess(FMStageProfileAtRoots(
                                               stockRoot, mirrorRoot, nil, nil,
                                               @[ @"Core/B.ttf", @"Core/C.ttf" ], statePath,
                                               FMProfileEngineNoFaultInjection, &error),
                         error, @"restore Stock before containment tests");

    error = nil;
    FMTestRequireSuccess(FMMarkProfileRepairRequiredAtStatePath(statePath, allPaths, &error),
                         error, @"mark clean state repair-required");
    FMAssertState(statePath, @"repairRequired", NSNull.null, NO);
    error = nil;
    FMTestRequireSuccess(FMRepairProfileAtRoots(stockRoot, mirrorRoot, nil, nil, allPaths,
                                                statePath, FMProfileEngineNoFaultInjection,
                                                &error),
                         error, @"repair explicitly marked Stock state");
    FMAssertState(statePath, @"clean", NSNull.null, NO);

    NSString *externalFile = [engineRoot stringByAppendingPathComponent:@"external.ttf"];
    FMWriteText(externalFile, @"outside");
    NSString *mirrorA = [mirrorRoot stringByAppendingPathComponent:@"Core/A.ttf"];
    FMTestRequire([NSFileManager.defaultManager removeItemAtPath:mirrorA error:&error],
                  @"remove mirror A for symlink test");
    FMTestRequire(symlink(externalFile.fileSystemRepresentation,
                          mirrorA.fileSystemRepresentation) == 0,
                  @"create mirror target symlink");
    error = nil;
    FMTestRequire(!FMStageProfileAtRoots(stockRoot, mirrorRoot, profileA,
                                         profileADirectory, @[ @"Core/A.ttf", @"Core/B.ttf" ],
                                         statePath, FMProfileEngineNoFaultInjection, &error),
                  @"symlink mirror target accepted");
    FMTestRequire([FMReadText(externalFile) isEqual:@"outside"],
                  @"symlink target outside mirror was modified");
    FMTestRequire([NSFileManager.defaultManager removeItemAtPath:mirrorA error:&error],
                  @"remove mirror target symlink");
    FMWriteText(mirrorA, @"stock-a");

    NSString *stockEscape = [stockRoot stringByAppendingPathComponent:@"Escape/X.ttf"];
    FMWriteText(stockEscape, @"stock-x");
    NSString *externalDirectory = [engineRoot stringByAppendingPathComponent:@"outside-dir"];
    FMWriteText([externalDirectory stringByAppendingPathComponent:@"X.ttf"], @"outside-x");
    NSString *mirrorEscape = [mirrorRoot stringByAppendingPathComponent:@"Escape"];
    FMTestRequire(symlink(externalDirectory.fileSystemRepresentation,
                          mirrorEscape.fileSystemRepresentation) == 0,
                  @"create escaping mirror parent symlink");
    error = nil;
    FMTestRequire(!FMStageProfileAtRoots(stockRoot, mirrorRoot, nil, nil,
                                         @[ @"Escape/X.ttf" ], statePath,
                                         FMProfileEngineNoFaultInjection, &error),
                  @"mirror parent escaping its root was accepted");
    FMTestRequire([FMReadText([externalDirectory stringByAppendingPathComponent:@"X.ttf"])
                      isEqual:@"outside-x"],
                  @"escaping mirror parent modified an outside file");
    FMAssertState(statePath, @"clean", NSNull.null, NO);
    FMAssertNoTemporaryFiles(engineRoot);
    printf("PASS: Profile stage, Stock restore, interruption repair, containment\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        FMTestRequire(argc == 2, @"data-core test requires one fixture root argument");
        NSString *testRoot = [NSString stringWithUTF8String:argv[1]];
        FMCreateDirectory(testRoot);
        FMTestSchemas();
        FMTestStoreAndManifest(testRoot);
        FMTestProfileEngine(testRoot);
        printf("PASS: Font Manager Phase 1 data core\n");
    }
    return 0;
}
