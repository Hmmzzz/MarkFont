#import "FMFontProfileStore.h"

#import "FMLocalization.h"

#import <CoreText/CoreText.h>
#import <errno.h>
#import <sys/stat.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMFontPackageAnalyzer.h"

NSString *const FMFontProfileStoreErrorDomain =
    @"com.hmmzzz.fontmanager.fontprofilestore";

typedef NS_ENUM(NSInteger, FMFontProfileStoreErrorCode) {
    FMFontProfileStoreErrorInvalidInput = 1,
    FMFontProfileStoreErrorFilesystem = 2,
    FMFontProfileStoreErrorInvalidProfile = 3,
    FMFontProfileStoreErrorConflict = 4,
};

static BOOL FMProfileStoreFail(NSError **error,
                               FMFontProfileStoreErrorCode code,
                               NSString *message,
                               NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:message
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMFontProfileStoreErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMProfileStoreIsSafeID(NSString *profileID) {
    if (![profileID isKindOfClass:NSString.class] || profileID.length == 0) return NO;
    NSDictionary *probe = @{
        @"schemaVersion" : @2,
        @"id" : profileID,
        @"name" : @"Profile",
        @"systemBuild" : @"BUILD",
        @"replacements" : @[],
    };
    return FMValidateProfileDocument(probe, nil);
}

static BOOL FMPreviewCandidateIsDecorative(NSString *relativePath) {
    NSString *path = relativePath.lowercaseString;
    return [path containsString:@"symbol"] ||
           [path containsString:@"emoji"] ||
           [path containsString:@"keycap"] ||
           [path containsString:@"phone"] ||
           [path containsString:@"lastresort"];
}

static NSInteger FMPreviewCandidateScore(NSString *relativePath, BOOL latin) {
    NSString *path = relativePath.lowercaseString;
    if (FMPreviewCandidateIsDecorative(path)) return NSIntegerMax;

    if (latin) {
        if ([path hasSuffix:@"core/sfui.ttf"]) return 0;
        if ([path hasSuffix:@"coreui/sfuisoft.ttc"]) return 10;
        if ([path containsString:@"helveticaneueinterface"]) return 20;
        if ([path containsString:@"helveticaneue"]) return 30;
        if ([path containsString:@"helvetica"]) return 40;
        if ([path containsString:@"arial"]) return 50;
        if ([path containsString:@"pingfang"]) return 60;
        if ([path hasSuffix:@"core/sfuiitalic.ttf"]) return 70;
        return 100;
    }

    if ([path hasSuffix:@"languagesupport/pingfang.ttc"] ||
        [path.lastPathComponent containsString:@"pingfang"]) return 0;
    if ([path hasSuffix:@"core/sfui.ttf"]) return 20;
    if ([path containsString:@"helveticaneueinterface"]) return 30;
    if ([path containsString:@"helveticaneue"]) return 40;
    if ([path containsString:@"helvetica"]) return 50;
    if ([path containsString:@"arial"]) return 60;
    return 100;
}

NSDictionary<NSString *, NSString *> *FMFontProfilePreviewPaths(
    NSDictionary<NSString *, id> *profile,
    NSString *replacementsDirectory) {
    if (![profile isKindOfClass:NSDictionary.class] ||
        ![replacementsDirectory isKindOfClass:NSString.class]) return @{};

    NSString *chinesePath = nil;
    NSString *latinPath = nil;
    NSInteger chineseScore = NSIntegerMax;
    NSInteger latinScore = NSIntegerMax;
    for (NSDictionary<NSString *, id> *replacement in profile[@"replacements"]) {
        NSString *relativePath = replacement[@"relativePath"];
        NSString *fileName = replacement[@"fileName"];
        if (![relativePath isKindOfClass:NSString.class] ||
            ![fileName isKindOfClass:NSString.class]) continue;

        NSInteger candidateChineseScore = FMPreviewCandidateScore(relativePath, NO);
        NSInteger candidateLatinScore = FMPreviewCandidateScore(relativePath, YES);
        if (candidateChineseScore == NSIntegerMax && candidateLatinScore == NSIntegerMax) {
            continue;
        }
        NSString *candidate = [replacementsDirectory stringByAppendingPathComponent:fileName];
        CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:candidate isDirectory:NO]);
        BOOL recognized = descriptors != NULL && CFArrayGetCount(descriptors) > 0;
        if (descriptors != NULL) CFRelease(descriptors);
        if (!recognized) continue;

        if (candidateChineseScore < chineseScore) {
            chineseScore = candidateChineseScore;
            chinesePath = candidate;
        }
        if (candidateLatinScore < latinScore) {
            latinScore = candidateLatinScore;
            latinPath = candidate;
        }
    }

    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];
    if (chinesePath != nil) paths[@"previewFontPath"] = chinesePath;
    if (latinPath != nil) paths[@"previewLatinFontPath"] = latinPath;
    return paths;
}

