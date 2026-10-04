#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import "QGWidgetServer.h"
#import "QGClaudeQuota.h"
#import "QGPlan.h"
#import "QGInsights.h"
#import "QGDailyUsage.h"
#import "QGLoginItem.h"
#import "QGQuotaRing.h"
#import <UserNotifications/UserNotifications.h>
#import <math.h>
#import <unistd.h>
#import <dlfcn.h>

static NSString * const QGProductName = @"AgentReadout";
static NSString * const QGPreviousBundleID = @"com.local.codexgauge";
static NSString * const QGLegacyBundleID = @"com.local.codex-quota-overlay";
static NSString * const QGLegacyPrefix = @"CodexQuotaOverlay";
static NSString * const QGWindowsKey = @"QuotaWindows";
static NSString * const QGLastSyncKey = @"LastSuccessfulSync";
static NSString * const QGClaudeWindowsKey = @"ClaudeQuotaWindows";
static NSString * const QGClaudeLastSyncKey = @"ClaudeLastSuccessfulSync";
static NSString * const QGClaudeLastErrorKey = @"ClaudeLastSyncErrorKey";
static NSString * const QGCodexPlanKey = @"CodexPlanName";
static NSString * const QGClaudePlanKey = @"ClaudePlanName";
static NSString * const QGClaudeEnabledKey = @"ClaudeEnabled";
static NSString * const QGSelectedProviderKey = @"SelectedProvider";
static NSString * const QGDisplayModeKey = @"DisplayMode";
static NSString * const QGQuotaStyleKey = @"QuotaVisualStyle";
static NSString * const QGAppearanceModeKey = @"AppearanceMode";
static NSString * const QGLanguageModeKey = @"AppLanguageMode";
static NSString * const QGDesktopWidgetVisibleKey = @"DesktopWidgetVisible";
static NSString * const QGDesktopWidgetSizeKey = @"DesktopWidgetSize";
static NSString * const QGDesktopWidgetProviderModeKey = @"DesktopWidgetProviderMode";
static NSString * const QGDesktopWidgetFrameKey = @"DesktopWidgetFrame";
static NSString * const QGAutomaticUpdateChecksKey = @"AutomaticUpdateChecks";
static NSString * const QGLastUpdateCheckKey = @"LastUpdateCheck";
static NSString * const QGHistoryKey = @"QuotaHistory24Hours";
static NSString * const QGRecordHistoryKey = @"RecordQuotaHistory";
static NSString * const QGQuotaAlertsKey = @"LowQuotaAlertsEnabled";
static NSString * const QGAlertLedgerKey = @"QuotaAlertLedger";
static NSString * const QGReleaseAPIURL = @"https://api.github.com/repos/qingtan-labs/GaugeForCodex/releases/latest";
static NSTimeInterval const QGAutomaticUpdateInterval = 24.0 * 60.0 * 60.0;

static NSString *QGAppearanceMode(void) {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:QGAppearanceModeKey];
    return [@[@"light", @"dark"] containsObject:mode] ? mode : @"system";
}

static NSString *QGLanguageMode(void) {
    NSString *mode = [NSUserDefaults.standardUserDefaults stringForKey:QGLanguageModeKey];
    return [@[@"zh-Hans", @"en"] containsObject:mode] ? mode : @"system";
}

static NSString *QGEffectiveLanguage(void) {
    NSString *mode = QGLanguageMode();
    return [mode isEqualToString:@"system"] ? (NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en") : mode;
}

static NSString *QGLForMode(NSString *key, NSString *mode) {
    if ([mode isEqualToString:@"system"]) return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
    static NSDictionary<NSString *, NSBundle *> *bundles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *found = [NSMutableDictionary dictionary];
        for (NSString *language in @[@"zh-Hans", @"en", @"ja", @"es"]) {
            NSString *path = [NSBundle.mainBundle pathForResource:language ofType:@"lproj"];
            if (path) found[language] = [NSBundle bundleWithPath:path];
        }
        bundles = found.copy;
    });
    return [bundles[mode] localizedStringForKey:key value:key table:nil] ?: key;
}

static NSString *QGL(NSString *key) { return QGLForMode(key, QGLanguageMode()); }

static void QGApplyAppearanceMode(void) {
    NSString *mode = QGAppearanceMode();
    NSApp.appearance = [mode isEqualToString:@"system"] ? nil :
        [NSAppearance appearanceNamed:[mode isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

static BOOL QGIsDailyTokenURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"gaugeforcodex"] &&
        [url.host.lowercaseString isEqualToString:@"insights"] &&
        [url.path isEqualToString:@"/daily-token"] &&
        url.user.length == 0 && url.password.length == 0 && !url.port &&
        url.query.length == 0 && url.fragment.length == 0;
}

#import "QGManualQuota.h"

static BOOL QGNativeWidgetAvailable(void) {
    if (@available(macOS 14.0, *)) {
        NSString *extensionPath = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Contents/PlugIns/GaugeForCodexWidget.appex"];
        return [NSFileManager.defaultManager fileExistsAtPath:extensionPath];
    }
    return NO;
}

static BOOL QGNativeWidgetSupportsClaude(void) {
    NSString *plistPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
                           @"Contents/PlugIns/GaugeForCodexWidget.appex/Contents/Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    return [info[@"QGSupportsClaudeProvider"] boolValue];
}

static BOOL QGNativeWidgetSupportsDualProvider(void) {
    NSString *plistPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
                           @"Contents/PlugIns/GaugeForCodexWidget.appex/Contents/Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    return [info[@"QGSupportsDualProvider"] boolValue];
}

static double QGLinearColorComponent(double value) {
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static BOOL QGPrefersLightTextForRGB(double red, double green, double blue) {
    double luminance = 0.2126 * QGLinearColorComponent(red)
        + 0.7152 * QGLinearColorComponent(green)
        + 0.0722 * QGLinearColorComponent(blue);
    return luminance < 0.27;
}

static BOOL QGWallpaperPrefersLightText(NSScreen *screen, BOOL fallback) {
    if (!screen) return fallback;
    // Desktop widgets sit over the wallpaper, whose brightness is independent of
    // the app's light/dark appearance. Sample a tiny thumbnail of this screen's
    // wallpaper so saturated dark colors use the same light typography as the
    // neighboring system widgets, while pale wallpapers retain dark typography.
    NSURL *url = [NSWorkspace.sharedWorkspace desktopImageURLForScreen:screen];
    if (!url) return fallback;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return fallback;
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @16
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return fallback;

    enum { sampleSize = 12 };
    unsigned char pixels[sampleSize * sampleSize * 4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, sampleSize, sampleSize, 8, sampleSize * 4,
                                                colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        CGImageRelease(image);
        return fallback;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, sampleSize, sampleSize), image);
    CGContextRelease(context);
    CGImageRelease(image);

    double red = 0, green = 0, blue = 0, count = 0;
    for (NSUInteger index = 0; index < sampleSize * sampleSize; index++) {
        const unsigned char *pixel = pixels + index * 4;
        if (pixel[3] < 128) continue;
        red += pixel[0] / 255.0;
        green += pixel[1] / 255.0;
        blue += pixel[2] / 255.0;
        count += 1.0;
    }
    return count > 0 ? QGPrefersLightTextForRGB(red / count, green / count, blue / count) : fallback;
}

static NSNumber *QGNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() || !isfinite([value doubleValue])) return nil;
        return value;
    }
    if ([value isKindOfClass:NSString.class]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double number = 0;
        if ([scanner scanDouble:&number] && scanner.isAtEnd && isfinite(number)) return @(number);
    }
    return nil;
}

static BOOL QGIDEquals(id value, NSInteger expected) {
    NSNumber *number = QGNumber(value);
    return number && number.integerValue == expected;
}

