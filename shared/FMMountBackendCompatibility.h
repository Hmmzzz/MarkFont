#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const FMMountBackendCapabilityContractVersion;
FOUNDATION_EXPORT NSString *const FMMountBackendCompatibilityErrorDomain;

// Pure parser used by host tests and by the device metadata inspection.
NSDictionary<NSString *, id> *FMMountBackendAnalyzeExecutablePrefix(
    NSData *prefix);

// Inspects the packaged MarkFont backend without executing it or touching the
// mount table. A missing or incompatible file is represented in the report.
NSDictionary<NSString *, id> *_Nullable
FMInspectMountBackendCompatibilityAtPath(NSString *path, NSError **error);

NSString *FMMountBackendRecognitionForVersion(
    NSString *_Nullable version);

BOOL FMMountBackendEvidenceSatisfiesCompatibilityContract(
    NSDictionary<NSString *, id> *backendEvidence);

NS_ASSUME_NONNULL_END
