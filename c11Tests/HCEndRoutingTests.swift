import XCTest
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-24 (T3.9, Settled 10): only operator/CLI closes of a panel, area,
/// workspace or window end hc sessions. Restore retirement, moves and Quit
/// detach. Inside the host app every new terminal already has a persistent hc
/// identity (with no key yet), so a test that asserts an end gives its panels
/// a persistent identity with a known key on the fake session; a fake session
/// confirms each end, so `outcomes` says exactly which panels were asked to
/// end: `.ended` was asked, `.none` never was.
@MainActor
final class HCEndRoutingTests: XCTestCase {
    private var session: HCEndFakeSession!
    private var coordinator: HCExplicitEndCoordinator!

    override func setUp() {
        super.setUp()
        session = HCEndFakeSession()
        // C11H-46: these panels are the only holders and each is being closed.
        HCSessionEnd.keyShownByLivePanel = { _ in .none }
        HCSessionEnd.install(session: session, store: HCEndMemoryStore())
        coordinator = HCSessionEnd.coordinator
    }

    override func tearDown() {
        HCSessionEnd.keyShownByLivePanel = { _ in .unknown }
        HCSessionEnd.resetForTesting()
        coordinator = nil
        session = nil
        super.tearDown()
    }

    nonisolated private static func key(for panelID: UUID) -> HCTerminalKey {
        HCTerminalKey(owningCoreID: "core-test", localAddress: panelID.uuidString)
    }

    /// Makes these panels hc terminals whose ends reach the fake session under
    /// `key(for:)`. The panel's own identity is what production reads first.
    /// Checks the setup took, so a detach test can never pass because its
    /// panel had no endable identity.
    private func useHC(_ panels: TerminalPanel..., file: StaticString = #filePath, line: UInt = #line) {
        for panel in panels {
            panel.surface.usePersistentHCForTesting(session: session, key: Self.key(for: panel.id), file: file, line: line)
            XCTAssertEqual(panel.hcEndIdentity?.key, Self.key(for: panel.id),
                           "the panel is an hc terminal with an endable key", file: file, line: line)
        }
    }

    private func confirmEnds(for panelIDs: [UUID]) {
        for panelID in panelIDs {
            let key = Self.key(for: panelID)
            session.scriptEnd(key, .confirmed(HCEndEvidence(
                id: UUID(), key: key, revision: HCRevision(connectionGeneration: 1, sequence: 1), kind: .observedRemoval
            )))
        }
    }

    private func outcomes(_ ids: [UUID], timeout: TimeInterval = 2) -> [UUID: HCPanelEndOutcome] {
        let done = expectation(description: "outcomes")
        var result: [UUID: HCPanelEndOutcome] = [:]
        let coordinator = self.coordinator!
        Task.detached {
            let value = await coordinator.outcomes(for: ids, timeout: timeout)
            await MainActor.run {
                result = value
                done.fulfill()
            }
        }
        wait(for: [done], timeout: timeout + 2)
        return result
    }

