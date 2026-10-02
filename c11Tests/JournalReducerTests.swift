import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

enum JournalTestData {
    static let tab = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let instance = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static func draft(_ kind: JournalKind, at: Int64 = 1_000) -> JournalDraft {
        JournalDraft(kind: kind, emittedAtMs: at, tabID: tab, workspaceID: workspace,
                     sessionID: "fixture-session", agentKind: "claude-code", source: .hook, adapter: .claudeHook,
                     nativeEvent: kind == .turnStarted ? "UserPromptSubmit" : (kind == .turnCompleted ? "Stop" : "PreToolUse"))
    }
    static func fold(_ prior: JournalSnapshot?, _ draft: JournalDraft, seq: Int64,
                     context: JournalContext = JournalContext(eligible: true, verifiedNativeClock: true)) -> JournalFoldResult {
        JournalReducer.fold(previous: prior, draft: draft, sequence: seq, committedAtMs: 10_000 + seq,
                            tick: UInt64(seq), instanceID: instance, context: context)
    }
}

final class JournalReducerTests: XCTestCase {
    // C11-263 seen/sibling repair: unread can disappear independently of a blocked ask.
    func testJournalAttentionSurvivesSeenAndRespectsSuppressionAndFlag() {
        XCTAssertEqual(TabActivityResolver.resolve(hasExactSurfaceNotification: false,
            hasJournalAttention: true, derivedActivity: .idle, terminalType: "claude-code"), .waiting)
        XCTAssertEqual(TabActivityResolver.resolve(hasExactSurfaceNotification: false,
            hasJournalAttention: true, derivedActivity: .idle, terminalType: "claude-code", suppressed: true), .idle)
        XCTAssertEqual(TabActivityResolver.resolve(hasExactSurfaceNotification: false,
            hasJournalAttention: true, derivedActivity: .idle, terminalType: "claude-code", flagged: true, suppressed: true), .waiting)
        XCTAssertEqual(TabActivityResolver.resolve(hasExactSurfaceNotification: false,
            hasJournalAttention: false, derivedActivity: .working, terminalType: "claude-code"), .running)
    }

    // Restart while waiting: no duration since last run and no claim of live confirmation.
    func testRestoredAskHelpIsUnconfirmedWithoutDuration() throws {
        let state = try XCTUnwrap(JournalTestData.fold(nil, JournalTestData.draft(.questionRequested), seq: 1).snapshot)
        let restored = JournalReplayPolicy.restored(state)
        let help = AgentActivityHelpProjection.project(state: .waiting, lastActivityAt: nil,
            waitingStartedAt: nil, coldAfterSeconds: 60, flagReason: nil, flagRaisedAt: nil,
            suppressed: false, journal: restored)
        XCTAssertNil(help.stateStartedAt)
        XCTAssertTrue(help.text(at: Date()).contains("Unconfirmed"))
        XCTAssertTrue(help.text(at: Date()).contains("Question"))
    }

    // C11-257 integration: only committed live native turn boundaries may authorize stdin.
    func testMailboxDoesNotTreatBlockedReplayOrDuplicateAsPrompt() throws {
        func result(_ draft: JournalDraft, replayed: Bool = false) -> JournalAppendResult {
            let fold = JournalTestData.fold(nil, draft, seq: 1)
            return JournalAppendResult(receipt: JournalReceipt(eventID: draft.eventID, sequence: 1,
                committedAtMs: 10001, replayed: replayed, projectionEffect: fold.effect), changedSnapshot: fold.snapshot)
        }
        let stop = JournalTestData.draft(.turnCompleted)
        XCTAssertNotNil(JournalMailboxBoundary.make(draft: stop, result: result(stop), historical: false, pid: 123))
        XCTAssertNil(JournalMailboxBoundary.make(draft: stop, result: result(stop, replayed: true), historical: false, pid: 123))
        XCTAssertNil(JournalMailboxBoundary.make(draft: stop, result: result(stop), historical: true, pid: 123))
        let ask = JournalTestData.draft(.questionRequested)
        XCTAssertNil(JournalMailboxBoundary.make(draft: ask, result: result(ask), historical: false, pid: 123))
        var transcript = stop; transcript.source = .transcript; transcript.adapter = .codexTranscript
        XCTAssertNil(JournalMailboxBoundary.make(draft: transcript, result: result(transcript), historical: false, pid: 123))
    }

    // C11-271 derived-late-pretool-after-stop and the spec's missing/hook-start clock variants.
    func testLateToolCannotReopenCompletedTurnWithAnyClockQuality() throws {
        for quality in [JournalTimeQuality.nativeLocal, .observed, .missing] {
            var start = JournalTestData.draft(.turnStarted)
            start.occurredAtMs = quality == .missing ? nil : 50
            start.timeQuality = quality
            var stop = JournalTestData.draft(.turnCompleted)
            stop.occurredAtMs = quality == .missing ? nil : 200
            stop.timeQuality = quality
            var tool = JournalTestData.draft(.stateChanged)
            tool.signal = .toolActivity
            tool.occurredAtMs = quality == .missing ? nil : 100
            tool.timeQuality = quality
            let working = JournalTestData.fold(nil, start, seq: 9).snapshot
            let completed = JournalTestData.fold(working, stop, seq: 10).snapshot
            let late = JournalTestData.fold(completed, tool, seq: 11)
            XCTAssertEqual(late.snapshot?.phase, .idle)
            XCTAssertEqual(late.snapshot?.turnOutcome, "completed")
            XCTAssertEqual(late.effect, quality == .nativeLocal ? .stale : .advisory)
            var next = JournalTestData.draft(.turnStarted)
            next.turnID = "next-turn"
            XCTAssertEqual(JournalTestData.fold(late.snapshot, next, seq: 12).snapshot?.phase, .working)
        }
    }

