import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class HCReconnectCoordinatorTests: XCTestCase {
    func testAdoptsFirstBindingWithoutCompetingInitialAttach() async {
        let f = HCReconnectFixture()
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        var attaches = 0
        var retired: [UInt64] = []
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
            attach: { _ in attaches += 1; return second },
            detach: { retired.append($0.generation); $0.detach() })
        let wrong = HCReconnectTestAttachment(
            key: HCTerminalKey(owningCoreID: "other", localAddress: "t1"), generation: 1)
        XCTAssertFalse(coordinator.start(attached: wrong, record: f.record))
        XCTAssertTrue(coordinator.start(attached: f.attachment, record: f.record))
        XCTAssertTrue(coordinator.start(attached: f.attachment, record: f.record))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(coordinator.attempts, 0)
        XCTAssertEqual(attaches, 0)
        XCTAssertTrue(coordinator.attachment === f.attachment)
        XCTAssertEqual(coordinator.status, .attached(1))
        coordinator.disconnected(generation: 1)
        await eventually { coordinator.status == .attached(2) }
        XCTAssertEqual(attaches, 1)
        XCTAssertEqual(retired, [1])
        let mutations = await session.mutations
        XCTAssertEqual(mutations, 0)
        coordinator.stop()
        XCTAssertEqual(retired, [1, 2])
    }

    func testFreshBindingRetiresOnlyTheLateCandidateAndStillReconnectsAfterANewLoss() async throws {
        let f = HCReconnectFixture()
        let fresh = HCReconnectTestAttachment(key: f.key, generation: 2)
        let late = HCReconnectTestAttachment(key: f.key, generation: 3)
        let next = HCReconnectTestAttachment(key: f.key, generation: 4)
        let gate = HCReconnectTestGate<any HCAttachment>()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        var attaches = 0
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session, attach: { _ in
            attaches += 1
            return attaches == 1 ? await gate.wait() : next
        })
        defer { coordinator.stop() }
        XCTAssertTrue(coordinator.start(attached: f.attachment, record: f.record))
        coordinator.disconnected(generation: 1)
        await eventually { attaches == 1 }
        let obsolete = try XCTUnwrap(coordinator.pendingAttemptForTesting)
        XCTAssertTrue(coordinator.start(attached: fresh, record: f.record))

        let otherKey = HCTerminalKey(owningCoreID: "other", localAddress: "t7")
        let wrong = HCReconnectTestAttachment(key: otherKey, generation: 5)
        XCTAssertFalse(coordinator.start(attached: wrong,
            record: HCTerminalRecord(key: otherKey, state: .running, pid: 707)))
        await gate.release(late)
        await obsolete.value
        XCTAssertTrue(coordinator.attachment === fresh)
        XCTAssertEqual(coordinator.status, .attached(2))
        XCTAssertEqual(late.detachCount, 1)
        XCTAssertEqual(late.port.invalidations, [.cancelled])
        XCTAssertEqual(fresh.detachCount, 0)
        XCTAssertTrue(fresh.port.invalidations.isEmpty)

        coordinator.disconnected(generation: 1) // a late loss from the original reader
        XCTAssertTrue(coordinator.attachment === fresh)
        coordinator.disconnected(generation: 2) // an actual subsequent outage
        let reconnect = try XCTUnwrap(coordinator.pendingAttemptForTesting)
        await reconnect.value
        XCTAssertTrue(coordinator.attachment === next)
        XCTAssertEqual(coordinator.status, .attached(4))
        XCTAssertEqual(attaches, 2)
        XCTAssertEqual(fresh.detachCount, 1)
    }

    func testFirstRuntimeBindingAdoptsAnInitiallyKeylessOwner() async throws {
        let f = HCReconnectFixture()
        let identity = HCPanelIdentity(panelID: f.panelID, persistence: .persistent)
        let session = HCReconnectTestSession(identity: identity, record: f.record)
        let coordinator = HCReconnectCoordinator(identity: identity, session: session, attach: { _ in
            XCTFail("the queued retry was superseded by the runtime binding")
            return f.attachment
        })
        coordinator.start()
        let attempt = try XCTUnwrap(coordinator.pendingAttemptForTesting)
        // Exercise adoption while the initial resolve is still queued.
        XCTAssertTrue(coordinator.start(attached: f.attachment, record: f.record))
        await attempt.value
        XCTAssertEqual(coordinator.identity.key, f.key)
        XCTAssertTrue(coordinator.attachment === f.attachment)
        XCTAssertEqual(f.attachment.detachCount, 0)
        coordinator.stop()
    }

    func testOutagePast120SecondsRetainsIdentityAndNeverCreates() async {
        let fixture = HCReconnectFixture()
        let clock = HCReconnectTestClock()
        let session = HCReconnectTestSession(identity: fixture.identity, record: fixture.record, unavailableAttempts: 121)
        var states: [HCReconnectStatus] = []
        let coordinator = HCReconnectCoordinator(
            identity: fixture.identity, session: session,
            sleep: { await clock.advance($0) },
            attach: { _ in fixture.attachment },
            changed: { states.append($0.status) }
        )
        coordinator.start()
        await eventually { coordinator.attachment != nil }
        XCTAssertEqual(coordinator.identity, fixture.identity)
        XCTAssertEqual(coordinator.attempts, 122)
        XCTAssertEqual(coordinator.status, .attached(1))
        let elapsed = await clock.elapsed
        XCTAssertGreaterThanOrEqual(elapsed, 121)
        let mutations = await session.mutations
        XCTAssertEqual(mutations, 0, "reconnect cannot create or end a terminal")
        XCTAssertTrue(states.contains(.waiting(.coreUnreachable)))
        guard case .live(let record) = coordinator.lifecycle else { return XCTFail("not live") }
        XCTAssertEqual(record.pid, fixture.record.pid)
        coordinator.stop()
    }

    func testFailedAttachRetriesTheSameKey() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        var keys: [HCTerminalKey] = []
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
            sleep: { _ in await Task.yield() }, attach: { record in
                keys.append(record.key)
                if keys.count == 1 { throw HCUnavailableReason.connectionLost }
                return f.attachment
            })
        coordinator.start()
        await eventually { coordinator.attachment != nil }
        XCTAssertEqual(keys, [f.key, f.key])
        XCTAssertEqual(coordinator.identity.panelID, f.identity.panelID)
        coordinator.stop()
    }

    func testStoppedCoordinatorDetachesLateAttachWithoutPublishingIt() async {
        let f = HCReconnectFixture()
        let gate = HCReconnectTestGate<any HCAttachment>()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        var attaching = false
        var attached = false
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
            attach: { _ in attaching = true; return await gate.wait() },
            attachmentChanged: { if $0 != nil { attached = true } })
        coordinator.start()
        await eventually { attaching }
        coordinator.stop()
        await gate.release(f.attachment)
        await eventually { f.attachment.detachCount == 1 }
        XCTAssertFalse(attached)
        XCTAssertEqual(coordinator.status, .stopped)
        XCTAssertNil(coordinator.attachment)
    }

    func testOldReaderLossDoesNotDetachReplacement() async {
        let f = HCReconnectFixture()
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        var calls = 0
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session, attach: { _ in
            calls += 1
            return calls == 1 ? f.attachment : second
        })
        coordinator.start()
        await eventually { coordinator.attachment?.generation == 1 }
        coordinator.disconnected(generation: 1)
        await eventually { coordinator.attachment?.generation == 2 }
        coordinator.disconnected(generation: 1)
        XCTAssertEqual(coordinator.status, .attached(2))
        XCTAssertEqual(second.detachCount, 0)
        XCTAssertEqual(f.attachment.port.invalidations, [.unavailable])
        coordinator.stop()
    }

    func testWrongTerminalCannotReplaceExistingIdentity() async {
        let f = HCReconnectFixture()
        let wrong = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "other", localAddress: "t1"),
                                     state: .running, pid: 123)
        let session = HCReconnectTestSession(identity: f.identity, record: wrong)
        var attachCalls = 0
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session, attach: { _ in
            attachCalls += 1
            return f.attachment
        })
        coordinator.start()
        await eventually { coordinator.status == .recoveryRequired(.staleIdentity) }
        XCTAssertEqual(attachCalls, 0)
        XCTAssertEqual(coordinator.identity, f.identity)
        coordinator.stop()
    }

    func testExplicitRecoveryDoesNotLoopOrCreate() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record,
                                             unresolvedReason: .recoveryRequired)
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session, attach: { _ in f.attachment })
        coordinator.start()
        await eventually { coordinator.status == .recoveryRequired(.recoveryRequired) }
        var calls = await session.recoveryCalls
        XCTAssertEqual(calls, 0)
        await coordinator.retryRecovery(reason: .foreignBuild)
        XCTAssertEqual(coordinator.status, .recoveryRequired(.foreignBuild))
        calls = await session.recoveryCalls
        XCTAssertEqual(calls, 1)
        let mutations = await session.mutations
        XCTAssertEqual(mutations, 0)
        coordinator.stop()
    }

    func testFreshReadyGenerationResumesAfterSharedSessionRecovery() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record,
                                             unresolvedReason: .recoveryRequired)
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
                                                  attach: { _ in f.attachment })
        defer { coordinator.stop() }
        coordinator.start()
        await eventually { coordinator.status == .recoveryRequired(.recoveryRequired) }

        // The first ready observation may arrive while another panel's
        // recovery is still in progress. One resolve is safe; no restart is.
        let first = HCRevision(connectionGeneration: 1, sequence: 0)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(first), revision: first))
        await eventually {
            coordinator.attempts == 2 && coordinator.status == .recoveryRequired(.recoveryRequired)
        }
        let ordinary = HCRevision(connectionGeneration: 1, sequence: 1)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(ordinary), revision: ordinary))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(coordinator.attempts, 2, "ordinary ready updates must not retry a recovery-required result")

        await session.setUnavailable(nil)
        let recovered = HCRevision(connectionGeneration: 2, sequence: 0)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(recovered), revision: recovered))
        await eventually { coordinator.status == .attached(1) }
        XCTAssertEqual(coordinator.identity, f.identity)
        XCTAssertTrue(coordinator.attachment === f.attachment)
        let recoveryCalls = await session.recoveryCalls
        let mutations = await session.mutations
        XCTAssertEqual(recoveryCalls, 0, "observe the recovered session without restarting it again")
        XCTAssertEqual(mutations, 0)
    }

    func testPendingToReadyResumesRecoveryRequiredOnSameGeneration() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record,
                                             unresolvedReason: .recoveryRequired)
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
                                                  attach: { _ in f.attachment })
        defer { coordinator.stop() }
        coordinator.start()
        await eventually { coordinator.status == .recoveryRequired(.recoveryRequired) }
        let pending = HCRevision(connectionGeneration: 1, sequence: 0)
        session.observations.emit(HCInventorySnapshot(readiness: .pending(.inventoryPending), revision: pending))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(coordinator.status, .recoveryRequired(.recoveryRequired))
        XCTAssertEqual(coordinator.attempts, 1)

        await session.setUnavailable(nil)
        let ready = HCRevision(connectionGeneration: 1, sequence: 1)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(ready), revision: ready))
        await eventually { coordinator.status == .attached(1) }
        XCTAssertEqual(coordinator.identity, f.identity)
        let recoveryCalls = await session.recoveryCalls
        let mutations = await session.mutations
        XCTAssertEqual(recoveryCalls, 0)
        XCTAssertEqual(mutations, 0)
    }

    func testAuthoritativeEndStopsReconnectWithoutEndingAgain() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record, ended: true)
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session, attach: { _ in
            XCTFail("ended terminal must not attach")
            return f.attachment
        })
        coordinator.start()
        await eventually { coordinator.status == .ended }
        guard case .ended(let proof) = coordinator.lifecycle else { return XCTFail("missing end evidence") }
        XCTAssertEqual(proof.hcReason, "holder_lost")
        let mutations = await session.mutations
        XCTAssertEqual(mutations, 0)
    }

    func testInventoryLossPublishesUnresolvedAndOldSnapshotCannotUndoReattach() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        var attachCalls = 0
        // No timer retry: only the ready snapshot starts the reattach. This fake answers
        // `.live` as soon as it is available again, before the generation-2 snapshot it would
        // publish first; a 10 ms retry could attach in that window on a loaded host, and the
        // snapshot's new generation then retired the attachment it had just made (C11H-346).
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
            sleep: { seconds in if seconds > 0 { try await Task.sleep(nanoseconds: 3_600_000_000_000) } }, attach: { _ in
                attachCalls += 1
                return attachCalls == 1 ? f.attachment : second
            })
        coordinator.start()
        await eventually { coordinator.attachment != nil }
        let first = HCRevision(connectionGeneration: 1, sequence: 1)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(first), revision: first))
        await session.setUnavailable(.connectionLost)
        let lost = HCRevision(connectionGeneration: 1, sequence: 2)
        session.observations.emit(HCInventorySnapshot(readiness: .pending(.connectionLost), revision: lost))
        await eventually { coordinator.status == .waiting(.connectionLost) }
        XCTAssertNil(coordinator.attachment)
        guard case .unresolved(let retained, _) = coordinator.lifecycle else { return XCTFail("loss inferred death") }
        XCTAssertEqual(retained, f.identity)
        await session.setUnavailable(nil)
        let ready = HCRevision(connectionGeneration: 2, sequence: 0)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(ready), revision: ready))
        await eventually { coordinator.status == .attached(2) }
        session.observations.emit(HCInventorySnapshot(readiness: .pending(.connectionLost), revision: lost))
        // A main-queue barrier ensures the stale callback was actually consumed.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(coordinator.status, .attached(2))
        XCTAssertEqual(second.detachCount, 0)
        XCTAssertEqual(attachCalls, 2, "one reattach, started by the ready snapshot")
        coordinator.stop()
    }

    /// C11H-92 (hc Lead item 2): a panel whose terminal moved to another shard
    /// sees that shard's own, lower revisions. They are a new stream, not stale.
    func testANewShardsLowerRevisionIsNotStale() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        var attachCalls = 0
        // No timer retry: only an inventory snapshot can start the reattach.
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
            sleep: { seconds in if seconds > 0 { try await Task.sleep(nanoseconds: 3_600_000_000_000) } }, attach: { _ in
                attachCalls += 1
                return attachCalls == 1 ? f.attachment : second
            })
        coordinator.start()
        await eventually { coordinator.attachment != nil }
        let s0 = HCShardID.legacy
        let pool1 = HCShardID(index: 1)
        let old = HCRevision(connectionGeneration: 7, sequence: 40)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(old), revision: old, source: s0))
        await session.setUnavailable(.connectionLost)
        let lost = HCRevision(connectionGeneration: 7, sequence: 41)
        session.observations.emit(HCInventorySnapshot(readiness: .pending(.connectionLost), revision: lost, source: s0))
        await eventually { coordinator.status == .waiting(.connectionLost) }
        await session.setUnavailable(nil)
        let fresh = HCRevision(connectionGeneration: 1, sequence: 1)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(fresh), revision: fresh, source: pool1))
        await eventually { coordinator.status == .attached(2) }
        XCTAssertEqual(coordinator.status, .attached(2), "shard 1's generation 1 is accepted after S0's generation 7")
        coordinator.stop()
    }

    /// Grok on #141 (non-blocking 1): a still-attached panel whose route moves
    /// to another shard reattaches, even when both snapshots are ready at the
    /// same revision: a new shard is a new generation.
    func testAnAttachedPanelReattachesWhenItsShardChanges() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        let second = HCReconnectTestAttachment(key: f.key, generation: 2)
        var attachCalls = 0
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
            sleep: { seconds in if seconds > 0 { try await Task.sleep(nanoseconds: 3_600_000_000_000) } }, attach: { _ in
                attachCalls += 1
                return attachCalls == 1 ? f.attachment : second
            })
        coordinator.start()
        await eventually { coordinator.attachment != nil }
        let same = HCRevision(connectionGeneration: 1, sequence: 5)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(same), revision: same, source: .legacy))
        session.observations.emit(HCInventorySnapshot(readiness: .ready(same), revision: same, source: HCShardID(index: 1)))
        await eventually { coordinator.status == .attached(2) }
        XCTAssertEqual(coordinator.status, .attached(2), "the new shard's terminal is attached afresh")
        XCTAssertEqual(attachCalls, 2)
        coordinator.stop()
    }

    func testSlowInventoryOnOpenGenerationKeepsAttachmentAndInput() async {
        let f = HCReconnectFixture()
        let session = HCReconnectTestSession(identity: f.identity, record: f.record)
        var attaches = 0
        let coordinator = HCReconnectCoordinator(identity: f.identity, session: session,
            attach: { _ in attaches += 1; return f.attachment })
        coordinator.start()
        await eventually { coordinator.attachment != nil }
        let initial = HCRevision(connectionGeneration: 1, sequence: 1)
        session.observations.emit(HCInventorySnapshot(readiness: .ready(initial), revision: initial))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        for (index, reason) in [HCUnavailableReason.inventoryPending, .deadlineExceeded].enumerated() {
            let revision = HCRevision(connectionGeneration: 1, sequence: UInt64(index + 2))
            session.observations.emit(HCInventorySnapshot(readiness: .pending(reason), revision: revision))
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            XCTAssertTrue(coordinator.attachment === f.attachment)
            XCTAssertEqual(coordinator.status, .attached(1))
            XCTAssertEqual(f.attachment.detachCount, 0)
            XCTAssertTrue(f.attachment.port.invalidations.isEmpty)
        }
        XCTAssertEqual(attaches, 1, "slow inventory must not reopen an already open attachment")
        coordinator.stop()
    }
}

