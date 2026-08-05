#import "FMFloatingActionDockView.h"

#import <QuartzCore/QuartzCore.h>

#import "FMDesignSystem.h"

@implementation FMFloatingActionDockView

+ (Class)layerClass {
    return CAGradientLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
    gradient.startPoint = CGPointMake(0.5, 0.0);
    gradient.endPoint = CGPointMake(0.5, 1.0);
    gradient.locations = @[ @0.0, @0.34, @0.68 ];
    [self updateGradientColors];
    if (@available(iOS 17.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                          withHandler:^(__unused id<UITraitEnvironment> environment,
                                        __unused UITraitCollection *previousTraitCollection) {
            [weakSelf updateGradientColors];
        }];
    }
    return self;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 17.0, *)) return;
    if (previousTraitCollection == nil ||
        previousTraitCollection.userInterfaceStyle !=
            self.traitCollection.userInterfaceStyle) {
        [self updateGradientColors];
    }
}
#pragma clang diagnostic pop

- (void)updateGradientColors {
    UIColor *canvas = [FMCanvasColor() resolvedColorWithTraitCollection:self.traitCollection];
    ((CAGradientLayer *)self.layer).colors = @[
        (id)[canvas colorWithAlphaComponent:0.0].CGColor,
        (id)[canvas colorWithAlphaComponent:0.96].CGColor,
        (id)canvas.CGColor,
    ];
}

@end
