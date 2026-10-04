#import <Foundation/Foundation.h>

// Display only known, explicit plan identifiers. Never infer a subscription from
// percentages, window count, payment method, or an arbitrary account string.
static inline NSString *QGPlanIdentifier(id value) {
    return [value isKindOfClass:NSString.class] ? [value lowercaseString] : @"";
}

static inline NSString *QGCodexPlan(id value) {
    // Official client billing copy maps prolite -> Pro 5x and pro -> Pro 20x.
    // Other Pro variants stay generic until their multiplier is verified.
    return @{@"free": @"Free", @"go": @"Go", @"plus": @"Plus", @"pro": @"Pro 20×",
             @"prolite": @"Pro 5×", @"promax": @"Pro",
             @"team": @"Team", @"business": @"Business", @"enterprise": @"Enterprise",
             @"edu": @"Edu"}[QGPlanIdentifier(value)];
}

static inline NSString *QGClaudePlan(id subscription, id rateLimitTier) {
    NSString *type = QGPlanIdentifier(subscription);
    NSString *tier = QGPlanIdentifier(rateLimitTier);
    if ([type isEqualToString:@"max"] || [type isEqualToString:@"claude_max"]) {
        if ([tier isEqualToString:@"default_claude_max_5x"]) return @"Max 5×";
        if ([tier isEqualToString:@"default_claude_max_20x"]) return @"Max 20×";
        return @"Max";
    }
    return @{@"free": @"Free", @"claude_free": @"Free", @"pro": @"Pro", @"claude_pro": @"Pro",
             @"team": @"Team", @"claude_team": @"Team",
             @"enterprise": @"Enterprise", @"claude_enterprise": @"Enterprise"}[type];
}

static inline NSString *QGValidatedPlanLabel(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    if ([value isEqual:@"Pro Lite"]) return @"Pro 5×";
    if ([value isEqual:@"Pro Max"]) return @"Pro";
    return [@[@"Free", @"Go", @"Plus", @"Pro", @"Pro 5×", @"Pro 20×", @"Team", @"Business", @"Enterprise", @"Edu",
              @"Max", @"Max 5×", @"Max 20×"] containsObject:value] ? value : nil;
}
