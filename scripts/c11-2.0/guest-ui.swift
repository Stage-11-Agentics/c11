// Guest UI helper for the c11 2.0 guest proofs (C11H-270): reads an app's windows, menus and accessibility
// text, and posts a click or a key. Run it only inside a sandbox guest, never on a host.
// Build: xcrun swiftc -O -target arm64-apple-macos14 scripts/c11-2.0/guest-ui.swift -o guest-ui
//   dump <pid>                 every element of the app (windows and the whole menu bar): role, title, value,
//                              description, help, identifier, frame, and the path of titled ancestors
//   find <pid> <id-prefix>     elements whose AXIdentifier starts with the prefix
//   press <pid> <identifier>   AXPress on the first element with exactly that identifier
//   menu <pid> <top> <prefix>  AXPress the first item under menu-bar item <top> whose title starts with <prefix>
//   openmenu <pid> <index>     AXPress menu-bar item <index> (1 = the app menu), so the menu is on screen
//   windows <pid>              on-screen layer-0 windows of the pid: id, title, bounds
//   activate <pid> | foreground
//   click <x> <y>              one timestamped HID click at a global point
//   key <keycode> [cmd|cmd-shift]  one HID key press (53 = Escape, 13 = w, 35 = p, 36 = Return)
//   type <text>                the text as HID key presses, one per character
//   focus <pid>                the app's key (AXFocusedWindow) and main window titles, and its windows' frames
//   keywin <pid> <title>       raise the window with this exact title and make it key (AXFocused), not main
import AppKit
import ApplicationServices

func emit(_ o: Any) {
    let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .fragmentsAllowed])
    FileHandle.standardOutput.write(d); FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ n: String) -> String? {
    guard let v = attr(e, n) else { return nil }
    if let s = v as? String { return s }
    if let a = v as? NSAttributedString { return a.string }
    return nil
}
func frame(_ e: AXUIElement) -> [Double]? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return [Double(pt.x), Double(pt.y), Double(sz.width), Double(sz.height)]
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

var visited = 0
func walk(_ e: AXUIElement, _ path: [String], _ depth: Int, _ visit: (AXUIElement, [String]) -> Void) {
    if depth > 80 || visited > 60000 { return }
    visited += 1
    visit(e, path)
    var next = path
    if let t = str(e, kAXTitleAttribute), !t.isEmpty, next.count < 6 { next.append(t) }
    for k in kids(e) { walk(k, next, depth + 1, visit) }
}
func roots(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var out: [AXUIElement] = []
    if let w = attr(app, kAXWindowsAttribute) as? [AXUIElement] { out += w }
    if let m = attr(app, kAXMenuBarAttribute) { out.append(m as! AXUIElement) }
    return out
}
func post(key: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)!
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}
func post(text: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in text {
        let units = Array(String(ch).utf16)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            ev.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }
}

let a = CommandLine.arguments
guard a.count >= 2 else { exit(2) }
switch a[1] {
case "foreground":
    emit(Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1))
case "activate":
    guard a.count == 3, let pid = pid_t(a[2]), let app = NSRunningApplication(processIdentifier: pid) else { emit(false); exit(1) }
    emit(app.activate(options: [.activateAllWindows]))
case "click":
    guard a.count == 4, let x = Double(a[2]), let y = Double(a[3]) else { exit(2) }
    let src = CGEventSource(stateID: .hidSystemState)
    let pt = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)!.post(tap: .cghidEventTap)
    usleep(120_000)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)!
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        ev.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        ev.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    emit(["clicked": [x, y]])
case "key":
    guard a.count >= 3, let code = UInt16(a[2]) else { exit(2) }
    let mods = a.count > 3 ? a[3] : ""
    let flags: CGEventFlags = mods == "cmd-shift" ? [.maskCommand, .maskShift] : mods == "cmd" ? .maskCommand : []
    post(key: code, flags: flags)
    emit(["key": Int(code), "mods": mods])
case "type":
    guard a.count == 3 else { exit(2) }
    post(text: a[2])
    emit(["typed": a[2]])
case "windows":
    guard a.count == 3, let pid = Int(a[2]) else { exit(2) }
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    emit(list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        .map { ["id": $0[kCGWindowNumber as String] ?? 0, "title": $0[kCGWindowName as String] ?? "",
                "bounds": $0[kCGWindowBounds as String] ?? [:]] })
