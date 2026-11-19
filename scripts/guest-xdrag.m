// C11H-207 guest-only pointer driver: a real, timestamped HID drag in global screen points,
// able to cross from one window into another. Usage: xdrag X1 Y1 X2 Y2 [steps] [hold_ms] [escape_at_ms]
//                                                    xdrag click X Y
// escape_at_ms presses Escape (a timestamped HID key event) that far into the hold.
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#include <time.h>
#include <unistd.h>

static CGEventSourceRef source;
static CGPoint last;

static void post(CGEventType type, CGPoint p) {
    CGEventRef e = CGEventCreateMouseEvent(source, type, p, kCGMouseButtonLeft);
    if (type == kCGEventLeftMouseDragged || type == kCGEventMouseMoved) {
        CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, (int64_t)lround(p.x - last.x));
        CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, (int64_t)lround(p.y - last.y));
    }
    last = p;
    CGEventSetFlags(e, 0);
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, type == kCGEventMouseMoved ? 0 : 1);
    CGEventSetTimestamp(e, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (argc == 4 && strcmp(argv[1], "click") == 0) {
            CGPoint p = CGPointMake(atof(argv[2]), atof(argv[3]));
            post(kCGEventMouseMoved, p); usleep(120000);
            post(kCGEventLeftMouseDown, p); usleep(80000);
            post(kCGEventLeftMouseUp, p); usleep(150000);
            return 0;
        }
        if (argc < 5) { fprintf(stderr, "usage: xdrag X1 Y1 X2 Y2 [steps] [hold_ms]\n"); return 2; }
        CGPoint a = CGPointMake(atof(argv[1]), atof(argv[2]));
        CGPoint b = CGPointMake(atof(argv[3]), atof(argv[4]));
        int steps = argc > 5 ? atoi(argv[5]) : 40;
        int hold = argc > 6 ? atoi(argv[6]) : 400;
        int escapeAt = argc > 7 ? atoi(argv[7]) : -1;
        post(kCGEventMouseMoved, a); usleep(150000);
        post(kCGEventLeftMouseDown, a); usleep(150000);
        // A few small moves first so the drag gesture passes its threshold near the source.
        for (int i = 1; i <= 6; ++i) { post(kCGEventLeftMouseDragged, CGPointMake(a.x + i * 2, a.y + i)); usleep(20000); }
        CGPoint s = CGPointMake(a.x + 12, a.y + 6);
        for (int i = 1; i <= steps; ++i) {
            double t = (double)i / steps;
            post(kCGEventLeftMouseDragged, CGPointMake(s.x + (b.x - s.x) * t, s.y + (b.y - s.y) * t));
            usleep(18000);
        }
        for (int i = 0; i < hold / 50; ++i) {
            if (escapeAt >= 0 && i == escapeAt / 50) {
                for (int down = 1; down >= 0; --down) {
                    CGEventRef k = CGEventCreateKeyboardEvent(source, (CGKeyCode)53, down);
                    CGEventSetFlags(k, 0);
                    CGEventSetTimestamp(k, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
                    CGEventPost(kCGHIDEventTap, k);
                    CFRelease(k);
                    usleep(60000);
                }
            }
            post(kCGEventLeftMouseDragged, b); usleep(50000);
        }
        post(kCGEventLeftMouseUp, b); usleep(300000);
    }
    return 0;
}
