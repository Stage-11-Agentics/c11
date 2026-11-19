import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCAgentRecoveryTests: XCTestCase {
    private let panelID = UUID()
    private let key = HCTerminalKey(owningCoreID: "own-core", localAddress: "t1")
    private let root = HCProcessIdentity(pid: 123, startTimeMicroseconds: 1_000_000)
    private let revision = HCRevision(connectionGeneration: 2, sequence: 10)

    private func record(key: HCTerminalKey? = nil, state: HCTerminalState = .running,
                        locality: HCMachineAvailability = .local, pid: Int32? = 123,
                        identity: HCProcessIdentity? = nil) -> HCTerminalRecord {
        HCTerminalRecord(key: key ?? self.key, state: state, machineAvailability: locality,
                         pid: pid, tty: "untrusted-inventory-tty", localProcessIdentity: identity)
    }

    private func snapshot(records: [HCTerminalRecord]? = nil, revision: HCRevision? = nil,
                          readiness: HCReadiness? = nil, bound: Bool = true,
                          includeBuild: Bool = true) -> HCInventorySnapshot {
        let revision = revision ?? self.revision
        let build = HCBuildIdentity(pin: .current, executablePath: "/owned/hc",
            fileIdentity: HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 0),
            process: HCProcessIdentity(pid: 99, startTimeMicroseconds: 100), coreID: "own-core", protocolGeneration: 1)
        return HCInventorySnapshot(readiness: readiness ?? .ready(revision), revision: revision,
            records: Dictionary(uniqueKeysWithValues: (records ?? [record()]).map { ($0.key, $0) }),
            buildIdentity: includeBuild ? build : nil, panelBindings: bound ? [panelID: key] : [:])
    }

    private func kernel() -> RecoveryTestKernel {
        RecoveryTestKernel(facts: HCAgentRecoveryProcessFacts(identity: root, controllingTTYDevice: 42))
    }

    private func state(_ kernel: RecoveryTestKernel) -> HCAgentRecoveryState {
        HCAgentRecoveryState(readProcess: { kernel.read($0) }, ttyName: { kernel.tty($0) })
    }

    func testReadyLocalBindingPublishesKernelTTYAndPinnedRootWithoutSteadyStateReads() throws {
        let kernel = kernel()
        var state = state(kernel)
        XCTAssertTrue(state.accept(snapshot()))
        let observation = try XCTUnwrap(state.observations.first)
        XCTAssertEqual(observation.panelID, panelID)
        XCTAssertEqual(observation.key, key)
        XCTAssertEqual(observation.rootProcessIdentity, root)
        XCTAssertEqual(observation.ttyName, "ttys042")
        XCTAssertEqual(observation.revision, revision)
        XCTAssertEqual(kernel.readPIDs, [123, 123])
        XCTAssertEqual(kernel.mappedDevices, [42])
        XCTAssertFalse(state.needsRetry)

        state.accept(snapshot(revision: HCRevision(connectionGeneration: 2, sequence: 11)))
        state.recover()
        XCTAssertEqual(state.observations.count, 1)
        XCTAssertEqual(kernel.readPIDs, [123, 123], "Existing detectors own polling after recovery resolves")
    }

    func testPendingGapAndStaleGenerationsCannotReadOrReplaceThePinnedProcess() {
        let kernel = kernel()
        var state = state(kernel)
        state.accept(snapshot())
        let pendingRevision = HCRevision(connectionGeneration: 3, sequence: 0)
        state.accept(snapshot(revision: pendingRevision, readiness: .pending(.connectionLost)))
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertFalse(state.needsRetry)
        XCTAssertEqual(kernel.readPIDs.count, 2)

        XCTAssertFalse(state.accept(snapshot()))
        XCTAssertEqual(kernel.readPIDs.count, 2)
        let replacement = HCProcessIdentity(pid: 123, startTimeMicroseconds: 2_000_000)
        kernel.setFacts(HCAgentRecoveryProcessFacts(identity: replacement, controllingTTYDevice: 42))
        state.accept(snapshot(revision: HCRevision(connectionGeneration: 3, sequence: 1)))
        XCTAssertTrue(state.observations.isEmpty, "A reconnect must not adopt a reused numeric PID")
        XCTAssertFalse(state.needsRetry)
    }

    func testOlderSequenceAndOldPendingSnapshotPreserveCurrentPositiveFacts() {
        let kernel = kernel()
        var state = state(kernel)
        state.accept(snapshot())
        let observed = state.observations
        XCTAssertFalse(state.accept(snapshot(revision: HCRevision(connectionGeneration: 2, sequence: 9))))
        XCTAssertFalse(state.accept(snapshot(revision: HCRevision(connectionGeneration: 1, sequence: 100),
                                             readiness: .pending(.malformedResponse))))
        XCTAssertEqual(state.observations, observed)
        XCTAssertEqual(kernel.readPIDs.count, 2)
    }

    func testUnreadyMissingBuildAndMismatchedReadyRevisionDoNotReadProcesses() {
        let kernel = kernel()
        var state = state(kernel)
        state.accept(snapshot(readiness: .pending(.inventoryPending)))
        state.accept(snapshot(includeBuild: false))
        state.accept(snapshot(readiness: .ready(HCRevision(connectionGeneration: 9, sequence: 9))))
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertFalse(state.needsRetry)
        XCTAssertTrue(kernel.readPIDs.isEmpty)
        XCTAssertTrue(kernel.mappedDevices.isEmpty)
    }

    func testRemoteUnknownForeignCoreAndNonRunningRecordsNeverTouchLocalKernel() {
        let kernel = kernel()
        var state = state(kernel)
        for locality in [HCMachineAvailability.connected, .disconnected, .unknown] {
            state.accept(snapshot(records: [record(locality: locality)]))
        }
        for terminalState in [HCTerminalState.starting, .finished] {
            state.accept(snapshot(records: [record(state: terminalState)]))
        }
        state.accept(snapshot(records: [record(pid: nil)]))
        state.accept(snapshot(records: [record(pid: 0)]))
        let foreign = HCTerminalKey(owningCoreID: "remote-core", localAddress: "t1")
        state.setClaims([panelID: foreign])
        state.accept(snapshot(records: [record(key: foreign)], bound: false))
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertFalse(state.needsRetry)
        XCTAssertTrue(kernel.readPIDs.isEmpty)
        XCTAssertTrue(kernel.mappedDevices.isEmpty)
    }

    func testLateRecoveredClaimReplaysSeedAndConflictingBindingDoesNotAdmit() {
        let kernel = kernel()
        var state = state(kernel)
        state.accept(snapshot(bound: false))
        XCTAssertTrue(kernel.readPIDs.isEmpty)
        state.setClaims([panelID: key])
        XCTAssertEqual(state.observations.count, 1)
        XCTAssertEqual(kernel.readPIDs.count, 2)

        let other = HCTerminalKey(owningCoreID: "own-core", localAddress: "t2")
        state.setClaims([panelID: other])
        state.accept(snapshot(records: [record(), record(key: other)]))
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertEqual(kernel.readPIDs.count, 2, "Conflicting panel ownership is not resolved by guessing")
    }

    func testLateExplicitClaimRevalidatesEvenIfInventoryBindingWasPublishedBeforePanelConstruction() {
        let kernel = kernel()
        var state = state(kernel)
        state.accept(snapshot())
        XCTAssertEqual(state.observations.count, 1)
        kernel.setFacts(HCAgentRecoveryProcessFacts(
            identity: HCProcessIdentity(pid: root.pid, startTimeMicroseconds: root.startTimeMicroseconds + 1),
            controllingTTYDevice: 42))
        state.setClaims([panelID: key])
        XCTAssertTrue(state.observations.isEmpty, "A delayed panel cannot adopt a root that changed after the seed")
    }

    func testUnavailableProcessAndMissingTTYRetryWithoutInventingFacts() {
        let kernel = kernel()
        kernel.setFacts(nil)
        var state = state(kernel)
        state.accept(snapshot())
        XCTAssertTrue(state.needsRetry)
        XCTAssertTrue(state.observations.isEmpty)

        kernel.setFacts(HCAgentRecoveryProcessFacts(identity: root, controllingTTYDevice: nil))
        state.recover()
        XCTAssertTrue(state.needsRetry)
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertTrue(kernel.mappedDevices.isEmpty)

        kernel.setFacts(HCAgentRecoveryProcessFacts(identity: root, controllingTTYDevice: 42))
        kernel.setTTY(nil)
        state.recover()
        XCTAssertTrue(state.needsRetry)
        XCTAssertTrue(state.observations.isEmpty)
        kernel.setTTY("ttys042")
        state.recover()
        XCTAssertFalse(state.needsRetry)
        XCTAssertEqual(state.observations.first?.rootProcessIdentity, root)
    }

    func testIdentityPinsBeforeTTYIsAvailableAndSurvivesAuthoritativeAbsence() {
        let kernel = kernel()
        kernel.setFacts(HCAgentRecoveryProcessFacts(identity: root, controllingTTYDevice: nil))
        var state = state(kernel)
        state.accept(snapshot())
        state.accept(snapshot(records: []))
        kernel.setFacts(HCAgentRecoveryProcessFacts(
            identity: HCProcessIdentity(pid: root.pid, startTimeMicroseconds: root.startTimeMicroseconds + 1),
            controllingTTYDevice: 42))
        state.accept(snapshot())
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertFalse(state.needsRetry)
        XCTAssertTrue(kernel.mappedDevices.isEmpty)
    }

    func testAuthoritativeRecordIdentityRejectsReusedPIDAndInconsistentPID() {
        let kernel = kernel()
        let older = HCProcessIdentity(pid: root.pid, startTimeMicroseconds: root.startTimeMicroseconds - 1)
        var state = state(kernel)
        state.accept(snapshot(records: [record(identity: older)]))
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertTrue(kernel.mappedDevices.isEmpty)
        // A later record omitting the optional fact cannot remove its pin.
        state.accept(snapshot())
        XCTAssertTrue(state.observations.isEmpty)

        let reads = kernel.readPIDs.count
        state.accept(snapshot(records: [record(identity: HCProcessIdentity(pid: 999, startTimeMicroseconds: 1))]))
        XCTAssertEqual(kernel.readPIDs.count, reads)
    }

    func testProcessReuseOrTTYChangeDuringMappingCannotPublishMixedFacts() {
        let kernel = kernel()
        let before = HCAgentRecoveryProcessFacts(identity: root, controllingTTYDevice: 42)
        let reused = HCAgentRecoveryProcessFacts(
            identity: HCProcessIdentity(pid: root.pid, startTimeMicroseconds: root.startTimeMicroseconds + 1),
            controllingTTYDevice: 42)
        kernel.setScript([before, reused])
        var state = state(kernel)
        state.accept(snapshot())
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertFalse(state.needsRetry)

        kernel.setScript([before, HCAgentRecoveryProcessFacts(identity: root, controllingTTYDevice: 43)])
        state.recover()
        XCTAssertTrue(state.observations.isEmpty)
        XCTAssertTrue(state.needsRetry)
    }

    func testObserverRetriesOffMainThenStopsItsTimerAfterResolution() throws {
        let kernel = kernel()
        kernel.setScript([nil])
        let feed = RecoveryTestFeed()
        let subscribed = expectation(description: "subscribed")
        let recovered = expectation(description: "recovered on retry")
        let observations = RecoveryTestObservations()
        let recovery = HCAgentRecovery(observeInventory: { queue, handler in
            let token = feed.observe(queue: queue, handler: handler)
            subscribed.fulfill()
            return token
        }, readProcess: { pid in
            XCTAssertFalse(Thread.isMainThread)
            return kernel.read(pid)
        }, ttyName: { kernel.tty($0) }, retryInterval: 0.01, handler: { batch in
            XCTAssertFalse(Thread.isMainThread)
            observations.append(batch)
            recovered.fulfill()
        })
        defer { recovery.stop() }
        recovery.start()
        wait(for: [subscribed], timeout: 1)
        feed.send(snapshot())
        wait(for: [recovered], timeout: 1)
        let observation = try XCTUnwrap(observations.values.first)
        XCTAssertTrue(recovery.isCurrent(observation))
        let settled = expectation(description: "timer remains stopped")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(observations.values.count, 1, "A resolved panel must not keep a recovery timer alive")
        XCTAssertEqual(kernel.readPIDs.count, 3)
    }

    func testPendingAndChangedClaimInvalidateQueuedMainObservationAndStopInvalidatesImmediately() throws {
        let kernel = kernel()
        let feed = RecoveryTestFeed()
        let subscribed = expectation(description: "subscribed")
        let observations = RecoveryTestObservations()
        let recovery = HCAgentRecovery(observeInventory: { queue, handler in
            let token = feed.observe(queue: queue, handler: handler)
            subscribed.fulfill()
            return token
        }, readProcess: { kernel.read($0) }, ttyName: { kernel.tty($0) }, handler: { observations.append($0) })
        defer { recovery.stop() }
        recovery.start()
        wait(for: [subscribed], timeout: 1)
        let ready = expectation(description: "ready")
        feed.send(snapshot(), delivered: ready)
        wait(for: [ready], timeout: 1)
        let old = try XCTUnwrap(observations.values.first)
        XCTAssertTrue(recovery.isCurrent(old))

        let pending = expectation(description: "pending")
        feed.send(snapshot(readiness: .pending(.malformedResponse)), delivered: pending)
        wait(for: [pending], timeout: 1)
        XCTAssertFalse(recovery.isCurrent(old))
        XCTAssertEqual(observations.values.count, 1, "Pending is not an empty/dead publication")

        let next = expectation(description: "next generation")
        feed.send(snapshot(revision: HCRevision(connectionGeneration: 3, sequence: 0)), delivered: next)
        wait(for: [next], timeout: 1)
        let current = try XCTUnwrap(observations.values.last)
        XCTAssertFalse(recovery.isCurrent(old))
        XCTAssertTrue(recovery.isCurrent(current))

        recovery.setClaims([panelID: HCTerminalKey(owningCoreID: "own-core", localAddress: "other")])
        let claimsApplied = expectation(description: "claim update")
        feed.send(snapshot(revision: HCRevision(connectionGeneration: 3, sequence: 1)), delivered: claimsApplied)
        wait(for: [claimsApplied], timeout: 1)
        XCTAssertFalse(recovery.isCurrent(current))

        recovery.setClaims([:])
        let rebound = expectation(description: "binding restored")
        feed.send(snapshot(revision: HCRevision(connectionGeneration: 3, sequence: 2)), delivered: rebound)
        wait(for: [rebound], timeout: 1)
        let restored = try XCTUnwrap(observations.values.last)
        XCTAssertTrue(recovery.isCurrent(restored))
        recovery.stop()
        XCTAssertFalse(recovery.isCurrent(restored))
    }

    func testUnresolvedRetryBudgetStopsAndAnInventoryUpdateCanRetryAgain() {
        let kernel = kernel()
        kernel.setFacts(nil)
        let feed = RecoveryTestFeed()
        let subscribed = expectation(description: "subscribed")
        let recovery = HCAgentRecovery(observeInventory: { queue, handler in
            let token = feed.observe(queue: queue, handler: handler)
            subscribed.fulfill()
            return token
        }, readProcess: { kernel.read($0) }, ttyName: { kernel.tty($0) },
            retryInterval: 0.01, maximumRetryAttempts: 2, handler: { _ in XCTFail("No local facts available") })
        defer { recovery.stop() }
        recovery.start()
        wait(for: [subscribed], timeout: 1)
        feed.send(snapshot())
        // The first read plus two retries, then the timer disarms itself. Wait
        // for that milestone, bounded so a budget that never stops fails in 1 s.
        let deadline = Date().addingTimeInterval(1)
        while (kernel.readPIDs.count < 3 || recovery.retryTimerArmedForTesting()), Date() < deadline {
            usleep(2_000)
        }
        XCTAssertFalse(recovery.retryTimerArmedForTesting(), "the retry budget did not stop the timer")
        XCTAssertEqual(kernel.readPIDs.count, 3)
        let restarted = expectation(description: "new inventory retries")
        feed.send(snapshot(revision: HCRevision(connectionGeneration: 2, sequence: 11)), delivered: restarted)
        wait(for: [restarted], timeout: 1)
        XCTAssertGreaterThanOrEqual(kernel.readPIDs.count, 4)
    }
}

