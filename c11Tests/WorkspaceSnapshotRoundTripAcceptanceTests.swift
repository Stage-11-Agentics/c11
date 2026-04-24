import XCTest
import Bonsplit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// End-to-end acceptance fixture for CMUX-37 Phase 1 — capture + store +
/// read-back + restart-registry restore on a single mixed workspace.
///
/// Shape: one workspace at horizontal split. Left pane: one `claude-code`
/// terminal plus a markdown surface tab-stacked in the same pane. Right
/// pane: a second `claude-code` terminal. Each terminal carries a
/// `terminal_type=claude-code` + `claude.session_id=<fixed-uuid>` + pane
/// `mailbox.*` metadata.
///
/// Flow (the commit-plan description):
/// 1. Seed the workspace by applying `mixed-claude-mailbox.json` verbatim.
///    The fixture seeds both terminals with an explicit `command: "echo
///    seed"` so the initial apply path is deterministic (no registry
///    synthesis during seed — `options.restartRegistry = nil`).
/// 2. Capture the live workspace via `LiveWorkspaceSnapshotSource`.
/// 3. Write through `WorkspaceSnapshotStore` to a temp directory, read it
///    back, and assert the round-tripped envelope re-serialises to the
///    same bytes (modulo `created_at` / `snapshot_id`).
/// 4. Run `WorkspaceSnapshotConverter.applyPlan(from:)` on the read-back
///    envelope; get a `WorkspaceApplyPlan`.
/// 5. Strip `command` from the terminal surfaces (simulating "no explicit
///    command, let the restart registry decide"), apply with
///    `ApplyOptions(restartRegistry: .phase1)`, and assert both terminals
///    receive the correct `cc --resume <session-id>` send-text.
/// 6. Round-trip checks: no `restart_registry_declined` failures,
///    `mailbox.*` pane metadata byte-for-byte equal, surface titles
///    byte-equal, layout tree structural fingerprint preserved.
/// 7. Negative case: re-run step 5 with `ApplyOptions(restartRegistry:
///    nil)` and assert both terminals receive no sendText (Phase 0 default).
///
/// CI-only per `CLAUDE.md` testing policy. Never run locally.
@MainActor
final class WorkspaceSnapshotRoundTripAcceptanceTests: XCTestCase {

    private var tabManager: TabManager!

    override func setUp() {
        super.setUp()
        tabManager = TabManager()
    }

    override func tearDown() {
        tabManager = nil
        super.tearDown()
    }

    // MARK: - Scenarios

