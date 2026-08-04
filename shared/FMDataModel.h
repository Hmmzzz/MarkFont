#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const FMDataSchemaVersion;
FOUNDATION_EXPORT NSInteger const FMBaselineIdentitySchemaVersion;
FOUNDATION_EXPORT NSString *const FMDataErrorDomain;

typedef NS_ENUM(NSInteger, FMDataErrorCode) {
    FMDataErrorInvalidDocument = 1,
    FMDataErrorInvalidPath = 2,
    FMDataErrorInvalidHash = 3,
    FMDataErrorDuplicateEntry = 4,
};

BOOL FMValidateRelativePath(NSString *relativePath, NSError **error);
BOOL FMValidateBaselineIdentity(id document, NSError **error);
BOOL FMBaselineIdentityUsesLegacyProvider(id document);
NSDictionary<NSString *, id> *_Nullable
FMMigrateBaselineIdentityToBuiltInBackend(id document, NSError **error);
BOOL FMValidateProfileDocument(id document, NSError **error);
BOOL FMValidateStateDocument(id document, NSError **error);
BOOL FMValidateManifestDocument(id document, NSError **error);
BOOL FMValidateFontCatalogDocument(id document, NSError **error);
BOOL FMValidateFontCatalogPreviewDocument(id document,
                                          NSString *expectedSystemBuild,
                                          NSError **error);

NS_ASSUME_NONNULL_END
