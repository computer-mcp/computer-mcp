#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <dlfcn.h>
#include <libproc.h>

// The target owns every window, AX element and Apple event used by this fixture.
// Captures are limited to the fixture window. Only request-permissions prompts.
static const AEEventClass FixtureClass = 'CMCP';
static const AEEventID FixtureEvent = 'ping';

@interface ServiceTarget : NSObject
@property(nonatomic, copy) NSString *token;
- (void)receiveEvent:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply;
@end

@implementation ServiceTarget
- (void)receiveEvent:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply {
    [reply setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:self.token]
                   forKeyword:keyDirectObject];
}
@end

static int runProbe(NSString *executable, NSArray<NSString *> *arguments, NSString *profile, NSString *root) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:profile ? @"/usr/bin/sandbox-exec" : executable];
    task.arguments = profile ? [@[@"-f", profile, executable] arrayByAddingObjectsFromArray:arguments] : arguments;
    task.environment = @{@"PATH": @"/usr/bin:/bin", @"HOME": [root stringByAppendingPathComponent:@"home"],
        @"TMPDIR": [root stringByAppendingPathComponent:@"tmp"],
        @"FIXTURE_RESPONSIBLE_PID": [NSString stringWithFormat:@"%d", getpid()]};
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:[root stringByAppendingPathComponent:@"probe.log"]];
    [log seekToEndOfFile];
    [log writeData:[[NSString stringWithFormat:@"%@ %@\n", arguments.firstObject, profile.lastPathComponent ?: @"control"] dataUsingEncoding:NSUTF8StringEncoding]];
    task.standardOutput = log;
    task.standardError = log;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return 2;
    [task waitUntilExit];
    [log closeFile];
    int status = task.terminationStatus;
    if ([arguments.firstObject isEqual:@"screen-cli"]) {
        NSString *output = [root stringByAppendingPathComponent:@"tmp/fixture-window.png"];
        NSImageRep *image = [NSBitmapImageRep imageRepWithContentsOfFile:output];
        if (status == 0 && !(image.pixelsWide > 0 && image.pixelsHigh > 0)) status = 1;
        [NSFileManager.defaultManager removeItemAtPath:output error:nil];
    }
    return status;
}

static void runMatrix(NSString *root, NSString *token, CGWindowID windowID) {
    NSString *executable = NSBundle.mainBundle.executablePath;
    NSMutableDictionary *results = [NSMutableDictionary new];
    [[NSData data] writeToFile:[root stringByAppendingPathComponent:@"probe.log"] atomically:YES];
    int (*responsible)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    results[@"hostPID"] = @(getpid());
    results[@"responsiblePID"] = responsible ? @(responsible(getpid())) : @(-1);
    NSArray *services = @[@"screen", @"screen-cg", @"screen-cli", @"accessibility", @"apple-events"];
    for (NSString *service in services) {
        NSArray *arguments = @[service, [NSString stringWithFormat:@"%d", getpid()],
            [NSString stringWithFormat:@"%u", windowID], token];
        NSArray *preflight = [service isEqual:@"apple-events"]
            ? [@[@"preflight-apple-events"] arrayByAddingObjectsFromArray:[arguments subarrayWithRange:NSMakeRange(1, 3)]]
            : @[[ @"preflight-" stringByAppendingString:[service hasPrefix:@"screen"] ? @"screen" : service]];
        int status = runProbe(executable, preflight, nil, root);
        results[[service stringByAppendingString:@"/preflight"]] = @(status);
        if (status != 0) continue;
        status = runProbe(executable, arguments, nil, root);
        results[[service stringByAppendingString:@"/control"]] = @(status);
        if (status != 0) continue;
        for (int mask = 0; mask < 8; ++mask) {
            NSString *profile = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.sb", mask]];
            results[[NSString stringWithFormat:@"%@/%d", service, mask]] = @(runProbe(executable, arguments, profile, root));
        }
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingSortedKeys error:nil];
    [data writeToFile:[root stringByAppendingPathComponent:@"results.json"] atomically:YES];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}

static void requestPermissions(NSString *root, NSString *token, CGWindowID windowID) {
    if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    if (!AXIsProcessTrusted()) {
        NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
    NSString *log = [root stringByAppendingPathComponent:@"probe.log"];
    if (![NSFileManager.defaultManager fileExistsAtPath:log]) [[NSData data] writeToFile:log atomically:YES];
    runProbe(NSBundle.mainBundle.executablePath, @[@"request-apple-events",
        [NSString stringWithFormat:@"%d", getpid()], [NSString stringWithFormat:@"%u", windowID], token], nil, root);
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}

static int target(NSString *root, NSString *token, BOOL requestsPermissions) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    __attribute__((objc_precise_lifetime)) ServiceTarget *receiver = [ServiceTarget new];
    receiver.token = token;
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:receiver
        andSelector:@selector(receiveEvent:reply:) forEventClass:FixtureClass andEventID:FixtureEvent];
    __attribute__((objc_precise_lifetime)) NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 160, 120)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title = token;
    window.backgroundColor = NSColor.blueColor;
    window.restorable = NO;
    [window orderFront:nil];
    CGWindowID windowID = (CGWindowID)window.windowNumber;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (requestsPermissions) requestPermissions(root, token, windowID);
        else runMatrix(root, token, windowID);
    });
    alarm(requestsPermissions ? 600 : 180);
    [NSApp run];
    return 0;
}