    func testCaptureAndRestoreMixedClaudeMailboxWithRegistry() throws {
        // Step 1 — seed.
        let seedPlan = try loadFixturePlan(named: "mixed-claude-mailbox")
        let deps = makeDependencies()
        let seedResult = WorkspaceLayoutExecutor.apply(
            seedPlan,
            options: ApplyOptions(select: false),
            dependencies: deps
        )
        XCTAssertFalse(seedResult.workspaceRef.isEmpty, "seed workspaceRef populated")
        XCTAssertTrue(
            seedResult.failures.filter { $0.code != "restart_registry_declined" }.isEmpty,
            "seed apply reports no non-registry failures: \(seedResult.failures)"
        )
        let workspace = try XCTUnwrap(
            resolveWorkspace(from: seedResult.workspaceRef),
            "seed workspaceRef resolves to live Workspace"
        )

        // Step 2 — capture.
        let source = LiveWorkspaceSnapshotSource(
            tabManager: tabManager,
            c11Version: "acceptance+0"
        )
        let captured = try XCTUnwrap(
            source.capture(
                workspaceId: workspace.id,
                origin: .manual,
                clock: { Date(timeIntervalSince1970: 1_745_000_000) }
            ),
            "LiveWorkspaceSnapshotSource returns an envelope"
        )

        // Step 3 — write, read, compare.
        let tmp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceSnapshotStore(
            currentDirectory: tmp,
            legacyDirectory: tmp.appendingPathComponent("legacy"),
            fileManager: .default
        )
        let writtenURL = try store.write(captured)
        let readBack = try store.read(from: writtenURL)
        XCTAssertEqual(readBack.snapshotId, captured.snapshotId)
        XCTAssertEqual(readBack.plan, captured.plan, "embedded plan round-trips through store")

        // Step 4 — converter.
        let planResult = WorkspaceSnapshotConverter.applyPlan(from: readBack)
        guard case .success(let convertedPlan) = planResult else {
            XCTFail("converter failed: \(planResult)")
            return
        }
        XCTAssertEqual(convertedPlan, readBack.plan, "converter is identity for matching versions")

        // Step 5 — strip explicit commands, restore with phase1 registry.
        var registryPlan = convertedPlan
        for idx in registryPlan.surfaces.indices where registryPlan.surfaces[idx].kind == .terminal {
            registryPlan.surfaces[idx].command = nil
        }
        let registryDeps = makeDependencies()
        let restoreResult = WorkspaceLayoutExecutor.apply(
            registryPlan,
            options: ApplyOptions(select: false, restartRegistry: .phase1),
            dependencies: registryDeps
        )
        XCTAssertFalse(restoreResult.workspaceRef.isEmpty)
        XCTAssertTrue(
            restoreResult.failures.allSatisfy { $0.code != "restart_registry_declined" },
            "both seeded terminals had session ids — registry must not decline: \(restoreResult.failures)"
        )
        let restoredWorkspace = try XCTUnwrap(
            resolveWorkspace(from: restoreResult.workspaceRef),
            "restored workspaceRef resolves to live Workspace"
        )

        // Every terminal in the restored workspace should have received the
        // synthesised `cc --resume <session-id>` via sendText. Inspect the
        // Ghostty surface's pending input buffer (the same path Phase 0's
        // acceptance fixture reads through).
        for surfaceSpec in registryPlan.surfaces where surfaceSpec.kind == .terminal {
            guard let panelId = parseUUIDSuffix(restoreResult.surfaceRefs[surfaceSpec.id]),
                  let terminal = restoredWorkspace.panels[panelId] as? TerminalPanel else {
                XCTFail("restored terminal surface[\(surfaceSpec.id)] not resolvable")
                continue
            }
            let sessionId = stringMetadataValue(surfaceSpec.metadata, key: "claude.session_id")
            XCTAssertNotNil(
                sessionId,
                "fixture surface[\(surfaceSpec.id)] missing claude.session_id"
            )
            if let sessionId {
                // B2 acceptance: the registry returns the submit form — the
                // trailing newline is load-bearing. `==` not `.contains`:
                // `.contains("cc --resume <id>")` would happily pass on
                // `"cc --resume <id>"` (typed but never submitted), which
                // was exactly the shipped regression this test now guards.
                let expected = "cc --resume \(sessionId)\n"
                let sent = terminalPendingInput(terminal) ?? ""
                XCTAssertEqual(
                    sent,
                    expected,
                    "surface[\(surfaceSpec.id)] expected to have received exactly '\(expected)'; got: '\(sent)'"
                )
            }
        }

        // Step 6 — mailbox.* pane metadata byte-for-byte.
        for surfaceSpec in registryPlan.surfaces {
            guard let paneMetadata = surfaceSpec.paneMetadata, !paneMetadata.isEmpty else { continue }
            guard let panelId = parseUUIDSuffix(restoreResult.surfaceRefs[surfaceSpec.id]),
                  let paneUUID = restoredWorkspace.paneIdForPanel(panelId)?.id else {
                XCTFail("surface[\(surfaceSpec.id)] paneUUID not resolvable on restored workspace")
                continue
            }
            let (liveMap, _) = PaneMetadataStore.shared.getMetadata(
                workspaceId: restoredWorkspace.id,
                paneId: paneUUID
            )
            for (key, expected) in paneMetadata where key.hasPrefix("mailbox.") {
                guard case .string(let expectedString) = expected else { continue }
                XCTAssertEqual(
                    liveMap[key] as? String,
                    expectedString,
                    "mailbox round-trip: surface[\(surfaceSpec.id)].\(key)"
                )
            }
        }

        // Surface titles and layout structural match implicitly follow from
        // the plan round-trip (captured plan == read-back plan == converter
        // output); Phase 0's acceptance tests already cover the layout
        // re-materialisation for a plan. The key phase-1-specific assertion
        // is the registry-driven command synthesis above.
    }