@MainActor
func eventually(file: StaticString = #filePath, line: UInt = #line,
                _ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
    XCTAssertTrue(predicate(), "condition did not become true", file: file, line: line)
}

struct HCReconnectFixture {
    let key = HCTerminalKey(owningCoreID: "owned-core", localAddress: "t7")
    let panelID = UUID()
    var identity: HCPanelIdentity { HCPanelIdentity(panelID: panelID, key: key) }
    var record: HCTerminalRecord { HCTerminalRecord(key: key, state: .running, pid: 707) }
    let attachment: HCReconnectTestAttachment
    init() { attachment = HCReconnectTestAttachment(key: key, generation: 1) }
    func display(_ generation: UInt64) -> HCDisplayState {
        HCDisplayState(revision: HCDisplayRevision(attachmentGeneration: generation, displayGeneration: 1),
                       grid: HCGridSize(columns: 80, rows: 24))
    }
    func request(_ generation: UInt64 = 1, source: HCInputSource = .socket) -> HCInputRequest {
        HCInputRequest(operationID: UUID(), panelID: panelID, key: key, attachmentGeneration: generation,
                       source: source, payload: Data("a whole body".utf8), submitReturn: true)
    }
}

actor HCReconnectTestClock {
    private(set) var elapsed: TimeInterval = 0
    func advance(_ seconds: TimeInterval) async { elapsed += seconds; await Task.yield() }
}