static NSString *FMProfileDirectory(NSString *profilesRoot, NSString *profileID) {
    return [profilesRoot stringByAppendingPathComponent:profileID];
}

static NSString *FMProfileDocumentPath(NSString *profilesRoot, NSString *profileID) {
    return [[FMProfileDirectory(profilesRoot, profileID)
        stringByAppendingPathComponent:@"profile.json"] copy];
}

static BOOL FMEnsureProfilesRoot(NSString *profilesRoot, NSError **error) {
    if (![profilesRoot isKindOfClass:NSString.class] || profilesRoot.length == 0 ||
        profilesRoot.lastPathComponent.length == 0) {
        return FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidInput,
                                  FMLocalized(@"字体库目录无效。"), nil);
    }
    struct stat info = {0};
    if (lstat(profilesRoot.fileSystemRepresentation, &info) == 0) {
        if (!S_ISDIR(info.st_mode)) {
            return FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                                      FMLocalized(@"字体库位置不是普通目录。"), nil);
        }
        return YES;
    }
    if (errno != ENOENT) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno
                                               userInfo:nil];
        return FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                                  FMLocalized(@"无法检查字体库目录。"), underlying);
    }
    NSError *directoryError = nil;
    BOOL created = [NSFileManager.defaultManager
        createDirectoryAtPath:profilesRoot
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions : @0700 }
                        error:&directoryError];
    if (!created || lstat(profilesRoot.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode)) {
        return FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                                  FMLocalized(@"无法创建字体库目录。"), directoryError);
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMLoadValidatedProfile(
    NSString *profilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    BOOL validateFiles,
    NSError **error) {
    if (!FMProfileStoreIsSafeID(profileID) || systemBuild.length == 0) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidInput,
                           FMLocalized(@"字体方案标识无效。"), nil);
        return nil;
    }
    NSString *profileDirectory = FMProfileDirectory(profilesRoot, profileID);
    struct stat directoryInfo = {0};
    if (lstat(profileDirectory.fileSystemRepresentation, &directoryInfo) != 0 ||
        !S_ISDIR(directoryInfo.st_mode)) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                           FMLocalized(@"找不到这个字体方案。"), nil);
        return nil;
    }
    NSError *readError = nil;
    id object = FMReadJSONObjectAtPath(FMProfileDocumentPath(profilesRoot, profileID),
                                       &readError);
    NSError *profileError = nil;
    if (![object isKindOfClass:NSDictionary.class] ||
        !FMValidateProfileDocument(object, &profileError)) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidProfile,
                           FMLocalized(@"字体方案数据无效。"), profileError ?: readError);
        return nil;
    }
    NSDictionary<NSString *, id> *profile = object;
    if (![profile[@"id"] isEqual:profileID] ||
        ![profile[@"systemBuild"] isEqual:systemBuild]) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidProfile,
                           FMLocalized(@"这个字体方案不属于当前系统版本。"), nil);
        return nil;
    }
    if (!validateFiles) return profile;

    NSString *replacementsDirectory =
        [profileDirectory stringByAppendingPathComponent:@"replacements"];
    struct stat replacementsInfo = {0};
    if (lstat(replacementsDirectory.fileSystemRepresentation, &replacementsInfo) != 0 ||
        !S_ISDIR(replacementsInfo.st_mode)) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidProfile,
                           FMLocalized(@"字体方案缺少替换文件目录。"), nil);
        return nil;
    }
    for (NSDictionary<NSString *, id> *replacement in profile[@"replacements"]) {
        NSString *path = [replacementsDirectory
            stringByAppendingPathComponent:replacement[@"fileName"]];
        struct stat fileInfo = {0};
        if (lstat(path.fileSystemRepresentation, &fileInfo) != 0 ||
            !S_ISREG(fileInfo.st_mode) || fileInfo.st_size <= 0) {
            FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidProfile,
                               FMLocalized(@"字体方案包含缺失或异常的字体文件。"), nil);
            return nil;
        }
    }
    return profile;
}

