#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FMSystemFontLayout) {
    FMSystemFontLayoutUnsupported = 0,
    FMSystemFontLayoutPrimaryFonts = 1,
    FMSystemFontLayoutFontServicesCorePrivate = 2,
};

FOUNDATION_EXPORT NSString *const FMSystemFontLayoutErrorDomain;

// Converts an exact numeric iOS product version into MarkFont's supported
// system-font layout. iOS 16-17 retain the primary Fonts-only layout; iOS
// 18-26 use the additional FontServices/CorePrivate layout. Every other or
// malformed version fails closed as unsupported.
FMSystemFontLayout FMSystemFontLayoutForProductVersion(
    NSString *productVersion);

// Reads the immutable system identity and applies the same version policy.
// When confirmedSystemBuild is non-nil it must exactly match the current
// ProductBuildVersion before a layout is returned.
FMSystemFontLayout FMCurrentSystemFontLayout(
    NSString * _Nullable confirmedSystemBuild,
    NSError **error);

NS_ASSUME_NONNULL_END
