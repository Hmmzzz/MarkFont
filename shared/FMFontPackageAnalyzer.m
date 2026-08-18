#import "FMFontPackageAnalyzer.h"

#import "FMLocalization.h"

#import <CommonCrypto/CommonDigest.h>
#import <CoreText/CoreText.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMFontCatalog.h"
#import "FMFontPackageContentRefinement.h"
#import "FMFontPackageMatcher.h"

NSString *const FMFontPackageAnalyzerErrorDomain =
    @"com.hmmzzz.fontmanager.fontpackageanalyzer";

typedef NS_ENUM(NSInteger, FMFontPackageAnalyzerErrorCode) {
    FMFontPackageAnalyzerErrorInvalidInput = 1,
    FMFontPackageAnalyzerErrorUnsupportedArchive = 2,
    FMFontPackageAnalyzerErrorUnsafeArchive = 3,
    FMFontPackageAnalyzerErrorNoFonts = 4,
    FMFontPackageAnalyzerErrorMaterialization = 5,
};

static const unsigned long long FMMaximumArchiveBytes = 1024ULL * 1024ULL * 1024ULL;
static const unsigned long long FMMaximumFontBytes = 256ULL * 1024ULL * 1024ULL;
static const unsigned long long FMMaximumPackageFontBytes = 2ULL * 1024ULL * 1024ULL * 1024ULL;
static const NSUInteger FMMaximumArchiveEntries = 4096;

typedef struct archive FMArchive;
typedef struct archive_entry FMArchiveEntry;

typedef struct {
    void *handle;
    FMArchive *(*readNew)(void);
    int (*readSupportFilterAll)(FMArchive *archive);
    int (*readSupportFormatZip)(FMArchive *archive);
    int (*readOpenFilename)(FMArchive *archive, const char *path, size_t blockSize);
    int (*readNextHeader)(FMArchive *archive, FMArchiveEntry **entry);
    ssize_t (*readData)(FMArchive *archive, void *buffer, size_t length);
    int (*readDataSkip)(FMArchive *archive);
    const char *(*errorString)(FMArchive *archive);
    int (*readFree)(FMArchive *archive);
    const char *(*entryPathnameUTF8)(FMArchiveEntry *entry);
    const char *(*entryPathname)(FMArchiveEntry *entry);
    mode_t (*entryFiletype)(FMArchiveEntry *entry);
    int64_t (*entrySize)(FMArchiveEntry *entry);
    int (*entryIsEncrypted)(FMArchiveEntry *entry);
} FMArchiveAPI;

static NSError *FMAnalyzerError(FMFontPackageAnalyzerErrorCode code,
                                NSString *description,
                                NSError *underlying) {
    NSMutableDictionary *userInfo =
        [NSMutableDictionary dictionaryWithObject:description
                                           forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:FMFontPackageAnalyzerErrorDomain
                               code:code
                           userInfo:userInfo];
}

static BOOL FMAnalyzerFail(NSError **error,
                           FMFontPackageAnalyzerErrorCode code,
                           NSString *description,
                           NSError *underlying) {
    if (error != NULL) *error = FMAnalyzerError(code, description, underlying);
    return NO;
}

static BOOL FMLoadArchiveSymbol(void *handle,
                                const char *name,
                                void *destination,
                                size_t destinationSize) {
    void *symbol = dlsym(handle, name);
    if (symbol == NULL || destinationSize != sizeof(symbol)) return NO;
    memcpy(destination, &symbol, sizeof(symbol));
    return YES;
}

static BOOL FMLoadArchiveAPI(FMArchiveAPI *api, NSError **error) {
    memset(api, 0, sizeof(*api));
    api->handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_LOCAL | RTLD_LAZY);
    if (api->handle == NULL) {
        return FMAnalyzerFail(error, FMFontPackageAnalyzerErrorUnsupportedArchive,
                              FMLocalized(@"当前系统无法读取 ZIP 字体包。"), nil);
    }

