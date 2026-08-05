#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure startup-state policy. A clean confirmed mirror, a late custom-font
// refresh, and a staged Profile change interrupted by reboot are recoverable.
BOOL FMAutomaticMountStateAllowsTrustedMirror(
    NSDictionary<NSString *, id> *_Nullable state);
BOOL FMAutomaticMountStateHasPendingProfileChange(
    NSDictionary<NSString *, id> *_Nullable state);

// Pure, side-effect-free decision used after automatic mounting. Both caller
// facts are supplied separately so command parsing and launchd provenance
// cannot be inferred from mutable report content.
BOOL FMLateAutomaticMountNeedsRestartEvidenceForReport(
    NSDictionary<NSString *, id> *_Nullable report,
    BOOL exactLaunchdInvocation,
    BOOL launchdService);

BOOL FMAutomaticRespringEligibleForReport(
    NSDictionary<NSString *, id> *_Nullable report,
    BOOL exactLaunchdInvocation,
    BOOL launchdService);

NS_ASSUME_NONNULL_END
