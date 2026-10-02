import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class GhosttyPasteboardHelperTests: XCTestCase {
    func testHTMLOnlyPasteboardExtractsPlainText() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-html-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<p>Hello <strong>world</strong></p>", forType: .html)

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), "Hello world")
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
    }

    func testImageHTMLClipboardFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-html-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<meta charset='utf-8'><img src=\"https://example.com/keyboard.png\">", forType: .html)

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(pngData, forType: .png)

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testImageHTMLClipboardWithVisibleTextPrefersText() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-html-text-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<p>Hello <img src=\"https://example.com/keyboard.png\"></p>", forType: .html)

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(pngData, forType: .png)

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), "Hello")
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
    }

    func testJPEGClipboardFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-jpeg-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let jpegData = try XCTUnwrap(
            bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 1.0]
            )
        )
        pasteboard.setData(
            jpegData,
            forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        )

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".jpeg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testAttachmentOnlyRTFDClipboardFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-rtfd-attachment-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = image
        let attributed = NSAttributedString(attachment: attachment)
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        pasteboard.setData(data, forType: .rtfd)

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".tiff"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testAttachmentOnlyRTFDNonImageClipboardDoesNotFallBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-rtfd-non-image-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let wrapper = FileWrapper(regularFileWithContents: Data("hello".utf8))
        wrapper.preferredFilename = "note.txt"

        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let attributed = NSAttributedString(attachment: attachment)
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        pasteboard.setData(data, forType: .rtfd)

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
    }

    func testRTFDClipboardWithVisibleTextPrefersText() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-rtfd-text-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.purple.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = image

        let attributed = NSMutableAttributedString(string: "Hello ")
        attributed.append(NSAttributedString(attachment: attachment))
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        pasteboard.setData(data, forType: .rtfd)

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), "Hello")
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
    }
}


final class TerminalKeyboardCopyModeActionTests: XCTestCase {
    func testCopyModeBypassAllowsOnlyCommandShortcuts() {
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command]))
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command, .shift]))
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command, .option]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.option]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.option, .shift]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.control]))
    }

    func testJKWithoutSelectionScrollByLine() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [],
                hasSelection: false
            ),
            .scrollLines(1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifierFlags: [],
                hasSelection: false
            ),
            .scrollLines(-1)
        )
    }

    func testCapsLockDoesNotBlockLetterMappings() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [.capsLock],
                hasSelection: false
            ),
            .scrollLines(1)
        )
    }

    func testJKWithSelectionAdjustSelection() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.down)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.up)
        )
    }

    func testControlPagingSupportsPrintableAndControlCharacters() {
        // Ctrl+U = half-page up (vim standard).
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{15}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollHalfPage(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{04}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.pageDown)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{02}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollPage(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{06}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.pageDown)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{19}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollLines(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{05}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.down)
        )
    }

    func testVGYMapping() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [],
                hasSelection: false
            ),
            .startSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [],
                hasSelection: true
            ),
            .clearSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 16,
                charactersIgnoringModifiers: "y",
                modifierFlags: [],
                hasSelection: true
            ),
            .copyAndExit
        )
    }

    func testGAndShiftGMapping() {
        // Bare "g" is a prefix key (gg), not an immediate action.
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 5,
                charactersIgnoringModifiers: "g",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 5,
                charactersIgnoringModifiers: "g",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .scrollToBottom
        )
    }

    func testLineBoundaryPromptAndSearchMappings() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 29,
                charactersIgnoringModifiers: "0",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.beginningOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 20,
                charactersIgnoringModifiers: "^",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .adjustSelection(.beginningOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .adjustSelection(.endOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 33,
                charactersIgnoringModifiers: "[",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .jumpToPrompt(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 30,
                charactersIgnoringModifiers: "]",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .jumpToPrompt(1)
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifierFlags: [],
                hasSelection: true
            )
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 33,
                charactersIgnoringModifiers: "[",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 30,
                charactersIgnoringModifiers: "]",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 44,
                charactersIgnoringModifiers: "/",
                modifierFlags: [],
                hasSelection: false
            ),
            .startSearch
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 45,
                charactersIgnoringModifiers: "n",
                modifierFlags: [],
                hasSelection: false
            ),
            .searchNext
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 45,
                charactersIgnoringModifiers: "n",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .searchPrevious
        )
    }

    func testShiftVMatchesVisualToggleBehavior() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .startSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .clearSelection
        )
    }

    func testEscapeAlwaysExits() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 53,
                charactersIgnoringModifiers: "",
                modifierFlags: [],
                hasSelection: false
            ),
            .exit
        )
    }

    func testQAlwaysExits() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 12, // kVK_ANSI_Q
                charactersIgnoringModifiers: "q",
                modifierFlags: [],
                hasSelection: false
            ),
            .exit
        )
    }
}


final class TerminalKeyboardCopyModeResolveTests: XCTestCase {
    private func resolve(
        _ keyCode: UInt16,
        chars: String,
        modifiers: NSEvent.ModifierFlags = [],
        hasSelection: Bool,
        state: inout TerminalKeyboardCopyModeInputState
    ) -> TerminalKeyboardCopyModeResolution {
        terminalKeyboardCopyModeResolve(
            keyCode: keyCode,
            charactersIgnoringModifiers: chars,
            modifierFlags: modifiers,
            hasSelection: hasSelection,
            state: &state
        )
    }

    func testCountPrefixAppliesToMotion() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.scrollLines(1), count: 3))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testZeroAppendsCountOrActsAsMotion() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(19, chars: "2", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(29, chars: "0", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(40, chars: "k", hasSelection: false, state: &state), .perform(.scrollLines(-1), count: 20))

        var selectionState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(29, chars: "0", hasSelection: true, state: &selectionState),
            .perform(.adjustSelection(.beginningOfLine), count: 1)
        )
    }

    func testYankLineOperatorSupportsYYAndYWithCounts() {
        var yyState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &yyState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &yyState), .perform(.copyLineAndExit, count: 1))

        var countedState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(21, chars: "4", hasSelection: false, state: &countedState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &countedState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &countedState), .perform(.copyLineAndExit, count: 4))

        var shiftYState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &shiftYState), .consume)
        XCTAssertEqual(
            resolve(16, chars: "y", modifiers: [.shift], hasSelection: false, state: &shiftYState),
            .perform(.copyLineAndExit, count: 3)
        )
    }

    func testPendingYankLineDoesNotSwallowNextCommand() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.scrollLines(1), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testSearchAndPromptMotionsUseCounts() {
        var promptState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &promptState), .consume)
        XCTAssertEqual(
            resolve(30, chars: "]", modifiers: [.shift], hasSelection: false, state: &promptState),
            .perform(.jumpToPrompt(1), count: 3)
        )

        var searchState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(18, chars: "2", hasSelection: false, state: &searchState), .consume)
        XCTAssertEqual(resolve(45, chars: "n", hasSelection: false, state: &searchState), .perform(.searchNext, count: 2))
    }

    func testInvalidKeyClearsPendingState() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(18, chars: "2", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(7, chars: "x", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    // MARK: - gg (scroll to top via two-key sequence)

    func testGGScrollsToTop() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .perform(.scrollToTop, count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testGGWithSelectionAdjustsToHome() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: true, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: true, state: &state), .perform(.adjustSelection(.home), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testCountedGG() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(22, chars: "5", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .perform(.scrollToTop, count: 5))
    }

    func testPendingGCancelledByOtherKey() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.scrollLines(1), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testShiftGStillWorksImmediately() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(5, chars: "g", modifiers: [.shift], hasSelection: false, state: &state),
            .perform(.scrollToBottom, count: 1)
        )
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    // MARK: - Ctrl+U/D half-page scroll

    func testCtrlUHalfPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(32, chars: "u", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollHalfPage(-1), count: 1)
        )
    }

    func testCtrlDHalfPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(2, chars: "d", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollHalfPage(1), count: 1)
        )
    }

    func testCtrlBFullPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(11, chars: "b", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollPage(-1), count: 1)
        )
    }

    func testCtrlFFullPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(3, chars: "f", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollPage(1), count: 1)
        )
    }
}


final class TerminalKeyboardCopyModeViewportRowTests: XCTestCase {
    func testInitialViewportRowUsesImePointBaseline() {
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 24,
                imeCellHeight: 24
            ),
            0
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 240,
                imeCellHeight: 24
            ),
            9
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 48,
                imeCellHeight: 24,
                topPadding: 24
            ),
            0
        )
    }

    func testInitialViewportRowClampsBoundsAndFallsBackWhenHeightMissing() {
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 0,
                imeCellHeight: 24
            ),
            0
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 9999,
                imeCellHeight: 24
            ),
            23
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 123,
                imeCellHeight: 0
            ),
            23
        )
    }
}


final class GhosttyBackgroundThemeTests: XCTestCase {
    func testColorClampsOpacity() {
        let base = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1.0)

        let lowerClamped = GhosttyBackgroundTheme.color(backgroundColor: base, opacity: -2.0)
        XCTAssertEqual(lowerClamped.alphaComponent, 0.0, accuracy: 0.0001)

