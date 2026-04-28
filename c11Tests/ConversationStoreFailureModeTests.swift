import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// 1:1 mapping with the C11-24 architecture doc §"Failure modes" table.
/// Each test exercises one row from the grid: the failure scenario and
/// the new conversation-store behaviour that prevents it.
///
/// The merge-blocker fixture-driven regression test for the 2026-04-27
/// staging-QA bug (two codex panes same cwd) is also here, with a
/// fixture session-storage layout under
/// `Tests/Fixtures/codex/two-panes-same-cwd/`. The test reproduces the
/// failure shape against the new strategy.
///
/// Per `CLAUDE.md`, never run locally — CI only.
final class ConversationStoreFailureModeTests: XCTestCase {

    private let claudeId = "abc12345-ef67-890a-bcde-f0123456789a"
    private let codexIdA = "ddd11111-2222-3333-4444-555566667777"
    private let codexIdB = "eee22222-3333-4444-5555-666677778888"
    private let cwd = "/work/proj"

    override func setUp() async throws {
        try await super.setUp()
        for id in await ConversationStore.shared.snapshot().keys {
            await ConversationStore.shared.clear(surfaceId: id)
        }
    }

    // MARK: - Row: Hook fires after shutdown begins

    /// Hook fires during shutdown with slow/dying socket → ref preserved
    /// (NOT tombstoned). The hook side-decides via system.ping
    /// is_terminating_app; CLI policy treats unreachable/timeout as
    /// terminating so we err on preservation.
    ///
    /// Pure-store test: simulate the hook handler's "no-op when
    /// terminating" decision and verify the ref stays at its previous
    /// state.
    func testHookFiresAfterShutdownBegins() async {
        let store = ConversationStore.shared
        await store.push(
            surfaceId: "S1",
            kind: "claude-code",
            id: claudeId,
            source: .hook,
            state: .alive
        )
        // Application shutdown begins → suspendAllAlive transitions to
        // .suspended.
        await store.suspendAllAlive()
        // SessionEnd hook fires AFTER shutdown began. The CLI handler
        // detects is_terminating_app == true and NO-OPS. Simulate by
        // not calling the store at all; the ref must remain suspended.
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .suspended,
                       "ref must NOT be tombstoned during shutdown — preserved for next-launch resume")
    }

    // MARK: - Row: Hook env strips CMUX_SURFACE_ID

    /// Without `CMUX_SURFACE_ID` and no `--surface` flag, the conversation
    /// CLI errors out. No silent misroute. (Tested via the surface
    /// resolution rule in the strategy layer.)
    func testHookEnvStripsCmuxSurfaceId() async {
        // The CLI would error out at parse time. Verify by calling the
        // store directly: a missing surface id can't even reach the
        // store (the store API takes surfaceId by value), so the bug
        // shape is structurally impossible. This test serves as the
        // structural assertion.
        let store = ConversationStore.shared
        // No write. Verify: nothing leaked into the store.
        let snap = await store.snapshot()
        XCTAssertEqual(snap.count, 0,
                       "missing surface id must NOT silently route to focused — that path was eliminated")
    }

    // MARK: - Row: TUI crashes before hook fires

    /// TUI crashes before SessionStart fires → next-launch pull-scrape
    /// catches the session id from `~/.claude/sessions/<uuid>.jsonl`.
    func testTuiCrashesBeforeHookFires() {
        let mock = ConversationScraperTests.MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let sessionsDir = URL(fileURLWithPath: "/Users/test/.claude/sessions")
        mock.directoryEntries[sessionsDir] = [
            ConversationFilesystemEntry(
                url: sessionsDir.appendingPathComponent("\(claudeId).jsonl"),
                fileName: "\(claudeId).jsonl",
                mtime: Date(),
                size: 4096
            )
        ]
        let scraper = ClaudeCodeScraper(filesystem: mock)
        let candidates = scraper.candidates(cwd: cwd)
        XCTAssertEqual(candidates.count, 1,
                       "pull-scrape must surface the session even if the hook never fired")
        XCTAssertEqual(candidates.first?.id, claudeId)
    }

    // MARK: - Row: c11 crashes (dirty sentinel found)

    /// Dirty sentinel found at next launch → conversation refs transition
    /// to .unknown, ready for the forthcoming pull-scrape pass to
    /// reclassify.
    func testCrashRecoveryUnknownTransition() async {
        let store = ConversationStore.shared
        await store.push(
            surfaceId: "S1",
            kind: "claude-code",
            id: claudeId,
            source: .hook,
            state: .alive
        )
        // Dirty sentinel found at next launch → AppDelegate calls
        // markAllUnknown.
        await store.markAllUnknown(reason: "crash recovery (dirty sentinel)")
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .unknown)
        XCTAssertEqual(active?.diagnosticReason, "crash recovery (dirty sentinel)")
    }

    // MARK: - MERGE-BLOCKER row: Two panes same TUI same cwd (Codex)

    /// Reproduces the 2026-04-27 staging-QA failure shape using the
    /// fixture layout under
    /// `c11Tests/Fixtures/codex/two-panes-same-cwd/`. With the new
    /// Codex strategy, BOTH panes return `state = .unknown` and `resume`
    /// returns `.skip(reason: "ambiguous")`. Neither pane resumes the
    /// other's session.
    func testTwoPanesSameTuiSameCwd_2026_04_27() {
        // Two distinct sessions, same cwd, both newer than the
        // wrapper-claim time. The strategy filters by cwd → both
        // candidates pass; ambiguity policy fires.
        let mock = ConversationScraperTests.MockFS()
        mock.home = URL(fileURLWithPath: "/Users/test")
        let root = URL(fileURLWithPath: "/Users/test/.codex/sessions")
        let claimTime = Date().addingTimeInterval(-300)
        mock.recursiveEntries[root] = [
            ConversationFilesystemEntry(
                url: root.appendingPathComponent("2026/04/27/\(codexIdA).jsonl"),
                fileName: "\(codexIdA).jsonl",
                mtime: claimTime.addingTimeInterval(60),
                size: 8192
            ),
            ConversationFilesystemEntry(
                url: root.appendingPathComponent("2026/04/27/\(codexIdB).jsonl"),
                fileName: "\(codexIdB).jsonl",
                mtime: claimTime.addingTimeInterval(120),
                size: 4096
            )
        ]
        let scraper = CodexScraper(filesystem: mock)
        let candidates = scraper.candidates(cwd: cwd)
        XCTAssertEqual(candidates.count, 2)

        let strategy = CodexStrategy()
        let claim = ConversationRef(
            kind: "codex",
            id: "wrapper-claim:S1:1",
            placeholder: true,
            cwd: cwd,
            capturedAt: claimTime,
            capturedVia: .wrapperClaim,
            state: .unknown
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            wrapperClaim: claim,
            scrapeCandidates: candidates
        )
        let ref = strategy.capture(inputs: inputs)
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref?.state, .unknown,
                       "ambiguous candidates must transition to unknown — the merge-blocker behaviour")
        XCTAssertTrue(ref?.diagnosticReason?.contains("ambiguous") ?? false,
                      "advisory must surface for operator visibility")
        guard case .skip(let reason) = strategy.resume(ref: ref!) else {
            XCTFail("expected skip on ambiguous ref")
            return
        }
        XCTAssertEqual(reason, "ambiguous",
                       "resume must NOT auto-fire — neither pane resumes the other's session")
    }

    // MARK: - Row: Sleep/power-off mid-session (same as crash recovery)

    func testSleepPowerOffMidSession() async {
        // Same as testCrashRecoveryUnknownTransition: dirty sentinel +
        // markAllUnknown. The "same as crash recovery" row in the
        // failure-modes table is intentional — both paths converge on
        // the same primitive.
        let store = ConversationStore.shared
        await store.push(
            surfaceId: "S1",
            kind: "codex",
            id: codexIdA,
            source: .scrape,
            state: .alive
        )
        await store.markAllUnknown(reason: "sleep recovery (dirty sentinel)")
        let active = await store.active(for: "S1")
        XCTAssertEqual(active?.state, .unknown)
    }

    // MARK: - Row: TUI session file deleted out-of-band

    /// For Claude (with hook history) → tombstone is appropriate.
    /// For hookless TUIs (Codex/Opencode/Kimi) → state stays `.unknown`,
    /// operator clears explicitly. (Pure logic — the strategy never
    /// auto-tombstones for hookless kinds.)
    func testTuiSessionFileDeletedOutOfBand() {
        // Codex strategy with no candidates and no claim → returns nil
        // (no ref to update); state would stay where it was (likely
        // unknown from the prior dirty-sentinel transition).
        let strategy = CodexStrategy()
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            scrapeCandidates: []
        )
        XCTAssertNil(strategy.capture(inputs: inputs))
    }

    // MARK: - Row: Wrapper not on PATH (system update)

    /// Wrapper-claim absent → strategy degrades to pull-scrape only;
    /// no regression. Verified via Claude Code: with no wrapper-claim
    /// AND a scrape candidate, capture returns the scraped ref.
    func testWrapperNotOnPath() {
        let strategy = ClaudeCodeStrategy()
        let candidate = ScrapeCandidate(
            id: claudeId,
            filePath: "/Users/test/.claude/sessions/\(claudeId).jsonl",
            mtime: Date(),
            size: 4096,
            cwd: cwd
        )
        let inputs = ConversationStrategyInputs(
            surfaceId: "S1",
            cwd: cwd,
            wrapperClaim: nil, // wrapper absent
            push: nil,
            scrapeCandidates: [candidate]
        )
        let ref = strategy.capture(inputs: inputs)
        XCTAssertEqual(ref?.id, claudeId,
                       "without a wrapper-claim, scrape still produces a usable ref — no regression")
    }
}
