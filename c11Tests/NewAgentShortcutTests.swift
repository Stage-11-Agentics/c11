import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The New Agent shortcut: the A button's plain left-click, as a rebindable
/// keyboard action.
final class NewAgentShortcutTests: XCTestCase {
    private let action = KeyboardShortcutSettings.Action.newAgent
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: action.defaultsKey)
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: action.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        super.tearDown()
    }

    func testDefaultIsOptionCommandA() {
        XCTAssertEqual(action.defaultsKey, "shortcut.newAgent")
        XCTAssertEqual(action.label, "New Agent")
        XCTAssertEqual(
            action.defaultShortcut,
            StoredShortcut(key: "a", command: true, shift: false, option: true, control: false)
        )
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: action), action.defaultShortcut)
        XCTAssertEqual(action.defaultShortcut.displayString, "⌥⌘A")
    }

    func testEveryBoundDefaultChordIsUnique() {
        var ownerByChord: [String: KeyboardShortcutSettings.Action] = [:]
        for candidate in KeyboardShortcutSettings.Action.allCases {
            let shortcut = candidate.defaultShortcut
            guard !shortcut.key.isEmpty else { continue }
            let chord = shortcut.displayString
            if let owner = ownerByChord[chord] {
                XCTFail("\(candidate.rawValue) and \(owner.rawValue) both default to \(chord)")
            }
            ownerByChord[chord] = candidate
        }
        XCTAssertEqual(ownerByChord[action.defaultShortcut.displayString], action)
    }

    func testDefaultLeavesTheAgentPickerChordAlone() {
        // ⌘⇧A is the hardcoded "Launch Agent Picker…" menu item.
        XCTAssertNotEqual(
            action.defaultShortcut,
            StoredShortcut(key: "a", command: true, shift: true, option: false, control: false)
        )
    }

    /// The bytes `defaults write <domain> shortcut.newAgent -data <hex>` stores
    /// for ⌃⌥A decode as the operator's binding, and reset returns the default.
    func testOperatorBindingWrittenAsJSONDataIsHonoured() throws {
        let json = #"{"key":"a","command":false,"control":true,"option":true,"shift":false}"#
        UserDefaults.standard.set(Data(json.utf8), forKey: action.defaultsKey)

        let bound = KeyboardShortcutSettings.shortcut(for: action)
        XCTAssertEqual(
            bound,
            StoredShortcut(key: "a", command: false, shift: false, option: true, control: true)
        )
        XCTAssertEqual(bound.displayString, "⌃⌥A")
        XCTAssertEqual(action.tooltip("Launch Agent"), "Launch Agent (⌃⌥A)")

        KeyboardShortcutSettings.resetShortcut(for: action)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: action), action.defaultShortcut)
    }

    func testRecordedBindingRoundTrips() {
        let custom = StoredShortcut(key: "j", command: true, shift: false, option: true, control: false)
        KeyboardShortcutSettings.setShortcut(custom, for: action)
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: action), custom)
    }
}
