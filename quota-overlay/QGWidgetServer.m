#import "QGWidgetServer.h"

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

- (void)updateWithWindows:(NSArray<NSDictionary *> *)windows updatedAt:(NSTimeInterval)timestamp {
    NSDictionary *snapshot = @{
        @"windows": windows ?: @[],
        @"updatedAt": @(MAX(0.0, timestamp))
    };
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
