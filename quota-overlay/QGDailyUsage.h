#import <Foundation/Foundation.h>
#import <math.h>

// Only source-provided daily aggregates. No conversation logs and no disk history.
static NSArray<NSDictionary *> *QGDailyBuckets(id rows, BOOL claude) {
    if (![rows isKindOfClass:NSArray.class]) return nil;
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    format.dateFormat = @"yyyy-MM-dd"; format.lenient = NO;
    NSMutableDictionary *days = [NSMutableDictionary dictionary];
    for (id item in rows) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *day = item[claude ? @"date" : @"startDate"];
        if (![day isKindOfClass:NSString.class] || day.length != 10) continue;
        NSDate *date = [format dateFromString:day];
        if (!date || ![[format stringFromDate:date] isEqual:day]) continue;
        NSArray *values;
        if (claude) {
            NSDictionary *models = item[@"tokensByModel"];
            if (![models isKindOfClass:NSDictionary.class] || !models.count) continue;
            values = models.allValues;
        } else values = @[item[@"tokens"] ?: NSNull.null];
        double total = 0; BOOL valid = YES;
        for (id value in values) {
            if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
                !isfinite([value doubleValue]) || [value doubleValue] < 0 || [value doubleValue] > 1e15) { valid = NO; break; }
            total += [value doubleValue];
        }
        if (valid && total <= 1e15) days[day] = @{@"date": day, @"t": @(date.timeIntervalSince1970),
            @"value": @(floor(total)), @"provider": claude ? @"claude" : @"codex"};
    }
    if ([rows count] && !days.count) return nil;
    return [days.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"date"] compare:b[@"date"]];
    }];
}

static NSDictionary *QGDailyProvider(NSArray *days, NSDate *updatedAt) {
    return @{@"available": @(days != nil), @"days": days ?: @[], @"latest": days.lastObject[@"date"] ?: @"",
        @"updatedAt": days ? @(updatedAt.timeIntervalSince1970) : @0, @"stale": @NO};
}

static NSDictionary *QGDailyReport(NSDictionary *codexResult, NSDictionary *claudeCache, NSDate *now) {
    NSArray *codex = QGDailyBuckets(codexResult[@"dailyUsageBuckets"], NO);
    NSArray *claude = QGDailyBuckets(claudeCache[@"dailyModelTokens"], YES);
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    NSDictionary *source = [codexResult[@"summary"] isKindOfClass:NSDictionary.class] ? codexResult[@"summary"] : @{};
    for (NSString *key in @[@"lifetimeTokens", @"peakDailyTokens", @"longestRunningTurnSec", @"currentStreakDays", @"longestStreakDays"]) {
        id value = source[key];
        if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
            isfinite([value doubleValue]) && [value doubleValue] >= 0 && [value doubleValue] <= 1e15) summary[key] = value;
    }
    return @{@"providers": @{@"codex": QGDailyProvider(codex, now), @"claude": QGDailyProvider(claude, now)},
        @"codexSummary": summary, @"scannedAt": codexResult ? @(now.timeIntervalSince1970) : @0, @"stale": @NO};
}

// Preserve only the last successful in-memory source aggregates when a refresh fails.
// Their original timestamp and stale flag must survive widget publication.
static NSDictionary *QGDailyMergeReport(NSDictionary *incoming, NSDictionary *previous,
                                         BOOL codexFailed, BOOL claudeFailed, BOOL claudeSkipped) {
    NSMutableDictionary *providers = [incoming[@"providers"] mutableCopy];
    NSMutableDictionary *result = [incoming mutableCopy];
    BOOL hasPreviousCodex = [previous[@"providers"][@"codex"][@"available"] boolValue] ||
        [previous[@"codexSummary"] count] > 0;
    if (codexFailed && hasPreviousCodex) {
        NSDictionary *old = previous[@"providers"][@"codex"];
        NSMutableDictionary *retained = [old mutableCopy];
        retained[@"stale"] = @YES;
        providers[@"codex"] = retained;
        result[@"codexSummary"] = previous[@"codexSummary"];
        result[@"scannedAt"] = previous[@"scannedAt"] ?: @0;
        result[@"stale"] = @YES;
    }
    if (codexFailed && !hasPreviousCodex) result[@"scannedAt"] = @0;
    if ((claudeFailed || claudeSkipped) && previous[@"providers"][@"claude"]) {
        NSMutableDictionary *retained = [previous[@"providers"][@"claude"] mutableCopy];
        if (claudeFailed) retained[@"stale"] = @YES;
        providers[@"claude"] = retained;
    }
    result[@"providers"] = providers;
    return result;
}

