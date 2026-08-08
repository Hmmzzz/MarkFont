#import <Foundation/Foundation.h>
#import <sys/stat.h>

#import "FMFontCatalog.h"
#import "FMFontPackageAnalyzer.h"
#import "FMFontPackageImportSession.h"
#import "FMFontProfileStore.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static void FMAppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[] = { (uint8_t)value, (uint8_t)(value >> 8) };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void FMAppendLE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {
        (uint8_t)value,
        (uint8_t)(value >> 8),
        (uint8_t)(value >> 16),
        (uint8_t)(value >> 24),
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint32_t FMCRC32(NSData *data) {
    uint32_t crc = UINT32_MAX;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        crc ^= bytes[index];
        for (NSUInteger bit = 0; bit < 8; bit++) {
            crc = (crc >> 1) ^ (0xedb88320U & (uint32_t)-(int32_t)(crc & 1));
        }
    }
    return ~crc;
}

static BOOL FMWriteStoredZIP(NSString *path,
                             NSArray<NSDictionary<NSString *, id> *> *entries,
                             NSError **error) {
    NSMutableData *archive = [NSMutableData data];
    NSMutableArray<NSDictionary<NSString *, id> *> *centralEntries =
        [NSMutableArray array];
    for (NSDictionary<NSString *, id> *entry in entries) {
        NSData *name = [entry[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *contents = entry[@"data"];
        FMRequire(name.length <= UINT16_MAX && contents.length <= UINT32_MAX,
                  @"ZIP fixture entry is too large");
        uint32_t offset = (uint32_t)archive.length;
        uint32_t crc = FMCRC32(contents);
        FMAppendLE32(archive, 0x04034b50);
        FMAppendLE16(archive, 20);
        FMAppendLE16(archive, 0x0800);
        FMAppendLE16(archive, 0);
        FMAppendLE16(archive, 0);
        FMAppendLE16(archive, 0);
        FMAppendLE32(archive, crc);
        FMAppendLE32(archive, (uint32_t)contents.length);
        FMAppendLE32(archive, (uint32_t)contents.length);
        FMAppendLE16(archive, (uint16_t)name.length);
        FMAppendLE16(archive, 0);
        [archive appendData:name];
        [archive appendData:contents];
        [centralEntries addObject:@{
            @"name" : name,
            @"size" : @((uint32_t)contents.length),
            @"crc" : @(crc),
            @"offset" : @(offset),
            @"mode" : entry[@"mode"] ?: @(S_IFREG | 0644),
        }];
    }

    uint32_t centralOffset = (uint32_t)archive.length;
    for (NSDictionary<NSString *, id> *entry in centralEntries) {
        NSData *name = entry[@"name"];
        uint32_t size = [entry[@"size"] unsignedIntValue];
        FMAppendLE32(archive, 0x02014b50);
        FMAppendLE16(archive, 0x0314);
        FMAppendLE16(archive, 20);
        FMAppendLE16(archive, 0x0800);
        FMAppendLE16(archive, 0);
        FMAppendLE16(archive, 0);
        FMAppendLE16(archive, 0);
        FMAppendLE32(archive, [entry[@"crc"] unsignedIntValue]);
        FMAppendLE32(archive, size);
        FMAppendLE32(archive, size);
        FMAppendLE16(archive, (uint16_t)name.length);
        FMAppendLE16(archive, 0);
        FMAppendLE16(archive, 0);
        FMAppendLE16(archive, 0);
        FMAppendLE16(archive, 0);
        FMAppendLE32(archive, [entry[@"mode"] unsignedIntValue] << 16);
        FMAppendLE32(archive, [entry[@"offset"] unsignedIntValue]);
        [archive appendData:name];
    }
    uint32_t centralSize = (uint32_t)archive.length - centralOffset;
    FMAppendLE32(archive, 0x06054b50);
    FMAppendLE16(archive, 0);
    FMAppendLE16(archive, 0);
    FMAppendLE16(archive, (uint16_t)centralEntries.count);
    FMAppendLE16(archive, (uint16_t)centralEntries.count);
    FMAppendLE32(archive, centralSize);
    FMAppendLE32(archive, centralOffset);
    FMAppendLE16(archive, 0);
    return [archive writeToFile:path options:NSDataWritingAtomic error:error];
}

static NSDictionary<NSString *, id> *FMCatalogForPaths(
    NSArray<NSDictionary<NSString *, NSString *> *> *pathHashes,
    NSString *systemBuild,
    NSError **error) {
    NSMutableArray<NSDictionary<NSString *, id> *> *primaryEntries =
        [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *supplementalEntries =
        [NSMutableArray array];
    NSString *supplementalPrefix =
        [FMFontCatalogFontServicesCorePrivatePrefix stringByAppendingString:@"/"];
    for (NSDictionary<NSString *, NSString *> *item in pathHashes) {
        NSString *path = item[@"path"];
        BOOL supplemental = [path hasPrefix:supplementalPrefix];
        NSString *manifestPath = supplemental
            ? [path substringFromIndex:supplementalPrefix.length] : path;
        NSMutableArray *entries = supplemental
            ? supplementalEntries : primaryEntries;
        [entries addObject:@{
            @"relativePath" : manifestPath,
            @"type" : @"regular",
            @"mode" : @0644,
            @"uid" : @0,
            @"gid" : @0,
            @"size" : @1,
            @"sha256" : item[@"sha256"],
        }];
    }
    NSComparator byPath = ^NSComparisonResult(NSDictionary *left,
                                               NSDictionary *right) {
        return [left[@"relativePath"] compare:right[@"relativePath"]];
    };
    [primaryEntries sortUsingComparator:byPath];
    [supplementalEntries sortUsingComparator:byPath];
    NSDictionary *supplementalManifest = supplementalEntries.count > 0
        ? @{ @"schemaVersion" : @2, @"entries" : supplementalEntries }
        : nil;
    return FMCreateFontCatalogFromManifests(
        @{ @"schemaVersion" : @2, @"entries" : primaryEntries },
        supplementalManifest, systemBuild,
        @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        supplementalManifest != nil
            ? @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            : nil,
        error);
}

static NSDictionary<NSString *, id> *FMFixtureCatalog(NSError **error) {
    return FMCatalogForPaths(@[
        @{
            @"path" : @"Core/Geneva.ttf",
            @"sha256" : @"1111111111111111111111111111111111111111111111111111111111111111",
        },
    ], @"TEST-BUILD", error);
}

static void FMRunImportSessionTests(NSString *temporaryRoot) {
    NSError *error = nil;
    FMRequire([FMFontPackageImportSession discardAbandonedSessions:&error],
              [NSString stringWithFormat:@"stale import cleanup failed: %@", error]);
    NSData *fontData =
        [NSData dataWithContentsOfFile:@"/System/Library/Fonts/Geneva.ttf"];
    FMRequire(fontData.length > 0, @"import-session font fixture is missing");
    NSString *sourceDirectory =
        [temporaryRoot stringByAppendingPathComponent:@"picker-source"];
    FMRequire([NSFileManager.defaultManager createDirectoryAtPath:sourceDirectory
                                      withIntermediateDirectories:NO
                                                       attributes:nil
                                                            error:&error],
              [NSString stringWithFormat:@"picker-source directory failed: %@", error]);
    NSString *sourcePath = [sourceDirectory stringByAppendingPathComponent:@"Geneva.ttf"];
    FMRequire([fontData writeToFile:sourcePath options:NSDataWritingAtomic error:&error],
              [NSString stringWithFormat:@"picker-source write failed: %@", error]);

    FMFontPackageImportSession *session =
        [FMFontPackageImportSession sessionByImportingURL:
            [NSURL fileURLWithPath:sourcePath]
                                                     error:&error];
    FMRequire(session != nil,
              [NSString stringWithFormat:@"controlled import failed: %@", error]);
    NSString *sessionPath = session.sessionDirectoryURL.path;
    NSString *copyPath = session.packageURL.path;
    struct stat sessionInfo = {0};
    struct stat copyInfo = {0};
    FMRequire(lstat(sessionPath.fileSystemRepresentation, &sessionInfo) == 0 &&
                  S_ISDIR(sessionInfo.st_mode) && (sessionInfo.st_mode & 0777) == 0700,
              @"controlled import directory mode is not 0700");
    FMRequire(lstat(copyPath.fileSystemRepresentation, &copyInfo) == 0 &&
                  S_ISREG(copyInfo.st_mode) && (copyInfo.st_mode & 0777) == 0600,
              @"controlled package copy mode is not 0600");
    FMRequire([session.packageURL.lastPathComponent isEqual:@"Geneva.ttf"] &&
                  [[NSData dataWithContentsOfFile:copyPath] isEqual:fontData],
              @"controlled package copy changed the name or contents");
    FMRequire([session discard:&error],
              [NSString stringWithFormat:@"controlled import discard failed: %@", error]);
    FMRequire(![NSFileManager.defaultManager fileExistsAtPath:sessionPath] &&
                  [NSFileManager.defaultManager fileExistsAtPath:sourcePath],
              @"discard removed the source or retained the controlled copy");

    FMFontPackageImportSession *abandoned =
        [FMFontPackageImportSession sessionByImportingURL:
            [NSURL fileURLWithPath:sourcePath]
                                                     error:&error];
    NSString *abandonedPath = abandoned.sessionDirectoryURL.path;
    FMRequire(abandoned != nil &&
                  [FMFontPackageImportSession discardAbandonedSessions:&error],
              [NSString stringWithFormat:@"abandoned import cleanup failed: %@", error]);
    FMRequire(![NSFileManager.defaultManager fileExistsAtPath:abandonedPath] &&
                  [NSFileManager.defaultManager fileExistsAtPath:sourcePath] &&
                  [abandoned discard:&error],
              @"abandoned cleanup was not exact or idempotent");
}

static NSArray<NSDictionary<NSString *, NSString *> *> *FMReadHashList(
    NSString *path,
    NSError **error) {
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:error];
    if (text == nil) return nil;
    NSMutableArray *items = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        (void)stop;
        NSRange separator = [line rangeOfString:@"  ./"];
        if (separator.location == NSNotFound || separator.location != 64) return;
        NSString *hash = [line substringToIndex:64];
        NSString *relativePath = [line substringFromIndex:NSMaxRange(separator)];
        [items addObject:@{ @"path" : relativePath, @"sha256" : hash }];
    }];
    return items;
}

