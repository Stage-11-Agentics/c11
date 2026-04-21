import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - TextBoxInputSettings Tests

final class TextBoxInputSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TextBoxInputSettings.resetAll()
    }

    override func tearDown() {
        TextBoxInputSettings.resetAll()
        super.tearDown()
    }

    func testDefaultEnterToSendIsTrue() {
        XCTAssertTrue(TextBoxInputSettings.isEnterToSend())
    }

    func testSetEnterToSendFalse() {
        UserDefaults.standard.set(false, forKey: TextBoxInputSettings.enterToSendKey)
        XCTAssertFalse(TextBoxInputSettings.isEnterToSend())
    }
}

// MARK: - KeyboardShortcutSettings Integration Tests

final class TextBoxShortcutTests: XCTestCase {

    override func tearDown() {
        KeyboardShortcutSettings.resetShortcut(for: .toggleTextBoxInput)
        super.tearDown()
    }

    func testToggleTextBoxInputDefaultShortcut() {
        let shortcut = KeyboardShortcutSettings.Action.toggleTextBoxInput.defaultShortcut
        XCTAssertEqual(shortcut.key, "b")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testToggleTextBoxInputDefaultsKey() {
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.toggleTextBoxInput.defaultsKey,
            "shortcut.toggleTextBoxInput"
        )
    }

    func testToggleTextBoxInputLabel() {
        let label = KeyboardShortcutSettings.Action.toggleTextBoxInput.label
        XCTAssertEqual(label, "Toggle TextBox Input")
    }

    func testCustomShortcutPersistence() {
        let custom = StoredShortcut(key: "j", command: true, shift: false, option: false, control: false)
        KeyboardShortcutSettings.setShortcut(custom, for: .toggleTextBoxInput)

        let loaded = KeyboardShortcutSettings.shortcut(for: .toggleTextBoxInput)
        XCTAssertEqual(loaded, custom)
    }

    func testResetShortcutRestoresDefault() {
        let custom = StoredShortcut(key: "j", command: true, shift: false, option: false, control: false)
        KeyboardShortcutSettings.setShortcut(custom, for: .toggleTextBoxInput)
        KeyboardShortcutSettings.resetShortcut(for: .toggleTextBoxInput)

        let loaded = KeyboardShortcutSettings.shortcut(for: .toggleTextBoxInput)
        XCTAssertEqual(loaded, KeyboardShortcutSettings.Action.toggleTextBoxInput.defaultShortcut)
    }
}

// MARK: - TextBoxKeyRouting Tests

final class TextBoxKeyRoutingTests: XCTestCase {

    // Helper to call route() with common defaults.
    private func route(
        _ input: TextBoxKeyInput,
        isEmpty: Bool = false,
        terminalTitle: String = "",
        enterToSend: Bool = true
    ) -> TextBoxKeyAction {
        TextBoxKeyRouting.route(input, isEmpty: isEmpty, terminalTitle: terminalTitle, enterToSend: enterToSend)
    }

    // MARK: Rule 1 — Emacs editing (Ctrl + A/E/F/B/N/P/K/H)

    func testCtrlEmacsKeysReturnEmacsEdit() {
        for key in ["a", "e", "f", "b", "n", "p", "k", "h"] {
            let action = route(.ctrl(key))
            guard case .emacsEdit = action else {
                XCTFail("Ctrl+\(key) should be .emacsEdit, got \(action)")
                return
            }
        }
    }

    // MARK: Rule 2 — Ctrl+other → forward to terminal

    func testCtrlNonEmacsKeysReturnForwardControl() {
        for key in ["c", "z", "d", "l", "r"] {
            let action = route(.ctrl(key))
            guard case .forwardControl = action else {
                XCTFail("Ctrl+\(key) should be .forwardControl, got \(action)")
                return
            }
        }
    }

    // MARK: Rule 3 — "/" prefix forwarding (empty + app detected)

    func testSlashForwardWhenEmptyAndClaudeCodeRunning() {
        let action = route(.text("/"), isEmpty: true, terminalTitle: "Claude Code")
        guard case .forwardPrefix("/") = action else {
            XCTFail("Expected .forwardPrefix(\"/\"), got \(action)")
            return
        }
    }

    func testSlashForwardWhenEmptyAndCodexRunning() {
        let action = route(.text("/"), isEmpty: true, terminalTitle: "Codex")
        guard case .forwardPrefix("/") = action else {
            XCTFail("Expected .forwardPrefix(\"/\"), got \(action)")
            return
        }
    }

    func testSlashNotForwardedWhenNotEmpty() {
        let action = route(.text("/"), isEmpty: false, terminalTitle: "Claude Code")
        guard case .textInput = action else {
            XCTFail("Expected .textInput, got \(action)")
            return
        }
    }

    func testSlashNotForwardedWhenNoAppDetected() {
        let action = route(.text("/"), isEmpty: true, terminalTitle: "zsh")
        guard case .textInput = action else {
            XCTFail("Expected .textInput, got \(action)")
            return
        }
    }

