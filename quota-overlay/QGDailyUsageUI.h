@interface QGDailyBarChartView : NSView
@property NSArray<NSString *> *dayKeys;
@property NSArray<NSDictionary *> *buckets;
@property NSString *emptyText;
@property NSArray<NSDictionary *> *hoverRegions;
@property NSString *hoverText;
@property NSPoint hoverPoint;
@property NSTrackingArea *hoverTrackingArea;
- (NSString *)hoverTextAtPoint:(NSPoint)point;
@end
@implementation QGDailyBarChartView
- (BOOL)isFlipped { return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverTrackingArea) [self removeTrackingArea:_hoverTrackingArea];
    _hoverTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_hoverTrackingArea];
}
- (NSString *)hoverTextAtPoint:(NSPoint)point {
    for (NSDictionary *region in _hoverRegions) {
        if (NSPointInRect(point, [region[@"rect"] rectValue])) return region[@"text"];
    }
    return nil;
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSString *text = [self hoverTextAtPoint:point];
    if (![_hoverText isEqualToString:text] || !NSEqualPoints(_hoverPoint, point)) {
        _hoverText = text; _hoverPoint = point; [self setNeedsDisplay:YES];
    }
}
- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(NSEvent *)event {
    (void)event; _hoverText = nil; [self setNeedsDisplay:YES];
}
- (void)drawText:(NSString *)text centeredAt:(CGFloat)center y:(CGFloat)y {
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:10],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    CGFloat width = [text sizeWithAttributes:attributes].width;
    [text drawAtPoint:NSMakePoint(center-width/2, y) withAttributes:attributes];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSMutableArray<NSDictionary *> *regions = [NSMutableArray array];
    NSRect plot = NSMakeRect(45, 12, self.bounds.size.width-57, self.bounds.size.height-40);
    NSSet *visibleDays = [NSSet setWithArray:_dayKeys ?: @[]];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSDictionary *> *> *byDate = [NSMutableDictionary dictionary];
    double maximum = 1;
    for (NSDictionary *bucket in _buckets) {
        NSString *date = bucket[@"date"], *provider = bucket[@"provider"];
        if (![visibleDays containsObject:date] || ![@[@"codex", @"claude"] containsObject:provider]) continue;
        if (!byDate[date]) byDate[date] = [NSMutableDictionary dictionary];
        byDate[date][provider] = bucket;
        maximum = MAX(maximum, [bucket[@"value"] doubleValue]);
    }
    for (NSUInteger index = 0; index < 3; index++) {
        CGFloat y = plot.origin.y + plot.size.height * index / 2;
        [[NSColor.labelColor colorWithAlphaComponent:0.08] setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(plot.origin.x, y)]; [line lineToPoint:NSMakePoint(NSMaxX(plot), y)]; [line stroke];
        if (maximum > 1 || index != 1)
            [self drawText:QGTokenText(maximum * (1-index/2.0)) centeredAt:20 y:y-6];
    }
    NSUInteger dayCount = _dayKeys.count;
    CGFloat slotWidth = dayCount ? plot.size.width/dayCount : plot.size.width;
    CGFloat barWidth = MIN(24, MAX(2.5, slotWidth * 0.30));
    NSUInteger points = 0;
    for (NSUInteger index = 0; index < dayCount; index++) {
        NSString *date = _dayKeys[index];
        CGFloat center = plot.origin.x + slotWidth * (index+0.5);
        // Short ranges label every day; long ranges use sparse labels, still
        // centered on their actual day slots rather than time-axis ticks.
        if (dayCount <= 7 || index == 0 || index == dayCount-1 || index % 5 == 0) {
            NSString *label = [NSString stringWithFormat:@"%ld/%ld", (long)[[date substringWithRange:NSMakeRange(5, 2)] integerValue],
                (long)[[date substringWithRange:NSMakeRange(8, 2)] integerValue]];
            [self drawText:label centeredAt:center y:NSMaxY(plot)+8];
        }
        NSDictionary *entries = byDate[date];
        NSUInteger count = entries.count;
        for (NSString *provider in @[@"codex", @"claude"]) {
            NSDictionary *bucket = entries[provider];
            if (!bucket) continue;
            BOOL claude = [provider isEqual:@"claude"];
            CGFloat x = center-barWidth/2;
            if (count == 2) x += (claude ? 1 : -1) * (barWidth/2 + 1);
            double value = [bucket[@"value"] doubleValue];
            CGFloat height = value == 0 ? 2 : MAX(2, plot.size.height * value / maximum);
            NSRect bar = NSMakeRect(x, NSMaxY(plot)-height, barWidth, height);
            [[QGServiceColor(claude) colorWithAlphaComponent:0.85] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:MIN(2, height/2) yRadius:MIN(2, height/2)] fill];
            NSString *exact = [NSNumberFormatter localizedStringFromNumber:@((long long)llround(value))
                numberStyle:NSNumberFormatterDecimalStyle];
            NSString *tip = exact;
            // Only the visible bar responds; the empty date slot and the
            // space above a short bar must not claim that day's value.
            [regions addObject:@{@"rect": [NSValue valueWithRect:bar], @"text": tip}];
            points++;
        }
    }
    _hoverRegions = regions;
    if (!points) [self drawText:_emptyText ?: QGL(@"insights.noSamples")
        centeredAt:NSMidX(plot) y:plot.origin.y+plot.size.height/2-6];
    if (_hoverText.length) {
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.labelColor};
        CGFloat width = MIN(self.bounds.size.width-12, [_hoverText sizeWithAttributes:attributes].width+18);
        CGFloat x = MIN(MAX(5, _hoverPoint.x-width/2), self.bounds.size.width-width-5);
        CGFloat y = MAX(2, _hoverPoint.y-32);
        NSRect bubble = NSMakeRect(x, y, width, 25);
        [NSColor.windowBackgroundColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bubble xRadius:6 yRadius:6] fill];
        [[NSColor.separatorColor colorWithAlphaComponent:0.65] setStroke];
        [[NSBezierPath bezierPathWithRoundedRect:bubble xRadius:6 yRadius:6] stroke];
        [_hoverText drawInRect:NSInsetRect(bubble, 9, 5) withAttributes:attributes];
    }
}
@end