        let upperClamped = GhosttyBackgroundTheme.color(backgroundColor: base, opacity: 5.0)
        XCTAssertEqual(upperClamped.alphaComponent, 1.0, accuracy: 0.0001)
    }

    func testColorFromNotificationUsesBackgroundAndOpacity() {
        let fallbackColor = NSColor.black
        let fallbackOpacity = 1.0
        let notification = Notification(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0),
                GhosttyNotificationKey.backgroundOpacity: NSNumber(value: 0.57),
            ]
        )

        let actual = GhosttyBackgroundTheme.color(
            from: notification,
            fallbackColor: fallbackColor,
            fallbackOpacity: fallbackOpacity
        )
        guard let srgb = actual.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(srgb.redComponent, 0.18, accuracy: 0.005)
        XCTAssertEqual(srgb.greenComponent, 0.29, accuracy: 0.005)
        XCTAssertEqual(srgb.blueComponent, 0.44, accuracy: 0.005)
        XCTAssertEqual(srgb.alphaComponent, 0.57, accuracy: 0.005)
    }

    func testColorFromNotificationFallsBackWhenPayloadMissing() {
        let fallbackColor = NSColor(srgbRed: 0.12, green: 0.34, blue: 0.56, alpha: 1.0)
        let fallbackOpacity = 0.42
        let notification = Notification(name: .ghosttyDefaultBackgroundDidChange)

        let actual = GhosttyBackgroundTheme.color(
            from: notification,
            fallbackColor: fallbackColor,
            fallbackOpacity: fallbackOpacity
        )
        guard let srgb = actual.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(srgb.redComponent, 0.12, accuracy: 0.005)
        XCTAssertEqual(srgb.greenComponent, 0.34, accuracy: 0.005)
        XCTAssertEqual(srgb.blueComponent, 0.56, accuracy: 0.005)
        XCTAssertEqual(srgb.alphaComponent, 0.42, accuracy: 0.005)
    }
}


final class GhosttyResponderResolutionTests: XCTestCase {
    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testResolvesGhosttyViewFromDescendantResponder() {
        let ghosttyView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let descendant = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        ghosttyView.addSubview(descendant)

        XCTAssertTrue(cmuxOwningGhosttyView(for: descendant) === ghosttyView)
    }

    func testResolvesGhosttyViewFromGhosttyResponder() {
        let ghosttyView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertTrue(cmuxOwningGhosttyView(for: ghosttyView) === ghosttyView)
    }

    func testReturnsNilForUnrelatedResponder() {
        let view = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(cmuxOwningGhosttyView(for: view))
    }
}


final class TerminalDirectoryOpenTargetAvailabilityTests: XCTestCase {
    private func environment(
        existingPaths: Set<String>,
        homeDirectoryPath: String = "/Users/tester",
        applicationPathsByName: [String: String] = [:]
    ) -> TerminalDirectoryOpenTarget.DetectionEnvironment {
        TerminalDirectoryOpenTarget.DetectionEnvironment(
            homeDirectoryPath: homeDirectoryPath,
            fileExistsAtPath: { existingPaths.contains($0) },
            isExecutableFileAtPath: { existingPaths.contains($0) },
            applicationPathForName: { applicationPathsByName[$0] }
        )
    }

    func testAvailableTargetsDetectSystemApplications() {
        let env = environment(
            existingPaths: [
                "/Applications/Visual Studio Code.app",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel",
                "/System/Library/CoreServices/Finder.app",
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Zed Preview.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.vscode))
        XCTAssertTrue(availableTargets.contains(.finder))
        XCTAssertTrue(availableTargets.contains(.terminal))
        XCTAssertTrue(availableTargets.contains(.zed))
        XCTAssertFalse(availableTargets.contains(.cursor))
    }

    func testAvailableTargetsFallbackToUserApplications() {
        let env = environment(
            existingPaths: [
                "/Users/tester/Applications/Cursor.app",
                "/Users/tester/Applications/Warp.app",
                "/Users/tester/Applications/Android Studio.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.cursor))
        XCTAssertTrue(availableTargets.contains(.warp))
        XCTAssertTrue(availableTargets.contains(.androidStudio))
        XCTAssertFalse(availableTargets.contains(.vscode))
    }

    func testVSCodeInlineRequiresCodeTunnelExecutable() {
        let env = environment(existingPaths: ["/Applications/Visual Studio Code.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.vscode.isAvailable(in: env))
        XCTAssertFalse(TerminalDirectoryOpenTarget.vscodeInline.isAvailable(in: env))
    }

    func testITerm2DetectsLegacyBundleName() {
        let env = environment(existingPaths: ["/Applications/iTerm.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.iterm2.isAvailable(in: env))
    }

    func testTowerDetected() {
        let env = environment(existingPaths: ["/Applications/Tower.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.tower.isAvailable(in: env))
    }

    func testAvailableTargetsFallbackToApplicationLookupForVSCodeAliasOutsideApplications() {
        let vscodePath = "/Volumes/Tools/Code.app"
        let env = environment(
            existingPaths: [
                vscodePath,
                "\(vscodePath)/Contents/Resources/app/bin/code-tunnel",
            ],
            applicationPathsByName: [
                "Code": vscodePath,
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.vscode))
        XCTAssertTrue(availableTargets.contains(.vscodeInline))
    }

    func testTowerDetectedViaApplicationLookupOutsideApplications() {
        let towerPath = "/Volumes/Setapp/Tower.app"
        let env = environment(
            existingPaths: [towerPath],
            applicationPathsByName: [
                "Tower": towerPath,
            ]
        )

        XCTAssertTrue(TerminalDirectoryOpenTarget.tower.isAvailable(in: env))
    }

    func testCommandPaletteShortcutsExcludeGenericIDEEntry() {
        let targets = TerminalDirectoryOpenTarget.commandPaletteShortcutTargets
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteTitle == "Open Current Directory in IDE" }))
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteCommandId == "palette.terminalOpenDirectory" }))
    }
}


@MainActor
final class TerminalNotificationDirectInteractionTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func makeKeyEvent(characters: String, keyCode: UInt16, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to create key event")
        }
        return event
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> NSView? {
        hostedView.subviews
            .compactMap { $0 as? NSScrollView }
            .first?
            .documentView?
            .subviews
            .first
    }

    func testTerminalMouseDownDismissesUnreadWhenSurfaceIsAlreadyFirstResponder() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = WorkspaceManager()
        let store = TerminalNotificationStore.shared
        let window = makeWindow()

        let originalWorkspaceManager = appDelegate.workspaceManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.workspaceManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.workspaceManager = originalWorkspaceManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            window.orderOut(nil)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalTab = workspace.focusedTerminalTab else {
            XCTFail("Expected an initial focused terminal panel")
            return
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = terminalTab.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        guard let surfaceView = surfaceView(in: hostedView) else {
            XCTFail("Expected terminal surface view")
            return
        }

        GhosttySurfaceScrollView.resetFlashCounts()
        AppFocusState.overrideIsFocused = true
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        store.addNotification(
            workspaceId: workspace.id,
            surfaceId: terminalTab.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: terminalTab.id))

        AppFocusState.overrideIsFocused = true
        let pointInWindow = surfaceView.convert(NSPoint(x: 20, y: 20), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: pointInWindow, window: window)
        surfaceView.mouseDown(with: event)
        let drained = expectation(description: "flash drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5.0)

        XCTAssertFalse(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: terminalTab.id))
        XCTAssertEqual(GhosttySurfaceScrollView.flashCount(for: terminalTab.id), 1)
    }

    func testTerminalKeyDownDismissesUnreadWhenSurfaceIsAlreadyFirstResponder() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = WorkspaceManager()
        let store = TerminalNotificationStore.shared
        let window = makeWindow()

        let originalWorkspaceManager = appDelegate.workspaceManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.workspaceManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.workspaceManager = originalWorkspaceManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            window.orderOut(nil)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalTab = workspace.focusedTerminalTab else {
            XCTFail("Expected an initial focused terminal panel")
            return
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = terminalTab.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }

        GhosttySurfaceScrollView.resetFlashCounts()
        AppFocusState.overrideIsFocused = true
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        store.addNotification(
            workspaceId: workspace.id,
            surfaceId: terminalTab.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: terminalTab.id))

        let event = makeKeyEvent(characters: "", keyCode: 122, window: window)
        surfaceView.keyDown(with: event)
        let drained = expectation(description: "flash drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5.0)

        XCTAssertFalse(store.hasUnreadNotification(forWorkspaceId: workspace.id, surfaceId: terminalTab.id))
        XCTAssertEqual(GhosttySurfaceScrollView.flashCount(for: terminalTab.id), 1)
    }
}


@MainActor
final class WindowTerminalHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    func testHostViewPassesThroughWhenNoTerminalSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        XCTAssertNil(host.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testHostViewReturnsSubviewWhenSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let child = CapturingView(frame: NSRect(x: 20, y: 15, width: 40, height: 30))
        host.addSubview(child)

        XCTAssertTrue(host.hitTest(NSPoint(x: 25, y: 20)) === child)
        XCTAssertNil(host.hitTest(NSPoint(x: 150, y: 100)))
    }

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Host view must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        XCTAssertTrue(host.hitTest(contentPointInHost) === child)
    }
}


@MainActor
final class GhosttySurfaceOverlayTests: XCTestCase {
    private final class ScrollProbeSurfaceView: GhosttyNSView {
        private(set) var scrollWheelCallCount = 0

        override func scrollWheel(with event: NSEvent) {
            scrollWheelCallCount += 1
        }
    }

