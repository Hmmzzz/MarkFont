#import "FMProviderAutoMountPolicy.h"

NSString *const FMProviderAutoMountPolicyErrorDomain =
    @"com.hmmzzz.fontmanager.provider-auto-mount-policy";

static NSString *const FMProviderSystemFontsPath = @"/System/Library/Fonts";
static NSString *const FMProviderSupportedRoot = @".jbroot/bindfs";

static BOOL FMProviderPathIsEqualOrDescendant(NSString *path,
                                              NSString *root) {
    if ([path isEqual:root]) return YES;
    NSString *prefix = [root isEqual:@"/"]
        ? @"/" : [root stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static BOOL FMProviderPathOverlapsSystemFonts(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) {
        return NO;
    }
    NSString *candidate = path.stringByStandardizingPath;
    NSString *fonts = FMProviderSystemFontsPath.stringByStandardizingPath;
    return FMProviderPathIsEqualOrDescendant(candidate, fonts) ||
        FMProviderPathIsEqualOrDescendant(fonts, candidate);
}

static NSArray *FMProviderConfiguredPaths(NSDictionary *preference,
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

NSDictionary<NSString *, id> *FMAnalyzeProviderAutoMountPreference(
    NSDictionary<NSString *, id> *preference) {
    BOOL pathsValid = NO;
    NSArray *paths = FMProviderConfiguredPaths(preference, &pathsValid);
    BOOL enabled = [preference[@"Enable"] isKindOfClass:NSNumber.class] &&
        [preference[@"Enable"] boolValue];
    BOOL fontsConfigured = NO;
    if (pathsValid) {
        for (NSString *path in paths) {
            if (FMProviderPathOverlapsSystemFonts(path)) {
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
        @"rootSupported" : [root isEqual:FMProviderSupportedRoot] ? @YES : @NO,
    };
}

NSDictionary<NSString *, id> *
FMProviderAutoMountPreferenceByRemovingSystemFonts(
    NSDictionary<NSString *, id> *preference,
    BOOL *changed,
    NSError **error) {
    if (changed == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:FMProviderAutoMountPolicyErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"Provider preference change output is required."
                                     }];
        }
        return nil;
    }
    *changed = NO;
    NSDictionary *analysis = FMAnalyzeProviderAutoMountPreference(preference);
    if (![analysis[@"conflictsWithFonts"] boolValue]) {
        return [preference copy];
    }

    NSMutableArray *remaining = [NSMutableArray array];
    for (NSString *path in analysis[@"paths"]) {
        if (!FMProviderPathOverlapsSystemFonts(path)) {
            [remaining addObject:path];
        }
    }
    NSMutableDictionary *updated = [preference mutableCopy];
    updated[@"path"] = remaining;
    if (remaining.count == 0) updated[@"Enable"] = @NO;
    *changed = YES;
    return updated;
}
