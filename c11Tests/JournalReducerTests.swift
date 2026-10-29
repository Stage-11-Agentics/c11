import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

enum JournalTestData {
    static let panel = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let instance = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static func draft(_ kind: JournalKind, at: Int64 = 1_000) -> JournalDraft {
        JournalDraft(kind: kind, emittedAtMs: at, panelID: panel, workspaceID: workspace,
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
        XCTAssertEqual(PanelActivityResolver.resolve(hasExactSurfaceNotification: false,
            hasJournalAttention: true, derivedActivity: .idle, terminalType: "claude-code"), .waiting)
        XCTAssertEqual(PanelActivityResolver.resolve(hasExactSurfaceNotification: false,
            hasJournalAttention: true, derivedActivity: .idle, terminalType: "claude-code", suppressed: true), .idle)
        XCTAssertEqual(PanelActivityResolver.resolve(hasExactSurfaceNotification: false,
            hasJournalAttention: true, derivedActivity: .idle, terminalType: "claude-code", flagged: true, suppressed: true), .waiting)
        XCTAssertEqual(PanelActivityResolver.resolve(hasExactSurfaceNotification: false,
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
        // A transcript turn end without the agent's own verified clock is not a boundary.
        var transcript = stop; transcript.source = .transcript; transcript.adapter = .codexTranscript
        XCTAssertNil(JournalMailboxBoundary.make(draft: transcript, result: result(transcript), historical: false, pid: 123))
        // A hook edge without the interactive PID is a headless run.
        XCTAssertEqual(JournalMailboxBoundary.make(draft: stop, result: result(stop), historical: false, pid: nil)?.headless, true)
        XCTAssertEqual(JournalMailboxBoundary.make(draft: stop, result: result(stop), historical: false, pid: 123)?.headless, false)
    }

    private func codexTranscript(_ kind: JournalKind, turn: String, endedAtMs: Int64) -> JournalDraft {
        var draft = JournalDraft(kind: kind, emittedAtMs: endedAtMs + 200, panelID: JournalTestData.panel,
                                 workspaceID: JournalTestData.workspace, sessionID: "fixture-session",
                                 agentKind: "codex", source: .transcript, adapter: .codexTranscript,
                                 nativeEvent: kind == .turnStarted ? "turn.started" : "turn.completed")
        draft.adapterVersion = JournalNativeClockEvidence.codexTranscriptVersion
        draft.turnID = turn
        draft.occurredAtMs = endedAtMs
        draft.timeQuality = .nativeLocal
        return draft
    }

    private func codexNotify(at: Int64) -> JournalDraft {
        JournalDraft(kind: .turnCompleted, emittedAtMs: at, panelID: JournalTestData.panel,
                     workspaceID: JournalTestData.workspace, sessionID: "fixture-session",
                     agentKind: "codex", source: .hook, adapter: .codexNotify, nativeEvent: "agent-turn-complete")
    }

    private func appended(_ prior: JournalSnapshot?, _ draft: JournalDraft, seq: Int64) -> (JournalAppendResult, JournalSnapshot?) {
        let context = draft.source == .transcript
            ? JournalContext.forTranscriptAppend(draft: draft, eligible: true)
            : JournalContext.forAppend(draft: draft, eligible: true)
        let fold = JournalTestData.fold(prior, draft, seq: seq, context: context)
        let result = JournalAppendResult(receipt: JournalReceipt(eventID: draft.eventID, sequence: seq,
            committedAtMs: 10_000 + seq, replayed: false, projectionEffect: fold.effect),
            changedSnapshot: fold.snapshot == prior ? nil : fold.snapshot)
        return (result, fold.snapshot)
    }

    // C11-365: the 10 s transcript poll folded a Codex turn end 25 ms before the
    // notify hook; the hook folded as duplicate evidence and the gate never
    // heard the prompt edge. The transcript turn end is now the boundary,
    // stamped with Codex's own clock.
    func testTranscriptTurnEndThatBeatsTheNotifyHookIsTheBoundary() throws {
        let (startResult, working) = appended(nil, codexTranscript(.turnStarted, turn: "t1", endedAtMs: 5_000), seq: 1)
        XCTAssertEqual(working?.phase, .working)
        XCTAssertNil(JournalMailboxBoundary.make(draft: codexTranscript(.turnStarted, turn: "t1", endedAtMs: 5_000),
            result: startResult, historical: false, pid: nil), "a transcript turn start never touches the gate")

        let end = codexTranscript(.turnCompleted, turn: "t1", endedAtMs: 9_800)
        let (endResult, idle) = appended(working, end, seq: 2)
        XCTAssertEqual(endResult.receipt.projectionEffect, .applied)
        let boundary = try XCTUnwrap(JournalMailboxBoundary.make(draft: end, result: endResult, historical: false,
                                                                 pid: nil, verifiedNativeClock: true))
        XCTAssertFalse(boundary.working)
        XCTAssertFalse(boundary.headless)
        XCTAssertNil(boundary.pid)
        XCTAssertEqual(boundary.at, Date(timeIntervalSince1970: 9.8), "stamped when the turn ended, not when the poll saw it")

        let hook = codexNotify(at: 10_025)
        let (hookResult, refreshed) = appended(idle, hook, seq: 3)
        XCTAssertEqual(hookResult.receipt.projectionEffect, .duplicateEvidence)
        XCTAssertNil(JournalMailboxBoundary.make(draft: hook, result: hookResult, historical: false, pid: 4242))
        // The hook's refresh replaces the transcript's snapshot; the turn end still holds.
        XCTAssertTrue(boundary.stillHolds(projected: idle, current: refreshed))

        // Only the transcript route's own clock evidence qualifies a transcript turn end.
        XCTAssertNil(JournalMailboxBoundary.make(draft: end, result: endResult, historical: false, pid: nil))
        XCTAssertNil(JournalMailboxBoundary.make(draft: end, result: endResult, historical: true, pid: nil,
                                                 verifiedNativeClock: true))
        var child = end; child.isChild = true
        XCTAssertNil(JournalMailboxBoundary.make(draft: child, result: endResult, historical: false, pid: nil,
                                                 verifiedNativeClock: true))
        // A skewed agent clock never stamps the gate later than c11 recorded the turn end.
        var future = end; future.occurredAtMs = 99_000
        XCTAssertEqual(JournalMailboxBoundary.make(draft: future, result: endResult, historical: false, pid: nil,
                                                   verifiedNativeClock: true)?.at,
                       Date(timeIntervalSince1970: Double(endResult.receipt.committedAtMs) / 1000))
    }

    // C11-365: a turn edge whose snapshot was superseded reaches the gate only
    // while the current state of the same owner agrees with it.
    func testSupersededTurnEdgeReachesTheGateOnlyWhenStateAgrees() throws {
        let (_, working) = appended(nil, codexTranscript(.turnStarted, turn: "t1", endedAtMs: 5_000), seq: 1)
        let (_, idle) = appended(working, codexTranscript(.turnCompleted, turn: "t1", endedAtMs: 9_800), seq: 2)
        let (_, nextTurn) = appended(idle, codexTranscript(.turnStarted, turn: "t2", endedAtMs: 12_000), seq: 3)
        let idleEdge = JournalMailboxBoundary(working: false, pid: nil, at: Date(timeIntervalSince1970: 9.8), headless: false)
        let workingEdge = JournalMailboxBoundary(working: true, pid: 4242, at: Date(timeIntervalSince1970: 5), headless: false)

        XCTAssertTrue(idleEdge.stillHolds(projected: idle, current: idle))
        XCTAssertFalse(idleEdge.stillHolds(projected: idle, current: nextTurn), "an old turn end never reopens a newer turn")
        XCTAssertFalse(workingEdge.stillHolds(projected: working, current: idle), "an old start never strands an idle agent")
        XCTAssertTrue(workingEdge.stillHolds(projected: working, current: nextTurn))

        var otherOwner = try XCTUnwrap(idle)
        otherOwner.owner = JournalOwner(panelID: JournalTestData.panel, agentKind: "codex", sessionID: "another-session")
        XCTAssertFalse(idleEdge.stillHolds(projected: idle, current: otherOwner))
        XCTAssertFalse(idleEdge.stillHolds(projected: idle, current: nil))
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

    // Seeing or an uncorrelated Stop is not a response to a blocked request.
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

    func testOnlySameTurnClaudeHookStopResolvesApproval() throws {
        var approval = JournalTestData.draft(.approvalRequested)
        approval.turnID = "approval-turn"
        let blocked = try XCTUnwrap(JournalTestData.fold(nil, approval, seq: 1).snapshot)
        var stop = JournalTestData.draft(.turnCompleted)
        XCTAssertEqual(JournalTestData.fold(blocked, stop, seq: 2).snapshot, blocked)
        stop.turnID = "other-turn"
        XCTAssertEqual(JournalTestData.fold(blocked, stop, seq: 3).snapshot, blocked)
        stop.turnID = "approval-turn"
        stop.adapter = .codexNotify
        XCTAssertEqual(JournalTestData.fold(blocked, stop, seq: 4).snapshot, blocked)
        stop.adapter = .claudeHook; stop.source = .transcript
        XCTAssertEqual(JournalTestData.fold(blocked, stop, seq: 5).snapshot, blocked)
        stop.source = .hook
        let completed = try XCTUnwrap(JournalTestData.fold(blocked, stop, seq: 6).snapshot)
        XCTAssertEqual(completed.phase, .idle)
        XCTAssertEqual(completed.turnOutcome, "completed")
        XCTAssertNil(completed.reason)
        XCTAssertNil(completed.requestID)
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

    // C11-275: exact Codex ownership exposes the unsupported hook coverage as
    // degraded without opening a turn; the existing root notify still owns
    // completion and a repeat is duplicate evidence.
    func testCodexNotifyKeepsDegradedHookCoverageAndDeduplicatesCompletion() throws {
        var gap = JournalTestData.draft(.stateChanged)
        gap.agentKind = "codex"
        gap.source = .c11
        gap.adapter = .c11
        gap.nativeEvent = "adapter_gap"
        gap.signal = .adapterGap
        let degraded = try XCTUnwrap(JournalTestData.fold(nil, gap, seq: 1).snapshot)
        XCTAssertEqual(degraded.owner.agentKind, "codex")
        XCTAssertEqual(degraded.phase, .unknown)
        XCTAssertEqual(degraded.health, .degraded)

        var notify = JournalTestData.draft(.turnCompleted)
        notify.agentKind = "codex"
        notify.adapter = .codexNotify
        notify.nativeEvent = "agent-turn-complete"
        let completed = try XCTUnwrap(JournalTestData.fold(degraded, notify, seq: 2).snapshot)
        XCTAssertEqual(completed.phase, .idle)
        XCTAssertEqual(completed.turnOutcome, "completed")
        XCTAssertEqual(completed.health, .degraded)
        XCTAssertEqual(completed.adapter, .codexNotify)

        let duplicate = JournalTestData.fold(completed, notify, seq: 3)
        XCTAssertEqual(duplicate.effect, .duplicateEvidence)
        XCTAssertEqual(duplicate.snapshot?.phase, .idle)
        XCTAssertEqual(duplicate.snapshot?.health, .degraded)
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

    func testTranscriptRankNeverSetsOrClearsBlockedAndGrokCannotClaimInterrupt() {
        let blocked = JournalTestData.fold(nil, JournalTestData.draft(.questionRequested), seq: 1).snapshot

        var transcriptStart = JournalTestData.draft(.turnStarted)
        transcriptStart.source = .transcript
        transcriptStart.adapter = .codexTranscript
        transcriptStart.nativeEvent = "turn.started"
        transcriptStart.turnID = "turn-1"
        let afterStart = JournalTestData.fold(blocked, transcriptStart, seq: 2)
        XCTAssertEqual(afterStart.effect, .advisory)
        XCTAssertEqual(afterStart.snapshot?.phase, .blocked)
        XCTAssertEqual(afterStart.snapshot?.rank, JournalSource.hook.rank)

        var transcriptStop = JournalTestData.draft(.turnCompleted)
        transcriptStop.source = .transcript
        transcriptStop.adapter = .codexTranscript
        transcriptStop.nativeEvent = "turn.completed"
        transcriptStop.turnID = "turn-1"
        let afterStop = JournalTestData.fold(blocked, transcriptStop, seq: 3)
        XCTAssertEqual(afterStop.effect, .advisory)
        XCTAssertEqual(afterStop.snapshot?.phase, .blocked)

        var gap = JournalTestData.draft(.stateChanged)
        gap.source = .c11
        gap.adapter = .c11
        gap.nativeEvent = "adapter_gap"
        gap.signal = .adapterGap
        let degraded = JournalTestData.fold(blocked, gap, seq: 4)
        XCTAssertEqual(degraded.snapshot?.phase, .blocked)
        XCTAssertEqual(degraded.snapshot?.health, .degraded)

        var grokInterrupt = transcriptStop
        grokInterrupt.adapter = .grokTranscript
        XCTAssertEqual(JournalAdapter.grokTranscript.capabilities, ["turn"])
        XCTAssertEqual(JournalTestData.fold(afterStart.snapshot, grokInterrupt, seq: 5).effect, .advisory)
    }

    // Retain C11-271 provenance: replay the captured hook stream in its recorded order.
    func testMergedFixtureCorpusHookSequences() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lifecycle/normalized")
        for (name, expected) in [("derived-late-pretool-after-stop", JournalPhase.idle), ("claude-bypass-ask", .blocked), ("claude-bypass-ask-answered", .idle)] {
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
                case "PostToolUse": kind = (tool == "AskUserQuestion" || tool == "ExitPlanMode") ? .attentionResolved : .stateChanged
                default: continue
                }
                var draft = JournalTestData.draft(kind)
                draft.nativeEvent = native
                let attrs = event["attrs"] as? [String: Any] ?? [:]
                draft.turnID = attrs["prompt_id"] as? String
                draft.requestID = attrs["tool_use_id"] as? String
                if kind == .attentionResolved { draft.resolution = .resumed }
                if kind == .stateChanged { draft.signal = .toolActivity }
                // Capture timestamps are observational, not certified native causality.
                draft.timeQuality = .observed
                draft.occurredAtMs = (event["t_ms"] as? NSNumber)?.int64Value ?? 0
                state = JournalTestData.fold(state, draft, seq: Int64(index + 1)).snapshot
                if kind == .attentionResolved { XCTAssertEqual(state?.phase, .working, name) }

            }
            XCTAssertEqual(state?.phase, expected, name)
        }
    }

    // MARK: - C11-398: a resumed session re-attaches as unknown

    private func sessionStart() -> JournalDraft {
        var draft = JournalTestData.draft(.sessionStarted)
        draft.nativeEvent = "SessionStart"
        return draft
    }

    private func mailboxResult(_ draft: JournalDraft, _ fold: JournalFoldResult) -> JournalAppendResult {
        JournalAppendResult(receipt: JournalReceipt(eventID: draft.eventID, sequence: 9, committedAtMs: 20_000,
                                                    replayed: false, projectionEffect: fold.effect),
                            changedSnapshot: fold.snapshot)
    }

    /// The observed C11-398 trace: the session was mid-turn (or idle) before
    /// the restart, its row came back from another process, and the resumed
    /// session's SessionStart folded as `session_already_known`. Nothing went
    /// live, so the shell's "working" stood for 37 hours.
    func testResumedSessionReattachesAsUnknownAndLive() throws {
        let started = try XCTUnwrap(JournalTestData.fold(nil, sessionStart(), seq: 1).snapshot)
        var working = try XCTUnwrap(JournalTestData.fold(started, JournalTestData.draft(.turnStarted), seq: 2).snapshot)
        XCTAssertEqual(working.phase, .working)
        working.appInstanceID = UUID() // the row an earlier c11 process wrote

        let resumed = JournalTestData.fold(working, sessionStart(), seq: 3)
        XCTAssertEqual(resumed.effect, .applied)
        XCTAssertEqual(resumed.reason, "session_reattached")
        let state = try XCTUnwrap(resumed.snapshot)
        XCTAssertEqual(state.phase, .unknown)
        XCTAssertEqual(state.connection, .live)
        XCTAssertEqual(state.confirmation, .confirmed)
        XCTAssertNil(state.turnID)
        XCTAssertFalse(state.terminalBarrier)

        // The harness's next edge decides the turn.
        XCTAssertEqual(JournalTestData.fold(state, JournalTestData.draft(.turnCompleted), seq: 4).snapshot?.phase, .idle)
    }

    /// A live row from this process is the same session still running. A
    /// `compact` SessionStart fires mid-turn and must not end the turn.
    func testLiveSessionStartIsAlreadyKnown() throws {
        let started = try XCTUnwrap(JournalTestData.fold(nil, sessionStart(), seq: 1).snapshot)
        let working = try XCTUnwrap(JournalTestData.fold(started, JournalTestData.draft(.turnStarted), seq: 2).snapshot)
        let again = JournalTestData.fold(working, sessionStart(), seq: 3)
        XCTAssertEqual(again.effect, .observation)
        XCTAssertEqual(again.reason, "session_already_known")
        XCTAssertEqual(again.snapshot?.phase, .working)

        // A drained (historical) start re-attaches nothing.
        var restored = working
        restored.appInstanceID = UUID()
        let drained = JournalTestData.fold(restored, sessionStart(), seq: 3,
                                           context: JournalContext(eligible: true, historical: true))
        XCTAssertEqual(drained.reason, "session_already_known")
        XCTAssertEqual(drained.snapshot?.phase, .working)
    }

    /// The order a real restart produces: the quit kills Claude, its
    /// SessionEnd hook finds no socket and spools, and the relaunched c11
    /// drains that spool before the resumed session's SessionStart. The drain
    /// restamps the row with this process's instance, but as history. The
    /// start must still re-attach (seen live on Atlas, C11-398).
    func testResumeAfterADrainedSessionEndReattaches() throws {
        let started = try XCTUnwrap(JournalTestData.fold(nil, sessionStart(), seq: 1).snapshot)
        var earlier = try XCTUnwrap(JournalTestData.fold(started, JournalTestData.draft(.turnCompleted), seq: 2).snapshot)
        earlier.appInstanceID = UUID() // written live by the c11 that quit
        XCTAssertGreaterThan(earlier.lastLiveSequence, 0)

        var end = JournalTestData.draft(.sessionEnded)
        end.nativeEvent = "SessionEnd"
        let drained = JournalTestData.fold(earlier, end, seq: 3, context: JournalContext(eligible: true, historical: true))
        let restamped = try XCTUnwrap(drained.snapshot)
        XCTAssertEqual(restamped.appInstanceID, JournalTestData.instance)
        XCTAssertEqual(restamped.connection, .disconnected)

        let resumed = JournalTestData.fold(restamped, sessionStart(), seq: 4)
        XCTAssertEqual(resumed.reason, "session_reattached")
        XCTAssertEqual(resumed.snapshot?.phase, .unknown)
        XCTAssertEqual(resumed.snapshot?.connection, .live)
    }

    /// A session this process saw end keeps its ended label when it starts
    /// again here (`JournalStoreTests` holds the restore side). Only a row
    /// from an earlier c11 process re-attaches.
    func testEndedSessionInThisProcessStaysKnown() throws {
        let started = try XCTUnwrap(JournalTestData.fold(nil, sessionStart(), seq: 1).snapshot)
        var end = JournalTestData.draft(.sessionEnded)
        end.nativeEvent = "SessionEnd"
        let ended = try XCTUnwrap(JournalTestData.fold(started, end, seq: 2).snapshot)
        XCTAssertEqual(ended.connection, .disconnected)
        let again = JournalTestData.fold(ended, sessionStart(), seq: 3)
        XCTAssertEqual(again.reason, "session_already_known")
        XCTAssertEqual(again.snapshot?.connection, .disconnected)

        var restored = ended
        restored.appInstanceID = UUID()
        XCTAssertEqual(JournalTestData.fold(restored, sessionStart(), seq: 3).reason, "session_reattached")
    }

    /// A live start that leaves the session unknown names the interactive
    /// process for the mailbox gate and says nothing about the turn.
    func testSessionStartIsAnAttachEdgeCarryingTheInteractivePID() throws {
        let start = sessionStart()
        var restored = try XCTUnwrap(JournalTestData.fold(nil, JournalTestData.draft(.turnCompleted), seq: 1).snapshot)
        restored.appInstanceID = UUID()
        for prior in [nil, restored] as [JournalSnapshot?] {
            let fold = JournalTestData.fold(prior, start, seq: 2)
            let edge = try XCTUnwrap(JournalMailboxBoundary.make(draft: start, result: mailboxResult(start, fold),
                                                                 historical: false, pid: 4242))
            XCTAssertTrue(edge.attached)
            XCTAssertFalse(edge.working)
            XCTAssertFalse(edge.headless)
            XCTAssertEqual(edge.pid, 4242)
            XCTAssertEqual(edge.at, Date(timeIntervalSince1970: 20))
            XCTAssertEqual(JournalMailboxBoundary.make(draft: start, result: mailboxResult(start, fold),
                                                       historical: false, pid: nil)?.headless, true)
            XCTAssertNil(JournalMailboxBoundary.make(draft: start, result: mailboxResult(start, fold),
                                                     historical: true, pid: 4242))
        }
        // An already-known start changes nothing and is no edge.
        let live = try XCTUnwrap(JournalTestData.fold(nil, start, seq: 1).snapshot)
        let known = JournalTestData.fold(live, start, seq: 2)
        let unchanged = JournalAppendResult(receipt: JournalReceipt(eventID: start.eventID, sequence: 2,
            committedAtMs: 20_000, replayed: false, projectionEffect: known.effect), changedSnapshot: nil)
        XCTAssertNil(JournalMailboxBoundary.make(draft: start, result: unchanged, historical: false, pid: 4242))

        // A superseded attach reaches the gate only while the session is still unknown.
        let attached = JournalMailboxBoundary(working: false, pid: 4242, at: Date(), headless: false, attached: true)
        let working = JournalTestData.fold(live, JournalTestData.draft(.turnStarted), seq: 3).snapshot
        XCTAssertTrue(attached.stillHolds(projected: live, current: live))
        XCTAssertFalse(attached.stillHolds(projected: live, current: working))
    }
}

/// C11-412. Claude fires no Stop hook on an Esc interrupt. Its transcript
/// marker ends the turn it names, and only that turn.
final class ClaudeTranscriptInterruptTests: XCTestCase {
    private func hookStart(prompt: String?) -> JournalDraft {
        var draft = JournalTestData.draft(.turnStarted)
        draft.turnID = prompt
        return draft
    }

    private func interrupt(prompt: String?, atMs: Int64 = 5_000) -> JournalDraft {
        var draft = JournalDraft(kind: .turnInterrupted, emittedAtMs: atMs + 200, panelID: JournalTestData.panel,
                                 workspaceID: JournalTestData.workspace, sessionID: "fixture-session",
                                 agentKind: "claude-code", source: .transcript, adapter: .claudeTranscript,
                                 nativeEvent: "turn.interrupted")
        draft.adapterVersion = JournalNativeClockEvidence.claudeTranscriptVersion
        draft.turnID = prompt
        draft.occurredAtMs = atMs
        draft.timeQuality = .nativeLocal
        return draft
    }

    func testMarkerForTheWorkingPromptEndsTheTurn() throws {
        let working = JournalTestData.fold(nil, hookStart(prompt: "prompt-1"), seq: 1).snapshot
        XCTAssertEqual(working?.phase, .working)
        let applied = JournalTestData.fold(working, interrupt(prompt: "prompt-1"), seq: 2)
        XCTAssertEqual(applied.effect, .applied)
        XCTAssertEqual(applied.snapshot?.phase, .idle)
        XCTAssertEqual(applied.snapshot?.turnOutcome, "interrupted")
    }

    /// A marker read late, after a newer prompt started, names the old prompt
    /// and must not idle the new turn. A marker with no prompt id cannot be
    /// tied to a turn at all, and neither can a turn whose hook gave no id.
    func testMarkerForAnotherPromptOrNoPromptChangesNothing() throws {
        let working = try XCTUnwrap(JournalTestData.fold(nil, hookStart(prompt: "prompt-2"), seq: 1).snapshot)
        for marker in [interrupt(prompt: "prompt-1"), interrupt(prompt: nil)] {
            let result = JournalTestData.fold(working, marker, seq: 2)
            XCTAssertEqual(result.effect, .stale)
            XCTAssertEqual(result.snapshot?.phase ?? working.phase, .working)
        }
        let unnamed = try XCTUnwrap(JournalTestData.fold(nil, hookStart(prompt: nil), seq: 1).snapshot)
        let result = JournalTestData.fold(unnamed, interrupt(prompt: "prompt-1"), seq: 2)
        XCTAssertEqual(result.effect, .stale)
    }

    /// A finished turn is not ended again, and a marker cannot start or end
    /// a turn as a Stop would: the adapter carries only `interrupt`.
    func testMarkerOnAnIdleTurnIsAdvisory() throws {
        let working = JournalTestData.fold(nil, hookStart(prompt: "prompt-1"), seq: 1).snapshot
        var stop = JournalTestData.draft(.turnCompleted)
        stop.turnID = "prompt-1"
        let stopped = JournalTestData.fold(working, stop, seq: 2).snapshot
        XCTAssertEqual(stopped?.phase, .idle)
        XCTAssertNotEqual(JournalTestData.fold(stopped, interrupt(prompt: "prompt-1"), seq: 3).effect, .applied)
        var asStop = interrupt(prompt: "prompt-1")
        asStop.kind = .turnCompleted
        XCTAssertEqual(JournalTestData.fold(working, asStop, seq: 3).effect, .advisory)
    }

    /// The interrupted turn reopens the mail gate, like a transcript turn end,
    /// stamped no later than c11 recorded it.
    func testInterruptedTurnIsAMailboxPromptBoundary() throws {
        let working = JournalTestData.fold(nil, hookStart(prompt: "prompt-1"), seq: 1).snapshot
        let marker = interrupt(prompt: "prompt-1", atMs: 9_000)
        let fold = JournalTestData.fold(working, marker, seq: 2)
        let result = JournalAppendResult(
            receipt: JournalReceipt(eventID: marker.eventID, sequence: 2, committedAtMs: 10_002,
                                    replayed: false, projectionEffect: fold.effect),
            changedSnapshot: fold.snapshot
        )
        let boundary = try XCTUnwrap(JournalMailboxBoundary.make(
            draft: marker, result: result, historical: false, pid: nil, verifiedNativeClock: true
        ))
        XCTAssertFalse(boundary.working)
        XCTAssertFalse(boundary.headless)
        XCTAssertEqual(boundary.at, Date(timeIntervalSince1970: 9))
        XCTAssertNil(JournalMailboxBoundary.make(
            draft: marker, result: result, historical: false, pid: nil, verifiedNativeClock: false
        ), "a transcript edge needs the reader's verified clock")
    }
}

/// C11-499: a hook from a panel that moved after its shell started names the
/// workspace it started in. The journal records it under the panel's workspace.
final class JournalMovedPanelAppendTests: XCTestCase {
    func testAppendFromAMovedPanelIsRecordedUnderItsLiveWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("c11-499-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory), clock: { 20_000 })
        let coordinator = JournalCoordinator(store: store)
        let panel = UUID(), start = UUID(), live = UUID()
        let owner = JournalOwner(panelID: panel, agentKind: "claude-code", sessionID: "c11-499-session")
        coordinator.register(panelID: panel, workspaceID: start)
        coordinator.setOwner(panelID: panel, owner: owner)
        defer { coordinator.remove(panelID: panel) }
        coordinator.register(panelID: panel, workspaceID: live)   // the move

        let draft = JournalDraft(kind: .turnStarted, emittedAtMs: 10_000, panelID: panel, workspaceID: start,
                                 sessionID: owner.sessionID, agentKind: owner.agentKind, source: .hook,
                                 adapter: .claudeHook, nativeEvent: "UserPromptSubmit")
        let result = try coordinator.append(draft)

        XCTAssertEqual(result.receipt.projectionEffect, .applied)
        XCTAssertEqual(try XCTUnwrap(store.current(owner: owner)).workspaceID, live)
    }
}
