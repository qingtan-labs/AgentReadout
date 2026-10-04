#define main GaugeUpdaterMain
#import "updater.m"
#undef main

@interface TestUpdateOperations : QGUpdateOperations
@property NSString *failure;
@property NSMutableArray<NSString *> *launches;
@end
@implementation TestUpdateOperations
- (void)stopWidget:(NSString *)appPath { (void)appPath; }
- (BOOL)copy:(NSString *)source to:(NSString *)destination {
    if ([_failure isEqual:@"copy"]) return NO;
    return [NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:nil];
}
- (BOOL)validate:(NSString *)path version:(NSString *)version build:(NSString *)build {
    (void)path;
    return ![_failure isEqual:@"validation"] && [version isEqual:@"1.0.1"] && [build isEqual:@"11"];
}
- (BOOL)move:(NSString *)source to:(NSString *)destination {
    if ([_failure isEqual:@"old-move"] && [destination.lastPathComponent isEqual:@"Previous.app"]) return NO;
    if (([_failure isEqual:@"swap"] || [_failure isEqual:@"restore"]) && [source.lastPathComponent isEqual:@"New.app"]) return NO;
    if ([_failure isEqual:@"restore"] && [source.lastPathComponent isEqual:@"Previous.app"]) return NO;
    return [super move:source to:destination];
}
- (BOOL)launch:(NSString *)path {
    NSString *value = [NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@"marker"] encoding:NSUTF8StringEncoding error:nil];
    [_launches addObject:value ?: @"missing"];
    return value && !([_failure isEqual:@"launch"] && [value isEqual:@"new"]);
}
- (void)retireBackup:(NSString *)directory {
    // Fixtures only: no application launch or Trash operations in tests.
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}
@end

int main(void) {
    @autoreleasepool {
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"GaugeUpdaterTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSUInteger failures = 0;
        NSArray *cases = @[@"success", @"copy", @"validation", @"old-move", @"swap", @"launch", @"restore", @"build-mismatch"];
        for (NSString *scenario in cases) {
            NSString *folder = [root stringByAppendingPathComponent:scenario];
            NSString *target = [folder stringByAppendingPathComponent:@"Gauge.app"];
            NSString *replacement = [folder stringByAppendingPathComponent:@"Download.app"];
            [files createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil];
            [files createDirectoryAtPath:replacement withIntermediateDirectories:YES attributes:nil error:nil];
            [@"old" writeToFile:[target stringByAppendingPathComponent:@"marker"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [@"new" writeToFile:[replacement stringByAppendingPathComponent:@"marker"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            TestUpdateOperations *ops = [TestUpdateOperations new];
            ops.failure = scenario;
            ops.launches = [NSMutableArray array];
            int status = QGInstallReplacement(target, replacement, @"1.0.1", [scenario isEqual:@"build-mismatch"] ? @"12" : @"11", ops);
            NSString *value = [NSString stringWithContentsOfFile:[target stringByAppendingPathComponent:@"marker"] encoding:NSUTF8StringEncoding error:nil];
            BOOL passed;
            if ([scenario isEqual:@"success"]) passed = status == 0 && [value isEqual:@"new"] && [ops.launches isEqual:@[@"new"]];
            else if ([scenario isEqual:@"restore"]) passed = status == 71 && [ops.launches.lastObject isEqual:@"old"];
            else passed = status != 0 && [value isEqual:@"old"] && [ops.launches.lastObject isEqual:@"old"];
            fprintf(stdout, "%s updater %s\n", passed ? "PASS" : "FAIL", scenario.UTF8String);
            if (!passed) failures++;
        }
        [files removeItemAtPath:root error:nil];
        fprintf(stdout, "%lu rollback tests, %lu failures (isolated fixtures only)\n", (unsigned long)cases.count, (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
