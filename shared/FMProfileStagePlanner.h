#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMProfileStagePlannerErrorDomain;

typedef NS_ENUM(NSInteger, FMProfileStagePlannerErrorCode) {
    FMProfileStagePlannerErrorInvalidInput = 1,
    FMProfileStagePlannerErrorInvalidState = 2,
    FMProfileStagePlannerErrorInvalidProfile = 3,
    FMProfileStagePlannerErrorMirrorMismatch = 4,
};

// Builds a read-only two-phase transition plan. Phase 1 restores every path
// declared by the current Profile from Stock; phase 2 overlays every path in
// targetProfileID (nil means Stock). If the recorded current Profile is missing,
// phase 1 falls back to every path in the current-build catalog. The mirror is
// never written.
NSDictionary<NSString *, id> *_Nullable FMCreateProfileStagePlanAtRoots(
    NSString *stockRoot,
    NSString *mirrorRoot,
    NSString *profilesRoot,
    NSString *_Nullable targetProfileID,
    NSString *statePath,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

NS_ASSUME_NONNULL_END
