#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const FMMountInspectionSchemaVersion;
FOUNDATION_EXPORT NSInteger const FMMountDecisionVersion;
FOUNDATION_EXPORT NSString *const FMMountCoordinatorErrorDomain;

typedef NS_ENUM(NSInteger, FMMountCoordinatorErrorCode) {
    FMMountCoordinatorErrorInvalidInspection = 1,
};

// Inspection documents are populated by a read-only adapter. The simulator
// uses fixtures; the RootHide adapter reads the built-in backend, fixed
// /bindfs storage, mount table/statfs, and manifest evidence.
BOOL FMValidateMountInspection(id inspection, NSError **error);

// Returns a read-only decision document. `operations` is a dry-run only: this
// function never executes mount backend commands or writes a mirror/state file.
NSDictionary<NSString *, id> * _Nullable
FMCoordinateMountInspection(NSDictionary<NSString *, id> *inspection,
                               NSError **error);

NSString *FMMountDecisionText(NSDictionary<NSString *, id> *decision);

NS_ASSUME_NONNULL_END