static int screen(pid_t pid, CGWindowID windowID) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int result = 1;
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
        completionHandler:^(SCShareableContent *content, NSError *error) {
            if (error) {
                fprintf(stderr, "screen enumeration: %ld\n", (long)error.code);
                dispatch_semaphore_signal(done);
                return;
            }
            SCWindow *selected = nil;
            for (SCWindow *candidate in content.windows) {
                if (candidate.windowID == windowID && candidate.owningApplication.processID == pid) {
                    selected = candidate;
                    break;
                }
            }
            if (!selected) { dispatch_semaphore_signal(done); return; }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:selected];
            SCStreamConfiguration *configuration = [SCStreamConfiguration new];
            configuration.width = 160;
            configuration.height = 120;
            configuration.showsCursor = NO;
            [SCScreenshotManager captureImageWithFilter:filter configuration:configuration
                completionHandler:^(CGImageRef image, NSError *captureError) {
                    if (image && !captureError && CGImageGetWidth(image) == 160 && CGImageGetHeight(image) == 120) result = 0;
                    fprintf(stderr, "screen capture: %ld\n", (long)captureError.code);
                    dispatch_semaphore_signal(done);
                }];
        }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) return 3;
    return result;
}

static int screenCG(CGWindowID windowID) {
    CGImageRef (*capture)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) =
        dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (!capture) return 77;
    CGImageRef image = capture(CGRectNull, kCGWindowListOptionIncludingWindow, windowID,
        kCGWindowImageBoundsIgnoreFraming);
    if (!image) return 1;
    int result = CGImageGetWidth(image) > 0 && CGImageGetHeight(image) > 0 ? 0 : 1;
    CGImageRelease(image);
    return result;
}

static int screenCLI(CGWindowID windowID) {
    NSString *output = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fixture-window.png"];
    [NSFileManager.defaultManager removeItemAtPath:output error:nil];
    NSString *identifier = [NSString stringWithFormat:@"%u", windowID];
    // exec preserves the probe's alarm and inherited responsibility.
    execl("/usr/sbin/screencapture", "screencapture", "-x", "-l", identifier.UTF8String, output.fileSystemRepresentation, NULL);
    return 2;
}

static int accessibility(pid_t pid, NSString *token) {
    AXUIElementRef application = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(application, 3);
    CFTypeRef windows = NULL;
    AXError error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &windows);
    int result = 1;
    if (error == kAXErrorSuccess && windows && CFGetTypeID(windows) == CFArrayGetTypeID()) {
        for (id window in (__bridge NSArray *)windows) {
            CFTypeRef title = NULL;
            AXError titleError = AXUIElementCopyAttributeValue((__bridge AXUIElementRef)window, kAXTitleAttribute, &title);
            if (titleError == kAXErrorSuccess && [(__bridge id)title isEqual:token]) result = 0;
            if (title) CFRelease(title);
        }
    }
    fprintf(stderr, "accessibility: %d\n", error);
    if (windows) CFRelease(windows);
    CFRelease(application);
    return result;
}

static int appleEvents(pid_t pid, NSString *token, BOOL preflight, BOOL requestPermission) {
    NSAppleEventDescriptor *address = [NSAppleEventDescriptor descriptorWithProcessIdentifier:pid];
    if (preflight) {
        OSStatus status = AEDeterminePermissionToAutomateTarget(address.aeDesc, FixtureClass, FixtureEvent, requestPermission);
        fprintf(stderr, "apple events preflight: %d\n", (int)status);
        return status == noErr ? 0 : 77;
    }
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:FixtureClass
        eventID:FixtureEvent targetDescriptor:address returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    NSError *error = nil;
    NSAppleEventDescriptor *reply = [event sendEventWithOptions:NSAppleEventSendWaitForReply | NSAppleEventSendNeverInteract
        timeout:3 error:&error];
    fprintf(stderr, "apple events: %ld\n", (long)error.code);
    return !error && [[[reply paramDescriptorForKeyword:keyDirectObject] stringValue] isEqual:token] ? 0 : 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "request-permissions")) {
            NSString *root = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.path;
            return target(root, NSUUID.UUID.UUIDString, YES);
        }
        if (argc == 4 && !strcmp(argv[1], "host")) return target(@(argv[2]), @(argv[3]), NO);
        alarm(8);
        const char *expected = getenv("FIXTURE_RESPONSIBLE_PID");
        if (expected) {
            int (*responsible)(pid_t) = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
            if (!responsible || responsible(getpid()) != atoi(expected)) return 78;
        }
        if (argc == 2 && !strcmp(argv[1], "preflight-screen")) return CGPreflightScreenCaptureAccess() ? 0 : 77;
        if (argc == 2 && !strcmp(argv[1], "preflight-accessibility")) return AXIsProcessTrusted() ? 0 : 77;
        if (argc != 5) return 2;
        pid_t pid = atoi(argv[2]);
        if (!strcmp(argv[1], "screen")) return screen(pid, (CGWindowID)strtoul(argv[3], NULL, 10));
        if (!strcmp(argv[1], "screen-cg")) return screenCG((CGWindowID)strtoul(argv[3], NULL, 10));
        if (!strcmp(argv[1], "screen-cli")) return screenCLI((CGWindowID)strtoul(argv[3], NULL, 10));
        if (!strcmp(argv[1], "accessibility")) return accessibility(pid, @(argv[4]));
        if (!strcmp(argv[1], "apple-events")) return appleEvents(pid, @(argv[4]), NO, NO);
        if (!strcmp(argv[1], "preflight-apple-events")) return appleEvents(pid, @(argv[4]), YES, NO);
        if (!strcmp(argv[1], "request-apple-events")) {
            alarm(300);
            return appleEvents(pid, @(argv[4]), YES, YES);
        }
        return 2;
    }
}
