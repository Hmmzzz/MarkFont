#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMTreeManifestErrorDomain;

NSDictionary<NSString *, id> * _Nullable FMCreateTreeManifestAtPath(NSString *rootPath,
                                                                     NSError **error);

NS_ASSUME_NONNULL_END