    // MARK: Rule 4 — "@" prefix forwarding (empty + app detected)

    func testAtForwardWhenEmptyAndClaudeCodeRunning() {
        let action = route(.text("@"), isEmpty: true, terminalTitle: "Claude Code")
        guard case .forwardPrefix("@") = action else {
            XCTFail("Expected .forwardPrefix(\"@\"), got \(action)")
            return
        }
    }

    func testAtForwardWhenEmptyAndCodexRunning() {
        let action = route(.text("@"), isEmpty: true, terminalTitle: "Codex")
        guard case .forwardPrefix("@") = action else {
            XCTFail("Expected .forwardPrefix(\"@\") for Codex, got \(action)")
            return
        }
    }

    func testAtNotForwardedWhenNotEmpty() {
        let action = route(.text("@"), isEmpty: false, terminalTitle: "Claude Code")
        guard case .textInput = action else {
            XCTFail("Expected .textInput, got \(action)")
            return
        }
    }

    // MARK: Rule 5 — "?" key event forwarding (empty + app detected, keep focus)

    func testQuestionMarkForwardWhenEmptyAndClaudeCodeRunning() {
        let action = route(.key("?"), isEmpty: true, terminalTitle: "Claude Code")
        guard case .forwardKeyEvent = action else {
            XCTFail("Expected .forwardKeyEvent, got \(action)")
            return
        }
    }

    func testQuestionMarkForwardWhenEmptyAndCodexRunning() {
        let action = route(.key("?"), isEmpty: true, terminalTitle: "Codex")
        guard case .forwardKeyEvent = action else {
            XCTFail("Expected .forwardKeyEvent, got \(action)")
            return
        }
    }

    func testQuestionMarkNotForwardedWhenNotEmpty() {
        let action = route(.key("?"), isEmpty: false, terminalTitle: "Claude Code")
        guard case .textInput = action else {
            XCTFail("Expected .textInput, got \(action)")
            return
        }
    }

    func testQuestionMarkNotForwardedWhenNoAppDetected() {
        let action = route(.key("?"), isEmpty: true, terminalTitle: "zsh")
        guard case .textInput = action else {
            XCTFail("Expected .textInput, got \(action)")
            return
        }
    }

    // MARK: Rule 6/7 — Return (setting-dependent)

