#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import "QGWidgetServer.h"
#import <math.h>
#import <unistd.h>

static NSString * const QGProductName = @"Gauge for Codex";
static NSString * const QGPreviousBundleID = @"com.local.codexgauge";
static NSString * const QGLegacyBundleID = @"com.local.codex-quota-overlay";
static NSString * const QGLegacyPrefix = @"CodexQuotaOverlay";
static NSString * const QGWindowsKey = @"QuotaWindows";
static NSString * const QGLastSyncKey = @"LastSuccessfulSync";
static NSString * const QGDisplayModeKey = @"DisplayMode";
static NSString * const QGDesktopWidgetVisibleKey = @"DesktopWidgetVisible";
static NSString * const QGDesktopWidgetSizeKey = @"DesktopWidgetSize";
static NSString * const QGDesktopWidgetFrameKey = @"DesktopWidgetFrame";
static NSString * const QGAutomaticUpdateChecksKey = @"AutomaticUpdateChecks";
static NSString * const QGLastUpdateCheckKey = @"LastUpdateCheck";
static NSString * const QGReleaseAPIURL = @"https://api.github.com/repos/qingtan-labs/GaugeForCodex/releases/latest";
static NSTimeInterval const QGAutomaticUpdateInterval = 24.0 * 60.0 * 60.0;

static NSString *QGL(NSString *key) {
    return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
}

static BOOL QGNativeWidgetAvailable(void) {
    if (@available(macOS 14.0, *)) {
        NSString *extensionPath = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Contents/PlugIns/GaugeForCodexWidget.appex"];
        return [NSFileManager.defaultManager fileExistsAtPath:extensionPath];
    }
    return NO;
}

static NSNumber *QGNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double number = 0;
        if ([scanner scanDouble:&number] && scanner.isAtEnd) return @(number);
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

    double used = usedNumber ? usedNumber.doubleValue : 100.0 - remainingNumber.doubleValue;
    if (!isfinite(used)) return nil;
    used = MIN(100.0, MAX(0.0, used));

    NSNumber *resetNumber = QGNumber(dictionary[@"resetsAt"]);
    if (!resetNumber) resetNumber = QGNumber(dictionary[@"resetAt"]);
    if (!resetNumber) resetNumber = QGNumber(dictionary[@"resets_at"]);
    NSTimeInterval resetAt = resetNumber.doubleValue;
    if (resetAt > 100000000000.0) resetAt /= 1000.0;

    NSNumber *durationNumber = QGNumber(dictionary[@"windowDurationMins"]);
    if (!durationNumber) durationNumber = QGNumber(dictionary[@"windowDurationMinutes"]);
    double durationMinutes = MAX(0.0, durationNumber.doubleValue);
    NSNumber *durationSeconds = QGNumber(dictionary[@"windowDurationSeconds"]);
    if (!durationMinutes && durationSeconds) durationMinutes = MAX(0.0, durationSeconds.doubleValue / 60.0);

    return @{
        @"usedPercent": @(used),
        @"remainingPercent": @(100.0 - used),
        @"resetsAt": @(MAX(0.0, resetAt)),
        @"windowDurationMins": @(durationMinutes),
        @"kind": kind ?: @"primary"
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
    return @{
        @"windows": windows,
        @"selected": selected,
        @"remainingPercent": selected[@"remainingPercent"],
        @"resetsAt": selected[@"resetsAt"],
        @"bucket": bucketName ?: @"Codex"
    };
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
    for (NSDictionary *test in cases) {
        NSDictionary *quota = QGQuotaFromResult(test[@"input"]);
        BOOL passed = quota
            && fabs([quota[@"remainingPercent"] doubleValue] - [test[@"remaining"] doubleValue]) < 0.001
            && fabs([quota[@"resetsAt"] doubleValue] - [test[@"reset"] doubleValue]) < 0.001
            && [quota[@"windows"] count] == [test[@"windowCount"] unsignedIntegerValue];
        fprintf(stdout, "%s %s\n", passed ? "PASS" : "FAIL", [test[@"name"] UTF8String]);
        if (!passed) failures++;
    }
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
    BOOL localizationPassed = ![QGL(@"menu.refresh") isEqualToString:@"menu.refresh"];
    fprintf(stdout, "%s localization resources\n", localizationPassed ? "PASS" : "FAIL");
    if (!localizationPassed) failures++;
    fprintf(stdout, "%lu tests, %lu failures\n",
            (unsigned long)(cases.count + versionCases.count + 1), (unsigned long)failures);
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
    QGDesktopWidgetSizeMedium
};

@interface QGStatusContentView : NSView
@property (copy, nonatomic) NSString *displayText;
@property (nonatomic) double remainingPercent;
@property (nonatomic) BOOL hasQuota;
@property (nonatomic) BOOL showProgress;
@property (nonatomic) BOOL stale;
@end