static NSComparisonResult QGCompareVersions(NSString *left, NSString *right) {
    NSString *(^normalize)(NSString *) = ^NSString *(NSString *version) {
        NSString *trimmed = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([trimmed hasPrefix:@"v"] || [trimmed hasPrefix:@"V"]) trimmed = [trimmed substringFromIndex:1];
        return [[trimmed componentsSeparatedByString:@"-"] firstObject] ?: @"0";
    };
    NSArray<NSString *> *leftParts = [normalize(left ?: @"0") componentsSeparatedByString:@"."];
    NSArray<NSString *> *rightParts = [normalize(right ?: @"0") componentsSeparatedByString:@"."];
    NSUInteger count = MAX(leftParts.count, rightParts.count);
    for (NSUInteger index = 0; index < count; index++) {
        NSInteger leftValue = index < leftParts.count ? leftParts[index].integerValue : 0;
        NSInteger rightValue = index < rightParts.count ? rightParts[index].integerValue : 0;
        if (leftValue < rightValue) return NSOrderedAscending;
        if (leftValue > rightValue) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

static BOOL QGNewerRelease(NSString *version, NSString *build, NSString *currentVersion, NSString *currentBuild) {
    NSComparisonResult comparison = QGCompareVersions(version, currentVersion);
    return comparison == NSOrderedDescending || (comparison == NSOrderedSame && build.length &&
        QGCompareVersions(build, currentBuild) == NSOrderedDescending);
}

static BOOL QGValidUpdateManifest(NSDictionary *manifest, NSString *version) {
    if (![manifest isKindOfClass:NSDictionary.class]) return NO;
    NSString *build = manifest[@"build"], *archive = manifest[@"archive"], *sha = manifest[@"sha256"];
    if (![build isKindOfClass:NSString.class] || !build.length || build.longLongValue <= 0 ||
        [build rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound) return NO;
    if (![manifest[@"version"] isEqual:version] || ![manifest[@"bundleIdentifier"] isEqual:@"com.qingtanlabs.gaugeforcodex"]) return NO;
    if (![archive isKindOfClass:NSString.class] || ![archive isEqual:archive.lastPathComponent] ||
        ![archive hasSuffix:@"-Universal.zip"]) return NO;
    return [sha isKindOfClass:NSString.class] && sha.length == 64 &&
        [sha rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location == NSNotFound;
}

static NSString *QGChecksumForFilename(NSString *fileName, NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length < 67 || [line characterAtIndex:64] != ' ') continue;
        NSString *hash = [line substringToIndex:64];
        if ([hash rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) continue;
        NSString *name = [[line substringFromIndex:65] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([name hasPrefix:@"*"]) name = [name substringFromIndex:1];
        if ([name isEqualToString:fileName]) return hash.lowercaseString;
    }
    return nil;
}

static NSString *QGSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) [hex appendFormat:@"%02x", digest[index]];
    return hex;
}

static NSDictionary *QGNormalizedWindow(NSDictionary *dictionary, NSString *kind) {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *usedNumber = QGNumber(dictionary[@"usedPercent"]);
    NSNumber *remainingNumber = QGNumber(dictionary[@"remainingPercent"]);
    if (!usedNumber && !remainingNumber) return nil;
    if ((usedNumber && (usedNumber.doubleValue < 0 || usedNumber.doubleValue > 100)) ||
        (remainingNumber && (remainingNumber.doubleValue < 0 || remainingNumber.doubleValue > 100))) return nil;

    double used = usedNumber ? usedNumber.doubleValue : 100.0 - remainingNumber.doubleValue;
    if (remainingNumber && usedNumber && fabs(used + remainingNumber.doubleValue - 100.0) > 0.1) return nil;

    NSNumber *resetNumber = QGNumber(dictionary[@"resetsAt"]);
    if (!resetNumber) resetNumber = QGNumber(dictionary[@"resetAt"]);
    if (!resetNumber) resetNumber = QGNumber(dictionary[@"resets_at"]);
    if (resetNumber && resetNumber.doubleValue < 0) return nil;
    NSTimeInterval resetAt = resetNumber.doubleValue;
    if (resetAt > 100000000000.0) resetAt /= 1000.0;

    NSNumber *durationNumber = QGNumber(dictionary[@"windowDurationMins"]);
    if (!durationNumber) durationNumber = QGNumber(dictionary[@"windowDurationMinutes"]);
    if (durationNumber && durationNumber.doubleValue < 0) return nil;
    double durationMinutes = durationNumber.doubleValue;
    NSNumber *durationSeconds = QGNumber(dictionary[@"windowDurationSeconds"]);
    if (durationSeconds && durationSeconds.doubleValue < 0) return nil;
    if (!durationMinutes && durationSeconds) durationMinutes = durationSeconds.doubleValue / 60.0;

    return @{
        @"usedPercent": @(used),
        @"remainingPercent": @(100.0 - used),
        @"resetsAt": @(MAX(0.0, resetAt)),
        @"windowDurationMins": @(durationMinutes),
        @"kind": kind ?: @"primary",
        @"manual": @([dictionary[@"manual"] boolValue])
    };
}

static NSArray<NSDictionary *> *QGWindowsFromBucket(NSDictionary *bucket) {
    if (![bucket isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray<NSDictionary *> *windows = [NSMutableArray array];
    NSDictionary *primary = QGNormalizedWindow(bucket[@"primary"], @"primary");
    NSDictionary *secondary = QGNormalizedWindow(bucket[@"secondary"], @"secondary");
    if (primary) [windows addObject:primary];
    if (secondary) [windows addObject:secondary];
    if (windows.count) return windows;

    NSDictionary *direct = QGNormalizedWindow(bucket, @"primary");
    if (direct) return @[direct];

    for (NSString *key in @[@"rateLimit", @"rateLimits", @"limit"]) {
        NSArray<NSDictionary *> *nested = QGWindowsFromBucket(bucket[key]);
        if (nested.count) return nested;
    }
    return @[];
}

static NSDictionary *QGQuotaFromBucket(NSDictionary *bucket, NSString *bucketName) {
    NSArray<NSDictionary *> *windows = QGWindowsFromBucket(bucket);
    if (!windows.count) return nil;
    NSDictionary *selected = windows.firstObject;
    for (NSDictionary *window in windows) {
        if ([window[@"remainingPercent"] doubleValue] < [selected[@"remainingPercent"] doubleValue]) selected = window;
    }
    NSMutableDictionary *quota = [@{
        @"windows": windows,
        @"selected": selected,
        @"remainingPercent": selected[@"remainingPercent"],
        @"resetsAt": selected[@"resetsAt"],
        @"bucket": bucketName ?: @"Codex"
    } mutableCopy];
    NSString *plan = QGCodexPlan(bucket[@"planType"]);
    if (plan) quota[@"planName"] = plan;
    return quota;
}

static NSArray<NSString *> *QGSortedStringKeys(NSDictionary *dictionary) {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (id key in dictionary) if ([key isKindOfClass:NSString.class]) [keys addObject:key];
    [keys sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return keys;
}

static NSDictionary *QGQuotaFromResult(NSDictionary *result) {
    if (![result isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *byID = result[@"rateLimitsByLimitId"];
    if ([byID isKindOfClass:NSDictionary.class]) {
        NSArray<NSString *> *keys = QGSortedStringKeys(byID);
        NSMutableArray<NSString *> *ordered = [NSMutableArray array];
        if ([byID[@"codex"] isKindOfClass:NSDictionary.class]) [ordered addObject:@"codex"];
        for (NSString *key in keys) {
            if (![ordered containsObject:key] && [key caseInsensitiveCompare:@"codex"] == NSOrderedSame) [ordered addObject:key];
        }
        for (NSString *key in keys) {
            if (![ordered containsObject:key] && [key rangeOfString:@"codex" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [ordered addObject:key];
            }
        }
        for (NSString *key in keys) if (![ordered containsObject:key]) [ordered addObject:key];
        for (NSString *key in ordered) {
            NSDictionary *quota = QGQuotaFromBucket(byID[key], key);
            if (quota) return quota;
        }
    }

    NSDictionary *legacy = QGQuotaFromBucket(result[@"rateLimits"], @"Codex");
    if (legacy) return legacy;
    return QGQuotaFromBucket(result, @"Codex");
}

static BOOL QGRunFloatingWidgetSelfTests(void);

static BOOL QGRunSelfTests(void) {
    NSArray<NSDictionary *> *cases = @[
        @{
            @"name": @"prefers exact codex bucket",
            @"input": @{@"rateLimitsByLimitId": @{
                @"alpha": @{@"primary": @{@"usedPercent": @91, @"resetsAt": @1000}},
                @"codex": @{@"primary": @{@"usedPercent": @23, @"resetsAt": @2000}}
            }},
            @"remaining": @77, @"reset": @2000, @"windowCount": @1
        },
        @{
            @"name": @"supports remaining percent and nested rateLimit",
            @"input": @{@"rateLimitsByLimitId": @{
                @"Codex-General": @{@"rateLimit": @{@"primary": @{@"remainingPercent": @62, @"resetAt": @3000}}}
            }},
            @"remaining": @62, @"reset": @3000, @"windowCount": @1
        },
        @{
            @"name": @"supports legacy rateLimits",
            @"input": @{@"rateLimits": @{@"remainingPercent": @1, @"primary": @{@"usedPercent": @7, @"resetsAt": @4000}}},
            @"remaining": @93, @"reset": @4000, @"windowCount": @1
        },
        @{
            @"name": @"converts millisecond reset epoch",
            @"input": @{@"rateLimitsByLimitId": @{@"codex": @{@"primary": @{@"usedPercent": @50, @"resetsAt": @2000000000000LL}}}},
            @"remaining": @50, @"reset": @2000000000, @"windowCount": @1
        },
        @{
            @"name": @"selects the most constrained window",
            @"input": @{@"rateLimitsByLimitId": @{@"codex": @{
                @"primary": @{@"usedPercent": @10, @"resetsAt": @5000, @"windowDurationMins": @10080},
                @"secondary": @{@"usedPercent": @84, @"resetsAt": @6000, @"windowDurationMins": @300}
            }}},
            @"remaining": @16, @"reset": @6000, @"windowCount": @2
        }
    ];

    NSUInteger failures = 0;
    NSArray *planTests = @[
        @[@"Codex explicit plan normalized", @([QGQuotaFromResult(@{@"rateLimits": @{@"planType": @"plus",
            @"primary": @{@"usedPercent": @10}}})[@"planName"] isEqual:@"Plus"])],
        @[@"Codex plan follows selected bucket", @([QGQuotaFromResult(@{@"rateLimits": @{@"planType": @"plus"},
            @"rateLimitsByLimitId": @{@"codex": @{@"planType": @"prolite", @"primary": @{@"usedPercent": @10}}}})[@"planName"] isEqual:@"Pro 5×"])],
        @[@"Codex Pro uses verified 20x client label", @([QGCodexPlan(@"pro") isEqual:@"Pro 20×"])],
        @[@"Codex unverified Pro multiplier stays generic", @([QGCodexPlan(@"promax") isEqual:@"Pro"])],
        @[@"Legacy internal plan names migrate", @([QGValidatedPlanLabel(@"Pro Lite") isEqual:@"Pro 5×"] &&
            [QGValidatedPlanLabel(@"Pro Max") isEqual:@"Pro"])],
        @[@"Codex missing plan not inferred from quota", @(QGQuotaFromResult(@{@"rateLimits": @{@"primary":
            @{@"usedPercent": @0, @"windowDurationMins": @10080}}})[@"planName"] == nil)],
        @[@"Codex malformed and unknown plans omitted", @(QGCodexPlan(NSNull.null) == nil && QGCodexPlan(@"future-plan") == nil)],
        @[@"Account identifiers cannot become plan labels", @(QGValidatedPlanLabel(@"user@example.com") == nil)]
    ];
    for (NSArray *test in planTests) {
        BOOL passed = [test[1] boolValue];
        fprintf(stdout, "%s %s\n", passed ? "PASS" : "FAIL", [test[0] UTF8String]);
        if (!passed) failures++;
    }
    for (NSDictionary *test in cases) {
        NSDictionary *quota = QGQuotaFromResult(test[@"input"]);
        BOOL passed = quota
            && fabs([quota[@"remainingPercent"] doubleValue] - [test[@"remaining"] doubleValue]) < 0.001
            && fabs([quota[@"resetsAt"] doubleValue] - [test[@"reset"] doubleValue]) < 0.001
            && [quota[@"windows"] count] == [test[@"windowCount"] unsignedIntegerValue];
        fprintf(stdout, "%s %s\n", passed ? "PASS" : "FAIL", [test[@"name"] UTF8String]);
        if (!passed) failures++;
    }
    NSArray *invalidWindows = @[
        @{@"usedPercent": @150}, @{@"remainingPercent": @(-1)},
        @{@"usedPercent": @YES}, @{@"usedPercent": @"NaN"},
        @{@"usedPercent": @20, @"remainingPercent": @20},
        @{@"usedPercent": @20, @"resetsAt": @(-2)},
        @{@"usedPercent": @20, @"windowDurationMins": @(-300)}
    ];
    BOOL invalidRejected = YES;
    for (NSDictionary *item in invalidWindows) invalidRejected &= QGNormalizedWindow(item, @"primary") == nil;
    fprintf(stdout, "%s invalid quota percentages and metadata rejected\n", invalidRejected ? "PASS" : "FAIL");
    if (!invalidRejected) failures++;
    NSArray<NSDictionary *> *versionCases = @[
        @{ @"left": @"1.0.1", @"right": @"1.0.0", @"expected": @(NSOrderedDescending) },
        @{ @"left": @"v1.0.1", @"right": @"1.0.1", @"expected": @(NSOrderedSame) },
        @{ @"left": @"1.0", @"right": @"1.0.1", @"expected": @(NSOrderedAscending) }
    ];
    for (NSDictionary *test in versionCases) {
        NSComparisonResult actual = QGCompareVersions(test[@"left"], test[@"right"]);
        BOOL passed = actual == [test[@"expected"] integerValue];
        fprintf(stdout, "%s version %s vs %s\n", passed ? "PASS" : "FAIL",
                [test[@"left"] UTF8String], [test[@"right"] UTF8String]);
        if (!passed) failures++;
    }
    BOOL localizationPassed = ![QGL(@"menu.refresh") isEqualToString:@"menu.refresh"] &&
        [QGLForMode(@"settings.title", @"zh-Hans") isEqualToString:@"设置"] &&
        [QGLForMode(@"settings.title", @"en") isEqualToString:@"Settings"] &&
        ![QGLForMode(@"settings.appearance", @"ja") isEqualToString:@"settings.appearance"] &&
        ![QGLForMode(@"settings.appearance", @"es") isEqualToString:@"settings.appearance"];
    NSDictionary *manifest = @{@"version": @"1.0.1", @"build": @"11", @"bundleIdentifier": @"com.qingtanlabs.gaugeforcodex",
        @"archive": @"Gauge-for-Codex-1.0.1-Universal.zip", @"sha256": [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]};
    NSArray *releaseTests = @[
        @[@"same-version newer build updates", @(QGNewerRelease(@"1.0.1", @"11", @"1.0.1", @"10"))],
        @[@"same build does not update", @(!QGNewerRelease(@"1.0.1", @"11", @"1.0.1", @"11"))],
        @[@"older build does not downgrade", @(!QGNewerRelease(@"1.0.1", @"10", @"1.0.1", @"11"))],
        @[@"older version ignores higher build", @(!QGNewerRelease(@"1.0.0", @"999", @"1.0.1", @"11"))],
        @[@"newer marketing version still updates", @(QGNewerRelease(@"1.0.2", nil, @"1.0.1", @"11"))],
        @[@"legacy same-version release needs no update", @(!QGNewerRelease(@"1.0.1", nil, @"1.0.1", @"11"))],
        @[@"valid release manifest", @(QGValidUpdateManifest(manifest, @"1.0.1"))],
        @[@"checksum matches exact archive", @([QGChecksumForFilename(@"a.zip", [[manifest[@"sha256"] stringByAppendingString:@"  a.zip\n"] dataUsingEncoding:NSUTF8StringEncoding]) isEqual:manifest[@"sha256"]])],
        @[@"checksum rejects substring filename", @(QGChecksumForFilename(@"a.zip", [[manifest[@"sha256"] stringByAppendingString:@"  extra-a.zip\n"] dataUsingEncoding:NSUTF8StringEncoding]) == nil)]
    ];
    for (NSArray *test in releaseTests) {
        BOOL passed = [test[1] boolValue];
        fprintf(stdout, "%s %s\n", passed ? "PASS" : "FAIL", [test[0] UTF8String]);
        if (!passed) failures++;
    }
    NSArray *invalidManifestCases = @[@[@"build", NSNull.null], @[@"build", @"-1"], @[@"version", @"1.0.2"],
        @[@"archive", @"../Other-Universal.zip"], @[@"sha256", @"invalid"], @[@"bundleIdentifier", @"other.app"]];
    for (NSArray *test in invalidManifestCases) {
        NSMutableDictionary *invalid = [manifest mutableCopy];
        invalid[test[0]] = test[1];
        BOOL passed = !QGValidUpdateManifest(invalid, @"1.0.1");
        fprintf(stdout, "%s rejects invalid manifest %s\n", passed ? "PASS" : "FAIL", [test[0] UTF8String]);
        if (!passed) failures++;
    }
    fprintf(stdout, "%s localization resources\n", localizationPassed ? "PASS" : "FAIL");
    if (!localizationPassed) failures++;
    BOOL violetContrastPassed = QGPrefersLightTextForRGB(0.71, 0.31, 0.84);
    fprintf(stdout, "%s light text on violet wallpaper\n", violetContrastPassed ? "PASS" : "FAIL");
    if (!violetContrastPassed) failures++;
    BOOL paleContrastPassed = !QGPrefersLightTextForRGB(0.96, 0.88, 0.82);
    fprintf(stdout, "%s dark text on pale wallpaper\n", paleContrastPassed ? "PASS" : "FAIL");
    if (!paleContrastPassed) failures++;
    BOOL claudePassed = QGRunClaudeQuotaSelfTests();
    if (!claudePassed) failures++;
    BOOL widgetPassed = QGRunWidgetSnapshotSelfTests();
    if (!widgetPassed) failures++;
    if (!QGRunFloatingWidgetSelfTests()) failures++;
    fprintf(stdout, "%lu tests, %lu failures\n",
            (unsigned long)(cases.count + planTests.count + versionCases.count + releaseTests.count + invalidManifestCases.count + 31), (unsigned long)failures);
    return failures == 0;
}

typedef NS_ENUM(NSInteger, QGSyncState) {
    QGSyncStateIdle,
    QGSyncStateSyncing,
    QGSyncStateSuccess,
    QGSyncStateFailed
};

typedef NS_ENUM(NSInteger, QGDisplayMode) {
    QGDisplayModeFull,
    QGDisplayModeCompact
};

typedef NS_ENUM(NSInteger, QGDesktopWidgetSize) {
    QGDesktopWidgetSizeSmall,
    QGDesktopWidgetSizeMedium,
    QGDesktopWidgetSizeLarge
};

static QGDesktopWidgetSize QGWidgetSizeFromPreference(id value) {
    if (![value isKindOfClass:NSNumber.class]) return QGDesktopWidgetSizeMedium;
    NSInteger size = [value integerValue];
    return size >= QGDesktopWidgetSizeSmall && size <= QGDesktopWidgetSizeLarge
        ? (QGDesktopWidgetSize)size : QGDesktopWidgetSizeMedium;
}

static NSSize QGFloatingWidgetSize(QGDesktopWidgetSize size) {
    switch (size) {
        case QGDesktopWidgetSizeLarge: return NSMakeSize(344, 344);
        case QGDesktopWidgetSizeMedium: return NSMakeSize(344, 164);
        default: return NSMakeSize(164, 164);
    }
}

static NSRect QGConstrainWidgetFrame(NSRect frame, NSRect visible) {
    frame.origin.x = MAX(NSMinX(visible), MIN(NSMinX(frame), NSMaxX(visible) - NSWidth(frame)));
    frame.origin.y = MAX(NSMinY(visible), MIN(NSMinY(frame), NSMaxY(visible) - NSHeight(frame)));
    return frame;
}

// Only real windows produce cells. Unknown/manual periods are retained too.
static NSArray<NSDictionary *> *QGOrderedFloatingWindows(NSArray<NSDictionary *> *windows) {
    return [(windows ?: @[]) sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        double lhs = [left[@"windowDurationMins"] doubleValue];
        double rhs = [right[@"windowDurationMins"] doubleValue];
        if (lhs <= 0) lhs = DBL_MAX;
        if (rhs <= 0) rhs = DBL_MAX;
        return lhs < rhs ? NSOrderedAscending : lhs > rhs ? NSOrderedDescending : NSOrderedSame;
    }];
}

static NSArray<NSValue *> *QGLargeQuotaFrames(NSRect area, NSUInteger count, BOOL singleProvider) {
    if (!count) return @[];
    count = MIN(count, (NSUInteger)2);
    if (count == 1) return @[[NSValue valueWithRect:area]];
    NSMutableArray *frames = [NSMutableArray array];
    CGFloat gap = 14;
    for (NSUInteger index = 0; index < count; index++) {
        NSRect cell = singleProvider
            ? NSMakeRect(NSMinX(area), NSMinY(area) + index * ((NSHeight(area) - gap) / 2 + gap),
                         NSWidth(area), (NSHeight(area) - gap) / 2)
            : NSMakeRect(NSMinX(area) + index * ((NSWidth(area) - gap) / 2 + gap), NSMinY(area),
                         (NSWidth(area) - gap) / 2, NSHeight(area));
        [frames addObject:[NSValue valueWithRect:cell]];
    }
    return frames;
}

static BOOL QGRunFloatingWidgetSelfTests(void) {
    NSRect area = NSMakeRect(18, 76, 308, 105);
    NSArray<NSValue *> *one = QGLargeQuotaFrames(area, 1, NO);
    NSArray<NSValue *> *two = QGLargeQuotaFrames(area, 2, NO);
    NSArray<NSValue *> *stacked = QGLargeQuotaFrames(NSMakeRect(18, 76, 308, 250), 2, YES);
    NSArray *ordered = QGOrderedFloatingWindows(@[@{@"windowDurationMins": @10080},
        @{@"windowDurationMins": @0}, @{@"windowDurationMins": @300}]);
    NSArray *cases = @[
        @[@"floating size preferences survive relaunch", @(QGWidgetSizeFromPreference(@2) == QGDesktopWidgetSizeLarge &&
            QGWidgetSizeFromPreference(@0) == QGDesktopWidgetSizeSmall &&
            QGWidgetSizeFromPreference(@99) == QGDesktopWidgetSizeMedium &&
            QGWidgetSizeFromPreference(nil) == QGDesktopWidgetSizeMedium)],
        @[@"floating large size is 344 x 344", @(NSEqualSizes(QGFloatingWidgetSize(QGDesktopWidgetSizeLarge), NSMakeSize(344, 344)))],
        @[@"floating single quota uses full width", @(one.count == 1 && NSEqualRects(one[0].rectValue, area) && QGLargeQuotaFrames(area, 0, NO).count == 0)],
        @[@"floating two quota cells stay within bounds", @(two.count == 2 && NSContainsRect(area, two[0].rectValue) &&
            NSContainsRect(area, two[1].rectValue) && !NSIntersectsRect(two[0].rectValue, two[1].rectValue) &&
            stacked.count == 2 && NSWidth(stacked[0].rectValue) == 308)],
        @[@"floating period sorting retains manual quota", @(ordered.count == 3 &&
            [ordered[0][@"windowDurationMins"] intValue] == 300 && [ordered[2][@"windowDurationMins"] intValue] == 0)],
        @[@"floating resize stays on screen", @(NSEqualRects(QGConstrainWidgetFrame(NSMakeRect(900, -100, 344, 344),
            NSMakeRect(0, 0, 1000, 800)), NSMakeRect(656, 0, 344, 344)))]
    ];
    BOOL passed = YES;
    for (NSArray *test in cases) {
        BOOL result = [test[1] boolValue];
        fprintf(stdout, "%s %s\n", result ? "PASS" : "FAIL", [test[0] UTF8String]);
        passed &= result;
    }
    return passed;
}

typedef NS_ENUM(NSInteger, QGDesktopWidgetProviderMode) {
    QGDesktopWidgetProviderModeFollow,
    QGDesktopWidgetProviderModeCodex,
    QGDesktopWidgetProviderModeClaude,
    QGDesktopWidgetProviderModeBoth
};

static NSString *QGWidgetProviderModeName(QGDesktopWidgetProviderMode mode) {
    switch (mode) {
        case QGDesktopWidgetProviderModeCodex: return @"codex";
        case QGDesktopWidgetProviderModeClaude: return @"claude";
        case QGDesktopWidgetProviderModeBoth: return @"both";
        default: return @"follow";
    }
}

@interface QGStatusContentView : NSView
@property (copy, nonatomic) NSString *displayText;
@property (copy, nonatomic) NSString *providerLabel;
@property (nonatomic) double remainingPercent;
@property (nonatomic) BOOL hasQuota;
@property (nonatomic) BOOL showProgress;
@property (nonatomic) BOOL stale;
@end

@implementation QGStatusContentView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)setDisplayText:(NSString *)displayText { _displayText = [displayText copy]; [self setNeedsDisplay:YES]; }
- (void)setProviderLabel:(NSString *)providerLabel { _providerLabel = [providerLabel copy]; [self setNeedsDisplay:YES]; }
- (void)setRemainingPercent:(double)value { _remainingPercent = MIN(100.0, MAX(0.0, value)); [self setNeedsDisplay:YES]; }
- (void)setHasQuota:(BOOL)value { _hasQuota = value; [self setNeedsDisplay:YES]; }
- (void)setShowProgress:(BOOL)value { _showProgress = value; [self setNeedsDisplay:YES]; }
- (void)setStale:(BOOL)value { _stale = value; [self setNeedsDisplay:YES]; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self setNeedsDisplay:YES]; }
- (NSColor *)statusTextColor {
    NSAppearanceName match = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua,
        NSAppearanceNameVibrantLight, NSAppearanceNameVibrantDark
    ]];
    BOOL dark = [match isEqualToString:NSAppearanceNameDarkAqua] || [match isEqualToString:NSAppearanceNameVibrantDark];
    return dark ? NSColor.whiteColor : NSColor.blackColor;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSString *text = _displayText.length ? _displayText : @"--";
    NSColor *textColor = self.statusTextColor;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: textColor
    };
    NSDictionary *providerAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [textColor colorWithAlphaComponent:0.82]
    };
    NSSize textSize = [text sizeWithAttributes:attributes];
    NSString *provider = _providerLabel ?: @"C";
    NSSize providerSize = [provider sizeWithAttributes:providerAttributes];
    CGFloat textAreaHeight = NSHeight(self.bounds) - (_showProgress ? 4.5 : 0.0);
    CGFloat groupWidth = providerSize.width + 4.0 + textSize.width;
    CGFloat groupX = floor((NSWidth(self.bounds) - groupWidth) / 2.0);
    CGFloat providerY = floor((textAreaHeight - providerSize.height) / 2.0);
    [provider drawAtPoint:NSMakePoint(groupX, providerY) withAttributes:providerAttributes];
    CGFloat textX = groupX + providerSize.width + 4.0;
    CGFloat textY = floor((textAreaHeight - textSize.height) / 2.0) - 0.5;
    [text drawAtPoint:NSMakePoint(textX, textY) withAttributes:attributes];
    if (!_showProgress) return;

    NSRect track = NSMakeRect(5.0, NSHeight(self.bounds) - 3.5, MAX(0.0, NSWidth(self.bounds) - 10.0), 2.5);
    [[textColor colorWithAlphaComponent:0.22] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:1.25 yRadius:1.25] fill];
    if (!_hasQuota || _remainingPercent <= 0) return;
    NSColor *fillColor = _stale ? NSColor.systemGrayColor :
        (_remainingPercent <= 20 ? NSColor.systemRedColor :
         (_remainingPercent <= 40 ? NSColor.systemOrangeColor : NSColor.systemGreenColor));
    [fillColor setFill];
    CGFloat fillWidth = MAX(3.0, NSWidth(track) * _remainingPercent / 100.0);
    NSRect fill = NSMakeRect(NSMinX(track), NSMinY(track), MIN(NSWidth(track), fillWidth), NSHeight(track));
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:1.25 yRadius:1.25] fill];
}
@end

@interface QGDesktopWidgetView : NSView
@property (nonatomic, copy) NSArray<NSDictionary *> *windowModels;
@property (nonatomic, copy) NSArray<NSDictionary *> *providerModels;
@property (nonatomic, copy) NSString *freshnessText;
@property (nonatomic, copy) NSString *exactResetText;
@property (nonatomic, copy) NSString *emptyText;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic) BOOL medium;
@property (nonatomic) BOOL large;
@property (nonatomic) BOOL dualProviderMode;
@property (nonatomic) BOOL usesBars;
@property (nonatomic) BOOL desktopFocused;
@property (nonatomic) BOOL prefersLightText;
@property (nonatomic) BOOL stale;
- (BOOL)usesDarkWidgetAppearance;
@end

@implementation QGDesktopWidgetView
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)setWindowModels:(NSArray<NSDictionary *> *)value { _windowModels = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setProviderModels:(NSArray<NSDictionary *> *)value { _providerModels = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setFreshnessText:(NSString *)value { _freshnessText = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setExactResetText:(NSString *)value { _exactResetText = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setEmptyText:(NSString *)value { _emptyText = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setTitleText:(NSString *)value { _titleText = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setMedium:(BOOL)value { _medium = value; [self setNeedsDisplay:YES]; }
- (void)setLarge:(BOOL)value { _large = value; [self setNeedsDisplay:YES]; }
- (void)setDualProviderMode:(BOOL)value { _dualProviderMode = value; [self setNeedsDisplay:YES]; }
- (void)setUsesBars:(BOOL)value { _usesBars = value; [self setNeedsDisplay:YES]; }
- (void)setDesktopFocused:(BOOL)value { _desktopFocused = value; [self setNeedsDisplay:YES]; }
- (void)setPrefersLightText:(BOOL)value { _prefersLightText = value; [self setNeedsDisplay:YES]; }
- (void)setStale:(BOOL)value { _stale = value; [self setNeedsDisplay:YES]; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self setNeedsDisplay:YES]; }

- (BOOL)usesDarkWidgetAppearance {
    NSString *name = [self.effectiveAppearance bestMatchFromAppearancesWithNames:
                      @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [name isEqualToString:NSAppearanceNameDarkAqua];
}

- (BOOL)usesSystemWidgetSurface {
    return _desktopFocused || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
}

- (NSColor *)primaryTextColor {
    if ([self usesSystemWidgetSurface]) return NSColor.labelColor;
    return _prefersLightText ? [NSColor colorWithWhite:0.92 alpha:0.94]
        : [NSColor colorWithSRGBRed:0.08 green:0.14 blue:0.12 alpha:1.0];
}

- (NSColor *)secondaryTextColor {
    if ([self usesSystemWidgetSurface]) return NSColor.secondaryLabelColor;
    return _prefersLightText ? [NSColor colorWithWhite:0.90 alpha:0.83]
        : [NSColor colorWithSRGBRed:0.09 green:0.15 blue:0.13 alpha:1.0];
}

- (NSShadow *)textShadow {
    NSShadow *shadow = [NSShadow new];
    if (_prefersLightText && ![self usesSystemWidgetSurface]) {
        shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.13];
        shadow.shadowBlurRadius = 1.5;
        shadow.shadowOffset = NSMakeSize(0, -1);
    }
    return shadow;
}

- (void)drawText:(NSString *)text inRect:(NSRect)rect font:(NSFont *)font color:(NSColor *)color
       alignment:(NSTextAlignment)alignment {
    if (!text.length) return;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = alignment;
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: style,
        NSShadowAttributeName: [self textShadow]
    };
    [text drawInRect:rect withAttributes:attributes];
}

- (void)drawRing:(NSDictionary *)model provider:(NSString *)provider inRect:(NSRect)rect {
    QGDrawQuotaRing(rect, [model[@"percent"] doubleValue], model[@"percentText"],
        [self accentForProvider:provider], [[self primaryTextColor] colorWithAlphaComponent:0.12], [self primaryTextColor]);
}

- (void)drawProgressInRect:(NSRect)rect percent:(double)percent provider:(NSString *)provider {
    [[[self primaryTextColor] colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:NSHeight(rect)/2 yRadius:NSHeight(rect)/2] fill];
    double fraction = QGQuotaRingFraction(percent);
    if (fraction <= 0) return;
    [[self accentForProvider:provider] setFill];
    NSRect fill = rect; fill.size.width *= fraction;
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:NSHeight(fill)/2 yRadius:NSHeight(fill)/2] fill];
}

- (void)drawBarCard:(NSDictionary *)model inRect:(NSRect)rect {
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:15 yRadius:15];
    NSColor *fill = [self usesSystemWidgetSurface]
        ? [NSColor.labelColor colorWithAlphaComponent:0.055]
        : _prefersLightText ? [NSColor.whiteColor colorWithAlphaComponent:0.08]
                            : [NSColor.blackColor colorWithAlphaComponent:0.055];
    [fill setFill];
    [card fill];
    if ([model[@"provider"] length]) {
        [self drawProviderName:model[@"provider"] plan:model[@"planName"]
                       inRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 9, NSWidth(rect) - 24, 17) size:11];
    } else {
        [self drawText:model[@"label"] inRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 9, NSWidth(rect) - 24, 17)
              font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    }
    if (model[@"hasQuota"] && ![model[@"hasQuota"] boolValue]) {
        [self drawText:model[@"exactResetText"] inRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 38, NSWidth(rect) - 24, 48)
                  font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        return;
    }
    [self drawText:model[@"percentText"] inRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 28, NSWidth(rect) - 24, 35)
              font:[NSFont monospacedDigitSystemFontOfSize:27 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawProgressInRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 69, NSWidth(rect) - 24, 5)
                      percent:[model[@"percent"] doubleValue] provider:model[@"providerID"]];
    if ([model[@"provider"] length])
        [self drawText:model[@"period"] inRect:NSMakeRect(NSMaxX(rect) - 50, NSMinY(rect) + 43, 38, 16)
                  font:[NSFont systemFontOfSize:9 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentRight];
    [self drawText:model[@"exactResetText"]
            inRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 80, NSWidth(rect) - 24, 16)
              font:[NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightMedium]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
}

