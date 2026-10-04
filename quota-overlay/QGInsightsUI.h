// Native AppKit views shared by the app and offscreen visual regression previews.
static NSColor *QGServiceColor(BOOL claude) {
    return claude ? [NSColor colorWithSRGBRed:0.77 green:0.40 blue:0.29 alpha:1]
                  : [NSColor colorWithSRGBRed:0.12 green:0.58 blue:0.49 alpha:1];
}
static NSTextField *QGInsightLabel(NSView *parent, NSString *text, NSRect frame, CGFloat size, BOOL secondary) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size weight:secondary ? NSFontWeightRegular : NSFontWeightSemibold];
    label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.toolTip = text;
    [parent addSubview:label];
    return label;
}
static NSString *QGTokenText(double value) {
    NSNumberFormatter *format = [NSNumberFormatter new];
    format.numberStyle = NSNumberFormatterDecimalStyle;
    format.maximumFractionDigits = value >= 1000 ? 1 : 0;
    if ([QGEffectiveLanguage() hasPrefix:@"zh"]) {
        double unit = value >= 1e8 ? 1e8 : (value >= 1e4 ? 1e4 : 1);
        return [[format stringFromNumber:@(value / unit)] stringByAppendingString:unit == 1e8 ? @" 亿" : (unit == 1e4 ? @" 万" : @"")];
    }
    double divisor = value >= 1e9 ? 1e9 : (value >= 1e6 ? 1e6 : (value >= 1e3 ? 1e3 : 1));
    return [[format stringFromNumber:@(value / divisor)] stringByAppendingString:
        divisor == 1e9 ? @" B" : (divisor == 1e6 ? @" M" : (divisor == 1e3 ? @" K" : @""))];
}

// Keep native button tracking and accessibility, with an explicit selected
// treatment that also renders correctly inside a non-key menu window.
@interface QGProviderButton : NSButton
@property BOOL hidesCheckmark;
@end
@implementation QGProviderButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    BOOL selected = self.state == NSControlStateValueOn;
    if (selected || self.highlighted) {
        NSColor *fill = selected ? NSColor.controlBackgroundColor : [NSColor.labelColor colorWithAlphaComponent:0.06];
        [fill setFill];
        NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:7 yRadius:7];
        [pill fill];
        if (selected) {
            [[NSColor.labelColor colorWithAlphaComponent:0.10] setStroke]; pill.lineWidth = 0.5; [pill stroke];
        }
    }
    NSString *title = selected && !_hidesCheckmark ? [@"✓ " stringByAppendingString:self.title] : self.title;
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:selected ? NSFontWeightSemibold : NSFontWeightMedium],
        NSForegroundColorAttributeName: selected ? NSColor.labelColor : NSColor.secondaryLabelColor};
    NSSize size = [title sizeWithAttributes:attributes];
    [title drawAtPoint:NSMakePoint(round((self.bounds.size.width-size.width)/2), round((self.bounds.size.height-size.height)/2))
        withAttributes:attributes];
}
@end

@interface QGChoiceBar : NSView
@property (nonatomic) NSInteger selectedSegment;
@property NSArray<QGProviderButton *> *buttons;
@property (weak) id target;
@property SEL action;
- (instancetype)initWithLabels:(NSArray<NSString *> *)labels frame:(NSRect)frame;
@end
@implementation QGChoiceBar
- (instancetype)initWithLabels:(NSArray<NSString *> *)labels frame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSMutableArray *buttons = [NSMutableArray array];
        CGFloat width = (frame.size.width-4)/labels.count;
        for (NSUInteger index = 0; index < labels.count; index++) {
            QGProviderButton *button = [[QGProviderButton alloc] initWithFrame:NSMakeRect(2+index*width, 2, width, frame.size.height-4)];
            button.title = labels[index]; button.hidesCheckmark = YES; button.bordered = NO;
            [button setButtonType:NSButtonTypeMomentaryPushIn];
            button.tag = index; button.target = self; button.action = @selector(choose:);
            [button setAccessibilityLabel:button.title];
            [self addSubview:button]; [buttons addObject:button];
        }
        _buttons = buttons; self.selectedSegment = 0;
    }
    return self;
}
- (void)drawRect:(NSRect)rect {
    (void)rect; [[NSColor.labelColor colorWithAlphaComponent:0.055] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:9 yRadius:9] fill];
}
- (void)setSelectedSegment:(NSInteger)index {
    _selectedSegment = MAX(0, MIN((NSInteger)_buttons.count-1, index));
    for (NSButton *button in _buttons) {
        button.state = button.tag == _selectedSegment ? NSControlStateValueOn : NSControlStateValueOff;
        button.needsDisplay = YES;
    }
}
- (void)choose:(NSButton *)sender {
    self.selectedSegment = sender.tag;
    [NSApp sendAction:_action to:_target from:self];
}
@end

