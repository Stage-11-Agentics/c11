import XCTest
import Bonsplit
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-96: a remote (Studio) panel created in a background workspace must ask for its
/// headless start at once. Pure policy; `Workspace` wires it into both create paths
/// (host-only, compile-checked, covered by the bridge-mode guest proof).
final class HCRemoteCreateStartTests: XCTestCase {
    func testAFreshRemotePanelWithoutASurfaceAsksForTheHeadlessStart() {
        // The background-workspace case: new-panel --on studio, no view in a window, no surface yet.
        XCTAssertEqual(HCInputReadyQueue.createStart(isRemote: true, restoring: false, hasNativeSurface: false),
                       .requestBackground)
    }

    func testALocalPanelIsLeftToItsOwnLazyStart() {
        XCTAssertEqual(HCInputReadyQueue.createStart(isRemote: false, restoring: false, hasNativeSurface: false), .leave)
    }

    func testARestoredRemotePanelKeepsTheRestoreDeferral() {
        XCTAssertEqual(HCInputReadyQueue.createStart(isRemote: true, restoring: true, hasNativeSurface: false), .leave)
    }

    func testAPanelThatAlreadyHasASurfaceHasNothingToStart() {
        XCTAssertEqual(HCInputReadyQueue.createStart(isRemote: true, restoring: false, hasNativeSurface: true), .leave)
    }

    func testEveryCombinationOnlyOneRequestsTheStart() {
        var requested: [[Bool]] = []
        for remote in [false, true] { for restoring in [false, true] { for surface in [false, true] {
            if HCInputReadyQueue.createStart(isRemote: remote, restoring: restoring, hasNativeSurface: surface) == .requestBackground {
                requested.append([remote, restoring, surface])
            }
        } } }
        XCTAssertEqual(requested, [[true, false, false]])
    }
}

