#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

#import "FMFontCatalog.h"
#import "FMFontPackageAnalyzer.h"
#import "FMFontPackageContentRefinement.h"
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

static void FMAppendBE16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[] = { (uint8_t)(value >> 8), (uint8_t)(value & 0xFF) };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void FMAppendBE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {
        (uint8_t)(value >> 24), (uint8_t)(value >> 16),
        (uint8_t)(value >> 8), (uint8_t)(value & 0xFF),
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void FMAppendUTF16BE(NSMutableData *data, NSString *string) {
    for (NSUInteger index = 0; index < string.length; index++) {
        FMAppendBE16(data, [string characterAtIndex:index]);
    }
}

// Minimal single-face TrueType font accepted by CoreText: parameterized
// PostScript name, cmap maps U+FF0C to glyph 1, and glyph 1 carries the
// parameterized advance so the content probe measures it directly.
static NSData *FMEmitMinimalTrueTypeFont(NSString *postScriptName,
                                         uint16_t commaAdvance) {
    NSMutableData *head = [NSMutableData data];
    FMAppendBE32(head, 0x00010000);  // version
    FMAppendBE32(head, 0x00010000);  // fontRevision
    FMAppendBE32(head, 0);           // checkSumAdjustment
    FMAppendBE32(head, 0x5F0F3CF5);  // magicNumber
    FMAppendBE16(head, 0);           // flags
    FMAppendBE16(head, 1000);        // unitsPerEm
    FMAppendBE32(head, 0); FMAppendBE32(head, 0);  // created
    FMAppendBE32(head, 0); FMAppendBE32(head, 0);  // modified
    FMAppendBE16(head, 0); FMAppendBE16(head, 0);  // xMin yMin
    FMAppendBE16(head, 1000); FMAppendBE16(head, 1000);  // xMax yMax
    FMAppendBE16(head, 0);           // macStyle
    FMAppendBE16(head, 8);           // lowestRecPPEM
    FMAppendBE16(head, 2);           // fontDirectionHint
    FMAppendBE16(head, 0);           // indexToLocFormat (short)
    FMAppendBE16(head, 0);           // glyphDataFormat

    NSMutableData *hhea = [NSMutableData data];
    FMAppendBE32(hhea, 0x00010000);
    FMAppendBE16(hhea, 800); FMAppendBE16(hhea, (uint16_t)-200); FMAppendBE16(hhea, 0);
    FMAppendBE16(hhea, 1000);        // advanceWidthMax
    FMAppendBE16(hhea, 0); FMAppendBE16(hhea, 0); FMAppendBE16(hhea, 1000);
    FMAppendBE16(hhea, 1); FMAppendBE16(hhea, 0); FMAppendBE16(hhea, 0);
    for (NSUInteger index = 0; index < 4; index++) FMAppendBE16(hhea, 0);
    FMAppendBE16(hhea, 0);           // metricDataFormat
    FMAppendBE16(hhea, 2);           // numberOfHMetrics

    NSMutableData *maxp = [NSMutableData data];
    FMAppendBE32(maxp, 0x00010000);
    FMAppendBE16(maxp, 2);           // numGlyphs
    for (NSUInteger index = 0; index < 13; index++) FMAppendBE16(maxp, 0);

    NSMutableData *hmtx = [NSMutableData data];
    FMAppendBE16(hmtx, 500); FMAppendBE16(hmtx, 0);
    FMAppendBE16(hmtx, commaAdvance); FMAppendBE16(hmtx, 0);

    NSMutableData *cmap = [NSMutableData data];
    FMAppendBE16(cmap, 0); FMAppendBE16(cmap, 1);
    FMAppendBE16(cmap, 3); FMAppendBE16(cmap, 1); FMAppendBE32(cmap, 12);
    FMAppendBE16(cmap, 4); FMAppendBE16(cmap, 32); FMAppendBE16(cmap, 0);
    FMAppendBE16(cmap, 4); FMAppendBE16(cmap, 4); FMAppendBE16(cmap, 1); FMAppendBE16(cmap, 0);
    FMAppendBE16(cmap, 0xFF0C); FMAppendBE16(cmap, 0xFFFF);  // endCode
    FMAppendBE16(cmap, 0);                                    // reservedPad
    FMAppendBE16(cmap, 0xFF0C); FMAppendBE16(cmap, 0xFFFF);  // startCode
    FMAppendBE16(cmap, 0x00F5); FMAppendBE16(cmap, 0x0001);  // idDelta -> glyphs 1, 0
    FMAppendBE16(cmap, 0); FMAppendBE16(cmap, 0);

    NSMutableData *glyf = [NSMutableData data];
    FMAppendBE16(glyf, 0);           // numberOfContours = 0
    FMAppendBE16(glyf, 0); FMAppendBE16(glyf, (uint16_t)-200);
    FMAppendBE16(glyf, 300); FMAppendBE16(glyf, 0);

    NSMutableData *loca = [NSMutableData data];
    FMAppendBE16(loca, 0); FMAppendBE16(loca, 0); FMAppendBE16(loca, 5);

    NSArray<NSNumber *> *nameIDs = @[ @1, @2, @4, @6 ];
    NSString *familyName = [postScriptName componentsSeparatedByString:@"-"].firstObject;
    NSArray<NSString *> *nameValues = @[ familyName, @"Regular",
                                         postScriptName, postScriptName ];
    NSMutableData *name = [NSMutableData data];
    FMAppendBE16(name, 0); FMAppendBE16(name, (uint16_t)nameIDs.count);
    FMAppendBE16(name, (uint16_t)(6 + 12 * nameIDs.count));
    NSUInteger stringOffset = 0;
    NSMutableArray<NSData *> *nameStrings = [NSMutableArray array];
    for (NSUInteger index = 0; index < nameIDs.count; index++) {
        NSMutableData *value = [NSMutableData data];
        FMAppendUTF16BE(value, nameValues[index]);
        [nameStrings addObject:value];
        FMAppendBE16(name, 3); FMAppendBE16(name, 1); FMAppendBE16(name, 0x409);
        FMAppendBE16(name, nameIDs[index].unsignedShortValue);
        FMAppendBE16(name, (uint16_t)value.length);
        FMAppendBE16(name, (uint16_t)stringOffset);
        stringOffset += value.length;
    }
    for (NSData *value in nameStrings) [name appendData:value];

    NSMutableData *post = [NSMutableData data];
    FMAppendBE32(post, 0x00030000);
    FMAppendBE32(post, 0);
    FMAppendBE16(post, (uint16_t)-100); FMAppendBE16(post, 50);
    FMAppendBE32(post, 0);
    for (NSUInteger index = 0; index < 4; index++) FMAppendBE32(post, 0);

    NSMutableData *os2 = [NSMutableData data];
    FMAppendBE16(os2, 4); FMAppendBE16(os2, 500); FMAppendBE16(os2, 400);
    FMAppendBE16(os2, 5); FMAppendBE16(os2, 0);
    for (NSUInteger index = 0; index < 8; index++) FMAppendBE16(os2, 0);
    FMAppendBE16(os2, 50); FMAppendBE16(os2, 250); FMAppendBE16(os2, 0);
    for (NSUInteger index = 0; index < 10; index++) [os2 appendBytes:"\0" length:1];
    for (NSUInteger index = 0; index < 4; index++) FMAppendBE32(os2, 0);
    [os2 appendBytes:"TEST" length:4];
    FMAppendBE16(os2, 0x0040); FMAppendBE16(os2, 0x2C); FMAppendBE16(os2, 0xFF0C);
    FMAppendBE16(os2, 800); FMAppendBE16(os2, (uint16_t)-200); FMAppendBE16(os2, 0);
    FMAppendBE16(os2, 800); FMAppendBE16(os2, 200);
    FMAppendBE32(os2, 0); FMAppendBE32(os2, 0);
    FMAppendBE16(os2, 0); FMAppendBE16(os2, 700);
    FMAppendBE16(os2, 0); FMAppendBE16(os2, 0x20); FMAppendBE16(os2, 1);

    NSArray<NSDictionary<NSString *, id> *> *tables = @[
        @{ @"tag" : @"OS/2", @"data" : os2 },
        @{ @"tag" : @"cmap", @"data" : cmap },
        @{ @"tag" : @"glyf", @"data" : glyf },
        @{ @"tag" : @"head", @"data" : head },
        @{ @"tag" : @"hhea", @"data" : hhea },
        @{ @"tag" : @"hmtx", @"data" : hmtx },
        @{ @"tag" : @"loca", @"data" : loca },
        @{ @"tag" : @"maxp", @"data" : maxp },
        @{ @"tag" : @"name", @"data" : name },
        @{ @"tag" : @"post", @"data" : post },
    ];
    NSUInteger tableCount = tables.count;
    NSUInteger entrySelector = 3;
    NSUInteger searchRange = 16 << entrySelector;
    NSMutableData *font = [NSMutableData data];
    FMAppendBE32(font, 0x00010000);
    FMAppendBE16(font, (uint16_t)tableCount);
    FMAppendBE16(font, (uint16_t)searchRange);
    FMAppendBE16(font, (uint16_t)entrySelector);
    FMAppendBE16(font, (uint16_t)(tableCount * 16 - searchRange));
    NSUInteger offset = 12 + 16 * tableCount;
    NSMutableData *body = [NSMutableData data];
    for (NSDictionary<NSString *, id> *table in tables) {
        NSData *data = table[@"data"];
        [font appendBytes:[table[@"tag"] UTF8String] length:4];
        FMAppendBE32(font, 0);
        FMAppendBE32(font, (uint32_t)(offset + body.length));
        FMAppendBE32(font, (uint32_t)data.length);
        [body appendData:data];
        while (body.length % 4 != 0) [body appendBytes:"\0" length:1];
    }
    [font appendData:body];
    return font;
}

static NSString *FMFixtureSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = { 0 };
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
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
    // FontServices target while distinct PingFang bytes remain targetless.
    NSData *modernCollection =
        [NSData dataWithContentsOfFile:@"/System/Library/Fonts/AppleSDGothicNeo.ttc"];
    NSData *legacyCollection = geneva;
    FMRequire(modernCollection.length > 0 &&
                  ![modernCollection isEqual:legacyCollection],
              @"distinct Chinese-role font fixtures are missing");
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
        @{ @"name" : @"Package/PingFang.ttc", @"data" : legacyCollection },
        @{ @"name" : @"Package/PingFangUI.ttc", @"data" : modernCollection },
    ], &error), @"dual-version Chinese ZIP fixture write failed");
    NSDictionary *modernChinesePreview =
        FMAnalyzeFontPackageAtPath(modernChinesePath, modernCatalog, &error);
    FMRequire(modernChinesePreview != nil &&
                  [modernChinesePreview[@"matchedTargetCount"] unsignedIntegerValue] == 1 &&
                  [modernChinesePreview[@"otherSystemVersionSourceCount"] unsignedIntegerValue] == 1 &&
                  [modernChinesePreview[@"matches"][0][@"selectedSourceRelativePath"]
                      isEqual:@"Package/PingFangUI.ttc"] &&
                  [modernChinesePreview[@"matches"][0][@"targetRelativePath"]
                      isEqual:@"FontServicesCorePrivate/PingFangUI.ttc"] &&
                  [[NSSet setWithArray:
                      [modernChinesePreview[@"otherSystemVersionSources"][0] allKeys]]
                      isEqual:[NSSet setWithArray:@[
                          @"fileName", @"sourceRelativePath"
                      ]]],
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
                  [[NSData dataWithContentsOfFile:modernReplacement]
                      isEqual:modernCollection] &&
                  ![[NSData dataWithContentsOfFile:modernReplacement]
                      isEqual:legacyCollection],
              @"legacy PingFang bytes crossed into the PingFangUI target");
    FMRequire(FMDeleteFontProfileAtRoot(modernProfilesRoot, @"import-pingfang-ui",
                                        @"TEST-MODERN-BUILD", &error),
              [NSString stringWithFormat:@"modern Chinese Profile delete failed: %@", error]);

    NSString *legacyOnlyPath =
        [temporaryRoot stringByAppendingPathComponent:@"legacy-chinese-only.zip"];
    FMRequire(FMWriteStoredZIP(legacyOnlyPath, @[
        @{ @"name" : @"Package/PingFang.ttc", @"data" : legacyCollection },
    ], &error), @"legacy-only Chinese ZIP fixture write failed");
    NSDictionary *legacyOnlyPreview =
        FMAnalyzeFontPackageAtPath(legacyOnlyPath, modernCatalog, &error);
    FMRequire(legacyOnlyPreview != nil &&
                  [legacyOnlyPreview[@"matchedTargetCount"] unsignedIntegerValue] == 0 &&
                  [legacyOnlyPreview[@"otherSystemVersionSourceCount"] unsignedIntegerValue] == 1 &&
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

static void FMRunContentSelectionTests(NSString *temporaryRoot) {
    NSError *error = nil;
    NSData *tight = FMEmitMinimalTrueTypeFont(@"PingFangSC-Regular", 216);
    NSData *wide = FMEmitMinimalTrueTypeFont(@"PingFangSC-Regular", 900);
    NSData *other = FMEmitMinimalTrueTypeFont(@"SomeOtherFont", 500);
    FMRequire(tight.length > 0 && wide.length > 0 && other.length > 0,
              @"content-selection font fixtures could not be emitted");

    NSDictionary *tightProbe = FMProbeFontDataForContentSelection(tight);
    NSDictionary *wideProbe = FMProbeFontDataForContentSelection(wide);
    NSDictionary *otherProbe = FMProbeFontDataForContentSelection(other);
    FMRequire([tightProbe[@"hasLegacyPingFangRegular"] boolValue] &&
                  fabs([tightProbe[@"commaAdvanceRatio"] doubleValue] - 0.216) < 0.001,
              @"tight fixture probe did not report the comma advance ratio");
    FMRequire([wideProbe[@"hasLegacyPingFangRegular"] boolValue] &&
                  fabs([wideProbe[@"commaAdvanceRatio"] doubleValue] - 0.9) < 0.001,
              @"wide fixture probe did not report the comma advance ratio");
    FMRequire(otherProbe != nil &&
                  ![otherProbe[@"hasLegacyPingFangRegular"] boolValue],
              @"foreign face fixture unexpectedly qualified as a PingFang candidate");

    NSDictionary *legacyCatalog = FMCatalogForPaths(@[
        @{
            @"path" : @"LanguageSupport/PingFang.ttc",
            @"sha256" : @"1111111111111111111111111111111111111111111111111111111111111111",
        },
    ], @"TEST-BUILD", &error);
    FMRequire(legacyCatalog != nil,
              [NSString stringWithFormat:@"legacy catalog fixture failed: %@", error]);
    NSDictionary *modernCatalog = FMCatalogForPaths(@[
        @{
            @"path" : @"FontServicesCorePrivate/PingFangUI.ttc",
            @"sha256" : @"1111111111111111111111111111111111111111111111111111111111111111",
        },
    ], @"TEST-BUILD", &error);
    FMRequire(modernCatalog != nil,
              [NSString stringWithFormat:@"modern catalog fixture failed: %@", error]);

    NSString *tightSHA = FMFixtureSHA256(tight);

    // Two candidates under different filenames: the punctuation-tuned
    // variant must replace the exact-name match automatically.
    NSString *dualPath =
        [temporaryRoot stringByAppendingPathComponent:@"content-selection-dual.zip"];
    FMRequire(FMWriteStoredZIP(dualPath, @[
        @{ @"name" : @"PingFang.ttc", @"data" : wide },
        @{ @"name" : @"iOS17专用PingFang.ttc", @"data" : tight },
    ], &error), @"content-selection dual ZIP fixture write failed");
    NSDictionary *dual = FMAnalyzeFontPackageAtPath(dualPath, legacyCatalog, &error);
    FMRequire(dual != nil,
              [NSString stringWithFormat:@"content-selection dual preview failed: %@", error]);
    FMRequire([dual[@"matchedTargetCount"] integerValue] == 1 &&
                  [dual[@"unmatchedSourceCount"] integerValue] == 1 &&
                  [dual[@"conflictTargetCount"] integerValue] == 0,
              @"content-selection dual counts are wrong");
    NSDictionary *dualMatch = dual[@"matches"][0];
    FMRequire([dualMatch[@"selectedSourceRelativePath"]
                  isEqual:@"iOS17专用PingFang.ttc"] &&
                  [dualMatch[@"sourceSHA256"] isEqual:tightSHA] &&
                  [dualMatch[@"selectionReason"]
                      isEqual:FMFontContentSelectionReasonLegacyChinesePunctuationCompact],
              @"content-selection did not pick the punctuation-tight variant");
    FMRequire([dual[@"unmatched"][0][@"sourceRelativePath"] isEqual:@"PingFang.ttc"] &&
                  [dual[@"unmatched"][0][@"sourceSHA256"] isEqual:FMFixtureSHA256(wide)],
              @"displaced exact-name source was not reported as unmatched");
    FMRequire([dual[@"contentSelection"][@"candidates"] count] == 2 &&
                  [dual[@"contentSelection"][@"selectedSourceRelativePath"]
                      isEqual:@"iOS17专用PingFang.ttc"],
              @"content-selection summary is missing candidates");

    // The displaced package must still materialize the tight bytes only.
    NSString *profilesRoot =
        [temporaryRoot stringByAppendingPathComponent:@"content-selection-profiles"];
    NSDictionary *saved = FMImportFontPackageProfile(
        dualPath, legacyCatalog, profilesRoot,
        @"import-content-dual", @"Content Dual", &error);
    FMRequire(saved != nil && [saved[@"replacementCount"] integerValue] == 1,
              [NSString stringWithFormat:@"content-selection Profile save failed: %@", error]);
    NSDictionary *details = FMFontProfileDetailsAtRoot(
        profilesRoot, @"import-content-dual", @"TEST-BUILD", &error);
    NSString *materializedPath =
        details[@"filePathByRelativePath"][@"LanguageSupport/PingFang.ttc"];
    NSData *materialized = materializedPath.length > 0
        ? [NSData dataWithContentsOfFile:materializedPath] : nil;
    FMRequire(materialized != nil && [materialized isEqual:tight],
              @"content-selection Profile did not persist the tight variant bytes");
    FMRequire(FMDeleteFontProfileAtRoot(profilesRoot, @"import-content-dual",
                                        @"TEST-BUILD", &error),
              @"content-selection Profile cleanup failed");

    // A package carrying only the differently named variant still imports.
    NSString *onlyPath =
        [temporaryRoot stringByAppendingPathComponent:@"content-selection-only.zip"];
    FMRequire(FMWriteStoredZIP(onlyPath, @[
        @{ @"name" : @"iOS17专用PingFang.ttc", @"data" : tight },
    ], &error), @"content-selection only ZIP fixture write failed");
    NSDictionary *only = FMAnalyzeFontPackageAtPath(onlyPath, legacyCatalog, &error);
    FMRequire(only != nil &&
                  [only[@"matchedTargetCount"] integerValue] == 1 &&
                  [only[@"unmatchedSourceCount"] integerValue] == 0 &&
                  [only[@"matches"][0][@"selectedSourceRelativePath"]
                      isEqual:@"iOS17专用PingFang.ttc"],
              @"lone differently named variant was not promoted to a match");

    // Modern layouts keep ignoring legacy-named content candidates.
    NSString *modernPath =
        [temporaryRoot stringByAppendingPathComponent:@"content-selection-modern.zip"];
    FMRequire(FMWriteStoredZIP(modernPath, @[
        @{ @"name" : @"PingFangUI.ttc", @"data" : wide },
        @{ @"name" : @"iOS17专用PingFang.ttc", @"data" : tight },
    ], &error), @"content-selection modern ZIP fixture write failed");
    NSDictionary *modern = FMAnalyzeFontPackageAtPath(modernPath, modernCatalog, &error);
    FMRequire(modern != nil &&
                  [modern[@"matchedTargetCount"] integerValue] == 1 &&
                  [modern[@"unmatchedSourceCount"] integerValue] == 1 &&
                  [modern[@"matches"][0][@"selectedSourceRelativePath"]
                      isEqual:@"PingFangUI.ttc"] &&
                  modern[@"matches"][0][@"selectionReason"] == nil &&
                  modern[@"contentSelection"] == nil,
              @"modern layout unexpectedly refined the legacy Chinese target");

    // Sources without the PingFangSC-Regular face never become candidates.
    NSString *foreignPath =
        [temporaryRoot stringByAppendingPathComponent:@"content-selection-foreign.zip"];
    FMRequire(FMWriteStoredZIP(foreignPath, @[
        @{ @"name" : @"PingFang.ttc", @"data" : wide },
        @{ @"name" : @"SomeOtherFont.ttf", @"data" : other },
    ], &error), @"content-selection foreign ZIP fixture write failed");
    NSDictionary *foreign = FMAnalyzeFontPackageAtPath(foreignPath, legacyCatalog, &error);
    FMRequire(foreign != nil &&
                  [foreign[@"matchedTargetCount"] integerValue] == 1 &&
                  [foreign[@"matches"][0][@"selectedSourceRelativePath"]
                      isEqual:@"PingFang.ttc"] &&
                  foreign[@"matches"][0][@"selectionReason"] == nil &&
                  foreign[@"contentSelection"] == nil,
              @"foreign unmatched font changed the exact-name selection");

    // When the exact-name source is already the tightest one, nothing changes.
    NSString *incumbentPath =
        [temporaryRoot stringByAppendingPathComponent:@"content-selection-incumbent.zip"];
    FMRequire(FMWriteStoredZIP(incumbentPath, @[
        @{ @"name" : @"PingFang.ttc", @"data" : tight },
        @{ @"name" : @"旧版PingFang.ttc", @"data" : wide },
    ], &error), @"content-selection incumbent ZIP fixture write failed");
    NSDictionary *incumbent =
        FMAnalyzeFontPackageAtPath(incumbentPath, legacyCatalog, &error);
    FMRequire(incumbent != nil &&
                  [incumbent[@"matchedTargetCount"] integerValue] == 1 &&
                  [incumbent[@"unmatchedSourceCount"] integerValue] == 1 &&
                  [incumbent[@"matches"][0][@"selectedSourceRelativePath"]
                      isEqual:@"PingFang.ttc"] &&
                  [incumbent[@"matches"][0][@"sourceSHA256"] isEqual:tightSHA] &&
                  incumbent[@"contentSelection"] == nil,
              @"tight exact-name incumbent was unexpectedly rewritten");

    // A differently named single font file also promotes through the probe.
    NSString *rawTightPath =
        [temporaryRoot stringByAppendingPathComponent:@"iOS17专用PingFang.ttc"];
    FMRequire([tight writeToFile:rawTightPath options:NSDataWritingAtomic
                            error:&error],
              @"raw tight font fixture write failed");
    NSDictionary *rawTight = FMAnalyzeFontPackageAtPath(rawTightPath, legacyCatalog, &error);
    FMRequire(rawTight != nil &&
                  [rawTight[@"matchedTargetCount"] integerValue] == 1 &&
                  [rawTight[@"unmatchedSourceCount"] integerValue] == 0 &&
                  [rawTight[@"matches"][0][@"selectedSourceRelativePath"]
                      isEqual:@"iOS17专用PingFang.ttc"],
              @"raw differently named variant was not promoted to a match");
    FMRequire(FMImportFontPackageProfile(
                  rawTightPath, legacyCatalog, profilesRoot,
                  @"import-raw-tight", @"Raw Tight", &error) != nil &&
                  FMDeleteFontProfileAtRoot(profilesRoot, @"import-raw-tight",
                                            @"TEST-BUILD", &error),
              @"raw tight variant did not round-trip through a Profile");

    // A single foreign font file without the PingFang face stays unimportable.
    NSString *rawForeignPath =
        [temporaryRoot stringByAppendingPathComponent:@"SomeOtherFont.ttf"];
    FMRequire([other writeToFile:rawForeignPath options:NSDataWritingAtomic
                            error:&error],
              @"raw foreign font fixture write failed");
    NSDictionary *rawForeign =
        FMAnalyzeFontPackageAtPath(rawForeignPath, legacyCatalog, &error);
    FMRequire(rawForeign != nil &&
                  [rawForeign[@"matchedTargetCount"] integerValue] == 0 &&
                  [rawForeign[@"unmatchedSourceCount"] integerValue] == 1,
              @"raw foreign font unexpectedly matched a Stock target");

    printf("PASS: legacy Chinese content selection picks the punctuation-optimized candidate\n");
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
            FMRunContentSelectionTests(temporaryRoot);
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
