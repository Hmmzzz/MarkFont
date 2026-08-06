#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMMirrorPreparation.h"
#import "FMTreeManifest.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static void FMWriteFixture(NSString *path, NSString *contents, mode_t mode) {
    NSData *data = [contents dataUsingEncoding:NSUTF8StringEncoding];
    FMRequire([data writeToFile:path atomically:NO], @"write fixture file");
    FMRequire(chmod(path.fileSystemRepresentation, mode) == 0, @"chmod fixture file");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        FMRequire(argc == 2, @"fixture root argument");
        NSString *fixtureRoot = [NSString stringWithUTF8String:argv[1]];
        NSString *stock = [fixtureRoot stringByAppendingPathComponent:@"stock"];
        NSString *mountLibrary =
            [fixtureRoot stringByAppendingPathComponent:@"mount/System/Library"];
        NSString *staging =
            [mountLibrary stringByAppendingPathComponent:@".Fonts.fontmanager-staging"];
        NSString *mirror = [mountLibrary stringByAppendingPathComponent:@"Fonts"];
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        FMRequire([files createDirectoryAtPath:[stock stringByAppendingPathComponent:@"Core"]
                    withIntermediateDirectories:YES attributes:nil error:&error],
                  error.localizedDescription ?: @"create stock Core");
        FMRequire([files createDirectoryAtPath:
                            [stock stringByAppendingPathComponent:@"LanguageSupport"]
                    withIntermediateDirectories:YES attributes:nil error:&error],
                  error.localizedDescription ?: @"create stock LanguageSupport");
        FMRequire([files createDirectoryAtPath:mountLibrary
                    withIntermediateDirectories:YES attributes:nil error:&error],
                  error.localizedDescription ?: @"create mount parent");
        FMWriteFixture([stock stringByAppendingPathComponent:@"Core/A.ttf"], @"stock-a", 0644);
        FMWriteFixture([stock stringByAppendingPathComponent:@"LanguageSupport/B.ttc"],
                       @"stock-b", 0600);
        NSString *alias = [stock stringByAppendingPathComponent:@"Alias.ttf"];
        FMRequire(symlink("Core/A.ttf", alias.fileSystemRepresentation) == 0,
                  @"create fixture symlink");

        NSDictionary *manifest = FMBuildVerifiedStockMirror(stock, staging, &error);
        FMRequire(manifest != nil && error == nil, error.localizedDescription ?: @"build mirror");
        FMRequire([manifest[@"entries"] count] == 5, @"unexpected Stock entry count");
        FMRequire([files fileExistsAtPath:staging] && ![files fileExistsAtPath:mirror],
                  @"build published before explicit publish");

        FMRequire(FMPublishVerifiedStockMirror(stock, staging, mirror, &error),
                  error.localizedDescription ?: @"publish mirror");
        FMRequire(![files fileExistsAtPath:staging] && [files fileExistsAtPath:mirror],
                  @"atomic publish paths are incorrect");
        NSDictionary *publishedManifest = FMCreateTreeManifestAtPath(mirror, &error);
        FMRequire(publishedManifest != nil && error == nil, @"manifest published mirror");

        NSString *secondStaging =
            [mountLibrary stringByAppendingPathComponent:@".Fonts.second-staging"];
        NSDictionary *second = FMBuildVerifiedStockMirror(stock, secondStaging, &error);
        FMRequire(second != nil, error.localizedDescription ?: @"build second staging");
        error = nil;
        FMRequire(!FMPublishVerifiedStockMirror(stock, secondStaging, mirror, &error),
                  @"existing final mirror was overwritten");
        FMRequire(error.code == FMMirrorPreparationErrorPreflightFailed &&
                      [files fileExistsAtPath:secondStaging],
                  @"failed publish did not preserve staging evidence");

        printf("PASS: staged Stock mirror verification and atomic publish\n");
    }
    return 0;
}
