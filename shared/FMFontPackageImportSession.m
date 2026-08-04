#import "FMFontPackageImportSession.h"

#import <errno.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const FMFontPackageImportSessionErrorDomain =
    @"com.hmmzzz.fontmanager.fontpackageimportsession";

typedef NS_ENUM(NSInteger, FMFontPackageImportSessionErrorCode) {
    FMFontPackageImportSessionErrorInvalidSource = 1,
    FMFontPackageImportSessionErrorTemporaryStorage = 2,
    FMFontPackageImportSessionErrorCoordination = 3,
    FMFontPackageImportSessionErrorCleanup = 4,
};

static const unsigned long long FMMaximumImportedPackageBytes =
    1024ULL * 1024ULL * 1024ULL;

static BOOL FMImportSessionFail(NSError **error,
                                FMFontPackageImportSessionErrorCode code,
                                NSString *message,
                                NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:message
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMFontPackageImportSessionErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSString *FMImportSessionsRootPath(void) {
    NSString *temporaryRoot = NSTemporaryDirectory();
    if (![temporaryRoot isKindOfClass:NSString.class] || temporaryRoot.length == 0) {
        return nil;
    }
    return [[temporaryRoot stringByStandardizingPath]
        stringByAppendingPathComponent:@"com.hmmzzz.fontmanager.font-imports"];
}

static BOOL FMEnsureImportSessionsRoot(NSString **rootPath, NSError **error) {
    NSString *root = FMImportSessionsRootPath();
    if (root.length == 0) {
        return FMImportSessionFail(error,
                                   FMFontPackageImportSessionErrorTemporaryStorage,
                                   @"字体包临时目录不可用。", nil);
    }
    struct stat info = {0};
    if (lstat(root.fileSystemRepresentation, &info) != 0) {
        if (errno != ENOENT) {
            NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                       code:errno
                                                   userInfo:nil];
            return FMImportSessionFail(error,
                                       FMFontPackageImportSessionErrorTemporaryStorage,
                                       @"无法检查字体包临时目录。", underlying);
        }
        NSError *directoryError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:root
                                      withIntermediateDirectories:NO
                                                       attributes:@{
                                                           NSFilePosixPermissions : @0700
                                                       }
                                                            error:&directoryError] &&
            lstat(root.fileSystemRepresentation, &info) != 0) {
            return FMImportSessionFail(error,
                                       FMFontPackageImportSessionErrorTemporaryStorage,
                                       @"无法创建字体包临时目录。", directoryError);
        }
    }
    if (lstat(root.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) {
        return FMImportSessionFail(error,
                                   FMFontPackageImportSessionErrorTemporaryStorage,
                                   @"字体包临时位置不是普通目录。", nil);
    }
    if (chmod(root.fileSystemRepresentation, 0700) != 0) {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno
                                               userInfo:nil];
        return FMImportSessionFail(error,
                                   FMFontPackageImportSessionErrorTemporaryStorage,
                                   @"无法保护字体包临时目录。", underlying);
    }
    if (rootPath != NULL) *rootPath = root;
    return YES;
}

static BOOL FMIsSupportedImportFileName(NSString *fileName) {
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0 ||
        ![fileName.lastPathComponent isEqual:fileName] ||
        fileName.pathComponents.count != 1 || [fileName isEqual:@"."] ||
        [fileName isEqual:@".."]) {
        return NO;
    }
    NSString *extension = fileName.pathExtension.lowercaseString;
    return [extension isEqual:@"zip"] || [extension isEqual:@"ttf"] ||
           [extension isEqual:@"ttc"] || [extension isEqual:@"otf"];
}

static BOOL FMIsSessionDirectoryName(NSString *name) {
    static NSString *const prefix = @"session-";
    if (![name hasPrefix:prefix]) return NO;
    NSString *uuid = [name substringFromIndex:prefix.length];
    return [[NSUUID alloc] initWithUUIDString:uuid] != nil;
}

static BOOL FMRemoveSessionDirectoryAtPath(NSString *path,
                                           NSString *root,
                                           NSError **error) {
    if (![[path stringByDeletingLastPathComponent] isEqual:root] ||
        !FMIsSessionDirectoryName(path.lastPathComponent)) {
        return FMImportSessionFail(error, FMFontPackageImportSessionErrorCleanup,
                                   @"拒绝清理不属于 Font Manager 的路径。", nil);
    }
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) return YES;
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno
                                               userInfo:nil];
        return FMImportSessionFail(error, FMFontPackageImportSessionErrorCleanup,
                                   @"无法检查字体包临时会话。", underlying);
    }
    if (!S_ISDIR(info.st_mode)) {
        return FMImportSessionFail(error, FMFontPackageImportSessionErrorCleanup,
                                   @"字体包临时会话不是普通目录。", nil);
    }
    NSError *removeError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:path error:&removeError]) {
        return FMImportSessionFail(error, FMFontPackageImportSessionErrorCleanup,
                                   @"无法清理字体包临时副本。", removeError);
    }
    return YES;
}

@interface FMFontPackageImportSession ()
@property(nonatomic, copy, readwrite) NSURL *packageURL;
@property(nonatomic, copy, readwrite) NSURL *sessionDirectoryURL;
- (instancetype)initWithPackageURL:(NSURL *)packageURL
                sessionDirectoryURL:(NSURL *)sessionDirectoryURL;
@end

@implementation FMFontPackageImportSession

- (instancetype)initWithPackageURL:(NSURL *)packageURL
                sessionDirectoryURL:(NSURL *)sessionDirectoryURL {
    self = [super init];
    if (self != nil) {
        _packageURL = [packageURL copy];
        _sessionDirectoryURL = [sessionDirectoryURL copy];
    }
    return self;
}

