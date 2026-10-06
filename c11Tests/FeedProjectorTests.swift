import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11-264. Question/plan/permission rows follow the claude-bypass-ask PreToolUse shape
// (blocked + request id, source hook). Prompt text is the synthetic sentinel used only
// on the live note, never in the journal fold. Approval Stop follows the same-turn
// Claude hook rule already covered by JournalReducerTests.
final class FeedProjectorTests: XCTestCase {
    private let sentinel = "SYNTHETIC-PROMPT-264"
    private let otherTab = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    private let laterWorkspace = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!

    private func blocked(_ kind: JournalKind, request: String, tab: UUID = JournalTestData.tab, workspace: UUID = JournalTestData.workspace, seq: Int64 = 1) throws -> JournalSnapshot {
        var draft = JournalTestData.draft(kind)
        draft.requestID = request
        draft.tabID = tab
        draft.workspaceID = workspace
        return try XCTUnwrap(JournalTestData.fold(nil, draft, seq: seq).snapshot)
    }

    private func project(_ rows: [JournalSnapshot], attention: [FeedAttentionFact] = [], notes: [UUID: [String: FeedDisplayNote]] = [:], scope: FeedScope) -> [FeedRow] {
        FeedProjector.project(journalRows: rows, attention: attention, notes: notes, scope: scope)
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func flag(tab: UUID = JournalTestData.tab, workspace: UUID = JournalTestData.workspace, suppressed: Bool = false) -> FeedAttentionFact {
        FeedAttentionFact(workspaceID: workspace, tabID: tab, flagReason: "synthetic-flag", flagRaisedAtMs: 50, flagCallerTabID: otherTab, suppressed: suppressed)
    }

    func testFeedAnswerTextPolicyClassifiesNewlinesForPreDeliveryRefusal() {
        XCTAssertNil(FeedAnswerTextPolicy.refusalCode(for: "single line answer"))
        XCTAssertEqual(FeedAnswerTextPolicy.refusalCode(for: "first\nsecond"), "multiline_unsupported")
        XCTAssertEqual(FeedAnswerTextPolicy.refusalCode(for: "first\rsecond"), "multiline_unsupported")
        XCTAssertEqual(FeedAnswerTextPolicy.refusalCode(for: "first\u{2028}second"), "multiline_unsupported")
    }

    @MainActor
    func testAttentionServiceRemovalAndPruningRetireClosedTargets() throws {
        let bridge = FeedProjectionBridge()
        let service = TabAttentionService(feedProjection: bridge)
        let workspace = UUID()
        let flagOnly = UUID(), askTab = UUID(), survivor = UUID()
        for tab in [flagOnly, askTab, survivor] {
            try service.raise(workspaceId: workspace, surfaceId: tab, reason: "synthetic-flag", by: .operator, title: nil)
        }
        let ask = try blocked(.questionRequested, request: "closure", tab: askTab, workspace: workspace)
        bridge.noteJournal(tabID: askTab, snapshot: ask)
        func rows() -> [[String: Any]] { bridge.list(scope: .attention)["rows"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(rows().count, 3)
        // A journal owner disappearing alone must preserve the independent flag.
        bridge.noteJournal(tabID: askTab, snapshot: nil)
        XCTAssertEqual(rows().count, 3)
        bridge.noteJournal(tabID: askTab, snapshot: ask)
        service.remove(workspaceId: workspace, surfaceId: flagOnly)
        XCTAssertEqual(rows().count, 2)
        XCTAssertFalse(rows().contains { $0["tab_id"] as? String == flagOnly.uuidString })
        service.prune(workspaceId: workspace, validSurfaceIds: [survivor])
        XCTAssertEqual(rows().map { $0["tab_id"] as? String }, [survivor.uuidString])
        // Workspace closure prunes all remaining targets, including flag-only rows.
        service.prune(workspaceId: workspace, validSurfaceIds: [])
        XCTAssertTrue(rows().isEmpty)
    }

    func testCapturedBypassAndAnsweredAsksThroughFeedRowsAndEvents() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lifecycle/normalized")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-corpus-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("events.ndjson")
        let log = EventLog(url: logURL, instance: "synthetic-feed-corpus")
        EventEmitter.shared.startForTesting(log: log, instance: "synthetic-feed-corpus")
        defer {
            EventEmitter.shared.resetForTesting()
            try? FileManager.default.removeItem(at: directory)
        }
        for name in ["claude-bypass-ask", "claude-bypass-ask-answered"] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name + ".json"))) as? [String: Any])
            let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            var state: JournalSnapshot?
            var tracker = FeedAskTracker()
            let bridge = FeedProjectionBridge()
            var transitions: [FeedAskEvent] = []
            var sawResolution = false
            for (index, event) in events.enumerated() where event["source"] as? String == "claude-hook" {
                let native = event["name"] as? String ?? ""
                let tool = event["tool_name"] as? String
                let kind: JournalKind
                switch native {
                case "SessionStart": kind = .sessionStarted
                case "UserPromptSubmit": kind = .turnStarted
                case "Stop": kind = .turnCompleted
                case "PreToolUse", "PermissionRequest":
                    kind = tool == "AskUserQuestion" ? .questionRequested : (tool == "ExitPlanMode" ? .planReviewRequested : .stateChanged)
                case "PostToolUse": kind = tool == "AskUserQuestion" || tool == "ExitPlanMode" ? .attentionResolved : .stateChanged
                default: continue
                }
                var draft = JournalTestData.draft(kind)
                let attrs = event["attrs"] as? [String: Any] ?? [:]
                draft.nativeEvent = native
                draft.turnID = attrs["prompt_id"] as? String
                draft.requestID = attrs["tool_use_id"] as? String
                draft.timeQuality = .observed
                draft.occurredAtMs = (event["t_ms"] as? NSNumber)?.int64Value ?? 0
                if kind == .attentionResolved { draft.resolution = .resumed }
                if kind == .stateChanged { draft.signal = .toolActivity }
                state = JournalTestData.fold(state, draft, seq: Int64(index + 1)).snapshot
                bridge.noteJournal(tabID: JournalTestData.tab, snapshot: state)
                let bridgeRows = bridge.list(scope: .attention)["rows"] as? [[String: Any]] ?? []
                XCTAssertEqual(bridgeRows.count, state.flatMap(FeedProjector.blockingKind) == nil ? 0 : 1, name)
                transitions += tracker.consume(tabID: JournalTestData.tab, snapshot: state)
                if let snapshot = state, FeedProjector.blockingKind(snapshot) != nil {
                    XCTAssertEqual(project([snapshot], scope: .attention).first?.kind, .question, name)
                    var unrelated = JournalTestData.draft(.stateChanged)
                    unrelated.signal = .toolActivity
                    let unchanged = JournalTestData.fold(snapshot, unrelated, seq: snapshot.lastSequence + 1).snapshot
                    XCTAssertEqual(project([unchanged!], scope: .attention).first?.state, "open")
                    XCTAssertTrue(tracker.consume(tabID: JournalTestData.tab, snapshot: unchanged).isEmpty)
                    var sibling = JournalTestData.draft(.turnStarted)
                    sibling.tabID = otherTab
                    let siblingState = JournalTestData.fold(nil, sibling, seq: 1).snapshot
                    XCTAssertTrue(tracker.consume(tabID: otherTab, snapshot: siblingState).isEmpty)
                }
                if kind == .attentionResolved {
                    sawResolution = true
                    XCTAssertTrue(project([state!], scope: .attention).isEmpty, name)
                }
            }
            XCTAssertTrue(transitions.contains { $0.action == .opened }, name)
            if name.hasSuffix("answered") {
                XCTAssertTrue(sawResolution)
                XCTAssertTrue(transitions.contains { $0.action == .closed && $0.resolution == "resumed" })
                XCTAssertTrue(project([state!], scope: .attention).isEmpty)
            } else {
                XCTAssertEqual(project([state!], scope: .attention).first?.state, "open")
            }
        }
        log.flush()
        let recorded = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertTrue(recorded.contains { $0["type"] as? String == "ask.opened" })
        XCTAssertTrue(recorded.contains { $0["type"] as? String == "ask.closed" && ($0["payload"] as? [String: Any])?["resolution"] as? String == "resumed" })
    }

    // claude-bypass-ask: question, plan, and permission are typed rows; other blocked reasons are not.
    func testTypedAsksUseJournalFactsAndLeaveUnknownOptionsNull() throws {
        let question = try blocked(.questionRequested, request: "ask-1")
        let plan = try blocked(.planReviewRequested, request: "plan-1", tab: otherTab)
        let permission = try blocked(.approvalRequested, request: "perm-1", tab: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!)
        for (snapshot, kind) in [(question, FeedKind.question), (plan, .plan), (permission, .permission)] {
            let row = try XCTUnwrap(project([snapshot], scope: .attention).first { $0.tabID == snapshot.owner.tabID })
            XCTAssertEqual(row.kind, kind)
            XCTAssertEqual(row.workspaceID, snapshot.workspaceID)
            XCTAssertEqual(row.source, "hook")
            XCTAssertEqual(row.sourceRank, 60)
            XCTAssertEqual(row.openedAtMs, snapshot.sinceMs)
            XCTAssertEqual(row.openedAtMs, 10_001)
            XCTAssertEqual(row.state, "open")
            XCTAssertEqual(row.confirmation, "confirmed")
            XCTAssertEqual(row.blocking, true)
            XCTAssertNil(row.options)
            XCTAssertFalse(row.promptAvailable)
        }
        var unknown = question
        for reason in [JournalReason.observation, .toolFailure, nil] {
            unknown.reason = reason
            XCTAssertNil(FeedProjector.blockingKind(unknown))
            XCTAssertTrue(project([unknown], scope: .all).isEmpty)
        }
        var undated = question
        undated.sinceMs = 0
        XCTAssertNil(project([undated], scope: .attention).first?.openedAtMs)
    }

    func testTurnEndIsScopeAllOnlyAndSortsByWorkspaceThenTab() throws {
        var start = JournalTestData.draft(.turnStarted)
        start.turnID = "turn-1"
        let working = try XCTUnwrap(JournalTestData.fold(nil, start, seq: 1).snapshot)
        var stop = JournalTestData.draft(.turnCompleted)
        stop.turnID = "turn-1"
        let ended = try XCTUnwrap(JournalTestData.fold(working, stop, seq: 2).snapshot)
        XCTAssertTrue(FeedProjector.isTurnEnd(ended))
        XCTAssertTrue(project([ended], scope: .attention).isEmpty)
        let row = try XCTUnwrap(project([ended], scope: .all).first)
        XCTAssertEqual(row.kind, .turnEnd)
        XCTAssertNil(row.state)
        XCTAssertEqual(row.blocking, false)
        XCTAssertEqual(row.openedAtMs, ended.sinceMs)

        let early = try blocked(.questionRequested, request: "early")
        let late = try blocked(.questionRequested, request: "late", tab: otherTab, workspace: laterWorkspace)
        let sorted = project([late, early], scope: .attention)
        XCTAssertEqual(sorted.map(\.workspaceID), [JournalTestData.workspace, laterWorkspace])
    }

    // Prompt joins the live row and is absent from the journal database opened in the same test.
    func testPromptAppearsOnlyOnTheJoinedNote() throws {
        let question = try blocked(.questionRequested, request: "ask-1")
        let note = FeedDisplayNote(eventID: UUID(), requestID: "ask-1", prompt: sentinel, options: ["one"])
        let row = try XCTUnwrap(project([question], notes: [question.owner.tabID: ["ask-1": note]], scope: .attention).first)
        XCTAssertEqual(row.prompt, sentinel)
        XCTAssertEqual(row.options, ["one"])
        XCTAssertTrue(row.promptAvailable)
        let encoded = try jsonData(row.jsonObject())
        XCTAssertTrue(encoded.range(of: Data(sentinel.utf8)) != nil)

        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("feed-264-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JournalStore(layout: JournalStorageLayout(directory: directory), clock: { 1_000 })
        var draft = JournalTestData.draft(.questionRequested)
        draft.requestID = "ask-1"
        _ = try store.append(draft: draft, context: JournalContext(eligible: true))
        let needle = Data(sentinel.utf8)
        for name in ["lifecycle.sqlite3", "lifecycle.sqlite3-wal", "lifecycle.sqlite3-shm"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            XCTAssertNil(try Data(contentsOf: url).range(of: needle), name)
        }
    }

    func testDisplayNoteRequiresCurrentAppendIdentity() throws {
        let question = try blocked(.questionRequested, request: "ask-1")
        let owner = question.owner
        let workspaceID = try XCTUnwrap(question.workspaceID)
        let requestID = try XCTUnwrap(question.requestID)
        let bridge = FeedProjectionBridge()
        let currentEvent = UUID()
        bridge.noteJournal(tabID: owner.tabID, snapshot: question, eventID: currentEvent)

        let wrong = bridge.acceptNote(
            tabID: owner.tabID, workspaceID: workspaceID,
            agentKind: owner.agentKind, sessionID: owner.sessionID,
            eventID: UUID(), requestID: requestID, prompt: sentinel, options: nil
        )
        XCTAssertEqual(wrong, FeedNoteError.unmatched.rawValue)

        XCTAssertNil(bridge.acceptNote(
            tabID: owner.tabID, workspaceID: workspaceID,
            agentKind: owner.agentKind, sessionID: owner.sessionID,
            eventID: currentEvent, requestID: requestID, prompt: sentinel, options: nil
        ))
        let rows = bridge.list(scope: .attention)["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["prompt"] as? String, sentinel)

        bridge.noteJournal(tabID: owner.tabID, snapshot: JournalReplayPolicy.restored(question))
        let replayed = bridge.acceptNote(
            tabID: owner.tabID, workspaceID: workspaceID,
            agentKind: owner.agentKind, sessionID: owner.sessionID,
            eventID: currentEvent, requestID: requestID, prompt: "stale", options: nil
        )
        XCTAssertEqual(replayed, FeedNoteError.unmatched.rawValue)
    }

    // Flag plus question is one row. A sibling working fold and same-tab tool activity leave it open.
    func testFlagAndSiblingActivityKeepTheOpenQuestion() throws {
        let question = try blocked(.questionRequested, request: "ask-1")
        let row = try XCTUnwrap(project([question], attention: [flag()], scope: .attention).first)
        XCTAssertEqual(row.kind, .question)
        XCTAssertEqual(row.state, "open")
        XCTAssertEqual(row.flag?.reason, "synthetic-flag")
        XCTAssertEqual(row.flag?.raisedAtMs, 50)
        XCTAssertEqual(row.flag?.callerTabID, otherTab)

        var sibling = JournalTestData.draft(.turnStarted)
        sibling.tabID = otherTab
        sibling.workspaceID = laterWorkspace
        let working = try XCTUnwrap(JournalTestData.fold(nil, sibling, seq: 1).snapshot)
        var tool = JournalTestData.draft(.stateChanged)
        tool.signal = .toolActivity
        let afterTool = JournalTestData.fold(question, tool, seq: 2)
        XCTAssertEqual(afterTool.snapshot?.phase, .blocked)
        XCTAssertEqual(afterTool.snapshot?.requestID, "ask-1")
        let rows = project([afterTool.snapshot!, working], attention: [flag()], scope: .attention)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].state, "open")
        XCTAssertEqual(rows[0].tabID, question.owner.tabID)
    }

    func testTrackerEmitsOneOpenThenReplacementAndResolution() throws {
        let question = try blocked(.questionRequested, request: "ask-a")
        var tracker = FeedAskTracker()
        let opened = tracker.consume(tabID: question.owner.tabID, snapshot: question)
        XCTAssertEqual(opened.map(\.action), [.opened])
        XCTAssertEqual(opened[0].kind, "question")
        XCTAssertEqual(opened[0].state, "open")
        XCTAssertNil(opened[0].resolution)
        XCTAssertEqual(tracker.consume(tabID: question.owner.tabID, snapshot: question), [])

        var again = JournalTestData.draft(.questionRequested)
        again.requestID = "ask-a"
        let duplicate = JournalTestData.fold(question, again, seq: 2)
        XCTAssertEqual(duplicate.effect, .duplicateEvidence)
        XCTAssertEqual(tracker.consume(tabID: question.owner.tabID, snapshot: duplicate.snapshot), [])

        var replacement = JournalTestData.draft(.questionRequested)
        replacement.requestID = "ask-b"
        let replaced = try XCTUnwrap(JournalTestData.fold(question, replacement, seq: 3).snapshot)
        let swapped = tracker.consume(tabID: question.owner.tabID, snapshot: replaced)
        XCTAssertEqual(swapped.map(\.action), [.closed, .opened])
        XCTAssertEqual(swapped[0].requestID, "ask-a")
        XCTAssertNil(swapped[0].resolution)
        XCTAssertEqual(swapped[1].requestID, "ask-b")
        let swappedBytes = try jsonData(swapped[0].jsonObject()) + jsonData(swapped[1].jsonObject())
        XCTAssertNil(swappedBytes.range(of: Data(sentinel.utf8)))
        XCTAssertNil(swappedBytes.range(of: Data("options".utf8)))

        func resolve(_ resolution: JournalResolution, seq: Int64) throws -> JournalSnapshot {
            var draft = JournalTestData.draft(.attentionResolved)
            draft.requestID = "ask-b"
            draft.resolution = resolution
            return try XCTUnwrap(JournalTestData.fold(replaced, draft, seq: seq).snapshot)
        }
        let resumed = try resolve(.resumed, seq: 4)
        XCTAssertEqual(FeedProjector.resolution(after: resumed), "resumed")
        let resumedEvents = tracker.consume(tabID: question.owner.tabID, snapshot: resumed)
        XCTAssertEqual(resumedEvents.map(\.resolution), ["resumed"])

        let reopened = try blocked(.planReviewRequested, request: "plan-1", seq: 5)
        _ = tracker.consume(tabID: reopened.owner.tabID, snapshot: reopened)
        var cancel = JournalTestData.draft(.attentionResolved)
        cancel.requestID = "plan-1"
        cancel.resolution = .cancelled
        let cancelled = try XCTUnwrap(JournalTestData.fold(reopened, cancel, seq: 6).snapshot)
        XCTAssertEqual(tracker.consume(tabID: reopened.owner.tabID, snapshot: cancelled).first?.resolution, "cancelled")

        let third = try blocked(.approvalRequested, request: "perm-1", seq: 7)
        _ = tracker.consume(tabID: third.owner.tabID, snapshot: third)
        var unknown = JournalTestData.draft(.attentionResolved)
        unknown.requestID = "perm-1"
        unknown.resolution = .unknown
        let foldedUnknown = try XCTUnwrap(JournalTestData.fold(third, unknown, seq: 8).snapshot)
        XCTAssertEqual(FeedProjector.resolution(after: foldedUnknown), "unknown")
        XCTAssertEqual(tracker.consume(tabID: third.owner.tabID, snapshot: foldedUnknown).first?.resolution, "unknown")
    }

    func testReplaySuppressionAndStaleSnapshotsDoNotEmitFalseCloses() throws {
        let question = try blocked(.questionRequested, request: "ask-1")
        var tracker = FeedAskTracker()
        let restored = JournalReplayPolicy.restored(question)
        XCTAssertEqual(restored.confirmation, .unconfirmed)
        XCTAssertEqual(tracker.consume(tabID: question.owner.tabID, snapshot: restored), [])
        XCTAssertEqual(tracker.consume(tabID: question.owner.tabID, snapshot: question), [])

        var fresh = FeedAskTracker()
        _ = fresh.consume(tabID: question.owner.tabID, snapshot: question)
        var stale = question
        stale.lastSequence = 0
        XCTAssertEqual(fresh.consume(tabID: question.owner.tabID, snapshot: stale), [])
        let gone = fresh.consume(tabID: question.owner.tabID, snapshot: nil)
        XCTAssertEqual(gone.map(\.action), [.closed])
        XCTAssertNil(gone[0].resolution)

        let suppressed = project([question], attention: [FeedAttentionFact(
            workspaceID: JournalTestData.workspace, tabID: question.owner.tabID,
            flagReason: nil, flagRaisedAtMs: nil, flagCallerTabID: nil, suppressed: true
        )], scope: .attention)
        XCTAssertTrue(suppressed.isEmpty)
        XCTAssertEqual(fresh.consume(tabID: question.owner.tabID, snapshot: nil).count, 0)
    }

    func testClaudeApprovalStopClosesWithoutCancelledResolution() throws {
        var approval = JournalTestData.draft(.approvalRequested)
        approval.requestID = "perm-1"
        approval.turnID = "approval-turn"
        let blockedApproval = try XCTUnwrap(JournalTestData.fold(nil, approval, seq: 1).snapshot)
        var stop = JournalTestData.draft(.turnCompleted)
        stop.turnID = "approval-turn"
        let completed = try XCTUnwrap(JournalTestData.fold(blockedApproval, stop, seq: 2).snapshot)
        XCTAssertEqual(completed.phase, .idle)
        XCTAssertEqual(completed.turnOutcome, "completed")
        XCTAssertNil(FeedProjector.resolution(after: completed))
        var tracker = FeedAskTracker()
        _ = tracker.consume(tabID: blockedApproval.owner.tabID, snapshot: blockedApproval)
        let closed = tracker.consume(tabID: blockedApproval.owner.tabID, snapshot: completed)
        XCTAssertEqual(closed.map(\.action), [.closed])
        XCTAssertNil(closed[0].resolution)
        let bytes = try jsonData(closed[0].jsonObject())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertTrue(object["resolution"] is NSNull)
    }

    func testSuppressionAndConfirmationFilterRowsWithoutASecondProjector() throws {
        let question = try blocked(.questionRequested, request: "ask-1")
        let suppressedOnly = FeedAttentionFact(workspaceID: JournalTestData.workspace, tabID: question.owner.tabID, flagReason: nil, flagRaisedAtMs: nil, flagCallerTabID: nil, suppressed: true)
        XCTAssertTrue(project([question], attention: [suppressedOnly], scope: .attention).isEmpty)
        XCTAssertTrue(project([question], attention: [suppressedOnly], scope: .all).isEmpty)
        let kept = try XCTUnwrap(project([question], attention: [flag(suppressed: true)], scope: .attention).first)
        XCTAssertEqual(kept.kind, .question)
        XCTAssertNotNil(kept.flag)

        var start = JournalTestData.draft(.turnStarted)
        start.turnID = "turn-1"
        let working = try XCTUnwrap(JournalTestData.fold(nil, start, seq: 1).snapshot)
        var stop = JournalTestData.draft(.turnCompleted)
        stop.turnID = "turn-1"
        let ended = try XCTUnwrap(JournalTestData.fold(working, stop, seq: 2).snapshot)
        let attentionFlag = try XCTUnwrap(project([ended], attention: [flag()], scope: .attention).first)
        XCTAssertNil(attentionFlag.kind)
        XCTAssertNil(attentionFlag.state)
        XCTAssertNil(attentionFlag.openedAtMs)
        XCTAssertNil(attentionFlag.source)
        XCTAssertNil(attentionFlag.confirmation)
        XCTAssertNil(attentionFlag.blocking)
        XCTAssertEqual(attentionFlag.flag?.reason, "synthetic-flag")
        let all = try XCTUnwrap(project([ended], attention: [flag()], scope: .all).first)
        XCTAssertEqual(all.kind, .turnEnd)
        XCTAssertNotNil(all.flag)
        let suppressedEnd = try XCTUnwrap(project([ended], attention: [flag(suppressed: true)], scope: .all).first)
        XCTAssertNil(suppressedEnd.kind)
        XCTAssertNotNil(suppressedEnd.flag)
        XCTAssertNil(project([ended], attention: [flag(suppressed: true)], scope: .attention).first?.kind)

        let restored = JournalReplayPolicy.restored(question)
        let replay = try XCTUnwrap(project([restored], scope: .attention).first)
        XCTAssertEqual(replay.confirmation, "unconfirmed")
        XCTAssertFalse(replay.promptAvailable)

        let emptyNote = FeedDisplayNote(eventID: UUID(), requestID: "ask-1", prompt: nil, options: [])
        let joined = try XCTUnwrap(project([question], notes: [question.owner.tabID: ["ask-1": emptyNote]], scope: .attention).first)
        XCTAssertTrue(joined.promptAvailable)
        XCTAssertNil(joined.prompt)
        XCTAssertEqual(joined.options, [])
        let wrong = FeedDisplayNote(eventID: UUID(), requestID: "other", prompt: sentinel, options: ["x"])
        let missed = try XCTUnwrap(project([question], notes: [question.owner.tabID: ["other": wrong]], scope: .attention).first)
        XCTAssertFalse(missed.promptAvailable)
        XCTAssertNil(missed.prompt)

        let encoded = try jsonData(attentionFlag.jsonObject())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["kind", "state", "opened_at_ms", "source", "confirmation", "blocking"] {
            XCTAssertTrue(object[key] is NSNull, key)
        }
        XCTAssertNotNil(object["flag"] as? [String: Any])
    }

    // C11-337: rows and flags carry the panel spelling beside the legacy tab spelling.
    func testRowsEmitPanelIdBesideTabIdAndCallerPanelIdBesideCallerTabId() throws {
        let question = try blocked(.questionRequested, request: "ask-1")
        let row = try XCTUnwrap(project([question], attention: [flag()], scope: .attention).first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData(row.jsonObject())) as? [String: Any])
        XCTAssertEqual(object["panel_id"] as? String, JournalTestData.tab.uuidString)
        XCTAssertEqual(object["tab_id"] as? String, JournalTestData.tab.uuidString)
        XCTAssertNil(object["surface_id"])
        let flagObject = try XCTUnwrap(object["flag"] as? [String: Any])
        XCTAssertEqual(flagObject["caller_panel_id"] as? String, otherTab.uuidString)
        XCTAssertEqual(flagObject["caller_tab_id"] as? String, otherTab.uuidString)
        XCTAssertNil(flagObject["caller_surface_id"])

        let noCaller = FeedAttentionFact(workspaceID: JournalTestData.workspace, tabID: question.owner.tabID, flagReason: "synthetic-flag", flagRaisedAtMs: 50, flagCallerTabID: nil, suppressed: false)
        let bare = try XCTUnwrap(project([question], attention: [noCaller], scope: .attention).first)
        let bareFlag = try XCTUnwrap(bare.jsonObject()["flag"] as? [String: Any])
        XCTAssertTrue(bareFlag["caller_panel_id"] is NSNull)
        XCTAssertTrue(bareFlag["caller_tab_id"] is NSNull)
    }

    func testFeedPanelParamPrefersPanelIdThenTabIdThenSurfaceId() {
        let panel = "00000000-0000-0000-0000-0000000000c1"
        let tab = "00000000-0000-0000-0000-0000000000c2"
        let surface = "00000000-0000-0000-0000-0000000000c3"
        XCTAssertEqual(FeedPanelParam.rawValue(in: ["panel_id": panel, "tab_id": tab, "surface_id": surface]), panel)
        XCTAssertEqual(FeedPanelParam.rawValue(in: ["tab_id": tab, "surface_id": surface]), tab)
        XCTAssertEqual(FeedPanelParam.rawValue(in: ["surface_id": surface]), surface)
        XCTAssertNil(FeedPanelParam.rawValue(in: ["workspace_id": panel]))
        XCTAssertEqual(FeedPanelParam.key(in: ["panel_id": panel]), "panel_id")
        XCTAssertEqual(FeedPanelParam.key(in: ["tab_id": tab]), "tab_id")
        XCTAssertEqual(FeedPanelParam.key(in: [:]), "panel_id")
    }

    func testDisplayCacheHonorsCountBytesAndOversize() throws {
        let cache = AskDisplayCache()
        let tab = JournalTestData.tab
        func maxNote(request: String, event: UUID = UUID()) -> FeedDisplayNote {
            FeedDisplayNote(eventID: event, requestID: request, prompt: String(repeating: "p", count: 1024),
                            options: Array(repeating: String(repeating: "l", count: 128), count: 12))
        }
        for index in 0..<204 {
            try cache.store(tabID: tab, note: maxNote(request: "r\(index)"))
        }
        XCTAssertEqual(cache.count, 204)
        XCTAssertEqual(cache.accountedBytes, 204 * 2560)
        XCTAssertThrowsError(try cache.store(tabID: tab, note: maxNote(request: "overflow"))) { XCTAssertEqual($0 as? FeedNoteError, .overflow) }
        XCTAssertEqual(cache.count, 204)

        let zero = UUID()
        try cache.store(tabID: tab, note: FeedDisplayNote(eventID: zero, requestID: "slack", prompt: nil, options: []))
        XCTAssertEqual(cache.count, 205)
        XCTAssertEqual(cache.accountedBytes, 204 * 2560)
        XCTAssertThrowsError(try cache.store(tabID: tab, note: maxNote(request: "slack"))) { XCTAssertEqual($0 as? FeedNoteError, .overflow) }
        XCTAssertEqual(cache.note(tabID: tab, requestID: "slack")?.eventID, zero)

        let repeated = UUID()
        try cache.store(tabID: tab, note: FeedDisplayNote(eventID: repeated, requestID: "repeat", prompt: "0123456789", options: nil))
        let before = cache.accountedBytes
        try cache.store(tabID: tab, note: FeedDisplayNote(eventID: repeated, requestID: "repeat", prompt: "abcd", options: nil))
        XCTAssertEqual(cache.accountedBytes, before - 6)
        XCTAssertEqual(cache.note(tabID: tab, requestID: "repeat")?.prompt, "abcd")

        let fresh = AskDisplayCache()
        XCTAssertThrowsError(try fresh.store(tabID: tab, note: FeedDisplayNote(eventID: UUID(), requestID: "big", prompt: String(repeating: "p", count: 1025), options: nil))) {
            XCTAssertEqual($0 as? FeedNoteError, .oversize)
        }
        XCTAssertThrowsError(try fresh.store(tabID: tab, note: FeedDisplayNote(eventID: UUID(), requestID: "many", prompt: nil, options: Array(repeating: "a", count: 13)))) {
            XCTAssertEqual($0 as? FeedNoteError, .oversize)
        }
        XCTAssertThrowsError(try fresh.store(tabID: tab, note: FeedDisplayNote(eventID: UUID(), requestID: "long", prompt: nil, options: [String(repeating: "x", count: 129)]))) {
            XCTAssertEqual($0 as? FeedNoteError, .oversize)
        }
        XCTAssertEqual(fresh.count, 0)

        let counted = AskDisplayCache()
        for index in 0..<256 {
            try counted.store(tabID: tab, note: FeedDisplayNote(eventID: UUID(), requestID: "z\(index)", prompt: nil, options: []))
        }
        XCTAssertThrowsError(try counted.store(tabID: tab, note: FeedDisplayNote(eventID: UUID(), requestID: "z256", prompt: nil, options: []))) {
            XCTAssertEqual($0 as? FeedNoteError, .overflow)
        }
        XCTAssertEqual(counted.count, 256)
        XCTAssertEqual(counted.accountedBytes, 0)
    }

    func testExtractorBoundsPromptAndLabels() {
        let prompt = String(repeating: "é", count: 600)
        let labels = (0..<20).map { _ in String(repeating: "x", count: 200) }
        let object: [String: Any] = ["tool_input": ["questions": [[
            "question": prompt,
            "options": labels.map { ["label": $0] },
        ]]]]
        let bounded = FeedDisplayExtract.claude(toolName: "AskUserQuestion", object: object)
        XCTAssertLessThanOrEqual(bounded.prompt?.utf8.count ?? 0, 1024)
        XCTAssertEqual(bounded.options?.count, 12)
        XCTAssertTrue(bounded.options?.allSatisfy { $0.utf8.count <= 128 } == true)
        XCTAssertEqual(FeedNoteLimits.prefix("é", maxBytes: 1), "")

        let malformed: [String: Any] = ["tool_input": ["questions": [[
            "question": "prompt",
            "options": [["label": "known"], ["value": "missing-label"]],
        ]]]]
        let unknownOptions = FeedDisplayExtract.claude(toolName: "AskUserQuestion", object: malformed)
        XCTAssertNil(unknownOptions.options)

        let missing = FeedDisplayExtract.claude(toolName: "AskUserQuestion", object: ["tool_input": ["questions": [["question": "Which?"]]]])
        XCTAssertEqual(missing.prompt, "Which?")
        XCTAssertNil(missing.options)
        let empty = FeedDisplayExtract.claude(toolName: "AskUserQuestion", object: ["tool_input": ["questions": [["header": "Pick", "options": [String]()]]]])
        XCTAssertEqual(empty.prompt, "Pick")
        XCTAssertEqual(empty.options, [])
        let plan = FeedDisplayExtract.claude(toolName: "ExitPlanMode", object: ["tool_input": ["plan": "ship the feed"]])
        XCTAssertEqual(plan.prompt, "ship the feed")
        XCTAssertNil(plan.options)
        let blank = FeedDisplayExtract.claude(toolName: "AskUserQuestion", object: ["tool_input": ["questions": [["question": "", "header": ""]]]])
        XCTAssertNil(blank.prompt)
        XCTAssertNil(blank.options)
        XCTAssertNotEqual(blank.prompt, "Asking a question")
    }

    func testWatchParserHoldsPartialLinesAndMarksGapsBeforeFiltering() {
        var parser = FeedWatchParser()
        XCTAssertEqual(parser.consume("{\"seq\":1,\"type\":\"log.opened\"}\n"), [.followedEvent("log.opened")])
        XCTAssertEqual(parser.consume("{\"seq\":2,\"type\":\"surface.created\"}\n"), [])
        XCTAssertEqual(parser.lastSeq, 2)
        XCTAssertEqual(parser.consume("{\"seq\":4,\"type\":\"surface.created\"}\n"), [.continuityUnavailable])
        var dropped = FeedWatchParser()
        _ = dropped.consume("{\"seq\":1,\"type\":\"ask.opened\"}\n")
        XCTAssertEqual(dropped.consume("{\"seq\":2,\"type\":\"log.dropped\"}\n"), [.continuityUnavailable])
        var restarted = FeedWatchParser()
        _ = restarted.consume("{\"seq\":1,\"type\":\"ask.opened\"}\n")
        XCTAssertEqual(restarted.consume("{\"seq\":2,\"type\":\"log.opened\"}\n"), [.continuityUnavailable])
        XCTAssertEqual(restarted.consume("{\"seq\":1,\"type\":\"ask.closed\"}\n"), [.continuityUnavailable])
        var partial = FeedWatchParser()
        XCTAssertEqual(partial.consume("{\"seq\":1,\"type\":\"ask.opened\""), [])
        XCTAssertEqual(partial.consume("}\n{\"seq\":2,\"type\":\"flag.raised\"}\n"), [.followedEvent("ask.opened"), .followedEvent("flag.raised")])
    }
}
