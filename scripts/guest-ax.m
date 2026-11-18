// Guest-only accessibility driver: press, open context menus and read frames of one
// process's elements by AXIdentifier, AXDescription or menu-item title. It drives the
// real AppKit action path (AXPress, AXShowMenu) without coordinates. Sandbox guests only.
// Build in the guest: clang -fobjc-arc -framework Foundation -framework ApplicationServices guest-ax.m -o ax
// Usage: ax <pid> press <identifier>            AXPress the element with that identifier
//        ax <pid> showmenu <identifier>         AXShowMenu (a SwiftUI .contextMenu)
//        ax <pid> pressin <identifier> <desc>   AXPress the first element under <identifier>
//                                               whose AXDescription or AXTitle is <desc>
//        ax <pid> menuitem <title>              AXPress the visible menu item with that title
//        ax <pid> focus <identifier>            set AXFocused on it
//        ax <pid> frame <identifier>            print "x y w h" in global points
//        ax <pid> click <identifier>            a real, timestamped HID click at its centre
//                                               (activates the app and focuses a field)
//        ax <pid> value <identifier>            print AXValue
//        ax <pid> dump <identifier> [depth]     print the subtree's role, id, title, description
//        ax <pid> windowid -                    print the CGWindowID of its largest on-screen window
// Exit 0 on success, 2 when the element is not found, 3 when the action fails.
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#include <time.h>
#include <unistd.h>

static void click(CGPoint p) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventType types[] = {kCGEventMouseMoved, kCGEventLeftMouseDown, kCGEventLeftMouseUp};
    for (int i = 0; i < 3; i++) {
        CGEventRef e = CGEventCreateMouseEvent(source, types[i], p, kCGMouseButtonLeft);
        CGEventSetFlags(e, 0);
        CGEventSetIntegerValueField(e, kCGMouseEventClickState, i == 0 ? 0 : 1);
        CGEventSetTimestamp(e, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
        usleep(i == 0 ? 120000 : 60000);
    }
    CFRelease(source);
}

static NSString *attr(AXUIElementRef e, CFStringRef name) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(e, name, &v) != kAXErrorSuccess || !v) return nil;
    id obj = CFBridgingRelease(v);
    return [obj isKindOfClass:[NSString class]] ? obj : nil;
}

static NSArray *children(AXUIElementRef e) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXChildrenAttribute, &v) != kAXErrorSuccess || !v) return @[];
    return CFBridgingRelease(v);
}

typedef BOOL (^Match)(AXUIElementRef);

/// Breadth-first, so the shallowest match wins; bounded so a deep terminal tree cannot stall.
static AXUIElementRef find(AXUIElementRef root, Match match) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(__bridge id)root];
    NSUInteger visited = 0;
    while (queue.count && visited < 20000) {
        AXUIElementRef e = (__bridge AXUIElementRef)queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (match(e)) return (AXUIElementRef)CFRetain(e);
        [queue addObjectsFromArray:children(e)];
    }
    return NULL;
}

static Match byIdentifier(NSString *identifier) {
    return ^BOOL(AXUIElementRef e) { return [attr(e, kAXIdentifierAttribute) isEqualToString:identifier]; };
}

