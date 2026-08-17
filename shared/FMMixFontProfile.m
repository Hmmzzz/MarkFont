#import "FMMixFontProfile.h"

#import "FMLocalization.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMFileStore.h"
#import "FMFontProfileStore.h"
#import "FMFontSlotCatalog.h"

NSString *const FMMixFontProfileErrorDomain = @"com.hmmzzz.fontmanager.mixprofile";

static BOOL FMMixFail(NSError **error,
                      FMMixFontProfileErrorCode code,
                      NSString *message,
                      NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:message
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMMixFontProfileErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMMixProfileIDIsSafe(NSString *profileID) {
    if (![profileID isKindOfClass:NSString.class] ||
        ![profileID hasPrefix:@"import-mix-"]) {
        return NO;
    }
    NSDictionary *probe = @{
        @"schemaVersion" : @2,
        @"id" : profileID,
        @"name" : @"Profile",
        @"systemBuild" : @"BUILD",
        @"replacements" : @[],
    };
    return FMValidateProfileDocument(probe, nil);
}

// One merged replacement: enough identity to re-emit the Profile document and
// to locate the source bytes during materialization.
static NSDictionary<NSString *, id> *FMMixMergedEntry(
    NSString *relativePath,
    NSDictionary<NSString *, id> *replacement,
    NSString *sourceProfileID) {
    return @{
        @"relativePath" : relativePath,
        @"fontFileID" : replacement[@"fontFileID"],
        @"sha256" : replacement[@"sha256"],
        @"sourceFileName" : replacement[@"fileName"],
        @"sourceProfileID" : sourceProfileID,
    };
}

static BOOL FMMixEntryMatchesCatalog(
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *catalogByID,
    NSDictionary<NSString *, id> *replacement,
    NSString *relativePath,
    NSError **error) {
    NSDictionary<NSString *, id> *catalogFile = catalogByID[replacement[@"fontFileID"]];
    if (![catalogFile isKindOfClass:NSDictionary.class] ||
        ![catalogFile[@"relativePath"] isEqual:relativePath]) {
        return FMMixFail(error, FMMixFontProfileErrorInvalidProfile,
                         FMLocalized(@"来源方案与当前系统字体清单不匹配。"), nil);
    }
    return YES;
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
FMMixReplacementsByPath(NSDictionary<NSString *, id> *profile) {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *byPath =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *replacement in profile[@"replacements"]) {
        byPath[replacement[@"relativePath"]] = replacement;
    }
    return byPath;
}

// Shared merge core for the preview and the materializer. Slot schemes only
// contribute files inside their own slot; every remaining replacement comes
// from the fallback scheme. Paths the slot scheme lacks fall back to the
// fallback scheme, and anything neither provides stays Stock.
static BOOL FMMixBuildMerge(
    NSString *profilesRoot,
    NSDictionary<NSString *, id> *catalog,
    NSDictionary<NSString *, NSString *> *slotAssignments,
    NSString *fallbackProfileID,
    NSMutableArray<NSDictionary<NSString *, id> *> *merged,
    NSMutableArray<NSDictionary<NSString *, id> *> *slotSummaries,
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *sourceProfiles,
    NSString **fallbackName,
    NSUInteger *fallbackCount,
    NSError **error) {
    NSError *validationError = nil;
    if (profilesRoot.length == 0 ||
        !FMValidateFontCatalogDocument(catalog, &validationError) ||
        ![slotAssignments isKindOfClass:NSDictionary.class] ||
        (fallbackProfileID != nil &&
         (![fallbackProfileID isKindOfClass:NSString.class] ||
          fallbackProfileID.length == 0))) {
        return FMMixFail(error, FMMixFontProfileErrorInvalidInput,
                         FMLocalized(@"混搭配置或本机字体清单无效。"), validationError);
    }
    NSString *systemBuild = catalog[@"systemBuild"];

    // Every merged replacement must still resolve against the current-build
    // catalog, so a saved source scheme that no longer matches this build
    // fails here instead of at adoption time.
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *catalogByID =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *file in catalog[@"files"]) {
        catalogByID[file[@"id"]] = file;
    }

    NSArray<NSDictionary<NSString *, id> *> *resolvedSlots =
        FMResolvedFontSlotsForCatalog(catalog);
    NSMutableSet<NSString *> *knownSlotIDs = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *slot in resolvedSlots) {
        [knownSlotIDs addObject:slot[@"slotID"]];
    }
    for (NSString *slotID in slotAssignments) {
        id assignedProfileID = slotAssignments[slotID];
        if (![slotID isKindOfClass:NSString.class] ||
            ![assignedProfileID isKindOfClass:NSString.class] ||
            [(NSString *)assignedProfileID length] == 0 ||
            ![knownSlotIDs containsObject:slotID]) {
            return FMMixFail(error, FMMixFontProfileErrorInvalidInput,
                             FMLocalized(@"混搭配置里包含当前系统不支持的字体槽位。"),
                             nil);
        }
    }

    // Load every distinct source Profile once, in stable order.
    NSMutableArray<NSString *> *sourceIDs = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *slot in resolvedSlots) {
        NSString *profileID = slotAssignments[slot[@"slotID"]];
        if (profileID.length > 0 && ![sourceIDs containsObject:profileID]) {
            [sourceIDs addObject:profileID];
        }
    }
    if (fallbackProfileID.length > 0 && ![sourceIDs containsObject:fallbackProfileID]) {
        [sourceIDs addObject:fallbackProfileID];
    }
    for (NSString *profileID in sourceIDs) {
        NSError *loadError = nil;
        NSDictionary<NSString *, id> *profile =
            FMFontProfileStoreValidatedProfileAtRoot(profilesRoot, profileID,
                                                     systemBuild, &loadError);
        if (profile == nil) {
            return FMMixFail(error, FMMixFontProfileErrorInvalidProfile,
                             FMLocalized(@"找不到混搭所需的来源方案。"), loadError);
        }
        sourceProfiles[profileID] = profile;
    }

    NSMutableSet<NSString *> *claimedPaths = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *slotReplacedPaths =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *slot in resolvedSlots) {
        NSString *slotID = slot[@"slotID"];
        NSString *slotProfileID = slotAssignments[slotID];
        NSMutableArray<NSString *> *replacedPaths = [NSMutableArray array];
        if (slotProfileID.length > 0) {
            NSDictionary<NSString *, NSDictionary<NSString *, id> *> *byPath =
                FMMixReplacementsByPath(sourceProfiles[slotProfileID]);
            for (NSString *relativePath in slot[@"relativePaths"]) {
                if ([claimedPaths containsObject:relativePath]) continue;
                NSDictionary<NSString *, id> *replacement = byPath[relativePath];
                if (replacement == nil) continue;
                if (!FMMixEntryMatchesCatalog(catalogByID, replacement,
                                              relativePath, error)) {
                    return NO;
                }
                [merged addObject:FMMixMergedEntry(relativePath, replacement,
                                                   slotProfileID)];
                [claimedPaths addObject:relativePath];
                [replacedPaths addObject:relativePath];
            }
        }
        slotReplacedPaths[slotID] = replacedPaths;
    }

    *fallbackCount = 0;
    NSMutableSet<NSString *> *fallbackPaths = [NSMutableSet set];
    if (fallbackProfileID.length > 0) {
        NSDictionary<NSString *, id> *fallbackProfile = sourceProfiles[fallbackProfileID];
        *fallbackName = fallbackProfile[@"name"];
        for (NSDictionary<NSString *, id> *replacement in fallbackProfile[@"replacements"]) {
            NSString *relativePath = replacement[@"relativePath"];
            if ([claimedPaths containsObject:relativePath]) continue;
            if (!FMMixEntryMatchesCatalog(catalogByID, replacement,
                                          relativePath, error)) {
                return NO;
            }
            [merged addObject:FMMixMergedEntry(relativePath, replacement,
                                               fallbackProfileID)];
            [fallbackPaths addObject:relativePath];
            (*fallbackCount)++;
        }
    }

    for (NSDictionary<NSString *, id> *slot in resolvedSlots) {
        NSString *slotID = slot[@"slotID"];
        NSString *slotProfileID = slotAssignments[slotID];
        NSDictionary<NSString *, id> *slotProfile =
            slotProfileID.length > 0 ? sourceProfiles[slotProfileID] : nil;
        NSMutableArray<NSString *> *fallbackPathsForSlot = [NSMutableArray array];
        NSMutableArray<NSString *> *stockPathsForSlot = [NSMutableArray array];
        for (NSString *relativePath in slot[@"relativePaths"]) {
            if ([slotReplacedPaths[slotID] containsObject:relativePath]) {
                continue;
            }
            if ([fallbackPaths containsObject:relativePath]) {
                [fallbackPathsForSlot addObject:relativePath];
            } else {
                [stockPathsForSlot addObject:relativePath];
            }
        }
        [slotSummaries addObject:@{
            @"slotID" : slotID,
            @"name" : slot[@"name"],
            @"assignedProfileID" : slotProfileID ?: NSNull.null,
            @"assignedProfileName" : slotProfile[@"name"] ?: NSNull.null,
            @"replacedRelativePaths" : slotReplacedPaths[slotID] ?: @[],
            @"fallbackRelativePaths" : fallbackPathsForSlot,
            @"stockRelativePaths" : stockPathsForSlot,
        }];
    }
    return YES;
}