BOOL FMEnsureFontProfileStoreRoot(NSString *profilesRoot, NSError **error) {
    return FMEnsureProfilesRoot(profilesRoot, error);
}

NSDictionary<NSString *, id> *FMFontProfileStoreValidatedProfileAtRoot(
    NSString *profilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    NSError **error) {
    return FMLoadValidatedProfile(profilesRoot, profileID, systemBuild, YES, error);
}

NSArray<NSDictionary<NSString *, id> *> *FMListFontProfilesAtRoot(
    NSString *profilesRoot,
    NSString *systemBuild,
    NSError **error) {
    if (systemBuild.length == 0 || profilesRoot.length == 0) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidInput,
                           FMLocalized(@"当前系统字体库路径无效。"), nil);
        return nil;
    }
    struct stat rootInfo = {0};
    if (lstat(profilesRoot.fileSystemRepresentation, &rootInfo) != 0) {
        if (errno == ENOENT) return @[];
        FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                           FMLocalized(@"无法读取字体库目录。"), nil);
        return nil;
    }
    if (!S_ISDIR(rootInfo.st_mode)) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                           FMLocalized(@"字体库位置不是普通目录。"), nil);
        return nil;
    }
    NSError *contentsError = nil;
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:profilesRoot
                                                           error:&contentsError];
    if (entries == nil) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                           FMLocalized(@"无法列出字体库内容。"), contentsError);
        return nil;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *profiles = [NSMutableArray array];
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."] || !FMProfileStoreIsSafeID(entry)) continue;
        NSDictionary<NSString *, id> *profile =
            FMLoadValidatedProfile(profilesRoot, entry, systemBuild, YES, nil);
        if (profile == nil) continue;
        [profiles addObject:@{
            @"id" : profile[@"id"],
            @"name" : profile[@"name"],
            @"replacementCount" : @([profile[@"replacements"] count]),
            @"isMix" : @([profile[@"mixRecipe"] isKindOfClass:NSDictionary.class]),
        }];
    }
    [profiles sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                       NSDictionary *right) {
        NSComparisonResult nameResult =
            [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
        return nameResult == NSOrderedSame
            ? [left[@"id"] compare:right[@"id"]]
            : nameResult;
    }];
    return profiles;
}

NSDictionary<NSString *, id> *FMFontProfileDetailsAtRoot(
    NSString *profilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    NSError **error) {
    NSDictionary<NSString *, id> *profile =
        FMLoadValidatedProfile(profilesRoot, profileID, systemBuild, YES, error);
    if (profile == nil) return nil;
    NSString *replacementsDirectory = [FMProfileDirectory(profilesRoot, profileID)
        stringByAppendingPathComponent:@"replacements"];
    NSMutableArray<NSString *> *relativePaths = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *filePathByRelativePath =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *replacement in profile[@"replacements"]) {
        [relativePaths addObject:replacement[@"relativePath"]];
        filePathByRelativePath[replacement[@"relativePath"]] =
            [replacementsDirectory stringByAppendingPathComponent:replacement[@"fileName"]];
    }
    NSMutableDictionary<NSString *, id> *details = [@{
        @"id" : profile[@"id"],
        @"name" : profile[@"name"],
        @"relativePaths" : relativePaths,
        @"replacementCount" : @(relativePaths.count),
        @"filePathByRelativePath" : filePathByRelativePath,
    } mutableCopy];
    [details addEntriesFromDictionary:
        FMFontProfilePreviewPaths(profile, replacementsDirectory)];
    if ([profile[@"mixRecipe"] isKindOfClass:NSDictionary.class]) {
        details[@"isMix"] = @YES;
        details[@"mixRecipe"] = profile[@"mixRecipe"];
    }
    return details;
}

