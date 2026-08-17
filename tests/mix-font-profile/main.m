#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMFontProfileStore.h"
#import "FMFontSlotCatalog.h"
#import "FMMixFontProfile.h"
#import "FMProfileAdoptionValidator.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSString *FMSHA256HexForData(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex =
        [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static NSString *FMFixtureFontFileID(NSString *relativePath) {
    return [@"font-file-"
        stringByAppendingString:FMSHA256HexForData(
             [relativePath dataUsingEncoding:NSUTF8StringEncoding])];
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

static NSDictionary<NSString *, id> *FMFixtureCatalog(void) {
    // The manifest contract requires unique, sorted relative paths.
    NSArray<NSString *> *paths = [@[
        @"Core/SFUI.ttf",
        @"Core/SFUIItalic.ttf",
        @"LanguageSupport/PingFang.ttc",
        @"AppFonts/LockClock.ttf",
        @"CoreAddition/AppleColorEmoji-160px.ttc",
        @"Watch/ADTNumeric.ttc",
    ] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
    for (NSUInteger index = 0; index < paths.count; index++) {
        [entries addObject:FMRegularEntry(
            paths[index],
            [NSString stringWithFormat:@"%064lu", (unsigned long)index],
            @100)];
    }
    NSError *error = nil;
    NSDictionary<NSString *, id> *catalog = FMCreateFontCatalogFromManifest(
        @{ @"schemaVersion" : @2, @"entries" : entries }, @"21D61",
        @"1111111111111111111111111111111111111111111111111111111111111111",
        &error);
    FMRequire(catalog != nil, @"fixture catalog could not be built");
    return catalog;
}

// Writes one app-owned source Profile whose replacement bytes are stable,
// distinctive payloads ("owner|relativePath").
static BOOL FMMakeSourceProfile(NSString *profilesRoot,
                                NSString *profileID,
                                NSString *name,
                                NSArray<NSString *> *relativePaths,
                                NSString *bogusFontFileID) {
    NSString *directory = [profilesRoot stringByAppendingPathComponent:profileID];
    NSString *replacements = [directory stringByAppendingPathComponent:@"replacements"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:replacements
                                withIntermediateDirectories:YES
                                                 attributes:@{ NSFilePosixPermissions : @0700 }
                                                      error:nil]) {
        return NO;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
    NSUInteger index = 0;
    for (NSString *relativePath in relativePaths) {
        NSData *payload = [[NSString stringWithFormat:@"%@|%@", profileID, relativePath]
            dataUsingEncoding:NSUTF8StringEncoding];
        NSString *fileName = [NSString
            stringWithFormat:@"replacement-%04lu.%@", (unsigned long)index,
            relativePath.pathExtension];
        NSString *target = [replacements stringByAppendingPathComponent:fileName];
        if (![payload writeToFile:target atomically:YES]) return NO;
        [entries addObject:@{
            @"fontFileID" : bogusFontFileID ?: FMFixtureFontFileID(relativePath),
            @"relativePath" : relativePath,
            @"fileName" : fileName,
            @"sha256" : FMSHA256HexForData(payload),
        }];
        index++;
    }
    NSDictionary<NSString *, id> *profile = @{
        @"schemaVersion" : @2,
        @"id" : profileID,
        @"name" : name,
        @"systemBuild" : @"21D61",
        @"replacements" : entries,
    };
    return FMWriteJSONObjectAtomically(
        profile, [directory stringByAppendingPathComponent:@"profile.json"], 0600, nil);
}

static NSData *FMSourcePayload(NSString *profileID, NSString *relativePath) {
    return [[NSString stringWithFormat:@"%@|%@", profileID, relativePath]
        dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *FMMakeTempRoot(void) {
    NSString *root = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString
            stringWithFormat:@"mix-profile-test-%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static NSData *FMStoredReplacement(NSString *profilesRoot,
                                   NSString *profileID,
                                   NSString *fileName) {
    NSString *path = [[[profilesRoot stringByAppendingPathComponent:profileID]
        stringByAppendingPathComponent:@"replacements"]
        stringByAppendingPathComponent:fileName];
    return [NSData dataWithContentsOfFile:path];
}

int main(void) {
    @autoreleasepool {
        NSDictionary<NSString *, id> *catalog = FMFixtureCatalog();
        NSString *chinese = @"LanguageSupport/PingFang.ttc";
        NSString *latin = @"Core/SFUI.ttf";
        NSString *latinItalic = @"Core/SFUIItalic.ttf";
        NSString *lockNumeric = @"Watch/ADTNumeric.ttc";
        NSString *lockScreen = @"AppFonts/LockClock.ttf";
        NSString *emoji = @"CoreAddition/AppleColorEmoji-160px.ttc";

        NSString *root = FMMakeTempRoot();
        NSString *profilesRoot = [root stringByAppendingPathComponent:@"profiles"];
        FMRequire(FMMakeSourceProfile(profilesRoot, @"import-a", @"方案A",
                     @[ chinese, emoji ], nil) &&
                      FMMakeSourceProfile(profilesRoot, @"import-b", @"方案B",
                          @[ latin, chinese, emoji ], nil) &&
                      FMMakeSourceProfile(profilesRoot, @"import-c", @"方案C",
                          @[ latin ], nil) &&
                      FMMakeSourceProfile(profilesRoot, @"import-d", @"方案D",
                          @[ lockNumeric ], nil),
                  @"source schemes could not be written");

        NSDictionary *assignments =
            @{ FMFontSlotIdentifierChinese : @"import-a" };
        NSError *error = nil;

        // Preview: slot scheme A contributes only PingFang; B supplies SFUI
        // and emoji (its own PingFang is claimed by the Chinese slot).
        NSDictionary *preview = FMMixFontProfilePreviewAtRoot(
            profilesRoot, catalog, assignments, @"import-b", &error);
        FMRequire(preview != nil, @"preview merge failed");
        FMRequire([preview[@"replacementCount"] unsignedIntegerValue] == 3,
                  @"preview must merge 3 replacements");
        FMRequire([preview[@"fallbackReplacementCount"] unsignedIntegerValue] == 2,
                  @"preview must attribute 2 replacements to the fallback");
        NSArray *slots = preview[@"slots"];
        NSDictionary *chineseSummary = slots[0];
        FMRequire([chineseSummary[@"assignedProfileID"] isEqual:@"import-a"] &&
                      [chineseSummary[@"replacedRelativePaths"] isEqual:@[ chinese ]],
                  @"Chinese slot summary must show the assigned scheme coverage");
        NSDictionary *latinSummary = slots[1];
        FMRequire([latinSummary[@"assignedProfileID"] isEqual:NSNull.null] &&
                      [latinSummary[@"fallbackRelativePaths"] isEqual:@[ latin ]] &&
                      [latinSummary[@"stockRelativePaths"] isEqual:@[ latinItalic ]],
                  @"unassigned Latin slot must fall back and keep the rest stock");
        NSDictionary *lockSummary = slots[2];
        FMRequire([lockSummary[@"fallbackRelativePaths"] isEqual:@[]] &&
                      [lockSummary[@"stockRelativePaths"]
                          isEqual:@[ lockNumeric, lockScreen ]],
                  @"dedicated clock paths must stay independent from Latin fallback");

        // Materialize the same merge.
        NSDictionary *saved = FMCreateMixedFontProfileAtRoot(
            profilesRoot, catalog, assignments, @"import-b",
            @"import-mix-0001", @"我的混搭", &error);
        FMRequire(saved != nil, @"mix profile could not be created");
        FMRequire([saved[@"replacementCount"] unsignedIntegerValue] == 3,
                  @"created mix must contain 3 replacements");

        NSString *mixDirectory = [profilesRoot stringByAppendingPathComponent:@"import-mix-0001"];
        NSDictionary *document = [FMReadJSONObjectAtPath(
            [mixDirectory stringByAppendingPathComponent:@"profile.json"], nil) copy];
        FMRequire(FMValidateProfileDocument(document, nil),
                  @"created mix document must validate");
        NSDictionary *recipe = document[@"mixRecipe"];
        FMRequire([recipe isKindOfClass:NSDictionary.class] &&
                      [recipe[@"type"] isEqual:@"mix"] &&
                      [recipe[@"slots"][FMFontSlotIdentifierChinese][@"profileID"]
                          isEqual:@"import-a"] &&
                      [recipe[@"fallback"][@"profileID"] isEqual:@"import-b"],
                  @"mix recipe must record slot and fallback sources");

        // Slot precedence: PingFang bytes come from A, never from B.
        __block NSString *chineseStoredName = nil;
        __block NSString *latinStoredName = nil;
        __block NSString *emojiStoredName = nil;
        for (NSDictionary *entry in document[@"replacements"]) {
            NSData *expected = nil;
            if ([entry[@"relativePath"] isEqual:chinese]) {
                expected = FMSourcePayload(@"import-a", chinese);
                chineseStoredName = entry[@"fileName"];
            } else if ([entry[@"relativePath"] isEqual:latin]) {
                expected = FMSourcePayload(@"import-b", latin);
                latinStoredName = entry[@"fileName"];
            } else if ([entry[@"relativePath"] isEqual:emoji]) {
                expected = FMSourcePayload(@"import-b", emoji);
                emojiStoredName = entry[@"fileName"];
            }
            FMRequire(expected != nil, @"mix contains an unexpected target");
            NSData *stored = FMStoredReplacement(profilesRoot, @"import-mix-0001",
                                                 entry[@"fileName"]);
            FMRequire([stored isEqual:expected],
                      @"merged file bytes must come from the winning scheme");
        }
        FMRequire(chineseStoredName != nil && latinStoredName != nil &&
                      emojiStoredName != nil,
                  @"mix must contain all three expected targets");

        // Stored files are sequential, private, and match their hashes.
        struct stat info = {0};
        NSString *storedPath = [[[mixDirectory stringByAppendingPathComponent:@"replacements"]
            stringByAppendingPathComponent:chineseStoredName] copy];
        FMRequire(lstat(storedPath.fileSystemRepresentation, &info) == 0 &&
                      S_ISREG(info.st_mode) && (info.st_mode & 0777) == 0600,
                  @"merged replacement files must be private regular files");

        // The merged Profile is listed, flagged, detailed, and adopt-compatible.
        __block NSDictionary *listed = nil;
        for (NSDictionary *entry in FMListFontProfilesAtRoot(profilesRoot, @"21D61", nil)) {
            if ([entry[@"id"] isEqual:@"import-mix-0001"]) listed = entry;
        }
        FMRequire(listed != nil && [listed[@"isMix"] boolValue],
                  @"library listing must flag the mix profile");
        NSDictionary *details = FMFontProfileDetailsAtRoot(
            profilesRoot, @"import-mix-0001", @"21D61", nil);
        FMRequire([details[@"mixRecipe"] isKindOfClass:NSDictionary.class] &&
                      [details[@"filePathByRelativePath"] count] == 3u,
                  @"mix details must expose the recipe and stored file paths");
        FMRequire(FMCreateProfileAdoptionPreviewAtRoot(
                      profilesRoot, @"import-mix-0001", @"21D61", catalog, nil) != nil,
                  @"merged profile must remain adoption-compatible");

        // A slot scheme without the slot file contributes nothing; the
        // uncovered slot path falls back (A supplies PingFang) while the
        // unassigned Latin slot also falls back (A lacks SFUI, so it stays
        // stock).
        preview = FMMixFontProfilePreviewAtRoot(
            profilesRoot, catalog, @{ FMFontSlotIdentifierChinese : @"import-c" },
            @"import-a", &error);
        FMRequire(preview != nil &&
                      [preview[@"replacementCount"] unsignedIntegerValue] == 2,
                  @"slot without coverage must fall back to the fallback scheme");
        FMRequire([preview[@"slots"][0][@"fallbackRelativePaths"] isEqual:@[ chinese ]] &&
                      [preview[@"slots"][1][@"stockRelativePaths"]
                          isEqual:@[ latin, latinItalic ]],
                  @"Chinese path must be fallback-provided, Latin stays stock");

        // No fallback: only slot files are merged.
        saved = FMCreateMixedFontProfileAtRoot(
            profilesRoot, catalog, assignments, nil,
            @"import-mix-0002", @"纯槽位混搭", &error);
        FMRequire(saved != nil && [saved[@"replacementCount"] unsignedIntegerValue] == 1,
                  @"slot-only mix must contain exactly the slot file");

        // Latin and dedicated lock-clock targets can come from different
        // schemes without either slot overriding the other.
        NSDictionary *independentAssignments = @{
            FMFontSlotIdentifierLatin : @"import-b",
            FMFontSlotIdentifierLockScreen : @"import-d",
        };
        preview = FMMixFontProfilePreviewAtRoot(
            profilesRoot, catalog, independentAssignments, nil, &error);
        FMRequire(preview != nil &&
                      [preview[@"replacementCount"] unsignedIntegerValue] == 2,
                  @"Latin and clock assignments must merge two disjoint targets");
        NSDictionary *independentLatinSummary = preview[@"slots"][1];
        NSDictionary *independentLockSummary = preview[@"slots"][2];
        FMRequire([independentLatinSummary[@"replacedRelativePaths"]
                      isEqual:@[ latin ]] &&
                      [independentLockSummary[@"replacedRelativePaths"]
                          isEqual:@[ lockNumeric ]],
                  @"each independent slot must retain its assigned source");
        saved = FMCreateMixedFontProfileAtRoot(
            profilesRoot, catalog, independentAssignments, nil,
            @"import-mix-0003", @"独立锁屏混搭", &error);
        FMRequire(saved != nil && [saved[@"replacementCount"] unsignedIntegerValue] == 2,
                  @"independent Latin and clock mix could not be materialized");
        document = FMReadJSONObjectAtPath([[profilesRoot
            stringByAppendingPathComponent:@"import-mix-0003"]
            stringByAppendingPathComponent:@"profile.json"], nil);
        for (NSDictionary *replacement in document[@"replacements"]) {
            NSString *relativePath = replacement[@"relativePath"];
            NSString *expectedSource = [relativePath isEqual:latin]
                ? @"import-b"
                : ([relativePath isEqual:lockNumeric] ? @"import-d" : nil);
            FMRequire(expectedSource != nil &&
                          [FMStoredReplacement(profilesRoot, @"import-mix-0003",
                              replacement[@"fileName"])
                              isEqual:FMSourcePayload(expectedSource, relativePath)],
                      @"materialized bytes must come from each independent slot");
        }

        // Nothing selected at all is rejected.
        error = nil;
        saved = FMCreateMixedFontProfileAtRoot(
            profilesRoot, catalog, @{}, nil, @"import-mix-0004", @"空混搭", &error);
        FMRequire(saved == nil && error.code == FMMixFontProfileErrorEmptyResult,
                  @"empty mix must fail closed");

        // Identifier prefix and unknown slots are rejected.
        error = nil;
        FMRequire(FMCreateMixedFontProfileAtRoot(
                      profilesRoot, catalog, assignments, @"import-b",
                      @"import-not-mix", @"x", &error) == nil,
                  @"non-mix identifier prefix must be rejected");
        error = nil;
        FMRequire(FMMixFontProfilePreviewAtRoot(
                      profilesRoot, catalog, @{ @"nonexistent" : @"import-a" },
                      nil, &error) == nil,
                  @"unknown slot must be rejected");

        // A source scheme that drifted from the catalog fails the merge.
        FMRequire(FMMakeSourceProfile(profilesRoot, @"import-stale", @"过期方案",
                     @[ chinese ], @"font-file-stale0000000000000000000000000000000000000"),
                  @"stale source scheme could not be written");
        error = nil;
        FMRequire(FMMixFontProfilePreviewAtRoot(
                      profilesRoot, catalog, @{ FMFontSlotIdentifierChinese : @"import-stale" },
                      nil, &error) == nil &&
                      error.code == FMMixFontProfileErrorInvalidProfile,
                  @"catalog-mismatched source scheme must be rejected");

        printf("PASS: mix merge keeps Latin and clock targets independent with fallback, recipes, and adoption compatibility\n");
        return 0;
    }
}