@interface QGToolbarButton : NSButton
@end
@implementation QGToolbarButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
@end
static NSButton *QGSymbolButton(NSString *symbol, NSString *label, NSRect frame) {
    NSButton *button = [[QGToolbarButton alloc] initWithFrame:frame];
    button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label];
    button.imagePosition = NSImageOnly; button.bordered = NO; button.contentTintColor = NSColor.secondaryLabelColor;
    button.toolTip = label; [button setAccessibilityLabel:label];
    return button;
}

@interface QGProviderSwitchView : NSView
@property QGProviderButton *codexButton;
@property QGProviderButton *claudeButton;
@property NSButton *refreshButton;
@property NSButton *settingsButton;
@property NSProgressIndicator *spinner;
@property (nonatomic) BOOL refreshing;
- (void)configureSelectedProvider:(NSString *)provider claudeEnabled:(BOOL)enabled;
@end
@implementation QGProviderSwitchView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        QGInsightLabel(self, QGL(@"menu.providerShort"), NSMakeRect(20, 12, 61, 18), 11, YES);
        _codexButton = [[QGProviderButton alloc] initWithFrame:NSMakeRect(85, 5, 80, 30)];
        _claudeButton = [[QGProviderButton alloc] initWithFrame:NSMakeRect(167, 5, 84, 30)];
        _codexButton.title = @"Codex"; _claudeButton.title = @"Claude";
        for (QGProviderButton *button in @[_codexButton, _claudeButton]) {
            button.bordered = NO;
            [button setButtonType:NSButtonTypeMomentaryPushIn];
            [button setAccessibilityLabel:[NSString stringWithFormat:QGL(@"insights.menuProvider"), button.title]];
            [self addSubview:button];
        }
        _refreshButton = QGSymbolButton(@"arrow.clockwise", QGL(@"menu.refreshAll"), NSMakeRect(257, 5, 28, 30));
        [self addSubview:_refreshButton];
        _settingsButton = QGSymbolButton(@"gearshape", QGL(@"settings.title"), NSMakeRect(291, 5, 28, 30));
        [self addSubview:_settingsButton];
        _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(263, 12, 16, 16)];
        _spinner.style = NSProgressIndicatorStyleSpinning; _spinner.controlSize = NSControlSizeSmall;
        _spinner.displayedWhenStopped = NO; _spinner.hidden = YES;
        _spinner.toolTip = QGL(@"sync.syncing"); [_spinner setAccessibilityLabel:QGL(@"sync.syncing")];
        [self addSubview:_spinner];
    }
    return self;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor.labelColor colorWithAlphaComponent:0.055] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(83, 3, 170, 34) xRadius:9 yRadius:9] fill];
}
- (void)setRefreshing:(BOOL)refreshing {
    if (_refreshing == refreshing) return;
    _refreshing = refreshing;
    _refreshButton.enabled = !refreshing; _refreshButton.hidden = refreshing;
    _spinner.hidden = !refreshing;
    if (refreshing) [_spinner startAnimation:nil]; else [_spinner stopAnimation:nil];
}
- (void)configureSelectedProvider:(NSString *)provider claudeEnabled:(BOOL)enabled {
    for (QGProviderButton *button in @[_codexButton, _claudeButton]) {
        BOOL claude = button == _claudeButton;
        button.state = [provider isEqual:claude ? @"claude" : @"codex"] ? NSControlStateValueOn : NSControlStateValueOff;
        NSString *help = QGL(claude && !enabled ? @"insights.providerConnectHelp" : @"insights.providerHelp");
        button.toolTip = [NSString stringWithFormat:@"%@ · ⌘%@", help, claude ? @"2" : @"1"];
        [button setAccessibilityHelp:button.toolTip];
        button.needsDisplay = YES;
    }
}
@end