    // Bypass AskUserQuestion/ExitPlanMode + seen/Stop are not responses.
    func testBypassRequestsPersistUntilCorrelatedResolution() {
        for kind in [JournalKind.questionRequested, .planReviewRequested, .approvalRequested] {
            var ask = JournalTestData.draft(kind)
            ask.requestID = "request-a"
            let blocked = JournalTestData.fold(nil, ask, seq: 1).snapshot
            XCTAssertEqual(blocked?.phase, .blocked)
            let stop = JournalTestData.fold(blocked, JournalTestData.draft(.turnCompleted), seq: 2)
            XCTAssertEqual(stop.snapshot, blocked)
            var resolve = JournalTestData.draft(.attentionResolved)
            resolve.requestID = "request-b"; resolve.resolution = .resumed
            XCTAssertEqual(JournalTestData.fold(blocked, resolve, seq: 3).snapshot, blocked)
            resolve.requestID = "request-a"
            XCTAssertEqual(JournalTestData.fold(blocked, resolve, seq: 4).snapshot?.phase, .working)
        }
    }

    // Esc captures expose gaps; a keypress cannot assert a successful interruption.
    func testSupportedInterruptAndKeyOnlyEvidenceHaveDifferentEffects() {
        let working = JournalTestData.fold(nil, JournalTestData.draft(.turnStarted), seq: 1).snapshot
        var interrupt = JournalTestData.draft(.turnInterrupted)
        interrupt.adapter = .keypress; interrupt.source = .keypress
        XCTAssertEqual(JournalTestData.fold(working, interrupt, seq: 2).effect, .advisory)
        interrupt.adapter = .codexTranscript; interrupt.source = .transcript
        let applied = JournalTestData.fold(working, interrupt, seq: 3)
        XCTAssertEqual(applied.snapshot?.turnOutcome, "interrupted")
        XCTAssertEqual(applied.snapshot?.phase, .idle)
    }

    // C11-189: no child callback can finish the captured root.
    func testChildAndUnknownOwnerDoNotChangeRoot() {
        let working = JournalTestData.fold(nil, JournalTestData.draft(.turnStarted), seq: 1).snapshot
        var child = JournalTestData.draft(.turnCompleted); child.isChild = true
        XCTAssertEqual(JournalTestData.fold(working, child, seq: 2).effect, .child)
        XCTAssertEqual(JournalTestData.fold(working, child, seq: 2).snapshot, working)
        child.isChild = false
        XCTAssertEqual(JournalTestData.fold(working, child, seq: 3, context: JournalContext(eligible: false)).effect, .unattributed)
    }

    // Hook/transcript overlap must not double count Q4 or reopen the native stop.
    func testTranscriptDuplicateStartCannotReopenHookBarrier() {
        let working = JournalTestData.fold(nil, JournalTestData.draft(.turnStarted), seq: 1).snapshot
        let stopped = JournalTestData.fold(working, JournalTestData.draft(.turnCompleted), seq: 2).snapshot
        var start = JournalTestData.draft(.turnStarted)
        start.adapter = .codexTranscript; start.source = .transcript
        XCTAssertEqual(JournalTestData.fold(stopped, start, seq: 3).effect, .duplicateEvidence)
        start.turnID = "new-native-turn"
        XCTAssertEqual(JournalTestData.fold(stopped, start, seq: 4).snapshot?.phase, .working)
    }

    // Retain C11-271 provenance: replay the captured hook stream in its recorded order.
    func testMergedFixtureCorpusHookSequences() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lifecycle/normalized")
        for (name, expected) in [("derived-late-pretool-after-stop", JournalPhase.idle), ("claude-bypass-ask", .blocked)] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name + ".json"))) as? [String: Any])
            let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            var state: JournalSnapshot?
            for (index, event) in events.enumerated() where event["source"] as? String == "claude-hook" {
                let native = event["name"] as? String ?? "other"
                let tool = event["tool_name"] as? String
                let kind: JournalKind
                switch native {
                case "SessionStart": kind = .sessionStarted
                case "UserPromptSubmit": kind = .turnStarted
                case "Stop": kind = .turnCompleted
                case "PreToolUse", "PermissionRequest":
                    kind = tool == "AskUserQuestion" ? .questionRequested : (tool == "ExitPlanMode" ? .planReviewRequested : .stateChanged)
                case "PostToolUse": kind = .stateChanged
                default: continue
                }
                var draft = JournalTestData.draft(kind)
                draft.nativeEvent = native
                if kind == .stateChanged { draft.signal = .toolActivity }
                // Capture timestamps are observational, not certified native causality.
                draft.timeQuality = .observed
                draft.occurredAtMs = (event["t_ms"] as? NSNumber)?.int64Value ?? 0
                state = JournalTestData.fold(state, draft, seq: Int64(index + 1)).snapshot
            }
            XCTAssertEqual(state?.phase, expected, name)
        }
    }
}