static void dump(AXUIElementRef e, int depth, int limit) {
    printf("%*s%s id=%s title=%s desc=%s\n", depth * 2, "",
           attr(e, kAXRoleAttribute).UTF8String ?: "?", attr(e, kAXIdentifierAttribute).UTF8String ?: "",
           attr(e, kAXTitleAttribute).UTF8String ?: "", attr(e, kAXDescriptionAttribute).UTF8String ?: "");
    if (depth >= limit) return;
    for (id child in children(e)) dump((__bridge AXUIElementRef)child, depth + 1, limit);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: ax <pid> <verb> <arg> [arg]\n"); return 64; }
        pid_t pid = atoi(argv[1]);
        NSString *verb = @(argv[2]), *arg = @(argv[3]);
        if ([verb isEqualToString:@"windowid"]) {
            NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
            long best = 0; double area = 0;
            for (NSDictionary *w in windows) {
                if ([w[(id)kCGWindowOwnerPID] intValue] != pid || [w[(id)kCGWindowLayer] intValue] != 0) continue;
                NSDictionary *b = w[(id)kCGWindowBounds];
                double a = [b[@"Width"] doubleValue] * [b[@"Height"] doubleValue];
                if (a > area) { area = a; best = [w[(id)kCGWindowNumber] longValue]; }
            }
            if (!best) return 2;
            printf("%ld\n", best);
            return 0;
        }
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(app, 5);
        AXUIElementRef target = NULL;
        if ([verb isEqualToString:@"menuitem"]) {
            target = find(app, ^BOOL(AXUIElementRef e) {
                return [attr(e, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXMenuItemRole]
                    && [attr(e, kAXTitleAttribute) isEqualToString:arg];
            });
        } else if ([verb isEqualToString:@"pressin"] && argc >= 5) {
            AXUIElementRef container = find(app, byIdentifier(arg));
            if (container) {
                NSString *desc = @(argv[4]);
                target = find(container, ^BOOL(AXUIElementRef e) {
                    return [attr(e, kAXDescriptionAttribute) isEqualToString:desc]
                        || [attr(e, kAXTitleAttribute) isEqualToString:desc];
                });
                CFRelease(container);
            }
        } else {
            target = find(app, byIdentifier(arg));
        }
        if (!target) { fprintf(stderr, "not found: %s %s\n", argv[2], argv[3]); return 2; }
        AXError err = kAXErrorSuccess;
        if ([verb isEqualToString:@"press"] || [verb isEqualToString:@"pressin"] || [verb isEqualToString:@"menuitem"]) {
            err = AXUIElementPerformAction(target, kAXPressAction);
        } else if ([verb isEqualToString:@"showmenu"]) {
            err = AXUIElementPerformAction(target, kAXShowMenuAction);
        } else if ([verb isEqualToString:@"focus"]) {
            err = AXUIElementSetAttributeValue(target, kAXFocusedAttribute, kCFBooleanTrue);
        } else if ([verb isEqualToString:@"click"]) {
            CFTypeRef pos = NULL, size = NULL; CGPoint p; CGSize s;
            AXUIElementCopyAttributeValue(target, kAXPositionAttribute, &pos);
            AXUIElementCopyAttributeValue(target, kAXSizeAttribute, &size);
            if (!pos || !size) return 3;
            AXValueGetValue(pos, kAXValueCGPointType, &p); AXValueGetValue(size, kAXValueCGSizeType, &s);
            CFRelease(pos); CFRelease(size);
            click(CGPointMake(p.x + s.width / 2, p.y + s.height / 2));
        } else if ([verb isEqualToString:@"frame"]) {
            CFTypeRef pos = NULL, size = NULL; CGPoint p; CGSize s;
            AXUIElementCopyAttributeValue(target, kAXPositionAttribute, &pos);
            AXUIElementCopyAttributeValue(target, kAXSizeAttribute, &size);
            if (!pos || !size) return 3;
            AXValueGetValue(pos, kAXValueCGPointType, &p); AXValueGetValue(size, kAXValueCGSizeType, &s);
            printf("%.0f %.0f %.0f %.0f\n", p.x, p.y, s.width, s.height);
            CFRelease(pos); CFRelease(size);
        } else if ([verb isEqualToString:@"value"]) {
            printf("%s\n", attr(target, kAXValueAttribute).UTF8String ?: "");
        } else if ([verb isEqualToString:@"dump"]) {
            dump(target, 0, argc >= 5 ? atoi(argv[4]) : 6);
        } else {
            fprintf(stderr, "unknown verb %s\n", argv[2]); return 64;
        }
        CFRelease(target);
        if (err != kAXErrorSuccess) { fprintf(stderr, "AX error %d\n", err); return 3; }
        return 0;
    }
}
