#import "FMProviderExecutor.h"

#import <errno.h>
#import <fcntl.h>
#import <roothide.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#import "FMProviderCompatibility.h"
#import "FMProviderPaths.h"

NSString *const FMProviderExecutorErrorDomain =
    @"com.hmmzzz.fontmanager.providerexecutor";

static NSString *const FMProviderInterpreterLogicalPath = @"/usr/bin/dash";

static BOOL FMProviderExecutorFail(NSError **error,
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
        *error = [NSError errorWithDomain:FMProviderExecutorErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static NSDictionary<NSString *, id> *FMRequireCompatibleProviderExecutable(
    NSError **error) {
    if (geteuid() != 0) {
        FMProviderExecutorFail(error, 1,
                               @"Provider execution requires uid 0.", 0);
        return nil;
    }
    NSString *executablePath = jbroot(FMProviderExecutableLogicalPath);
    NSError *compatibilityError = nil;
    NSDictionary *compatibility =
        FMInspectProviderExecutableCompatibilityAtPath(
            executablePath, &compatibilityError);
    if (compatibility == nil || ![compatibility[@"compatible"] boolValue]) {
        if (error != NULL) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
                @"The Provider executable does not satisfy the fixed capability contract."
                forKey:NSLocalizedDescriptionKey];
            if (compatibilityError != nil) {
                userInfo[NSUnderlyingErrorKey] = compatibilityError;
            }
            *error = [NSError errorWithDomain:FMProviderExecutorErrorDomain
                                         code:2
                                     userInfo:userInfo];
        }
        return nil;
    }
    NSString *interpreterPath = jbroot(FMProviderInterpreterLogicalPath);
    struct stat interpreterInfo = {0};
    if (lstat(interpreterPath.fileSystemRepresentation, &interpreterInfo) != 0 ||
        !S_ISREG(interpreterInfo.st_mode) || interpreterInfo.st_uid != 0 ||
        (interpreterInfo.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
        access(interpreterPath.fileSystemRepresentation, X_OK) != 0) {
        FMProviderExecutorFail(
            error, 2, @"The verified Provider interpreter is unavailable.",
            errno != 0 ? errno : EPERM);
        return nil;
    }
    NSString *jbrootToolPath = jbroot(@"/usr/bin/jbroot");
    if (access(jbrootToolPath.fileSystemRepresentation, X_OK) != 0) {
        FMProviderExecutorFail(error, 2,
                               @"The RootHide path utility is unavailable.", errno);
        return nil;
    }
    return compatibility;
}

static BOOL FMValidateFixedProviderEnvironment(BOOL requireAlias,
                                               BOOL *aliasPresent,
                                               NSError **error) {
    BOOL preferencePresent = NO;
    NSError *pathError = nil;
    if (!FMProviderPreferenceExists(&preferencePresent, &pathError) ||
        preferencePresent) {
        if (error != NULL) {
            *error = pathError ?: [NSError errorWithDomain:FMProviderExecutorErrorDomain
                                                      code:3
                                                  userInfo:@{
                                                      NSLocalizedDescriptionKey :
                                                          @"Provider auto-mount preference appeared after preflight."
                                                  }];
        }
        return NO;
    }
    BOOL localAliasPresent = NO;
    if (!FMValidateProviderAlias(requireAlias, &localAliasPresent, &pathError)) {
        if (error != NULL) {
            *error = pathError;
        }
        return NO;
    }
    if (aliasPresent != NULL) *aliasPresent = localAliasPresent;
    return YES;
}

static NSDictionary<NSString *, id> *FMInvokeFixedProviderOption(
    NSString *option,
    NSError **error) {
    if (![option isEqual:@"--skip-copy"] && ![option isEqual:@"-u"]) {
        FMProviderExecutorFail(error, 3,
                               @"The fixed Provider option is invalid.", 0);
        return nil;
    }

    NSString *interpreterPath = jbroot(FMProviderInterpreterLogicalPath);
    char *const arguments[] = {
        (char *)"sh",
        (char *)FMProviderExecutableLogicalPath.fileSystemRepresentation,
        (char *)option.UTF8String,
        (char *)"/System/Library/Fonts",
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
        FMProviderExecutorFail(error, 4,
                               @"Unable to initialize Provider process isolation.",
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
        FMProviderExecutorFail(error, 4,
                               @"Unable to isolate Provider process output.", result);
        return nil;
    }

    pid_t child = -1;
    int spawnResult = posix_spawn(&child, interpreterPath.fileSystemRepresentation,
                                  &actions, NULL, arguments, environment);
    posix_spawn_file_actions_destroy(&actions);
    if (spawnResult != 0) {
        FMProviderExecutorFail(error, 5,
                               @"The verified Provider process could not be started.",
                               spawnResult);
        return nil;
    }

    int status = 0;
    pid_t waitResult = -1;
    do {
        waitResult = waitpid(child, &status, 0);
    } while (waitResult < 0 && errno == EINTR);
    if (waitResult != child) {
        FMProviderExecutorFail(error, 6,
                               @"The verified Provider process could not be observed.",
                               errno != 0 ? errno : ECHILD);
        return nil;
    }

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

NSDictionary<NSString *, id> *FMInvokeProviderForPreparedSystemFonts(
    NSError **error) {
    BOOL aliasPresent = NO;
    NSDictionary *compatibility =
        FMRequireCompatibleProviderExecutable(error);
    if (compatibility == nil ||
        !FMValidateFixedProviderEnvironment(NO, &aliasPresent, error)) {
        return nil;
    }
    NSDictionary *execution = FMInvokeFixedProviderOption(@"--skip-copy", error);
    if (execution == nil) return nil;
    NSMutableDictionary *report = [execution mutableCopy];
    report[@"aliasWasPresent"] = @(aliasPresent);
    report[@"providerCompatibility"] = compatibility[@"compatibility"];
    return report;
}

NSDictionary<NSString *, id> *FMRefreshProviderForPreparedSystemFonts(
    NSError **error) {
    BOOL aliasPresent = NO;
    NSDictionary *compatibility =
        FMRequireCompatibleProviderExecutable(error);
    if (compatibility == nil ||
        !FMValidateFixedProviderEnvironment(YES, &aliasPresent, error)) {
        return nil;
    }

    NSDictionary *unmount = FMInvokeFixedProviderOption(@"-u", error);
    if (unmount == nil || ![unmount[@"reportedSuccess"] boolValue]) {
        if (unmount != nil) {
            FMProviderExecutorFail(error, 7,
                                   @"The managed font mapping could not be detached.", 0);
        }
        return nil;
    }

    NSDictionary *mount = FMInvokeFixedProviderOption(@"--skip-copy", error);
    if (mount == nil || ![mount[@"reportedSuccess"] boolValue]) {
        if (mount != nil) {
            FMProviderExecutorFail(error, 8,
                                   @"The prepared font mirror could not be reconnected.", 0);
        }
        return nil;
    }

    BOOL refreshedAliasPresent = NO;
    if (!FMValidateProviderAlias(YES, &refreshedAliasPresent, error)) {
        return nil;
    }
    return @{
        @"operation" : @"refreshPreparedSystemFontsMapping",
        @"reportedSuccess" : @YES,
        @"aliasWasPresent" : @(aliasPresent),
        @"aliasPresent" : @(refreshedAliasPresent),
        @"providerCompatibility" : compatibility[@"compatibility"],
        @"unmount" : unmount,
        @"mount" : mount,
    };
}
