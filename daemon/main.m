#import <Foundation/Foundation.h>

#import <roothide.h>

#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "../shared/FMDeviceMountEngine.h"
#import "../shared/FMDeviceAutoMount.h"
#import "../shared/FMAutomaticRespringPolicy.h"
#import "../shared/FMDevicePackageLifecycle.h"
#import "../shared/FMDeviceFontCatalog.h"
#import "../shared/FMDeviceProfileActivation.h"
#import "../shared/FMDeviceProfileAdoption.h"
#import "../shared/FMDeviceProfileStage.h"
#import "../shared/FMDeviceRestartCoordinator.h"
#import "../shared/FMDeviceStockSnapshot.h"
#import "../shared/FMEnvironmentProbe.h"
#import "../shared/FMFileStore.h"
#import "../shared/FMStatusContract.h"

static NSString *const FMAutomaticMountReceiptLogicalPath =
    @"/var/lib/fontmanager/automount-last.json";

static BOOL FMAutomaticMountIsLaunchdRun(void) {
    const char *serviceNameBytes = getenv("XPC_SERVICE_NAME");
    NSString *serviceName = serviceNameBytes != NULL
        ? [NSString stringWithUTF8String:serviceNameBytes]
        : nil;
    return [serviceName isEqual:@"com.hmmzzz.fontmanager.automount"];
}

static NSString *FMAutomaticMountTimestamp(NSDate *date) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:date];
}

static NSArray<NSDictionary<NSString *, id> *> *FMAutomaticMountErrorChain(
    NSError *error) {
    NSMutableArray<NSDictionary<NSString *, id> *> *chain =
        [NSMutableArray array];
    NSError *current = error;
    for (NSUInteger depth = 0; current != nil && depth < 8; depth++) {
        NSMutableDictionary<NSString *, id> *entry = [@{
            @"domain" : current.domain ?: @"unknown",
            @"code" : @(current.code),
        } mutableCopy];
        // The outer automatic-mount message is a fixed, path-free stage label.
        // Underlying localized descriptions may contain the current randomized
        // jbroot, so only their domain/code pairs are persisted.
        if (depth == 0 && current.localizedDescription.length > 0) {
            entry[@"stageMessage"] = current.localizedDescription;
        }
        [chain addObject:entry];
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        current = [underlying isKindOfClass:NSError.class] ? underlying : nil;
    }
    return chain;
}

static BOOL FMWriteAutomaticMountReceipt(
    NSDate *startedAt,
    NSDictionary<NSString *, id> *report,
    NSError *operationError,
    NSDictionary<NSString *, id> *automaticRespringFacts,
    NSError **error) {
    NSDate *finishedAt = NSDate.date;
    const char *serviceNameBytes = getenv("XPC_SERVICE_NAME");
    NSString *serviceName = serviceNameBytes != NULL
        ? [NSString stringWithUTF8String:serviceNameBytes]
        : nil;
    BOOL launchdRun = [serviceName
        isEqual:@"com.hmmzzz.fontmanager.automount"];
    NSMutableDictionary<NSString *, id> *receipt = [@{
        @"schemaVersion" : @1,
        @"operation" : @"automaticMountRunReceipt",
        @"runKind" : launchdRun ? @"launchd" : @"manual",
        @"serviceName" : serviceName ?: NSNull.null,
        @"startedAt" : FMAutomaticMountTimestamp(startedAt),
        @"finishedAt" : FMAutomaticMountTimestamp(finishedAt),
        @"durationMilliseconds" :
            @((long long)([finishedAt timeIntervalSinceDate:startedAt] * 1000.0)),
        @"realUID" : @(getuid()),
        @"effectiveUID" : @(geteuid()),
        @"jailbreakSession" : @(jbrand()),
        @"outcome" : report != nil ? @"success" : @"failure",
    } mutableCopy];
    if (report != nil) {
        for (NSString *key in @[
                 @"status", @"systemBuild", @"mountBackendInvoked",
                 @"mountBackendReportedSuccess", @"mappingChanged",
                 @"mappingActive", @"mappingReadOnly", @"stateChanged",
                 @"springBoardWasRunning",
                 @"springBoardObservationAvailable",
                 @"activationRefreshRequired", @"lateAutomaticMountPending",
                 @"pendingProfileChange", @"staleRestartEvidenceCleared",
                 @"manualRespringRequired",
                 @"restartRequested"
             ]) {
            id value = report[key];
            if (value != nil) receipt[key] = value;
        }
    } else {
        receipt[@"errorChain"] = FMAutomaticMountErrorChain(operationError);
    }
    if (automaticRespringFacts != nil) {
        [receipt addEntriesFromDictionary:automaticRespringFacts];
    }
    return FMWriteJSONObjectAtomically(
        receipt, jbroot(FMAutomaticMountReceiptLogicalPath), 0600, error);
}

