#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMMirrorPreparationErrorDomain;

typedef NS_ENUM(NSInteger, FMMirrorPreparationErrorCode) {
    FMMirrorPreparationErrorInvalidPath = 1,
    FMMirrorPreparationErrorPreflightFailed = 2,
    FMMirrorPreparationErrorCopyFailed = 3,
    FMMirrorPreparationErrorVerificationFailed = 4,
    FMMirrorPreparationErrorPublishFailed = 5,
};

// Copies Stock into a new, previously absent staging directory and verifies a
// complete content/metadata manifest. The caller owns the staging parent.
NSDictionary<NSString *, id> * _Nullable
FMBuildVerifiedStockMirror(NSString *stockRoot,
                           NSString *stagingRoot,
                           NSError **error);

// Re-verifies staging against Stock, fsyncs its files/directories, and atomically
// renames it to finalMirrorRoot. Staging and final must have the same parent and
// finalMirrorRoot must not exist.
BOOL FMPublishVerifiedStockMirror(NSString *stockRoot,
                                  NSString *stagingRoot,
                                  NSString *finalMirrorRoot,
                                  NSError **error);

NS_ASSUME_NONNULL_END
