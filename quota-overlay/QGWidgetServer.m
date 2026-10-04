#import "QGWidgetServer.h"
#import "QGPlan.h"

#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <string.h>
#import <unistd.h>

static uint16_t const QGWidgetPort = 38429;

static NSDictionary *QGWidgetSnapshot(NSArray<NSDictionary *> *codexWindows, NSTimeInterval codexUpdatedAt,
                                      BOOL codexFailed, NSArray<NSDictionary *> *claudeWindows,
                                      NSTimeInterval claudeUpdatedAt, BOOL claudeFailed,
                                      NSString *selectedProvider, NSString *displayMode,
                                      BOOL claudeEnabled, BOOL legacyClaudeSupport,
                                      NSString *codexPlanName, NSString *claudePlanName, NSString *quotaStyle,
                                      NSString *appearanceMode, NSString *language, NSDictionary *dailyUsage) {
    BOOL legacyClaude = legacyClaudeSupport && [selectedProvider isEqualToString:@"claude"] && claudeEnabled;
    NSArray<NSDictionary *> *legacyWindows = legacyClaude ? claudeWindows : codexWindows;
    NSTimeInterval legacyUpdatedAt = legacyClaude ? claudeUpdatedAt : codexUpdatedAt;
    return @{
        // Older installed extensions use these three fields and remain Codex-only
        // unless they explicitly advertised Claude support.
        @"windows": legacyWindows ?: @[],
        @"updatedAt": @(MAX(0.0, legacyUpdatedAt)),
        @"provider": legacyClaude ? @"claude" : @"codex",
        @"providers": @{
            @"codex": @{@"windows": codexWindows ?: @[], @"updatedAt": @(MAX(0.0, codexUpdatedAt)),
                        @"planName": QGValidatedPlanLabel(codexPlanName) ?: NSNull.null,
                        @"stale": [NSNumber numberWithBool:codexFailed]},
            @"claude": @{@"windows": claudeEnabled ? (claudeWindows ?: @[]) : @[],
                         @"planName": (claudeEnabled ? QGValidatedPlanLabel(claudePlanName) : nil) ?: NSNull.null,
                         @"updatedAt": @(claudeEnabled ? MAX(0.0, claudeUpdatedAt) : 0.0),
                         @"stale": [NSNumber numberWithBool:(claudeEnabled && claudeFailed)]}
        },
        @"selectedProvider": [selectedProvider isEqualToString:@"claude"] ? @"claude" : @"codex",
        @"displayMode": displayMode ?: @"follow",
        @"quotaStyle": [quotaStyle isEqual:@"ring"] ? @"ring" : @"bar",
        @"appearanceMode": [@[@"light", @"dark"] containsObject:appearanceMode] ? appearanceMode : @"system",
        @"dailyUsage": dailyUsage ?: @{},
        @"language": [@[@"zh-Hans", @"en", @"ja", @"es"] containsObject:language] ? language : @"en",
        @"localeIdentifier": NSLocale.currentLocale.localeIdentifier,
        @"claudeEnabled": [NSNumber numberWithBool:claudeEnabled]
    };
}

@interface QGWidgetServer () {
    int _listenFD;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _acceptQueue;
    NSData *_snapshotData;
}
@end

@implementation QGWidgetServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _acceptQueue = dispatch_queue_create("com.qingtanlabs.gaugeforcodex.widget-http", DISPATCH_QUEUE_SERIAL);
        _snapshotData = [@"{\"windows\":[],\"updatedAt\":0}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    return self;
}

- (BOOL)start {
    if (_listenFD >= 0) return YES;
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) return NO;

    int enabled = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(descriptor);
        return NO;
    }

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(QGWidgetPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(descriptor, (const struct sockaddr *)&address, sizeof(address)) < 0 ||
        listen(descriptor, 8) < 0) {
        close(descriptor);
        return NO;
    }

    _listenFD = descriptor;
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)descriptor, 0, _acceptQueue);
    if (!_acceptSource) {
        close(descriptor);
        _listenFD = -1;
        return NO;
    }
    __weak QGWidgetServer *weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        [weakSelf acceptConnections];
    });
    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(descriptor);
    });
    dispatch_resume(_acceptSource);
    return YES;
}