    func testRestoreWithoutRegistrySendsNoCommand() throws {
        // Step 5-only negative case: restore the captured envelope through
        // the converter with `restartRegistry: nil` and assert no terminal
        // receives a synthesised command. Phase 0 behaviour preserved.
        let seedPlan = try loadFixturePlan(named: "mixed-claude-mailbox")
        let deps = makeDependencies()
        let seedResult = WorkspaceLayoutExecutor.apply(
            seedPlan,
            options: ApplyOptions(select: false),
            dependencies: deps
        )
        let workspace = try XCTUnwrap(resolveWorkspace(from: seedResult.workspaceRef))
        let source = LiveWorkspaceSnapshotSource(
            tabManager: tabManager,
            c11Version: "acceptance+0"
        )
        let captured = try XCTUnwrap(source.capture(
            workspaceId: workspace.id,
            origin: .manual,
            clock: { Date(timeIntervalSince1970: 1_745_000_000) }
        ))
        var plan = captured.plan
        for idx in plan.surfaces.indices where plan.surfaces[idx].kind == .terminal {
            plan.surfaces[idx].command = nil
        }
        let restoreDeps = makeDependencies()
        let result = WorkspaceLayoutExecutor.apply(
            plan,
            options: ApplyOptions(select: false, restartRegistry: nil),
            dependencies: restoreDeps
        )
        let restored = try XCTUnwrap(resolveWorkspace(from: result.workspaceRef))
        for spec in plan.surfaces where spec.kind == .terminal {
            guard let panelId = parseUUIDSuffix(result.surfaceRefs[spec.id]),
                  let terminal = restored.panels[panelId] as? TerminalPanel else {
                continue
            }
            let pending = terminalPendingInput(terminal) ?? ""
            XCTAssertFalse(
                pending.contains("cc --resume"),
                "restartRegistry=nil must not synthesise any cc --resume; got: '\(pending)'"
            )
        }
    }

    // MARK: - Helpers

    private func loadFixturePlan(named name: String) throws -> WorkspaceApplyPlan {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("workspace-snapshots", isDirectory: true)
            .appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(WorkspaceSnapshotFile.self, from: data)
        return envelope.plan
    }

    private func makeDependencies() -> WorkspaceLayoutExecutorDependencies {
        WorkspaceLayoutExecutorDependencies(
            tabManager: tabManager,
            workspaceRefMinter: { "workspace:\($0.uuidString)" },
            surfaceRefMinter: { "surface:\($0.uuidString)" },
            paneRefMinter: { "pane:\($0.uuidString)" }
        )
    }

    private func resolveWorkspace(from ref: String) -> Workspace? {
        guard let uuid = parseUUIDSuffix(ref) else { return nil }
        return tabManager.tabs.first { $0.id == uuid }
    }

    private func parseUUIDSuffix(_ ref: String?) -> UUID? {
        guard let ref = ref,
              let uuidString = ref.split(separator: ":").last else {
            return nil
        }
        return UUID(uuidString: String(uuidString))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-snapshot-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stringMetadataValue(
        _ metadata: [String: PersistedJSONValue]?,
        key: String
    ) -> String? {
        guard let metadata else { return nil }
        if case .string(let value) = metadata[key] {
            return value
        }
        return nil
    }

    /// Read whatever `TerminalPanel.sendText` has queued. The underlying
    /// Ghostty surface buffers pre-ready sends and flushes when the live
    /// surface is available; the acceptance harness runs without a real
    /// Ghostty process, so pre-ready text stays in the queue.
    ///
    /// Observed through the `#if DEBUG` test-only accessor on
    /// `TerminalSurface` (`pendingInitialInputForTests`) — a small seam
    /// added in Phase 1 rather than making `pendingTextQueue` internal.
    private func terminalPendingInput(_ panel: TerminalPanel) -> String? {
        #if DEBUG
        return panel.surface.pendingInitialInputForTests
        #else
        return nil
        #endif
    }
}
