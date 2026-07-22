import Bonsplit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class BrowserCompanionWorkspaceTests: XCTestCase {
    private let metadataStore = SurfaceMetadataStore.shared
    private var previousFeatureEnvironment: String?

    override func setUp() {
        super.setUp()
        previousFeatureEnvironment = getenv(AgentCompanionBrowserFeature.environmentKey)
            .map { String(cString: $0) }
        // Xcode's hosted XCTest launcher does not inherit arbitrary shell
        // environment variables from xcodebuild. Enable the default-off
        // feature process-locally for this behavioral fixture.
        setenv(AgentCompanionBrowserFeature.environmentKey, "1", 1)
    }

    override func tearDown() {
        if let previousFeatureEnvironment {
            setenv(
                AgentCompanionBrowserFeature.environmentKey,
                previousFeatureEnvironment,
                1
            )
        } else {
            unsetenv(AgentCompanionBrowserFeature.environmentKey)
        }
        previousFeatureEnvironment = nil
        super.tearDown()
    }

    private func initialTerminalID(in workspace: Workspace) throws -> UUID {
        try XCTUnwrap(
            workspace.panels.first(where: { $0.value is TerminalPanel })?.key,
            "Workspace should seed a terminal"
        )
    }

    private func paneID(in workspace: Workspace) throws -> PaneID {
        try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
    }

    private func setTerminalKind(
        _ kind: String,
        surfaceID: UUID,
        workspace: Workspace
    ) throws {
        _ = try metadataStore.setMetadata(
            workspaceId: workspace.id,
            surfaceId: surfaceID,
            partial: [MetadataKey.terminalType: kind],
            mode: .merge,
            source: .explicit
        )
    }

    private func clearTerminalKind(surfaceID: UUID, workspace: Workspace) throws {
        _ = try metadataStore.clearMetadata(
            workspaceId: workspace.id,
            surfaceId: surfaceID,
            keys: [MetadataKey.terminalType],
            source: .explicit
        )
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func testExplicitAgentFocusEstablishesContextWhileMaintenanceAndNonAgentFocusPreserveIt() async throws {
        XCTAssertTrue(AgentCompanionBrowserFeature.isEnabled)
        let workspace = Workspace()
        let pane = try paneID(in: workspace)
        let agent = try initialTerminalID(in: workspace)
        try setTerminalKind("codex", surfaceID: agent, workspace: workspace)
        await drainMainQueue()

        workspace.focusPanel(agent, agentContextProvenance: .maintenance)
        XCTAssertNil(workspace.agentContextState.activeAgentSurfaceID)

        workspace.focusPanel(
            agent,
            trigger: .terminalFirstResponder,
            currentEventType: nil
        )
        XCTAssertNil(
            workspace.agentContextState.activeAgentSurfaceID,
            "Programmatic first-responder maintenance must not establish context"
        )

        workspace.focusPanel(
            agent,
            trigger: .terminalFirstResponder,
            currentEventType: .leftMouseDown
        )
        XCTAssertEqual(workspace.agentContextState.activeAgentSurfaceID, agent)
        XCTAssertEqual(workspace.agentContextState.generation, 1)

        let browser = try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, focus: false))
        workspace.focusPanel(browser.id, agentContextProvenance: .operatorInteraction)
        XCTAssertEqual(workspace.agentContextState.activeAgentSurfaceID, agent)

        let markdown = try XCTUnwrap(workspace.newMarkdownSurface(inPane: pane, focus: false))
        workspace.focusPanel(markdown.id, agentContextProvenance: .operatorInteraction)
        XCTAssertEqual(workspace.agentContextState.activeAgentSurfaceID, agent)

        let shell = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        try setTerminalKind("shell", surfaceID: shell.id, workspace: workspace)
        await drainMainQueue()
        workspace.focusPanel(shell.id, agentContextProvenance: .operatorInteraction)
        XCTAssertEqual(workspace.agentContextState.activeAgentSurfaceID, agent)

        XCTAssertTrue(
            metadataStore.setInternal(
                workspaceId: workspace.id,
                surfaceId: agent,
                key: MetadataKey.activity,
                value: "working",
                source: .derived
            )
        )
        await drainMainQueue()
        XCTAssertEqual(
            workspace.agentContextState.activeAgentSurfaceID,
            agent,
            "Background activity must not establish or replace context"
        )
    }

    func testFocusedUnknownTerminalPromotesLateAndDemotionOrphansUntilReclassification() async throws {
        let workspace = Workspace()
        let pane = try paneID(in: workspace)
        let candidate = try initialTerminalID(in: workspace)
        try setTerminalKind("shell", surfaceID: candidate, workspace: workspace)
        await drainMainQueue()

        workspace.focusPanel(candidate, agentContextProvenance: .operatorInteraction)
        XCTAssertNil(workspace.agentContextState.activeAgentSurfaceID)

        try setTerminalKind("codex", surfaceID: candidate, workspace: workspace)
        await drainMainQueue()
        XCTAssertEqual(workspace.agentContextState.activeAgentSurfaceID, candidate)
        XCTAssertEqual(workspace.agentContextState.generation, 1)

        let browser = try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, focus: false))
        workspace.setPanelCustomTitle(panelId: candidate, title: "Candidate Agent")
        try workspace.linkBrowser(browser.id, toAgent: candidate)
        XCTAssertEqual(browser.linkedAgent?.lastKnownName, "Candidate Agent")
        workspace.setPanelCustomTitle(panelId: candidate, title: "Renamed Agent")
        XCTAssertEqual(browser.linkedAgent?.lastKnownName, "Renamed Agent")
        XCTAssertEqual(workspace.companionPresentation(for: browser.id).state, .aligned)

        try clearTerminalKind(surfaceID: candidate, workspace: workspace)
        await drainMainQueue()
        XCTAssertNil(workspace.agentContextState.activeAgentSurfaceID)
        XCTAssertEqual(workspace.agentContextState.generation, 2)
        XCTAssertEqual(workspace.companionPresentation(for: browser.id).state, .orphaned)
        XCTAssertEqual(browser.linkedAgent?.lastKnownName, "Renamed Agent")

        try setTerminalKind("codex", surfaceID: candidate, workspace: workspace)
        await drainMainQueue()
        XCTAssertEqual(workspace.agentContextState.activeAgentSurfaceID, candidate)
        XCTAssertEqual(workspace.agentContextState.generation, 3)
        XCTAssertEqual(workspace.companionPresentation(for: browser.id).state, .aligned)
    }

    func testManyBrowserLinksRevealRevocationAndLinkMutationsDoNotChangeFocus() async throws {
        let workspace = Workspace()
        let pane = try paneID(in: workspace)
        let agentA = try initialTerminalID(in: workspace)
        let agentB = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        try setTerminalKind("codex", surfaceID: agentA, workspace: workspace)
        try setTerminalKind("claude-code", surfaceID: agentB.id, workspace: workspace)
        await drainMainQueue()

        let browserA = try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, focus: false))
        let browserB = try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, focus: false))
        try workspace.linkBrowser(browserA.id, toAgent: agentA)
        try workspace.linkBrowser(browserB.id, toAgent: agentA)

        workspace.focusPanel(agentB.id, agentContextProvenance: .operatorInteraction)
        XCTAssertEqual(workspace.companionPresentation(for: browserA.id).state, .veiled)
        XCTAssertEqual(workspace.companionPresentation(for: browserB.id).state, .veiled)

        let focusedBeforeMutation = workspace.focusedPanelId
        try workspace.linkBrowser(browserB.id, toAgent: agentB.id)
        try workspace.unlinkBrowser(browserB.id)
        try workspace.linkBrowser(browserB.id, toAgent: agentA)
        XCTAssertEqual(workspace.focusedPanelId, focusedBeforeMutation)

        workspace.focusPanel(browserA.id, agentContextProvenance: .operatorInteraction)
        try workspace.revealBrowser(browserA.id)
        XCTAssertEqual(workspace.companionPresentation(for: browserA.id).state, .revealed)

        workspace.focusPanel(browserA.id, agentContextProvenance: .operatorInteraction)
        XCTAssertEqual(
            workspace.companionPresentation(for: browserA.id).state,
            .revealed,
            "Focus changes within the same browser must retain its reveal"
        )

        try workspace.linkBrowser(browserA.id, toAgent: agentB.id)
        try workspace.linkBrowser(browserA.id, toAgent: agentA)
        XCTAssertEqual(
            workspace.companionPresentation(for: browserA.id).state,
            .veiled,
            "Changing a link must revoke the prior reveal grant"
        )
        try workspace.revealBrowser(browserA.id)

        workspace.focusPanel(browserB.id, agentContextProvenance: .operatorInteraction)
        XCTAssertEqual(workspace.companionPresentation(for: browserA.id).state, .veiled)
        try workspace.revealBrowser(browserB.id)
        XCTAssertEqual(workspace.companionPresentation(for: browserB.id).state, .revealed)
        workspace.revokeAgentCompanionReveals()
        XCTAssertEqual(workspace.companionPresentation(for: browserB.id).state, .veiled)
    }

    func testAutomaticLinkResultsAndWireSnapshotUseLiveWorkspaceIdentity() async throws {
        let workspace = Workspace()
        let pane = try paneID(in: workspace)
        let agent = try initialTerminalID(in: workspace)
        let shell = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: false))
        let browser = try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, focus: false))
        try setTerminalKind("codex", surfaceID: agent, workspace: workspace)
        try setTerminalKind("shell", surfaceID: shell.id, workspace: workspace)
        await drainMainQueue()

        XCTAssertEqual(
            workspace.automaticLinkBrowser(browser.id, callerSurfaceID: nil, mode: .automatic),
            .noCaller
        )
        XCTAssertEqual(
            workspace.automaticLinkBrowser(
                browser.id,
                callerSurfaceID: shell.id,
                mode: .automatic
            ),
            .callerNotAgent
        )

        let focusedBeforeLink = workspace.focusedPanelId
        XCTAssertEqual(
            workspace.automaticLinkBrowser(
                browser.id,
                callerSurfaceID: agent,
                mode: .automatic
            ),
            .automatic
        )
        XCTAssertEqual(workspace.focusedPanelId, focusedBeforeLink)

        let linkedSnapshot = try XCTUnwrap(workspace.companionWireSnapshot(for: browser.id))
        XCTAssertEqual(linkedSnapshot.kind, "agent_companion")
        XCTAssertEqual(linkedSnapshot.browserSurfaceID, browser.id)
        XCTAssertEqual(linkedSnapshot.linkedAgentSurfaceID, agent)
        XCTAssertEqual(linkedSnapshot.linkState, .resolved)
        XCTAssertEqual(linkedSnapshot.presentationState, .linkedNoContext)
        XCTAssertTrue(linkedSnapshot.browserSurfaceRef.hasPrefix("surface:"))
        XCTAssertTrue(linkedSnapshot.linkedAgentSurfaceRef?.hasPrefix("surface:") == true)

        workspace.focusPanel(agent, agentContextProvenance: .explicitFocusCommand)
        let activeSnapshot = try XCTUnwrap(workspace.companionWireSnapshot(for: browser.id))
        XCTAssertEqual(activeSnapshot.presentationState, .aligned)
        XCTAssertEqual(activeSnapshot.activeAgentSurfaceID, agent)
        XCTAssertTrue(activeSnapshot.activeAgentSurfaceRef?.hasPrefix("surface:") == true)

        XCTAssertEqual(
            workspace.automaticLinkBrowser(browser.id, callerSurfaceID: agent, mode: .workspace),
            .workspace
        )
        XCTAssertEqual(workspace.companionPresentation(for: browser.id).state, .unlinked)
    }

    func testCrossWorkspaceValidationAndDetachAttachPreserveDurableLink() async throws {
        let manager = TabManager()
        let source = try XCTUnwrap(manager.selectedWorkspace)
        let destination = manager.addWorkspace(select: false)
        let sourcePane = try paneID(in: source)
        let destinationPane = try paneID(in: destination)
        let sourceAgent = try initialTerminalID(in: source)
        try setTerminalKind("codex", surfaceID: sourceAgent, workspace: source)
        await drainMainQueue()

        let sourceBrowser = try XCTUnwrap(source.newBrowserSurface(inPane: sourcePane, focus: false))
        let destinationBrowser = try XCTUnwrap(
            destination.newBrowserSurface(inPane: destinationPane, focus: false)
        )
        try source.linkBrowser(sourceBrowser.id, toAgent: sourceAgent)

        XCTAssertThrowsError(
            try destination.linkBrowser(destinationBrowser.id, toAgent: sourceAgent)
        ) { error in
            XCTAssertEqual(error as? BrowserCompanionLinkError, .linkWorkspaceMismatch)
        }

        let browserTransfer = try XCTUnwrap(source.detachSurface(panelId: sourceBrowser.id))
        let movedBrowserID = try XCTUnwrap(
            destination.attachDetachedSurface(browserTransfer, inPane: destinationPane, focus: false)
        )
        let movedBrowser = try XCTUnwrap(destination.panels[movedBrowserID] as? BrowserPanel)
        XCTAssertEqual(movedBrowser.linkedAgent?.surfaceID, sourceAgent)
        XCTAssertEqual(destination.companionPresentation(for: movedBrowserID).state, .orphaned)

        let agentTransfer = try XCTUnwrap(source.detachSurface(panelId: sourceAgent))
        let movedAgentID = try XCTUnwrap(
            destination.attachDetachedSurface(agentTransfer, inPane: destinationPane, focus: false)
        )
        await drainMainQueue()

        XCTAssertEqual(movedAgentID, sourceAgent)
        XCTAssertEqual(movedBrowser.linkedAgent?.surfaceID, movedAgentID)
        XCTAssertEqual(
            destination.companionPresentation(for: movedBrowserID).state,
            .linkedNoContext
        )
        XCTAssertNil(
            destination.agentContextState.activeAgentSurfaceID,
            "Move/attach maintenance must not establish context"
        )
    }

    func testInsertAtEndReorderPreservesExplicitLatePromotionCandidate() async throws {
        let workspace = Workspace()
        let pane = try paneID(in: workspace)
        let candidate = try initialTerminalID(in: workspace)
        try setTerminalKind("shell", surfaceID: candidate, workspace: workspace)
        await drainMainQueue()

        workspace.focusPanel(candidate, agentContextProvenance: .operatorInteraction)
        XCTAssertNil(workspace.agentContextState.activeAgentSurfaceID)
        let focusedBeforeInsert = workspace.focusedPanelId

        XCTAssertNotNil(
            workspace.newBrowserSurface(
                inPane: pane,
                focus: false,
                insertAtEnd: true
            )
        )
        XCTAssertEqual(workspace.focusedPanelId, focusedBeforeInsert)

        try setTerminalKind("codex", surfaceID: candidate, workspace: workspace)
        await drainMainQueue()
        XCTAssertEqual(
            workspace.agentContextState.activeAgentSurfaceID,
            candidate,
            "Maintenance reorder callbacks must not clear explicit late-promotion intent"
        )
    }

    func testIndexedAttachWithoutFocusPreservesDestinationAgentContext() async throws {
        let manager = TabManager()
        let source = try XCTUnwrap(manager.selectedWorkspace)
        let destination = manager.addWorkspace(select: false)
        let destinationPane = try paneID(in: destination)
        let sourceAgent = try initialTerminalID(in: source)
        let destinationAgent = try initialTerminalID(in: destination)
        try setTerminalKind("codex", surfaceID: sourceAgent, workspace: source)
        try setTerminalKind("claude-code", surfaceID: destinationAgent, workspace: destination)
        await drainMainQueue()

        destination.focusPanel(
            destinationAgent,
            agentContextProvenance: .explicitFocusCommand
        )
        let generationBeforeAttach = destination.agentContextState.generation
        let focusedBeforeAttach = destination.focusedPanelId
        let transfer = try XCTUnwrap(source.detachSurface(panelId: sourceAgent))

        XCTAssertEqual(
            destination.attachDetachedSurface(
                transfer,
                inPane: destinationPane,
                atIndex: 0,
                focus: false
            ),
            sourceAgent
        )
        await drainMainQueue()

        XCTAssertEqual(destination.focusedPanelId, focusedBeforeAttach)
        XCTAssertEqual(destination.agentContextState.activeAgentSurfaceID, destinationAgent)
        XCTAssertEqual(destination.agentContextState.generation, generationBeforeAttach)
    }
}