    private func findEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func firstResponderOwnsTextField(_ firstResponder: NSResponder?, textField: NSTextField) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }

    func testTrackpadScrollRoutesToTerminalSurfaceAndPreservesKeyboardFocusPath() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surfaceView = ScrollProbeSurfaceView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let scrollView = hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView else {
            XCTFail("Expected hosted terminal scroll view")
            return
        }
        XCTAssertFalse(
            scrollView.acceptsFirstResponder,
            "Host scroll view should not become first responder and steal terminal shortcuts"
        )

        _ = window.makeFirstResponder(nil)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: -12,
            wheel3: 0
        ), let scrollEvent = NSEvent(cgEvent: cgEvent) else {
            XCTFail("Expected scroll wheel event")
            return
        }

        scrollView.scrollWheel(with: scrollEvent)

        XCTAssertEqual(
            surfaceView.scrollWheelCallCount,
            1,
            "Trackpad wheel events should be forwarded directly to Ghostty surface scrolling"
        )
        XCTAssertTrue(
            window.firstResponder === surfaceView,
            "Scroll wheel handling should keep keyboard focus on terminal surface"
        )
    }

    func testInactiveOverlayVisibilityTracksRequestedState() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        )

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: true)
        var state = hostedView.debugInactiveOverlayState()
        XCTAssertFalse(state.isHidden)
        XCTAssertEqual(state.alpha, 0.35, accuracy: 0.01)

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: false)
        state = hostedView.debugInactiveOverlayState()
        XCTAssertTrue(state.isHidden)
    }

    func testWindowResignKeyClearsFocusedTerminalFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        )
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        hostedView.moveFocus()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to be first responder before window blur"
        )

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Window blur should force terminal surface to resign first responder"
        )
    }

    func testSearchOverlayMountsAndUnmountsWithSearchState() {
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        XCTAssertFalse(hostedView.debugHasSearchOverlay())

        let searchState = TerminalSurface.SearchState(needle: "example")
        hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        hostedView.setSearchOverlay(searchState: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(hostedView.debugHasSearchOverlay())
    }

    func testFlagBannerMountIsAdditiveAndDoesNotStealFocusOrReflowTerminal() {
        let workspace = UUID()
        let surface = TerminalSurface(
            workspaceId: workspace,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            TabAttentionIndex.shared.remove(workspaceId: workspace, surfaceId: surface.id)
            hostedView.updateFlagBanner()
            window.orderOut(nil)
        }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        let outsideResponder = NSTextField(frame: NSRect(x: 4, y: 4, width: 80, height: 20))
        contentView.addSubview(hostedView)
        contentView.addSubview(outsideResponder)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostedView.reconcileGeometryNow()
        XCTAssertTrue(window.makeFirstResponder(outsideResponder))
        let before = hostedView.debugFlagBannerState()

        TabAttentionIndex.shared.publish(
            TabAttentionSnapshot(
                workspaceId: workspace,
                surfaceId: surface.id,
                flagReason: "Need a schema decision",
                flagRaisedAt: Date(timeIntervalSince1970: 100),
                suppressed: false
            )
        )
        hostedView.updateFlagBanner()
        let after = hostedView.debugFlagBannerState()

        XCTAssertTrue(after.isMounted)
        XCTAssertTrue(after.isAboveFlashOverlay)
        XCTAssertEqual(after.bannerFrame?.height, 30)
        XCTAssertEqual(after.scrollFrame, before.scrollFrame)
        XCTAssertEqual(after.surfaceFrame, before.surfaceFrame)
        XCTAssertTrue(window.firstResponder === outsideResponder)
    }

    func testFlagBannerStaysBelowSearchOverlayInPortalZOrder() {
        let workspace = UUID()
        let surface = TerminalSurface(
            workspaceId: workspace,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        defer {
            TabAttentionIndex.shared.remove(workspaceId: workspace, surfaceId: surface.id)
            hostedView.updateFlagBanner()
            hostedView.setSearchOverlay(searchState: nil)
        }

        hostedView.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        hostedView.setSearchOverlay(
            searchState: TerminalSurface.SearchState(needle: "operator")
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        TabAttentionIndex.shared.publish(
            TabAttentionSnapshot(
                workspaceId: workspace,
                surfaceId: surface.id,
                flagReason: "Need operator input",
                flagRaisedAt: Date(timeIntervalSince1970: 100),
                suppressed: false
            )
        )
        hostedView.updateFlagBanner()

        let state = hostedView.debugFlagBannerState()
        XCTAssertTrue(state.isMounted)
        XCTAssertEqual(state.isBelowSearchOverlay, true)
        XCTAssertTrue(state.isAboveFlashOverlay)
    }

    func testRapidSearchOverlayToggleDoesNotLeaveStaleOverlayMounted() {
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "example"))
        hostedView.setSearchOverlay(searchState: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            hostedView.debugHasSearchOverlay(),
            "A stale deferred mount must not resurrect the find overlay after it closes"
        )
    }

    func testSearchOverlayFocusesSearchFieldAfterDeferredAttach() {
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)

        let searchState = TerminalSurface.SearchState(needle: "")
        surface.searchState = searchState
        hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let searchField = findEditableTextField(in: hostedView) else {
            XCTFail("Expected mounted find text field")
            return
        }

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Deferred search overlay attach should still move focus into the find field"
        )
    }

    func testStartOrFocusTerminalSearchReusesExistingSearchState() {
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let existingSearchState = TerminalSurface.SearchState(needle: "existing")
        surface.searchState = existingSearchState

        var focusNotificationCount = 0
        XCTAssertTrue(
            startOrFocusTerminalSearch(surface) { _ in
                focusNotificationCount += 1
            }
        )

        XCTAssertTrue(surface.searchState === existingSearchState)
        XCTAssertEqual(
            focusNotificationCount,
            1,
            "Re-triggering terminal Find should refocus the existing overlay without recreating state"
        )
    }

    func testEscapeDismissingFindOverlayDoesNotLeakEscapeKeyUpToTerminal() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let searchState = TerminalSurface.SearchState(needle: "")
        surface.searchState = searchState
        hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let searchField = findEditableTextField(in: hostedView) else {
            XCTFail("Expected mounted find text field")
            return
        }
        window.makeFirstResponder(searchField)

        var escapeKeyUpCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_RELEASE, keyEvent.keycode == 53 else { return }
            escapeKeyUpCount += 1
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let escapeKeyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ), let escapeKeyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            XCTFail("Failed to construct Escape key events")
            return
        }

        NSApp.sendEvent(escapeKeyDown)
        NSApp.sendEvent(escapeKeyUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(surface.searchState, "Escape should dismiss find overlay when search text is empty")
        XCTAssertEqual(
            escapeKeyUpCount,
            0,
            "Escape used to dismiss find overlay must not pass through to the terminal key-up path"
        )
    }

    @MainActor
    func testKeyboardCopyModeIndicatorMountsAndUnmounts() {
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        XCTAssertFalse(hostedView.debugHasKeyboardCopyModeIndicator())

        hostedView.syncKeyStateIndicator(text: "vim")
        XCTAssertTrue(hostedView.debugHasKeyboardCopyModeIndicator())

        hostedView.syncKeyStateIndicator(text: nil)
        XCTAssertFalse(hostedView.debugHasKeyboardCopyModeIndicator())
    }

    @MainActor
    func testDropHoverOverlayAttachesToParentContainerInsteadOfHostedTerminalView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let surfaceView = GhosttyNSView(frame: .zero)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = container.bounds
        container.addSubview(hostedView)

        hostedView.setDropZoneOverlay(zone: .right)
        container.layoutSubtreeIfNeeded()

        let state = hostedView.debugDropZoneOverlayState()
        XCTAssertFalse(state.isHidden)
        XCTAssertFalse(
            state.isAttachedToHostedView,
            "Drop-hover overlay should be mounted outside the hosted terminal view"
        )
        XCTAssertTrue(
            state.isAttachedToParentContainer,
            "Drop-hover overlay should be mounted in the parent container so it cannot perturb terminal layout"
        )
        XCTAssertEqual(state.frame.origin.x, 120, accuracy: 0.5)
        XCTAssertEqual(state.frame.origin.y, 4, accuracy: 0.5)
        XCTAssertEqual(state.frame.size.width, 116, accuracy: 0.5)
        XCTAssertEqual(state.frame.size.height, 112, accuracy: 0.5)

        hostedView.setDropZoneOverlay(zone: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(hostedView.debugDropZoneOverlayState().isHidden)
    }

    func testForceRefreshNoopsAfterSurfaceReleaseDuringGeometryReconcile() throws {
#if DEBUG
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostedView.reconcileGeometryNow()
        surface.releaseSurfaceForTesting()
        XCTAssertNil(surface.surface, "Surface should be nil after test release helper")

        hostedView.reconcileGeometryNow()
        surface.forceRefresh()
        XCTAssertNil(surface.surface, "Force refresh should no-op when runtime surface is nil")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testSearchOverlayMountDoesNotRetainTerminalSurface() {
        weak var weakSurface: TerminalSurface?

        let hostedView: GhosttySurfaceScrollView = {
            let surface = TerminalSurface(
                workspaceId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil,
                workingDirectory: nil
            )
            weakSurface = surface
            let hostedView = surface.hostedView
            hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "retain-check"))
            return hostedView
        }()

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())
        XCTAssertNil(weakSurface, "Mounted search overlay must not retain TerminalSurface")
    }

    func testSearchOverlaySurvivesPortalRebindDuringSplitLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorA = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 140))
        let anchorB = NSView(frame: NSRect(x: 220, y: 20, width: 180, height: 140))
        contentView.addSubview(anchorA)
        contentView.addSubview(anchorB)

        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "split"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorA, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorB, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Split-like anchor churn should not unmount terminal search overlay"
        )
    }

    func testSearchOverlaySurvivesPortalVisibilityToggleDuringWorkspaceSwitchLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 220, height: 160))
        contentView.addSubview(anchor)

        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "workspace"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: false)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Workspace-switch-like visibility toggles should not unmount terminal search overlay"
        )
    }
}


