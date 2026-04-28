import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-24: replaces the old `WorkspaceRestartCommandsTests` (which keyed
/// off the legacy `claude.session_id` reserved-metadata path). The new
/// `Workspace.pendingRestartPlans(from:registry:)` reads from the
/// `ConversationStore.shared` actor; this exercises that path end-to-end
/// (in-process, no socket).
///
/// Per `CLAUDE.md`, never run locally — CI only.
@MainActor
final class WorkspaceConversationResumeTests: XCTestCase {

    private let claudeSessionId = "abc12345-ef67-890a-bcde-f0123456789a"
    private let codexSessionId = "ddd11111-2222-3333-4444-555566667777"

    override func setUp() async throws {
        try await super.setUp()
        // Each test starts with a clean store so prior tests' state
        // doesn't leak into the snapshot read.
        for surfaceId in await ConversationStore.shared.snapshot().keys {
            await ConversationStore.shared.clear(surfaceId: surfaceId)
        }
    }

    // MARK: - pendingRestartPlans

    func testEmitsTypeCommandPlanForClaudeCode() async throws {
        let workspace = Workspace()
        let panelId = UUID()
        let surfaceId = panelId.uuidString
        await ConversationStore.shared.push(
            surfaceId: surfaceId,
            kind: "claude-code",
            id: claudeSessionId,
            source: .hook,
            state: .suspended
        )
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(id: panelId, type: .terminal, metadata: nil)
        ])
        let plans = workspace.pendingRestartPlans(
            from: snapshot,
            registry: ConversationStrategyRegistry.v1
        )
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.panelId, panelId)
        guard case .typeCommand(let text, let submit) = plans.first?.action else {
            XCTFail("expected typeCommand")
            return
        }
        XCTAssertTrue(submit)
        XCTAssertTrue(text.contains("claude --dangerously-skip-permissions --resume"))
        XCTAssertTrue(text.contains(claudeSessionId))
    }

    func testCodexAmbiguousRefSkipsViaPlans() async throws {
        let workspace = Workspace()
        let panelId = UUID()
        let surfaceId = panelId.uuidString
        // Manually write an ambiguous ref (state=unknown) — same shape as
        // the strategy would emit when there's >1 candidate.
        let ref = ConversationRef(
            kind: "codex",
            id: codexSessionId,
            placeholder: false,
            cwd: "/work/proj",
            capturedAt: Date(),
            capturedVia: .scrape,
            state: .unknown,
            diagnosticReason: "ambiguous: 2 candidates; chose newest"
        )
        await ConversationStore.shared.recordScrape(surfaceId: surfaceId, ref: ref)
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(id: panelId, type: .terminal, metadata: nil)
        ])
        let plans = workspace.pendingRestartPlans(
            from: snapshot,
            registry: ConversationStrategyRegistry.v1
        )
        XCTAssertTrue(plans.isEmpty,
                      "ambiguous (unknown) Codex ref must NOT generate a resume plan — that's the merge-blocker behaviour")
    }

    func testPolicyDisabledReturnsEmptyPlans() async throws {
        // CMUX_DISABLE_AGENT_RESTART is read from the env at every read, so
        // setenv-then-unset makes the test hermetic.
        setenv("CMUX_DISABLE_AGENT_RESTART", "1", 1)
        defer { unsetenv("CMUX_DISABLE_AGENT_RESTART") }

        let workspace = Workspace()
        let panelId = UUID()
        await ConversationStore.shared.push(
            surfaceId: panelId.uuidString,
            kind: "claude-code",
            id: claudeSessionId,
            source: .hook,
            state: .suspended
        )
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(id: panelId, type: .terminal, metadata: nil)
        ])
        let plans = workspace.pendingRestartPlans(
            from: snapshot,
            registry: ConversationStrategyRegistry.v1
        )
        XCTAssertTrue(plans.isEmpty)
    }

    // MARK: - Helpers (mirror the deleted WorkspaceRestartCommandsTests
    // helpers so this file is self-contained).

    private func makePanelSnapshot(
        id: UUID,
        type: PanelType,
        metadata: [String: PersistedJSONValue]? = nil
    ) -> SessionPanelSnapshot {
        return SessionPanelSnapshot(
            id: id,
            type: type,
            title: "Test",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: type == .terminal ? SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil) : nil,
            browser: nil,
            markdown: nil,
            metadata: metadata,
            metadataSources: nil
        )
    }

    private func makeSnapshot(panels: [SessionPanelSnapshot]) -> SessionWorkspaceSnapshot {
        return SessionWorkspaceSnapshot(
            id: UUID(),
            processTitle: "Test",
            customTitle: nil,
            stableDefaultTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: panels.map { $0.id }, selectedPanelId: panels.first?.id)),
            panels: panels,
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            metadata: nil
        )
    }
}
