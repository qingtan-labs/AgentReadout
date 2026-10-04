#import <Foundation/Foundation.h>

static NSString *QGLoginItemPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.qingtanlabs.gaugeforcodex.plist"];
}
static BOOL QGLoginItemEnabled(NSString *path) {
    NSDictionary *item = [NSDictionary dictionaryWithContentsOfFile:path];
    return [item[@"Label"] isEqual:@"com.qingtanlabs.gaugeforcodex"] && [item[@"RunAtLoad"] boolValue];
}
static BOOL QGWriteLoginItem(NSString *path, NSString *executable, BOOL enabled, NSError **error) {
    NSDictionary *item = @{@"Label": @"com.qingtanlabs.gaugeforcodex", @"ProgramArguments": @[executable],
        @"RunAtLoad": @(enabled), @"LimitLoadToSessionType": @"Aqua", @"ProcessType": @"Interactive",
        @"StandardOutPath": @"/tmp/com.qingtanlabs.gaugeforcodex.out.log",
        @"StandardErrorPath": @"/tmp/com.qingtanlabs.gaugeforcodex.err.log"};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:item format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data || ![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    // launchd reads this at the next login. Do not boot out the running menu app.
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}
