#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontPackageMatcherErrorDomain;

// Matches already enumerated package font files to the current Stock catalog
// by exact filename. PingFang.ttc (iOS 14-17) and PingFangUI.ttc (iOS 18-26) are
// different build-bound targets, not interchangeable file contents. When a
// package carries the name for the other system layout, it is reported as an
// ignored compatibility alternate instead of being written to the current
// target. Package entries contain relativePath, sha256, and fileSize. Exact
// same-name/same-hash sources are deduplicated; different hashes are reported
// as conflicts and never selected.
NSDictionary<NSString *, id> * _Nullable FMMatchFontPackageFilesToCatalog(
    NSArray<NSDictionary<NSString *, id> *> *packageFiles,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

NS_ASSUME_NONNULL_END