/// C11H-96, part 2: the production creation and restore paths, driven for real (a `Workspace`, a
/// `WorkspaceManager`, a session snapshot) with `TerminalSurface.backgroundStartSink` observing the start
/// request instead of Ghostty starting. Removing the request (or the restore dispatch, or a path's
/// machine forwarding) turns the matching test red.
@MainActor
final class HCRemoteStartPathTests: XCTestCase {
    private var requested: [UUID] = []
    private var finishes: [UUID: () -> Void] = [:]
    private let studio = HCRemoteTarget(machine: "studio", cwd: "/work")

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        requested = []
        finishes = [:]
        TerminalSurface.backgroundStartSink = { [unowned self] surface, finish in
            self.requested.append(surface.id)
            self.finishes[surface.id] = finish
        }
    }

    override func tearDown() {
        TerminalSurface.backgroundStartSink = nil
        super.tearDown()
    }

    private func firstPane(_ workspace: Workspace) throws -> PaneID {
        try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
    }

    private func terminalSnapshot(_ id: UUID, remote: HCRemoteTarget?) -> SessionPanelSnapshot {
        SessionPanelSnapshot(id: id, type: .terminal, title: "Fixture", customTitle: nil,
            directory: "/fixture", isPinned: false, isManuallyUnread: false,
            gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: remote == nil ? "/fixture" : nil, scrollback: nil,
                hcIdentity: HCPanelIdentity(panelID: id, persistence: .nonpersistent), hcRemoteTarget: remote),
            browser: nil, markdown: nil)
    }

    private func workspaceSnapshot(_ panels: [SessionPanelSnapshot]) -> SessionWorkspaceSnapshot {
        let ids = panels.map(\.id)
        return SessionWorkspaceSnapshot(id: UUID(), processTitle: "Fixture", customTitle: nil,
            customColor: nil, isPinned: false, currentDirectory: "/fixture", focusedPanelId: ids[0],
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: ids, selectedPanelId: ids[0])),
            panels: panels, statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
    }

    // MARK: creation paths

    func testNewPanelOnAtlasRequestsTheStartAndALocalPanelDoesNot() throws {
        let workspace = Workspace()
        let pane = try firstPane(workspace)
        let remote = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false, machine: .on("studio")))
        XCTAssertEqual(requested, [remote.id])
        let local = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false, machine: .local))
        XCTAssertFalse(requested.contains(local.id))
    }

    func testNewAreaOnAtlasASplitOfAnAtlasPanelAndLaunchAgentOnAtlasRequestTheStart() throws {
        let workspace = Workspace()
        let pane = try firstPane(workspace)
        let source = try XCTUnwrap(workspace.focusedTerminalPanel)
        // new-area --on studio (split case)
        let split = try XCTUnwrap(workspace.newTerminalSplit(from: source.id, orientation: .horizontal, focus: false,
                                                             machine: .on("studio")))
        XCTAssertTrue(requested.contains(split.id))
        // launch-agent --on studio: the handler's own call (startup environment, explicit remote cwd, machine request)
        let agent = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false, workingDirectory: "/work",
            startupEnvironment: ["C11_AGENT_TYPE": "claude"], machine: .on("studio")))
        XCTAssertTrue(requested.contains(agent.id))
        // a split of a local panel stays local
        let localSplit = try XCTUnwrap(workspace.newTerminalSplit(from: source.id, orientation: .vertical, focus: false))
        XCTAssertFalse(requested.contains(localSplit.id))
    }

    func testTheMenusNewTerminalOnAtlasRequestsTheStart() throws {
        let manager = WorkspaceManager()
        let before = Set(manager.selectedWorkspace?.panels.keys.map { $0 } ?? [])
        manager.newSurface(onMachine: "studio")
        let created = try XCTUnwrap(manager.selectedWorkspace).panels.keys.filter { !before.contains($0) }
        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(created.allSatisfy { requested.contains($0) })
    }

    // MARK: restore

    func testCreatingAPanelForARestoreLeavesItToTheRestoreStep() throws {
        let workspace = Workspace(restoringSession: true)
        let pane = try firstPane(workspace)
        let restored = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false, panelId: UUID(),
                                                                  machine: .restored(studio)))
        XCTAssertFalse(requested.contains(restored.id))
    }

    func testRestoringAHiddenWorkspaceRequestsTheStartOfItsAtlasPanelsOnly() throws {
        let shown = UUID(), hiddenAtlas = UUID(), hiddenAtlas2 = UUID(), hiddenLocal = UUID()
        let snapshot = SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [
            workspaceSnapshot([terminalSnapshot(shown, remote: nil)]),
            workspaceSnapshot([terminalSnapshot(hiddenAtlas, remote: studio), terminalSnapshot(hiddenLocal, remote: nil),
                               terminalSnapshot(hiddenAtlas2, remote: studio)])])
        let manager = WorkspaceManager()
        manager.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(Set(requested).intersection([hiddenAtlas, hiddenAtlas2]), [hiddenAtlas, hiddenAtlas2])
        XCTAssertFalse(requested.contains(hiddenLocal))
        XCTAssertFalse(requested.contains(shown))
        // The workspace was never selected: the start did not wait for it to be shown.
        XCTAssertEqual(manager.selectedWorkspaceId, manager.workspaces[0].id)
    }

    func testARepeatedRestoreRequestIsCoalescedUntilTheQueuedStartRuns() throws {
        let id = UUID()
        let manager = WorkspaceManager()
        manager.restoreSessionSnapshot(SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [
            workspaceSnapshot([terminalSnapshot(UUID(), remote: nil)]),
            workspaceSnapshot([terminalSnapshot(id, remote: studio)])]))
        XCTAssertEqual(requested.filter { $0 == id }.count, 1)
        manager.workspaces[1].startRestoredRemoteTerminalsInBackground()
        XCTAssertEqual(requested.filter { $0 == id }.count, 1)           // still queued: not asked twice
        finishes[id]?()                                                    // the queued turn ran, no surface yet
        manager.workspaces[1].startRestoredRemoteTerminalsInBackground()
        XCTAssertEqual(requested.filter { $0 == id }.count, 2)           // asked again, as the gate-release retry does
    }

    func testAPanelClosedBeforeTheStartRunsIsNeverRequestedAgain() throws {
        let id = UUID()
        let manager = WorkspaceManager()
        manager.restoreSessionSnapshot(SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [
            workspaceSnapshot([terminalSnapshot(UUID(), remote: nil)]),
            workspaceSnapshot([terminalSnapshot(id, remote: studio), terminalSnapshot(UUID(), remote: nil)])]))
        let hidden = manager.workspaces[1]
        let panel = try XCTUnwrap(hidden.panels[id] as? TerminalPanel)
        XCTAssertEqual(requested.filter { $0 == id }.count, 1)
        XCTAssertTrue(hidden.closePanel(id, force: true))
        finishes[id]?()
        panel.surface.requestBackgroundSurfaceStartIfNeeded()
        hidden.startRestoredRemoteTerminalsInBackground()
        XCTAssertEqual(requested.filter { $0 == id }.count, 1)           // closed: the live guard refuses it
    }

    func testTheRestoredStartRunsHeadlessWhenTheGateOpensWithNoWindow() {
        // What the parked start does once the restore gate releases (GhosttyTerminalView.createSurface).
        XCTAssertEqual(HCInputReadyQueue.parkedStart(viewAlive: true, inWindow: false, needsStart: true), .startHeadless)
        XCTAssertEqual(HCInputReadyQueue.parkedStart(viewAlive: false, inWindow: false, needsStart: true), .drop)
    }
}

