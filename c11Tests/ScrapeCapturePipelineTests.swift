import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Tests for the C11-152 live scrape-capture pipeline — the seam that wires
/// scrapers into restore so a `ScrapeCandidate` becomes a resumable ref.
///
/// Member of the **`c11LogicTests`** target only, so it runs on the safe
/// `c11-logic` scheme. All mocks are declared locally (the host-target
/// `ConversationScraperTests.MockFS` is not reachable from this target).
final class ScrapeCapturePipelineTests: XCTestCase {

    // MARK: - Local mocks (logic-target-local; do not borrow host-target helpers)

    /// A stub scraper that returns preset candidates regardless of cwd, but
    /// stamps the passed cwd onto each (mirroring the real scrapers).
    struct MockScraper: ConversationScraper {
        let kind: String
        let preset: [ScrapeCandidate]
        func candidates(cwd: String?) -> [ScrapeCandidate] {
            preset.map {
                ScrapeCandidate(id: $0.id, filePath: $0.filePath, mtime: $0.mtime, size: $0.size, cwd: cwd ?? $0.cwd)
            }
        }
    }

    private let codexId = "abc12345-ef67-890a-bcde-f0123456789a"
    private let codexId2 = "eee22222-2222-3333-4444-555566667777"

    private func candidate(_ id: String, mtime: Date, cwd: String? = nil) -> ScrapeCandidate {
        ScrapeCandidate(id: id, filePath: "/Users/test/.codex/sessions/\(id).jsonl", mtime: mtime, size: 1024, cwd: cwd)
    }

    // MARK: - Case 1: end-to-end acceptance (the gate)

    func testSingleCodexCandidateBecomesResumableTypeCommand() {
        let surfaceId = UUID().uuidString
        let cwd = "/work/proj"
        let now = Date()
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "codex", preset: [candidate(codexId, mtime: now)])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        let contexts = [ScrapeCaptureContext(surfaceId: surfaceId, kind: "codex", cwd: cwd)]

        let captured = pipeline.captureRefs(contexts: contexts, existing: [:])
        XCTAssertEqual(captured.count, 1)
        let ref = captured[0].ref
        XCTAssertEqual(captured[0].surfaceId, surfaceId)
        XCTAssertEqual(ref.kind, "codex")
        XCTAssertEqual(ref.id, codexId)
        XCTAssertEqual(ref.capturedVia, .scrape)
        XCTAssertEqual(ref.state, .alive)