@implementation QGStatusContentView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)setDisplayText:(NSString *)displayText { _displayText = [displayText copy]; [self setNeedsDisplay:YES]; }
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
    NSSize textSize = [text sizeWithAttributes:attributes];
    CGFloat textAreaHeight = NSHeight(self.bounds) - (_showProgress ? 4.5 : 0.0);
    CGFloat textX = floor((NSWidth(self.bounds) - textSize.width) / 2.0);
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
@property (nonatomic, copy) NSString *freshnessText;
@property (nonatomic, copy) NSString *exactResetText;
@property (nonatomic, copy) NSString *emptyText;
@property (nonatomic) BOOL medium;
@property (nonatomic) BOOL desktopFocused;
@property (nonatomic) BOOL stale;
@end

@implementation QGDesktopWidgetView
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)setWindowModels:(NSArray<NSDictionary *> *)value { _windowModels = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setFreshnessText:(NSString *)value { _freshnessText = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setExactResetText:(NSString *)value { _exactResetText = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setEmptyText:(NSString *)value { _emptyText = [value copy]; [self setNeedsDisplay:YES]; }
- (void)setMedium:(BOOL)value { _medium = value; [self setNeedsDisplay:YES]; }
- (void)setDesktopFocused:(BOOL)value { _desktopFocused = value; [self setNeedsDisplay:YES]; }
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
    return [self usesDarkWidgetAppearance] ? NSColor.whiteColor
        : [NSColor colorWithSRGBRed:0.08 green:0.14 blue:0.12 alpha:1.0];
}

- (NSColor *)secondaryTextColor {
    if ([self usesSystemWidgetSurface]) return NSColor.secondaryLabelColor;
    return [self usesDarkWidgetAppearance] ? [NSColor.whiteColor colorWithAlphaComponent:0.94]
        : [NSColor colorWithSRGBRed:0.09 green:0.15 blue:0.13 alpha:1.0];
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
        NSParagraphStyleAttributeName: style
    };
    [text drawInRect:rect withAttributes:attributes];
}

- (void)drawProgressInRect:(NSRect)rect percent:(double)percent {
    NSColor *trackColor = [self usesSystemWidgetSurface]
        ? [NSColor.labelColor colorWithAlphaComponent:0.13]
        : [self usesDarkWidgetAppearance]
            ? [NSColor.whiteColor colorWithAlphaComponent:0.26]
            : [NSColor colorWithWhite:0.05 alpha:0.15];
    [trackColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:NSHeight(rect) / 2.0 yRadius:NSHeight(rect) / 2.0] fill];
    if (percent <= 0.0) return;
    CGFloat width = MAX(5.0, NSWidth(rect) * MIN(100.0, percent) / 100.0);
    NSRect fill = NSMakeRect(NSMinX(rect), NSMinY(rect), MIN(NSWidth(rect), width), NSHeight(rect));
    NSBezierPath *fillPath = [NSBezierPath bezierPathWithRoundedRect:fill
                                                             xRadius:NSHeight(fill) / 2.0
                                                             yRadius:NSHeight(fill) / 2.0];
    if ([self usesSystemWidgetSurface]) {
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:NSColor.systemCyanColor
                                                            endingColor:NSColor.systemGreenColor];
        [gradient drawInBezierPath:fillPath angle:0.0];
    } else if ([self usesDarkWidgetAppearance]) {
        [[NSColor.whiteColor colorWithAlphaComponent:0.92] setFill];
        [fillPath fill];
    } else {
        [[NSColor colorWithSRGBRed:0.10 green:0.30 blue:0.27 alpha:0.88] setFill];
        [fillPath fill];
    }
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
    CGFloat titleWidth = _stale ? (_medium ? width - 98 : width - 67) : width - 58;
    [self drawText:QGL(@"widget.title")
            inRect:NSMakeRect(43, 13, titleWidth, 22)
              font:[NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    if (_stale) {
        if (_medium) {
            [self drawText:QGL(@"widget.cached") inRect:NSMakeRect(width - 52, 16, 37, 17)
                      font:[NSFont systemFontOfSize:9 weight:NSFontWeightSemibold]
                     color:[self secondaryTextColor] alignment:NSTextAlignmentRight];
        } else {
            NSColor *indicator = [self usesDarkWidgetAppearance]
                ? [NSColor colorWithSRGBRed:1.0 green:0.82 blue:0.48 alpha:1.0]
                : [NSColor colorWithSRGBRed:0.60 green:0.34 blue:0.02 alpha:1.0];
            [indicator setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(width - 20, 21, 6, 6)] fill];
        }
    }
}

- (void)drawCard:(NSDictionary *)model inRect:(NSRect)rect {
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:15 yRadius:15];
    NSColor *fill = [self usesSystemWidgetSurface]
        ? [NSColor.labelColor colorWithAlphaComponent:0.055]
        : [NSColor.blackColor colorWithAlphaComponent:0.055];
    [fill setFill];
    [card fill];
    [self drawText:model[@"label"] inRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 9, NSWidth(rect) - 24, 17)
              font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawText:model[@"percentText"] inRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 28, NSWidth(rect) - 24, 35)
              font:[NSFont monospacedDigitSystemFontOfSize:27 weight:NSFontWeightSemibold]
             color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
    [self drawProgressInRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 69, NSWidth(rect) - 24, 5)
                      percent:[model[@"percent"] doubleValue]];
    [self drawText:model[@"exactResetText"]
            inRect:NSMakeRect(NSMinX(rect) + 12, NSMinY(rect) + 80, NSWidth(rect) - 24, 16)
              font:[NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightMedium]
             color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
}

