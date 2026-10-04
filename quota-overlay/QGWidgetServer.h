#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Serves normalized quota and daily Token aggregate snapshots to WidgetKit.
// No account identities, messages, or conversation logs are shared.
@interface QGWidgetServer : NSObject
- (BOOL)start;
- (void)stop;
- (void)updateWithCodexWindows:(NSArray<NSDictionary *> *)codexWindows
                codexUpdatedAt:(NSTimeInterval)codexUpdatedAt
                   codexFailed:(BOOL)codexFailed
                 codexPlanName:(nullable NSString *)codexPlanName
                  claudeWindows:(NSArray<NSDictionary *> *)claudeWindows
               claudeUpdatedAt:(NSTimeInterval)claudeUpdatedAt
                  claudeFailed:(BOOL)claudeFailed
                claudePlanName:(nullable NSString *)claudePlanName
              selectedProvider:(NSString *)selectedProvider
                   displayMode:(NSString *)displayMode
                   quotaStyle:(NSString *)quotaStyle
                   appearanceMode:(NSString *)appearanceMode
                       language:(NSString *)language
                   dailyUsage:(NSDictionary *)dailyUsage
                 claudeEnabled:(BOOL)claudeEnabled
           legacyClaudeSupport:(BOOL)legacyClaudeSupport;
@end

BOOL QGRunWidgetSnapshotSelfTests(void);

NS_ASSUME_NONNULL_END
