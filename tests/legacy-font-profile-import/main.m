#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMLegacyFontProfileImport.h"
#import "FMFileStore.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static void FMWrite(NSString *path, NSString *contents) {
    NSError *error = nil;
    NSData *data = [contents dataUsingEncoding:NSUTF8StringEncoding];
    FMRequire([data writeToFile:path options:NSDataWritingAtomic error:&error],
              error.localizedDescription ?: @"write fixture");
}

static void FMMkdir(NSString *path) {
    NSError *error = nil;
    FMRequire([NSFileManager.defaultManager
        createDirectoryAtPath:path
  withIntermediateDirectories:YES
                   attributes:@{ NSFilePosixPermissions : @0700 }
                        error:&error],
              error.localizedDescription ?: @"create fixture directory");
    FMRequire(chmod(path.fileSystemRepresentation, 0700) == 0,
              @"secure fixture directory mode");
    FMRequire(chown(path.fileSystemRepresentation, getuid(), getgid()) == 0,
              @"secure fixture directory owner");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        FMRequire(argc == 2, @"expected fixture root");
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        NSString *stock = [root stringByAppendingPathComponent:@"Stock"];
        NSString *legacy = [root stringByAppendingPathComponent:@"Legacy"];
        NSString *profiles = [root stringByAppendingPathComponent:@"Profiles"];
        FMMkdir([stock stringByAppendingPathComponent:@"Core"]);
        FMMkdir([stock stringByAppendingPathComponent:@"LanguageSupport"]);
        FMMkdir(profiles);
        FMWrite([stock stringByAppendingPathComponent:@"Core/System.ttf"],
                @"stock-system-font");
        FMWrite([stock stringByAppendingPathComponent:
                     @"LanguageSupport/Chinese.ttc"],
                @"stock-chinese-font");
        FMWrite([stock stringByAppendingPathComponent:@"Core/Unchanged.otf"],
                @"same-font");
        FMWrite([stock stringByAppendingPathComponent:@"metadata.plist"],
                @"not-a-font");

        NSError *error = nil;
        FMRequire([NSFileManager.defaultManager copyItemAtPath:stock
                                                        toPath:legacy
                                                         error:&error],
                  error.localizedDescription ?: @"copy legacy fixture");
        FMWrite([legacy stringByAppendingPathComponent:@"Core/System.ttf"],
                @"legacy-system-font");
        FMWrite([legacy stringByAppendingPathComponent:
                      @"LanguageSupport/Chinese.ttc"],
                @"legacy-chinese-font");
        FMWrite([legacy stringByAppendingPathComponent:@"Extra.ttf"],
                @"unmapped-extra-font");

        NSDictionary *report = FMImportLegacyFontTreeAsProfile(
            legacy, stock, profiles, @"21D61", @"import-legacy-test",
            @"安装前字体", getuid(), getgid(), &error);
        FMRequire(report != nil,
                  error.localizedDescription ?: @"legacy import failed");
        FMRequire([report[@"status"] isEqual:@"imported"],
                  @"legacy import did not publish a Profile");
        FMRequire([report[@"replacementCount"] isEqual:@2],
                  @"legacy import did not keep only the two changed fonts");

        NSString *profileRoot =
            [profiles stringByAppendingPathComponent:@"import-legacy-test"];
        NSDictionary *profile = FMReadJSONObjectAtPath(
            [profileRoot stringByAppendingPathComponent:@"profile.json"],
            &error);
        FMRequire(profile != nil,
                  error.localizedDescription ?: @"read generated Profile");
        NSArray *replacements = profile[@"replacements"];
        NSSet *paths = [NSSet setWithArray:
            [replacements valueForKey:@"relativePath"]];
        FMRequire([paths isEqual:[NSSet setWithArray:@[
            @"Core/System.ttf", @"LanguageSupport/Chinese.ttc"
        ]]], @"generated Profile contains the wrong target paths");
        FMRequire(![paths containsObject:@"Core/Unchanged.otf"] &&
                      ![paths containsObject:@"Extra.ttf"],
                  @"generated Profile copied unchanged or unmapped fonts");

        error = nil;
        NSDictionary *second = FMImportLegacyFontTreeAsProfile(
            legacy, stock, profiles, @"21D61", @"import-legacy-test",
            @"安装前字体", getuid(), getgid(), &error);
        FMRequire([second[@"status"] isEqual:@"alreadyImported"],
                  error.localizedDescription ?: @"idempotent import failed");

        NSString *identical = [root stringByAppendingPathComponent:@"Identical"];
        NSString *emptyProfiles =
            [root stringByAppendingPathComponent:@"EmptyProfiles"];
        FMRequire([NSFileManager.defaultManager copyItemAtPath:stock
                                                        toPath:identical
                                                         error:&error],
                  error.localizedDescription ?: @"copy identical fixture");
        FMMkdir(emptyProfiles);
        error = nil;
        NSDictionary *unchanged = FMImportLegacyFontTreeAsProfile(
            identical, stock, emptyProfiles, @"21D61",
            @"import-legacy-stock", @"安装前字体", getuid(), getgid(),
            &error);
        FMRequire([unchanged[@"status"] isEqual:@"noChanges"] &&
                      ![NSFileManager.defaultManager fileExistsAtPath:
                          [emptyProfiles stringByAppendingPathComponent:
                              @"import-legacy-stock"]],
                  error.localizedDescription ?: @"Stock-identical import created a Profile");

        printf("PASS: legacy Fonts tree becomes one differential App Profile\n");
    }
    return 0;
}