final class PortalWorkspaceFrameOverlayTests: XCTestCase {
    func testWorkspaceFrameSegmentsIncludeNonHostLeadingEdge() {
        let style = PortalWorkspaceFrameStyle(colorHex: "#00ff00", thicknessPt: 2, opacity: 1)
        let color = NSColor.green
        var segments: [PortalChromeOverlaySegment] = []

        PortalWorkspaceFrameOverlay.appendWorkspaceFrameSegments(
            for: NSRect(x: 180, y: 20, width: 300, height: 200),
            hostBounds: NSRect(x: 0, y: 0, width: 800, height: 600),
            style: style,
            color: color,
            dividerSegments: [],
            into: &segments
        )

        XCTAssertTrue(
            segments.contains { segment in
                abs(segment.rect.minX - 180) <= 0.001 &&
                    abs(segment.rect.width - 2) <= 0.001 &&
                    abs(segment.rect.height - 200) <= 0.001
            },
            "Portal workspace frame should render the workspace/content leading edge even when the portal host begins before it."
        )
    }

    func testWorkspaceFrameSegmentsSkipEdgesOwnedBySplitDividers() {
        let style = PortalWorkspaceFrameStyle(colorHex: "#00ff00", thicknessPt: 2, opacity: 1)
        let color = NSColor.green
        var segments: [PortalChromeOverlaySegment] = []

        PortalWorkspaceFrameOverlay.appendWorkspaceFrameSegments(
            for: NSRect(x: 482, y: 20, width: 300, height: 200),
            hostBounds: NSRect(x: 0, y: 0, width: 800, height: 600),
            style: style,
            color: color,
            dividerSegments: [
                PortalChromeOverlayDividerSegment(
                    rect: NSRect(x: 480, y: 0, width: 2, height: 260),
                    isVertical: true
                ),
            ],
            into: &segments
        )

        XCTAssertFalse(
            segments.contains { segment in
                abs(segment.rect.minX - 482) <= 0.001 &&
                    abs(segment.rect.width - 2) <= 0.001 &&
                    abs(segment.rect.height - 200) <= 0.001
            },
            "Portal workspace frame should not paint over a real split divider edge."
        )
    }

    func testWorkspaceFrameSegmentsRespectDisabledPanelChromeEdges() {
        let style = PortalWorkspaceFrameStyle(
            colorHex: "#00ff00",
            thicknessPt: 2,
            opacity: 1,
            edges: PortalWorkspaceFrameEdges(top: false)
        )
        let color = NSColor.green
        var segments: [PortalChromeOverlaySegment] = []

        PortalWorkspaceFrameOverlay.appendWorkspaceFrameSegments(
            for: NSRect(x: 180, y: 20, width: 300, height: 200),
            hostBounds: NSRect(x: 0, y: 0, width: 800, height: 600),
            style: style,
            color: color,
            dividerSegments: [],
            into: &segments
        )

        XCTAssertFalse(
            segments.contains { segment in
                abs(segment.rect.minY - 218) <= 0.001 &&
                    abs(segment.rect.height - 2) <= 0.001
            },
            "Portal workspace frame should not draw internal edges covered by SwiftUI panel chrome."
        )
    }

    func testWorkspaceFrameColorPreservesThemeAlpha() throws {
        let style = PortalWorkspaceFrameStyle(colorHex: "#33669980", thicknessPt: 2, opacity: 0.5)

        let color = try XCTUnwrap(PortalWorkspaceFrameOverlay.color(from: style))
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))

        XCTAssertEqual(srgb.redComponent, CGFloat(0x33) / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.greenComponent, CGFloat(0x66) / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.blueComponent, CGFloat(0x99) / 255.0, accuracy: 0.001)
        XCTAssertEqual(srgb.alphaComponent, (CGFloat(0x80) / 255.0) * 0.5, accuracy: 0.001)
    }
}


@MainActor
final class TerminalWindowPortalLifecycleTests: XCTestCase {
    private final class ContentViewCountingWindow: NSWindow {
        var contentViewReadCount = 0