- (void)drawBarSingleWindow:(NSDictionary *)model inWidth:(CGFloat)width {
    [self drawText:model[@"percentText"] inRect:NSMakeRect(18, 56, 155, 61)
              font:[NSFont monospacedDigitSystemFontOfSize:45 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    CGFloat detailsX = 183;
    [self drawText:model[@"label"] inRect:NSMakeRect(detailsX, 60, width - detailsX - 18, 22)
              font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:_freshnessText inRect:NSMakeRect(detailsX, 85, width - detailsX - 18, 18)
              font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:_exactResetText inRect:NSMakeRect(detailsX, 106, width - detailsX - 18, 18)
              font:[NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawProgressInRect:NSMakeRect(19, 135, width - 38, 5)
                      percent:[model[@"percent"] doubleValue] provider:model[@"providerID"]];
}

- (void)drawBarCompactDualRows {
    CGFloat width = NSWidth(self.bounds);
    for (NSUInteger index = 0; index < MIN((NSUInteger)2, _windowModels.count); index++) {
        NSDictionary *model = _windowModels[index];
        CGFloat y = 47.0 + 54.0 * index;
        [self drawText:model[@"provider"] ?: model[@"label"]
                inRect:NSMakeRect(17, y + 3, width - 100, 16)
                  font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold]
                 color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
        if (model[@"hasQuota"] && ![model[@"hasQuota"] boolValue]) {
            [self drawText:model[@"exactResetText"] inRect:NSMakeRect(17, y + 26, width - 34, 26)
                      font:[NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium]
                     color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
            continue;
        }
        [self drawText:model[@"percentText"] inRect:NSMakeRect(width - 79, y - 1, 62, 27)
                  font:[NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightSemibold]
                 color:[self primaryTextColor] alignment:NSTextAlignmentRight];
        [self drawProgressInRect:NSMakeRect(17, y + 28, width - 34, 4)
                          percent:[model[@"percent"] doubleValue] provider:model[@"providerID"]];
        NSString *period = model[@"period"];
        NSString *detail = period.length
            ? [NSString stringWithFormat:@"%@ · %@", period, model[@"exactResetText"] ?: @""]
            : model[@"exactResetText"];
        [self drawText:detail inRect:NSMakeRect(17, y + 35, width - 34, 14)
                  font:[NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    }
}

- (void)drawBarLargeQuota:(NSDictionary *)model provider:(NSString *)provider inRect:(NSRect)rect {
    CGFloat x = NSMinX(rect), y = NSMinY(rect), width = NSWidth(rect), height = NSHeight(rect);
    BOOL horizontal = width > 220 && height < 150;
    BOOL hero = height >= 150;
    CGFloat numberSize = hero ? 64 : horizontal ? 39 : 32;
    [self drawText:model[@"label"] inRect:NSMakeRect(x, y, width, 17)
              font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:model[@"percentText"]
            inRect:NSMakeRect(x, y + (hero ? 29 : 18), horizontal ? width * 0.50 : width, numberSize + 10)
              font:[NSFont monospacedDigitSystemFontOfSize:numberSize weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    CGFloat progressY = y + (hero ? height - 64 : horizontal ? height - 12 : 59);
    NSRect track = NSMakeRect(x, progressY, width, 5);
    [[[self primaryTextColor] colorWithAlphaComponent:0.13] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2.5 yRadius:2.5] fill];
    double percent = MIN(100, MAX(0, [model[@"percent"] doubleValue]));
    if (percent > 0) {
        [[self accentForProvider:provider] setFill];
        NSRect fill = NSMakeRect(x, progressY, width * percent / 100, 5);
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2.5 yRadius:2.5] fill];
    }
    CGFloat detailX = horizontal ? x + width * 0.52 : x;
    CGFloat detailWidth = horizontal ? width * 0.48 : width;
    CGFloat detailY = horizontal ? y + 29 : progressY + 11;
    [self drawText:model[@"resetText"] inRect:NSMakeRect(detailX, detailY, detailWidth, 15)
              font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:model[@"exactResetText"] inRect:NSMakeRect(detailX, detailY + 17, detailWidth, 14)
              font:[NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightRegular]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
}

- (void)drawHeaderInWidth:(CGFloat)width {
    // Match the compact 24-point vector mark used by the Windows desktop widget.
    CGFloat scale = 19.0 / 24.0;
    NSAffineTransform *markTransform = [NSAffineTransform transform];
    [markTransform translateXBy:15.0 yBy:14.0];
    [markTransform scaleBy:scale];
    NSColor *markColor = [self primaryTextColor];
    [markColor setStroke];
    NSBezierPath *ring = [NSBezierPath bezierPath];
    [ring appendBezierPathWithArcWithCenter:NSMakePoint(12, 12) radius:8.5
                                 startAngle:45 endAngle:315 clockwise:NO];
    [ring transformUsingAffineTransform:markTransform];
    ring.lineWidth = 3.0 * scale;
    ring.lineCapStyle = NSLineCapStyleRound;
    [ring stroke];
    NSBezierPath *prompt = [NSBezierPath bezierPath];
    [prompt moveToPoint:NSMakePoint(8.5, 8.5)];
    [prompt lineToPoint:NSMakePoint(12, 12)];
    [prompt lineToPoint:NSMakePoint(8.5, 15.5)];
    [prompt moveToPoint:NSMakePoint(15, 15.5)];
    [prompt lineToPoint:NSMakePoint(18.5, 15.5)];
    [prompt transformUsingAffineTransform:markTransform];
    prompt.lineWidth = 2.0 * scale;
    prompt.lineCapStyle = NSLineCapStyleRound;
    prompt.lineJoinStyle = NSLineJoinStyleRound;
    [prompt stroke];
    CGFloat titleWidth = _stale && !_large ? (_medium ? width - 98 : width - 67) : width - 58;
    [self drawText:_titleText ?: QGL(@"widget.title")
            inRect:NSMakeRect(43, 13, titleWidth, 22)
              font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    if (_stale && !_large) {
        if (_medium) {
            [self drawText:QGL(@"widget.cached") inRect:NSMakeRect(width - 52, 16, 37, 17)
                      font:[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold]
                     color:[self secondaryTextColor] alignment:NSTextAlignmentRight];
        } else {
            NSColor *indicator = _prefersLightText && ![self usesSystemWidgetSurface]
                ? [NSColor colorWithSRGBRed:1.0 green:0.82 blue:0.48 alpha:1.0]
                : [NSColor colorWithSRGBRed:0.60 green:0.34 blue:0.02 alpha:1.0];
            [indicator setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(width - 20, 21, 6, 6)] fill];
        }
    }
}

- (void)drawCard:(NSDictionary *)model inRect:(NSRect)rect {
    if (_usesBars) { [self drawBarCard:model inRect:rect]; return; }
    CGFloat x = NSMinX(rect), y = NSMinY(rect), width = NSWidth(rect);
    [self drawRing:model provider:model[@"providerID"] inRect:NSMakeRect(x+4, y+3, 60, 60)];
    [self drawText:model[@"label"] inRect:NSMakeRect(x+74, y+24, width-78, 20)
              font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:model[@"exactResetText"] inRect:NSMakeRect(x+4, y+76, width-8, 24)
              font:[NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
}

- (void)drawSingleWindow:(NSDictionary *)model inWidth:(CGFloat)width {
    if (_usesBars) { [self drawBarSingleWindow:model inWidth:width]; return; }
    [self drawRing:model provider:model[@"providerID"] inRect:NSMakeRect(19, 49, 96, 96)];
    CGFloat detailsX = 137;
    [self drawText:model[@"label"] inRect:NSMakeRect(detailsX, 60, width-detailsX-18, 22)
              font:[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:_freshnessText inRect:NSMakeRect(detailsX, 85, width-detailsX-18, 18)
              font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:_exactResetText inRect:NSMakeRect(detailsX, 106, width-detailsX-18, 28)
              font:[NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
}

- (void)drawCompactDualRows {
    if (_usesBars) { [self drawBarCompactDualRows]; return; }
    CGFloat width = NSWidth(self.bounds);
    for (NSUInteger index = 0; index < MIN((NSUInteger)2, _windowModels.count); index++) {
        NSDictionary *model = _windowModels[index];
        CGFloat y = 44 + 55 * index;
        BOOL hasQuota = !model[@"hasQuota"] || [model[@"hasQuota"] boolValue];
        CGFloat textX = hasQuota ? 67 : 17;
        [self drawText:model[@"provider"] ?: model[@"label"] inRect:NSMakeRect(textX, y, width-textX-14, 16)
                  font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold]
                 color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
        if (!hasQuota) {
            [self drawText:model[@"exactResetText"] inRect:NSMakeRect(17, y+22, width-34, 26)
                      font:[NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium]
                     color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
            continue;
        }
        [self drawRing:model provider:model[@"providerID"] inRect:NSMakeRect(15, y, 44, 44)];
        [self drawText:model[@"period"] inRect:NSMakeRect(textX, y+16, width-textX-14, 14)
                  font:[NSFont systemFontOfSize:9 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        [self drawText:model[@"exactResetText"] inRect:NSMakeRect(textX, y+31, width-textX-14, 14)
                  font:[NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    }
}

- (NSColor *)accentForProvider:(NSString *)provider {
    if (![self usesSystemWidgetSurface]) return [self primaryTextColor];
    BOOL dark = [self usesDarkWidgetAppearance];
    if ([provider isEqualToString:@"claude"]) {
        return dark ? [NSColor colorWithSRGBRed:0.90 green:0.58 blue:0.43 alpha:1]
            : [NSColor colorWithSRGBRed:0.70 green:0.34 blue:0.25 alpha:1];
    }
    return dark ? [NSColor colorWithSRGBRed:0.34 green:0.78 blue:0.68 alpha:1]
        : [NSColor colorWithSRGBRed:0.10 green:0.48 blue:0.41 alpha:1];
}

- (void)drawProviderName:(NSString *)name plan:(NSString *)plan inRect:(NSRect)rect size:(CGFloat)size {
    NSFont *font = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    CGFloat nameWidth = ceil([name sizeWithAttributes:@{NSFontAttributeName: font}].width);
    [self drawText:name inRect:NSMakeRect(rect.origin.x, rect.origin.y, MIN(nameWidth, rect.size.width), rect.size.height)
              font:font color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    if (plan.length && rect.size.width > nameWidth + 12)
        [self drawText:plan inRect:NSMakeRect(rect.origin.x + nameWidth + 6, rect.origin.y + 1,
                                            rect.size.width - nameWidth - 6, rect.size.height)
                  font:[NSFont systemFontOfSize:size - 2 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
}

- (void)drawLargeQuota:(NSDictionary *)model provider:(NSString *)provider inRect:(NSRect)rect {
    if (_usesBars) { [self drawBarLargeQuota:model provider:provider inRect:rect]; return; }
    CGFloat x = NSMinX(rect), y = NSMinY(rect), width = NSWidth(rect), height = NSHeight(rect);
    BOOL horizontal = width > 220;
    CGFloat diameter = horizontal ? (height >= 150 ? 132 : 90) : 60;
    CGFloat ringY = horizontal ? y + MAX(0, (height-diameter)/2) : y;
    [self drawRing:model provider:provider inRect:NSMakeRect(x, ringY, diameter, diameter)];
    CGFloat labelX = x+diameter+(horizontal ? 16 : 8);
    CGFloat labelY = horizontal ? ringY+diameter/2-30 : y+22;
    [self drawText:model[@"label"] inRect:NSMakeRect(labelX, labelY, width-(labelX-x), 18)
              font:[NSFont systemFontOfSize:horizontal ? 12 : 11 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    CGFloat detailX = horizontal ? labelX : x, detailWidth = width-(detailX-x);
    CGFloat detailY = horizontal ? labelY+25 : y+diameter+7;
    [self drawText:model[@"resetText"] inRect:NSMakeRect(detailX, detailY, detailWidth, 15)
              font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:model[@"exactResetText"] inRect:NSMakeRect(detailX, detailY+17, detailWidth, 14)
              font:[NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightRegular]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
}

- (void)drawMediumProviders {
    CGFloat columnWidth = 143;
    for (NSUInteger index = 0; index < MIN((NSUInteger)2, _providerModels.count); index++) {
        NSDictionary *provider = _providerModels[index];
        CGFloat x = 16 + index*169;
        if (index) {
            [[[self primaryTextColor] colorWithAlphaComponent:0.10] setFill];
            NSRectFillUsingOperation(NSMakeRect(171.5, 16, 0.5, 132), NSCompositingOperationSourceOver);
        }
        BOOL stale = [provider[@"stale"] boolValue];
        [self drawProviderName:provider[@"name"] plan:provider[@"planName"]
                       inRect:NSMakeRect(x, 16, columnWidth-(stale ? 39 : 0), 18) size:12];
        if (stale) [self drawText:QGL(@"widget.cached") inRect:NSMakeRect(x+columnWidth-35, 19, 35, 14)
                            font:[NSFont systemFontOfSize:8.5 weight:NSFontWeightMedium]
                           color:[self secondaryTextColor] alignment:NSTextAlignmentRight];
        NSArray *windows = provider[@"windows"];
        if (!windows.count) {
            [self drawText:provider[@"emptyTitle"] inRect:NSMakeRect(x, 55, columnWidth, 20)
                      font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
                     color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
            [self drawText:provider[@"emptyText"] inRect:NSMakeRect(x, 79, columnWidth, 59)
                      font:[NSFont systemFontOfSize:10 weight:NSFontWeightRegular]
                     color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        }
        for (NSUInteger cell = 0; cell < MIN((NSUInteger)2, windows.count); cell++) {
            NSDictionary *window = windows[cell];
            CGFloat diameter = windows.count == 1 ? 60 : 44;
            CGFloat y = windows.count == 1 ? 64 : 46+cell*56;
            if (_usesBars) {
                [self drawText:window[@"label"] inRect:NSMakeRect(x, y, 62, 17)
                          font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]
                         color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
                [self drawText:window[@"percentText"] inRect:NSMakeRect(x+65, y-4, columnWidth-65, 24)
                          font:[NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightSemibold]
                         color:[self primaryTextColor] alignment:NSTextAlignmentRight];
                [self drawProgressInRect:NSMakeRect(x, y+23, columnWidth, 4) percent:[window[@"percent"] doubleValue] provider:provider[@"id"]];
                [self drawText:[window[@"compactResetText"] length] ? window[@"compactResetText"] : window[@"resetText"]
                        inRect:NSMakeRect(x, y+33, columnWidth, 14)
                          font:[NSFont systemFontOfSize:9 weight:NSFontWeightMedium]
                         color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
                continue;
            }
            [self drawRing:window provider:provider[@"id"] inRect:NSMakeRect(x, y, diameter, diameter)];
            CGFloat detailX = x+diameter+8, detailWidth = columnWidth-diameter-8;
            [self drawText:window[@"label"] inRect:NSMakeRect(detailX, y+3, detailWidth, 17)
                      font:[NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]
                     color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
            [self drawText:[window[@"compactResetText"] length] ? window[@"compactResetText"] : window[@"resetText"]
                    inRect:NSMakeRect(detailX, y+23, detailWidth, 28)
                      font:[NSFont systemFontOfSize:9 weight:NSFontWeightMedium]
                     color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        }
    }
}

- (void)drawLargeProviders {
    NSUInteger count = MIN((NSUInteger)2, _providerModels.count);
    if (!count) return;
    CGFloat width = NSWidth(self.bounds) - 36;
    CGFloat gap = 16;
    CGFloat sectionHeight = (NSHeight(self.bounds) - 52 - 18 - gap * (count - 1)) / count;
    for (NSUInteger index = 0; index < count; index++) {
        NSDictionary *provider = _providerModels[index];
        CGFloat top = 52 + index * (sectionHeight + gap);
        if (index) {
            [[[self primaryTextColor] colorWithAlphaComponent:0.10] setFill];
            NSRectFillUsingOperation(NSMakeRect(18, top - gap / 2, width, 0.5), NSCompositingOperationSourceOver);
        }
        [[self accentForProvider:provider[@"id"]] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(18, top + 6, 5, 5)] fill];
        [self drawProviderName:provider[@"name"] plan:provider[@"planName"]
                       inRect:NSMakeRect(29, top, width * 0.57 - 11, 19) size:13];
        [self drawText:provider[@"updatedText"] inRect:NSMakeRect(18 + width * 0.58, top + 2, width * 0.42, 17)
                  font:[NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentRight];
        NSArray<NSDictionary *> *windows = provider[@"windows"];
        NSRect area = NSMakeRect(18, top + 26, width, sectionHeight - 26);
        if (!windows.count) {
            [[[self primaryTextColor] colorWithAlphaComponent:0.035] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:area xRadius:12 yRadius:12] fill];
            CGFloat helpTop = NSMinY(area) + MAX(15, (NSHeight(area) - 72) / 2);
            [self drawText:provider[@"emptyTitle"] inRect:NSMakeRect(32, helpTop, width - 28, 20)
                      font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                     color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
            NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
            style.lineBreakMode = NSLineBreakByWordWrapping;
            style.lineSpacing = 2;
            [provider[@"emptyText"] drawWithRect:NSMakeRect(32, helpTop + 26, width - 28, 43)
                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular],
                             NSForegroundColorAttributeName: [self secondaryTextColor],
                             NSParagraphStyleAttributeName: style}];
            continue;
        }
        NSArray<NSValue *> *frames = QGLargeQuotaFrames(area, windows.count, count == 1);
        for (NSUInteger cell = 0; cell < frames.count; cell++) {
            [self drawLargeQuota:windows[cell] provider:provider[@"id"] inRect:frames[cell].rectValue];
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5)
                                                                  xRadius:24 yRadius:24];
    // Finder focus uses the same opaque surface as desktop system widgets;
    // otherwise the wallpaper remains visible through a gentle contrast scrim.
    NSColor *background = [self usesSystemWidgetSurface]
        ? (_desktopFocused && ![self usesDarkWidgetAppearance]
            ? NSColor.whiteColor : NSColor.windowBackgroundColor)
        : _prefersLightText ? [NSColor.blackColor colorWithAlphaComponent:0.14]
                            : [NSColor.whiteColor colorWithAlphaComponent:0.22];
    [background setFill];
    [backgroundPath fill];
    backgroundPath.lineWidth = 1.0;
    NSColor *border = [self usesSystemWidgetSurface]
        ? [NSColor.labelColor colorWithAlphaComponent:0.08]
        : _prefersLightText ? [NSColor.whiteColor colorWithAlphaComponent:0.22]
                            : [NSColor.blackColor colorWithAlphaComponent:0.11];
    [border setStroke];
    [backgroundPath stroke];
    if (!_large && _medium && _dualProviderMode) {
        [self drawMediumProviders];
        return;
    }
    [self drawHeaderInWidth:NSWidth(bounds)];

    if (_large) {
        [self drawLargeProviders];
        return;
    }

    if (_dualProviderMode) {
        if (_medium) {
            CGFloat gap = 8.0;
            CGFloat cardWidth = (NSWidth(bounds) - 32.0 - gap) / 2.0;
            for (NSUInteger index = 0; index < MIN((NSUInteger)2, _windowModels.count); index++) {
                NSRect card = NSMakeRect(16.0 + index * (cardWidth + gap), 50.0, cardWidth, 103.0);
                [self drawCard:_windowModels[index] inRect:card];
            }
        } else {
            [self drawCompactDualRows];
        }
        return;
    }

    if (!_windowModels.count) {
        [self drawText:@"--%" inRect:NSMakeRect(16, 54, NSWidth(bounds) - 32, 48)
                  font:[NSFont monospacedDigitSystemFontOfSize:36 weight:NSFontWeightBold]
                 color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
        [self drawText:_emptyText inRect:NSMakeRect(16, 108, NSWidth(bounds) - 32, 38)
                  font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        return;
    }

    if (_medium) {
        if (_windowModels.count == 1) {
            [self drawSingleWindow:_windowModels.firstObject inWidth:NSWidth(bounds)];
        } else {
            CGFloat gap = 8.0;
            CGFloat cardWidth = (NSWidth(bounds) - 32.0 - gap) / 2.0;
            for (NSUInteger index = 0; index < MIN((NSUInteger)2, _windowModels.count); index++) {
                NSRect card = NSMakeRect(16.0 + index * (cardWidth + gap), 50.0, cardWidth, 103.0);
                [self drawCard:_windowModels[index] inRect:card];
            }
        }
    } else {
        NSDictionary *model = _windowModels.firstObject;
        if (!_usesBars) {
            [self drawRing:model provider:model[@"providerID"] inRect:NSMakeRect((NSWidth(bounds)-78)/2, 40, 78, 78)];
            [self drawText:model[@"label"] inRect:NSMakeRect(17, 121, NSWidth(bounds)-34, 16)
                      font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
                     color:[self secondaryTextColor] alignment:NSTextAlignmentCenter];
            [self drawText:_exactResetText.length ? _exactResetText : QGL(@"quota.resetUnknown") inRect:NSMakeRect(17, 141, NSWidth(bounds)-34, 15)
                      font:[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium]
                     color:[self secondaryTextColor] alignment:NSTextAlignmentCenter];
            return;
        }
        [self drawText:model[@"label"] inRect:NSMakeRect(17, 48, NSWidth(bounds) - 34, 18)
                  font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        [self drawText:model[@"percentText"] inRect:NSMakeRect(16, 65, NSWidth(bounds) - 32, 48)
                  font:[NSFont monospacedDigitSystemFontOfSize:37 weight:NSFontWeightSemibold]
                 color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
        [self drawProgressInRect:NSMakeRect(17, 117, NSWidth(bounds) - 34, 5)
                          percent:[model[@"percent"] doubleValue] provider:model[@"providerID"]];
        [self drawText:_freshnessText inRect:NSMakeRect(17, 129, NSWidth(bounds) - 34, 15)
                  font:[NSFont systemFontOfSize:10 weight:NSFontWeightRegular]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        [self drawText:_exactResetText inRect:NSMakeRect(17, 145, NSWidth(bounds) - 34, 15)
                  font:[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    }
}
@end

// A compact, non-interactive quota summary inside the native menu. Native
// labels retain normal contrast instead of looking like disabled commands.
@interface QGMenuRingView : NSView
@property double percent;
@property BOOL claude;
@property BOOL usesBars;
@property NSString *percentText;
@end

@implementation QGMenuRingView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    double value = QGQuotaRingFraction(_percent) * 100;
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:
                  @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *tint = _claude
        ? [NSColor colorWithSRGBRed:dark ? 0.92 : 0.70 green:dark ? 0.64 : 0.36 blue:dark ? 0.48 : 0.25 alpha:1]
        : [NSColor colorWithSRGBRed:dark ? 0.40 : 0.12 green:dark ? 0.80 : 0.48 blue:dark ? 0.70 : 0.41 alpha:1];
    if (value <= 10) tint = NSColor.systemRedColor;
    else if (value <= 20) tint = NSColor.systemOrangeColor;
    if (_usesBars) {
        [[NSColor.labelColor colorWithAlphaComponent:0.10] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:2.5 yRadius:2.5] fill];
        if (value > 0) {
            [tint setFill];
            NSRect fill = self.bounds; fill.size.width *= value / 100.0;
            [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:2.5 yRadius:2.5] fill];
        }
        return;
    }
    QGDrawQuotaRing(self.bounds, value, _percentText, tint,
        [NSColor.labelColor colorWithAlphaComponent:0.10], value <= 20 ? tint : NSColor.labelColor);
}
@end

#import "QGInsightsUI.h"
#import "QGSettingsUI.h"

@interface QGAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate>
@property NSStatusItem *statusItem;
@property QGStatusContentView *statusContentView;
@property NSMenu *statusMenu;
@property QGMenuQuotaView *menuQuotaView;
@property QGProviderSwitchView *providerSwitchView;
@property NSMenuItem *settingsMenuItem;
@property NSMenuItem *widgetsMenuItem;
@property NSMenuItem *syncStateMenuItem;
@property NSMenuItem *statisticsMenuItem;
@property NSWindow *settingsWindow;
@property QGSettingsView *settingsView;
@property NSWindow *statisticsWindow;
@property QGStatisticsView *statisticsView;
@property NSDictionary *usageStatsReport;
@property (atomic) NSUInteger statisticsGeneration;
@property BOOL usageStatsLoading;
@property NSDate *lastDailyUsageAttempt;
@property BOOL usageStatsIncludesClaude;
@property BOOL appReady;
@property BOOL pendingDailyTokenOpen;
@property BOOL notificationsAllowed;
@property NSMutableSet *pendingQuotaAlerts;
@property NSMenuItem *refreshMenuItem;
@property NSMenuItem *codexProviderMenuItem;
@property NSMenuItem *claudeProviderMenuItem;
@property NSMenuItem *nativeWidgetMenuItem;
@property NSMenuItem *addWidgetMenuItem;
@property NSMenuItem *toggleWidgetMenuItem;
@property NSMenuItem *smallWidgetMenuItem;
@property NSMenuItem *mediumWidgetMenuItem;
@property NSMenuItem *largeWidgetMenuItem;
@property NSMenuItem *widgetProviderMenuItem;
@property NSMenuItem *widgetFollowMenuItem;
@property NSMenuItem *widgetCodexMenuItem;
@property NSMenuItem *widgetClaudeMenuItem;
@property NSMenuItem *widgetBothMenuItem;
@property NSMenuItem *resetWidgetPositionMenuItem;
@property NSMenuItem *quitMenuItem;
@property NSTimer *syncTimer;
@property NSTimer *dailyUsageTimer;
@property NSTimer *displayTimer;
@property NSTimer *updateTimer;
@property NSPanel *desktopWidgetPanel;
@property NSVisualEffectView *desktopWidgetEffectView;
@property QGDesktopWidgetView *desktopWidgetView;
@property QGWidgetServer *widgetServer;
@property QGDesktopWidgetSize desktopWidgetSize;
@property QGDesktopWidgetProviderMode desktopWidgetProviderMode;
@property NSArray<NSDictionary *> *quotaWindows;
@property NSDictionary *selectedWindow;
@property NSArray<NSDictionary *> *claudeWindows;
@property NSString *codexPlanName;
@property NSString *claudePlanName;
@property NSDictionary *claudeSelectedWindow;
@property NSDate *claudeLastSuccessfulSync;
@property NSDate *claudeLastAttempt;
@property NSString *claudeLastError;
@property NSString *claudeSourceKind;
@property QGSyncState claudeSyncState;
@property BOOL claudeSyncInProgress;
@property NSString *selectedProvider;
@property QGSyncState syncState;
@property QGDisplayMode displayMode;
@property BOOL syncInProgress;
@property BOOL updateCheckInProgress;
@property BOOL updateInstallInProgress;
@property NSDate *lastSuccessfulSync;
@property NSString *syncDetail;
@property NSString *lastError;
@property NSString *availableUpdateVersion;
@property NSString *availableUpdateBuild;
@property NSDictionary *availableUpdateManifest;
@property NSURL *availableUpdateURL;
@property NSDictionary *lastWidgetContent;
@property NSTimer *nativeWidgetReloadTimer;
@property NSDate *lastNativeWidgetReload;
- (void)publishWidgetSnapshot;
- (void)openPendingDailyTokenIfReady;
- (void)refreshDailyUsageForced:(BOOL)forced;
- (void)reloadLocalizedInterface;
- (void)performAutomaticUpdateCheckIfNeeded;
- (void)checkForUpdates:(id)sender;
- (void)toggleAutomaticUpdateChecks:(id)sender;
- (void)refreshDesktopWidget;
- (void)updateDesktopWidgetAppearance;
- (void)refreshClaudeQuotaForced:(BOOL)forced;
- (NSArray<NSDictionary *> *)activeWindows;
- (NSDictionary *)activeWindow;
- (NSDate *)activeLastSuccessfulSync;
- (QGSyncState)activeSyncState;
- (NSString *)activeLastError;
- (BOOL)hasClaudeDisplayData;
@end

@implementation QGAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    QGApplyAppearanceMode();
    if ([NSUserDefaults.standardUserDefaults objectForKey:QGAutomaticUpdateChecksKey] == nil) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:QGAutomaticUpdateChecksKey];
    }
    [NSUserDefaults.standardUserDefaults registerDefaults:@{QGRecordHistoryKey: @NO}];
    NSArray *history = QGInsightHistory([NSUserDefaults.standardUserDefaults objectForKey:QGHistoryKey], NSDate.date.timeIntervalSince1970);
    [NSUserDefaults.standardUserDefaults setObject:history forKey:QGHistoryKey];
    _pendingQuotaAlerts = [NSMutableSet set];
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    if ([NSUserDefaults.standardUserDefaults boolForKey:QGQuotaAlertsKey]) [self refreshNotificationPermission];
    [self restoreCachedQuota];
    [self restoreCachedClaudeQuota];
    id savedWidgetSize = [NSUserDefaults.standardUserDefaults objectForKey:QGDesktopWidgetSizeKey];
    _desktopWidgetSize = QGWidgetSizeFromPreference(savedWidgetSize);
    NSInteger savedProviderMode = [NSUserDefaults.standardUserDefaults integerForKey:QGDesktopWidgetProviderModeKey];
    _desktopWidgetProviderMode = savedProviderMode >= QGDesktopWidgetProviderModeFollow &&
        savedProviderMode <= QGDesktopWidgetProviderModeBoth
        ? (QGDesktopWidgetProviderMode)savedProviderMode : QGDesktopWidgetProviderModeFollow;
    if (QGNativeWidgetAvailable()) {
        _widgetServer = [QGWidgetServer new];
        if (![_widgetServer start]) NSLog(@"AgentReadout: native widget loopback server could not start");
    }
    [self publishWidgetSnapshot];

    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:56.0];
    _statusItem.autosaveName = @"CodexGaugeStatusItem";
    _statusItem.button.image = nil;
    _statusItem.button.title = @"";
    _statusContentView = [[QGStatusContentView alloc] initWithFrame:_statusItem.button.bounds];
    _statusContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_statusItem.button addSubview:_statusContentView];
    _statusMenu = [self makeMenu];
    _statusItem.menu = _statusMenu;
    [self updateStatusItem];
    if ([NSUserDefaults.standardUserDefaults boolForKey:QGDesktopWidgetVisibleKey]) {
        [self showDesktopWidget:nil];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(localeOrTimeZoneChanged:)
                                                 name:NSCurrentLocaleDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(localeOrTimeZoneChanged:)
                                                 name:NSSystemTimeZoneDidChangeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(workspaceDidWake:)
                                                            name:NSWorkspaceDidWakeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(activeApplicationChanged:)
                                                            name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(accessibilityDisplayOptionsChanged:)
                                                            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];

    __weak QGAppDelegate *weakSelf = self;
    _syncTimer = [NSTimer timerWithTimeInterval:60.0 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refreshQuota:nil];
    }];
    _syncTimer.tolerance = 5.0;
    [NSRunLoop.mainRunLoop addTimer:_syncTimer forMode:NSRunLoopCommonModes];
    _dailyUsageTimer = [NSTimer timerWithTimeInterval:30.0 * 60.0 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refreshDailyUsageForced:NO];
    }];
    _dailyUsageTimer.tolerance = 60.0;
    [NSRunLoop.mainRunLoop addTimer:_dailyUsageTimer forMode:NSRunLoopCommonModes];
    _displayTimer = [NSTimer timerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf displayTimerFired];
    }];
    _displayTimer.tolerance = 3.0;
    [NSRunLoop.mainRunLoop addTimer:_displayTimer forMode:NSRunLoopCommonModes];
    _updateTimer = [NSTimer timerWithTimeInterval:6.0 * 60.0 * 60.0 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf performAutomaticUpdateCheckIfNeeded];
    }];
    _updateTimer.tolerance = 15.0 * 60.0;
    [NSRunLoop.mainRunLoop addTimer:_updateTimer forMode:NSRunLoopCommonModes];
    [self refreshQuota:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf refreshDailyUsageForced:NO];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf performAutomaticUpdateCheckIfNeeded];
    });
    self.appReady = YES;
    [self openPendingDailyTokenIfReady];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    for (NSURL *url in urls) {
        if (QGIsDailyTokenURL(url)) {
            self.pendingDailyTokenOpen = YES;
            [self openPendingDailyTokenIfReady];
            break;
        }
    }
}

- (void)openPendingDailyTokenIfReady {
    if (!self.appReady || !self.pendingDailyTokenOpen) return;
    self.pendingDailyTokenOpen = NO;
    if (_statisticsView) _statisticsView.tabs.selectedSegment = 0;
    [self showStatistics:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [_syncTimer invalidate];
    [_dailyUsageTimer invalidate];
    [_displayTimer invalidate];
    [_updateTimer invalidate];
    [_nativeWidgetReloadTimer invalidate];
    [_widgetServer stop];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return NO; }

- (NSMenu *)makeMenu {
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    NSMenuItem *switchItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _providerSwitchView = [[QGProviderSwitchView alloc] initWithFrame:NSMakeRect(0, 0, 336, 40)];
    switchItem.view = _providerSwitchView;
    _providerSwitchView.codexButton.target = self;
    _providerSwitchView.claudeButton.target = self;
    _providerSwitchView.codexButton.action = @selector(selectProviderButton:);
    _providerSwitchView.claudeButton.action = @selector(selectProviderButton:);
    _providerSwitchView.refreshButton.target = self;
    _providerSwitchView.refreshButton.action = @selector(refreshFromMenu:);
    _providerSwitchView.settingsButton.target = self;
    _providerSwitchView.settingsButton.action = @selector(showSettings:);
    // Menu-hosted views do not receive normal keyboard navigation. Retain the
    // native command equivalents without duplicating visible provider rows.
    _codexProviderMenuItem = [menu addItemWithTitle:@"" action:@selector(selectProvider:) keyEquivalent:@"1"];
    _codexProviderMenuItem.target = self;
    _codexProviderMenuItem.representedObject = @"codex";
    _claudeProviderMenuItem = [menu addItemWithTitle:@"" action:@selector(selectProvider:) keyEquivalent:@"2"];
    _claudeProviderMenuItem.target = self;
    _claudeProviderMenuItem.representedObject = @"claude";
    for (NSMenuItem *item in @[_codexProviderMenuItem, _claudeProviderMenuItem]) {
        item.hidden = YES; item.allowsKeyEquivalentWhenHidden = YES;
    }
    NSMenuItem *quotaItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _menuQuotaView = [[QGMenuQuotaView alloc] initWithFrame:NSMakeRect(0, 0, 320, 108)];
    quotaItem.view = _menuQuotaView;
    _syncStateMenuItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _syncStateMenuItem.enabled = NO;
    _syncStateMenuItem.hidden = YES;
    [menu addItem:NSMenuItem.separatorItem];
    _refreshMenuItem = [menu addItemWithTitle:@"" action:@selector(refreshFromMenu:) keyEquivalent:@"r"];
    _refreshMenuItem.target = self;
    _refreshMenuItem.hidden = YES; _refreshMenuItem.allowsKeyEquivalentWhenHidden = YES;
    _statisticsMenuItem = [menu addItemWithTitle:@"" action:@selector(showStatistics:) keyEquivalent:@"s"];
    _statisticsMenuItem.target = self;
    _widgetsMenuItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *widgetsMenu = [NSMenu new];
    _widgetsMenuItem.submenu = widgetsMenu;
    _settingsMenuItem = [menu addItemWithTitle:@"" action:@selector(showSettings:) keyEquivalent:@","];
    _settingsMenuItem.target = self;
    _settingsMenuItem.hidden = YES; _settingsMenuItem.allowsKeyEquivalentWhenHidden = YES;
    _nativeWidgetMenuItem = [widgetsMenu addItemWithTitle:@"" action:@selector(showNativeWidgetInstructions:) keyEquivalent:@""];
    _nativeWidgetMenuItem.target = self;
    _addWidgetMenuItem = [widgetsMenu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *widgetMenu = [NSMenu new];
    _toggleWidgetMenuItem = [widgetMenu addItemWithTitle:@"" action:@selector(toggleDesktopWidget:) keyEquivalent:@""];
    _toggleWidgetMenuItem.target = self;
    [widgetMenu addItem:NSMenuItem.separatorItem];
    _smallWidgetMenuItem = [widgetMenu addItemWithTitle:@"" action:@selector(changeDesktopWidgetSize:) keyEquivalent:@""];
    _smallWidgetMenuItem.target = self;
    _smallWidgetMenuItem.tag = QGDesktopWidgetSizeSmall;
    _mediumWidgetMenuItem = [widgetMenu addItemWithTitle:@"" action:@selector(changeDesktopWidgetSize:) keyEquivalent:@""];
    _mediumWidgetMenuItem.target = self;
    _mediumWidgetMenuItem.tag = QGDesktopWidgetSizeMedium;
    _largeWidgetMenuItem = [widgetMenu addItemWithTitle:@"" action:@selector(changeDesktopWidgetSize:) keyEquivalent:@""];
    _largeWidgetMenuItem.target = self;
    _largeWidgetMenuItem.tag = QGDesktopWidgetSizeLarge;
    [widgetMenu addItem:NSMenuItem.separatorItem];
    _resetWidgetPositionMenuItem = [widgetMenu addItemWithTitle:@"" action:@selector(resetDesktopWidgetPosition:) keyEquivalent:@""];
    _resetWidgetPositionMenuItem.target = self;
    _addWidgetMenuItem.submenu = widgetMenu;
    _widgetProviderMenuItem = [widgetsMenu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *providerMenu = [NSMenu new];
    _widgetFollowMenuItem = [providerMenu addItemWithTitle:@"" action:@selector(changeDesktopWidgetProviderMode:) keyEquivalent:@""];
    _widgetCodexMenuItem = [providerMenu addItemWithTitle:@"" action:@selector(changeDesktopWidgetProviderMode:) keyEquivalent:@""];
    _widgetClaudeMenuItem = [providerMenu addItemWithTitle:@"" action:@selector(changeDesktopWidgetProviderMode:) keyEquivalent:@""];
    _widgetBothMenuItem = [providerMenu addItemWithTitle:@"" action:@selector(changeDesktopWidgetProviderMode:) keyEquivalent:@""];
    NSArray<NSMenuItem *> *providerItems = @[_widgetFollowMenuItem, _widgetCodexMenuItem,
        _widgetClaudeMenuItem, _widgetBothMenuItem];
    for (NSUInteger index = 0; index < providerItems.count; index++) {
        providerItems[index].target = self;
        providerItems[index].tag = (NSInteger)index;
    }
    _widgetProviderMenuItem.submenu = providerMenu;
    [menu addItem:NSMenuItem.separatorItem];
    _quitMenuItem = [menu addItemWithTitle:@"" action:@selector(terminate:) keyEquivalent:@"q"];
    _quitMenuItem.target = NSApp;
    return menu;
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    if ([NSUserDefaults.standardUserDefaults boolForKey:QGQuotaAlertsKey]) [self refreshNotificationPermission];
    [self updateStatusItem];
    NSTimeInterval age = _lastSuccessfulSync ? -_lastSuccessfulSync.timeIntervalSinceNow : DBL_MAX;
    if (!_syncInProgress && age > 60.0) [self refreshQuota:nil];
    if ([NSUserDefaults.standardUserDefaults boolForKey:QGClaudeEnabledKey]) [self refreshClaudeQuotaForced:NO];
}

- (void)localeOrTimeZoneChanged:(NSNotification *)notification {
    (void)notification;
    [self reloadLocalizedInterface];
}

- (void)workspaceDidWake:(NSNotification *)notification {
    (void)notification;
    [self refreshQuota:nil];
    [self refreshDailyUsageForced:NO];
    [self performAutomaticUpdateCheckIfNeeded];
}

- (void)activeApplicationChanged:(NSNotification *)notification {
    (void)notification;
    [self updateDesktopWidgetAppearance];
}

- (void)accessibilityDisplayOptionsChanged:(NSNotification *)notification {
    (void)notification;
    [self updateDesktopWidgetAppearance];
    [_desktopWidgetView setNeedsDisplay:YES];
}

- (void)displayTimerFired {
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:QGHistoryKey];
    NSArray *recent = QGInsightHistory(stored, NSDate.date.timeIntervalSince1970);
    if (stored && ![stored isEqual:recent]) [NSUserDefaults.standardUserDefaults setObject:recent forKey:QGHistoryKey];
    if (_statisticsWindow.isVisible) [self updateStatisticsView];
    [self updateStatusItem];
    [self refreshDesktopWidget];
    NSTimeInterval resetAt = [self.activeWindow[@"resetsAt"] doubleValue];
    if (resetAt > 0 && resetAt <= NSDate.date.timeIntervalSince1970 && !_syncInProgress) {
        NSDate *lastSync = self.activeLastSuccessfulSync;
        NSTimeInterval age = lastSync ? -lastSync.timeIntervalSinceNow : DBL_MAX;
        if (age > 20.0) {
            if ([_selectedProvider isEqualToString:@"claude"]) [self refreshClaudeQuotaForced:NO];
            else [self refreshQuota:nil];
        }
    }
}

- (NSString *)percentageString:(double)remaining {
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterPercentStyle;
    formatter.minimumFractionDigits = 0;
    formatter.maximumFractionDigits = 0;
    return [formatter stringFromNumber:@(remaining / 100.0)] ?: [NSString stringWithFormat:@"%.0f%%", remaining];
}

- (NSString *)relativeDuration:(NSTimeInterval)seconds maximumUnits:(NSInteger)maximumUnits {
    NSDateComponentsFormatter *formatter = [NSDateComponentsFormatter new];
    formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
    formatter.maximumUnitCount = maximumUnits;
    formatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorDropAll;
    if (seconds >= 86400.0) formatter.allowedUnits = NSCalendarUnitDay | NSCalendarUnitHour;
    else if (seconds >= 3600.0) formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute;
    else formatter.allowedUnits = NSCalendarUnitMinute;
    return [formatter stringFromTimeInterval:MAX(60.0, seconds)] ?: @"";
}

- (NSString *)exactResetTextForWindow:(NSDictionary *)window {
    NSTimeInterval resetAt = [window[@"resetsAt"] doubleValue];
    if (resetAt <= 0) return QGL(@"quota.resetUnknown");
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:resetAt]];
}

- (NSString *)compactResetTextForWindow:(NSDictionary *)window {
    NSTimeInterval resetAt = [window[@"resetsAt"] doubleValue];
    if (resetAt <= 0) return @"";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:resetAt]];
}

- (NSString *)resetDescriptionForWindow:(NSDictionary *)window {
    NSTimeInterval resetAt = [window[@"resetsAt"] doubleValue];
    if (resetAt <= 0) return QGL(@"quota.resetUnknown");
    NSTimeInterval remaining = resetAt - NSDate.date.timeIntervalSince1970;
    if (remaining <= 0) return QGL(@"quota.awaitingRefresh");
    return [NSString stringWithFormat:QGL(@"quota.resetIn"),
            [self relativeDuration:remaining maximumUnits:2], [self exactResetTextForWindow:window]];
}

- (NSString *)menuResetTextForWindow:(NSDictionary *)window {
    NSTimeInterval resetAt = [window[@"resetsAt"] doubleValue];
    if (resetAt <= 0) return [QGL(@"quota.resetUnknown") stringByAppendingString:@" ⓘ"];
    if (resetAt <= NSDate.date.timeIntervalSince1970) return QGL(@"quota.awaitingRefreshShort");
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.timeZone = NSTimeZone.localTimeZone;
    [formatter setLocalizedDateFormatFromTemplate:@"Mdjm"];
    return [NSString stringWithFormat:QGL(@"quota.resetAtShort"),
            [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:resetAt]]];
}

- (NSString *)resetHelpForWindow:(NSDictionary *)window {
    if ([window[@"resetsAt"] doubleValue] > 0) return [self resetDescriptionForWindow:window];
    return QGL(self.showingClaude && [_claudeSourceKind isEqualToString:@"desktop"]
               ? @"quota.resetCacheHelp" : @"quota.resetUnavailableHelp");
}

- (NSString *)windowLabel:(NSDictionary *)window {
    double minutes = [window[@"windowDurationMins"] doubleValue];
    NSString *kind = window[@"kind"];
    NSString *label = minutes > 0 ? [self relativeDuration:minutes * 60.0 maximumUnits:1] :
        ([kind isEqualToString:@"secondary"] ? QGL(@"quota.secondaryWindow") : QGL(@"quota.primaryWindow"));
    return [window[@"manual"] boolValue] ? [NSString stringWithFormat:@"%@ · %@", label, QGL(@"manual.short")] : label;
}

- (BOOL)dataIsStale {
    NSDate *lastSync = self.activeLastSuccessfulSync;
    return !lastSync || -lastSync.timeIntervalSinceNow > 300.0;
}

- (NSString *)freshnessText {
    QGSyncState state = self.activeSyncState;
    NSDate *lastSync = self.activeLastSuccessfulSync;
    if (state == QGSyncStateSyncing) return QGL(@"sync.syncing");
    NSString *ageText = nil;
    if (lastSync) {
        NSTimeInterval age = MAX(0.0, -lastSync.timeIntervalSinceNow);
        ageText = age < 75.0 ? QGL(@"sync.justNow") :
            [NSString stringWithFormat:QGL(@"sync.ago"), [self relativeDuration:age maximumUnits:1]];
    }
    if (state == QGSyncStateFailed) {
        NSString *error = self.activeLastError;
        NSString *failure = error.length ? error : QGL(@"sync.failed");
        return ageText.length ? [NSString stringWithFormat:QGL(@"sync.failedWithLastUpdate"), failure, ageText] : failure;
    }
    if (!lastSync) {
        if ([_selectedProvider isEqualToString:@"claude"]) {
            return [NSUserDefaults.standardUserDefaults boolForKey:QGClaudeEnabledKey]
                ? QGL(@"sync.claudeWaiting") : QGL(@"sync.claudeDisabled");
        }
        return _syncDetail.length ? _syncDetail : QGL(@"sync.waiting");
    }
    NSString *source = QGManualQuotaSource(self.activeWindows);
    if (source) {
        // Manual provenance survives relaunch and failed automatic refreshes.
    } else if (self.showingClaude) {
        if (state == QGSyncStateSuccess) {
            source = [_claudeSourceKind isEqualToString:@"desktop"]
                ? QGL(@"sync.claudeDesktopCache") : QGL(@"sync.claudeCodeLive");
        } else {
            source = QGL(@"sync.cached");
        }
    } else if (state == QGSyncStateSuccess) {
        source = QGL(@"sync.openaiLive");
    } else {
        source = _syncDetail;
    }
    NSString *freshness = self.dataIsStale ? [NSString stringWithFormat:QGL(@"sync.stale"), ageText] : ageText;
    return source.length ? [NSString stringWithFormat:@"%@ · %@", source, freshness] : freshness;
}

- (void)updateStatusItem {
    NSDictionary *selected = self.activeWindow;
    BOOL hasQuota = selected != nil;
    double remaining = hasQuota ? [selected[@"remainingPercent"] doubleValue] : 0.0;
    NSString *percent = hasQuota ? [self percentageString:remaining] : @"--";
    NSDictionary *statusTextAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14.5 weight:NSFontWeightSemibold]
    };
    NSDictionary *providerTextAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium]
    };
    CGFloat measuredWidth = ceil([percent sizeWithAttributes:statusTextAttributes].width);
    NSString *providerLabel = self.showingClaude ? @"A" : @"C";
    CGFloat providerWidth = ceil([providerLabel sizeWithAttributes:providerTextAttributes].width);
    CGFloat minimumWidth = _displayMode == QGDisplayModeCompact ? 46.0 : 56.0;
    _statusItem.length = MAX(minimumWidth, measuredWidth + providerWidth + 20.0);
    _statusContentView.displayText = percent;
    _statusContentView.providerLabel = providerLabel;
    _statusContentView.hasQuota = hasQuota;
    _statusContentView.remainingPercent = remaining;
    _statusContentView.showProgress = _displayMode == QGDisplayModeFull;
    _statusContentView.stale = self.dataIsStale || self.activeSyncState == QGSyncStateFailed;

    NSString *providerName = [_selectedProvider isEqualToString:@"claude"] ? @"Claude" : @"Codex";
    [_providerSwitchView configureSelectedProvider:_selectedProvider
        claudeEnabled:self.hasClaudeDisplayData];
    _providerSwitchView.refreshing = _syncInProgress || _claudeSyncInProgress;
    _refreshMenuItem.enabled = !_providerSwitchView.refreshing;
    _menuQuotaView.usesBars = ![[NSUserDefaults.standardUserDefaults stringForKey:QGQuotaStyleKey] isEqual:@"ring"];
    [_menuQuotaView configureWithCards:@[[self menuCardForProvider:@"codex" enabled:YES],
        [self menuCardForProvider:@"claude" enabled:self.hasClaudeDisplayData]]];
    _syncStateMenuItem.title = [self freshnessText];
    _syncStateMenuItem.toolTip = _syncStateMenuItem.title;
    NSString *codexName = _codexPlanName.length ? [@"Codex · " stringByAppendingString:_codexPlanName] : @"Codex";
    NSString *claudeName = _claudePlanName.length ? [@"Claude · " stringByAppendingString:_claudePlanName] : @"Claude";
    _codexProviderMenuItem.title = [NSString stringWithFormat:@"%@ · %@", codexName,
        _selectedWindow ? [self percentageString:[_selectedWindow[@"remainingPercent"] doubleValue]] : @"--"];
    _claudeProviderMenuItem.title = [NSString stringWithFormat:@"%@ · %@", claudeName,
        _claudeSelectedWindow ? [self percentageString:[_claudeSelectedWindow[@"remainingPercent"] doubleValue]] : @"--"];
    _codexProviderMenuItem.toolTip = QGL(@"plan.help");
    _claudeProviderMenuItem.toolTip = QGL(@"plan.help");
    _codexProviderMenuItem.state = [_selectedProvider isEqualToString:@"codex"] ? NSControlStateValueOn : NSControlStateValueOff;
    _claudeProviderMenuItem.state = [_selectedProvider isEqualToString:@"claude"] ? NSControlStateValueOn : NSControlStateValueOff;
    _refreshMenuItem.title = QGL(@"menu.refresh");
    _statisticsMenuItem.title = QGL(@"insights.menu");
    _widgetsMenuItem.title = QGL(@"menu.desktopWidget");
    _settingsMenuItem.title = QGL(_availableUpdateVersion.length ? @"menu.settingsUpdate" : @"menu.settings");
    _providerSwitchView.settingsButton.toolTip = [_settingsMenuItem.title stringByAppendingString:@" · ⌘,"];
    [_providerSwitchView.settingsButton setAccessibilityLabel:_settingsMenuItem.title];
    _providerSwitchView.settingsButton.contentTintColor = _availableUpdateVersion.length ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    if (QGNativeWidgetAvailable()) {
        _nativeWidgetMenuItem.title = QGL(@"menu.nativeWidget");
        _nativeWidgetMenuItem.hidden = NO;
        _addWidgetMenuItem.title = QGL(@"menu.floatingWidget");
    } else {
        _nativeWidgetMenuItem.hidden = YES;
        _addWidgetMenuItem.title = QGL(@"menu.desktopWidget");
    }
    _addWidgetMenuItem.hidden = NO;
    BOOL widgetVisible = _desktopWidgetPanel.isVisible;
    _toggleWidgetMenuItem.title = widgetVisible ? QGL(@"widget.hide") : QGL(@"widget.show");
    _smallWidgetMenuItem.title = QGL(@"widget.sizeSmall");
    _mediumWidgetMenuItem.title = QGL(@"widget.sizeMedium");
    _largeWidgetMenuItem.title = QGL(@"widget.sizeLarge");
    _smallWidgetMenuItem.state = _desktopWidgetSize == QGDesktopWidgetSizeSmall
        ? NSControlStateValueOn : NSControlStateValueOff;
    _mediumWidgetMenuItem.state = _desktopWidgetSize == QGDesktopWidgetSizeMedium
        ? NSControlStateValueOn : NSControlStateValueOff;
    _largeWidgetMenuItem.state = _desktopWidgetSize == QGDesktopWidgetSizeLarge
        ? NSControlStateValueOn : NSControlStateValueOff;
    _widgetProviderMenuItem.title = QGL(@"widget.providersMenu");
    _widgetFollowMenuItem.title = QGL(@"widget.providersFollow");
    _widgetCodexMenuItem.title = QGL(@"widget.providersCodex");
    _widgetClaudeMenuItem.title = QGL(@"widget.providersClaude");
    _widgetBothMenuItem.title = QGL(@"widget.providersBoth");
    for (NSMenuItem *item in @[_widgetFollowMenuItem, _widgetCodexMenuItem,
                              _widgetClaudeMenuItem, _widgetBothMenuItem]) {
        item.state = item.tag == _desktopWidgetProviderMode ? NSControlStateValueOn : NSControlStateValueOff;
    }
    _resetWidgetPositionMenuItem.title = QGL(@"widget.resetPosition");
    _resetWidgetPositionMenuItem.enabled = widgetVisible;
    _quitMenuItem.title = [NSString stringWithFormat:QGL(@"menu.quit"), QGProductName];

    NSString *reset = hasQuota ? [self resetDescriptionForWindow:selected] : QGL(@"quota.resetUnknown");
    _statusItem.button.toolTip = [NSString stringWithFormat:@"%@ · %@ · %@", providerName, percent, reset];
    [_statusItem.button setAccessibilityLabel:[NSString stringWithFormat:QGL(@"accessibility.menu"), providerName]];
    [_statusItem.button setAccessibilityValue:[NSString stringWithFormat:QGL(@"accessibility.value"), percent, reset, self.freshnessText]];
    [self updateSettingsView];
    [self updateStatisticsView];
}

- (NSDictionary *)menuCardForProvider:(NSString *)provider enabled:(BOOL)enabled {
    BOOL claude = [provider isEqual:@"claude"];
    NSArray *windows = enabled ? (claude ? _claudeWindows : _quotaWindows) : @[];
    NSDate *lastSync = enabled ? (claude ? _claudeLastSuccessfulSync : _lastSuccessfulSync) : nil;
    QGSyncState state = claude ? _claudeSyncState : _syncState;
    BOOL stale = windows.count && (!lastSync || -lastSync.timeIntervalSinceNow > 300 || state == QGSyncStateFailed);
    NSMutableArray *entries = [NSMutableArray array];
    for (NSDictionary *window in QGOrderedFloatingWindows(windows)) {
        NSString *help = [window[@"resetsAt"] doubleValue] > 0 ? [self resetDescriptionForWindow:window] :
            QGL(claude && [_claudeSourceKind isEqual:@"desktop"] ? @"quota.resetCacheHelp" : @"quota.resetUnavailableHelp");
        [entries addObject:@{@"title": [self windowLabel:window], @"remaining": window[@"remainingPercent"],
            @"percent": [self percentageString:[window[@"remainingPercent"] doubleValue]],
            @"reset": [self menuResetTextForWindow:window], @"help": help}];
    }
    NSString *source = claude ? QGL([_claudeSourceKind isEqual:@"desktop"] ? @"sync.claudeDesktopCache" : @"sync.claudeCodeLive") : QGL(@"sync.openaiLive");
    if (state == QGSyncStateIdle) source = claude ? QGL(@"sync.cached") : (_syncDetail ?: QGL(@"sync.cached"));
    source = QGManualQuotaSource(windows) ?: source;
    if (stale && !QGHasManualQuota(windows)) source = QGL(@"widget.cached");
    NSDateFormatter *formatter = [NSDateFormatter new]; [formatter setLocalizedDateFormatFromTemplate:@"jm"];
    if (lastSync) source = [NSString stringWithFormat:@"%@ · %@", source,
        [NSString stringWithFormat:QGL(@"widget.updatedAt"), [formatter stringFromDate:lastSync]]];
    NSString *stateText = !enabled ? @"" : (state == QGSyncStateSyncing ? QGL(@"sync.syncing") :
        (state == QGSyncStateFailed ? QGL(@"sync.failed") : (stale ? QGL(@"widget.cached") : @"")));
    NSString *empty = claude ? QGL(enabled ? @"widget.claudeSyncHelp" : @"widget.claudeConnectHelp") : QGL(@"widget.noData");
    return @{@"id": provider, @"name": claude ? @"Claude" : @"Codex", @"entries": entries,
        @"plan": enabled ? ((claude ? _claudePlanName : _codexPlanName) ?: @"") : @"", @"state": stateText,
        @"source": source, @"help": (claude ? _claudeLastError : _lastError) ?: source, @"empty": empty,
        @"stale": @(stale)};
}

- (void)refreshFromMenu:(id)sender {
    if (_syncInProgress || _claudeSyncInProgress) return;
    // Keep the menu open so the spinner and each service's state are visible.
    [self refreshQuota:sender ?: _providerSwitchView.refreshButton];
    [self refreshDailyUsageForced:YES];
}

- (void)showSettings:(id)sender {
    if (sender && sender == _providerSwitchView.settingsButton) {
        [_statusMenu cancelTracking];
        dispatch_async(dispatch_get_main_queue(), ^{ [self showSettings:nil]; });
        return;
    }
    if (!_settingsWindow) {
        _settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 536, 566)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        _settingsWindow.releasedWhenClosed = NO; _settingsWindow.title = QGL(@"settings.title");
        _settingsView = [[QGSettingsView alloc] initWithFrame:NSMakeRect(0, 0, 536, 566)];
        _settingsView.actionTarget = self; _settingsWindow.contentView = _settingsView;
        [_settingsWindow center];
    }
    [self updateSettingsView]; [_settingsWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}

- (void)updateSettingsView {
    if (!_settingsView) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL claudeEnabled = [defaults boolForKey:QGClaudeEnabledKey];
    NSString *(^status)(QGSyncState, BOOL) = ^NSString *(QGSyncState state, BOOL hasData) {
        if (state == QGSyncStateSyncing) return QGL(@"sync.syncing");
        if (state == QGSyncStateFailed) return QGL(@"sync.failed");
        return QGL(hasData ? @"settings.hasData" : @"settings.noData");
    };
    NSString *updateButton = _updateInstallInProgress ? QGL(@"update.installing") :
        (_updateCheckInProgress ? QGL(@"update.checking") : (_availableUpdateVersion.length
            ? [NSString stringWithFormat:QGL(@"update.availableMenu"), [self availableUpdateLabel]] : QGL(@"menu.checkUpdates")));
    NSString *version = [NSString stringWithFormat:QGL(@"settings.version"), QGProductName,
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0.1",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"—"];
    _settingsView.configuration = @{@"displayMode": @(_displayMode), @"loginEnabled": @(QGLoginItemEnabled(QGLoginItemPath())),
        @"appearanceMode": QGAppearanceMode(), @"languageMode": QGLanguageMode(),
        @"quotaStyle": [defaults stringForKey:QGQuotaStyleKey] ?: @"bar", @"alerts": @([defaults boolForKey:QGQuotaAlertsKey]),
        @"claudeEnabled": @(claudeEnabled), @"codexStatus": status(_syncState, _quotaWindows.count > 0),
        @"claudeStatus": self.hasClaudeDisplayData ? status(_claudeSyncState, _claudeWindows.count > 0) : QGL(@"settings.notEnabled"),
        @"codexDetail": QGHasManualQuota(_quotaWindows) ? QGL(@"manual.help") : (_lastError ?: QGL(@"settings.codexSource")),
        @"claudeDetail": QGHasManualQuota(_claudeWindows) ? QGL(@"manual.help") :
            (claudeEnabled ? (_claudeLastError ?: QGL(@"settings.claudeSource")) : QGL(@"settings.claudeDisabled")),
        @"automaticUpdates": @([defaults boolForKey:QGAutomaticUpdateChecksKey]),
        @"installing": @(_updateInstallInProgress), @"updateBusy": @(_updateCheckInProgress || _updateInstallInProgress),
        @"updateButton": updateButton, @"version": version,
        @"updateStatus": QGL(_availableUpdateVersion.length ? @"settings.updateAvailable" : @"settings.updateOnDemand")};
}

- (void)showServiceHelp:(NSButton *)sender {
    NSAlert *alert = [NSAlert new]; alert.messageText = sender.tag == 1 ? @"Claude" : @"Codex";
    alert.informativeText = QGL(sender.tag == 1 ? @"settings.claudeConnectionHelp" : @"settings.codexConnectionHelp");
    [alert addButtonWithTitle:QGL(@"common.ok")]; [NSApp activateIgnoringOtherApps:YES]; [alert runModal];
}

- (void)changeQuotaStyle:(NSButton *)sender {
    if (sender.tag != 0 && sender.tag != 1) return;
    [NSUserDefaults.standardUserDefaults setObject:sender.tag == 1 ? @"ring" : @"bar" forKey:QGQuotaStyleKey];
    [self updateStatusItem];
    [self publishWidgetSnapshot];
    // This is an explicit user appearance change, not a quota polling refresh.
    [self requestNativeWidgetReload:YES];
}

- (void)changeAppearanceMode:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag > 2) return;
    NSString *mode = @[@"system", @"light", @"dark"][sender.tag];
    if ([mode isEqual:QGAppearanceMode()]) return;
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:QGAppearanceModeKey];
    QGApplyAppearanceMode();
    [_desktopWidgetView setNeedsDisplay:YES];
    [self updateDesktopWidgetAppearance];
    [self updateStatusItem];
    [self publishWidgetSnapshot];
    [self requestNativeWidgetReload:YES];
}

- (void)changeLanguageMode:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag > 2) return;
    NSString *mode = @[@"system", @"zh-Hans", @"en"][sender.tag];
    if ([mode isEqual:QGLanguageMode()]) return;
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:QGLanguageModeKey];
    [self reloadLocalizedInterface];
}

- (void)reloadLocalizedInterface {
    // Recreate controls that cached text at initialization; quota data and
    // user preferences stay untouched, so the selection applies immediately.
    if (_statusMenu) {
        _statusMenu = [self makeMenu];
        _statusItem.menu = _statusMenu;
    }
    if (_settingsWindow) {
        NSInteger page = _settingsView.tabs.selectedSegment;
        _settingsView = [[QGSettingsView alloc] initWithFrame:NSMakeRect(0, 0, 536, 566)];
        _settingsView.actionTarget = self;
        _settingsView.tabs.selectedSegment = page;
        _settingsWindow.title = QGL(@"settings.title");
        _settingsWindow.contentView = _settingsView;
    }
    if (_statisticsWindow) {
        NSInteger tab = _statisticsView.tabs.selectedSegment;
        NSInteger range = _statisticsView.range.selectedSegment;
        _statisticsView = [[QGStatisticsView alloc] initWithFrame:NSMakeRect(0, 0, 608, 552)];
        _statisticsView.recordButton.target = self; _statisticsView.recordButton.action = @selector(toggleQuotaHistory:);
        _statisticsView.clearHistoryItem.target = self;
        _statisticsView.refreshButton.target = self; _statisticsView.refreshButton.action = @selector(refreshStatistics:);
        _statisticsView.tabs.selectedSegment = tab;
        _statisticsView.range.selectedSegment = range;
        _statisticsWindow.title = QGL(@"insights.title");
        _statisticsWindow.contentView = _statisticsView;
    }
    if (_syncState == QGSyncStateFailed) _lastError = QGL(@"sync.failed");
    if (_syncState == QGSyncStateIdle) _syncDetail = QGL(QGHasManualQuota(_quotaWindows) ? @"sync.manual" : @"sync.cached");
    if (_syncState == QGSyncStateSuccess) _syncDetail = [NSString stringWithFormat:QGL(@"sync.source"), @"Codex"];
    NSString *claudeErrorKey = [NSUserDefaults.standardUserDefaults stringForKey:QGClaudeLastErrorKey];
    if (claudeErrorKey.length) _claudeLastError = QGL(claudeErrorKey);
    [self updateStatusItem];
    [self refreshDesktopWidget];
    [self publishWidgetSnapshot];
    [self requestNativeWidgetReload:YES];
}

- (void)toggleLoginItem:(NSButton *)sender {
    BOOL enabled = sender.state == NSControlStateValueOn;
    NSError *error = nil;
    if (!QGWriteLoginItem(QGLoginItemPath(), NSBundle.mainBundle.executablePath, enabled, &error)) {
        NSAlert *alert = [NSAlert new]; alert.messageText = QGL(@"settings.loginFailed");
        alert.informativeText = error.localizedDescription ?: QGL(@"settings.loginFailed");
        [alert addButtonWithTitle:QGL(@"common.ok")]; [alert runModal];
    }
    [self updateSettingsView];
}

- (void)showStatistics:(id)sender {
    (void)sender;
    if (!_statisticsWindow) {
        _statisticsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 608, 552)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        _statisticsWindow.releasedWhenClosed = NO;
        _statisticsWindow.title = QGL(@"insights.title");
        _statisticsView = [[QGStatisticsView alloc] initWithFrame:NSMakeRect(0, 0, 608, 552)];
        _statisticsView.recordButton.target = self; _statisticsView.recordButton.action = @selector(toggleQuotaHistory:);
        _statisticsView.clearHistoryItem.target = self;
        _statisticsView.refreshButton.target = self; _statisticsView.refreshButton.action = @selector(refreshStatistics:);
        _statisticsWindow.contentView = _statisticsView;
        [_statisticsWindow center];
    }
    [self updateStatisticsView];
    [_statisticsWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    if (!_usageStatsReport || !_usageStatsIncludesClaude) [self refreshDailyUsageForced:YES];
}

- (void)updateStatisticsView {
    if (!_statisticsView) return;
    _statisticsView.history = QGInsightHistory([NSUserDefaults.standardUserDefaults objectForKey:QGHistoryKey], NSDate.date.timeIntervalSince1970);
    _statisticsView.recordHistory = [NSUserDefaults.standardUserDefaults boolForKey:QGRecordHistoryKey];
    _statisticsView.quotaRefreshing = _syncInProgress || _claudeSyncInProgress;
    _statisticsView.report = _usageStatsReport; _statisticsView.loading = _usageStatsLoading;
    [_statisticsView render];
}

- (void)refreshStatistics:(id)sender {
    if (sender && _statisticsView.tabs.selectedSegment == 1) { [self refreshQuota:sender]; return; }
    [self refreshDailyUsageForced:sender != nil];
}

- (void)refreshDailyUsageForced:(BOOL)forced {
    if (_usageStatsLoading) return;
    NSTimeInterval age = _lastDailyUsageAttempt ? -_lastDailyUsageAttempt.timeIntervalSinceNow : DBL_MAX;
    if (!forced && age < 30.0 * 60.0) return;
    _lastDailyUsageAttempt = NSDate.date;
    _usageStatsLoading = YES;
    NSUInteger generation = ++self.statisticsGeneration;
    NSString *binary = self.codexBinaryPath;
    BOOL includeClaude = _statisticsWindow.isVisible;
    [self updateStatisticsView];
    __weak QGAppDelegate *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = binary ? [weakSelf readCodexResultUsingBinary:binary method:@"account/usage/read" error:nil] : nil;
        if (!weakSelf || weakSelf.statisticsGeneration != generation) return;
        NSDictionary *claudeCache = nil;
        if (includeClaude) {
            NSString *configDirectory = NSProcessInfo.processInfo.environment[@"CLAUDE_CONFIG_DIR"];
            if (!configDirectory.length) configDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@".claude"];
            claudeCache = QGReadClaudeDailyCache(configDirectory);
        }
        NSDictionary *report = QGDailyReport(result, claudeCache, NSDate.date);
        dispatch_async(dispatch_get_main_queue(), ^{
            QGAppDelegate *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.statisticsGeneration != generation) return;
            strongSelf.usageStatsLoading = NO;
            BOOL codexFailed = result == nil || (![report[@"providers"][@"codex"][@"available"] boolValue] &&
                [report[@"codexSummary"] count] == 0);
            BOOL claudeFailed = includeClaude && ![report[@"providers"][@"claude"][@"available"] boolValue];
            strongSelf.usageStatsReport = QGDailyMergeReport(report, strongSelf.usageStatsReport,
                codexFailed, claudeFailed, !includeClaude);
            strongSelf.usageStatsIncludesClaude = includeClaude;
            [strongSelf publishWidgetSnapshot];
            [strongSelf updateStatisticsView];
            if (!includeClaude && strongSelf.statisticsWindow.isVisible) [strongSelf refreshDailyUsageForced:YES];
        });
    });
}

