import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-349: an operator's jump brings the window holding its target to the
/// display the operator is on. Geometry is the layout of the night it failed:
/// the operator's window on DELL P2715Q (2), an agent's window on the built-in
/// Retina, in top-left global points.
final class OperatorJumpTests: XCTestCase {
    private let builtin = DisplayGeometry(
        uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", displayID: 1, name: "Built-in Retina Display",
        isMain: true, isBuiltin: true,
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 39, width: 1800, height: 1130), scale: 2, index: 4)
    private let dell = DisplayGeometry(
        uuid: "DBDAE43B-1551-4262-90B2-74C254A7C815", displayID: 3, name: "DELL P2715Q (2)",
        isMain: false, isBuiltin: false,
        frame: CGRect(x: -3008, y: -523, width: 3008, height: 1692),
        visibleFrame: CGRect(x: -3008, y: -493, width: 3008, height: 1597), scale: 2, index: 3)
    private var displays: [DisplayGeometry] { [dell, builtin] }

    /// The agent's 1120x840 window on the built-in display, as logged.
    private let agentWindow = CGRect(x: 340, y: 184, width: 1120, height: 840)

    func testWindowOnAnotherDisplayComesToTheOperatorCentredAtItsOwnSize() {
        let placement = OperatorJumpPlacement.plan(
            window: agentWindow, windowDisplay: builtin, operatorDisplay: dell,
            isFullScreen: false, minSize: CGSize(width: 400, height: 300))
        guard case .moveToDisplay(let frame) = placement else { return XCTFail("\(placement)") }
        XCTAssertEqual(frame.size, agentWindow.size)
        XCTAssertTrue(dell.visibleFrame.contains(frame))
        XCTAssertEqual(frame.midX, dell.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, dell.visibleFrame.midY, accuracy: 1)
        XCTAssertEqual(placement.token, "moved_display")
    }

    func testWindowAlreadyOnTheOperatorsDisplayStays() {
        let placement = OperatorJumpPlacement.plan(
            window: agentWindow, windowDisplay: builtin, operatorDisplay: builtin,
            isFullScreen: false, minSize: .zero)
        XCTAssertEqual(placement, .inPlace)
        XCTAssertEqual(OperatorJumpPlacement.plan(window: agentWindow, windowDisplay: nil, operatorDisplay: dell,
                                                  isFullScreen: false, minSize: .zero), .inPlace)
    }

    func testWindowTooLargeForTheOperatorsDisplayShrinksToItsVisibleFrame() {
        let huge = CGRect(x: -3008, y: -493, width: 3008, height: 1597)
        let placement = OperatorJumpPlacement.plan(
            window: huge, windowDisplay: dell, operatorDisplay: builtin,
            isFullScreen: false, minSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(placement, .moveToDisplay(builtin.visibleFrame))
    }

    /// c11's real minimum (900x640) on a display too small for it: the axis that
    /// cannot fit keeps its left edge or title bar inside the visible frame, the
    /// other is centred.
    func testOnADisplaySmallerThanTheMinimumTheTitleBarAndLeftEdgeStayVisible() {
        let minimum = CGSize(width: 900, height: 640)
        let narrow = DisplayGeometry(
            uuid: nil, displayID: 7, name: "Portrait", isMain: false, isBuiltin: false,
            frame: CGRect(x: 1800, y: 0, width: 720, height: 1280),
            visibleFrame: CGRect(x: 1800, y: 25, width: 720, height: 1255), scale: 2, index: 5)
        guard case .moveToDisplay(let wide) = OperatorJumpPlacement.plan(
            window: agentWindow, windowDisplay: builtin, operatorDisplay: narrow,
            isFullScreen: false, minSize: minimum) else { return XCTFail("narrow") }
        XCTAssertEqual(wide.width, 900)
        XCTAssertEqual(wide.minX, narrow.visibleFrame.minX)
        XCTAssertEqual(wide.height, agentWindow.height)
        XCTAssertEqual(wide.midY, narrow.visibleFrame.midY, accuracy: 1)

        let short = DisplayGeometry(
            uuid: nil, displayID: 8, name: "Short", isMain: false, isBuiltin: false,
            frame: CGRect(x: 1800, y: 0, width: 1280, height: 625),
            visibleFrame: CGRect(x: 1800, y: 25, width: 1280, height: 600), scale: 2, index: 5)
        guard case .moveToDisplay(let tall) = OperatorJumpPlacement.plan(
            window: agentWindow, windowDisplay: builtin, operatorDisplay: short,
            isFullScreen: false, minSize: minimum) else { return XCTFail("short") }
        XCTAssertEqual(tall.height, 640)
        XCTAssertEqual(tall.minY, short.visibleFrame.minY)
        XCTAssertEqual(tall.width, agentWindow.width)
        XCTAssertEqual(tall.midX, short.visibleFrame.midX, accuracy: 1)
    }

    func testFullScreenWindowElsewhereIsRaisedThereNotMoved() {
        let placement = OperatorJumpPlacement.plan(
            window: builtin.frame, windowDisplay: builtin, operatorDisplay: dell,
            isFullScreen: true, minSize: .zero)
        XCTAssertEqual(placement, .fullScreenElsewhere)
    }

    func testOperatorDisplayIsTheActiveC11WindowsElseThePointers() {
        let pointerOnBuiltin = CGPoint(x: 900, y: 600)
        let operatorWindowOnDell = CGRect(x: -3008, y: -493, width: 3008, height: 1597)
        XCTAssertEqual(OperatorJumpPlacement.operatorDisplay(
            activeWindowFrame: operatorWindowOnDell, pointer: pointerOnBuiltin, displays: displays)?.displayID,
            dell.displayID)
        XCTAssertEqual(OperatorJumpPlacement.operatorDisplay(
            activeWindowFrame: nil, pointer: pointerOnBuiltin, displays: displays)?.displayID,
            builtin.displayID)
    }

    func testPointerOnNoDisplayBelongsToTheNearest() {
        // The built-in display's far right edge is outside its half-open frame.
        let edge = CGPoint(x: 1800, y: 600)
        XCTAssertEqual(OperatorJumpPlacement.display(containing: edge, in: displays)?.displayID, builtin.displayID)
    }
}

