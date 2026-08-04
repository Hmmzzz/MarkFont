#import "FMDeviceMountTopology.h"

#import <errno.h>
#import <sys/mount.h>

#import "FMMountPaths.h"

NSString *const FMDeviceMountTopologyErrorDomain =
    @"com.hmmzzz.fontmanager.device-mount-topology";

static NSError *FMTTopologyError(NSString *description, int errorNumber) {
    NSMutableDictionary *userInfo =
        [NSMutableDictionary dictionaryWithObject:description
                                           forKey:NSLocalizedDescriptionKey];
    if (errorNumber != 0) {
        userInfo[NSUnderlyingErrorKey] =
            [NSError errorWithDomain:NSPOSIXErrorDomain
                                code:errorNumber
                            userInfo:nil];
    }
    return [NSError errorWithDomain:FMDeviceMountTopologyErrorDomain
                               code:1
                           userInfo:userInfo];
}

static NSString *FMTString(const char *value) {
    if (value == NULL) return @"";
    NSString *result = [NSString stringWithUTF8String:value];
    return result ?: @"";
}

static NSString *FMTCanonicalPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return @"";
    return path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
}

static BOOL FMTPathIsEqualOrDescendant(NSString *path, NSString *root) {
    NSString *normalizedPath = path.stringByStandardizingPath;
    NSString *normalizedRoot = root.stringByStandardizingPath;
    if ([normalizedPath isEqual:normalizedRoot]) return YES;
    return [normalizedPath hasPrefix:
        [normalizedRoot stringByAppendingString:@"/"]];
}

static BOOL FMTPathsOverlap(NSString *first, NSString *second) {
    return FMTPathIsEqualOrDescendant(first, second) ||
        FMTPathIsEqualOrDescendant(second, first);
}

static NSDictionary<NSString *, id> *FMTRow(const struct statfs *row) {
    NSString *filesystemType = FMTString(row->f_fstypename);
    NSString *target = FMTString(row->f_mntonname);
    NSString *source = FMTString(row->f_mntfromname);
    return @{
        @"filesystemType" : filesystemType,
        @"target" : target,
        @"source" : source,
        @"readOnly" : (row->f_flags & MNT_RDONLY) != 0 ? @YES : @NO,
    };
}

NSDictionary<NSString *, id> *FMCreateSystemFontsMountTopology(
    NSString *expectedMirrorPath,
    NSError **error) {
    if (![expectedMirrorPath isKindOfClass:NSString.class] ||
        expectedMirrorPath.length == 0) {
        if (error != NULL) {
            *error = FMTTopologyError(@"The expected font-mirror path is invalid.", 0);
        }
        return nil;
    }

    struct statfs *rows = NULL;
    int count = getmntinfo(&rows, MNT_NOWAIT);
    if (count <= 0 || rows == NULL) {
        if (error != NULL) {
            *error = FMTTopologyError(@"The device mount table is unavailable.", errno);
        }
        return nil;
    }

    NSString *fontTarget = FMMountSystemFontsLogicalPath;
    NSString *canonicalMirror = FMTCanonicalPath(expectedMirrorPath);
    NSMutableArray<NSDictionary<NSString *, id> *> *exactTargetRows =
        [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *overlappingTargetRows =
        [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, id> *> *overlappingSourceRows =
        [NSMutableArray array];

    for (int index = 0; index < count; index++) {
        NSDictionary<NSString *, id> *row = FMTRow(&rows[index]);
        NSString *target = row[@"target"];
        NSString *source = row[@"source"];
        NSString *filesystemType = row[@"filesystemType"];
        BOOL exactTarget = [target isEqual:fontTarget];

        if (exactTarget) {
            [exactTargetRows addObject:row];
        } else if (![target isEqual:@"/"] && FMTPathsOverlap(target, fontTarget)) {
            [overlappingTargetRows addObject:row];
        }

        if ([filesystemType caseInsensitiveCompare:@"bindfs"] != NSOrderedSame) {
            continue;
        }
        NSString *canonicalSource = FMTCanonicalPath(source);
        BOOL exactExpectedRow = exactTarget &&
            [canonicalSource isEqual:canonicalMirror];
        if (!exactExpectedRow && canonicalSource.length > 0 &&
            FMTPathsOverlap(canonicalSource, canonicalMirror)) {
            [overlappingSourceRows addObject:row];
        }
    }

    NSDictionary<NSString *, id> *exactRow = exactTargetRows.count == 1
        ? exactTargetRows.firstObject : nil;
    BOOL exactBindfs = exactRow != nil &&
        [exactRow[@"filesystemType"] caseInsensitiveCompare:@"bindfs"] ==
            NSOrderedSame;
    BOOL sourceMatches = exactBindfs &&
        [FMTCanonicalPath(exactRow[@"source"]) isEqual:canonicalMirror];
    BOOL readOnly = exactBindfs && [exactRow[@"readOnly"] boolValue];
    BOOL conflict = exactTargetRows.count > 1 ||
        overlappingTargetRows.count > 0 || overlappingSourceRows.count > 0;

    return @{
        @"schemaVersion" : @1,
        @"exactTargetCount" : @(exactTargetRows.count),
        @"exactTargetRows" : exactTargetRows,
        @"overlappingTargetRows" : overlappingTargetRows,
        @"overlappingSourceRows" : overlappingSourceRows,
        @"active" : exactRow != nil ? @YES : @NO,
        @"bindfs" : exactBindfs ? @YES : @NO,
        @"readOnly" : readOnly ? @YES : @NO,
        @"sourceMatchesExpectedMirror" : sourceMatches ? @YES : @NO,
        @"hasConflict" : conflict ? @YES : @NO,
        @"exactRow" : exactRow ?: NSNull.null,
    };
}