- (void)toggleQuotaHistory:(id)sender {
    (void)sender;
    BOOL enabled = ![NSUserDefaults.standardUserDefaults boolForKey:QGRecordHistoryKey];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:QGRecordHistoryKey];
    [self updateStatusItem];
}

- (void)clearQuotaHistory:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new]; alert.messageText = QGL(@"insights.clearHistory");
    alert.informativeText = QGL(@"insights.clearHelp");
    [alert addButtonWithTitle:QGL(@"common.ok")]; [alert addButtonWithTitle:QGL(@"common.cancel")];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:QGHistoryKey];
    [self updateStatisticsView];
}

- (void)refreshNotificationPermission {
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.notificationsAllowed = settings.authorizationStatus == UNAuthorizationStatusAuthorized; });
    }];
}

- (void)toggleQuotaAlerts:(id)sender {
    (void)sender;
    if ([NSUserDefaults.standardUserDefaults boolForKey:QGQuotaAlertsKey]) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:QGQuotaAlertsKey]; [self updateStatusItem]; return;
    }
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert
        completionHandler:^(BOOL granted, NSError *error) {
            (void)error;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.notificationsAllowed = granted;
                [NSUserDefaults.standardUserDefaults setBool:granted forKey:QGQuotaAlertsKey];
                [self updateStatusItem];
                if (!granted) {
                    NSAlert *alert = [NSAlert new]; alert.messageText = QGL(@"insights.alerts");
                    alert.informativeText = QGL(@"insights.alertsDenied"); [alert runModal];
                }
            });
        }];
}

