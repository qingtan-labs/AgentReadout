#import "QGInsights.h"

int main(void) {
    @autoreleasepool {
        __block NSUInteger failures = 0, count = 0;
        void (^check)(BOOL, NSString *) = ^(BOOL passed, NSString *name) {
            count++; if (!passed) failures++;
            printf("%s %s\n", passed ? "PASS" : "FAIL", name.UTF8String);
        };
        double now = 2000000000;
        NSDictionary *(^window)(double, double) = ^NSDictionary *(double remaining, double reset) {
            return @{@"remainingPercent": @(remaining), @"windowDurationMins": @300, @"resetsAt": @(reset), @"ignoredSecret": @"must-not-persist"};
        };
        NSArray *history = QGInsightAppend(nil, @"codex", @[window(90, now+5000)], now-600, now);
        check(history.count == 1 && [history[0] count] == 5, @"history allowlist strips unrelated data");
        history = QGInsightAppend(history, @"codex", @[window(80, now+5000)], now-300, now);
        check(history.count == 2, @"five-minute history buckets");
        history = QGInsightAppend(history, @"codex", @[window(79, now+5000)], now-290, now);
        check(history.count == 2 && [history.lastObject[@"remaining"] intValue] == 79, @"same bucket replaces latest sample");
        check(QGInsightAppend(history, @"codex", @[window(99, now+5000)], now-295, now).count == 2, @"older cache does not add a duplicate");
        check(QGInsightHistory(@[@{}, @"bad", @{ @"provider": @"claude", @"t": @"oops"}], now).count == 0, @"malformed history is ignored");
        check(QGInsightHistory(history, now+86401).count == 0, @"history expires after 24 hours");
        check(QGInsightAppend(history, @"codex", @[window(20, 0)], now+1, now).count == 2, @"future observations ignored");
        check(QGInsightSegments(history, @"codex", 300, now).count == 1, @"continuous observations form one line");
        history = QGInsightAppend(history, @"codex", @[window(100, now+9000)], now, now);
        check(QGInsightSegments(history, @"codex", 300, now).count == 2, @"reset breaks trend instead of connecting a false slope");
        NSArray *gap = QGInsightAppend(history, @"codex", @[window(60, now+9000)], now+1800, now+1800);
        check(QGInsightSegments(gap, @"codex", 300, now+1800).count == 3, @"offline gaps remain gaps");
        check(QGInsightSegments(history, @"claude", 300, now).count == 0, @"provider trends stay separate");
        NSMutableDictionary *ledger = [NSMutableDictionary dictionary];
        check(QGInsightAlerts(ledger, @"codex", @[window(20, now+5000)], now, now).count == 1, @"first low quota triggers");
        check(QGInsightAlerts(ledger, @"codex", @[window(19, now+5000)], now+60, now+60).count == 0, @"same threshold does not repeat");
        check(QGInsightAlerts(ledger, @"codex", @[window(9, now+5000)], now+120, now+120).count == 1, @"critical threshold triggers once");
        NSMutableDictionary *restored = [ledger mutableCopy];
        check(QGInsightAlerts(restored, @"codex", @[window(8, now+5000)], now+180, now+180).count == 0, @"restart ledger suppresses duplicate alerts");
        check(QGInsightAlerts(ledger, @"codex", @[window(0, now+5000)], now+240, now+240).count == 1, @"exhaustion threshold triggers");
        check(QGInsightAlerts(ledger, @"codex", @[window(10, now+10000)], now+6000, now+6000).count == 1, @"new reset window re-arms alerts");
        check(QGInsightAlerts(ledger, @"claude", @[window(0, 0)], now-301, now).count == 0, @"stale cache never alerts");
        check(QGInsightAlerts(ledger, @"claude", @[window(0, now-1)], now, now).count == 0, @"expired windows never alert");
        check(QGInsightAlerts(ledger, @"claude", @[window(10, 0)], now, now).count == 1, @"unknown reset can alert");
        QGInsightAlerts(ledger, @"claude", @[window(80, 0)], now+60, now+60);
        check(QGInsightAlerts(ledger, @"claude", @[window(10, 0)], now+120, now+120).count == 1, @"unknown reset re-arms after recovery");
        check(QGInsightAlerts(ledger, @"claude", @[window(0, 0)], now+121, now+120).count == 0, @"future cache never alerts");
        printf("%lu insight checks; %lu failures\n", count, failures);
        return failures ? 1 : 0;
    }
}
