#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceFontCatalogErrorDomain;

// Confirms the current iOS/build layout first, then builds the current-build
// catalog from the corresponding exact Stock source: primary PingFang.ttc on
// iOS 16-17 or FontServices PingFangUI.ttc on iOS 18-26. This is read-only and
// does not require the mapping to be active; App-facing callers must enforce
// their managed-workspace state first.
NSDictionary<NSString *, id> * _Nullable FMCreateDeviceFontCatalogForBuild(
    NSString *confirmedSystemBuild,
    NSError **error);

// Loads the supported SFNT filenames from the immutable baseline record. The
// normal app path checks state and mount metadata but never rescans the mirror.
// It never persists catalog.json or changes mirror/state/mapping.
NSDictionary<NSString *, id> * _Nullable FMCreateDeviceFontCatalogPreview(
    NSString *confirmedSystemBuild,
    NSError **error);

NS_ASSUME_NONNULL_END
