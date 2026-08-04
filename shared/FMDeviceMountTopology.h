#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceMountTopologyErrorDomain;

// Takes one read-only snapshot of the device mount table and classifies only
// rows whose source or target overlaps the exact system-font mapping. Unrelated
// bindfs mappings are returned neither as conflicts nor as owned data.
NSDictionary<NSString *, id> *_Nullable FMCreateSystemFontsMountTopology(
    NSString *expectedMirrorPath,
    NSError **error);

NS_ASSUME_NONNULL_END
