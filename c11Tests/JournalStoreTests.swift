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
}
