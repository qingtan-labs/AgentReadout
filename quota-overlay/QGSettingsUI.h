// A small, task-oriented settings window. Quota/Token history controls belong
// to the statistics window, not here. All mutations still use host actions.
@interface QGSettingsView : NSView
@property (weak) id actionTarget;
@property (nonatomic) NSDictionary *configuration;
@property QGChoiceBar *tabs;
@property QGChoiceBar *displayChoice;
@property QGChoiceBar *quotaStyleChoice;
@property QGChoiceBar *appearanceChoice;
@property QGChoiceBar *languageChoice;
@property NSButton *alertsButton;
@property NSButton *claudeButton;
@property NSButton *automaticUpdatesButton;
@property NSButton *checkUpdatesButton;
@property NSButton *manualButton;
@property NSButton *loginButton;
@property BOOL advancedExpanded;
- (void)render;
@end

@implementation QGSettingsView
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _tabs = [[QGChoiceBar alloc] initWithLabels:@[QGL(@"settings.general"), QGL(@"settings.appearance"),
            QGL(@"settings.services"), QGL(@"settings.updates")]
            frame:NSMakeRect(20, 16, 496, 34)];
        _tabs.target = self; _tabs.action = @selector(changeTab:); [self addSubview:_tabs];
    }
    return self;
}
- (void)setConfiguration:(NSDictionary *)configuration {
    if ([_configuration isEqual:configuration]) return;
    _configuration = configuration.copy; [self render];
}
- (void)changeTab:(id)sender { (void)sender; [self render]; }
- (void)toggleAdvanced:(id)sender { (void)sender; _advancedExpanded = !_advancedExpanded; [self render]; }
- (void)changeDisplay:(QGChoiceBar *)sender {
    // Reuse the same tagged choice action as the old native menu items.
    [NSApp sendAction:@selector(changeDisplayMode:) to:_actionTarget from:sender.buttons[sender.selectedSegment]];
}
- (void)changeQuotaStyle:(QGChoiceBar *)sender {
    [NSApp sendAction:@selector(changeQuotaStyle:) to:_actionTarget from:sender.buttons[sender.selectedSegment]];
}
- (void)changeAppearance:(QGChoiceBar *)sender {
    [NSApp sendAction:@selector(changeAppearanceMode:) to:_actionTarget from:sender.buttons[sender.selectedSegment]];
}
- (void)changeLanguage:(QGChoiceBar *)sender {
    [NSApp sendAction:@selector(changeLanguageMode:) to:_actionTarget from:sender.buttons[sender.selectedSegment]];
}
- (NSTextField *)paragraph:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = QGInsightLabel(self, text, frame, 11, YES);
    label.maximumNumberOfLines = 4; label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [NSButton buttonWithTitle:title target:_actionTarget action:action];
    button.frame = frame; button.font = [NSFont systemFontOfSize:12];
    [self addSubview:button]; return button;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; [NSColor.windowBackgroundColor setFill]; NSRectFill(self.bounds);
    NSArray<NSValue *> *groups = _tabs.selectedSegment == 0
        ? @[[NSValue valueWithRect:NSMakeRect(16, 143, 504, 90)],
            [NSValue valueWithRect:NSMakeRect(16, 245, 504, 108)], [NSValue valueWithRect:NSMakeRect(16, 365, 504, 86)],
            [NSValue valueWithRect:NSMakeRect(16, 463, 504, 70)]]
        : _tabs.selectedSegment == 1
        ? @[[NSValue valueWithRect:NSMakeRect(16, 143, 504, 112)],
            [NSValue valueWithRect:NSMakeRect(16, 270, 504, 112)]]
        : _tabs.selectedSegment == 2
        ? @[[NSValue valueWithRect:NSMakeRect(16, 143, 504, 98)], [NSValue valueWithRect:NSMakeRect(16, 253, 504, 110)]]
        : @[[NSValue valueWithRect:NSMakeRect(16, 143, 504, 100)], [NSValue valueWithRect:NSMakeRect(16, 255, 504, 90)]];
    for (NSValue *value in groups) {
        [NSColor.controlBackgroundColor setFill];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:value.rectValue xRadius:12 yRadius:12]; [path fill];
        [[NSColor.separatorColor colorWithAlphaComponent:0.20] setStroke]; path.lineWidth = 0.5; [path stroke];
    }
}
- (void)render {
    for (NSView *view in self.subviews.copy) if (view != _tabs) [view removeFromSuperview];
    _displayChoice = nil; _quotaStyleChoice = nil; _appearanceChoice = nil; _languageChoice = nil;
    _alertsButton = nil; _claudeButton = nil;
    _automaticUpdatesButton = nil; _checkUpdatesButton = nil; _manualButton = nil; _loginButton = nil;
    NSInteger page = _tabs.selectedSegment;
    NSString *heading = QGL(page == 0 ? @"settings.generalTitle" : (page == 1 ? @"settings.appearanceTitle" :
        (page == 2 ? @"settings.servicesTitle" : @"settings.updates")));
    QGInsightLabel(self, heading, NSMakeRect(24, 72, 488, 26), 19, NO);
    NSString *subtitle = page == 0 ? QGL(@"settings.generalHelp") :
        (page == 1 ? QGL(@"settings.appearanceHelp") : (page == 2 ? QGL(@"settings.servicesHelp") : _configuration[@"version"]));
    [self paragraph:subtitle frame:NSMakeRect(24, 106, 480, 32)];
    if (page == 0) {
        QGInsightLabel(self, QGL(@"menu.display"), NSMakeRect(30, 158, 472, 20), 12, NO);
        _displayChoice = [[QGChoiceBar alloc] initWithLabels:@[QGL(@"menu.displayFull"), QGL(@"menu.displayCompact")]
            frame:NSMakeRect(28, 186, 480, 32)];
        _displayChoice.selectedSegment = [_configuration[@"displayMode"] integerValue];
        _displayChoice.target = self; _displayChoice.action = @selector(changeDisplay:); [self addSubview:_displayChoice];
        QGInsightLabel(self, QGL(@"settings.quotaStyle"), NSMakeRect(30, 257, 472, 20), 12, NO);
        _quotaStyleChoice = [[QGChoiceBar alloc] initWithLabels:@[QGL(@"settings.styleBar"), QGL(@"settings.styleRing")]
            frame:NSMakeRect(28, 285, 480, 30)];
        _quotaStyleChoice.selectedSegment = [_configuration[@"quotaStyle"] isEqual:@"ring"] ? 1 : 0;
        _quotaStyleChoice.target = self; _quotaStyleChoice.action = @selector(changeQuotaStyle:);
        [self addSubview:_quotaStyleChoice];
        [self paragraph:QGL(@"settings.quotaStyleHelp") frame:NSMakeRect(30, 322, 470, 28)];
        _alertsButton = [NSButton checkboxWithTitle:QGL(@"settings.alerts") target:_actionTarget action:@selector(toggleQuotaAlerts:)];
        _alertsButton.frame = NSMakeRect(28, 375, 476, 24);
        _alertsButton.state = [_configuration[@"alerts"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [self addSubview:_alertsButton];
        [self paragraph:QGL(@"settings.alertsHelp") frame:NSMakeRect(30, 406, 470, 40)];
        _loginButton = [NSButton checkboxWithTitle:QGL(@"settings.login") target:_actionTarget action:@selector(toggleLoginItem:)];
        _loginButton.frame = NSMakeRect(28, 471, 476, 24);
        _loginButton.state = [_configuration[@"loginEnabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [self addSubview:_loginButton];
        [self paragraph:QGL(@"settings.loginHelp") frame:NSMakeRect(30, 502, 470, 28)];
        [self paragraph:QGL(@"settings.quotaStyleHelp") frame:NSMakeRect(24, 544, 480, 16)];
    } else if (page == 1) {
        QGInsightLabel(self, QGL(@"settings.colorScheme"), NSMakeRect(30, 158, 472, 20), 12, NO);
        _appearanceChoice = [[QGChoiceBar alloc] initWithLabels:@[QGL(@"settings.followSystem"),
            QGL(@"settings.light"), QGL(@"settings.dark")] frame:NSMakeRect(28, 187, 480, 34)];
        NSString *appearance = _configuration[@"appearanceMode"];
        _appearanceChoice.selectedSegment = [appearance isEqual:@"light"] ? 1 : ([appearance isEqual:@"dark"] ? 2 : 0);
        _appearanceChoice.target = self; _appearanceChoice.action = @selector(changeAppearance:);
        [self addSubview:_appearanceChoice];
        [self paragraph:QGL(@"settings.colorSchemeHelp") frame:NSMakeRect(30, 229, 470, 20)];
        QGInsightLabel(self, QGL(@"settings.language"), NSMakeRect(30, 285, 472, 20), 12, NO);
        _languageChoice = [[QGChoiceBar alloc] initWithLabels:@[QGL(@"settings.followSystem"), @"简体中文", @"English"]
            frame:NSMakeRect(28, 314, 480, 34)];
        NSString *language = _configuration[@"languageMode"];
        _languageChoice.selectedSegment = [language isEqual:@"zh-Hans"] ? 1 : ([language isEqual:@"en"] ? 2 : 0);
        _languageChoice.target = self; _languageChoice.action = @selector(changeLanguage:);
        [self addSubview:_languageChoice];
        [self paragraph:QGL(@"settings.languageHelp") frame:NSMakeRect(30, 356, 470, 20)];
    } else if (page == 2) {
        QGInsightLabel(self, @"Codex", NSMakeRect(30, 158, 90, 22), 14, NO).textColor = QGServiceColor(NO);
        QGInsightLabel(self, _configuration[@"codexStatus"], NSMakeRect(126, 160, 214, 20), 11, YES);
        [self paragraph:_configuration[@"codexDetail"] frame:NSMakeRect(30, 191, 470, 40)];
        NSButton *help = [self button:QGL(@"settings.connectionHelp") action:@selector(showServiceHelp:)
            frame:NSMakeRect(378, 155, 126, 28)]; help.tag = 0;
        QGInsightLabel(self, @"Claude", NSMakeRect(30, 270, 90, 22), 14, NO).textColor = QGServiceColor(YES);
        QGInsightLabel(self, _configuration[@"claudeStatus"], NSMakeRect(126, 272, 214, 20), 11, YES);
        [self paragraph:_configuration[@"claudeDetail"] frame:NSMakeRect(30, 305, 340, 46)];
        BOOL enabled = [_configuration[@"claudeEnabled"] boolValue];
        _claudeButton = [self button:QGL(enabled ? @"settings.connectionHelp" : @"settings.connectClaude")
            action:enabled ? @selector(showServiceHelp:) : @selector(toggleClaudeConnection:)
            frame:NSMakeRect(378, 269, 126, 28)]; _claudeButton.tag = 1;
        NSButton *advanced = [NSButton buttonWithTitle:QGL(@"settings.advanced") target:self action:@selector(toggleAdvanced:)];
        advanced.frame = NSMakeRect(24, 375, 216, 26); advanced.bordered = NO;
        advanced.image = [NSImage imageWithSystemSymbolName:_advancedExpanded ? @"chevron.down" : @"chevron.right" accessibilityDescription:nil];
        advanced.imagePosition = NSImageLeft; advanced.alignment = NSTextAlignmentLeft;
        [advanced setAccessibilityValue:@(_advancedExpanded)]; [self addSubview:advanced];
        if (_advancedExpanded) {
            [self paragraph:QGL(@"settings.manualHelp") frame:NSMakeRect(28, 413, 262, 46)];
            _manualButton = [self button:QGL(@"settings.manualQuota") action:@selector(editQuota:)
                frame:NSMakeRect(298, 416, 210, 28)];
        }
    } else {
        _automaticUpdatesButton = [NSButton checkboxWithTitle:QGL(@"settings.dailyUpdates") target:_actionTarget action:@selector(toggleAutomaticUpdateChecks:)];
        _automaticUpdatesButton.frame = NSMakeRect(28, 159, 476, 26);
        _automaticUpdatesButton.state = [_configuration[@"automaticUpdates"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        _automaticUpdatesButton.enabled = ![_configuration[@"installing"] boolValue]; [self addSubview:_automaticUpdatesButton];
        [self paragraph:QGL(@"settings.updateHelp") frame:NSMakeRect(30, 196, 470, 36)];
        QGInsightLabel(self, QGL(@"settings.softwareUpdate"), NSMakeRect(30, 270, 244, 22), 12, NO);
        [self paragraph:_configuration[@"updateStatus"] frame:NSMakeRect(30, 303, 258, 34)];
        _checkUpdatesButton = [self button:_configuration[@"updateButton"] action:@selector(checkForUpdates:)
            frame:NSMakeRect(302, 281, 204, 30)];
        _checkUpdatesButton.enabled = ![_configuration[@"updateBusy"] boolValue];
        [self button:QGL(@"settings.about") action:@selector(showAbout:) frame:NSMakeRect(22, 411, 180, 30)];
        [self paragraph:QGL(@"settings.localOnly") frame:NSMakeRect(24, 454, 480, 20)];
    }
    self.needsDisplay = YES;
}
@end
