// Manual quota is a display fallback, never an account connection or a Token record.
static BOOL QGHasManualQuota(NSArray<NSDictionary *> *windows) {
    for (NSDictionary *window in windows) if ([window[@"manual"] boolValue]) return YES;
    return NO;
}

static NSString *QGManualQuotaSource(NSArray<NSDictionary *> *windows) {
    if (!QGHasManualQuota(windows)) return nil;
    for (NSDictionary *window in windows) if (![window[@"manual"] boolValue]) return QGL(@"manual.mixedSource");
    return QGL(@"sync.manual");
}

static NSArray<NSDictionary *> *QGReplacingQuotaPeriod(NSArray<NSDictionary *> *windows, NSDictionary *replacement) {
    NSMutableArray *result = [NSMutableArray array];
    double period = [replacement[@"windowDurationMins"] doubleValue];
    for (NSDictionary *window in windows) {
        if (fabs([window[@"windowDurationMins"] doubleValue] - period) >= 0.5) [result addObject:window];
    }
    [result addObject:replacement];
    return result.copy;
}

static BOOL QGParseManualNumber(NSString *text, double *value) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return NO;
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.locale = NSLocale.currentLocale;
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.lenient = NO;
    NSRange range = NSMakeRange(0, trimmed.length);
    NSNumber *number = nil;
    if (![formatter getObjectValue:&number forString:trimmed range:&range error:nil] ||
        range.length != trimmed.length || !number || !isfinite(number.doubleValue)) return NO;
    if (value) *value = number.doubleValue;
    return YES;
}

@interface QGManualQuotaView : NSView
@property NSPopUpButton *providerChoice;
@property NSPopUpButton *periodChoice;
@property NSTextField *remainingField;
@property NSDatePicker *resetDatePicker;
@property NSDatePicker *resetTimePicker;
@property NSButton *unknownResetButton;
@property NSDictionary<NSString *, NSArray<NSDictionary *> *> *providerWindows;
@property NSTimeInterval loadedResetAt;
- (instancetype)initWithProvider:(NSString *)provider windows:(NSDictionary *)windows;
- (NSString *)provider;
- (void)selectionChanged:(id)sender;
- (NSDictionary *)windowAtDate:(NSDate *)date error:(NSString **)error;
@end

