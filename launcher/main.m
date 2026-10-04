#import <Cocoa/Cocoa.h>
#import <unistd.h>

static NSString * const QLBundleID = @"com.qingtanlabs.gaugeforcodex";
static NSString * const QLAgentLabel = @"com.qingtanlabs.gaugeforcodex";

static NSString *QLAppPath(void) {
    NSURL *registeredURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:QLBundleID];
    if (registeredURL && [NSFileManager.defaultManager fileExistsAtPath:registeredURL.path]) {
        return registeredURL.path;
    }
    NSArray<NSString *> *candidates = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/AgentReadout.app"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/Gauge for Codex.app"],
        @"/Applications/AgentReadout.app",
        @"/Applications/Gauge for Codex.app"
    ];
    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    }
    return candidates.firstObject;
}

static NSString *QLText(NSString *key) {
    NSDictionary *english = @{
        @"title": @"AgentReadout could not start",
        @"missing": @"AgentReadout is not installed at %@.",
        @"timeout": @"Opening AgentReadout timed out.",
        @"failure": @"Could not open AgentReadout: %@",
        @"ok": @"OK"
    };
    NSDictionary *chinese = @{
        @"title": @"AgentReadout 未能启动",
        @"missing": @"在 %@ 找不到 AgentReadout。",
        @"timeout": @"启动 AgentReadout 超时。",
        @"failure": @"无法打开 AgentReadout：%@",
        @"ok": @"好"
    };
    NSDictionary *japanese = @{
        @"title": @"AgentReadout を起動できません",
        @"missing": @"%@ に AgentReadout がインストールされていません。",
        @"timeout": @"AgentReadout の起動がタイムアウトしました。",
        @"failure": @"AgentReadout を開けません：%@",
        @"ok": @"OK"
    };
    NSDictionary *spanish = @{
        @"title": @"No se pudo iniciar AgentReadout",
        @"missing": @"AgentReadout no está instalado en %@.",
        @"timeout": @"Se agotó el tiempo al abrir AgentReadout.",
        @"failure": @"No se pudo abrir AgentReadout: %@",
        @"ok": @"Aceptar"
    };
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"en";
    NSDictionary *table = [language hasPrefix:@"zh"] ? chinese :
        ([language hasPrefix:@"ja"] ? japanese : ([language hasPrefix:@"es"] ? spanish : english));
    return table[key] ?: english[key] ?: key;
}

static BOOL QLAppIsRunning(void) {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:QLBundleID].count > 0;
}

static BOOL QLKickstart(void) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = @[
        @"kickstart",
        [NSString stringWithFormat:@"gui/%u/%@", getuid(), QLAgentLabel]
    ];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

static BOOL QLOpenApplication(NSError **resultError) {
    NSString *path = QLAppPath();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        if (resultError) {
            *resultError = [NSError errorWithDomain:@"GaugeForCodexLauncher" code:1
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:QLText(@"missing"), path]}];
        }
        return NO;
    }

    __block BOOL finished = NO;
    __block NSError *openError = nil;
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:path]
                                         configuration:configuration
                                     completionHandler:^(NSRunningApplication *application, NSError *error) {
        (void)application;
        openError = error;
        finished = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    while (!finished && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!finished && !openError) {
        openError = [NSError errorWithDomain:@"GaugeForCodexLauncher" code:2
            userInfo:@{NSLocalizedDescriptionKey: QLText(@"timeout")}];
    }
    if (resultError) *resultError = openError;
    return finished && !openError;
}

static int QLRunSelfTest(void) {
    NSString *resolvedName = QLAppPath().lastPathComponent;
    BOOL pathPassed = [resolvedName isEqualToString:@"AgentReadout.app"] ||
        [resolvedName isEqualToString:@"Gauge for Codex.app"];
    BOOL bundlePassed = [QLBundleID isEqualToString:QLAgentLabel];
    fprintf(stdout, "%s resolves an application path\n", pathPassed ? "PASS" : "FAIL");
    fprintf(stdout, "%s bundle and launch-agent identifiers match\n", bundlePassed ? "PASS" : "FAIL");
    return pathPassed && bundlePassed ? 0 : 1;
}

static void QLShowError(NSString *message) {
    if (!message.length) return;
    NSApplication *application = NSApplication.sharedApplication;
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [application activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = QLText(@"title");
    alert.informativeText = message;
    [alert addButtonWithTitle:QLText(@"ok")];
    [alert runModal];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return QLRunSelfTest();
        if (QLAppIsRunning()) return 0;
        if (QLKickstart()) return 0;
        NSError *error = nil;
        if (!QLOpenApplication(&error)) {
            NSString *detail = error.localizedDescription ?: @"Unknown error";
            QLShowError([NSString stringWithFormat:QLText(@"failure"), detail]);
            return 1;
        }
    }
    return 0;
}
