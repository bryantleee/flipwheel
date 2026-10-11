#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <time.h>

static const int64_t PROBE_MARK = 0x4E535443;   // "NSTC". Our probes carry it in UserData; real scrolls carry 0.
static const CFTimeInterval TIMEOUT_SECONDS = 2;

static int64_t fixed_step_lines;    // Flipwheel's lines per click while Constant Scroll Speed is on, 0 while off
static CGEventRef received_event;   // the probe as it came back after Flipwheel's tap, NULL until it does
static int failures;

// The three forms of a scroll delta that a scroll event carries. Apps read different ones:
// Terminal the lines, Chrome and Firefox the fixed-point lines, Safari and Finder the pixels.
typedef struct {
    int64_t lines[2];     // kCGScrollWheelEventDeltaAxis1/2
    double  fixedpt[2];   // kCGScrollWheelEventFixedPtDeltaAxis1/2
    int64_t pixels[2];    // kCGScrollWheelEventPointDeltaAxis1/2
} Deltas;

static int     sgn(double x) { return (x > 0) - (x < 0); }
static double  now_ms(void)  { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e6; }
static int64_t int_field(CGEventRef event, CGEventField field)    { return CGEventGetIntegerValueField(event, field); }
static double  double_field(CGEventRef event, CGEventField field) { return CGEventGetDoubleValueField(event, field); }

static Deltas read_deltas(CGEventRef event) {
    return (Deltas){
        .lines   = { int_field(event, kCGScrollWheelEventDeltaAxis1),           int_field(event, kCGScrollWheelEventDeltaAxis2) },
        .fixedpt = { double_field(event, kCGScrollWheelEventFixedPtDeltaAxis1), double_field(event, kCGScrollWheelEventFixedPtDeltaAxis2) },
        .pixels  = { int_field(event, kCGScrollWheelEventPointDeltaAxis1),      int_field(event, kCGScrollWheelEventPointDeltaAxis2) },
    };
}

static void print_deltas(const char *label, Deltas d) {
    printf("       %-9s lines (%lld,%lld)  fixedpt (%.2f,%.2f)  pixels (%lld,%lld)\n",
           label, d.lines[0], d.lines[1], d.fixedpt[0], d.fixedpt[1], d.pixels[0], d.pixels[1]);
}

// What Flipwheel must have done to a probe.
typedef enum { UNCHANGED, REVERSED, FIXED_STEP } Expectation;
static const char *const expectation_name[] = { "unchanged", "reversed", "at the fixed step" };

static int holds(Expectation expected, Deltas sent, Deltas received, int axis) {
    switch (expected) {
    case UNCHANGED:
        return received.lines[axis] == sent.lines[axis] && received.fixedpt[axis] == sent.fixedpt[axis]
            && received.pixels[axis] == sent.pixels[axis];
    case REVERSED:
        return received.lines[axis] == -sent.lines[axis] && received.fixedpt[axis] == -sent.fixedpt[axis]
            && received.pixels[axis] == -sent.pixels[axis];
    case FIXED_STEP:
        // Flipwheel replaces the lines and macOS derives fixedpt and pixels from them, so only their sign is pinned.
        return received.lines[axis] == -sgn(sent.fixedpt[axis]) * fixed_step_lines
            && sgn(received.fixedpt[axis]) == -sgn(sent.fixedpt[axis]) && sgn(received.pixels[axis]) == -sgn(sent.pixels[axis]);
    }
    return 0;
}

// Runs for every scroll event in the session. Keeps a copy of our probe and wakes check() up.
static CGEventRef capture(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventScrollWheel && int_field(event, kCGEventSourceUserData) == PROBE_MARK) {
        received_event = CGEventCreateCopy(event);
        CFRunLoopStop(CFRunLoopGetMain());
    }
    return event;
}

// Posts one marked scroll event, waits for it to come back through Flipwheel's tap, and compares the two.
static void check(const char *name, CGScrollEventUnit unit, Expectation expected) {
    CGEventRef const probe = CGEventCreateScrollWheelEvent(NULL, unit, 2, 1, 2);   // 1 unit on axis 1 (vertical), 2 on axis 2
    CGEventSetIntegerValueField(probe, kCGEventSourceUserData, PROBE_MARK);
    const Deltas sent = read_deltas(probe);
    received_event = NULL;
    const double posted_at = now_ms();
    CGEventPost(kCGSessionEventTap, probe);
    CFRelease(probe);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, TIMEOUT_SECONDS, false);   // returns early once capture() stops the loop
    const double round_trip = now_ms() - posted_at;
    if (!received_event) {
        printf("FAIL %s never came back through the tap\n", name);
        failures++;
        return;
    }
    const Deltas received = read_deltas(received_event);
    CFRelease(received_event);
    const int ok = holds(expected, sent, received, 0) && holds(expected, sent, received, 1);
    failures += !ok;
    printf("%s %s comes back %s, round trip %.1f ms\n", ok ? "ok  " : "FAIL", name, expectation_name[expected], round_trip);
    print_deltas("sent", sent);
    print_deltas("received", received);
}

// Flipwheel keeps its switches in its defaults: "fixed" is Constant Scroll Speed, "lines" the step (3 unless set).
static int64_t read_fixed_step_lines(void) {
    const CFStringRef app = CFSTR("com.bryant.flipwheel");
    Boolean valid;
    if (!CFPreferencesGetAppBooleanValue(CFSTR("fixed"), app, &valid) || !valid) return 0;
    const CFIndex lines = CFPreferencesGetAppIntegerValue(CFSTR("lines"), app, &valid);
    return valid && lines > 0 ? lines : 3;
}

int main(void) {
    fixed_step_lines = read_fixed_step_lines();
    printf("Flipwheel mode: %s\n", fixed_step_lines ? "Constant Scroll Speed" : "reverse only");
    // Appended after Flipwheel's tap, so it sees the events as Flipwheel left them.
    CFMachPortRef const tap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap, kCGEventTapOptionDefault,
                                               CGEventMaskBit(kCGEventScrollWheel), capture, NULL);
    if (!tap) {
        printf("FAIL cannot create a tap; grant Accessibility to this terminal\n");
        return 1;
    }
    CFRunLoopSourceRef const source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);

    check("wheel click",    kCGScrollEventUnitLine,  fixed_step_lines ? FIXED_STEP : REVERSED);
    check("trackpad swipe", kCGScrollEventUnitPixel, UNCHANGED);

    CFMachPortInvalidate(tap);
    CFRelease(tap);
    return failures != 0;
}