static BOOL FMAutomaticRespringIsEligible(
    NSDictionary<NSString *, id> *report,
    BOOL exactLaunchdInvocation) {
    return FMAutomaticRespringEligibleForReport(
        report, exactLaunchdInvocation, FMAutomaticMountIsLaunchdRun());
}

static BOOL FMLateAutomaticMountNeedsRestartEvidence(
    NSDictionary<NSString *, id> *report,
    BOOL exactLaunchdInvocation) {
    return FMLateAutomaticMountNeedsRestartEvidenceForReport(
        report, exactLaunchdInvocation, FMAutomaticMountIsLaunchdRun());
}

static void FMPrintUsage(FILE *stream) {
    fprintf(stream,
            "usage: fontmanagerd status [--json]\n"
            "       fontmanagerd privilege-status [--json]\n"
            "       fontmanagerd auto-mount [--json]\n"
            "       fontmanagerd package-configure [--json]\n"
            "       fontmanagerd package-prepare-removal [--json]\n"
            "       fontmanagerd preflight-stock-mirror --confirm-build <build> [--json]\n"
            "       fontmanagerd prepare-stock-mirror --confirm-build <build> [--json]\n"
            "       fontmanagerd preflight-prepared-stock-mount --confirm-build <build> [--json]\n"
            "       fontmanagerd mount-prepared-stock --confirm-build <build> [--json]\n"
            "       fontmanagerd inspect-font-catalog --confirm-build <build> [--json]\n"
            "       fontmanagerd preflight-profile --confirm-build <build> --profile-id <id> [--json]\n"
            "       fontmanagerd preflight-stage-profile --confirm-build <build> --profile-id <id> [--json]\n"
            "       fontmanagerd stage-profile --confirm-build <build> --profile-id <id> [--json]\n"
            "       fontmanagerd preflight-stage-stock --confirm-build <build> [--json]\n"
            "       fontmanagerd stage-stock --confirm-build <build> [--json]\n"
            "       fontmanagerd repair-working-profile --confirm-build <build> [--json]\n"
            "       fontmanagerd preflight-stock-snapshot --confirm-build <build> [--json]\n"
            "       fontmanagerd capture-stock-snapshot --confirm-build <build> [--json]\n"
            "       fontmanagerd preflight-userspace-reboot --confirm-build <build> [--json]\n"
            "       fontmanagerd request-userspace-reboot --confirm-build <build> [--json]\n"
            "       fontmanagerd request-respring --confirm-build <build> [--json]\n"
            "       fontmanagerd enable-auto-respring --confirm-build <build> [--json]\n"
            "       fontmanagerd disable-auto-respring --confirm-build <build> [--json]\n"
            "       fontmanagerd reconcile-after-restart --confirm-build <build> [--json]\n"
            "       fontmanagerd adopt-profile --confirm-build <build> --profile-id <id> [--json]\n");
}

static BOOL FMWriteString(FILE *stream, NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    return fwrite(data.bytes, 1, data.length, stream) == data.length;
}

