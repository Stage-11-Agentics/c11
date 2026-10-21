import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-468 (logic-only, member of `c11LogicTests`). The startup conversation
/// audit decides resume per panel: exact causal refs never wait on, or lose
/// state to, a scrape; a failed or slow phase writes nothing.
final class StartupConversationAuditTests: XCTestCase {

    // MARK: - Mocks

    final class MockFS: ConversationFilesystem, @unchecked Sendable {
        let home = URL(fileURLWithPath: "/Users/test")
        var existingPaths: Set<String> = []
        var codexRollouts: [ConversationFilesystemEntry] = []
        var homeDirectory: URL? { home }
        func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
        func listDirectoryByMtime(_ directory: URL, max: Int) -> [ConversationFilesystemEntry] { [] }
        func listSessionsRecursivelyByMtime(_ root: URL, extensionFilter: String, max: Int) -> [ConversationFilesystemEntry] {
            guard root.path == home.appendingPathComponent(".codex/sessions").path else { return [] }
            return Array(codexRollouts.prefix(max))
        }
    }

    /// A scraper slower than any startup budget, counting its collections.
    final class SlowScraper: ConversationScraper, @unchecked Sendable {
        let kind: String
        let delay: TimeInterval
        let preset: [ScrapeCandidate]
        let failure: ScrapeCollectionFailure?
        private let lock = NSLock()
        private var collections = 0

        init(kind: String, delay: TimeInterval, preset: [ScrapeCandidate] = [], failure: ScrapeCollectionFailure? = nil) {
            self.kind = kind
            self.delay = delay
            self.preset = preset
            self.failure = failure
        }

        var collectionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return collections
        }

        func candidates(cwd: String?) -> [ScrapeCandidate] { preset }

