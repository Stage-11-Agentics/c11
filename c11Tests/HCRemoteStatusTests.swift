import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCRemoteStatusTests: XCTestCase {
    private let panel = UUID()
    private let workspace = UUID()
    private let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t1")
    private var directory: URL!
    private var store: JournalStore!
    private var journal: JournalCoordinator!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("hc-status-\(UUID().uuidString)")
        store = try JournalStore(layout: JournalStorageLayout(directory: directory))
        journal = coordinator(store)
    }

    override func tearDownWithError() throws {
        journal = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var owner: JournalOwner { HCRemoteStatus.owner(panelID: panel, key: key, agentKind: "claude-code") }

    private func coordinator(_ store: JournalStore) -> JournalCoordinator {
        let value = JournalCoordinator(store: store)
        value.register(panelID: panel, workspaceID: workspace)
        value.setHCStatusOwner(panelID: panel, owner: owner)
        return value
    }

    private func record(_ status: String?, turn: Int64 = 0, at: Int64? = 1_000,
                        availability: HCMachineAvailability = .connected) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: .running, machineName: "studio", machineAvailability: availability, pid: 8122,
                         foreground: HCForeground(pid: 8123, name: "claude", argv: ["claude"]),
                         status: status, statusTimestampMilliseconds: at, turn: turn)
    }

    private func draft(_ record: HCTerminalRecord) throws -> JournalDraft {
        try XCTUnwrap(HCRemoteStatus.draft(record: record, owner: owner, workspaceID: workspace,
                                          observedAtMs: Int64(Date().timeIntervalSince1970 * 1000)))
    }

    @discardableResult
    private func append(_ status: String, turn: Int64 = 0, at: Int64? = 1_000) throws -> JournalAppendResult {
        try journal.appendHCStatus(draft(record(status, turn: turn, at: at)))
    }

    func testWorkingAndBlockedUseTheExistingJournalAndAttentionProjection() throws {
        try append("working")
        XCTAssertEqual(journal.snapshot(panelID: panel)?.phase, .working)
        try append("blocked", turn: 1, at: 2_000)
        let blocked = try XCTUnwrap(journal.snapshot(panelID: panel))
        XCTAssertEqual(blocked.phase, .blocked)
        XCTAssertTrue(blocked.paintsAttention)
        XCTAssertNil(blocked.requestID, "a status word is not a provider permission request")
        XCTAssertEqual(PanelActivityResolver.resolve(hasExactSurfaceNotification: false,
            hasJournalAttention: blocked.paintsAttention, derivedActivity: .idle,
            terminalType: "claude-code"), .waiting)
        try append("working", turn: 1, at: 3_000)
        XCTAssertEqual(journal.snapshot(panelID: panel)?.phase, .working)
        XCTAssertFalse(try XCTUnwrap(journal.snapshot(panelID: panel)).paintsAttention)
    }

    func testCounterChangesBlockedIdleErrorAndClearNeverInventCompletedTurns() throws {
        try append("working")
        for (offset, status) in ["blocked", "idle", "error", "working"].enumerated() {
            try append(status, turn: Int64(offset + 10), at: Int64(offset + 2) * 1_000)
            XCTAssertFalse(FeedProjector.isTurnEnd(try XCTUnwrap(journal.snapshot(panelID: panel))))
        }
        XCTAssertNil(HCRemoteStatus.draft(record: record(nil, turn: 50), owner: owner,
                                         workspaceID: workspace, observedAtMs: 10_000))
    }

    func testAwayTimeDoneUsesRetainedTimestampAndDoesNotReplayACompletedTurn() throws {
        try append("working")
        // A fresh coordinator/store stands for relaunch. The only away-time
        // evidence is hc's retained done status, not invented intermediate turns.
        let reopenedStore = try JournalStore(layout: JournalStorageLayout(directory: directory))
        let reopened = coordinator(reopenedStore)
        let done = try draft(record("done", turn: 9, at: 2_500))
        let receipt = try reopened.appendHCStatus(done)
        XCTAssertEqual(receipt.receipt.projectionEffect, .applied)
        let state = try XCTUnwrap(reopened.snapshot(panelID: panel))
        let rows = FeedProjector.project(journalRows: [state], attention: [], notes: [:], scope: .all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, .turnEnd)
        XCTAssertEqual(rows.first?.openedAtMs, 2_500)
        var repeated = done
        repeated.eventID = UUID()
        XCTAssertEqual(try reopened.appendHCStatus(repeated).receipt.projectionEffect, .duplicateEvidence)
        XCTAssertEqual(reopened.snapshot(panelID: panel)?.sinceMs, 2_500)
        XCTAssertEqual(try reopenedStore.readPage(after: 0).filter { $0.effect == .applied }.count, 2,
                       "one observed working state and one retained completion, not nine turns")
    }

    func testDoneWithoutAnEndTimeDoesNotPretendItEndedAtReconnect() throws {
        try append("done", turn: 1, at: nil)
        let state = try XCTUnwrap(journal.snapshot(panelID: panel))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.sinceMs, 0)
        XCTAssertFalse(FeedProjector.isTurnEnd(state))
    }

    func testTimelessReobservationOfTheSameWordAndTurnKeepsAVerifiedCompletion() throws {
        XCTAssertEqual(try append("done", turn: 9, at: 2_500).receipt.projectionEffect, .applied)
        XCTAssertEqual(try append("done", turn: 9, at: nil).receipt.projectionEffect, .duplicateEvidence)
        let state = try XCTUnwrap(journal.snapshot(panelID: panel))
        XCTAssertTrue(FeedProjector.isTurnEnd(state))
        XCTAssertEqual(state.sinceMs, 2_500)
        // A genuinely new hc turn without a time is still new evidence.
        XCTAssertEqual(try append("working", turn: 10, at: nil).receipt.projectionEffect, .applied)
        XCTAssertEqual(journal.snapshot(panelID: panel)?.phase, .working)
    }

    func testStrippedResnapshotDoesNotEraseAnEnrichedCompletedTurn() async throws {
        let session = StatusSession()
        let first = HCRevision(connectionGeneration: 1, sequence: 1)
        session.feed.publish(HCInventorySnapshot(readiness: .ready(first), revision: first,
            records: [key: record("done", turn: 9, at: 2_500)]))
        let seen = expectation(description: "both snapshots presented")
        seen.expectedFulfillmentCount = 2
        let observer = HCRemoteStatusObservation(session: session, panelID: panel, workspaceID: workspace,
            key: key, journal: journal) { _ in seen.fulfill() }
        let stripped = HCRevision(connectionGeneration: 1, sequence: 2)
        session.feed.publish(HCInventorySnapshot(readiness: .ready(stripped), revision: stripped,
            records: [key: record("done", turn: 9, at: nil)]))
        await fulfillment(of: [seen], timeout: 2)
        let state = try XCTUnwrap(journal.snapshot(panelID: panel))
        XCTAssertTrue(FeedProjector.isTurnEnd(state))
        XCTAssertEqual(state.sinceMs, 2_500)
        withExtendedLifetime(observer) {}
    }

    func testOldRetainedStatusCannotClearANewerBlockedState() throws {
        try append("blocked", turn: 2, at: 3_000)
        XCTAssertEqual(try append("done", turn: 1, at: 2_000).receipt.projectionEffect, .stale)
        XCTAssertEqual(journal.snapshot(panelID: panel)?.phase, .blocked)
    }

    func testRemoteEvidenceCannotBeForgedThroughTheGenericJournalAppend() throws {
        let value = try draft(record("done", turn: 1))
        try value.validate()
        XCTAssertEqual(try journal.append(value).receipt.projectionEffect, .advisory)
        XCTAssertNil(journal.snapshot(panelID: panel))
    }

    func testForegroundUsesLocalClassifierWithoutResolvingRemotePID() {
        XCTAssertEqual(HCRemoteStatus.classification(.init(pid: 1, name: "codex", argv: ["codex"])), "codex")
        XCTAssertEqual(HCRemoteStatus.classification(.init(name: "claude", argv: ["claude"])), "claude-code")
        XCTAssertNil(HCRemoteStatus.classification(nil))
        let elsewhere = HCTerminalKey(owningCoreID: "laptop-core", localAddress: "t1")
        XCTAssertNotEqual(owner, HCRemoteStatus.owner(panelID: panel, key: elsewhere, agentKind: "claude-code"))
    }

    func testLostLinkAndMissingMirrorNeverPublishAFalseIdleOrEnd() async throws {
        let session = StatusSession()
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        session.feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                                                  records: [key: record("working")]))
        let working = expectation(description: "working published")
        let reconnecting = expectation(description: "reconnecting published")
        let observer = HCRemoteStatusObservation(session: session, panelID: panel, workspaceID: workspace,
            key: key, journal: journal) { value in
                if value.reconnecting {
                    XCTAssertEqual(value.classification, "claude-code")
                    reconnecting.fulfill()
                } else { working.fulfill() }
            }
        await fulfillment(of: [working], timeout: 2)
        XCTAssertEqual(journal.snapshot(panelID: panel)?.phase, .working)
        let lost = HCRevision(connectionGeneration: 1, sequence: 2)
        session.feed.publish(HCInventorySnapshot(readiness: .ready(lost), revision: lost,
            records: [key: record("idle", turn: 1, availability: .disconnected)]))
        await fulfillment(of: [reconnecting], timeout: 2)
        XCTAssertEqual(journal.snapshot(panelID: panel)?.phase, .working)
        XCTAssertEqual(journal.snapshot(panelID: panel)?.connection, .disconnected)
        XCTAssertEqual(try store.readPage(after: 0).count, 2)
        let pending = HCInventorySnapshot(readiness: .pending(.connectionLost), revision: lost,
                                           records: [key: record("done", turn: 1)])
        XCTAssertNil(HCRemoteStatus.reachable(pending, key: key))
        XCTAssertNil(HCRemoteStatus.reachable(HCInventorySnapshot(readiness: .ready(lost), revision: lost), key: key))
        withExtendedLifetime(observer) {}
    }

    /// C11H-205: a Studio terminal that ended stays ended. Once hc prunes the
    /// finished record (a day later) or its line drops, the chip used to read
    /// "Studio, Reconnecting" for good with the link up.
    func testAnEndedRemoteTerminalNeverReadsReconnecting() throws {
        let session = StatusSession()
        let presentations = StatusPresentations()
        let queue = DispatchQueue(label: "test.remote-status.ended")
        let observer = HCRemoteStatusObservation(session: session, panelID: panel, workspaceID: workspace,
            key: key, journal: journal, queue: queue) { presentations.append($0) }
        func publish(_ sequence: UInt64, _ records: [HCTerminalKey: HCTerminalRecord]) {
            let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
            session.feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: records))
            queue.sync {}; queue.sync {}
        }
        let ended = HCTerminalRecord(key: key, state: .finished, machineName: "studio", machineAvailability: .connected,
                                     endReason: "host_shutdown", finishedMilliseconds: 42)
        publish(1, [key: ended])
        publish(2, [key: HCTerminalRecord(key: key, state: .finished, machineName: "studio",
                                          machineAvailability: .disconnected, endReason: "host_shutdown")])
        publish(3, [:])
        let last = try XCTUnwrap(presentations.values.last)
        XCTAssertFalse(last.reconnecting, "a pruned end is still an end")
        guard case .ended(let evidence) = last.lifecycle else { return XCTFail("got \(last.lifecycle)") }
        XCTAssertEqual(evidence.endedAtMilliseconds, 42)
        let sinceEnd = presentations.values.drop { if case .ended = $0.lifecycle { return false }; return true }
        XCTAssertEqual(sinceEnd.count, 3, "the end, the dropped line and the pruned record each present")
        XCTAssertFalse(sinceEnd.contains { $0.reconnecting }, "never Reconnecting after the end")
        withExtendedLifetime(observer) {}
    }

    /// C11H-78: with shard pairs, the merged view's machine map holds one
    /// entry per name (another shard's line). A record's own availability,
    /// from its own shard, decides.
    func testReachabilityFollowsTheRecordsOwnShardLineNotTheMergedMachineMap() {
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let ownUpOtherDown = HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            records: [key: record("idle")], machines: ["studio": .disconnected])
        XCTAssertNotNil(HCRemoteStatus.reachable(ownUpOtherDown, key: key), "shard 0's line is down; this shard's is up")
        let ownDownOtherUp = HCInventorySnapshot(readiness: .ready(revision), revision: revision,
            records: [key: record("idle", availability: .disconnected)], machines: ["studio": .connected])
        XCTAssertNil(HCRemoteStatus.reachable(ownDownOtherUp, key: key), "this shard's line is down")
    }

    func testInventoryRefreshPreservesRemoteOwnershipAndJournalInBothLinkStates() throws {
        let session = StatusSession(), queue = DispatchQueue(label: "test.remote-status.refresh")
        let presentations = StatusPresentations()
        var sequence: UInt64 = 0
        func publish(_ reason: HCUnavailableReason? = nil, link: HCMachineAvailability = .connected) {
            sequence += 1
            let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
            session.feed.publish(HCInventorySnapshot(readiness: reason.map { .pending($0) } ?? .ready(revision),
                revision: revision, records: [key: record("working", availability: link)], machines: ["studio": link]))
            queue.sync {}; queue.sync {}
        }
        publish()
        let observer = HCRemoteStatusObservation(session: session, panelID: panel, workspaceID: workspace,
            key: key, journal: journal, queue: queue) { presentations.append($0) }
        defer { withExtendedLifetime(observer) {} }
        queue.sync {}; queue.sync {}
        XCTAssertEqual(presentations.values.last?.mailboxOwnsTerminal, true)
        publish(.inventoryPending)
        XCTAssertEqual(presentations.values.count, 1, "a refresh publishes no synthetic ownership or turn edge")
        XCTAssertEqual(presentations.values.last?.mailboxOwnsTerminal, true)
        XCTAssertEqual(journal.snapshot(panelID: panel)?.connection, .live)
        XCTAssertEqual(try store.readPage(after: 0).count, 1, "no connection_lost draft")

        publish(link: .disconnected)
        XCTAssertEqual(presentations.values.last?.mailboxOwnsTerminal, false)
        publish(.inventoryPending, link: .disconnected)
        XCTAssertEqual(presentations.values.count, 2, "refresh must also preserve the down presentation")
        XCTAssertEqual(journal.snapshot(panelID: panel)?.connection, .disconnected)
        XCTAssertEqual(try store.readPage(after: 0).count, 2)
        for actualLoss in [HCUnavailableReason.connectionLost, .coreUnreachable] {
            publish()
            XCTAssertEqual(presentations.values.last?.mailboxOwnsTerminal, true)
            publish(actualLoss)
            XCTAssertEqual(presentations.values.last?.mailboxOwnsTerminal, false,
                           "real loss must still revoke ownership")
            XCTAssertEqual(journal.snapshot(panelID: panel)?.connection, .disconnected)
        }
    }

    func testMissingRemoteTimeRequestsInventoryEnrichmentBeforeFeedCompletion() async throws {
        let feed = HCSessionFeed()
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let missing = record("done", turn: 4, at: nil)
        let enriched = record("done", turn: 4, at: 2_500)
        let expectedKey = key
        let attempts = StatusEnrichmentAttempts()
        let requested = expectation(description: "owning inventory enrichment requested")
        requested.expectedFulfillmentCount = 2
        let completed = expectation(description: "verified retained time published")
        let session = StatusSession(feed: feed) { key, status, turn, generation in
            XCTAssertEqual(key, expectedKey)
            XCTAssertEqual(status, "done")
            XCTAssertEqual(turn, 4)
            XCTAssertEqual(generation, 1)
            requested.fulfill()
            if await attempts.next() == 1 {
                // A different terminal's enrichment can publish a later
                // snapshot at the SAME hc sequence after this request was
                // refused by the shared admission limit. That must retry.
                feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                    records: [key: missing]))
                return nil
            }
            feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: [key: enriched]))
            return enriched
        }
        feed.publish(HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [key: missing]))
        let observer = HCRemoteStatusObservation(session: session, panelID: panel, workspaceID: workspace,
            key: key, journal: journal) { value in
                if value.record?.statusTimestampMilliseconds == 2_500 { completed.fulfill() }
            }
        await fulfillment(of: [requested, completed], timeout: 2)
        let state = try XCTUnwrap(journal.snapshot(panelID: panel))
        XCTAssertTrue(FeedProjector.isTurnEnd(state))
        XCTAssertEqual(state.sinceMs, 2_500)
        withExtendedLifetime(observer) {}
    }

    func testRemovingPanelCannotBeReversedByALateStatusCallback() throws {
        journal.remove(panelID: panel)
        journal.setHCStatusOwner(panelID: panel, owner: owner)
        XCTAssertNil(journal.exactOwner(panelID: panel))
        XCTAssertEqual(try append("working").receipt.projectionEffect, .unattributed)
        XCTAssertNil(journal.snapshot(panelID: panel))
    }
}

