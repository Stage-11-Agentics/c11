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
}
