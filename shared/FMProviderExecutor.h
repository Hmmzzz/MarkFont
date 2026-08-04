#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMProviderExecutorErrorDomain;

// Executes the single Provider operation admitted by the first-release Mount
// Engine. It intentionally accepts no executable, path, option, or environment
// input from callers. Completion of the child process is reported separately
// from its exit result so the coordinator can always verify the actual mount
// table instead of guessing from wrapper output.
NSDictionary<NSString *, id> * _Nullable
FMInvokeProviderForPreparedSystemFonts(NSError **error);

// Refreshes the already-managed Fonts mapping after atomic mirror updates.
// The fixed Provider unmount exposes the original read-only system directory;
// the fixed --skip-copy mount then reconnects the prepared mirror. No caller-
// supplied executable, option, source, or target is accepted.
NSDictionary<NSString *, id> * _Nullable
FMRefreshProviderForPreparedSystemFonts(NSError **error);

NS_ASSUME_NONNULL_END
