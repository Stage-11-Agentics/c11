import XCTest
import AppKit
import Bonsplit
import UserNotifications

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-246: a flag's alert goes only when its flag is lowered, its panel
/// closes, or an explicit operator input names the panel. These drive the real
/// callers with real workspaces, panels and windows: the sidebar selection, a
/// pointer tab selection (the tab already shown included), keyboard panel
/// selection, a mouse-down in the terminal, activation onto a terminal window
/// (and onto Settings, which opens nothing). An agent's `panel.focus` and the
/// focus notifications that follow it never remove an alert.
///
/// Host target (`c11Tests`): needs AppKit windows and `WorkspaceManager`.
/// Host-app classes only compile on the build host and the laptop (AGENTS.md, Testing);
/// the guest table in PR #270 drives the same paths in the real app.
@MainActor
final class FlagNotificationHostTests: XCTestCase {
    private var removals: [String] = []
    private var records: [FlagNotificationRecord] = []
    private var requests: [UNNotificationRequest] = []
    private var flagged: [(UUID, UUID)] = []
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "c11-246-host-\(UUID().uuidString)"
        removals = []
        records = []
        requests = []
        flagged = []
        AppFocusState.overrideIsFocused = true
        let store = TerminalNotificationStore.shared
        store.resetDirectFlagDeliveryHandlersForTesting()
        store.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        store.configureDirectFlagAuthorizationHandlerForTesting { $0(true) }
        store.configureDirectFlagCustomCommandHandlerForTesting { _ in }
        store.configureFlagNotificationObservationForTesting(
            request: { [weak self] request, completion in
                self?.requests.append(request)
                completion(nil)
            },
            removal: { [weak self] in self?.removals.append($0) },
            record: { [weak self] in self?.records.append($0) },
            settings: UserDefaults(suiteName: suiteName)
        )
    }

    override func tearDown() {
        for (workspace, surface) in flagged {
            PanelAttentionService.shared.remove(workspaceId: workspace, surfaceId: surface)
        }
        let store = TerminalNotificationStore.shared
        store.resetDirectFlagDeliveryHandlersForTesting()
        store.resetFlagNotificationReplacementHandlerForTesting()
        UserDefaults().removePersistentDomain(forName: suiteName)
        AppFocusState.overrideIsFocused = nil
        super.tearDown()
    }

    private func drainMain(_ turns: Int = 3) {
        for _ in 0..<turns {
            let drained = expectation(description: "main drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
        }
    }

    private func raiseFlag(_ workspace: Workspace, _ panel: UUID) throws -> String {
        flagged.append((workspace.id, panel))
        _ = try PanelAttentionService.shared.raise(
            workspaceId: workspace.id, surfaceId: panel, reason: "Host proof", title: "Owner"
        )
        drainMain()
        return try XCTUnwrap(requests.last?.identifier)
    }

    /// What `panel.focus` does: `Workspace.focusPanel` inside the request,
    /// then the terminal's focus notification on a later turn, twice (a
    /// repeated first-responder change).
    private func agentFocus(_ manager: WorkspaceManager, _ workspace: Workspace, _ panel: UUID) {
        SocketCommandContext.withContext(SocketCommandContext(method: "panel.focus", allowsFocus: true)) {
            workspace.focusPanel(panel)
        }
        for _ in 0..<2 {
            NotificationCenter.default.post(
                name: .ghosttyDidFocusSurface, object: nil,
                userInfo: [GhosttyNotificationKey.workspaceId: workspace.id, GhosttyNotificationKey.surfaceId: panel]
            )
            drainMain()
        }
    }

    /// The causes of every alert removal so far: an open must say `opened`.
    private var removalCauses: [FlagNotificationRecord.Cause] {
        records.filter { $0.action == .removed }.map(\.cause)
    }

    private func flaggedState(_ workspace: Workspace, _ panel: UUID) -> Bool {
        PanelAttentionIndex.shared.snapshot(workspaceId: workspace.id, surfaceId: panel).isFlagged
    }

    // MARK: Negative: focus alone never removes an alert

    func testAnAgentFocusAndItsFocusNotificationsNeverRemoveAnAlert() throws {
        let manager = WorkspaceManager()
        let workspace = manager.workspaces[0]
        manager.selectWorkspace(workspace, cause: "create")
        drainMain()
        let first = try XCTUnwrap(workspace.focusedPanelId)
        let second = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: false)?.id)
        _ = try raiseFlag(workspace, second)

        agentFocus(manager, workspace, second)
        agentFocus(manager, workspace, first)
        agentFocus(manager, workspace, second)

        XCTAssertTrue(removals.isEmpty, "a focus change, whoever caused it, is not an open")
        XCTAssertNil(TerminalNotificationStore.shared.lastOperatorOpenPanel)
    }

    // MARK: Positive: each operator input names the panel

    func testSidebarSelectionOpensTheAgentFocusedPanelItShows() throws {
        let manager = WorkspaceManager()
        let first = manager.workspaces[0]
        let second = manager.addWorkspace()
        manager.selectWorkspace(first, cause: "create")
        drainMain()
        let panel = try XCTUnwrap(second.focusedPanelId)
        let identifier = try raiseFlag(second, panel)
        agentFocus(manager, second, panel)
        XCTAssertTrue(removals.isEmpty)

        // The card's own entry point (WorkspaceRowView.updateSelection).
        manager.selectWorkspaceFromSidebarCard(second, isCommand: false, isShift: false)
        drainMain()

        XCTAssertEqual(removals, [identifier])
        XCTAssertEqual(removalCauses, [.opened])
        XCTAssertTrue(flaggedState(second, panel), "opening never lowers the flag")
    }

    func testPointerSelectionOfTheTabAlreadyShownOpensIt() throws {
        let manager = WorkspaceManager()
        let workspace = manager.workspaces[0]
        manager.selectWorkspace(workspace, cause: "create")
        drainMain()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let identifier = try raiseFlag(workspace, panel)
        agentFocus(manager, workspace, panel)
        XCTAssertTrue(removals.isEmpty)

        // Bonsplit's strip tab, sheet row and rail row report a pointer
        // selection through this hook, the selected tab included.
        let tab = try XCTUnwrap(workspace.bonsplitTabIdFromTabId(panel))
        let pane = try XCTUnwrap(workspace.paneId(forPanelId: panel))
        let hook = try XCTUnwrap(workspace.bonsplitController.onTabSelectedByUser, "Workspace installs the hook")
        hook(tab, pane)

        XCTAssertEqual(removals, [identifier])
        XCTAssertEqual(removalCauses, [.opened])
        XCTAssertTrue(flaggedState(workspace, panel))
    }

    func testKeyboardSelectionOfTheSameAgentFocusedPanelOpensIt() throws {
        let manager = WorkspaceManager()
        let workspace = manager.workspaces[0]
        manager.selectWorkspace(workspace, cause: "create")
        drainMain()
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let identifier = try raiseFlag(workspace, panel)
        agentFocus(manager, workspace, panel)
        XCTAssertTrue(removals.isEmpty)

        // Cmd-1: select the first (and only) panel, which is already shown.
        workspace.selectSurface(at: 0)

        XCTAssertEqual(removals, [identifier])
        XCTAssertEqual(removalCauses, [.opened])
        XCTAssertTrue(flaggedState(workspace, panel))
    }

    func testAMouseDownInTheTerminalOpensIt() throws {
        let manager = WorkspaceManager()
        let workspace = manager.workspaces[0]
        manager.selectWorkspace(workspace, cause: "create")
        drainMain()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let terminal = try XCTUnwrap(workspace.panels[panelId] as? TerminalPanel)
        let identifier = try raiseFlag(workspace, panelId)
        agentFocus(manager, workspace, panelId)
        XCTAssertTrue(removals.isEmpty)

        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.terminalSurface = terminal.surface
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        view.mouseDown(with: event)

        XCTAssertEqual(removals, [identifier])
        XCTAssertEqual(removalCauses, [.opened])
        XCTAssertTrue(flaggedState(workspace, panelId))
    }

    func testActivationOntoTheTerminalWindowOpensItsPanelAndOntoSettingsOpensNothing() throws {
        _ = NSApplication.shared
        let previousDelegate = AppDelegate.shared
        let app = AppDelegate()
        app.resignSnapshotWriterOverrideForTesting = {}
        defer { AppDelegate.shared = previousDelegate }
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedPanelId)
        let windowId = UUID()
        let terminalWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        terminalWindow.isReleasedWhenClosed = false
        terminalWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        defer {
            app.debugUnregisterMainWindow(terminalWindow)
            terminalWindow.close()
            settingsWindow.close()
        }
        app.registerMainWindow(terminalWindow, windowId: windowId, workspaceManager: manager,
                               sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState())
        let identifier = try raiseFlag(workspace, panel)

        app.handleActivationFlagOpen(keyWindow: settingsWindow)
        XCTAssertTrue(removals.isEmpty, "returning to Settings opens no terminal panel")

        app.handleActivationFlagOpen(keyWindow: terminalWindow)
        XCTAssertEqual(removals, [identifier])
        XCTAssertEqual(removalCauses, [.opened])
        XCTAssertTrue(flaggedState(workspace, panel))
    }

    // MARK: The looking skip needs the operator's own open (R1 Astra P1)

    /// Two windows, two agents: an agent focuses A in the key window's
    /// workspace, another focuses B in a second window. A fresh flag on A
    /// still posts: no operator input named A.
    func testAFreshFlagOnAnAgentFocusedPanelPostsAcrossTwoWindows() throws {
        let keyManager = WorkspaceManager()
        let otherManager = WorkspaceManager()
        let keyWorkspace = keyManager.workspaces[0]
        let otherWorkspace = otherManager.workspaces[0]
        keyManager.selectWorkspace(keyWorkspace, cause: "create")
        otherManager.selectWorkspace(otherWorkspace, cause: "create")
        drainMain()
        let a = try XCTUnwrap(keyWorkspace.focusedPanelId)
        let b = try XCTUnwrap(otherWorkspace.focusedPanelId)
        // The key window shows A, focused.
        TerminalNotificationStore.shared.configureFlagNotificationObservationForTesting(
            request: { [weak self] request, completion in
                self?.requests.append(request)
                completion(nil)
            },
            removal: { [weak self] in self?.removals.append($0) },
            record: { [weak self] in self?.records.append($0) },
            operatorLooking: { _, surface in surface == a },
            settings: UserDefaults(suiteName: suiteName)
        )

        agentFocus(keyManager, keyWorkspace, a)
        agentFocus(otherManager, otherWorkspace, b)
        _ = try raiseFlag(keyWorkspace, a)

        XCTAssertEqual(requests.count, 1, "the flag on A posts its alert")
    }

    // MARK: Repair 3: panel-named jumps acknowledge only their target

    /// Workspace W shows tab A; tab B is hidden; both flagged; the operator
    /// is in another workspace.
    private func twoFlaggedTabs() throws -> (WorkspaceManager, Workspace, a: UUID, b: UUID, aID: String, bID: String) {
        let manager = WorkspaceManager()
        let home = manager.workspaces[0]
        let w = manager.addWorkspace()
        manager.selectWorkspace(w, cause: "create")
        drainMain()
        let a = try XCTUnwrap(w.focusedPanelId)
        let b = try XCTUnwrap(w.newTerminalSurfaceInFocusedPane(focus: false)?.id)
        w.focusPanel(a)
        manager.selectWorkspace(home, cause: "create")
        drainMain()
        let aID = try raiseFlag(w, a)
        let bID = try raiseFlag(w, b)
        return (manager, w, a, b, aID, bID)
    }

    func testANotificationClickOnBAcknowledgesOnlyB() throws {
        let (manager, w, _, b, _, bID) = try twoFlaggedTabs()
        XCTAssertTrue(SocketCommandContext.withContext(nil) { manager.focusTabFromNotification(w.id, surfaceId: b) })
        drainMain()
        XCTAssertEqual(removals, [bID])
        XCTAssertEqual(removalCauses, [.opened])
        XCTAssertEqual(TerminalNotificationStore.shared.lastOperatorOpenPanel, b)
    }

    func testAPaletteSwitchToBAcknowledgesOnlyB() throws {
        let (manager, w, _, b, _, bID) = try twoFlaggedTabs()
        SocketCommandContext.withContext(nil) {
            manager.focusPaletteSwitcherTarget(windowId: UUID(), workspaceId: w.id, surfaceId: b)
        }
        drainMain(5)
        XCTAssertEqual(removals, [bID])
        XCTAssertEqual(removalCauses, [.opened])
        XCTAssertEqual(TerminalNotificationStore.shared.lastOperatorOpenPanel, b)
    }

    /// Escape out of the palette restores focus with cause "palette"; that
    /// restoration is not an open.
    func testPaletteFocusRestorationAcknowledgesNothing() throws {
        let (manager, w, a, _, _, _) = try twoFlaggedTabs()
        let before = TerminalNotificationStore.shared.lastOperatorOpenPanel
        SocketCommandContext.withContext(nil) {
            manager.focusWorkspace(w.id, surfaceId: a, suppressFlash: true, cause: "palette")
        }
        drainMain(5)
        XCTAssertTrue(removals.isEmpty)
        XCTAssertEqual(TerminalNotificationStore.shared.lastOperatorOpenPanel, before)
    }

    /// The Flagged Agents button and the menu-bar list open their target.
    func testTheFlaggedAgentsJumpAcknowledgesItsTarget() throws {
        _ = NSApplication.shared
        let previousDelegate = AppDelegate.shared
        let app = AppDelegate()
        app.resignSnapshotWriterOverrideForTesting = {}
        defer { AppDelegate.shared = previousDelegate }
        let (manager, w, _, b, _, bID) = try twoFlaggedTabs()
        let windowId = UUID()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        defer {
            app.debugUnregisterMainWindow(window)
            window.close()
        }
        app.registerMainWindow(window, windowId: windowId, workspaceManager: manager,
                               sidebarState: SidebarState(), sidebarSelectionState: SidebarSelectionState())

        XCTAssertTrue(app.operatorOpenAttentionTarget(.init(workspaceID: w.id, panelID: b)))
        drainMain()

        XCTAssertEqual(removals, [bID])
        XCTAssertEqual(removalCauses, [.opened])
    }

    /// v2 review: a real agent focus, then a reason and a kind revision,
    /// nothing injected: the alert stays and is replaced, the flag stays.
    func testAnAgentFocusThenARevisionKeepsTheAlert() throws {
        let manager = WorkspaceManager()
        let workspace = manager.workspaces[0]
        manager.selectWorkspace(workspace, cause: "create")
        drainMain()
        let first = try XCTUnwrap(workspace.focusedPanelId)
        let flaggedPanel = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: false)?.id)
        workspace.focusPanel(first)
        TerminalNotificationStore.shared.configureFlagNotificationObservationForTesting(
            request: { [weak self] request, completion in
                self?.requests.append(request)
                completion(nil)
            },
            removal: { [weak self] in self?.removals.append($0) },
            record: { [weak self] in self?.records.append($0) },
            settings: UserDefaults(suiteName: suiteName)
        )
        flagged.append((workspace.id, flaggedPanel))
        _ = try PanelAttentionService.shared.raise(
            workspaceId: workspace.id, surfaceId: flaggedPanel, reason: "First", title: "Owner"
        )
        drainMain()
        let identifier = try XCTUnwrap(requests.last?.identifier)

        agentFocus(manager, workspace, flaggedPanel)
        _ = try PanelAttentionService.shared.raise(
            workspaceId: workspace.id, surfaceId: flaggedPanel, reason: "Revised", title: "Owner"
        )
        // Let the reason revision's add complete before the kind revision: a
        // newer revision supersedes an add still in flight, and that add then
        // records nothing (TerminalNotificationStore's generation guard).
        drainMain()
        let kind = try XCTUnwrap(PanelFlagKindRegistry.shared.all().first)
        _ = try PanelAttentionService.shared.raise(
            workspaceId: workspace.id, surfaceId: flaggedPanel, reason: "Revised", kind: kind, title: "Owner"
        )
        drainMain()

        XCTAssertTrue(removals.isEmpty)
        XCTAssertEqual(requests.map(\.identifier), [identifier, identifier, identifier])
        XCTAssertEqual(records.map(\.action), [.posted, .replaced, .replaced])
        XCTAssertTrue(flaggedState(workspace, flaggedPanel))
    }

    /// Repair 4: a Cmd or Shift card click that brings another workspace into
    /// view opens its panel; one on the card already shown does not.
    func testACmdOrShiftCardClickOpensOnlyWhenItChangesTheWorkspace() throws {
        let manager = WorkspaceManager()
        let first = manager.workspaces[0]
        let second = manager.addWorkspace()
        manager.selectWorkspace(first, cause: "create")
        drainMain()
        let firstPanel = try XCTUnwrap(first.focusedPanelId)
        let secondPanel = try XCTUnwrap(second.focusedPanelId)
        _ = try raiseFlag(first, firstPanel)
        let secondID = try raiseFlag(second, secondPanel)

        manager.selectWorkspaceFromSidebarCard(first, isCommand: true, isShift: false)
        drainMain()
        XCTAssertTrue(removals.isEmpty, "Cmd-click on the card already shown is multiselection only")

        manager.selectWorkspaceFromSidebarCard(second, isCommand: true, isShift: false)
        drainMain()
        XCTAssertEqual(removals, [secondID])
        XCTAssertEqual(removalCauses, [.opened])
    }
}
