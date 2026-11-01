// C11-510 guest helper: a compiled accessibility walk of one exact PID, for
// guests where System Events has no Accessibility grant.
// Build: xcrun swiftc -O -target arm64-apple-macos14 tests_v2/ax_walk.swift -o tests_v2/.ax-walk
// Usage: .ax-walk <pid> tree|activate|foreground|menus|fields|ids, or <pid> scroll <AXIdentifier>
//   menus: every open AXMenu's items in order (title "" is a separator)
//   fields: text fields (value, placeholder) and buttons, plus elements
//           whose AX identifier starts with "sidebar.workspace."
//   ids: every element with an AX identifier, and every button, in all
//        windows, with enabled state and the owning window's id and title
//   scroll <id>: AXScrollToVisible on the element with that identifier
import AppKit
import ApplicationServices

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let args = CommandLine.arguments
guard args.count == 3 || (args.count == 4 && args[2] == "scroll"), let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: ax-walk <pid> tree|activate|foreground|menus|fields|ids, or <pid> scroll <id>\n".data(using: .utf8)!)
    exit(2)
}

switch args[2] {
case "foreground":
    emit(Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1))
    exit(0)
case "activate":
    guard let app = NSRunningApplication(processIdentifier: pid) else { emit(false); exit(1) }
    emit(app.activate(options: [.activateAllWindows]))
    exit(0)
case "tree", "menus", "fields", "ids", "scroll":
    break
default:
    exit(2)
}

guard AXIsProcessTrusted() else {
    emit(["error": "not_trusted"])
    exit(3)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func point(_ element: AXUIElement, _ name: String) -> [Double]? {
    guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    var p = CGPoint.zero
    var s = CGSize.zero
    if AXValueGetValue(value, .cgPoint, &p) { return [Double(p.x), Double(p.y)] }
    if AXValueGetValue(value, .cgSize, &s) { return [Double(s.width), Double(s.height)] }
    return nil
}

var sheets: [[String: Any]] = []
var webAreas: [[String: Any]] = []
var notices: [[String: Any]] = []

func info(_ element: AXUIElement) -> [String: Any] {
    var result: [String: Any] = [:]
    result["role"] = string(element, kAXRoleAttribute) ?? NSNull()
    result["title"] = string(element, kAXTitleAttribute) ?? NSNull()
    result["value"] = string(element, kAXValueAttribute) ?? NSNull()
    result["id"] = string(element, kAXIdentifierAttribute) ?? NSNull()
    result["position"] = point(element, kAXPositionAttribute) ?? NSNull()
    result["size"] = point(element, kAXSizeAttribute) ?? NSNull()
    return result
}

func walk(_ element: AXUIElement, depth: Int, sheetIndex: Int?) {
    guard depth <= 18 else { return }
    let item = info(element)
    let role = item["role"] as? String
    var currentSheet = sheetIndex
    if role == "AXSheet" {
        var sheet = item
        sheet["children"] = [[String: Any]]()
        sheets.append(sheet)
        currentSheet = sheets.count - 1
    } else if let index = sheetIndex, ["AXButton", "AXCheckBox", "AXStaticText"].contains(role ?? "") {
        var children = sheets[index]["children"] as! [[String: Any]]
        children.append(item)
        sheets[index]["children"] = children
    }
    if (item["id"] as? String) == "c11.panel-link.notice" { notices.append(item) }
    if role == "AXWebArea" { webAreas.append(item); return }
    if role == "AXTextArea" { return }
    guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for child in children { walk(child, depth: depth + 1, sheetIndex: currentSheet) }
}

let application = AXUIElementCreateApplication(pid)

// C11-563: menus and fields, read-only, for menu-layout and rename proofs.
var menus: [[[String: Any]]] = []
var fields: [[String: Any]] = []
var buttons: [[String: Any]] = []
var rows: [[String: Any]] = []

func collect(_ element: AXUIElement, depth: Int) {
    guard depth <= 24 else { return }
    let item = info(element)
    let role = item["role"] as? String ?? ""
    if role == "AXMenuBar" { return }  // its menus exist while closed
    if role == "AXMenu" {
        var entries: [[String: Any]] = []
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            var entry = info(child)
            entry["enabled"] = (attribute(child, kAXEnabledAttribute) as? Bool) ?? NSNull()
            entry["has_submenu"] = ((attribute(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []).isEmpty == false
            entries.append(entry)
        }
        menus.append(entries)
        return
    }
    if role == "AXTextField" {
        var entry = item
        entry["placeholder"] = string(element, kAXPlaceholderValueAttribute) ?? NSNull()
        fields.append(entry)
    } else if role == "AXButton" {
        buttons.append(item)
    }
    if let id = item["id"] as? String, id.hasPrefix("sidebar.workspace.") {
        var entry = item
        entry["label"] = string(element, kAXDescriptionAttribute) ?? NSNull()
        rows.append(entry)
    }
    if role == "AXWebArea" || role == "AXTextArea" { return }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        collect(child, depth: depth + 1)
    }
}

// C11-562: identified elements, for proofs that locate controls by AX id.
if args[2] == "ids" || args[2] == "scroll" {
    var found: [[String: Any]] = []
    var target: AXUIElement?
    var visited = 0
    func collectIdentified(_ element: AXUIElement, depth: Int, window: [String: Any]) {
        visited += 1
        guard depth <= 40, visited <= 20000 else { return }
        var item = info(element)
        let role = item["role"] as? String
        let id = item["id"] as? String
        if args[2] == "scroll", id == args[3] { target = element }
        if (id?.isEmpty == false) || role == "AXButton" {
            item["enabled"] = (attribute(element, kAXEnabledAttribute) as? Bool) ?? NSNull()
            item["window_id"] = window["id"] ?? NSNull()
            item["window_title"] = window["title"] ?? NSNull()
            found.append(item)
        }
        if role == "AXWebArea" || role == "AXTextArea" { return }
        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children { collectIdentified(child, depth: depth + 1, window: window) }
    }
    for window in (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        collectIdentified(window, depth: 0, window: info(window))
    }
    if args[2] == "scroll" {
        guard let target else { emit(["error": "not_found"]); exit(4) }
        emit(AXUIElementPerformAction(target, "AXScrollToVisible" as CFString) == .success)
        exit(0)
    }
    emit(found)
    exit(0)
}

switch args[2] {
case "menus", "fields":
    collect(application, depth: 0)
    if args[2] == "menus" {
        emit(["menus": menus])
    } else {
        emit(["fields": fields, "buttons": buttons, "rows": rows])
    }
    exit(0)
default:
    break
}

for window in (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
    walk(window, depth: 0, sheetIndex: nil)
}
emit(["sheets": sheets, "webAreas": webAreas, "notices": notices])