NSDictionary<NSString *, id> *FMMixFontProfilePreviewAtRoot(
    NSString *profilesRoot,
    NSDictionary<NSString *, id> *catalog,
    NSDictionary<NSString *, NSString *> *slotAssignments,
    NSString *fallbackProfileID,
    NSError **error) {
    NSMutableArray<NSDictionary<NSString *, id> *> *merged = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *slotSummaries = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *sourceProfiles =
        [NSMutableDictionary dictionary];
    NSString *fallbackName = nil;
    NSUInteger fallbackCount = 0;
    if (!FMMixBuildMerge(profilesRoot, catalog, slotAssignments, fallbackProfileID,
                         merged, slotSummaries, sourceProfiles, &fallbackName,
                         &fallbackCount, error)) {
        return nil;
    }
    return @{
        @"slots" : slotSummaries,
        @"fallbackProfileID" : fallbackProfileID ?: NSNull.null,
        @"fallbackProfileName" : fallbackName ?: NSNull.null,
        @"fallbackReplacementCount" : @(fallbackCount),
        @"replacementCount" : @(merged.count),
    };
}

static NSString *FMMixRecipeTimestamp(void) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:NSDate.date];
}

// Verifies one source replacement against its recorded SHA-256 and republishes
// it as a fresh, exclusive 0600 file inside the mix staging directory.
static BOOL FMMixStageReplacementFile(NSString *sourcePath,
                                      NSString *targetPath,
                                      NSString *expectedSHA256,
                                      NSError **error) {
    struct stat info = {0};
    if (lstat(sourcePath.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_size <= 0) {
        return FMMixFail(error, FMMixFontProfileErrorInvalidProfile,
                         FMLocalized(@"来源方案包含缺失或异常的字体文件。"), nil);
    }
    NSError *readError = nil;
    NSData *payload = [NSData dataWithContentsOfFile:sourcePath
                                             options:NSDataReadingMappedIfSafe
                                               error:&readError];
    if (payload == nil) {
        return FMMixFail(error, FMMixFontProfileErrorFilesystem,
                         FMLocalized(@"无法读取来源方案的字体文件。"), readError);
    }
    int descriptor = open(targetPath.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          0600);
    if (descriptor < 0) {
        NSError *underlying =
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return FMMixFail(error, FMMixFontProfileErrorFilesystem,
                         FMLocalized(@"无法在字体库中创建字体文件。"), underlying);
    }
    const uint8_t *cursor = payload.bytes;
    NSUInteger remaining = payload.length;
    BOOL success = YES;
    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            success = NO;
            break;
        }
        cursor += (NSUInteger)written;
        remaining -= (NSUInteger)written;
    }
    if (success && fsync(descriptor) != 0) success = NO;
    if (close(descriptor) != 0 && success) success = NO;
    if (!success) {
        unlink(targetPath.fileSystemRepresentation);
        return FMMixFail(error, FMMixFontProfileErrorFilesystem,
                         FMLocalized(@"无法完整写入字体库文件。"), nil);
    }
    NSError *hashError = nil;
    NSString *actualSHA256 = FMSHA256ForFileAtPath(targetPath, &hashError);
    if (actualSHA256 == nil) {
        unlink(targetPath.fileSystemRepresentation);
        return FMMixFail(error, FMMixFontProfileErrorFilesystem,
                         FMLocalized(@"无法校验来源方案的字体文件。"), hashError);
    }
    if (![actualSHA256 isEqual:expectedSHA256]) {
        unlink(targetPath.fileSystemRepresentation);
        return FMMixFail(error, FMMixFontProfileErrorInvalidProfile,
                         FMLocalized(@"来源方案的字体文件与记录不一致。"), nil);
    }
    return YES;
}