@implementation QGManualQuotaView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithProvider:(NSString *)provider windows:(NSDictionary *)windows {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 360, 260)])) {
        _providerWindows = windows.copy;
        _providerChoice = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [_providerChoice addItemsWithTitles:@[@"Codex", @"Claude"]];
        [_providerChoice selectItemAtIndex:[provider isEqual:@"claude"] ? 1 : 0];
        _periodChoice = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [_periodChoice addItemsWithTitles:@[QGL(@"manual.fiveHours"), QGL(@"manual.sevenDays")]];
        // Prefer an available period without assuming that a missing one is 100%.
        NSArray *initial = windows[self.provider];
        BOOL hasFive = NO, hasSeven = NO;
        for (NSDictionary *window in initial) {
            double minutes = [window[@"windowDurationMins"] doubleValue];
            hasFive |= fabs(minutes - 300) < 0.5; hasSeven |= fabs(minutes - 10080) < 0.5;
        }
        if (!hasFive && hasSeven) [_periodChoice selectItemAtIndex:1];
        _remainingField = [NSTextField textFieldWithString:@""];
        _remainingField.placeholderString = @"0–100";
        _resetDatePicker = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
        _resetDatePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
        _resetDatePicker.datePickerElements = NSDatePickerElementFlagYearMonthDay;
        _resetTimePicker = [[NSDatePicker alloc] initWithFrame:NSZeroRect];
        _resetTimePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
        _resetTimePicker.datePickerElements = NSDatePickerElementFlagHourMinuteSecond;
        NSArray *controls = @[_providerChoice, _periodChoice, _remainingField, _resetDatePicker, _resetTimePicker];
        NSArray *labels = @[QGL(@"manual.provider"), QGL(@"manual.period"), QGL(@"manual.remainingLabel"),
            QGL(@"manual.resetDateLabel"), QGL(@"manual.resetTimeLabel")];
        for (NSUInteger i = 0; i < controls.count; i++) {
            NSTextField *label = [NSTextField labelWithString:labels[i]];
            label.frame = NSMakeRect(0, 7 + i * 36, 150, 22);
            label.font = [NSFont systemFontOfSize:12];
            NSControl *control = controls[i]; control.frame = NSMakeRect(158, 3 + i * 36, 200, 28);
            [control setAccessibilityLabel:labels[i]];
            [self addSubview:label]; [self addSubview:control];
        }
        _unknownResetButton = [NSButton checkboxWithTitle:QGL(@"manual.unknownReset") target:self action:@selector(toggleUnknownReset:)];
        _unknownResetButton.frame = NSMakeRect(158, 185, 200, 24);
        [self addSubview:_unknownResetButton];
        NSTextField *hint = [NSTextField wrappingLabelWithString:QGL(@"manual.resetHelp")];
        hint.font = [NSFont systemFontOfSize:11]; hint.textColor = NSColor.secondaryLabelColor;
        hint.frame = NSMakeRect(0, 219, 358, 38); [self addSubview:hint];
        _providerChoice.target = _periodChoice.target = self;
        _providerChoice.action = _periodChoice.action = @selector(selectionChanged:);
        [self selectionChanged:nil];
    }
    return self;
}
- (NSString *)provider { return _providerChoice.indexOfSelectedItem == 1 ? @"claude" : @"codex"; }
- (void)toggleUnknownReset:(id)sender {
    (void)sender;
    BOOL known = _unknownResetButton.state != NSControlStateValueOn;
    _resetDatePicker.enabled = known;
    _resetTimePicker.enabled = known;
}
- (void)selectionChanged:(id)sender {
    (void)sender;
    NSDictionary *selected = nil;
    double minutes = _periodChoice.indexOfSelectedItem == 1 ? 10080 : 300;
    for (NSDictionary *window in _providerWindows[self.provider]) {
        if (fabs([window[@"windowDurationMins"] doubleValue] - minutes) < 0.5) { selected = window; break; }
    }
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.locale = NSLocale.currentLocale; formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO; formatter.maximumFractionDigits = 2;
    _remainingField.stringValue = selected ? [formatter stringFromNumber:selected[@"remainingPercent"]] : @"";
    _loadedResetAt = [selected[@"resetsAt"] doubleValue];
    NSDate *proposal = _loadedResetAt > 0 ? [NSDate dateWithTimeIntervalSince1970:_loadedResetAt]
        : [NSDate dateWithTimeIntervalSinceNow:minutes * 60.0];
    _resetDatePicker.dateValue = proposal;
    _resetTimePicker.dateValue = proposal;
    _unknownResetButton.state = _loadedResetAt > 0 ? NSControlStateValueOff : NSControlStateValueOn;
    [self toggleUnknownReset:nil];
}
- (NSDictionary *)windowAtDate:(NSDate *)date error:(NSString **)error {
    double remaining = 0;
    if (!QGParseManualNumber(_remainingField.stringValue, &remaining) || remaining < 0 || remaining > 100) {
        if (error) *error = QGL(@"manual.invalidPercent"); return nil;
    }
    double reset = 0;
    if (_unknownResetButton.state != NSControlStateValueOn) {
        NSCalendar *calendar = NSCalendar.currentCalendar;
        NSDateComponents *day = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
            fromDate:_resetDatePicker.dateValue];
        NSDateComponents *time = [calendar components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond
            fromDate:_resetTimePicker.dateValue];
        day.hour = time.hour; day.minute = time.minute; day.second = time.second;
        NSDate *chosen = [calendar dateFromComponents:day];
        NSDateComponents *confirmed = chosen ? [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
            NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:chosen] : nil;
        if (!chosen || confirmed.year != day.year || confirmed.month != day.month || confirmed.day != day.day ||
            confirmed.hour != day.hour || confirmed.minute != day.minute || confirmed.second != day.second ||
            chosen.timeIntervalSince1970 <= date.timeIntervalSince1970 ||
            chosen.timeIntervalSince1970 > date.timeIntervalSince1970 + 365.0 * 86400.0) {
            if (error) *error = QGL(@"manual.invalidResetTime"); return nil;
        }
        reset = chosen.timeIntervalSince1970;
        if (_loadedResetAt > 0) {
            NSDateComponents *original = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond
                fromDate:[NSDate dateWithTimeIntervalSince1970:_loadedResetAt]];
            if ([original isEqual:confirmed]) reset = _loadedResetAt;
        }
    }
    BOOL weekly = _periodChoice.indexOfSelectedItem == 1;
    return @{@"usedPercent": @(100 - remaining), @"remainingPercent": @(remaining), @"resetsAt": @(reset),
        @"windowDurationMins": weekly ? @10080 : @300, @"kind": weekly ? @"secondary" : @"primary", @"manual": @YES};
}
@end
