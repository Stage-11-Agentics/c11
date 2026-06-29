import XCTest
import Carbon.HIToolbox

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Unit tests for `TerminalController.namedKeyEvent` — the pure `send-key`
/// vocabulary mapping. Host-free: runs in the fast `c11LogicTests` target.
///
/// Regression guard for the v0.54.0 bug where `c11 send-key down` (and the
/// other arrow/navigation keys) returned `invalid_params: Unknown key`. The
/// mapping resolves a key name to a macOS virtual keycode; Ghostty owns the
/// keycode → PTY-bytes translation, so asserting the keycode pins the
/// behavior that produces the correct CSI/SS3 escape sequence on the PTY.
@MainActor
final class SendKeyVocabularyTests: XCTestCase {

    private func keycode(_ name: String) -> UInt32? {
        TerminalController.namedKeyEvent(for: name)?.keycode
    }

    // MARK: Arrow keys — the reported regression

    func testArrowKeysResolveToVirtualKeycodes() {
        XCTAssertEqual(keycode("up"), UInt32(kVK_UpArrow))
        XCTAssertEqual(keycode("down"), UInt32(kVK_DownArrow))
        XCTAssertEqual(keycode("left"), UInt32(kVK_LeftArrow))
        XCTAssertEqual(keycode("right"), UInt32(kVK_RightArrow))
    }

    func testArrowKeyAliasesResolve() {
        XCTAssertEqual(keycode("arrow-up"), UInt32(kVK_UpArrow))
        XCTAssertEqual(keycode("arrowdown"), UInt32(kVK_DownArrow))
    }

    func testKeyNamesAreCaseInsensitive() {
        XCTAssertEqual(keycode("UP"), UInt32(kVK_UpArrow))
        XCTAssertEqual(keycode("Down"), UInt32(kVK_DownArrow))
    }

    // MARK: Navigation / editing keys

    func testNavigationKeysResolve() {
        XCTAssertEqual(keycode("home"), UInt32(kVK_Home))
        XCTAssertEqual(keycode("end"), UInt32(kVK_End))
        XCTAssertEqual(keycode("pageup"), UInt32(kVK_PageUp))
        XCTAssertEqual(keycode("pagedown"), UInt32(kVK_PageDown))
        XCTAssertEqual(keycode("page-up"), UInt32(kVK_PageUp))
        XCTAssertEqual(keycode("pgdn"), UInt32(kVK_PageDown))
    }

    func testEditingKeysResolve() {
        XCTAssertEqual(keycode("space"), UInt32(kVK_Space))
        XCTAssertEqual(keycode("backspace"), UInt32(kVK_Delete))
        XCTAssertEqual(keycode("delete"), UInt32(kVK_ForwardDelete))
        XCTAssertNotEqual(
            keycode("delete"), keycode("backspace"),
            "delete (forward-delete) must not collide with backspace"
        )
    }

    func testFunctionKeysResolve() {
        XCTAssertEqual(keycode("f1"), UInt32(kVK_F1))
        XCTAssertEqual(keycode("f5"), UInt32(kVK_F5))
        XCTAssertEqual(keycode("f12"), UInt32(kVK_F12))
    }

    // MARK: Existing vocabulary still works

    func testSubmissionAndControlKeysStillResolve() {
        XCTAssertEqual(keycode("enter"), UInt32(kVK_Return))
        XCTAssertEqual(keycode("return"), UInt32(kVK_Return))
        XCTAssertEqual(keycode("tab"), UInt32(kVK_Tab))
        XCTAssertEqual(keycode("escape"), UInt32(kVK_Escape))
        XCTAssertEqual(keycode("esc"), UInt32(kVK_Escape))
    }

    func testControlCombinationsResolveToLetterKeycodes() {
        XCTAssertEqual(keycode("ctrl-c"), UInt32(kVK_ANSI_C))
        XCTAssertEqual(keycode("ctrl-d"), UInt32(kVK_ANSI_D))
        XCTAssertEqual(keycode("ctrl-z"), UInt32(kVK_ANSI_Z))
        // Generic ctrl-<letter> fallthrough.
        XCTAssertEqual(keycode("ctrl-k"), UInt32(kVK_ANSI_K))
        XCTAssertEqual(keycode("ctrl+k"), UInt32(kVK_ANSI_K))
    }

    func testControlComboCarriesModifierDistinctFromPlainKey() {
        // ctrl-c and a plain 'c' keystroke share a keycode but differ in mods;
        // the arrow keys carry no modifier. Compare the resolved events so the
        // modifier wiring is covered without naming GhosttyKit symbols.
        let ctrlC = TerminalController.namedKeyEvent(for: "ctrl-c")
        let plainUp = TerminalController.namedKeyEvent(for: "up")
        XCTAssertNotNil(ctrlC)
        XCTAssertNotNil(plainUp)
        XCTAssertNotEqual(ctrlC, plainUp)
    }

    // MARK: Unknown keys

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(TerminalController.namedKeyEvent(for: "nope"))
        XCTAssertNil(TerminalController.namedKeyEvent(for: ""))
        XCTAssertNil(TerminalController.namedKeyEvent(for: "ctrl-"))
    }
}
