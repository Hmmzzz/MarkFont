#import "FMProviderCompatibility.h"

#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSInteger const FMProviderCapabilityContractVersion = 1;
NSString *const FMProviderCompatibilityErrorDomain =
    @"com.hmmzzz.fontmanager.providercompatibility";

static const off_t FMProviderMaximumWrapperBytes = 1024 * 1024;

static BOOL FMProviderCompatibilityFail(NSError **error,
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
        *error = [NSError errorWithDomain:FMProviderCompatibilityErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL FMProviderScriptContainsToken(NSString *script,
                                          NSString *escapedToken) {
    NSString *pattern = [NSString stringWithFormat:
        @"(^|[^A-Za-z0-9_])%@([^A-Za-z0-9_]|$)", escapedToken];
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:0
                                                    error:NULL];
    return expression != nil &&
        [expression firstMatchInString:script
                               options:0
                                 range:NSMakeRange(0, script.length)] != nil;
}

NSDictionary<NSString *, id> *FMAnalyzeProviderWrapperData(NSData *data) {
    BOOL bounded = data.length > 0 &&
        data.length <= (NSUInteger)FMProviderMaximumWrapperBytes;
    const void *nul = bounded ? memchr(data.bytes, 0, data.length) : NULL;
    NSString *script = bounded && nul == NULL
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : nil;
    NSRange firstLineEnd = [script rangeOfCharacterFromSet:
        NSCharacterSet.newlineCharacterSet];
    NSString *firstLine = script != nil
        ? (firstLineEnd.location == NSNotFound
            ? script
            : [script substringToIndex:firstLineEnd.location])
        : nil;
    BOOL shellWrapper = [firstLine hasPrefix:@"#!"] &&
        [firstLine rangeOfString:@"sh" options:NSCaseInsensitiveSearch].location !=
            NSNotFound;
    BOOL supportsSkipCopy = shellWrapper &&
        FMProviderScriptContainsToken(script, @"--skip-copy");
    BOOL supportsUnmount = shellWrapper &&
        FMProviderScriptContainsToken(script, @"-u");
    return @{
        @"contractVersion" : @(FMProviderCapabilityContractVersion),
        @"boundedTextWrapper" : bounded && script != nil ? @YES : @NO,
        @"shellWrapper" : shellWrapper ? @YES : @NO,
        @"supportsSkipCopy" : supportsSkipCopy ? @YES : @NO,
        @"supportsUnmount" : supportsUnmount ? @YES : @NO,
    };
}

NSString *FMProviderRecognitionForVersion(NSString *version) {
    return [version isEqual:@"0.6.0"] ? @"known" : @"unknown";
}

static NSDictionary<NSString *, id> *FMProviderUnavailableReport(
    BOOL executablePresent,
    NSString *reason) {
    return @{
        @"contractVersion" : @(FMProviderCapabilityContractVersion),
        @"executablePresent" : executablePresent ? @YES : @NO,
        @"executableSecure" : @NO,
        @"boundedTextWrapper" : @NO,
        @"shellWrapper" : @NO,
        @"supportsSkipCopy" : @NO,
        @"supportsUnmount" : @NO,
        @"compatible" : @NO,
        @"compatibility" : @"incompatible",
        @"compatibilityReason" : reason,
    };
}

NSDictionary<NSString *, id> *
FMInspectProviderExecutableCompatibilityAtPath(NSString *path,
                                                NSError **error) {
    if (path.length == 0) {
        FMProviderCompatibilityFail(
            error, 1, @"Provider executable path is required.", EINVAL);
        return nil;
    }

    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        int savedError = errno;
        struct stat pathInfo = {0};
        BOOL present = lstat(path.fileSystemRepresentation, &pathInfo) == 0;
        return FMProviderUnavailableReport(
            present,
            savedError == ENOENT ? @"executableMissing" : @"safeOpenFailed");
    }

    struct stat info = {0};
    if (fstat(descriptor, &info) != 0) {
        close(descriptor);
        return FMProviderUnavailableReport(YES, @"metadataReadFailed");
    }
    BOOL regular = S_ISREG(info.st_mode);
    BOOL executable = (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
    BOOL secure = regular && executable && info.st_uid == 0 &&
        (info.st_mode & (S_IWGRP | S_IWOTH)) == 0;
    if (!regular || info.st_size <= 0 ||
        info.st_size > FMProviderMaximumWrapperBytes) {
        close(descriptor);
        NSMutableDictionary *report =
            [FMProviderUnavailableReport(YES, @"unsupportedExecutable") mutableCopy];
        report[@"executableSecure"] = secure ? @YES : @NO;
        return report;
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    uint8_t *cursor = data.mutableBytes;
    size_t remaining = (size_t)info.st_size;
    while (remaining > 0) {
        ssize_t count = read(descriptor, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            close(descriptor);
            return FMProviderUnavailableReport(YES, @"contentReadFailed");
        }
        cursor += count;
        remaining -= (size_t)count;
    }
    uint8_t extra = 0;
    ssize_t trailing = -1;
    do {
        trailing = read(descriptor, &extra, sizeof(extra));
    } while (trailing < 0 && errno == EINTR);
    int closeResult = close(descriptor);
    if (trailing != 0 || closeResult != 0) {
        return FMProviderUnavailableReport(
            YES, trailing > 0 ? @"contentChanged" : @"inspectionFailed");
    }

    NSMutableDictionary *report =
        [FMAnalyzeProviderWrapperData(data) mutableCopy];
    BOOL compatible = secure && [report[@"shellWrapper"] boolValue] &&
        [report[@"supportsSkipCopy"] boolValue] &&
        [report[@"supportsUnmount"] boolValue];
    report[@"executablePresent"] = @YES;
    report[@"executableSecure"] = secure ? @YES : @NO;
    report[@"compatible"] = compatible ? @YES : @NO;
    report[@"compatibility"] = compatible ? @"compatible" : @"incompatible";
    return report;
}

BOOL FMProviderEvidenceSatisfiesCompatibilityContract(
    NSDictionary<NSString *, id> *provider) {
    NSString *version = [provider[@"version"] isKindOfClass:NSString.class]
        ? provider[@"version"] : nil;
    return [provider[@"packageID"] isEqual:@"com.nan.bindfs"] &&
        [provider[@"packageInstalled"] boolValue] &&
        [provider[@"executablePresent"] boolValue] &&
        version.length > 0 &&
        [@[ @"known", @"unknown" ] containsObject:provider[@"recognition"]] &&
        [provider[@"contractVersion"] integerValue] ==
            FMProviderCapabilityContractVersion &&
        [provider[@"compatibility"] isEqual:@"compatible"] &&
        [provider[@"executableSecure"] boolValue] &&
        [provider[@"boundedTextWrapper"] boolValue] &&
        [provider[@"shellWrapper"] boolValue] &&
        ![provider[@"supportsCopy"] boolValue] &&
        [provider[@"supportsSkipCopy"] boolValue] &&
        [provider[@"supportsUnmount"] boolValue] &&
        [provider[@"compatible"] boolValue] &&
        [provider[@"rootConfigurationSupported"] boolValue] &&
        ![provider[@"preferencePresent"] boolValue];
}
