#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const FMProviderInspectionSchemaVersion;
FOUNDATION_EXPORT NSInteger const FMProviderDecisionVersion;
FOUNDATION_EXPORT NSString *const FMProviderCoordinatorErrorDomain;

typedef NS_ENUM(NSInteger, FMProviderCoordinatorErrorCode) {
    FMProviderCoordinatorErrorInvalidInspection = 1,
};

// Inspection documents are populated by a read-only adapter. The simulator host
// uses fixtures; the future RootHide adapter will populate the same contract from
// package metadata, mount table/statfs, /.bindfs and manifest evidence.
BOOL FMValidateProviderInspection(id inspection, NSError **error);

// Returns a read-only decision document. `operations` is a dry-run only: this
// function never executes Provider commands or writes a mirror/state file.
NSDictionary<NSString *, id> * _Nullable
FMCoordinateProviderInspection(NSDictionary<NSString *, id> *inspection,
                               NSError **error);

NSString *FMProviderDecisionText(NSDictionary<NSString *, id> *decision);

NS_ASSUME_NONNULL_END
