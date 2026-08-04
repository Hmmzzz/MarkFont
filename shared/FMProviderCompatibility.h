#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const FMProviderCapabilityContractVersion;
FOUNDATION_EXPORT NSString *const FMProviderCompatibilityErrorDomain;

// Pure parser used by tests and the device inspector. A compatible wrapper is
// a bounded UTF-8 shell script that exposes both fixed operations MarkFont
// uses: --skip-copy for mounting and -u for the existing refresh workflow.
NSDictionary<NSString *, id> *FMAnalyzeProviderWrapperData(NSData *data);

// Version recognition is diagnostic only. Unknown versions can still be fully
// compatible when their wrapper satisfies the capability contract.
NSString *FMProviderRecognitionForVersion(NSString * _Nullable version);

// Reads the wrapper through an O_NOFOLLOW descriptor and combines the parsed
// CLI contract with owner/mode/execute metadata. Incompatibility is returned as
// evidence instead of being treated as an I/O failure, so status and removal
// paths can remain read-only and descriptive.
NSDictionary<NSString *, id> * _Nullable
FMInspectProviderExecutableCompatibilityAtPath(NSString *path,
                                                NSError **error);

// Validates the complete Provider dictionary emitted by device inspection.
// Version recognition is diagnostic-only, and no executable digest is created.
BOOL FMProviderEvidenceSatisfiesCompatibilityContract(
    NSDictionary<NSString *, id> *provider);

NS_ASSUME_NONNULL_END