    /// End requests run in tasks; give any stray one time to reach the fake
    /// before asserting that nothing was ended.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private func split(_ workspace: Workspace) throws -> TerminalPanel {
        let anchor = try XCTUnwrap(workspace.focusedTerminalPanel)
        return try XCTUnwrap(workspace.newTerminalSplit(from: anchor.id, orientation: .horizontal, focus: false))
    }

    func testExplicitPanelCloseEndsThatPanelOnly() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let keep = try XCTUnwrap(workspace.focusedTerminalPanel)
        let closing = try split(workspace)
        useHC(keep, closing)
        confirmEnds(for: [closing.id])

        XCTAssertTrue(workspace.closePanel(closing.id, force: true))

        let result = outcomes([closing.id, keep.id])
        XCTAssertEqual(result[closing.id], .ended)
        XCTAssertEqual(result[keep.id], HCPanelEndOutcome.none)
        XCTAssertEqual(session.ends, [Self.key(for: closing.id)])
    }

    /// The operator's area close: the card says End Sessions, and confirming
    /// it ends the area's hc sessions.
    func testConfirmedAreaCloseSaysEndSessionsAndEndsItsPanels() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let closing = try split(workspace)
        useHC(closing)
        let pane = try XCTUnwrap(workspace.paneId(forPanelId: closing.id))
        confirmEnds(for: [closing.id])

        XCTAssertFalse(workspace.bonsplitController.closePane(pane), "an hc area asks before it closes")
        workspace.splitTabBar(workspace.bonsplitController, didRequestClosePane: pane)
        let runtime = workspace.areaCloseInteractionRuntime
        let deadline = Date().addingTimeInterval(2)
        while !runtime.hasActiveConfirm(panelId: pane.id) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard case .confirm(let content)? = runtime.active[pane.id] else {
            return XCTFail("no area close card")
        }
        XCTAssertEqual(content.confirmLabel, "End Sessions")
        XCTAssertTrue((content.message ?? "").contains("nohup"))

        runtime.resolveConfirm(panelId: pane.id, result: .confirmed)
        // The confirmed close resumes in a task; wait for the panel to go.
        let closeDeadline = Date().addingTimeInterval(2)
        while workspace.panels[closing.id] != nil && Date() < closeDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNil(workspace.panels[closing.id], "the confirmed area close removed the panel")

        XCTAssertEqual(outcomes([closing.id])[closing.id], .ended)
    }

    func testWorkspaceCloseEndsEveryPanelInIt() throws {
        let manager = WorkspaceManager()
        let survivor = try XCTUnwrap(manager.selectedWorkspace)
        let closingWorkspace = manager.addWorkspace(select: false)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let first = try XCTUnwrap(closingWorkspace.focusedTerminalPanel)
        let second = try split(closingWorkspace)
        let survivorPanel = try XCTUnwrap(survivor.focusedTerminalPanel)
        useHC(first, second, survivorPanel)
        confirmEnds(for: [first.id, second.id])

        manager.closeWorkspace(closingWorkspace)

        let result = outcomes([first.id, second.id, survivorPanel.id])
        XCTAssertEqual(result[first.id], .ended)
        XCTAssertEqual(result[second.id], .ended)
        XCTAssertEqual(result[survivorPanel.id], HCPanelEndOutcome.none)
    }

    func testRestoreRetirementDetachesAndEndsNothing() throws {
        let manager = WorkspaceManager()
        let old = try XCTUnwrap(manager.selectedWorkspace)
        let oldTerminal = try XCTUnwrap(old.focusedTerminalPanel)
        useHC(oldTerminal)
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        defer {
            for ws in manager.workspaces { ws.teardownAllPanels() }
            old.teardownAllPanels()
        }

        manager.restoreSessionSnapshot(snapshot)
        settle()

        XCTAssertTrue(old.panels.isEmpty, "the old graph was retired")
        XCTAssertEqual(outcomes([oldTerminal.id], timeout: 0)[oldTerminal.id], HCPanelEndOutcome.none)
        XCTAssertTrue(session.ends.isEmpty, "restore retirement must never end a session")
    }

    func testPlainTeardownWithoutOriginEndsNothing() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminal = try XCTUnwrap(workspace.focusedTerminalPanel)
        useHC(terminal)

        workspace.teardownAllPanels()
        settle()

        XCTAssertEqual(outcomes([terminal.id], timeout: 0)[terminal.id], HCPanelEndOutcome.none)
        XCTAssertTrue(session.ends.isEmpty)
    }

    func testDetachingAPanelForAMoveEndsNothing() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let moving = try split(workspace)
        useHC(moving)

        let transfer = workspace.detachPanel(panelId: moving.id)
        settle()

        XCTAssertNotNil(transfer)
        XCTAssertEqual(outcomes([moving.id], timeout: 0)[moving.id], HCPanelEndOutcome.none)
        XCTAssertTrue(session.ends.isEmpty)
        transfer?.panel.close()
    }

    /// A shell that exits is not an operator close: its session detaches so
    /// nohup and background jobs outlive it (Grok PR14 finding 1).
    func testShellExitDetachesAndEndsNothing() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let exiting = try split(workspace)
        useHC(exiting)

        manager.closePanelAfterChildExited(workspaceId: workspace.id, surfaceId: exiting.id)
        settle()

        XCTAssertNil(workspace.panels[exiting.id], "the exited panel closed")
        XCTAssertEqual(outcomes([exiting.id], timeout: 0)[exiting.id], HCPanelEndOutcome.none)
        XCTAssertTrue(session.ends.isEmpty)
    }

    func testLastShellExitInAWorkspaceDetachesAndEndsNothing() throws {
        let manager = WorkspaceManager()
        let exitingWorkspace = manager.addWorkspace(select: false)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let exiting = try XCTUnwrap(exitingWorkspace.focusedTerminalPanel)
        XCTAssertEqual(exitingWorkspace.panels.count, 1)
        useHC(exiting)

        manager.closePanelAfterChildExited(workspaceId: exitingWorkspace.id, surfaceId: exiting.id)
        settle()

        XCTAssertFalse(manager.workspaces.contains { $0.id == exitingWorkspace.id }, "the workspace collapsed")
        XCTAssertEqual(outcomes([exiting.id], timeout: 0)[exiting.id], HCPanelEndOutcome.none)
        XCTAssertTrue(session.ends.isEmpty)
    }

    func testWindowCloseEndsButQuitDetaches() throws {
        let quitting = WorkspaceManager()
        let quittingPanel = try XCTUnwrap(quitting.selectedWorkspace?.focusedTerminalPanel)
        let closing = WorkspaceManager()
        let closingPanel = try XCTUnwrap(closing.selectedWorkspace?.focusedTerminalPanel)
        defer { for ws in quitting.workspaces + closing.workspaces { ws.teardownAllPanels() } }
        useHC(quittingPanel, closingPanel)
        confirmEnds(for: [closingPanel.id])

        quitting.retireForWindowClose(endingSessions: false)
        closing.retireForWindowClose(endingSessions: true)

        let result = outcomes([closingPanel.id, quittingPanel.id])
        XCTAssertEqual(result[closingPanel.id], .ended)
        XCTAssertEqual(result[quittingPanel.id], HCPanelEndOutcome.none, "Quit detaches persistent sessions")
    }

    func testExecPanelWithoutIdentityIsNeverSentToHC() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let closing = try split(workspace)
        // A non-persistent identity is an exec shell: it has no hc identity to end.
        closing.surface.useExecShellForTesting()
        XCTAssertNil(closing.hcEndIdentity)
        XCTAssertFalse(workspace.closeEndsHCSession(panelIds: [closing.id]))
        XCTAssertEqual(Workspace.panelCloseCopy(endsSession: false).title, "Close panel?")

        XCTAssertTrue(workspace.closePanel(closing.id, force: true))
        settle()

        XCTAssertEqual(outcomes([closing.id], timeout: 0)[closing.id], HCPanelEndOutcome.none)
        XCTAssertTrue(session.ends.isEmpty)
    }

    /// Settled 10: an idle hc shell with only background jobs still asks,
    /// because its close ends them; an exec panel keeps today's gate.
    func testHCPanelCloseAlwaysAsksEvenAtAnIdlePrompt() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        useHC(panel)

        XCTAssertTrue(workspace.panelNeedsConfirmClose(panelId: panel.id, fallbackNeedsConfirmClose: false))

        panel.surface.useExecShellForTesting()
        XCTAssertFalse(workspace.panelNeedsConfirmClose(panelId: panel.id, fallbackNeedsConfirmClose: false))
    }

    func testHCPanelCloseConfirmationSaysEndSession() throws {
        let manager = WorkspaceManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        defer { for ws in manager.workspaces { ws.teardownAllPanels() } }
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        useHC(panel)

        XCTAssertTrue(workspace.closeEndsHCSession(panelIds: [panel.id]))
        let copy = Workspace.panelCloseCopy(endsSession: true)
        XCTAssertEqual(copy.title, "End session?")
        XCTAssertEqual(copy.confirmLabel, "End Session")
        XCTAssertTrue(copy.message.contains("nohup"))
    }
}
