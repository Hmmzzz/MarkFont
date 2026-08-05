#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceAutoMountErrorDomain;

// Root-launchd-only entry point used while the jailbreak environment is loaded.
// It accepts no caller-controlled path, Profile, backend option, or build.
// A trusted clean working mirror is connected through the fixed read-only
// mount backend without rescanning font file contents. A staged Profile that
// survived reboot stays unconfirmed until current-session Respring evidence is
// safely reconciled or explicitly completed.
NSDictionary<NSString *, id> *_Nullable FMAutomountManagedDeviceFonts(
    NSError **error);

// Effective-root helper operation used by the App's explicit setting. Missing
// autoRespring state is treated as disabled, so installing a newer package
// never enables the policy or requests a restart as a side effect.
NSDictionary<NSString *, id> *_Nullable FMSetAutomaticRespringEnabled(
    NSString *confirmedSystemBuild,
    BOOL enabled,
    NSError **error);

NS_ASSUME_NONNULL_END
