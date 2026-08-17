#import <UIKit/UIKit.h>

// Mix-and-match composer: assign one saved scheme to each main font slot and
// one fallback scheme for everything else, then save the merged result as a
// new library Profile.

@protocol FMProfileWorkspace;

NS_ASSUME_NONNULL_BEGIN

@interface FMMixFontViewController : UITableViewController

// mixRecipe/replacingProfileID pre-fill an edit round of an existing mix
// Profile; after a successful save the replaced Profile is deleted when it is
// no longer active.
- (instancetype)initWithWorkspace:(id<FMProfileWorkspace>)workspace
                        mixRecipe:(nullable NSDictionary<NSString *, id> *)mixRecipe
               replacingProfileID:(nullable NSString *)replacingProfileID NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil
                         bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
