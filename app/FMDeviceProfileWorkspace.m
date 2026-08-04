#import "FMDeviceProfileWorkspace.h"

#import "FMLocalization.h"

#import <roothide.h>

#import "FMFontPackageAnalyzer.h"
#import "FMFontProfileStore.h"
#import "FMHelperClient.h"

NSString *const FMDeviceProfileWorkspaceErrorDomain =
    @"com.hmmzzz.fontmanager.device-workspace";

typedef NS_ENUM(NSInteger, FMDeviceProfileWorkspaceErrorCode) {
    FMDeviceProfileWorkspaceErrorEnvironment = 1,
    FMDeviceProfileWorkspaceErrorUnknownProfile = 2,
    FMDeviceProfileWorkspaceErrorChangesUnavailable = 3,
};

static BOOL FMDeviceWorkspaceFail(NSError **error,
                                  FMDeviceProfileWorkspaceErrorCode code,
                                  NSString *message,
                                  NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:message
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMDeviceProfileWorkspaceErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

@interface FMDeviceProfileWorkspace ()
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *status;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *catalogPreview;
@property(nonatomic, strong, nullable) NSDate *lastStatusDate;
@end

@implementation FMDeviceProfileWorkspace

- (NSString *)profileStoreRoot {
    NSString *systemBuild = [self.status[@"system"][@"productBuildVersion"]
        isKindOfClass:NSString.class]
        ? self.status[@"system"][@"productBuildVersion"]
        : nil;
    if (systemBuild.length == 0) return nil;
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"._-"];
    if ([systemBuild rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        return nil;
    }
    NSArray<NSURL *> *urls =
        [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                             inDomains:NSUserDomainMask];
    NSString *applicationSupport = urls.firstObject.path;
    if (applicationSupport.length == 0) {
        applicationSupport = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Library/Application Support"];
    }
    return [[[[applicationSupport
        stringByAppendingPathComponent:@"com.hmmzzz.fontmanager"]
        stringByAppendingPathComponent:@"ProfileLibrary"]
        stringByAppendingPathComponent:systemBuild]
        stringByAppendingPathComponent:@"profiles"];
}

- (BOOL)loadCatalogIfNeeded:(NSError **)error {
    if (self.catalogPreview != nil) return YES;
    if (![self prepareIfNeeded:error]) return NO;
    NSString *systemBuild = self.status[@"system"][@"productBuildVersion"];
    NSError *catalogError = nil;
    self.catalogPreview = FMFetchFontCatalogFromHelper(systemBuild, &catalogError);
    if (self.catalogPreview == nil) {
        return FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                                     FMLocalized(@"暂时无法读取本机系统字体清单。"), catalogError);
    }
    return YES;
}

- (BOOL)allowsChanges {
    NSDictionary *capabilities = self.status[@"capabilities"];
    NSDictionary *state = self.status[@"state"];
    return [self.status[@"engineState"] isEqual:@"ready"] &&
           [capabilities[@"stageProfile"] boolValue] &&
           [capabilities[@"stageStock"] boolValue] &&
           ![state[@"restartRequired"] boolValue] &&
           [state[@"mirrorState"] isEqual:@"clean"];
}

- (BOOL)allowsRestart {
    return [self.status[@"engineState"] isEqual:@"ready"] &&
           [self.status[@"capabilities"][@"respring"] boolValue];
}

- (NSArray<NSString *> *)managedRelativePaths {
    NSDictionary *catalog = self.catalogPreview[@"catalog"];
    NSArray *files = [catalog[@"files"] isKindOfClass:NSArray.class] ? catalog[@"files"] : @[];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:files.count];
    for (NSDictionary *file in files) {
        NSString *relativePath = [file[@"relativePath"] isKindOfClass:NSString.class]
            ? file[@"relativePath"]
            : nil;
        if (relativePath != nil) [paths addObject:relativePath];
    }
    return paths;
}

