import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Tests for the C11-24 backwards-compat bridge that lifts legacy
/// `claude.session_id` reserved metadata into `ConversationRef`s on
/// snapshot read. Per `CLAUDE.md`, never run locally — CI only.
final class ConversationSnapshotBridgeTests: XCTestCase {

    private let claudeSessionId = "abc12345-ef67-890a-bcde-f0123456789a"

    func testLiftLegacyClaudeSessionIdProducesScrapeRef() {
        let panel = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: "T",
            customTitle: nil,
            directory: "/work/proj",
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/work/proj", scrollback: nil),
            browser: nil,
            markdown: nil,
            metadata: [
                SurfaceMetadataKeyName.claudeSessionId: .string(claudeSessionId),
                SurfaceMetadataKeyName.terminalType: .string("claude-code")
            ],
            metadataSources: nil,
            surfaceConversations: nil
        )
        let lifted = WorkspaceSnapshotConversationBridge.liftLegacyClaudeSessionId(panel)
        XCTAssertNotNil(lifted)
        XCTAssertEqual(lifted?.kind, "claude-code")
        XCTAssertEqual(lifted?.id, claudeSessionId)
        XCTAssertEqual(lifted?.capturedVia, .scrape)
        XCTAssertEqual(lifted?.state, .unknown)
        XCTAssertEqual(lifted?.cwd, "/work/proj")
        XCTAssertEqual(lifted?.diagnosticReason,
                       "lifted from legacy claude.session_id metadata")
    }

    func testLiftReturnsNilWhenLegacyKeyAbsent() {
        let panel = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: "T",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: nil,
            markdown: nil,
            metadata: nil,
            metadataSources: nil,
            surfaceConversations: nil
        )
        XCTAssertNil(WorkspaceSnapshotConversationBridge.liftLegacyClaudeSessionId(panel))
    }

    func testLiftValidatesUUIDGrammarBeforeSynthesizingRef() {
        let panel = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: "T",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: nil,
            markdown: nil,
            metadata: [
                SurfaceMetadataKeyName.claudeSessionId: .string("not-a-uuid")
            ],
            metadataSources: nil,
            surfaceConversations: nil
        )
        XCTAssertNil(
            WorkspaceSnapshotConversationBridge.liftLegacyClaudeSessionId(panel),
            "non-UUID values must NOT be lifted (defence-in-depth)"
        )
    }

    func testSurfaceConversationsCodableEmitsHistoryAsArrayNotOmitted() throws {
        // v1 contract: history is written as `[]`, not omitted, for stable
        // JSON output across v1/v2.
        let panel = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: "T",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil),
            browser: nil,
            markdown: nil,
            metadata: nil,
            metadataSources: nil,
            surfaceConversations: SurfaceConversations(
                active: ConversationRef(
                    kind: "claude-code",
                    id: claudeSessionId,
                    capturedVia: .hook,
                    state: .alive
                ),
                history: []
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(panel)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"surface_conversations\""),
                      "field must serialize with snake-case wire name")
        XCTAssertTrue(json.contains("\"history\":[]"),
                      "history must be written as empty array, not omitted")
    }

    func testNativeFieldRoundTripsThroughCodable() throws {
        let original = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: "T",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil),
            browser: nil,
            markdown: nil,
            metadata: nil,
            metadataSources: nil,
            surfaceConversations: SurfaceConversations(
                active: ConversationRef(
                    kind: "codex",
                    id: "ddd11111-2222-3333-4444-555566667777",
                    cwd: "/p",
                    capturedVia: .scrape,
                    state: .alive,
                    diagnosticReason: "matched cwd + mtime after claim"
                ),
                history: []
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)
        XCTAssertEqual(decoded.surfaceConversations?.active?.kind, "codex")
        XCTAssertEqual(decoded.surfaceConversations?.active?.id,
                       "ddd11111-2222-3333-4444-555566667777")
        XCTAssertEqual(decoded.surfaceConversations?.history.count, 0)
    }

    func testRuntimeIdentityAndQuarantineRoundTripThroughSnapshotCodable() throws {
        let original = SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: "Codex",
            customTitle: nil,
            directory: "/work/shared",
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: "/work/shared",
                scrollback: nil
            ),
            browser: nil,
            markdown: nil,
            metadata: nil,
            metadataSources: nil,
            surfaceConversations: SurfaceConversations(
                active: ConversationRef(
                    kind: "codex",
                    id: "ddd11111-2222-4333-8444-555566667777",
                    cwd: "/work/shared",
                    capturedVia: .runtimeEnv,
                    state: .unknown,
                    quarantineReason: .conflictingCausalIdentity,
                    diagnosticReason: "quarantined:conflicting_causal_identity"
                ),
                history: []
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)
        XCTAssertEqual(decoded.surfaceConversations?.active?.capturedVia, .runtimeEnv)
        XCTAssertEqual(
            decoded.surfaceConversations?.active?.quarantineReason,
            .conflictingCausalIdentity
        )
    }

    func testKillSwitchEnvVarHonored() {
        unsetenv("CMUX_DISABLE_CONVERSATION_STORE")
        XCTAssertFalse(ConversationStorePolicy.isDisabled)
        setenv("CMUX_DISABLE_CONVERSATION_STORE", "1", 1)
        XCTAssertTrue(ConversationStorePolicy.isDisabled)
        setenv("CMUX_DISABLE_CONVERSATION_STORE", "0", 1)
        XCTAssertFalse(ConversationStorePolicy.isDisabled)
        setenv("CMUX_DISABLE_CONVERSATION_STORE", "true", 1)
        XCTAssertTrue(ConversationStorePolicy.isDisabled)
        unsetenv("CMUX_DISABLE_CONVERSATION_STORE")
    }

    @MainActor
    func testKillSwitchFallsBackToLegacyRegistryAtRestoreTime() {
        // When CMUX_DISABLE_CONVERSATION_STORE=1, the new
        // pendingRestartPlans path no-ops (the snapshot wouldn't have
        // been seeded into ConversationStore anyway). A snapshot with
        // legacy claude.session_id reserved metadata should still
        // produce a resume command via the legacy
        // AgentRestartRegistry fallback path.
        //
        // We can't invoke the private scheduleAgentRestartLegacy directly,
        // but the legacy registry's command resolution is the same logic
        // wrapped inside it. Asserting via the registry validates the
        // fallback's load-bearing semantics.
        let registry = AgentRestartRegistry.phase1
        let cmd = registry.resolveCommand(
            terminalType: "claude-code",
            sessionId: claudeSessionId,
            metadata: [:]
        )
        XCTAssertNotNil(cmd)
        XCTAssertTrue(cmd?.contains("claude --dangerously-skip-permissions --resume") ?? false)
    }
}
