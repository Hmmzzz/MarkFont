#import "FMDeviceFontCatalog.h"

#import <roothide.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMEnvironmentProbe.h"
#import "FMFileStore.h"
#import "FMFontCatalog.h"
#import "FMMountPaths.h"

NSString *const FMDeviceFontCatalogErrorDomain =
    @"com.hmmzzz.fontmanager.devicefontcatalog";

static BOOL FMDeviceCatalogFail(NSError **error,
                                NSString *description,
                                NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) {
            userInfo[NSUnderlyingErrorKey] = underlying;
        }
        *error = [NSError errorWithDomain:FMDeviceFontCatalogErrorDomain
                                     code:1
                                 userInfo:userInfo];
    }
    return NO;
}

NSDictionary<NSString *, id> *FMCreateDeviceFontCatalogPreview(
    NSString *confirmedSystemBuild,
    NSError **error) {
    if (geteuid() != 0 || confirmedSystemBuild.length == 0 ||
        confirmedSystemBuild.length > 32 ||
        confirmedSystemBuild.pathComponents.count != 1) {
        FMDeviceCatalogFail(error, @"The device or system build is unavailable.", nil);
        return nil;
    }

    NSDictionary *environment = FMCreateEnvironmentStatus();
    NSDictionary *state = environment[@"state"];
    if (![environment[@"engineState"] isEqual:@"ready"] ||
        ![environment[@"system"][@"productBuildVersion"]
            isEqual:confirmedSystemBuild] ||
        ![state[@"present"] boolValue] || ![state[@"valid"] boolValue] ||
        ![state[@"systemBuild"] isEqual:confirmedSystemBuild] ||
        ![state[@"mirrorState"] isEqual:@"clean"] ||
        !FMMountManagedMappingIsActive(error)) {
        if (error == NULL || *error == nil) {
            FMDeviceCatalogFail(error,
                                @"The managed font workspace is unavailable.", nil);
        }
        return nil;
    }

    NSString *baselinePath = [[jbroot(@"/var/lib/fontmanager/baseline")
        stringByAppendingPathComponent:confirmedSystemBuild]
        stringByAppendingPathComponent:@"manifest.json"];
    struct stat baselineInfo = {0};
    if (lstat(baselinePath.fileSystemRepresentation, &baselineInfo) != 0 ||
        !S_ISREG(baselineInfo.st_mode) || baselineInfo.st_uid != 0 ||
        (baselineInfo.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        FMDeviceCatalogFail(error, @"The saved Stock catalog is unavailable.", nil);
        return nil;
    }
    NSError *baselineError = nil;
    NSDictionary *baselineManifest = FMReadJSONObjectAtPath(baselinePath, &baselineError);
    NSString *baselineHash = baselineManifest != nil &&
            FMValidateManifestDocument(baselineManifest, &baselineError)
        ? FMSHA256ForJSONObject(baselineManifest, &baselineError)
        : nil;
    if (baselineHash.length == 0) {
        FMDeviceCatalogFail(error,
                            @"The saved Stock catalog is invalid.",
                            baselineError);
        return nil;
    }

    NSError *catalogError = nil;
    NSDictionary *catalog = FMCreateFontCatalogFromManifest(
        baselineManifest, confirmedSystemBuild, baselineHash, &catalogError);
    if (catalog == nil) {
        FMDeviceCatalogFail(error, @"The Stock filename catalog could not be generated.",
                            catalogError);
        return nil;
    }

    return @{
        @"schemaVersion" : @1,
        @"operation" : @"inspectFontCatalog",
        @"status" : @"reviewRequired",
        @"systemBuild" : confirmedSystemBuild,
        @"sourceManifestSHA256" : baselineHash,
        @"matchingMode" : catalog[@"matchingMode"],
        @"sourceRegularFileCount" : catalog[@"sourceRegularFileCount"],
        @"fontFileCount" : @([catalog[@"files"] count]),
        @"excludedRegularFileCount" : @([catalog[@"excludedRegularPaths"] count]),
        @"excludedRegularPaths" : catalog[@"excludedRegularPaths"],
        @"readOnly" : @YES,
        @"mirrorContentScanned" : @NO,
        @"filesystemMutated" : @NO,
        @"mappingChanged" : @NO,
        @"stateChanged" : @NO,
        @"restartRequested" : @NO,
        @"catalog" : catalog,
    };
}
