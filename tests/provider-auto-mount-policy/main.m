#import <Foundation/Foundation.h>

#import "FMLegacyProviderAutoMountPolicy.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSDictionary *FMPreference(BOOL enabled, NSArray *paths) {
    return @{
        @"Enable" : enabled ? @YES : @NO,
        @"root" : @".jbroot/bindfs",
        @"path" : paths,
    };
}

int main(void) {
    @autoreleasepool {
        NSDictionary *fonts = FMPreference(
            YES, @[ @"/System/Library/Fonts" ]);
        NSDictionary *fontsAnalysis =
            FMAnalyzeLegacyProviderAutoMountPreference(fonts);
        FMRequire([fontsAnalysis[@"conflictsWithFonts"] boolValue],
                  @"enabled Fonts path was not classified as a conflict");

        BOOL changed = NO;
        NSError *error = nil;
        NSDictionary *fontsRemoved =
            FMLegacyProviderAutoMountPreferenceByRemovingSystemFonts(
                fonts, &changed, &error);
        FMRequire(fontsRemoved != nil && error == nil && changed &&
                      ![fontsRemoved[@"Enable"] boolValue] &&
                      [fontsRemoved[@"path"] count] == 0 &&
                      [fontsRemoved[@"root"] isEqual:@".jbroot/bindfs"],
                  @"Fonts-only preference was not disabled after removal");

        NSDictionary *disabled = FMPreference(
            NO, @[ @"/System/Library/Fonts" ]);
        NSDictionary *disabledAnalysis =
            FMAnalyzeLegacyProviderAutoMountPreference(disabled);
        changed = YES;
        NSDictionary *disabledResult =
            FMLegacyProviderAutoMountPreferenceByRemovingSystemFonts(
                disabled, &changed, &error);
        FMRequire(![disabledAnalysis[@"conflictsWithFonts"] boolValue] &&
                      disabledResult != nil && !changed &&
                      [disabledResult isEqual:disabled],
                  @"disabled preference was treated as active automatic mounting");

        NSDictionary *empty = FMPreference(YES, @[]);
        FMRequire(![[FMAnalyzeLegacyProviderAutoMountPreference(empty)
                         objectForKey:@"conflictsWithFonts"] boolValue],
                  @"empty automatic-mount path list was treated as a conflict");

        NSDictionary *mixed = FMPreference(
            YES,
            @[ @"/System/Library/Fonts", @"/System/Library/ThermalMonitor" ]);
        changed = NO;
        NSDictionary *mixedResult =
            FMLegacyProviderAutoMountPreferenceByRemovingSystemFonts(
                mixed, &changed, &error);
        FMRequire(mixedResult != nil && changed &&
                      [mixedResult[@"Enable"] boolValue] &&
                      [mixedResult[@"path"] isEqual:
                          @[ @"/System/Library/ThermalMonitor" ]],
                  @"unrelated automatic-mount targets were not preserved");

        for (NSString *overlap in @[
                 @"/", @"/System/Library",
                 @"/System/Library/Fonts/Core"
             ]) {
            NSDictionary *analysis = FMAnalyzeLegacyProviderAutoMountPreference(
                FMPreference(YES, @[ overlap ]));
            FMRequire([analysis[@"conflictsWithFonts"] boolValue],
                      @"overlapping Fonts mount target was not detected");
        }

        NSDictionary *other = FMPreference(
            YES, @[ @"/System/Library/ThermalMonitor" ]);
        FMRequire(![[FMAnalyzeLegacyProviderAutoMountPreference(other)
                         objectForKey:@"conflictsWithFonts"] boolValue],
                  @"unrelated legacy Provider target was treated as a Fonts conflict");

        printf("PASS: legacy Provider automatic-mount preference policy\n");
    }
    return 0;
}
