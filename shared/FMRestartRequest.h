#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const FMRestartRequestSchemaVersion;
FOUNDATION_EXPORT NSString *const FMRestartRequestErrorDomain;

// Restart evidence contains the kernel boot identity plus an optional
// userspace-session identity. New device requests include both.
BOOL FMValidateRestartBootEvidence(id evidence, NSError **error);

NSDictionary<NSString *, id> *_Nullable FMCreateRestartRequestDocument(
    NSString *systemBuild,
    id workingProfileID,
    NSDictionary<NSString *, id> *bootEvidence,
    NSError **error);

BOOL FMValidateRestartRequestDocument(id document, NSError **error);

// Returns YES when comparison succeeded. `observed` is YES only when the
// current boot evidence proves that userspace restarted after the request.
BOOL FMRestartRequestObservedRestart(
    NSDictionary<NSString *, id> *request,
    NSDictionary<NSString *, id> *currentBootEvidence,
    BOOL *observed,
    NSError **error);

NS_ASSUME_NONNULL_END
