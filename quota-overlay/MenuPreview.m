// Production UI, synthetic fixtures only. Never reads accounts or writes preferences.
#define main GaugeHostMain
#import "main.m"
#undef main

@interface QGPreviewStack : NSView
@end
@implementation QGPreviewStack
- (BOOL)isFlipped { return YES; }
@end

@interface QGTrackingProbe : NSMenu
@property NSUInteger cancellations;
@end
@implementation QGTrackingProbe
- (void)cancelTracking { _cancellations++; }
@end

// Exercise the production button/keyboard routing without persisting a choice,
// fetching accounts, or triggering a real connection consent dialog.
@interface QGMenuActionProbe : QGAppDelegate
@property NSString *receivedProvider;
@property BOOL simulateConsent;
@property NSUInteger refreshCalls;
@property NSInteger receivedDisplayMode;
@property NSInteger receivedQuotaStyle;
@property NSInteger receivedAppearanceMode;
@property NSInteger receivedLanguageMode;
@end
@implementation QGMenuActionProbe
- (BOOL)needsClaudeConnectionForProvider:(NSString *)provider { return _simulateConsent && [provider isEqual:@"claude"]; }
- (void)refreshQuota:(id)sender {
    (void)sender; _refreshCalls++; self.syncInProgress = YES; [self updateStatusItem];
}
- (void)refreshDailyUsageForced:(BOOL)forced { (void)forced; }
- (void)changeDisplayMode:(NSButton *)sender { _receivedDisplayMode = sender.tag; }
- (void)changeQuotaStyle:(NSButton *)sender { _receivedQuotaStyle = sender.tag; }
- (void)changeAppearanceMode:(NSButton *)sender { _receivedAppearanceMode = sender.tag; }
- (void)changeLanguageMode:(NSButton *)sender { _receivedLanguageMode = sender.tag; }
- (void)selectProvider:(NSMenuItem *)sender {
    self.receivedProvider = sender.representedObject;
    self.selectedProvider = sender.representedObject;
    [self.providerSwitchView configureSelectedProvider:self.selectedProvider claudeEnabled:YES];
}
@end

@interface QGRouteProbe : QGAppDelegate
@property NSUInteger statisticsOpens;
@property NSInteger tabAtOpen;
@end
@implementation QGRouteProbe
- (void)showStatistics:(id)sender {
    (void)sender; self.statisticsOpens++; self.tabAtOpen = self.statisticsView.tabs.selectedSegment;
}
@end

@interface QGManualSaveProbe : QGAppDelegate
@property NSUInteger publications;
@end
@implementation QGManualSaveProbe
- (void)publishWidgetSnapshot { _publications++; }
- (void)requestNativeWidgetReload:(BOOL)userInitiated { (void)userInitiated; }
- (void)updateStatusItem {}
@end

static BOOL WithinBounds(NSView *view) {
    // Native controls own private focus/label subviews that may extend a few
    // points beyond their bounds. Validate our layout, not AppKit internals.
    if ([view isKindOfClass:NSControl.class]) return YES;
    for (NSView *child in view.subviews) {
        if (!NSContainsRect(view.bounds, child.frame) || !WithinBounds(child)) {
            fprintf(stderr, "Clipped subview: %s\n", NSStringFromRect(child.frame).UTF8String); return NO;
        }
    }
    return YES;
}

