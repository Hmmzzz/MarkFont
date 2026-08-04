#import "FMProfileAdoptionValidator.h"

#import <errno.h>
#import <limits.h>
#import <sys/stat.h>

#import "FMDataModel.h"
#import "FMFileStore.h"

NSString *const FMProfileAdoptionValidatorErrorDomain =
    @"com.hmmzzz.fontmanager.profile-adoption-validator";

typedef NS_ENUM(NSInteger, FMProfileAdoptionValidatorErrorCode) {
    FMProfileAdoptionValidatorErrorInvalidInput = 1,
    FMProfileAdoptionValidatorErrorInvalidProfile = 2,
    FMProfileAdoptionValidatorErrorCatalogMismatch = 3,
    FMProfileAdoptionValidatorErrorFilesystem = 4,
    FMProfileAdoptionValidatorErrorHashMismatch = 5,
};

static BOOL FMAdoptionFail(NSError **error,
                           FMProfileAdoptionValidatorErrorCode code,
                           NSString *description,
                           NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMProfileAdoptionValidatorErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMAdoptionProfileIDIsSafe(NSString *profileID) {
    if (![profileID isKindOfClass:NSString.class] ||
        ![profileID hasPrefix:@"import-"]) {
        return NO;
    }
    NSDictionary *probe = @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"id" : profileID,
        @"name" : @"Profile",
        @"systemBuild" : @"BUILD",
        @"replacements" : @[],
    };
    return FMValidateProfileDocument(probe, nil);
}

static BOOL FMAdoptionDirectoryNameIsSafe(NSString *directoryName) {
    if (![directoryName isKindOfClass:NSString.class] || directoryName.length == 0 ||
        directoryName.length > 180 || directoryName.isAbsolutePath ||
        directoryName.pathComponents.count != 1 ||
        ![directoryName.lastPathComponent isEqual:directoryName] ||
        [directoryName isEqual:@"."] || [directoryName isEqual:@".."]) {
        return NO;
    }
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"._-"];
    return [directoryName rangeOfCharacterFromSet:allowed.invertedSet].location ==
        NSNotFound;
}

static BOOL FMAdoptionRequireDirectory(NSString *path,
                                       NSString *purpose,
                                       NSError **error) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)) {
        return YES;
    }
    int savedError = errno != 0 ? errno : ENOTDIR;
    NSError *underlying =
        [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil];
    return FMAdoptionFail(
        error, FMProfileAdoptionValidatorErrorFilesystem,
        [NSString stringWithFormat:@"%@ is not an ordinary directory.", purpose],
        underlying);
}

static BOOL FMAdoptionRequireExactEntries(NSString *directory,
                                          NSSet<NSString *> *expected,
                                          NSString *purpose,
                                          NSError **error) {
    NSError *contentsError = nil;
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory
                                                           error:&contentsError];
    if (entries == nil || ![[NSSet setWithArray:entries] isEqual:expected]) {
        return FMAdoptionFail(
            error, FMProfileAdoptionValidatorErrorInvalidProfile,
            [NSString stringWithFormat:@"%@ contains missing or unexpected entries.", purpose],
            contentsError);
    }
    return YES;
}

NSDictionary<NSString *, id> *FMCreateProfileAdoptionPreviewAtRoot(
    NSString *profilesRoot,
    NSString *profileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    return FMCreateProfileAdoptionPreviewAtDirectory(
        profilesRoot, profileID, profileID, systemBuild, catalog, error);
}