        func collectBatchCandidates(
            contexts: [ScrapeCaptureContext],
            maxCandidates: Int
        ) -> ScrapeCandidateCollectionResult {
            lock.lock()
            collections += 1
            lock.unlock()
            Thread.sleep(forTimeInterval: delay)
            if let failure { return .failure(failure) }
            return .success(Array(preset.prefix(maxCandidates)))
        }
    }

    final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StartupConversationAuditReport?
        func set(_ report: StartupConversationAuditReport) {
            lock.lock(); stored = report; lock.unlock()
        }
        var value: StartupConversationAuditReport? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    // MARK: - Fixtures

    private struct Panel {
        var id = UUID()
        let kind: String
        let cwd: String
        let ref: ConversationRef?
    }

    private func uuid(_ prefix: Int, _ index: Int) -> String {
        String(format: "%08x-1111-4111-8111-%012x", prefix, index)
    }

    private func claudePanel(_ index: Int, state: ConversationState = .alive) -> Panel {
        let cwd = "/work/claude-\(index)"
        return Panel(kind: "claude-code", cwd: cwd, ref: ConversationRef(
            kind: "claude-code", id: uuid(0xC1, index), cwd: cwd,
            capturedVia: .hook, state: state
        ))
    }

    private func codexPanel(_ index: Int) -> Panel {
        let cwd = "/work/codex-\(index)"
        return Panel(kind: "codex", cwd: cwd, ref: ConversationRef(
            kind: "codex", id: uuid(0xC0, index), cwd: cwd,
            capturedVia: .runtimeEnv, state: .alive
        ))
    }

    private func placeholderPanel(_ index: Int) -> Panel {
        let cwd = "/work/late-\(index)"
        return Panel(kind: "codex", cwd: cwd, ref: ConversationRef(
            kind: "codex", id: "wrapper-claim:p\(index)", placeholder: true, cwd: cwd,
            capturedVia: .wrapperClaim, state: .unknown
        ))
    }

    private func snapshot(_ panels: [Panel]) -> AppSessionSnapshot {
        let snapshots = panels.map { panel in
            SessionPanelSnapshot(
                id: panel.id, type: .terminal, title: "T", customTitle: nil, directory: panel.cwd,
                isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [],
                ttyName: nil, terminal: nil, browser: nil, markdown: nil,
                metadata: [PanelMetadataKeyName.terminalType: .string(panel.kind)],
                metadataSources: nil,
                surfaceConversations: panel.ref.map { PanelConversations(active: $0) }
            )
        }
        let workspace = SessionWorkspaceSnapshot(
            id: UUID(), processTitle: "Terminal", customTitle: nil, customColor: nil,
            isPinned: false, currentDirectory: "/tmp", focusedPanelId: nil,
            layout: .pane(SessionAreaLayoutSnapshot(panelIds: snapshots.map(\.id), selectedPanelId: nil)),
            panels: snapshots, statusEntries: [], logEntries: [], progress: nil, gitBranch: nil
        )
        let window = SessionWindowSnapshot(
            frame: nil, display: nil,
            workspaceManager: SessionWorkspaceManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
        return AppSessionSnapshot(version: SessionSnapshotSchema.currentVersion,
                                  createdAt: Date().timeIntervalSince1970, windows: [window])
    }

    /// Every panel's transcript is on disk: Claude by exact path, Codex as a
    /// date-nested rollout.
    private func filesystem(for panels: [Panel], extraCodexIds: [String] = []) -> MockFS {
        let fs = MockFS()
        for panel in panels {
            guard let ref = panel.ref, !ref.placeholder else { continue }
            if ref.kind == "claude-code" {
                fs.existingPaths.insert(fs.home
                    .appendingPathComponent(".claude/projects")
                    .appendingPathComponent(ClaudeCodeStrategy.projectSlug(forCwd: panel.cwd))
                    .appendingPathComponent("\(ref.id).jsonl").path)
            }
        }
        let codexIds = panels.compactMap { $0.ref }.filter { $0.kind == "codex" && !$0.placeholder }.map(\.id)
        for id in codexIds + extraCodexIds {
            let name = "rollout-2026-10-21T15-00-00-\(id).jsonl"
            fs.codexRollouts.append(ConversationFilesystemEntry(
                url: fs.home.appendingPathComponent(".codex/sessions/2026/10/21/\(name)"),
                fileName: name, mtime: Date(), size: 4096
            ))
        }
        return fs
    }

    private func environment(
        store: ConversationStore,
        scrapers: [any ConversationScraper],
        filesystem: MockFS,
        report: ReportBox
    ) -> StartupConversationAudit.Environment {
        StartupConversationAudit.Environment(
            store: store,
            pipeline: ScrapeCapturePipeline(scrapers: ConversationScraperRegistry(scrapers: scrapers), strategies: .v1),
            registry: .v1,
            filesystem: filesystem,
            loadLaunchBoundaries: { _ in [] },
            refreshOwners: {},
            classificationReady: {},
            report: { report.set($0) }
        )
    }

    private func decision(_ panel: Panel, in conversations: [String: PanelConversations], mode: ResumeRecoveryMode) -> ResumeDecision? {
        conversations[panel.id.uuidString]?.active.map {
            Workspace.resumeDecision(for: $0, registry: .v1, mode: mode)
        }
    }

    private func isCommand(_ decision: ResumeDecision?) -> Bool {
        if case .command = decision { return true }
        return false
    }

    // MARK: - Acceptance

    /// The 2026-10-21 shape: 24 Claude hook refs, 6 Codex runtime refs and 2
    /// placeholders on a dirty restore, with every scraper slower than the old
    /// 5 s budget would allow for. Every causal ref resumes before any scrape
    /// finishes; the placeholders settle when theirs does.
    func testDirtyRestoreResumesEveryCausalRefWhileScrapeIsStillRunning() async {
        let causal = (0..<24).map { claudePanel($0) } + (0..<6).map { codexPanel($0) }
        let resolvable = placeholderPanel(0)
        let unresolvable = placeholderPanel(1)
        let lateId = uuid(0x1A7E, 0)
        let panels = causal + [resolvable, unresolvable]
        let fs = filesystem(for: panels, extraCodexIds: [lateId])
        let claudeScraper = SlowScraper(kind: "claude-code", delay: 3.0)
        let codexScraper = SlowScraper(kind: "codex", delay: 1.5, preset: [
            ScrapeCandidate(id: lateId, filePath: "/Users/test/.codex/sessions/2026/10/21/x-\(lateId).jsonl",
                            mtime: Date(), size: 4096, cwd: resolvable.cwd),
        ])
        let store = ConversationStore()
        let report = ReportBox()
        let audit = StartupConversationAudit()

        let start = Date()
        audit.begin(mode: .dirty, snapshot: snapshot(panels), environment: environment(
            store: store, scrapers: [claudeScraper, codexScraper], filesystem: fs, report: report
        ))
        let classification = await audit.awaitClassification()
        let conversations = await store.snapshot()
        let classifiedAfter = Date().timeIntervalSince(start)

        XCTAssertLessThan(classifiedAfter, 1.0, "classification must not wait on a scrape")
        XCTAssertNil(report.value, "the scrape is still running")
        for panel in causal {
            XCTAssertTrue(isCommand(decision(panel, in: conversations, mode: .dirty)),
                          "causal \(panel.kind) ref must resume without the scrape")
        }
        XCTAssertEqual(
            Set(classification.scrapeKindBySurface.keys),
            [resolvable.id.uuidString, unresolvable.id.uuidString]
        )
        XCTAssertNil(classification.scrapes["claude-code"], "no Claude panel needs a scrape")

        let finished = await audit.awaitReport()
        let settled = await store.snapshot()
        XCTAssertEqual(claudeScraper.collectionCount, 0)
        XCTAssertEqual(codexScraper.collectionCount, 1)
        XCTAssertEqual(finished?.outcome, "complete")
        XCTAssertEqual(finished?.panelsByTier["causal"], 30)
        XCTAssertEqual(finished?.panelsByTier["placeholder"], 2)
        XCTAssertEqual(finished?.scrapeDependentPanels, 2)
        XCTAssertNotNil(finished?.collectMsByKind["codex"])

        XCTAssertTrue(isCommand(decision(resolvable, in: settled, mode: .dirty)),
                      "a placeholder the scrape resolves resumes late")
        guard case .skip(let code, _)? = decision(unresolvable, in: settled, mode: .dirty) else {
            return XCTFail("an unresolved placeholder must skip")
        }
        XCTAssertEqual(code, .placeholder)
        for panel in causal {
            XCTAssertTrue(isCommand(decision(panel, in: settled, mode: .dirty)))
        }
    }

    /// A failed scrape changes no persisted state, and a relaunch from what
    /// autosave would write still resumes every causal ref.
    func testFailedScrapeWritesNothingAndRelaunchStillResumes() async {
        let causal = (0..<4).map { claudePanel($0) } + (0..<2).map { codexPanel($0) }
        let pending = placeholderPanel(0)
        let panels = causal + [pending]
        let fs = filesystem(for: panels)
        let records = WorkspaceSnapshotConversationBridge.records(from: snapshot(panels))

        func launch(_ panels: [Panel], mode: ResumeRecoveryMode) async -> (ConversationStore, StartupConversationAuditReport?) {
            let store = ConversationStore()
            let report = ReportBox()
            let audit = StartupConversationAudit()
            audit.begin(mode: mode, snapshot: snapshot(panels), environment: environment(
                store: store,
                scrapers: [SlowScraper(kind: "codex", delay: 0.3, failure: .unreadable)],
                filesystem: fs, report: report
            ))
            return (store, await audit.awaitReport())
        }

        let (cleanStore, cleanReport) = await launch(panels, mode: .clean)
        let afterClean = await cleanStore.snapshot()
        XCTAssertEqual(cleanReport?.outcome, "scrape_failed")
        XCTAssertNotNil(cleanReport?.scrapeFailuresByKind["codex"])
        XCTAssertEqual(afterClean, records, "a failed audit must not write state")

        let (dirtyStore, _) = await launch(panels, mode: .dirty)
        let persisted = await dirtyStore.snapshot()
        XCTAssertFalse(persisted.values.contains {
            $0.active?.diagnosticReason?.hasPrefix("startup audit failed") == true
        })
        // Relaunch from exactly what autosave would persist, failing again.
        let relaunched = panels.map { panel in
            Panel(id: panel.id, kind: panel.kind, cwd: panel.cwd, ref: persisted[panel.id.uuidString]?.active)
        }
        let (secondStore, _) = await launch(relaunched, mode: .dirty)
        let second = await secondStore.snapshot()
        for panel in causal {
            XCTAssertTrue(isCommand(decision(panel, in: persisted, mode: .dirty)))
            XCTAssertTrue(isCommand(decision(panel, in: second, mode: .dirty)),
                          "a forced failure must not cost the next launch its resumes")
        }
        guard case .skip(let code, _)? = decision(pending, in: second, mode: .dirty) else {
            return XCTFail("an unresolved placeholder must skip")
        }
        XCTAssertEqual(code, .placeholder)
    }

    func testSameIdRuntimeCaptureHealsUnknownRef() async {
        let store = ConversationStore()
        let id = uuid(0xC0, 7)
        _ = await store.captureRuntimeEnv(surfaceId: "S1", id: id, cwd: "/work/codex")
        await store.markAllUnknown(reason: "app restart --no-resume")
        let stale = await store.active(for: "S1")
        XCTAssertEqual(stale?.state, .unknown)

        let healed = await store.captureRuntimeEnv(surfaceId: "S1", id: id, cwd: "/work/codex")
        XCTAssertEqual(healed.outcome, .accepted)
        XCTAssertEqual(healed.ref.state, .alive)
        XCTAssertTrue(isCommand(Workspace.resumeDecision(for: healed.ref, registry: .v1, mode: .clean)))

        let repeated = await store.captureRuntimeEnv(surfaceId: "S1", id: id, cwd: "/work/codex")
        XCTAssertEqual(repeated.outcome, .idempotent)
    }

    func testExitTombstoneAndNoResumeNeverResume() async {
        let exited = claudePanel(0, state: .tombstoned)
        let live = claudePanel(1)
        let pending = placeholderPanel(0)
        let panels = [exited, live, pending]
        let fs = filesystem(for: panels)

        let store = ConversationStore()
        let audit = StartupConversationAudit()
        audit.begin(mode: .dirty, snapshot: snapshot(panels), environment: environment(
            store: store, scrapers: [], filesystem: fs, report: ReportBox()
        ))
        _ = await audit.awaitClassification()
        let dirty = await store.snapshot()
        XCTAssertFalse(isCommand(decision(exited, in: dirty, mode: .dirty)), "a /exit tombstone must never resume")
        XCTAssertEqual(dirty[exited.id.uuidString]?.active?.state, .tombstoned)
        guard case .skip(let code, _)? = decision(exited, in: dirty, mode: .clean) else {
            return XCTFail("a /exit tombstone must never resume")
        }
        XCTAssertEqual(code, .stateNotResumable)
        XCTAssertTrue(isCommand(decision(live, in: dirty, mode: .dirty)))

        let noResumeStore = ConversationStore()
        let noResume = StartupConversationAudit()
        let codexScraper = SlowScraper(kind: "codex", delay: 0)
        noResume.begin(mode: .noResume, snapshot: snapshot(panels), environment: environment(
            store: noResumeStore, scrapers: [codexScraper], filesystem: fs, report: ReportBox()
        ))
        let classification = await noResume.awaitClassification()
        let suppressed = await noResumeStore.snapshot()
        XCTAssertTrue(classification.scrapes.isEmpty, "no-resume collects nothing")
        XCTAssertEqual(codexScraper.collectionCount, 0)
        for panel in panels {
            guard case .skip(let code, _)? = decision(panel, in: suppressed, mode: .noResume) else {
                return XCTFail("no-resume must never resume")
            }
            XCTAssertEqual(code, .policyNoResume)
        }
    }

    /// A persisted inferred ref A and a newer session B in the same cwd: the
    /// scrape must still be able to replace A on a dirty restore, so A is
    /// not checked (and restamped) before its scrape lands.
    func testDirtyRestoreLetsTheScrapeReplaceAStaleInferredRef() async {
        let cwd = "/work/inferred"
        let staleId = uuid(0xA, 1)
        let freshId = uuid(0xB, 2)
        let stale = Panel(kind: "codex", cwd: cwd, ref: ConversationRef(
            kind: "codex", id: staleId, cwd: cwd,
            capturedAt: Date().addingTimeInterval(-600),
            capturedVia: .scrape, state: .alive
        ))
        let fs = filesystem(for: [stale], extraCodexIds: [freshId])
        let scraper = SlowScraper(kind: "codex", delay: 0.2, preset: [
            ScrapeCandidate(id: freshId, filePath: "/Users/test/.codex/sessions/2026/10/21/x-\(freshId).jsonl",
                            mtime: Date().addingTimeInterval(-60), size: 4096, cwd: cwd),
        ])
        let store = ConversationStore()
        let audit = StartupConversationAudit()
        audit.begin(mode: .dirty, snapshot: snapshot([stale]), environment: environment(
            store: store, scrapers: [scraper], filesystem: fs, report: ReportBox()
        ))
        let classification = await audit.awaitClassification()
        XCTAssertEqual(Set(classification.scrapeKindBySurface.keys), [stale.id.uuidString])
        _ = await audit.awaitReport()
        let settled = await store.snapshot()
        XCTAssertEqual(settled[stale.id.uuidString]?.active?.id, freshId, "the newer scraped session wins")
        XCTAssertTrue(isCommand(decision(stale, in: settled, mode: .dirty)))
    }

    func testCrashVerdictsNeverOverwriteARefThatChangedMeanwhile() async {
        let store = ConversationStore()
        let stale = uuid(0xE, 1)
        let fresh = uuid(0xE, 2)
        _ = await store.push(surfaceId: "A", kind: "claude-code", id: stale, source: .hook, cwd: "/work/a")
        _ = await store.push(surfaceId: "B", kind: "claude-code", id: uuid(0xE, 3), source: .hook, cwd: "/work/b")
        let verdicts = ConversationStore.crashTranscriptVerdicts(
            for: await store.snapshot(), registry: .v1, filesystem: MockFS()
        )
        // A new causal report lands on A while the verdicts were computed.
        _ = await store.push(surfaceId: "A", kind: "claude-code", id: fresh, source: .hook, cwd: "/work/a",
                             capturedAt: Date().addingTimeInterval(1))
        await store.applyCrashTranscriptVerdicts(verdicts)
        let after = await store.snapshot()
        XCTAssertEqual(after["A"]?.active?.id, fresh)
        XCTAssertEqual(after["A"]?.active?.state, .alive, "a newer ref keeps its state")
        XCTAssertEqual(after["B"]?.active?.state, .unknown, "an unchanged ref takes its verdict")
    }

    func testOneCodexWalkAnswersEveryCodexRef() {
        final class CountingFS: ConversationFilesystem, @unchecked Sendable {
            let inner: MockFS
            var walks = 0
            init(_ inner: MockFS) { self.inner = inner }
            var homeDirectory: URL? { inner.homeDirectory }
            func fileExists(atPath path: String) -> Bool { inner.fileExists(atPath: path) }
            func listDirectoryByMtime(_ d: URL, max: Int) -> [ConversationFilesystemEntry] { [] }
            func listSessionsRecursivelyByMtime(_ r: URL, extensionFilter: String, max: Int) -> [ConversationFilesystemEntry] {
                walks += 1
                return inner.listSessionsRecursivelyByMtime(r, extensionFilter: extensionFilter, max: max)
            }
        }
        let panels = (0..<8).map { codexPanel($0) }
        let counting = CountingFS(filesystem(for: panels))
        let records = Dictionary(uniqueKeysWithValues: panels.map {
            ($0.id.uuidString, PanelConversations(active: $0.ref))
        })
        let verdicts = ConversationStore.crashTranscriptVerdicts(
            for: records, registry: .v1, filesystem: SessionNameIndexFilesystem(base: counting)
        )
        XCTAssertEqual(verdicts.count, 8)
        XCTAssertTrue(verdicts.values.allSatisfy { $0.exists == true })
        XCTAssertEqual(counting.walks, 1)
    }

    func testScrapeScopeSkipsKindsWhoseRefsAreAllCausal() {
        let claudeCausal = ScrapeCaptureContext(surfaceId: "C1", kind: "claude-code", cwd: "/a")
        let claudeMissing = ScrapeCaptureContext(surfaceId: "C2", kind: "claude-code", cwd: "/b")
        let codexCausal = ScrapeCaptureContext(surfaceId: "X1", kind: "codex", cwd: "/c")
        let codexPlaceholder = ScrapeCaptureContext(surfaceId: "X2", kind: "codex", cwd: "/d")
        let piCausal = ScrapeCaptureContext(surfaceId: "P1", kind: "pi", cwd: "/e")
        let conversations: [String: PanelConversations] = [
            "C1": PanelConversations(active: ConversationRef(kind: "claude-code", id: uuid(1, 1), capturedVia: .hook, state: .alive)),
            "X1": PanelConversations(active: ConversationRef(kind: "codex", id: uuid(1, 2), capturedVia: .runtimeEnv, state: .alive)),
            "X2": PanelConversations(active: ConversationRef(kind: "codex", id: "wrapper-claim:x", placeholder: true, capturedVia: .wrapperClaim, state: .unknown)),
            "P1": PanelConversations(active: ConversationRef(kind: "pi", id: "p1", capturedVia: .hook, state: .alive)),
        ]
        let scoped = ScrapeCaptureContext.scoped(
            [claudeCausal, claudeMissing, codexCausal, codexPlaceholder, piCausal],
            to: conversations
        )
        XCTAssertEqual(scoped["claude-code"], [claudeMissing])
        XCTAssertEqual(scoped["codex"], [codexCausal, codexPlaceholder], "Codex keeps causal contexts for reservation")
        XCTAssertNil(scoped["pi"])
        XCTAssertTrue(ScrapeCaptureContext.scoped([claudeCausal, codexCausal], to: conversations).isEmpty)
    }
}
