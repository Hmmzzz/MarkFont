#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontPackageImportSessionErrorDomain;

// Owns one stable, app-controlled copy of a user-selected font package. The
// copy lives only under Font Manager's namespaced temporary root and is never a
// Profile or a managed mirror input by itself.
@interface FMFontPackageImportSession : NSObject

@property(nonatomic, copy, readonly) NSURL *packageURL;
@property(nonatomic, copy, readonly) NSURL *sessionDirectoryURL;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Coordinates a read of the selected URL, copies one regular ZIP/font into a
// new 0700 session directory, and publishes it as a 0600 regular file.
+ (nullable instancetype)sessionByImportingURL:(NSURL *)sourceURL
                                         error:(NSError **)error;

// Removes sessions left by a previous process. Call only during app startup or
// before opening a new picker, when this process owns no active import session.
+ (BOOL)discardAbandonedSessions:(NSError **)error;

// Idempotently removes this session's exact directory. The selected source URL
// is never removed.
- (BOOL)discard:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
