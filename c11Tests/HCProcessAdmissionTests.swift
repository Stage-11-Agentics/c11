import XCTest
import Darwin
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCProcessAdmissionTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "own", localAddress: "t1")
    private let root = HCProcessIdentity(pid: 100, startTimeMicroseconds: 10)
    private let peer = HCProcessIdentity(pid: 101, startTimeMicroseconds: 20)
    private let panel = UUID()

    private func snapshot(_ records: [HCTerminalRecord] = [], generation: UInt64 = 1,
                          sequence: UInt64 = 1, ready: Bool = true) -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: generation, sequence: sequence)
        let build = HCBuildIdentity(pin: .current, executablePath: "/owned/hc", fileIdentity:
            HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 0),
            process: HCProcessIdentity(pid: 50, startTimeMicroseconds: 1), coreID: "own", protocolGeneration: 1)
        return HCInventorySnapshot(readiness: ready ? .ready(revision) : .pending(.inventoryPending),
            revision: revision, records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }),
            buildIdentity: build, panelBindings: [panel: key])
    }

    private func record(key: HCTerminalKey? = nil, state: HCTerminalState = .running,
                        machine: HCMachineAvailability = .local, pid: Int32? = 100,
                        identity: HCProcessIdentity? = nil) -> HCTerminalRecord {
        HCTerminalRecord(key: key ?? self.key, state: state, machineAvailability: machine,
                         pid: pid, localProcessIdentity: identity)
    }

    private func facts() -> Facts {
        Facts([100: HCLocalProcess(identity: root, parentPID: 50, uid: getuid()),
               101: HCLocalProcess(identity: peer, parentPID: 100, uid: getuid())])
    }

    private func engine(_ source: Inventory, _ facts: Facts, _ clock: Clock = Clock()) -> HCAdmissionEngine {
        HCAdmissionEngine(inventory: source, process: { facts.read($0) }, now: { clock.read() },
                          executable: { "/fake/p\($0)" })
    }

    func testCaptainCallerBindsExactPanelAndCurrentLocalRoot() {
        let inventory = snapshot([record(identity: root)])
        let admitted = HCVerifiedTerminal(key: key, rootIdentity: root, peerIdentity: peer)
        let graph = facts()
        XCTAssertTrue(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: peer.pid,
                                                  inventory: inventory, admitted: admitted, process: graph.read))
        XCTAssertFalse(MailboxCaptainCaller.verify(panel: UUID(), key: key, peerPID: peer.pid,
                                                   inventory: inventory, admitted: admitted, process: graph.read))
        XCTAssertFalse(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: peer.pid,
                                                   inventory: snapshot([record(identity: root)], ready: false), admitted: admitted, process: graph.read))
        XCTAssertFalse(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: peer.pid,
                                                   inventory: snapshot([record(machine: .connected, identity: root)]), admitted: admitted, process: graph.read))
        let stale = HCInventorySnapshot(readiness: .ready(inventory.revision),
            revision: HCRevision(connectionGeneration: 2, sequence: 1), records: inventory.records,
            buildIdentity: inventory.buildIdentity, panelBindings: inventory.panelBindings)
        XCTAssertFalse(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: peer.pid,
                                                   inventory: stale, admitted: admitted, process: graph.read))
    }

    func testCaptainCallerRefusesPIDReuseAndAncestryChanges() {
        let inventory = snapshot([record()])
        let admitted = HCVerifiedTerminal(key: key, rootIdentity: root, peerIdentity: peer)
        let graph = facts()
        let replacementRoot = HCLocalProcess(identity: .init(pid: root.pid, startTimeMicroseconds: 11),
                                              parentPID: 50, uid: getuid())
        XCTAssertFalse(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: peer.pid,
                                                   inventory: inventory, admitted: admitted) { pid in
            pid == self.root.pid ? replacementRoot : graph.read(pid)
        })
        var peerReads = 0
        XCTAssertFalse(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: peer.pid,
                                                   inventory: inventory, admitted: admitted) { pid in
            if pid == self.peer.pid {
                peerReads += 1
                if peerReads > 2 { return nil }
            }
            return graph.read(pid)
        })
        XCTAssertFalse(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: peer.pid,
                                                   inventory: inventory, admitted: admitted) { pid in
            if pid == self.peer.pid {
                return HCLocalProcess(identity: self.peer, parentPID: 999, uid: getuid())
            }
            return graph.read(pid)
        })
    }

    func testPermissiveSocketPolicyStillCarriesVerifiedCaptainCallerFacts() async {
        let inventory = snapshot([record()])
        let source = Inventory(inventory)
        let graph = facts()
        let check = await engine(source, graph).check(peer: peer, requiresOwnership: false)
        XCTAssertEqual(check.decision, .admitted)
        XCTAssertEqual(check.verifiedTerminal, HCVerifiedTerminal(key: key, rootIdentity: root, peerIdentity: peer))
        XCTAssertTrue(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: peer.pid,
                                                  inventory: check.inventory, admitted: check.verifiedTerminal,
                                                  process: graph.read))
        let unrelated = HCProcessIdentity(pid: 900, startTimeMicroseconds: 30)
        graph.set(900, HCLocalProcess(identity: unrelated, parentPID: 1, uid: getuid()))
        let unverified = await engine(source, graph).check(peer: unrelated, requiresOwnership: false)
        XCTAssertEqual(unverified.decision, .admitted, "capturing facts must not narrow permissive socket access")
        XCTAssertNil(unverified.verifiedTerminal)
        XCTAssertFalse(MailboxCaptainCaller.verify(panel: panel, key: key, peerPID: unrelated.pid,
                                                   inventory: unverified.inventory, admitted: unverified.verifiedTerminal,
                                                   process: graph.read))
    }

    private func decision(_ engine: HCAdmissionEngine) async -> HCAdmissionDecision {
        await engine.check(peer: peer).decision
    }

    private func drainRefresh(_ engine: HCAdmissionEngine, _ source: Inventory) async throws {
        // Synchronize via observed completion, not a guessed race-winning sleep.
        for _ in 0..<100 {
            if await source.count() > 0 { await Task.yield(); return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("refresh did not run")
    }

    func testLiveUnlabeledTerminalAndDescendantNeedNoSurface() async {
        let source = Inventory(snapshot([record()]))
        let gate = engine(source, facts())
        let child = await decision(gate)
        let direct = await gate.check(peer: root).decision
        XCTAssertEqual(child, .admitted)
        XCTAssertEqual(direct, .admitted)
        let count = await source.count()
        XCTAssertEqual(count, 0)
    }

    func testBirthPendingThenPIDArrivesUsesOneRefresh() async throws {
        let source = Inventory(snapshot([record(state: .starting, pid: nil)]))
        let gate = engine(source, facts())
        let first = await decision(gate)
        XCTAssertEqual(first, .pending)
        try await drainRefresh(gate, source)
        let stillPending = await decision(gate)
        XCTAssertEqual(stillPending, .pending)
        await source.set(snapshot([record()], sequence: 2))
        let born = await decision(gate)
        XCTAssertEqual(born, .admitted)
        let count = await source.count()
        XCTAssertEqual(count, 1)
    }

    func testPendingInventoryNeverUsesStalePositiveRecords() async throws {
        let source = Inventory(snapshot([record()]))
        let gate = engine(source, facts())
        let before = await decision(gate)
        XCTAssertEqual(before, .admitted)
        await source.set(snapshot([record()], sequence: 2, ready: false))
        let after = await decision(gate)
        XCTAssertEqual(after, .pending)
        try await drainRefresh(gate, source)
        let count = await source.count()
        XCTAssertEqual(count, 1)
    }

    func testForeignAndRemoteAndFinishedNeverAuthorizeLocalPID() async throws {
        for value in [record(key: HCTerminalKey(owningCoreID: "foreign", localAddress: "t1")),
                      record(machine: .connected), record(state: .finished)] {
            let source = Inventory(snapshot([value]))
            let gate = engine(source, facts())
            let initial = await decision(gate)
            XCTAssertEqual(initial, .pending)
            try await drainRefresh(gate, source)
            var result = await decision(gate)
            for _ in 0..<100 where result == .pending { await Task.yield(); result = await decision(gate) }
            XCTAssertEqual(result, .notOwned)
        }
    }

    /// hc 0.1.16: `/usr/bin/login -flp <user> /bin/bash ... exec -l /bin/zsh`.
    /// The recorded pid is login, setuid root: euid 0, real uid ours.
    private func loginRootedFacts(rootRealUID: UInt32) -> Facts {
        let shell = HCProcessIdentity(pid: 110, startTimeMicroseconds: 12)
        return Facts([100: HCLocalProcess(identity: root, parentPID: 50, uid: 0, realUID: rootRealUID),
                      110: HCLocalProcess(identity: shell, parentPID: 100, uid: getuid()),
                      101: HCLocalProcess(identity: peer, parentPID: 110, uid: getuid())])
    }

    private func settledDecision(_ gate: HCAdmissionEngine, _ source: Inventory) async throws -> HCAdmissionDecision {
        var result = await decision(gate)
        guard result != .admitted else { return result }
        try await drainRefresh(gate, source)
        for _ in 0..<100 where result == .pending { await Task.yield(); result = await decision(gate) }
        return result
    }

    func testASetuidRootLoginTerminalRootStartedByUsAdmitsItsShellsDescendants() async throws {
        let source = Inventory(snapshot([record()]))
        let result = try await settledDecision(engine(source, loginRootedFacts(rootRealUID: getuid())), source)
        XCTAssertEqual(result, .admitted)
    }

    func testASetuidRootTerminalRootWhoseRealUIDIsNotOursIsRefused() async throws {
        let source = Inventory(snapshot([record()]))
        let result = try await settledDecision(engine(source, loginRootedFacts(rootRealUID: getuid() &+ 1)), source)
        XCTAssertEqual(result, .notOwned)
    }

    func testARootOwnedProcessBetweenTheCallerAndItsTerminalRootIsRefused() async throws {
        // The intermediate is root-effective with our real uid, exactly like
        // login, but it is not the process hc recorded for the terminal.
        let source = Inventory(snapshot([record()]))
        let processes = loginRootedFacts(rootRealUID: getuid())
        processes.set(110, HCLocalProcess(identity: HCProcessIdentity(pid: 110, startTimeMicroseconds: 12),
                                          parentPID: 100, uid: 0, realUID: getuid()))
        let result = try await settledDecision(engine(source, processes), source)
        XCTAssertEqual(result, .notOwned)
    }

    func testARootOwnedCallerIsRefusedEvenUnderAnOwnedTerminal() async throws {
        let source = Inventory(snapshot([record()]))
        let processes = facts()
        processes.set(101, HCLocalProcess(identity: peer, parentPID: 100, uid: 0, realUID: getuid()))
        let result = try await settledDecision(engine(source, processes), source)
        XCTAssertEqual(result, .notOwned)
    }

    func testARootOwnedProcessThatIsNotAnOwnTerminalRootIsNeverATerminalRoot() async throws {
        // The same setuid-root login, but recorded by a foreign core: its
        // effective uid 0 is not excused, and the walk is refused.
        let source = Inventory(snapshot([record(key: HCTerminalKey(owningCoreID: "foreign", localAddress: "t1"))]))
        let result = try await settledDecision(engine(source, loginRootedFacts(rootRealUID: getuid())), source)
        XCTAssertEqual(result, .notOwned)
    }

    // MARK: refusal reasons: the caller's own chain only

    /// Another live panel of the same core, which no reason may ever name.
    private let otherKey = HCTerminalKey(owningCoreID: "own", localAddress: "t7q")
    private func withOtherPanel(_ records: [HCTerminalRecord]) -> [HCTerminalRecord] {
        records + [record(key: otherKey, pid: 9_907)]
    }

    private func settledCheck(_ gate: HCAdmissionEngine, _ source: Inventory, peer: HCProcessIdentity? = nil)
        async throws -> HCAdmissionCheck {
        let peer = peer ?? self.peer
        var result = await gate.check(peer: peer)
        guard result.decision != .admitted else { return result }
        try await drainRefresh(gate, source)
        for _ in 0..<100 where result.decision == .pending { await Task.yield(); result = await gate.check(peer: peer) }
        return result
    }

    private func assertReason(_ check: HCAdmissionCheck, _ expected: HCAdmissionStop, _ text: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(check.stop, expected, file: file, line: line)
        XCTAssertEqual(expected.text, text, file: file, line: line)
        let json = try XCTUnwrap(check.rejectionResponse(command: "{\"id\":3,\"method\":\"system.identify\",\"params\":{}}", pid: 101))
        let error = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, check.decision.rawValue, file: file, line: line)
        XCTAssertTrue((error["message"] as? String ?? "").hasSuffix("(\(text))"), file: file, line: line)
        XCTAssertEqual((error["data"] as? [String: Any])?["reason"] as? String, text, file: file, line: line)
        let plain = try XCTUnwrap(check.rejectionResponse(command: "identify", pid: 101))
        XCTAssertTrue(plain.hasSuffix("(\(text))"), file: file, line: line)
        for response in [json, plain] {
            for foreign in ["9907", "t7q", "/fake/p9907"] {
                XCTAssertFalse(response.contains(foreign), "a reason names another panel: \(response)", file: file, line: line)
            }
        }
    }

    func testRefusalAtASetuidLoginRootWithAnotherRealUIDNamesThatStep() async throws {
        let source = Inventory(snapshot(withOtherPanel([record()])))
        let check = try await settledCheck(engine(source, loginRootedFacts(rootRealUID: getuid() &+ 1)), source)
        XCTAssertEqual(check.decision, .notOwned)
        try assertReason(check, .walk(.terminalRootUID(euid: 0, ruid: getuid() &+ 1, want: getuid()), pid: 100, depth: 2, exe: "/fake/p100"),
            "stop=terminal_root_uid pid=100 exe=\"/fake/p100\" depth=2 euid=0 ruid=\(getuid() &+ 1) want=\(getuid())")
    }

    func testRefusalAtARootOwnedIntermediateNamesItsEffectiveUID() async throws {
        // This morning's refusal on the laptop had this shape: the walk died at login, euid 0.
        let source = Inventory(snapshot(withOtherPanel([record()])))
        let processes = loginRootedFacts(rootRealUID: getuid())
        processes.set(110, HCLocalProcess(identity: HCProcessIdentity(pid: 110, startTimeMicroseconds: 12),
                                          parentPID: 100, uid: 0, realUID: getuid()))
        let check = try await settledCheck(engine(source, processes), source)
        XCTAssertEqual(check.decision, .notOwned)
        try assertReason(check, .walk(.effectiveUID(euid: 0, want: getuid()), pid: 110, depth: 1, exe: "/fake/p110"),
            "stop=euid pid=110 exe=\"/fake/p110\" depth=1 euid=0 want=\(getuid())")
    }

    func testRefusalWithNoTerminalRootInTheChainNamesTheTopOfTheCallersChain() async throws {
        let source = Inventory(snapshot(withOtherPanel([])))
        let processes = facts()
        processes.set(100, HCLocalProcess(identity: root, parentPID: 1, uid: getuid()))
        let check = try await settledCheck(engine(source, processes), source)
        XCTAssertEqual(check.decision, .notOwned)
        try assertReason(check, .walk(.noTerminalRoot, pid: 100, depth: 1, exe: "/fake/p100"),
            "stop=no_terminal_root pid=100 exe=\"/fake/p100\" depth=1")
    }

    func testRefusalAtAnAncestorStartedAfterItsChildNamesTheStartTime() async throws {
        let source = Inventory(snapshot(withOtherPanel([record()])))
        let processes = facts()
        processes.set(100, HCLocalProcess(identity: HCProcessIdentity(pid: 100, startTimeMicroseconds: 30),
                                          parentPID: 50, uid: getuid()))
        let check = try await settledCheck(engine(source, processes), source)
        XCTAssertEqual(check.decision, .notOwned)
        try assertReason(check, .walk(.startedAfterChild, pid: 100, depth: 1, exe: "/fake/p100"),
            "stop=started_after_child pid=100 exe=\"/fake/p100\" depth=1")
    }

    func testRefusalWhenAnAncestorIsGoneNamesThatPID() async throws {
        let source = Inventory(snapshot(withOtherPanel([])))
        let check = try await settledCheck(engine(source, facts()), source)
        XCTAssertEqual(check.decision, .notOwned)
        try assertReason(check, .walk(.gone, pid: 50, depth: 2, exe: "/fake/p50"),
            "stop=process_gone pid=50 exe=\"/fake/p50\" depth=2")
    }

    func testRefusalWhenTheCallerItselfChangedNamesOnlyItsPID() async throws {
        let source = Inventory(snapshot(withOtherPanel([record()])))
        let stale = HCProcessIdentity(pid: 101, startTimeMicroseconds: 19)
        let check = try await settledCheck(engine(source, facts()), source, peer: stale)
        XCTAssertEqual(check.decision, .notOwned)
        try assertReason(check, .callerChanged(pid: 101), "stop=caller_changed pid=101")
    }

    func testEveryPendingHoldSaysWhyWithoutNamingAnotherPanel() async throws {
        let unknown = Inventory(snapshot(withOtherPanel([record()])))
        let none = await engine(unknown, facts()).check(peer: nil)
        try assertReason(none, .callerUnknown, "stop=caller_identity_unknown")

        let notReady = Inventory(snapshot(withOtherPanel([record()]), ready: false))
        let held = await engine(notReady, facts()).check(peer: peer)
        try assertReason(held, .inventoryNotReady, "stop=inventory_not_ready")

        let birth = Inventory(snapshot(withOtherPanel([])))
        let first = await engine(birth, facts()).check(peer: peer)
        try assertReason(first, .birthRefreshPending, "stop=birth_refresh_pending")

        let starting = Inventory(snapshot(withOtherPanel([record(key: HCTerminalKey(owningCoreID: "own", localAddress: "t2"),
                                                                 state: .starting, pid: nil)])))
        let startingCheck = try await settledCheck(engine(starting, facts()), starting)
        try assertReason(startingCheck, .terminalStarting, "stop=own_terminal_starting")

        let service = HCProcessAdmission()
        let peer = peer
        let uninstalled = await Task.detached { service.checkOnSocketWorker(peer: peer, requiresOwnership: true) }.value
        try assertReason(uninstalled, .backendNotInstalled, "stop=backend_not_installed")

        let slow = HCProcessAdmission()
        slow.install(inventory: Inventory(snapshot([record()]), delay: 500_000_000))
        let timedOut = await Task.detached { slow.checkOnSocketWorker(peer: peer, requiresOwnership: true) }.value
        try assertReason(timedOut, .inventoryTimeout, "stop=inventory_timeout budget_ms=50")
    }

    func testAnAdmittedCallerCarriesNoReason() async throws {
        let source = Inventory(snapshot([record()]))
        let check = await engine(source, facts()).check(peer: peer)
        XCTAssertEqual(check.decision, .admitted)
        XCTAssertNil(check.stop)
        XCTAssertEqual(check.verifiedTerminal, HCVerifiedTerminal(key: key, rootIdentity: root, peerIdentity: peer))
    }

    func testPIDReuseCannotBorrowAnAdmittedRoot() async throws {
        let source = Inventory(snapshot([record()]))
        let processes = facts()
        let gate = engine(source, processes)
        let initial = await decision(gate)
        XCTAssertEqual(initial, .admitted)
        processes.set(100, HCLocalProcess(identity: HCProcessIdentity(pid: 100, startTimeMicroseconds: 15),
                                        parentPID: 50, uid: getuid()))
        let reused = await decision(gate)
        XCTAssertNotEqual(reused, .admitted)
    }

    func testReplacedProcessAndReconnectUseCurrentGeneration() async throws {
        let source = Inventory(snapshot([record()]))
        let processes = facts()
        let gate = engine(source, processes)
        let initial = await decision(gate)
        XCTAssertEqual(initial, .admitted)
        await source.set(snapshot([], generation: 2, ready: false))
        let pending = await decision(gate)
        XCTAssertEqual(pending, .pending)
        let newRoot = HCProcessIdentity(pid: 102, startTimeMicroseconds: 15)
        processes.set(102, HCLocalProcess(identity: newRoot, parentPID: 50, uid: getuid()))
        processes.set(101, HCLocalProcess(identity: peer, parentPID: 102, uid: getuid()))
        await source.set(snapshot([record(pid: 102)], generation: 2, sequence: 2))
        let replaced = await decision(gate)
        XCTAssertEqual(replaced, .admitted)
    }

    func testOwnRefreshReadinessRevocationDoesNotStartSecondBirthRefresh() async throws {
        let source = DeferredInventory(snapshot())
        let processes = facts()
        let gate = HCAdmissionEngine(inventory: source, process: { processes.read($0) })
        let first = await decision(gate)
        XCTAssertEqual(first, .pending)
        try await source.waitForRefreshes(1)
        // HCLiveInventorySource revokes readiness while its one authoritative
        // refresh is running, retaining the same revision until it completes.
        await source.set(snapshot(ready: false))
        let refreshing = await decision(gate)
        XCTAssertEqual(refreshing, .pending)
        for _ in 0..<20 { await Task.yield() }
        let calls = await source.refreshCount()
        XCTAssertEqual(calls, 1, "our refresh must not recursively request another refresh")
        await source.releaseAll(snapshot())
    }

    func testReconnectInvalidatesAnInflightRefreshFromPreviousGeneration() async throws {
        let source = DeferredInventory(snapshot())
        let processes = facts()
        let gate = HCAdmissionEngine(inventory: source, process: { processes.read($0) })
        let first = await decision(gate)
        XCTAssertEqual(first, .pending)
        try await source.waitForRefreshes(1)
        await source.set(snapshot(generation: 2, sequence: 2, ready: false))
        let gap = await decision(gate)
        XCTAssertEqual(gap, .pending)
        try await source.waitForRefreshes(2)
        // The old connection completes after reconnect. Its result cannot
        // certify absence for the new connection's birth attempt.
        await source.release(0, snapshot())
        await source.set(snapshot(generation: 2, sequence: 3))
        for _ in 0..<20 { await Task.yield() }
        let afterOldReply = await decision(gate)
        XCTAssertEqual(afterOldReply, .pending)
        await source.release(1, snapshot(generation: 2, sequence: 3))
        var final = await decision(gate)
        for _ in 0..<100 where final == .pending { await Task.yield(); final = await decision(gate) }
        XCTAssertEqual(final, .notOwned)
    }

    func testCompletedRefreshNeverAuthorizesAbsenceWhileInventoryIsPending() async throws {
        let source = DeferredInventory(snapshot())
        let processes = facts()
        let gate = HCAdmissionEngine(inventory: source, process: { processes.read($0) })
        _ = await decision(gate)
        try await source.waitForRefreshes(1)
        await source.release(0, snapshot())
        var before = await decision(gate)
        for _ in 0..<100 where before == .pending { await Task.yield(); before = await decision(gate) }
        XCTAssertEqual(before, .notOwned)
        await source.set(snapshot(sequence: 2, ready: false))
        let gap = await decision(gate)
        XCTAssertEqual(gap, .pending)
        let calls = await source.refreshCount()
        XCTAssertEqual(calls, 1)
        // The source replaces gaps itself. Until this new authoritative ready
        // snapshot is published, no cached absence may refuse the caller.
        await source.set(snapshot(sequence: 3))
        let after = await decision(gate)
        XCTAssertEqual(after, .notOwned)
    }

    func testUnavailableRefreshRemainsRetryableAfterBirthWindow() async throws {
        let source = Inventory(snapshot(ready: false))
        let clock = Clock()
        let gate = engine(source, facts(), clock)
        let initial = await decision(gate)
        XCTAssertEqual(initial, .pending)
        try await drainRefresh(gate, source)
        clock.set(3)
        let expired = await decision(gate)
        XCTAssertEqual(expired, .pending)
    }

    func testCaptureLivenessUsesInventoryAndRetainsUnresolvedIdentity() {
        let identity = HCPanelIdentity(panelID: panel, key: key)
        XCTAssertEqual(HCProcessAdmission.captureLiveness(identity: identity, panelID: panel,
            inventory: snapshot([record()])), .live)
        XCTAssertEqual(HCProcessAdmission.captureLiveness(identity: identity, panelID: panel,
            inventory: snapshot([record(state: .finished)])), .ended)
        XCTAssertEqual(HCProcessAdmission.captureLiveness(identity: identity, panelID: panel,
            inventory: snapshot([record()], ready: false)), .pending)
        XCTAssertEqual(HCProcessAdmission.captureLiveness(identity: identity, panelID: panel,
            inventory: snapshot()), .pending)
        XCTAssertEqual(HCProcessAdmission.captureLiveness(identity: HCPanelIdentity(panelID: panel, persistence: .nonpersistent),
            panelID: panel, inventory: nil), .unmanaged)
    }

    func testPendingResponsePreservesRequestIDAndDeclaresNoDispatch() throws {
        let response = try XCTUnwrap(HCAdmissionCheck.pending.rejectionResponse(
            command: "{\"id\":42,\"method\":\"agent.event.append\",\"params\":{}}", pid: 101))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(body["id"] as? Int, 42)
        XCTAssertEqual(body["ok"] as? Bool, false)
        let error = try XCTUnwrap(body["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "hc_inventory_pending")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["pre_dispatch"] as? Bool, true)
        XCTAssertEqual(data["retryable"] as? Bool, true)
        XCTAssertNil(HCAdmissionCheck(decision: .admitted, inventory: nil).rejectionResponse(command: "ping", pid: 101))
        XCTAssertTrue(try XCTUnwrap(HCAdmissionCheck.pending.rejectionResponse(command: "ping", pid: 101))
            .hasPrefix("ERROR: hc_inventory_pending:"))
    }

    func testUninstalledBackendIsRetryableAndDirectCallersRemainAdmitted() async {
        let service = HCProcessAdmission()
        let peer = peer
        let results = await Task.detached {
            (service.checkOnSocketWorker(peer: peer, requiresOwnership: true).decision,
             service.checkOnSocketWorker(peer: peer, requiresOwnership: false).decision)
        }.value
        XCTAssertEqual(results.0, .pending)
        XCTAssertEqual(results.1, .admitted)
    }

    func testSocketWorkerReturnsPendingBeforeSlowInventoryCompletes() async {
        let source = Inventory(snapshot([record()]), delay: 500_000_000)
        let service = HCProcessAdmission()
        service.install(inventory: source)
        let peer = peer
        let result = await Task.detached { () -> (HCAdmissionDecision, TimeInterval) in
            let start = ProcessInfo.processInfo.systemUptime
            let result = service.checkOnSocketWorker(peer: peer, requiresOwnership: true)
            return (result.decision, ProcessInfo.processInfo.systemUptime - start)
        }.value
        XCTAssertEqual(result.0, .pending)
        XCTAssertLessThan(result.1, 0.3, "slow inventory must not consume a short hook's deadline")
    }

    func testActualKernelProcessIdentity() {
        let own = HCLocalProcess.read(getpid())
        XCTAssertEqual(own?.identity.pid, getpid())
        XCTAssertEqual(own?.parentPID, getppid())
        XCTAssertEqual(own?.uid, getuid())
        XCTAssertEqual(own?.realUID, getuid())
        XCTAssertNotNil(HCLocalProcess.executable(getpid()))
        XCTAssertGreaterThan(own?.identity.startTimeMicroseconds ?? 0, 0)
    }

    func testKernelProcessFallbackAgreesWithProcInfo() {
        for pid in [getpid(), getppid()] where pid > 1 {
            XCTAssertEqual(HCLocalProcess.readKernelProcess(pid), HCLocalProcess.read(pid))
        }
        XCTAssertNil(HCLocalProcess.readKernelProcess(Int32.max))
    }

    func testAnotherUsersProcessIsStillReadWithItsUIDs() throws {
        // hc's terminal root is setuid-root login. PROC_PIDTBSDINFO refuses to read
        // another effective uid's process; the guest walk stopped there as process_gone.
        // Read-only: any root-owned process on this machine stands in for login.
        try XCTSkipIf(getuid() == 0, "needs a non-root test runner")
        let rootOwned = (2..<4096).lazy.compactMap { HCLocalProcess.readKernelProcess(Int32($0)) }.first { $0.uid == 0 }
        let other = try XCTUnwrap(rootOwned, "no root-owned process found")
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        XCTAssertNotEqual(proc_pidinfo(other.identity.pid, PROC_PIDTBSDINFO, 0, &info, size), size,
                          "PROC_PIDTBSDINFO read another uid's process; the fallback is untested here")
        let read = HCLocalProcess.read(other.identity.pid)
        XCTAssertEqual(read, other)
        XCTAssertEqual(read?.uid, 0)
        XCTAssertGreaterThan(read?.identity.startTimeMicroseconds ?? 0, 0)
    }

    // MARK: shards (C11H-77, Amendment 1): admission across the pool's merged view

    private struct Shard { let index: Int; let core: String; var ready = true; var generation: UInt64 = 1 }

    /// The pool's merged snapshot: per-shard readiness, revisions and core ids;
    /// its own revision is only a change counter, and buildIdentity is shard 1's.
    private func pool(_ records: [HCTerminalRecord], _ shards: [Shard], sequence: UInt64 = 1) -> HCInventorySnapshot {
        var readiness: [HCShardID: HCReadiness] = [:], revisions: [HCShardID: HCRevision] = [:], cores: [HCShardID: String] = [:]
        for shard in shards {
            let id = HCShardID(index: shard.index)
            let revision = HCRevision(connectionGeneration: shard.generation, sequence: sequence)
            readiness[id] = shard.ready ? .ready(revision) : .pending(.inventoryPending)
            revisions[id] = revision
            cores[id] = shard.core
        }
        let counter = HCRevision(connectionGeneration: 7, sequence: 100 + sequence)
        let build = HCBuildIdentity(pin: .current, executablePath: "/owned/hc", fileIdentity:
            HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 0),
            process: HCProcessIdentity(pid: 50, startTimeMicroseconds: 1), coreID: shards.first?.core ?? "none", protocolGeneration: 1)
        return HCInventorySnapshot(readiness: shards.allSatisfy(\.ready) ? .ready(counter) : .pending(.inventoryPending),
            revision: counter, records: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }),
            buildIdentity: build, shardReadiness: readiness, shardRevisions: revisions, shardCoreIDs: cores)
    }

    private func local(_ core: String, _ address: String = "t1", state: HCTerminalState = .running, pid: Int32? = 100) -> HCTerminalRecord {
        HCTerminalRecord(key: HCTerminalKey(owningCoreID: core, localAddress: address), state: state,
                         machineAvailability: .local, pid: pid)
    }

    private func settledShardDecision(_ source: Inventory) async throws -> HCAdmissionCheck {
        let gate = engine(source, facts())
        var result = await gate.check(peer: peer)
        guard result.decision != .admitted else { return result }
        try await drainRefresh(gate, source)
        for _ in 0..<100 where result.decision == .pending { await Task.yield(); result = await gate.check(peer: peer) }
        return result
    }

    private let s1 = Shard(index: 1, core: "core-1"), s2 = Shard(index: 2, core: "core-2")

    func testACallerOfAnyShardsTerminalIsOwnedThroughTheMergedView() async throws {
        // The caller's terminal lives in shard 2; the merged buildIdentity is shard 1's.
        let source = Inventory(pool([local("core-1", pid: 300), local("core-2")], [s1, s2]))
        let check = await engine(source, facts()).check(peer: peer)
        XCTAssertEqual(check.decision, .admitted)
        XCTAssertEqual(check.verifiedTerminal?.key, HCTerminalKey(owningCoreID: "core-2", localAddress: "t1"))
        XCTAssertEqual(check.verifiedTerminal?.rootIdentity, root)
        XCTAssertEqual(check.verifiedTerminal?.peerIdentity, peer)
        let refreshes = await source.count()
        XCTAssertEqual(refreshes, 0, "an owner needs no refresh")
    }

    func testOneUnreadyStartedShardHoldsTheCallerAndIsNamed() async throws {
        var down = s2
        down.ready = false
        let source = Inventory(pool([local("core-1", pid: 300)], [s1, down]))
        let check = try await settledShardDecision(source)
        XCTAssertEqual(check.decision, .pending)
        XCTAssertEqual(check.shard, HCShardID(index: 2))
        let text = try XCTUnwrap(check.rejectionResponse(command: "identify", pid: 101))
        XCTAssertTrue(text.contains("stop=inventory_not_ready shard=s2"), text)
    }

    func testAnUnreadyShardsTerminalNeverAdmitsItsCaller() async throws {
        var down = s2
        down.ready = false
        let source = Inventory(pool([local("core-2")], [s1, down]))
        let check = try await settledShardDecision(source)
        XCTAssertEqual(check.decision, .pending, "only a ready shard's inventory owns")
    }

    func testAMissIsPendingUntilEveryReadyShardsBirthRefreshCompletes() async throws {
        for shards in [[s1], [s1, s2]] {
            let snap = pool([local("core-1", pid: 300)], shards)
            let source = DeferredInventory(snap)
            let processes = facts()
            let gate = HCAdmissionEngine(inventory: source, process: { processes.read($0) },
                                         executable: { "/fake/p\($0)" })
            let first = await gate.check(peer: peer)
            XCTAssertEqual(first.decision, .pending, "every shard ready is never enough to refuse (\(shards.count) shard)")
            XCTAssertEqual(first.stop, .birthRefreshPending)
            try await source.waitForRefreshes(1)
            let waiting = await gate.check(peer: peer)
            XCTAssertEqual(waiting.decision, .pending, "the refresh has not completed")
            await source.release(0, snap)
            var final = await gate.check(peer: peer)
            for _ in 0..<100 where final.decision == .pending { await Task.yield(); final = await gate.check(peer: peer) }
            XCTAssertEqual(final.decision, .notOwned, "refused only after every started shard refreshed")
            XCTAssertEqual(final.stop, .walk(.gone, pid: 50, depth: 2, exe: "/fake/p50"))
        }
    }

    func testAStartingOrPIDLessTerminalInAnyShardHoldsTheCaller() async throws {
        for waiting in [local("core-2", "t2", state: .starting, pid: nil), local("core-2", "t2", state: .running, pid: nil)] {
            let source = Inventory(pool([local("core-1", pid: 300), waiting], [s1, s2]))
            let check = try await settledShardDecision(source)
            XCTAssertEqual(check.decision, .pending)
            XCTAssertEqual(check.stop, .terminalStarting)
            XCTAssertEqual(check.shard, HCShardID(index: 2))
        }
    }

    func testAForeignCoresLocalRecordNeverAdmitsAcrossShards() async throws {
        let source = Inventory(pool([local("foreign")], [s1, s2]))
        let check = try await settledShardDecision(source)
        XCTAssertEqual(check.decision, .notOwned)
    }

    func testAShardReconnectStartsANewBirthRefresh() async throws {
        let source = Inventory(pool([local("core-1", pid: 300)], [s1, s2]))
        let gate = engine(source, facts())
        _ = await gate.check(peer: peer)
        try await drainRefresh(gate, source)
        var reconnected = s2
        reconnected.generation = 2
        await source.set(pool([local("core-1", pid: 300)], [s1, reconnected], sequence: 2))
        let check = await gate.check(peer: peer)
        XCTAssertEqual(check.decision, .pending, "a refresh of shard 2's old connection proves nothing about the new one")
        var tries = 0
        while await source.count() < 2, tries < 100 { tries += 1; try await Task.sleep(nanoseconds: 1_000_000) }
        let refreshes = await source.count()
        XCTAssertEqual(refreshes, 2)
    }

    private actor Inventory: HCInventorySource {
        var value: HCInventorySnapshot
        var refreshes = 0
        let delay: UInt64
        init(_ value: HCInventorySnapshot, delay: UInt64 = 0) { self.value = value; self.delay = delay }
        func set(_ value: HCInventorySnapshot) { self.value = value }
        func snapshot() async -> HCInventorySnapshot {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return value
        }
        func refresh() -> HCInventorySnapshot { refreshes += 1; return value }
        func count() -> Int { refreshes }
        nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
            HCObservation()
        }
    }
    private actor DeferredInventory: HCInventorySource {
        var value: HCInventorySnapshot
        var waiting: [CheckedContinuation<HCInventorySnapshot, Never>?] = []
        init(_ value: HCInventorySnapshot) { self.value = value }
        func set(_ value: HCInventorySnapshot) { self.value = value }
        func snapshot() -> HCInventorySnapshot { value }
        func refresh() async -> HCInventorySnapshot {
            await withCheckedContinuation { waiting.append($0) }
        }
        func refreshCount() -> Int { waiting.count }
        func releaseAll(_ snapshot: HCInventorySnapshot) {
            for index in waiting.indices { release(index, snapshot) }
        }
        func waitForRefreshes(_ count: Int) async throws {
            for _ in 0..<100 {
                if waiting.count >= count { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTFail("refresh did not start")
        }
        func release(_ index: Int, _ snapshot: HCInventorySnapshot) {
            guard waiting.indices.contains(index) else { return }
            waiting[index]?.resume(returning: snapshot)
            waiting[index] = nil
        }
        nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
            HCObservation()
        }
    }
    private final class Facts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int32: HCLocalProcess]
        init(_ values: [Int32: HCLocalProcess]) { self.values = values }
        func read(_ pid: Int32) -> HCLocalProcess? { lock.lock(); defer { lock.unlock() }; return values[pid] }
        func set(_ pid: Int32, _ value: HCLocalProcess) { lock.lock(); values[pid] = value; lock.unlock() }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
    }
}