actor HCReconnectTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var value: Value?
    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: Value) {
        self.value = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

actor HCReconnectTestSession: HCSession {
    let identity: HCPanelIdentity
    let record: HCTerminalRecord
    let unavailableAttempts: Int
    var unresolvedReason: HCUnavailableReason?
    let ended: Bool
    nonisolated let observations = HCReconnectTestObservations()
    private var resolutions = 0
    private(set) var mutations = 0
    private(set) var recoveryCalls = 0
    init(identity: HCPanelIdentity, record: HCTerminalRecord, unavailableAttempts: Int = 0,
         unresolvedReason: HCUnavailableReason? = nil, ended: Bool = false) {
        self.identity = identity; self.record = record; self.unavailableAttempts = unavailableAttempts
        self.unresolvedReason = unresolvedReason; self.ended = ended
    }
    nonisolated func observe(on queue: DispatchQueue,
                            handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        observations.observe(on: queue, handler: handler)
    }
    func setUnavailable(_ reason: HCUnavailableReason?) { unresolvedReason = reason }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        resolutions += 1
        if let unresolvedReason { return .unresolved(identity, unresolvedReason) }
        if resolutions <= unavailableAttempts { return .unresolved(identity, .coreUnreachable) }
        if ended {
            return .ended(HCEndEvidence(id: UUID(), key: record.key,
                revision: HCRevision(connectionGeneration: 1, sequence: 2), kind: .finished, hcReason: "holder_lost"))
        }
        return .live(record)
    }
    func create(_ request: HCCreateRequest) async -> HCCreateResult {
        mutations += 1; return .rejectedBeforeTransmission(.backendNotInstalled)
    }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink,
                display: HCDisplayState) async throws -> any HCAttachment { throw HCUnavailableReason.backendNotInstalled }
    func end(_ key: HCTerminalKey) async -> HCEndResult { mutations += 1; return .unresolved(key, .backendNotInstalled) }
    func diagnostics() async -> HCDiagnostics { await HCUnavailableRuntime().diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult {
        recoveryCalls += 1; return .recoveryRequired(.foreignBuild)
    }
}

