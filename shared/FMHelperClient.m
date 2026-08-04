#import "FMHelperClient.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <roothide.h>
#import <spawn.h>
#import <stdlib.h>
#import <sys/wait.h>
#import <unistd.h>

#import "FMDataModel.h"
#import "FMStatusContract.h"

extern char **environ;

static NSError *FMHelperError(FMStatusErrorCode code, NSString *description) {
    return [NSError errorWithDomain:FMStatusErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

static BOOL FMHelperIsJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSDictionary<NSString *, id> *FMFetchJSONFromHelper(
    NSArray<NSString *> *commandArguments,
    NSString *operationName,
    NSError **error) {
    NSString *helperPath = jbroot(@"/usr/libexec/fontmanagerd");
    if (![NSFileManager.defaultManager isExecutableFileAtPath:helperPath]) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorHelperUnavailable,
                                   @"fontmanagerd is missing or not executable.");
        }
        return nil;
    }

    int outputPipe[2] = {-1, -1};
    if (pipe(outputPipe) != 0) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorHelperFailed, @"Unable to create helper output pipe.");
        }
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    posix_spawn_file_actions_addclose(&actions, outputPipe[1]);

    const char *executable = helperPath.fileSystemRepresentation;
    NSUInteger argumentCount = commandArguments.count + 2;
    char **arguments = calloc(argumentCount, sizeof(char *));
    if (arguments == NULL) {
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[0]);
        close(outputPipe[1]);
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorHelperFailed,
                                   @"Unable to allocate helper arguments.");
        }
        return nil;
    }
    arguments[0] = (char *)executable;
    [commandArguments enumerateObjectsUsingBlock:^(NSString *argument,
                                                    NSUInteger index,
                                                    BOOL *stop) {
        (void)stop;
        arguments[index + 1] = (char *)argument.UTF8String;
    }];

    pid_t child = 0;
    int spawnResult = posix_spawn(&child, executable, &actions, NULL, arguments, environ);
    free(arguments);
    posix_spawn_file_actions_destroy(&actions);
    close(outputPipe[1]);

    if (spawnResult != 0) {
        close(outputPipe[0]);
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorHelperFailed,
                                   [NSString stringWithFormat:@"Unable to launch fontmanagerd (%d).",
                                                              spawnResult]);
        }
        return nil;
    }

    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[4096];
    BOOL outputTooLarge = NO;
    BOOL readFailed = NO;
    while (YES) {
        ssize_t count = read(outputPipe[0], buffer, sizeof(buffer));
        if (count > 0) {
            if (output.length + (NSUInteger)count > 1024 * 1024) {
                outputTooLarge = YES;
                break;
            }
            [output appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            readFailed = YES;
        }
        break;
    }
    close(outputPipe[0]);

    int childStatus = 0;
    pid_t waitResult = -1;
    do {
        waitResult = waitpid(child, &childStatus, 0);
    } while (waitResult < 0 && errno == EINTR);

    if (outputTooLarge) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorHelperOutputTooLarge,
                                   @"fontmanagerd returned more than 1 MiB.");
        }
        return nil;
    }
    if (readFailed || waitResult < 0) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorHelperFailed,
                                   @"Unable to read or wait for fontmanagerd.");
        }
        return nil;
    }
    if (!WIFEXITED(childStatus) || WEXITSTATUS(childStatus) != 0) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorHelperFailed,
                                   [NSString stringWithFormat:@"fontmanagerd %@ command failed.",
                                                              operationName]);
        }
        return nil;
    }

    NSError *jsonError = nil;
    id document = [NSJSONSerialization JSONObjectWithData:output options:0 error:&jsonError];
    if (document == nil) {
        if (error != NULL) {
            *error = jsonError ?: FMHelperError(FMStatusErrorInvalidDocument,
                                                 @"Invalid helper JSON output.");
        }
        return nil;
    }
    return document;
}

NSDictionary<NSString *, id> *FMFetchStatusFromHelper(NSError **error) {
    NSDictionary *document = FMFetchJSONFromHelper(@[ @"status", @"--json" ],
                                                    @"status", error);
    NSError *contractError = nil;
    if (document == nil || !FMValidateStatusDocument(document, &contractError)) {
        if (document != nil && error != NULL) {
            *error = contractError ?: FMHelperError(FMStatusErrorInvalidDocument,
                                                     @"Invalid helper status output.");
        }
        return nil;
    }
    return document;
}

