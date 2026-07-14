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

    // MARK: C11-173 — printable keys must carry their text

    /// Ghostty's legacy encoder emits printable keys from the event's UTF-8
    /// text, not from the keycode. A keycode-only `space` encoded to zero bytes,
    /// so `c11 send-key space` returned OK and wrote nothing to the PTY.
    func testSpaceCarriesItsText() {
        XCTAssertEqual(TerminalController.namedKeyEvent(for: "space")?.text, " ")
    }

    /// Control keys encode from the keycode alone. Handing them text would make
    /// Ghostty's encoder treat them as committed IME text instead.
    func testControlKeysCarryNoText() {
        for name in ["enter", "return", "tab", "escape", "backspace", "up", "down", "ctrl-c"] {
            XCTAssertNil(
                TerminalController.namedKeyEvent(for: name)?.text,
                "\(name) must not carry text"
            )
        }
    }
}

/// C11-173: how a socket `send` payload is delivered. Prose (including
/// multi-line prose) goes through the paste path so embedded newlines stay
/// literal; keystroke sequences keep the key-event path.
final class SocketSendDeliveryTests: XCTestCase {

    func testPlainAndMultiLineTextIsPasteDeliverable() {
        XCTAssertTrue(TerminalController.socketTextIsPasteDeliverable("echo hi"))
        XCTAssertTrue(TerminalController.socketTextIsPasteDeliverable("line one\nline two\nline three"))
        XCTAssertTrue(TerminalController.socketTextIsPasteDeliverable("trailing\n"))
        XCTAssertTrue(TerminalController.socketTextIsPasteDeliverable(""))
    }

    func testKeystrokeSequencesAreNotPasteDeliverable() {
        XCTAssertFalse(TerminalController.socketTextIsPasteDeliverable("\u{1B}[A"), "ESC sequence")
        XCTAssertFalse(TerminalController.socketTextIsPasteDeliverable("git ch\t"), "tab completion")
        XCTAssertFalse(TerminalController.socketTextIsPasteDeliverable("oops\u{7F}"), "backspace")
    }

    /// Ghostty's paste encoder *replaces* control bytes with spaces (xterm's
    /// strip list: NUL, ESC, DEL, and the tty control chars — 0x03 VINTR,
    /// 0x04 VEOF, 0x1A VSUSP, …). Routing a control byte through the paste path
    /// would silently type a space instead of interrupting the target, so every
    /// C0 byte except the newlines must stay on the key path.
    func testControlBytesNeverGoThroughThePastePath() {
        for value in 0x00...0x1F where value != 0x0A && value != 0x0D {
            let scalar = UnicodeScalar(UInt8(value))
            XCTAssertFalse(
                TerminalController.socketTextIsPasteDeliverable(String(Character(scalar))),
                "C0 byte \(String(format: "0x%02X", value)) must not be pasted (paste strips it to a space)"
            )
        }
        // The two that matter most in a fleet: Ctrl-C and Ctrl-D to a stuck agent.
        XCTAssertFalse(TerminalController.socketTextIsPasteDeliverable("\u{03}"), "Ctrl-C (VINTR)")
        XCTAssertFalse(TerminalController.socketTextIsPasteDeliverable("\u{04}"), "Ctrl-D (VEOF)")
    }

    /// The newline rule: interior newlines are content, a trailing newline means
    /// "and press Enter". `trimmingTrailingNewlines(text) != text` is how both the
    /// live and queued send paths detect that trailing-newline submit intent, so
    /// `send --no-submit 'cmd\n'` still runs the command.
    func testTrailingNewlineIsDistinguishableFromInteriorNewlines() {
        func wantsReturn(_ text: String) -> Bool {
            TerminalController.trimmingTrailingNewlines(text) != text
        }
        XCTAssertTrue(wantsReturn("run me\n"))
        XCTAssertTrue(wantsReturn("\n"))
        XCTAssertFalse(wantsReturn("line one\nline two"))
        XCTAssertFalse(wantsReturn("no newline at all"))
    }

    func testTrailingNewlinesAreTrimmedFromSubmittedPayload() {
        // The submit is a real Return key event, so a trailing newline in the
        // payload would only add a blank line to the target's composer.
        XCTAssertEqual(TerminalController.trimmingTrailingNewlines("run it\n"), "run it")
        XCTAssertEqual(TerminalController.trimmingTrailingNewlines("run it\r\n\n"), "run it")
        XCTAssertEqual(TerminalController.trimmingTrailingNewlines("a\nb\n"), "a\nb")
        XCTAssertEqual(TerminalController.trimmingTrailingNewlines("\n"), "")
        XCTAssertEqual(TerminalController.trimmingTrailingNewlines("no newline"), "no newline")
    }
}