- (void)recordInsightsForProvider:(NSString *)provider windows:(NSArray *)windows observedAt:(NSDate *)observed {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    double now = NSDate.date.timeIntervalSince1970;
    if ([defaults boolForKey:QGRecordHistoryKey]) {
        NSArray *history = QGInsightAppend([defaults objectForKey:QGHistoryKey], provider, windows, observed.timeIntervalSince1970, now);
        [defaults setObject:history forKey:QGHistoryKey];
    }
    [self updateStatisticsView];
    if (![defaults boolForKey:QGQuotaAlertsKey] || !_notificationsAllowed || [_pendingQuotaAlerts containsObject:provider]) return;
    NSMutableDictionary *ledger = [[defaults dictionaryForKey:QGAlertLedgerKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSArray *events = QGInsightAlerts(ledger, provider, windows, observed.timeIntervalSince1970, now);
    if (!events.count) { [defaults setObject:ledger forKey:QGAlertLedgerKey]; return; }
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *window in events) [parts addObject:[NSString stringWithFormat:QGL(@"insights.alertBody"),
        [self windowLabel:window], [self percentageString:[window[@"remainingPercent"] doubleValue]], [self menuResetTextForWindow:window]]];
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = [NSString stringWithFormat:QGL(@"insights.alertTitle"), [provider isEqual:@"claude"] ? @"Claude" : @"Codex"];
    content.body = [parts componentsJoinedByString:@"\n"];
    [_pendingQuotaAlerts addObject:provider];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[@"quota-" stringByAppendingString:provider] content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.pendingQuotaAlerts removeObject:provider];
            if (!error) {
                // Merge only this provider; concurrent success for the other provider must survive.
                NSMutableDictionary *current = [[defaults dictionaryForKey:QGAlertLedgerKey] mutableCopy] ?: [NSMutableDictionary dictionary];
                for (NSString *key in ledger) if ([key hasPrefix:[provider stringByAppendingString:@"-"]]) current[key] = ledger[key];
                [defaults setObject:current forKey:QGAlertLedgerKey];
            }
        });
    }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center; (void)notification; completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

