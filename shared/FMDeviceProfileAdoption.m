#import "FMDeviceProfileAdoption.h"

#import <roothide.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMDeviceProfileActivation.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMProfileAdoption.h"
#import "FMSecureDirectory.h"

NSString *const FMDeviceProfileAdoptionErrorDomain =
    @"com.hmmzzz.fontmanager.device-profile-adoption";

static BOOL FMDeviceAdoptionFail(NSError **error,
                                 NSInteger code,
                                 NSString *description,
                                 NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:FMDeviceProfileAdoptionErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

NSDictionary<NSString *, id> *FMAdoptDeviceProfile(
    NSString *confirmedSystemBuild,
    NSString *profileID,
    NSError **error) {
    if (geteuid() != 0) {
        FMDeviceAdoptionFail(error, 1,
                             @"Profile adoption requires effective uid 0.", nil);
        return nil;
    }

    NSError *preflightError = nil;
    NSDictionary *preflight = FMCreateDeviceProfileActivationPreflight(
        confirmedSystemBuild, profileID, &preflightError);
    if (preflight == nil) {
        FMDeviceAdoptionFail(error, 2,
                             @"Profile adoption preflight did not pass.",
                             preflightError);
        return nil;
    }

    NSString *manifestPath = [[jbroot(@"/var/lib/fontmanager/baseline")
        stringByAppendingPathComponent:confirmedSystemBuild]
        stringByAppendingPathComponent:@"manifest.json"];
    NSError *catalogError = nil;
    id manifestObject = FMReadJSONObjectAtPath(manifestPath, &catalogError);
    if (![manifestObject isKindOfClass:NSDictionary.class] ||
        !FMValidateManifestDocument(manifestObject, &catalogError)) {
        FMDeviceAdoptionFail(error, 3,
                             @"The verified Stock baseline is unavailable.",
                             catalogError);
        return nil;
    }
    NSDictionary *manifest = manifestObject;
    NSString *manifestHash = FMSHA256ForJSONObject(manifest, &catalogError);
    if (![manifestHash isEqual:preflight[@"baselineManifestSHA256"]]) {
        FMDeviceAdoptionFail(error, 3,
                             @"The Stock baseline changed after preflight.",
                             catalogError);
        return nil;
    }
    NSDictionary *catalog = FMCreateFontCatalogFromManifest(
        manifest, confirmedSystemBuild, manifestHash, &catalogError);
    if (catalog == nil) {
        FMDeviceAdoptionFail(error, 3,
                             @"The current-build font catalog is unavailable.",
                             catalogError);
        return nil;
    }

    NSString *varLib = jbroot(@"/var/lib");
    NSError *directoryError = nil;
    if (!FMEnsureSecureDirectoryTree(varLib, @[ @"fontmanager", @"profiles" ],
                                     0, 0, 0755, &directoryError)) {
        FMDeviceAdoptionFail(error, 4,
                             @"The privileged Profile root is unavailable.",
                             directoryError);
        return nil;
    }

    NSString *sourceProfilesRoot = [[[[jbroot(
        @"/var/mobile/Library/Application Support/com.hmmzzz.fontmanager")
        stringByAppendingPathComponent:@"ProfileLibrary"]
        stringByAppendingPathComponent:confirmedSystemBuild]
        stringByAppendingPathComponent:@"profiles"] copy];
    NSString *destinationProfilesRoot = jbroot(@"/var/lib/fontmanager/profiles");
    NSError *adoptionError = nil;
    NSDictionary *adoption = FMPublishProfileAdoptionAtRoots(
        sourceProfilesRoot, destinationProfilesRoot, profileID,
        confirmedSystemBuild, catalog, 0, 0, &adoptionError);
    if (adoption == nil ||
        ![adoption[@"profileJSONSHA256"]
            isEqual:preflight[@"profileJSONSHA256"]] ||
        ![adoption[@"replacementCount"]
            isEqual:preflight[@"replacementCount"]]) {
        FMDeviceAdoptionFail(error, 5,
                             @"The privileged Profile could not be published exactly.",
                             adoptionError);
        return nil;
    }

    NSMutableDictionary *report = [adoption mutableCopy];
    report[@"preflightEligible"] = @YES;
    report[@"profileAdopted"] = @YES;
    return report;
}
