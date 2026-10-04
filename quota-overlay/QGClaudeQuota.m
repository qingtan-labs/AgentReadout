#import "QGClaudeQuota.h"
#import "QGPlan.h"
#import <Security/Security.h>
#import <math.h>

static NSString * const QGClaudeKeychainService = @"Claude Code-credentials";
static NSString * const QGClaudeUsageURL = @"https://api.anthropic.com/api/oauth/usage";
static NSTimeInterval const QGClaudeDesktopFreshness = 15.0 * 60.0;
static NSTimeInterval const QGClaudeDesktopMaximumAge = 24.0 * 60.0 * 60.0;

static NSString *QGClaudeErrorKeyForHTTPStatus(NSInteger status) {
    if (status == 401 || status == 403) return @"error.claudeUnauthorized";
    if (status == 429) return @"error.claudeRateLimited";
    if (status >= 500) return @"error.claudeServer";
    return @"error.claudeUnavailable";
}

static NSDictionary *QGClaudeFallback(NSDictionary *desktop, NSString *errorKey) {
    if (!desktop) return nil;
    NSMutableDictionary *result = [desktop mutableCopy];
    result[@"fallbackErrorKey"] = errorKey;
    return result;
}

static NSDictionary *QGClaudeJSONDictionary(NSData *data) {
    if (!data.length || data.length > 1024 * 1024) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSDictionary *QGClaudeOAuthCredentials(void) {
    NSDictionary *credentials = nil;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: QGClaudeKeychainService,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef item = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
    if (status == errSecSuccess && item) credentials = QGClaudeJSONDictionary(CFBridgingRelease(item));
    if (!credentials) {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".claude/.credentials.json"];
        NSData *fileData = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        credentials = QGClaudeJSONDictionary(fileData);
    }
    NSDictionary *oauth = [credentials[@"claudeAiOauth"] isKindOfClass:NSDictionary.class]
        ? credentials[@"claudeAiOauth"] : nil;
    return oauth;
}

static NSTimeInterval QGClaudeResetTime(id value) {
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        double timestamp = [value doubleValue];
        return isfinite(timestamp) && timestamp > 0 ? (timestamp > 100000000000.0 ? timestamp / 1000.0 : timestamp) : 0;
    }
    if (![value isKindOfClass:NSString.class]) return 0;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:value];
    if (!date) {
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [formatter dateFromString:value];
    }
    return date.timeIntervalSince1970;
}

NSDictionary *QGClaudeQuotaFromResponse(NSDictionary *response) {
    if (![response isKindOfClass:NSDictionary.class]) return nil;
    NSArray<NSDictionary *> *definitions = @[
        @{@"key": @"five_hour", @"kind": @"primary", @"minutes": @300},
        @{@"key": @"seven_day", @"kind": @"secondary", @"minutes": @10080}
    ];
    NSMutableArray<NSDictionary *> *windows = [NSMutableArray array];
    for (NSDictionary *definition in definitions) {
        NSDictionary *bucket = response[definition[@"key"]];
        if (![bucket isKindOfClass:NSDictionary.class]) continue;
        id raw = bucket[@"utilization"];
        if (![raw isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) continue;
        double used = [raw doubleValue];
        if (!isfinite(used) || used < 0 || used > 100) continue;
        NSTimeInterval reset = QGClaudeResetTime(bucket[@"resets_at"]);
        if (reset <= 0) reset = QGClaudeResetTime(bucket[@"resetsAt"]);
        [windows addObject:@{
            @"usedPercent": @(used),
            @"remainingPercent": @(100.0 - used),
            @"resetsAt": @(reset),
            @"windowDurationMins": definition[@"minutes"],
            @"kind": definition[@"kind"]
        }];
    }
    if (!windows.count) return nil;
    return @{@"windows": windows, @"bucket": @"Claude"};
}

static NSDictionary *QGClaudeLatestDesktopSample(NSDictionary *history) {
    if (![history isKindOfClass:NSDictionary.class] || ![history[@"version"] isKindOfClass:NSNumber.class]) return nil;
    NSArray *samples = history[@"samples"];
    if (![samples isKindOfClass:NSArray.class]) return nil;
    NSDictionary *latest = nil;
    double latestTime = 0;
    for (id item in samples) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"t"] isKindOfClass:NSNumber.class]) continue;
        NSDictionary *usage = item[@"u"];
        if (![usage isKindOfClass:NSDictionary.class]) continue;
        if (![usage[@"fh"] isKindOfClass:NSNumber.class] && ![usage[@"sd"] isKindOfClass:NSNumber.class]) continue;
        double timestamp = [item[@"t"] doubleValue] / 1000.0;
        if (isfinite(timestamp) && timestamp > latestTime && timestamp <= NSDate.date.timeIntervalSince1970 + 300) {
            latest = item;
            latestTime = timestamp;
        }
    }
    if (!latest || NSDate.date.timeIntervalSince1970 - latestTime > QGClaudeDesktopMaximumAge) return nil;
    return latest;
}

