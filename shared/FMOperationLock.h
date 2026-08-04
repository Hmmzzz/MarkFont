#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMOperationLockErrorDomain;

// Takes a nonblocking exclusive flock on an already-existing physical
// directory. No lock file is created, and the kernel releases the lock if the
// helper exits or is killed. The returned descriptor must be released.
int FMAcquireExclusiveDirectoryLock(NSString *directoryPath,
                                    uid_t expectedUID,
                                    gid_t expectedGID,
                                    NSError **error);

BOOL FMReleaseExclusiveDirectoryLock(int descriptor, NSError **error);

NS_ASSUME_NONNULL_END
