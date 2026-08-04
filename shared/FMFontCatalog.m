#import "FMFontCatalog.h"

#import <CommonCrypto/CommonDigest.h>

#import "FMDataModel.h"

NSString *const FMFontCatalogErrorDomain = @"com.hmmzzz.fontmanager.fontcatalog";

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

NSDictionary<NSString *, id> *FMCreateFontCatalogFromManifest(
    NSDictionary<NSString *, id> *manifest,
    NSString *systemBuild,
    NSString *sourceManifestSHA256,
    NSError **error) {
    NSError *validationError = nil;
    if (!FMValidateManifestDocument(manifest, &validationError) ||
        systemBuild.length == 0 || sourceManifestSHA256.length != 64) {
        if (error != NULL) {
            *error = FMCatalogError(@"Catalog inputs are invalid.", validationError);
        }
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *files = [NSMutableArray array];
    NSMutableArray<NSString *> *excludedRegularPaths = [NSMutableArray array];
    NSMutableSet<NSString *> *fileNames = [NSMutableSet set];
    NSUInteger regularFileCount = 0;

    for (NSDictionary<NSString *, id> *entry in manifest[@"entries"]) {
        if (![entry[@"type"] isEqual:@"regular"]) {
            continue;
        }
        regularFileCount++;
        NSString *relativePath = entry[@"relativePath"];
        if (!FMIsSupportedFontCatalogRelativePath(relativePath)) {
            [excludedRegularPaths addObject:relativePath];
            continue;
        }

        NSString *fileName = relativePath.lastPathComponent;
        if ([fileNames containsObject:fileName]) {
            if (error != NULL) {
                *error = FMCatalogError(
                    @"Stock contains duplicate filenames; filename matching is ambiguous.", nil);
            }
            return nil;
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
    if (files.count == 0) {
        if (error != NULL) {
            *error = FMCatalogError(@"The Stock manifest contains no supported font files.",
                                    nil);
        }
        return nil;
    }

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSDictionary<NSString *, id> *catalog = @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"catalogVersion" : @1,
        @"matchingMode" : @"stockFileName",
        @"systemBuild" : systemBuild,
        @"sourceLogicalPath" : @"/System/Library/Fonts",
        @"sourceManifestSHA256" : sourceManifestSHA256,
        @"generatedAt" : [formatter stringFromDate:NSDate.date],
        @"sourceRegularFileCount" : @(regularFileCount),
        @"excludedRegularPaths" : excludedRegularPaths,
        @"files" : files,
    };
    if (!FMValidateFontCatalogDocument(catalog, &validationError)) {
        if (error != NULL) {
            *error = FMCatalogError(@"Generated font catalog failed validation.",
                                    validationError);
        }
        return nil;
    }
    return catalog;
}
