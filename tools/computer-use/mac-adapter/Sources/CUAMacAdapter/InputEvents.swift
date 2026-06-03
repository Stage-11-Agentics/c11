import CoreGraphics
import Foundation

struct ComputerAction: Codable {
    let type: String
    let x: Double?
    let y: Double?
    let button: String?
    let dx: Double?
    let dy: Double?
    let text: String?
    let keys: [String]?
    let durationMs: Int?
    let path: [ActionPoint]?
}

struct ActionPoint: Codable {
    let x: Double
    let y: Double
}

struct ActionResult: Codable {
    let ok: Bool
    let action: String
    let message: String
}

enum InputEventError: Error, CustomStringConvertible {
    case missingCoordinate(String)
    case missingText
    case unsupportedAction(String)
    case unsupportedKey(String)

    var description: String {
        switch self {
        case .missingCoordinate(let action):
            return "\(action) requires x and y"
        case .missingText:
            return "type requires text"
        case .unsupportedAction(let action):
            return "unsupported action: \(action)"
        case .unsupportedKey(let key):
            return "unsupported key: \(key)"
        }
    }
}

enum InputEvents {
    static func perform(_ action: ComputerAction, observation: Observation) throws -> ActionResult {
        switch action.type {
        case "click":
            try click(action, observation: observation, clickCount: 1)
        case "double_click", "doubleClick":
            try click(action, observation: observation, clickCount: 2)
        case "move":
            try move(action, observation: observation)
        case "drag":
            try drag(action, observation: observation)
        case "scroll":
            try scroll(action)
        case "type":
            try typeText(action.text)
        case "keypress", "key":
            try keypress(action.keys)
        case "wait":
            Thread.sleep(forTimeInterval: Double(action.durationMs ?? 1000) / 1000.0)
        case "screenshot":
            break
        default:
            throw InputEventError.unsupportedAction(action.type)
        }
        return ActionResult(ok: true, action: action.type, message: "executed")
    }

    private static func click(_ action: ComputerAction, observation: Observation, clickCount: Int) throws {
        guard let x = action.x, let y = action.y else {
            throw InputEventError.missingCoordinate(action.type)
        }
        let point = ScreenshotCapture.pointInWindow(x: x, y: y, observation: observation)
        let button = mouseButton(action.button)
        let down = mouseType(button: button, down: true)
        let up = mouseType(button: button, down: false)
        for index in 1...clickCount {
            let clickState = Int64(index)
            postMouse(type: .mouseMoved, point: point, button: button, clickState: clickState)
            postMouse(type: down, point: point, button: button, clickState: clickState)
            usleep(45_000)
            postMouse(type: up, point: point, button: button, clickState: clickState)
            usleep(80_000)
        }
    }

    private static func move(_ action: ComputerAction, observation: Observation) throws {
        guard let x = action.x, let y = action.y else {
            throw InputEventError.missingCoordinate(action.type)
        }
        let point = ScreenshotCapture.pointInWindow(x: x, y: y, observation: observation)
        postMouse(type: .mouseMoved, point: point, button: .left, clickState: 0)
    }

    private static func drag(_ action: ComputerAction, observation: Observation) throws {
        let points: [ActionPoint]
        if let path = action.path, path.count >= 2 {
            points = path
        } else if let x = action.x, let y = action.y, let dx = action.dx, let dy = action.dy {
            points = [ActionPoint(x: x, y: y), ActionPoint(x: x + dx, y: y + dy)]
        } else {
            throw InputEventError.missingCoordinate(action.type)
        }
        let mapped = points.map { ScreenshotCapture.pointInWindow(x: $0.x, y: $0.y, observation: observation) }
        guard let first = mapped.first, let last = mapped.last else { return }
        postMouse(type: .mouseMoved, point: first, button: .left, clickState: 0)
        postMouse(type: .leftMouseDown, point: first, button: .left, clickState: 1)
        usleep(80_000)
        for point in mapped.dropFirst().dropLast() {
            postMouse(type: .leftMouseDragged, point: point, button: .left, clickState: 1)
            usleep(35_000)
        }
        postMouse(type: .leftMouseDragged, point: last, button: .left, clickState: 1)
        usleep(50_000)
        postMouse(type: .leftMouseUp, point: last, button: .left, clickState: 1)
    }

    private static func scroll(_ action: ComputerAction) throws {
        let dx = Int32(action.dx ?? 0)
        let dy = Int32(action.dy ?? 0)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    private static func typeText(_ text: String?) throws {
        guard let text else { throw InputEventError.missingText }
        for scalar in text.unicodeScalars {
            var value = UniChar(scalar.value)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    private static func keypress(_ keys: [String]?) throws {
        let rawKeys = keys ?? []
        let events: [[String]]
        if rawKeys.count > 1 && rawKeys.dropLast().allSatisfy({ isModifier($0) }) {
            events = [rawKeys.map { $0.lowercased() }]
        } else {
            events = rawKeys.map { $0.split(separator: "+").map { String($0).lowercased() } }
        }
        for combo in events {
            let modifiers = modifierFlags(combo)
            guard let keyName = combo.last else { continue }
            guard let keyCode = keyCode(for: keyName) else {
                throw InputEventError.unsupportedKey(combo.joined(separator: "+"))
            }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                continue
            }
            down.flags = modifiers
            up.flags = modifiers
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    private static func isModifier(_ raw: String) -> Bool {
        ["cmd", "command", "meta", "shift", "option", "alt", "ctrl", "control"].contains(raw.lowercased())
    }

    private static func postMouse(type: CGEventType, point: CGPoint, button: CGMouseButton, clickState: Int64) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return
        }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
    }

    private static func mouseButton(_ value: String?) -> CGMouseButton {
        switch value?.lowercased() {
        case "right":
            return .right
        case "middle":
            return .center
        default:
            return .left
        }
    }

    private static func mouseType(button: CGMouseButton, down: Bool) -> CGEventType {
        switch (button, down) {
        case (.right, true): return .rightMouseDown
        case (.right, false): return .rightMouseUp
        case (.center, true): return .otherMouseDown
        case (.center, false): return .otherMouseUp
        case (_, true): return .leftMouseDown
        case (_, false): return .leftMouseUp
        }
    }

    private static func modifierFlags(_ parts: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        if parts.contains("cmd") || parts.contains("command") || parts.contains("meta") { flags.insert(.maskCommand) }
        if parts.contains("shift") { flags.insert(.maskShift) }
        if parts.contains("option") || parts.contains("alt") { flags.insert(.maskAlternate) }
        if parts.contains("ctrl") || parts.contains("control") { flags.insert(.maskControl) }
        return flags
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased()
        if normalized.count == 1, let scalar = normalized.unicodeScalars.first {
            return letterAndDigitKeyCodes[CharacterSet(charactersIn: String(scalar)).description] ?? letterAndDigitKeyCodes[String(scalar)]
        }
        return specialKeyCodes[normalized]
    }

    private static let specialKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53, "esc": 53,
        "delete": 51, "backspace": 51, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121
    ]

    private static let letterAndDigitKeyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50
    ]
}
