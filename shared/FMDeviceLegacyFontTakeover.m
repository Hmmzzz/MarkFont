#import "FMDeviceLegacyFontTakeover.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <roothide.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDeviceMountTopology.h"
#import "FMFileStore.h"
#import "FMLegacyFontProfileImport.h"
#import "FMMountBackendExecutor.h"
#import "FMMountPaths.h"
#import "FMSecureDirectory.h"

NSString *const FMDeviceLegacyFontTakeoverErrorDomain =
    @"com.hmmzzz.fontmanager.device-legacy-font-takeover";
NSString *const FMLegacyFontTakeoverJournalLogicalPath =
    @"/var/lib/fontmanager/install-takeover.json";

static NSString *const FMLegacyMirrorOwnershipLogicalPath =
    @"/var/lib/fontmanager/.mirror-owned";
static NSString *const FMLegacyMirrorLogicalPath =
    @"/bindfs/System/Library/Fonts";
static NSString *const FMLegacyProfileName = @"安装前字体";

static BOOL FMLegacyFail(NSError **error,
                         NSInteger code,
                         NSString *description,
                         int errorNumber) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (errorNumber != 0) {
            userInfo[NSUnderlyingErrorKey] =
                [NSError errorWithDomain:NSPOSIXErrorDomain
                                    code:errorNumber
                                userInfo:nil];
        }
        *error = [NSError errorWithDomain:FMDeviceLegacyFontTakeoverErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMLegacySafeComponent(NSString *value, NSUInteger maximumLength) {
    if (![value isKindOfClass:NSString.class] || value.length == 0 ||
        value.length > maximumLength || value.isAbsolutePath ||
        value.pathComponents.count != 1 ||
        ![value.lastPathComponent isEqual:value] || [value isEqual:@"."] ||
        [value isEqual:@".."]) {
        return NO;
    }
    NSMutableCharacterSet *allowed =
        [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"._-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location ==
        NSNotFound;
}

static BOOL FMLegacySafeBuild(NSString *systemBuild) {
    return FMLegacySafeComponent(systemBuild, 32);
}

static BOOL FMLegacySafeProfileID(NSString *profileID) {
    return [profileID hasPrefix:@"import-legacy-"] &&
        FMLegacySafeComponent(profileID, 128);
}

static BOOL FMLegacyJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSString *FMLegacyPhysicalDirectory(NSString *path, NSError **error) {
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (resolved == NULL) {
        FMLegacyFail(error, 2,
                     @"A legacy-takeover directory could not be resolved.",
                     errno);
        return nil;
    }
    NSString *result = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:resolved
                                     length:strlen(resolved)];
    free(resolved);
    if (result.length == 0) {
        FMLegacyFail(error, 2,
                     @"A legacy-takeover directory resolved to an empty path.",
                     EINVAL);
        return nil;
    }
    return result;
}

static BOOL FMLegacyInspectPath(NSString *path,
                                BOOL *present,
                                struct stat *result,
                                NSError **error) {
    if (present == NULL) {
        return FMLegacyFail(
            error, 2, @"A legacy-takeover presence result is unavailable.",
            EINVAL);
    }
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) == 0) {
        *present = YES;
        if (result != NULL) *result = info;
        return YES;
    }
    if (errno == ENOENT) {
        *present = NO;
        return YES;
    }
    *present = NO;
    return FMLegacyFail(
        error, 2, @"A legacy-takeover path could not be inspected.", errno);
}

static BOOL FMLegacyRequireSafeMirror(const struct stat *info,
                                      NSError **error) {
    return (S_ISDIR(info->st_mode) && info->st_uid == 0 &&
            info->st_gid == 0 &&
            (info->st_mode & (S_IWGRP | S_IWOTH)) == 0) ||
        FMLegacyFail(
            error, 3,
            @"The existing font mirror is not a secure root-owned directory.",
            EPERM);
}

