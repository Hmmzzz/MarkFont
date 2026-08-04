#import "FMFontPackageMatcher.h"

#import <CoreFoundation/CoreFoundation.h>

#import "FMDataModel.h"
#import "FMFontCatalog.h"

NSString *const FMFontPackageMatcherErrorDomain =
    @"com.hmmzzz.fontmanager.fontpackagematcher";

static NSError *FMMatcherError(NSString *description, NSError *underlying) {
    NSMutableDictionary *userInfo =
        [NSMutableDictionary dictionaryWithObject:description
                                           forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:FMFontPackageMatcherErrorDomain
                               code:1
                           userInfo:userInfo];
}

static BOOL FMMatcherIsJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL FMMatcherIsPositiveInteger(id value) {
    if (![value isKindOfClass:NSNumber.class] || FMMatcherIsJSONBoolean(value)) {
        return NO;
    }
    NSNumber *number = value;
    double raw = number.doubleValue;
    unsigned long long integer = number.unsignedLongLongValue;
    return raw > 0.0 && raw == (double)integer;
}

static BOOL FMMatcherIsLowercaseSHA256(id value) {
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] != 64) {
        return NO;
    }
    NSCharacterSet *hex =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [(NSString *)value rangeOfCharacterFromSet:hex.invertedSet].location ==
        NSNotFound;
}

NSDictionary<NSString *, id> *FMMatchFontPackageFilesToCatalog(
    NSArray<NSDictionary<NSString *, id> *> *packageFiles,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    NSError *validationError = nil;
    if (![packageFiles isKindOfClass:NSArray.class] || packageFiles.count == 0 ||
        !FMValidateFontCatalogDocument(catalog, &validationError)) {
        if (error != NULL) {
            *error = FMMatcherError(@"Package files or Stock catalog are invalid.",
                                    validationError);
        }
        return nil;
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *stockByName =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *stockFile in catalog[@"files"]) {
        stockByName[stockFile[@"fileName"]] = stockFile;
    }

    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary<NSString *, id> *> *>
        *packageByName = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *sourcePaths = [NSMutableSet set];
    for (id objectFile in packageFiles) {
        if (![objectFile isKindOfClass:NSDictionary.class]) {
            if (error != NULL) {
                *error = FMMatcherError(@"A package font entry is not a dictionary.", nil);
            }
            return nil;
        }
        NSDictionary<NSString *, id> *file = objectFile;
        NSString *relativePath = file[@"relativePath"];
        NSError *pathError = nil;
        if (!FMValidateRelativePath(relativePath, &pathError) ||
            !FMIsSupportedFontCatalogRelativePath(relativePath) ||
            !FMMatcherIsLowercaseSHA256(file[@"sha256"]) ||
            !FMMatcherIsPositiveInteger(file[@"fileSize"]) ||
            [sourcePaths containsObject:relativePath]) {
            if (error != NULL) {
                *error = FMMatcherError(@"A package font entry is invalid or duplicated.",
                                        pathError);
            }
            return nil;
        }
        [sourcePaths addObject:relativePath];
        NSString *fileName = relativePath.lastPathComponent;
        NSMutableArray *group = packageByName[fileName];
        if (group == nil) {
            group = [NSMutableArray array];
            packageByName[fileName] = group;
        }
        [group addObject:@{
            @"relativePath" : relativePath,
            @"sha256" : file[@"sha256"],
            @"fileSize" : file[@"fileSize"],
        }];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *matches = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *unmatched = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *conflicts = [NSMutableArray array];
    NSUInteger deduplicatedSourceCount = 0;

    NSArray<NSString *> *sortedNames =
        [packageByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *fileName in sortedNames) {
        NSArray<NSDictionary<NSString *, id> *> *sources =
            [packageByName[fileName]
                sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                                NSDictionary *right) {
            return [left[@"relativePath"] compare:right[@"relativePath"]];
        }];
        NSDictionary<NSString *, id> *target = stockByName[fileName];
        if (target == nil) {
            for (NSDictionary<NSString *, id> *source in sources) {
                [unmatched addObject:@{
                    @"fileName" : fileName,
                    @"sourceRelativePath" : source[@"relativePath"],
                    @"sourceSHA256" : source[@"sha256"],
                    @"fileSize" : source[@"fileSize"],
                }];
            }
            continue;
        }

        NSSet<NSString *> *hashes = [NSSet setWithArray:[sources valueForKey:@"sha256"]];
        if (hashes.count != 1) {
            NSMutableArray *alternatives = [NSMutableArray arrayWithCapacity:sources.count];
            for (NSDictionary<NSString *, id> *source in sources) {
                [alternatives addObject:@{
                    @"sourceRelativePath" : source[@"relativePath"],
                    @"sourceSHA256" : source[@"sha256"],
                    @"fileSize" : source[@"fileSize"],
                }];
            }
            [conflicts addObject:@{
                @"fileName" : fileName,
                @"targetFileID" : target[@"id"],
                @"targetRelativePath" : target[@"relativePath"],
                @"alternatives" : alternatives,
            }];
            continue;
        }

        NSDictionary<NSString *, id> *selected = sources.firstObject;
        NSMutableArray<NSString *> *duplicatePaths = [NSMutableArray array];
        for (NSUInteger index = 1; index < sources.count; index++) {
            [duplicatePaths addObject:sources[index][@"relativePath"]];
        }
        deduplicatedSourceCount += duplicatePaths.count;
        [matches addObject:@{
            @"fileName" : fileName,
            @"targetFileID" : target[@"id"],
            @"targetRelativePath" : target[@"relativePath"],
            @"selectedSourceRelativePath" : selected[@"relativePath"],
            @"sourceSHA256" : selected[@"sha256"],
            @"fileSize" : selected[@"fileSize"],
            @"duplicateSourceRelativePaths" : duplicatePaths,
        }];
    }

    return @{
        @"schemaVersion" : @1,
        @"matchingMode" : @"stockFileName",
        @"systemBuild" : catalog[@"systemBuild"],
        @"packageFontFileCount" : @(packageFiles.count),
        @"matchedTargetCount" : @(matches.count),
        @"unmatchedSourceCount" : @(unmatched.count),
        @"conflictTargetCount" : @(conflicts.count),
        @"deduplicatedSourceCount" : @(deduplicatedSourceCount),
        @"matches" : matches,
        @"unmatched" : unmatched,
        @"conflicts" : conflicts,
    };
}