NSDictionary<NSString *, id> *FMImportFontPackageProfile(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *catalog,
    NSString *profilesRoot,
    NSString *profileID,
    NSString *profileName,
    NSError **error) {
    NSString *name = [profileName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!FMProfileStoreIsSafeID(profileID) || name.length == 0 || name.length > 80) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidInput,
                           FMLocalized(@"字体方案名称或标识无效。"), nil);
        return nil;
    }
    NSError *analysisError = nil;
    NSDictionary<NSString *, id> *preview =
        FMAnalyzeFontPackageAtPath(sourcePath, catalog, &analysisError);
    if (preview == nil) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidInput,
                           FMLocalized(@"无法重新验证这个字体包。"), analysisError);
        return nil;
    }
    if (![preview[@"systemBuild"] isEqual:catalog[@"systemBuild"]] ||
        [preview[@"matchedTargetCount"] unsignedIntegerValue] == 0) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidInput,
                           FMLocalized(@"字体包没有可保存到当前系统的字体。"), nil);
        return nil;
    }
    if ([preview[@"conflictTargetCount"] unsignedIntegerValue] != 0) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorConflict,
                           FMLocalized(@"字体包存在同名但内容不同的文件，请处理冲突后重新选择。"), nil);
        return nil;
    }
    if (!FMEnsureProfilesRoot(profilesRoot, error)) return nil;

    NSString *finalDirectory = FMProfileDirectory(profilesRoot, profileID);
    struct stat finalInfo = {0};
    if (lstat(finalDirectory.fileSystemRepresentation, &finalInfo) == 0 || errno != ENOENT) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidInput,
                           FMLocalized(@"字体库中已经存在同标识的方案。"), nil);
        return nil;
    }

    NSString *temporaryDirectory = [profilesRoot
        stringByAppendingPathComponent:[@".import-" stringByAppendingString:
            NSUUID.UUID.UUIDString.lowercaseString]];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:temporaryDirectory
                                  withIntermediateDirectories:NO
                                                   attributes:@{ NSFilePosixPermissions : @0700 }
                                                        error:&directoryError]) {
        FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                           FMLocalized(@"无法创建字体方案暂存目录。"), directoryError);
        return nil;
    }
    NSString *replacementsDirectory =
        [temporaryDirectory stringByAppendingPathComponent:@"replacements"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:replacementsDirectory
                                  withIntermediateDirectories:NO
                                                   attributes:@{ NSFilePosixPermissions : @0700 }
                                                        error:&directoryError]) {
        [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
        FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                           FMLocalized(@"无法创建字体方案文件目录。"), directoryError);
        return nil;
    }

    NSError *materializationError = nil;
    NSArray<NSDictionary<NSString *, id> *> *replacements =
        FMMaterializeFontPackageMatchesAtPath(sourcePath, preview,
                                              replacementsDirectory,
                                              &materializationError);
    NSDictionary<NSString *, id> *profile = replacements == nil ? nil : @{
        @"schemaVersion" : @2,
        @"id" : profileID,
        @"name" : name,
        @"systemBuild" : catalog[@"systemBuild"],
        @"replacements" : replacements,
    };
    NSError *profileError = materializationError;
    NSString *temporaryProfilePath =
        [temporaryDirectory stringByAppendingPathComponent:@"profile.json"];
    if (profile == nil || !FMValidateProfileDocument(profile, &profileError) ||
        !FMWriteJSONObjectAtomically(profile, temporaryProfilePath, 0600,
                                     &profileError)) {
        [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
        FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidProfile,
                           FMLocalized(@"无法生成完整的字体方案。"), profileError);
        return nil;
    }

    NSError *moveError = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:temporaryDirectory
                                               toPath:finalDirectory
                                                error:&moveError]) {
        [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
        FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                           FMLocalized(@"无法把字体方案存入字体库。"), moveError);
        return nil;
    }
    return @{
        @"id" : profileID,
        @"name" : name,
        @"replacementCount" : @(replacements.count),
        @"matchedTargetCount" : preview[@"matchedTargetCount"],
        @"unmatchedSourceCount" : preview[@"unmatchedSourceCount"],
        @"invalidFontEntryCount" : preview[@"invalidFontEntryCount"],
        @"deduplicatedSourceCount" : preview[@"deduplicatedSourceCount"],
    };
}

BOOL FMDeleteFontProfileAtRoot(NSString *profilesRoot,
                               NSString *profileID,
                               NSString *systemBuild,
                               NSError **error) {
    if (![profileID hasPrefix:@"import-"]) {
        return FMProfileStoreFail(error, FMFontProfileStoreErrorInvalidInput,
                                  FMLocalized(@"只能删除导入到字体库的方案。"), nil);
    }
    if (FMLoadValidatedProfile(profilesRoot, profileID, systemBuild, YES, error) == nil) {
        return NO;
    }
    NSError *removeError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:
            FMProfileDirectory(profilesRoot, profileID)
                                                   error:&removeError]) {
        return FMProfileStoreFail(error, FMFontProfileStoreErrorFilesystem,
                                  FMLocalized(@"无法删除这个字体方案。"), removeError);
    }
    return YES;
}