@interface QGMenuQuotaView : NSView
@property NSArray<NSDictionary *> *cards;
@property BOOL usesBars;
- (void)configureWithCards:(NSArray<NSDictionary *> *)cards;
@end
@implementation QGMenuQuotaView
- (BOOL)isFlipped { return YES; }
- (CGFloat)heightForEntryCount:(NSUInteger)count {
    if (_usesBars) return count ? 55 + count * 42 : 82;
    // Two columns, one row in normal use; additional provider windows remain visible.
    return count ? 62 + ceil(count / 2.0) * 56 : 82;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat y = 4;
    for (NSDictionary *card in _cards) {
        NSUInteger count = [card[@"entries"] count];
        CGFloat height = [self heightForEntryCount:count];
        [[NSColor.labelColor colorWithAlphaComponent:0.035] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(10, y, 316, height) xRadius:12 yRadius:12] fill];
        y += height + 8;
    }
}
- (void)configureWithCards:(NSArray<NSDictionary *> *)cards {
    _cards = cards;
    for (NSView *view in self.subviews.copy) [view removeFromSuperview];
    [self setAccessibilityLabel:QGL(@"widget.titleRemaining")];
    CGFloat y = 4;
    for (NSDictionary *card in cards) {
        BOOL claude = [card[@"id"] isEqual:@"claude"];
        BOOL stale = [card[@"stale"] boolValue];
        NSArray *entries = card[@"entries"];
        CGFloat height = [self heightForEntryCount:entries.count];
        NSTextField *name = QGInsightLabel(self, card[@"name"], NSMakeRect(22, y+9, 64, 19), 13, NO);
        name.textColor = QGServiceColor(claude);
        QGInsightLabel(self, card[@"plan"], NSMakeRect(88, y+10, 130, 18), 11, YES);
        NSTextField *state = QGInsightLabel(self, card[@"state"], NSMakeRect(219, y+10, 94, 18), 10, YES);
        state.alignment = NSTextAlignmentRight;
        state.toolTip = card[@"help"];
        if (!entries.count) {
            NSTextField *empty = QGInsightLabel(self, card[@"empty"], NSMakeRect(22, y+34, 290, 36), 11, YES);
            empty.maximumNumberOfLines = 2; empty.lineBreakMode = NSLineBreakByWordWrapping;
        }
        for (NSUInteger index = 0; index < entries.count; index++) {
            NSDictionary *entry = entries[index];
            if (_usesBars) {
                CGFloat rowY = y + 34 + index * 42;
                QGInsightLabel(self, entry[@"title"], NSMakeRect(22, rowY, 67, 18), 11, NO);
                QGMenuRingView *bar = [[QGMenuRingView alloc] initWithFrame:NSMakeRect(92, rowY+6, 165, 5)];
                bar.percent = [entry[@"remaining"] doubleValue]; bar.claude = claude; bar.usesBars = YES;
                if (stale) bar.alphaValue = 0.45;
                [bar setAccessibilityElement:NO]; [self addSubview:bar];
                NSTextField *value = QGInsightLabel(self, entry[@"percent"], NSMakeRect(262, rowY-2, 51, 22), 15, NO);
                value.font = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold];
                value.alignment = NSTextAlignmentRight;
                if (bar.percent <= 10) value.textColor = NSColor.systemRedColor;
                else if (bar.percent <= 20) value.textColor = NSColor.systemOrangeColor;
                if (stale) value.textColor = NSColor.secondaryLabelColor;
                NSTextField *reset = QGInsightLabel(self, entry[@"reset"], NSMakeRect(22, rowY+20, 291, 15), 10, YES);
                reset.toolTip = entry[@"help"]; [reset setAccessibilityHelp:entry[@"help"]];
                continue;
            }
            BOOL wide = entries.count == 1;
            CGFloat x = 22 + (index % 2) * 151, rowY = y + 35 + (index / 2) * 56;
            CGFloat diameter = wide ? 58 : 50;
            CGFloat detailX = x + diameter + (wide ? 16 : 8);
            CGFloat detailWidth = wide ? 291 - diameter - 16 : 140 - diameter - 8;
            QGMenuRingView *ring = [[QGMenuRingView alloc] initWithFrame:NSMakeRect(x, rowY, diameter, diameter)];
            ring.percent = [entry[@"remaining"] doubleValue]; ring.claude = claude; ring.percentText = entry[@"percent"];
            if (stale) ring.alphaValue = 0.55;
            [ring setAccessibilityElement:YES]; [ring setAccessibilityRole:NSAccessibilityStaticTextRole];
            [ring setAccessibilityLabel:[NSString stringWithFormat:@"%@ · %@ · %@", card[@"name"], entry[@"title"], QGL(@"widget.titleRemaining")]];
            [ring setAccessibilityValue:entry[@"percent"]];
            [ring setAccessibilityHelp:entry[@"help"]];
            [self addSubview:ring];
            QGInsightLabel(self, entry[@"title"], NSMakeRect(detailX, rowY + (wide ? 6 : 1), detailWidth, 17), 11, NO);
            NSTextField *reset = QGInsightLabel(self, entry[@"reset"], NSMakeRect(detailX, rowY + (wide ? 28 : 21), detailWidth, 28), 10, YES);
            reset.maximumNumberOfLines = 2; reset.lineBreakMode = NSLineBreakByWordWrapping;
            reset.toolTip = entry[@"help"]; [reset setAccessibilityHelp:entry[@"help"]];
        }
        if (entries.count) {
            NSTextField *source = QGInsightLabel(self, card[@"source"], NSMakeRect(22, y+height-19, 291, 14), 9.5, YES);
            source.toolTip = card[@"help"];
        }
        y += height + 8;
    }
    self.frame = NSMakeRect(0, 0, 336, y+2);
    self.needsDisplay = YES;
}
@end

