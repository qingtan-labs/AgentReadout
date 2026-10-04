#import <Cocoa/Cocoa.h>

static NSColor *GColor(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:red / 255.0 green:green / 255.0 blue:blue / 255.0 alpha:alpha];
}

static NSBitmapImageRep *NewBitmap(NSInteger width, NSInteger height) {
    return [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
}

static void BeginBitmap(NSBitmapImageRep *bitmap) {
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
}

static BOOL SaveBitmap(NSBitmapImageRep *bitmap, NSString *path) {
    NSData *data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [data writeToFile:path atomically:YES];
}

static NSMutableParagraphStyle *Paragraph(NSTextAlignment alignment) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = alignment;
    return style;
}

static NSDictionary *TextStyle(CGFloat size, NSFontWeight weight, NSColor *color) {
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: Paragraph(NSTextAlignmentLeft)
    };
}

static void DrawRoundRect(NSRect rect, CGFloat radius, NSColor *color) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}

static NSBitmapImageRep *SocialPreview(NSImage *icon) {
    NSBitmapImageRep *bitmap = NewBitmap(1280, 640);
    BeginBitmap(bitmap);

    NSGradient *background = [[NSGradient alloc]
        initWithStartingColor:GColor(13, 18, 34, 1)
                  endingColor:GColor(42, 52, 88, 1)];
    [background drawInRect:NSMakeRect(0, 0, 1280, 640) angle:-20];

    [GColor(47, 204, 255, 0.11) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-150, 250, 650, 650)] fill];
    [GColor(113, 239, 151, 0.08) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(860, -260, 660, 660)] fill];

    NSShadow *iconShadow = [NSShadow new];
    iconShadow.shadowColor = GColor(0, 0, 0, 0.38);
    iconShadow.shadowBlurRadius = 36;
    iconShadow.shadowOffset = NSMakeSize(0, -16);
    [NSGraphicsContext saveGraphicsState];
    [iconShadow set];
    [icon drawInRect:NSMakeRect(90, 82, 476, 476)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:NO
                hints:nil];
    [NSGraphicsContext restoreGraphicsState];

    [@"AgentReadout" drawInRect:NSMakeRect(610, 420, 600, 82)
                       withAttributes:TextStyle(61, NSFontWeightBold, NSColor.whiteColor)];
    [@"Codex + Claude quotas,\nat a glance." drawInRect:NSMakeRect(614, 310, 560, 96)
                                                withAttributes:TextStyle(32, NSFontWeightMedium,
                                                                               GColor(220, 229, 247, 1))];

    NSRect statusPill = NSMakeRect(614, 205, 225, 66);
    DrawRoundRect(statusPill, 26, GColor(255, 255, 255, 0.11));
    [@"76%" drawInRect:NSMakeRect(638, 222, 88, 35)
         withAttributes:TextStyle(29, NSFontWeightSemibold, NSColor.whiteColor)];
    DrawRoundRect(NSMakeRect(725, 234, 87, 8), 4, GColor(255, 255, 255, 0.16));
    DrawRoundRect(NSMakeRect(725, 234, 66, 8), 4, GColor(111, 237, 148, 1));

    [@"NATIVE macOS  ·  LOCAL-FIRST  ·  OPEN SOURCE"
        drawInRect:NSMakeRect(614, 142, 575, 27)
     withAttributes:TextStyle(17, NSFontWeightSemibold, GColor(149, 170, 207, 1))];

    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

static void DrawMenuRow(NSString *text, NSRect rect, NSFontWeight weight, NSColor *color) {
    [text drawInRect:rect withAttributes:TextStyle(20, weight, color)];
}