static NSDictionary *QGReadClaudeDailyCache(NSString *configDirectory) {
    NSString *path = [configDirectory stringByAppendingPathComponent:@"stats-cache.json"];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes fileSize] > 8 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length > 8 * 1024 * 1024) return nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![result isKindOfClass:NSDictionary.class]) return nil;
    // Allowlist the existing aggregate; never return unrelated contents of the file.
    return [result[@"dailyModelTokens"] isKindOfClass:NSArray.class] ? @{@"dailyModelTokens": result[@"dailyModelTokens"]} : nil;
}

static NSDictionary *QGDailySummary(NSDictionary *report, NSDate *start, NSDate *end) {
    NSMutableArray *buckets = [NSMutableArray array];
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    double total = 0;
    for (NSString *provider in @[@"codex", @"claude"]) {
        double tokens = 0; NSUInteger count = 0;
        for (NSDictionary *day in report[@"providers"][provider][@"days"]) {
            double t = [day[@"t"] doubleValue];
            if (t < start.timeIntervalSince1970 || t > end.timeIntervalSince1970) continue;
            [buckets addObject:day]; tokens += [day[@"value"] doubleValue]; count++;
        }
        summary[provider] = @(tokens); summary[[provider stringByAppendingString:@"Count"]] = @(count);
        total += tokens;
    }
    summary[@"total"] = @(total); summary[@"count"] = @(buckets.count); summary[@"buckets"] = buckets;
    return summary.copy;
}

// Give each calendar day its own chart slot. Source buckets remain sparse:
// an absent day has no bar, while an explicitly reported zero is still a day.
static NSArray<NSString *> *QGDailyDateKeys(NSDate *start, NSDate *now) {
    if (!start || !now) return @[];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *first = [calendar startOfDayForDate:start];
    NSDate *last = [calendar startOfDayForDate:now];
    if ([first compare:last] == NSOrderedDescending) return @[];
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    format.dateFormat = @"yyyy-MM-dd";
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSDate *day = first; day && [day compare:last] != NSOrderedDescending && keys.count < 366;) {
        [keys addObject:[format stringFromDate:day]];
        NSDate *next = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0];
        if (!next || [next compare:day] != NSOrderedDescending) break;
        day = next;
    }
    return keys.copy;
}

// A bounded, allowlisted snapshot for WidgetKit. It is derived from the
// current official response, never from a separate local usage log.
static NSDictionary *QGDailyWidgetPayload(NSDictionary *report, NSDate *now) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *today = [calendar startOfDayForDate:now];
    NSDate *start = [calendar dateByAddingUnit:NSCalendarUnitDay value:-6 toDate:today options:0];
    NSSet *visible = [NSSet setWithArray:QGDailyDateKeys(start, now)];
    NSDictionary *provider = report[@"providers"][@"codex"];
    NSMutableArray *days = [NSMutableArray array];
    for (NSDictionary *bucket in provider[@"days"]) {
        if (![visible containsObject:bucket[@"date"]]) continue;
        [days addObject:@{@"date": bucket[@"date"], @"value": bucket[@"value"]}];
    }
    NSMutableDictionary *metrics = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"lifetimeTokens", @"peakDailyTokens", @"longestRunningTurnSec",
                            @"currentStreakDays", @"longestStreakDays"]) {
        NSNumber *value = report[@"codexSummary"][key];
        if ([value isKindOfClass:NSNumber.class]) metrics[key] = value;
    }
    BOOL available = [provider[@"available"] boolValue] || metrics.count > 0;
    return @{@"days": days, @"summary": metrics, @"latest": provider[@"latest"] ?: @"",
             @"updatedAt": available ? report[@"scannedAt"] ?: @0 : @0,
             @"available": @(available), @"stale": @([report[@"stale"] boolValue])};
}