@interface QGTrendView : NSView
@property NSArray *history;
@property NSString *provider;
@property NSDate *now;
@property NSArray *buckets;
@property NSDate *start;
@property BOOL tokens;
@property BOOL hourly;
@property NSString *emptyText;
@property NSMutableArray<NSString *> *tips;
@end
@implementation QGTrendView
- (BOOL)isFlipped { return YES; }
- (void)drawText:(NSString *)text at:(NSPoint)point {
    [text drawAtPoint:point withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
}
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    (void)view; (void)tag; (void)point;
    NSUInteger index = (NSUInteger)data;
    return index < _tips.count ? _tips[index] : @"";
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self removeAllToolTips]; _tips = [NSMutableArray array];
    NSRect plot = NSMakeRect(38, 12, self.bounds.size.width-50, self.bounds.size.height-38);
    double max = 100;
    if (_tokens) {
        max = 1;
        for (NSDictionary *bucket in _buckets) max = MAX(max, [bucket[@"value"] doubleValue]);
    }
    for (NSUInteger index = 0; index < 3; index++) {
        CGFloat y = plot.origin.y + plot.size.height * index / 2;
        [[NSColor.labelColor colorWithAlphaComponent:0.08] setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(plot.origin.x, y)]; [line lineToPoint:NSMakePoint(NSMaxX(plot), y)]; [line stroke];
        [self drawText:_tokens ? QGTokenText(max * (1-index/2.0)) : [NSString stringWithFormat:@"%.0f%%", max * (1-index/2.0)] at:NSMakePoint(0, y-6)];
    }
    NSDateFormatter *formatter = [NSDateFormatter new];
    [formatter setLocalizedDateFormatFromTemplate:_tokens && !_hourly ? @"Md" : @"jm"];
    NSTimeInterval end = _now.timeIntervalSince1970;
    NSTimeInterval start = _tokens ? _start.timeIntervalSince1970 : end-86400;
    double span = MAX(1, end-start);
    [self drawText:_tokens ? [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:start]] : @"−24h" at:NSMakePoint(plot.origin.x, NSMaxY(plot)+8)];
    NSDate *lastLabelDate = _tokens && !_hourly ? [_now dateByAddingTimeInterval:-1] : _now;
    [self drawText:_tokens ? [formatter stringFromDate:lastLabelDate] : @"0h" at:NSMakePoint(NSMaxX(plot)-45, NSMaxY(plot)+8)];
    for (NSUInteger tick = 1; tick <= 3; tick++) {
        double t = start + span * tick/4.0;
        [self drawText:_tokens ? [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]] : [NSString stringWithFormat:@"−%luh", 24-tick*6]
            at:NSMakePoint(plot.origin.x + plot.size.width*tick/4.0-13, NSMaxY(plot)+8)];
    }
    NSUInteger points = 0;
    if (_tokens) {
        double bucketWidth = _hourly ? 3600 : 86400;
        CGFloat width = MAX(2, MIN(14, plot.size.width * bucketWidth / span * 0.33));
        for (NSDictionary *bucket in _buckets) {
            BOOL claude = [bucket[@"provider"] isEqual:@"claude"];
            double fraction = MIN(1, MAX(0, ([bucket[@"t"] doubleValue]-start+MIN(bucketWidth/2, span/2))/span));
            CGFloat x = plot.origin.x + (plot.size.width-2*width)*fraction + (claude ? width : 0);
            CGFloat height = plot.size.height * [bucket[@"value"] doubleValue] / max;
            NSRect rect = NSMakeRect(x, NSMaxY(plot)-height, width-1, height);
            [[QGServiceColor(claude) colorWithAlphaComponent:0.85] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:2 yRadius:2] fill];
            NSString *tip = [NSString stringWithFormat:@"%@ · %@ · %.0f tokens", claude ? @"Claude" : @"Codex",
                bucket[@"date"] ?: [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[bucket[@"t"] doubleValue]]], [bucket[@"value"] doubleValue]];
            [_tips addObject:tip]; [self addToolTipRect:NSInsetRect(rect, -2, -3) owner:self userData:(void *)(_tips.count-1)];
            points++;
        }
    } else {
        for (NSNumber *duration in @[@300, @10080]) {
            NSColor *color = QGServiceColor([_provider isEqual:@"claude"]);
            [color setStroke]; [color setFill];
            for (NSArray *segment in QGInsightSegments(_history, _provider, duration.doubleValue, end)) {
                NSBezierPath *path = [NSBezierPath bezierPath]; path.lineWidth = 2;
                if (duration.intValue == 10080) { CGFloat dash[] = {5, 4}; [path setLineDash:dash count:2 phase:0]; }
                BOOL first = YES;
                for (NSDictionary *row in segment) {
                    NSPoint point = NSMakePoint(plot.origin.x + plot.size.width*([row[@"t"] doubleValue]-start)/span,
                        plot.origin.y + plot.size.height*(1-[row[@"remaining"] doubleValue]/100));
                    if (first) [path moveToPoint:point]; else [path lineToPoint:point];
                    first = NO; points++;
                    if (segment.count == 1) [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-2, point.y-2, 4, 4)] fill];
                    NSString *tip = [NSString stringWithFormat:@"%@ · %@ · %.0f%%", duration.intValue == 300 ? @"5h" : @"7d",
                        [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[row[@"t"] doubleValue]]], [row[@"remaining"] doubleValue]];
                    [_tips addObject:tip]; [self addToolTipRect:NSMakeRect(point.x-4, point.y-6, 8, 12) owner:self userData:(void *)(_tips.count-1)];
                }
                [path stroke];
            }
        }
    }
    if (!points) [self drawText:_emptyText ?: QGL(@"insights.noSamples") at:NSMakePoint(plot.origin.x+35, plot.origin.y+plot.size.height/2-6)];
}
@end

