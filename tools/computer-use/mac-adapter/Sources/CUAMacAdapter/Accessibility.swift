import AppKit
import ApplicationServices
import Foundation

enum AccessibilitySupport {
    static func raise(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        return AXUIElementPerformAction(app, kAXRaiseAction as CFString) == .success
    }

    static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused else {
            return nil
        }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
}