        override var contentView: NSView? {
            get {
                contentViewReadCount += 1
                return super.contentView
            }
            set {
                super.contentView = newValue
            }
        }
    }

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func drainMainQueue() {
        let expectation = XCTestExpectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        XCTWaiter().wait(for: [expectation], timeout: 5.0)
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        _ = portal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Portal host must remain above content view so portal-hosted terminals stay visible"
        )
    }

    func testTerminalPortalHostStaysBelowBrowserPortalHostWhenBothAreInstalled() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        let browserPortal = WindowBrowserPortal(window: window)
        let terminalPortal = WindowTerminalPortal(window: window)
        _ = browserPortal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))
        _ = terminalPortal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        func assertHostOrder(_ message: String) {
            guard let terminalHostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }),
                  let browserHostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }) else {
                XCTFail("Expected both portal hosts in same container")
                return
            }

            XCTAssertLessThan(
                terminalHostIndex,
                browserHostIndex,
                message
            )
        }

        assertHostOrder("Terminal portal host should start below browser portal host")

        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 220, height: 150))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        terminalPortal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        terminalPortal.synchronizeHostedViewForAnchor(anchor)

        assertHostOrder("Terminal portal bind/sync should not rise above the browser portal host")
    }

    func testRegistryPrunesPortalWhenWindowCloses() {
        let baseline = TerminalWindowPortalRegistry.debugPortalCount()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        _ = TerminalWindowPortalRegistry.viewAtWindowPoint(NSPoint(x: 1, y: 1), in: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline + 1)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline)
    }

    func testPruneDeadEntriesDetachesAnchorlessHostedView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hosted1 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )

        var anchor1: NSView? = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor1!)
        portal.bind(hostedView: hosted1, to: anchor1!, visibleInUI: true)

        anchor1?.removeFromSuperview()
        anchor1 = nil

        let hosted2 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )
        let anchor2 = NSView(frame: NSRect(x: 180, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor2)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        XCTAssertEqual(portal.debugEntryCount(), 1, "Only the live anchored hosted view should remain tracked")
        XCTAssertEqual(portal.debugHostedSubviewCount(), 1, "Stale anchorless hosted views should be detached from hostView")
    }

    func testSynchronizeReusesInstalledTargetWithoutRepeatedContentViewLookup() {
        let window = ContentViewCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 50, width: 200, height: 120))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let baselineReads = window.contentViewReadCount
        for _ in 0..<25 {
            portal.synchronizeHostedViewForAnchor(anchor)
        }

        XCTAssertEqual(
            window.contentViewReadCount,
            baselineReads,
            "Repeated synchronize calls should reuse installed target instead of repeatedly reading window.contentView"
        )
    }

    func testTerminalViewAtWindowPointResolvesPortalHostedSurface() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 50, width: 200, height: 120))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let center = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let windowPoint = anchor.convert(center, to: nil)
        XCTAssertNotNil(
            portal.terminalViewAtWindowPoint(windowPoint),
            "Portal hit-testing should resolve the terminal view for Finder file drops"
        )
    }

    func testVisibilityTransitionBringsHostedViewToFront() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Latest bind should be top-most before visibility transition"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: false)
        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Becoming visible should refresh z-order for already-hosted view"
        )
    }

    func testPriorityIncreaseBringsHostedViewToFrontWithoutVisibilityToggle() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 1)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true, zPriority: 2)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Higher-priority terminal should initially be top-most"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 2)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Promoting z-priority should bring an already-visible terminal to front"
        )
    }

    func testHiddenPortalDefersRevealUntilFrameHasUsableSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let portal = WindowTerminalPortal(window: window)
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 280, height: 220))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        XCTAssertFalse(hosted.isHidden, "Healthy geometry should be visible")

        // Collapse to a tiny frame first.
        anchor.frame = NSRect(x: 160.5, y: 1037.0, width: 79.0, height: 0.0)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(hosted.isHidden, "Tiny geometry should hide the portal-hosted terminal")

        // Then restore to a non-zero but still too-small frame. It should remain hidden.
        anchor.frame = NSRect(x: 160.9, y: 1026.5, width: 93.6, height: 10.3)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(
            hosted.isHidden,
            "Portal should defer reveal until geometry reaches a usable size"
        )

        // Once the frame is large enough again, reveal should resume.
        anchor.frame = NSRect(x: 40, y: 40, width: 180, height: 40)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertFalse(hosted.isHidden, "Portal should unhide after geometry is usable")
    }

    func testScheduledExternalGeometrySyncRefreshesAncestorLayoutShift() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 120, y: 60, width: 220, height: 160))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 24, y: 28, width: 72, height: 56))
        shiftedContainer.addSubview(anchor)

        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)

        let anchorCenter = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let originalWindowPoint = anchor.convert(anchorCenter, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        shiftedContainer.frame.origin.x += 96
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let shiftedWindowPoint = anchor.convert(anchorCenter, to: nil)
        XCTAssertNotEqual(originalWindowPoint.x, shiftedWindowPoint.x, accuracy: 0.5)
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "Ancestor-only layout shifts should leave the portal stale until an external geometry sync runs"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Before the external geometry sync, hit-testing should still point at the stale portal location"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows(trigger: "test")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "The stale portal position should be cleared after the scheduled external geometry sync"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "The scheduled external geometry sync should move the portal-hosted terminal to the anchor's new window position"
        )
    }

    func testScheduledExternalGeometrySyncWaitsForQueuedLayoutShift() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        shiftedContainer.addSubview(anchor)
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)

        let anchorCenter = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let originalWindowPoint = anchor.convert(anchorCenter, to: nil)
        let originalAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window, trigger: "test")
        DispatchQueue.main.async {
            shiftedContainer.frame.origin.x += 72
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let shiftedAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertGreaterThan(
            shiftedAnchorFrameInWindow.minX,
            originalAnchorFrameInWindow.minX + 1,
            "The queued layout shift should move the anchor to the right"
        )
        XCTAssertGreaterThan(
            shiftedAnchorFrameInWindow.maxX,
            originalAnchorFrameInWindow.maxX + 1,
            "The shifted anchor should expose a new trailing region outside the stale portal frame"
        )
        let retiredStaleWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.minX + shiftedAnchorFrameInWindow.minX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        let shiftedWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.maxX + shiftedAnchorFrameInWindow.maxX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredStaleWindowPoint, in: window),
            "The queued external sync should wait until the later layout shift settles, clearing the stale portal location"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "The delayed external sync should move the portal-hosted terminal to the queued layout shift position"
        )
    }

    func testScheduledExternalGeometrySyncKeepsDragDrivenResizeResponsive() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        shiftedContainer.addSubview(anchor)
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        realizeWindowLayout(window)

        let anchorCenter = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let originalWindowPoint = anchor.convert(anchorCenter, to: nil)
        let originalAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        defer {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
        }

        do {
            shiftedContainer.frame.origin.x += 72
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows(trigger: "test")
        }

        drainMainQueue()

        let shiftedAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        let retiredStaleWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.minX + shiftedAnchorFrameInWindow.minX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        let shiftedWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.maxX + shiftedAnchorFrameInWindow.maxX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        XCTAssertGreaterThan(
            shiftedWindowPoint.x,
            originalWindowPoint.x + 1,
            "The drag handler should shift the anchor to the right"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredStaleWindowPoint, in: window),
            "Drag-driven geometry sync should clear the stale portal location on the next main-queue turn"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "Drag-driven geometry sync should update the portal-hosted terminal without waiting an extra queue turn"
        )
    }

    func testDragDrivenSidebarResizeDoesNotScheduleLateSecondTerminalResize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 420, height: 220))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: shiftedContainer.bounds)
        anchor.autoresizingMask = [.width, .height]
        shiftedContainer.addSubview(anchor)

        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        realizeWindowLayout(window)
        let originalHostedFrame = hosted.frame

        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        defer {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
        }

        shiftedContainer.frame.origin.x += 72
        shiftedContainer.frame.size.width -= 72
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window, trigger: "test")

        drainMainQueue()

        let firstPassHostedFrame = hosted.frame
        XCTAssertGreaterThan(
            firstPassHostedFrame.minX,
            originalHostedFrame.minX + 1,
            "The sidebar drag should shift the hosted terminal on the first window-scoped sync pass"
        )
        XCTAssertLessThan(
            firstPassHostedFrame.width,
            originalHostedFrame.width - 1,
            "The sidebar drag should resize the hosted terminal on the first window-scoped sync pass"
        )

        drainMainQueue()

        let secondPassHostedFrame = hosted.frame
        XCTAssertEqual(
            secondPassHostedFrame.minX,
            firstPassHostedFrame.minX,
            accuracy: 0.5,
            "Interactive sidebar resizes should not land a second delayed horizontal terminal shift on the next queue turn"
        )
        XCTAssertEqual(
            secondPassHostedFrame.width,
            firstPassHostedFrame.width,
            accuracy: 0.5,
            "Interactive sidebar resizes should not land a second delayed terminal resize on the next queue turn"
        )
    }

    func testWindowScopedExternalGeometrySyncDoesNotRefreshOtherWindows() {
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: firstWindow)
            firstWindow.orderOut(nil)
        }

        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: secondWindow)
            secondWindow.orderOut(nil)
        }

        let firstSurface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let secondSurface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )

        guard let firstContentView = firstWindow.contentView,
              let secondContentView = secondWindow.contentView else {
            XCTFail("Expected content views")
            return
        }

        let firstContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        firstContentView.addSubview(firstContainer)
        let firstAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        firstContainer.addSubview(firstAnchor)

        let secondContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        secondContentView.addSubview(secondContainer)
        let secondAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        secondContainer.addSubview(secondAnchor)

        TerminalWindowPortalRegistry.bind(
            hostedView: firstSurface.hostedView,
            to: firstAnchor,
            visibleInUI: true,
            expectedSurfaceId: firstSurface.id,
            expectedGeneration: firstSurface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.bind(
            hostedView: secondSurface.hostedView,
            to: secondAnchor,
            visibleInUI: true,
            expectedSurfaceId: secondSurface.id,
            expectedGeneration: secondSurface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(firstAnchor)
        TerminalWindowPortalRegistry.synchronizeForAnchor(secondAnchor)
        realizeWindowLayout(firstWindow)
        realizeWindowLayout(secondWindow)

        let originalFirstFrameInWindow = firstAnchor.convert(firstAnchor.bounds, to: nil)
        let originalSecondFrameInWindow = secondAnchor.convert(secondAnchor.bounds, to: nil)

        firstContainer.frame.origin.x += 72
        secondContainer.frame.origin.x += 88
        firstContentView.layoutSubtreeIfNeeded()
        secondContentView.layoutSubtreeIfNeeded()
        firstWindow.displayIfNeeded()
        secondWindow.displayIfNeeded()

        let shiftedFirstFrameInWindow = firstAnchor.convert(firstAnchor.bounds, to: nil)
        let shiftedSecondFrameInWindow = secondAnchor.convert(secondAnchor.bounds, to: nil)
        let retiredFirstPoint = NSPoint(
            x: (originalFirstFrameInWindow.minX + shiftedFirstFrameInWindow.minX) / 2,
            y: shiftedFirstFrameInWindow.midY
        )
        let shiftedFirstPoint = NSPoint(
            x: (originalFirstFrameInWindow.maxX + shiftedFirstFrameInWindow.maxX) / 2,
            y: shiftedFirstFrameInWindow.midY
        )
        let retiredSecondPoint = NSPoint(
            x: (originalSecondFrameInWindow.minX + shiftedSecondFrameInWindow.minX) / 2,
            y: shiftedSecondFrameInWindow.midY
        )
        let shiftedSecondPoint = NSPoint(
            x: (originalSecondFrameInWindow.maxX + shiftedSecondFrameInWindow.maxX) / 2,
            y: shiftedSecondFrameInWindow.midY
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedFirstPoint, in: firstWindow),
            "First window should remain stale until its scheduled external geometry sync runs"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedSecondPoint, in: secondWindow),
            "Second window should remain stale until its scheduled external geometry sync runs"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredSecondPoint, in: secondWindow),
            "Before syncing, unrelated windows should still report the stale portal location"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: firstWindow, trigger: "test")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredFirstPoint, in: firstWindow),
            "Window-scoped sync should clear the stale location in the requested window"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedFirstPoint, in: firstWindow),
            "Window-scoped sync should refresh the requested window"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedSecondPoint, in: secondWindow),
            "Window-scoped sync should not refresh unrelated windows"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredSecondPoint, in: secondWindow),
            "Unrelated windows should retain their stale geometry until their own sync runs"
        )
    }
}


final class TerminalOpenURLTargetResolutionTests: XCTestCase {
    func testResolvesHTTPSAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https://example.com/path?q=1"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/path")
        default:
            XCTFail("Expected web URL to route to embedded browser")
        }
    }

    func testResolvesBareDomainAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("example.com/docs"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/docs")
        default:
            XCTFail("Expected bare domain to be normalized as an HTTPS browser URL")
        }
    }

    func testResolvesFileSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("file:///tmp/cmux.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/cmux.txt")
        default:
            XCTFail("Expected file URL to open externally")
        }
    }

    func testResolvesAbsolutePathAsExternalFileURL() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("/tmp/cmux-path.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/cmux-path.txt")
        default:
            XCTFail("Expected absolute file path to open externally")
        }
    }

    func testResolvesNonWebSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("mailto:test@example.com"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "mailto")
        default:
            XCTFail("Expected non-web scheme to open externally")
        }
    }

    func testResolvesHostlessHTTPSAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https:///tmp/cmux.txt"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNil(url.host)
            XCTAssertEqual(url.path, "/tmp/cmux.txt")
        default:
            XCTFail("Expected hostless HTTPS URL to open externally")
        }
    }
}


