#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontPackageAnalyzerErrorDomain;

// Reads one copied .zip/.ttf/.ttc/.otf selected by the user, validates font
// payloads with CoreText, hashes them, and matches them against the current
// build-bound Stock catalog. ZIP entries are never extracted to disk.
NSDictionary<NSString *, id> * _Nullable FMAnalyzeFontPackageAtPath(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

// Reopens an already previewed package and writes only its selected matches
// into an existing empty destination directory. Each output is a new 0600
// regular file, and the returned entries use the Profile replacement schema.
// The caller owns the destination staging directory and removes it on failure.
NSArray<NSDictionary<NSString *, id> *> * _Nullable
FMMaterializeFontPackageMatchesAtPath(
    NSString *sourcePath,
    NSDictionary<NSString *, id> *preview,
    NSString *destinationDirectory,
    NSError **error);

NS_ASSUME_NONNULL_END
