#import "FMSystemFontLayout.h"

NSString *const FMSystemFontLayoutErrorDomain =
    @"com.hmmzzz.fontmanager.system-font-layout";

static BOOL FMSystemFontLayoutSafeBuild(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length > 0 &&
        value.length <= 32 && !value.isAbsolutePath &&
        value.pathComponents.count == 1 &&
        [value.lastPathComponent isEqual:value] &&
        ![value isEqual:@"."] && ![value isEqual:@".."];
}

static BOOL FMSystemFontLayoutNumericVersion(NSString *productVersion,
                                             NSInteger *majorVersion) {
    if (![productVersion isKindOfClass:NSString.class] ||
        productVersion.length == 0 || productVersion.length > 32 ||
        majorVersion == NULL) {
        return NO;
    }
    NSCharacterSet *nonDecimal =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789"]
            .invertedSet;
    NSArray<NSString *> *components =
        [productVersion componentsSeparatedByString:@"."];
    if (components.count == 0) return NO;
    for (NSString *component in components) {
        if (component.length == 0 ||
            [component rangeOfCharacterFromSet:nonDecimal].location !=
                NSNotFound) {
            return NO;
        }
    }
    NSString *majorComponent = components.firstObject;
    if (majorComponent.length > 2) return NO;
    NSInteger parsedMajor = majorComponent.integerValue;
    if (parsedMajor <= 0) return NO;
    *majorVersion = parsedMajor;
    return YES;
}

FMSystemFontLayout FMSystemFontLayoutForProductVersion(
    NSString *productVersion) {
    NSInteger majorVersion = 0;
    if (!FMSystemFontLayoutNumericVersion(productVersion, &majorVersion)) {
        return FMSystemFontLayoutUnsupported;
    }
    if (majorVersion >= 16 && majorVersion <= 17) {
        return FMSystemFontLayoutPrimaryFonts;
    }
    if (majorVersion >= 18 && majorVersion <= 26) {
        return FMSystemFontLayoutFontServicesCorePrivate;
    }
    return FMSystemFontLayoutUnsupported;
}

FMSystemFontLayout FMCurrentSystemFontLayout(
    NSString *confirmedSystemBuild,
    NSError **error) {
    NSDictionary *version = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    NSString *productVersion = [version[@"ProductVersion"]
        isKindOfClass:NSString.class] ? version[@"ProductVersion"] : nil;
    NSString *productBuildVersion = [version[@"ProductBuildVersion"]
        isKindOfClass:NSString.class] ? version[@"ProductBuildVersion"] : nil;
    FMSystemFontLayout layout =
        FMSystemFontLayoutForProductVersion(productVersion);
    BOOL confirmedBuildValid = confirmedSystemBuild == nil ||
        (FMSystemFontLayoutSafeBuild(confirmedSystemBuild) &&
         [productBuildVersion isEqual:confirmedSystemBuild]);
    if (layout != FMSystemFontLayoutUnsupported &&
        FMSystemFontLayoutSafeBuild(productBuildVersion) &&
        confirmedBuildValid) {
        return layout;
    }

    if (error != NULL) {
        NSString *description = layout == FMSystemFontLayoutUnsupported
            ? @"The current iOS version has no supported font-layout policy."
            : @"The confirmed system build does not match the current device.";
        *error = [NSError errorWithDomain:FMSystemFontLayoutErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : description}];
    }
    return FMSystemFontLayoutUnsupported;
}