final class TerminalControllerSocketTextChunkTests: XCTestCase {
    func testSocketTextChunksReturnsSingleChunkForPlainText() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("echo hello"),
            [.text("echo hello")]
        )
    }

    func testSocketTextChunksSplitsControlScalars() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("abc\rdef\tghi"),
            [
                .text("abc"),
                .control("\r".unicodeScalars.first!),
                .text("def"),
                .control("\t".unicodeScalars.first!),
                .text("ghi")
            ]
        )
    }

    func testSocketTextChunksDoesNotEmitEmptyTextChunksAroundConsecutiveControls() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("\r\n\t"),
            [
                .control("\r".unicodeScalars.first!),
                .control("\n".unicodeScalars.first!),
                .control("\t".unicodeScalars.first!)
            ]
        )
    }
}


final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
    func testImmediateStateUpdateAllowedWhenHostNotInWindow() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenBoundToCurrentHost() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    func testImmediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    func testInteractiveGeometryResizeUsesImmediatePortalSyncDecision() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldSynchronizePortalGeometryImmediately(
                hostInLiveResize: false,
                windowInLiveResize: false,
                interactiveGeometryResizeActive: true
            ),
            "Interactive resize should use the immediate portal sync path"
        )
    }
}


final class TerminalControllerSocketListenerHealthTests: XCTestCase {
    func testStableSocketBindPermissionFailureFallsBackToUserScopedSocket() {
        XCTAssertEqual(
            TerminalController.fallbackSocketPathAfterBindFailure(
                requestedPath: SocketControlSettings.stableDefaultSocketPath,
                stage: "bind",
                errnoCode: EACCES,
                currentUserID: 501
            ),
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        )
    }

    func testNonStableSocketBindFailureDoesNotFallback() {
        XCTAssertNil(
            TerminalController.fallbackSocketPathAfterBindFailure(
                requestedPath: "/tmp/cmux-debug.sock",
                stage: "bind",
                errnoCode: EACCES,
                currentUserID: 501
            )
        )
    }

    private func makeTempSocketPath() -> String {
        "/tmp/cmux-socket-health-\(UUID().uuidString).sock"
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(pathBuf, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }

    private func acceptSingleClient(
        on listenerFD: Int32,
        handler: @escaping (_ clientFD: Int32) -> Void
    ) -> XCTestExpectation {
        let handled = expectation(description: "socket client handled")
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.fulfill()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.fulfill()
            }
            handler(clientFD)
        }
        return handled
    }

    @MainActor
    func testSocketListenerHealthRecognizesSocketPath() throws {
        let path = makeTempSocketPath()
        let fd = try bindUnixSocket(at: path)
        defer {
            Darwin.close(fd)
            unlink(path)
        }

        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        XCTAssertTrue(health.socketPathExists)
        XCTAssertFalse(health.isHealthy)
    }

    @MainActor
    func testSocketListenerHealthRejectsRegularFile() throws {
        let path = makeTempSocketPath()
        let url = URL(fileURLWithPath: path)
        try "not-a-socket".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        XCTAssertFalse(health.socketPathExists)
        XCTAssertFalse(health.isHealthy)
    }

    func testProbeSocketCommandReturnsFirstLineResponse() throws {
        let path = makeTempSocketPath()
        let listenerFD = try bindUnixSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let handled = acceptSingleClient(on: listenerFD) { clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &buffer, buffer.count)
            let response = "PONG\nextra\n"
            _ = response.withCString { ptr in
                write(clientFD, ptr, strlen(ptr))
            }
        }

        let response = TerminalController.probeSocketCommand("ping", at: path, timeout: 0.5)

        XCTAssertEqual(response, "PONG")
        wait(for: [handled], timeout: 5.0)
    }

    func testProbeSocketCommandTimesOutWithoutPollingUntilServerResponds() throws {
        let path = makeTempSocketPath()
        let listenerFD = try bindUnixSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let releaseServer = DispatchSemaphore(value: 0)
        let handled = acceptSingleClient(on: listenerFD) { clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &buffer, buffer.count)
            _ = releaseServer.wait(timeout: .now() + 1.0)
        }

        let startedAt = Date()
        let response = TerminalController.probeSocketCommand("ping", at: path, timeout: 0.2)
        let elapsed = Date().timeIntervalSince(startedAt)
        releaseServer.signal()

        XCTAssertNil(response)
        XCTAssertGreaterThanOrEqual(elapsed, 0.18)
        XCTAssertLessThan(elapsed, 0.8)
        wait(for: [handled], timeout: 5.0)
    }

    func testSocketListenerHealthFailureSignalsAreEmptyWhenHealthy() {
        let health = TerminalController.SocketListenerHealth(
            isRunning: true,
            acceptLoopAlive: true,
            socketPathMatches: true,
            socketPathExists: true
        )
        XCTAssertTrue(health.isHealthy)
        XCTAssertTrue(health.failureSignals.isEmpty)
    }

    func testSocketListenerHealthFailureSignalsIncludeAllDetectedProblems() {
        let health = TerminalController.SocketListenerHealth(
            isRunning: false,
            acceptLoopAlive: false,
            socketPathMatches: false,
            socketPathExists: false
        )
        XCTAssertFalse(health.isHealthy)
        XCTAssertEqual(
            health.failureSignals,
            ["not_running", "accept_loop_dead", "socket_path_mismatch", "socket_missing"]
        )
    }
}

/// The mailbox push's submit reports whether its Return went out, so the push
/// can undo its inbox claim instead of marking undelivered mail delivered.
@MainActor
final class TerminalSurfaceMailboxSubmitTests: XCTestCase {
    func testSubmitReportsFalseForUnattachedSurfaceWithoutQueueing() {
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        XCTAssertNil(surface.surface)
        var reported: [Bool] = []
        surface.sendSubmitFormText("<c11-msg>hi</c11-msg>") { reported.append($0) }
        XCTAssertEqual(reported, [false], "an unattached surface must refuse at once, not queue for attach")
    }

    func testSubmitReportsFalseForEmptyText() {
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        var reported: [Bool] = []
        surface.sendSubmitFormText("\n\n") { reported.append($0) }
        XCTAssertEqual(reported, [false])
    }

    /// An attached surface whose recipient re-check says no at Return time:
    /// the paste is not submitted and the completion reports `false`, so the
    /// push undoes its claim. The check runs after the paste-settle delay.
    func testAttachedSurfaceWithholdsReturnWhenRecheckFails() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            return XCTFail("Expected content view")
        }
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostedView.reconcileGeometryNow()
        guard surface.surface != nil else {
            throw XCTSkip("terminal surface did not attach in this host")
        }

        var checks = 0
        var reported: [Bool] = []
        let done = expectation(description: "completion")
        surface.sendSubmitFormText(
            "<c11-msg>hi</c11-msg>",
            shouldSubmit: { checks += 1; return false }
        ) { dispatched in
            reported.append(dispatched)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(checks, 1, "the re-check runs once, just before the Return")
        XCTAssertEqual(reported, [false])

        var passReported: [Bool] = []
        let passed = expectation(description: "completion when the re-check passes")
        surface.sendSubmitFormText("<c11-msg>ok</c11-msg>", shouldSubmit: { true }) { dispatched in
            passReported.append(dispatched)
            passed.fulfill()
        }
        wait(for: [passed], timeout: 2)
        XCTAssertEqual(passReported, [true])
    }
}

/// One programmatic input transaction at a time per tab. A writer between its
/// paste and its Return owns the input line; every other programmatic writer
/// waits its turn, and the mailbox push never starts inside it.
@MainActor
final class TerminalSurfaceInputTransactionTests: XCTestCase {
    private func makeSurface() -> TerminalSurface {
        TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
    }

    func testTransactionsRunOneAtATimeInOrder() {
        let surface = makeSurface()
        var log: [String] = []
        var finishA: (() -> Void)?
        surface.performInputTransaction { finish in log.append("A start"); finishA = finish }
        XCTAssertTrue(surface.isInputTransactionActive)
        let epochA = surface.inputTransactionEpoch
        surface.performInputTransaction { finish in log.append("B"); finish() }
        surface.performInputTransaction { finish in log.append("C"); finish() }
        XCTAssertEqual(log, ["A start"], "B and C wait while A is between its paste and its Return")
        finishA?()
        XCTAssertEqual(log, ["A start", "B", "C"])
        XCTAssertFalse(surface.isInputTransactionActive)
        XCTAssertEqual(surface.inputTransactionEpoch, epochA + 2)
    }

    /// The mailbox push only ever takes an idle slot.
    func testTryInputTransactionRefusesWhileBusy() {
        let surface = makeSurface()
        var finishA: (() -> Void)?
        surface.performInputTransaction { finish in finishA = finish }
        var ran = false
        XCTAssertFalse(surface.tryInputTransaction { finish in ran = true; finish() })
        XCTAssertFalse(ran)
        finishA?()
        XCTAssertTrue(surface.tryInputTransaction { finish in ran = true; finish() })
        XCTAssertTrue(ran)
    }