NSDictionary *QGClaudeQuotaFromDesktopHistory(NSDictionary *history) {
    NSDictionary *latest = QGClaudeLatestDesktopSample(history);
    if (!latest) return nil;
    double latestTime = [latest[@"t"] doubleValue] / 1000.0;
    NSDictionary *usage = latest[@"u"];
    NSArray<NSDictionary *> *definitions = @[
        @{@"key": @"fh", @"kind": @"primary", @"minutes": @300},
        @{@"key": @"sd", @"kind": @"secondary", @"minutes": @10080}
    ];
    NSMutableArray<NSDictionary *> *windows = [NSMutableArray array];
    for (NSDictionary *definition in definitions) {
        id raw = usage[definition[@"key"]];
        if (![raw isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) continue;
        double used = [raw doubleValue];
        if (!isfinite(used) || used < 0 || used > 100) continue;
        [windows addObject:@{
            @"usedPercent": @(used),
            @"remainingPercent": @(100.0 - used),
            @"resetsAt": @0,
            @"windowDurationMins": definition[@"minutes"],
            @"kind": definition[@"kind"]
        }];
    }
    return windows.count ? @{@"windows": windows, @"updatedAt": @(latestTime), @"bucket": @"Claude Desktop"} : nil;
}

// A CLI and Desktop sign-in can belong to different organizations. Only use the
// non-secret CLI profile when it identifies the exact organization of the sample.
static NSString *QGClaudeDesktopPlan(NSDictionary *sample, NSDictionary *account, NSTimeInterval now) {
    if (![account isKindOfClass:NSDictionary.class]) return nil;
    NSString *org = sample[@"org"];
    if (![org isKindOfClass:NSString.class] || !org.length || ![org isEqual:account[@"organizationUuid"]]) return nil;
    id fetched = account[@"profileFetchedAt"];
    if (![fetched isKindOfClass:NSNumber.class]) return nil;
    double age = now - [fetched doubleValue] / 1000.0;
    if (!isfinite(age) || age < -300 || age > 7 * 86400) return nil;
    return QGClaudePlan(account[@"organizationType"], account[@"organizationRateLimitTier"]);
}

static NSDictionary *QGClaudeDesktopCachedQuota(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
                      @"Library/Application Support/Claude/plan-usage-history.json"];
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSDictionary *history = QGClaudeJSONDictionary(data);
    NSMutableDictionary *quota = [QGClaudeQuotaFromDesktopHistory(history) mutableCopy];
    if (!quota) return nil;
    NSString *profilePath = [NSHomeDirectory() stringByAppendingPathComponent:@".claude.json"];
    NSDictionary *profile = QGClaudeJSONDictionary([NSData dataWithContentsOfFile:profilePath]);
    NSString *plan = QGClaudeDesktopPlan(QGClaudeLatestDesktopSample(history), profile[@"oauthAccount"], NSDate.date.timeIntervalSince1970);
    if (plan) quota[@"planName"] = plan;
    return quota;
}

