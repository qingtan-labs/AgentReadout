#import <Cocoa/Cocoa.h>
#import <signal.h>

static BOOL QGRun(NSString *executable, NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

static BOOL QGValidateApp(NSString *path, NSString *expectedVersion) {
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (!bundle || ![bundle.bundleIdentifier isEqualToString:@"com.qingtanlabs.gaugeforcodex"]) return NO;
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (expectedVersion.length && ![version isEqualToString:expectedVersion]) return NO;
    return QGRun(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", path]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 6) return 64;
        pid_t parentPID = (pid_t)strtol(argv[1], NULL, 10);
        NSString *target = [NSString stringWithUTF8String:argv[2]];
        NSString *replacement = [NSString stringWithUTF8String:argv[3]];
        NSString *version = [NSString stringWithUTF8String:argv[4]];
        NSString *cleanupDirectory = [NSString stringWithUTF8String:argv[5]];
        NSFileManager *files = NSFileManager.defaultManager;

        for (NSInteger attempt = 0; attempt < 300 && kill(parentPID, 0) == 0; attempt++) {
            usleep(100000);
        }

        NSString *staging = [target stringByAppendingString:@".updating"];
        NSString *backup = [target stringByAppendingString:@".previous"];
        [files removeItemAtPath:staging error:nil];
        [files removeItemAtPath:backup error:nil];

        if (!QGRun(@"/usr/bin/ditto", @[replacement, staging]) || !QGValidateApp(staging, version)) {
            [files removeItemAtPath:staging error:nil];
            return 65;
        }

        NSError *error = nil;
        if (![files moveItemAtPath:target toPath:backup error:&error]) {
            [files removeItemAtPath:staging error:nil];
            return 66;
        }
        if (![files moveItemAtPath:staging toPath:target error:&error]) {
            [files moveItemAtPath:backup toPath:target error:nil];
            return 67;
        }

        if (!QGRun(@"/usr/bin/open", @[@"-n", target])) {
            [files removeItemAtPath:target error:nil];
            [files moveItemAtPath:backup toPath:target error:nil];
            QGRun(@"/usr/bin/open", @[@"-n", target]);
            return 68;
        }

        sleep(2);
        [files removeItemAtPath:backup error:nil];
        if (cleanupDirectory.length) [files removeItemAtPath:cleanupDirectory error:nil];
    }
    return 0;
}
