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

// Detaches the exact managed Fonts mapping for an explicit package lifecycle
// operation. The Provider option and target are fixed; callers cannot supply
// an executable, option, or path. The current Provider may force this detach,
// so callers must first prove ownership/content and then verify exposed Stock.
NSDictionary<NSString *, id> * _Nullable
FMDetachProviderSystemFontsForPackageLifecycle(NSError **error);

// Refreshes the already-managed Fonts mapping after atomic mirror updates.
// The fixed Provider unmount exposes the original read-only system directory;
// the fixed --skip-copy mount then reconnects the prepared mirror. No caller-
// supplied executable, option, source, or target is accepted.
NSDictionary<NSString *, id> * _Nullable
FMRefreshProviderForPreparedSystemFonts(NSError **error);

NS_ASSUME_NONNULL_END