static NSBitmapImageRep *MenuOverview(NSImage *icon) {
    NSBitmapImageRep *bitmap = NewBitmap(1400, 820);
    BeginBitmap(bitmap);

    [GColor(244, 246, 250, 1) setFill];
    NSRectFill(NSMakeRect(0, 0, 1400, 820));
    [@"One glance, before your next Codex run"
        drawInRect:NSMakeRect(90, 735, 1220, 55)
     withAttributes:TextStyle(38, NSFontWeightBold, GColor(20, 25, 40, 1))];
    [@"Illustrative macOS menu-bar preview"
        drawInRect:NSMakeRect(92, 701, 500, 28)
     withAttributes:TextStyle(18, NSFontWeightRegular, GColor(101, 109, 128, 1))];

    NSRect screen = NSMakeRect(90, 70, 1220, 600);
    NSShadow *screenShadow = [NSShadow new];
    screenShadow.shadowColor = GColor(22, 28, 48, 0.16);
    screenShadow.shadowBlurRadius = 30;
    screenShadow.shadowOffset = NSMakeSize(0, -8);
    [NSGraphicsContext saveGraphicsState];
    [screenShadow set];
    DrawRoundRect(screen, 34, NSColor.whiteColor);
    [NSGraphicsContext restoreGraphicsState];

    NSBezierPath *screenClip = [NSBezierPath bezierPathWithRoundedRect:screen xRadius:34 yRadius:34];
    [NSGraphicsContext saveGraphicsState];
    [screenClip addClip];
    NSGradient *wallpaper = [[NSGradient alloc]
        initWithStartingColor:GColor(79, 64, 142, 1)
                  endingColor:GColor(36, 139, 139, 1)];
    [wallpaper drawInRect:screen angle:-18];
    [GColor(255, 255, 255, 0.12) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(70, 190, 650, 650)] fill];
    [NSGraphicsContext restoreGraphicsState];

    NSRect menuBar = NSMakeRect(90, 622, 1220, 48);
    DrawRoundRect(menuBar, 0, GColor(14, 19, 33, 0.70));
    [@"AgentReadout" drawInRect:NSMakeRect(120, 634, 220, 25)
                      withAttributes:TextStyle(17, NSFontWeightSemibold, NSColor.whiteColor)];

    NSRect quotaItem = NSMakeRect(1117, 626, 160, 39);
    DrawRoundRect(quotaItem, 15, GColor(255, 255, 255, 0.12));
    [@"76%" drawInRect:NSMakeRect(1139, 638, 61, 22)
         withAttributes:TextStyle(18, NSFontWeightSemibold, NSColor.whiteColor)];
    DrawRoundRect(NSMakeRect(1210, 644, 46, 5), 2.5, GColor(255, 255, 255, 0.22));
    DrawRoundRect(NSMakeRect(1210, 644, 35, 5), 2.5, GColor(111, 237, 148, 1));

    NSRect menu = NSMakeRect(795, 118, 482, 490);
    NSShadow *menuShadow = [NSShadow new];
    menuShadow.shadowColor = GColor(10, 15, 30, 0.32);
    menuShadow.shadowBlurRadius = 28;
    menuShadow.shadowOffset = NSMakeSize(0, -9);
    [NSGraphicsContext saveGraphicsState];
    [menuShadow set];
    DrawRoundRect(menu, 26, GColor(252, 252, 253, 0.97));
    [NSGraphicsContext restoreGraphicsState];

    [icon drawInRect:NSMakeRect(826, 526, 48, 48)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:NO
                hints:nil];
    DrawMenuRow(@"AgentReadout · 76% remaining", NSMakeRect(888, 539, 355, 27),
                NSFontWeightSemibold, GColor(25, 28, 39, 1));
    DrawMenuRow(@"5 hr window · 76% remaining", NSMakeRect(826, 492, 400, 27),
                NSFontWeightRegular, GColor(41, 45, 58, 1));
    DrawMenuRow(@"7 day window · 89% remaining", NSMakeRect(826, 452, 400, 27),
                NSFontWeightRegular, GColor(41, 45, 58, 1));
    DrawMenuRow(@"Resets in 2d 4h · Sep 14, 3:11 PM", NSMakeRect(826, 403, 415, 27),
                NSFontWeightRegular, GColor(75, 81, 97, 1));
    DrawMenuRow(@"Updated just now", NSMakeRect(826, 365, 380, 27),
                NSFontWeightRegular, GColor(75, 81, 97, 1));
    [GColor(28, 32, 45, 0.10) setFill];
    NSRectFill(NSMakeRect(816, 342, 440, 1));
    DrawMenuRow(@"Refresh Now", NSMakeRect(826, 303, 390, 27),
                NSFontWeightRegular, GColor(32, 36, 49, 1));
    DrawMenuRow(@"Menu Bar Display  ›", NSMakeRect(826, 263, 390, 27),
                NSFontWeightRegular, GColor(32, 36, 49, 1));
    DrawMenuRow(@"Enter Usage Manually…", NSMakeRect(826, 223, 390, 27),
                NSFontWeightRegular, GColor(32, 36, 49, 1));
    [GColor(28, 32, 45, 0.10) setFill];
    NSRectFill(NSMakeRect(816, 201, 440, 1));
    DrawMenuRow(@"About AgentReadout", NSMakeRect(826, 164, 390, 27),
                NSFontWeightRegular, GColor(32, 36, 49, 1));

    NSArray<NSString *> *numbers = @[@"1", @"2", @"3"];
    NSArray<NSString *> *titles = @[@"Remaining quota", @"Reset countdown", @"Resilient refresh"];
    NSArray<NSString *> *bodies = @[
        @"Percentage and progress stay visible\nwithout following a Codex window.",
        @"See the exact local reset time and\nhow many days or hours remain.",
        @"Auto-refreshes and keeps the last\ngood value during transient failures."
    ];
    NSArray<NSNumber *> *ys = @[@500, @330, @160];
    for (NSInteger index = 0; index < 3; index++) {
        CGFloat y = ys[index].doubleValue;
        DrawRoundRect(NSMakeRect(135, y, 52, 52), 18, GColor(26, 34, 56, 0.88));
        NSMutableParagraphStyle *center = Paragraph(NSTextAlignmentCenter);
        NSDictionary *numberStyle = @{
            NSFontAttributeName: [NSFont systemFontOfSize:23 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: NSColor.whiteColor,
            NSParagraphStyleAttributeName: center
        };
        [numbers[index] drawInRect:NSMakeRect(135, y + 12, 52, 29) withAttributes:numberStyle];
        [titles[index] drawInRect:NSMakeRect(215, y + 17, 470, 32)
                    withAttributes:TextStyle(25, NSFontWeightSemibold, NSColor.whiteColor)];
        [bodies[index] drawInRect:NSMakeRect(215, y - 44, 500, 58)
                    withAttributes:TextStyle(18, NSFontWeightRegular, GColor(226, 234, 247, 1))];
    }

    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: GenerateRepositoryArtwork app-icon.png output-directory\n");
            return 2;
        }
        NSString *iconPath = [NSString stringWithUTF8String:argv[1]];
        NSString *outputDirectory = [NSString stringWithUTF8String:argv[2]];
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        if (!icon) {
            fprintf(stderr, "could not load app icon\n");
            return 1;
        }

        NSBitmapImageRep *social = SocialPreview(icon);
        NSBitmapImageRep *menu = MenuOverview(icon);
        NSString *socialPath = [outputDirectory stringByAppendingPathComponent:@"social-preview.png"];
        NSString *menuPath = [outputDirectory stringByAppendingPathComponent:@"screenshots/menu-overview.png"];
        if (!SaveBitmap(social, socialPath) || !SaveBitmap(menu, menuPath)) {
            fprintf(stderr, "failed to write repository artwork\n");
            return 1;
        }
        printf("%s\n%s\n", socialPath.UTF8String, menuPath.UTF8String);
    }
    return 0;
}