- (void)drawSingleWindow:(NSDictionary *)model inWidth:(CGFloat)width {
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
                      percent:[model[@"percent"] doubleValue]];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5)
                                                                  xRadius:24 yRadius:24];
    // A subtle neutral scrim preserves the current wallpaper color instead of washing it out.
    NSColor *background = [self usesSystemWidgetSurface]
        ? NSColor.windowBackgroundColor
        : [NSColor.blackColor colorWithAlphaComponent:[self usesDarkWidgetAppearance] ? 0.58 : 0.16];
    [background setFill];
    [backgroundPath fill];
    backgroundPath.lineWidth = 1.0;
    NSColor *border = [self usesSystemWidgetSurface]
        ? [NSColor.labelColor colorWithAlphaComponent:0.08]
        : [NSColor.whiteColor colorWithAlphaComponent:0.18];
    [border setStroke];
    [backgroundPath stroke];
    [self drawHeaderInWidth:NSWidth(bounds)];

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
        [self drawText:model[@"label"] inRect:NSMakeRect(17, 48, NSWidth(bounds) - 34, 18)
                  font:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        [self drawText:model[@"percentText"] inRect:NSMakeRect(16, 65, NSWidth(bounds) - 32, 48)
                  font:[NSFont monospacedDigitSystemFontOfSize:37 weight:NSFontWeightSemibold]
                 color:[self primaryTextColor] alignment:NSTextAlignmentLeft];
        [self drawProgressInRect:NSMakeRect(17, 117, NSWidth(bounds) - 34, 5)
                          percent:[model[@"percent"] doubleValue]];
        [self drawText:_freshnessText inRect:NSMakeRect(17, 129, NSWidth(bounds) - 34, 15)
                  font:[NSFont systemFontOfSize:10 weight:NSFontWeightRegular]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
        [self drawText:_exactResetText inRect:NSMakeRect(17, 145, NSWidth(bounds) - 34, 15)
                  font:[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium]
                 color:[self secondaryTextColor] alignment:NSTextAlignmentLeft];
    }
}
@end

@interface QGAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate>
@property NSStatusItem *statusItem;
@property QGStatusContentView *statusContentView;
@property NSMenu *statusMenu;
@property NSMenuItem *summaryMenuItem;
@property NSArray<NSMenuItem *> *windowMenuItems;
@property NSMenuItem *resetMenuItem;
@property NSMenuItem *syncStateMenuItem;
@property NSMenuItem *refreshMenuItem;
@property NSMenuItem *manualMenuItem;
@property NSMenuItem *displayMenuItem;
@property NSMenuItem *fullModeMenuItem;
@property NSMenuItem *compactModeMenuItem;
@property NSMenuItem *nativeWidgetMenuItem;
@property NSMenuItem *addWidgetMenuItem;
@property NSMenuItem *toggleWidgetMenuItem;
@property NSMenuItem *smallWidgetMenuItem;
@property NSMenuItem *mediumWidgetMenuItem;
@property NSMenuItem *resetWidgetPositionMenuItem;
@property NSMenuItem *checkUpdateMenuItem;
@property NSMenuItem *automaticUpdateMenuItem;
@property NSMenuItem *aboutMenuItem;
@property NSMenuItem *quitMenuItem;
@property NSTimer *syncTimer;
@property NSTimer *displayTimer;
@property NSTimer *updateTimer;
@property NSPanel *desktopWidgetPanel;
@property NSVisualEffectView *desktopWidgetEffectView;
@property QGDesktopWidgetView *desktopWidgetView;
@property QGWidgetServer *widgetServer;
@property QGDesktopWidgetSize desktopWidgetSize;
@property NSArray<NSDictionary *> *quotaWindows;
@property NSDictionary *selectedWindow;
@property QGSyncState syncState;
@property QGDisplayMode displayMode;
@property BOOL syncInProgress;
@property BOOL updateCheckInProgress;
@property BOOL updateInstallInProgress;
@property NSDate *lastSuccessfulSync;
@property NSString *syncDetail;
@property NSString *lastError;
@property NSString *availableUpdateVersion;
@property NSURL *availableUpdateURL;
- (void)publishWidgetSnapshot;
- (void)performAutomaticUpdateCheckIfNeeded;
- (void)checkForUpdates:(id)sender;
- (void)toggleAutomaticUpdateChecks:(id)sender;
- (void)refreshDesktopWidget;
- (void)updateDesktopWidgetAppearance;
@end