private final class RecoveryTestKernel: @unchecked Sendable {
    private let lock = NSLock()
    private var facts: HCAgentRecoveryProcessFacts?
    private var name: String? = "ttys042"
    private var script: [HCAgentRecoveryProcessFacts?] = []
    private var reads: [Int32] = []
    private var devices: [UInt32] = []

    init(facts: HCAgentRecoveryProcessFacts?) { self.facts = facts }
    var readPIDs: [Int32] { lock.lock(); defer { lock.unlock() }; return reads }
    var mappedDevices: [UInt32] { lock.lock(); defer { lock.unlock() }; return devices }
    func setFacts(_ value: HCAgentRecoveryProcessFacts?) { lock.lock(); facts = value; lock.unlock() }
    func setTTY(_ value: String?) { lock.lock(); name = value; lock.unlock() }
    func setScript(_ values: [HCAgentRecoveryProcessFacts?]) { lock.lock(); script = values; lock.unlock() }
    func read(_ pid: Int32) -> HCAgentRecoveryProcessFacts? {
        lock.lock(); defer { lock.unlock() }
        reads.append(pid)
        return script.isEmpty ? facts : script.removeFirst()
    }
    func tty(_ device: UInt32) -> String? {
        lock.lock(); defer { lock.unlock() }
        devices.append(device)
        return name
    }
}

