#import "FMProfileMirrorMatcher.h"

#import "FMDataModel.h"
#import "FMProfileAdoptionValidator.h"

NSString *const FMProfileMirrorMatcherErrorDomain =
    @"com.hmmzzz.fontmanager.profile-mirror-matcher";

static BOOL FMMirrorMatcherFail(NSError **error,
                                NSString *description,
                                NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMProfileMirrorMatcherErrorDomain
                                     code:1
                                 userInfo:userInfo];
    }
    return NO;
}

static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *FMMirrorEntriesByPath(
    NSDictionary<NSString *, id> *manifest) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in manifest[@"entries"]) {
        result[entry[@"relativePath"]] = entry;
    }
    return result;
}

BOOL FMManifestsMatchWorkingProfile(
    NSDictionary<NSString *, id> *stockManifest,
    NSDictionary<NSString *, id> *mirrorManifest,
    NSString *profilesRoot,
    id workingProfileID,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error) {
    NSError *validationError = nil;
    if (!FMValidateManifestDocument(stockManifest, &validationError) ||
        !FMValidateManifestDocument(mirrorManifest, &validationError) ||
        !FMValidateFontCatalogDocument(catalog, &validationError) ||
        ![catalog[@"systemBuild"] isEqual:systemBuild]) {
        return FMMirrorMatcherFail(error, @"Working Profile match inputs are invalid.",
                                   validationError);
    }

    NSDictionary *preview = nil;
    if (workingProfileID != nil && workingProfileID != NSNull.null) {
        if (![workingProfileID isKindOfClass:NSString.class] || profilesRoot.length == 0) {
            return FMMirrorMatcherFail(error,
                                       @"The working Profile identifier is invalid.", nil);
        }
        preview = FMCreateProfileAdoptionPreviewAtRoot(
            profilesRoot, workingProfileID, systemBuild, catalog, &validationError);
        if (preview == nil) {
            return FMMirrorMatcherFail(error,
                                       @"The working privileged Profile is invalid.",
                                       validationError);
        }
    }

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *targets =
        [NSMutableDictionary dictionary];
    for (NSDictionary *target in preview[@"targets"] ?: @[]) {
        targets[target[@"relativePath"]] = target;
    }
    NSDictionary *stockByPath = FMMirrorEntriesByPath(stockManifest);
    NSDictionary *mirrorByPath = FMMirrorEntriesByPath(mirrorManifest);
    if (stockByPath.count != mirrorByPath.count) return NO;

    for (NSString *relativePath in stockByPath) {
        NSDictionary *stock = stockByPath[relativePath];
        NSDictionary *mirror = mirrorByPath[relativePath];
        if (mirror == nil || ![mirror[@"type"] isEqual:stock[@"type"]] ||
            ![mirror[@"mode"] isEqual:stock[@"mode"]] ||
            ![mirror[@"uid"] isEqual:stock[@"uid"]] ||
            ![mirror[@"gid"] isEqual:stock[@"gid"]]) {
            return NO;
        }
        if ([stock[@"type"] isEqual:@"regular"]) {
            NSDictionary *target = targets[relativePath];
            NSString *expectedHash = target != nil
                ? target[@"sha256"]
                : stock[@"sha256"];
            if (![mirror[@"sha256"] isEqual:expectedHash]) return NO;
        } else if ([stock[@"type"] isEqual:@"symlink"] &&
                   ![mirror[@"linkTarget"] isEqual:stock[@"linkTarget"]]) {
            return NO;
        }
    }
    return YES;
}
