#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMSecureDirectoryErrorDomain;

// Opens and validates an existing tree without attempting to create any
// component. This is suitable for dry-run/preflight checks.
BOOL FMValidateSecureDirectoryTree(NSString *anchorPath,
                                   NSArray<NSString *> *components,
                                   uid_t expectedUID,
                                   gid_t expectedGID,
                                   NSError **error);

// Opens every component relative to an already-physical anchor with openat(2).
// Existing components must be physical directories owned by the expected
// uid/gid and must not be group/world writable. Missing components are created
// with the supplied mode. Symbolic links are never followed.
BOOL FMEnsureSecureDirectoryTree(NSString *anchorPath,
                                 NSArray<NSString *> *components,
                                 uid_t expectedUID,
                                 gid_t expectedGID,
                                 mode_t creationMode,
                                 NSError **error);

// Ensures parentComponents as above, then creates a leaf that must not already
// exist. This gives baseline publication an explicit no-overwrite boundary.
BOOL FMCreateSecureLeafDirectory(NSString *anchorPath,
                                 NSArray<NSString *> *parentComponents,
                                 NSString *leafComponent,
                                 uid_t expectedUID,
                                 gid_t expectedGID,
                                 mode_t creationMode,
                                 NSError **error);

NS_ASSUME_NONNULL_END