- (BOOL)prepareIfNeeded:(NSError **)error {
    if (self.status != nil && self.lastStatusDate != nil &&
        -self.lastStatusDate.timeIntervalSinceNow < 1.0) {
        if ([self.status[@"engineState"] isEqual:@"ready"]) return YES;
        return FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                                     FMLocalized(@"字体引擎尚未准备好。"), nil);
    }

    NSError *statusError = nil;
    NSDictionary *status = FMFetchStatusFromHelper(&statusError);
    if (status == nil) {
        return FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                                     FMLocalized(@"暂时无法读取这台设备的字体环境。"), statusError);
    }
    self.status = status;
    self.lastStatusDate = NSDate.date;
    if (![status[@"engineState"] isEqual:@"ready"]) {
        return FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                                     FMLocalized(@"字体引擎尚未准备好。"), nil);
    }
    NSDictionary *state = [status[@"state"] isKindOfClass:NSDictionary.class]
        ? status[@"state"]
        : nil;
    if ([state[@"restartRequired"] boolValue]) {
        NSString *systemBuild = status[@"system"][@"productBuildVersion"];
        NSError *reconcileError = nil;
        NSDictionary *report = FMReconcileAfterRestartFromHelper(
            systemBuild, &reconcileError);
        if (report == nil) {
            return FMDeviceWorkspaceFail(
                error, FMDeviceProfileWorkspaceErrorEnvironment,
                FMLocalized(@"暂时无法确认重启后的字体状态，请重新打开 App 后再试。"),
                reconcileError);
        }
        if ([report[@"status"] isEqual:@"reconciled"] ||
            [report[@"status"] isEqual:@"alreadyReconciled"]) {
            status = FMFetchStatusFromHelper(&reconcileError);
            if (status == nil || ![status[@"engineState"] isEqual:@"ready"]) {
                return FMDeviceWorkspaceFail(
                    error, FMDeviceProfileWorkspaceErrorEnvironment,
                    FMLocalized(@"字体已重启，但暂时无法刷新当前状态。"), reconcileError);
            }
            self.status = status;
            self.lastStatusDate = NSDate.date;
        }
    }
    return YES;
}

- (NSDictionary<NSString *, id> *)currentState:(NSError **)error {
    if (self.status == nil && ![self prepareIfNeeded:error]) return nil;
    NSDictionary *state = [self.status[@"state"] isKindOfClass:NSDictionary.class]
        ? self.status[@"state"]
        : nil;
    if (state == nil) {
        FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                              FMLocalized(@"设备没有返回有效的字体状态。"), nil);
    }
    return state;
}

- (NSDictionary<NSString *, id> *)environmentStatus:(NSError **)error {
    NSError *statusError = nil;
    NSDictionary *status = FMFetchStatusFromHelper(&statusError);
    if (status == nil) {
        FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                              FMLocalized(@"暂时无法读取这台设备的运行环境。"), statusError);
        return nil;
    }
    self.status = status;
    self.lastStatusDate = NSDate.date;
    return status;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)availableProfiles {
    NSString *systemBuild = self.status[@"system"][@"productBuildVersion"];
    NSString *profilesRoot = [self profileStoreRoot];
    if (systemBuild.length == 0 || profilesRoot.length == 0) return @[];
    NSArray<NSDictionary<NSString *, id> *> *profiles =
        FMListFontProfilesAtRoot(profilesRoot, systemBuild, nil);
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *summaries =
        [NSMutableArray arrayWithCapacity:profiles.count];
    for (NSDictionary<NSString *, id> *profile in profiles) {
        NSString *profileID = profile[@"id"];
        NSString *name = profile[@"name"];
        if ([profileID isKindOfClass:NSString.class] &&
            [name isKindOfClass:NSString.class]) {
            [summaries addObject:@{ @"id" : profileID, @"name" : name }];
        }
    }
    return summaries;
}