+ (instancetype)sessionByImportingURL:(NSURL *)sourceURL error:(NSError **)error {
    if (![sourceURL isKindOfClass:NSURL.class] || !sourceURL.isFileURL ||
        !FMIsSupportedImportFileName(sourceURL.lastPathComponent)) {
        FMImportSessionFail(error, FMFontPackageImportSessionErrorInvalidSource,
                            @"请选择 ZIP、TTF、TTC 或 OTF 文件。", nil);
        return nil;
    }

    NSString *root = nil;
    if (!FMEnsureImportSessionsRoot(&root, error)) return nil;
    NSString *sessionName = [@"session-" stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
    NSString *sessionPath = [root stringByAppendingPathComponent:sessionName];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:sessionPath
                                  withIntermediateDirectories:NO
                                                   attributes:@{
                                                       NSFilePosixPermissions : @0700
                                                   }
                                                        error:&directoryError]) {
        FMImportSessionFail(error, FMFontPackageImportSessionErrorTemporaryStorage,
                            @"无法创建字体包临时会话。", directoryError);
        return nil;
    }

    NSURL *destinationURL = [NSURL fileURLWithPath:
        [sessionPath stringByAppendingPathComponent:sourceURL.lastPathComponent]
                                       isDirectory:NO];
    BOOL accessed = [sourceURL startAccessingSecurityScopedResource];
    NSFileCoordinator *coordinator =
        [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSError *copyError = nil;
    NSError *coordinationError = nil;
    [coordinator coordinateReadingItemAtURL:sourceURL
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordinationError
                                 byAccessor:^(NSURL *coordinatedURL) {
        struct stat sourceInfo = {0};
        int sourceStatResult =
            lstat(coordinatedURL.path.fileSystemRepresentation, &sourceInfo);
        if (sourceStatResult != 0 ||
            !S_ISREG(sourceInfo.st_mode) || sourceInfo.st_size <= 0 ||
            (unsigned long long)sourceInfo.st_size > FMMaximumImportedPackageBytes) {
            int savedError = sourceStatResult == 0 ? EINVAL : errno;
            copyError = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:savedError
                                         userInfo:@{
                                             NSLocalizedDescriptionKey :
                                                 @"所选字体包不是大小有效的普通文件。"
                                         }];
            return;
        }
        if (![NSFileManager.defaultManager copyItemAtURL:coordinatedURL
                                                   toURL:destinationURL
                                                   error:&copyError]) {
            return;
        }
        if (![NSFileManager.defaultManager setAttributes:@{
                NSFilePosixPermissions : @0600
            }
                                             ofItemAtPath:destinationURL.path
                                                      error:&copyError]) {
            return;
        }
        struct stat destinationInfo = {0};
        int destinationStatResult =
            lstat(destinationURL.path.fileSystemRepresentation, &destinationInfo);
        if (destinationStatResult != 0 ||
            !S_ISREG(destinationInfo.st_mode) ||
            destinationInfo.st_size != sourceInfo.st_size) {
            int savedError = destinationStatResult == 0 ? EIO : errno;
            copyError = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:savedError
                                         userInfo:@{
                                             NSLocalizedDescriptionKey :
                                                 @"字体包临时副本不完整。"
                                         }];
        }
    }];
    if (accessed) [sourceURL stopAccessingSecurityScopedResource];

    if (coordinationError != nil || copyError != nil) {
        [NSFileManager.defaultManager removeItemAtPath:sessionPath error:nil];
        FMImportSessionFail(error, FMFontPackageImportSessionErrorCoordination,
                            @"无法安全读取所选字体包。",
                            copyError ?: coordinationError);
        return nil;
    }
    return [[self alloc] initWithPackageURL:destinationURL
                       sessionDirectoryURL:[NSURL fileURLWithPath:sessionPath
                                                      isDirectory:YES]];
}

+ (BOOL)discardAbandonedSessions:(NSError **)error {
    NSString *root = FMImportSessionsRootPath();
    if (root.length == 0) {
        return FMImportSessionFail(error,
                                   FMFontPackageImportSessionErrorTemporaryStorage,
                                   @"字体包临时目录不可用。", nil);
    }
    struct stat rootInfo = {0};
    if (lstat(root.fileSystemRepresentation, &rootInfo) != 0) {
        if (errno == ENOENT) return YES;
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                   code:errno
                                               userInfo:nil];
        return FMImportSessionFail(error, FMFontPackageImportSessionErrorCleanup,
                                   @"无法检查遗留的字体包临时目录。", underlying);
    }
    if (!S_ISDIR(rootInfo.st_mode)) {
        return FMImportSessionFail(error, FMFontPackageImportSessionErrorCleanup,
                                   @"字体包临时位置不是普通目录。", nil);
    }
    NSError *contentsError = nil;
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:root
                                                           error:&contentsError];
    if (entries == nil) {
        return FMImportSessionFail(error, FMFontPackageImportSessionErrorCleanup,
                                   @"无法读取遗留的字体包临时目录。", contentsError);
    }
    for (NSString *entry in entries) {
        if (!FMIsSessionDirectoryName(entry)) continue;
        if (!FMRemoveSessionDirectoryAtPath([root stringByAppendingPathComponent:entry],
                                            root, error)) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)discard:(NSError **)error {
    NSString *root = FMImportSessionsRootPath();
    if (root.length == 0) {
        return FMImportSessionFail(error, FMFontPackageImportSessionErrorCleanup,
                                   @"字体包临时目录不可用。", nil);
    }
    return FMRemoveSessionDirectoryAtPath(self.sessionDirectoryURL.path, root, error);
}

- (void)dealloc {
    [self discard:nil];
}

@end