- (void)stop {
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    } else if (_listenFD >= 0) {
        close(_listenFD);
    }
    _listenFD = -1;
}

- (void)dealloc {
    [self stop];
}

- (void)updateWithCodexWindows:(NSArray<NSDictionary *> *)codexWindows
                codexUpdatedAt:(NSTimeInterval)codexUpdatedAt
                   codexFailed:(BOOL)codexFailed
                 codexPlanName:(NSString *)codexPlanName
                  claudeWindows:(NSArray<NSDictionary *> *)claudeWindows
               claudeUpdatedAt:(NSTimeInterval)claudeUpdatedAt
                  claudeFailed:(BOOL)claudeFailed
                claudePlanName:(NSString *)claudePlanName
              selectedProvider:(NSString *)selectedProvider
                   displayMode:(NSString *)displayMode
                    quotaStyle:(NSString *)quotaStyle
                appearanceMode:(NSString *)appearanceMode
                      language:(NSString *)language
                    dailyUsage:(NSDictionary *)dailyUsage
                 claudeEnabled:(BOOL)claudeEnabled
           legacyClaudeSupport:(BOOL)legacyClaudeSupport {
    NSDictionary *snapshot = QGWidgetSnapshot(codexWindows, codexUpdatedAt, codexFailed,
                                              claudeWindows, claudeUpdatedAt, claudeFailed,
                                              selectedProvider, displayMode, claudeEnabled, legacyClaudeSupport,
                                              codexPlanName, claudePlanName, quotaStyle, appearanceMode, language, dailyUsage);
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if (!data) return;
    @synchronized (self) {
        _snapshotData = data;
    }
}

- (void)acceptConnections {
    for (;;) {
        int client = accept(_listenFD, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            return;
        }
        int enabled = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
        int clientFlags = fcntl(client, F_GETFL, 0);
        if (clientFlags < 0 || fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) < 0) {
            close(client);
            continue;
        }
        struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self respondToClient:client];
        });
    }
}

- (void)sendData:(NSData *)data toClient:(int)client {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t count = send(client, bytes, remaining, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return;
        bytes += count;
        remaining -= (NSUInteger)count;
    }
}