@implementation QGAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    if ([NSUserDefaults.standardUserDefaults objectForKey:QGAutomaticUpdateChecksKey] == nil) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:QGAutomaticUpdateChecksKey];
    }
    [self restoreCachedQuota];
    if (QGNativeWidgetAvailable()) {
        _widgetServer = [QGWidgetServer new];
        if (![_widgetServer start]) NSLog(@"Gauge: native widget loopback server could not start");
    }
    [self publishWidgetSnapshot];
    id savedWidgetSize = [NSUserDefaults.standardUserDefaults objectForKey:QGDesktopWidgetSizeKey];
    _desktopWidgetSize = savedWidgetSize && [savedWidgetSize integerValue] == QGDesktopWidgetSizeSmall
        ? QGDesktopWidgetSizeSmall : QGDesktopWidgetSizeMedium;

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf performAutomaticUpdateCheckIfNeeded];
    });
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [_syncTimer invalidate];
    [_displayTimer invalidate];
    [_updateTimer invalidate];
    [_widgetServer stop];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return NO; }

- (NSMenu *)makeMenu {
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    _summaryMenuItem = [menu addItemWithTitle:QGProductName action:nil keyEquivalent:@""];
    _summaryMenuItem.enabled = NO;
    NSMutableArray<NSMenuItem *> *windowItems = [NSMutableArray array];
    for (NSInteger index = 0; index < 3; index++) {
        NSMenuItem *item = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
        item.enabled = NO;
        item.hidden = YES;
        [windowItems addObject:item];
    }
    _windowMenuItems = windowItems;
    _resetMenuItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _resetMenuItem.enabled = NO;
    _syncStateMenuItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _syncStateMenuItem.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];

    _refreshMenuItem = [menu addItemWithTitle:@"" action:@selector(refreshQuota:) keyEquivalent:@"r"];
    _refreshMenuItem.target = self;
    _displayMenuItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *displayMenu = [NSMenu new];
    _fullModeMenuItem = [displayMenu addItemWithTitle:@"" action:@selector(changeDisplayMode:) keyEquivalent:@""];
    _fullModeMenuItem.target = self;
    _fullModeMenuItem.tag = QGDisplayModeFull;
    _compactModeMenuItem = [displayMenu addItemWithTitle:@"" action:@selector(changeDisplayMode:) keyEquivalent:@""];
    _compactModeMenuItem.target = self;
    _compactModeMenuItem.tag = QGDisplayModeCompact;
    _displayMenuItem.submenu = displayMenu;
    _manualMenuItem = [menu addItemWithTitle:@"" action:@selector(editQuota:) keyEquivalent:@""];
    _manualMenuItem.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    _nativeWidgetMenuItem = [menu addItemWithTitle:@"" action:@selector(showNativeWidgetInstructions:) keyEquivalent:@""];
    _nativeWidgetMenuItem.target = self;
    _addWidgetMenuItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
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
    [widgetMenu addItem:NSMenuItem.separatorItem];
    _resetWidgetPositionMenuItem = [widgetMenu addItemWithTitle:@"" action:@selector(resetDesktopWidgetPosition:) keyEquivalent:@""];
    _resetWidgetPositionMenuItem.target = self;
    _addWidgetMenuItem.submenu = widgetMenu;
    _checkUpdateMenuItem = [menu addItemWithTitle:@"" action:@selector(checkForUpdates:) keyEquivalent:@""];
    _checkUpdateMenuItem.target = self;
    _automaticUpdateMenuItem = [menu addItemWithTitle:@"" action:@selector(toggleAutomaticUpdateChecks:) keyEquivalent:@""];
    _automaticUpdateMenuItem.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    _aboutMenuItem = [menu addItemWithTitle:@"" action:@selector(showAbout:) keyEquivalent:@""];
    _aboutMenuItem.target = self;
    _quitMenuItem = [menu addItemWithTitle:@"" action:@selector(terminate:) keyEquivalent:@"q"];
    _quitMenuItem.target = NSApp;
    return menu;
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self updateStatusItem];
    NSTimeInterval age = _lastSuccessfulSync ? -_lastSuccessfulSync.timeIntervalSinceNow : DBL_MAX;
    if (!_syncInProgress && age > 60.0) [self refreshQuota:nil];
}

- (void)localeOrTimeZoneChanged:(NSNotification *)notification {
    (void)notification;
    [self updateStatusItem];
    [self refreshDesktopWidget];
}