#define FM_LOAD_ARCHIVE_SYMBOL(field, symbolName) \
    FMLoadArchiveSymbol(api->handle, symbolName, &api->field, sizeof(api->field))
    BOOL loaded =
        FM_LOAD_ARCHIVE_SYMBOL(readNew, "archive_read_new") &&
        FM_LOAD_ARCHIVE_SYMBOL(readSupportFilterAll, "archive_read_support_filter_all") &&
        FM_LOAD_ARCHIVE_SYMBOL(readSupportFormatZip, "archive_read_support_format_zip") &&
        FM_LOAD_ARCHIVE_SYMBOL(readOpenFilename, "archive_read_open_filename") &&
        FM_LOAD_ARCHIVE_SYMBOL(readNextHeader, "archive_read_next_header") &&
        FM_LOAD_ARCHIVE_SYMBOL(readData, "archive_read_data") &&
        FM_LOAD_ARCHIVE_SYMBOL(readDataSkip, "archive_read_data_skip") &&
        FM_LOAD_ARCHIVE_SYMBOL(errorString, "archive_error_string") &&
        FM_LOAD_ARCHIVE_SYMBOL(readFree, "archive_read_free") &&
        FM_LOAD_ARCHIVE_SYMBOL(entryPathnameUTF8, "archive_entry_pathname_utf8") &&
        FM_LOAD_ARCHIVE_SYMBOL(entryPathname, "archive_entry_pathname") &&
        FM_LOAD_ARCHIVE_SYMBOL(entryFiletype, "archive_entry_filetype") &&
        FM_LOAD_ARCHIVE_SYMBOL(entrySize, "archive_entry_size") &&
        FM_LOAD_ARCHIVE_SYMBOL(entryIsEncrypted, "archive_entry_is_encrypted");
#undef FM_LOAD_ARCHIVE_SYMBOL
    if (!loaded) {
        dlclose(api->handle);
        memset(api, 0, sizeof(*api));
        return FMAnalyzerFail(error, FMFontPackageAnalyzerErrorUnsupportedArchive,
                              FMLocalized(@"当前系统的 ZIP 读取组件不完整。"), nil);
    }
    return YES;
}

static void FMCloseArchiveAPI(FMArchiveAPI *api) {
    if (api->handle != NULL) dlclose(api->handle);
    memset(api, 0, sizeof(*api));
}

static NSString *FMArchiveFailureDescription(FMArchiveAPI *api,
                                             FMArchive *archive,
                                             NSString *fallback) {
    const char *archiveMessage = archive == NULL ? NULL : api->errorString(archive);
    if (archiveMessage == NULL) return fallback;
    NSString *message = [NSString stringWithUTF8String:archiveMessage];
    return message.length > 0
        ? [NSString stringWithFormat:@"%@（%@）", fallback, message]
        : fallback;
}

static NSString *FMNormalizedArchiveRelativePath(NSString *rawPath) {
    if (![rawPath isKindOfClass:NSString.class] || rawPath.length == 0 ||
        [rawPath rangeOfString:@"\0"].location != NSNotFound) {
        return nil;
    }
    NSString *path = [rawPath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if (path.isAbsolutePath) return nil;

    NSMutableArray<NSString *> *components = [NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length == 0 || [component isEqual:@"."]) continue;
        if ([component isEqual:@".."]) return nil;
        [components addObject:component];
    }
    if (components.count == 0) return nil;
    NSString *normalized = [components componentsJoinedByString:@"/"];
    return FMValidateRelativePath(normalized, nil) ? normalized : nil;
}

static BOOL FMArchivePathIsMetadata(NSString *relativePath) {
    NSArray<NSString *> *components = relativePath.pathComponents;
    if ([components containsObject:@"__MACOSX"]) return YES;
    return [relativePath.lastPathComponent hasPrefix:@"._"] ||
           [relativePath.lastPathComponent isEqual:@".DS_Store"];
}

static NSString *FMSHA256ForData(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex =
        [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static BOOL FMCoreTextRecognizesFontData(NSData *data) {
    CFArrayRef descriptors =
        CTFontManagerCreateFontDescriptorsFromData((__bridge CFDataRef)data);
    BOOL recognized = descriptors != NULL && CFArrayGetCount(descriptors) > 0;
    if (descriptors != NULL) CFRelease(descriptors);
    return recognized;
}

static NSData *FMReadArchiveFontData(FMArchiveAPI *api,
                                     FMArchive *archive,
                                     int64_t declaredSize,
                                     NSError **error) {
    NSMutableData *fontData = [NSMutableData dataWithCapacity:(NSUInteger)declaredSize];
    unsigned char buffer[64 * 1024];
    while (fontData.length <= FMMaximumFontBytes) {
        ssize_t readCount = api->readData(archive, buffer, sizeof(buffer));
        if (readCount == 0) break;
        if (readCount < 0) {
            if (error != NULL) {
                *error = FMAnalyzerError(
                    FMFontPackageAnalyzerErrorUnsupportedArchive,
                    FMArchiveFailureDescription(api, archive,
                                                FMLocalized(@"解码字体文件时发生错误。")), nil);
            }
            return nil;
        }
        if ((unsigned long long)fontData.length + (unsigned long long)readCount >
            FMMaximumFontBytes) {
            if (error != NULL) {
                *error = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                         FMLocalized(@"字体包中的字体文件过大。"), nil);
            }
            return nil;
        }
        [fontData appendBytes:buffer length:(NSUInteger)readCount];
    }
    if ((int64_t)fontData.length != declaredSize) {
        if (error != NULL) {
            *error = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsupportedArchive,
                                     FMLocalized(@"字体文件的实际大小与 ZIP 清单不一致。"), nil);
        }
        return nil;
    }
    return fontData;
}

