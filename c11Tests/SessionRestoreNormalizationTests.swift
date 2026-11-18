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

    // MARK: C11H-46: hc twins across workspaces and windows

    private func atlasKey(_ address: String) -> HCTerminalKey { HCTerminalKey(owningCoreID: "atlas-core", localAddress: address) }

    private func terminal(_ id: UUID, _ key: HCTerminalKey?) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id, type: .terminal, title: "Terminal", customTitle: nil,
            directory: nil, isPinned: false, isManuallyUnread: false,
            gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil,
                hcIdentity: key.map { HCPanelIdentity(panelID: id, key: $0) }, hcRemoteTarget: HCRemoteTarget(machine: "studio")),
            browser: nil, markdown: nil, metadata: nil, metadataSources: nil
        )
    }

    private func workspace(_ panels: [SessionPanelSnapshot], recovered: Bool = false) -> SessionWorkspaceSnapshot {
        var snapshot = SessionWorkspaceSnapshot(
            id: UUID(), processTitle: "W", customTitle: recovered ? "Recovered" : nil, customColor: nil,
            isPinned: false, currentDirectory: "/tmp", focusedPanelId: panels.last?.id,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: panels.map(\.id), selectedPanelId: panels.last?.id)),
            panels: panels, statusEntries: [], logEntries: [], progress: nil, gitBranch: nil
        )
        if recovered { snapshot.metadata = ["c11h.recovered": "true"] }
        return snapshot
    }

    private func window(_ workspaces: [SessionWorkspaceSnapshot], selected: Int = 0) -> SessionWindowSnapshot {
        SessionWindowSnapshot(frame: nil, display: nil,
            workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: selected, workspaces: workspaces),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 200))
    }

    private func app(_ windows: [SessionWindowSnapshot]) -> AppSessionSnapshot {
        AppSessionSnapshot(version: SessionSnapshotSchema.currentVersion, createdAt: 1, windows: windows)
    }

    private func panelIDs(_ snapshot: AppSessionSnapshot) -> [[[UUID]]] {
        snapshot.windows.map { $0.workspaceManager.workspaces.map { $0.panels.map(\.id) } }
    }

    private func layoutIDs(_ node: SessionWorkspaceLayoutSnapshot) -> [UUID] {
        switch node {
        case .pane(let pane): return pane.panelIds
        case .split(let split): return layoutIDs(split.first) + layoutIDs(split.second)
        }
    }

    /// sol review 1, item 2: the original in window A, its Recovered twin the
    /// only panel of window B. The twin and its now-empty window are gone
    /// before any panel exists; the original is untouched.
    func testATwinAloneInItsWindowIsRemovedWithThatWindow() throws {
        let ticker = UUID(), other = UUID()
        let original = window([workspace([terminal(other, atlasKey("t2")), terminal(ticker, atlasKey("t1"))])])
        let twin = window([workspace([terminal(ticker, atlasKey("t1"))], recovered: true)])
        var diagnostics: [String] = []
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: encoded(app([twin, original])))
        let prepared = SessionRestoreNormalization.prepareStartupSnapshot(decoded) { diagnostics.append($0) }
        XCTAssertEqual(panelIDs(prepared), [[[other, ticker]]])
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].hasPrefix("hc.duplicate_binding.dropped panel=\(ticker)"), diagnostics[0])
        XCTAssertTrue(diagnostics[0].hasSuffix("terminals=atlas-core/t1"), diagnostics[0])
    }

    /// The laptop's shape: Workspace 1 holds the ticker and shell beside
    /// other panels; Recovered holds their twins and an unrelated orphan.
    /// The twins leave Recovered's panels and layout; the rest stay.
    func testRecoveredTwinsLeaveTheirWorkspaceAndLayoutAndTheOriginalsStay() {
        let ticker = UUID(), shell = UUID(), cat = UUID(), orphan = UUID()
        let one = workspace([terminal(cat, atlasKey("t2")), terminal(ticker, atlasKey("t1")), terminal(shell, atlasKey("t5"))])
        var recovered = workspace([terminal(shell, atlasKey("t5")), terminal(orphan, atlasKey("t9")),
                                   terminal(ticker, atlasKey("t1"))], recovered: true)
        recovered.focusedPanelId = ticker
        let prepared = SessionRestoreNormalization.dropHCTwins(app([window([recovered, one], selected: 1)])) { _ in }
        XCTAssertEqual(panelIDs(prepared), [[[orphan], [cat, ticker, shell]]])
        let kept = prepared.windows[0].workspaceManager.workspaces
        XCTAssertEqual(layoutIDs(kept[0].layout), [orphan])
        XCTAssertEqual(kept[0].focusedPanelId, orphan)
        XCTAssertEqual(layoutIDs(kept[1].layout), [cat, ticker, shell])
        XCTAssertEqual(prepared.windows[0].workspaceManager.selectedWorkspaceIndex, 1, "the selection follows its workspace")
    }

    /// One terminal saved under two UUIDs keeps the first; an emptied
    /// workspace goes, and the window's selection moves to what remains.
    func testOneTerminalUnderTwoUUIDsKeepsTheFirstAndDropsTheEmptiedWorkspace() {
        let first = UUID(), second = UUID(), local = UUID()
        let prepared = SessionRestoreNormalization.dropHCTwins(app([window([
            workspace([terminal(first, atlasKey("t1")), terminal(local, nil)]),
            workspace([terminal(second, atlasKey("t1"))]),
        ], selected: 1)])) { _ in }
        XCTAssertEqual(panelIDs(prepared), [[[first, local]]])
        XCTAssertEqual(prepared.windows[0].workspaceManager.selectedWorkspaceIndex, 0)
    }

    /// A split side left empty collapses into its sibling.
    func testAnEmptiedSplitSideCollapses() {
        let ticker = UUID(), keep = UUID()
        let one = workspace([terminal(ticker, atlasKey("t1"))])
        var two = workspace([terminal(keep, atlasKey("t3")), terminal(ticker, atlasKey("t1"))], recovered: true)
        two.layout = .split(SessionSplitLayoutSnapshot(orientation: .vertical, dividerPosition: 0.5,
            first: .pane(SessionAreaLayoutSnapshot(panelIds: [keep], selectedPanelId: keep)),
            second: .pane(SessionAreaLayoutSnapshot(panelIds: [ticker], selectedPanelId: ticker))))
        let prepared = SessionRestoreNormalization.dropHCTwins(app([window([one, two])])) { _ in }
        guard case .pane(let pane) = prepared.windows[0].workspaceManager.workspaces[1].layout else {
            return XCTFail("the split should collapse to its remaining pane")
        }
        XCTAssertEqual(pane.panelIds, [keep])
    }

    func testNoTwinsLeavesTheSnapshotAsIs() {
        let input = app([window([workspace([terminal(UUID(), atlasKey("t1")), terminal(UUID(), nil), terminal(UUID(), nil)])]),
                         window([workspace([terminal(UUID(), atlasKey("t2"))])])])
        var diagnostics: [String] = []
        let prepared = SessionRestoreNormalization.dropHCTwins(input) { diagnostics.append($0) }
        XCTAssertEqual(panelIDs(prepared), panelIDs(input))
        XCTAssertTrue(diagnostics.isEmpty)
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

    // MARK: C11H-171 explicit metadata title

    /// The h4→h5 panel: metadata title source explicit, no customTitle.
    /// The restored tab shows that title, and it is not a custom title.
    @MainActor
    func testExplicitMetadataTitleRestoresWithoutCustomTitle() throws {
        let workspace = try restoreTitlePanel(Self.explicitTitleFixture(source: "explicit"))
        defer { retire(workspace) }
        let panelId = try panelId()
        XCTAssertNil(workspace.panelCustomTitles[panelId])
        XCTAssertEqual(workspace.displayedTabTitle(panelId: panelId), "Glideslope · Chrono")
        XCTAssertEqual(
            workspace.resolvedPanelTitle(panelId: panelId, fallback: workspace.panelTitles[panelId] ?? ""),
            "Glideslope · Chrono"
        )
    }

    /// set-title writes metadata and syncs the tab. It does not write a custom
    /// title, so the tab changes. A later OSC title loses to the explicit one.
    @MainActor
    func testSetTitleAfterRestoreChangesDisplayedTitle() throws {
        let workspace = try restoreTitlePanel(Self.explicitTitleFixture(source: "explicit"))
        defer { retire(workspace) }
        let panelId = try panelId()
        XCTAssertEqual(workspace.displayedTabTitle(panelId: panelId), "Glideslope · Chrono")
        XCTAssertTrue(workspace.applyMetadataTitle(panelId: panelId, title: "Chrono, renamed", source: .explicit))
        XCTAssertNil(workspace.panelCustomTitles[panelId])
        XCTAssertEqual(workspace.displayedTabTitle(panelId: panelId), "Chrono, renamed")
        XCTAssertFalse(workspace.applyMetadataTitle(panelId: panelId, title: "cx", source: .osc))
        XCTAssertEqual(workspace.displayedTabTitle(panelId: panelId), "Chrono, renamed")
        let stored = PanelMetadataStore.shared.getMetadata(workspaceId: workspace.id, surfaceId: panelId)
        XCTAssertEqual(stored.metadata[MetadataKey.title] as? String, "Chrono, renamed")
        XCTAssertEqual(stored.sources[MetadataKey.title]?["source"] as? String, MetadataSource.explicit.rawValue)
    }

    /// `launch-agent --title` is source declare. Restore shows that title
    /// and does not write a custom title. A later OSC title cannot replace
    /// declare, so the tab stays. OSC, heuristic, and derived stay unsynced.
    @MainActor
    func testOSCAndHeuristicTitlesAreNotPromotedOnRestore() throws {
        do {
            let declared = try restoreTitlePanel(Self.explicitTitleFixture(source: "declare", title: "cx"))
            defer { retire(declared) }
            let panelId = try panelId()
            XCTAssertNil(declared.panelCustomTitles[panelId])
            XCTAssertEqual(declared.displayedTabTitle(panelId: panelId), "cx")
            XCTAssertFalse(declared.applyMetadataTitle(panelId: panelId, title: "from-osc", source: .osc))
            XCTAssertEqual(declared.displayedTabTitle(panelId: panelId), "cx")
        }
        for source in ["osc", "heuristic", "derived"] {
            let workspace = try restoreTitlePanel(Self.explicitTitleFixture(source: source, title: "cx"))
            defer { retire(workspace) }
            let panelId = try panelId()
            XCTAssertNil(workspace.panelCustomTitles[panelId], source)
            XCTAssertEqual(workspace.displayedTabTitle(panelId: panelId), "Terminal", source)
        }
    }

    @MainActor
    func testMissingTitleSourceKeepsTodayBehavior() throws {
        let json = """
        {
          "id": "B9ACF249-8AF6-4ED4-A55F-49FE2016899C",
          "type": "terminal",
          "title": "Glideslope · Chrono",
          "isPinned": false,
          "isManuallyUnread": false,
          "listeningPorts": []
        }
        """
        let workspace = try restoreTitlePanel(json)
        defer { retire(workspace) }
        let panelId = try panelId()
        XCTAssertNil(workspace.panelCustomTitles[panelId])
        XCTAssertEqual(workspace.displayedTabTitle(panelId: panelId), "Terminal")
    }

    /// A real custom title still wins, including over a later set-title.
    @MainActor
    func testCustomTitleWinsOverADifferentExplicitMetadataTitle() throws {
        var panel = try decodePanel(Self.explicitTitleFixture(source: "explicit"))
        panel.customTitle = "Kept name"
        let workspace = try restoreDecodedPanel(panel)
        defer { retire(workspace) }
        XCTAssertEqual(workspace.panelCustomTitles[panel.id], "Kept name")
        XCTAssertEqual(workspace.displayedTabTitle(panelId: panel.id), "Kept name")
        XCTAssertTrue(workspace.applyMetadataTitle(panelId: panel.id, title: "Chrono, renamed", source: .explicit))
        XCTAssertEqual(workspace.displayedTabTitle(panelId: panel.id), "Kept name")
    }

    @MainActor
    func testBlankExplicitMetadataTitleIsNotInstalled() throws {
        let json = """
        {
          "id": "B9ACF249-8AF6-4ED4-A55F-49FE2016899C",
          "type": "terminal",
          "title": "Terminal",
          "isPinned": false,
          "isManuallyUnread": false,
          "listeningPorts": [],
          "metadata": {"title": "   "},
          "metadataSources": {"title": {"source": "explicit", "ts": 1762146720}}
        }
        """
        let workspace = try restoreTitlePanel(json)
        defer { retire(workspace) }
        let panelId = try panelId()
        XCTAssertNil(workspace.panelCustomTitles[panelId])
        XCTAssertEqual(workspace.displayedTabTitle(panelId: panelId), "Terminal")
    }

    // MARK: C11H-323 restored lifecycle

    /// A survivor's agent may have ended its turn while c11 was down. A saved
    /// derived `activity` never comes back, whoever owns the panel (an opencode
    /// panel has no causal conversation owner, so before C11H-323 it kept the
    /// `working` it was saved with for good). An explicit one is the agent's
    /// own report and keeps its precedence.
    @MainActor
    func testARestoredPanelNeverCarriesItsDerivedActivity() throws {
        for (source, kept) in [("derived", false), ("explicit", true)] {
            let json = """
            {
              "id": "B9ACF249-8AF6-4ED4-A55F-49FE2016899C",
              "type": "terminal",
              "title": "Terminal",
              "isPinned": false,
              "isManuallyUnread": false,
              "listeningPorts": [],
              "metadata": {"activity": "working", "terminal_type": "opencode"},
              "metadataSources": {"activity": {"source": "\(source)", "ts": 1762146720},
                                  "terminal_type": {"source": "declare", "ts": 1762146720}}
            }
            """
            let workspace = try restoreTitlePanel(json)
            defer { retire(workspace) }
            let panelId = try panelId()
            let stored = PanelMetadataStore.shared.getMetadata(workspaceId: workspace.id, surfaceId: panelId)
            XCTAssertEqual(stored.metadata[MetadataKey.activity] as? String, kept ? "working" : nil, source)
            XCTAssertEqual(workspace.derivedActivityByPanel[panelId], kept ? .working : nil, source)
            XCTAssertEqual(workspace.resolvedSurfacePanelActivityState(panelId: panelId), kept ? .running : .idle, source)
        }
    }

    private func decodePanel(_ json: String) throws -> SessionPanelSnapshot {
        try JSONDecoder().decode(SessionPanelSnapshot.self, from: Data(json.utf8))
    }

    @MainActor
    private func restoreTitlePanel(_ json: String) throws -> Workspace {
        try restoreDecodedPanel(try decodePanel(json))
    }

    @MainActor
    private func restoreDecodedPanel(_ panel: SessionPanelSnapshot) throws -> Workspace {
        let snapshot = SessionWorkspaceSnapshot(
            id: UUID(), processTitle: "Fixture", customTitle: nil, customColor: nil,
            isPinned: false, currentDirectory: "/tmp", focusedPanelId: panel.id,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: [panel.id], selectedPanelId: panel.id)),
            panels: [panel], statusEntries: [], logEntries: [], progress: nil, gitBranch: nil
        )
        let workspace = Workspace(restoringSession: true)
        workspace.restoreSessionSnapshot(snapshot)
        XCTAssertNotNil(workspace.panels[panel.id])
        return workspace
    }

    @MainActor
    private func retire(_ workspace: Workspace) {
        let panelIds = Array(workspace.panels.keys)
        workspace.retireForSessionRestore()
        for panelId in panelIds {
            PanelMetadataStore.shared.removeSurface(workspaceId: workspace.id, surfaceId: panelId)
        }
    }

    private func panelId() throws -> UUID {
        try XCTUnwrap(UUID(uuidString: "B9ACF249-8AF6-4ED4-A55F-49FE2016899C"))
    }

    /// Ticket fixture: metadata title, panel title, no customTitle key.
    private static func explicitTitleFixture(source: String, title: String = "Glideslope · Chrono") -> String {
        """
        {
          "id": "B9ACF249-8AF6-4ED4-A55F-49FE2016899C",
          "type": "terminal",
          "title": "\(title)",
          "isPinned": false,
          "isManuallyUnread": false,
          "listeningPorts": [],
          "metadata": {"title": "\(title)"},
          "metadataSources": {"title": {"source": "\(source)", "ts": 1762146720}}
        }
        """
    }
}
