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
    __weak typeof(self) weakSelf = self;
    [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                      withHandler:^(__unused id<UITraitEnvironment> environment,
                                    __unused UITraitCollection *previousTraitCollection) {
        [weakSelf updateGradientColors];
    }];
    return self;
}

- (void)updateGradientColors {
    UIColor *canvas = [FMCanvasColor() resolvedColorWithTraitCollection:self.traitCollection];
    ((CAGradientLayer *)self.layer).colors = @[
        (id)[canvas colorWithAlphaComponent:0.0].CGColor,
        (id)[canvas colorWithAlphaComponent:0.96].CGColor,
        (id)canvas.CGColor,
    ];
}

@end