static BOOL FMWriteNewFontPayload(NSData *data, NSString *path, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          0600);
    if (descriptor < 0) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno
                                               userInfo:nil];
        return FMAnalyzerFail(error, FMFontPackageAnalyzerErrorMaterialization,
                              FMLocalized(@"无法在字体库中创建字体文件。"), underlying);
    }
    const uint8_t *cursor = data.bytes;
    NSUInteger remaining = data.length;
    BOOL success = YES;
    int savedError = 0;
    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            savedError = written < 0 ? errno : EIO;
            success = NO;
            break;
        }
        cursor += (NSUInteger)written;
        remaining -= (NSUInteger)written;
    }
    if (success && fsync(descriptor) != 0) {
        savedError = errno;
        success = NO;
    }
    if (close(descriptor) != 0 && success) {
        savedError = errno;
        success = NO;
    }
    if (!success) {
        unlink(path.fileSystemRepresentation);
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:savedError
                                               userInfo:nil];
        return FMAnalyzerFail(error, FMFontPackageAnalyzerErrorMaterialization,
                              FMLocalized(@"无法完整写入字体库文件。"), underlying);
    }
    return YES;
}

static BOOL FMSyncFontPayloadDirectory(NSString *path, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno
                                               userInfo:nil];
        return FMAnalyzerFail(error, FMFontPackageAnalyzerErrorMaterialization,
                              FMLocalized(@"无法校验字体库目录。"), underlying);
    }
    int result = fsync(descriptor);
    int savedError = result == 0 ? 0 : errno;
    if (close(descriptor) != 0 && result == 0) savedError = errno;
    if (savedError == EINVAL || savedError == ENOTSUP) return YES;
    if (savedError != 0) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:savedError
                                               userInfo:nil];
        return FMAnalyzerFail(error, FMFontPackageAnalyzerErrorMaterialization,
                              FMLocalized(@"无法完成字体库目录同步。"), underlying);
    }
    return YES;
}