- (void)changeDisplayMode:(NSMenuItem *)sender {
    _displayMode = (QGDisplayMode)sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:_displayMode forKey:QGDisplayModeKey];
    [self updateStatusItem];
}

- (void)migrateLegacyDefaultsIfNeeded {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:QGWindowsKey]) return;

    NSDictionary *previous = [defaults persistentDomainForName:QGPreviousBundleID];
    NSArray *previousWindows = previous[QGWindowsKey];
    if ([previousWindows isKindOfClass:NSArray.class] && previousWindows.count) {
        [defaults setObject:previousWindows forKey:QGWindowsKey];
        NSNumber *lastSync = QGNumber(previous[QGLastSyncKey]);
        if (lastSync) [defaults setDouble:lastSync.doubleValue forKey:QGLastSyncKey];
        NSNumber *displayMode = QGNumber(previous[QGDisplayModeKey]);
        if (displayMode) [defaults setInteger:displayMode.integerValue forKey:QGDisplayModeKey];
        return;
    }

    NSDictionary *legacy = [defaults persistentDomainForName:QGLegacyBundleID];
    NSNumber *remaining = legacy[[QGLegacyPrefix stringByAppendingString:@"Remaining"]];
    if (![remaining isKindOfClass:NSNumber.class]) return;
    NSNumber *reset = legacy[[QGLegacyPrefix stringByAppendingString:@"ResetsAt"]] ?: @0;
    NSDictionary *window = @{
        @"usedPercent": @(100.0 - remaining.doubleValue),
        @"remainingPercent": remaining,
        @"resetsAt": reset,
        @"windowDurationMins": @0,
        @"kind": @"primary"
    };
    [defaults setObject:@[window] forKey:QGWindowsKey];
    NSNumber *lastSync = legacy[[QGLegacyPrefix stringByAppendingString:@"LastSuccessfulSync"]];
    if ([lastSync isKindOfClass:NSNumber.class]) [defaults setDouble:lastSync.doubleValue forKey:QGLastSyncKey];
}

- (void)restoreCachedQuota {
    [self migrateLegacyDefaultsIfNeeded];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *stored = [defaults arrayForKey:QGWindowsKey];
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (id item in stored) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *kind = [item[@"kind"] isKindOfClass:NSString.class] ? item[@"kind"] : @"primary";
        NSDictionary *window = QGNormalizedWindow(item, kind);
        if (window) [valid addObject:window];
    }
    if (valid.count) [self applyWindows:valid];
    NSTimeInterval lastSync = [defaults doubleForKey:QGLastSyncKey];
    if (lastSync > 0) _lastSuccessfulSync = [NSDate dateWithTimeIntervalSince1970:lastSync];
    if (NSDate.date.timeIntervalSince1970 - lastSync < 7 * 86400)
        _codexPlanName = QGValidatedPlanLabel([defaults objectForKey:QGCodexPlanKey]);
    NSInteger mode = [defaults integerForKey:QGDisplayModeKey];
    _displayMode = mode == QGDisplayModeCompact ? QGDisplayModeCompact : QGDisplayModeFull;
    _syncState = QGSyncStateIdle;
    if (valid.count) _syncDetail = QGL(@"sync.cached");
}

- (void)restoreCachedClaudeQuota {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (id item in [defaults arrayForKey:QGClaudeWindowsKey]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *kind = [item[@"kind"] isKindOfClass:NSString.class] ? item[@"kind"] : @"primary";
        NSDictionary *window = QGNormalizedWindow(item, kind);
        if (window) [valid addObject:window];
    }
    [self applyClaudeWindows:valid];
    NSTimeInterval lastSync = [defaults doubleForKey:QGClaudeLastSyncKey];
    if (lastSync > 0) _claudeLastSuccessfulSync = [NSDate dateWithTimeIntervalSince1970:lastSync];
    if (NSDate.date.timeIntervalSince1970 - lastSync < 7 * 86400)
        _claudePlanName = QGValidatedPlanLabel([defaults objectForKey:QGClaudePlanKey]);
    NSString *lastErrorKey = [defaults stringForKey:QGClaudeLastErrorKey];
    _claudeSyncState = lastErrorKey.length ? QGSyncStateFailed : QGSyncStateIdle;
    _claudeLastError = lastErrorKey.length ? QGL(lastErrorKey) : nil;
    NSString *provider = [defaults stringForKey:QGSelectedProviderKey];
    _selectedProvider = [provider isEqualToString:@"claude"] && self.hasClaudeDisplayData
        ? @"claude" : @"codex";
}

- (BOOL)hasClaudeDisplayData {
    return [NSUserDefaults.standardUserDefaults boolForKey:QGClaudeEnabledKey] || QGHasManualQuota(_claudeWindows);
}

- (BOOL)showingClaude { return [_selectedProvider isEqualToString:@"claude"]; }
- (NSArray<NSDictionary *> *)activeWindows { return self.showingClaude ? _claudeWindows : _quotaWindows; }
- (NSDictionary *)activeWindow { return self.showingClaude ? _claudeSelectedWindow : _selectedWindow; }
- (NSDate *)activeLastSuccessfulSync { return self.showingClaude ? _claudeLastSuccessfulSync : _lastSuccessfulSync; }
- (QGSyncState)activeSyncState { return self.showingClaude ? _claudeSyncState : _syncState; }
- (NSString *)activeLastError { return self.showingClaude ? _claudeLastError : _lastError; }

- (void)applyClaudeWindows:(NSArray<NSDictionary *> *)windows {
    _claudeWindows = [windows copy];
    _claudeSelectedWindow = _claudeWindows.firstObject;
    for (NSDictionary *window in _claudeWindows) {
        if ([window[@"remainingPercent"] doubleValue] < [_claudeSelectedWindow[@"remainingPercent"] doubleValue]) {
            _claudeSelectedWindow = window;
        }
    }
}

- (void)applyWindows:(NSArray<NSDictionary *> *)windows {
    _quotaWindows = [windows copy];
    _selectedWindow = _quotaWindows.firstObject;
    for (NSDictionary *window in _quotaWindows) {
        if ([window[@"remainingPercent"] doubleValue] < [_selectedWindow[@"remainingPercent"] doubleValue]) _selectedWindow = window;
    }
}

- (void)saveQuotaWindows:(NSArray<NSDictionary *> *)windows {
    [NSUserDefaults.standardUserDefaults setObject:windows forKey:QGWindowsKey];
}

- (void)publishWidgetSnapshot {
    [NSUserDefaults.standardUserDefaults synchronize];
    NSDictionary *dailyUsage = QGDailyWidgetPayload(_usageStatsReport, NSDate.date);
    [_widgetServer updateWithCodexWindows:_quotaWindows ?: @[]
                          codexUpdatedAt:_lastSuccessfulSync.timeIntervalSince1970
                             codexFailed:_syncState == QGSyncStateFailed
                           codexPlanName:_codexPlanName
                            claudeWindows:_claudeWindows ?: @[]
                         claudeUpdatedAt:_claudeLastSuccessfulSync.timeIntervalSince1970
                            claudeFailed:_claudeSyncState == QGSyncStateFailed
                          claudePlanName:_claudePlanName
                        selectedProvider:_selectedProvider ?: @"codex"
                             displayMode:QGWidgetProviderModeName(_desktopWidgetProviderMode)
                              quotaStyle:[NSUserDefaults.standardUserDefaults stringForKey:QGQuotaStyleKey] ?: @"bar"
                          appearanceMode:QGAppearanceMode()
                                language:QGEffectiveLanguage()
                              dailyUsage:dailyUsage
                           claudeEnabled:self.hasClaudeDisplayData
                     legacyClaudeSupport:QGNativeWidgetSupportsClaude()];
    [self refreshDesktopWidget];
    // Timestamp-only updates don't need to spend the system's reload budget.
    NSDictionary *content = @{@"codex": _quotaWindows ?: @[], @"claude": _claudeWindows ?: @[],
        @"codexPlan": _codexPlanName ?: @"", @"claudePlan": _claudePlanName ?: @"",
        @"codexFailed": @(_syncState == QGSyncStateFailed), @"claudeFailed": @(_claudeSyncState == QGSyncStateFailed),
        @"provider": _selectedProvider ?: @"codex", @"mode": @(_desktopWidgetProviderMode),
        @"quotaStyle": [NSUserDefaults.standardUserDefaults stringForKey:QGQuotaStyleKey] ?: @"bar",
        @"appearanceMode": QGAppearanceMode(), @"language": QGEffectiveLanguage(),
        @"claudeEnabled": @(self.hasClaudeDisplayData), @"dailyUsage": dailyUsage};
    if (![_lastWidgetContent isEqual:content]) {
        _lastWidgetContent = content;
        [self requestNativeWidgetReload:NO];
    }
}

- (void)requestNativeWidgetReload:(BOOL)userInitiated {
    if (!QGNativeWidgetAvailable()) return;
    if (_nativeWidgetReloadTimer.valid && !userInitiated) return;
    [_nativeWidgetReloadTimer invalidate];
    NSTimeInterval since = _lastNativeWidgetReload ? -_lastNativeWidgetReload.timeIntervalSinceNow : DBL_MAX;
    NSTimeInterval delay = userInitiated ? 0.3 : MAX(0.5, 60 - since);
    __weak QGAppDelegate *weakSelf = self;
    _nativeWidgetReloadTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        QGAppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/libQGWidgetBridge.dylib"];
        static void *bridge = NULL;
        if (!bridge) bridge = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        void (*reload)(void) = bridge ? (void (*)(void))dlsym(bridge, "QGReloadNativeWidgets") : NULL;
        if (reload) {
            reload();
            strongSelf.lastNativeWidgetReload = NSDate.date;
            NSLog(@"AgentReadout: requested native widget timeline reload");
        } else {
            NSLog(@"AgentReadout: native widget reload bridge unavailable");
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:_nativeWidgetReloadTimer forMode:NSRunLoopCommonModes];
}

- (BOOL)needsClaudeConnectionForProvider:(NSString *)provider {
    return [provider isEqual:@"claude"] && !self.hasClaudeDisplayData;
}

- (void)selectProviderButton:(NSButton *)sender {
    NSMenuItem *item = sender == _providerSwitchView.codexButton ? _codexProviderMenuItem :
        (sender == _providerSwitchView.claudeButton ? _claudeProviderMenuItem : nil);
    if (!item) return;
    if ([self needsClaudeConnectionForProvider:item.representedObject]) {
        // Only a modal consent dialog needs to end menu tracking.
        [_statusMenu cancelTracking];
        dispatch_async(dispatch_get_main_queue(), ^{ [self selectProvider:item]; });
    } else {
        [self selectProvider:item];
    }
}

- (void)selectProvider:(NSMenuItem *)sender {
    NSString *provider = sender.representedObject;
    if (![provider isEqualToString:@"codex"] && ![provider isEqualToString:@"claude"]) return;
    if ([self needsClaudeConnectionForProvider:provider]) {
        [self toggleClaudeConnection:nil];
        if (![NSUserDefaults.standardUserDefaults boolForKey:QGClaudeEnabledKey]) return;
    }
    if ([_selectedProvider isEqual:provider]) { [self updateStatusItem]; return; }
    _selectedProvider = provider;
    [NSUserDefaults.standardUserDefaults setObject:provider forKey:QGSelectedProviderKey];
    [self publishWidgetSnapshot];
    [self requestNativeWidgetReload:YES];
    [self updateStatusItem];
    if ([provider isEqualToString:@"claude"] && [NSUserDefaults.standardUserDefaults boolForKey:QGClaudeEnabledKey]) {
        [self refreshClaudeQuotaForced:NO];
    }
}

- (void)toggleClaudeConnection:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:QGClaudeEnabledKey]) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = QGL(@"claude.connectTitle");
    alert.informativeText = QGL(@"claude.connectBody");
    [alert addButtonWithTitle:QGL(@"claude.connectButton")];
    [alert addButtonWithTitle:QGL(@"common.cancel")];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [defaults setBool:YES forKey:QGClaudeEnabledKey];
    [self publishWidgetSnapshot];
    [self refreshClaudeQuotaForced:YES];
    [self updateStatusItem];
}

- (NSArray<NSString *> *)codexBinaryCandidates {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *bundleID in @[@"com.openai.codex", @"com.openai.chatgpt"]) {
        NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
        if (appURL) [paths addObject:[[appURL path] stringByAppendingPathComponent:@"Contents/Resources/codex"]];
    }
    NSString *userApplications = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
    [paths addObjectsFromArray:@[
        @"/Applications/Codex.app/Contents/Resources/codex",
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        [userApplications stringByAppendingPathComponent:@"Codex.app/Contents/Resources/codex"],
        [userApplications stringByAppendingPathComponent:@"ChatGPT.app/Contents/Resources/codex"],
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex",
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/codex"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".npm-global/bin/codex"]
    ]];
    return [[NSOrderedSet orderedSetWithArray:paths] array];
}

- (NSString *)codexBinaryPath {
    for (NSString *path in self.codexBinaryCandidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

- (void)refreshQuota:(id)sender {
    if ([NSUserDefaults.standardUserDefaults boolForKey:QGClaudeEnabledKey]) {
        [self refreshClaudeQuotaForced:sender != nil];
    }
    if (_syncInProgress) return;
    _syncInProgress = YES;
    _syncState = QGSyncStateSyncing;
    _lastError = nil;
    [self updateStatusItem];
    NSString *binary = self.codexBinaryPath;
    if (!binary) {
        [self finishSyncWithQuota:nil error:QGL(@"error.codexNotFound")];
        if (sender) [self requestNativeWidgetReload:YES];
        return;
    }

    __weak QGAppDelegate *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *errorMessage = nil;
        NSDictionary *quota = [weakSelf readQuotaUsingBinary:binary error:&errorMessage];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishSyncWithQuota:quota error:errorMessage];
            if (sender) [weakSelf requestNativeWidgetReload:YES];
        });
    });
}

- (void)refreshClaudeQuotaForced:(BOOL)forced {
    if (![NSUserDefaults.standardUserDefaults boolForKey:QGClaudeEnabledKey] || _claudeSyncInProgress) return;
    NSTimeInterval age = _claudeLastAttempt ? -_claudeLastAttempt.timeIntervalSinceNow : DBL_MAX;
    if (!forced && age < 5.0 * 60.0) return;
    _claudeLastAttempt = NSDate.date;
    _claudeSyncInProgress = YES;
    _claudeSyncState = QGSyncStateSyncing;
    _claudeLastError = nil;
    [self updateStatusItem];
    __weak QGAppDelegate *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *errorKey = nil;
        NSDictionary *quota = QGReadClaudeQuota(&errorKey);
        dispatch_async(dispatch_get_main_queue(), ^{
            QGAppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.claudeSyncInProgress = NO;
            if (![NSUserDefaults.standardUserDefaults boolForKey:QGClaudeEnabledKey]) return;
            if (quota) {
                [strongSelf applyClaudeWindows:quota[@"windows"]];
                strongSelf.claudePlanName = QGValidatedPlanLabel(quota[@"planName"]);
                [NSUserDefaults.standardUserDefaults setObject:strongSelf.claudePlanName forKey:QGClaudePlanKey];
                NSTimeInterval updatedAt = [quota[@"updatedAt"] doubleValue];
                strongSelf.claudeLastSuccessfulSync = updatedAt > 0
                    ? [NSDate dateWithTimeIntervalSince1970:updatedAt] : NSDate.date;
                NSString *fallbackErrorKey = quota[@"fallbackErrorKey"];
                strongSelf.claudeSyncState = fallbackErrorKey.length ? QGSyncStateFailed : QGSyncStateSuccess;
                strongSelf.claudeLastError = fallbackErrorKey.length ? QGL(fallbackErrorKey) : nil;
                if (fallbackErrorKey.length) [NSUserDefaults.standardUserDefaults setObject:fallbackErrorKey forKey:QGClaudeLastErrorKey];
                else [NSUserDefaults.standardUserDefaults removeObjectForKey:QGClaudeLastErrorKey];
                strongSelf.claudeSourceKind = [quota[@"bucket"] isEqualToString:@"Claude Desktop"]
                    ? @"desktop" : @"anthropic";
                [NSUserDefaults.standardUserDefaults setObject:strongSelf.claudeWindows forKey:QGClaudeWindowsKey];
                [NSUserDefaults.standardUserDefaults setDouble:strongSelf.claudeLastSuccessfulSync.timeIntervalSince1970
                                                        forKey:QGClaudeLastSyncKey];
                [strongSelf recordInsightsForProvider:@"claude" windows:strongSelf.claudeWindows observedAt:strongSelf.claudeLastSuccessfulSync];
            } else {
                strongSelf.claudeSyncState = QGSyncStateFailed;
                NSString *failureKey = errorKey ?: @"error.claudeUnavailable";
                strongSelf.claudeLastError = QGL(failureKey);
                [NSUserDefaults.standardUserDefaults setObject:failureKey forKey:QGClaudeLastErrorKey];
            }
            [strongSelf publishWidgetSnapshot];
            if (forced) [strongSelf requestNativeWidgetReload:YES];
            [strongSelf updateStatusItem];
        });
    });
}