#if DEBUG
@MainActor
final class HCAdmissionSocketTests: XCTestCase {
    func testPendingOrdinaryRequestNeverExecutesAndNextRequestCanPass() throws {
        var checks = 0
        let result = try exchange([
            "{\"id\":1,\"method\":\"fixture.mutate\",\"params\":{}}",
            "{\"id\":2,\"method\":\"fixture.mutate\",\"params\":{}}"
        ]) {
            checks += 1
            return HCAdmissionCheck(decision: checks == 1 ? .pending : .admitted, inventory: nil)
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(result.executions, 1)
        XCTAssertEqual(result.lines.count, 2)
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(pending["id"] as? Int, 1)
        XCTAssertEqual((pending["error"] as? [String: Any])?["code"] as? String, "hc_inventory_pending")
        XCTAssertEqual(result.lines[1], "OK executed")
    }

    func testPendingStreamIsCorrelatedAndNeverEntersStreamHandler() throws {
        let result = try exchange(["{\"id\":7,\"method\":\"mailbox.native.subscribe\",\"params\":{}}"],
                                  admission: { .pending })
        XCTAssertEqual(result.executions, 0)
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(pending["id"] as? Int, 7)
        XCTAssertEqual((pending["error"] as? [String: Any])?["code"] as? String, "hc_inventory_pending")
    }

    func testPendingStreamKeepsLineConnectionAliveForRetry() throws {
        var checks = 0
        let result = try exchange([
            "{\"id\":7,\"method\":\"mailbox.native.subscribe\",\"params\":{}}",
            "{\"id\":7,\"method\":\"mailbox.native.subscribe\",\"params\":{}}",
            "{\"id\":8,\"method\":\"fixture.mutate\",\"params\":{}}"
        ]) {
            checks += 1
            return HCAdmissionCheck(decision: checks <= 2 ? .pending : .admitted, inventory: nil)
        }
        XCTAssertEqual(checks, 3, "pending streams must neither close nor check admission twice")
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.executions, 1)
        XCTAssertEqual(result.lines.last, "OK executed")
    }

    private func exchange(_ commands: [String], admission: @escaping () -> HCAdmissionCheck) throws
        -> (lines: [String], executions: Int) {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let client = descriptors[0], server = descriptors[1]
        defer { close(client) }
        let payload = Array((commands.joined(separator: "\n") + "\n").utf8)
        XCTAssertEqual(write(client, payload, payload.count), payload.count)
        XCTAssertEqual(shutdown(client, SHUT_WR), 0)
        let controller = TerminalController.makeForTesting(socketPasswordSource: .shipped)
        var executions = 0
        controller.serveClientCommandLines(socket: server, callerTTYDevice: nil,
            admission: admission, shouldContinue: { true }, execute: { _ in
                executions += 1
                return "OK executed"
            })
        close(server)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return (String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init), executions)
    }
}

#endif