private final class StatusSession: HCSession, HCInventorySource, @unchecked Sendable {
    let feed: HCSessionFeed
    let enrich: @Sendable (HCTerminalKey, String, Int64, UInt64) async -> HCTerminalRecord?
    init(feed: HCSessionFeed = HCSessionFeed(),
         enrich: @escaping @Sendable (HCTerminalKey, String, Int64, UInt64) async -> HCTerminalRecord? = { _, _, _, _ in nil }) {
        self.feed = feed; self.enrich = enrich
    }
    func snapshot() async -> HCInventorySnapshot { await unavailable.snapshot() }
    func refresh() async -> HCInventorySnapshot { await unavailable.refresh() }
    func enrichStatusTimestamp(for key: HCTerminalKey, matchingStatus status: String,
                               turn: Int64, connectionGeneration: UInt64) async -> HCTerminalRecord? {
        await enrich(key, status, turn, connectionGeneration)
    }
    private let unavailable = HCUnavailableRuntime()
    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        feed.observe(on: queue, handler: handler)
    }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle { await unavailable.resolve(identity) }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { await unavailable.create(request) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        try await unavailable.attach(key, sink: sink, display: display)
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { await unavailable.end(key) }
    func diagnostics() async -> HCDiagnostics { await unavailable.diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { await unavailable.recoverSession(reason: reason) }
}

private final class StatusPresentations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HCRemoteStatusObservation.Presentation] = []
    func append(_ value: HCRemoteStatusObservation.Presentation) {
        lock.lock(); storage.append(value); lock.unlock()
    }
    var values: [HCRemoteStatusObservation.Presentation] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

private actor StatusEnrichmentAttempts {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
