#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

#import "FMOperationLock.h"

static void FMRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        FMRequire(argc == 2, @"operation lock fixture path is required");
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSError *error = nil;
        FMRequire([NSFileManager.defaultManager createDirectoryAtPath:directory
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:&error],
                  error.localizedDescription ?: @"fixture directory failed");
        FMRequire(chown(directory.fileSystemRepresentation, getuid(), getgid()) == 0 &&
                      chmod(directory.fileSystemRepresentation, 0755) == 0,
                  @"fixture metadata failed");

        int first = FMAcquireExclusiveDirectoryLock(directory, getuid(), getgid(), &error);
        FMRequire(first >= 0, error.localizedDescription ?: @"first lock failed");
        error = nil;
        int competing = FMAcquireExclusiveDirectoryLock(
            directory, getuid(), getgid(), &error);
        FMRequire(competing < 0 && error.code == 4,
                  @"a competing engine lock was accepted");
        FMRequire(FMReleaseExclusiveDirectoryLock(first, &error),
                  error.localizedDescription ?: @"lock release failed");

        error = nil;
        int repeated = FMAcquireExclusiveDirectoryLock(
            directory, getuid(), getgid(), &error);
        FMRequire(repeated >= 0,
                  error.localizedDescription ?: @"released lock stayed busy");
        FMRequire(FMReleaseExclusiveDirectoryLock(repeated, &error),
                  error.localizedDescription ?: @"repeated lock release failed");

        FMRequire(chmod(directory.fileSystemRepresentation, 0777) == 0,
                  @"unsafe fixture chmod failed");
        error = nil;
        FMRequire(FMAcquireExclusiveDirectoryLock(
                      directory, getuid(), getgid(), &error) < 0 && error.code == 3,
                  @"unsafe lock directory was accepted");
        printf("PASS: crash-released exclusive engine directory lock\n");
    }
    return 0;
}