static NSString *FMErrorChainDescription(NSError *error) {
    if (error == nil) {
        return @"unknown error";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSError *current = error;
    for (NSUInteger depth = 0; current != nil && depth < 8; depth++) {
        [parts addObject:[NSString stringWithFormat:@"%@(code %ld): %@",
                                                   current.domain,
                                                   (long)current.code,
                                                   current.localizedDescription]];
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        current = [underlying isKindOfClass:NSError.class] ? underlying : nil;
    }
    return [parts componentsJoinedByString:@" <- "];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        umask(077);
        if (argc == 2 && strcmp(argv[1], "--version") == 0) {
            fprintf(stdout, "fontmanagerd 0.3.0\n");
            return 0;
        }

        BOOL statusCommand = argc >= 2 && strcmp(argv[1], "status") == 0;
        BOOL privilegeCommand = argc >= 2 && strcmp(argv[1], "privilege-status") == 0;
        BOOL autoMountCommand = argc >= 2 && strcmp(argv[1], "auto-mount") == 0;
        BOOL packageConfigureCommand = argc >= 2 &&
            strcmp(argv[1], "package-configure") == 0;
        BOOL packageRemovalCommand = argc >= 2 &&
            strcmp(argv[1], "package-prepare-removal") == 0;
        BOOL prepareCommand = argc >= 2 &&
                              strcmp(argv[1], "prepare-stock-mirror") == 0;
        BOOL preflightCommand = argc >= 2 &&
                                strcmp(argv[1], "preflight-stock-mirror") == 0;
        BOOL mountPreflightCommand = argc >= 2 &&
            strcmp(argv[1], "preflight-prepared-stock-mount") == 0;
        BOOL mountCommand = argc >= 2 &&
                            strcmp(argv[1], "mount-prepared-stock") == 0;
        BOOL fontCatalogCommand = argc >= 2 &&
                                  strcmp(argv[1], "inspect-font-catalog") == 0;
        BOOL profilePreflightCommand = argc >= 2 &&
                                       strcmp(argv[1], "preflight-profile") == 0;
        BOOL profileAdoptionCommand = argc >= 2 &&
                                      strcmp(argv[1], "adopt-profile") == 0;
        BOOL profileStagePreflightCommand = argc >= 2 &&
            strcmp(argv[1], "preflight-stage-profile") == 0;
        BOOL profileStageCommand = argc >= 2 &&
                                   strcmp(argv[1], "stage-profile") == 0;
        BOOL stockStagePreflightCommand = argc >= 2 &&
            strcmp(argv[1], "preflight-stage-stock") == 0;
        BOOL stockStageCommand = argc >= 2 &&
                                 strcmp(argv[1], "stage-stock") == 0;
        BOOL profileRepairCommand = argc >= 2 &&
                                    strcmp(argv[1], "repair-working-profile") == 0;
        BOOL stockSnapshotPreflightCommand = argc >= 2 &&
            strcmp(argv[1], "preflight-stock-snapshot") == 0;
        BOOL stockSnapshotCaptureCommand = argc >= 2 &&
            strcmp(argv[1], "capture-stock-snapshot") == 0;
        BOOL rebootPreflightCommand = argc >= 2 &&
            strcmp(argv[1], "preflight-userspace-reboot") == 0;
        BOOL rebootRequestCommand = argc >= 2 &&
            strcmp(argv[1], "request-userspace-reboot") == 0;
        BOOL respringRequestCommand = argc >= 2 &&
            strcmp(argv[1], "request-respring") == 0;
        BOOL autoRespringEnableCommand = argc >= 2 &&
            strcmp(argv[1], "enable-auto-respring") == 0;
        BOOL autoRespringDisableCommand = argc >= 2 &&
            strcmp(argv[1], "disable-auto-respring") == 0;
        BOOL restartReconcileCommand = argc >= 2 &&
            strcmp(argv[1], "reconcile-after-restart") == 0;
        BOOL readOnlyArgumentsValid =
            (statusCommand || privilegeCommand) && argc <= 3 &&
            (argc != 3 || strcmp(argv[2], "--json") == 0);
        BOOL autoMountArgumentsValid =
            autoMountCommand && (argc == 2 || argc == 3) &&
            (argc != 3 || strcmp(argv[2], "--json") == 0);
        BOOL packageArgumentsValid =
            (packageConfigureCommand || packageRemovalCommand) &&
            (argc == 2 || argc == 3) &&
            (argc != 3 || strcmp(argv[2], "--json") == 0);
        BOOL prepareArgumentsValid =
            (prepareCommand || preflightCommand || mountPreflightCommand ||
             mountCommand || fontCatalogCommand || profileRepairCommand) &&
            (argc == 4 || argc == 5) &&
            strcmp(argv[2], "--confirm-build") == 0 &&
            (argc != 5 || strcmp(argv[4], "--json") == 0);
        if (stockSnapshotPreflightCommand || stockSnapshotCaptureCommand) {
            prepareArgumentsValid =
                (argc == 4 || argc == 5) &&
                strcmp(argv[2], "--confirm-build") == 0 &&
                (argc != 5 || strcmp(argv[4], "--json") == 0);
        }
        BOOL profileArgumentsValid =
            (profilePreflightCommand || profileAdoptionCommand ||
             profileStagePreflightCommand || profileStageCommand) &&
            (argc == 6 || argc == 7) &&
            strcmp(argv[2], "--confirm-build") == 0 &&
            strcmp(argv[4], "--profile-id") == 0 &&
            (argc != 7 || strcmp(argv[6], "--json") == 0);
        BOOL stockStageArgumentsValid =
            (stockStagePreflightCommand || stockStageCommand) &&
            (argc == 4 || argc == 5) &&
            strcmp(argv[2], "--confirm-build") == 0 &&
            (argc != 5 || strcmp(argv[4], "--json") == 0);
        BOOL restartArgumentsValid =
            (rebootPreflightCommand || rebootRequestCommand ||
             respringRequestCommand || restartReconcileCommand) &&
            (argc == 4 || argc == 5) &&
            strcmp(argv[2], "--confirm-build") == 0 &&
            (argc != 5 || strcmp(argv[4], "--json") == 0);
        BOOL autoRespringPolicyArgumentsValid =
            (autoRespringEnableCommand || autoRespringDisableCommand) &&
            (argc == 4 || argc == 5) &&
            strcmp(argv[2], "--confirm-build") == 0 &&
            (argc != 5 || strcmp(argv[4], "--json") == 0);
        if (argc < 2 || (!readOnlyArgumentsValid && !autoMountArgumentsValid &&
                         !packageArgumentsValid &&
                         !prepareArgumentsValid &&
                         !profileArgumentsValid && !stockStageArgumentsValid &&
                         !restartArgumentsValid &&
                         !autoRespringPolicyArgumentsValid)) {
            FMPrintUsage(stderr);
            return 64;
        }

        if (privilegeCommand) {
            uid_t realUID = getuid();
            uid_t effectiveUID = geteuid();
            NSDictionary *report = @{
                @"schemaVersion" : @1,
                @"operation" : @"privilegeStatus",
                @"realUID" : @(realUID),
                @"effectiveUID" : @(effectiveUID),
                @"rootAvailable" : effectiveUID == 0 ? @YES : @NO,
                @"setuidTransition" :
                    realUID != effectiveUID && effectiveUID == 0 ? @YES : @NO,
                @"filesystemMutated" : @NO,
            };
            if (argc == 3) {
                NSError *jsonError = nil;
                NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                               options:NSJSONWritingSortedKeys
                                                                 error:&jsonError];
                if (json == nil) {
                    fprintf(stderr, "privilege serialization failure: %s\n",
                            jsonError.localizedDescription.UTF8String);
                    return 70;
                }
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                return effectiveUID == 0 ? 0 : 77;
            }
            NSString *text = [NSString stringWithFormat:
                @"fontmanagerd privilege: real uid %u, effective uid %u, root available: %@\n",
                realUID, effectiveUID, effectiveUID == 0 ? @"yes" : @"no"];
            if (!FMWriteString(stdout, text)) return 74;
            return effectiveUID == 0 ? 0 : 77;
        }

        if (autoMountCommand) {
            if (getuid() != 0 || geteuid() != 0) {
                fprintf(stderr,
                        "Automatic mounting requires a root launchd caller.\n");
                return 77;
            }
            NSDate *autoMountStartedAt = NSDate.date;
            NSError *autoMountError = nil;
            NSDictionary *report =
                FMAutomountManagedDeviceFonts(&autoMountError);
            BOOL restartEvidenceRequired =
                FMLateAutomaticMountNeedsRestartEvidence(report, argc == 2);
            BOOL automaticRespringEligible = FMAutomaticRespringIsEligible(
                report, argc == 2);
            NSMutableDictionary<NSString *, id> *automaticRespringFacts = [@{
                @"restartEvidenceRequired" :
                    restartEvidenceRequired ? @YES : @NO,
                @"restartEvidenceArmed" : @NO,
                @"automaticRespringPolicyEnabled" :
                    [report[@"autoRespringEnabled"] boolValue] ? @YES : @NO,
                @"automaticRespringEligible" :
                    automaticRespringEligible ? @YES : @NO,
                @"automaticRespringAttempted" : @NO,
                @"automaticRespringArmed" : @NO,
                @"automaticRespringExecutionRequested" : @NO,
            } mutableCopy];
            NSError *automaticRespringError = nil;
            NSDictionary<NSString *, id> *automaticRespringReport = nil;
            if (restartEvidenceRequired) {
                if (automaticRespringEligible) {
                    automaticRespringFacts[@"automaticRespringAttempted"] = @YES;
                }
                automaticRespringReport = FMArmDeviceRespring(
                    report[@"systemBuild"], &automaticRespringError);
                if (automaticRespringReport != nil) {
                    automaticRespringFacts[@"restartEvidenceArmed"] = @YES;
                    automaticRespringFacts[@"automaticRespringArmed"] =
                        automaticRespringEligible ? @YES : @NO;
                    automaticRespringFacts[@"automaticRespringExecutionRequested"] =
                        automaticRespringEligible ? @YES : @NO;
                    automaticRespringFacts[@"restartRequested"] = @YES;
                    automaticRespringFacts[@"automaticRespringActivationMode"] =
                        automaticRespringReport[@"activationMode"] ?: @"unknown";
                } else {
                    automaticRespringFacts[@"restartEvidenceErrorChain"] =
                        FMAutomaticMountErrorChain(automaticRespringError);
                    if (automaticRespringEligible) {
                        automaticRespringFacts[@"automaticRespringErrorChain"] =
                            FMAutomaticMountErrorChain(automaticRespringError);
                    }
                }
            }
            NSError *receiptError = nil;
            if (!FMWriteAutomaticMountReceipt(
                    autoMountStartedAt, report, autoMountError,
                    automaticRespringFacts, &receiptError)) {
                fprintf(stderr,
                        "Automatic mount receipt unavailable (%s/%ld).\n",
                        receiptError.domain.UTF8String ?: "unknown",
                        (long)receiptError.code);
            }
            if (report == nil) {
                fprintf(stderr, "Automatic mount failure: %s\n",
                        FMErrorChainDescription(autoMountError).UTF8String);
                return 70;
            }
            if (automaticRespringReport != nil && automaticRespringEligible) {
                if (!FMExecuteDeviceRespring(
                        report[@"systemBuild"], &automaticRespringError)) {
                    automaticRespringFacts[@"automaticRespringExecutionRequested"] = @NO;
                    automaticRespringFacts[@"automaticRespringExecutionFailed"] = @YES;
                    automaticRespringFacts[@"automaticRespringErrorChain"] =
                        FMAutomaticMountErrorChain(automaticRespringError);
                    FMWriteAutomaticMountReceipt(
                        autoMountStartedAt, report, autoMountError,
                        automaticRespringFacts, NULL);
                    fprintf(stderr, "Automatic Respring execution failure: %s\n",
                            FMErrorChainDescription(automaticRespringError).UTF8String);
                }
                // Mounting succeeded and remains usable with the App's manual
                // Respring fallback even if the optional refresh could not run.
                return 0;
            }
            if (argc == 3) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                               options:NSJSONWritingSortedKeys
                                                                 error:&autoMountError];
                if (json == nil) {
                    fprintf(stderr, "Automatic mount serialization failure: %s\n",
                            autoMountError.localizedDescription.UTF8String);
                    return 70;
                }
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                return 0;
            }
            NSString *text = [NSString stringWithFormat:
                @"Automatic mount: %@.\n"
                 "Mount backend invoked: %@\nMapping changed: %@\n"
                 "State changed: %@\nStale restart evidence cleared: %@\n"
                 "Respring executed: no\n",
                report[@"status"],
                [report[@"mountBackendInvoked"] boolValue] ? @"yes" : @"no",
                [report[@"mappingChanged"] boolValue] ? @"yes" : @"no",
                [report[@"stateChanged"] boolValue] ? @"yes" : @"no",
                [report[@"staleRestartEvidenceCleared"] boolValue]
                    ? @"yes" : @"no"];
            return FMWriteString(stdout, text) ? 0 : 74;
        }

        if (autoRespringEnableCommand || autoRespringDisableCommand) {
            NSString *confirmedBuild = [NSString stringWithUTF8String:argv[3]];
            BOOL enabled = autoRespringEnableCommand;
            NSError *policyError = nil;
            NSDictionary *report = FMSetAutomaticRespringEnabled(
                confirmedBuild, enabled, &policyError);
            if (report == nil) {
                fprintf(stderr, "Automatic Respring policy failure: %s\n",
                        FMErrorChainDescription(policyError).UTF8String);
                return 70;
            }
            if (argc == 5) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                               options:NSJSONWritingSortedKeys
                                                                 error:&policyError];
                if (json == nil) {
                    fprintf(stderr,
                            "Automatic Respring policy serialization failure: %s\n",
                            policyError.localizedDescription.UTF8String);
                    return 70;
                }
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                return 0;
            }
            NSString *text = [NSString stringWithFormat:
                @"Automatic Respring: %@ for %@.\n"
                 "State changed: %@\nRestart requested: no\n",
                [report[@"enabled"] boolValue] ? @"enabled" : @"disabled",
                report[@"systemBuild"],
                [report[@"stateChanged"] boolValue] ? @"yes" : @"no"];
            return FMWriteString(stdout, text) ? 0 : 74;
        }

        if (packageConfigureCommand || packageRemovalCommand) {
            if (getuid() != 0 || geteuid() != 0) {
                fprintf(stderr,
                        "Package lifecycle operations require a real root caller.\n");
                return 77;
            }
            NSError *lifecycleError = nil;
            NSDictionary *report = packageConfigureCommand
                ? FMConfigureInstalledDevicePackage(&lifecycleError)
                : FMPrepareDevicePackageRemoval(&lifecycleError);
            if (report == nil) {
                fprintf(stderr, "Package lifecycle failure: %s\n",
                        FMErrorChainDescription(lifecycleError).UTF8String);
                return lifecycleError.code == 9 ? 75 : 70;
            }
            if (argc == 3) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                               options:NSJSONWritingSortedKeys
                                                                 error:&lifecycleError];
                if (json == nil) {
                    fprintf(stderr,
                            "Package lifecycle serialization failure: %s\n",
                            lifecycleError.localizedDescription.UTF8String);
                    return 70;
                }
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                return 0;
            }
            NSString *text = [NSString stringWithFormat:
                @"Package lifecycle: %@ (%@).\n"
                 "Mapping changed: %@\nState changed: %@\n"
                 "Restart requested: no\n",
                report[@"operation"], report[@"status"],
                [report[@"mappingChanged"] boolValue] ? @"yes" : @"no",
                [report[@"stateChanged"] boolValue] ? @"yes" : @"no"];
            return FMWriteString(stdout, text) ? 0 : 74;
        }

        if (profilePreflightCommand || profileAdoptionCommand ||
            profileStagePreflightCommand || profileStageCommand ||
            stockStagePreflightCommand || stockStageCommand) {
            NSString *confirmedBuild = [NSString stringWithUTF8String:argv[3]];
            NSString *profileID = stockStagePreflightCommand || stockStageCommand
                ? nil
                : [NSString stringWithUTF8String:argv[5]];
            NSError *preflightError = nil;
            NSDictionary *report = profileAdoptionCommand
                ? FMAdoptDeviceProfile(confirmedBuild, profileID, &preflightError)
                : profileStageCommand || stockStageCommand
                    ? FMStageDeviceProfile(
                        confirmedBuild, profileID, &preflightError)
                    : profileStagePreflightCommand || stockStagePreflightCommand
                        ? FMCreateDeviceProfileStagePreflight(
                            confirmedBuild, profileID, &preflightError)
                        : FMCreateDeviceProfileActivationPreflight(
                            confirmedBuild, profileID, &preflightError);
            if (report == nil) {
                fprintf(stderr, "Profile %s failure: %s\n",
                        profileAdoptionCommand
                            ? "adoption"
                            : profileStageCommand || stockStageCommand
                                ? "stage"
                                : profileStagePreflightCommand ||
                                      stockStagePreflightCommand
                                    ? "stage preflight"
                                    : "activation preflight",
                        FMErrorChainDescription(preflightError).UTF8String);
                return 70;
            }
            BOOL JSONOutput = profileID != nil ? argc == 7 : argc == 5;
            if (JSONOutput) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                               options:NSJSONWritingSortedKeys
                                                                 error:&preflightError];
                if (json == nil) {
                    fprintf(stderr, "Profile operation serialization failure: %s\n",
                            preflightError.localizedDescription.UTF8String);
                    return 70;
                }
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                return 0;
            }
            NSString *text = profileAdoptionCommand
                ? [NSString stringWithFormat:
                    @"Privileged Profile %@ for %@.\n"
                     "Profile: %@ (%@ replacements)\n"
                     "Mirror changed: no\nState changed: no\nRestart requested: no\n",
                    [report[@"status"] isEqual:@"alreadyAdopted"]
                        ? @"already verified" : @"adopted",
                    report[@"systemBuild"], report[@"profileName"],
                    report[@"replacementCount"]]
                : profileStageCommand || stockStageCommand
                    ? [NSString stringWithFormat:
                        @"Profile staged for %@.\n"
                         "Profile: %@ (%@ managed paths)\n"
                         "Restart required: %@\nMount backend invoked: no\nRestart requested: no\n",
                        report[@"systemBuild"], report[@"profileName"],
                        report[@"managedPathCount"],
                        [report[@"restartRequired"] boolValue] ? @"yes" : @"no"]
                : profileStagePreflightCommand || stockStagePreflightCommand
                    ? [NSString stringWithFormat:
                        @"Profile stage preflight passed for %@.\n"
                         "Profile: %@ (%@ writes)\n"
                         "Filesystem mutated: no\nMirror changed: no\nRestart requested: no\n",
                        report[@"systemBuild"], report[@"profileName"],
                        report[@"writeCount"]]
                    : [NSString stringWithFormat:
                    @"Profile activation preflight passed for %@.\n"
                     "Profile: %@ (%@ replacements)\n"
                     "Filesystem mutated: no\nMirror changed: no\nRestart requested: no\n",
                    report[@"systemBuild"], report[@"profileName"],
                    report[@"replacementCount"]];
            return FMWriteString(stdout, text) ? 0 : 74;
        }

        if (rebootPreflightCommand || rebootRequestCommand || respringRequestCommand ||
            restartReconcileCommand) {
            NSString *confirmedBuild = [NSString stringWithUTF8String:argv[3]];
            NSError *restartError = nil;
            NSDictionary *report = nil;
            if (respringRequestCommand) {
                report = FMArmDeviceRespring(confirmedBuild, &restartError);
            } else if (rebootRequestCommand) {
                report = FMArmDeviceUserspaceReboot(confirmedBuild,
                                                    &restartError);
            } else if (restartReconcileCommand) {
                report = FMReconcileDeviceAfterRestart(confirmedBuild,
                                                       &restartError);
            } else {
                report = FMCreateDeviceUserspaceRebootPreflight(
                    confirmedBuild, &restartError);
            }
            if (report == nil) {
                fprintf(stderr, "Userspace restart %s failure: %s\n",
                        respringRequestCommand
                            ? "Respring request"
                            : rebootRequestCommand
                                ? "request"
                                : restartReconcileCommand
                                    ? "reconciliation"
                                    : "preflight",
                        FMErrorChainDescription(restartError).UTF8String);
                return 70;
            }

            BOOL outputWritten = NO;
            if (argc == 5) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                               options:NSJSONWritingSortedKeys
                                                                 error:&restartError];
                if (json != nil) {
                    outputWritten = fwrite(json.bytes, 1, json.length, stdout) == json.length &&
                                    fputc('\n', stdout) != EOF;
                }
            } else {
                NSString *text = nil;
                if (respringRequestCommand) {
                    text = [NSString stringWithFormat:
                        @"Respring armed for %@.\nExecutable: %@\n",
                        report[@"systemBuild"],
                        report[@"executableLogicalPath"]];
                } else if (rebootPreflightCommand) {
                    text = [NSString stringWithFormat:
                        @"Userspace restart preflight passed for %@.\n"
                         "Mirror verified: yes\nRestart requested: no\n",
                        report[@"systemBuild"]];
                } else if (restartReconcileCommand) {
                    text = [NSString stringWithFormat:
                        @"Restart reconciliation: %@ for %@.\n"
                         "Restart observed: %@\nState changed: %@\n",
                        report[@"status"], report[@"systemBuild"],
                        [report[@"restartObserved"] boolValue] ? @"yes" : @"no",
                        [report[@"stateChanged"] boolValue] ? @"yes" : @"no"];
                } else {
                    text = [NSString stringWithFormat:
                        @"Userspace restart armed for %@.\n"
                         "Executable: %@ reboot_userspace\n",
                        report[@"systemBuild"],
                        report[@"executableLogicalPath"]];
                }
                outputWritten = FMWriteString(stdout, text);
            }
            if (!outputWritten || fflush(stdout) != 0) {
                fprintf(stderr, "Userspace restart output failure.\n");
                return 74;
            }
            if (!rebootRequestCommand && !respringRequestCommand) return 0;

            close(STDOUT_FILENO);
            BOOL executed = respringRequestCommand
                ? FMExecuteDeviceRespring(confirmedBuild, &restartError)
                : FMExecuteDeviceUserspaceReboot(&restartError);
            if (!executed) {
                fprintf(stderr, "%s execution failure: %s\n",
                        respringRequestCommand ? "Respring" : "Userspace restart",
                        FMErrorChainDescription(restartError).UTF8String);
                return 70;
            }
            return 70;
        }

        if (prepareCommand || preflightCommand || mountPreflightCommand ||
            mountCommand || fontCatalogCommand || profileRepairCommand ||
            stockSnapshotPreflightCommand || stockSnapshotCaptureCommand) {
            if ((prepareCommand || mountCommand || stockSnapshotCaptureCommand) &&
                getuid() != 0) {
                fprintf(stderr,
                        "This administrative operation requires an explicit root caller.\n");
                return 77;
            }
            NSString *confirmedBuild = [NSString stringWithUTF8String:argv[3]];
            NSError *preparationError = nil;
            NSDictionary *report = nil;
            if (prepareCommand) {
                report = FMPrepareDeviceStockMirror(confirmedBuild, &preparationError);
            } else if (preflightCommand) {
                report = FMCreateDeviceStockMirrorPreflight(confirmedBuild,
                                                            &preparationError);
            } else if (mountPreflightCommand) {
                report = FMCreateDevicePreparedStockMountPreflight(
                    confirmedBuild, &preparationError);
            } else if (mountCommand) {
                report = FMMountPreparedDeviceStock(confirmedBuild,
                                                    &preparationError);
            } else if (profileRepairCommand) {
                report = FMRepairDeviceWorkingProfile(confirmedBuild,
                                                      &preparationError);
            } else if (stockSnapshotPreflightCommand) {
                report = FMCreateDeviceStockSnapshotPreflight(
                    confirmedBuild, &preparationError);
            } else if (stockSnapshotCaptureCommand) {
                report = FMCaptureDeviceStockSnapshot(
                    confirmedBuild, &preparationError);
            } else {
                report = FMCreateDeviceFontCatalogPreview(confirmedBuild,
                                                          &preparationError);
            }
            if (report == nil) {
                const char *operation = prepareCommand
                    ? "preparation"
                    : preflightCommand
                        ? "preflight"
                        : mountPreflightCommand
                            ? "mount preflight"
                            : mountCommand
                                ? "mount activation"
                                : profileRepairCommand
                                    ? "Profile repair"
                                    : stockSnapshotPreflightCommand
                                        ? "Stock snapshot preflight"
                                        : stockSnapshotCaptureCommand
                                            ? "Stock snapshot capture"
                                    : "font catalog inspection";
                fprintf(stderr, "%s failure: %s\n", operation,
                        FMErrorChainDescription(preparationError).UTF8String);
                return 70;
            }
            if (argc == 5) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                               options:NSJSONWritingSortedKeys
                                                                 error:&preparationError];
                if (json == nil) {
                    fprintf(stderr, "preparation serialization failure: %s\n",
                            preparationError.localizedDescription.UTF8String);
                    return 70;
                }
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                return 0;
            }
            NSString *text = nil;
            if (prepareCommand) {
                text = [NSString stringWithFormat:
                    @"Stock mirror prepared for %@.\n"
                     "Mapping changed: no\nMount backend invoked: no\n"
                     "Next classification: %@\n",
                    report[@"systemBuild"], report[@"nextClassification"]];
            } else if (preflightCommand) {
                text = [NSString stringWithFormat:
                    @"Stock mirror preflight passed for %@.\n"
                     "Filesystem mutated: no\nMount backend invoked: no\n",
                    report[@"systemBuild"]];
            } else if (mountPreflightCommand) {
                text = [NSString stringWithFormat:
                    @"Prepared Stock mount preflight passed for %@.\n"
                     "Filesystem mutated: no\nMount backend invoked: no\n"
                     "Mount backend would be invoked: %@\n",
                    report[@"systemBuild"],
                    [report[@"mountBackendWouldBeInvoked"] boolValue] ? @"yes" : @"no"];
            } else if (mountCommand) {
                text = [NSString stringWithFormat:
                    @"Prepared Stock mapping is managed for %@.\n"
                     "Mount backend invoked: %@\nMapping read-only: yes\n"
                     "State created: yes\nRestart requested: no\n",
                    report[@"systemBuild"],
                    [report[@"mountBackendInvoked"] boolValue] ? @"yes" : @"no"];
            } else if (profileRepairCommand) {
                text = [NSString stringWithFormat:
                    @"Interrupted Profile transition repaired for %@.\n"
                     "Managed paths: %@\nRestart required: %@\n"
                     "Mount backend invoked: no\nRestart requested: no\n",
                    report[@"systemBuild"], report[@"managedPathCount"],
                    [report[@"restartRequired"] boolValue] ? @"yes" : @"no"];
            } else if (stockSnapshotPreflightCommand) {
                text = [NSString stringWithFormat:
                    @"Stock snapshot preflight passed for %@.\n"
                     "Non-force unmount only: yes\nFilesystem mutated: no\n",
                    report[@"systemBuild"]];
            } else if (stockSnapshotCaptureCommand) {
                text = [NSString stringWithFormat:
                    @"Stock snapshot captured for %@.\n"
                     "Mapping active: yes\nForce unmount: no\nRestart requested: no\n",
                    report[@"systemBuild"]];
            } else {
                text = [NSString stringWithFormat:
                    @"Font catalog preview generated for %@.\n"
                     "Stock font files: %@\nRead-only: yes\nPersisted: no\n",
                    report[@"systemBuild"], report[@"fontFileCount"]];
            }
            return FMWriteString(stdout, text) ? 0 : 74;
        }

        NSDictionary<NSString *, id> *status = FMCreateEnvironmentStatus();
        NSError *contractError = nil;
        if (!FMValidateStatusDocument(status, &contractError)) {
            fprintf(stderr, "status contract failure: %s\n",
                    contractError.localizedDescription.UTF8String);
            return 70;
        }

        if (argc == 3) {
            NSError *jsonError = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:status
                                                           options:NSJSONWritingSortedKeys
                                                             error:&jsonError];
            if (json == nil) {
                fprintf(stderr, "status serialization failure: %s\n",
                        jsonError.localizedDescription.UTF8String);
                return 70;
            }
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return 0;
        }

        return FMWriteString(stdout, FMStatusHumanReadableText(status)) ? 0 : 74;
    }
}