    /// An out-of-band write (AppleScript, drag and drop, a key from the text
    /// box) during another writer's transaction runs after it, not inside it.
    func testOutOfBandWritesWaitForTheTransactionInFlight() {
        let surface = makeSurface()
        var log: [String] = []
        var finishA: (() -> Void)?
        surface.performInputTransaction { finish in log.append("A"); finishA = finish }
        surface.writeOrDefer { log.append("out-of-band") }
        XCTAssertEqual(log, ["A"])
        finishA?()
        XCTAssertEqual(log, ["A", "out-of-band"])
        // With the slot idle, the same write runs at once.
        surface.writeOrDefer { log.append("idle write") }
        XCTAssertEqual(log, ["A", "out-of-band", "idle write"])
    }

    /// A transaction that never finishes cannot wedge the tab's input.
    func testWatchdogReleasesAStuckTransaction() {
        let surface = makeSurface()
        surface.performInputTransaction { _ in }
        let next = expectation(description: "queued transaction runs after the watchdog")
        surface.performInputTransaction { finish in finish(); next.fulfill() }
        wait(for: [next], timeout: TerminalSurface.inputTransactionWatchdog + 2)
        XCTAssertFalse(surface.isInputTransactionActive)
    }

    /// A text-box or `c11 send` submit is in flight: the mailbox push refuses
    /// at once (no paste into the shared input line) and reports `false`, so
    /// the push requeues and the mail becomes its own later turn.
    func testMailboxPushNeverStartsInsideAnotherSubmit() {
        let surface = makeSurface()
        var finishSubmit: (() -> Void)?
        surface.performInputTransaction { finish in finishSubmit = finish }
        var reported: [Bool] = []
        var rechecks = 0
        surface.sendSubmitFormText("<c11-msg>mail</c11-msg>", shouldSubmit: { rechecks += 1; return true }) {
            reported.append($0)
        }
        XCTAssertEqual(reported, [false])
        XCTAssertEqual(rechecks, 0, "nothing was pasted, so nothing to re-check")
        finishSubmit?()
        XCTAssertFalse(surface.isInputTransactionActive)
    }

    /// Programmatic text left without a newline is a draft; a submitted line
    /// is not.
    func testProgrammaticTextWithoutNewlineMarksADraft() {
        let surface = makeSurface()
        XCTAssertNil(surface.lastOperatorKeyAt)
        surface.sendText("ls\n")
        XCTAssertNil(surface.lastOperatorKeyAt)
        surface.sendText("half a line")
        XCTAssertNotNil(surface.lastOperatorKeyAt)
        let stamped = surface.lastOperatorKeyAt
        surface.writeProgrammaticText("<c11-msg/>", marksDraft: false)
        XCTAssertEqual(surface.lastOperatorKeyAt, stamped, "the push's own paste is not a draft")
    }

    /// Binding actions that write into the input line join the slot; the
    /// rest (scrolling, search, copy) do not.
    func testBindingActionsThatWriteInputAreProgrammaticWriters() {
        for action in ["text:hello", "csi:A", "esc:d", "paste_from_clipboard", "paste_from_selection"] {
            XCTAssertTrue(TerminalSurface.bindingActionWritesInput(action), action)
        }
        for action in ["copy_to_clipboard", "scroll_page_lines:3", "search:needle", "end_search"] {
            XCTAssertFalse(TerminalSurface.bindingActionWritesInput(action), action)
        }
    }
}

/// B087: reading a never-presented terminal is itself a runtime demand.
@MainActor
final class ColdTerminalReadTests: XCTestCase {
    func testReadStartsNeverPresentedTerminalWithoutChangingSelection() async throws {
        let controller = TerminalController.shared
        let originalManager = controller.workspaceManager
        let manager = WorkspaceManager()
        controller.workspaceManager = manager
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let selectedTab = workspace.focusedPanelId
        let terminal = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        defer {
            _ = workspace.closeTab(terminal.id, force: true)
            controller.workspaceManager = originalManager
        }
        XCTAssertNil(terminal.surface.surface, "Fixture must begin cold, before any read or send")
        XCTAssertNil(terminal.hostedView.window, "Fixture must never have been presented")

        let workspaceID = workspace.id.uuidString
        let tabID = terminal.id.uuidString
        let result = await Task.detached {
            controller.v2SurfaceReadText(params: ["workspace_id": workspaceID, "surface_id": tabID])
        }.value

        guard case .ok(let value) = result, let payload = value as? [String: Any] else {
            return XCTFail("Cold read failed: \(result)")
        }
        XCTAssertNotNil(terminal.surface.surface)
        XCTAssertEqual(payload["surface_id"] as? String, tabID)
        XCTAssertNotNil(payload["text"] as? String) // The shell may not have printed yet.
        XCTAssertEqual(workspace.focusedPanelId, selectedTab)
        XCTAssertEqual(manager.selectedWorkspaceId, workspace.id)
    }

    func testReadRejectsWorkspaceRemovedWhileColdRuntimeBecomesReady() async throws {
        let controller = TerminalController.shared
        let originalManager = controller.workspaceManager
        let manager = WorkspaceManager()
        controller.workspaceManager = manager
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminal = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        XCTAssertNil(terminal.surface.surface)
        // The notification fires after target resolution and before the final
        // read hop. Keep the runtime alive to catch a stale-object read too.
        let observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: terminal.surface,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { manager.workspaces.removeAll { $0 === workspace } }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            _ = workspace.closeTab(terminal.id, force: true)
            controller.workspaceManager = originalManager
        }
        let workspaceID = workspace.id.uuidString
        let tabID = terminal.id.uuidString
        let result = await Task.detached {
            controller.v2SurfaceReadText(params: ["workspace_id": workspaceID, "surface_id": tabID])
        }.value
        XCTAssertFalse(manager.workspaces.contains { $0 === workspace }, "Read must request cold startup")
        guard case .err(let code, _, _) = result else {
            return XCTFail("Read succeeded for a workspace removed during startup")
        }
        XCTAssertEqual(code, "not_found")
    }
}

final class GhosttyCallbackCoalescerTests: XCTestCase {
    /// Records actual scheduled closures, without running them until a test
    /// admits a turn. Never hold the scheduler lock while executing user code.
    private final class Scheduler {
        private let lock = NSLock()
        private var jobs: [() -> Void] = []
        private var enqueued = 0

        func enqueue(_ job: @escaping () -> Void) {
            lock.lock()
            jobs.append(job)
            enqueued += 1
            lock.unlock()
        }

        var scheduledCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return enqueued
        }