- (void)workspaceDidWake:(NSNotification *)notification {
    (void)notification;
    [self refreshQuota:nil];
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
    [self updateStatusItem];
    [self refreshDesktopWidget];
    NSTimeInterval resetAt = [_selectedWindow[@"resetsAt"] doubleValue];
    if (resetAt > 0 && resetAt <= NSDate.date.timeIntervalSince1970 && !_syncInProgress) {
        NSTimeInterval age = _lastSuccessfulSync ? -_lastSuccessfulSync.timeIntervalSinceNow : DBL_MAX;
        if (age > 20.0) [self refreshQuota:nil];
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

- (NSString *)windowLabel:(NSDictionary *)window {
    double minutes = [window[@"windowDurationMins"] doubleValue];
    if (minutes > 0) return [self relativeDuration:minutes * 60.0 maximumUnits:1];
    NSString *kind = window[@"kind"];
    return [kind isEqualToString:@"secondary"] ? QGL(@"quota.secondaryWindow") : QGL(@"quota.primaryWindow");
}

- (BOOL)dataIsStale {
    return !_lastSuccessfulSync || -_lastSuccessfulSync.timeIntervalSinceNow > 300.0;
}

- (NSString *)freshnessText {
    if (_syncState == QGSyncStateSyncing) return QGL(@"sync.syncing");
    NSString *ageText = nil;
    if (_lastSuccessfulSync) {
        NSTimeInterval age = MAX(0.0, -_lastSuccessfulSync.timeIntervalSinceNow);
        ageText = age < 75.0 ? QGL(@"sync.justNow") :
            [NSString stringWithFormat:QGL(@"sync.ago"), [self relativeDuration:age maximumUnits:1]];
    }
    if (_syncState == QGSyncStateFailed) {
        NSString *failure = _lastError.length ? _lastError : QGL(@"sync.failed");
        return ageText.length ? [NSString stringWithFormat:QGL(@"sync.failedWithLastUpdate"), failure, ageText] : failure;
    }
    if (!_lastSuccessfulSync) return _syncDetail.length ? _syncDetail : QGL(@"sync.waiting");
    if (self.dataIsStale) return [NSString stringWithFormat:QGL(@"sync.stale"), ageText];
    return ageText;
}

- (void)updateStatusItem {
    BOOL hasQuota = _selectedWindow != nil;
    double remaining = hasQuota ? [_selectedWindow[@"remainingPercent"] doubleValue] : 0.0;
    NSString *percent = hasQuota ? [self percentageString:remaining] : @"--";
    NSDictionary *statusTextAttributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14.5 weight:NSFontWeightSemibold]
    };
    CGFloat measuredWidth = ceil([percent sizeWithAttributes:statusTextAttributes].width);
    CGFloat minimumWidth = _displayMode == QGDisplayModeCompact ? 46.0 : 56.0;
    _statusItem.length = MAX(minimumWidth, measuredWidth + 14.0);
    _statusContentView.displayText = percent;
    _statusContentView.hasQuota = hasQuota;
    _statusContentView.remainingPercent = remaining;
    _statusContentView.showProgress = _displayMode == QGDisplayModeFull;
    _statusContentView.stale = self.dataIsStale || _syncState == QGSyncStateFailed;

    _summaryMenuItem.title = hasQuota
        ? [NSString stringWithFormat:QGL(@"menu.summary"), QGProductName, percent]
        : [NSString stringWithFormat:QGL(@"menu.summaryUnknown"), QGProductName];
    for (NSUInteger index = 0; index < _windowMenuItems.count; index++) {
        NSMenuItem *item = _windowMenuItems[index];
        if (index < _quotaWindows.count) {
            NSDictionary *window = _quotaWindows[index];
            item.hidden = NO;
            item.title = [NSString stringWithFormat:QGL(@"menu.window"), [self windowLabel:window],
                          [self percentageString:[window[@"remainingPercent"] doubleValue]]];
        } else {
            item.hidden = YES;
        }
    }
    _resetMenuItem.title = hasQuota ? [self resetDescriptionForWindow:_selectedWindow] : QGL(@"quota.resetUnknown");
    _syncStateMenuItem.title = [self freshnessText];
    _refreshMenuItem.title = QGL(@"menu.refresh");
    _manualMenuItem.title = QGL(@"menu.manual");
    _displayMenuItem.title = QGL(@"menu.display");
    _fullModeMenuItem.title = QGL(@"menu.displayFull");
    _compactModeMenuItem.title = QGL(@"menu.displayCompact");
    _fullModeMenuItem.state = _displayMode == QGDisplayModeFull ? NSControlStateValueOn : NSControlStateValueOff;
    _compactModeMenuItem.state = _displayMode == QGDisplayModeCompact ? NSControlStateValueOn : NSControlStateValueOff;
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
    _smallWidgetMenuItem.state = _desktopWidgetSize == QGDesktopWidgetSizeSmall
        ? NSControlStateValueOn : NSControlStateValueOff;
    _mediumWidgetMenuItem.state = _desktopWidgetSize == QGDesktopWidgetSizeMedium
        ? NSControlStateValueOn : NSControlStateValueOff;
    _resetWidgetPositionMenuItem.title = QGL(@"widget.resetPosition");
    _resetWidgetPositionMenuItem.enabled = widgetVisible;
    _checkUpdateMenuItem.title = _updateInstallInProgress ? QGL(@"update.installing") :
        (_updateCheckInProgress ? QGL(@"update.checking") :
         (_availableUpdateVersion.length
              ? [NSString stringWithFormat:QGL(@"update.availableMenu"), _availableUpdateVersion]
              : QGL(@"menu.checkUpdates")));
    _checkUpdateMenuItem.enabled = !_updateCheckInProgress && !_updateInstallInProgress;
    _automaticUpdateMenuItem.title = QGL(@"menu.automaticUpdates");
    _automaticUpdateMenuItem.state = [NSUserDefaults.standardUserDefaults boolForKey:QGAutomaticUpdateChecksKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    _automaticUpdateMenuItem.enabled = !_updateInstallInProgress;
    _aboutMenuItem.title = [NSString stringWithFormat:QGL(@"menu.about"), QGProductName];
    _quitMenuItem.title = [NSString stringWithFormat:QGL(@"menu.quit"), QGProductName];

    NSString *reset = hasQuota ? [self resetDescriptionForWindow:_selectedWindow] : QGL(@"quota.resetUnknown");
    _statusItem.button.toolTip = [NSString stringWithFormat:@"%@ · %@ · %@", QGProductName, percent, reset];
    [_statusItem.button setAccessibilityLabel:[NSString stringWithFormat:QGL(@"accessibility.menu"), QGProductName]];
    [_statusItem.button setAccessibilityValue:[NSString stringWithFormat:QGL(@"accessibility.value"), percent, reset, self.freshnessText]];
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
    NSInteger mode = [defaults integerForKey:QGDisplayModeKey];
    _displayMode = mode == QGDisplayModeCompact ? QGDisplayModeCompact : QGDisplayModeFull;
    _syncState = QGSyncStateIdle;
    if (valid.count) _syncDetail = QGL(@"sync.cached");
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
    [self publishWidgetSnapshot];
}

- (void)publishWidgetSnapshot {
    [NSUserDefaults.standardUserDefaults synchronize];
    [_widgetServer updateWithWindows:_quotaWindows ?: @[]
                          updatedAt:_lastSuccessfulSync.timeIntervalSince1970];
    [self refreshDesktopWidget];
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
    (void)sender;
    if (_syncInProgress) return;
    _syncInProgress = YES;
    _syncState = QGSyncStateSyncing;
    _lastError = nil;
    [self updateStatusItem];
    NSString *binary = self.codexBinaryPath;
    if (!binary) {
        [self finishSyncWithQuota:nil error:QGL(@"error.codexNotFound")];
        return;
    }

    __weak QGAppDelegate *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *errorMessage = nil;
        NSDictionary *quota = [weakSelf readQuotaUsingBinary:binary error:&errorMessage];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishSyncWithQuota:quota error:errorMessage];
        });
    });
}

