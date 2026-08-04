#import "FMLegacyProviderAutoMountPolicy.h"

NSString *const FMLegacyProviderAutoMountPolicyErrorDomain =
    @"com.hmmzzz.fontmanager.provider-auto-mount-policy";

static NSString *const FMLegacyProviderSystemFontsPath = @"/System/Library/Fonts";
static NSString *const FMLegacyProviderSupportedRoot = @".jbroot/bindfs";

static BOOL FMLegacyProviderPathIsEqualOrDescendant(NSString *path,
                                              NSString *root) {
    if ([path isEqual:root]) return YES;
    NSString *prefix = [root isEqual:@"/"]
        ? @"/" : [root stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static BOOL FMLegacyProviderPathOverlapsSystemFonts(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) {
        return NO;
    }
    NSString *candidate = path.stringByStandardizingPath;
    NSString *fonts = FMLegacyProviderSystemFontsPath.stringByStandardizingPath;
    return FMLegacyProviderPathIsEqualOrDescendant(candidate, fonts) ||
        FMLegacyProviderPathIsEqualOrDescendant(fonts, candidate);
}

static NSArray *FMLegacyProviderConfiguredPaths(NSDictionary *preference,
                                          BOOL *valid) {
    id value = preference[@"path"];
    if (value == nil) {
        if (valid != NULL) *valid = YES;
        return @[];
    }
    if (![value isKindOfClass:NSArray.class]) {
        if (valid != NULL) *valid = NO;
        return @[];
    }
    BOOL allStrings = YES;
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:NSString.class]) {
            allStrings = NO;
            break;
        }
    }
    if (valid != NULL) *valid = allStrings;
    return value;
}

NSDictionary<NSString *, id> *FMAnalyzeLegacyProviderAutoMountPreference(
    NSDictionary<NSString *, id> *preference) {
    BOOL pathsValid = NO;
    NSArray *paths = FMLegacyProviderConfiguredPaths(preference, &pathsValid);
    BOOL enabled = [preference[@"Enable"] isKindOfClass:NSNumber.class] &&
        [preference[@"Enable"] boolValue];
    BOOL fontsConfigured = NO;
    if (pathsValid) {
        for (NSString *path in paths) {
            if (FMLegacyProviderPathOverlapsSystemFonts(path)) {
                fontsConfigured = YES;
                break;
            }
        }
    }
    NSString *root = [preference[@"root"] isKindOfClass:NSString.class]
        ? preference[@"root"] : nil;
    return @{
        @"enabled" : enabled ? @YES : @NO,
        @"pathsValid" : pathsValid ? @YES : @NO,
        @"paths" : pathsValid ? paths : @[],
        @"fontsConfigured" : fontsConfigured ? @YES : @NO,
        @"conflictsWithFonts" : enabled && fontsConfigured ? @YES : @NO,
        @"rootSupported" : [root isEqual:FMLegacyProviderSupportedRoot] ? @YES : @NO,
    };
}

NSDictionary<NSString *, id> *
FMLegacyProviderAutoMountPreferenceByRemovingSystemFonts(
    NSDictionary<NSString *, id> *preference,
    BOOL *changed,
    NSError **error) {
    if (changed == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:FMLegacyProviderAutoMountPolicyErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"legacy Provider preference change output is required."
                                     }];
        }
        return nil;
    }
    *changed = NO;
    NSDictionary *analysis = FMAnalyzeLegacyProviderAutoMountPreference(preference);
    if (![analysis[@"conflictsWithFonts"] boolValue]) {
        return [preference copy];
    }

    NSMutableArray *remaining = [NSMutableArray array];
    for (NSString *path in analysis[@"paths"]) {
        if (!FMLegacyProviderPathOverlapsSystemFonts(path)) {
            [remaining addObject:path];
        }
    }
    NSMutableDictionary *updated = [preference mutableCopy];
    updated[@"path"] = remaining;
    if (remaining.count == 0) updated[@"Enable"] = @NO;
    *changed = YES;
    return updated;
}
