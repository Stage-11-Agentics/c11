import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class MarkdownPanelFontScaleTests: XCTestCase {
    private let lastUsedDefaultsKey = "markdown.fontScale.lastUsed"
    private var savedLastUsed: Any?

    override func setUp() async throws {
        savedLastUsed = UserDefaults.standard.object(forKey: lastUsedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: lastUsedDefaultsKey)
    }

    override func tearDown() async throws {
        if let savedLastUsed {
            UserDefaults.standard.set(savedLastUsed, forKey: lastUsedDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastUsedDefaultsKey)
        }
    }

    // MARK: - Scale normalization

    func testNormalizedFontScaleClampsToRange() {
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(0.1), MarkdownPanel.fontScaleRange.lowerBound)
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(10.0), MarkdownPanel.fontScaleRange.upperBound)
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(1.0), 1.0)
    }

    func testNormalizedFontScaleRoundsToOneStep() {
        // Repeated float additions like 1.0 + 0.1 + 0.1 drift; the normalizer
        // must land on exact tenths so equality short-circuits work.
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(1.0 + 0.1 + 0.1), 1.2)
        XCTAssertEqual(MarkdownPanel.normalizedFontScale(0.9999999), 1.0)
    }

    // MARK: - Zoom stepping on a live panel

    func testZoomInOutAndResetStepTheScale() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }

        XCTAssertEqual(panel.fontScale, 1.0)
        panel.zoomIn()
        XCTAssertEqual(panel.fontScale, 1.1)
        panel.zoomIn()
        XCTAssertEqual(panel.fontScale, 1.2)
        panel.zoomOut()
        XCTAssertEqual(panel.fontScale, 1.1)
        panel.resetZoom()
        XCTAssertEqual(panel.fontScale, 1.0)
    }

    func testZoomOutClampsAtLowerBound() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }

        for _ in 0..<100 { panel.zoomOut() }
        XCTAssertEqual(panel.fontScale, MarkdownPanel.fontScaleRange.lowerBound)
        for _ in 0..<100 { panel.zoomIn() }
        XCTAssertEqual(panel.fontScale, MarkdownPanel.fontScaleRange.upperBound)
    }

    func testNewPanelsInheritLastUsedScale() {
        let first = MarkdownPanel(workspaceId: UUID())
        first.zoomIn()
        first.zoomIn()
        XCTAssertEqual(first.fontScale, 1.2)
        first.close()

        let second = MarkdownPanel(workspaceId: UUID())
        defer { second.close() }
        XCTAssertEqual(second.fontScale, 1.2)
    }

    func testApplyRestoredFontScaleDoesNotChangeLastUsedDefault() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }

        panel.applyRestoredFontScale(2.0)
        XCTAssertEqual(panel.fontScale, 2.0)

        let next = MarkdownPanel(workspaceId: UUID())
        defer { next.close() }
        XCTAssertEqual(next.fontScale, 1.0, "restore must not leak into the new-panel default")
    }

    func testRestoredInvalidScaleFallsBackRatherThanClamping() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }
        for value in [0.1, 10, Double.nan, Double.infinity] {
            panel.applyRestoredFontScale(value)
            XCTAssertEqual(panel.fontScale, 1.0)
        }
        XCTAssertNil(panel.renderer, "hidden model never creates a web view")
    }
}

@MainActor
private final class StubMarkdownPanelReaderRenderer: MarkdownPanelReaderCommanding {
    var readerOutlineIsOpen = false
    private(set) var synchronizeCount = 0
    private(set) var commands: [String] = []
    private(set) var findFocusRequests: [Bool] = []

    func synchronize() { synchronizeCount += 1 }
    func call(_ method: String) { commands.append(method) }
    func openFind(focusAllowed: Bool) {
        findFocusRequests.append(focusAllowed)
        commands.append("openFind")
    }
}

