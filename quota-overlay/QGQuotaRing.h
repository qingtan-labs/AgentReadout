// Vector-only rings shared by the menu and floating widgets. Call from flipped views.
#import <Cocoa/Cocoa.h>
#import <math.h>

static double QGQuotaRingFraction(double percent) {
    return isfinite(percent) ? MIN(100, MAX(0, percent)) / 100.0 : 0;
}

static void QGDrawQuotaRing(NSRect rect, double percent, NSString *text,
                            NSColor *accent, NSColor *track, NSColor *foreground) {
    CGFloat diameter = MIN(NSWidth(rect), NSHeight(rect));
    CGFloat lineWidth = MIN(6, MAX(3, diameter * 0.055));
    NSRect circle = NSMakeRect(NSMidX(rect)-diameter/2, NSMidY(rect)-diameter/2, diameter, diameter);
    NSBezierPath *outline = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circle, lineWidth/2, lineWidth/2)];
    outline.lineWidth = lineWidth;
    [track setStroke]; [outline stroke];
    double fraction = QGQuotaRingFraction(percent);
    if (fraction > 0) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        // In a flipped view, increasing angles travel clockwise from twelve o'clock.
        [arc appendBezierPathWithArcWithCenter:NSMakePoint(NSMidX(circle), NSMidY(circle))
            radius:(diameter-lineWidth)/2 startAngle:-90 endAngle:-90+360*fraction clockwise:NO];
        arc.lineWidth = lineWidth; arc.lineCapStyle = NSLineCapStyleRound;
        [accent setStroke]; [arc stroke];
    }
    CGFloat fontSize = diameter * 0.28;
    NSMutableAttributedString *label = [[NSMutableAttributedString alloc] initWithString:text ?: @""
        attributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:fontSize weight:NSFontWeightSemibold],
                     NSForegroundColorAttributeName: foreground}];
    NSRange symbol = [label.string rangeOfString:@"%"];
    if (symbol.location != NSNotFound)
        [label addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:fontSize * 0.56 weight:NSFontWeightMedium] range:symbol];
    NSSize size = label.size;
    [label drawAtPoint:NSMakePoint(NSMidX(circle)-size.width/2, NSMidY(circle)-size.height/2)];
}