/// C11H-349: every panel-link jump writes one `operator_jump` line, whichever
/// exit it takes. The raise is a recorder and the link path queues no second
/// activation, so the test process never activates or shows a window.
@MainActor
final class OperatorJumpPanelLinkTests: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private var directory: URL!
    private var resetDiagnostics: (@MainActor () -> Void)?
    private var previousDelegate: AppDelegate?
    private var registered: [(AppDelegate, NSWindow)] = []
    private var raised: [NSWindow] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        previousDelegate = AppDelegate.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-operator-jump-\(UUID().uuidString)")
        resetDiagnostics = HCDiagnosticRecorder.installFixtureForTesting(directory: directory)
    }

    override func tearDown() async throws {
        for (app, window) in registered {
            app.debugUnregisterMainWindow(window)
            window.close()
        }
        registered.removeAll()
        raised.removeAll()
        resetDiagnostics?()
        AppDelegate.shared = previousDelegate
        try? FileManager.default.removeItem(at: directory)
    }

    private func jumpLines() -> [String] {
        let log = (try? String(contentsOf: directory.appendingPathComponent("diagnostics.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init).filter { $0.contains("event=operator_jump") }
    }

    private func makeApp(window: NSWindow? = nil) -> (AppDelegate, WorkspaceManager) {
        let app = AppDelegate()
        app.resignSnapshotWriterOverrideForTesting = {}
        app.operatorJumpRaise = { [weak self] in self?.raised.append($0) }
        let manager = WorkspaceManager()
        if let window {
            let windowId = UUID()
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
            app.registerMainWindow(window, windowId: windowId, workspaceManager: manager,
                                   sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState())
            registered.append((app, window))
        }
        return (app, manager)
    }

    /// Runs everything the jump queued on the main queue, so an activation
    /// queued outside the recorder would have run before the assertions.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    private func plainWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }

    func testAClosedPanelLinkLogsMissingPanelWithNoWorkspace() {
        let (app, _) = makeApp()
        let panel = UUID()
        XCTAssertFalse(app.openPanelLink(.panel(panel)))
        let lines = jumpLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("source=panel_link outcome=missing_panel") == true, "\(lines)")
        XCTAssertTrue(lines.first?.contains("panel_id=\(panel.uuidString)") == true, "\(lines)")
        XCTAssertFalse(lines.first?.contains("workspace_id=") == true, "\(lines)")
        XCTAssertTrue(raised.isEmpty)
    }

    func testAClosedWorkspaceLinkLogsMissingWorkspace() {
        let (app, _) = makeApp(window: plainWindow())
        let workspace = UUID()
        XCTAssertFalse(app.openPanelLink(.workspace(workspace)))
        let lines = jumpLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("source=panel_link outcome=missing_workspace") == true, "\(lines)")
        XCTAssertTrue(lines.first?.contains("workspace_id=\(workspace.uuidString)") == true, "\(lines)")
        XCTAssertTrue(raised.isEmpty)
    }

    func testALinkToAPanelRaisesItsWindowAndLogsOpenedOnce() throws {
        let window = plainWindow()
        let (app, manager) = makeApp(window: window)
        let panel = try XCTUnwrap(manager.selectedWorkspace?.focusedPanelId)
        let wasActive = NSApp.isActive
        XCTAssertTrue(app.openPanelLink(.panel(panel)))
        drainMainQueue()
        // Every raise went through the recorder: nothing showed the window or
        // activated the test process, then or from the main queue.
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(NSApp.isActive, wasActive)
        XCTAssertFalse(raised.isEmpty)
        XCTAssertTrue(raised.allSatisfy { $0 === window })
        let lines = jumpLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("source=panel_link outcome=opened placement=") == true, "\(lines)")
        XCTAssertTrue(lines.first?.contains("panel_id=\(panel.uuidString)") == true, "\(lines)")
    }

    func testALinkToThePanelAlreadyInFrontLogsOpenedWithoutRaising() throws {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let (app, manager) = makeApp(window: window)
        let panel = try XCTUnwrap(manager.selectedWorkspace?.focusedPanelId)
        let wasActive = NSApp.isActive
        XCTAssertTrue(app.openPanelLink(.panel(panel)))
        drainMainQueue()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(NSApp.isActive, wasActive)
        XCTAssertTrue(raised.isEmpty)
        let lines = jumpLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("source=panel_link outcome=opened") == true, "\(lines)")
        XCTAssertFalse(lines.first?.contains("placement=") == true, "\(lines)")
    }
}
