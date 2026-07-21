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
        await ConversationStore.shared.applyScrape(surfaceId: surfaceId, ref: ref)
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

    // MARK: - readConversationsByPanelIdSync (regression: sync-bridge deadlock)

    /// Regression for the snapshot-capture deadlock. `Workspace` is
    /// `@MainActor`-isolated, and the original capture path used
    /// `Task { ... }` (which inherits caller isolation) while blocking
    /// main on a `DispatchSemaphore`. The task body could never run
    /// while main was blocked — every call timed out and the resulting
    /// snapshot wrote `.empty` for every panel even when the live store
    /// held a confirmed `.alive` ref. Verified end-to-end against a
    /// tagged build: alive ref pre-quit, empty `surface_conversations`
    /// post-quit, see `notes/c11-24-snapshot-capture-bug.md`.
    /// `readConversationsByPanelIdSync` uses `Task.detached` so the
    /// spawned task does not inherit `@MainActor`; this test exercises
    /// it from `@MainActor` (the deadlock-prone caller context) and
    /// asserts the actor's data is observable inside the timeout.
    func testReadConversationsByPanelIdSyncReturnsLiveData() async throws {
        let surfaceA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let surfaceB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        await ConversationStore.shared.push(
            surfaceId: surfaceA,
            kind: "claude-code",
            id: claudeSessionId,
            source: .hook,
            state: .alive
        )
        await ConversationStore.shared.push(
            surfaceId: surfaceB,
            kind: "codex",
            id: codexSessionId,
            source: .wrapperClaim,
            state: .unknown
        )

        // Call the helper from a `@MainActor` context (the same context
        // `sessionSnapshot` and `sessionAutosaveFingerprint` use at
        // runtime). With the original `Task { ... }` pattern, this
        // would deadlock against the test's main-actor wait and the
        // returned dict would be empty.
        let captured: [String: SurfaceConversations] = await MainActor.run {
            Workspace.readConversationsByPanelIdSync(timeout: 2.0)
        }

        XCTAssertEqual(captured[surfaceA]?.active?.id, claudeSessionId)
        XCTAssertEqual(captured[surfaceA]?.active?.kind, "claude-code")
        XCTAssertEqual(captured[surfaceA]?.active?.state, .alive)
        XCTAssertEqual(captured[surfaceB]?.active?.id, codexSessionId)
        XCTAssertEqual(captured[surfaceB]?.active?.kind, "codex")
    }

    /// Sanity check the empty-store contract.
    func testReadConversationsByPanelIdSyncEmptyStoreReturnsEmpty() async throws {
        // setUp clears the store; nothing else pushed.
        let captured: [String: SurfaceConversations] = await MainActor.run {
            Workspace.readConversationsByPanelIdSync(timeout: 1.0)
        }
        XCTAssertTrue(captured.isEmpty,
                      "expected empty dict from empty store; got \(captured.count) entries")
    }

    // MARK: - C11-183: autosave stalls at high surface count

    /// The autosave fingerprint must flip when any surface's active
    /// conversation ref changes (so wrapper-claim / hook-push / tombstone
    /// activity forces a save — the C11-24 invariant) and must be
    /// order-independent (dictionary iteration order must not spuriously
    /// change the fingerprint and cause churn). `hashConversationState` is
    /// the pure, off-main seam extracted from `sessionAutosaveFingerprint`
    /// so the async autosave tick can feed it the map it read via `await`
    /// instead of blocking main on a semaphore. Pure (no `Workspace`), so
    /// this one runs in the bare local xctest runner too.
    func testAutosaveConversationHashChangeSensitiveAndOrderIndependent() {
        func hash(_ map: [String: SurfaceConversations]) -> Int {
            var hasher = Hasher()
            AppDelegate.hashConversationState(map, into: &hasher)
            return hasher.finalize()
        }
        func ref(
            id: String,
            state: ConversationState = .alive,
            via: CaptureSource = .hook,
            kind: String = "claude-code"
        ) -> SurfaceConversations {
            SurfaceConversations(active: ConversationRef(
                kind: kind, id: id, capturedVia: via, state: state))
        }

        let base: [String: SurfaceConversations] = [
            "surface-a": ref(id: "sess-1"),
            "surface-b": ref(id: "sess-2"),
        ]
        // Same entries, rebuilt dict → identical hash (order-independent).
        let reordered: [String: SurfaceConversations] = [
            "surface-b": ref(id: "sess-2"),
            "surface-a": ref(id: "sess-1"),
        ]
        XCTAssertEqual(hash(base), hash(reordered),
                       "fingerprint must not depend on dictionary iteration order")

        // A changed active id / lifecycle state / capture source each flips it.
        XCTAssertNotEqual(hash(base), hash([
            "surface-a": ref(id: "sess-1-CHANGED"),
            "surface-b": ref(id: "sess-2"),
        ]), "a changed active id must change the fingerprint")
        XCTAssertNotEqual(hash(base), hash([
            "surface-a": ref(id: "sess-1", state: .tombstoned),
            "surface-b": ref(id: "sess-2"),
        ]), "a changed lifecycle state must change the fingerprint")
        XCTAssertNotEqual(hash(base), hash([
            "surface-a": ref(id: "sess-1", via: .scrape),
            "surface-b": ref(id: "sess-2"),
        ]), "a changed capture source must change the fingerprint")

        // A surface with no active ref must not contribute (empty == none),
        // so idle terminals don't force perpetual autosaves.
        let withEmpty = base.merging(["surface-c": .empty]) { existing, _ in existing }
        XCTAssertEqual(hash(base), hash(withEmpty),
                       "a surface with no active ref must not change the fingerprint")
    }

    /// C11-183: the async autosave tick reads the conversation store off-main
    /// via `await` and injects the resulting map into `sessionSnapshot`, so
    /// the 8 s tick no longer blocks main on a `DispatchSemaphore.wait`.
    /// Injection must be honored verbatim (the map the tick read is exactly
    /// what gets persisted), while synchronous callers that pass no map still
    /// fall back to the in-process store read. Both keep `surface_conversations`
    /// populated (C11-24 — guards against the C11-170 "drops under load" class).
    ///
    /// Constructs a live terminal surface → CI-only (the bare local xctest
    /// runner crashes on `Workspace` construction; see CLAUDE.md).
    func testSessionSnapshotHonorsInjectedConversationMapOverStore() async throws {
        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let surfaceId = panel.id.uuidString

        // Store holds ref X (claude) for the surface.
        await ConversationStore.shared.push(
            surfaceId: surfaceId,
            kind: "claude-code",
            id: claudeSessionId,
            source: .hook,
            state: .alive
        )

        // Inject a DIFFERENT map (ref Y, codex). Injection wins over the store.
        let injectedY = SurfaceConversations(active: ConversationRef(
            kind: "codex", id: codexSessionId, capturedVia: .scrape, state: .suspended))
        let injectedSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            conversationsByPanelId: [surfaceId: injectedY]
        )
        let injectedPanel = try XCTUnwrap(injectedSnapshot.panels.first { $0.id == panel.id })
        XCTAssertEqual(injectedPanel.surfaceConversations?.active?.id, codexSessionId,
                       "injected conversation map must be honored verbatim")
        XCTAssertEqual(injectedPanel.surfaceConversations?.active?.kind, "codex")

        // No injection → synchronous in-process store read (ref X) still populates.
        let fallbackSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        let fallbackPanel = try XCTUnwrap(fallbackSnapshot.panels.first { $0.id == panel.id })
        XCTAssertEqual(fallbackPanel.surfaceConversations?.active?.id, claudeSessionId,
                       "sync fallback must still read the live store (C11-24)")
    }
}
