#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceFontCatalogErrorDomain;

// Loads the supported SFNT filenames from the immutable baseline record. The
// normal app path checks state and mount metadata but never rescans the mirror.
// It never persists catalog.json or changes mirror/state/mapping.
NSDictionary<NSString *, id> * _Nullable FMCreateDeviceFontCatalogPreview(
    NSString *confirmedSystemBuild,
    NSError **error);

NS_ASSUME_NONNULL_END
