#import <UIKit/UIKit.h>

// Mix-and-match composer: assign one saved scheme to each main font slot and
// one fallback scheme for everything else, then save the merged result as a
// new library Profile.

@protocol FMProfileWorkspace;

NS_ASSUME_NONNULL_BEGIN

@interface FMMixFontViewController : UITableViewController

- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil
                         bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
