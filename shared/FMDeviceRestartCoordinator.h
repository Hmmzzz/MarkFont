#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceRestartCoordinatorErrorDomain;
FOUNDATION_EXPORT NSString *const FMRestartRequestLogicalPath;
FOUNDATION_EXPORT NSString *const FMUserspaceRebootExecutableLogicalPath;
FOUNDATION_EXPORT NSString *const FMRespringExecutableLogicalPath;

// Read-only. Verifies pending state, the managed read-only bindfs mapping,
// current build, Stock recovery source, and the fixed reboot executable.
NSDictionary<NSString *, id> *_Nullable FMCreateDeviceUserspaceRebootPreflight(
    NSString *confirmedSystemBuild,
    NSError **error);

// Repeats the preflight under the Font Manager operation lock and writes the
// one-shot request marker. It does not invoke the reboot executable.
NSDictionary<NSString *, id> *_Nullable FMArmDeviceUserspaceReboot(
    NSString *confirmedSystemBuild,
    NSError **error);

// Replaces the helper process with the fixed RootHide jbctl invocation. This
// returns only if exec fails, in which case the request marker is removed.
BOOL FMExecuteDeviceUserspaceReboot(NSError **error);

// Arms a SpringBoard-only refresh. A staged Profile change first refreshes the
// fixed mount backend mapping; a late automatic custom-font mount keeps its already
// restored mapping. Both paths write the same SpringBoard-session evidence and
// execute only the fixed no-argument sbreload tool.
NSDictionary<NSString *, id> *_Nullable FMArmDeviceRespring(
    NSString *confirmedSystemBuild,
    NSError **error);

// Revalidates the armed request and exact managed mapping under the Font
// Manager operation lock, commits workingProfileID as the persistent confirmed
// selection, then replaces the helper with UIKitTools sbreload. The lock is
// close-on-exec; if exec itself fails, the armed state is restored before this
// function returns.
BOOL FMExecuteDeviceRespring(NSString *confirmedSystemBuild, NSError **error);

// Compatibility reconciliation for userspace-reboot requests and older armed
// Respring requests. New Respring execution commits before invoking sbreload,
// so it normally leaves no request marker for this path.
NSDictionary<NSString *, id> *_Nullable FMReconcileDeviceAfterRestart(
    NSString *confirmedSystemBuild,
    NSError **error);

NS_ASSUME_NONNULL_END