static BOOL FMLegacyMirrorOwnershipMarkerPresent(BOOL *present,
                                                  NSError **error) {
    NSString *path = jbroot(FMLegacyMirrorOwnershipLogicalPath);
    struct stat info = {0};
    if (!FMLegacyInspectPath(path, present, &info, error)) return NO;
    if (!*present) return YES;
    if (!S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return FMLegacyFail(
            error, 3, @"The MarkFont mirror ownership marker is unsafe.",
            EPERM);
    }
    NSError *readError = nil;
    id object = FMReadJSONObjectAtPath(path, &readError);
    if (![object isKindOfClass:NSDictionary.class] ||
        ![object[@"schemaVersion"] isEqual:@1] ||
        ![object[@"purpose"] isEqual:@"markFontMirrorOwned"] ||
        ![object[@"systemBuild"] isKindOfClass:NSString.class]) {
        return FMLegacyFail(
            error, 3, @"The MarkFont mirror ownership marker is invalid.",
            EINVAL);
    }
    return YES;
}

static BOOL FMLegacyRequirePhysicalStockTarget(NSError **error) {
    int descriptor = open(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return FMLegacyFail(
            error, 4, @"The exposed Stock font directory could not be opened.",
            errno);
    }
    struct stat info = {0};
    int inspectResult = fstat(descriptor, &info);
    int savedError = inspectResult == 0 ? 0 : errno;
    int closeResult = close(descriptor);
    if (inspectResult != 0 || closeResult != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return FMLegacyFail(
            error, 4, @"The exposed Stock font directory is unsafe.",
            savedError != 0 ? savedError : closeResult != 0 ? errno : EPERM);
    }
    struct statfs filesystem = {0};
    if (statfs(FMMountSystemFontsLogicalPath.fileSystemRepresentation,
               &filesystem) != 0) {
        return FMLegacyFail(
            error, 4, @"The exposed Stock font filesystem is unavailable.",
            errno);
    }
    NSString *filesystemType =
        [NSString stringWithUTF8String:filesystem.f_fstypename] ?: @"";
    if ([filesystemType caseInsensitiveCompare:@"bindfs"] == NSOrderedSame ||
        (filesystem.f_flags & MNT_RDONLY) == 0) {
        return FMLegacyFail(
            error, 4,
            @"The original read-only Stock font directory was not exposed.",
            EBUSY);
    }
    return YES;
}