// Second-pass content probe for the refinement step. Re-reads only the
// requested entries; unreadable or changed entries simply produce no probe,
// which leaves the affected source unmatched. Selection is still protected by
// the save-time re-analysis and the materializer's SHA-256 verification.
static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
FMProbeArchiveFontContents(NSString *sourcePath, NSArray<NSString *> *probePaths) {
    if (probePaths.count == 0) return @{};
    NSSet<NSString *> *wanted = [NSSet setWithArray:probePaths];
    FMArchiveAPI api;
    if (!FMLoadArchiveAPI(&api, NULL)) return @{};
    FMArchive *archive = api.readNew();
    if (archive == NULL) {
        FMCloseArchiveAPI(&api);
        return @{};
    }
    static const int FMArchiveOK = 0;
    static const int FMArchiveEOF = 1;
    static const int FMArchiveWarn = -20;
    BOOL supportReady = api.readSupportFilterAll(archive) >= FMArchiveWarn &&
                        api.readSupportFormatZip(archive) >= FMArchiveWarn;
    if (!supportReady ||
        api.readOpenFilename(archive, sourcePath.fileSystemRepresentation,
                             64 * 1024) != FMArchiveOK) {
        api.readFree(archive);
        FMCloseArchiveAPI(&api);
        return @{};
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *probes =
        [NSMutableDictionary dictionary];
    NSUInteger entryCount = 0;
    while (probes.count < wanted.count) {
        FMArchiveEntry *entry = NULL;
        int nextResult = api.readNextHeader(archive, &entry);
        if (nextResult == FMArchiveEOF) break;
        if (nextResult != FMArchiveOK) break;
        if (++entryCount > FMMaximumArchiveEntries) break;

        const char *pathBytes = api.entryPathnameUTF8(entry);
        if (pathBytes == NULL) pathBytes = api.entryPathname(entry);
        NSString *rawPath =
            pathBytes == NULL ? nil : [NSString stringWithUTF8String:pathBytes];
        NSString *relativePath = FMNormalizedArchiveRelativePath(rawPath);
        if (relativePath == nil || ![wanted containsObject:relativePath] ||
            api.entryFiletype(entry) != S_IFREG ||
            api.entryIsEncrypted(entry) > 0) {
            api.readDataSkip(archive);
            continue;
        }
        int64_t declaredSize = api.entrySize(entry);
        if (declaredSize <= 0 ||
            (unsigned long long)declaredSize > FMMaximumFontBytes) {
            api.readDataSkip(archive);
            continue;
        }
        NSData *fontData = FMReadArchiveFontData(&api, archive, declaredSize, NULL);
        if (fontData == nil) break;
        NSDictionary<NSString *, id> *probe =
            FMProbeFontDataForContentSelection(fontData);
        if (probe != nil) probes[relativePath] = probe;
    }
    api.readFree(archive);
    FMCloseArchiveAPI(&api);
    return probes;
}

static NSDictionary<NSString *, id> *FMAnalyzeRawFont(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    NSString *fileName = sourcePath.lastPathComponent;
    if (!FMIsSupportedFontCatalogRelativePath(fileName)) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                       FMLocalized(@"请选择 ZIP、TTF、TTC 或 OTF 字体文件。"), nil);
        return nil;
    }
    NSError *readError = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [NSFileManager.defaultManager attributesOfItemAtPath:sourcePath error:&readError];
    unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
    if (attributes == nil || fileSize == 0 || fileSize > FMMaximumFontBytes) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                       FMLocalized(@"字体文件大小无效或超过 256 MB。"), readError);
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:sourcePath
                                         options:NSDataReadingMappedIfSafe
                                           error:&readError];
    if (data == nil || !FMCoreTextRecognizesFontData(data)) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                       FMLocalized(@"这个文件不是可识别的字体。"), readError);
        return nil;
    }
    NSDictionary *matching = FMMatchFontPackageFilesToCatalog(@[
        @{
            @"relativePath" : fileName,
            @"sha256" : FMSHA256ForData(data),
            @"fileSize" : @(data.length),
        }
    ], catalog, error);
    if (matching == nil) return nil;
    matching = FMRefineLegacyChineseTargetSelection(
        matching,
        [FMContentSelectionProbeRelativePaths(matching, catalog)
            containsObject:fileName]
            ? @{fileName : FMProbeFontDataForContentSelection(data) ?: @{}}
            : @{},
        catalog);
    NSMutableDictionary *result = [matching mutableCopy];
    result[@"packageName"] = fileName.stringByDeletingPathExtension;
    result[@"sourceKind"] = @"fontFile";
    result[@"archiveEntryCount"] = @1;
    result[@"ignoredEntryCount"] = @0;
    result[@"invalidFontEntryCount"] = @0;
    result[@"invalidFontEntries"] = @[];
    result[@"readOnly"] = @YES;
    return result;
}