/// The restore gate, through the real deferral (`HCBackendComposition.deferSurfaceStartUntilRestore`): a persistent
/// remote panel whose start is parked behind the gate, with its view off any window, retries as a headless
/// start when the gate opens; a panel closed before the release is never retried.
@MainActor
final class HCRestoreGateReleaseTests: XCTestCase {
    private var requested: [UUID] = []
    private var gateWasOpen = false
    private let studio = HCRemoteTarget(machine: "studio", cwd: "/work")

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        requested = []
        gateWasOpen = HCBackendComposition.shared.isInitialRestoreReady
        HCBackendComposition.shared.setInitialRestoreReady(false)
        TerminalSurface.backgroundStartSink = { [unowned self] surface, _ in self.requested.append(surface.id) }
    }

    override func tearDown() {
        TerminalSurface.backgroundStartSink = nil
        HCBackendComposition.shared.setInitialRestoreReady(gateWasOpen)
        super.tearDown()
    }

    /// A restored persistent remote panel: the identity carries a key, so the panel has a real hc runtime that has
    /// never attached.
    private func restoredPanel() throws -> (Workspace, TerminalPanel, UUID) {
        let id = UUID()
        let key = HCTerminalKey(owningCoreID: "owned", localAddress: "t1")
        let panel = SessionPanelSnapshot(id: id, type: .terminal, title: "Fixture", customTitle: nil,
            directory: "/fixture", isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil,
                hcIdentity: HCPanelIdentity(panelID: id, key: key), hcRemoteTarget: studio),
            browser: nil, markdown: nil)
        let snapshot = SessionWorkspaceSnapshot(id: UUID(), processTitle: "Fixture", customTitle: nil, customColor: nil,
            isPinned: false, currentDirectory: "/fixture", focusedPanelId: id,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [id], selectedPanelId: id)), panels: [panel],
            statusEntries: [], logEntries: [], progress: nil, gitBranch: nil)
        let workspace = Workspace(restoringSession: true)
        workspace.restoreSessionSnapshot(snapshot)
        let terminal = try XCTUnwrap(workspace.panels[id] as? TerminalPanel)
        XCTAssertNotNil(terminal.hcSession, "the fixture needs a real persistent hc runtime")
        return (workspace, terminal, id)
    }

    func testGateReleaseWithTheViewOffWindowRetriesAsAHeadlessStart() throws {
        let (workspace, panel, id) = try restoredPanel()
        defer { workspace.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id) }
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))      // no window
        XCTAssertTrue(panel.surface.parkStartBehindRestoreGate(view: view), "the start parks behind the closed gate")
        XCTAssertFalse(requested.contains(id), "nothing starts before the gate opens")
        HCBackendComposition.shared.setInitialRestoreReady(true)                       // the real release
        XCTAssertEqual(requested.filter { $0 == id }.count, 1, "the parked start retries headless on release")
    }

    func testAGateOpenedWithNothingParkedStartsNothing() throws {
        let (workspace, _, id) = try restoredPanel()
        defer { workspace.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id) }
        HCBackendComposition.shared.setInitialRestoreReady(true)
        XCTAssertFalse(requested.contains(id))
    }

    func testAPanelClosedBeforeTheGateOpensIsNeverRetried() throws {
        let (workspace, panel, id) = try restoredPanel()
        defer { workspace.retireForSessionRestore(); HCPanelRestoreState.shared.remove(panelID: id) }
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        XCTAssertTrue(panel.surface.parkStartBehindRestoreGate(view: view))
        panel.surface.teardownSurface()                                                // the panel closes
        HCBackendComposition.shared.setInitialRestoreReady(true)
        XCTAssertFalse(requested.contains(id), "a parked start is cancelled with its panel")
    }
}