private final class RecoveryTestObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HCAgentRecoveryObservation] = []
    var values: [HCAgentRecoveryObservation] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ values: [HCAgentRecoveryObservation]) { lock.lock(); storage += values; lock.unlock() }
}

private final class RecoveryTestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (DispatchQueue, @Sendable (HCInventorySnapshot) -> Void)?

    func observe(queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        lock.lock(); target = (queue, handler); lock.unlock()
        return HCObservation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.target = nil; self.lock.unlock()
        }
    }

    func send(_ snapshot: HCInventorySnapshot, delivered: XCTestExpectation? = nil) {
        lock.lock(); let target = self.target; lock.unlock()
        guard let (queue, handler) = target else { return XCTFail("Recovery has not subscribed") }
        queue.async { handler(snapshot); delivered?.fulfill() }
    }
}

/// Plan 8's recovery reads panel identities from process admission
/// (`HCAgentRecoveryController.apply`); `HCPanelSession` is their production
/// producer (wiring audit gap 3). Each test uses its own panel id; nothing is
/// launched and no core is reached (`HCUnavailableRuntime`).
@MainActor
final class HCPanelIdentityRegistrationTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "own-core", localAddress: "t-registered")
    private let replacementKey = HCTerminalKey(owningCoreID: "own-core", localAddress: "t-replacement")

    private func runtime(_ identity: HCPanelIdentity) -> HCPanelSession {
        HCPanelSession(identity: identity, session: HCUnavailableRuntime())
    }

    private func registered(_ panelID: UUID) -> HCPanelIdentity? {
        HCProcessAdmission.shared.panelIdentity(panelID)
    }

    func testARestoredPanelIsRegisteredBeforeItResolves() {
        let identity = HCPanelIdentity(panelID: UUID(), key: key, persistence: .persistent, origin: .restored)
        let panel = runtime(identity)
        defer { panel.detachSurface() }
        XCTAssertEqual(registered(identity.panelID), identity, "a surviving terminal's key must be claimable at once")
    }

    func testALiveTerminalsKeyIsRegistered() {
        let panelID = UUID()
        let panel = runtime(HCPanelIdentity(panelID: panelID, origin: .fresh))
        defer { panel.detachSurface() }
        panel.publish(.live(HCTerminalRecord(key: key, state: .running)))
        XCTAssertEqual(registered(panelID)?.key, key)
        XCTAssertEqual(registered(panelID)?.persistence, .persistent)
    }

    func testDisposingThePanelClearsItsRegistrationButReattachKeepsIt() {
        let identity = HCPanelIdentity(panelID: UUID(), key: key, persistence: .persistent, origin: .restored)
        let panel = runtime(identity)
        XCTAssertEqual(registered(identity.panelID), identity, "precondition")
        panel.detachSurface(forReattach: true)
        XCTAssertEqual(registered(identity.panelID), identity, "a reattach keeps the claim")
        panel.detachSurface()
        XCTAssertNil(registered(identity.panelID), "a disposed panel claims nothing")
    }

    func testRepeatedIdenticalPublicationsRegisterOnceAndAChangedKeyOnce() {
        let panelID = UUID()
        var calls: [HCPanelIdentity?] = []
        let panel = HCPanelSession(identity: HCPanelIdentity(panelID: panelID, origin: .fresh),
                                   session: HCUnavailableRuntime(), registrar: { identity, _ in calls.append(identity) })
        XCTAssertEqual(calls.count, 1, "creation registers")
        panel.publish(.live(HCTerminalRecord(key: key, state: .running)))
        XCTAssertEqual(calls.count, 2, "the live key registers once")
        // Inventory republishes an unchanged running terminal on every snapshot.
        panel.publish(.live(HCTerminalRecord(key: key, state: .running, title: "busy")))
        panel.publish(.live(HCTerminalRecord(key: key, state: .running, status: "working")))
        XCTAssertEqual(calls.count, 2, "an unchanged identity is not registered again")
        panel.publish(.live(HCTerminalRecord(key: replacementKey, state: .running)))
        XCTAssertEqual(calls.count, 3, "a changed key registers exactly once")
        XCTAssertEqual(calls.last??.key, replacementKey)
        panel.detachSurface()
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.last.map { $0 == nil }, true, "disposal registers nil")
    }

    func testARetiredRuntimesDisposalLeavesItsReplacementRegistered() {
        let panelID = UUID()
        let retired = runtime(HCPanelIdentity(panelID: panelID, key: key, origin: .restored))
        let replacement = runtime(HCPanelIdentity(panelID: panelID, key: replacementKey, origin: .restored))
        defer { replacement.detachSurface() }
        retired.detachSurface()
        XCTAssertEqual(registered(panelID)?.key, replacementKey)
    }
}