    func testReturnSubmitsWhenEnterToSendAndNotShifted() {
        let action = route(.command(#selector(NSResponder.insertNewline(_:)), shifted: false), enterToSend: true)
        guard case .submit = action else {
            XCTFail("Expected .submit, got \(action)")
            return
        }
    }

    func testShiftReturnInsertsNewlineWhenEnterToSend() {
        let action = route(.command(#selector(NSResponder.insertNewline(_:)), shifted: true), enterToSend: true)
        guard case .insertNewline = action else {
            XCTFail("Expected .insertNewline, got \(action)")
            return
        }
    }

    func testReturnInsertsNewlineWhenNotEnterToSend() {
        let action = route(.command(#selector(NSResponder.insertNewline(_:)), shifted: false), enterToSend: false)
        guard case .insertNewline = action else {
            XCTFail("Expected .insertNewline, got \(action)")
            return
        }
    }

    func testShiftReturnSubmitsWhenNotEnterToSend() {
        let action = route(.command(#selector(NSResponder.insertNewline(_:)), shifted: true), enterToSend: false)
        guard case .submit = action else {
            XCTFail("Expected .submit, got \(action)")
            return
        }
    }

    // MARK: Rule 8 — Escape

    func testEscapeReturnsEscape() {
        let action = route(.command(#selector(NSResponder.cancelOperation(_:)), shifted: false))
        guard case .escape = action else {
            XCTFail("Expected .escape, got \(action)")
            return
        }
    }

    // MARK: Rule 9 — Empty-state navigation forwarding
    //
    // Option B: arrow keys are never forwarded to the terminal. They always
    // drive NSTextView cursor movement (.textInput), whether the TextBox is
    // empty or not. Only Tab and Backspace still forward in the empty state.

    func testTabForwardedWhenEmpty() {
        let action = route(.command(#selector(NSResponder.insertTab(_:)), shifted: false), isEmpty: true)
        guard case .forwardKey(.tab) = action else {
            XCTFail("Expected .forwardKey(.tab), got \(action)")
            return
        }
    }

    func testBackspaceForwardedWhenEmpty() {
        let action = route(.command(#selector(NSResponder.deleteBackward(_:)), shifted: false), isEmpty: true)
        guard case .forwardKey(.backspace) = action else {
            XCTFail("Expected .forwardKey(.backspace), got \(action)")
            return
        }
    }

    func testTabNotForwardedWhenNotEmpty() {
        let action = route(.command(#selector(NSResponder.insertTab(_:)), shifted: false), isEmpty: false)
        guard case .textInput = action else {
            XCTFail("Expected .textInput when not empty, got \(action)")
            return
        }
    }

    func testArrowUpStaysInTextBoxWhenEmpty() {
        let action = route(.command(#selector(NSResponder.moveUp(_:)), shifted: false), isEmpty: true)
        guard case .textInput = action else {
            XCTFail("Expected .textInput (arrows never forward — Option B), got \(action)")
            return
        }
    }

    func testArrowDownStaysInTextBoxWhenEmpty() {
        let action = route(.command(#selector(NSResponder.moveDown(_:)), shifted: false), isEmpty: true)
        guard case .textInput = action else {
            XCTFail("Expected .textInput (arrows never forward — Option B), got \(action)")
            return
        }
    }

    func testArrowLeftStaysInTextBoxWhenEmpty() {
        let action = route(.command(#selector(NSResponder.moveLeft(_:)), shifted: false), isEmpty: true)
        guard case .textInput = action else {
            XCTFail("Expected .textInput (arrows never forward — Option B), got \(action)")
            return
        }
    }

    func testArrowRightStaysInTextBoxWhenEmpty() {
        let action = route(.command(#selector(NSResponder.moveRight(_:)), shifted: false), isEmpty: true)
        guard case .textInput = action else {
            XCTFail("Expected .textInput (arrows never forward — Option B), got \(action)")
            return
        }
    }

    func testArrowUpNotForwardedWhenNotEmpty() {
        let action = route(.command(#selector(NSResponder.moveUp(_:)), shifted: false), isEmpty: false)
        guard case .textInput = action else {
            XCTFail("Expected .textInput when not empty, got \(action)")
            return
        }
    }

    // MARK: Rule 10 — Fallback (textInput)

    func testRegularTextReturnsTextInput() {
        let action = route(.text("a"), isEmpty: false)
        guard case .textInput = action else {
            XCTFail("Expected .textInput, got \(action)")
            return
        }
    }

    func testUnknownSelectorReturnsTextInput() {
        let action = route(.command(#selector(NSResponder.selectAll(_:)), shifted: false))
        guard case .textInput = action else {
            XCTFail("Expected .textInput for unknown selector, got \(action)")
            return
        }
    }
}

// MARK: - TextBoxAppDetection Tests

final class TextBoxAppDetectionTests: XCTestCase {

    func testClaudeCodeDetected() {
        XCTAssertTrue(TextBoxAppDetection.claudeCode.matches(terminalTitle: "Claude Code"))
    }

    func testClaudeCodeDetectedWithIcon() {
        XCTAssertTrue(TextBoxAppDetection.claudeCode.matches(terminalTitle: "✱ Claude Code"))
    }

    func testClaudeCodeDetectedWithAltIcon() {
        XCTAssertTrue(TextBoxAppDetection.claudeCode.matches(terminalTitle: "✳ Claude Code"))
    }

    func testClaudeCodeDetectedWithThinkingIndicator() {
        XCTAssertTrue(TextBoxAppDetection.claudeCode.matches(terminalTitle: "⠂ New coding session"))
    }

    func testClaudeCodeDetectedWithIconAndSessionTitle() {
        XCTAssertTrue(TextBoxAppDetection.claudeCode.matches(terminalTitle: "✳ Japanese greeting conversation"))
    }

    func testCodexDetected() {
        XCTAssertTrue(TextBoxAppDetection.codex.matches(terminalTitle: "Codex"))
    }

    func testPlainShellNotDetected() {
        XCTAssertFalse(TextBoxAppDetection.claudeCode.matches(terminalTitle: "zsh"))
        XCTAssertFalse(TextBoxAppDetection.codex.matches(terminalTitle: "zsh"))
    }

    // MARK: Metadata-first detection (c11mux SurfaceMetadataStore)

    func testMetadataClaudeCodeDetectedRegardlessOfTitle() {
        XCTAssertTrue(
            TextBoxAppDetection.claudeCode.matches(
                terminalType: "claude-code", terminalTitle: "zsh")
        )
    }

    func testMetadataCodexDetectedRegardlessOfTitle() {
        XCTAssertTrue(
            TextBoxAppDetection.codex.matches(
                terminalType: "codex", terminalTitle: "zsh")
        )
    }

    func testMetadataShellSuppressesClaudeCodeDetection() {
        // Metadata says shell; title happens to say "Claude Code". Metadata wins.
        XCTAssertFalse(
            TextBoxAppDetection.claudeCode.matches(
                terminalType: "shell", terminalTitle: "Claude Code")
        )
    }

    func testNilMetadataFallsBackToTitleRegex() {
        XCTAssertTrue(
            TextBoxAppDetection.claudeCode.matches(
                terminalType: nil, terminalTitle: "Claude Code")
        )
        XCTAssertFalse(
            TextBoxAppDetection.claudeCode.matches(
                terminalType: nil, terminalTitle: "zsh")
        )
    }

    func testEmptyMetadataFallsBackToTitleRegex() {
        XCTAssertTrue(
            TextBoxAppDetection.claudeCode.matches(
                terminalType: "", terminalTitle: "Claude Code")
        )
    }
}
