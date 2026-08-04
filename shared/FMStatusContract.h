#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const FMStatusAPIVersion;
FOUNDATION_EXPORT NSString *const FMStatusErrorDomain;

typedef NS_ENUM(NSInteger, FMStatusErrorCode) {
    FMStatusErrorInvalidDocument = 1,
    FMStatusErrorHelperUnavailable = 2,
    FMStatusErrorHelperFailed = 3,
    FMStatusErrorHelperOutputTooLarge = 4,
};

BOOL FMValidateStatusDocument(id document, NSError **error);
NSString *FMEngineStateForFacts(NSDictionary<NSString *, id> *provider,
                                NSDictionary<NSString *, id> *fonts,
                                NSDictionary<NSString *, id> *state);
NSString *FMStatusHumanReadableText(NSDictionary<NSString *, id> *document);

NS_ASSUME_NONNULL_END
