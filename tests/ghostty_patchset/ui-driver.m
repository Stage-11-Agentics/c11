// C11-294 real UI fixture helper. All input is PID-targeted; activate is explicit.
// Compile through scripts/with-build-lock.sh:
// xcrun clang -std=c11 -fobjc-arc -Wall -Wextra tests/ghostty_patchset/ui-driver.m
//   -o /tmp/c11-294-ui-driver -framework Cocoa -framework ApplicationServices -framework Carbon
// Always list/check the exact tagged PID and CGWindow before driving a scenario.
// Posted events and accepted activation requests require screenshot/oracle proof.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <libproc.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

static void timeout_exit(int sig) {
    (void)sig;
    const char msg[] = "{\"error\":\"driver timed out after 8 seconds\"}\n";
    (void)write(2, msg, sizeof(msg)-1);
    _exit(124);
}
static void output(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
}
static void fail(NSString *message) { output(@{@"error":message}); exit(1); }
static pid_t target_pid;
static uint64_t first_post_ns;
// Give a pressed event its own delivery interval before releasing it. This is
// fixture pacing, not confirmation that the destination consumed the event.
static const useconds_t event_spacing_us = 20000;
static NSString *target_tag, *target_path;
static void verify_process(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(target_pid, path, sizeof(path)) <= 0) fail(@"PID is absent or executable path cannot be read");
    NSString *current = @(path);
    NSString *bundleComponent = [NSString stringWithFormat:@"/c11 DEV %@.app/Contents/MacOS/", target_tag];
    if (target_tag.length == 0 || [target_tag containsString:@"/"] || ![current containsString:bundleComponent])
        fail(@"Executable must be a tagged c11 DEV app containing the supplied tag");
    if (target_path && ![current isEqualToString:target_path]) fail(@"Target executable changed during run");
    target_path = current;
}
static NSArray *owned_windows(void) {
    NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *window in all) if ([window[(id)kCGWindowOwnerPID] intValue] == target_pid) [result addObject:window];
    return result;
}
static CGRect window_bounds(NSDictionary *window) {
    CGRect bounds;
    if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds)) fail(@"Missing window geometry");
    return bounds;
}
static NSDictionary *exact_window(CGWindowID wid, BOOL require_onscreen) {
    verify_process();
    for (NSDictionary *window in owned_windows()) if ([window[(id)kCGWindowNumber] unsignedIntValue] == wid) {
        if ([window[(id)kCGWindowLayer] intValue] != 0 || (require_onscreen && ![window[(id)kCGWindowIsOnscreen] boolValue])) fail(@"Target must be a layer-zero window and onscreen for input");
        return window;
    }
    fail(@"Window ID is not owned by verified target PID"); return nil;
}
static void require_focused_window(NSDictionary *window) {
    // Keyboard events are PID-scoped, not window-scoped. Refuse them unless
    // the target PID's AX-focused window matches the requested CG geometry.
    AXUIElementRef app = AXUIElementCreateApplication(target_pid);
    CFTypeRef focused = NULL, position = NULL, size = NULL;
    AXError err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &focused);
    CFRelease(app);
    if (err != kAXErrorSuccess || !focused) fail(@"Cannot inspect target focused window; Accessibility permission or a focused window is missing");
    AXUIElementCopyAttributeValue((AXUIElementRef)focused, kAXPositionAttribute, &position);
    AXUIElementCopyAttributeValue((AXUIElementRef)focused, kAXSizeAttribute, &size);
    CGPoint point; CGSize dimensions;
    BOOL ok = position && size && CFGetTypeID(position)==AXValueGetTypeID() && CFGetTypeID(size)==AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)position, kAXValueCGPointType, &point) && AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &dimensions);
    if (position) CFRelease(position); if (size) CFRelease(size); CFRelease(focused);
    if (!ok) fail(@"Target focused-window geometry unavailable");
    CGRect requested = window_bounds(window);
    if (fabs(point.x-requested.origin.x)>1 || fabs(point.y-requested.origin.y)>1 ||
        fabs(dimensions.width-requested.size.width)>1 || fabs(dimensions.height-requested.size.height)>1)
        fail(@"Requested CGWindow is not the PID's focused window; no event sent");
    NSUInteger matches = 0;
    for (NSDictionary *other in owned_windows()) if ([other[(id)kCGWindowLayer] intValue]==0 && CGRectEqualToRect(window_bounds(other),requested)) ++matches;
    if (matches != 1) fail(@"Focused-window geometry is ambiguous; no event sent");
}
static void post(CGEventRef event) {
    if (!event) fail(@"Could not create Quartz event");
    verify_process();
    if (first_post_ns == 0) {
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC_RAW, &now) != 0) fail(@"Cannot read event-post clock; no event sent");
        first_post_ns = (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
    }
    CGEventPostToPid(target_pid, event);
    CFRelease(event);
}
static CGEventFlags modifiers(NSString *input) {
    CGEventFlags flags=0;
    if ([input isEqualToString:@"none"] || input.length==0) return flags;
    for (NSString *part in [input componentsSeparatedByString:@","]) {
        if ([part isEqualToString:@"cmd"]) flags|=kCGEventFlagMaskCommand;
        else if ([part isEqualToString:@"shift"]) flags|=kCGEventFlagMaskShift;
        else if ([part isEqualToString:@"alt"]) flags|=kCGEventFlagMaskAlternate;
        else if ([part isEqualToString:@"ctrl"]) flags|=kCGEventFlagMaskControl;
        else fail(@"Unknown modifier; use cmd,shift,alt,ctrl or none");
    }
    return flags;
}
static CGKeyCode keycode(NSString *key) {
    NSDictionary *keys=@{@"a":@(kVK_ANSI_A),@"c":@(kVK_ANSI_C),@"v":@(kVK_ANSI_V),@"w":@(kVK_ANSI_W),@"q":@(kVK_ANSI_Q),@"f":@(kVK_ANSI_F),@"n":@(kVK_ANSI_N),@"t":@(kVK_ANSI_T),@"return":@(kVK_Return),@"escape":@(kVK_Escape),@"tab":@(kVK_Tab),@"space":@(kVK_Space),@"delete":@(kVK_Delete),@"left":@(kVK_LeftArrow),@"right":@(kVK_RightArrow),@"up":@(kVK_UpArrow),@"down":@(kVK_DownArrow)};
    if ([key.lowercaseString isEqualToString:@"h"]) return kVK_ANSI_H;
    if ([key.lowercaseString isEqualToString:@"leftbracket"]) return kVK_ANSI_LeftBracket;
    if ([key.lowercaseString isEqualToString:@"rightbracket"]) return kVK_ANSI_RightBracket;
    NSNumber *number=keys[key.lowercaseString]; if (!number) fail(@"Unsupported key name"); return number.unsignedShortValue;
}
static CGPoint local_point(CGRect bounds, const char *x_text, const char *y_text) {
    char *endx, *endy; double x=strtod(x_text,&endx), y=strtod(y_text,&endy);
    if (*endx || *endy || !isfinite(x) || !isfinite(y) || x<0 || y<0 || x>=bounds.size.width || y>=bounds.size.height) fail(@"Coordinates must be finite offsets within the exact window");
    CGPoint point=CGPointMake(bounds.origin.x+x,bounds.origin.y+y);
    BOOL verified=NO;
    for (NSScreen *screen in NSScreen.screens) if (CGRectContainsPoint(CGDisplayBounds([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]),point)) verified=YES;
    if (!verified) fail(@"Pointer location is outside enumerated displays"); return point;
}
static void mouse(CGEventType type, CGPoint point, CGWindowID window) {
    CGEventRef event=CGEventCreateMouseEvent(NULL,type,point,kCGMouseButtonLeft);
    if (!event) fail(@"Could not create Quartz mouse event");
    CGEventSetFlags(event,0);
    CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer,window);
    CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,window);
    CGEventSetIntegerValueField(event,kCGMouseEventClickState,1);
    post(event);
}
int main(int argc,char **argv) {
    signal(SIGALRM,timeout_exit); alarm(8);
    @autoreleasepool {
        if (argc<4) fail(@"Usage: list PID TAG | check PID TAG WINDOW | activate PID TAG WINDOW | key PID TAG WINDOW KEY [MODIFIERS] | text PID TAG WINDOW TEXT | click PID TAG WINDOW X Y | drag PID TAG WINDOW X1 Y1 X2 Y2 | scroll PID TAG WINDOW X Y PIXELS");
        char *end; long parsed=strtol(argv[2],&end,10); if (*end || parsed<=1 || parsed>INT_MAX) fail(@"Invalid PID");
        target_pid=(pid_t)parsed; target_tag=@(argv[3]);
        NSString *command=@(argv[1]);
        int32_t scrollPixels=0;
        if ([command isEqualToString:@"scroll"]) {
            if (argc!=8) fail(@"Usage: scroll PID TAG WINDOW X Y PIXELS (Quartz: positive up, negative down)");
            const char *digits=argv[7];
            if (*digits=='+' || *digits=='-') ++digits;
            if (!*digits) fail(@"Scroll pixels must be a nonzero signed integer between -10000 and 10000");
            for (const char *p=digits; *p; ++p) if (*p<'0' || *p>'9')
                fail(@"Scroll pixels must be a nonzero signed integer between -10000 and 10000");
            errno=0;
            long pixels=strtol(argv[7],&end,10);
            if (errno==ERANGE || *end || pixels==0 || pixels < -10000 || pixels > 10000)
                fail(@"Scroll pixels must be a nonzero signed integer between -10000 and 10000");
            scrollPixels=(int32_t)pixels;
        }
        verify_process();
        if ([command isEqualToString:@"list"]) {
            NSMutableArray *screens=[NSMutableArray array];
            for (NSScreen *screen in NSScreen.screens) {
                CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
                CGRect rect=CGDisplayBounds(display);
                [screens addObject:@{@"display_id":@(display),@"name":screen.localizedName,@"quartz_bounds":@{@"x":@(rect.origin.x),@"y":@(rect.origin.y),@"width":@(rect.size.width),@"height":@(rect.size.height)}}];
            }
            output(@{@"pid":@(target_pid),@"executable":target_path,@"screens":screens,@"windows":owned_windows(),@"post_event_permission":@(CGPreflightPostEventAccess()),@"accessibility_permission":@(AXIsProcessTrusted()),@"note":@"Read-only enumeration; no activation or input sent"}); return 0;
        }
        if (argc<5) fail(@"Missing exact window");
        unsigned long wid=strtoul(argv[4],&end,10); if (*end || wid==0 || wid>UINT32_MAX) fail(@"Invalid CGWindow ID");
        BOOL activate=[command isEqualToString:@"activate"];
        NSDictionary *window=exact_window((CGWindowID)wid, !activate);
        if (activate) {
            if (argc!=5) fail(@"Usage: activate PID TAG WINDOW");
            verify_process();
            NSRunningApplication *application=[NSRunningApplication runningApplicationWithProcessIdentifier:target_pid];
            if (!application || application.terminated) fail(@"Verified target application is no longer running");
            BOOL accepted=[application activateWithOptions:0];
            output(@{@"status":@"activation_requested",@"accepted":@(accepted),@"pid":@(target_pid),@"window":@(wid),@"executable":target_path,@"note":@"Request is not proof of visible or focused state; inspect exact-window screenshots and oracles"});
            return accepted ? 0 : 1;
        }
        if ([command isEqualToString:@"check"]) {
            require_focused_window(window);
            output(@{@"status":@"verified",@"pid":@(target_pid),@"window":@(wid),@"executable":target_path,@"post_event_permission":@(CGPreflightPostEventAccess()),@"note":@"Read-only preflight; no activation or input sent"}); return 0;
        }
        if (argc<6) fail(@"Missing action arguments");
        if (!CGPreflightPostEventAccess()) fail(@"Quartz event-posting permission denied; no event sent");
        if ([command isEqualToString:@"key"]) {
            if (argc>7) fail(@"Unexpected key arguments"); require_focused_window(window);
            CGKeyCode code=keycode(@(argv[5])); CGEventFlags flags=modifiers(argc==7?@(argv[6]):@"none");
            for (int down=1;down>=0;--down) { CGEventRef event=CGEventCreateKeyboardEvent(NULL,code,down); CGEventSetFlags(event,flags); post(event); if (down) usleep(event_spacing_us); }
        } else if ([command isEqualToString:@"text"]) {
            if (argc!=6) fail(@"Text must be one shell argument"); require_focused_window(window);
            NSString *text=@(argv[5]); if (text.length>1024) fail(@"Text limited to 1024 UTF-16 units per invocation");
            UniChar chars[1024]; [text getCharacters:chars range:NSMakeRange(0,text.length)];
            for (int down=1;down>=0;--down) { CGEventRef event=CGEventCreateKeyboardEvent(NULL,0,down); CGEventSetFlags(event,0); CGEventKeyboardSetUnicodeString(event,text.length,chars); post(event); if (down) usleep(event_spacing_us); }
        } else if ([command isEqualToString:@"scroll"]) {
            // Preserve Quartz wheel-axis sign: positive scrolls up, negative down.
            // This is one vertical pixel-unit event at a validated window point.
            CGPoint point=local_point(window_bounds(window),argv[5],argv[6]);
            CGEventRef event=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,1,scrollPixels);
            if (!event) fail(@"Could not create Quartz scroll event");
            CGEventSetFlags(event,0);
            CGEventSetLocation(event,point);
            CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer,(CGWindowID)wid);
            CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,(CGWindowID)wid);
            post(event);
        } else if ([command isEqualToString:@"click"] || [command isEqualToString:@"drag"]) {
            BOOL drag=[command isEqualToString:@"drag"]; if (argc!=(drag?9:7)) fail(@"Wrong pointer argument count");
            CGRect bounds=window_bounds(window); CGPoint start=local_point(bounds,argv[5],argv[6]); CGPoint finish=drag?local_point(bounds,argv[7],argv[8]):start;
            mouse(kCGEventLeftMouseDown,start,(CGWindowID)wid);
            if (drag) for (int i=1;i<=12;++i) { usleep(event_spacing_us); mouse(kCGEventLeftMouseDragged,CGPointMake(start.x+(finish.x-start.x)*i/12.0,start.y+(finish.y-start.y)*i/12.0),(CGWindowID)wid); }
            usleep(event_spacing_us);
            mouse(kCGEventLeftMouseUp,finish,(CGWindowID)wid);
        } else fail(@"Unknown command");
        output(@{@"status":@"posted",@"pid":@(target_pid),@"window":@(wid),@"executable":target_path,@"command":command,@"first_post_ns":@(first_post_ns),@"clock":@"CLOCK_MONOTONIC_RAW",@"event_spacing_us":@(event_spacing_us),@"note":@"Delivery is not proof of application behavior; inspect exact-window and socket oracles"});
    }
    alarm(0); return 0;
}
