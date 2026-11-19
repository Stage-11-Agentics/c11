import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCLifecycleResolverTests: XCTestCase {
    private let revision = HCRevision(connectionGeneration: 2, sequence: 10)
    private let process = HCProcessIdentity(pid: 50, startTimeMicroseconds: 200)

    private func build() -> HCBuildIdentity {
        HCBuildIdentity(pin: .current, executablePath: "/owned/hc", fileIdentity: HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 0),
                        process: process, coreID: "core", protocolGeneration: 1)
    }
    private func snapshot(_ records: [HCTerminalKey: HCTerminalRecord] = [:]) -> HCInventorySnapshot {
        HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: records, buildIdentity: build())
    }
    private func pending(_ identity: HCPanelIdentity) -> HCStoredCreation {
        HCStoredCreation(panelID: identity.panelID, creationID: UUID(), coreID: "core",
            coreProcess: HCProcessIdentity(pid: 49, startTimeMicroseconds: 100), phase: .uncertain, key: nil, endEvidence: nil, initialInput: .none)
    }

    /// C11H-313: a creation recorded as never run answers for itself, even with
    /// no ready inventory. An identity still carrying an earlier terminal's key
    /// is answered only when the record names that key as the ended predecessor
    /// it replaced: a rejection never vouches for another terminal.
    func testANeverRunCreationAnswersForItselfAndOnlyItsRecordedPredecessorsKey() {
        let panel = UUID(), creation = UUID()
        let old = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
        let other = HCTerminalKey(owningCoreID: "core", localAddress: "t2")
        let rejected = HCEndEvidence(id: UUID(), creationID: creation, revision: revision, kind: .createRejected)
        let record = HCStoredCreation(panelID: panel, creationID: creation, coreID: "core", coreProcess: process,
            phase: .ended, key: nil, endEvidence: rejected, initialInput: .none, predecessorKey: old)
        let catchingUp = HCInventorySnapshot(readiness: .pending(.inventoryPending), revision: revision)
        for identity in [HCPanelIdentity(panelID: panel, creationID: creation),
                         HCPanelIdentity(panelID: panel, key: old, creationID: creation)] {
            guard case .ended(let proof) = HCLifecycleResolver.resolve(identity, snapshot: catchingUp, intent: record) else {
                return XCTFail("a never-run creation needs no inventory: \(identity)")
            }
            XCTAssertEqual(proof.creationID, creation)
        }
        let foreignKey = HCPanelIdentity(panelID: panel, key: other, creationID: creation)
        XCTAssertNil(HCLifecycleResolver.neverRan(foreignKey, intent: record), "a rejection never vouches for another terminal")
        guard case .unresolved(_, .inventoryPending) = HCLifecycleResolver.resolve(foreignKey, snapshot: catchingUp, intent: record) else {
            return XCTFail("an unvouched key waits for the inventory")
        }
        XCTAssertNil(HCLifecycleResolver.neverRan(HCPanelIdentity(panelID: panel, creationID: UUID()), intent: record),
                     "a record speaks for its own creation only")
    }

    func testEmptyReadySnapshotDoesNotSettleUnobservedRunWithoutExitProof() {
        let identity = HCPanelIdentity(panelID: UUID())
        guard case .unresolved(_, .creationPending) = HCLifecycleResolver.resolve(identity, snapshot: snapshot(), intent: pending(identity)) else {
            return XCTFail("A label can still be inserted after the holder handshake")
        }
    }

    func testOnlyMatchingPostAdoptionProofSettlesUnknownAttempt() {
        let identity = HCPanelIdentity(panelID: UUID())
        let intent = pending(identity)
        let proof = HCAdoptionProof(retiredProcess: intent.coreProcess, servingProcess: process, revision: revision, coreID: "core")
        guard case .ended(let end) = HCLifecycleResolver.resolve(identity, snapshot: snapshot(), intent: intent, adoption: proof) else { return XCTFail("Confirmed absence must settle") }
        XCTAssertEqual(end.kind, .postAdoptionAbsence)
        let stale = HCAdoptionProof(retiredProcess: HCProcessIdentity(pid: 999, startTimeMicroseconds: 1), servingProcess: process, revision: revision, coreID: "core")
        guard case .unresolved = HCLifecycleResolver.resolve(identity, snapshot: snapshot(), intent: intent, adoption: stale) else { return XCTFail("Wrong incarnation authorized replacement") }
    }

    func testRestoredNewResolvesExistingAttemptBeforeCreatingAndReplacementDropsOldKey() {
        let oldKey = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
        let identity = HCPanelIdentity(panelID: UUID(), key: oldKey, origin: .restored)
        let intent = pending(identity)
        let newKey = HCTerminalKey(owningCoreID: "core", localAddress: "t2")
        let record = HCTerminalRecord(key: newKey, state: .running,
            labels: ["c11.panel": identity.panelID.uuidString, "c11.creation": intent.creationID.uuidString], pid: 100)
        guard case .live(let bound) = HCLifecycleResolver.resolve(identity, snapshot: snapshot([newKey: record]), intent: intent) else {
            return XCTFail("The active attempt must bind, not the ended prior key")
        }
        XCTAssertEqual(bound.key, newKey)
        let keyless = HCPanelIdentity(panelID: identity.panelID, origin: .restored)
        guard case .live = HCLifecycleResolver.resolve(keyless, snapshot: snapshot([newKey: record]), intent: nil) else { return XCTFail("Saved-new restore duplicated a labeled terminal") }
    }

    func testRemoteMirrorAbsenceAndUnreadyInventoryNeverEndIdentity() {
        let remote = HCTerminalKey(owningCoreID: "remote-core", localAddress: "t1")
        let identity = HCPanelIdentity(panelID: UUID(), key: remote)
        guard case .unresolved = HCLifecycleResolver.resolve(identity, snapshot: snapshot(), intent: nil) else { return XCTFail("Remote mirror loss is not death") }
        let unready = HCInventorySnapshot(readiness: .pending(.connectionLost), revision: revision)
        guard case .unresolved(_, .connectionLost) = HCLifecycleResolver.resolve(identity, snapshot: unready, intent: nil) else { return XCTFail("Unavailable inventory is not absence") }
    }

    func testObservedLocalRemovalSettlesAndFinishedReasonIsPreserved() {
        let key = HCTerminalKey(owningCoreID: "core", localAddress: "t1")
        let identity = HCPanelIdentity(panelID: UUID(), key: key)
        guard case .ended(let removed) = HCLifecycleResolver.resolve(identity, snapshot: snapshot(), intent: nil) else { return XCTFail("Observed local absence must settle") }
        XCTAssertEqual(removed.kind, .observedRemoval)
        let finished = HCTerminalRecord(key: key, state: .finished, endReason: "holder_lost")
        guard case .ended(let end) = HCLifecycleResolver.resolve(identity, snapshot: snapshot([key: finished]), intent: nil) else { return XCTFail("Expected finished") }
        XCTAssertEqual(end.hcReason, "holder_lost")
    }

    // MARK: C11H-359 (M3): a label match counts only on the panel's own placement

    private func linked(_ address: String, panel: UUID, creation: UUID? = nil, machine: String = "lyra",
                        core: String = "lyra-core") -> HCTerminalRecord {
        var labels = ["c11.panel": panel.uuidString]
        labels["c11.creation"] = creation?.uuidString
        return HCTerminalRecord(key: HCTerminalKey(owningCoreID: core, localAddress: address), state: .running,
            labels: labels, machineName: machine, machineAvailability: .connected, pid: 77)
    }

    /// A linked machine labels one of its own terminals with a local panel's
    /// UUID (and, for a creation, its creation id). A local panel never
    /// resolves to it: restored keyless, fresh, and creation-labelled
    /// identities all stay new or pending, while the panel's own local
    /// terminal still resolves live.
    func testALinkedMachinesTerminalLabelledWithALocalPanelNeverBindsIt() {
        let panel = UUID(), creation = UUID()
        let planted = linked("t7", panel: panel, creation: creation)
        let plantedSnapshot = snapshot([planted.key: planted])
        for identity in [HCPanelIdentity(panelID: panel, origin: .restored), HCPanelIdentity(panelID: panel, origin: .fresh)] {
            guard case .new = HCLifecycleResolver.resolve(identity, snapshot: plantedSnapshot, intent: nil) else {
                return XCTFail("\(identity.origin): a planted label must not bind a local panel")
            }
        }
        let retargeted = HCPanelIdentity(panelID: panel, creationID: creation, origin: .restored)
        guard case .unresolved(_, .creationPending) = HCLifecycleResolver.resolve(retargeted, snapshot: plantedSnapshot, intent: nil) else {
            return XCTFail("a creation label from another machine is not this creation's terminal")
        }
        let own = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "core", localAddress: "t1"), state: .running,
            labels: ["c11.panel": panel.uuidString], pid: 9)
        guard case .live(let record) = HCLifecycleResolver.resolve(HCPanelIdentity(panelID: panel, origin: .restored),
                snapshot: snapshot([planted.key: planted, own.key: own]), intent: nil) else {
            return XCTFail("the panel's own local terminal still resolves")
        }
        XCTAssertEqual(record.key, own.key)
        // A local record another core owns (a stale core's mirror) is not this Mac's either.
        let stale = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "other-core", localAddress: "t2"), state: .running,
            labels: ["c11.panel": panel.uuidString], pid: 10)
        guard case .new = HCLifecycleResolver.resolve(HCPanelIdentity(panelID: panel, origin: .restored),
                snapshot: snapshot([stale.key: stale]), intent: nil) else {
            return XCTFail("a local label match needs a key this Mac's core owns")
        }
    }

    /// A remote panel matches by label only on its own machine. Its intent's
    /// machine is the authority; with no intent, the placement it was made for.
    func testARemotePanelMatchesByLabelOnlyOnItsOwnMachine() {
        let panel = UUID(), creation = UUID()
        let elsewhere = linked("t4", panel: panel, creation: creation, machine: "studio", core: "studio-core")
        let home = linked("t3", panel: panel, creation: creation)
        let intent = HCStoredCreation(panelID: panel, creationID: creation, coreID: "core", coreProcess: process,
            phase: .transmitted, key: nil, endEvidence: nil, initialInput: .none, machine: "lyra")
        let identity = HCPanelIdentity(panelID: panel, creationID: creation, origin: .fresh)
        guard case .live(let bound) = HCLifecycleResolver.resolve(identity,
                snapshot: snapshot([elsewhere.key: elsewhere, home.key: home]), intent: intent) else {
            return XCTFail("the creation's own machine holds its terminal")
        }
        XCTAssertEqual(bound.key, home.key)
        guard case .unresolved(_, .creationPending) = HCLifecycleResolver.resolve(identity,
                snapshot: snapshot([elsewhere.key: elsewhere]), intent: intent) else {
            return XCTFail("another machine's terminal is never this creation's")
        }
        let keyless = HCPanelIdentity(panelID: panel, origin: .restored)
        guard case .live(let restored) = HCLifecycleResolver.resolve(keyless, snapshot: snapshot([home.key: home]),
                intent: nil, placement: .machine("lyra")) else {
            return XCTFail("a restored remote panel finds its terminal on its machine")
        }
        XCTAssertEqual(restored.key, home.key)
        guard case .new = HCLifecycleResolver.resolve(keyless, snapshot: snapshot([elsewhere.key: elsewhere]),
                intent: nil, placement: .machine("lyra")) else {
            return XCTFail("nor on another")
        }
    }
}