NSDictionary *QGReadClaudeQuota(NSString **errorKey) {
    NSDictionary *desktop = QGClaudeDesktopCachedQuota();
    NSTimeInterval desktopAge = NSDate.date.timeIntervalSince1970 - [desktop[@"updatedAt"] doubleValue];
    if (desktop && desktopAge <= QGClaudeDesktopFreshness) return desktop;
    NSDictionary *oauth = QGClaudeOAuthCredentials();
    NSString *token = [oauth[@"accessToken"] isKindOfClass:NSString.class] ? oauth[@"accessToken"] : nil;
    if (!token.length) {
        if (desktop) return QGClaudeFallback(desktop, @"error.claudeNotLoggedIn");
        if (errorKey) *errorKey = @"error.claudeNotLoggedIn";
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:QGClaudeUsageURL]];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 15;
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"AgentReadout/2.0" forHTTPHeaderField:@"User-Agent"];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *response = nil;
    __block NSError *networkError = nil;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *urlResponse, NSError *error) {
            responseData = data;
            response = [urlResponse isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)urlResponse : nil;
            networkError = error;
            dispatch_semaphore_signal(done);
        }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0) {
        [task cancel];
        if (desktop) return QGClaudeFallback(desktop, @"error.claudeNetwork");
        if (errorKey) *errorKey = @"error.claudeNetwork";
        return nil;
    }
    if (networkError || !response) {
        if (desktop) return QGClaudeFallback(desktop, @"error.claudeNetwork");
        if (errorKey) *errorKey = @"error.claudeNetwork";
        return nil;
    }
    if (response.statusCode != 200) {
        NSString *statusError = QGClaudeErrorKeyForHTTPStatus(response.statusCode);
        if (desktop) return QGClaudeFallback(desktop, statusError);
        if (errorKey) *errorKey = statusError;
        return nil;
    }
    NSDictionary *quota = QGClaudeQuotaFromResponse(QGClaudeJSONDictionary(responseData));
    if (quota) {
        NSMutableDictionary *dated = [quota mutableCopy];
        dated[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
        NSString *plan = QGClaudePlan(oauth[@"subscriptionType"], oauth[@"rateLimitTier"]);
        if (plan) dated[@"planName"] = plan;
        return dated;
    }
    if (desktop) return QGClaudeFallback(desktop, @"error.claudeUnsupported");
    if (!quota && errorKey) *errorKey = @"error.claudeUnsupported";
    return nil;
}