static NSDictionary<NSString *, id> *FMAnalyzeZipArchive(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    FMArchiveAPI api;
    if (!FMLoadArchiveAPI(&api, error)) return nil;

    FMArchive *archive = api.readNew();
    if (archive == NULL) {
        FMCloseArchiveAPI(&api);
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorUnsupportedArchive,
                       FMLocalized(@"无法创建 ZIP 读取会话。"), nil);
        return nil;
    }

    static const int FMArchiveOK = 0;
    static const int FMArchiveEOF = 1;
    static const int FMArchiveWarn = -20;
    BOOL supportReady = api.readSupportFilterAll(archive) >= FMArchiveWarn &&
                        api.readSupportFormatZip(archive) >= FMArchiveWarn;
    if (!supportReady ||
        api.readOpenFilename(archive, sourcePath.fileSystemRepresentation, 64 * 1024) !=
            FMArchiveOK) {
        NSString *message = FMArchiveFailureDescription(&api, archive,
                                                        FMLocalized(@"无法打开这个 ZIP 字体包。"));
        api.readFree(archive);
        FMCloseArchiveAPI(&api);
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorUnsupportedArchive, message, nil);
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *packageFiles =
        [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *invalidFontEntries =
        [NSMutableArray array];
    NSMutableSet<NSString *> *fontPaths = [NSMutableSet set];
    NSUInteger archiveEntryCount = 0;
    NSUInteger ignoredEntryCount = 0;
    unsigned long long packageFontBytes = 0;
    BOOL failed = NO;
    NSError *archiveError = nil;

    while (!failed) {
        FMArchiveEntry *entry = NULL;
        int nextResult = api.readNextHeader(archive, &entry);
        if (nextResult == FMArchiveEOF) break;
        if (nextResult != FMArchiveOK || entry == NULL) {
            archiveError = FMAnalyzerError(
                FMFontPackageAnalyzerErrorUnsupportedArchive,
                FMArchiveFailureDescription(&api, archive,
                                            FMLocalized(@"读取 ZIP 条目时发生错误。")), nil);
            failed = YES;
            break;
        }
        archiveEntryCount++;
        if (archiveEntryCount > FMMaximumArchiveEntries) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                           FMLocalized(@"字体包包含的文件数量过多。"), nil);
            failed = YES;
            break;
        }

        const char *pathBytes = api.entryPathnameUTF8(entry);
        if (pathBytes == NULL) pathBytes = api.entryPathname(entry);
        NSString *rawPath = pathBytes == NULL ? nil : [NSString stringWithUTF8String:pathBytes];
        NSString *relativePath = FMNormalizedArchiveRelativePath(rawPath);
        NSString *rawExtension = [[rawPath stringByReplacingOccurrencesOfString:@"\\"
                                                                      withString:@"/"]
            pathExtension].lowercaseString;
        BOOL looksLikeFont = [rawExtension isEqual:@"ttf"] ||
                             [rawExtension isEqual:@"ttc"] ||
                             [rawExtension isEqual:@"otf"];
        if (relativePath == nil) {
            if (looksLikeFont) {
                archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                               FMLocalized(@"字体包包含不安全的字体路径。"), nil);
                failed = YES;
                break;
            }
            ignoredEntryCount++;
            api.readDataSkip(archive);
            continue;
        }

        if (FMArchivePathIsMetadata(relativePath) ||
            !FMIsSupportedFontCatalogRelativePath(relativePath)) {
            ignoredEntryCount++;
            api.readDataSkip(archive);
            continue;
        }
        mode_t filetype = api.entryFiletype(entry);
        if (filetype != S_IFREG) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                           FMLocalized(@"字体包包含非普通字体文件。"), nil);
            failed = YES;
            break;
        }
        if (api.entryIsEncrypted(entry) > 0) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsupportedArchive,
                                           FMLocalized(@"暂不支持带密码的 ZIP 字体包。"), nil);
            failed = YES;
            break;
        }
        if ([fontPaths containsObject:relativePath]) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                           FMLocalized(@"字体包内存在重复路径，无法确定应使用哪一份。"), nil);
            failed = YES;
            break;
        }
        [fontPaths addObject:relativePath];

        int64_t declaredSize = api.entrySize(entry);
        if (declaredSize <= 0 ||
            (unsigned long long)declaredSize > FMMaximumFontBytes ||
            packageFontBytes + (unsigned long long)declaredSize >
                FMMaximumPackageFontBytes) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                           FMLocalized(@"字体包中的字体文件过大。"), nil);
            failed = YES;
            break;
        }

        NSData *fontData = FMReadArchiveFontData(&api, archive, declaredSize, &archiveError);
        if (fontData == nil) {
            failed = YES;
            break;
        }
        packageFontBytes += fontData.length;
        if (!FMCoreTextRecognizesFontData(fontData)) {
            [invalidFontEntries addObject:@{
                @"sourceRelativePath" : relativePath,
                @"fileName" : relativePath.lastPathComponent,
                @"reason" : FMLocalized(@"CoreText 无法识别这个文件"),
            }];
            continue;
        }
        [packageFiles addObject:@{
            @"relativePath" : relativePath,
            @"sha256" : FMSHA256ForData(fontData),
            @"fileSize" : @(fontData.length),
        }];
    }

    api.readFree(archive);
    FMCloseArchiveAPI(&api);
    if (failed) {
        if (error != NULL) *error = archiveError;
        return nil;
    }
    if (packageFiles.count == 0) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorNoFonts,
                       FMLocalized(@"字体包中没有找到可识别的 TTF、TTC 或 OTF 字体。"), nil);
        return nil;
    }

    NSDictionary *matching = FMMatchFontPackageFilesToCatalog(packageFiles, catalog, error);
    if (matching == nil) return nil;
    matching = FMRefineLegacyChineseTargetSelection(
        matching,
        FMProbeArchiveFontContents(
            sourcePath, FMContentSelectionProbeRelativePaths(matching, catalog)),
        catalog);
    NSMutableDictionary *result = [matching mutableCopy];
    result[@"packageName"] = sourcePath.lastPathComponent.stringByDeletingPathExtension;
    result[@"sourceKind"] = @"zipArchive";
    result[@"archiveEntryCount"] = @(archiveEntryCount);
    result[@"ignoredEntryCount"] = @(ignoredEntryCount);
    result[@"invalidFontEntryCount"] = @(invalidFontEntries.count);
    result[@"invalidFontEntries"] = invalidFontEntries;
    result[@"readOnly"] = @YES;
    return result;
}