static BOOL FMLegacySyncDirectory(NSString *path, NSError **error) {
    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return FMLegacyFail(
            error, 6, @"A takeover directory could not be opened.", errno);
    }
    int syncResult = fsync(descriptor);
    int syncError = syncResult == 0 ? 0 : errno;
    int closeResult = close(descriptor);
    if ((syncResult != 0 && syncError != EINVAL && syncError != ENOTSUP) ||
        closeResult != 0) {
        return FMLegacyFail(
            error, 6, @"A takeover directory could not be synchronized.",
            syncResult != 0 ? syncError : errno);
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMLegacyReadJournal(NSError **error) {
    NSString *path = jbroot(FMLegacyFontTakeoverJournalLogicalPath);
    BOOL present = NO;
    struct stat info = {0};
    if (!FMLegacyInspectPath(path, &present, &info, error) || !present) {
        return nil;
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_gid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        FMLegacyFail(error, 7, @"The takeover journal is unsafe.", EPERM);
        return nil;
    }
    NSError *readError = nil;
    id object = FMReadJSONObjectAtPath(path, &readError);
    if (![object isKindOfClass:NSDictionary.class]) {
        FMLegacyFail(error, 7, @"The takeover journal is invalid.", EINVAL);
        return nil;
    }
    NSDictionary *journal = object;
    NSSet *phases = [NSSet setWithArray:@[
        @"planned", @"detached", @"profilePublished", @"sourceRemoved"
    ]];
    if (![journal[@"schemaVersion"] isEqual:@1] ||
        !FMLegacySafeBuild(journal[@"systemBuild"]) ||
        ![phases containsObject:journal[@"phase"]] ||
        ![journal[@"legacySourceLogicalPath"]
            isEqual:FMLegacyMirrorLogicalPath] ||
        ![journal[@"legacySourceDevice"] isKindOfClass:NSNumber.class] ||
        ![journal[@"legacySourceInode"] isKindOfClass:NSNumber.class] ||
        [journal[@"legacySourceInode"] unsignedLongLongValue] == 0 ||
        !FMLegacyJSONBoolean(journal[@"legacyMappingWasActive"]) ||
        !FMLegacySafeProfileID(journal[@"profileID"]) ||
        ![journal[@"profileName"] isEqual:FMLegacyProfileName] ||
        !FMLegacyJSONBoolean(journal[@"profileCreated"]) ||
        ![journal[@"replacementCount"] isKindOfClass:NSNumber.class] ||
        !FMLegacyJSONBoolean(journal[@"legacyContentCompared"])) {
        FMLegacyFail(error, 7,
                     @"The takeover journal contains invalid data.", EINVAL);
        return nil;
    }
    return journal;
}

static BOOL FMLegacyWriteJournal(NSDictionary<NSString *, id> *journal,
                                 NSError **error) {
    NSError *writeError = nil;
    if (FMWriteJSONObjectAtomically(
            journal, jbroot(FMLegacyFontTakeoverJournalLogicalPath), 0600,
            &writeError)) {
        return YES;
    }
    if (error != NULL) *error = writeError;
    return NO;
}

static NSString *FMLegacyPrepareAppProfilesRoot(NSString *systemBuild,
                                                NSError **error) {
    NSString *applicationSupport = FMLegacyPhysicalDirectory(
        FMMountResolvedMobileDataPath(
            @"/var/mobile/Library/Application Support"), error);
    if (applicationSupport == nil ||
        !FMEnsureSecureDirectoryTree(
            applicationSupport,
            @[ @"com.hmmzzz.fontmanager", @"ProfileLibrary", systemBuild,
               @"profiles" ],
            501, 501, 0700, error)) {
        return nil;
    }
    return [[[[applicationSupport
        stringByAppendingPathComponent:@"com.hmmzzz.fontmanager"]
        stringByAppendingPathComponent:@"ProfileLibrary"]
        stringByAppendingPathComponent:systemBuild]
        stringByAppendingPathComponent:@"profiles"];
}

static NSDictionary<NSString *, id> *FMLegacyReport(
    NSString *systemBuild,
    NSDictionary<NSString *, id> *journal,
    BOOL resumed,
    BOOL mutated) {
    BOOL profileCreated = [journal[@"profileCreated"] boolValue];
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"legacyFontTakeover",
        @"status" : profileCreated
            ? (resumed ? @"alreadyImported" : @"imported") : @"noChanges",
        @"systemBuild" : systemBuild,
        @"profileCreated" : profileCreated ? @YES : @NO,
        @"profileID" : profileCreated ? journal[@"profileID"] : NSNull.null,
        @"profileName" : journal[@"profileName"],
        @"replacementCount" : journal[@"replacementCount"],
        @"mappingWasActive" : journal[@"legacyMappingWasActive"],
        @"legacySourceRemoved" : @YES,
        @"contentCompared" : journal[@"legacyContentCompared"],
        @"unmountAttempted" : journal[@"legacyMappingWasActive"],
        @"unmountMethod" : [journal[@"legacyMappingWasActive"] boolValue]
            ? @"builtInBackendForceUnmount" : @"notRequired",
        @"backendDetachMayForce" : journal[@"legacyMappingWasActive"],
        @"mountBackendInvoked" : journal[@"legacyMappingWasActive"],
        @"journalResumed" : resumed ? @YES : @NO,
        @"filesystemMutated" : mutated ? @YES : @NO,
    };
}