- (void)respondToClient:(int)client {
    char request[2048] = {0};
    size_t length = 0;
    while (length < sizeof(request) - 1) {
        ssize_t count = recv(client, request + length, sizeof(request) - 1 - length, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        length += (size_t)count;
        if (memchr(request, '\n', length)) break;
    }
    request[length] = '\0';
    const char *lineEnd = memchr(request, '\n', length);
    size_t lineLength = lineEnd ? (size_t)(lineEnd - request) : length;
    while (lineLength > 0 && request[lineLength - 1] == '\r') lineLength--;
    NSString *requestLine = [[NSString alloc] initWithBytes:request length:lineLength encoding:NSASCIIStringEncoding];
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    BOOL valid = parts.count == 3 &&
        [parts[0] isEqualToString:@"GET"] &&
        ([parts[1] isEqualToString:@"/widget"] ||
         [parts[1] isEqualToString:@"http://127.0.0.1:38429/widget"]) &&
        ([parts[2] isEqualToString:@"HTTP/1.0"] || [parts[2] isEqualToString:@"HTTP/1.1"]);
    if (!valid) NSLog(@"Widget HTTP request rejected: %@", requestLine ?: @"<invalid ASCII>");
    NSData *body = nil;
    if (valid) {
        @synchronized (self) {
            body = _snapshotData;
        }
    } else {
        body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %@\r\nContent-Type: application/json; charset=utf-8\r\n"
         @"Cache-Control: no-store\r\nConnection: close\r\nContent-Length: %lu\r\n\r\n",
        valid ? @"200 OK" : @"404 Not Found", (unsigned long)body.length];
    [self sendData:[header dataUsingEncoding:NSUTF8StringEncoding] toClient:client];
    [self sendData:body toClient:client];
    close(client);
}

@end

BOOL QGRunWidgetSnapshotSelfTests(void) {
    NSArray *codex = @[@{@"remainingPercent": @42}];
    NSArray *claude = @[@{@"remainingPercent": @81}];
    NSDictionary *daily = @{@"days": @[], @"summary": @{@"lifetimeTokens": @120}, @"available": @YES};
    NSDictionary *dual = QGWidgetSnapshot(codex, 10, YES, claude, 20, NO, @"claude", @"both", YES, NO, @"Plus", @"Max 5×", @"bar", @"dark", @"zh-Hans", daily);
    BOOL dualPassed = [dual[@"displayMode"] isEqualToString:@"both"] &&
        [dual[@"providers"][@"codex"][@"windows"] isEqual:codex] &&
        [dual[@"providers"][@"claude"][@"windows"] isEqual:claude] &&
        [dual[@"providers"][@"codex"][@"stale"] boolValue] &&
        [dual[@"provider"] isEqualToString:@"codex"] && [dual[@"windows"] isEqual:codex] &&
        [dual[@"dailyUsage"] isEqual:daily];
    fprintf(stdout, "%s dual-provider snapshot with legacy fallback\n", dualPassed ? "PASS" : "FAIL");

    NSData *dualJSON = [NSJSONSerialization dataWithJSONObject:dual options:0 error:nil];
    NSString *dualJSONText = [[NSString alloc] initWithData:dualJSON encoding:NSUTF8StringEncoding];
    BOOL jsonBooleansPassed = [dualJSONText containsString:@"\"claudeEnabled\":true"] &&
        [dualJSONText containsString:@"\"stale\":true"] &&
        [dualJSONText containsString:@"\"stale\":false"];
    fprintf(stdout, "%s widget snapshot JSON booleans\n", jsonBooleansPassed ? "PASS" : "FAIL");

    NSDictionary *disabled = QGWidgetSnapshot(codex, 10, NO, claude, 20, YES, @"claude", @"both", NO, YES, @"private@example.com", @"Max 5×", @"unknown", @"invalid", @"invalid", nil);
    BOOL disabledPassed = [disabled[@"providers"][@"claude"][@"windows"] count] == 0 &&
        [disabled[@"provider"] isEqualToString:@"codex"] && [disabled[@"windows"] isEqual:codex];
    fprintf(stdout, "%s disconnected Claude hidden from widget\n", disabledPassed ? "PASS" : "FAIL");
    BOOL plansPassed = [dual[@"providers"][@"codex"][@"planName"] isEqual:@"Plus"] &&
        [dual[@"providers"][@"claude"][@"planName"] isEqual:@"Max 5×"] &&
        disabled[@"providers"][@"codex"][@"planName"] == NSNull.null &&
        disabled[@"providers"][@"claude"][@"planName"] == NSNull.null;
    fprintf(stdout, "%s widget plan labels allowlisted; disabled and invalid labels omitted\n", plansPassed ? "PASS" : "FAIL");
    NSDictionary *ring = QGWidgetSnapshot(codex, 10, NO, claude, 20, NO, @"codex", @"both", YES, YES, nil, nil, @"ring", @"light", @"en", nil);
    NSDictionary *unset = QGWidgetSnapshot(codex, 10, NO, claude, 20, NO, @"codex", @"both", YES, YES, nil, nil, nil, nil, nil, nil);
    BOOL stylePassed = [dual[@"quotaStyle"] isEqual:@"bar"] && [disabled[@"quotaStyle"] isEqual:@"bar"] &&
        [ring[@"quotaStyle"] isEqual:@"ring"] && [unset[@"quotaStyle"] isEqual:@"bar"];
    fprintf(stdout, "%s widget style propagated with safe default\n", stylePassed ? "PASS" : "FAIL");
    BOOL presentationPassed = [dual[@"appearanceMode"] isEqual:@"dark"] && [dual[@"language"] isEqual:@"zh-Hans"] &&
        [ring[@"appearanceMode"] isEqual:@"light"] && [ring[@"language"] isEqual:@"en"] &&
        [disabled[@"appearanceMode"] isEqual:@"system"] && [disabled[@"language"] isEqual:@"en"];
    fprintf(stdout, "%s widget appearance and language preferences allowlisted\n", presentationPassed ? "PASS" : "FAIL");
    return dualPassed && jsonBooleansPassed && disabledPassed && plansPassed && stylePassed && presentationPassed;
}