- (NSDictionary *)readQuotaUsingBinary:(NSString *)binary error:(NSString **)errorMessage {
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
                NSString *request = @"{\"method\":\"account/rateLimits/read\",\"id\":2}\n";
                @try {
                    [input.fileHandleForWriting writeData:[request dataUsingEncoding:NSUTF8StringEncoding]];
                } @catch (__unused NSException *exception) {
                    finish(nil, QGL(@"error.connectionClosed"));
                }
                continue;
            }
            if (QGIDEquals(json[@"id"], 2)) {
                if ([json[@"result"] isKindOfClass:NSDictionary.class]) {
                    NSDictionary *quota = QGQuotaFromResult(json[@"result"]);
                    finish(quota, quota ? nil : QGL(@"error.unrecognizedResponse"));
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

    NSString *initialize = @"{\"method\":\"initialize\",\"id\":1,\"params\":{\"clientInfo\":{\"name\":\"gauge-for-codex\",\"title\":\"Gauge for Codex\",\"version\":\"1.0\"},\"capabilities\":null}}\n";
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
        _syncState = QGSyncStateSuccess;
        _syncDetail = [NSString stringWithFormat:QGL(@"sync.source"), quota[@"bucket"] ?: @"Codex"];
        _lastSuccessfulSync = NSDate.date;
        _lastError = nil;
        [self saveQuotaWindows:_quotaWindows];
        [NSUserDefaults.standardUserDefaults setDouble:_lastSuccessfulSync.timeIntervalSince1970 forKey:QGLastSyncKey];
        [self publishWidgetSnapshot];
    } else {
        _syncState = QGSyncStateFailed;
        _lastError = errorMessage ?: QGL(@"sync.failed");
    }
    [self updateStatusItem];
}

