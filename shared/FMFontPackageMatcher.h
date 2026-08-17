#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontPackageMatcherErrorDomain;

// Matches already enumerated package font files to the current Stock catalog
// by exact filename. PingFang.ttc/PingFangUI.ttc and ADTTime.ttc/ADTNumeric.ttc
// are different files: bytes from one name are never reused for the other
// target. ADTTime and ADTNumeric legitimately coexist on iOS 17+, so both may
// match their own catalog targets even though only ADTNumeric owns the
// lock-screen mix slot there. A package member absent because it belongs to
// another system layout is reported only as an ignored source, without target
// metadata. Exact same-name/same-hash sources are deduplicated; different
// hashes are reported as conflicts and never selected.
NSDictionary<NSString *, id> * _Nullable FMMatchFontPackageFilesToCatalog(
    NSArray<NSDictionary<NSString *, id> *> *packageFiles,
    NSDictionary<NSString *, id> *catalog,
    NSError **error);

NS_ASSUME_NONNULL_END
