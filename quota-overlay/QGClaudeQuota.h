#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns normalized quota windows, never credentials or raw account data.
NSDictionary * _Nullable QGClaudeQuotaFromResponse(NSDictionary *response);
NSDictionary * _Nullable QGClaudeQuotaFromDesktopHistory(NSDictionary *history);
NSDictionary * _Nullable QGReadClaudeQuota(NSString * _Nullable * _Nullable errorKey);
BOOL QGRunClaudeQuotaSelfTests(void);

NS_ASSUME_NONNULL_END
