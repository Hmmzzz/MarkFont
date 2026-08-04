#import "FMAppDelegate.h"

#import "FMDesignSystem.h"
#import "FMDeviceProfileWorkspace.h"
#import "FMFontPackageImportSession.h"
#import "FMProfileLabViewController.h"

@implementation FMAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)application;
    (void)launchOptions;

    // No session can be active before the first UI is created. Remove only
    // Font Manager's exact temporary import directories left by an earlier
    // terminated process; Profiles and user-selected source files are outside
    // this root.
    [FMFontPackageImportSession discardAbandonedSessions:nil];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.tintColor = FMAccentColor();

    UINavigationBarAppearance *navigationAppearance = [[UINavigationBarAppearance alloc] init];
    [navigationAppearance configureWithTransparentBackground];
    navigationAppearance.backgroundColor = FMCanvasColor();
    navigationAppearance.shadowColor = UIColor.clearColor;
    navigationAppearance.largeTitleTextAttributes = @{
        NSForegroundColorAttributeName : UIColor.labelColor,
        NSFontAttributeName : [UIFont systemFontOfSize:34 weight:UIFontWeightBold],
    };
    navigationAppearance.titleTextAttributes = @{
        NSForegroundColorAttributeName : UIColor.labelColor,
        NSFontAttributeName : [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
    };
    UINavigationBar.appearance.standardAppearance = navigationAppearance;
    UINavigationBar.appearance.scrollEdgeAppearance = navigationAppearance;
    UINavigationBar.appearance.compactAppearance = navigationAppearance;

    FMDeviceProfileWorkspace *workspace = [[FMDeviceProfileWorkspace alloc] init];
    FMProfileLabViewController *profiles =
        [[FMProfileLabViewController alloc] initWithWorkspace:workspace];
    self.window.rootViewController =
        [[UINavigationController alloc] initWithRootViewController:profiles];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
