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

    final class CountingBatchScraper: ConversationScraper, @unchecked Sendable {
        let kind: String
        let preset: [ScrapeCandidate]
        let failure: ScrapeCollectionFailure?
        private(set) var collectionCount = 0
        private(set) var requestedBudgets: [Int] = []

        init(
            kind: String = "codex",
            preset: [ScrapeCandidate],
            failure: ScrapeCollectionFailure? = nil
        ) {
            self.kind = kind
            self.preset = preset
            self.failure = failure
        }

        func candidates(cwd: String?) -> [ScrapeCandidate] { preset }

        func collectBatchCandidates(
            contexts: [ScrapeCaptureContext],
            maxCandidates: Int
        ) -> ScrapeCandidateCollectionResult {
            collectionCount += 1
            requestedBudgets.append(maxCandidates)
            if let failure { return .failure(failure) }
            let sorted = preset.sorted {
                if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
                return $0.filePath < $1.filePath
            }
            return .success(Array(sorted.prefix(maxCandidates)))
        }
    }

    /// C11-164 (RES-2): logic-local filesystem mock supporting the bounded
    /// head read used by `CodexScraper` cwd recovery. Recursive listing +
    /// per-path head content; stat-only otherwise.
    final class MockFS: ConversationFilesystem, @unchecked Sendable {
        var home: URL?
        // Keyed by normalized `.path` so a scraper root built with
        // `appendingPathComponent(isDirectory: true)` (trailing slash) still
        // matches a plainly-constructed key.
        var recursiveEntriesByPath: [String: [ConversationFilesystemEntry]] = [:]
        var headContents: [String: String] = [:]
        var homeDirectory: URL? { home }
        func fileExists(atPath path: String) -> Bool { false }
        func listDirectoryByMtime(_ directory: URL, max: Int) -> [ConversationFilesystemEntry] { [] }
        func listSessionsRecursivelyByMtime(_ root: URL, extensionFilter: String, max: Int) -> [ConversationFilesystemEntry] {
            Array((recursiveEntriesByPath[root.path] ?? [])
                .filter { $0.fileName.hasSuffix("." + extensionFilter) }
                .sorted { $0.mtime > $1.mtime }
                .prefix(max))
        }
        func readSessionHead(atPath path: String, maxBytes: Int) -> String? {
            guard let full = headContents[path] else { return nil }
            let firstLine = full.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? full
            return String(firstLine.prefix(maxBytes))
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
        XCTAssertEqual(text, "codex resume --yolo '\(codexId)'")
        XCTAssertTrue(submit)
    }

    // MARK: - Case 2: ambiguous codex → skip

    func testAmbiguousCodexCandidatesYieldUnknownAndSkip() async throws {
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

        let batch = try await pipeline.collectCandidateBatch(contexts: contexts)
        let store = ConversationStore()
        let result = await store.applyScrapeBatch(batch, pipeline: pipeline)
        XCTAssertEqual(result.quarantinedSurfaceIds, [surfaceId])
        let active = await store.active(for: surfaceId)
        XCTAssertEqual(active?.state, .unknown)
        XCTAssertEqual(active?.quarantineReason, .ambiguousGlobalAssignment)
        if let active, case .skip = CodexStrategy().resume(ref: active) {
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

    func testRunScrapeCaptureAppliesRefToStoreAndRoundTripsToResume() async throws {
        let surfaceId = UUID().uuidString
        let cwd = "/work/proj"
        let scrapers = ConversationScraperRegistry(scrapers: [
            MockScraper(kind: "codex", preset: [candidate(codexId, mtime: Date())])
        ])
        let pipeline = ScrapeCapturePipeline(scrapers: scrapers, strategies: .v1)
        let contexts = [ScrapeCaptureContext(surfaceId: surfaceId, kind: "codex", cwd: cwd)]

        let store = ConversationStore()
        let applied = try await store.runScrapeCapture(contexts: contexts, pipeline: pipeline)
        XCTAssertEqual(applied.applied.count, 1)

        // The store's active ref for the surface is now the scraped, resumable ref.
        let active = await store.active(for: surfaceId)
        XCTAssertNotNil(active)
        XCTAssertEqual(active?.id, codexId)
        XCTAssertEqual(active?.capturedVia, .scrape)
        guard let active, case let .typeCommand(text, _) = CodexStrategy().resume(ref: active) else {
            return XCTFail("store ref must resume to a typeCommand")
        }
        XCTAssertEqual(text, "codex resume --yolo '\(codexId)'")
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
        // Pre-C11-164 panels (no persisted floor) thread nil — prior behaviour.
        XCTAssertNil(contexts[0].lastActivityTimestamp)
    }

    // C11-164 (RES-2): the persisted per-panel activity floor is threaded into
    // the restore-time scrape context (without it, `lastActivityTimestamp` was
    // hardcoded nil and the floor lost across a crash).
    func testContextsThreadPersistedActivityFloor() {
        let codexPanelId = UUID()
        let floor = Date(timeIntervalSince1970: 1_700_000_000)
        var codexPanel = makeTerminalPanel(
            id: codexPanelId, directory: "/work/proj",
            metadata: [SurfaceMetadataKeyName.terminalType: .string("codex")]
        )
        codexPanel.lastActivityAt = floor
        let snapshot = makeSnapshot(panels: [codexPanel])
        let contexts = ScrapeCaptureContext.contexts(from: snapshot)
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0].lastActivityTimestamp, floor)
    }

    // MARK: - C11-206: bounded global assignment and atomic commit

    private func stableUUID(_ index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", index)
    }

    func testThirtyTwoLiveCodexSurfacesCollectOnceAndResolvePastLegacySixteen() async throws {
        let now = Date()
        let floor = now.addingTimeInterval(-120)
        let contexts = (0..<32).map { index in
            ScrapeCaptureContext(
                surfaceId: "S\(index)",
                kind: "codex",
                cwd: "/work/p\(index)",
                lastActivityTimestamp: floor
            )
        }
        let foreign = (100..<120).map { index in
            candidate(
                stableUUID(index),
                mtime: now.addingTimeInterval(TimeInterval(1_000 - index)),
                cwd: "/foreign/p\(index)"
            )
        }
        let stale = (200..<220).map { index in
            candidate(
                stableUUID(index),
                mtime: floor.addingTimeInterval(-TimeInterval(index)),
                cwd: "/work/p\(index - 200)"
            )
        }
        let live = (0..<32).map { index in
            candidate(
                stableUUID(index),
                mtime: now.addingTimeInterval(-TimeInterval(index)),
                cwd: "/work/p\(index)"
            )
        }
        let scraper = CountingBatchScraper(preset: foreign + stale + live)
        let pipeline = ScrapeCapturePipeline(
            scrapers: ConversationScraperRegistry(scrapers: [scraper]),
            strategies: .v1
        )

        let batch = try await pipeline.collectCandidateBatch(contexts: contexts)
        XCTAssertEqual(scraper.collectionCount, 1, "one global enumeration per kind")
        XCTAssertEqual(scraper.requestedBudgets, [128])
        let sortedIds = batch.candidatesByKind["codex"]?.map(\.id) ?? []
        let lastLiveId = stableUUID(31)
        XCTAssertGreaterThan(sortedIds.firstIndex(of: lastLiveId) ?? -1, 15,
                             "the oldest live candidate must be discoverable beyond legacy top-16")

        let store = ConversationStore()
        let result = await store.applyScrapeBatch(batch, pipeline: pipeline)
        XCTAssertEqual(result.applied.count, 32)
        XCTAssertTrue(result.quarantinedSurfaceIds.isEmpty)
        let assigned = Dictionary(uniqueKeysWithValues: result.applied.map { ($0.surfaceId, $0.ref.id) })
        XCTAssertEqual(Set(assigned.values).count, 32)
        XCTAssertEqual(assigned["S31"], lastLiveId)
    }

    func testSameCwdWithoutCausalIdentityQuarantinesEverySurface() async throws {
        let now = Date()
        let contexts = [
            ScrapeCaptureContext(surfaceId: "S1", kind: "codex", cwd: "/work/shared"),
            ScrapeCaptureContext(surfaceId: "S2", kind: "codex", cwd: "/work/shared")
        ]
        let scraper = CountingBatchScraper(preset: [
            candidate(stableUUID(1), mtime: now, cwd: "/work/shared"),
            candidate(stableUUID(2), mtime: now.addingTimeInterval(-1), cwd: "/work/shared")
        ])
        let pipeline = ScrapeCapturePipeline(
            scrapers: ConversationScraperRegistry(scrapers: [scraper])
        )
        let batch = try await pipeline.collectCandidateBatch(contexts: contexts)
        let store = ConversationStore()
        let result = await store.applyScrapeBatch(batch, pipeline: pipeline)

        XCTAssertEqual(result.quarantinedSurfaceIds, ["S1", "S2"])
        let s1 = await store.active(for: "S1")
        let s2 = await store.active(for: "S2")
        XCTAssertEqual(s1?.quarantineReason, .sameCwdWithoutCausalIdentity)
        XCTAssertEqual(s2?.quarantineReason, .sameCwdWithoutCausalIdentity)
    }

    func testUnknownCwdCandidateCannotBeConsumedByAnySurface() async throws {
        let contexts = [
            ScrapeCaptureContext(surfaceId: "S1", kind: "codex"),
            ScrapeCaptureContext(surfaceId: "S2", kind: "codex")
        ]
        let scraper = CountingBatchScraper(preset: [
            candidate(stableUUID(1), mtime: Date(), cwd: nil)
        ])
        let pipeline = ScrapeCapturePipeline(
            scrapers: ConversationScraperRegistry(scrapers: [scraper])
        )
        let batch = try await pipeline.collectCandidateBatch(contexts: contexts)
        let store = ConversationStore()
        let result = await store.applyScrapeBatch(batch, pipeline: pipeline)

        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertTrue(result.quarantinedSurfaceIds.isEmpty)
        let s1 = await store.active(for: "S1")
        let s2 = await store.active(for: "S2")
        XCTAssertNil(s1)
        XCTAssertNil(s2)
    }

    func testKnownSurfaceRejectsForeignCandidateWithUnknownCwd() {
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: "/work/project",
            lastActivityTimestamp: nil,
            wrapperClaim: nil,
            push: nil,
            scrapeCandidates: [
                candidate(stableUUID(1), mtime: Date(), cwd: nil),
            ]
        )

        XCTAssertTrue(CodexStrategy().eligibleCandidates(inputs: inputs).isEmpty)
        XCTAssertNil(CodexStrategy().capture(inputs: inputs))
    }

    func testMissingSurfaceCwdRejectsKnownCandidateCwd() {
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: nil,
            lastActivityTimestamp: nil,
            wrapperClaim: nil,
            push: nil,
            scrapeCandidates: [
                candidate(stableUUID(1), mtime: Date(), cwd: "/foreign/project"),
            ]
        )

        XCTAssertTrue(CodexStrategy().eligibleCandidates(inputs: inputs).isEmpty)
        XCTAssertNil(CodexStrategy().capture(inputs: inputs))
    }

    func testWrapperClaimCwdCanProvideExplicitNormalizedOwnerContext() {
        let claim = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:S1:fixture",
            placeholder: true,
            cwd: "/work/shared/../shared",
            capturedAt: Date(timeIntervalSince1970: 1_000),
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: nil,
            lastActivityTimestamp: nil,
            wrapperClaim: claim,
            push: nil,
            scrapeCandidates: [
                candidate(
                    stableUUID(1),
                    mtime: Date(timeIntervalSince1970: 1_001),
                    cwd: "/work/shared"
                ),
            ]
        )

        XCTAssertEqual(
            CodexStrategy().eligibleCandidates(inputs: inputs).map(\.id),
            [stableUUID(1)]
        )
    }

    func testRuntimeCaptureLandingAfterCollectionWinsAtomicCommit() async throws {
        let scrapeId = stableUUID(1)
        let runtimeId = stableUUID(2)
        let contexts = [
            ScrapeCaptureContext(surfaceId: "S1", kind: "codex", cwd: "/work/p")
        ]
        let scraper = CountingBatchScraper(preset: [
            candidate(scrapeId, mtime: Date(), cwd: "/work/p")
        ])
        let pipeline = ScrapeCapturePipeline(
            scrapers: ConversationScraperRegistry(scrapers: [scraper])
        )
        let batch = try await pipeline.collectCandidateBatch(contexts: contexts)
        let store = ConversationStore()
        _ = await store.captureRuntimeEnv(surfaceId: "S1", id: runtimeId, cwd: "/work/p")

        let result = await store.applyScrapeBatch(batch, pipeline: pipeline)
        XCTAssertTrue(result.applied.isEmpty)
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.id, runtimeId)
        XCTAssertEqual(active?.capturedVia, .runtimeEnv)
        XCTAssertNil(active?.quarantineReason)
    }

    func testCollectionFailureIsDistinctFromSuccessfulEmptyCollection() async throws {
        let contexts = [
            ScrapeCaptureContext(surfaceId: "S1", kind: "codex", cwd: "/work/p")
        ]
        let emptyScraper = CountingBatchScraper(preset: [])
        let emptyPipeline = ScrapeCapturePipeline(
            scrapers: ConversationScraperRegistry(scrapers: [emptyScraper])
        )
        let emptyBatch = try await emptyPipeline.collectCandidateBatch(contexts: contexts)
        XCTAssertEqual(emptyBatch.candidatesByKind["codex"], [])

        let failingScraper = CountingBatchScraper(
            preset: [],
            failure: .injectedFailure
        )
        let failingPipeline = ScrapeCapturePipeline(
            scrapers: ConversationScraperRegistry(scrapers: [failingScraper])
        )
        do {
            _ = try await failingPipeline.collectCandidateBatch(contexts: contexts)
            XCTFail("typed collection failure must throw")
        } catch let error as ScrapeCandidateBatchCollectionError {
            XCTAssertEqual(error.failuresByKind, ["codex": .injectedFailure])
        }
    }

    func testQASessionsRootOverrideRequiresTaggedOrQALaunch() {
        let path = "/tmp/c11-206-fixtures/../sessions"
        XCTAssertNil(CodexScraper.qaSessionsRootOverride(environment: [
            CodexScraper.qaSessionsRootEnvironmentKey: path
        ]))
        let overridden = CodexScraper.qaSessionsRootOverride(environment: [
            "C11_TAG": "c11-206",
            CodexScraper.qaSessionsRootEnvironmentKey: path
        ])
        XCTAssertEqual(overridden?.path, "/tmp/sessions")
    }

    func testSnapshotCaptureScopeAuthorizesEveryTerminalButScrapesOnlyTypedAgents() {
        let typed = UUID()
        let missingType = UUID()
        let emptyType = UUID()
        let browser = UUID()
        let snapshot = makeSnapshot(panels: [
            makeTerminalPanel(
                id: typed,
                directory: "/tmp/typed",
                metadata: [SurfaceMetadataKeyName.terminalType: .string("codex")]
            ),
            makeTerminalPanel(id: missingType, directory: nil, metadata: nil),
            makeTerminalPanel(
                id: emptyType,
                directory: nil,
                metadata: [SurfaceMetadataKeyName.terminalType: .string("   ")]
            ),
            makeBrowserPanel(id: browser),
        ])

        let scope = ConversationSnapshotCaptureScope(snapshot: snapshot)

        XCTAssertEqual(scope.scrapeContexts.map(\.surfaceId), [typed.uuidString])
        XCTAssertEqual(
            scope.markerSurfaceIds,
            [typed.uuidString, missingType.uuidString, emptyType.uuidString]
        )
        XCTAssertFalse(scope.markerSurfaceIds.contains(browser.uuidString))
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

    // MARK: - C11-164 (RES-2): Codex real-cwd recovery

    private func codexFS(sessions: [(id: String, cwd: String?, mtime: Date)]) -> MockFS {
        let mock = MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = URL(fileURLWithPath: "/Users/test/.codex/sessions")
        var entries: [ConversationFilesystemEntry] = []
        for s in sessions {
            let file = "rollout-2026-07-07T00-00-00-\(s.id).jsonl"
            let url = root.appendingPathComponent("2026/07/07/\(file)")
            entries.append(ConversationFilesystemEntry(url: url, fileName: file, mtime: s.mtime, size: 4096))
            if let cwd = s.cwd {
                mock.headContents[url.path] = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(s.id)\",\"cwd\":\"\(cwd)\",\"instructions\":\"stub body\"}}"
            }
        }
        mock.recursiveEntriesByPath[root.path] = entries
        return mock
    }

    /// The scraper recovers each candidate's REAL cwd from the rollout header
    /// instead of stamping the querying surface's cwd (the disambiguation no-op).
    func testCodexScraperRecoversRealCwdPerCandidate() {
        let idA = "aaaa1111-2222-3333-4444-555566667777"
        let idB = "bbbb1111-2222-3333-4444-555566667777"
        let now = Date()
        let mock = codexFS(sessions: [
            (idA, "/Users/test/projA", now),
            (idB, "/Users/test/projB", now.addingTimeInterval(-5))
        ])
        // Even with a surface cwd passed, candidates carry their OWN real cwd.
        let cands = CodexScraper(filesystem: mock).candidates(cwd: "/Users/test/projA")
        let byId = Dictionary(uniqueKeysWithValues: cands.map { ($0.id, $0.cwd) })
        XCTAssertEqual(byId[idA], "/Users/test/projA")
        XCTAssertEqual(byId[idB], "/Users/test/projB")
    }

    /// Distinct-cwd codex sessions resolve to their own session (state .alive),
    /// no longer read as mutually ambiguous — the bug G3 fixes.
    func testCodexDistinctCwdResolvesInsteadOfAmbiguous() {
        let idA = "aaaa1111-2222-3333-4444-555566667777"
        let idB = "bbbb1111-2222-3333-4444-555566667777"
        let now = Date()
        let mock = codexFS(sessions: [
            (idA, "/Users/test/projA", now),
            (idB, "/Users/test/projB", now.addingTimeInterval(-5))
        ])
        let cands = CodexScraper(filesystem: mock).candidates(cwd: nil)
        let claim = ConversationRef(kind: "codex", id: "placeholder", placeholder: true,
                                    cwd: "/Users/test/projA", capturedAt: now.addingTimeInterval(-60),
                                    capturedVia: .wrapperClaim, state: .unknown, diagnosticReason: nil)
        let inputs = ConversationStrategyInputs(surfaceId: "A", cwd: "/Users/test/projA",
                                                lastActivityTimestamp: nil, wrapperClaim: claim,
                                                push: nil, scrapeCandidates: cands)
        let ref = CodexStrategy().capture(inputs: inputs)
        XCTAssertEqual(ref?.id, idA)
        XCTAssertEqual(ref?.state, .alive, "distinct-cwd codex must resolve, not read as ambiguous")
    }

    /// Same-cwd multi-session stays honestly ambiguous — the correct behaviour
    /// the ambiguity policy exists for; cwd recovery must not paper over it.
    func testCodexSameCwdStaysAmbiguous() {
        let idA = "aaaa1111-2222-3333-4444-555566667777"
        let idB = "bbbb1111-2222-3333-4444-555566667777"
        let now = Date()
        let mock = codexFS(sessions: [
            (idA, "/Users/test/shared", now),
            (idB, "/Users/test/shared", now.addingTimeInterval(-5))
        ])
        let cands = CodexScraper(filesystem: mock).candidates(cwd: nil)
        let claim = ConversationRef(kind: "codex", id: "placeholder", placeholder: true,
                                    cwd: "/Users/test/shared", capturedAt: now.addingTimeInterval(-60),
                                    capturedVia: .wrapperClaim, state: .unknown, diagnosticReason: nil)
        let inputs = ConversationStrategyInputs(surfaceId: "A", cwd: "/Users/test/shared",
                                                lastActivityTimestamp: nil, wrapperClaim: claim,
                                                push: nil, scrapeCandidates: cands)
        let ref = CodexStrategy().capture(inputs: inputs)
        XCTAssertEqual(ref?.state, .unknown)
        XCTAssertEqual(ref?.diagnosticReason?.contains("ambiguous"), true)
    }

    func testCodexTranscriptVerificationFindsExactIdPastLegacySixteen() {
        let now = Date()
        let sessions = (0..<32).map { index in
            (stableUUID(index), "/Users/test/p\(index)", now.addingTimeInterval(-TimeInterval(index)))
        }
        let targetId = stableUUID(31)
        let ref = ConversationRef(
            kind: "codex",
            id: targetId,
            cwd: "/Users/test/p31",
            capturedVia: .runtimeEnv,
            state: .suspended
        )
        XCTAssertEqual(
            CodexStrategy().transcriptExists(for: ref, filesystem: codexFS(sessions: sessions)),
            true,
            "exact membership verification must not inherit the legacy newest-16 cutoff"
        )
    }

    // MARK: - C11-164: parseCodexCwd (bounded, allowlisted extractor)

    func testParseCodexCwdExtractsOnlyCwd() {
        let head = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"cwd\":\"/Users/test/proj\",\"instructions\":\"secret transcript body\"}}"
        XCTAssertEqual(CodexScraper.parseCodexCwd(fromHead: head), "/Users/test/proj")
    }

    func testParseCodexCwdHandlesEscapedSlashes() {
        XCTAssertEqual(CodexScraper.parseCodexCwd(fromHead: "{\"payload\":{\"cwd\":\"\\/Users\\/test\\/proj\"}}"),
                       "/Users/test/proj")
    }

    func testParseCodexCwdReturnsNilWhenAbsent() {
        XCTAssertNil(CodexScraper.parseCodexCwd(fromHead: "{\"payload\":{\"id\":\"x\"}}"))
    }

    func testParseCodexCwdReturnsNilOnTruncatedValue() {
        XCTAssertNil(CodexScraper.parseCodexCwd(fromHead: "{\"payload\":{\"cwd\":\"/Users/test/pro"))
    }
}
