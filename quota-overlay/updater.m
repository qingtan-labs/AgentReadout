#import <Cocoa/Cocoa.h>
#import <signal.h>
#import <errno.h>
#import <libproc.h>
#import <CoreServices/CoreServices.h>

static BOOL QGRegisterApp(NSString *path) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    if (![info[@"CFBundleIdentifier"] isEqual:@"com.qingtanlabs.gaugeforcodex"]) return NO;
    return LSRegisterURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], true) == noErr;
}

static void QGStopWidgetForApp(NSString *appPath) {
    NSString *expected = [[appPath stringByAppendingPathComponent:
        @"Contents/PlugIns/GaugeForCodexWidget.appex/Contents/MacOS/GaugeForCodexWidget"] stringByResolvingSymlinksInPath];
    int capacity = proc_listallpids(NULL, 0) + 64;
    if (capacity <= 64) return;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return;
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    for (int index = 0; index < MIN(count, capacity); index++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (pids[index] > 1 && proc_pidpath(pids[index], path, sizeof(path)) > 0 &&
            [@(path).stringByResolvingSymlinksInPath isEqual:expected]) {
            // Only this installation's extension, never chronod or other widgets.
            kill(pids[index], SIGTERM);
        }
    }
    free(pids);
}

static BOOL QGRun(NSString *executable, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

// Injectable operations let regression tests exercise every rollback branch
// using fixtures, without starting/stopping the user's app.
@interface QGUpdateOperations : NSObject
- (BOOL)copy:(NSString *)source to:(NSString *)destination;
- (BOOL)move:(NSString *)source to:(NSString *)destination;
- (BOOL)validate:(NSString *)path version:(NSString *)version build:(NSString *)build;
- (BOOL)launch:(NSString *)path;
- (void)retireBackup:(NSString *)directory;
- (void)stopWidget:(NSString *)appPath;
@end

@implementation QGUpdateOperations
- (void)stopWidget:(NSString *)appPath { QGStopWidgetForApp(appPath); }
- (BOOL)copy:(NSString *)source to:(NSString *)destination {
    return QGRun(@"/usr/bin/ditto", @[source, destination]);
}
- (BOOL)move:(NSString *)source to:(NSString *)destination {
    return [NSFileManager.defaultManager moveItemAtPath:source toPath:destination error:nil];
}
- (BOOL)validate:(NSString *)path version:(NSString *)version build:(NSString *)build {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    return [info[@"CFBundleIdentifier"] isEqual:@"com.qingtanlabs.gaugeforcodex"] &&
        [info[@"CFBundleShortVersionString"] isEqual:version] &&
        (!build.length || [info[@"CFBundleVersion"] isEqual:build]) &&
        QGRun(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", path]);
}
- (BOOL)launch:(NSString *)path {
    if (!QGRegisterApp(path)) return NO;
    if (!QGRun(@"/usr/bin/open", @[@"-n", path])) return NO;
    NSString *expected = path.stringByResolvingSymlinksInPath;
    for (NSUInteger attempt = 0; attempt < 50; attempt++) {
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.qingtanlabs.gaugeforcodex"]) {
            if (!app.terminated && [app.bundleURL.path.stringByResolvingSymlinksInPath isEqual:expected]) return YES;
        }
        usleep(100000);
    }
    return NO;
}
- (void)retireBackup:(NSString *)directory {
    // Preserve a recoverable copy instead of deleting the last working build.
    [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:directory] resultingItemURL:nil error:nil];
}
@end

static int QGInstallReplacement(NSString *target, NSString *replacement, NSString *version, NSString *build,
                                QGUpdateOperations *operations) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *work = [target.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [@".gauge-update-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *staging = [work stringByAppendingPathComponent:@"New.app"];
    NSString *backup = [work stringByAppendingPathComponent:@"Previous.app"];
    __block BOOL movedOld = NO;
    __block BOOL createdWork = NO;
    int (^recover)(int) = ^int(int status) {
        if (movedOld) {
            if ([files fileExistsAtPath:target] &&
                ![operations move:target to:[work stringByAppendingPathComponent:@"Rejected.app"]]) {
                // Never delete a potentially recoverable installation.
                [operations launch:backup];
                NSLog(@"AgentReadout update recovery requires manual restore from %@", backup);
                return 71;
            }
            if (![operations move:backup to:target]) {
                [operations launch:backup];
                NSLog(@"AgentReadout update recovery requires manual restore from %@", backup);
                return 71;
            }
        }
        BOOL relaunched = [operations launch:target];
        if (createdWork && ![files fileExistsAtPath:backup]) [files removeItemAtPath:work error:nil];
        NSLog(@"AgentReadout update failed (%d); previous application restart %@", status, relaunched ? @"succeeded" : @"failed");
        return status;
    };

    if (![files createDirectoryAtPath:work withIntermediateDirectories:NO attributes:nil error:nil]) return recover(65);
    createdWork = YES;
    if (![operations copy:replacement to:staging] || ![operations validate:staging version:version build:build]) return recover(65);
    [operations stopWidget:target];
    if (![operations move:target to:backup]) return recover(66);
    movedOld = YES;
    if (![operations move:staging to:target]) return recover(67);
    if (![operations launch:target]) return recover(68);
    [operations retireBackup:work];
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--register-app") == 0) {
            return QGRegisterApp(@(argv[2])) ? 0 : 65;
        }
        if (argc == 3 && strcmp(argv[1], "--stop-widget") == 0) {
            QGStopWidgetForApp(@(argv[2]));
            return 0;
        }
        // Keep accepting the older host's argument list.
        if (argc != 6 && argc != 7) return 64;
        pid_t parentPID = (pid_t)strtol(argv[1], NULL, 10);
        if (parentPID <= 1) return 64;
        NSString *target = [NSString stringWithUTF8String:argv[2]];
        NSString *replacement = [NSString stringWithUTF8String:argv[3]];
        NSString *version = [NSString stringWithUTF8String:argv[4]];
        NSString *cleanup = [NSString stringWithUTF8String:argv[5]];
        NSString *build = argc == 7 ? [NSString stringWithUTF8String:argv[6]] : @"";
        for (NSUInteger attempt = 0; attempt < 300 && (kill(parentPID, 0) == 0 || errno == EPERM); attempt++) usleep(100000);
        if (kill(parentPID, 0) == 0 || errno == EPERM) return 69; // Don't replace a still-running parent.
        int status = QGInstallReplacement(target, replacement, version, build, [QGUpdateOperations new]);
        // Only clean our own download directory, never an arbitrary argument.
        NSString *temporary = NSTemporaryDirectory().stringByStandardizingPath;
        NSString *resolved = cleanup.stringByStandardizingPath;
        if (status == 0 && [resolved hasPrefix:[temporary stringByAppendingString:@"/"]] &&
            [resolved.lastPathComponent hasPrefix:@"GaugeForCodexUpdate-"] &&
            [replacement.stringByStandardizingPath hasPrefix:[resolved stringByAppendingString:@"/"]]) {
            [NSFileManager.defaultManager removeItemAtPath:resolved error:nil];
        }
        return status;
    }
}