NSDictionary<NSString *, id> *FMAnalyzeFontPackageAtPath(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    NSError *catalogError = nil;
    if (![sourcePath isKindOfClass:NSString.class] || sourcePath.length == 0 ||
        !FMValidateFontCatalogDocument(catalog, &catalogError)) {
        if (error != NULL) {
            *error = FMAnalyzerError(FMFontPackageAnalyzerErrorInvalidInput,
                                     FMLocalized(@"字体包路径或本机字体目录无效。"), catalogError);
        }
        return nil;
    }
    struct stat sourceStat;
    if (lstat(sourcePath.fileSystemRepresentation, &sourceStat) != 0 ||
        !S_ISREG(sourceStat.st_mode) || sourceStat.st_size <= 0 ||
        (unsigned long long)sourceStat.st_size > FMMaximumArchiveBytes) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                       FMLocalized(@"请选择一个不超过 1 GB 的普通字体包文件。"), nil);
        return nil;
    }

    NSString *extension = sourcePath.pathExtension.lowercaseString;
    if ([extension isEqual:@"zip"]) {
        return FMAnalyzeZipArchive(sourcePath, catalog, error);
    }
    return FMAnalyzeRawFont(sourcePath, catalog, error);
}

static BOOL FMAnalyzerIsLowercaseSHA256(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 64) return NO;
    NSCharacterSet *hex =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [value rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

NSArray<NSDictionary<NSString *, id> *> *
FMMaterializeFontPackageMatchesAtPath(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *preview,
    NSString *destinationDirectory,
    NSError **error) {
    if (![sourcePath isKindOfClass:NSString.class] || sourcePath.length == 0 ||
        ![preview isKindOfClass:NSDictionary.class] ||
        ![destinationDirectory isKindOfClass:NSString.class] ||
        destinationDirectory.length == 0) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                       FMLocalized(@"字体包保存参数无效。"), nil);
        return nil;
    }

    struct stat sourceStat = {0};
    struct stat destinationStat = {0};
    if (lstat(sourcePath.fileSystemRepresentation, &sourceStat) != 0 ||
        !S_ISREG(sourceStat.st_mode) || sourceStat.st_size <= 0 ||
        (unsigned long long)sourceStat.st_size > FMMaximumArchiveBytes ||
        lstat(destinationDirectory.fileSystemRepresentation, &destinationStat) != 0 ||
        !S_ISDIR(destinationStat.st_mode)) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                       FMLocalized(@"字体包或字体库暂存目录无效。"), nil);
        return nil;
    }
    NSError *contentsError = nil;
    NSArray<NSString *> *existing =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:destinationDirectory
                                                           error:&contentsError];
    if (existing == nil || existing.count != 0) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorMaterialization,
                       FMLocalized(@"字体库暂存目录必须为空。"), contentsError);
        return nil;
    }

    NSArray<NSDictionary<NSString *, id> *> *matches =
        [preview[@"matches"] isKindOfClass:NSArray.class] ? preview[@"matches"] : nil;
    NSString *systemBuild = [preview[@"systemBuild"] isKindOfClass:NSString.class]
        ? preview[@"systemBuild"] : nil;
    if (matches.count == 0 || systemBuild.length == 0 ||
        [preview[@"conflictTargetCount"] unsignedIntegerValue] != 0 ||
        [preview[@"matchedTargetCount"] unsignedIntegerValue] != matches.count) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                       FMLocalized(@"这个匹配结果暂时不能存入字体库。"), nil);
        return nil;
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *selectionBySource =
        [NSMutableDictionary dictionaryWithCapacity:matches.count];
    NSMutableSet<NSString *> *targetPaths = [NSMutableSet set];
    NSMutableArray<NSDictionary<NSString *, id> *> *replacements =
        [NSMutableArray arrayWithCapacity:matches.count];
    for (NSUInteger index = 0; index < matches.count; index++) {
        id objectMatch = matches[index];
        if (![objectMatch isKindOfClass:NSDictionary.class]) {
            FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                           FMLocalized(@"匹配结果包含无效的字体条目。"), nil);
            return nil;
        }
        NSDictionary<NSString *, id> *match = objectMatch;
        NSString *sourceRelativePath = match[@"selectedSourceRelativePath"];
        NSString *targetRelativePath = match[@"targetRelativePath"];
        NSString *targetFileID = match[@"targetFileID"];
        NSString *sourceSHA256 = match[@"sourceSHA256"];
        NSNumber *fileSize = match[@"fileSize"];
        unsigned long long expectedSize = [fileSize isKindOfClass:NSNumber.class]
            ? fileSize.unsignedLongLongValue : 0;
        if (!FMIsSupportedFontCatalogRelativePath(sourceRelativePath) ||
            !FMIsSupportedFontCatalogRelativePath(targetRelativePath) ||
            ![targetFileID isKindOfClass:NSString.class] || targetFileID.length == 0 ||
            !FMAnalyzerIsLowercaseSHA256(sourceSHA256) ||
            ![fileSize isKindOfClass:NSNumber.class] || expectedSize == 0 ||
            expectedSize > FMMaximumFontBytes || selectionBySource[sourceRelativePath] != nil ||
            [targetPaths containsObject:targetRelativePath]) {
            FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                           FMLocalized(@"匹配结果包含无效或重复的字体条目。"), nil);
            return nil;
        }
        [targetPaths addObject:targetRelativePath];
        NSString *fileName =
            [NSString stringWithFormat:@"replacement-%04lu.%@",
                                       (unsigned long)(index + 1),
                                       targetRelativePath.pathExtension.lowercaseString];
        NSDictionary<NSString *, id> *selection = @{
            @"sourceRelativePath" : sourceRelativePath,
            @"destinationFileName" : fileName,
            @"expectedSHA256" : sourceSHA256,
            @"expectedSize" : fileSize,
        };
        selectionBySource[sourceRelativePath] = selection;
        [replacements addObject:@{
            @"fontFileID" : targetFileID,
            @"relativePath" : targetRelativePath,
            @"fileName" : fileName,
            @"sha256" : sourceSHA256,
        }];
    }

    NSError *profileError = nil;
    NSDictionary<NSString *, id> *validationProfile = @{
        @"schemaVersion" : @2,
        @"id" : @"materialization-check",
        @"name" : @"Materialization Check",
        @"systemBuild" : systemBuild,
        @"replacements" : replacements,
    };
    if (!FMValidateProfileDocument(validationProfile, &profileError)) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                       FMLocalized(@"匹配结果无法生成有效的字体方案。"), profileError);
        return nil;
    }

    NSString *extension = sourcePath.pathExtension.lowercaseString;
    if (![extension isEqual:@"zip"]) {
        if (selectionBySource.count != 1 ||
            selectionBySource[sourcePath.lastPathComponent] == nil) {
            FMAnalyzerFail(error, FMFontPackageAnalyzerErrorInvalidInput,
                           FMLocalized(@"单个字体文件的匹配结果不一致。"), nil);
            return nil;
        }
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:sourcePath
                                             options:NSDataReadingMappedIfSafe
                                               error:&readError];
        NSDictionary<NSString *, id> *selection =
            selectionBySource[sourcePath.lastPathComponent];
        if (data == nil || !FMCoreTextRecognizesFontData(data) ||
            data.length != [selection[@"expectedSize"] unsignedLongLongValue] ||
            ![FMSHA256ForData(data) isEqual:selection[@"expectedSHA256"]]) {
            FMAnalyzerFail(error, FMFontPackageAnalyzerErrorMaterialization,
                           FMLocalized(@"字体文件在保存前发生变化或无法再验证。"), readError);
            return nil;
        }
        NSString *destinationPath = [destinationDirectory
            stringByAppendingPathComponent:selection[@"destinationFileName"]];
        if (!FMWriteNewFontPayload(data, destinationPath, error) ||
            !FMSyncFontPayloadDirectory(destinationDirectory, error)) {
            return nil;
        }
        return replacements;
    }

    FMArchiveAPI api;
    if (!FMLoadArchiveAPI(&api, error)) return nil;
    FMArchive *archive = api.readNew();
    if (archive == NULL) {
        FMCloseArchiveAPI(&api);
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorUnsupportedArchive,
                       FMLocalized(@"无法创建 ZIP 保存会话。"), nil);
        return nil;
    }
    static const int FMArchiveOK = 0;
    static const int FMArchiveEOF = 1;
    static const int FMArchiveWarn = -20;
    BOOL supportReady = api.readSupportFilterAll(archive) >= FMArchiveWarn &&
                        api.readSupportFormatZip(archive) >= FMArchiveWarn;
    if (!supportReady ||
        api.readOpenFilename(archive, sourcePath.fileSystemRepresentation, 64 * 1024) !=
            FMArchiveOK) {
        NSString *message = FMArchiveFailureDescription(&api, archive,
                                                        FMLocalized(@"无法重新打开这个 ZIP 字体包。"));
        api.readFree(archive);
        FMCloseArchiveAPI(&api);
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorUnsupportedArchive, message, nil);
        return nil;
    }

    NSMutableSet<NSString *> *fontPaths = [NSMutableSet set];
    NSMutableSet<NSString *> *materializedPaths = [NSMutableSet set];
    NSUInteger archiveEntryCount = 0;
    unsigned long long packageFontBytes = 0;
    NSError *archiveError = nil;
    BOOL failed = NO;
    while (!failed) {
        FMArchiveEntry *entry = NULL;
        int nextResult = api.readNextHeader(archive, &entry);
        if (nextResult == FMArchiveEOF) break;
        if (nextResult != FMArchiveOK || entry == NULL) {
            archiveError = FMAnalyzerError(
                FMFontPackageAnalyzerErrorUnsupportedArchive,
                FMArchiveFailureDescription(&api, archive,
                                            FMLocalized(@"重新读取 ZIP 条目时发生错误。")), nil);
            failed = YES;
            break;
        }
        archiveEntryCount++;
        if (archiveEntryCount > FMMaximumArchiveEntries) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                           FMLocalized(@"字体包包含的文件数量过多。"), nil);
            failed = YES;
            break;
        }

        const char *pathBytes = api.entryPathnameUTF8(entry);
        if (pathBytes == NULL) pathBytes = api.entryPathname(entry);
        NSString *rawPath = pathBytes == NULL ? nil : [NSString stringWithUTF8String:pathBytes];
        NSString *relativePath = FMNormalizedArchiveRelativePath(rawPath);
        NSString *rawExtension = [[rawPath stringByReplacingOccurrencesOfString:@"\\"
                                                                      withString:@"/"]
            pathExtension].lowercaseString;
        BOOL looksLikeFont = [rawExtension isEqual:@"ttf"] ||
                             [rawExtension isEqual:@"ttc"] ||
                             [rawExtension isEqual:@"otf"];
        if (relativePath == nil) {
            if (looksLikeFont) {
                archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                               FMLocalized(@"字体包包含不安全的字体路径。"), nil);
                failed = YES;
                break;
            }
            api.readDataSkip(archive);
            continue;
        }
        if (FMArchivePathIsMetadata(relativePath) ||
            !FMIsSupportedFontCatalogRelativePath(relativePath)) {
            api.readDataSkip(archive);
            continue;
        }
        if (api.entryFiletype(entry) != S_IFREG) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                           FMLocalized(@"字体包包含非普通字体文件。"), nil);
            failed = YES;
            break;
        }
        if (api.entryIsEncrypted(entry) > 0) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsupportedArchive,
                                           FMLocalized(@"暂不支持带密码的 ZIP 字体包。"), nil);
            failed = YES;
            break;
        }
        if ([fontPaths containsObject:relativePath]) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                           FMLocalized(@"字体包内存在重复路径。"), nil);
            failed = YES;
            break;
        }
        [fontPaths addObject:relativePath];

        int64_t declaredSize = api.entrySize(entry);
        if (declaredSize <= 0 ||
            (unsigned long long)declaredSize > FMMaximumFontBytes ||
            packageFontBytes + (unsigned long long)declaredSize >
                FMMaximumPackageFontBytes) {
            archiveError = FMAnalyzerError(FMFontPackageAnalyzerErrorUnsafeArchive,
                                           FMLocalized(@"字体包中的字体文件过大。"), nil);
            failed = YES;
            break;
        }
        packageFontBytes += (unsigned long long)declaredSize;
        NSDictionary<NSString *, id> *selection = selectionBySource[relativePath];
        if (selection == nil) {
            api.readDataSkip(archive);
            continue;
        }

        NSData *fontData = FMReadArchiveFontData(&api, archive, declaredSize, &archiveError);
        if (fontData == nil || !FMCoreTextRecognizesFontData(fontData) ||
            fontData.length != [selection[@"expectedSize"] unsignedLongLongValue] ||
            ![FMSHA256ForData(fontData) isEqual:selection[@"expectedSHA256"]]) {
            if (archiveError == nil) {
                archiveError = FMAnalyzerError(
                    FMFontPackageAnalyzerErrorMaterialization,
                    FMLocalized(@"字体包内容在保存前发生变化或无法再验证。"), nil);
            }
            failed = YES;
            break;
        }
        NSString *destinationPath = [destinationDirectory
            stringByAppendingPathComponent:selection[@"destinationFileName"]];
        if (!FMWriteNewFontPayload(fontData, destinationPath, &archiveError)) {
            failed = YES;
            break;
        }
        [materializedPaths addObject:relativePath];
    }

    api.readFree(archive);
    FMCloseArchiveAPI(&api);
    if (failed) {
        if (error != NULL) *error = archiveError;
        return nil;
    }
    if (materializedPaths.count != selectionBySource.count ||
        ![materializedPaths isEqualToSet:[NSSet setWithArray:selectionBySource.allKeys]]) {
        FMAnalyzerFail(error, FMFontPackageAnalyzerErrorMaterialization,
                       FMLocalized(@"字体包中的匹配文件不完整。"), nil);
        return nil;
    }
    if (!FMSyncFontPayloadDirectory(destinationDirectory, error)) return nil;
    return replacements;
}