final class HCReconnectTestObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var delivery: (DispatchQueue, @Sendable (HCInventorySnapshot) -> Void)?
    func observe(on queue: DispatchQueue,
                 handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        lock.lock(); delivery = (queue, handler); lock.unlock()
        return HCObservation { [weak self] in self?.cancel() }
    }
    func emit(_ snapshot: HCInventorySnapshot) {
        lock.lock(); let delivery = delivery; lock.unlock()
        if let (queue, handler) = delivery { queue.async { handler(snapshot) } }
    }
    private func cancel() { lock.lock(); delivery = nil; lock.unlock() }
}

final class HCReconnectTestInput: HCInputPort, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated: [HCInputRefusal] = []
    private var admitted = false
    private var raw: [Data] = []
    var rawWrites: [Data] { lock.lock(); defer { lock.unlock() }; return raw }
    var isAdmitted: Bool { lock.lock(); defer { lock.unlock() }; return admitted }
    func setAdmission(_ open: Bool) { lock.lock(); admitted = open; lock.unlock() }
    var invalidations: [HCInputRefusal] { lock.lock(); defer { lock.unlock() }; return invalidated }
    func invalidate(generation: UInt64, reason: HCInputRefusal) {
        lock.lock(); invalidated.append(reason); lock.unlock()
    }
    func receiveRaw(_ bytes: Data, kind: HCRawInputKind, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if admitted, invalidated.isEmpty { raw.append(bytes) }
    }
    func submit(_ request: HCInputRequest) async -> HCInputOutcome { .refused(.unavailable) }
}