        var pendingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return jobs.count
        }

        @discardableResult
        func runNext() -> Bool {
            lock.lock()
            let job = jobs.isEmpty ? nil : jobs.removeFirst()
            lock.unlock()
            guard let job else { return false }
            job()
            return true
        }
    }

    private final class Values<Element> {
        private let lock = NSLock()
        private var storage: [Element] = []

        func append(_ value: Element) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var snapshot: [Element] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testConcurrentBurstSchedulesOneClosureAndAppliesLatestPayload() {
        let scheduler = Scheduler()
        let coalescer = GhosttyCallbackCoalescer<Int>(schedule: scheduler.enqueue)
        let received = Values<Int>()

        DispatchQueue.concurrentPerform(iterations: 256) { value in
            coalescer.submit(value, apply: received.append)
        }
        // concurrentPerform has joined every producer; this is unambiguously
        // the final request, regardless of the order of the concurrent burst.
        coalescer.submit(-1, apply: received.append)

        XCTAssertEqual(scheduler.scheduledCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(received.snapshot, [])
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(received.snapshot, [-1])
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertFalse(scheduler.runNext())
        XCTAssertEqual(scheduler.scheduledCount, 1)
#if DEBUG
        let stats = coalescer.debugStats()
        XCTAssertEqual(stats.requests, 257)
        XCTAssertEqual(stats.enqueued, 1)
        XCTAssertEqual(stats.drained, 1)
        XCTAssertEqual(stats.pending, 0)
        XCTAssertEqual(stats.maxPending, 1)
#endif
    }

    func testRequestsDuringApplyProduceOneSuccessorWithLatestPayload() {
        let scheduler = Scheduler()
        let coalescer = GhosttyCallbackCoalescer<Int>(schedule: scheduler.enqueue)
        let received = Values<Int>()
        coalescer.submit(1) { value in
            received.append(value)
            coalescer.submit(2, apply: received.append)
            coalescer.submit(3, apply: received.append)
        }

        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(received.snapshot, [1])
        XCTAssertEqual(scheduler.scheduledCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(received.snapshot, [1, 3])
        XCTAssertEqual(scheduler.scheduledCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testBoundedBatchesReachFinalSentinelWithoutAnotherExternalRequest() {
        let scheduler = Scheduler()
        let coalescer = GhosttyCallbackCoalescer<Void>(schedule: scheduler.enqueue)
        let expected = Array(0..<70) + [-999]
        let batchLimit = 8
        let expectedTurns = (expected.count + batchLimit - 1) / batchLimit
        var remaining = expected[...]
        var consumed: [Int] = []
        var batchSizes: [Int] = []

        func drainBatch(_: Void) {
            let batch = remaining.prefix(batchLimit)
            consumed.append(contentsOf: batch)
            batchSizes.append(batch.count)
            remaining = remaining.dropFirst(batch.count)
            if !remaining.isEmpty {
                // Model the native bounded drain waking Swift before this
                // apply returns. Several wakeups must admit only one turn.
                for _ in 0..<16 {
                    coalescer.submit((), apply: drainBatch)
                }
            }
        }

        coalescer.submit((), apply: drainBatch) // The only external request.
        for _ in 0..<expectedTurns {
            XCTAssertEqual(scheduler.pendingCount, 1)
            XCTAssertTrue(scheduler.runNext())
        }
        XCTAssertEqual(consumed, expected)
        XCTAssertEqual(consumed.last, -999)
        XCTAssertEqual(batchSizes.count, expectedTurns)
        XCTAssertTrue(batchSizes.allSatisfy { $0 > 0 && $0 <= batchLimit })
        XCTAssertEqual(scheduler.scheduledCount, expectedTurns)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertFalse(scheduler.runNext())
    }

    func testTwoInstancesRetainIndependentFinalValues() {
        let scheduler = Scheduler()
        let first = GhosttyCallbackCoalescer<Int>(schedule: scheduler.enqueue)
        let second = GhosttyCallbackCoalescer<Int>(schedule: scheduler.enqueue)
        let firstValues = Values<Int>()
        let secondValues = Values<Int>()
        for value in 0..<128 {
            first.submit(value, apply: firstValues.append)
            second.submit(-value, apply: secondValues.append)
        }
        first.submit(1001, apply: firstValues.append)
        second.submit(-2002, apply: secondValues.append)

        XCTAssertEqual(scheduler.scheduledCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 2)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(firstValues.snapshot, [1001])
        XCTAssertEqual(secondValues.snapshot, [-2002])
        XCTAssertEqual(scheduler.pendingCount, 0)

        first.submit(3003, apply: firstValues.append)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(firstValues.snapshot, [1001, 3003])
        XCTAssertEqual(secondValues.snapshot, [-2002])
        XCTAssertEqual(scheduler.scheduledCount, 3)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testProducerDuringFlushRetainsLatestSuccessor() {
        let scheduler = Scheduler()
        let coalescer = GhosttyCallbackCoalescer<Int>(schedule: scheduler.enqueue)
        let received = Values<Int>()
        let waitResults = Values<DispatchTimeoutResult>()
        let runResults = Values<Bool>()
        let enteredApply = DispatchSemaphore(value: 0)
        let releaseApply = DispatchSemaphore(value: 0)
        let flush = DispatchGroup()

        coalescer.submit(0) { value in
            received.append(value)
            enteredApply.signal()
            waitResults.append(releaseApply.wait(timeout: .now() + 5))
        }
        flush.enter()
        DispatchQueue.global().async {
            runResults.append(scheduler.runNext())
            flush.leave()
        }
        defer {
            releaseApply.signal()
            XCTAssertEqual(flush.wait(timeout: .now() + 5), .success)
        }
        guard enteredApply.wait(timeout: .now() + 5) == .success else {
            return XCTFail("Scheduled flush never entered apply")
        }

        // The flushing worker is held inside apply. This producer can publish
        // a successor before that worker returns, without a race or a sleep.
        for value in 1...128 {
            coalescer.submit(value, apply: received.append)
        }
        coalescer.submit(999, apply: received.append)
        XCTAssertEqual(received.snapshot, [0])
        XCTAssertEqual(scheduler.scheduledCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)
        releaseApply.signal()
        guard flush.wait(timeout: .now() + 5) == .success else {
            return XCTFail("Flushing worker did not finish after release")
        }

        XCTAssertEqual(runResults.snapshot, [true])
        XCTAssertEqual(waitResults.snapshot, [.success])
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(received.snapshot, [0, 999])
        XCTAssertEqual(scheduler.scheduledCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDefaultSchedulerAppliesOnMainForWorkerRequest() async {
        let coalescer = GhosttyCallbackCoalescer<Int>()
        let applied = expectation(description: "Default scheduler applies on main")
        let requestThreads = Values<Bool>()
        let applyThreads = Values<Bool>()
        let received = Values<Int>()
        DispatchQueue.global().async {
            requestThreads.append(Thread.isMainThread)
            coalescer.submit(42) { value in
                applyThreads.append(Thread.isMainThread)
                received.append(value)
                applied.fulfill()
            }
        }

        await fulfillment(of: [applied], timeout: 5)
        XCTAssertEqual(requestThreads.snapshot, [false])
        XCTAssertEqual(applyThreads.snapshot, [true])
        XCTAssertEqual(received.snapshot, [42])
    }
}

#if DEBUG
@MainActor
final class GhosttySurfaceCallbackContextTests: XCTestCase {
    /// A real native surface in a hidden window. Mounting synchronously creates
    /// the runtime; these tests never activate or show a window.
    private func makeSurface() throws -> (NSWindow, TerminalSurface) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let contentView = try XCTUnwrap(window.contentView)
        surface.hostedView.frame = contentView.bounds
        contentView.addSubview(surface.hostedView)
        _ = try XCTUnwrap(surface.surface, "Mounting must create a real native surface")
        return (window, surface)
    }

    private func passMainQueueTurn() async {
        let marker = expectation(description: "Previously queued callbacks have run")
        DispatchQueue.main.async { marker.fulfill() }
        await fulfillment(of: [marker], timeout: 5)
    }

    func testQueuedScrollbarCallbackDoesNotNotifyAfterRuntimeRelease() async throws {
        let (window, surface) = try makeSurface()
        defer {
            surface.releaseSurfaceForTesting()
            window.orderOut(nil)
        }
        let oldContext = try XCTUnwrap(surface.debugCallbackContext)
        let view = try XCTUnwrap(oldContext.surfaceView)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar, object: view, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        oldContext.enqueueScrollbarUpdate(GhosttyScrollbar(c: .init(total: 100, offset: 37, len: 10)))
        surface.releaseSurfaceForTesting()
        XCTAssertNil(surface.surface)
        XCTAssertNil(surface.debugCallbackContext)
        let previousOffset = view.scrollbar?.offset
        await passMainQueueTurn()

        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(view.scrollbar?.offset, previousOffset)
        XCTAssertTrue(oldContext.surfaceView === view, "Keep the stale context alive through delivery")
    }

    func testRecreatedRuntimeRejectsOldContextAndAppliesNewContextToSameView() async throws {
        let (window, surface) = try makeSurface()
        defer {
            surface.releaseSurfaceForTesting()
            window.orderOut(nil)
        }
        let oldContext = try XCTUnwrap(surface.debugCallbackContext)
        let view = try XCTUnwrap(oldContext.surfaceView)
        let staleOffset: UInt64 = 999_937
        var staleScrollbarNotifications = 0
        var notifiedCellSizes: [CGSize] = []
        let scrollbarObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar, object: view, queue: nil
        ) { notification in
            if let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar,
               scrollbar.offset == staleOffset {
                staleScrollbarNotifications += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(scrollbarObserver) }
        oldContext.enqueueScrollbarUpdate(
            GhosttyScrollbar(c: .init(total: 1_000_000, offset: staleOffset, len: 10))
        )
        surface.releaseSurfaceForTesting()
        surface.attachToView(view)
        _ = try XCTUnwrap(surface.surface, "Explicit same-view attachment must recreate the runtime")
        let newContext = try XCTUnwrap(surface.debugCallbackContext)
        XCTAssertFalse(oldContext === newContext)
        XCTAssertTrue(newContext.surfaceView === view)

        let cellObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize, object: view, queue: nil
        ) { notification in
            if let size = notification.userInfo?[GhosttyNotificationKey.cellSize] as? CGSize {
                notifiedCellSizes.append(size)
            }
        }
        defer { NotificationCenter.default.removeObserver(cellObserver) }
        let currentSize = CGSize(width: 19, height: 29)
        newContext.updateCellSize(currentSize)
        oldContext.updateCellSize(CGSize(width: 97, height: 101))
        XCTAssertEqual(view.cellSize, currentSize)
        XCTAssertEqual(notifiedCellSizes, [currentSize])

        await passMainQueueTurn()
        XCTAssertEqual(staleScrollbarNotifications, 0)
        XCTAssertTrue(oldContext.surfaceView === newContext.surfaceView)
    }

    func testInitialCellSizeIsDeliveredBeforeNativeCreationReturns() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let surface = TerminalSurface(
            workspaceId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        defer {
            surface.releaseSurfaceForTesting()
            window.orderOut(nil)
        }
        XCTAssertNil(surface.surface)
        var initialSizes: [CGSize] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize, object: nil, queue: nil
        ) { notification in
            guard let view = notification.object as? GhosttyNSView,
                  view.terminalSurface === surface,
                  surface.surface == nil,
                  let size = notification.userInfo?[GhosttyNotificationKey.cellSize] as? CGSize else { return }
            XCTAssertTrue(Thread.isMainThread)
            initialSizes.append(size)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let contentView = try XCTUnwrap(window.contentView)
        surface.hostedView.frame = contentView.bounds
        contentView.addSubview(surface.hostedView)
        _ = try XCTUnwrap(surface.surface, "Mounting must create a real native surface")
        let view = try XCTUnwrap(surface.debugCallbackContext?.surfaceView)
        // No run-loop turn has occurred. The initializer's callback must already
        // have published dimensions while Swift's native handle was still nil.
        XCTAssertFalse(initialSizes.isEmpty)
        XCTAssertTrue(initialSizes.allSatisfy { $0.width > 0 && $0.height > 0 })
        XCTAssertGreaterThan(view.cellSize.width, 0)
        XCTAssertGreaterThan(view.cellSize.height, 0)
    }
}
#endif
