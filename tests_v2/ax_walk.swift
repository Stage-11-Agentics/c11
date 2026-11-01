// C11-510 guest helper: a compiled accessibility walk of one exact PID, for
// guests where System Events has no Accessibility grant.
// Build: xcrun swiftc -O -target arm64-apple-macos14 tests_v2/ax_walk.swift -o tests_v2/.ax-walk
// Usage: .ax-walk <pid> tree|activate|foreground
import AppKit
import ApplicationServices

func emit(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let args = CommandLine.arguments
guard args.count == 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: ax-walk <pid> tree|activate|foreground\n".data(using: .utf8)!)
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
case "tree":
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
for window in (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
    walk(window, depth: 0, sheetIndex: nil)
}
emit(["sheets": sheets, "webAreas": webAreas, "notices": notices])