NSDictionary<NSString *, id> *FMCreateMixedFontProfileAtRoot(
    NSString *profilesRoot,
    NSDictionary<NSString *, id> *catalog,
    NSDictionary<NSString *, NSString *> *slotAssignments,
    NSString *fallbackProfileID,
    NSString *profileID,
    NSString *profileName,
    NSError **error) {
    NSString *name = [profileName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!FMMixProfileIDIsSafe(profileID) || name.length == 0 || name.length > 80) {
        FMMixFail(error, FMMixFontProfileErrorInvalidInput,
                  FMLocalized(@"混搭方案名称或标识无效。"), nil);
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *merged = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *slotSummaries = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *sourceProfiles =
        [NSMutableDictionary dictionary];
    NSString *fallbackName = nil;
    NSUInteger fallbackCount = 0;
    if (!FMMixBuildMerge(profilesRoot, catalog, slotAssignments, fallbackProfileID,
                         merged, slotSummaries, sourceProfiles, &fallbackName,
                         &fallbackCount, error)) {
        return nil;
    }
    if (merged.count == 0) {
        FMMixFail(error, FMMixFontProfileErrorEmptyResult,
                  FMLocalized(@"混搭结果没有任何字体文件，请至少为一个槽位或兜底选择方案。"),
                  nil);
        return nil;
    }
    if (!FMEnsureFontProfileStoreRoot(profilesRoot, error)) return nil;

    NSString *finalDirectory = [profilesRoot stringByAppendingPathComponent:profileID];
    struct stat finalInfo = {0};
    errno = 0;
    if (lstat(finalDirectory.fileSystemRepresentation, &finalInfo) == 0 || errno != ENOENT) {
        FMMixFail(error, FMMixFontProfileErrorInvalidInput,
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
        FMMixFail(error, FMMixFontProfileErrorFilesystem,
                  FMLocalized(@"无法创建混搭方案暂存目录。"), directoryError);
        return nil;
    }
    NSString *replacementsDirectory =
        [temporaryDirectory stringByAppendingPathComponent:@"replacements"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:replacementsDirectory
                                  withIntermediateDirectories:NO
                                                   attributes:@{ NSFilePosixPermissions : @0700 }
                                                        error:&directoryError]) {
        [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
        FMMixFail(error, FMMixFontProfileErrorFilesystem,
                  FMLocalized(@"无法创建混搭方案文件目录。"), directoryError);
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *replacements =
        [NSMutableArray arrayWithCapacity:merged.count];
    NSUInteger index = 0;
    for (NSDictionary<NSString *, id> *entry in merged) {
        NSString *extension = ((NSString *)entry[@"sourceFileName"]).pathExtension;
        if (extension.length == 0) {
            [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
            FMMixFail(error, FMMixFontProfileErrorInvalidProfile,
                      FMLocalized(@"来源方案的字体文件名无效。"), nil);
            return nil;
        }
        NSString *targetFileName = [NSString stringWithFormat:@"replacement-%04lu.%@",
                                    (unsigned long)index, extension];
        NSString *sourcePath = [[[profilesRoot
            stringByAppendingPathComponent:entry[@"sourceProfileID"]]
            stringByAppendingPathComponent:@"replacements"]
            stringByAppendingPathComponent:entry[@"sourceFileName"]];
        NSString *targetPath =
            [replacementsDirectory stringByAppendingPathComponent:targetFileName];
        NSError *copyError = nil;
        if (!FMMixStageReplacementFile(sourcePath, targetPath, entry[@"sha256"],
                                       &copyError)) {
            [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
            if (error != NULL) *error = copyError;
            return nil;
        }
        [replacements addObject:@{
            @"fontFileID" : entry[@"fontFileID"],
            @"relativePath" : entry[@"relativePath"],
            @"fileName" : targetFileName,
            @"sha256" : entry[@"sha256"],
        }];
        index++;
    }

    NSMutableDictionary<NSString *, id> *recipeSlots = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *summary in slotSummaries) {
        NSString *slotProfileID = [summary[@"assignedProfileID"] isKindOfClass:NSString.class]
            ? summary[@"assignedProfileID"]
            : nil;
        if (slotProfileID == nil) continue;
        recipeSlots[summary[@"slotID"]] = @{
            @"profileID" : slotProfileID,
            @"name" : summary[@"assignedProfileName"],
        };
    }
    NSMutableDictionary<NSString *, id> *recipe = [@{
        @"schemaVersion" : @1,
        @"type" : @"mix",
        @"createdAt" : FMMixRecipeTimestamp(),
        @"slots" : recipeSlots,
    } mutableCopy];
    recipe[@"fallback"] = fallbackProfileID.length > 0
        ? @{ @"profileID" : fallbackProfileID, @"name" : fallbackName ?: @"" }
        : NSNull.null;

    NSDictionary<NSString *, id> *profile = @{
        @"schemaVersion" : @2,
        @"id" : profileID,
        @"name" : name,
        @"systemBuild" : catalog[@"systemBuild"],
        @"replacements" : replacements,
        @"mixRecipe" : recipe,
    };
    NSError *profileError = nil;
    NSString *temporaryProfilePath =
        [temporaryDirectory stringByAppendingPathComponent:@"profile.json"];
    if (!FMValidateProfileDocument(profile, &profileError) ||
        !FMWriteJSONObjectAtomically(profile, temporaryProfilePath, 0600,
                                     &profileError)) {
        [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
        FMMixFail(error, FMMixFontProfileErrorInvalidProfile,
                  FMLocalized(@"无法生成完整的混搭方案。"), profileError);
        return nil;
    }

    NSError *moveError = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:temporaryDirectory
                                               toPath:finalDirectory
                                                error:&moveError]) {
        [NSFileManager.defaultManager removeItemAtPath:temporaryDirectory error:nil];
        FMMixFail(error, FMMixFontProfileErrorFilesystem,
                  FMLocalized(@"无法把混搭方案存入字体库。"), moveError);
        return nil;
    }
    return @{
        @"id" : profileID,
        @"name" : name,
        @"replacementCount" : @(replacements.count),
        @"slotReplacementCount" : @(replacements.count - fallbackCount),
        @"fallbackReplacementCount" : @(fallbackCount),
    };
}