NSDictionary<NSString *, id> *FMCreateLegacyFontTakeoverPreflight(
    NSError **error) {
    BOOL rootSupported = NO;
    NSString *mirrorLogicalPath =
        FMMountResolvedMirrorLogicalPath(&rootSupported, NULL);
    if (!rootSupported ||
        ![mirrorLogicalPath isEqual:FMLegacyMirrorLogicalPath]) {
        FMLegacyFail(
            error, 2, @"The mount storage root is unavailable for legacy takeover.",
            EINVAL);
        return nil;
    }

    BOOL autoMountConflict = NO;
    if (!FMLegacyProviderAutoMountConflictsWithSystemFonts(
            &autoMountConflict, error)) return nil;
    if (autoMountConflict) {
        FMLegacyFail(
            error, 2,
            @"Legacy Provider automatic mounting still targets the system Fonts tree.",
            EBUSY);
        return nil;
    }

    NSString *mirrorPath = jbroot(mirrorLogicalPath);
    BOOL mirrorPresent = NO;
    struct stat mirrorInfo = {0};
    if (!FMLegacyInspectPath(mirrorPath, &mirrorPresent, &mirrorInfo, error)) {
        return nil;
    }
    BOOL markFontOwned = NO;
    if (!FMLegacyMirrorOwnershipMarkerPresent(&markFontOwned, error)) return nil;

    NSDictionary *topology = FMCreateSystemFontsMountTopology(mirrorPath, error);
    if (topology == nil) return nil;
    if ([topology[@"hasConflict"] boolValue]) {
        FMLegacyFail(
            error, 3,
            @"Another mount overlaps the system font target or legacy source.",
            EBUSY);
        return nil;
    }
    BOOL active = [topology[@"active"] boolValue];
    if (active && (![topology[@"bindfs"] boolValue] ||
                   ![topology[@"readOnly"] boolValue] ||
                   ![topology[@"sourceMatchesExpectedMirror"] boolValue])) {
        FMLegacyFail(
            error, 3,
            @"The active font mapping is not the exact read-only legacy mapping.",
            EINVAL);
        return nil;
    }
    if (active && !mirrorPresent) {
        FMLegacyFail(
            error, 3, @"The active legacy mapping has no physical source.",
            ENOENT);
        return nil;
    }
    if (!mirrorPresent || markFontOwned) {
        return @{
            @"schemaVersion" : @1,
            @"operation" : @"preflightLegacyFontTakeover",
            @"status" : markFontOwned ? @"markFontOwned" : @"notNeeded",
            @"eligible" : @NO,
            @"active" : active ? @YES : @NO,
            @"mirrorPresent" : mirrorPresent ? @YES : @NO,
            @"markFontOwned" : markFontOwned ? @YES : @NO,
            @"contentScanned" : @NO,
            @"filesystemMutated" : @NO,
        };
    }
    if (!FMLegacyRequireSafeMirror(&mirrorInfo, error)) return nil;

    NSString *bootstrapRoot = FMLegacyPhysicalDirectory(jbroot(@"/"), error);
    if (bootstrapRoot == nil ||
        !FMValidateSecureDirectoryTree(
            bootstrapRoot, @[ @"bindfs", @"System", @"Library" ], 0, 0,
            error)) {
        return nil;
    }
    return @{
        @"schemaVersion" : @1,
        @"operation" : @"preflightLegacyFontTakeover",
        @"status" : active ? @"eligibleActive" : @"eligibleInactive",
        @"eligible" : @YES,
        @"active" : active ? @YES : @NO,
        @"mirrorPresent" : @YES,
        @"markFontOwned" : @NO,
        @"sourceLogicalPath" : mirrorLogicalPath,
        @"sourceDevice" : @((unsigned long long)mirrorInfo.st_dev),
        @"sourceInode" : @((unsigned long long)mirrorInfo.st_ino),
        @"contentScanned" : @NO,
        @"filesystemMutated" : @NO,
    };
}

static BOOL FMLegacyRequireJournalSource(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *journal,
    NSError **error) {
    BOOL present = NO;
    struct stat info = {0};
    if (!FMLegacyInspectPath(sourcePath, &present, &info, error) || !present ||
        !FMLegacyRequireSafeMirror(&info, error) ||
        (unsigned long long)info.st_dev !=
            [journal[@"legacySourceDevice"] unsignedLongLongValue] ||
        (unsigned long long)info.st_ino !=
            [journal[@"legacySourceInode"] unsignedLongLongValue]) {
        if (error != NULL && *error == nil) {
            FMLegacyFail(
                error, 7,
                @"The legacy source no longer matches the takeover journal.",
                EIO);
        }
        return NO;
    }
    return YES;
}