NSDictionary<NSString *, id> *FMFetchFontCatalogFromHelper(NSString *systemBuild,
                                                            NSError **error) {
    if (![systemBuild isKindOfClass:NSString.class] || systemBuild.length == 0) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorInvalidDocument,
                                   @"A system build is required for catalog inspection.");
        }
        return nil;
    }
    NSDictionary *document = FMFetchJSONFromHelper(
        @[ @"inspect-font-catalog", @"--confirm-build", systemBuild, @"--json" ],
        @"font catalog inspection", error);
    NSError *validationError = nil;
    if (document == nil ||
        !FMValidateFontCatalogPreviewDocument(document, systemBuild, &validationError)) {
        if (document != nil && error != NULL) {
            *error = validationError ?: FMHelperError(FMStatusErrorInvalidDocument,
                                                       @"Invalid font catalog output.");
        }
        return nil;
    }
    return document;
}

NSDictionary<NSString *, id> *FMAdoptProfileFromHelper(
    NSString *systemBuild,
    NSString *profileID,
    NSError **error) {
    if (![systemBuild isKindOfClass:NSString.class] || systemBuild.length == 0 ||
        ![profileID isKindOfClass:NSString.class] || profileID.length == 0) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorInvalidDocument,
                                   @"A system build and Profile are required for adoption.");
        }
        return nil;
    }
    NSDictionary *report = FMFetchJSONFromHelper(
        @[ @"adopt-profile", @"--confirm-build", systemBuild,
           @"--profile-id", profileID, @"--json" ],
        @"Profile adoption", error);
    BOOL valid = [report[@"operation"] isEqual:@"adoptProfile"] &&
        ([report[@"status"] isEqual:@"adopted"] ||
         [report[@"status"] isEqual:@"alreadyAdopted"]) &&
        [report[@"systemBuild"] isEqual:systemBuild] &&
        [report[@"profileID"] isEqual:profileID] &&
        ![report[@"mirrorChanged"] boolValue] &&
        ![report[@"stateChanged"] boolValue] &&
        ![report[@"providerInvoked"] boolValue] &&
        ![report[@"restartRequested"] boolValue];
    if (report == nil || !valid) {
        if (report != nil && error != NULL) {
            *error = FMHelperError(FMStatusErrorInvalidDocument,
                                   @"Invalid Profile adoption helper output.");
        }
        return nil;
    }
    return report;
}

NSDictionary<NSString *, id> *FMStageProfileFromHelper(
    NSString *systemBuild,
    NSString *profileID,
    NSError **error) {
    if (![systemBuild isKindOfClass:NSString.class] || systemBuild.length == 0 ||
        (profileID != nil &&
         (![profileID isKindOfClass:NSString.class] || profileID.length == 0))) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorInvalidDocument,
                                   @"A valid font selection is required for staging.");
        }
        return nil;
    }
    NSArray<NSString *> *arguments = profileID != nil
        ? @[ @"stage-profile", @"--confirm-build", systemBuild,
             @"--profile-id", profileID, @"--json" ]
        : @[ @"stage-stock", @"--confirm-build", systemBuild, @"--json" ];
    NSString *expectedOperation = profileID != nil ? @"stageProfile" : @"stageStock";
    id expectedProfileID = profileID ?: NSNull.null;
    NSDictionary *report = FMFetchJSONFromHelper(
        arguments, profileID != nil ? @"Profile stage" : @"Stock stage", error);
    BOOL valid = [report[@"operation"] isEqual:expectedOperation] &&
        ([report[@"status"] isEqual:@"staged"] ||
         [report[@"status"] isEqual:@"alreadyStaged"]) &&
        [report[@"systemBuild"] isEqual:systemBuild] &&
        [report[@"profileID"] isEqual:expectedProfileID] &&
        ![report[@"providerInvoked"] boolValue] &&
        ![report[@"restartRequested"] boolValue];
    if (report == nil || !valid) {
        if (report != nil && error != NULL) {
            *error = FMHelperError(FMStatusErrorInvalidDocument,
                                   @"Invalid font stage helper output.");
        }
        return nil;
    }
    return report;
}

