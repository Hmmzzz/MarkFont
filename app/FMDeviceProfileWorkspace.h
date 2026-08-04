#import <Foundation/Foundation.h>

#import "FMProfileWorkspace.h"

NS_ASSUME_NONNULL_BEGIN

// Real RootHide adapter. Font selections are staged through fixed helper
// operations; nil Profile IDs restore the verified build-bound Stock snapshot.
@interface FMDeviceProfileWorkspace : NSObject <FMProfileWorkspace>
@end

NS_ASSUME_NONNULL_END
