#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FMDeviceLegacyFontTakeoverErrorDomain;
FOUNDATION_EXPORT NSString *const FMLegacyFontTakeoverJournalLogicalPath;

// Read-only classification for a no-state first install. Only the exact
// default read-only Fonts mapping (or its inactive physical source) is
// eligible. Unrelated /bindfs content is neither inspected nor modified.
NSDictionary<NSString *, id> *_Nullable
FMCreateLegacyFontTakeoverPreflight(NSError **error);

// Detaches the exact old mapping, compares its physical source directly with
// the newly exposed Stock tree, publishes changed TTF/TTC/OTF files as the
// standard App-owned "安装前字体" Profile, then removes the old source tree.
// No permanent .bak directory is created.
NSDictionary<NSString *, id> *_Nullable
FMPerformLegacyFontTakeover(NSString *systemBuild, NSError **error);

// Removes the short-lived takeover journal after package initialization has
// either activated the imported Profile or left it available in "我的字体".
BOOL FMCompleteLegacyFontTakeover(NSString *systemBuild, NSError **error);

NS_ASSUME_NONNULL_END
