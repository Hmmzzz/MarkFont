#import "FMAppDelegate.h"

#import "FMDesignSystem.h"
#import "FMDeviceProfileWorkspace.h"
#import "FMFontPackageImportSession.h"
#import "FMProfileLabViewController.h"
#import "FMLocalization.h"

@interface FMAppDelegate ()
- (UIViewController *)makeRootViewController;
- (void)installRootViewControllerAnimated:(BOOL)animated;
- (void)languagePreferenceDidChange:(NSNotification *)notification;
@end

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

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(languagePreferenceDidChange:)
               name:FMLanguagePreferenceDidChangeNotification()
             object:nil];
    [self installRootViewControllerAnimated:NO];
    [self.window makeKeyAndVisible];
    return YES;
}

- (UIViewController *)makeRootViewController {
    FMDeviceProfileWorkspace *workspace = [[FMDeviceProfileWorkspace alloc] init];
    FMProfileLabViewController *profiles =
        [[FMProfileLabViewController alloc] initWithWorkspace:workspace];
    return [[UINavigationController alloc] initWithRootViewController:profiles];
}

- (void)installRootViewControllerAnimated:(BOOL)animated {
    UIViewController *rootViewController = [self makeRootViewController];
    if (!animated || self.window.rootViewController == nil ||
        UIAccessibilityIsReduceMotionEnabled()) {
        self.window.rootViewController = rootViewController;
        return;
    }
    [UIView transitionWithView:self.window
                      duration:0.22
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionAllowAnimatedContent
                    animations:^{
        self.window.rootViewController = rootViewController;
    }
                    completion:nil];
}

- (void)languagePreferenceDidChange:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self installRootViewControllerAnimated:YES];
    });
}

@end
