#import "FMFontCatalog.h"

#import <CommonCrypto/CommonDigest.h>

#import "FMDataModel.h"

NSString *const FMFontCatalogErrorDomain = @"com.hmmzzz.fontmanager.fontcatalog";
NSString *const FMFontCatalogFontServicesCorePrivatePrefix =
    @"FontServicesCorePrivate";

static NSError *FMCatalogError(NSString *description, NSError *underlying) {
    NSMutableDictionary *userInfo =
        [NSMutableDictionary dictionaryWithObject:description
                                           forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:FMFontCatalogErrorDomain code:1 userInfo:userInfo];
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

static NSString *FMFontFileIdentifier(NSString *relativePath) {
    NSData *data = [relativePath dataUsingEncoding:NSUTF8StringEncoding];
    return [@"font-file-" stringByAppendingString:FMSHA256HexForData(data)];
}

BOOL FMIsSupportedFontCatalogRelativePath(NSString *relativePath) {
    NSError *pathError = nil;
    if (![relativePath isKindOfClass:NSString.class] ||
        !FMValidateRelativePath(relativePath, &pathError)) {
        return NO;
    }
    NSString *extension = relativePath.pathExtension.lowercaseString;
    return [extension isEqual:@"ttf"] || [extension isEqual:@"ttc"] ||
           [extension isEqual:@"otf"];
}

NSArray<NSString *> *FMFontCatalogPreviewRelativePaths(
    NSDictionary<NSString *, id> *catalog) {
    if (!FMValidateFontCatalogDocument(catalog, nil)) return @[];

    NSMutableDictionary<NSString *, NSString *> *relativePathByFileName =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *file in catalog[@"files"]) {
        relativePathByFileName[file[@"fileName"]] = file[@"relativePath"];
    }

    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:2];
    // Prefer the modern name only when it actually exists in this build's
    // verified Stock snapshot; legacy Stock exposes PingFang.ttc instead.
    NSString *chinesePath = relativePathByFileName[@"PingFangUI.ttc"] ?:
        relativePathByFileName[@"PingFang.ttc"];
    if (chinesePath != nil) [paths addObject:chinesePath];

    NSString *latinPath = relativePathByFileName[@"SFUI.ttf"];
    if (latinPath != nil && ![paths containsObject:latinPath]) {
        [paths addObject:latinPath];
    }
    return paths;
}

NSDictionary<NSString *, id> *FMCreateFontCatalogFromManifest(
    NSDictionary<NSString *, id> *manifest,
    NSString *systemBuild,
    NSString *sourceManifestSHA256,
    NSError **error) {
    return FMCreateFontCatalogFromManifests(
        manifest, nil, systemBuild, sourceManifestSHA256, nil, error);
}

static BOOL FMAppendManifestToCatalog(
    NSDictionary<NSString *, id> *manifest,
    NSString *prefix,
    NSMutableArray<NSDictionary<NSString *, id> *> *files,
    NSMutableArray<NSString *> *excludedRegularPaths,
    NSMutableSet<NSString *> *fileNames,
    NSUInteger *regularFileCount,
    NSError **error) {
    for (NSDictionary<NSString *, id> *entry in manifest[@"entries"]) {
        if (![entry[@"type"] isEqual:@"regular"]) continue;
        (*regularFileCount)++;

        NSString *sourceRelativePath = entry[@"relativePath"];
        NSString *relativePath = prefix.length > 0
            ? [prefix stringByAppendingPathComponent:sourceRelativePath]
            : sourceRelativePath;
        if (!FMIsSupportedFontCatalogRelativePath(relativePath)) {
            [excludedRegularPaths addObject:relativePath];
            continue;
        }

        NSString *fileName = relativePath.lastPathComponent;
        if ([fileNames containsObject:fileName]) {
            if (error != NULL) {
                *error = FMCatalogError(
                    @"Stock contains duplicate filenames; filename matching is ambiguous.",
                    nil);
            }
            return NO;
        }
        [fileNames addObject:fileName];
        [files addObject:@{
            @"id" : FMFontFileIdentifier(relativePath),
            @"fileName" : fileName,
            @"relativePath" : relativePath,
            @"stockSHA256" : entry[@"sha256"],
            @"fileSize" : entry[@"size"],
        }];
    }
    return YES;
}

NSDictionary<NSString *, id> *FMCreateFontCatalogFromManifests(
    NSDictionary<NSString *, id> *primaryManifest,
    NSDictionary<NSString *, id> *fontServicesManifest,
    NSString *systemBuild,
    NSString *primaryManifestSHA256,
    NSString *fontServicesManifestSHA256,
    NSError **error) {
    NSError *validationError = nil;
    BOOL hasFontServices = fontServicesManifest != nil;
    BOOL fontServicesValid = !hasFontServices ||
        (FMValidateManifestDocument(fontServicesManifest, &validationError) &&
         fontServicesManifestSHA256.length == 64);
    if (!FMValidateManifestDocument(primaryManifest, &validationError) ||
        !fontServicesValid || systemBuild.length == 0 ||
        primaryManifestSHA256.length != 64) {
        if (error != NULL) {
            *error = FMCatalogError(@"Catalog inputs are invalid.", validationError);
        }
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *files = [NSMutableArray array];
    NSMutableArray<NSString *> *excludedRegularPaths = [NSMutableArray array];
    NSMutableSet<NSString *> *fileNames = [NSMutableSet set];
    NSUInteger regularFileCount = 0;

    if (!FMAppendManifestToCatalog(
            primaryManifest, nil, files, excludedRegularPaths, fileNames,
            &regularFileCount, error) ||
        (hasFontServices && !FMAppendManifestToCatalog(
            fontServicesManifest, FMFontCatalogFontServicesCorePrivatePrefix,
            files, excludedRegularPaths, fileNames, &regularFileCount, error))) {
        return nil;
    }
    if (files.count == 0) {
        if (error != NULL) {
            *error = FMCatalogError(@"The Stock manifest contains no supported font files.",
                                    nil);
        }
        return nil;
    }

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                     NSDictionary *right) {
        return [left[@"relativePath"] compare:right[@"relativePath"]];
    }];
    [excludedRegularPaths sortUsingSelector:@selector(compare:)];

    NSMutableDictionary<NSString *, id> *catalog = [@{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"catalogVersion" : hasFontServices ? @2 : @1,
        @"matchingMode" : @"stockFileName",
        @"systemBuild" : systemBuild,
        @"sourceLogicalPath" : @"/System/Library/Fonts",
        @"sourceManifestSHA256" : primaryManifestSHA256,
        @"generatedAt" : [formatter stringFromDate:NSDate.date],
        @"sourceRegularFileCount" : @(regularFileCount),
        @"excludedRegularPaths" : excludedRegularPaths,
        @"files" : files,
    } mutableCopy];
    if (hasFontServices) {
        catalog[@"supplementalSource"] = @{
            @"sourceLogicalPath" :
                @"/System/Library/PrivateFrameworks/FontServices.framework/CorePrivate",
            @"virtualPathPrefix" : FMFontCatalogFontServicesCorePrivatePrefix,
            @"sourceManifestSHA256" : fontServicesManifestSHA256,
        };
    }
    if (!FMValidateFontCatalogDocument(catalog, &validationError)) {
        if (error != NULL) {
            *error = FMCatalogError(@"Generated font catalog failed validation.",
                                    validationError);
        }
        return nil;
    }
    return catalog;
}
