#import <Foundation/Foundation.h>

#import "../shared/FMHelperClient.h"
#import "../shared/FMStatusContract.h"

static void FMPrintUsage(FILE *stream) {
    fprintf(stream, "usage: fontmanagerctl status [--json]\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--version") == 0) {
            fprintf(stdout, "fontmanagerctl 0.1.1\n");
            return 0;
        }

        if (argc < 2 || strcmp(argv[1], "status") != 0 || argc > 3 ||
            (argc == 3 && strcmp(argv[2], "--json") != 0)) {
            FMPrintUsage(stderr);
            return 64;
        }

        NSError *error = nil;
        NSDictionary<NSString *, id> *status = FMFetchStatusFromHelper(&error);
        if (status == nil) {
            fprintf(stderr, "fontmanagerctl: %s\n", error.localizedDescription.UTF8String);
            return 69;
        }

        if (argc == 3) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:status
                                                           options:(NSJSONWritingPrettyPrinted |
                                                                    NSJSONWritingSortedKeys)
                                                             error:&error];
            if (json == nil) {
                fprintf(stderr, "fontmanagerctl: %s\n", error.localizedDescription.UTF8String);
                return 70;
            }
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return 0;
        }

        NSString *human = FMStatusHumanReadableText(status);
        NSData *data = [human dataUsingEncoding:NSUTF8StringEncoding];
        return fwrite(data.bytes, 1, data.length, stdout) == data.length ? 0 : 74;
    }
}
