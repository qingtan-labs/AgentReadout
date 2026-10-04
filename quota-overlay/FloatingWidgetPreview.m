// Render and test the production AppKit floating widget using synthetic data.
// Never opens a window, changes preferences, or reads account credentials.
#define main GaugeHostMain
#import "main.m"
#undef main

static NSDictionary *Window(double remaining, double minutes, double reset) {
    return @{@"remainingPercent": @(remaining), @"usedPercent": @(100 - remaining),
             @"windowDurationMins": @(minutes), @"resetsAt": @(reset), @"kind": @"primary"};
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 1;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSString *directory = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        QGAppDelegate *delegate = [QGAppDelegate new];
        delegate.selectedProvider = @"codex";
        delegate.codexPlanName = @"Pro 5×";
        delegate.claudePlanName = @"Max 20×";
        delegate.desktopWidgetSize = QGDesktopWidgetSizeLarge;
        delegate.statusMenu = [delegate makeMenu];
        [delegate updateStatusItem];
        BOOL menuOK = delegate.largeWidgetMenuItem.tag == QGDesktopWidgetSizeLarge &&
            delegate.largeWidgetMenuItem.state == NSControlStateValueOn &&
            [delegate.largeWidgetMenuItem.title isEqualToString:QGL(@"widget.sizeLarge")];
        fprintf(stdout, "%s large size menu item and checkmark\n", menuOK ? "PASS" : "FAIL");
        NSUInteger failures = menuOK ? 0 : 1;
        NSDate *now = NSDate.date;
        double reset = now.timeIntervalSince1970;
        NSArray *codexBoth = @[Window(68, 300, reset + 7200), Window(51, 10080, reset + 6 * 86400)];
        NSArray *claudeBoth = @[Window(100, 300, 0), Window(73, 10080, reset + 4 * 86400)];
        NSArray *scenarios = @[@"mixed", @"both-full", @"weekly-only", @"claude-disabled", @"codex-missing",
                               @"waiting", @"stale", @"single-codex", @"single-claude", @"single-weekly", @"manual"];
        for (NSString *scenario in scenarios) {
            delegate.lastSuccessfulSync = delegate.claudeLastSuccessfulSync = now;
            delegate.syncState = delegate.claudeSyncState = QGSyncStateSuccess;
            delegate.quotaWindows = [scenario isEqualToString:@"both-full"] ? codexBoth : @[codexBoth[1]];
            delegate.claudeWindows = claudeBoth;
            BOOL enabled = ![scenario isEqualToString:@"claude-disabled"];
            if ([scenario isEqualToString:@"weekly-only"]) delegate.claudeWindows = @[claudeBoth[1]];
            if ([scenario isEqualToString:@"codex-missing"]) delegate.quotaWindows = @[];
            if ([scenario isEqualToString:@"waiting"]) {
                delegate.quotaWindows = delegate.claudeWindows = @[];
                delegate.lastSuccessfulSync = delegate.claudeLastSuccessfulSync = nil;
            }
            if ([scenario isEqualToString:@"stale"]) {
                delegate.claudeSyncState = QGSyncStateFailed;
                delegate.claudeLastSuccessfulSync = [now dateByAddingTimeInterval:-3600];
            }
            if ([scenario isEqualToString:@"single-codex"]) delegate.quotaWindows = codexBoth;
            if ([scenario isEqualToString:@"manual"]) delegate.quotaWindows = @[Window(42, 0, 0)];
            NSDictionary *codex = [delegate largeFloatingProviderModel:@"codex" enabled:YES];
            NSDictionary *claude = [delegate largeFloatingProviderModel:@"claude" enabled:enabled];
            BOOL single = [scenario hasPrefix:@"single-"] || [scenario isEqualToString:@"manual"];
            NSArray *providers = single ? @[ [scenario isEqualToString:@"single-claude"] ? claude : codex ] : @[codex, claude];
            BOOL valid = [codex[@"windows"] count] == delegate.quotaWindows.count &&
                [claude[@"windows"] count] == (enabled ? delegate.claudeWindows.count : 0);
            if ([scenario isEqualToString:@"stale"]) valid &= [claude[@"stale"] boolValue] && [claude[@"windows"] count] == 2;
            if (!enabled) valid &= [claude[@"emptyTitle"] isEqualToString:QGL(@"widget.connectClaudeShort")];
            valid &= [codex[@"planName"] isEqual:@"Pro 5×"];
            valid &= [claude[@"planName"] isEqual:enabled ? @"Max 20×" : @""];
            if ([scenario isEqualToString:@"waiting"]) valid &= [claude[@"emptyText"] isEqualToString:QGL(@"widget.claudeSyncHelp")];
            if ([claude[@"windows"] count] == 2) valid &= [claude[@"windows"][0][@"exactResetText"] length] == 0;
            fprintf(stdout, "%s floating model %s\n", valid ? "PASS" : "FAIL", scenario.UTF8String);
            if (!valid) failures++;
            for (NSString *style in @[@"ring", @"bar"]) {
            for (NSNumber *size in @[@0, @1, @2]) {
            for (NSString *surface in @[@"light", @"dark", @"transparent"]) {
                NSSize dimensions = QGFloatingWidgetSize(size.integerValue);
                QGDesktopWidgetView *view = [[QGDesktopWidgetView alloc] initWithFrame:NSMakeRect(0, 0, dimensions.width, dimensions.height)];
                view.large = size.integerValue == 2; view.medium = size.integerValue == 1;
                view.dualProviderMode = !single; view.usesBars = [style isEqual:@"bar"];
                view.providerModels = providers;
                view.titleText = QGL(@"widget.titleRemaining");
                NSMutableArray *models = [NSMutableArray array];
                for (NSDictionary *provider in providers) {
                    NSArray *windows = provider[@"windows"];
                    if (!windows.count && !single) {
                        [models addObject:@{@"provider": provider[@"name"], @"hasQuota": @NO,
                            @"exactResetText": provider[@"emptyTitle"]}];
                    }
                    if (!view.medium || !single) {
                        windows = [windows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                            return [a[@"percent"] compare:b[@"percent"]];
                        }];
                        if (windows.count) windows = @[windows.firstObject];
                    }
                    for (NSDictionary *window in windows) {
                        NSMutableDictionary *model = window.mutableCopy;
                        model[@"providerID"] = provider[@"id"]; model[@"provider"] = provider[@"name"];
                        model[@"period"] = window[@"label"]; model[@"hasQuota"] = @YES;
                        model[@"exactResetText"] = window[@"compactResetText"];
                        [models addObject:model];
                    }
                }
                view.windowModels = models;
                view.exactResetText = models.firstObject[@"exactResetText"];
                view.freshnessText = models.firstObject[@"resetText"];
                view.emptyText = providers.firstObject[@"emptyText"];
                view.desktopFocused = ![surface isEqualToString:@"transparent"];
                view.prefersLightText = YES;
                NSAppearance *appearance = [NSAppearance appearanceNamed:[surface isEqualToString:@"dark"]
                    ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
                view.appearance = appearance;
                [appearance performAsCurrentDrawingAppearance:^{
                    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                        pixelsWide:dimensions.width*2 pixelsHigh:dimensions.height*2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                    bitmap.size = view.frame.size;
                    [NSGraphicsContext saveGraphicsState];
                    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
                    if ([surface isEqualToString:@"transparent"]) {
                        [[NSColor colorWithSRGBRed:0.18 green:0.56 blue:0.90 alpha:1] setFill];
                        NSRectFill(view.bounds);
                    }
                    [view displayRectIgnoringOpacity:view.bounds inContext:NSGraphicsContext.currentContext];
                    [NSGraphicsContext restoreGraphicsState];
                    NSString *filename = [NSString stringWithFormat:@"%@-%@-%@-%@.png", style, scenario, size, surface];
                    if (![[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                          writeToFile:[directory stringByAppendingPathComponent:filename] atomically:YES]) abort();
                }];
            }
            }
            }
        }
        fprintf(stdout, "12 floating integration checks, %lu failures; 198 previews\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
