#import <Foundation/Foundation.h>
#import <math.h>

// Deliberately accepts only normalized quota fields. No account or conversation data.
static inline BOOL QGInsightNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]);
}

static inline NSArray<NSDictionary *> *QGInsightHistory(id stored, NSTimeInterval now) {
    NSMutableArray *valid = [NSMutableArray array];
    if (![stored isKindOfClass:NSArray.class]) return valid;
    for (id row in stored) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        if (![@[@"codex", @"claude"] containsObject:row[@"provider"]]) continue;
        if (!QGInsightNumber(row[@"t"]) || !QGInsightNumber(row[@"remaining"]) ||
            !QGInsightNumber(row[@"duration"]) || !QGInsightNumber(row[@"reset"])) continue;
        double t = [row[@"t"] doubleValue], remaining = [row[@"remaining"] doubleValue];
        if (t < now - 86400 || t > now || remaining < 0 || remaining > 100 ||
            [row[@"duration"] doubleValue] <= 0 || [row[@"reset"] doubleValue] < 0) continue;
        [valid addObject:@{@"provider": row[@"provider"], @"t": row[@"t"], @"remaining": row[@"remaining"],
                          @"duration": row[@"duration"], @"reset": row[@"reset"]}];
    }
    [valid sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"t"] compare:b[@"t"]];
    }];
    // Four normal series, five-minute buckets, plus a small allowance for changes.
    if (valid.count > 1200) [valid removeObjectsInRange:NSMakeRange(0, valid.count - 1200)];
    return valid;
}

static inline NSArray<NSDictionary *> *QGInsightAppend(id history, NSString *provider,
        NSArray<NSDictionary *> *windows, NSTimeInterval observedAt, NSTimeInterval now) {
    NSMutableArray *result = [QGInsightHistory(history, now) mutableCopy];
    if (![@[@"codex", @"claude"] containsObject:provider] || observedAt > now || observedAt < now - 86400) return result;
    for (NSDictionary *window in windows) {
        if (!QGInsightNumber(window[@"remainingPercent"]) || !QGInsightNumber(window[@"windowDurationMins"])) continue;
        double remaining = [window[@"remainingPercent"] doubleValue];
        double duration = [window[@"windowDurationMins"] doubleValue];
        if (duration <= 0 || remaining < 0 || remaining > 100) continue;
        double reset = QGInsightNumber(window[@"resetsAt"]) ? MAX(0, [window[@"resetsAt"] doubleValue]) : 0;
        if (reset > 0 && reset <= observedAt) continue;
        NSUInteger existing = [result indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger idx, BOOL *stop) {
            (void)idx; (void)stop;
            return [row[@"provider"] isEqual:provider] && [row[@"duration"] doubleValue] == duration &&
                floor([row[@"t"] doubleValue] / 300) == floor(observedAt / 300);
        }];
        if (existing != NSNotFound && [result[existing][@"t"] doubleValue] > observedAt) continue;
        NSDictionary *row = @{@"provider": provider, @"t": @(observedAt), @"remaining": @(remaining),
                              @"duration": @(duration), @"reset": @(reset)};
        if (existing != NSNotFound) result[existing] = row;
        else [result addObject:row];
    }
    return QGInsightHistory(result, now);
}

static inline NSArray<NSArray<NSDictionary *> *> *QGInsightSegments(NSArray *history,
        NSString *provider, double duration, NSTimeInterval now) {
    NSMutableArray *segments = [NSMutableArray array];
    NSMutableArray *current = nil;
    NSDictionary *previous = nil;
    for (NSDictionary *point in QGInsightHistory(history, now)) {
        if (![point[@"provider"] isEqual:provider] || [point[@"duration"] doubleValue] != duration) continue;
        BOOL discontinuity = !previous || [point[@"t"] doubleValue] - [previous[@"t"] doubleValue] > 900 ||
            [point[@"remaining"] doubleValue] > [previous[@"remaining"] doubleValue] + 1 ||
            fabs([point[@"reset"] doubleValue] - [previous[@"reset"] doubleValue]) > 120;
        if (discontinuity) { current = [NSMutableArray array]; [segments addObject:current]; }
        [current addObject:point];
        previous = point;
    }
    return segments;
}

// 20%, 10%, exhausted. A first low sample is useful; repeats within the same
// known window are suppressed, including across app restarts. Unknown-reset
// windows re-arm only after an observed recovery above 20%.
static inline NSArray<NSDictionary *> *QGInsightAlerts(NSMutableDictionary *ledger, NSString *provider,
        NSArray<NSDictionary *> *windows, NSTimeInterval observedAt, NSTimeInterval now) {
    NSMutableArray *events = [NSMutableArray array];
    if (observedAt > now || now - observedAt > 300 || ![@[@"codex", @"claude"] containsObject:provider]) return events;
    for (id key in ledger.allKeys.copy) {
        id value = ledger[key];
        if (![value isKindOfClass:NSDictionary.class] || !QGInsightNumber(value[@"t"]) ||
            [value[@"t"] doubleValue] < now - 8 * 86400) [ledger removeObjectForKey:key];
    }
    for (NSDictionary *window in windows) {
        if (!QGInsightNumber(window[@"remainingPercent"]) || !QGInsightNumber(window[@"windowDurationMins"])) continue;
        double remaining = [window[@"remainingPercent"] doubleValue], duration = [window[@"windowDurationMins"] doubleValue];
        double reset = QGInsightNumber(window[@"resetsAt"]) ? MAX(0, [window[@"resetsAt"] doubleValue]) : 0;
        if (remaining < 0 || remaining > 100 || duration <= 0 || (reset > 0 && reset <= now)) continue;
        NSString *key = [NSString stringWithFormat:@"%@-%.0f", provider, duration];
        NSDictionary *last = [ledger[key] isKindOfClass:NSDictionary.class] ? ledger[key] : nil;
        if (last && observedAt <= [last[@"t"] doubleValue]) continue;
        NSInteger severity = remaining <= 0 ? 3 : (remaining <= 10 ? 2 : (remaining <= 20 ? 1 : 0));
        NSInteger previousSeverity = [last[@"severity"] integerValue];
        double lastReset = [last[@"reset"] doubleValue];
        BOOL newWindow = lastReset > 0 && now >= lastReset && reset > lastReset + 60;
        BOOL recoveredUnknown = (lastReset <= 0 || reset <= 0) && remaining > 20;
        if (newWindow || recoveredUnknown) previousSeverity = 0;
        if (severity > previousSeverity) [events addObject:window];
        ledger[key] = @{@"reset": @(reset), @"t": @(observedAt), @"severity": @(MAX(severity, previousSeverity))};
    }
    return events;
}