@interface QGDailyUsageView : NSView
- (instancetype)initWithReport:(NSDictionary *)report start:(NSDate *)start now:(NSDate *)now loading:(BOOL)loading;
@end
@implementation QGDailyUsageView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; [NSColor.controlBackgroundColor setFill];
    for (NSUInteger i = 0; i < 5; i++)
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(14+i*116, 26, 110, 74) xRadius:10 yRadius:10] fill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(14, 113, 580, 224) xRadius:12 yRadius:12] fill];
}
- (instancetype)initWithReport:(NSDictionary *)report start:(NSDate *)start now:(NSDate *)now loading:(BOOL)loading {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 608, 456)])) {
        QGInsightLabel(self, QGL(@"daily.codexSummary"), NSMakeRect(22, 0, 562, 22), 12, NO);
        NSArray *keys = @[@"lifetimeTokens", @"peakDailyTokens", @"longestRunningTurnSec", @"currentStreakDays", @"longestStreakDays"];
        NSArray *labels = @[@"daily.lifetime", @"daily.peak", @"daily.longestRun", @"daily.streak", @"daily.longestStreak"];
        for (NSUInteger i = 0; i < keys.count; i++) {
            CGFloat x = 22+i*116;
            NSTextField *caption = QGInsightLabel(self, QGL(labels[i]), NSMakeRect(x, 33, 98, 28), 10, YES);
            caption.maximumNumberOfLines = 2; caption.lineBreakMode = NSLineBreakByWordWrapping;
            NSNumber *number = report[@"codexSummary"][keys[i]];
            NSString *value = @"—";
            if (number) {
                if (i < 2) value = QGTokenText(number.doubleValue);
                else if (i == 2) value = [NSString stringWithFormat:@"%ldh %ldm", number.integerValue / 3600, (number.integerValue % 3600) / 60];
                else value = [NSString stringWithFormat:QGL(@"daily.days"), number.integerValue];
            }
            NSTextField *field = QGInsightLabel(self, value, NSMakeRect(x, 68, 100, 28), i == 2 ? 18 : 21, NO);
            field.toolTip = number ? [NSString stringWithFormat:@"%@ · %@", QGL(labels[i]), number] : QGL(@"daily.unavailable");
            if (i == 2) field.toolTip = QGL(@"daily.runHelp");
        }
        NSDictionary *summary = QGDailySummary(report, start, now);
        QGInsightLabel(self, QGL(@"daily.chartTitle"), NSMakeRect(22, 122, 180, 20), 12, NO);
        NSString *codex = [summary[@"codexCount"] integerValue] ? QGTokenText([summary[@"codex"] doubleValue]) : @"—";
        NSString *claude = [summary[@"claudeCount"] integerValue] ? QGTokenText([summary[@"claude"] doubleValue]) : @"—";
        NSTextField *legend = QGInsightLabel(self, [NSString stringWithFormat:@"● Codex %@     ● Claude %@", codex, claude],
            NSMakeRect(200, 122, 384, 20), 11, YES); legend.alignment = NSTextAlignmentRight;
        NSMutableAttributedString *text = legend.attributedStringValue.mutableCopy;
        NSRange split = [legend.stringValue rangeOfString:@"● Claude"];
        [text addAttribute:NSForegroundColorAttributeName value:QGServiceColor(NO) range:NSMakeRange(0, split.location)];
        [text addAttribute:NSForegroundColorAttributeName value:QGServiceColor(YES) range:NSMakeRange(split.location, text.length-split.location)];
        legend.attributedStringValue = text;
        QGDailyBarChartView *chart = [[QGDailyBarChartView alloc] initWithFrame:NSMakeRect(22, 149, 562, 180)];
        chart.buckets = summary[@"buckets"];
        chart.dayKeys = QGDailyDateKeys(start, now);
        chart.emptyText = QGL(loading ? @"daily.loading" : @"daily.noDays");
        [chart setAccessibilityLabel:QGL(@"daily.chartTitle")]; [self addSubview:chart];
        NSUInteger index = 0;
        for (NSString *provider in @[@"codex", @"claude"]) {
            NSDictionary *state = report[@"providers"][provider];
            NSString *source = QGL([provider isEqual:@"codex"] ? @"daily.codexSource" : @"daily.claudeSource");
            NSString *latest = state[@"latest"];
            NSString *status = loading ? QGL(@"daily.loading") : ![state[@"available"] boolValue] ? QGL(@"daily.unavailable") :
                latest.length ? [NSString stringWithFormat:QGL(@"daily.latest"), latest] : QGL(@"daily.noDays");
            if ([state[@"stale"] boolValue]) status = [NSString stringWithFormat:@"%@ · %@", QGL(@"widget.cached"), status];
            QGInsightLabel(self, [NSString stringWithFormat:@"%@ · %@", source, status], NSMakeRect(22, 351+index*24, 562, 20), 11, YES);
            index++;
        }
        NSTextField *help = QGInsightLabel(self, QGL(@"daily.help"), NSMakeRect(22, 404, 562, 44), 11, YES);
        help.maximumNumberOfLines = 3; help.lineBreakMode = NSLineBreakByWordWrapping;
    }
    return self;
}
@end
