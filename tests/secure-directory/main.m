#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMSecureDirectory.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        FMRequire(argc == 2, @"fixture root argument");
        NSString *fixtureRoot = [NSString stringWithUTF8String:argv[1]];
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        FMRequire([files createDirectoryAtPath:fixtureRoot
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&error],
                  error.localizedDescription ?: @"create secure fixture root");
        FMRequire(chown(fixtureRoot.fileSystemRepresentation, getuid(), getgid()) == 0,
                  @"secure fixture root owner");
        FMRequire(chmod(fixtureRoot.fileSystemRepresentation, 0700) == 0,
                  @"secure fixture root mode");

        uid_t uid = getuid();
        gid_t gid = getgid();
        FMRequire(FMEnsureSecureDirectoryTree(
                      fixtureRoot, @[ @"bindfs", @"System", @"Library" ],
                      uid, gid, 0755, &error),
                  error.localizedDescription ?: @"create secure mount parent");
        FMRequire(FMEnsureSecureDirectoryTree(
                      fixtureRoot, @[ @"bindfs", @"System", @"Library" ],
                      uid, gid, 0755, &error),
                  @"idempotent secure mount parent");
        FMRequire(FMValidateSecureDirectoryTree(
                      fixtureRoot, @[ @"bindfs", @"System", @"Library" ],
                      uid, gid, &error),
                  error.localizedDescription ?: @"validate existing secure tree");
        error = nil;
        FMRequire(!FMValidateSecureDirectoryTree(
                       fixtureRoot, @[ @"missing", @"child" ], uid, gid, &error),
                  @"read-only validation accepted a missing tree");
        FMRequire(![files fileExistsAtPath:
                         [fixtureRoot stringByAppendingPathComponent:@"missing"]],
                  @"read-only validation created a directory");

        FMRequire(FMCreateSecureLeafDirectory(
                      fixtureRoot, @[ @"metadata", @"baseline" ], @"21D61",
                      uid, gid, 0755, &error),
                  error.localizedDescription ?: @"create secure baseline leaf");
        error = nil;
        FMRequire(!FMCreateSecureLeafDirectory(
                       fixtureRoot, @[ @"metadata", @"baseline" ], @"21D61",
                       uid, gid, 0755, &error),
                  @"existing baseline leaf was accepted");

        NSString *outside = [fixtureRoot stringByAppendingPathComponent:@"outside"];
        FMRequire([files createDirectoryAtPath:outside
                   withIntermediateDirectories:NO
                                    attributes:nil
                                         error:&error],
                  @"create symlink target");
        NSString *link = [fixtureRoot stringByAppendingPathComponent:@"redirect"];
        FMRequire(symlink("outside", link.fileSystemRepresentation) == 0,
                  @"create redirect symlink");
        error = nil;
        FMRequire(!FMEnsureSecureDirectoryTree(
                       fixtureRoot, @[ @"redirect", @"child" ], uid, gid, 0755,
                       &error),
                  @"secure traversal followed a symlink");
        error = nil;
        FMRequire(!FMValidateSecureDirectoryTree(
                       fixtureRoot, @[ @"redirect" ], uid, gid, &error),
                  @"read-only secure traversal followed a symlink");
        FMRequire(![files fileExistsAtPath:
                         [outside stringByAppendingPathComponent:@"child"]],
                  @"symlink traversal wrote outside the requested tree");

        NSString *writable = [fixtureRoot stringByAppendingPathComponent:@"writable"];
        FMRequire([files createDirectoryAtPath:writable
                   withIntermediateDirectories:NO
                                    attributes:nil
                                         error:&error],
                  @"create writable directory");
        FMRequire(chmod(writable.fileSystemRepresentation, 0777) == 0,
                  @"set writable directory mode");
        error = nil;
        FMRequire(!FMEnsureSecureDirectoryTree(
                       fixtureRoot, @[ @"writable", @"child" ], uid, gid, 0755,
                       &error),
                  @"unsafe writable directory was accepted");
        error = nil;
        FMRequire(!FMValidateSecureDirectoryTree(
                       fixtureRoot, @[ @"writable" ], uid, gid, &error),
                  @"read-only validation accepted an unsafe directory");

        printf("PASS: secure directory traversal and no-overwrite boundaries\n");
    }
    return 0;
}