@MainActor
final class MarkdownReaderInteractionTests: XCTestCase {
    private let outlineDefaultsKey = MarkdownPresentation.Field.outlineOpen.defaultsKey
    private let outlineShortcut = KeyboardShortcutSettings.Action.toggleMarkdownOutline
    private var savedOutlineChoice: Any?
    private var savedOutlineShortcut: Any?

    override func setUp() async throws {
        savedOutlineChoice = UserDefaults.standard.object(forKey: outlineDefaultsKey)
        savedOutlineShortcut = UserDefaults.standard.object(forKey: outlineShortcut.defaultsKey)
        UserDefaults.standard.removeObject(forKey: outlineDefaultsKey)
        KeyboardShortcutSettings.resetShortcut(for: outlineShortcut)
    }

    override func tearDown() async throws {
        restore(savedOutlineChoice, key: outlineDefaultsKey)
        restore(savedOutlineShortcut, key: outlineShortcut.defaultsKey)
    }

    func testTogglePersistsExplicitChoiceAndSynchronizesStubRenderer() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }
        let renderer = StubMarkdownPanelReaderRenderer()
        renderer.readerOutlineIsOpen = true
        panel.readerCommandRendererForTesting = renderer

        panel.toggleOutline()
        XCTAssertEqual(panel.outlineOpen, false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: outlineDefaultsKey) as? Bool, false)
        XCTAssertEqual(renderer.synchronizeCount, 1)

        panel.toggleOutline()
        XCTAssertEqual(panel.outlineOpen, true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: outlineDefaultsKey) as? Bool, true)
        XCTAssertEqual(renderer.synchronizeCount, 2)
    }

    func testNativeEscapeFallbackRunsOnlyAfterPageLeavesEscapeUnhandled() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.applyRestoredPresentation(SessionMarkdownPanelSnapshot(outlineOpen: true))
        let renderer = StubMarkdownPanelReaderRenderer()
        renderer.readerOutlineIsOpen = true
        panel.readerCommandRendererForTesting = renderer

        XCTAssertFalse(panel.dismissReaderOverlay(pageConsumedEscape: true))
        XCTAssertEqual(panel.outlineOpen, true)
        XCTAssertEqual(renderer.synchronizeCount, 0)

        XCTAssertTrue(panel.dismissReaderOverlay(pageConsumedEscape: false))
        XCTAssertEqual(panel.outlineOpen, false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: outlineDefaultsKey) as? Bool, false)
        XCTAssertEqual(renderer.synchronizeCount, 1)
    }

    func testFindRequestKeepsWebViewFocusSubjectToPanelPolicy() {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }
        let renderer = StubMarkdownPanelReaderRenderer()
        panel.readerCommandRendererForTesting = renderer

        panel.requestFind()

        XCTAssertEqual(renderer.findFocusRequests, [false])
        XCTAssertEqual(renderer.commands, ["openFind"])
    }

    func testOutlineShortcutRoutesThroughCustomizedRegistryToPanelAndStubRenderer() throws {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }
        let renderer = StubMarkdownPanelReaderRenderer()
        panel.readerCommandRendererForTesting = renderer
        let custom = StoredShortcut(key: "j", command: true, shift: false, option: false, control: false)
        KeyboardShortcutSettings.setShortcut(custom, for: outlineShortcut)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "j",
            charactersIgnoringModifiers: "j",
            isARepeat: false,
            keyCode: 38
        ))
        var routedShortcut: StoredShortcut?
        let handled = MarkdownReaderShortcutRouter.routeOutlineToggle(
            event: event,
            panel: panel
        ) { event, shortcut in
            routedShortcut = shortcut
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            return flags == shortcut.modifierFlags
                && event.charactersIgnoringModifiers?.lowercased() == shortcut.key.lowercased()
        }

        XCTAssertTrue(handled)
        XCTAssertEqual(routedShortcut, custom)
        XCTAssertEqual(panel.outlineOpen, true)
        XCTAssertEqual(renderer.synchronizeCount, 1)
    }

    private func restore(_ value: Any?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