case "dump", "find", "press", "menu", "openmenu", "raise", "focus", "keywin":
    guard a.count >= 3, let pid = pid_t(a[2]) else { exit(2) }
    guard AXIsProcessTrusted() else { emit(["error": "not trusted for accessibility"]); exit(3) }
    switch a[1] {
    case "dump":
        var out: [[String: Any]] = []
        for r in roots(pid) {
            walk(r, [], 0) { e, path in
                var row: [String: Any] = ["role": str(e, kAXRoleAttribute) ?? "", "path": path.joined(separator: " > ")]
                for (k, n) in [("title", kAXTitleAttribute), ("value", kAXValueAttribute), ("description", kAXDescriptionAttribute),
                               ("help", kAXHelpAttribute), ("identifier", "AXIdentifier"), ("placeholder", kAXPlaceholderValueAttribute)] {
                    if let s = str(e, n), !s.isEmpty { row[k] = s }
                }
                if row.count > 2 { out.append(row) }
            }
        }
        emit(out)
    case "find":
        guard a.count == 4 else { exit(2) }
        var out: [[String: Any]] = []
        for r in roots(pid) {
            walk(r, [], 0) { e, _ in
                if let id = str(e, "AXIdentifier"), id.hasPrefix(a[3]) {
                    out.append(["identifier": id, "frame": frame(e) ?? NSNull(), "title": str(e, kAXTitleAttribute) ?? "",
                                "role": str(e, kAXRoleAttribute) ?? ""])
                }
            }
        }
        emit(out)
    case "press":
        guard a.count == 4 else { exit(2) }
        var hit: AXUIElement?
        for r in roots(pid) where hit == nil {
            walk(r, [], 0) { e, _ in if hit == nil, str(e, "AXIdentifier") == a[3] { hit = e } }
        }
        guard let e = hit else { emit(["error": "no element \(a[3])"]); exit(4) }
        emit(["pressed": a[3], "result": Int(AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue)])
    case "raise":
        // Raise the app's window with this exact title and make it main, as a click on it would.
        guard a.count == 4 else { exit(2) }
        let app = AXUIElementCreateApplication(pid)
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let w = windows.first(where: { str($0, kAXTitleAttribute) == a[3] }) else { emit(["error": "no window \(a[3])"]); exit(4) }
        let raised = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        let main = AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        emit(["raised": a[3], "result": Int(raised.rawValue), "main": Int(main.rawValue)])
    case "focus":
        let app = AXUIElementCreateApplication(pid)
        func title(_ ref: CFTypeRef?) -> String {
            guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return "" }
            return str(ref as! AXUIElement, kAXTitleAttribute) ?? ""
        }
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        emit(["key": title(attr(app, kAXFocusedWindowAttribute)), "main": title(attr(app, kAXMainWindowAttribute)),
              "windows": windows.map { ["title": str($0, kAXTitleAttribute) ?? "", "frame": (frame($0) as Any?) ?? NSNull()] as [String: Any] }])
    case "keywin":
        // Raise the window with this exact title and make it key without asking for main, as a click on a
        // panel does.
        guard a.count == 4 else { exit(2) }
        let app = AXUIElementCreateApplication(pid)
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let w = windows.first(where: { str($0, kAXTitleAttribute) == a[3] }) else { emit(["error": "no window \(a[3])"]); exit(4) }
        let raised = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        let focused = AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        emit(["keywin": a[3], "result": Int(raised.rawValue), "focused": Int(focused.rawValue)])
    case "menu", "openmenu":
        let app = AXUIElementCreateApplication(pid)
        guard let barRef = attr(app, kAXMenuBarAttribute) else { emit(["error": "no menu bar"]); exit(4) }
        let tops = kids(barRef as! AXUIElement)
        if a[1] == "openmenu" {
            guard a.count == 4, let i = Int(a[3]), i >= 0, i < tops.count else { emit(["error": "no menu-bar item", "count": tops.count]); exit(4) }
            emit(["opened": str(tops[i], kAXTitleAttribute) ?? "", "count": tops.count,
                  "result": Int(AXUIElementPerformAction(tops[i], kAXPressAction as CFString).rawValue)])
        } else {
            guard a.count == 5 else { exit(2) }
            guard let top = tops.first(where: { str($0, kAXTitleAttribute) == a[3] }) else { emit(["error": "no menu \(a[3])"]); exit(4) }
            var hit: AXUIElement?
            walk(top, [], 0) { e, _ in
                if hit == nil, str(e, kAXRoleAttribute) == "AXMenuItem", let t = str(e, kAXTitleAttribute), t.hasPrefix(a[4]) { hit = e }
            }
            guard let e = hit else { emit(["error": "no item starting \(a[4]) under \(a[3])"]); exit(4) }
            emit(["pressed": str(e, kAXTitleAttribute) ?? "", "result": Int(AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue)])
        }
    default: exit(2)
    }
default:
    exit(2)
}
