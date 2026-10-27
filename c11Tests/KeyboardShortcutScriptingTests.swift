import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Script names and combo strings behind `c11 shortcuts` and `settings.shortcuts.*`.
final class KeyboardShortcutScriptingTests: XCTestCase {
    typealias Action = KeyboardShortcutSettings.Action

    func testScriptNamesAreKebabCaseNamesFromCaseNotLegacyRawValue() {
        XCTAssertEqual(Action.toggleSidebar.scriptName, "toggle-sidebar")
        XCTAssertEqual(Action.newWorkspace.scriptName, "new-workspace")
        XCTAssertEqual(Action.renamePanel.scriptName, "rename-panel")
    }

    func testEveryScriptNameIsUniqueAndResolvesToItsAction() {
        let names = Action.allCases.map(\.scriptName)
        XCTAssertEqual(Set(names).count, names.count)
        for action in Action.allCases {
            XCTAssertEqual(Action.resolve(scriptName: action.scriptName), action)
        }
    }

    func testResolveAcceptsCaseVariantsAndLegacyAliases() {
        XCTAssertEqual(Action.resolve(scriptName: "toggleSidebar"), .toggleSidebar)
        XCTAssertEqual(Action.resolve(scriptName: "TOGGLE_SIDEBAR"), .toggleSidebar)
        XCTAssertEqual(Action.resolve(scriptName: "new-tab"), .newWorkspace)
        XCTAssertEqual(Action.resolve(scriptName: "renameTab"), .renamePanel)
        XCTAssertNil(Action.resolve(scriptName: ""))
        XCTAssertNil(Action.resolve(scriptName: "toggle-sidebars"))
    }

    func testParsesPlusSeparatedCombos() {
        XCTAssertEqual(
            StoredShortcut(combo: "ctrl+opt+cmd+x"),
            StoredShortcut(key: "x", command: true, shift: false, option: true, control: true)
        )
        XCTAssertEqual(
            StoredShortcut(combo: "Command+Shift+]"),
            StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)
        )
        XCTAssertEqual(StoredShortcut(combo: "cmd+left")?.key, "←")
        XCTAssertEqual(StoredShortcut(combo: "cmd+enter")?.key, "\r")
        XCTAssertEqual(StoredShortcut(combo: "alt+tab")?.key, "\t")
        XCTAssertEqual(StoredShortcut(combo: "ctrl+cmd+=")?.key, "=")
    }

    func testParsesDisplayForm() {
        XCTAssertEqual(StoredShortcut(combo: "⌃⌥⌘X"), StoredShortcut(combo: "ctrl+opt+cmd+x"))
        XCTAssertEqual(StoredShortcut(combo: "⇧⌘↩"), StoredShortcut(combo: "shift+cmd+return"))
    }

    func testRejectsWhatTheRecorderCouldNotStore() {
        XCTAssertNil(StoredShortcut(combo: "x"))            // no modifier
        XCTAssertNil(StoredShortcut(combo: "cmd+"))         // no key
        XCTAssertNil(StoredShortcut(combo: "cmd+xy"))       // two keys
        XCTAssertNil(StoredShortcut(combo: "hyper+x"))      // unknown modifier
        XCTAssertNil(StoredShortcut(combo: "cmd+f5"))       // unsupported key
        XCTAssertNil(StoredShortcut(combo: "cmd+é"))        // non-ASCII letter
        XCTAssertNil(StoredShortcut(combo: ""))
    }

    func testComboStringRoundTripsEveryDefaultShortcut() {
        for action in Action.allCases {
            let shortcut = action.defaultShortcut
            if shortcut == .unbound {
                XCTAssertEqual(shortcut.comboString, "none")
            } else {
                XCTAssertEqual(StoredShortcut(combo: shortcut.comboString), shortcut, action.scriptName)
            }
        }
    }

    func testScriptingRefusesReservedAndTypingCombos() {
        XCTAssertNotNil(StoredShortcut(combo: "cmd+q")?.scriptingRefusal)
        XCTAssertNotNil(StoredShortcut(combo: "cmd+v")?.scriptingRefusal)
        XCTAssertNotNil(StoredShortcut(combo: "shift+cmd+,")?.scriptingRefusal)
        XCTAssertNotNil(StoredShortcut(combo: "shift+a")?.scriptingRefusal)
        XCTAssertNotNil(StoredShortcut(combo: "shift+1")?.scriptingRefusal)
        XCTAssertNil(StoredShortcut(combo: "shift+left")?.scriptingRefusal)
        XCTAssertNil(StoredShortcut(combo: "opt+x")?.scriptingRefusal)
        XCTAssertNil(StoredShortcut(combo: "ctrl+opt+cmd+x")?.scriptingRefusal)
        XCTAssertNil(StoredShortcut.unbound.scriptingRefusal)
    }

    func testNoDefaultShortcutIsRefused() {
        for action in Action.allCases {
            XCTAssertNil(action.defaultShortcut.scriptingRefusal, action.scriptName)
        }
    }

    func testComboStringIsCanonical() {
        let shortcut = StoredShortcut(key: "\r", command: true, shift: true, option: false, control: true)
        XCTAssertEqual(shortcut.comboString, "ctrl+shift+cmd+return")
    }
}