- (NSDictionary *)readQuotaUsingBinary:(NSString *)binary error:(NSString **)errorMessage {
    NSDictionary *result = [self readCodexResultUsingBinary:binary method:@"account/rateLimits/read" error:errorMessage];
    return result ? QGQuotaFromResult(result) : nil;
}

- (NSDictionary *)readCodexResultUsingBinary:(NSString *)binary method:(NSString *)method error:(NSString **)errorMessage {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:binary];
    task.arguments = @[@"app-server", @"--stdio"];
    NSPipe *input = [NSPipe pipe];
    NSPipe *output = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;

    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    NSObject *stateLock = [NSObject new];
    NSMutableData *pending = [NSMutableData data];
    __block NSDictionary *resultQuota = nil;
    __block NSString *resultError = nil;
    __block BOOL finished = NO;
    __block BOOL requestSent = NO;

    void (^finish)(NSDictionary *, NSString *) = ^(NSDictionary *quota, NSString *failure) {
        BOOL shouldSignal = NO;
        @synchronized (stateLock) {
            if (!finished) {
                finished = YES;
                resultQuota = quota;
                resultError = failure;
                shouldSignal = YES;
            }
        }
        if (shouldSignal) dispatch_semaphore_signal(completed);
    };

    output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *chunk = handle.availableData;
        if (!chunk.length) {
            finish(nil, QGL(@"error.noQuotaData"));
            return;
        }
        NSMutableArray<NSDictionary *> *messages = [NSMutableArray array];
        @synchronized (stateLock) {
            [pending appendData:chunk];
            while (pending.length) {
                const uint8_t *bytes = pending.bytes;
                NSUInteger newlineIndex = NSNotFound;
                for (NSUInteger index = 0; index < pending.length; index++) {
                    if (bytes[index] == '\n') {
                        newlineIndex = index;
                        break;
                    }
                }
                if (newlineIndex == NSNotFound) break;
                NSData *lineData = [pending subdataWithRange:NSMakeRange(0, newlineIndex)];
                [pending replaceBytesInRange:NSMakeRange(0, newlineIndex + 1)
                                   withBytes:NULL
                                      length:0];
                if (!lineData.length) continue;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
                if ([json isKindOfClass:NSDictionary.class]) [messages addObject:json];
            }
        }
        for (NSDictionary *json in messages) {
            if (QGIDEquals(json[@"id"], 1) && [json[@"result"] isKindOfClass:NSDictionary.class] && !requestSent) {
                requestSent = YES;
                NSData *requestData = [NSJSONSerialization dataWithJSONObject:@{@"method": method, @"id": @2} options:0 error:nil];
                NSString *request = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
                request = [@"{\"method\":\"initialized\",\"params\":{}}\n" stringByAppendingFormat:@"%@\n", request];
                @try {
                    [input.fileHandleForWriting writeData:[request dataUsingEncoding:NSUTF8StringEncoding]];
                } @catch (__unused NSException *exception) {
                    finish(nil, QGL(@"error.connectionClosed"));
                }
                continue;
            }
            if (QGIDEquals(json[@"id"], 2)) {
                if ([json[@"result"] isKindOfClass:NSDictionary.class]) {
                    finish(json[@"result"], nil);
                } else {
                    finish(nil, QGL(@"error.noQuotaData"));
                }
            }
        }
    };

    task.terminationHandler = ^(NSTask *terminatedTask) {
        (void)terminatedTask;
        finish(nil, QGL(@"error.connectionClosed"));
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        output.fileHandleForReading.readabilityHandler = nil;
        if (errorMessage) *errorMessage = launchError.localizedDescription ?: QGL(@"error.launchFailed");
        return nil;
    }

    NSString *initialize = @"{\"method\":\"initialize\",\"id\":1,\"params\":{\"clientInfo\":{\"name\":\"agentreadout\",\"title\":\"AgentReadout\",\"version\":\"2.0\"},\"capabilities\":null}}\n";
    @try {
        [input.fileHandleForWriting writeData:[initialize dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *exception) {
        finish(nil, QGL(@"error.connectionClosed"));
    }

    long waitResult = dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if (waitResult != 0) finish(nil, QGL(@"error.timeout"));
    output.fileHandleForReading.readabilityHandler = nil;
    @try { [input.fileHandleForWriting closeFile]; } @catch (__unused NSException *exception) {}
    if (task.running) [task terminate];
    if (errorMessage) *errorMessage = resultError ?: (resultQuota ? nil : QGL(@"error.noQuotaData"));
    return resultQuota;
}

- (void)finishSyncWithQuota:(NSDictionary *)quota error:(NSString *)errorMessage {
    _syncInProgress = NO;
    if (quota) {
        [self applyWindows:quota[@"windows"]];
        _codexPlanName = QGValidatedPlanLabel(quota[@"planName"]);
        [NSUserDefaults.standardUserDefaults setObject:_codexPlanName forKey:QGCodexPlanKey];
        _syncState = QGSyncStateSuccess;
        _syncDetail = [NSString stringWithFormat:QGL(@"sync.source"), quota[@"bucket"] ?: @"Codex"];
        _lastSuccessfulSync = NSDate.date;
        _lastError = nil;
        [self saveQuotaWindows:_quotaWindows];
        [NSUserDefaults.standardUserDefaults setDouble:_lastSuccessfulSync.timeIntervalSince1970 forKey:QGLastSyncKey];
        [self recordInsightsForProvider:@"codex" windows:_quotaWindows observedAt:_lastSuccessfulSync];
    } else {
        _syncState = QGSyncStateFailed;
        _lastError = errorMessage ?: QGL(@"sync.failed");
    }
    [self publishWidgetSnapshot];
    [self updateStatusItem];
}

- (void)editQuota:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = QGL(@"manual.title");
    alert.informativeText = QGL(@"manual.help");
    [alert addButtonWithTitle:QGL(@"common.save")];
    [alert addButtonWithTitle:QGL(@"common.cancel")];

    QGManualQuotaView *form = [[QGManualQuotaView alloc] initWithProvider:_selectedProvider
        windows:@{@"codex": _quotaWindows ?: @[], @"claude": _claudeWindows ?: @[]}];
    alert.accessoryView = form;

    [NSApp activateIgnoringOtherApps:YES];
    while ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *error = nil;
        NSDictionary *window = [form windowAtDate:NSDate.date error:&error];
        if (!window) {
            NSBeep();
            alert.informativeText = error;
            continue;
        }
        [self saveManualWindow:window provider:form.provider preferences:NSUserDefaults.standardUserDefaults];
        break;
    }
}

- (void)saveManualWindow:(NSDictionary *)window provider:(NSString *)provider preferences:(NSUserDefaults *)defaults {
    if (![provider isEqual:@"codex"] && ![provider isEqual:@"claude"]) return;
    if (![window[@"manual"] boolValue]) return;
    NSDate *now = NSDate.date;
    if ([provider isEqual:@"claude"]) {
        [self applyClaudeWindows:QGReplacingQuotaPeriod(_claudeWindows, window)];
        _claudeLastSuccessfulSync = now;
        _claudeLastError = nil; _claudeSyncState = QGSyncStateIdle;
        [defaults removeObjectForKey:QGClaudeLastErrorKey];
        [defaults setObject:_claudeWindows forKey:QGClaudeWindowsKey];
        [defaults setDouble:now.timeIntervalSince1970 forKey:QGClaudeLastSyncKey];
        // Do not enable Claude credential access just to show user-entered data.
    } else {
        [self applyWindows:QGReplacingQuotaPeriod(_quotaWindows, window)];
        _lastSuccessfulSync = now;
        _lastError = nil; _syncState = QGSyncStateIdle; _syncDetail = QGL(@"sync.manual");
        [defaults setObject:_quotaWindows forKey:QGWindowsKey];
        [defaults setDouble:now.timeIntervalSince1970 forKey:QGLastSyncKey];
    }
    // Manual edits neither alter verified membership nor append usage/history samples.
    [self publishWidgetSnapshot];
    [self requestNativeWidgetReload:YES];
    [self updateStatusItem];
}

- (NSSize)desktopWidgetWindowSize {
    return QGFloatingWidgetSize(_desktopWidgetSize);
}

- (NSRect)defaultDesktopWidgetFrame {
    NSSize size = [self desktopWidgetWindowSize];
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    return NSMakeRect(NSMaxX(visible) - size.width - 28.0,
                      NSMaxY(visible) - size.height - 34.0,
                      size.width, size.height);
}

- (BOOL)desktopWidgetFrameIsUsable:(NSRect)frame {
    if (frame.size.width < 100 || frame.size.height < 100) return NO;
    for (NSScreen *screen in NSScreen.screens) {
        NSRect intersection = NSIntersectionRect(frame, screen.visibleFrame);
        if (NSWidth(intersection) >= 60 && NSHeight(intersection) >= 60) return YES;
    }
    return NO;
}

- (NSRect)constrainedDesktopWidgetFrame:(NSRect)frame {
    NSScreen *bestScreen = _desktopWidgetPanel.screen ?: NSScreen.mainScreen;
    CGFloat bestArea = 0;
    for (NSScreen *screen in NSScreen.screens) {
        NSRect intersection = NSIntersectionRect(frame, screen.visibleFrame);
        CGFloat area = NSWidth(intersection) * NSHeight(intersection);
        if (area > bestArea) { bestScreen = screen; bestArea = area; }
    }
    return bestScreen ? QGConstrainWidgetFrame(frame, bestScreen.visibleFrame) : frame;
}

- (void)configureDesktopWidgetIfNeeded {
    if (_desktopWidgetPanel) return;
    NSSize size = [self desktopWidgetWindowSize];
    NSRect frame = [self defaultDesktopWidgetFrame];
    NSString *savedFrame = [NSUserDefaults.standardUserDefaults stringForKey:QGDesktopWidgetFrameKey];
    if (savedFrame.length) {
        NSRect candidate = NSRectFromString(savedFrame);
        candidate.origin.x = NSMaxX(candidate) - size.width;
        candidate.origin.y = NSMaxY(candidate) - size.height;
        candidate.size = size;
        if ([self desktopWidgetFrameIsUsable:candidate]) frame = candidate;
    }
    frame = [self constrainedDesktopWidgetFrame:frame];

    _desktopWidgetPanel = [[NSPanel alloc] initWithContentRect:frame
                                                     styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                       backing:NSBackingStoreBuffered defer:NO];
    _desktopWidgetPanel.delegate = self;
    _desktopWidgetPanel.opaque = NO;
    _desktopWidgetPanel.backgroundColor = NSColor.clearColor;
    _desktopWidgetPanel.hasShadow = NO;
    _desktopWidgetPanel.movableByWindowBackground = YES;
    _desktopWidgetPanel.hidesOnDeactivate = NO;
    _desktopWidgetPanel.releasedWhenClosed = NO;
    _desktopWidgetPanel.excludedFromWindowsMenu = YES;
    _desktopWidgetPanel.level = (NSWindowLevel)(CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) + 1);
    _desktopWidgetPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    container.wantsLayer = YES;
    container.layer.cornerRadius = 24.0;
    container.layer.masksToBounds = YES;
    _desktopWidgetPanel.contentView = container;

    _desktopWidgetEffectView = [[NSVisualEffectView alloc] initWithFrame:container.bounds];
    _desktopWidgetEffectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _desktopWidgetEffectView.material = NSVisualEffectMaterialUnderWindowBackground;
    _desktopWidgetEffectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _desktopWidgetEffectView.state = NSVisualEffectStateActive;
    [container addSubview:_desktopWidgetEffectView];

    _desktopWidgetView = [[QGDesktopWidgetView alloc] initWithFrame:container.bounds];
    _desktopWidgetView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _desktopWidgetView.medium = _desktopWidgetSize == QGDesktopWidgetSizeMedium;
    _desktopWidgetView.large = _desktopWidgetSize == QGDesktopWidgetSizeLarge;
    _desktopWidgetView.emptyText = QGL(@"widget.noData");
    [_desktopWidgetView setAccessibilityLabel:QGL(@"widget.accessibility")];
    [container addSubview:_desktopWidgetView];
    [self updateDesktopWidgetAppearance];
    [self refreshDesktopWidget];
}

- (void)showDesktopWidget:(id)sender {
    (void)sender;
    [self configureDesktopWidgetIfNeeded];
    [_desktopWidgetPanel orderFront:nil];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:QGDesktopWidgetVisibleKey];
    [self updateDesktopWidgetAppearance];
    [self refreshDesktopWidget];
}

- (void)hideDesktopWidget:(id)sender {
    (void)sender;
    [_desktopWidgetPanel orderOut:nil];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:QGDesktopWidgetVisibleKey];
}

- (void)toggleDesktopWidget:(id)sender {
    if (_desktopWidgetPanel.isVisible) [self hideDesktopWidget:sender];
    else [self showDesktopWidget:sender];
}

- (void)changeDesktopWidgetSize:(NSMenuItem *)sender {
    if (sender.tag < QGDesktopWidgetSizeSmall || sender.tag > QGDesktopWidgetSizeLarge) return;
    QGDesktopWidgetSize newSize = (QGDesktopWidgetSize)sender.tag;
    if (_desktopWidgetSize == newSize && _desktopWidgetPanel) {
        [self showDesktopWidget:nil];
        return;
    }
    _desktopWidgetSize = newSize;
    [NSUserDefaults.standardUserDefaults setInteger:newSize forKey:QGDesktopWidgetSizeKey];
    [self configureDesktopWidgetIfNeeded];
    NSRect oldFrame = _desktopWidgetPanel.frame;
    NSSize size = [self desktopWidgetWindowSize];
    NSRect newFrame = NSMakeRect(NSMinX(oldFrame), NSMaxY(oldFrame) - size.height, size.width, size.height);
    if (![self desktopWidgetFrameIsUsable:newFrame]) newFrame = [self defaultDesktopWidgetFrame];
    newFrame = [self constrainedDesktopWidgetFrame:newFrame];
    _desktopWidgetView.medium = newSize == QGDesktopWidgetSizeMedium;
    _desktopWidgetView.large = newSize == QGDesktopWidgetSizeLarge;
    [_desktopWidgetPanel setFrame:newFrame display:YES animate:YES];
    [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(newFrame) forKey:QGDesktopWidgetFrameKey];
    [self showDesktopWidget:nil];
}

- (void)changeDesktopWidgetProviderMode:(NSMenuItem *)sender {
    if (sender.tag < QGDesktopWidgetProviderModeFollow || sender.tag > QGDesktopWidgetProviderModeBoth) return;
    _desktopWidgetProviderMode = (QGDesktopWidgetProviderMode)sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:_desktopWidgetProviderMode forKey:QGDesktopWidgetProviderModeKey];
    [self publishWidgetSnapshot];
    [self requestNativeWidgetReload:YES];
    [self updateStatusItem];
    BOOL needsNewNativeWidget = QGNativeWidgetAvailable() &&
        ((_desktopWidgetProviderMode == QGDesktopWidgetProviderModeBoth && !QGNativeWidgetSupportsDualProvider()) ||
         (_desktopWidgetProviderMode == QGDesktopWidgetProviderModeClaude && !QGNativeWidgetSupportsClaude()));
    if (needsNewNativeWidget) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = QGL(@"widget.nativeNeedsUpdateTitle");
        alert.informativeText = QGL(@"widget.nativeNeedsUpdateBody");
        [alert addButtonWithTitle:QGL(@"common.ok")];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
    }
}

- (void)resetDesktopWidgetPosition:(id)sender {
    (void)sender;
    [self configureDesktopWidgetIfNeeded];
    NSRect frame = [self defaultDesktopWidgetFrame];
    [_desktopWidgetPanel setFrame:frame display:YES animate:YES];
    [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(frame) forKey:QGDesktopWidgetFrameKey];
    [self showDesktopWidget:nil];
}

- (void)windowDidMove:(NSNotification *)notification {
    if (notification.object != _desktopWidgetPanel) return;
    [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(_desktopWidgetPanel.frame)
                                            forKey:QGDesktopWidgetFrameKey];
}

- (void)updateDesktopWidgetAppearance {
    if (!_desktopWidgetPanel) return;
    NSString *frontmostID = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.lowercaseString;
    BOOL desktopFocused = [frontmostID isEqualToString:@"com.apple.finder"];
    _desktopWidgetView.desktopFocused = desktopFocused;
    BOOL reduceTransparency = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    if (!desktopFocused && !reduceTransparency) {
        _desktopWidgetView.prefersLightText = QGWallpaperPrefersLightText(_desktopWidgetPanel.screen,
                                                                        [_desktopWidgetView usesDarkWidgetAppearance]);
    }
    _desktopWidgetEffectView.alphaValue = (desktopFocused || reduceTransparency) ? 0.0 : 0.12;
}

- (NSDictionary *)largeFloatingProviderModel:(NSString *)provider enabled:(BOOL)enabled {
    BOOL claude = [provider isEqualToString:@"claude"];
    NSArray *windows = enabled ? (claude ? _claudeWindows : _quotaWindows) : @[];
    NSDate *lastSync = enabled ? (claude ? _claudeLastSuccessfulSync : _lastSuccessfulSync) : nil;
    QGSyncState state = claude ? _claudeSyncState : _syncState;
    BOOL stale = windows.count && (!lastSync || -lastSync.timeIntervalSinceNow > 300 || state == QGSyncStateFailed);
    NSDateFormatter *timeFormatter = [NSDateFormatter new];
    timeFormatter.locale = NSLocale.currentLocale;
    [timeFormatter setLocalizedDateFormatFromTemplate:@"jm"];
    NSString *updated = lastSync ? [NSString stringWithFormat:QGL(@"widget.updatedAt"),
                                   [timeFormatter stringFromDate:lastSync]] : @"";
    if (stale) updated = updated.length ? [NSString stringWithFormat:@"%@ · %@", QGL(@"widget.cached"), updated]
                                        : QGL(@"widget.cached");
    NSDateFormatter *dateFormatter = [NSDateFormatter new];
    dateFormatter.locale = NSLocale.currentLocale;
    [dateFormatter setLocalizedDateFormatFromTemplate:@"yMdjm"];
    NSDateFormatter *shortFormatter = [NSDateFormatter new];
    shortFormatter.locale = NSLocale.currentLocale;
    [shortFormatter setLocalizedDateFormatFromTemplate:@"Mdjm"];
    NSMutableArray *models = [NSMutableArray array];
    for (NSDictionary *window in QGOrderedFloatingWindows(windows)) {
        NSTimeInterval resetAt = [window[@"resetsAt"] doubleValue];
        NSTimeInterval remaining = resetAt - NSDate.date.timeIntervalSince1970;
        NSString *reset = resetAt <= 0 ? QGL(@"quota.resetUnknown")
            : remaining <= 0 ? QGL(@"quota.awaitingRefreshShort")
            : [NSString stringWithFormat:QGL(@"widget.resetIn"), [self relativeDuration:remaining maximumUnits:2]];
        [models addObject:@{
            @"label": [self windowLabel:window],
            @"percent": window[@"remainingPercent"] ?: @0,
            @"percentText": [self percentageString:[window[@"remainingPercent"] doubleValue]],
            @"resetText": reset,
            @"compactResetText": resetAt > 0 ? (remaining > 0
                ? [shortFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:resetAt]] : reset) : @"",
            // The provider header already contains the update time. Do not repeat it here.
            @"exactResetText": resetAt > 0 ? [dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:resetAt]] : @""
        }];
    }
    NSString *empty = claude ? (enabled ? QGL(@"widget.claudeSyncHelp") : QGL(@"widget.claudeConnectHelp"))
                            : QGL(@"widget.noData");
    return @{@"id": provider, @"name": claude ? @"Claude" : @"Codex", @"windows": models,
             @"planName": enabled ? ((claude ? _claudePlanName : _codexPlanName) ?: @"") : @"",
             @"updatedText": updated, @"stale": @(stale), @"emptyText": empty,
             @"emptyTitle": claude && !enabled ? QGL(@"widget.connectClaudeShort") : QGL(@"widget.noQuotaShort")};
}

