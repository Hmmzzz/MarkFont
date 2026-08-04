#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontCatalogErrorDomain;

// Font Manager v0.1 imports only SFNT files represented by these extensions.
// The path must also be a normalized, safe relative path.
BOOL FMIsSupportedFontCatalogRelativePath(NSString *relativePath);

// Builds the current-device filename-to-path catalog from an already verified
// Stock manifest. It does not open, parse, create, or modify any font file.
NSDictionary<NSString *, id> * _Nullable FMCreateFontCatalogFromManifest(
    NSDictionary<NSString *, id> *manifest,
    NSString *systemBuild,
    NSString *sourceManifestSHA256,
    NSError **error);

NS_ASSUME_NONNULL_END
