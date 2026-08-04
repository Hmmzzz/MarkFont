#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFileStoreErrorDomain;

typedef NS_ENUM(NSInteger, FMFileStoreErrorCode) {
    FMFileStoreErrorInvalidArgument = 1,
    FMFileStoreErrorFilesystem = 2,
    FMFileStoreErrorJSON = 3,
    FMFileStoreErrorHashMismatch = 4,
    FMFileStoreErrorUnsupportedFile = 5,
};

id _Nullable FMReadJSONObjectAtPath(NSString *path, NSError **error);
BOOL FMWriteJSONObjectAtomically(id object, NSString *path, mode_t mode, NSError **error);
BOOL FMWriteJSONObjectAtomicallyIfAbsent(id object,
                                         NSString *path,
                                         mode_t mode,
                                         NSError **error);
NSString * _Nullable FMSHA256ForFileAtPath(NSString *path, NSError **error);
NSString * _Nullable FMSHA256ForJSONObject(id object, NSError **error);

// Publishes a fully written file over an existing mirror target in one rename.
// expectedSHA256 must be the caller's already-verified source hash; both the
// copied stream and the published target are verified against it.
BOOL FMCopyRegularFileAtomically(NSString *sourcePath,
                                 NSString *metadataSourcePath,
                                 NSString *targetPath,
                                 NSString *expectedSHA256,
                                 NSError **error);

NS_ASSUME_NONNULL_END
