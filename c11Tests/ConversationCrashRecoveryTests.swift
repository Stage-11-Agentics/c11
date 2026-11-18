import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-131 Tier 1 (logic-only, member of `c11LogicTests` — SAFE to run
/// locally). Covers the crash-recovery fix: the `transcriptExists` strategy
/// seam, the cwd→slug derivation, `ConversationStore.reclassifyAfterCrash`,
/// and that `.suspended` is resumable. Pure model code against an injectable
/// filesystem; no app host.
final class ConversationCrashRecoveryTests: XCTestCase {

    private let uuidA = "abc12345-ef67-890a-bcde-f0123456789a"
    private let uuidB = "ddd11111-2222-3333-4444-555566667777"
    private let cwd = "/Users/test/proj"

    /// Self-contained filesystem mock. Only the stat path is exercised;
    /// the listing methods return empty.
    private final class MockFS: ConversationFilesystem, @unchecked Sendable {
        let home: URL?
        var existingPaths: Set<String> = []
        var recursiveEntries: [URL: [ConversationFilesystemEntry]] = [:]
        /// C11H-196: directory names under `~/.claude/projects`, newest first.
        var projectDirs: [String] = []
        var prefixes: [String: String] = [:]
        init(home: String = "/Users/test") { self.home = URL(fileURLWithPath: home) }
        var homeDirectory: URL? { home }
        func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
        func listDirectoryByMtime(_ d: URL, max: Int) -> [ConversationFilesystemEntry] {
            guard d.standardizedFileURL.path == "/Users/test/.claude/projects" else { return [] }
            return projectDirs.prefix(max).map {
                ConversationFilesystemEntry(url: d.appendingPathComponent($0, isDirectory: true), fileName: $0,
                                            mtime: Date(), size: 0)
            }
        }
        func readSessionPrefix(atPath path: String, maxBytes: Int) -> String? { prefixes[path] }
        func listSessionsRecursivelyByMtime(_ r: URL, extensionFilter: String, max: Int) -> [ConversationFilesystemEntry] {
            Array((recursiveEntries[r] ?? [])
                .filter { $0.fileName.hasSuffix("." + extensionFilter) }
                .prefix(max))
        }
    }

    private func mockFS(present ids: [String], cwd: String) -> MockFS {
        let fs = MockFS()
        let slug = ClaudeCodeStrategy.projectSlug(forCwd: cwd)
        for id in ids {
            fs.existingPaths.insert("/Users/test/.claude/projects/\(slug)/\(id).jsonl")
        }
        return fs
    }

    // MARK: - Slug derivation

    func testProjectSlugReplacesEveryNonAlphanumeric() {
        XCTAssertEqual(
            ClaudeCodeStrategy.projectSlug(forCwd: "/Users/demo/Projects/Stage11/code/c11"),
            "-Users-demo-Projects-Stage11-code-c11"
        )
        // A `/.claude` segment collapses to `--claude` (slash + dot both → -).
        XCTAssertEqual(
            ClaudeCodeStrategy.projectSlug(forCwd: "/Users/demo/Projects/Stage11/code/c11/.claude/worktrees/c11-41"),
            "-Users-demo-Projects-Stage11-code-c11--claude-worktrees-c11-41"
        )
    }

    /// Regression: underscores in the cwd must slug to `-`, exactly as Claude
    /// Code encodes them. A prior implementation translated only `/` and `.`,
    /// so every underscore-cwd session (`…/singularist_salon`,
    /// `…/govee_control`) was pointed at a nonexistent transcript dir on crash
    /// recovery and silently refused to resume.
    func testProjectSlugReplacesUnderscoresAndPunctuation() {
        XCTAssertEqual(
            ClaudeCodeStrategy.projectSlug(
                forCwd: "/Users/demo/src/notes/singularist_salon"),
            "-Users-demo-src-notes-singularist-salon"
        )
        // Mixed separators each map to a single dash; digits and case survive.
        XCTAssertEqual(
            ClaudeCodeStrategy.projectSlug(forCwd: "/tmp/a_b.c-d E"),
            "-tmp-a-b-c-d-E"
        )
    }

    // MARK: - transcriptExists seam

    func testTranscriptExistsTrueWhenPresent() {
        let fs = mockFS(present: [uuidA], cwd: cwd)
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: cwd,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertEqual(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs), true)
    }

    func testTranscriptExistsFalseWhenMissing() {
        let fs = mockFS(present: [], cwd: cwd)
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: cwd,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertEqual(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs), false)
    }

    /// The true crash-recovery regression guard: the transcript lives at the
    /// DASHED slug dir Claude actually creates. The expected path is written
    /// out by hand (not via `projectSlug`/`mockFS`) so a slug bug can't cancel
    /// itself out on both sides of the comparison — the exact way the original
    /// underscore defect slipped past `testTranscriptExists…WhenPresent`.
    func testTranscriptExistsFindsUnderscoreCwdTranscriptOnDisk() {
        let fs = MockFS()  // home = /Users/test
        let underscoreCwd = "/Users/demo/src/notes/singularist_salon"
        fs.existingPaths.insert(
            "/Users/test/.claude/projects/"
            + "-Users-demo-src-notes-singularist-salon/\(uuidA).jsonl"
        )
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: underscoreCwd,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertEqual(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs), true)
    }

    /// C11H-196 gate A: the SessionStart bridge records no cwd. The transcript
    /// is found by id in any project directory. After the 2026-11-04 reboot,
    /// 26 of 38 Claude panels were skipped as "unverified" this way, although
    /// 25 of those transcripts were on disk.
    func testTranscriptFoundByIdWhenCwdMissing() {
        let fs = mockFS(present: [uuidA], cwd: cwd)
        fs.projectDirs = [ClaudeCodeStrategy.projectSlug(forCwd: "/Users/test/other"),
                          ClaudeCodeStrategy.projectSlug(forCwd: cwd)]
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: nil,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertEqual(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs), true)
    }

    /// A session started in another folder than the ref says is still found.
    func testTranscriptFoundByIdWhenCwdSlugMisses() {
        let fs = mockFS(present: [uuidA], cwd: cwd)
        fs.projectDirs = [ClaudeCodeStrategy.projectSlug(forCwd: cwd)]
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: "/Users/test/moved",
                                  capturedVia: .hook, state: .suspended)
        XCTAssertEqual(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs), true)
    }

    func testTranscriptMissingEverywhereIsFalseWithoutCwd() {
        let fs = mockFS(present: [uuidB], cwd: cwd)
        fs.projectDirs = [ClaudeCodeStrategy.projectSlug(forCwd: cwd)]
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: nil,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertEqual(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs), false)
    }

    /// The resume's `cd` comes from the transcript head: the first `cwd`
    /// value whose slug is the transcript's own project directory.
    func testRecoveredCwdComesFromTheTranscriptHead() {
        let underscore = "/Users/test/work_b.dir"
        let slug = ClaudeCodeStrategy.projectSlug(forCwd: underscore)
        let fs = mockFS(present: [uuidA], cwd: underscore)
        fs.projectDirs = [slug]
        fs.prefixes["/Users/test/.claude/projects/\(slug)/\(uuidA).jsonl"] = [
            #"{"type":"last-prompt","sessionId":"x"}"#,
            #"{"type":"mode","mode":"normal"}"#,
            #"{"type":"user","cwd":"/Users/test/elsewhere","message":"x"}"#,
            #"{"type":"user","cwd":"\#(underscore)","message":"y"}"#,
        ].joined(separator: "\n")
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: nil, capturedVia: .hook, state: .alive)
        XCTAssertEqual(ClaudeCodeStrategy().recoveredCwd(for: ref, filesystem: fs), underscore)
        let right = ConversationRef(kind: "claude-code", id: uuidA, cwd: underscore, capturedVia: .hook, state: .alive)
        XCTAssertNil(ClaudeCodeStrategy().recoveredCwd(for: right, filesystem: fs), "a cwd that already leads there stays")
    }

    /// The verdict carries the recovered cwd into the ref, so the typed resume
    /// `cd`s into the folder Claude filed the session under.
    func testVerifiedVerdictFillsTheRefsCwdAndTheResumeCdsThere() async {
        let fs = mockFS(present: [uuidA], cwd: cwd)
        let slug = ClaudeCodeStrategy.projectSlug(forCwd: cwd)
        fs.projectDirs = [slug]
        fs.prefixes["/Users/test/.claude/projects/\(slug)/\(uuidA).jsonl"] = #"{"cwd":"\#(cwd)"}"#
        let store = ConversationStore()
        let surface = UUID().uuidString
        _ = await store.captureClaudeBridgeSession(surfaceId: surface, sessionID: uuidA, isCurrent: { true })
        let records = await store.snapshot()
        XCTAssertNil(records[surface]?.active?.cwd, "the bridge had no cwd to give")
        let verdicts = ConversationStore.crashTranscriptVerdicts(for: records, registry: .v1, filesystem: fs)
        await store.applyCrashTranscriptVerdicts(verdicts)
        let active = await store.active(for: surface)
        XCTAssertEqual(active?.state, .suspended)
        XCTAssertEqual(active?.cwd, cwd)
        guard let active, case .command(let command) = Workspace.resumeDecision(for: active, registry: .v1, mode: .dirty) else {
            return XCTFail("a verified transcript resumes in a dirty launch")
        }
        XCTAssertTrue(command.text.hasPrefix("cd '\(cwd)' && "), command.text)
        XCTAssertTrue(command.text.contains("--resume '\(uuidA)'"), command.text)
    }

    /// C11H-196 gate B: after a clean shutdown a kind that cannot be checked
    /// keeps its state and resumes; after a dirty one it does not.
    func testUnverifiableKindIsDowngradedOnlyAfterADirtyShutdown() async {
        for dirty in [false, true] {
            let store = ConversationStore()
            await store.push(surfaceId: "S1", kind: "kimi", id: "real-id", source: .hook, cwd: cwd, state: .alive)
            let verdicts = ConversationStore.crashTranscriptVerdicts(for: await store.snapshot(), registry: .v1,
                                                                     filesystem: mockFS(present: [], cwd: cwd))
            await store.applyCrashTranscriptVerdicts(verdicts, downgradeUnverifiable: dirty)
            let active = await store.active(for: "S1")
            XCTAssertEqual(active?.state, dirty ? .unknown : .alive)
        }
    }

    /// The bridge records the agent's own folder, and a later report of the
    /// same session without one keeps it.
    func testBridgeCaptureRecordsAndKeepsTheAgentsCwd() async {
        let store = ConversationStore()
        let surface = UUID().uuidString
        let first = await store.captureClaudeBridgeSession(surfaceId: surface, sessionID: uuidA, cwd: cwd, isCurrent: { true })
        XCTAssertEqual(first?.cwd, cwd)
        let again = await store.captureClaudeBridgeSession(surfaceId: surface, sessionID: uuidA, cwd: nil, isCurrent: { true })
        XCTAssertEqual(again?.cwd, cwd)
        let other = UUID().uuidString
        _ = await store.captureClaudeBridgeSession(surfaceId: other, sessionID: uuidB, isCurrent: { true })
        let filled = await store.captureClaudeBridgeSession(surfaceId: other, sessionID: uuidB, cwd: "/Users/test/b",
                                                            isCurrent: { true })
        XCTAssertEqual(filled?.cwd, "/Users/test/b", "a cwd learned later fills an exact ref that had none")
    }

    func testTranscriptExistsNilWhenIdInvalid() {
        let fs = mockFS(present: [], cwd: cwd)
        let ref = ConversationRef(kind: "claude-code", id: "not-a-uuid", cwd: cwd,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertNil(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs))
    }

    func testNonClaudeStrategyTranscriptExistsDefaultsNil() {
        let fs = mockFS(present: [], cwd: cwd)
        let ref = ConversationRef(kind: "kimi", id: "real-id", cwd: cwd,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertNil(KimiStrategy().transcriptExists(for: ref, filesystem: fs))
    }

    /// Codex resumes after a crash too: `transcriptExists` finds the
    /// `rollout-<ts>-<uuid>.jsonl` on disk via the CodexScraper (which extracts
    /// the trailing UUID), so the ref is promoted to `.suspended` rather than
    /// forced `.unknown`. Exact-path stat isn't constructable (date-nested,
    /// unknown timestamp), hence the scraper-membership check.
    func testCodexTranscriptExistsViaScraper() {
        let fs = MockFS()
        let codexRoot = fs.home!
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let name = "rollout-2025-11-18T16-49-19-\(uuidA).jsonl"
        fs.recursiveEntries[codexRoot] = [
            ConversationFilesystemEntry(
                url: codexRoot.appendingPathComponent("2025/11/18").appendingPathComponent(name),
                fileName: name, mtime: Date(), size: 1024)
        ]
        let present = ConversationRef(kind: "codex", id: uuidA, cwd: cwd,
                                      capturedVia: .scrape, state: .suspended)
        XCTAssertEqual(CodexStrategy().transcriptExists(for: present, filesystem: fs), true)
        let absent = ConversationRef(kind: "codex", id: uuidB, cwd: cwd,
                                     capturedVia: .scrape, state: .suspended)
        XCTAssertEqual(CodexStrategy().transcriptExists(for: absent, filesystem: fs), false)
    }

    func testCodexExactTranscriptExistsBeyondNewestFiveHundredTwelve() {
        let fs = MockFS()
        let codexRoot = fs.home!
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        var entries: [ConversationFilesystemEntry] = []
        for index in 0..<513 {
            let id = String(format: "%08x-2222-4333-8444-555566667777", index)
            let name = "rollout-newer-\(id).jsonl"
            entries.append(ConversationFilesystemEntry(
                url: codexRoot.appendingPathComponent(name),
                fileName: name,
                mtime: Date(timeIntervalSince1970: Double(10_000 - index)),
                size: 1
            ))
        }
        let targetName = "rollout-old-\(uuidA).jsonl"
        entries.append(ConversationFilesystemEntry(
            url: codexRoot.appendingPathComponent(targetName),
            fileName: targetName,
            mtime: .distantPast,
            size: 1
        ))
        fs.recursiveEntries[codexRoot] = entries
        let target = ConversationRef(
            kind: "codex", id: uuidA, cwd: cwd,
            capturedVia: .runtimeEnv, state: .suspended
        )
        XCTAssertEqual(CodexStrategy().transcriptExists(for: target, filesystem: fs), true)
    }

    // MARK: - C11-206 completion-aware final store reads

    func testDelayedFinalConversationStoreReadReturnsResolvedRef() async {
        let store = ConversationStore()
        _ = await store.captureRuntimeEnv(
            surfaceId: "S1",
            id: uuidA,
            cwd: cwd
        )
        let outcome: BoundedLifecycleOutcome<[String: PanelConversations]> =
            BoundedLifecycleWait.run(timeout: 1.0) {
                try await Task.sleep(nanoseconds: 20_000_000)
                return await store.snapshot()
            }
        guard case .completed(let snapshot) = outcome else {
            return XCTFail("delayed store read should complete inside budget")
        }
        XCTAssertEqual(snapshot["S1"]?.active?.id, uuidA)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testTimedOutFinalConversationStoreReadDoesNotReturnEmptySuccess() async {
        let store = ConversationStore()
        _ = await store.captureRuntimeEnv(
            surfaceId: "S1",
            id: uuidA,
            cwd: cwd
        )
        let outcome: BoundedLifecycleOutcome<[String: PanelConversations]> =
            BoundedLifecycleWait.run(timeout: 0.005) {
                try await Task.sleep(nanoseconds: 100_000_000)
                return await store.snapshot()
            }
        guard case .timedOut = outcome else {
            return XCTFail("late store read must time out rather than return [:]")
        }
    }

    // MARK: - resume: suspended is resumable, unknown/tombstoned skip

    func testResumeEmitsTypeCommandForSuspended() {
        let ref = ConversationRef(kind: "claude-code", id: uuidA,
                                  capturedVia: .hook, state: .suspended)
        guard case .typeCommand(let text, let submit) = ClaudeCodeStrategy().resume(ref: ref) else {
            return XCTFail("expected typeCommand for suspended ref")
        }
        XCTAssertTrue(submit)
        XCTAssertTrue(text.contains("--resume"))
        XCTAssertTrue(text.contains(uuidA))
    }

    func testResumeSkipsUnknownAndTombstoned() {
        for state in [ConversationState.unknown, .tombstoned] {
            let ref = ConversationRef(kind: "claude-code", id: uuidA,
                                      capturedVia: .hook, state: state)
            guard case .skip(let reason) = ClaudeCodeStrategy().resume(ref: ref) else {
                return XCTFail("expected skip for state=\(state)")
            }
            XCTAssertTrue(reason.contains(state.rawValue))
        }
    }

    // MARK: - reclassifyAfterCrash matrix

    func testReclassifyVerifiedBecomesSuspended() async {
        let store = ConversationStore()
        await store.push(surfaceId: "S1", kind: "claude-code", id: uuidA,
                         source: .hook, cwd: cwd, state: .alive)
        await store.reclassifyAfterCrash(registry: .v1, filesystem: mockFS(present: [uuidA], cwd: cwd))
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .suspended)
        XCTAssertEqual(active?.diagnosticReason, "crash recovery: transcript verified on disk")
    }

    func testReclassifyMissingBecomesUnknown() async {
        let store = ConversationStore()
        await store.push(surfaceId: "S1", kind: "claude-code", id: uuidA,
                         source: .hook, cwd: cwd, state: .alive)
        await store.reclassifyAfterCrash(registry: .v1, filesystem: mockFS(present: [], cwd: cwd))
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .unknown)
        XCTAssertEqual(active?.diagnosticReason, "crash recovery: transcript not found")
    }

    func testReclassifyLeavesTombstonedUntouched() async {
        let store = ConversationStore()
        await store.push(surfaceId: "S1", kind: "claude-code", id: uuidA,
                         source: .hook, cwd: cwd, state: .tombstoned)
        await store.reclassifyAfterCrash(registry: .v1, filesystem: mockFS(present: [uuidA], cwd: cwd))
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .tombstoned,
                       "tombstoned (e.g. /exit) must survive a crash without reviving")
    }

    func testReclassifyLeavesUnknownUntouched() async {
        let store = ConversationStore()
        await store.push(surfaceId: "S1", kind: "claude-code", id: uuidA,
                         source: .hook, cwd: cwd, state: .unknown)
        await store.reclassifyAfterCrash(registry: .v1, filesystem: mockFS(present: [uuidA], cwd: cwd))
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .unknown, "idempotent across a double crash")
    }

    func testReclassifyNonClaudeKindBecomesUnknown() async {
        let store = ConversationStore()
        await store.push(surfaceId: "S1", kind: "kimi", id: "real-id",
                         source: .hook, cwd: cwd, state: .alive)
        await store.reclassifyAfterCrash(registry: .v1, filesystem: mockFS(present: [], cwd: cwd))
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .unknown)
    }

    func testReclassifyMixedSurfaces() async {
        let store = ConversationStore()
        await store.push(surfaceId: "S1", kind: "claude-code", id: uuidA,
                         source: .hook, cwd: cwd, state: .alive)
        await store.push(surfaceId: "S2", kind: "claude-code", id: uuidB,
                         source: .hook, cwd: cwd, state: .alive)
        await store.reclassifyAfterCrash(registry: .v1, filesystem: mockFS(present: [uuidA], cwd: cwd))
        let a = await store.active(for: "S1")
        let b = await store.active(for: "S2")
        XCTAssertEqual(a?.state, .suspended)
        XCTAssertEqual(b?.state, .unknown)
    }
}
