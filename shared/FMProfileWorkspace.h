#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Product UI contract. Implementations may use Simulator fixtures or real
// device evidence; nil Profile IDs always mean the current device's Stock font.
@protocol FMProfileWorkspace <NSObject>

@property(nonatomic, copy, readonly) NSArray<NSString *> *managedRelativePaths;
@property(nonatomic, readonly) BOOL allowsChanges;
@property(nonatomic, readonly) BOOL allowsRestart;

- (BOOL)prepareIfNeeded:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)currentState:(NSError **)error;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)availableProfiles;
- (nullable NSDictionary<NSString *, id> *)detailsForProfileID:(nullable NSString *)profileID
                                                         error:(NSError **)error;

- (BOOL)stageProfileID:(nullable NSString *)profileID error:(NSError **)error;
- (BOOL)requestRespring:(NSError **)error;
- (BOOL)resetWorkspace:(NSError **)error;
- (BOOL)deleteProfileID:(NSString *)profileID error:(NSError **)error;
- (BOOL)importReplacementAtPath:(NSString *)sourcePath
                      profileID:(NSString *)profileID
                           name:(NSString *)name
                     fontFileID:(NSString *)fontFileID
                   relativePath:(NSString *)relativePath
                          error:(NSError **)error;

@optional
// Lightweight environment summary for product UI. Implementations may read
// helper, state, and mount metadata, but must not walk or hash the font tree,
// invoke the mount backend, modify files, or request a restart.
- (nullable NSDictionary<NSString *, id> *)environmentStatus:(NSError **)error;

// Read-only package inspection. The UI passes an app-controlled temporary copy,
// never the original security-scoped document. Implementations must not persist
// a Profile, modify the mirror, invoke the mount backend, or request a restart.
- (nullable NSDictionary<NSString *, id> *)previewFontPackageAtPath:(NSString *)sourcePath
                                                               error:(NSError **)error;

// Saves only the unambiguous package matches as an inactive Profile in the
// app-owned library. It must not stage the Profile, modify the mirror, invoke
// the mount backend, change state.json, or request a restart.
- (nullable NSDictionary<NSString *, id> *)saveFontPackageAtPath:(NSString *)sourcePath
                                                      profileName:(NSString *)profileName
                                                            error:(NSError **)error;

// Materializes a mix-and-match Profile from already saved schemes (slot
// assignments plus one optional fallback scheme) into the same app-owned
// library. It carries the same restrictions as saveFontPackageAtPath.
- (nullable NSDictionary<NSString *, id> *)saveMixedProfileWithSlotAssignments:(NSDictionary<NSString *, NSString *> *)slotAssignments
                                                               fallbackProfileID:(nullable NSString *)fallbackProfileID
                                                                      profileName:(NSString *)profileName
                                                                            error:(NSError **)error;

// Changes only the persistent opt-in policy. Enabling it never requests a
// Respring immediately; it can be consumed only by a later launchd automount.
- (BOOL)setAutomaticRespringEnabled:(BOOL)enabled error:(NSError **)error;

@end


NS_ASSUME_NONNULL_END