final class HCReconnectTestAttachment: HCAttachment, @unchecked Sendable {
    @MainActor static func setAdmission(_ attachment: any HCAttachment, _ open: Bool) {
        (attachment as! HCReconnectTestAttachment).port.setAdmission(open)
    }
    let key: HCTerminalKey
    let generation: UInt64
    let port = HCReconnectTestInput()
    var input: any HCInputPort { port }
    private let lock = NSLock()
    private var detached = 0
    var detachCount: Int { lock.lock(); defer { lock.unlock() }; return detached }
    // Only configured/read on the main actor; async protocol witnesses hop to it.
    @MainActor var submissions: [HCInputRequest] = []
    @MainActor var submitHandler: ((HCInputRequest) async -> HCInputOutcome)?
    @MainActor var screenHandler: ((HCDisplayRevision) async -> HCScreenReceipt?)?
    init(key: HCTerminalKey, generation: UInt64) { self.key = key; self.generation = generation }
    @MainActor func submit(_ request: HCInputRequest) async -> HCInputOutcome {
        submissions.append(request)
        if let submitHandler { return await submitHandler(request) }
        return .written(HCWriteReceipt(operationID: request.operationID, attachmentGeneration: generation,
                                       bodyBytesWritten: request.payload.count, returnWritten: request.submitReturn))
    }
    @MainActor func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? {
        if let screenHandler { return await screenHandler(revision) }
        return HCScreenReceipt(revision: revision, parsedOutputWatermark: 42, columns: 80, rows: 24)
    }
    func updateDisplay(_ display: HCDisplayState) async -> HCControlOutcome { .written }
    func detach() { lock.lock(); detached += 1; lock.unlock() }
}