NSDictionary<NSString *, id> *FMCreateProfileAdoptionPreviewAtDirectory(
    NSString *profilesRoot,
    NSString *directoryName,
    NSString *profileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    NSError *validationError = nil;
    if (profilesRoot.length == 0 || systemBuild.length == 0 ||
        !FMAdoptionDirectoryNameIsSafe(directoryName) ||
        !FMAdoptionProfileIDIsSafe(profileID) ||
        !FMValidateFontCatalogDocument(catalog, &validationError) ||
        ![catalog[@"systemBuild"] isEqual:systemBuild]) {
        FMAdoptionFail(error, FMProfileAdoptionValidatorErrorInvalidInput,
                       @"Profile adoption inputs are invalid or build-mismatched.",
                       validationError);
        return nil;
    }

    NSString *profileDirectory = [profilesRoot stringByAppendingPathComponent:directoryName];
    NSString *profilePath = [profileDirectory stringByAppendingPathComponent:@"profile.json"];
    NSString *replacementsDirectory =
        [profileDirectory stringByAppendingPathComponent:@"replacements"];
    if (!FMAdoptionRequireDirectory(profilesRoot, @"Profile library", error) ||
        !FMAdoptionRequireDirectory(profileDirectory, @"Profile", error) ||
        !FMAdoptionRequireDirectory(replacementsDirectory, @"Profile replacements", error) ||
        !FMAdoptionRequireExactEntries(profileDirectory,
                                       [NSSet setWithArray:@[ @"profile.json", @"replacements" ]],
                                       @"Profile directory", error)) {
        return nil;
    }

    struct stat profileInfo = {0};
    if (lstat(profilePath.fileSystemRepresentation, &profileInfo) != 0 ||
        !S_ISREG(profileInfo.st_mode) || profileInfo.st_size <= 0) {
        FMAdoptionFail(error, FMProfileAdoptionValidatorErrorFilesystem,
                       @"Profile metadata is missing or is not a regular file.", nil);
        return nil;
    }

    NSError *readError = nil;
    id profileObject = FMReadJSONObjectAtPath(profilePath, &readError);
    if (![profileObject isKindOfClass:NSDictionary.class] ||
        !FMValidateProfileDocument(profileObject, &validationError)) {
        FMAdoptionFail(error, FMProfileAdoptionValidatorErrorInvalidProfile,
                       @"Profile metadata is invalid.", validationError ?: readError);
        return nil;
    }
    NSDictionary<NSString *, id> *profile = profileObject;
    NSArray<NSDictionary<NSString *, id> *> *replacements = profile[@"replacements"];
    NSString *profileName = profile[@"name"];
    if (![profile[@"id"] isEqual:profileID] ||
        ![profile[@"systemBuild"] isEqual:systemBuild] ||
        profileName.length == 0 || profileName.length > 80 || replacements.count == 0) {
        FMAdoptionFail(error, FMProfileAdoptionValidatorErrorInvalidProfile,
                       @"Profile identity, name, build, or replacement count is invalid.", nil);
        return nil;
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *catalogByID =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *file in catalog[@"files"]) {
        catalogByID[file[@"id"]] = file;
    }

    NSMutableSet<NSString *> *replacementFileNames = [NSMutableSet set];
    NSMutableArray<NSString *> *relativePaths = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *targets = [NSMutableArray array];
    unsigned long long totalBytes = 0;
    for (NSDictionary<NSString *, id> *replacement in replacements) {
        NSString *fileName = replacement[@"fileName"];
        NSString *relativePath = replacement[@"relativePath"];
        NSDictionary<NSString *, id> *catalogFile = catalogByID[replacement[@"fontFileID"]];
        if (catalogFile == nil ||
            ![catalogFile[@"relativePath"] isEqual:relativePath] ||
            ![catalogFile[@"fileName"] isEqual:relativePath.lastPathComponent] ||
            ![fileName.pathExtension.lowercaseString
                isEqual:relativePath.pathExtension.lowercaseString] ||
            [replacementFileNames containsObject:fileName]) {
            FMAdoptionFail(error, FMProfileAdoptionValidatorErrorCatalogMismatch,
                           @"A replacement does not match its current-build catalog target.",
                           nil);
            return nil;
        }

        NSString *replacementPath =
            [replacementsDirectory stringByAppendingPathComponent:fileName];
        struct stat fileInfo = {0};
        if (lstat(replacementPath.fileSystemRepresentation, &fileInfo) != 0 ||
            !S_ISREG(fileInfo.st_mode) || fileInfo.st_size <= 0) {
            FMAdoptionFail(error, FMProfileAdoptionValidatorErrorFilesystem,
                           @"A replacement is missing or is not a nonempty regular file.", nil);
            return nil;
        }
        unsigned long long fileBytes = (unsigned long long)fileInfo.st_size;
        if (ULLONG_MAX - totalBytes < fileBytes) {
            FMAdoptionFail(error, FMProfileAdoptionValidatorErrorInvalidProfile,
                           @"Replacement byte count overflowed.", nil);
            return nil;
        }

        NSError *hashError = nil;
        NSString *actualHash = FMSHA256ForFileAtPath(replacementPath, &hashError);
        if (![actualHash isEqual:replacement[@"sha256"]]) {
            FMAdoptionFail(error, FMProfileAdoptionValidatorErrorHashMismatch,
                           @"A replacement no longer matches its saved SHA-256.", hashError);
            return nil;
        }

        totalBytes += fileBytes;
        [replacementFileNames addObject:fileName];
        [relativePaths addObject:relativePath];
        [targets addObject:@{
            @"fontFileID" : replacement[@"fontFileID"],
            @"relativePath" : relativePath,
            @"fileName" : fileName,
            @"sha256" : actualHash,
            @"fileBytes" : @(fileBytes),
        }];
    }

    if (!FMAdoptionRequireExactEntries(replacementsDirectory, replacementFileNames,
                                       @"Profile replacements directory", error)) {
        return nil;
    }
    [relativePaths sortUsingSelector:@selector(compare:)];
    [targets sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                       NSDictionary *right) {
        return [left[@"relativePath"] compare:right[@"relativePath"]];
    }];
    NSString *profileHash = FMSHA256ForFileAtPath(profilePath, &readError);
    if (profileHash == nil) {
        FMAdoptionFail(error, FMProfileAdoptionValidatorErrorFilesystem,
                       @"Profile metadata could not be hashed.", readError);
        return nil;
    }

    return @{
        @"profileDocument" : profile,
        @"profileDirectory" : profileDirectory,
        @"profilePath" : profilePath,
        @"replacementsDirectory" : replacementsDirectory,
        @"profileID" : profileID,
        @"profileName" : profileName,
        @"profileJSONSHA256" : profileHash,
        @"replacementCount" : @(replacements.count),
        @"replacementBytes" : @(totalBytes),
        @"replacementFileNames" :
            [[replacementFileNames allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"relativePaths" : relativePaths,
        @"targets" : targets,
        @"readOnly" : @YES,
    };
}
