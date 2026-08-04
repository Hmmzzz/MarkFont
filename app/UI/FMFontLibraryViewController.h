#import <UIKit/UIKit.h>

// Product font-library sheet.

@protocol FMProfileWorkspace;

NS_ASSUME_NONNULL_BEGIN

typedef void (^FMFontLibraryApplyHandler)(NSString *_Nullable profileID);

@interface FMFontLibraryViewController : UIViewController

- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace
                      applyHandler:(FMFontLibraryApplyHandler)applyHandler
                  dismissalHandler:(dispatch_block_t)dismissalHandler;

@end

NS_ASSUME_NONNULL_END
