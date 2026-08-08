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

// Device-only extension for the fixed FontServices/CorePrivate mirror. Catalog
// paths below FontServicesCorePrivate/ are routed to supplementalMirrorRoot;
// every other path retains the primary mirrorRoot behavior. Passing nil keeps
// the original single-root contract used by iOS 16-17 and host tests.
NSDictionary<NSString *, id> *_Nullable
FMCreateProfileStagePlanAtRootsWithSupplementalMirror(
    NSString *stockRoot,
    NSString *mirrorRoot,
    NSString * _Nullable supplementalMirrorRoot,
    NSString *profilesRoot,
    NSString *_Nullable targetProfileID,
    NSString *statePath,
    NSString *systemBuild,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

NS_ASSUME_NONNULL_END
