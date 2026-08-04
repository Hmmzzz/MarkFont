#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMProfileEngineErrorDomain;
FOUNDATION_EXPORT NSInteger const FMProfileEngineNoFaultInjection;

typedef NS_ENUM(NSInteger, FMProfileEngineErrorCode) {
    FMProfileEngineErrorInvalidInput = 1,
    FMProfileEngineErrorInvalidState = 2,
    FMProfileEngineErrorBuildMismatch = 3,
    FMProfileEngineErrorInvalidTransition = 4,
    FMProfileEngineErrorPreflightFailed = 5,
    FMProfileEngineErrorInjectedFailure = 6,
    FMProfileEngineErrorCommitFailed = 7,
};

NSDictionary<NSString *, id> *FMCreateInitialState(NSString *systemBuild);

// Records that an externally completed userspace reboot made the working
// Profile observable. This function does not reboot or inspect the system.
BOOL FMConfirmWorkingProfileAtStatePath(NSString *statePath, NSError **error);

// Conservatively records that the working Profile needs convergence and keeps
// the exact managed path set required for deterministic repair. This does not
// modify any mirror file.
BOOL FMMarkProfileRepairRequiredAtStatePath(
    NSString *statePath,
    NSArray<NSString *> *managedRelativePaths,
    NSError **error);

// profileDocument/profileDirectory are both nil for Stock. For a normal stage,
// stockRestoreRelativePaths is the exact path list declared by the current
// Profile (or the full catalog fallback selected by the planner). The engine
// restores those paths first, then overlays every target Profile replacement.
// The persistent state must currently be clean.
BOOL FMStageProfileAtRoots(NSString *stockRoot,
                           NSString *mirrorRoot,
                           NSDictionary<NSString *, id> * _Nullable profileDocument,
                           NSString * _Nullable profileDirectory,
                           NSArray<NSString *> *stockRestoreRelativePaths,
                           NSString *statePath,
                           NSInteger faultAfterCommittedFiles,
                           NSError **error);

// Repair starts from Stock for the complete transition path set persisted
// before the first write, then overlays the saved target Profile again.
BOOL FMRepairProfileAtRoots(NSString *stockRoot,
                            NSString *mirrorRoot,
                            NSDictionary<NSString *, id> * _Nullable profileDocument,
                            NSString * _Nullable profileDirectory,
                            NSArray<NSString *> *stockRestoreRelativePaths,
                            NSString *statePath,
                            NSInteger faultAfterCommittedFiles,
                            NSError **error);

NS_ASSUME_NONNULL_END