static void FMRunFixtureTests(NSString *temporaryRoot) {
    NSString *genevaPath = @"/System/Library/Fonts/Geneva.ttf";
    NSString *symbolPath = @"/System/Library/Fonts/Symbol.ttf";
    NSData *geneva = [NSData dataWithContentsOfFile:genevaPath];
    NSData *symbol = [NSData dataWithContentsOfFile:symbolPath];
    FMRequire(geneva.length > 0 && symbol.length > 0,
              @"pinned host font fixtures are missing");

    NSError *error = nil;
    NSDictionary *catalog = FMFixtureCatalog(&error);
    FMRequire(catalog != nil,
              [NSString stringWithFormat:@"catalog fixture failed: %@", error]);

    NSDictionary *raw = FMAnalyzeFontPackageAtPath(genevaPath, catalog, &error);
    FMRequire(raw != nil && [raw[@"matchedTargetCount"] unsignedIntegerValue] == 1 &&
                  [raw[@"readOnly"] boolValue],
              [NSString stringWithFormat:@"raw font preview failed: %@", error]);

    NSString *archivePath = [temporaryRoot stringByAppendingPathComponent:@"package.zip"];
    NSArray *entries = @[
        @{ @"name" : @"Package/Core/Geneva.ttf", @"data" : geneva },
        @{ @"name" : @"Package/CoreUI/Geneva.ttf", @"data" : geneva },
        @{ @"name" : @"Package/Unknown.ttf", @"data" : symbol },
        @{ @"name" : @"Package/Bad.ttf", @"data" : [@"not a font" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"Package/README.txt", @"data" : [@"notes" dataUsingEncoding:NSUTF8StringEncoding] },
        @{ @"name" : @"__MACOSX/Package/._Geneva.ttf", @"data" : [@"metadata" dataUsingEncoding:NSUTF8StringEncoding] },
    ];
    FMRequire(FMWriteStoredZIP(archivePath, entries, &error),
              [NSString stringWithFormat:@"ZIP fixture write failed: %@", error]);
    NSDictionary *preview = FMAnalyzeFontPackageAtPath(archivePath, catalog, &error);
    FMRequire(preview != nil,
              [NSString stringWithFormat:@"ZIP preview failed: %@", error]);
    FMRequire([preview[@"packageFontFileCount"] unsignedIntegerValue] == 3 &&
                  [preview[@"matchedTargetCount"] unsignedIntegerValue] == 1 &&
                  [preview[@"unmatchedSourceCount"] unsignedIntegerValue] == 1 &&
                  [preview[@"conflictTargetCount"] unsignedIntegerValue] == 0 &&
                  [preview[@"deduplicatedSourceCount"] unsignedIntegerValue] == 1 &&
                  [preview[@"invalidFontEntryCount"] unsignedIntegerValue] == 1 &&
                  [preview[@"ignoredEntryCount"] unsignedIntegerValue] == 1,
              [NSString stringWithFormat:@"ZIP preview counts are inconsistent: %@", preview]);

    NSString *profilesRoot = [temporaryRoot stringByAppendingPathComponent:@"profiles"];
    NSDictionary<NSString *, id> *saved = FMImportFontPackageProfile(
        archivePath, catalog, profilesRoot, @"import-host-test", @"Host Test", &error);
    FMRequire(saved != nil && [saved[@"replacementCount"] unsignedIntegerValue] == 1,
              [NSString stringWithFormat:@"package Profile save failed: %@", error]);
    NSArray<NSDictionary<NSString *, id> *> *savedProfiles =
        FMListFontProfilesAtRoot(profilesRoot, @"TEST-BUILD", &error);
    FMRequire(savedProfiles.count == 1 &&
                  [savedProfiles.firstObject[@"id"] isEqual:@"import-host-test"],
              @"saved package Profile was not listed");
    NSDictionary<NSString *, id> *savedDetails = FMFontProfileDetailsAtRoot(
        profilesRoot, @"import-host-test", @"TEST-BUILD", &error);
    FMRequire(savedDetails != nil &&
                  [savedDetails[@"relativePaths"] isEqual:@[ @"Core/Geneva.ttf" ]],
              @"saved package Profile details are inconsistent");
    FMRequire(FMDeleteFontProfileAtRoot(profilesRoot, @"import-host-test",
                                        @"TEST-BUILD", &error),
              [NSString stringWithFormat:@"saved package Profile delete failed: %@", error]);

    // Exercise the complete iOS 18-26 path, not just the filename matcher:
    // the exact PingFangUI package member must materialize under the virtual
    // FontServices target while the legacy PingFang member is ignored.
    NSData *collection =
        [NSData dataWithContentsOfFile:@"/System/Library/Fonts/AppleSDGothicNeo.ttc"];
    FMRequire(collection.length > 0, @"TTC compatibility fixture is missing");
    NSDictionary *modernCatalog = FMCatalogForPaths(@[
        @{
            @"path" : @"FontServicesCorePrivate/PingFangUI.ttc",
            @"sha256" : @"2222222222222222222222222222222222222222222222222222222222222222",
        },
    ], @"TEST-MODERN-BUILD", &error);
    FMRequire(modernCatalog != nil,
              [NSString stringWithFormat:@"modern catalog fixture failed: %@", error]);
    NSString *modernChinesePath =
        [temporaryRoot stringByAppendingPathComponent:@"dual-version-chinese.zip"];
    FMRequire(FMWriteStoredZIP(modernChinesePath, @[
        @{ @"name" : @"Package/PingFang.ttc", @"data" : collection },
        @{ @"name" : @"Package/PingFangUI.ttc", @"data" : collection },
    ], &error), @"dual-version Chinese ZIP fixture write failed");
    NSDictionary *modernChinesePreview =
        FMAnalyzeFontPackageAtPath(modernChinesePath, modernCatalog, &error);
    FMRequire(modernChinesePreview != nil &&
                  [modernChinesePreview[@"matchedTargetCount"] unsignedIntegerValue] == 1 &&
                  [modernChinesePreview[@"compatibilityAlternateSourceCount"] unsignedIntegerValue] == 1 &&
                  [modernChinesePreview[@"matches"][0][@"selectedSourceRelativePath"]
                      isEqual:@"Package/PingFangUI.ttc"] &&
                  [modernChinesePreview[@"matches"][0][@"targetRelativePath"]
                      isEqual:@"FontServicesCorePrivate/PingFangUI.ttc"],
              [NSString stringWithFormat:@"modern Chinese preview failed: %@",
                                         modernChinesePreview ?: error]);
    NSString *modernProfilesRoot =
        [temporaryRoot stringByAppendingPathComponent:@"modern-profiles"];
    NSDictionary *modernSaved = FMImportFontPackageProfile(
        modernChinesePath, modernCatalog, modernProfilesRoot,
        @"import-pingfang-ui", @"PingFang UI", &error);
    FMRequire(modernSaved != nil &&
                  [modernSaved[@"replacementCount"] unsignedIntegerValue] == 1,
              [NSString stringWithFormat:@"modern Chinese save failed: %@", error]);
    NSDictionary *modernDetails = FMFontProfileDetailsAtRoot(
        modernProfilesRoot, @"import-pingfang-ui", @"TEST-MODERN-BUILD", &error);
    NSString *modernReplacement = [modernProfilesRoot stringByAppendingPathComponent:
        @"import-pingfang-ui/replacements/replacement-0001.ttc"];
    FMRequire(modernDetails != nil &&
                  [modernDetails[@"relativePaths"]
                      isEqual:@[ @"FontServicesCorePrivate/PingFangUI.ttc" ]] &&
                  [[NSData dataWithContentsOfFile:modernReplacement] isEqual:collection],
              @"PingFangUI bytes were not saved under the FontServices target");
    FMRequire(FMDeleteFontProfileAtRoot(modernProfilesRoot, @"import-pingfang-ui",
                                        @"TEST-MODERN-BUILD", &error),
              [NSString stringWithFormat:@"modern Chinese Profile delete failed: %@", error]);

    NSString *legacyOnlyPath =
        [temporaryRoot stringByAppendingPathComponent:@"legacy-chinese-only.zip"];
    FMRequire(FMWriteStoredZIP(legacyOnlyPath, @[
        @{ @"name" : @"Package/PingFang.ttc", @"data" : collection },
    ], &error), @"legacy-only Chinese ZIP fixture write failed");
    NSDictionary *legacyOnlyPreview =
        FMAnalyzeFontPackageAtPath(legacyOnlyPath, modernCatalog, &error);
    FMRequire(legacyOnlyPreview != nil &&
                  [legacyOnlyPreview[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                  [legacyOnlyPreview[@"compatibilityAlternateSourceCount"] unsignedIntegerValue] == 1 &&
                  FMImportFontPackageProfile(
                      legacyOnlyPath, modernCatalog, modernProfilesRoot,
                      @"import-legacy-only", @"Legacy Only", nil) == nil,
              @"legacy-only Chinese content was not blocked on the modern target");

    NSString *conflictPath = [temporaryRoot stringByAppendingPathComponent:@"conflict.zip"];
    FMRequire(FMWriteStoredZIP(conflictPath, @[
        @{ @"name" : @"Package/Core/Geneva.ttf", @"data" : geneva },
        @{ @"name" : @"Package/CoreUI/Geneva.ttf", @"data" : symbol },
    ], &error), @"conflict ZIP fixture write failed");
    NSDictionary *conflict = FMAnalyzeFontPackageAtPath(conflictPath, catalog, &error);
    FMRequire(conflict != nil &&
                  [conflict[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                  [conflict[@"conflictTargetCount"] unsignedIntegerValue] == 1,
              @"different same-name archive fonts were not reported as a conflict");
    FMRequire(FMImportFontPackageProfile(conflictPath, catalog, profilesRoot,
                                         @"import-conflict", @"Conflict", nil) == nil,
              @"conflicting package was saved as a Profile");

    NSString *traversalPath = [temporaryRoot stringByAppendingPathComponent:@"traversal.zip"];
    FMRequire(FMWriteStoredZIP(traversalPath, @[
        @{ @"name" : @"../Geneva.ttf", @"data" : geneva },
    ], &error), @"traversal ZIP fixture write failed");
    FMRequire(FMAnalyzeFontPackageAtPath(traversalPath, catalog, nil) == nil,
              @"archive analyzer accepted a traversal font path");

    NSString *symlinkPath = [temporaryRoot stringByAppendingPathComponent:@"symlink.zip"];
    FMRequire(FMWriteStoredZIP(symlinkPath, @[
        @{
            @"name" : @"Package/Geneva.ttf",
            @"data" : [@"../Core/Geneva.ttf" dataUsingEncoding:NSUTF8StringEncoding],
            @"mode" : @(S_IFLNK | 0777),
        },
    ], &error), @"symlink ZIP fixture write failed");
    FMRequire(FMAnalyzeFontPackageAtPath(symlinkPath, catalog, nil) == nil,
              @"archive analyzer accepted a symlink font entry");
}

static void FMRunSampleProbe(NSString *hashListPath,
                             NSArray<NSString *> *archivePaths,
                             NSString *temporaryRoot) {
    NSError *error = nil;
    NSArray *pathHashes = FMReadHashList(hashListPath, &error);
    FMRequire(pathHashes.count > 0,
              [NSString stringWithFormat:@"could not read Stock hash list: %@", error]);
    NSDictionary *catalog = FMCatalogForPaths(pathHashes, @"21D61", &error);
    FMRequire(catalog != nil,
              [NSString stringWithFormat:@"could not build Stock catalog: %@", error]);
    NSString *profilesRoot = [temporaryRoot stringByAppendingPathComponent:@"sample-profiles"];
    NSUInteger sampleIndex = 0;
    for (NSString *archivePath in archivePaths) {
        NSDictionary *preview = FMAnalyzeFontPackageAtPath(archivePath, catalog, &error);
        FMRequire(preview != nil,
                  [NSString stringWithFormat:@"sample preview failed for %@: %@",
                                             archivePath, error]);
        NSDictionary *summary = @{
            @"packageName" : preview[@"packageName"],
            @"packageFontFileCount" : preview[@"packageFontFileCount"],
            @"matchedTargetCount" : preview[@"matchedTargetCount"],
            @"unmatchedSourceCount" : preview[@"unmatchedSourceCount"],
            @"conflictTargetCount" : preview[@"conflictTargetCount"],
            @"deduplicatedSourceCount" : preview[@"deduplicatedSourceCount"],
            @"invalidFontEntryCount" : preview[@"invalidFontEntryCount"],
            @"ignoredEntryCount" : preview[@"ignoredEntryCount"],
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:summary
                                                       options:NSJSONWritingSortedKeys
                                                         error:&error];
        FMRequire(json != nil, @"sample summary JSON failed");
        printf("%s\n", [[[NSString alloc] initWithData:json
                                               encoding:NSUTF8StringEncoding] UTF8String]);

        NSString *profileID = [NSString stringWithFormat:@"import-sample-%lu",
                                                          (unsigned long)sampleIndex++];
        NSDictionary<NSString *, id> *saved = FMImportFontPackageProfile(
            archivePath, catalog, profilesRoot, profileID,
            preview[@"packageName"], &error);
        FMRequire(saved != nil &&
                      [saved[@"replacementCount"] isEqual:preview[@"matchedTargetCount"]],
                  [NSString stringWithFormat:@"sample Profile save failed for %@: %@",
                                             archivePath, error]);
        NSDictionary<NSString *, id> *details = FMFontProfileDetailsAtRoot(
            profilesRoot, profileID, @"21D61", &error);
        FMRequire([details[@"replacementCount"] isEqual:preview[@"matchedTargetCount"]],
                  @"sample Profile details do not match preview");
        FMRequire(FMDeleteFontProfileAtRoot(profilesRoot, profileID, @"21D61", &error),
                  @"sample Profile cleanup failed");
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *temporaryRoot = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"font-package-analyzer-%@",
                                                                      NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        FMRequire([NSFileManager.defaultManager createDirectoryAtPath:temporaryRoot
                                          withIntermediateDirectories:NO
                                                           attributes:nil
                                                                error:&error],
                  [NSString stringWithFormat:@"could not create test directory: %@", error]);
        @try {
            FMRunImportSessionTests(temporaryRoot);
            FMRunFixtureTests(temporaryRoot);
            if (argc >= 3) {
                NSString *hashListPath = [NSString stringWithUTF8String:argv[1]];
                NSMutableArray<NSString *> *archivePaths = [NSMutableArray array];
                for (int index = 2; index < argc; index++) {
                    [archivePaths addObject:[NSString stringWithUTF8String:argv[index]]];
                }
                FMRunSampleProbe(hashListPath, archivePaths, temporaryRoot);
            }
        } @finally {
            [NSFileManager.defaultManager removeItemAtPath:temporaryRoot error:nil];
        }
        printf("PASS: controlled import cleanup, package analysis, and inactive Profile persistence\n");
    }
    return 0;
}
