#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Serves only the normalized quota snapshot to the local WidgetKit extension.
// Authentication tokens and account details never enter this response.
@interface QGWidgetServer : NSObject
- (BOOL)start;
- (void)stop;
- (void)updateWithWindows:(NSArray<NSDictionary *> *)windows updatedAt:(NSTimeInterval)timestamp;
@end

NS_ASSUME_NONNULL_END