static BOOL Render(NSView *view, NSString *directory, NSString *filename, NSString *appearanceName) {
    NSAppearance *appearance = [NSAppearance appearanceNamed:appearanceName]; view.appearance = appearance;
    __block BOOL wrote = NO;
    [appearance performAsCurrentDrawingAppearance:^{
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:(NSInteger)view.frame.size.width*2 pixelsHigh:(NSInteger)view.frame.size.height*2
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        bitmap.size = view.frame.size;
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
        [NSColor.windowBackgroundColor setFill]; NSRectFill(view.bounds);
        [view displayRectIgnoringOpacity:view.bounds inContext:NSGraphicsContext.currentContext];
        [NSGraphicsContext restoreGraphicsState];
        wrote = [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[directory stringByAppendingPathComponent:filename] atomically:YES];
    }];
    return wrote && WithinBounds(view);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 1;
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if ([@(argv[1]) isEqual:@"--live-daily-probe"]) {
            QGAppDelegate *reader = [QGAppDelegate new];
            NSString *binary = reader.codexBinaryPath;
            NSDictionary *result = binary ? [reader readCodexResultUsingBinary:binary method:@"account/usage/read" error:nil] : nil;
            NSDictionary *report = QGDailyReport(result, QGReadClaudeDailyCache([NSHomeDirectory() stringByAppendingPathComponent:@".claude"]), NSDate.date);
            printf("Production daily reader: codex days=%lu, official summary fields=%lu, claude available=%d\n",
                (unsigned long)[report[@"providers"][@"codex"][@"days"] count],
                (unsigned long)[report[@"codexSummary"] count], [report[@"providers"][@"claude"][@"available"] boolValue]);
            return [report[@"codexSummary"] count] == 5 ? 0 : 1;
        }
        NSString *directory = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        QGAppDelegate *delegate = [QGAppDelegate new];
        delegate.selectedProvider = @"claude"; delegate.codexPlanName = @"Pro 5×"; delegate.claudePlanName = @"Max 20×";
        delegate.claudeSourceKind = @"anthropic";
        delegate.syncState = delegate.claudeSyncState = QGSyncStateSuccess;
        delegate.lastSuccessfulSync = delegate.claudeLastSuccessfulSync = NSDate.date;
        double now = NSDate.date.timeIntervalSince1970;
        NSDictionary *(^window)(double, double, double) = ^NSDictionary *(double percent, double duration, double reset) {
            return @{@"remainingPercent": @(percent), @"windowDurationMins": @(duration), @"resetsAt": @(reset), @"kind": @"primary"};
        };
        NSArray *codex = @[window(18, 300, now+7000), window(51, 10080, now+4*86400)];
        NSArray *claude = @[window(100, 300, 0), window(76, 10080, now+2*86400)];
        [delegate applyWindows:codex]; [delegate applyClaudeWindows:claude];
        delegate.statusMenu = [delegate makeMenu]; [delegate updateStatusItem];
        NSUInteger failures = 0;
        __block NSUInteger interactionChecks = 0;
        __block NSUInteger interactionFailures = 0;
        void (^check)(BOOL, NSString *) = ^(BOOL pass, NSString *name) {
            interactionChecks++; if (!pass) interactionFailures++;
            printf("%s %s\n", pass ? "PASS" : "FAIL", name.UTF8String);
        };
        NSDictionary *weeklyEntry = [delegate menuCardForProvider:@"codex" enabled:YES][@"entries"][1];
        NSString *weeklyCountdown = [delegate relativeDuration:
            [codex[1][@"resetsAt"] doubleValue] - NSDate.date.timeIntervalSince1970 maximumUnits:2];
        check([weeklyEntry[@"reset"] containsString:weeklyCountdown] &&
            [weeklyEntry[@"reset"] containsString:@" · "] &&
            [weeklyEntry[@"resetCompact"] containsString:weeklyCountdown] &&
            ![weeklyEntry[@"resetCompact"] containsString:@" · "],
            @"menu bar shows relative weekly reset; rings prioritize countdown over date");
        NSArray *claudeEntries = [delegate menuCardForProvider:@"claude" enabled:YES][@"entries"];
        NSString *claudeCountdown = [delegate relativeDuration:
            [claude[1][@"resetsAt"] doubleValue] - NSDate.date.timeIntervalSince1970 maximumUnits:2];
        check([claudeEntries[1][@"reset"] containsString:claudeCountdown] &&
            [claudeEntries[1][@"resetCompact"] containsString:claudeCountdown] &&
            [claudeEntries[0][@"reset"] containsString:QGL(@"quota.resetUnknown")],
            @"Claude shows a real countdown but never guesses a missing reset time");
        NSDictionary *expiredWindow = window(51, 10080, now-60);
        NSDictionary *unknownWindow = window(51, 10080, 0);
        check([[delegate menuResetTextForWindow:expiredWindow] isEqual:QGL(@"quota.awaitingRefreshShort")] &&
            [[delegate menuCompactResetTextForWindow:expiredWindow] isEqual:QGL(@"quota.awaitingRefreshShort")] &&
            [[delegate menuResetTextForWindow:unknownWindow] containsString:QGL(@"quota.resetUnknown")],
            @"expired or unknown reset never displays a fabricated countdown");
        NSURL *dailyRoute = [NSURL URLWithString:@"gaugeforcodex://insights/daily-token"];
        check(QGIsDailyTokenURL(dailyRoute) &&
            !QGIsDailyTokenURL([NSURL URLWithString:@"gaugeforcodex://insights/quota"]) &&
            !QGIsDailyTokenURL([NSURL URLWithString:@"https://insights/daily-token"]),
            @"only the Daily Token deep link matches the widget route");
        QGRouteProbe *routeProbe = [QGRouteProbe new];
        routeProbe.statisticsView = [[QGStatisticsView alloc] initWithFrame:NSMakeRect(0, 0, 608, 552)];
        routeProbe.statisticsView.tabs.selectedSegment = 1;
        [routeProbe application:NSApp openURLs:@[dailyRoute]];
        check(routeProbe.pendingDailyTokenOpen && routeProbe.statisticsOpens == 0,
            @"cold-launch widget link waits until the menu app is ready");
        routeProbe.appReady = YES; [routeProbe openPendingDailyTokenIfReady];
        check(routeProbe.statisticsOpens == 1 && routeProbe.tabAtOpen == 0 && !routeProbe.pendingDailyTokenOpen,
            @"widget link opens the Daily Token tab, not quota trends");
        [routeProbe application:NSApp openURLs:@[[NSURL URLWithString:@"gaugeforcodex://insights/quota"]]];
        check(routeProbe.statisticsOpens == 1, @"unknown widget routes do not open a window");
        QGManualQuotaView *manual = [[QGManualQuotaView alloc] initWithProvider:@"claude"
            windows:@{@"codex": codex, @"claude": claude}];
        check([manual.provider isEqual:@"claude"] && [manual.remainingField.stringValue isEqual:@"100"],
            @"manual editor opens on active Claude with remaining, not used, percentage");
        check(manual.unknownResetButton.state == NSControlStateValueOn && !manual.resetTimePicker.enabled,
            @"an unknown reset is explicit and disables date and time selection");
        [manual.periodChoice selectItemAtIndex:1]; [manual selectionChanged:nil];
        NSDictionary *unchanged = [manual windowAtDate:NSDate.date error:nil];
        check([unchanged[@"remainingPercent"] doubleValue] == 76 && [unchanged[@"resetsAt"] doubleValue] == now+2*86400 &&
            manual.unknownResetButton.state == NSControlStateValueOff && manual.resetTimePicker.enabled,
            @"changing period loads Claude weekly value and preserves its exact reset");
        [manual.providerChoice selectItemAtIndex:0]; [manual selectionChanged:nil];
        check([manual.remainingField.stringValue isEqual:@"51"], @"changing service loads its own period, no cross-service leakage");
        manual.unknownResetButton.state = NSControlStateValueOn; [manual toggleUnknownReset:nil];
        manual.remainingField.stringValue = @"35";
        NSDictionary *manualWindow = [manual windowAtDate:NSDate.date error:nil];
        check([manualWindow[@"remainingPercent"] doubleValue] == 35 && [manualWindow[@"usedPercent"] doubleValue] == 65 &&
            [manualWindow[@"resetsAt"] doubleValue] == 0 && [manualWindow[@"manual"] boolValue] &&
            [manualWindow[@"windowDurationMins"] intValue] == 10080, @"manual weekly data has explicit provenance and supports unknown reset");
        for (NSString *invalid in @[@"", @"-1", @"101", @"NaN", @"inf", @"23xyz"]) {
            manual.remainingField.stringValue = invalid;
            check([manual windowAtDate:NSDate.date error:nil] == nil, @"reject invalid remaining percentage");
        }
        for (NSString *valid in @[@"0", @"100"]) {
            manual.remainingField.stringValue = valid;
            check([manual windowAtDate:NSDate.date error:nil] != nil, @"accept zero and full remaining quota");
        }
        manual.unknownResetButton.state = NSControlStateValueOff; [manual toggleUnknownReset:nil];
        NSDate *target = [NSDate dateWithTimeIntervalSince1970:floor(now) + 2*3600 + 37];
        manual.resetDatePicker.dateValue = target;
        manual.resetTimePicker.dateValue = target;
        check(fabs([[manual windowAtDate:[NSDate dateWithTimeIntervalSince1970:now] error:nil][@"resetsAt"] doubleValue] - target.timeIntervalSince1970) < 0.01,
            @"date and hour-minute-second pickers save the selected absolute time");
        check((manual.resetTimePicker.datePickerElements & NSDatePickerElementFlagHourMinuteSecond) == NSDatePickerElementFlagHourMinuteSecond,
            @"time picker exposes hours, minutes, and seconds");
        NSDate *past = [NSDate dateWithTimeIntervalSince1970:now - 3600];
        manual.resetDatePicker.dateValue = past; manual.resetTimePicker.dateValue = past;
        check([manual windowAtDate:[NSDate dateWithTimeIntervalSince1970:now] error:nil] == nil,
            @"past reset date is rejected");
        NSDate *tooFar = [NSDate dateWithTimeIntervalSince1970:now + 366*86400];
        manual.resetDatePicker.dateValue = tooFar; manual.resetTimePicker.dateValue = tooFar;
        check([manual windowAtDate:[NSDate dateWithTimeIntervalSince1970:now] error:nil] == nil,
            @"reset date beyond one year is rejected");
        manual.unknownResetButton.state = NSControlStateValueOn; [manual toggleUnknownReset:nil];
        check([[manual windowAtDate:NSDate.date error:nil][@"resetsAt"] doubleValue] == 0,
            @"unknown reset does not save the disabled picker proposal");
        QGManualQuotaView *missingManual = [[QGManualQuotaView alloc] initWithProvider:@"claude" windows:@{}];
        check(missingManual.remainingField.stringValue.length == 0 && [missingManual windowAtDate:NSDate.date error:nil] == nil,
            @"missing quotas remain blank, never fabricate 100 percent");
        QGManualQuotaView *weeklyManual = [[QGManualQuotaView alloc] initWithProvider:@"codex" windows:@{@"codex": @[codex[1]]}];
        check(weeklyManual.periodChoice.indexOfSelectedItem == 1, @"weekly-only account defaults to its available period");
        NSArray *merged = QGReplacingQuotaPeriod(claude, manualWindow);
        check(merged.count == 2 && [merged containsObject:claude[0]] && [merged containsObject:manualWindow],
            @"manual save replaces only the selected period and retains the other period");
        check(QGReplacingQuotaPeriod(merged, manualWindow).count == 2, @"repeat edits do not duplicate periods");
        check([QGNormalizedWindow(manualWindow, @"secondary")[@"manual"] boolValue], @"manual provenance survives cache normalization");
        NSString *suite = [@"com.qingtanlabs.manual-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *isolated = [[NSUserDefaults alloc] initWithSuiteName:suite];
        QGManualSaveProbe *manualProbe = [QGManualSaveProbe new];
        [manualProbe applyWindows:codex]; [manualProbe applyClaudeWindows:claude];
        manualProbe.codexPlanName = @"Pro 5×"; manualProbe.claudePlanName = @"Pro";
        manualProbe.claudeLastError = @"old failure";
        [manualProbe saveManualWindow:manualWindow provider:@"claude" preferences:isolated];
        check([manualProbe.quotaWindows isEqual:codex] && [manualProbe.claudeWindows isEqual:merged] &&
            [[isolated arrayForKey:QGClaudeWindowsKey] isEqual:merged] && [isolated objectForKey:QGWindowsKey] == nil,
            @"Claude manual save persists Claude only and leaves Codex untouched");
        check([isolated objectForKey:QGClaudeEnabledKey] == nil && manualProbe.hasClaudeDisplayData &&
            ![manualProbe needsClaudeConnectionForProvider:@"claude"], @"manual Claude can display without enabling credential access");
        check(manualProbe.claudeLastError == nil && [manualProbe.claudePlanName isEqual:@"Pro"] && manualProbe.publications == 1,
            @"manual save clears old error, preserves verified plan, publishes widget data");
        NSDictionary *manualCard = [manualProbe menuCardForProvider:@"claude" enabled:YES];
        check([manualCard[@"source"] containsString:QGL(@"manual.mixedSource")] &&
            [[manualCard[@"entries"] lastObject][@"title"] containsString:QGL(@"manual.short")],
            @"mixed manual and official periods are labelled explicitly");
        [manualProbe saveManualWindow:manualWindow provider:@"codex" preferences:isolated];
        check([[isolated arrayForKey:QGWindowsKey] count] == 2 && [manualProbe.claudeWindows isEqual:merged] &&
            [manualProbe.codexPlanName isEqual:@"Pro 5×"], @"Codex manual save retains Claude and the other Codex period");
        check([isolated objectForKey:QGHistoryKey] == nil,
            @"manual quota never creates quota history");
        [manualProbe applyClaudeWindows:claude];
        check(!QGHasManualQuota(manualProbe.claudeWindows), @"successful automatic replacement removes manual provenance");
        [isolated removePersistentDomainForName:suite];
        QGMenuActionProbe *probe = [QGMenuActionProbe new];
        NSMenu *originalMenu = [probe makeMenu];
        QGTrackingProbe *tracking = [QGTrackingProbe new];
        for (NSMenuItem *item in originalMenu.itemArray.copy) { [originalMenu removeItem:item]; [tracking addItem:item]; }
        probe.statusMenu = tracking;
        [probe.menuQuotaView configureWithCards:delegate.menuQuotaView.cards];
        check(probe.statusMenu.itemArray.firstObject.view == probe.providerSwitchView, @"provider switch is the first menu item");
        check(probe.codexProviderMenuItem.hidden && probe.claudeProviderMenuItem.hidden &&
            probe.codexProviderMenuItem.allowsKeyEquivalentWhenHidden && probe.claudeProviderMenuItem.allowsKeyEquivalentWhenHidden,
            @"keyboard commands retained without duplicate visible menu rows");
        [probe.providerSwitchView configureSelectedProvider:@"codex" claudeEnabled:NO];
        check(probe.providerSwitchView.codexButton.state == NSControlStateValueOn &&
            probe.providerSwitchView.claudeButton.state == NSControlStateValueOff, @"Codex selection is explicit");
        check(probe.providerSwitchView.claudeButton.enabled &&
            [probe.providerSwitchView.claudeButton.toolTip containsString:QGL(@"insights.providerConnectHelp")],
            @"unconnected Claude remains actionable and explains consent");
        NSArray *cardsBefore = probe.menuQuotaView.cards;
        for (NSButton *button in @[probe.providerSwitchView.claudeButton, probe.providerSwitchView.codexButton]) {
            [button performClick:nil];
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            NSString *provider = button == probe.providerSwitchView.claudeButton ? @"claude" : @"codex";
            check([probe.receivedProvider isEqual:provider] && button.state == NSControlStateValueOn,
                [provider stringByAppendingString:@" button dispatches the existing selection path"]);
        }
        check(probe.menuQuotaView.cards == cardsBefore && cardsBefore.count == 2, @"switching preserves both quota cards");
        check(tracking.cancellations == 0, @"normal provider clicks keep menu open");
        for (NSString *key in @[@"1", @"2"]) {
            NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
                timestamp:0 windowNumber:0 context:nil characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:0];
            BOOL handled = [probe.statusMenu performKeyEquivalent:event];
            check(handled && [probe.receivedProvider isEqual:[key isEqual:@"1"] ? @"codex" : @"claude"],
                [@"Command-" stringByAppendingString:key]);
        }
        probe.simulateConsent = YES;
        [probe.providerSwitchView.claudeButton performClick:nil];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        check(tracking.cancellations == 1, @"only connection consent ends tracking");
        probe.simulateConsent = NO;
        [probe.providerSwitchView.refreshButton performClick:nil];
        check(probe.refreshCalls == 1 && probe.providerSwitchView.refreshing && probe.providerSwitchView.spinner.isHidden == NO,
            @"refresh action starts visible busy state");
        [probe refreshFromMenu:probe.providerSwitchView.refreshButton];
        check(probe.refreshCalls == 1 && tracking.cancellations == 1, @"refresh neither duplicates requests nor closes menu");
        probe.syncInProgress = NO; probe.claudeSyncInProgress = YES; [probe updateStatusItem];
        check(probe.providerSwitchView.refreshing, @"spinner stays active until both services finish");
        probe.claudeSyncInProgress = NO; [probe updateStatusItem];
        check(!probe.providerSwitchView.refreshing && probe.providerSwitchView.refreshButton.enabled, @"refresh recovers after completion");
        check(probe.refreshMenuItem.hidden && probe.refreshMenuItem.allowsKeyEquivalentWhenHidden, @"refresh command retained without menu row");
        NSEvent *refreshKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
            timestamp:0 windowNumber:0 context:nil characters:@"r" charactersIgnoringModifiers:@"r" isARepeat:NO keyCode:15];
        check([probe.statusMenu performKeyEquivalent:refreshKey] && probe.refreshCalls == 2, @"Command-R refreshes");
        check(probe.settingsMenuItem.submenu == nil && probe.settingsMenuItem.action == @selector(showSettings:) &&
            [probe.settingsMenuItem.keyEquivalent isEqual:@","], @"settings opens one window, with Command-comma");
        check(probe.settingsMenuItem.hidden && probe.settingsMenuItem.allowsKeyEquivalentWhenHidden &&
            probe.providerSwitchView.settingsButton.action == @selector(showSettings:) && probe.providerSwitchView.settingsButton.target == probe,
            @"settings gear replaces the full row and keeps its command");
        QGSettingsView *settings = [[QGSettingsView alloc] initWithFrame:NSMakeRect(0, 0, 536, 566)];
        settings.actionTarget = probe;
        NSDictionary *settingsModel = @{@"displayMode": @0, @"alerts": @NO, @"claudeEnabled": @YES,
            @"appearanceMode": @"system", @"languageMode": @"system",
            @"codexStatus": QGL(@"settings.hasData"), @"claudeStatus": QGL(@"settings.hasData"),
            @"codexDetail": QGL(@"settings.codexSource"), @"claudeDetail": QGL(@"settings.claudeSource"),
            @"automaticUpdates": @YES, @"installing": @NO, @"updateBusy": @NO,
            @"updateButton": QGL(@"menu.checkUpdates"), @"updateStatus": QGL(@"settings.updateOnDemand"),
            @"version": @"AgentReadout · 2.0.0 (build 34)"};
        settings.configuration = settingsModel;
        check(settings.loginButton.action == @selector(toggleLoginItem:) && settings.loginButton.state == NSControlStateValueOff,
            @"login startup is an explicit default-off setting");
        check(settings.quotaStyleChoice.selectedSegment == 0 &&
            [settings.quotaStyleChoice.buttons[0].title isEqual:QGL(@"settings.styleBar")],
            @"progress bars are the first and default style");
        NSMutableDictionary *ringSettings = settingsModel.mutableCopy; ringSettings[@"quotaStyle"] = @"ring";
        settings.configuration = ringSettings;
        check(settings.quotaStyleChoice.selectedSegment == 1, @"saved ring preference is restored");
        settings.configuration = settingsModel;
        [settings.displayChoice.buttons[1] performClick:nil];
        check(probe.receivedDisplayMode == 1, @"display choice reuses tagged display action");
        check(settings.alertsButton.action == @selector(toggleQuotaAlerts:), @"notification toggle keeps consent action");
        for (NSNumber *style in @[@1, @0]) {
            [settings.quotaStyleChoice.buttons[style.integerValue] performClick:nil];
            check(probe.receivedQuotaStyle == style.integerValue && settings.quotaStyleChoice.selectedSegment == style.integerValue,
                @"quota style buttons dispatch both directions");
        }
        check(QGQuotaRingFraction(0) == 0 && QGQuotaRingFraction(100) == 1 && QGQuotaRingFraction(1) == 0.01,
              @"AppKit ring geometry honors zero, one and full quotas");
        check(QGQuotaRingFraction(-5) == 0 && QGQuotaRingFraction(105) == 1 && QGQuotaRingFraction(NAN) == 0,
              @"AppKit ring geometry clamps malformed data");
        [settings.tabs.buttons[1] performClick:nil];
        check(settings.tabs.selectedSegment == 1 && settings.appearanceChoice.selectedSegment == 0 &&
            settings.languageChoice.selectedSegment == 0, @"appearance and language default to system");
        [settings.appearanceChoice.buttons[2] performClick:nil];
        [settings.languageChoice.buttons[1] performClick:nil];
        check(probe.receivedAppearanceMode == 2 && probe.receivedLanguageMode == 1,
            @"appearance and language controls dispatch independent choices");
        NSMutableDictionary *personalized = settingsModel.mutableCopy;
        personalized[@"appearanceMode"] = @"dark"; personalized[@"languageMode"] = @"zh-Hans";
        settings.configuration = personalized;
        check(settings.appearanceChoice.selectedSegment == 2 && settings.languageChoice.selectedSegment == 1,
            @"saved appearance and language choices are restored");
        settings.configuration = settingsModel;
        [settings.tabs.buttons[2] performClick:nil];
        check(settings.tabs.selectedSegment == 2 && settings.claudeButton != nil && settings.manualButton == nil,
            @"service page opens with advanced data collapsed");
        [settings toggleAdvanced:nil];
        check(settings.manualButton.action == @selector(editQuota:) && [settings.manualButton.title isEqual:QGL(@"settings.manualQuota")],
            @"shared Codex and Claude manual entry is available under Advanced");
        [settings.tabs.buttons[3] performClick:nil];
        check(settings.automaticUpdatesButton.action == @selector(toggleAutomaticUpdateChecks:) &&
            settings.checkUpdatesButton.action == @selector(checkForUpdates:), @"update actions preserved");
        NSMutableArray *history = [NSMutableArray array];
        for (NSInteger i = 0; i < 288; i++) {
            double t = now-86400+i*300;
            for (NSString *provider in @[@"codex", @"claude"]) for (NSNumber *duration in @[@300, @10080]) {
                double remaining = duration.intValue == 300 ? 100-fmod(i*0.55, 98) : 95-i*0.12;
                [history addObject:@{@"t": @(t), @"remaining": @(remaining), @"reset": @0, @"provider": provider, @"duration": duration}];
            }
        }
        for (NSString *appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            NSString *suffix = [appearance isEqual:NSAppearanceNameAqua] ? @"light" : @"dark";
            for (NSString *style in @[@"ring", @"bar"]) {
            for (NSString *scenario in @[@"full", @"mixed", @"missing", @"stale"]) {
                [delegate applyWindows:[scenario isEqual:@"full"] ? codex : @[codex[1]]];
                delegate.claudeSyncState = [scenario isEqual:@"stale"] ? QGSyncStateFailed : QGSyncStateSuccess;
                [delegate.menuQuotaView configureWithCards:@[[delegate menuCardForProvider:@"codex" enabled:YES],
                    [delegate menuCardForProvider:@"claude" enabled:![scenario isEqual:@"missing"]]]];
                if ([scenario isEqual:@"stale"]) {
                    NSDictionary *card = delegate.menuQuotaView.cards.lastObject;
                    check([card[@"stale"] boolValue] && [card[@"source"] containsString:QGL(@"widget.cached")] &&
                        ![card[@"source"] containsString:QGL(@"sync.claudeCodeLive")],
                        @"failed Claude refresh identifies retained quota as old, not live");
                }
                QGProviderSwitchView *header = [[QGProviderSwitchView alloc] initWithFrame:NSMakeRect(0, 0, 336, 40)];
                [header configureSelectedProvider:[scenario isEqual:@"full"] ? @"claude" : @"codex"
                    claudeEnabled:![scenario isEqual:@"missing"]];
                QGMenuQuotaView *cards = [[QGMenuQuotaView alloc] initWithFrame:NSZeroRect];
                cards.usesBars = [style isEqual:@"bar"];
                [cards configureWithCards:delegate.menuQuotaView.cards];
                NSUInteger indicators = 0;
                for (NSView *child in cards.subviews) if ([child isKindOfClass:QGMenuRingView.class]) indicators++;
                NSUInteger expected = 0;
                for (NSDictionary *card in cards.cards) expected += [card[@"entries"] count];
                check(indicators == expected, @"both styles preserve every real period and omit missing periods");
                cards.frame = NSOffsetRect(cards.frame, 0, 40);
                NSView *stack = [[QGPreviewStack alloc] initWithFrame:NSMakeRect(0, 0, 336, NSMaxY(cards.frame))];
                [stack addSubview:header]; [stack addSubview:cards];
                BOOL pass = Render(stack, directory, [NSString stringWithFormat:@"menu-%@-%@-%@.png", style, scenario, suffix], appearance);
                fprintf(stdout, "%s menu %s %s (%.0f x %.0f pt)\n", pass ? "PASS" : "FAIL", scenario.UTF8String, suffix.UTF8String, delegate.statusMenu.size.width, delegate.statusMenu.size.height);
                if (!pass) failures++;
            }
            }
            QGStatisticsView *view = [[QGStatisticsView alloc] initWithFrame:NSMakeRect(0, 0, 608, 552)];
            check(view.tabs.selectedSegment == 0 && [view.tabs.buttons.firstObject.title isEqualToString:QGL(@"insights.tokenTab")],
                @"daily Token is the first and default tab");
            view.tabs.selectedSegment = 1;
            view.history = history; view.recordHistory = YES; [view render];
            check(!view.recordButton.hidden && !view.historyActions.hidden,
                @"quota tab only shows history controls");
            if (!Render(view, directory, [NSString stringWithFormat:@"quota-trends-%@.png", suffix], appearance)) failures++;
            view.recordHistory = NO; [view render];
            if (!Render(view, directory, [NSString stringWithFormat:@"quota-paused-%@.png", suffix], appearance)) failures++;
            view.tabs.selectedSegment = 0; [view render];
            check(view.recordButton.hidden && view.historyActions.hidden,
                @"Token tab has no local-log collection control");
            NSMutableArray *days = [NSMutableArray array];
            NSDateFormatter *dayFormat = [NSDateFormatter new]; dayFormat.dateFormat = @"yyyy-MM-dd";
            for (NSUInteger i = 0; i < 7; i++) [days addObject:@{@"startDate": [dayFormat stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-(double)i*86400]], @"tokens": @(1200000 + i*42000)}];
            view.report = QGDailyReport(@{@"dailyUsageBuckets": days, @"summary": @{@"lifetimeTokens": @5390000000,
                @"peakDailyTokens": @390000000, @"longestRunningTurnSec": @55260, @"currentStreakDays": @4, @"longestStreakDays": @16}}, nil, NSDate.date);
            [view render];
            if (!Render(view, directory, [NSString stringWithFormat:@"token-stats-%@.png", suffix], appearance)) failures++;
            QGDailyBarChartView *dailyChart = nil;
            for (NSView *section in view.subviews) {
                for (NSView *child in section.subviews) {
                    if ([child isKindOfClass:QGDailyBarChartView.class]) dailyChart = (QGDailyBarChartView *)child;
                }
            }
            NSString *hoveredDay = [dailyChart hoverTextAtPoint:NSMakePoint(515, 60)];
            check([hoveredDay isEqualToString:@"1,200,000"],
                @"daily bar hover shows only the exact token count");
            check([dailyChart hoverTextAtPoint:NSMakePoint(490, 60)] == nil &&
                [dailyChart hoverTextAtPoint:NSMakePoint(515, 20)] == nil,
                @"blank date-slot space and space above a bar have no hover value");
            dailyChart.hoverText = hoveredDay; dailyChart.hoverPoint = NSMakePoint(450, 80);
            if (!Render(view, directory, [NSString stringWithFormat:@"token-stats-hover-%@.png", suffix], appearance)) failures++;
            dailyChart.hoverText = nil;
            view.range.selectedSegment = 1; [view render];
            if (!Render(view, directory, [NSString stringWithFormat:@"token-stats-3d-%@.png", suffix], appearance)) failures++;
            NSDictionary *fullReport = view.report;
            view.report = QGDailyReport(@{@"dailyUsageBuckets": [days subarrayWithRange:NSMakeRange(1, 2)],
                @"summary": fullReport[@"codexSummary"]}, nil, NSDate.date);
            [view render];
            if (!Render(view, directory, [NSString stringWithFormat:@"token-stats-3d-sparse-%@.png", suffix], appearance)) failures++;
            view.range.selectedSegment = 2;
            view.report = nil; [view render];
            if (!Render(view, directory, [NSString stringWithFormat:@"token-empty-%@.png", suffix], appearance)) failures++;
            view.loading = YES; [view render];
            check(!view.refreshButton.enabled, @"daily refresh cannot duplicate an in-flight request");
            if (!Render(view, directory, [NSString stringWithFormat:@"token-loading-%@.png", suffix], appearance)) failures++;
            for (NSNumber *page in @[@0, @1, @2, @3]) {
                settings.configuration = settingsModel; settings.tabs.selectedSegment = page.integerValue; settings.advancedExpanded = NO; [settings render];
                if (!Render(settings, directory, [NSString stringWithFormat:@"settings-%@-%@.png", page, suffix], appearance)) failures++;
            }
            settings.tabs.selectedSegment = 2; settings.advancedExpanded = YES;
            for (NSString *provider in @[@"codex", @"claude"]) {
                QGManualQuotaView *form = [[QGManualQuotaView alloc] initWithProvider:provider windows:@{@"codex": codex, @"claude": claude}];
                if (!Render(form, directory, [NSString stringWithFormat:@"manual-%@-%@.png", provider, suffix], appearance)) failures++;
            }
            NSMutableDictionary *missing = settingsModel.mutableCopy;
            missing[@"claudeEnabled"] = @NO; missing[@"claudeStatus"] = QGL(@"settings.notEnabled"); missing[@"claudeDetail"] = QGL(@"settings.claudeDisabled");
            settings.configuration = missing;
            check(settings.claudeButton.action == @selector(toggleClaudeConnection:), @"disconnected service requires existing consent path");
            if (!Render(settings, directory, [NSString stringWithFormat:@"settings-disconnected-%@.png", suffix], appearance)) failures++;
            settings.tabs.selectedSegment = 3;
            missing[@"updateBusy"] = @YES; missing[@"installing"] = @YES; missing[@"updateButton"] = QGL(@"update.installing");
            settings.configuration = missing.copy;
            check(!settings.checkUpdatesButton.enabled && !settings.automaticUpdatesButton.enabled, @"installation disables conflicting update actions");
            if (!Render(settings, directory, [NSString stringWithFormat:@"settings-updating-%@.png", suffix], appearance)) failures++;
            QGProviderSwitchView *busy = [[QGProviderSwitchView alloc] initWithFrame:NSMakeRect(0, 0, 336, 40)];
            [busy configureSelectedProvider:@"codex" claudeEnabled:YES]; busy.refreshing = YES;
            if (!Render(busy, directory, [NSString stringWithFormat:@"menu-refreshing-%@.png", suffix], appearance)) failures++;
        }
        failures += interactionFailures;
        printf("50 visual fixtures + %lu interaction checks; %lu failures\n", interactionChecks, failures);
        return failures ? 1 : 0;
    }
}