BOOL QGRunClaudeQuotaSelfTests(void) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSDictionary *account = @{@"organizationUuid": @"matching-org", @"organizationType": @"claude_pro",
        @"organizationRateLimitTier": @"default_claude_ai", @"profileFetchedAt": @(now * 1000)};
    NSMutableDictionary *expiredAccount = [account mutableCopy];
    expiredAccount[@"profileFetchedAt"] = @((now - 8 * 86400) * 1000);
    NSArray *planTests = @[
        @[@"Claude Pro metadata", @([QGClaudePlan(@"pro", nil) isEqual:@"Pro"])],
        @[@"Claude Max 5x metadata", @([QGClaudePlan(@"max", @"default_claude_max_5x") isEqual:@"Max 5×"])],
        @[@"Claude Max 20x metadata", @([QGClaudePlan(@"max", @"default_claude_max_20x") isEqual:@"Max 20×"])],
        @[@"Claude unknown multiplier stays Max", @([QGClaudePlan(@"max", @"new-tier") isEqual:@"Max"])],
        @[@"Claude tier cannot override subscription", @([QGClaudePlan(@"pro", @"default_claude_max_5x") isEqual:@"Pro"])],
        @[@"Claude missing and malformed plan omitted", @(QGClaudePlan(NSNull.null, @"default_claude_max_5x") == nil && QGClaudePlan(@[], @{}) == nil)],
        @[@"Claude matching Desktop organization", @([QGClaudeDesktopPlan(@{@"org": @"matching-org"}, account, now) isEqual:@"Pro"])],
        @[@"Claude different organizations cannot share a plan", @(QGClaudeDesktopPlan(@{@"org": @"different-org"}, account, now) == nil)],
        @[@"Claude unidentified Desktop organization omitted", @(QGClaudeDesktopPlan(@{}, account, now) == nil)],
        @[@"Claude expired profile does not label Desktop sample", @(QGClaudeDesktopPlan(@{@"org": @"matching-org"}, expiredAccount, now) == nil)],
        @[@"Claude invalid profile omitted", @(QGClaudeDesktopPlan(@{@"org": @"matching-org"}, (id)NSNull.null, now) == nil)]
    ];
    BOOL plansPassed = YES;
    for (NSArray *test in planTests) {
        BOOL passed = [test[1] boolValue];
        fprintf(stdout, "%s %s\n", passed ? "PASS" : "FAIL", [test[0] UTF8String]);
        plansPassed &= passed;
    }
    NSDictionary *fixture = @{
        @"five_hour": @{@"utilization": @25.5, @"resets_at": @"2026-10-02T12:00:00Z"},
        @"seven_day": @{@"utilization": @75, @"resets_at": @"2026-10-08T12:00:00.000Z"}
    };
    NSDictionary *quota = QGClaudeQuotaFromResponse(fixture);
    NSArray<NSDictionary *> *windows = quota[@"windows"];
    BOOL valid = windows.count == 2 &&
        fabs([windows[0][@"remainingPercent"] doubleValue] - 74.5) < 0.001 &&
        fabs([windows[1][@"remainingPercent"] doubleValue] - 25.0) < 0.001 &&
        [windows[0][@"resetsAt"] doubleValue] > 0 &&
        [windows[1][@"resetsAt"] doubleValue] > 0;
    NSDictionary *invalid = QGClaudeQuotaFromResponse(@{@"five_hour": @{@"utilization": @150}});
    BOOL rejected = invalid == nil && QGClaudeQuotaFromResponse(@{@"five_hour": @{@"utilization": @YES}}) == nil;
    NSDictionary *missingReset = QGClaudeQuotaFromResponse(@{
        @"five_hour": @{@"utilization": @0, @"resets_at": NSNull.null},
        @"seven_day": @{@"utilization": @20, @"resets_at": @"2026-10-08T12:00:00Z"}
    });
    NSArray *missingResetWindows = missingReset[@"windows"];
    BOOL missingResetValid = missingResetWindows.count == 2 &&
        [missingResetWindows[0][@"remainingPercent"] doubleValue] == 100 &&
        [missingResetWindows[0][@"resetsAt"] doubleValue] == 0 &&
        [missingResetWindows[1][@"resetsAt"] doubleValue] > 0;
    NSDictionary *fallbackReset = QGClaudeQuotaFromResponse(@{
        @"five_hour": @{@"utilization": @10, @"resets_at": NSNull.null,
                        @"resetsAt": @"2026-10-02T12:00:00Z"}
    });
    BOOL fallbackResetValid = [fallbackReset[@"windows"][0][@"resetsAt"] doubleValue] > 0;
    NSDictionary *desktop = QGClaudeQuotaFromDesktopHistory(@{
        @"version": @2,
        @"samples": @[@{@"t": @((long long)(NSDate.date.timeIntervalSince1970 * 1000)),
                        @"org": @"test", @"u": @{@"fh": @40, @"sd": @70}}]
    });
    NSArray *desktopWindows = desktop[@"windows"];
    BOOL desktopValid = desktopWindows.count == 2 &&
        fabs([desktopWindows[0][@"remainingPercent"] doubleValue] - 60) < 0.001 &&
        fabs([desktopWindows[1][@"remainingPercent"] doubleValue] - 30) < 0.001 &&
        [desktopWindows[0][@"resetsAt"] doubleValue] == 0;
    NSDictionary *expiredDesktop = QGClaudeQuotaFromDesktopHistory(@{
        @"version": @2,
        @"samples": @[@{@"t": @((long long)((NSDate.date.timeIntervalSince1970 - 25 * 3600) * 1000)),
                        @"org": @"test", @"u": @{@"fh": @40}}]
    });
    BOOL expiredRejected = expiredDesktop == nil;
    BOOL statusValid = [QGClaudeErrorKeyForHTTPStatus(401) isEqual:@"error.claudeUnauthorized"] &&
        [QGClaudeErrorKeyForHTTPStatus(429) isEqual:@"error.claudeRateLimited"] &&
        [QGClaudeErrorKeyForHTTPStatus(503) isEqual:@"error.claudeServer"] &&
        [QGClaudeErrorKeyForHTTPStatus(400) isEqual:@"error.claudeUnavailable"];
    NSDictionary *fallback = QGClaudeFallback(desktop, @"error.claudeRateLimited");
    BOOL fallbackValid = [fallback[@"windows"] isEqual:desktop[@"windows"]] &&
        [fallback[@"fallbackErrorKey"] isEqual:@"error.claudeRateLimited"] && !QGClaudeFallback(nil, @"error.claudeNetwork");
    fprintf(stdout, "%s Claude usage normalization\n", valid ? "PASS" : "FAIL");
    fprintf(stdout, "%s Claude invalid percentage rejected\n", rejected ? "PASS" : "FAIL");
    fprintf(stdout, "%s Claude missing reset retains valid quota without invented time\n", missingResetValid ? "PASS" : "FAIL");
    fprintf(stdout, "%s Claude alternate reset field with null primary\n", fallbackResetValid ? "PASS" : "FAIL");
    fprintf(stdout, "%s Claude Desktop cache normalization\n", desktopValid ? "PASS" : "FAIL");
    fprintf(stdout, "%s Claude expired cache rejected\n", expiredRejected ? "PASS" : "FAIL");
    fprintf(stdout, "%s Claude HTTP failures classified\n", statusValid ? "PASS" : "FAIL");
    fprintf(stdout, "%s Claude desktop fallback retains failure provenance\n", fallbackValid ? "PASS" : "FAIL");
    return plansPassed && valid && rejected && missingResetValid && fallbackResetValid && desktopValid && expiredRejected && statusValid && fallbackValid;
}