#import "QGDailyUsageUI.h"

@interface QGStatisticsView : NSView
@property NSArray *history;
@property NSDictionary *report;
@property BOOL loading;
@property BOOL recordHistory;
@property BOOL quotaRefreshing;
@property QGChoiceBar *tabs;
@property QGChoiceBar *range;
@property NSButton *recordButton;
@property NSPopUpButton *historyActions;
@property NSMenuItem *clearHistoryItem;
@property NSButton *refreshButton;
- (void)render;
@end
@implementation QGStatisticsView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds);
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _tabs = [[QGChoiceBar alloc] initWithLabels:@[QGL(@"insights.tokenTab"), QGL(@"insights.quotaTab")]
            frame:NSMakeRect(22, 16, 264, 32)];
        _tabs.selectedSegment = 0;
        _tabs.target = self; _tabs.action = @selector(changeTab:); [self addSubview:_tabs];
        _range = [[QGChoiceBar alloc] initWithLabels:@[QGL(@"insights.today"), @"3d", @"7d", @"30d"]
            frame:NSMakeRect(22, 58, 264, 30)];
        _range.target = self; _range.action = @selector(changeTab:); _range.selectedSegment = 2; [self addSubview:_range];
        _recordButton = [NSButton checkboxWithTitle:QGL(@"insights.recordShort") target:nil action:NULL];
        _recordButton.frame = NSMakeRect(302, 18, 206, 28); _recordButton.font = [NSFont systemFontOfSize:11]; [self addSubview:_recordButton];
        _historyActions = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(516, 18, 28, 28) pullsDown:YES];
        _historyActions.bordered = NO; ((NSPopUpButtonCell *)_historyActions.cell).arrowPosition = NSPopUpNoArrow;
        [_historyActions addItemWithTitle:@""];
        _historyActions.itemArray.firstObject.image = [NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:QGL(@"insights.manageHistory")];
        _historyActions.toolTip = QGL(@"insights.manageHistory"); [_historyActions setAccessibilityLabel:QGL(@"insights.manageHistory")];
        _clearHistoryItem = [[NSMenuItem alloc] initWithTitle:QGL(@"insights.clearHistory") action:@selector(clearQuotaHistory:) keyEquivalent:@""];
        [_historyActions.menu addItem:_clearHistoryItem]; [self addSubview:_historyActions];
        _refreshButton = QGSymbolButton(@"arrow.clockwise", QGL(@"menu.refresh"), NSMakeRect(553, 18, 32, 28));
        [self addSubview:_refreshButton];
        [self render];
    }
    return self;
}
- (void)changeTab:(id)sender { (void)sender; [self render]; }
- (void)render {
    self.needsDisplay = YES;
    for (NSView *view in self.subviews.copy) if (view != _tabs && view != _range && view != _refreshButton &&
        view != _recordButton && view != _historyActions) [view removeFromSuperview];
    BOOL tokens = _tabs.selectedSegment == 0;
    _range.hidden = !tokens;
    _recordButton.hidden = tokens; _historyActions.hidden = tokens;
    _recordButton.state = _recordHistory ? NSControlStateValueOn : NSControlStateValueOff;
    _refreshButton.enabled = tokens ? !_loading : !_quotaRefreshing;
    _refreshButton.toolTip = QGL(tokens ? @"insights.refreshTokens" : @"menu.refreshAll");
    NSDate *now = NSDate.date;
    double scannedAt = [_report[@"scannedAt"] doubleValue];
    if (tokens && scannedAt > 0) {
        NSDateFormatter *updatedFormat = [NSDateFormatter new]; [updatedFormat setLocalizedDateFormatFromTemplate:@"Mdjm"];
        NSString *time = [updatedFormat stringFromDate:[NSDate dateWithTimeIntervalSince1970:scannedAt]];
        NSString *label = [NSString stringWithFormat:QGL(@"widget.updatedAt"), time];
        if ([_report[@"stale"] boolValue]) label = [NSString stringWithFormat:@"%@ · %@", QGL(@"widget.cached"), label];
        NSTextField *updated = QGInsightLabel(self, label, NSMakeRect(304, 62, 280, 18), 10, YES);
        updated.alignment = NSTextAlignmentRight;
    }
    if (!tokens) {
        QGInsightLabel(self, QGL(_recordHistory ? @"insights.quotaHelp" : @"insights.recordPaused"), NSMakeRect(22, 60, 560, 34), 11, YES).maximumNumberOfLines = 2;
        CGFloat y = 105;
        for (NSString *provider in @[@"codex", @"claude"]) {
            QGInsightLabel(self, [provider isEqual:@"codex"] ? @"Codex" : @"Claude", NSMakeRect(22, y, 100, 20), 14, NO);
            BOOL five = NO, seven = NO;
            for (NSDictionary *row in _history) {
                if (![row[@"provider"] isEqual:provider]) continue;
                five |= [row[@"duration"] intValue] == 300; seven |= [row[@"duration"] intValue] == 10080;
            }
            NSMutableArray *periods = [NSMutableArray array];
            if (five) [periods addObject:QGL(@"insights.fiveLegend")];
            if (seven) [periods addObject:QGL(@"insights.sevenLegend")];
            NSTextField *legend = QGInsightLabel(self, [periods componentsJoinedByString:@" · "], NSMakeRect(280, y+1, 304, 18), 11, YES);
            legend.alignment = NSTextAlignmentRight;
            QGTrendView *chart = [[QGTrendView alloc] initWithFrame:NSMakeRect(22, y+25, 562, 136)];
            chart.history = _history ?: @[]; chart.provider = provider; chart.now = now;
            if (!_recordHistory) chart.emptyText = QGL(@"insights.pausedEmpty");
            [chart setAccessibilityLabel:[NSString stringWithFormat:@"%@ · %@", provider, QGL(@"insights.quotaTab")]];
            [self addSubview:chart]; y += 179;
        }
        return;
    }
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *today = [calendar startOfDayForDate:now];
    NSInteger days = [@[@1, @3, @7, @30][MAX(0, MIN(3, _range.selectedSegment))] integerValue];
    NSDate *start = [calendar dateByAddingUnit:NSCalendarUnitDay value:1-days toDate:today options:0];
    QGDailyUsageView *daily = [[QGDailyUsageView alloc] initWithReport:_report start:start now:now loading:_loading];
    daily.frame = NSMakeRect(0, 96, 608, 456); [self addSubview:daily];
}
@end
