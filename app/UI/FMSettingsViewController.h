#import <UIKit/UIKit.h>

// Product settings sheet.

@protocol FMProfileWorkspace;

NS_ASSUME_NONNULL_BEGIN

@interface FMSettingsViewController : UITableViewController
- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace
                  dismissalHandler:(dispatch_block_t)dismissalHandler;
@end

NS_ASSUME_NONNULL_END