- (NSDictionary<NSString *, id> *)detailsForProfileID:(NSString *)profileID
                                                   error:(NSError **)error {
    if (![self loadCatalogIfNeeded:error]) return nil;
    if (profileID != nil) {
        NSString *systemBuild = self.status[@"system"][@"productBuildVersion"];
        NSString *profilesRoot = [self profileStoreRoot];
        if (profilesRoot.length == 0) {
            FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                                  FMLocalized(@"字体库目录不可用。"), nil);
            return nil;
        }
        return FMFontProfileDetailsAtRoot(profilesRoot, profileID, systemBuild, error);
    }
    NSString *systemBuild = self.status[@"system"][@"productBuildVersion"];
    NSString *stockRoot = systemBuild.length > 0
        ? [jbroot(@"/var/lib/fontmanager/stock") stringByAppendingPathComponent:systemBuild]
        : nil;
    NSDictionary<NSString *, id> *stockProfile = @{
        @"replacements" : @[
            @{ @"relativePath" : @"LanguageSupport/PingFang.ttc",
               @"fileName" : @"LanguageSupport/PingFang.ttc" },
            @{ @"relativePath" : @"Core/SFUI.ttf",
               @"fileName" : @"Core/SFUI.ttf" },
        ],
    };
    NSMutableDictionary<NSString *, id> *details = [@{
        @"id" : NSNull.null,
        @"name" : FMLocalized(@"系统默认"),
        @"relativePaths" : self.managedRelativePaths,
    } mutableCopy];
    if (stockRoot != nil) {
        [details addEntriesFromDictionary:FMFontProfilePreviewPaths(stockProfile, stockRoot)];
    }
    return details;
}

- (NSDictionary<NSString *, id> *)previewFontPackageAtPath:(NSString *)sourcePath
                                                       error:(NSError **)error {
    if (![self loadCatalogIfNeeded:error]) return nil;
    NSDictionary *catalog = [self.catalogPreview[@"catalog"] isKindOfClass:NSDictionary.class]
        ? self.catalogPreview[@"catalog"]
        : nil;
    if (catalog == nil) {
        FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                              FMLocalized(@"本机系统字体清单无效。"), nil);
        return nil;
    }
    return FMAnalyzeFontPackageAtPath(sourcePath, catalog, error);
}

- (NSDictionary<NSString *, id> *)saveFontPackageAtPath:(NSString *)sourcePath
                                              profileName:(NSString *)profileName
                                                    error:(NSError **)error {
    if (![self loadCatalogIfNeeded:error]) return nil;
    NSDictionary *catalog = [self.catalogPreview[@"catalog"] isKindOfClass:NSDictionary.class]
        ? self.catalogPreview[@"catalog"]
        : nil;
    NSString *profilesRoot = [self profileStoreRoot];
    if (catalog == nil || profilesRoot.length == 0) {
        FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                              FMLocalized(@"本机字体目录或字体库位置无效。"), nil);
        return nil;
    }
    NSString *profileID = [@"import-" stringByAppendingString:
        NSUUID.UUID.UUIDString.lowercaseString];
    return FMImportFontPackageProfile(sourcePath, catalog, profilesRoot,
                                      profileID, profileName, error);
}

- (BOOL)changesUnavailable:(NSError **)error {
    return FMDeviceWorkspaceFail(
        error, FMDeviceProfileWorkspaceErrorChangesUnavailable,
        FMLocalized(@"这项管理功能暂时不可用。"), nil);
}

- (BOOL)stageProfileID:(NSString *)profileID error:(NSError **)error {
    if (![self prepareIfNeeded:error]) return NO;
    if (!self.allowsChanges) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorChangesUnavailable,
            FMLocalized(@"当前还有未完成的字体操作，暂时不能切换。"), nil);
    }

    NSString *systemBuild = self.status[@"system"][@"productBuildVersion"];
    NSError *operationError = nil;
    if (profileID != nil &&
        FMAdoptProfileFromHelper(systemBuild, profileID, &operationError) == nil) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorEnvironment,
            FMLocalized(@"暂时无法准备这款字体，请确认字体方案仍完整。"), operationError);
    }

    NSDictionary *report = FMStageProfileFromHelper(
        systemBuild, profileID, &operationError);
    if (report == nil) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorEnvironment,
            profileID != nil
                ? FMLocalized(@"字体切换没有完成，请稍后重试。")
                : FMLocalized(@"系统默认字体恢复没有完成，请稍后重试。"),
            operationError);
    }

    self.status = nil;
    self.lastStatusDate = nil;
    return YES;
}