- (BOOL)parseLocalizedNumber:(NSString *)string value:(double *)value {
    NSString *trimmed = [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return NO;
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.lenient = NO;
    NSRange range = NSMakeRange(0, trimmed.length);
    NSNumber *number = nil;
    BOOL valid = [formatter getObjectValue:&number forString:trimmed range:&range error:nil];
    if (!valid || range.length != trimmed.length || !isfinite(number.doubleValue)) return NO;
    if (value) *value = number.doubleValue;
    return YES;
}

- (void)editQuota:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = QGL(@"manual.title");
    alert.informativeText = QGL(@"manual.help");
    [alert addButtonWithTitle:QGL(@"common.save")];
    [alert addButtonWithTitle:QGL(@"common.cancel")];

    double currentUsed = _selectedWindow ? 100.0 - [_selectedWindow[@"remainingPercent"] doubleValue] : 0.0;
    NSTextField *usedField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%.0f", currentUsed]];
    usedField.placeholderString = @"0–100";
    NSTextField *hoursField = [NSTextField textFieldWithString:@""];
    hoursField.placeholderString = QGL(@"manual.hoursPlaceholder");
    NSTextField *usedLabel = [NSTextField labelWithString:QGL(@"manual.usedLabel")];
    NSTextField *hoursLabel = [NSTextField labelWithString:QGL(@"manual.hoursLabel")];
    usedLabel.alignment = hoursLabel.alignment = NSTextAlignmentRight;
    [usedLabel.widthAnchor constraintEqualToConstant:110].active = YES;
    [hoursLabel.widthAnchor constraintEqualToConstant:110].active = YES;
    [usedField.widthAnchor constraintEqualToConstant:178].active = YES;
    [hoursField.widthAnchor constraintEqualToConstant:178].active = YES;
    NSStackView *row1 = [NSStackView stackViewWithViews:@[usedLabel, usedField]];
    NSStackView *row2 = [NSStackView stackViewWithViews:@[hoursLabel, hoursField]];
    row1.spacing = row2.spacing = 8;
    NSStackView *stack = [NSStackView stackViewWithViews:@[row1, row2]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 8;
    stack.frame = NSMakeRect(0, 0, 300, 56);
    alert.accessoryView = stack;

    [NSApp activateIgnoringOtherApps:YES];
    while ([alert runModal] == NSAlertFirstButtonReturn) {
        double used = 0;
        if (![self parseLocalizedNumber:usedField.stringValue value:&used] || used < 0 || used > 100) {
            NSBeep();
            alert.informativeText = QGL(@"manual.invalidPercent");
            continue;
        }
        NSTimeInterval resetAt = [_selectedWindow[@"resetsAt"] doubleValue];
        NSString *hoursText = [hoursField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (hoursText.length) {
            double hours = 0;
            if (![self parseLocalizedNumber:hoursText value:&hours] || hours <= 0 || hours > 24 * 365) {
                NSBeep();
                alert.informativeText = QGL(@"manual.invalidHours");
                continue;
            }
            resetAt = NSDate.date.timeIntervalSince1970 + hours * 3600.0;
        }
        NSDictionary *window = @{
            @"usedPercent": @(used), @"remainingPercent": @(100.0 - used),
            @"resetsAt": @(MAX(0.0, resetAt)), @"windowDurationMins": @0, @"kind": @"primary"
        };
        [self applyWindows:@[window]];
        _syncState = QGSyncStateIdle;
        _syncDetail = QGL(@"sync.manual");
        _lastSuccessfulSync = NSDate.date;
        [self saveQuotaWindows:_quotaWindows];
        [NSUserDefaults.standardUserDefaults setDouble:_lastSuccessfulSync.timeIntervalSince1970 forKey:QGLastSyncKey];
        [self publishWidgetSnapshot];
        [self updateStatusItem];
        break;
    }
}

- (NSSize)desktopWidgetWindowSize {
    return _desktopWidgetSize == QGDesktopWidgetSizeMedium ? NSMakeSize(344, 164) : NSMakeSize(164, 164);
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
    QGDesktopWidgetSize newSize = sender.tag == QGDesktopWidgetSizeMedium
        ? QGDesktopWidgetSizeMedium : QGDesktopWidgetSizeSmall;
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
    _desktopWidgetView.medium = newSize == QGDesktopWidgetSizeMedium;
    [_desktopWidgetPanel setFrame:newFrame display:YES animate:YES];
    [NSUserDefaults.standardUserDefaults setObject:NSStringFromRect(newFrame) forKey:QGDesktopWidgetFrameKey];
    [self showDesktopWidget:nil];
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
    _desktopWidgetEffectView.alphaValue = (desktopFocused || reduceTransparency) ? 0.0 : 0.12;
}

- (void)refreshDesktopWidget {
    if (!_desktopWidgetView) return;
    NSArray<NSDictionary *> *source = nil;
    if (_desktopWidgetSize == QGDesktopWidgetSizeMedium) {
        source = [_quotaWindows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            double leftDuration = [left[@"windowDurationMins"] doubleValue];
            double rightDuration = [right[@"windowDurationMins"] doubleValue];
            if (leftDuration <= 0 && rightDuration > 0) return NSOrderedDescending;
            if (rightDuration <= 0 && leftDuration > 0) return NSOrderedAscending;
            if (leftDuration < rightDuration) return NSOrderedAscending;
            if (leftDuration > rightDuration) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    } else {
        source = _selectedWindow ? @[_selectedWindow] : @[];
    }
    NSMutableArray<NSDictionary *> *models = [NSMutableArray array];
    for (NSDictionary *window in source) {
        [models addObject:@{
            @"label": [self windowLabel:window],
            @"percent": window[@"remainingPercent"] ?: @0,
            @"percentText": [self percentageString:[window[@"remainingPercent"] doubleValue]],
            @"exactResetText": [self compactResetTextForWindow:window]
        }];
        if (models.count == 2) break;
    }
    _desktopWidgetView.windowModels = models;
    _desktopWidgetView.emptyText = QGL(@"widget.noData");
    _desktopWidgetView.stale = models.count > 0 && (self.dataIsStale || _syncState == QGSyncStateFailed);
    _desktopWidgetView.toolTip = _desktopWidgetView.stale ? QGL(@"widget.cached") : nil;
    _desktopWidgetView.exactResetText = _selectedWindow ? [self compactResetTextForWindow:_selectedWindow] : @"";
    if (_selectedWindow) {
        NSTimeInterval resetAt = [_selectedWindow[@"resetsAt"] doubleValue];
        if (resetAt > NSDate.date.timeIntervalSince1970) {
            NSString *duration = [self relativeDuration:resetAt - NSDate.date.timeIntervalSince1970 maximumUnits:2];
            _desktopWidgetView.freshnessText = [NSString stringWithFormat:QGL(@"widget.resetIn"), duration];
        } else {
            _desktopWidgetView.freshnessText = QGL(@"quota.resetUnknown");
        }
    } else {
        _desktopWidgetView.freshnessText = self.freshnessText;
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
    request.timeoutInterval = 30.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [request setValue:[NSString stringWithFormat:@"Gauge-for-Codex/%@", self.currentVersion]
   forHTTPHeaderField:@"User-Agent"];
    return request;
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
        NSDictionary *release = nil;
        if (!error && http.statusCode == 200 && data.length) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if ([object isKindOfClass:NSDictionary.class]) release = object;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            QGAppDelegate *self = weakSelf;
            if (!self) return;
            self.updateCheckInProgress = NO;
            if (!release) {
                [self updateStatusItem];
                if (manual) [self showUpdateFailure:error.localizedDescription ?: QGL(@"update.checkFailed")
                                         releaseURL:nil];
                return;
            }
            [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970
                                                    forKey:QGLastUpdateCheckKey];
            NSString *version = [release[@"tag_name"] isKindOfClass:NSString.class] ? release[@"tag_name"] : @"";
            if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) version = [version substringFromIndex:1];
            NSString *page = [release[@"html_url"] isKindOfClass:NSString.class] ? release[@"html_url"] : @"";
            self.availableUpdateURL = page.length ? [NSURL URLWithString:page] : nil;
            if (!version.length || QGCompareVersions(version, self.currentVersion) != NSOrderedDescending) {
                self.availableUpdateVersion = nil;
                [self updateStatusItem];
                if (manual) {
                    NSAlert *alert = [NSAlert new];
                    alert.messageText = QGL(@"update.upToDateTitle");
                    alert.informativeText = [NSString stringWithFormat:QGL(@"update.upToDateBody"), self.currentVersion];
                    [alert addButtonWithTitle:QGL(@"common.ok")];
                    [NSApp activateIgnoringOtherApps:YES];
                    [alert runModal];
                }
                return;
            }

            self.availableUpdateVersion = version;
            [self updateStatusItem];
            if (manual) {
                NSAlert *alert = [NSAlert new];
                alert.messageText = [NSString stringWithFormat:QGL(@"update.availableTitle"), version];
                alert.informativeText = QGL(@"update.availableBody");
                [alert addButtonWithTitle:QGL(@"update.install")];
                [alert addButtonWithTitle:QGL(@"update.later")];
                [NSApp activateIgnoringOtherApps:YES];
                if ([alert runModal] != NSAlertFirstButtonReturn) return;
            }
            [self downloadAndInstallRelease:release manual:manual];
        });
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
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if ([line rangeOfString:fileName options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSString *part in parts) {
            if (part.length == 64 && [[part stringByTrimmingCharactersInSet:hexSet] length] == 0) {
                return part.lowercaseString;
            }
        }
    }
    return nil;
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
        ![bundleVersion isEqualToString:version]) {
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
        if ([name.lowercaseString hasSuffix:@"-universal.zip"]) zipAsset = asset;
        else if (!zipAsset && [name.lowercaseString hasSuffix:@".zip"]) zipAsset = asset;
    }
    NSString *zipName = [zipAsset[@"name"] isKindOfClass:NSString.class] ? zipAsset[@"name"] : @"";
    NSURL *zipURL = [NSURL URLWithString:[zipAsset[@"browser_download_url"] isKindOfClass:NSString.class]
                                             ? zipAsset[@"browser_download_url"] : @""];
    NSURL *checksumURL = [NSURL URLWithString:[checksumAsset[@"browser_download_url"] isKindOfClass:NSString.class]
                                                  ? checksumAsset[@"browser_download_url"] : @""];
    if (!zipURL || !checksumURL || !zipName.length) {
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
                if (!expected.length || ![expected isEqualToString:QGSHA256(zipData)]) {
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
                       replacement, _availableUpdateVersion ?: @"", temporary];
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
    alert.informativeText = QGL(@"nativeWidget.guideBody");
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