        // The applied ref resumes to a typeCommand.
        let action = CodexStrategy().resume(ref: ref)
        guard case let .typeCommand(text, submit) = action else {
            return XCTFail("expected .typeCommand, got \(action)")
        }
        XCTAssertEqual(text, "codex resume '\(codexId)'")
        XCTAssertTrue(submit)
    }

    // MARK: - Case 2: ambiguous codex → skip

    func testAmbiguousCodexCandidatesYieldUnknownAndSkip() {
        let surfaceId = UUID().uuidString
        let cwd = "/work/proj"
        let now = Date()
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "codex", preset: [
                candidate(codexId, mtime: now),
                candidate(codexId2, mtime: now.addingTimeInterval(-10))
            ])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        let contexts = [ScrapeCaptureContext(surfaceId: surfaceId, kind: "codex", cwd: cwd)]

        let captured = pipeline.captureRefs(contexts: contexts, existing: [:])
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].ref.state, .unknown)
        if case .skip = CodexStrategy().resume(ref: captured[0].ref) {
            // expected
        } else {
            XCTFail("ambiguous ref must skip resume")
        }
    }

    // MARK: - Case 3: no regression — a seeded claude hook ref is preserved

    func testClaudeHookRefIsNotOverwrittenByScrapePath() {
        let surfaceId = UUID().uuidString
        let claudeId = "11111111-2222-3333-4444-555566667777"
        // A live hook ref already in the store for this surface.
        let hookRef = ConversationRef(
            kind: "claude-code", id: claudeId, placeholder: false, cwd: "/work/proj",
            capturedAt: Date(), capturedVia: .hook, state: .suspended
        )
        let existing = [surfaceId: SurfaceConversations(active: hookRef, history: [])]
        // Scraper would surface a DIFFERENT (stale) top-by-mtime transcript.
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "claude-code", preset: [candidate(codexId, mtime: Date())])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        let contexts = [ScrapeCaptureContext(surfaceId: surfaceId, kind: "claude-code", cwd: "/work/proj")]

        // capture() returns the push (hook) ref unchanged (capturedVia==.hook),
        // which the pipeline filters out — nothing scrape-derived to apply.
        let captured = pipeline.captureRefs(contexts: contexts, existing: existing)
        XCTAssertTrue(captured.isEmpty, "hook ref must not be displaced via the scrape path")
    }

    // MARK: - Case 4: injectable filesystem / empty output leaves store unchanged

    func testEmptyScraperOutputProducesNoRefs() {
        let surfaceId = UUID().uuidString
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "codex", preset: [])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        let contexts = [ScrapeCaptureContext(surfaceId: surfaceId, kind: "codex", cwd: "/work/proj")]
        XCTAssertTrue(pipeline.captureRefs(contexts: contexts, existing: [:]).isEmpty)
    }

    func testKindWithoutRegisteredScraperIsSkipped() {
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "codex", preset: [candidate(codexId, mtime: Date())])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        // "pi" has no scraper registered here → skipped, no crash.
        let contexts = [ScrapeCaptureContext(surfaceId: UUID().uuidString, kind: "pi", cwd: "/work/proj")]
        XCTAssertTrue(pipeline.captureRefs(contexts: contexts, existing: [:]).isEmpty)
    }

    // MARK: - Case 5: runScrapeCapture actor driver round-trips through the store

    func testRunScrapeCaptureAppliesRefToStoreAndRoundTripsToResume() async {
        let surfaceId = UUID().uuidString
        let cwd = "/work/proj"
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "codex", preset: [candidate(codexId, mtime: Date())])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        let contexts = [ScrapeCaptureContext(surfaceId: surfaceId, kind: "codex", cwd: cwd)]

        let store = ConversationStore()
        let applied = await store.runScrapeCapture(contexts: contexts, pipeline: pipeline)
        XCTAssertEqual(applied.count, 1)

        // The store's active ref for the surface is now the scraped, resumable ref.
        let active = await store.active(for: surfaceId)
        XCTAssertNotNil(active)
        XCTAssertEqual(active?.id, codexId)
        XCTAssertEqual(active?.capturedVia, .scrape)
        guard let active, case let .typeCommand(text, _) = CodexStrategy().resume(ref: active) else {
            return XCTFail("store ref must resume to a typeCommand")
        }
        XCTAssertEqual(text, "codex resume '\(codexId)'")
    }

    // MARK: - Case 6: ScrapeCaptureContext.contexts(from:) extraction

    func testContextsExtractedFromSnapshotTerminalPanelsOnly() {
        let codexPanelId = UUID()
        let kindlessPanelId = UUID()

        // Codex terminal panel: extracted.
        let codexPanel = makeTerminalPanel(
            id: codexPanelId, directory: "/work/proj",
            metadata: [SurfaceMetadataKeyName.terminalType: .string("codex")]
        )
        // Terminal panel with no terminal_type metadata: skipped.
        let kindlessPanel = makeTerminalPanel(id: kindlessPanelId, directory: "/tmp", metadata: nil)
        // Browser panel (non-terminal): skipped.
        let browserPanel = makeBrowserPanel(id: UUID())

        let snapshot = makeSnapshot(panels: [codexPanel, kindlessPanel, browserPanel])
        let contexts = ScrapeCaptureContext.contexts(from: snapshot)

        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0].surfaceId, codexPanelId.uuidString)
        XCTAssertEqual(contexts[0].kind, "codex")
        XCTAssertEqual(contexts[0].cwd, "/work/proj")
    }

    // MARK: - Snapshot builders

    private func makeTerminalPanel(
        id: UUID, directory: String?, metadata: [String: PersistedJSONValue]?
    ) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id, type: .terminal, title: "T", customTitle: nil, directory: directory,
            isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [],
            ttyName: nil, terminal: nil, browser: nil, markdown: nil,
            metadata: metadata, metadataSources: nil, surfaceConversations: nil
        )
    }

    private func makeBrowserPanel(id: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id, type: .browser, title: "B", customTitle: nil, directory: nil,
            isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [],
            ttyName: nil, terminal: nil, browser: nil, markdown: nil,
            metadata: [SurfaceMetadataKeyName.terminalType: .string("codex")],
            metadataSources: nil, surfaceConversations: nil
        )
    }

    private func makeSnapshot(panels: [SessionPanelSnapshot]) -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            id: UUID(), processTitle: "Terminal", customTitle: nil, customColor: nil,
            isPinned: false, currentDirectory: "/tmp", focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: panels.map(\.id), selectedPanelId: nil)),
            panels: panels, statusEntries: [], logEntries: [], progress: nil, gitBranch: nil
        )
        let window = SessionWindowSnapshot(
            frame: nil, display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        return AppSessionSnapshot(version: SessionSnapshotSchema.currentVersion,
                                  createdAt: Date().timeIntervalSince1970, windows: [window])
    }
}