- (void)refreshDesktopWidget {
    if (!_desktopWidgetView) return;
    _desktopWidgetView.usesBars = ![[NSUserDefaults.standardUserDefaults stringForKey:QGQuotaStyleKey] isEqual:@"ring"];
    BOOL claudeEnabled = self.hasClaudeDisplayData;
    if (_desktopWidgetSize == QGDesktopWidgetSizeLarge) {
        BOOL claude = _desktopWidgetProviderMode == QGDesktopWidgetProviderModeClaude ||
            (_desktopWidgetProviderMode == QGDesktopWidgetProviderModeFollow && self.showingClaude);
        NSArray *providers = _desktopWidgetProviderMode == QGDesktopWidgetProviderModeBoth
            ? @[@"codex", @"claude"] : @[claude ? @"claude" : @"codex"];
        NSMutableArray *models = [NSMutableArray array];
        NSMutableArray *accessible = [NSMutableArray arrayWithObject:QGL(@"widget.titleRemaining")];
        BOOL stale = NO;
        for (NSString *provider in providers) {
            NSDictionary *model = [self largeFloatingProviderModel:provider enabled:![provider isEqualToString:@"claude"] || claudeEnabled];
            [models addObject:model];
            stale |= [model[@"stale"] boolValue];
            [accessible addObject:model[@"name"]];
            [accessible addObject:model[@"planName"]];
            [accessible addObject:model[@"updatedText"]];
            if (![model[@"windows"] count]) [accessible addObject:model[@"emptyText"]];
            for (NSDictionary *window in model[@"windows"]) {
                [accessible addObjectsFromArray:@[window[@"label"], window[@"percentText"], window[@"resetText"], window[@"exactResetText"]]];
            }
        }
        _desktopWidgetView.providerModels = models;
        _desktopWidgetView.titleText = QGL(@"widget.titleRemaining");
        _desktopWidgetView.stale = stale;
        NSString *description = [accessible componentsJoinedByString:@" · "];
        _desktopWidgetView.toolTip = description;
        [_desktopWidgetView setAccessibilityLabel:description];
        return;
    }
    [_desktopWidgetView setAccessibilityLabel:QGL(@"widget.accessibility")];
    if (_desktopWidgetProviderMode == QGDesktopWidgetProviderModeBoth) {
        _desktopWidgetView.providerModels = @[[self largeFloatingProviderModel:@"codex" enabled:YES],
            [self largeFloatingProviderModel:@"claude" enabled:claudeEnabled]];
        NSMutableArray<NSDictionary *> *models = [NSMutableArray arrayWithCapacity:2];
        BOOL anyStale = NO;
        for (NSString *provider in @[@"codex", @"claude"]) {
            BOOL claude = [provider isEqualToString:@"claude"];
            NSDictionary *window = claude ? (claudeEnabled ? _claudeSelectedWindow : nil) : _selectedWindow;
            NSString *name = claude ? @"Claude" : @"Codex";
            NSString *label = window ? [NSString stringWithFormat:@"%@ · %@", name, [self windowLabel:window]] : name;
            NSString *reset = window ? [self compactResetTextForWindow:window] : @"";
            if (!reset.length) {
                reset = !window ? (claude ? (claudeEnabled ? QGL(@"widget.noQuotaShort")
                                                         : QGL(@"widget.connectClaudeShort"))
                                          : QGL(@"widget.codexUnavailableShort"))
                                : QGL(@"quota.resetUnknown");
            }
            [models addObject:@{
                @"label": label,
                @"provider": name,
                @"providerID": provider,
                @"planName": (claude ? (claudeEnabled ? _claudePlanName : nil) : _codexPlanName) ?: @"",
                @"period": window ? [self windowLabel:window] : @"",
                @"percent": window[@"remainingPercent"] ?: @0,
                @"hasQuota": @(window != nil),
                @"percentText": window ? [self percentageString:[window[@"remainingPercent"] doubleValue]] : @"--%",
                @"exactResetText": reset
            }];
            NSDate *lastSync = claude ? _claudeLastSuccessfulSync : _lastSuccessfulSync;
            QGSyncState state = claude ? _claudeSyncState : _syncState;
            if (window && (!lastSync || -lastSync.timeIntervalSinceNow > 300.0 || state == QGSyncStateFailed)) {
                anyStale = YES;
            }
        }
        _desktopWidgetView.dualProviderMode = YES;
        _desktopWidgetView.windowModels = models;
        _desktopWidgetView.titleText = QGL(@"widget.titleBoth");
        _desktopWidgetView.emptyText = @"";
        _desktopWidgetView.stale = anyStale;
        _desktopWidgetView.toolTip = anyStale ? QGL(@"widget.cached") : nil;
        _desktopWidgetView.exactResetText = @"";
        _desktopWidgetView.freshnessText = @"";
        return;
    }

    BOOL claude = _desktopWidgetProviderMode == QGDesktopWidgetProviderModeClaude ||
        (_desktopWidgetProviderMode == QGDesktopWidgetProviderModeFollow && self.showingClaude);
    NSArray<NSDictionary *> *activeWindows = claude ? (claudeEnabled ? _claudeWindows : @[]) : _quotaWindows;
    NSDictionary *selected = claude ? (claudeEnabled ? _claudeSelectedWindow : nil) : _selectedWindow;
    NSArray<NSDictionary *> *source = nil;
    if (_desktopWidgetSize == QGDesktopWidgetSizeMedium) {
        source = [activeWindows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            double leftDuration = [left[@"windowDurationMins"] doubleValue];
            double rightDuration = [right[@"windowDurationMins"] doubleValue];
            if (leftDuration <= 0 && rightDuration > 0) return NSOrderedDescending;
            if (rightDuration <= 0 && leftDuration > 0) return NSOrderedAscending;
            if (leftDuration < rightDuration) return NSOrderedAscending;
            if (leftDuration > rightDuration) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    } else {
        source = selected ? @[selected] : @[];
    }
    NSMutableArray<NSDictionary *> *models = [NSMutableArray array];
    for (NSDictionary *window in source) {
        [models addObject:@{
            @"providerID": claude ? @"claude" : @"codex",
            @"label": [self windowLabel:window],
            @"percent": window[@"remainingPercent"] ?: @0,
            @"percentText": [self percentageString:[window[@"remainingPercent"] doubleValue]],
            @"exactResetText": [self compactResetTextForWindow:window]
        }];
        if (models.count == 2) break;
    }
    _desktopWidgetView.dualProviderMode = NO;
    _desktopWidgetView.windowModels = models;
    _desktopWidgetView.titleText = claude ? QGL(@"widget.titleClaude") : QGL(@"widget.title");
    NSString *plan = claude ? (claudeEnabled ? _claudePlanName : nil) : _codexPlanName;
    if (_desktopWidgetSize == QGDesktopWidgetSizeMedium && plan.length)
        _desktopWidgetView.titleText = [NSString stringWithFormat:@"%@ · %@", claude ? @"Claude" : @"Codex", plan];
    _desktopWidgetView.emptyText = claude ? QGL(@"widget.noDataClaude") : QGL(@"widget.noData");
    NSDate *lastSync = claude ? _claudeLastSuccessfulSync : _lastSuccessfulSync;
    QGSyncState state = claude ? _claudeSyncState : _syncState;
    _desktopWidgetView.stale = models.count > 0 &&
        (!lastSync || -lastSync.timeIntervalSinceNow > 300.0 || state == QGSyncStateFailed);
    _desktopWidgetView.toolTip = _desktopWidgetView.stale ? QGL(@"widget.cached") : nil;
    _desktopWidgetView.exactResetText = selected ? [self compactResetTextForWindow:selected] : @"";
    if (selected) {
        NSTimeInterval resetAt = [selected[@"resetsAt"] doubleValue];
        if (resetAt > NSDate.date.timeIntervalSince1970) {
            NSString *duration = [self relativeDuration:resetAt - NSDate.date.timeIntervalSince1970 maximumUnits:2];
            _desktopWidgetView.freshnessText = [NSString stringWithFormat:QGL(@"widget.resetIn"), duration];
        } else {
            _desktopWidgetView.freshnessText = claude ? QGL(@"widget.desktopCache") : QGL(@"quota.resetUnknown");
        }
    } else {
        _desktopWidgetView.freshnessText = claude && !claudeEnabled ? QGL(@"widget.connectClaudeShort") : @"";
    }
}

- (NSString *)currentVersion {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
}

- (void)toggleAutomaticUpdateChecks:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = ![defaults boolForKey:QGAutomaticUpdateChecksKey];
    [defaults setBool:enabled forKey:QGAutomaticUpdateChecksKey];
    [self updateStatusItem];
    if (enabled) [self performAutomaticUpdateCheckIfNeeded];
}

- (void)performAutomaticUpdateCheckIfNeeded {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:QGAutomaticUpdateChecksKey] || _updateCheckInProgress || _updateInstallInProgress) return;
    NSTimeInterval lastCheck = [defaults doubleForKey:QGLastUpdateCheckKey];
    if (lastCheck > 0 && NSDate.date.timeIntervalSince1970 - lastCheck < QGAutomaticUpdateInterval) return;
    [self performUpdateCheckManual:NO];
}

- (void)checkForUpdates:(id)sender {
    (void)sender;
    if (_updateCheckInProgress || _updateInstallInProgress) return;
    [self performUpdateCheckManual:YES];
}

- (NSURLRequest *)releaseRequestForURL:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 30.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:[NSString stringWithFormat:@"AgentReadout/%@", self.currentVersion]
   forHTTPHeaderField:@"User-Agent"];
    return request;
}

- (NSString *)availableUpdateLabel {
    return _availableUpdateBuild.length ? [NSString stringWithFormat:@"%@ (build %@)", _availableUpdateVersion, _availableUpdateBuild]
                                        : _availableUpdateVersion;
}

- (void)finishUpdateCheckWithRelease:(NSDictionary *)release manifest:(NSDictionary *)manifest manual:(BOOL)manual {
    _updateCheckInProgress = NO;
    [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:QGLastUpdateCheckKey];
    NSString *version = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
    if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) version = [version substringFromIndex:1];
    NSString *page = [release[@"html_url"] isKindOfClass:NSString.class] ? release[@"html_url"] : @"";
    _availableUpdateURL = page.length ? [NSURL URLWithString:page] : nil;
    NSString *build = manifest[@"build"];
    NSString *installedBuild = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"0";
    if (!version.length || !QGNewerRelease(version, build, self.currentVersion, installedBuild)) {
        _availableUpdateVersion = nil;
        _availableUpdateBuild = nil;
        _availableUpdateManifest = nil;
        [self updateStatusItem];
        if (manual) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = QGL(@"update.upToDateTitle");
            alert.informativeText = [NSString stringWithFormat:QGL(@"update.upToDateBody"),
                [NSString stringWithFormat:@"%@ (build %@)", self.currentVersion, installedBuild]];
            [alert addButtonWithTitle:QGL(@"common.ok")];
            [NSApp activateIgnoringOtherApps:YES];
            [alert runModal];
        }
        return;
    }
    _availableUpdateVersion = version;
    _availableUpdateBuild = build;
    _availableUpdateManifest = manifest;
    [self updateStatusItem];
    if (manual) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:QGL(@"update.availableTitle"), [self availableUpdateLabel]];
        alert.informativeText = QGL(@"update.availableBody");
        [alert addButtonWithTitle:QGL(@"update.install")];
        [alert addButtonWithTitle:QGL(@"update.later")];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    [self downloadAndInstallRelease:release manual:manual];
}

- (void)failUpdateCheck:(BOOL)manual {
    _updateCheckInProgress = NO;
    [self updateStatusItem];
    if (manual) [self showUpdateFailure:QGL(@"update.checkFailed") releaseURL:nil];
}

- (void)performUpdateCheckManual:(BOOL)manual {
    NSURL *url = [NSURL URLWithString:QGReleaseAPIURL];
    if (!url) return;
    _updateCheckInProgress = YES;
    [self updateStatusItem];
    __weak QGAppDelegate *weakSelf = self;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:[self releaseRequestForURL:url]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
            id object = !error && http.statusCode == 200 && data.length
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *release = [object isKindOfClass:NSDictionary.class] ? object : nil;
            if (!release) {
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failUpdateCheck:manual]; });
                return;
            }
            NSDictionary *manifestAsset = nil;
            for (id asset in [release[@"assets"] isKindOfClass:NSArray.class] ? release[@"assets"] : @[]) {
                if ([asset isKindOfClass:NSDictionary.class] && [asset[@"name"] isEqual:@"update.json"]) manifestAsset = asset;
            }
            // Older releases without a manifest retain marketing-version comparisons.
            if (!manifestAsset) {
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishUpdateCheckWithRelease:release manifest:nil manual:manual]; });
                return;
            }
            NSString *link = [manifestAsset[@"browser_download_url"] isKindOfClass:NSString.class]
                ? manifestAsset[@"browser_download_url"] : @"";
            NSURL *manifestURL = [NSURL URLWithString:link];
            if (![manifestURL.scheme isEqual:@"https"] || ![manifestURL.host isEqual:@"github.com"] ||
                ![manifestURL.path.lowercaseString hasPrefix:@"/qingtan-labs/gaugeforcodex/releases/download/"]) {
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf failUpdateCheck:manual]; });
                return;
            }
            [weakSelf fetchDataAtURL:manifestURL completion:^(NSData *manifestData, NSError *manifestError) {
                id manifest = !manifestError && manifestData.length <= 65536
                    ? [NSJSONSerialization JSONObjectWithData:manifestData ?: NSData.data options:0 error:nil] : nil;
                NSString *version = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
                if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) version = [version substringFromIndex:1];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!QGValidUpdateManifest(manifest, version)) { [weakSelf failUpdateCheck:manual]; return; }
                    [weakSelf finishUpdateCheckWithRelease:release manifest:manifest manual:manual];
                });
            }];
        }];
    [task resume];
}

- (void)fetchDataAtURL:(NSURL *)url completion:(void (^)(NSData *, NSError *))completion {
    NSMutableURLRequest *request = [[self releaseRequestForURL:url] mutableCopy];
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        if (!error && (http.statusCode < 200 || http.statusCode >= 300)) {
            error = [NSError errorWithDomain:@"GaugeForCodexUpdate" code:http.statusCode
                                    userInfo:@{NSLocalizedDescriptionKey: QGL(@"update.downloadFailed")}];
        }
        completion(data, error);
    }];
    [task resume];
}

- (NSString *)expectedSHAForFileName:(NSString *)fileName checksumData:(NSData *)data {
    return QGChecksumForFilename(fileName, data);
}

- (BOOL)runExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments error:(NSString **)message {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = errorPipe;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (message) *message = launchError.localizedDescription;
        return NO;
    }
    [task waitUntilExit];
    if (task.terminationStatus == 0) return YES;
    NSData *data = [errorPipe.fileHandleForReading readDataToEndOfFile];
    NSString *detail = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (message) *message = detail.length ? detail : QGL(@"update.validationFailed");
    return NO;
}

- (NSString *)appBundleInsideDirectory:(NSString *)directory {
    NSDirectoryEnumerator<NSString *> *items = [NSFileManager.defaultManager enumeratorAtPath:directory];
    for (NSString *relativePath in items) {
        if (![relativePath.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
        NSString *path = [directory stringByAppendingPathComponent:relativePath];
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if ([bundle.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier]) return path;
        [items skipDescendants];
    }
    return nil;
}

- (BOOL)validateUpdateAppAtPath:(NSString *)path version:(NSString *)version error:(NSString **)message {
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    NSString *bundleVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!bundle || ![bundle.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier] ||
        ![bundleVersion isEqualToString:version] ||
        (_availableUpdateBuild.length && ![[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:_availableUpdateBuild])) {
        if (message) *message = QGL(@"update.identityFailed");
        return NO;
    }
    return [self runExecutable:@"/usr/bin/codesign" arguments:@[@"--verify", @"--deep", @"--strict", path] error:message];
}

- (void)downloadAndInstallRelease:(NSDictionary *)release manual:(BOOL)manual {
    NSArray *assets = [release[@"assets"] isKindOfClass:NSArray.class] ? release[@"assets"] : @[];
    NSDictionary *zipAsset = nil;
    NSDictionary *checksumAsset = nil;
    for (NSDictionary *asset in assets) {
        if (![asset isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [asset[@"name"] isKindOfClass:NSString.class] ? asset[@"name"] : @"";
        if ([name caseInsensitiveCompare:@"SHA256SUMS"] == NSOrderedSame) checksumAsset = asset;
        if (_availableUpdateManifest) {
            if ([name isEqual:_availableUpdateManifest[@"archive"]]) zipAsset = asset;
            continue;
        }
        if ([name.lowercaseString hasSuffix:@"-universal.zip"]) zipAsset = asset;
        else if (!zipAsset && [name.lowercaseString hasSuffix:@".zip"]) zipAsset = asset;
    }
    NSString *zipName = [zipAsset[@"name"] isKindOfClass:NSString.class] ? zipAsset[@"name"] : @"";
    NSURL *zipURL = [NSURL URLWithString:[zipAsset[@"browser_download_url"] isKindOfClass:NSString.class]
                                             ? zipAsset[@"browser_download_url"] : @""];
    NSURL *checksumURL = [NSURL URLWithString:[checksumAsset[@"browser_download_url"] isKindOfClass:NSString.class]
                                                  ? checksumAsset[@"browser_download_url"] : @""];
    if (!zipURL || !checksumURL || !zipName.length || ![zipName isEqual:zipName.lastPathComponent]) {
        if (manual) [self showUpdateFailure:QGL(@"update.assetsMissing") releaseURL:_availableUpdateURL];
        return;
    }

    _updateInstallInProgress = YES;
    [self updateStatusItem];
    __weak QGAppDelegate *weakSelf = self;
    [self fetchDataAtURL:checksumURL completion:^(NSData *checksumData, NSError *checksumError) {
        if (checksumError || !checksumData.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishUpdateWithError:checksumError.localizedDescription manual:manual]; });
            return;
        }
        [weakSelf fetchDataAtURL:zipURL completion:^(NSData *zipData, NSError *zipError) {
            if (zipError || !zipData.length) {
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishUpdateWithError:zipError.localizedDescription manual:manual]; });
                return;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                QGAppDelegate *self = weakSelf;
                if (!self) return;
                NSString *expected = [self expectedSHAForFileName:zipName checksumData:checksumData];
                NSString *actualSHA = QGSHA256(zipData);
                if (!expected.length || ![expected isEqualToString:actualSHA] ||
                    (self.availableUpdateManifest && ![[self.availableUpdateManifest[@"sha256"] lowercaseString] isEqual:actualSHA])) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self finishUpdateWithError:QGL(@"update.checksumFailed") manual:manual]; });
                    return;
                }
                NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [@"GaugeForCodexUpdate-" stringByAppendingString:NSUUID.UUID.UUIDString]];
                NSError *fileError = nil;
                [NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:&fileError];
                NSString *zipPath = [temporary stringByAppendingPathComponent:zipName];
                if (fileError || ![zipData writeToFile:zipPath options:NSDataWritingAtomic error:&fileError]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self finishUpdateWithError:fileError.localizedDescription manual:manual]; });
                    return;
                }
                NSString *commandError = nil;
                if (![self runExecutable:@"/usr/bin/ditto" arguments:@[@"-x", @"-k", zipPath, temporary] error:&commandError]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self finishUpdateWithError:commandError manual:manual]; });
                    return;
                }
                NSString *replacement = [self appBundleInsideDirectory:temporary];
                if (!replacement || ![self validateUpdateAppAtPath:replacement version:self.availableUpdateVersion error:&commandError]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self finishUpdateWithError:commandError ?: QGL(@"update.validationFailed") manual:manual]; });
                    return;
                }
                NSString *target = NSBundle.mainBundle.bundlePath;
                if (![NSFileManager.defaultManager isWritableFileAtPath:target.stringByDeletingLastPathComponent]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self finishUpdateWithError:QGL(@"update.readOnlyInstall") manual:YES]; });
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self launchUpdaterWithReplacement:replacement temporaryDirectory:temporary];
                });
            });
        }];
    }];
}

- (void)launchUpdaterWithReplacement:(NSString *)replacement temporaryDirectory:(NSString *)temporary {
    NSString *helper = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/GaugeForCodexUpdater"];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:helper]) {
        [self finishUpdateWithError:QGL(@"update.helperMissing") manual:YES];
        return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:helper];
    task.arguments = @[[NSString stringWithFormat:@"%d", getpid()], NSBundle.mainBundle.bundlePath,
                       replacement, _availableUpdateVersion ?: @"", temporary, _availableUpdateBuild ?: @""];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        [self finishUpdateWithError:error.localizedDescription manual:YES];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

- (void)finishUpdateWithError:(NSString *)message manual:(BOOL)manual {
    _updateInstallInProgress = NO;
    [self updateStatusItem];
    if (manual) [self showUpdateFailure:message.length ? message : QGL(@"update.installFailed")
                             releaseURL:_availableUpdateURL];
}

- (void)showUpdateFailure:(NSString *)message releaseURL:(NSURL *)releaseURL {
    NSAlert *alert = [NSAlert new];
    alert.messageText = QGL(@"update.failedTitle");
    alert.informativeText = message.length ? message : QGL(@"update.installFailed");
    if (releaseURL) [alert addButtonWithTitle:QGL(@"update.openDownload")];
    [alert addButtonWithTitle:QGL(@"common.ok")];
    [NSApp activateIgnoringOtherApps:YES];
    if (releaseURL && [alert runModal] == NSAlertFirstButtonReturn) {
        [NSWorkspace.sharedWorkspace openURL:releaseURL];
    } else if (!releaseURL) {
        [alert runModal];
    }
}

- (void)showNativeWidgetInstructions:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = QGL(@"nativeWidget.guideTitle");
    alert.informativeText = QGNativeWidgetSupportsDualProvider() ? QGL(@"nativeWidget.guideBody")
        : [NSString stringWithFormat:@"%@\n\n%@", QGL(@"nativeWidget.guideBody"),
                                   QGL(@"widget.nativeNeedsUpdateBody")];
    [alert addButtonWithTitle:QGL(@"common.ok")];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"2.0";
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"%@ %@", QGProductName, version];
    alert.informativeText = [NSString stringWithFormat:QGL(@"about.body"), QGProductName];
    [alert addButtonWithTitle:QGL(@"common.ok")];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return QGRunSelfTests() ? 0 : 1;
        NSApplication *application = NSApplication.sharedApplication;
        QGAppDelegate *delegate = [QGAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