- (BOOL)requestRespring:(NSError **)error {
    if (![self prepareIfNeeded:error]) return NO;
    if (!self.allowsRestart) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorChangesUnavailable,
            FMLocalized(@"这台设备当前无法执行 Respring。"), nil);
    }
    NSDictionary *state = [self currentState:error];
    if (state == nil) return NO;
    if (![state[@"restartRequired"] boolValue] ||
        ![state[@"mirrorState"] isEqual:@"clean"]) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorChangesUnavailable,
            FMLocalized(@"当前没有等待 Respring 应用的字体。"), nil);
    }
    NSString *systemBuild = self.status[@"system"][@"productBuildVersion"];
    NSError *restartError = nil;
    NSDictionary *report = FMRequestRespringFromHelper(
        systemBuild, &restartError);
    if (report == nil) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorEnvironment,
            FMLocalized(@"暂时无法发起 Respring。"),
            restartError);
    }
    return [report[@"status"] isEqual:@"armed"];
}

- (BOOL)setAutomaticRespringEnabled:(BOOL)enabled error:(NSError **)error {
    NSError *statusError = nil;
    NSDictionary<NSString *, id> *status = FMFetchStatusFromHelper(&statusError);
    NSDictionary<NSString *, id> *state = [status[@"state"]
        isKindOfClass:NSDictionary.class] ? status[@"state"] : nil;
    NSString *systemBuild = [status[@"system"][@"productBuildVersion"]
        isKindOfClass:NSString.class]
        ? status[@"system"][@"productBuildVersion"]
        : nil;
    if (status == nil || systemBuild.length == 0 ||
        ![state[@"present"] boolValue] || ![state[@"valid"] boolValue]) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorEnvironment,
            FMLocalized(@"当前无法读取自动 Respring 设置。"), statusError);
    }

    NSError *policyError = nil;
    NSDictionary *report = FMSetAutomaticRespringFromHelper(
        systemBuild, enabled, &policyError);
    if (report == nil) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorEnvironment,
            FMLocalized(@"自动 Respring 设置没有保存，请稍后重试。"), policyError);
    }

    NSDictionary *updatedStatus = FMFetchStatusFromHelper(&statusError);
    NSDictionary *updatedState = [updatedStatus[@"state"]
        isKindOfClass:NSDictionary.class] ? updatedStatus[@"state"] : nil;
    if (updatedStatus == nil || ![updatedState[@"valid"] boolValue] ||
        [updatedState[@"autoRespring"] boolValue] != enabled) {
        return FMDeviceWorkspaceFail(
            error, FMDeviceProfileWorkspaceErrorEnvironment,
            FMLocalized(@"自动 Respring 设置已写入，但状态确认失败。"), statusError);
    }
    self.status = updatedStatus;
    self.lastStatusDate = NSDate.date;
    return YES;
}

- (BOOL)resetWorkspace:(NSError **)error {
    return [self changesUnavailable:error];
}

- (BOOL)deleteProfileID:(NSString *)profileID error:(NSError **)error {
    if (![self prepareIfNeeded:error]) return NO;
    NSDictionary<NSString *, id> *state = [self currentState:error];
    if (state == nil) return NO;
    if ([state[@"confirmedProfileID"] isEqual:profileID] ||
        [state[@"workingProfileID"] isEqual:profileID]) {
        return FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorChangesUnavailable,
                                     FMLocalized(@"这款字体仍在使用，暂时不能删除。"), nil);
    }
    NSString *systemBuild = self.status[@"system"][@"productBuildVersion"];
    NSString *profilesRoot = [self profileStoreRoot];
    if (profilesRoot.length == 0) {
        return FMDeviceWorkspaceFail(error, FMDeviceProfileWorkspaceErrorEnvironment,
                                     FMLocalized(@"字体库目录不可用。"), nil);
    }
    return FMDeleteFontProfileAtRoot(profilesRoot, profileID, systemBuild, error);
}

- (BOOL)importReplacementAtPath:(NSString *)sourcePath
                      profileID:(NSString *)profileID
                           name:(NSString *)name
                     fontFileID:(NSString *)fontFileID
                   relativePath:(NSString *)relativePath
                          error:(NSError **)error {
    (void)sourcePath;
    (void)profileID;
    (void)name;
    (void)fontFileID;
    (void)relativePath;
    return [self changesUnavailable:error];
}

@end
