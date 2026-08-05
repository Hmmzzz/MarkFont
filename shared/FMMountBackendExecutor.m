#import "FMMountBackendExecutor.h"

#import <errno.h>
#import <fcntl.h>
#import <roothide.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#import "FMMountBackendProtocol.h"

NSString *const FMMountBackendIdentifier = @"markfont-bindfs";
NSString *const FMMountBackendVersion = @"1";
NSString *const FMMountBackendExecutableLogicalPath =
    @"/usr/libexec/markfont-bindfs";
NSString *const FMMountBackendRuntimeLibraryLogicalPath =
    @"/basebin/libjailbreak.dylib";
NSString *const FMMountBackendExecutorErrorDomain =
    @"com.hmmzzz.fontmanager.mount-backend-executor";

static BOOL FMMountBackendExecutorFail(NSError **error,
                                       NSInteger code,
                                       NSString *description,
                                       int errorNumber) {
    if (error != NULL) {
        NSMutableDictionary *userInfo =
            [NSMutableDictionary dictionaryWithObject:description
                                               forKey:NSLocalizedDescriptionKey];
        if (errorNumber != 0) {
            userInfo[NSUnderlyingErrorKey] =
                [NSError errorWithDomain:NSPOSIXErrorDomain
                                    code:errorNumber
                                userInfo:nil];
        }
        *error = [NSError errorWithDomain:FMMountBackendExecutorErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMMountBackendExecutableIsSecure(NSError **error) {
    if (geteuid() != 0) {
        return FMMountBackendExecutorFail(
            error, 1, @"The built-in mount backend requires effective uid 0.",
            EPERM);
    }
    NSString *path = jbroot(FMMountBackendExecutableLogicalPath);
    struct stat info = {0};
    errno = 0;
    if (lstat(path.fileSystemRepresentation, &info) != 0 ||
        !S_ISREG(info.st_mode) || info.st_uid != 0 ||
        (info.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID)) != 0 ||
        (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0 ||
        access(path.fileSystemRepresentation, X_OK) != 0) {
        int savedError = errno != 0 ? errno : EPERM;
        return FMMountBackendExecutorFail(
            error, 2,
            @"The built-in mount backend is missing or has unsafe metadata.",
            savedError);
    }
    return YES;
}

static NSDictionary<NSString *, id> *FMMountBackendProcessReport(int status) {
    BOOL exitedNormally = WIFEXITED(status);
    BOOL signaled = WIFSIGNALED(status);
    return @{
        @"processStarted" : @YES,
        @"exitedNormally" : @(exitedNormally),
        @"exitStatus" : exitedNormally ? @(WEXITSTATUS(status)) : NSNull.null,
        @"terminatingSignal" : signaled ? @(WTERMSIG(status)) : NSNull.null,
        @"reportedSuccess" : exitedNormally && WEXITSTATUS(status) == 0
            ? @YES : @NO,
    };
}

static int FMMountBackendErrnoFromReport(NSDictionary<NSString *, id> *report) {
    id status = report[@"exitStatus"];
    if (![status isKindOfClass:NSNumber.class]) return 0;
    NSInteger value = [status integerValue];
    NSInteger minimum = FMMountBackendProcessExitErrnoBase + 1;
    NSInteger maximum = FMMountBackendProcessExitErrnoBase +
        FMMountBackendProcessMaximumEncodedErrno;
    return value >= minimum && value <= maximum
        ? (int)(value - FMMountBackendProcessExitErrnoBase) : 0;
}

static NSString *FMMountBackendFailureDescription(
    NSDictionary<NSString *, id> *report) {
    NSInteger status = [report[@"exitStatus"] isKindOfClass:NSNumber.class]
        ? [report[@"exitStatus"] integerValue] : -1;
    switch (status) {
        case FMMountBackendProcessExitUnavailable:
            return @"The jailbreak mount capability is unavailable.";
        case FMMountBackendProcessExitCredentialBorrow:
            return @"The mount backend could not borrow the required credential.";
        case FMMountBackendProcessExitCredentialRestore:
            return @"The mount backend could not restore its original credential.";
        case FMMountBackendProcessExitNotMounted:
            return @"The exact managed mapping is not currently mounted.";
        case FMMountBackendProcessExitPermission:
            return @"The mount backend rejected an unprivileged caller.";
        case FMMountBackendProcessExitUnsafeState:
            return @"The mount backend rejected an unsafe path or mapping state.";
        case FMMountBackendProcessExitUnknownSyscall:
            return @"The bindfs system call failed with an unknown error.";
        default:
            return @"The built-in mount backend did not complete successfully.";
    }
}

static NSDictionary<NSString *, id> *FMMountBackendInvokeCommand(
    NSString *command,
    NSError **error) {
    NSSet<NSString *> *allowedCommands =
        [NSSet setWithArray:@[ @"probe", @"mount-fonts", @"force-unmount-fonts" ]];
    if (![allowedCommands containsObject:command]) {
        FMMountBackendExecutorFail(
            error, 3, @"The fixed mount backend command is invalid.", EINVAL);
        return nil;
    }
    if (!FMMountBackendExecutableIsSecure(error)) {
        return nil;
    }

    NSString *executablePath = jbroot(FMMountBackendExecutableLogicalPath);
    char *const arguments[] = {
        (char *)executablePath.fileSystemRepresentation,
        (char *)command.UTF8String,
        NULL,
    };
    char *const environment[] = {
        (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        (char *)"LANG=C",
        (char *)"LC_ALL=C",
        NULL,
    };

    posix_spawn_file_actions_t actions;
    int actionResult = posix_spawn_file_actions_init(&actions);
    if (actionResult != 0) {
        FMMountBackendExecutorFail(
            error, 4, @"Unable to initialize mount backend isolation.",
            actionResult);
        return nil;
    }
    int result = posix_spawn_file_actions_addopen(
        &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (result == 0) {
        result = posix_spawn_file_actions_addopen(
            &actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    }
    if (result == 0) {
        result = posix_spawn_file_actions_addopen(
            &actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    }
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        FMMountBackendExecutorFail(
            error, 4, @"Unable to isolate mount backend process output.",
            result);
        return nil;
    }

    pid_t child = -1;
    int spawnResult = posix_spawn(&child,
                                  executablePath.fileSystemRepresentation,
                                  &actions, NULL, arguments, environment);
    posix_spawn_file_actions_destroy(&actions);
    if (spawnResult != 0) {
        FMMountBackendExecutorFail(
            error, 5, @"The built-in mount backend could not be started.",
            spawnResult);
        return nil;
    }

    int status = 0;
    pid_t waitResult = -1;
    do {
        waitResult = waitpid(child, &status, 0);
    } while (waitResult < 0 && errno == EINTR);
    if (waitResult != child) {
        FMMountBackendExecutorFail(
            error, 6, @"The mount backend process could not be observed.",
            errno != 0 ? errno : ECHILD);
        return nil;
    }
    return FMMountBackendProcessReport(status);
}

static BOOL FMMountBackendRequireRuntime(NSError **error) {
    NSDictionary *probe = FMMountBackendInvokeCommand(@"probe", error);
    if (probe == nil || ![probe[@"reportedSuccess"] boolValue]) {
        if (probe != nil) {
            FMMountBackendExecutorFail(
                error, 7, FMMountBackendFailureDescription(probe),
                FMMountBackendErrnoFromReport(probe));
        }
        return NO;
    }
    return YES;
}

NSDictionary<NSString *, id> *FMInvokeMountBackendForPreparedSystemFonts(
    NSError **error) {
    if (!FMMountBackendRequireRuntime(error)) return nil;
    NSDictionary *execution =
        FMMountBackendInvokeCommand(@"mount-fonts", error);
    if (execution == nil || ![execution[@"reportedSuccess"] boolValue]) {
        if (execution != nil) {
            FMMountBackendExecutorFail(
                error, 8, FMMountBackendFailureDescription(execution),
                FMMountBackendErrnoFromReport(execution));
        }
        return nil;
    }
    NSMutableDictionary *report = [execution mutableCopy];
    report[@"mountBackend"] = FMMountBackendIdentifier;
    report[@"mountBackendVersion"] = FMMountBackendVersion;
    // Reaching this point means the fixed backend passed its runtime probe and
    // completed the requested read-only mount. Keep the compatibility fact in
    // the execution report so callers never have to synthesize it (or insert a
    // missing value into an Objective-C dictionary literal).
    report[@"mountBackendCompatibility"] = @"compatible";
    return report;
}

NSDictionary<NSString *, id> *
FMDetachManagedSystemFontsForPackageLifecycle(NSError **error) {
    if (!FMMountBackendRequireRuntime(error)) return nil;
    NSDictionary *execution =
        FMMountBackendInvokeCommand(@"force-unmount-fonts", error);
    if (execution == nil || ![execution[@"reportedSuccess"] boolValue]) {
        if (execution != nil) {
            FMMountBackendExecutorFail(
                error, 8, FMMountBackendFailureDescription(execution),
                FMMountBackendErrnoFromReport(execution));
        }
        return nil;
    }
    return @{
        @"operation" : @"detachManagedSystemFontsForPackageLifecycle",
        @"reportedSuccess" : @YES,
        @"mountBackend" : FMMountBackendIdentifier,
        @"mountBackendVersion" : FMMountBackendVersion,
        @"backendDetachMayForce" : @YES,
        @"unmount" : execution,
    };
}

NSDictionary<NSString *, id> *FMRefreshMountBackendForPreparedSystemFonts(
    NSError **error) {
    if (!FMMountBackendRequireRuntime(error)) return nil;
    NSDictionary *unmount =
        FMMountBackendInvokeCommand(@"force-unmount-fonts", error);
    BOOL alreadyDetached = [unmount[@"exitStatus"] isKindOfClass:NSNumber.class] &&
        [unmount[@"exitStatus"] integerValue] == FMMountBackendProcessExitNotMounted;
    if (unmount == nil ||
        (![unmount[@"reportedSuccess"] boolValue] && !alreadyDetached)) {
        if (unmount != nil && !alreadyDetached) {
            FMMountBackendExecutorFail(
                error, 8, FMMountBackendFailureDescription(unmount),
                FMMountBackendErrnoFromReport(unmount));
        }
        return nil;
    }

    NSDictionary *mount = FMMountBackendInvokeCommand(@"mount-fonts", error);
    if (mount == nil || ![mount[@"reportedSuccess"] boolValue]) {
        if (mount != nil) {
            FMMountBackendExecutorFail(
                error, 9, FMMountBackendFailureDescription(mount),
                FMMountBackendErrnoFromReport(mount));
        }
        return nil;
    }
    return @{
        @"operation" : @"refreshPreparedSystemFontsMapping",
        @"reportedSuccess" : @YES,
        @"mountBackend" : FMMountBackendIdentifier,
        @"mountBackendVersion" : FMMountBackendVersion,
        @"detachWasRequired" : alreadyDetached ? @NO : @YES,
        @"unmount" : unmount,
        @"mount" : mount,
    };
}
