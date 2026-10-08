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

    func testUnsupportedThemeAndTypefaceAreRejectedWithoutChangingTheModel() {
        let defaults = UserDefaults.standard
        let keys = ["markdown.theme.lastUsed", "markdown.typeface.lastUsed"]
        var savedDefaults: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { savedDefaults[key] = value }
        }
        defer {
            for key in keys {
                if let value = savedDefaults[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("system", forKey: "markdown.theme.lastUsed")
        defaults.set("theme", forKey: "markdown.typeface.lastUsed")
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }

        XCTAssertFalse(panel.setTheme("sepia"))
        XCTAssertFalse(panel.setTypeface("comic"))
        XCTAssertEqual(panel.theme, "system")
        XCTAssertEqual(panel.typeface, "theme")
        XCTAssertNil(panel.renderer, "presentation validation stays model-only")
    }

    func testPresentationChangesReachWatchersWhileReaderIsEvicted() throws {
        let panel = MarkdownPanel(workspaceId: UUID())
        defer { panel.close() }
        var snapshots: [[String: Any]] = []
        let observation = panel.observeReaderEvents { event in
            if case .state(let state) = event { snapshots.append(state) }
        }
        defer { panel.removeReaderObserver(observation) }

        panel.publishRendererState([
            "file": "guide.md",
            "pane": ["width": 720, "effectiveWidth": 720],
            "theme": ["choice": "system", "resolved": "light"],
            "typeface": ["choice": "theme", "resolved": "sans"],
            "font_scale": 1.0,
            "outline": ["open": false]
        ])
        XCTAssertTrue(panel.setTheme("dark"))
        XCTAssertTrue(panel.setTypeface("mono"))
        XCTAssertTrue(panel.setFontScale(1.4))

        let latest = try XCTUnwrap(snapshots.last)
        XCTAssertEqual((latest["theme"] as? [String: Any])?["choice"] as? String, "dark")
        XCTAssertEqual((latest["typeface"] as? [String: Any])?["choice"] as? String, "mono")
        XCTAssertEqual(latest["font_scale"] as? Double, 1.4)
        XCTAssertNil(panel.renderer, "watch events must not create or pin a reader")
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

final class MarkdownVisibleStateBufferTests: XCTestCase {
    func testInitialSnapshotIncludesReaderFieldsWithoutTheOutlineTree() {
        let buffer = MarkdownVisibleStateBuffer()
        buffer.begin(with: state(progress: 0.25, firstLine: 8, selection: "selected"))

        let snapshot = buffer.next()
        XCTAssertEqual(snapshot?["heading_path"] as? [String], ["Guide", "Install"])
        XCTAssertEqual((snapshot?["lines"] as? [String: Any])?["first"] as? Int, 8)
        XCTAssertEqual(snapshot?["progress"] as? Double, 0.25)
        XCTAssertEqual(snapshot?["size"] as? String, "medium")
        XCTAssertEqual(snapshot?["selection"] as? String, "selected")
        XCTAssertNil(snapshot?["outline"])
    }

    func testWatchDeduplicatesAndBoundsQueuedChangesToLatestState() {
        let buffer = MarkdownVisibleStateBuffer()
        let initial = state(progress: 0.1, firstLine: 1)
        buffer.begin(with: initial)
        buffer.publish(initial)
        buffer.publish(state(progress: 0.2, firstLine: 2))
        buffer.publish(state(progress: 0.3, firstLine: 3))

        XCTAssertEqual(buffer.next()?["progress"] as? Double, 0.1)
        XCTAssertEqual(buffer.next()?["progress"] as? Double, 0.3)
        buffer.finish()
        XCTAssertNil(buffer.next())
    }

    func testFinishingWakesAnEventWaiter() {
        let buffer = MarkdownVisibleStateBuffer()
        buffer.begin(with: state(progress: 0.1, firstLine: 1))
        let initialConsumed = expectation(description: "initial snapshot consumed")
        let waiterParked = expectation(description: "next-state waiter parked")
        let finished = expectation(description: "watch waiter released")
        DispatchQueue.global(qos: .userInitiated).async {
            var signaledWaiterParked = false
            XCTAssertNotNil(buffer.next())
            initialConsumed.fulfill()
            XCTAssertNil(buffer.next(onWaiting: {
                guard !signaledWaiterParked else { return }
                signaledWaiterParked = true
                waiterParked.fulfill()
            }))
            finished.fulfill()
        }

        wait(for: [initialConsumed, waiterParked], timeout: 2)
        buffer.finish()
        wait(for: [finished], timeout: 2)
    }

    private func state(progress: Double, firstLine: Int, selection: String? = nil) -> [String: Any] {
        [
            "file": "guide.md",
            "heading_path": ["Guide", "Install"],
            "lines": ["first": firstLine, "last": firstLine + 4, "total": 40, "offset": 5.0],
            "progress": progress,
            "minutes_left": 2,
            "pane": ["width": 700, "effectiveWidth": 700, "size": "medium"],
            "theme": ["choice": "system", "resolved": "light"],
            "typeface": ["choice": "theme", "resolved": "sans"],
            "font_scale": 1.2,
            "find": NSNull(),
            "selection": selection as Any? ?? NSNull(),
            "outline": ["tree": [["text": "large page outline"]]]
        ]
    }
}
