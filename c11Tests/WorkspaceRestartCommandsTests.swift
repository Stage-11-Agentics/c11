import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-24: unit tests for the startup-restore agent-restart wiring on
/// `Workspace.pendingRestartCommands(from:registry:)` and the policy flag
/// in `SessionPersistencePolicy.agentRestartOnRestoreEnabled`.
///
/// These tests exercise the pure command-collection path. The deferred
/// `DispatchQueue.main.asyncAfter` dispatch and `TerminalPanel.sendText`
/// glue are validated end-to-end by the existing
/// `WorkspaceSnapshotRoundTripAcceptanceTests` (manual `c11 restore` rail
/// uses the same registry).
///
/// CI-only per `CLAUDE.md` testing policy. Never run locally.
@MainActor
final class WorkspaceRestartCommandsTests: XCTestCase {

    private let claudeSessionId = "abc12345-ef67-890a-bcde-f0123456789a"

    // MARK: - pendingRestartCommands

    func testExtractsResumeCommandFromTerminalSnapshot() {
        let workspace = Workspace()
        let panelId = UUID()
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: panelId,
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
                    SurfaceMetadataKeyName.claudeSessionId: .string(claudeSessionId)
                ]
            )
        ])

        let pending = workspace.pendingRestartCommands(from: snapshot, registry: .phase1)

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.panelId, panelId)
        XCTAssertEqual(
            pending.first?.command,
            "claude --dangerously-skip-permissions --resume \(claudeSessionId)\n"
        )
    }

    func testSkipsNonTerminalPanels() {
        let workspace = Workspace()
        let metadata: [String: PersistedJSONValue] = [
            SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
            SurfaceMetadataKeyName.claudeSessionId: .string(claudeSessionId)
        ]
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(id: UUID(), type: .browser, metadata: metadata),
            makePanelSnapshot(id: UUID(), type: .markdown, metadata: metadata)
        ])

        let pending = workspace.pendingRestartCommands(from: snapshot, registry: .phase1)

        XCTAssertTrue(
            pending.isEmpty,
            "browser and markdown panels must never receive a resume command, even with full metadata"
        )
    }

    func testSkipsTerminalsWithoutSessionId() {
        let workspace = Workspace()
        let snapshot = makeSnapshot(panels: [
            // terminal_type set but no claude.session_id → registry declines
            makePanelSnapshot(
                id: UUID(),
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode)
                ]
            )
        ])

        XCTAssertTrue(workspace.pendingRestartCommands(from: snapshot, registry: .phase1).isEmpty)
    }

    func testSkipsTerminalsWithoutTerminalType() {
        let workspace = Workspace()
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: UUID(),
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.claudeSessionId: .string(claudeSessionId)
                ]
            )
        ])

        XCTAssertTrue(workspace.pendingRestartCommands(from: snapshot, registry: .phase1).isEmpty)
    }

    func testSkipsTerminalsWithMissingMetadata() {
        let workspace = Workspace()
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(id: UUID(), type: .terminal, metadata: nil)
        ])

        XCTAssertTrue(workspace.pendingRestartCommands(from: snapshot, registry: .phase1).isEmpty)
    }

    func testSkipsTerminalsWithInvalidSessionId() {
        let workspace = Workspace()
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: UUID(),
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
                    SurfaceMetadataKeyName.claudeSessionId: .string("not-a-uuid")
                ]
            )
        ])

        XCTAssertTrue(
            workspace.pendingRestartCommands(from: snapshot, registry: .phase1).isEmpty,
            "registry rejects malformed UUIDs even at the boundary"
        )
    }

    func testReturnsOneCommandPerEligibleTerminal() {
        let workspace = Workspace()
        let panelA = UUID()
        let panelB = UUID()
        let panelC = UUID()
        let sessionA = "11111111-1111-4111-8111-111111111111"
        let sessionB = "22222222-2222-4222-8222-222222222222"
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: panelA,
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
                    SurfaceMetadataKeyName.claudeSessionId: .string(sessionA)
                ]
            ),
            makePanelSnapshot(
                id: panelB,
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
                    SurfaceMetadataKeyName.claudeSessionId: .string(sessionB)
                ]
            ),
            // Third terminal has no metadata → ignored.
            makePanelSnapshot(id: panelC, type: .terminal, metadata: nil)
        ])

        let pending = workspace.pendingRestartCommands(from: snapshot, registry: .phase1)
        XCTAssertEqual(pending.count, 2)
        let byPanel = Dictionary(uniqueKeysWithValues: pending.map { ($0.panelId, $0.command) })
        XCTAssertEqual(
            byPanel[panelA],
            "claude --dangerously-skip-permissions --resume \(sessionA)\n"
        )
        XCTAssertEqual(
            byPanel[panelB],
            "claude --dangerously-skip-permissions --resume \(sessionB)\n"
        )
        XCTAssertNil(byPanel[panelC])
    }

    func testIgnoresNonStringMetadataValues() {
        // The store rejects non-string writes for these reserved keys, so this
        // path is defensive only — but the helper must not crash or coerce
        // a number/bool into a UUID.
        let workspace = Workspace()
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: UUID(),
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .number(42),
                    SurfaceMetadataKeyName.claudeSessionId: .bool(true)
                ]
            )
        ])
        XCTAssertTrue(workspace.pendingRestartCommands(from: snapshot, registry: .phase1).isEmpty)
    }

    // MARK: - claude.session_project_dir

    func testPrependsCdWhenProjectDirRecorded() {
        let workspace = Workspace()
        let panelId = UUID()
        let projectDir = "/Users/test/repo/c11-worktrees/feature-branch"
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: panelId,
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
                    SurfaceMetadataKeyName.claudeSessionId: .string(claudeSessionId),
                    SurfaceMetadataKeyName.claudeSessionProjectDir: .string(projectDir)
                ]
            )
        ])

        let pending = workspace.pendingRestartCommands(from: snapshot, registry: .phase1)

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(
            pending.first?.command,
            "cd '\(projectDir)' && claude --dangerously-skip-permissions --resume \(claudeSessionId)\n"
        )
    }

    func testFallsBackToBareResumeWhenProjectDirAbsent() {
        // Existing surfaces captured before the project_dir field shipped
        // must keep working — bare `claude --resume` is the right behavior.
        let workspace = Workspace()
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: UUID(),
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
                    SurfaceMetadataKeyName.claudeSessionId: .string(claudeSessionId)
                ]
            )
        ])

        let pending = workspace.pendingRestartCommands(from: snapshot, registry: .phase1)

        XCTAssertEqual(
            pending.first?.command,
            "claude --dangerously-skip-permissions --resume \(claudeSessionId)\n"
        )
    }

    func testFallsBackToBareResumeWhenProjectDirMalformed() {
        // The store rejects malformed paths at write time, but registry
        // re-validation must still drop a bypass. Defense-in-depth: a
        // relative path or one with shell metacharacters cannot become
        // part of the synthesized command.
        let workspace = Workspace()
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: UUID(),
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
                    SurfaceMetadataKeyName.claudeSessionId: .string(claudeSessionId),
                    // Relative path → registry rejects, falls back to bare.
                    SurfaceMetadataKeyName.claudeSessionProjectDir: .string("relative/path")
                ]
            )
        ])

        let pending = workspace.pendingRestartCommands(from: snapshot, registry: .phase1)

        XCTAssertEqual(
            pending.first?.command,
            "claude --dangerously-skip-permissions --resume \(claudeSessionId)\n",
            "registry must drop a malformed project_dir rather than emit it"
        )
    }

    func testProjectDirWithSpacesIsSingleQuoted() {
        // Real-world paths can have spaces. The single-quote escape must
        // wrap the whole path so `cd` receives one argument.
        let workspace = Workspace()
        let projectDir = "/Users/test/My Projects/repo"
        let snapshot = makeSnapshot(panels: [
            makePanelSnapshot(
                id: UUID(),
                type: .terminal,
                metadata: [
                    SurfaceMetadataKeyName.terminalType: .string(SurfaceMetadataKeyName.terminalTypeClaudeCode),
                    SurfaceMetadataKeyName.claudeSessionId: .string(claudeSessionId),
                    SurfaceMetadataKeyName.claudeSessionProjectDir: .string(projectDir)
                ]
            )
        ])

        let pending = workspace.pendingRestartCommands(from: snapshot, registry: .phase1)

        XCTAssertEqual(
            pending.first?.command,
            "cd '\(projectDir)' && claude --dangerously-skip-permissions --resume \(claudeSessionId)\n"
        )
    }

    // MARK: - stringValues helper

    func testStringValuesKeepsOnlyStringEntries() {
        let mixed: [String: PersistedJSONValue] = [
            "kept": .string("hello"),
            "dropped_number": .number(1.5),
            "dropped_bool": .bool(true),
            "dropped_null": .null,
            "dropped_array": .array([.string("x")]),
            "dropped_object": .object(["k": .string("v")])
        ]
        let coerced = Workspace.stringValues(from: mixed)
        XCTAssertEqual(coerced, ["kept": "hello"])
    }

    func testStringValuesNilReturnsEmpty() {
        XCTAssertTrue(Workspace.stringValues(from: nil).isEmpty)
    }

    // MARK: - Fixtures

    private func makeSnapshot(
        panels: [SessionPanelSnapshot]
    ) -> SessionWorkspaceSnapshot {
        // The layout is irrelevant to pendingRestartCommands; build a minimal
        // single-pane node referencing the first panel id (or a fresh UUID
        // when no panels are supplied) so the snapshot is still well-formed.
        let firstPanelId = panels.first?.id ?? UUID()
        return SessionWorkspaceSnapshot(
            id: UUID(),
            processTitle: "test",
            customTitle: nil,
            stableDefaultTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [firstPanelId],
                selectedPanelId: nil
            )),
            panels: panels,
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            metadata: nil
        )
    }

    private func makePanelSnapshot(
        id: UUID,
        type: PanelType,
        metadata: [String: PersistedJSONValue]?
    ) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: type,
            title: nil,
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
            metadata: metadata,
            metadataSources: nil
        )
    }
}
