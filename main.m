#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>

static CFMachPortRef tap;      // NULL until Accessibility is granted
static BOOL enabled = YES;     // the tap is enabled exactly when this is YES
static int64_t step;           // lines per wheel click while "Constant Scroll Speed" is on, 0 while off

static int sgn(double x) { return (x > 0) - (x < 0); }

// Runs for every scroll event in the session; WindowServer waits for it to return.
static CGEventRef flip(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *info) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (enabled) CGEventTapEnable(tap, true);       // WindowServer disabled us; recover
        return e;
    }
    if (type != kCGEventScrollWheel || CGEventGetIntegerValueField(e, kCGScrollWheelEventIsContinuous))
        return e;                                       // trackpad / Magic Mouse: untouched
    // Writing DeltaAxis makes CG re-derive the Point and FixedPt fields, so read before writing.
    const double  f1 = CGEventGetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis1);
    const double  f2 = CGEventGetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis2);
    if (step) {
        // Fixed step: write only the reversed line counts and let CG derive the rest, which drops the
        // acceleration macOS applied. FixedPt carries the sign even when a fine wheel tick rounds to 0 lines.
        CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1, -sgn(f1) * step);
        CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis2, -sgn(f2) * step);
        return e;
    }
    const int64_t l1 = CGEventGetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1);
    const int64_t l2 = CGEventGetIntegerValueField(e, kCGScrollWheelEventDeltaAxis2);
    const int64_t p1 = CGEventGetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis1);
    const int64_t p2 = CGEventGetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis2);
    // Apps read different fields: Terminal the lines, Chrome and Firefox FixedPt, Safari and Finder the pixels.
    // Both axes always: with Shift held, CG moves lines/FixedPt to axis 2 but leaves pixels on axis 1.
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1, -l1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis2, -l2);
    CGEventSetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis1, -f1);
    CGEventSetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis2, -f2);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis1, -p1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventPointDeltaAxis2, -p2);
    return e;
}

@interface App : NSObject <NSApplicationDelegate>
@end

@implementation App {
    NSStatusItem *item;
    NSMenuItem *toggle;
    NSMenuItem *fixed;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // A second copy (say the clone beside /Applications) would flip every event twice, so the newcomer quits.
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier].count > 1) exit(0);
    item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    item.button.image = [NSImage imageWithSystemSymbolName:@"computermouse" accessibilityDescription:@"Flipwheel"];
    NSMenu *const menu = [NSMenu new];
    toggle = [menu addItemWithTitle:@"" action:@selector(toggle:) keyEquivalent:@""];
    toggle.target = self;
    fixed = [menu addItemWithTitle:@"Constant Scroll Speed" action:@selector(fixed:) keyEquivalent:@""];
    fixed.target = self;
    [self setFixedStep:[NSUserDefaults.standardUserDefaults boolForKey:@"fixed"]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit Flipwheel" action:@selector(terminate:) keyEquivalent:@"q"];
    item.menu = menu;
    // Opens at login. The switch in System Settings > General > Login Items is the only control: once the
    // user turns it off there, the status is RequiresApproval, not NotRegistered, so this never overrides them.
    if (SMAppService.mainAppService.status == SMAppServiceStatusNotRegistered)
        [SMAppService.mainAppService registerAndReturnError:NULL];
    // Sleep can leave the tap dead on WindowServer's side; rebuild it once HID has settled after wake.
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(wake:)
                                                           name:NSWorkspaceDidWakeNotification object:nil];
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES });
    [self start];
}

// (Re)create the tap. Creation fails until Accessibility is granted, so retry every second.
// Main run loop on purpose: a dedicated tap thread measured no faster; the cost is the IPC round trip, not the callback.
- (void)start {
    if (tap) { CFMachPortInvalidate(tap); CFRelease(tap); }
    tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                           CGEventMaskBit(kCGEventScrollWheel), flip, NULL);
    if (!tap) {
        toggle.title = @"Open Accessibility Settings…";
        item.button.appearsDisabled = YES;
        [self performSelector:@selector(start) withObject:nil afterDelay:1];
        return;
    }
    CFRunLoopSourceRef const src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);  // common modes: keeps working while the menu is open
    CFRelease(src);
    toggle.title = @"Reverse Mouse Scrolling";
    [self setEnabled:enabled];
}

- (void)setEnabled:(BOOL)flag {
    enabled = flag;                         // must precede the disable: the callback checks it
    if (tap) CGEventTapEnable(tap, flag);   // off: WindowServer stops sending us events at all
    toggle.state = flag ? NSControlStateValueOn : NSControlStateValueOff;
    item.button.appearsDisabled = !flag;
}

// `defaults write com.bryant.flipwheel lines -int 5` changes the step; it is read each time the switch flips.
- (void)setFixedStep:(BOOL)flag {
    NSUserDefaults *const d = NSUserDefaults.standardUserDefaults;
    const NSInteger n = [d integerForKey:@"lines"];
    const int64_t lines = n > 0 ? n : 3;
    fixed.state = flag ? NSControlStateValueOn : NSControlStateValueOff;
    step = flag ? lines : 0;
    [d setBool:flag forKey:@"fixed"];
}

- (void)fixed:(id)sender { [self setFixedStep:!step]; }

- (void)toggle:(id)sender {
    if (tap) { [self setEnabled:!enabled]; return; }
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)wake:(NSNotification *)note {
    if (tap) [self performSelector:@selector(start) withObject:nil afterDelay:1];   // no tap: the retry loop is already running
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *const app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];  // no Dock icon, even unbundled
        __attribute__((objc_precise_lifetime)) App *const delegate = [App new];   // NSApp.delegate is weak
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