static BOOL FMLegacyRemoveConvertedSource(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *journal,
    NSError **error) {
    BOOL present = NO;
    if (!FMLegacyInspectPath(sourcePath, &present, NULL, error)) return NO;
    if (!present) return YES;
    if (!FMLegacyRequireJournalSource(sourcePath, journal, error)) return NO;
    NSError *removeError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:sourcePath
                                                  error:&removeError]) {
        if (error != NULL) *error = removeError;
        return NO;
    }
    return FMLegacySyncDirectory(sourcePath.stringByDeletingLastPathComponent,
                                 error);
}

NSDictionary<NSString *, id> *FMPerformLegacyFontTakeover(
    NSString *systemBuild,
    NSError **error) {
    if (getuid() != 0 || geteuid() != 0 ||
        !FMLegacySafeBuild(systemBuild)) {
        FMLegacyFail(
            error, 1,
            @"Legacy takeover requires a real root caller and safe build.",
            EPERM);
        return nil;
    }

    NSError *journalError = nil;
    NSDictionary *savedJournal = FMLegacyReadJournal(&journalError);
    if (journalError != nil) {
        if (error != NULL) *error = journalError;
        return nil;
    }
    if (savedJournal != nil &&
        ![savedJournal[@"systemBuild"] isEqual:systemBuild]) {
        FMLegacyFail(
            error, 7, @"The unfinished takeover belongs to another build.",
            EINVAL);
        return nil;
    }
    NSMutableDictionary<NSString *, id> *journal =
        savedJournal != nil ? [savedJournal mutableCopy] : nil;
    BOOL resumed = journal != nil;
    if ([journal[@"phase"] isEqual:@"sourceRemoved"]) {
        return FMLegacyReport(systemBuild, journal, YES, NO);
    }

    NSDictionary *preflight = nil;
    if (journal == nil) {
        preflight = FMCreateLegacyFontTakeoverPreflight(error);
        if (preflight == nil) return nil;
        if (![preflight[@"eligible"] boolValue]) {
            return @{
                @"schemaVersion" : @1,
                @"operation" : @"legacyFontTakeover",
                @"status" : @"notNeeded",
                @"systemBuild" : systemBuild,
                @"profileCreated" : @NO,
                @"profileID" : NSNull.null,
                @"profileName" : FMLegacyProfileName,
                @"replacementCount" : @0,
                @"mappingWasActive" : preflight[@"active"],
                @"legacySourceRemoved" : @NO,
                @"contentCompared" : @NO,
                @"unmountAttempted" : @NO,
                @"unmountMethod" : @"notRequired",
                @"backendDetachMayForce" : @NO,
                @"mountBackendInvoked" : @NO,
                @"journalResumed" : @NO,
                @"filesystemMutated" : @NO,
            };
        }
        NSString *profileID = [@"import-legacy-" stringByAppendingString:
            NSUUID.UUID.UUIDString.lowercaseString];
        journal = [@{
            @"schemaVersion" : @1,
            @"systemBuild" : systemBuild,
            @"phase" : @"planned",
            @"legacySourceLogicalPath" : FMLegacyMirrorLogicalPath,
            @"legacySourceDevice" : preflight[@"sourceDevice"],
            @"legacySourceInode" : preflight[@"sourceInode"],
            @"legacyMappingWasActive" : preflight[@"active"],
            @"profileID" : profileID,
            @"profileName" : FMLegacyProfileName,
            @"profileCreated" : @NO,
            @"replacementCount" : @0,
            @"legacyContentCompared" : @NO,
        } mutableCopy];
        if (!FMLegacyWriteJournal(journal, error)) return nil;
    }

    NSString *sourcePath = jbroot(FMLegacyMirrorLogicalPath);
    NSString *phase = journal[@"phase"];
    if ([phase isEqual:@"planned"]) {
        if (!FMLegacyRequireJournalSource(sourcePath, journal, error)) return nil;
        NSDictionary *topology = FMCreateSystemFontsMountTopology(sourcePath, error);
        if (topology == nil || [topology[@"hasConflict"] boolValue]) {
            if (error != NULL && *error == nil) {
                FMLegacyFail(error, 8,
                             @"The legacy mapping topology changed.", EBUSY);
            }
            return nil;
        }
        BOOL active = [topology[@"active"] boolValue];
        if (active && (![topology[@"bindfs"] boolValue] ||
                       ![topology[@"readOnly"] boolValue] ||
                       ![topology[@"sourceMatchesExpectedMirror"] boolValue])) {
            FMLegacyFail(error, 8,
                         @"The legacy mapping changed before detach.", EINVAL);
            return nil;
        }
        if (active) {
            NSError *detachError = nil;
            NSDictionary *detachment =
                FMDetachManagedSystemFontsForPackageLifecycle(&detachError);
            if (detachment == nil) {
                if (error != NULL) *error = detachError;
                return nil;
            }
        }
        NSDictionary *after = FMCreateSystemFontsMountTopology(sourcePath, error);
        if (after == nil || [after[@"active"] boolValue] ||
            [after[@"hasConflict"] boolValue] ||
            !FMLegacyRequirePhysicalStockTarget(error)) {
            if (error != NULL && *error == nil) {
                FMLegacyFail(error, 8,
                             @"The original Stock tree was not exposed.", EBUSY);
            }
            return nil;
        }
        journal[@"phase"] = @"detached";
        if (!FMLegacyWriteJournal(journal, error)) return nil;
        phase = @"detached";
    }

    if ([phase isEqual:@"detached"]) {
        if (!FMLegacyRequireJournalSource(sourcePath, journal, error) ||
            !FMLegacyRequirePhysicalStockTarget(error)) {
            return nil;
        }
        NSString *profilesRoot =
            FMLegacyPrepareAppProfilesRoot(systemBuild, error);
        if (profilesRoot == nil) return nil;
        NSError *importError = nil;
        NSDictionary *import = FMImportLegacyFontTreeAsProfile(
            sourcePath, FMMountSystemFontsLogicalPath, profilesRoot,
            systemBuild, journal[@"profileID"], journal[@"profileName"],
            501, 501, &importError);
        if (import == nil) {
            if (error != NULL) *error = importError;
            return nil;
        }
        journal[@"phase"] = @"profilePublished";
        journal[@"profileCreated"] = import[@"profileCreated"];
        journal[@"replacementCount"] = import[@"replacementCount"];
        journal[@"legacyContentCompared"] = @YES;
        if (!FMLegacyWriteJournal(journal, error)) return nil;
        phase = @"profilePublished";
    }

    if ([phase isEqual:@"profilePublished"]) {
        if (!FMLegacyRemoveConvertedSource(sourcePath, journal, error)) return nil;
        journal[@"phase"] = @"sourceRemoved";
        if (!FMLegacyWriteJournal(journal, error)) return nil;
    }
    return FMLegacyReport(systemBuild, journal, resumed, YES);
}

BOOL FMCompleteLegacyFontTakeover(NSString *systemBuild, NSError **error) {
    if (getuid() != 0 || geteuid() != 0 ||
        !FMLegacySafeBuild(systemBuild)) {
        return FMLegacyFail(
            error, 1,
            @"Legacy takeover completion requires root and a safe build.",
            EPERM);
    }
    NSError *journalError = nil;
    NSDictionary *journal = FMLegacyReadJournal(&journalError);
    if (journalError != nil) {
        if (error != NULL) *error = journalError;
        return NO;
    }
    if (journal == nil) return YES;
    if (![journal[@"systemBuild"] isEqual:systemBuild] ||
        ![journal[@"phase"] isEqual:@"sourceRemoved"]) {
        return FMLegacyFail(
            error, 7, @"The legacy takeover is not ready for completion.",
            EINVAL);
    }
    NSString *journalPath = jbroot(FMLegacyFontTakeoverJournalLogicalPath);
    if (unlink(journalPath.fileSystemRepresentation) != 0) {
        return FMLegacyFail(
            error, 7, @"The completed takeover journal could not be removed.",
            errno);
    }
    return FMLegacySyncDirectory(journalPath.stringByDeletingLastPathComponent,
                                 error);
}
