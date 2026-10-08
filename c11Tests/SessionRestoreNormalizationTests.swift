import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class SessionRestoreNormalizationTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private func fixture() -> SessionWorkspaceSnapshot {
        let panels = [a, b, c].map { id in
            SessionPanelSnapshot(
                id: id, type: .terminal, title: "Synthetic", customTitle: nil,
                directory: "/tmp", isPinned: false, isManuallyUnread: false,
                gitBranch: nil, listeningPorts: [], ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp", scrollback: nil),
                browser: nil, markdown: nil, metadata: ["fixture": .string("first")],
                metadataSources: nil
            )
        }
        return SessionWorkspaceSnapshot(
            id: UUID(), processTitle: "Synthetic", customTitle: nil, customColor: nil,
            isPinned: false, currentDirectory: "/tmp", focusedPanelId: c,
            layout: .split(SessionSplitLayoutSnapshot(
                orientation: .horizontal, dividerPosition: 0.4,
                first: .pane(SessionAreaLayoutSnapshot(panelIds: [a, b], selectedPanelId: b,
                    id: UUID(), metadata: ["fixture": .string("area")], railOpen: true)),
                second: .pane(SessionAreaLayoutSnapshot(panelIds: [c], selectedPanelId: c))
            )),
            panels: panels, statusEntries: [], logEntries: [], progress: nil, gitBranch: nil
        )
    }

    private func appSnapshot(workspaces: [SessionWorkspaceSnapshot]) -> AppSessionSnapshot {
        AppSessionSnapshot(version: SessionSnapshotSchema.currentVersion, createdAt: 1, windows: [
            SessionWindowSnapshot(frame: nil, display: nil,
                workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 200))
        ])
    }

    private struct EmptyCodexScraper: ConversationScraper {
        let kind = "codex"
        func candidates(cwd: String?) -> [ScrapeCandidate] { [] }
    }

    func testStartupPreparationDeduplicatesCodexBeforeReconciliationAndPreservesFirstActivityFloor() async throws {
        var workspace = fixture()
        let firstFloor = Date(timeIntervalSince1970: 100)
        workspace.panels[0].metadata = [PanelMetadataKeyName.terminalType: .string("codex")]
        workspace.panels[0].lastActivityAt = firstFloor
        var duplicate = workspace.panels[0]
        duplicate.directory = "/tmp/discarded"
        duplicate.lastActivityAt = Date(timeIntervalSince1970: 200)
        workspace.panels.insert(duplicate, at: 1)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: encoded(appSnapshot(workspaces: [workspace])))
        var diagnostics: [String] = []
        let prepared = SessionRestoreNormalization.prepareStartupSnapshot(decoded) { diagnostics.append($0) }
        let preparedWorkspace = prepared.windows[0].workspaceManager.workspaces[0]
        XCTAssertEqual(preparedWorkspace.panels.map(\.id), [a, b, c])
        XCTAssertEqual(preparedWorkspace.panels[0].lastActivityAt, firstFloor)
        XCTAssertEqual(diagnostics, ["session.restore.drop workspace=\(workspace.id) tab=\(a) reason=duplicate_record"])

        let scope = ConversationSnapshotCaptureScope(snapshot: prepared)
        XCTAssertEqual(scope.scrapeContexts, [ScrapeCaptureContext(
            surfaceId: a.uuidString, kind: "codex", cwd: "/tmp", lastActivityTimestamp: firstFloor
        )])
        XCTAssertEqual(scope.markerSurfaceIds, Set([a, b, c].map(\.uuidString)))
        let store = ConversationStore()
        _ = await WorkspaceSnapshotConversationBridge.seedFromSnapshot(prepared, store: store)
        let pipeline = ScrapeCapturePipeline(
            scrapers: ConversationScraperRegistry(scrapers: [EmptyCodexScraper()]), strategies: .v1
        )
        let batch = try await pipeline.collectCandidateBatch(contexts: scope.scrapeContexts)
        XCTAssertEqual(batch.contexts.count, 1)
        XCTAssertEqual(batch.candidatesByKind["codex"], [])
        // This calls reconcileCodex, whose unique-key dictionary trapped when
        // startup fed it the two raw A contexts, even with zero candidates.
        _ = await store.applyScrapeBatch(batch, pipeline: pipeline)
        let active = await store.active(for: a.uuidString)
        XCTAssertNil(active)
    }

    func testStartupPreparationNormalizesEveryWorkspaceAndReportsDropsOnlyOnce() throws {
        var first = fixture()
        first.panels.append(first.panels[0])
        var second = fixture()
        second.panels.append(second.panels[1])
        var input = appSnapshot(workspaces: [first, fixture()])
        input.windows.append(appSnapshot(workspaces: [second]).windows[0])
        var diagnostics: [String] = []
        let prepared = SessionRestoreNormalization.prepareStartupSnapshot(input) { diagnostics.append($0) }
        XCTAssertEqual(prepared.windows.count, 2)
        XCTAssertEqual(prepared.windows[0].workspaceManager.workspaces.count, 2)
        XCTAssertEqual(prepared.windows.flatMap { $0.workspaceManager.workspaces }.map { $0.panels.count }, [3, 3, 3])
        XCTAssertEqual(diagnostics, [
            "session.restore.drop workspace=\(first.id) tab=\(a) reason=duplicate_record",
            "session.restore.drop workspace=\(second.id) tab=\(b) reason=duplicate_record"
        ])
        let again = SessionRestoreNormalization.prepareStartupSnapshot(prepared) { _ in XCTFail("duplicate report after preparation") }
        XCTAssertEqual(try encoded(again), try encoded(prepared))
        for window in prepared.windows {
            for workspace in window.workspaceManager.workspaces {
                XCTAssertTrue(SessionRestoreNormalization.normalize(workspace).drops.isEmpty)
            }
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testDuplicateRecordsKeepTheEntireFirstRecordAndReportEachDrop() throws {
        var input = fixture()
        let first = input.panels[0]
        var conflicting = first
        conflicting.title = "Discarded"
        conflicting.metadata = ["fixture": .string("later")]
        input.panels.insert(conflicting, at: 1)
        input.panels.append(conflicting)
        let result = SessionRestoreNormalization.normalize(input)
        XCTAssertEqual(result.snapshot.panels.map(\.id), [a, b, c])
        XCTAssertEqual(try encoded(result.snapshot.panels[0]), try encoded(first))
        XCTAssertEqual(result.drops.map(\.reason), [.duplicateRecord, .duplicateRecord])
        XCTAssertEqual(result.drops.map(\.panelId), [a, a])
        XCTAssertEqual(result.drops[0].diagnostic(workspaceId: input.id),
            "session.restore.drop workspace=\(input.id) tab=\(a) reason=duplicate_record")
        XCTAssertEqual(try encoded(result.snapshot.layout), try encoded(input.layout))
    }

    func testRepeatedReferencesWithinAndAcrossLeavesKeepFirstPlacement() throws {
        var input = fixture()
        guard case .split(var split) = input.layout,
              case .pane(var first) = split.first,
              case .pane(var second) = split.second else { return XCTFail("fixture layout") }
        first.panelIds = [a, a, b]
        second.panelIds = [a, c]
        second.selectedPanelId = a
        split.first = .pane(first)
        split.second = .pane(second)
        input.layout = .split(split)
        let result = SessionRestoreNormalization.normalize(input)
        guard case .split(let repaired) = result.snapshot.layout,
              case .pane(let left) = repaired.first,
              case .pane(let right) = repaired.second else { return XCTFail("restored layout") }
        XCTAssertEqual(left.panelIds, [a, b])
        XCTAssertEqual(left.selectedPanelId, b)
        XCTAssertEqual(right.panelIds, [c])
        XCTAssertEqual(right.selectedPanelId, c)
        XCTAssertEqual(left.id, first.id)
        XCTAssertEqual(left.railOpen, true)
        XCTAssertEqual(try encoded(left.metadata), try encoded(first.metadata))
        XCTAssertEqual(repaired.dividerPosition, 0.4)
        XCTAssertEqual(repaired.orientation, .horizontal)
        XCTAssertEqual(result.drops.map(\.reason), [.duplicateLayoutReference, .duplicateLayoutReference])
        XCTAssertEqual(result.drops.map(\.panelId), [a, a])
        XCTAssertEqual(try encoded(result.snapshot.panels), try encoded(input.panels))
    }

    func testDuplicateOnlyLeafBecomesEmptyWithoutRemovingTheArea() throws {
        var input = fixture()
        input.layout = .split(SessionSplitLayoutSnapshot(
            orientation: .vertical, dividerPosition: 0.5,
            first: .pane(SessionAreaLayoutSnapshot(panelIds: [a], selectedPanelId: a)),
            second: .pane(SessionAreaLayoutSnapshot(panelIds: [a], selectedPanelId: a))
        ))
        let result = SessionRestoreNormalization.normalize(input)
        guard case .split(let split) = result.snapshot.layout,
              case .pane(let second) = split.second else { return XCTFail("layout") }
        XCTAssertEqual(second.panelIds, [])
        XCTAssertNil(second.selectedPanelId)
    }

    func testValidSnapshotIsUnchangedAndNormalizationIsWorkspaceLocal() throws {
        let input = fixture()
        for _ in 0..<2 {
            let result = SessionRestoreNormalization.normalize(input)
            XCTAssertTrue(result.drops.isEmpty)
            XCTAssertEqual(try encoded(result.snapshot), try encoded(input))
        }
    }

    func testUnknownReferencesAndEmptyLeavesRetainExistingFallbackInputs() throws {
        var input = fixture()
        let unknown = UUID()
        input.layout = .split(SessionSplitLayoutSnapshot(
            orientation: .vertical, dividerPosition: 0.5,
            first: .pane(SessionAreaLayoutSnapshot(panelIds: [unknown], selectedPanelId: unknown)),
            second: .pane(SessionAreaLayoutSnapshot(panelIds: [], selectedPanelId: nil))
        ))
        let result = SessionRestoreNormalization.normalize(input)
        XCTAssertTrue(result.drops.isEmpty)
        XCTAssertEqual(try encoded(result.snapshot), try encoded(input))
    }

    func testCombinedDuplicateFixtureIsStableAfterEncodingAndDecoding() throws {
        var input = fixture()
        input.panels.insert(input.panels[0], at: 1)
        input.layout = .split(SessionSplitLayoutSnapshot(
            orientation: .horizontal, dividerPosition: 0.4,
            first: .pane(SessionAreaLayoutSnapshot(panelIds: [a, a, b], selectedPanelId: b)),
            second: .pane(SessionAreaLayoutSnapshot(panelIds: [a, c], selectedPanelId: a))
        ))
        let first = SessionRestoreNormalization.normalize(input)
        XCTAssertEqual(first.drops.count, 3)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: encoded(first.snapshot))
        let second = SessionRestoreNormalization.normalize(decoded)
        XCTAssertTrue(second.drops.isEmpty)
        XCTAssertEqual(try encoded(second.snapshot), try encoded(first.snapshot))
    }
}
