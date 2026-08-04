#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceProfileStageErrorDomain;

// Fixed-path, read-only gate from the clean working selection to an already
// adopted Profile, or to Stock when profileID is nil. The returned plan has a
// Stock-restore phase followed by a target-overlay phase.
NSDictionary<NSString *, id> *_Nullable FMCreateDeviceProfileStagePreflight(
    NSString *confirmedSystemBuild,
    NSString *_Nullable profileID,
    NSError **error);

// Fixed-path write operation. It restores the current selection's paths from
// Stock, then overlays an already-adopted privileged Profile (or stops after
// restore for Stock). It never requests a restart. An interrupted transition
// is left repairable.
NSDictionary<NSString *, id> *_Nullable FMStageDeviceProfile(
    NSString *confirmedSystemBuild,
    NSString *_Nullable profileID,
    NSError **error);

// Package-lifecycle-only variant for a caller that already owns the MarkFont
// operation lock. Keeping the normal entry point separate prevents a nested
// lock acquisition during first-install legacy Profile activation.
NSDictionary<NSString *, id> *_Nullable
FMStageDeviceProfileWithExistingLock(
    NSString *confirmedSystemBuild,
    NSString *_Nullable profileID,
    NSError **error);

// Fixed-target recovery operation. The target Profile and exact path set are
// read from non-clean persistent state; callers cannot supply either value.
NSDictionary<NSString *, id> *_Nullable FMRepairDeviceWorkingProfile(
    NSString *confirmedSystemBuild,
    NSError **error);

NS_ASSUME_NONNULL_END
