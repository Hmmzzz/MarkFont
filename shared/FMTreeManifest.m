#import "FMTreeManifest.h"

#import <errno.h>
#import <fts.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMFileStore.h"

NSString *const FMTreeManifestErrorDomain = @"com.hmmzzz.fontmanager.manifest";

static NSError *FMManifestError(NSString *message, NSError *underlying) {
    NSMutableDictionary *userInfo =
        [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:FMTreeManifestErrorDomain code:1 userInfo:userInfo];
}

static NSError *FMManifestPOSIXError(NSString *operation, NSString *path, int errorNumber) {
    NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:errorNumber userInfo:nil];
    return FMManifestError([NSString stringWithFormat:@"%@ failed for %@: %@",
                                                      operation, path,
                                                      underlying.localizedDescription],
                           underlying);
}

static NSString *FMSymbolicLinkTarget(NSString *path, NSError **error) {
    size_t capacity = 256;
    while (capacity <= 1024 * 1024) {
        NSMutableData *buffer = [NSMutableData dataWithLength:capacity];
        ssize_t length = readlink(path.fileSystemRepresentation, buffer.mutableBytes, capacity);
        if (length < 0) {
            if (error != NULL) {
                *error = FMManifestPOSIXError(@"readlink", path, errno);
            }
            return nil;
        }
        if ((size_t)length < capacity) {
            NSString *target = [[NSString alloc] initWithBytes:buffer.bytes
                                                       length:(NSUInteger)length
                                                     encoding:NSUTF8StringEncoding];
            if (target == nil && error != NULL) {
                *error = FMManifestError(@"Symlink target is not valid UTF-8.", nil);
            }
            return target;
        }
        capacity *= 2;
    }
    if (error != NULL) {
        *error = FMManifestError(@"Symlink target exceeds the supported length.", nil);
    }
    return nil;
}

NSDictionary<NSString *, id> *FMCreateTreeManifestAtPath(NSString *rootPath,
                                                          NSError **error) {
    if (rootPath.length == 0) {
        if (error != NULL) {
            *error = FMManifestError(@"Manifest root path is empty.", nil);
        }
        return nil;
    }

    NSString *normalizedRoot = rootPath.stringByStandardizingPath;
    struct stat rootInfo = {0};
    if (lstat(normalizedRoot.fileSystemRepresentation, &rootInfo) != 0) {
        if (error != NULL) {
            *error = FMManifestPOSIXError(@"lstat manifest root", normalizedRoot, errno);
        }
        return nil;
    }
    if (!S_ISDIR(rootInfo.st_mode)) {
        if (error != NULL) {
            *error = FMManifestError(@"Manifest root must be a physical directory.", nil);
        }
        return nil;
    }

    char *rootCString = strdup(normalizedRoot.fileSystemRepresentation);
    if (rootCString == NULL) {
        if (error != NULL) {
            *error = FMManifestPOSIXError(@"copy manifest root path", normalizedRoot, ENOMEM);
        }
        return nil;
    }
    char *paths[] = {rootCString, NULL};
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) {
        int savedError = errno;
        free(rootCString);
        if (error != NULL) {
            *error = FMManifestPOSIXError(@"open manifest tree", normalizedRoot, savedError);
        }
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *entries = [NSMutableArray array];
    NSError *walkError = nil;
    size_t rootLength = strlen(rootCString);
    FTSENT *entry = NULL;
    int walkErrno = 0;
    while (YES) {
        errno = 0;
        entry = fts_read(tree);
        if (entry == NULL) {
            walkErrno = errno;
            break;
        }
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR ||
            entry->fts_info == FTS_NS) {
            int entryError = entry->fts_errno != 0 ? entry->fts_errno : EIO;
            NSString *entryPath = [NSFileManager.defaultManager
                stringWithFileSystemRepresentation:entry->fts_path
                                             length:strlen(entry->fts_path)];
            walkError = FMManifestPOSIXError(@"walk manifest tree", entryPath, entryError);
            break;
        }
        if (entry->fts_info == FTS_DP || entry->fts_level == 0) {
            continue;
        }
        if (entry->fts_statp == NULL) {
            walkError = FMManifestError(@"Manifest entry is missing stat metadata.", nil);
            break;
        }

        const char *relativeBytes = entry->fts_path + rootLength;
        if (*relativeBytes == '/') {
            relativeBytes++;
        }
        NSString *relativePath = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:relativeBytes
                                         length:strlen(relativeBytes)];
        if (relativePath.length == 0) {
            walkError = FMManifestError(@"Unable to decode a manifest relative path.", nil);
            break;
        }

        const struct stat *info = entry->fts_statp;
        NSString *type = @"other";
        if (S_ISREG(info->st_mode)) {
            type = @"regular";
        } else if (S_ISDIR(info->st_mode)) {
            type = @"directory";
        } else if (S_ISLNK(info->st_mode)) {
            type = @"symlink";
        }

        NSMutableDictionary<NSString *, id> *manifestEntry = [@{
            @"relativePath" : relativePath,
            @"type" : type,
            @"mode" : @((unsigned int)(info->st_mode & 07777)),
            @"uid" : @((unsigned int)info->st_uid),
            @"gid" : @((unsigned int)info->st_gid),
            @"size" : @((long long)info->st_size),
        } mutableCopy];

        NSString *fullPath = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->fts_path
                                         length:strlen(entry->fts_path)];
        if ([type isEqual:@"regular"]) {
            NSError *hashError = nil;
            NSString *hash = FMSHA256ForFileAtPath(fullPath, &hashError);
            if (hash == nil) {
                walkError = FMManifestError(@"Unable to hash a manifest file.", hashError);
                break;
            }
            manifestEntry[@"sha256"] = hash;
        } else if ([type isEqual:@"symlink"]) {
            NSError *linkError = nil;
            NSString *linkTarget = FMSymbolicLinkTarget(fullPath, &linkError);
            if (linkTarget == nil) {
                walkError = FMManifestError(@"Unable to read a manifest symlink.", linkError);
                break;
            }
            manifestEntry[@"linkTarget"] = linkTarget;
        }
        [entries addObject:manifestEntry];
    }

    if (fts_close(tree) != 0 && walkError == nil) {
        walkError = FMManifestPOSIXError(@"close manifest tree", normalizedRoot, errno);
    }
    free(rootCString);
    if (walkError == nil && walkErrno != 0) {
        walkError = FMManifestPOSIXError(@"read manifest tree", normalizedRoot, walkErrno);
    }
    if (walkError != nil) {
        if (error != NULL) {
            *error = walkError;
        }
        return nil;
    }

    [entries sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *left,
                                                      NSDictionary<NSString *, id> *right) {
        return [left[@"relativePath"] compare:right[@"relativePath"]];
    }];
    NSDictionary<NSString *, id> *manifest = @{
        @"schemaVersion" : @(FMDataSchemaVersion),
        @"entries" : entries,
    };
    NSError *validationError = nil;
    if (!FMValidateManifestDocument(manifest, &validationError)) {
        if (error != NULL) {
            *error = FMManifestError(@"Generated manifest failed schema validation.",
                                     validationError);
        }
        return nil;
    }
    return manifest;
}
