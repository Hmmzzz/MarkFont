#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontPackageMatcherErrorDomain;

// Matches already enumerated package font files to the current Stock catalog
// by exact filename. Package entries contain relativePath, sha256, and
// fileSize. Same-name/same-hash package copies are deduplicated; same-name
// copies with different hashes are reported as conflicts and never selected.
NSDictionary<NSString *, id> * _Nullable FMMatchFontPackageFilesToCatalog(
    NSArray<NSDictionary<NSString *, id> *> *packageFiles,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

NS_ASSUME_NONNULL_END
