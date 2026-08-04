#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline NSString *FMLanguagePreference(void) {
    NSString *preference = [NSUserDefaults.standardUserDefaults
        stringForKey:@"FMLanguagePreference"];
    if ([preference isEqualToString:@"en"] ||
        [preference isEqualToString:@"zh-Hans"]) {
        return preference;
    }
    return @"system";
}

static inline NSNotificationName FMLanguagePreferenceDidChangeNotification(void) {
    return @"FMLanguagePreferenceDidChangeNotification";
}

static inline BOOL FMSetLanguagePreference(NSString *preference) {
    NSString *normalized =
        ([preference isEqualToString:@"en"] ||
         [preference isEqualToString:@"zh-Hans"])
            ? preference : @"system";
    if ([FMLanguagePreference() isEqualToString:normalized]) return NO;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([normalized isEqualToString:@"system"]) {
        [defaults removeObjectForKey:@"FMLanguagePreference"];
    } else {
        [defaults setObject:normalized forKey:@"FMLanguagePreference"];
    }
    [NSNotificationCenter.defaultCenter
        postNotificationName:FMLanguagePreferenceDidChangeNotification()
                      object:nil];
    return YES;
}

// Chinese source text is the stable key and the fallback for unsupported locales.
static inline NSString *FMLocalized(NSString *key) {
    NSString *preference = FMLanguagePreference();
    NSBundle *bundle = NSBundle.mainBundle;
    if (![preference isEqualToString:@"system"]) {
        NSString *path = [bundle pathForResource:preference ofType:@"lproj"];
        NSBundle *preferredBundle = path.length > 0
            ? [NSBundle bundleWithPath:path] : nil;
        if (preferredBundle != nil) bundle = preferredBundle;
    }
    return [bundle localizedStringForKey:key value:key table:nil];
}

static inline NSString *FMLanguagePreferenceDisplayName(NSString *preference) {
    if ([preference isEqualToString:@"en"]) return FMLocalized(@"英文");
    if ([preference isEqualToString:@"zh-Hans"]) return FMLocalized(@"简体中文");
    return FMLocalized(@"跟随系统");
}

NS_ASSUME_NONNULL_END
