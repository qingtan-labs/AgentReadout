#import "QGDailyUsage.h"
#import "QGLoginItem.h"

int main(void) {
    @autoreleasepool {
        __block NSUInteger count = 0, failures = 0;
        void (^check)(BOOL, NSString *) = ^(BOOL passed, NSString *name) {
            count++; if (!passed) failures++;
            printf("%s %s\n", passed ? "PASS" : "FAIL", name.UTF8String);
        };
        NSArray *rows = @[@{@"startDate": @"2026-10-02", @"tokens": @150},
            @{@"startDate": @"2026-10-03", @"tokens": @0}];
        NSDictionary *official = @{@"dailyUsageBuckets": rows, @"summary": @{
            @"lifetimeTokens": @5390000000, @"peakDailyTokens": @390000000, @"longestRunningTurnSec": @55260,
            @"currentStreakDays": @4, @"longestStreakDays": @16, @"private": @"excluded"}, @"threadUsage": @[@"excluded"]};
        NSDictionary *cache = @{@"dailyModelTokens": @[@{@"date": @"2026-10-02", @"tokensByModel": @{@"model-a": @30, @"model-b": @20}}]};
        NSDictionary *report = QGDailyReport(official, cache, NSDate.date);
        check([report[@"codexSummary"] count] == 5 && !report[@"threadUsage"], @"only five official summary metrics retained");
        check([report[@"codexSummary"][@"longestRunningTurnSec"] integerValue] == 55260, @"longest turn kept as reported, not total chat time");
        check([report[@"providers"][@"codex"][@"days"] count] == 2, @"official daily buckets retained including explicit zero");
        check([report[@"providers"][@"claude"][@"days"][0][@"value"] integerValue] == 50, @"existing Claude per-model daily totals summed once");
        check([report[@"providers"][@"codex"][@"latest"] isEqual:@"2026-10-03"], @"latest source date exposed independently from fetch time");
        NSDictionary *missing = QGDailyReport(nil, nil, NSDate.date);
        check(![missing[@"providers"][@"claude"][@"available"] boolValue] && [missing[@"codexSummary"] count] == 0,
            @"unavailable data does not turn into zero metrics");
        NSDictionary *retained = QGDailyMergeReport(missing, report, YES, YES, NO);
        check([retained[@"providers"][@"codex"][@"days"] count] == 2 &&
              [retained[@"providers"][@"claude"][@"days"] count] == 1 &&
              [retained[@"codexSummary"] isEqual:report[@"codexSummary"]] &&
              [retained[@"scannedAt"] isEqual:report[@"scannedAt"]] && [retained[@"stale"] boolValue],
              @"failed refresh keeps previous official aggregates with original timestamp");
        check([QGDailyWidgetPayload(retained, NSDate.date)[@"stale"] boolValue],
              @"widget marks retained daily data stale");
        NSDictionary *neverAvailable = QGDailyMergeReport(missing, missing, YES, YES, NO);
        check(![neverAvailable[@"stale"] boolValue] && [neverAvailable[@"scannedAt"] doubleValue] == 0,
              @"repeated failures without prior source data do not claim stale data exists");
        NSDictionary *recovered = QGDailyMergeReport(QGDailyReport(official, cache, NSDate.date), retained, NO, NO, NO);
        check(![recovered[@"stale"] boolValue] && ![recovered[@"providers"][@"codex"][@"stale"] boolValue],
              @"successful refresh clears explicit stale state");
        check(QGDailyBuckets(NSNull.null, NO) == nil && QGDailyBuckets(@"malformed", YES) == nil, @"invalid bucket containers rejected");
        check(QGDailyBuckets(@[@{@"startDate": @"2026-02-31", @"tokens": @12}], NO) == nil, @"invalid calendar days rejected");
        check(QGDailyBuckets(@[@{@"startDate": @"2026-10-02", @"tokens": @YES}], NO) == nil, @"boolean is not a token count");
        check(QGDailyBuckets(@[@{@"startDate": @"2026-10-02", @"tokens": @(-1)}], NO) == nil, @"negative tokens rejected");
        check(QGDailyBuckets(@[@{@"date": @"2026-10-02", @"tokensByModel": @{@"a": @10, @"b": @"bad"}}], YES) == nil,
            @"malformed model count does not silently undercount a Claude day");
        check(QGDailyBuckets([rows arrayByAddingObject:rows[0]], NO).count == 2, @"duplicate daily rows do not double count");
        NSArray *days = report[@"providers"][@"codex"][@"days"];
        NSDate *start = [NSDate dateWithTimeIntervalSince1970:[days[0][@"t"] doubleValue]];
        NSDate *end = [NSDate dateWithTimeIntervalSince1970:[days[1][@"t"] doubleValue]+100];
        NSDictionary *summary = QGDailySummary(report, start, end);
        check([summary[@"codex"] integerValue] == 150 && [summary[@"claude"] integerValue] == 50, @"provider day totals remain separate");
        check([summary[@"codexCount"] integerValue] == 2 && [summary[@"count"] integerValue] == 3, @"missing days are not invented");
        NSDate *octoberFirst = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:start options:0];
        check([QGDailyDateKeys(octoberFirst, end) isEqual:@[@"2026-10-01", @"2026-10-02", @"2026-10-03"]],
            @"three-day chart has one ordered slot and label per calendar date");
        check([QGDailyDateKeys(start, end) count] == 2 && QGDailyDateKeys(end, start).count == 0,
            @"day slots include endpoints and reject inverted ranges");
        check([QGDailySummary(report, end, [end dateByAddingTimeInterval:86400])[@"count"] integerValue] == 0,
            @"unreported date range shows no records, not fabricated zero");
        NSDictionary *widget = QGDailyWidgetPayload(report, end);
        check([widget[@"days"] count] == 2 && [widget[@"summary"] count] == 5 &&
              !widget[@"providers"] && !widget[@"threadUsage"],
            @"widget receives only recent Codex daily aggregates and five official metrics");
        NSDictionary *oldAndRecent = QGDailyReport(@{@"dailyUsageBuckets": @[
            @{@"startDate": @"2026-09-20", @"tokens": @999},
            @{@"startDate": @"2026-10-03", @"tokens": @12}]}, nil, end);
        check([QGDailyWidgetPayload(oldAndRecent, end)[@"days"] count] == 1,
            @"widget transport excludes daily records outside the last seven days");
        check(![QGDailyWidgetPayload(missing, end)[@"available"] boolValue],
            @"widget does not turn missing official data into a fake zero");
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        check(QGReadClaudeDailyCache(directory) == nil, @"missing Claude cache needs no log scan");
        [[NSJSONSerialization dataWithJSONObject:cache options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"stats-cache.json"] atomically:YES];
        check([QGReadClaudeDailyCache(directory)[@"dailyModelTokens"] count] == 1, @"existing numeric cache readable without sessions");
        NSString *loginPath = [directory stringByAppendingPathComponent:@"LaunchAgents/test.plist"];
        check(!QGLoginItemEnabled(loginPath), @"new install defaults to no login startup");
        check(QGWriteLoginItem(loginPath, @"/Applications/Gauge for Codex.app/Contents/MacOS/GaugeForCodex", YES, nil) && QGLoginItemEnabled(loginPath),
            @"enable login writes valid RunAtLoad configuration");
        check(QGWriteLoginItem(loginPath, @"/Applications/Gauge for Codex.app/Contents/MacOS/GaugeForCodex", NO, nil) && !QGLoginItemEnabled(loginPath),
            @"disable login persists false without stopping this process");
        check([[[NSDictionary dictionaryWithContentsOfFile:loginPath] objectForKey:@"ProgramArguments"] count] == 1,
            @"login path with spaces is a single argument, not shell interpolation");
        check(QGLoginItemPath().length > 0, @"login path resolves to per-user scope");
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        printf("Daily usage and login: %lu checks, %lu failures\n", count, failures);
        return failures ? 1 : 0;
    }
}
