import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Synthetic J6 roster decisions. Timestamps are fixture values, not a captured corpus.
final class AgentRosterTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000
    private let tabA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let tabB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let tabC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let workspace = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    func testTwoOwnerDocumentKeepsNullsAndHistoricalCandidates() {
        let blocked = snapshot(tab: tabA, session: "owner-a", phase: .blocked, reason: .question, source: .hook, model: nil, confirmed: true)
        let working = snapshot(tab: tabB, session: "owner-b", phase: .working, reason: nil, source: .hook, model: "synthetic-model", confirmed: true)
        let historical = snapshot(tab: tabC, session: "owner-c", phase: .idle, reason: nil, source: .hook, model: nil, confirmed: false)
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let live = [
            AgentRoster.LiveTab(tabID: tabB, workspaceID: workspace, sessionID: "owner-b", kind: "claude-code", snapshot: working, turnStartedMs: 1_699_000_000_000, flagged: false, suppressed: false, lastSeenAt: nil),
            AgentRoster.LiveTab(tabID: tabC, workspaceID: workspace, sessionID: nil, kind: nil, snapshot: nil, turnStartedMs: nil, flagged: true, suppressed: false, lastSeenAt: seen),
            AgentRoster.LiveTab(tabID: tabA, workspaceID: workspace, sessionID: "owner-a", kind: "claude-code", snapshot: blocked, turnStartedMs: nil, flagged: false, suppressed: true, lastSeenAt: nil),
        ]
        let started = retained(.sessionStarted, sequence: 1, native: "SessionStart")
        let document = AgentRoster.document(
            live: live,
            currents: [blocked, working, historical],
            eventsByOwner: [historical.owner.key: [started]],
            truncatedOwners: [],
            unattributed: 2,
            storePruned: false,
            storageAvailable: true,
            healthDegraded: false,
            now: now,
            liveIdentity: "available"
        )
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        XCTAssertEqual(document["live_identity"] as? String, "available")
        let coverage = document["coverage"] as? [String: Any]
        XCTAssertEqual(coverage?["health"] as? String, "ok")
        XCTAssertEqual(coverage?["storage"] as? String, "ok")
        XCTAssertEqual(coverage?["unattributed"] as? Int, 2)
        let tabs = document["tabs"] as? [[String: Any]] ?? []
        XCTAssertEqual(tabs.map { $0["tab_id"] as? String }, [tabA.uuidString, tabB.uuidString, tabC.uuidString])
        let ask = tabs[0]
        XCTAssertEqual(ask["state"] as? String, "blocked")
        XCTAssertEqual(ask["reason"] as? String, "question")
        XCTAssertEqual(ask["source"] as? String, "hook")
        XCTAssertTrue(ask["model"] is NSNull)
        XCTAssertEqual(ask["freshness"] as? String, "fresh")
        XCTAssertEqual(ask["since"] as? String, AgentRoster.isoSeconds(ms: blocked.sinceMs))
        XCTAssertEqual(ask["suppressed"] as? Bool, true)
        let worker = tabs[1]
        XCTAssertEqual(worker["state"] as? String, "working")
        XCTAssertTrue(worker["reason"] is NSNull)
        XCTAssertEqual(worker["model"] as? String, "synthetic-model")
        XCTAssertEqual(worker["turn_started_at"] as? String, AgentRoster.isoSeconds(ms: 1_699_000_000_000))
        let bare = tabs[2]
        XCTAssertTrue(bare["state"] is NSNull)
        XCTAssertTrue(bare["session_id"] is NSNull)
        XCTAssertTrue(bare["kind"] is NSNull)
        XCTAssertEqual(bare["flag"] as? Bool, true)
        XCTAssertEqual(bare["last_seen_at"] as? String, AgentRoster.isoSeconds(date: seen))
        let candidates = document["restore_candidates"] as? [[String: Any]] ?? []
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0]["session_id"] as? String, "owner-c")
        XCTAssertEqual(candidates[0]["label"] as? String, "historical_candidate")
        XCTAssertEqual(candidates[0]["confirmation"] as? String, "unconfirmed")
        XCTAssertEqual(candidates[0]["connection"] as? String, "unknown")
        XCTAssertEqual(candidates[0]["coverage"] as? String, "retained")
    }

    func testRestoreLabelsKeepEndedAfterALaterConnectionObservation() {
        let started = retained(.sessionStarted, sequence: 1, native: "SessionStart")
        let ended = retained(.sessionEnded, sequence: 2, native: "SessionEnd")
        let lost = retained(.stateChanged, sequence: 3, native: "connection_lost", source: .c11, signal: .connectionLost)
        let restarted = retained(.sessionStarted, sequence: 4, native: "SessionStart")
        XCTAssertEqual(
            AgentRoster.classifyRestore(eventsNewestFirst: [started], truncated: false, storePruned: false),
            AgentRoster.RestoreClassification(label: "historical_candidate", coverage: "retained", connection: "unknown")
        )
        XCTAssertEqual(
            AgentRoster.classifyRestore(eventsNewestFirst: [lost, ended, started], truncated: false, storePruned: false),
            AgentRoster.RestoreClassification(label: "ended", coverage: "retained", connection: "disconnected")
        )
        XCTAssertEqual(
            AgentRoster.classifyRestore(eventsNewestFirst: [restarted, ended, started], truncated: false, storePruned: false),
            AgentRoster.RestoreClassification(label: "historical_candidate", coverage: "retained", connection: "unknown")
        )
        XCTAssertEqual(
            AgentRoster.classifyRestore(eventsNewestFirst: [lost], truncated: false, storePruned: false),
            AgentRoster.RestoreClassification(label: "unknown", coverage: "retained", connection: "disconnected")
        )
        XCTAssertEqual(
            AgentRoster.classifyRestore(eventsNewestFirst: [], truncated: true, storePruned: false),
            AgentRoster.RestoreClassification(label: "unknown", coverage: "event_pruned", connection: "unknown")
        )
        XCTAssertEqual(
            AgentRoster.classifyRestore(eventsNewestFirst: [], truncated: false, storePruned: true),
            AgentRoster.RestoreClassification(label: "unknown", coverage: "event_pruned", connection: "unknown")
        )
        XCTAssertEqual(
            AgentRoster.classifyRestore(eventsNewestFirst: [lost, started], truncated: false, storePruned: false).connection,
            "disconnected"
        )
    }

    func testOperatorResponseIsOncePerAskEventAndDoesNotClearBlocked() throws {
        var gate = OperatorResponseGate()
        let tab = tabA
        let ask = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let reused = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
        XCTAssertTrue(gate.begin(tab: tab, ask: ask))
        XCTAssertFalse(gate.begin(tab: tab, ask: ask))
        gate.succeed(tab: tab, ask: ask)
        XCTAssertFalse(gate.begin(tab: tab, ask: ask))
        XCTAssertTrue(gate.begin(tab: tab, ask: reused))
        let retry = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
        XCTAssertTrue(gate.begin(tab: tab, ask: retry))
        gate.fail(tab: tab, ask: retry)
        XCTAssertTrue(gate.begin(tab: tab, ask: retry))
        gate.clear(tab: tab)
        XCTAssertTrue(gate.begin(tab: tab, ask: ask))

        var open = JournalTestData.draft(.questionRequested)
        open.requestID = "request-a"
        let blocked = try XCTUnwrap(JournalTestData.fold(nil, open, seq: 1).snapshot)
        var response = JournalTestData.draft(.stateChanged)
        response.source = .c11
        response.adapter = .c11
        response.nativeEvent = "operator_response"
        response.signal = .operatorResponse
        response.requestID = "request-a"
        let observed = JournalTestData.fold(blocked, response, seq: 2)
        XCTAssertEqual(observed.effect, .observation)
        XCTAssertEqual(observed.reason, "operator_response")
        XCTAssertEqual(observed.snapshot?.phase, .blocked)
        XCTAssertNil(AgentRoster.lifecyclePayload(
            effect: observed.effect, from: observed.fromPhase, to: observed.snapshot?.phase,
            tab: tab, agent: "claude-code", reason: observed.snapshot?.reason))
        response.eventID = UUID()
        var unnamed = open
        unnamed.requestID = nil
        unnamed.eventID = UUID()
        let unnamedBlocked = try XCTUnwrap(JournalTestData.fold(nil, unnamed, seq: 3).snapshot)
        response.requestID = unnamed.eventID.uuidString
        let uncorrelated = JournalTestData.fold(unnamedBlocked, response, seq: 4)
        XCTAssertEqual(uncorrelated.effect, .advisory)
        XCTAssertEqual(uncorrelated.reason, "response_not_correlated")
        XCTAssertEqual(uncorrelated.snapshot?.phase, .blocked)
    }

    func testSubmitKeysAndPickerPolicy() {
        XCTAssertTrue(AgentRoster.isTerminalSubmit(keyCode: 36, modifierRaw: 0, isRepeat: false, synthesizing: false, hasMarkedText: false))
        XCTAssertTrue(AgentRoster.isTerminalSubmit(keyCode: 76, modifierRaw: 1 << 21, isRepeat: false, synthesizing: false, hasMarkedText: false))
        for bit in [AgentRoster.shiftModifier, AgentRoster.controlModifier, AgentRoster.optionModifier, AgentRoster.commandModifier] {
            XCTAssertFalse(AgentRoster.isTerminalSubmit(keyCode: 36, modifierRaw: bit, isRepeat: false, synthesizing: false, hasMarkedText: false))
        }
        XCTAssertFalse(AgentRoster.isTerminalSubmit(keyCode: 36, modifierRaw: 0, isRepeat: true, synthesizing: false, hasMarkedText: false))
        XCTAssertFalse(AgentRoster.isTerminalSubmit(keyCode: 36, modifierRaw: 0, isRepeat: false, synthesizing: true, hasMarkedText: false))
        XCTAssertFalse(AgentRoster.isTerminalSubmit(keyCode: 36, modifierRaw: 0, isRepeat: false, synthesizing: false, hasMarkedText: true))
        XCTAssertFalse(AgentRoster.isTerminalSubmit(keyCode: 123, modifierRaw: 0, isRepeat: false, synthesizing: false, hasMarkedText: false))
        XCTAssertFalse(AgentRoster.isPickerCommit(keyCode: 36, modifierRaw: 0, isRepeat: false, synthesizing: false, hasMarkedText: false, pickerKeyCode: nil, pickerModifierRaw: 0))
        XCTAssertTrue(AgentRoster.isPickerCommit(keyCode: 49, modifierRaw: 0, isRepeat: false, synthesizing: false, hasMarkedText: false, pickerKeyCode: 49, pickerModifierRaw: 0))
        XCTAssertFalse(AgentRoster.isPickerCommit(keyCode: 125, modifierRaw: 0, isRepeat: false, synthesizing: false, hasMarkedText: false, pickerKeyCode: 49, pickerModifierRaw: 0))
        XCTAssertFalse(AgentRoster.isPickerCommit(keyCode: 49, modifierRaw: 0, isRepeat: true, synthesizing: false, hasMarkedText: false, pickerKeyCode: 49, pickerModifierRaw: 0))
    }

    func testLifecyclePayloadEmitsOnlyAPhaseChange() {
        let tab = tabA
        let first = AgentRoster.lifecyclePayload(effect: .applied, from: nil, to: .blocked, tab: tab, agent: "claude-code", reason: .question)
        XCTAssertEqual(first?["tab"] as? String, tab.uuidString)
        XCTAssertEqual(first?["agent"] as? String, "claude-code")
        XCTAssertTrue(first?["from"] is NSNull)
        XCTAssertEqual(first?["to"] as? String, "blocked")
        XCTAssertEqual(first?["reason"] as? String, "question")
        XCTAssertNil(AgentRoster.lifecyclePayload(effect: .applied, from: .blocked, to: .blocked, tab: tab, agent: "claude-code", reason: .question))
        XCTAssertNil(AgentRoster.lifecyclePayload(effect: .duplicateEvidence, from: .working, to: .blocked, tab: tab, agent: "claude-code", reason: .question))
        XCTAssertNil(AgentRoster.lifecyclePayload(effect: .observation, from: .blocked, to: .working, tab: tab, agent: "claude-code", reason: nil))
        let failure = AgentRoster.lifecyclePayload(effect: .applied, from: .working, to: .error, tab: tab, agent: "claude-code", reason: .sessionFailure)
        XCTAssertEqual(failure?["to"] as? String, "error")
        XCTAssertTrue(failure?["reason"] is NSNull)
    }

    func testWaitAndClocksUseRecordedEvidenceOnly() {
        XCTAssertEqual(AgentRoster.waitMs(responseAt: 5500, askOpenedAt: 1000), 4500)
        XCTAssertNil(AgentRoster.waitMs(responseAt: nil, askOpenedAt: 1000))
        XCTAssertNil(AgentRoster.waitMs(responseAt: 5500, askOpenedAt: nil))
        XCTAssertNil(AgentRoster.waitMs(responseAt: 500, askOpenedAt: 1000))
        var native = JournalTestData.draft(.turnStarted)
        native.turnID = "turn-a"
        native.timeQuality = .nativeLocal
        native.occurredAtMs = 4_000
        let row = AgentRoster.RetainedEvent(sequence: 2, committedAtMs: 9_000, draft: native)
        XCTAssertEqual(AgentRoster.turnStartMs(turnID: "turn-a", eventsNewestFirst: [row]), 4_000)
        native.timeQuality = .observed
        let observed = AgentRoster.RetainedEvent(sequence: 2, committedAtMs: 9_000, draft: native)
        XCTAssertEqual(AgentRoster.turnStartMs(turnID: "turn-a", eventsNewestFirst: [observed]), 9_000)
        XCTAssertNil(AgentRoster.turnStartMs(turnID: "missing", eventsNewestFirst: [observed]))
        XCTAssertNil(AgentRoster.turnStartMs(turnID: nil, eventsNewestFirst: [observed]))

        var older = JournalTestData.draft(.questionRequested)
        older.requestID = "request-a"
        older.eventID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
        older.timeQuality = .nativeLocal
        older.occurredAtMs = 1_000
        var newer = older
        newer.eventID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        newer.occurredAtMs = 2_000
        let snap = snapshot(tab: tabA, session: "owner-a", phase: .blocked, reason: .question, source: .hook, model: nil, confirmed: true)
        var blocked = snap
        blocked.requestID = "request-a"
        let events = [
            AgentRoster.RetainedEvent(sequence: 2, committedAtMs: 8_000, draft: newer),
            AgentRoster.RetainedEvent(sequence: 1, committedAtMs: 7_000, draft: older),
        ]
        let restored = AgentRoster.restoredAsk(snapshot: blocked, eventsNewestFirst: events)
        XCTAssertEqual(restored?.eventID, newer.eventID)
        XCTAssertEqual(restored?.openedAtMs, 2_000)
        let clock = AgentRoster.sheetClock(phase: .working, activity: .running, flagged: false, historical: false, sinceMs: 5_000_000)
        XCTAssertEqual(clock, AgentRoster.SheetClock(applies: true, since: Date(timeIntervalSince1970: 5_000)))
        XCTAssertEqual(
            AgentRoster.sheetClock(phase: .blocked, activity: .waiting, flagged: true, historical: false, sinceMs: 5_000_000),
            AgentRoster.SheetClock(applies: false, since: nil)
        )
        XCTAssertEqual(
            AgentRoster.sheetClock(phase: .working, activity: .waiting, flagged: false, historical: false, sinceMs: 5_000_000),
            AgentRoster.SheetClock(applies: false, since: nil)
        )
        XCTAssertEqual(
            AgentRoster.sheetClock(phase: .working, activity: .running, flagged: false, historical: true, sinceMs: 5_000_000),
            AgentRoster.SheetClock(applies: true, since: nil)
        )
        XCTAssertEqual(
            AgentRoster.sheetClock(phase: .working, activity: .idle, flagged: false, historical: false, sinceMs: 5_000_000).applies,
            false
        )
    }

    private func snapshot(tab: UUID, session: String, phase: JournalPhase, reason: JournalReason?, source: JournalSource, model: String?, confirmed: Bool) -> JournalSnapshot {
        var row = JournalSnapshot(
            owner: JournalOwner(tabID: tab, agentKind: "claude-code", sessionID: session),
            workspaceID: workspace,
            appInstanceID: JournalTestData.instance
        )
        row.phase = phase
        row.reason = reason
        row.source = source
        row.adapter = source == .c11 ? .c11 : .claudeHook
        row.sinceMs = 1_699_000_000_000
        row.observedAtMs = now - 1_000
        row.modelID = model
        row.confirmation = confirmed ? .confirmed : .unconfirmed
        row.connection = confirmed ? .live : .disconnected
        return row
    }

    private func retained(_ kind: JournalKind, sequence: Int64, native: String, source: JournalSource = .hook, signal: JournalSignal? = nil) -> AgentRoster.RetainedEvent {
        var draft = JournalTestData.draft(kind)
        draft.nativeEvent = native
        draft.source = source
        draft.adapter = source == .c11 ? .c11 : .claudeHook
        draft.signal = signal
        return AgentRoster.RetainedEvent(sequence: sequence, committedAtMs: 10_000 + sequence, draft: draft)
    }
}
