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
        init(home: String = "/Users/test") { self.home = URL(fileURLWithPath: home) }
        var homeDirectory: URL? { home }
        func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
        func listDirectoryByMtime(_ d: URL, max: Int) -> [ConversationFilesystemEntry] { [] }
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
            ClaudeCodeStrategy.projectSlug(forCwd: "/Users/atin/Projects/Stage11/code/c11"),
            "-Users-atin-Projects-Stage11-code-c11"
        )
        // A `/.claude` segment collapses to `--claude` (slash + dot both → -).
        XCTAssertEqual(
            ClaudeCodeStrategy.projectSlug(forCwd: "/Users/atin/Projects/Stage11/code/c11/.claude/worktrees/c11-41"),
            "-Users-atin-Projects-Stage11-code-c11--claude-worktrees-c11-41"
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
                forCwd: "/Users/atin/Projects/Gregorovich/projects/singularist_salon"),
            "-Users-atin-Projects-Gregorovich-projects-singularist-salon"
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
        let underscoreCwd = "/Users/atin/Projects/Gregorovich/projects/singularist_salon"
        fs.existingPaths.insert(
            "/Users/test/.claude/projects/"
            + "-Users-atin-Projects-Gregorovich-projects-singularist-salon/\(uuidA).jsonl"
        )
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: underscoreCwd,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertEqual(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs), true)
    }

    func testTranscriptExistsNilWhenCwdMissing() {
        let fs = mockFS(present: [uuidA], cwd: cwd)
        let ref = ConversationRef(kind: "claude-code", id: uuidA, cwd: nil,
                                  capturedVia: .hook, state: .suspended)
        XCTAssertNil(ClaudeCodeStrategy().transcriptExists(for: ref, filesystem: fs))
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
        let outcome: BoundedLifecycleOutcome<[String: SurfaceConversations]> =
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
        let outcome: BoundedLifecycleOutcome<[String: SurfaceConversations]> =
            BoundedLifecycleWait.run(timeout: 0.005) {
                try await Task.sleep(nanoseconds: 100_000_000)
                return await store.snapshot()
            }
        guard case .timedOut = outcome else {
            return XCTFail("late store read must time out rather than return [:]")
        }
    }

    func testStartupTimeoutDurablyFailsClosedAcrossThirtyTwoRefs() async {
        let store = ConversationStore()
        for index in 0..<32 {
            _ = await store.captureRuntimeEnv(
                surfaceId: "S\(index)",
                id: String(format: "%08x-2222-3333-4444-555566667777", index),
                cwd: "/work/\(index)"
            )
        }
        let gate = ResumeStartupEpochGate()
        let token = gate.begin(mode: .clean)
        XCTAssertTrue(gate.markFailed(token, reason: "startup audit timeout"))
        await store.markAllUnknown(reason: "startup audit failed: timeout")

        let refs = await store.snapshot().values.compactMap(\.active)
        XCTAssertEqual(refs.count, 32)
        XCTAssertTrue(refs.allSatisfy { $0.state == .unknown })
        XCTAssertTrue(refs.allSatisfy {
            $0.diagnosticReason == "startup audit failed: timeout"
        })
        XCTAssertFalse(gate.snapshot().auditComplete)
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
