#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontPackageMatcherErrorDomain;

// Matches already enumerated package font files to the current Stock catalog
// by exact filename. PingFang.ttc (iOS 14-17) and PingFangUI.ttc (iOS 18-26) are
// different build-bound files: bytes from one name are never reused for the
// other target. A package member for the other system layout is reported only
// as an ignored source, without a target ID or target path. Package entries
// contain relativePath, sha256, and fileSize. Exact same-name/same-hash sources
// are deduplicated; different hashes are reported as conflicts and never
// selected.
NSDictionary<NSString *, id> * _Nullable FMMatchFontPackageFilesToCatalog(
    NSArray<NSDictionary<NSString *, id> *> *packageFiles,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

NS_ASSUME_NONNULL_END
