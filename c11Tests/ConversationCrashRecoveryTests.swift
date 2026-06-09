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
        init(home: String = "/Users/test") { self.home = URL(fileURLWithPath: home) }
        var homeDirectory: URL? { home }
        func fileExists(atPath path: String) -> Bool { existingPaths.contains(path) }
        func listDirectoryByMtime(_ d: URL, max: Int) -> [ConversationFilesystemEntry] { [] }
        func listSessionsRecursivelyByMtime(_ r: URL, extensionFilter: String, max: Int) -> [ConversationFilesystemEntry] { [] }
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

    func testProjectSlugReplacesSlashesAndDots() {
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
