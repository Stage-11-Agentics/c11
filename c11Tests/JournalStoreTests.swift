import XCTest
import SQLite3

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class JournalStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        // Resolve /var's system symlink before exercising the private-directory policy.
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("journal-test-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private var layout: JournalStorageLayout { JournalStorageLayout(directory: directory) }

    func testClearRemovesHistoryAndCurrentStateWithoutReusingSequenceNumbers() throws {
        let store = try JournalStore(layout: layout, clock: { 1000 })
        let draft = JournalTestData.draft(.questionRequested)
        let receipt = try store.append(draft: draft, context: JournalContext(eligible: true)).receipt
        XCTAssertTrue(JournalSpool(layout: layout).write(JournalTestData.draft(.turnStarted)))
        XCTAssertEqual(try store.readPage(after: 0).count, 1)
        XCTAssertNotNil(try store.current(owner: draft.owner!))

        try store.clear()

        XCTAssertTrue(try store.readPage(after: 0).isEmpty)
        XCTAssertNil(try store.current(owner: draft.owner!))
        let spoolNames = try FileManager.default.contentsOfDirectory(atPath: layout.spool.path)
        XCTAssertEqual(spoolNames.filter { $0.hasSuffix(".ready") }, [])
        XCTAssertGreaterThan(try store.coverage().first, receipt.sequence)
        var next = JournalTestData.draft(.turnStarted); next.eventID = UUID()
        let nextReceipt = try store.append(draft: next, context: JournalContext(eligible: true)).receipt
        XCTAssertGreaterThan(nextReceipt.sequence, receipt.sequence)
    }

    // Ambiguous committed acknowledgement + crash/reopen dedupe.
    func testReceiptSurvivesReopenAndConflictCannotReplaceIt() throws {
        let draft = JournalTestData.draft(.turnStarted)
        var store: JournalStore? = try JournalStore(layout: layout, clock: { 1000 })
        let receipt = try store!.append(draft: draft, context: JournalContext(eligible: true)).receipt
        store = nil
        store = try JournalStore(layout: layout, clock: { 2000 })
        let replay = try store!.append(draft: draft, context: JournalContext(eligible: true)).receipt
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.sequence, receipt.sequence)
        XCTAssertEqual(replay.committedAtMs, receipt.committedAtMs)
        var conflict = draft; conflict.kind = .turnCompleted
        XCTAssertThrowsError(try store!.append(draft: conflict, context: JournalContext(eligible: true))) { XCTAssertEqual($0 as? JournalError, .conflict) }
        XCTAssertEqual(try store!.readPage(after: 0).count, 1)
    }

    // Restart while waiting + old open ask survives history pruning; Q3 is left censored.
    func testOldAskBaselineSurvivesRetentionAndReplaysUnconfirmed() throws {
        let store = try JournalStore(layout: layout, clock: { 1000 })
        let draft = JournalTestData.draft(.questionRequested)
        _ = try store.append(draft: draft, context: JournalContext(eligible: true))
        try store.prune(now: 16 * 86_400_000)
        XCTAssertTrue(try store.readPage(after: 0).isEmpty)
        let baseline = try XCTUnwrap(store.current(owner: draft.owner!))
        let replay = try XCTUnwrap(JournalReplayPolicy.attention(baseline, matching: draft.owner))
        XCTAssertEqual(replay.phase, .blocked)
        XCTAssertEqual(replay.confirmation, .unconfirmed)
        XCTAssertEqual(replay.connection, .disconnected)
        XCTAssertEqual(replay.sinceMs, 1000)
        XCTAssertGreaterThan(try store.coverage().first, 1)
    }

    // Sibling tool activity cannot clear another owner's ask.
    func testSiblingAndHistoricalDrainCannotReplaceLiveAsk() throws {
        let store = try JournalStore(layout: layout, clock: { 1000 })
        let ask = JournalTestData.draft(.questionRequested)
        _ = try store.append(draft: ask, context: JournalContext(eligible: true))
        var sibling = JournalTestData.draft(.turnStarted); sibling.tabID = UUID()
        _ = try store.append(draft: sibling, context: JournalContext(eligible: true))
        let old = JournalTestData.draft(.turnStarted)
        let result = try store.append(draft: old, context: JournalContext(eligible: true, historical: true))
        XCTAssertEqual(result.receipt.projectionEffect, .stale)
        XCTAssertEqual(try store.current(owner: ask.owner!)?.phase, .blocked)
    }

    // Restart replay: multiple offline records are historical until this run admits live evidence.
    func testRestartDrainsMultipleHistoricalChangesWithoutInheritingLivePriority() throws {
        let start = JournalTestData.draft(.turnStarted)
        var store: JournalStore? = try JournalStore(layout: layout, clock: { 1000 })
        _ = try store!.append(draft: start, context: JournalContext(eligible: true))
        store = nil
        store = try JournalStore(layout: layout, clock: { 2000 })
        var ask = JournalTestData.draft(.questionRequested); ask.requestID = "first-offline-request"
        _ = try store!.append(draft: ask, context: JournalContext(eligible: true, historical: true))
        var plan = JournalTestData.draft(.planReviewRequested); plan.requestID = "second-offline-request"
        let second = try store!.append(draft: plan, context: JournalContext(eligible: true, historical: true))
        XCTAssertEqual(second.receipt.projectionEffect, .applied)
        XCTAssertEqual(second.changedSnapshot?.reason, .planReview)
        XCTAssertEqual(second.changedSnapshot?.confirmation, .unconfirmed)
        XCTAssertEqual(second.changedSnapshot?.lastLiveSequence, 0)
        _ = try store!.append(draft: JournalTestData.draft(.turnStarted), context: JournalContext(eligible: true))
        ask.eventID = UUID()
        XCTAssertEqual(try store!.append(draft: ask, context: JournalContext(eligible: true, historical: true))
            .receipt.projectionEffect, .stale)
    }

    // Protected baseline capacity fails transactionally without an orphan receipt.
    func testStateCapacityRollsBackEventAndKeepsAsk() throws {
        let ask = JournalTestData.draft(.questionRequested)
        var initial: JournalStore? = try JournalStore(layout: layout, clock: { 1000 })
        _ = try initial!.append(draft: ask, context: JournalContext(eligible: true))
        initial = nil
        // Lower the injected budget below protected state, independently of encoding size.
        var budget = JournalBudgets(); budget.currentBytes = 1
        let store = try JournalStore(layout: layout, budgets: budget, clock: { 1000 })
        var other = ask; other.eventID = UUID(); other.tabID = UUID()
        XCTAssertThrowsError(try store.append(draft: other, context: JournalContext(eligible: true))) { XCTAssertEqual($0 as? JournalError, .full) }
        XCTAssertEqual(try store.readPage(after: 0).count, 1)
        XCTAssertEqual(try store.current(owner: ask.owner!)?.phase, .blocked)
        XCTAssertEqual(store.health(), .full)
    }

    // Q1/Q4 effects distinguish recorded late evidence from actual transitions.
    func testStoredEffectsAndDimensionsDescribeObservedTransitions() throws {
        var now: Int64 = 1000
        let store = try JournalStore(layout: layout, clock: { now })
        let start = JournalTestData.draft(.turnStarted)
        _ = try store.append(draft: start, context: JournalContext(eligible: true, modelID: "fixture-model"))
        now = 3000
        _ = try store.append(draft: JournalTestData.draft(.turnCompleted), context: JournalContext(eligible: true))
        var late = JournalTestData.draft(.stateChanged); late.signal = .toolActivity
        _ = try store.append(draft: late, context: JournalContext(eligible: true))
        let page = try store.readPage(after: 0)
        XCTAssertEqual(page.map(\.effect), [.applied, .applied, .advisory])
        XCTAssertEqual(page[1].fromSinceMs, 1000)
        XCTAssertEqual(page[1].committedAtMs, 3000)
        XCTAssertEqual(page[0].modelID, "fixture-model")
        XCTAssertNil(page[2].fromPhase)
        XCTAssertEqual(try store.readPage(after: page[0].sequence, through: page[1].sequence).count, 1)
    }

    // Audit privacy sentinel is rejected before any disk operation.
    func testUnknownPayloadAndArbitraryRanksAreRejected() throws {
        let draft = JournalTestData.draft(.turnStarted)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.canonicalData()) as? [String: Any])
        json["prompt"] = "PRIVATE-SENTINEL"
        XCTAssertThrowsError(try JournalDraft.decode(JSONSerialization.data(withJSONObject: json)))
        json.removeValue(forKey: "prompt"); json["confidence_rank"] = 999
        XCTAssertThrowsError(try JournalDraft.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // The audit's locked-database failure preserves the last committed evidence and a bounded wait.
    func testSQLiteContentionReportsDegradedWithoutChangingBaseline() throws {
        let store = try JournalStore(layout: layout, clock: { 1000 })
        let ask = JournalTestData.draft(.questionRequested)
        _ = try store.append(draft: ask, context: JournalContext(eligible: true))
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(layout.database.path, &other), SQLITE_OK)
        defer { sqlite3_exec(other, "ROLLBACK", nil, nil, nil); sqlite3_close(other) }
        XCTAssertEqual(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let start = Date()
        XCTAssertThrowsError(try store.append(draft: JournalTestData.draft(.turnStarted), context: JournalContext(eligible: true))) {
            XCTAssertEqual($0 as? JournalError, .busy)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(store.health(), .busy)
        XCTAssertEqual(try store.current(owner: ask.owner!)?.phase, .blocked)
        XCTAssertEqual(try store.readPage(after: 0).count, 1)
    }

    // History tuning cannot shorten the receipt floor; a retained old retry is looked up before expiry.
    func testReceiptFloorAndRetainedExpiredRetry() throws {
        var now: Int64 = 1000
        var budget = JournalBudgets(); budget.historyMs = 1
        let store = try JournalStore(layout: layout, budgets: budget, clock: { now })
        let draft = JournalTestData.draft(.questionRequested)
        _ = try store.append(draft: draft, context: JournalContext(eligible: true))
        try store.prune(now: 60_000)
        XCTAssertEqual(try store.readPage(after: 0).count, 1)
        now = 86_400_000 + 2000
        XCTAssertTrue(try store.append(draft: draft, context: JournalContext(eligible: true)).receipt.replayed)
        var newID = draft; newID.eventID = UUID()
        XCTAssertThrowsError(try store.append(draft: newID, context: JournalContext(eligible: true))) {
            XCTAssertEqual($0 as? JournalError, .expired)
        }
    }

    // Relaunch must not advertise yesterday's working state as live activity.
    func testOldWorkingBaselineHasNoReplayAttention() throws {
        let store = try JournalStore(layout: layout, clock: { 1000 })
        let draft = JournalTestData.draft(.turnStarted)
        _ = try store.append(draft: draft, context: JournalContext(eligible: true))
        let baseline = try XCTUnwrap(store.current(owner: draft.owner!))
        XCTAssertNil(JournalReplayPolicy.attention(baseline, matching: draft.owner))
        XCTAssertTrue(JournalReplayPolicy.restored(baseline).isHistorical)
        XCTAssertNil(JournalReplayPolicy.attention(baseline, matching: nil))
    }

    // Audit unavailable-schema case: preserve evidence instead of silently recreating the file.
    func testUnknownSchemaIsPreservedAndPrivateFilesStayPrivate() throws {
        var store: JournalStore? = try JournalStore(layout: layout, clock: { 1000 })
        let draft = JournalTestData.draft(.questionRequested)
        _ = try store!.append(draft: draft, context: JournalContext(eligible: true))
        let attrs = try FileManager.default.attributesOfItem(atPath: layout.database.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        store = nil
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(layout.database.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        XCTAssertThrowsError(try JournalStore(layout: layout)) { XCTAssertEqual($0 as? JournalError, .unsupportedVersion) }
        XCTAssertEqual(sqlite3_open(layout.database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT count(*) FROM journal_events", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testReadOnlyOpenLeavesAMissingFileAbsent() {
        let outsideProduction = directory.path.contains("com.stage11.c11")
        XCTAssertFalse(outsideProduction)
        let missing = JournalStorageLayout(directory: directory.appendingPathComponent("absent"))
        XCTAssertThrowsError(try JournalStore(layout: missing, readOnly: true)) {
            XCTAssertEqual($0 as? JournalError, .unavailable)
        }
        let created = FileManager.default.fileExists(atPath: missing.database.path)
        XCTAssertFalse(created)
    }

    func testReadOnlyTimelineIsNewestFirstAndCountsUnattributedRows() throws {
        let outsideProduction = directory.path.contains("com.stage11.c11")
        XCTAssertFalse(outsideProduction)
        let clock: Int64 = 5_000
        var writer: JournalStore? = try JournalStore(layout: layout, clock: { clock })
        var started = JournalTestData.draft(.sessionStarted, at: clock)
        started.nativeEvent = "SessionStart"
        _ = try writer!.append(draft: started, context: JournalContext(eligible: true))
        var ended = JournalTestData.draft(.sessionEnded, at: clock)
        ended.nativeEvent = "SessionEnd"
        ended.eventID = UUID()
        _ = try writer!.append(draft: ended, context: JournalContext(eligible: true))
        var loose = JournalTestData.draft(.stateChanged, at: clock)
        loose.eventID = UUID()
        loose.tabID = nil
        loose.workspaceID = nil
        loose.sessionID = nil
        loose.signal = .observation
        loose.nativeEvent = "other"
        _ = try writer!.append(draft: loose, context: JournalContext(eligible: false))
        let owner = try XCTUnwrap(started.owner)
        writer = nil
        let reader = try JournalStore(layout: layout, readOnly: true)
        XCTAssertEqual(try reader.listCurrent().count, 1)
        let page = try reader.retainedOwnerEvents(owner: owner)
        XCTAssertEqual(page.events.map(\.draft.kind), [.sessionEnded, .sessionStarted])
        XCTAssertFalse(page.truncated)
        let capped = try reader.retainedOwnerEvents(owner: owner, limit: 1)
        XCTAssertTrue(capped.truncated)
        XCTAssertEqual(capped.events.map(\.draft.kind), [.sessionEnded])
        XCTAssertEqual(try reader.unattributedCount(), 1)
        XCTAssertThrowsError(try reader.append(draft: JournalTestData.draft(.turnStarted, at: clock), context: JournalContext(eligible: true))) {
            XCTAssertEqual($0 as? JournalError, .unavailable)
        }
    }

    func testReopenProjectsOnlyAppliedExactEvidenceBehindEachBaseline() throws {
        var now: Int64 = 1_000
        let context = JournalContext(eligible: true, verifiedNativeClock: true)
        var writer: JournalStore? = try JournalStore(layout: layout, clock: { now })

        var liveStart = JournalTestData.draft(.sessionStarted, at: 900)
        liveStart.sessionID = "live-session"
        liveStart.nativeEvent = "SessionStart"
        let liveOwner = try XCTUnwrap(liveStart.owner)
        XCTAssertEqual(try writer!.append(draft: liveStart, context: context).receipt.projectionEffect, .applied)

        var repeatedStart = liveStart
        repeatedStart.eventID = UUID()
        now = 950
        XCTAssertEqual(try writer!.append(draft: repeatedStart, context: context).receipt.projectionEffect, .observation)

        var turn = JournalTestData.draft(.turnStarted, at: 1_000)
        turn.sessionID = liveOwner.sessionID
        turn.turnID = "turn-live"
        turn.timeQuality = .nativeLocal
        turn.occurredAtMs = 1_000
        now = 1_000
        XCTAssertEqual(try writer!.append(draft: turn, context: context).receipt.projectionEffect, .applied)

        var repeatedTurn = turn
        repeatedTurn.eventID = UUID()
        repeatedTurn.emittedAtMs = 4_000
        repeatedTurn.occurredAtMs = 4_000
        now = 4_000
        XCTAssertEqual(try writer!.append(draft: repeatedTurn, context: context).receipt.projectionEffect, .duplicateEvidence)

        var ask = JournalTestData.draft(.questionRequested, at: 5_000)
        ask.sessionID = liveOwner.sessionID
        ask.turnID = "turn-live"
        ask.requestID = "request-live"
        ask.timeQuality = .nativeLocal
        ask.occurredAtMs = 5_000
        now = 5_000
        XCTAssertEqual(try writer!.append(draft: ask, context: context).receipt.projectionEffect, .applied)

        var repeatedAsk = ask
        repeatedAsk.eventID = UUID()
        repeatedAsk.emittedAtMs = 8_000
        repeatedAsk.occurredAtMs = 8_000
        now = 8_000
        XCTAssertEqual(try writer!.append(draft: repeatedAsk, context: context).receipt.projectionEffect, .duplicateEvidence)

        var advisoryAsk = ask
        advisoryAsk.eventID = UUID()
        advisoryAsk.source = .transcript
        advisoryAsk.adapter = .codexTranscript
        advisoryAsk.requestID = "advisory-request"
        advisoryAsk.emittedAtMs = 9_000
        advisoryAsk.occurredAtMs = 9_000
        now = 9_000
        XCTAssertEqual(try writer!.append(draft: advisoryAsk, context: context).receipt.projectionEffect, .advisory)

        var lost = JournalTestData.draft(.stateChanged, at: 10_000)
        lost.sessionID = liveOwner.sessionID
        lost.source = .c11
        lost.adapter = .c11
        lost.nativeEvent = "connection_lost"
        lost.signal = .connectionLost
        now = 10_000
        XCTAssertEqual(try writer!.append(draft: lost, context: context).receipt.projectionEffect, .applied)

        var endedStart = JournalTestData.draft(.sessionStarted, at: 11_000)
        endedStart.tabID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        endedStart.sessionID = "ended-session"
        endedStart.nativeEvent = "SessionStart"
        let endedOwner = try XCTUnwrap(endedStart.owner)
        now = 11_000
        XCTAssertEqual(try writer!.append(draft: endedStart, context: context).receipt.projectionEffect, .applied)
        var endedTurn = JournalTestData.draft(.turnStarted, at: 12_000)
        endedTurn.tabID = endedOwner.tabID
        endedTurn.sessionID = endedOwner.sessionID
        endedTurn.turnID = "turn-ended"
        endedTurn.timeQuality = .nativeLocal
        endedTurn.occurredAtMs = 12_000
        now = 12_000
        XCTAssertEqual(try writer!.append(draft: endedTurn, context: context).receipt.projectionEffect, .applied)
        var end = JournalTestData.draft(.sessionEnded, at: 13_000)
        end.tabID = endedOwner.tabID
        end.sessionID = endedOwner.sessionID
        end.nativeEvent = "SessionEnd"
        now = 13_000
        XCTAssertEqual(try writer!.append(draft: end, context: context).receipt.projectionEffect, .applied)
        var startAfterEnd = endedStart
        startAfterEnd.eventID = UUID()
        startAfterEnd.emittedAtMs = 14_000
        now = 14_000
        XCTAssertEqual(try writer!.append(draft: startAfterEnd, context: context).receipt.projectionEffect, .observation)

        let originalInstance = writer!.instanceID
        writer = nil
        let reopened = try JournalStore(layout: layout, clock: { 15_000 })
        XCTAssertNotEqual(reopened.instanceID, originalInstance)

        let liveBaseline = try XCTUnwrap(reopened.current(owner: liveOwner))
        let livePage = try reopened.retainedOwnerEvents(owner: liveOwner, throughSequence: liveBaseline.lastSequence)
        let repeatedStartRow = try XCTUnwrap(livePage.events.first { $0.draft.eventID == repeatedStart.eventID })
        let duplicateTurnRow = try XCTUnwrap(livePage.events.first { $0.draft.eventID == repeatedTurn.eventID })
        let duplicateAskRow = try XCTUnwrap(livePage.events.first { $0.draft.eventID == repeatedAsk.eventID })
        let advisoryRow = try XCTUnwrap(livePage.events.first { $0.draft.eventID == advisoryAsk.eventID })
        XCTAssertEqual(repeatedStartRow.event.effect, .observation)
        XCTAssertEqual(repeatedStartRow.event.attribution, "exact")
        XCTAssertEqual(duplicateTurnRow.event.effect, .duplicateEvidence)
        XCTAssertEqual(duplicateAskRow.event.effect, .duplicateEvidence)
        XCTAssertEqual(advisoryRow.event.effect, .advisory)
        XCTAssertEqual(duplicateAskRow.event.attribution, "exact")
        XCTAssertEqual(AgentRoster.turnStartMs(turnID: liveBaseline.turnID, throughSequence: liveBaseline.lastSequence, eventsNewestFirst: livePage.events), 1_000)
        let restoredAsk = try XCTUnwrap(AgentRoster.restoredAsk(snapshot: liveBaseline, eventsNewestFirst: livePage.events))
        XCTAssertEqual(restoredAsk.eventID, ask.eventID)
        XCTAssertEqual(restoredAsk.requestID, ask.requestID)
        XCTAssertEqual(restoredAsk.openedAtMs, 5_000)

        let endedBaseline = try XCTUnwrap(reopened.current(owner: endedOwner))
        let endedPage = try reopened.retainedOwnerEvents(owner: endedOwner, throughSequence: endedBaseline.lastSequence)
        let fullEndedPage = try reopened.retainedOwnerEvents(owner: endedOwner)
        let postEndStart = try XCTUnwrap(fullEndedPage.events.first { $0.draft.eventID == startAfterEnd.eventID })
        XCTAssertEqual(postEndStart.event.effect, .observation)
        XCTAssertEqual(postEndStart.event.attribution, "exact")
        XCTAssertGreaterThan(postEndStart.sequence, endedBaseline.lastSequence)
        XCTAssertEqual(
            AgentRoster.classifyRestore(eventsNewestFirst: endedPage.events, throughSequence: endedBaseline.lastSequence, truncated: false, storePruned: false).label,
            "ended"
        )

        let projected = try reopened.listCurrent().map(JournalReplayPolicy.restored)
        let pages = [liveOwner, endedOwner].reduce(into: [String: [AgentRoster.RetainedEvent]]()) { result, owner in
            let lastSequence = owner == liveOwner ? liveBaseline.lastSequence : endedBaseline.lastSequence
            result[owner.key] = (try? reopened.retainedOwnerEvents(owner: owner, throughSequence: lastSequence).events) ?? []
        }
        let document = AgentRoster.document(
            live: [], currents: projected, eventsByOwner: pages, truncatedOwners: [], unattributed: 0,
            storePruned: false, storageAvailable: true, healthDegraded: false, now: 15_000, liveIdentity: "unavailable")
        let labels: [String: String] = Dictionary(uniqueKeysWithValues: (document["restore_candidates"] as? [[String: Any]] ?? []).compactMap { candidate -> (String, String)? in
            guard let sessionID = candidate["session_id"] as? String, let label = candidate["label"] as? String else { return nil }
            return (sessionID, label)
        })
        XCTAssertEqual(labels[liveOwner.sessionID], "historical_candidate")
        XCTAssertEqual(labels[endedOwner.sessionID], "ended")
    }

    func testCrashLiveBaselineBecomesCandidateOnlyAfterReplayProjection() throws {
        var writer: JournalStore? = try JournalStore(layout: layout, clock: { 1_000 })
        var start = JournalTestData.draft(.sessionStarted, at: 900)
        start.nativeEvent = "SessionStart"
        let owner = try XCTUnwrap(start.owner)
        _ = try writer!.append(draft: start, context: JournalContext(eligible: true))
        var turn = JournalTestData.draft(.turnStarted, at: 1_000)
        turn.turnID = "crash-live-turn"
        turn.timeQuality = .nativeLocal
        turn.occurredAtMs = 1_000
        _ = try writer!.append(draft: turn, context: JournalContext(eligible: true, verifiedNativeClock: true))
        let confirmed = try XCTUnwrap(writer!.current(owner: owner))
        XCTAssertEqual(confirmed.confirmation, .confirmed)
        XCTAssertEqual(confirmed.connection, .live)
        writer = nil // model a process close with no SessionEnd or connection_lost write

        let reopened = try JournalStore(layout: layout, clock: { 2_000 })
        let raw = try XCTUnwrap(reopened.current(owner: owner))
        XCTAssertEqual(raw.confirmation, .confirmed, "the stored row is not rewritten by read-only reopen")
        let restored = JournalReplayPolicy.restored(raw)
        XCTAssertTrue(restored.isHistorical)
        let page = try reopened.retainedOwnerEvents(owner: owner, throughSequence: restored.lastSequence)
        XCTAssertFalse(page.events.contains { $0.draft.signal == .connectionLost })
        let document = AgentRoster.document(
            live: [], currents: [restored], eventsByOwner: [owner.key: page.events], truncatedOwners: [],
            unattributed: 0, storePruned: false, storageAvailable: true, healthDegraded: false,
            now: 2_000, liveIdentity: "unavailable")
        let candidates = document["restore_candidates"] as? [[String: Any]] ?? []
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0]["label"] as? String, "historical_candidate")
        XCTAssertEqual(candidates[0]["connection"] as? String, "unknown")
    }

    // MARK: - C11-337 on-disk pins

    private func jsonColumn(_ connection: OpaquePointer?, _ sql: String) throws -> [String: Any] {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let pointer = try XCTUnwrap(sqlite3_column_blob(statement, 0))
        let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `journal_current.state` keeps the owner keys `tabID` / `agentKind` /
    /// `sessionID`, the stored draft keeps `tab_id`, and a state blob in the
    /// current on-disk format decodes through the real store.
    func testCurrentStateBlobKeepsPinnedKeysAndDecodesTheCurrentFormat() throws {
        var store: JournalStore? = try JournalStore(layout: layout, clock: { 1000 })
        let draft = JournalTestData.draft(.questionRequested)
        _ = try store!.append(draft: draft, context: JournalContext(eligible: true))
        store = nil

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(layout.database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let state = try jsonColumn(connection, "SELECT state FROM journal_current")
        let owner = try XCTUnwrap(state["owner"] as? [String: Any])
        XCTAssertEqual(Set(owner.keys), ["tabID", "agentKind", "sessionID"])
        XCTAssertEqual(owner["tabID"] as? String, JournalTestData.tab.uuidString)
        let storedDraft = try jsonColumn(connection, "SELECT draft FROM journal_events")
        XCTAssertEqual(storedDraft["tab_id"] as? String, JournalTestData.tab.uuidString)
        XCTAssertNil(storedDraft["panel_id"])

        let fixture = """
        {"owner":{"tabID":"00000000-0000-0000-0000-000000000001","agentKind":"claude-code","sessionID":"fixture-session"},\
        "workspaceID":"00000000-0000-0000-0000-000000000002","phase":"blocked","reason":"question",\
        "requestID":"synthetic-ask","turnID":"synthetic-turn","source":"hook","adapter":"claude_hook","rank":3,\
        "sinceMs":900,"observedAtMs":900,"observedTickNs":7,"appInstanceID":"00000000-0000-0000-0000-0000000000e1",\
        "lastSequence":1,"nativeWatermarks":{},"terminalBarrier":false,"terminalRank":0,"confirmation":"confirmed",\
        "connection":"live","health":"ok","timingUncertain":false,"lastLiveSequence":1,"lastLiveEmittedAtMs":900}
        """
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE journal_current SET state=CAST('\(fixture)' AS BLOB)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        connection = nil

        let reopened = try JournalStore(layout: layout, clock: { 1000 })
        let decoded = try XCTUnwrap(try reopened.current(owner: XCTUnwrap(draft.owner)))
        XCTAssertEqual(decoded.owner, JournalOwner(tabID: JournalTestData.tab, agentKind: "claude-code", sessionID: "fixture-session"))
        XCTAssertEqual(decoded.workspaceID, JournalTestData.workspace)
        XCTAssertEqual(decoded.phase, .blocked)
        XCTAssertEqual(decoded.requestID, "synthetic-ask")
        XCTAssertEqual(decoded.appInstanceID, UUID(uuidString: "00000000-0000-0000-0000-0000000000e1"))
        XCTAssertEqual(decoded.lastSequence, 1)
    }

    /// Draft input accepts `panel_id`; the stored and hashed bytes keep `tab_id`.
    func testDraftDecodeAcceptsPanelIdWithoutChangingCanonicalBytes() throws {
        let draft = JournalTestData.draft(.questionRequested)
        let canonical = try draft.canonicalData()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        XCTAssertEqual(object["tab_id"] as? String, JournalTestData.tab.uuidString)
        XCTAssertNil(object["panel_id"])

        XCTAssertEqual(try JournalDraft.decode(canonical), draft)

        object["panel_id"] = object.removeValue(forKey: "tab_id")
        let panelOnly = try JournalDraft.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(panelOnly.tabID, JournalTestData.tab)
        XCTAssertEqual(try panelOnly.canonicalData(), canonical)

        object["tab_id"] = JournalTestData.tab.uuidString
        XCTAssertEqual(try JournalDraft.decode(JSONSerialization.data(withJSONObject: object)), draft)

        // The same UUID in a different case names the same panel.
        object["panel_id"] = JournalTestData.tab.uuidString.lowercased()
        XCTAssertEqual(try JournalDraft.decode(JSONSerialization.data(withJSONObject: object)), draft)

        object["tab_id"] = JournalTestData.workspace.uuidString
        XCTAssertThrowsError(try JournalDraft.decode(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? JournalError, .invalidEvent)
        }
    }
}
