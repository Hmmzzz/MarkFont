#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMFontCatalogErrorDomain;
FOUNDATION_EXPORT NSString *const FMFontCatalogFontServicesCorePrivatePrefix;

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

// Adds the optional iOS 18-26 FontServices/CorePrivate tree to the same logical
// catalog without pretending that it lives below /System/Library/Fonts. Its
// entries use the fixed FontServicesCorePrivate/ virtual prefix so Profile
// data stays path-safe while device code can route writes to the second fixed
// mirror. The primary-only wrapper above remains the iOS 16-17 path.
NSDictionary<NSString *, id> * _Nullable FMCreateFontCatalogFromManifests(
    NSDictionary<NSString *, id> *primaryManifest,
    NSDictionary<NSString *, id> * _Nullable fontServicesManifest,
    NSString *systemBuild,
    NSString *primaryManifestSHA256,
    NSString * _Nullable fontServicesManifestSHA256,
    NSError **error);

// Selects the build-specific Stock files used by the System Default preview.
// Device code must first create this catalog through the confirmed system-layout
// policy: iOS 18-26 expose PingFangUI.ttc through the FontServices namespace,
// while iOS 14-17 expose PingFang.ttc below the primary Fonts tree. A catalog
// containing both distinct Chinese targets is ambiguous and selects neither.
NSArray<NSString *> *FMFontCatalogPreviewRelativePaths(
    NSDictionary<NSString *, id> *catalog);

NS_ASSUME_NONNULL_END