static NSDictionary<NSString *, id> *FMFetchRestartReportFromHelper(
    NSString *systemBuild,
    NSString *command,
    NSString *operation,
    NSSet<NSString *> *allowedStatuses,
    NSError **error) {
    if (![systemBuild isKindOfClass:NSString.class] || systemBuild.length == 0) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorInvalidDocument,
                                   @"A system build is required for restart operations.");
        }
        return nil;
    }
    NSDictionary *report = FMFetchJSONFromHelper(
        @[ command, @"--confirm-build", systemBuild, @"--json" ],
        operation, error);
    if (report == nil) return nil;
    BOOL valid = [report[@"operation"] isEqual:operation] &&
                 [report[@"systemBuild"] isEqual:systemBuild] &&
                 [allowedStatuses containsObject:report[@"status"]];
    if (!valid) {
        if (error != NULL) {
            *error = FMHelperError(FMStatusErrorInvalidDocument,
                                   @"Invalid userspace restart helper output.");
        }
        return nil;
    }
    return report;
}

NSDictionary<NSString *, id> *FMFetchUserspaceRebootPreflightFromHelper(
    NSString *systemBuild,
    NSError **error) {
    return FMFetchRestartReportFromHelper(
        systemBuild, @"preflight-userspace-reboot", @"preflightUserspaceReboot",
        [NSSet setWithObject:@"eligible"], error);
}

NSDictionary<NSString *, id> *FMReconcileAfterRestartFromHelper(
    NSString *systemBuild,
    NSError **error) {
    return FMFetchRestartReportFromHelper(
        systemBuild, @"reconcile-after-restart", @"reconcileAfterRestart",
        [NSSet setWithArray:@[
            @"notRequested", @"waitingForRestart", @"reconciled",
            @"alreadyReconciled"
        ]], error);
}

NSDictionary<NSString *, id> *FMRequestUserspaceRestartFromHelper(
    NSString *systemBuild,
    NSError **error) {
    return FMFetchRestartReportFromHelper(
        systemBuild, @"request-userspace-reboot", @"requestUserspaceReboot",
        [NSSet setWithObject:@"armed"], error);
}

NSDictionary<NSString *, id> *FMRequestRespringFromHelper(
    NSString *systemBuild,
    NSError **error) {
    return FMFetchRestartReportFromHelper(
        systemBuild, @"request-respring", @"requestRespring",
        [NSSet setWithObject:@"armed"], error);
}

NSDictionary<NSString *, id> *FMSetAutomaticRespringFromHelper(
    NSString *systemBuild,
    BOOL enabled,
    NSError **error) {
    if (![systemBuild isKindOfClass:NSString.class] || systemBuild.length == 0) {
        if (error != NULL) {
            *error = FMHelperError(
                FMStatusErrorInvalidDocument,
                @"A system build is required for the automatic Respring policy.");
        }
        return nil;
    }
    NSString *command = enabled
        ? @"enable-auto-respring" : @"disable-auto-respring";
    NSDictionary *report = FMFetchJSONFromHelper(
        @[ command, @"--confirm-build", systemBuild, @"--json" ],
        @"automatic Respring policy", error);
    NSSet<NSString *> *allowedStatuses = enabled
        ? [NSSet setWithArray:@[ @"enabled", @"alreadyEnabled" ]]
        : [NSSet setWithArray:@[ @"disabled", @"alreadyDisabled" ]];
    BOOL valid = [report[@"operation"] isEqual:@"setAutomaticRespring"] &&
        [report[@"systemBuild"] isEqual:systemBuild] &&
        [allowedStatuses containsObject:report[@"status"]] &&
        FMHelperIsJSONBoolean(report[@"enabled"]) &&
        [report[@"enabled"] boolValue] == enabled &&
        FMHelperIsJSONBoolean(report[@"stateChanged"]) &&
        FMHelperIsJSONBoolean(report[@"providerInvoked"]) &&
        ![report[@"providerInvoked"] boolValue] &&
        FMHelperIsJSONBoolean(report[@"restartRequested"]) &&
        ![report[@"restartRequested"] boolValue];
    if (report == nil || !valid) {
        if (report != nil && error != NULL) {
            *error = FMHelperError(
                FMStatusErrorInvalidDocument,
                @"Invalid automatic Respring policy helper output.");
        }
        return nil;
    }
    return report;
}
