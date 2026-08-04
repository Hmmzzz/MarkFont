#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FMCompatibilityLoadCompletion)(
    NSDictionary<NSString *, id> *_Nullable status,
    NSError *_Nullable error);
typedef void (^FMCompatibilityStatusLoader)(FMCompatibilityLoadCompletion completion);

// A lightweight product-facing environment summary. The supplied status must
// come from mount/state metadata only; this screen never scans the font tree.
@interface FMCompatibilityViewController : UITableViewController

- (instancetype)initWithEnvironmentStatus:
                    (nullable NSDictionary<NSString *, id> *)status
                                  statusLoader:
                    (nullable FMCompatibilityStatusLoader)statusLoader;

- (void)updateWithEnvironmentStatus:
            (nullable NSDictionary<NSString *, id> *)status
                               error:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
