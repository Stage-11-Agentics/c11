import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCPanelConsumerInterfaceTests: XCTestCase {
    @MainActor
    func testOldGraphResolutionCannotOverwriteNewRuntimeWithSamePanelUUID() async {
        let entered = expectation(description: "old graph resolving")
        let session = HCInterfaceHeldResolution { entered.fulfill() }
        let panelID = UUID()
        let oldIdentity = HCPanelIdentity(panelID: panelID, key: HCTerminalKey(owningCoreID: "own", localAddress: "old"))
        let newIdentity = HCPanelIdentity(panelID: panelID, key: HCTerminalKey(owningCoreID: "own", localAddress: "new"))
        defer { HCPanelRestoreState.shared.remove(panelID: panelID) }
        HCPanelRestoreState.shared.seed(oldIdentity)
        let old = HCPanelSession(identity: oldIdentity, session: session)
        let resolving = Task { await old.resolveIdentity() }
        await fulfillment(of: [entered], timeout: 2)
        old.detachSurface()
        HCPanelRestoreState.shared.seed(newIdentity)
        let replacement = HCPanelSession(identity: newIdentity, session: HCUnavailableRuntime())
        replacement.publish(.live(HCTerminalRecord(key: newIdentity.key!, state: .running)))
        await session.release(.unresolved(oldIdentity, .connectionLost))
        _ = await resolving.value
        XCTAssertEqual(HCPanelRestoreState.shared.entry(for: panelID)?.identity.key, newIdentity.key)
        guard case .live = HCPanelRestoreState.shared.entry(for: panelID)?.lifecycle else {
            return XCTFail("old hidden resolution overwrote replacement")
        }
    }

    @MainActor
    func testPendingResolveCannotOverwriteNewerLifecycleOnSameRuntime() async {
        for scenario in ["live", "ended", "unresolved"] {
            let entered = expectation(description: "resolution suspended: \(scenario)")
            let session = HCInterfaceHeldResolution { entered.fulfill() }
            let identity = HCPanelIdentity(panelID: UUID(), key: HCTerminalKey(owningCoreID: "own", localAddress: "t1"))
            defer { HCPanelRestoreState.shared.remove(panelID: identity.panelID) }
            let runtime = HCPanelSession(identity: identity, session: session)
            let resolving = Task { await runtime.resolveIdentity() }
            await fulfillment(of: [entered], timeout: 2)
            let proof = HCEndEvidence(id: UUID(), key: identity.key!,
                revision: HCRevision(connectionGeneration: 1, sequence: 12), kind: .finished)
            switch scenario {
            case "live": runtime.publish(.live(HCTerminalRecord(key: identity.key!, state: .running)))
            case "ended": runtime.publish(.ended(proof))
            default: runtime.publish(.unresolved(identity, .connectionLost))
            }
            // All three publications preserve identity: only the epoch can
            // reject the stale result on this still-owned, uncancelled runtime.
            XCTAssertEqual(runtime.identity, identity)
            await session.release(.unresolved(identity, .inventoryPending))
            _ = await resolving.value
            XCTAssertEqual(runtime.identity, identity)
            let saved = HCPanelRestoreState.shared.entry(for: identity.panelID)
            XCTAssertNotNil(saved)
            for lifecycle in [runtime.lifecycle, saved?.lifecycle].compactMap({ $0 }) {
                switch scenario {
                case "live":
                    if case .live = lifecycle {} else { XCTFail("epoch-live: stale resolution replaced live observation") }
                case "ended":
                    if case .ended(let current) = lifecycle {
                        XCTAssertEqual(current, proof)
                    } else { XCTFail("epoch-ended: stale resolution erased end evidence") }
                default:
                    if case .unresolved(let current, let reason) = lifecycle {
                        XCTAssertEqual(current, identity)
                        XCTAssertEqual(reason, .connectionLost, "epoch-unresolved: stale resolution replaced newer reason")
                    } else { XCTFail("expected newer unresolved lifecycle") }
                }
            }
            runtime.detachSurface()
        }
    }

    func testSavedFreshIdentityIsRestoredAndSeedSurvivesRepeatedReads() {
        let registry = HCPanelRestoreState()
        let identity = HCPanelIdentity(panelID: UUID(), creationID: UUID(), origin: .fresh)
        registry.seed(identity)
        XCTAssertEqual(registry.entry(for: identity.panelID)?.identity.origin, .restored)
        XCTAssertEqual(registry.entry(for: identity.panelID)?.identity.creationID, identity.creationID)
        XCTAssertEqual(registry.entry(for: identity.panelID)?.identity.panelID, identity.panelID)
    }

    func testLostReplacementRetainsEndProvenanceUntilMatchingCreationReconciles() throws {
        let registry = HCPanelRestoreState()
        let oldKey = HCTerminalKey(owningCoreID: "own", localAddress: "t1")
        let newKey = HCTerminalKey(owningCoreID: "own", localAddress: "t2")
        let attempt = UUID()
        let identity = HCPanelIdentity(panelID: UUID(), key: oldKey, creationID: attempt)
        let proof = HCEndEvidence(id: UUID(), key: oldKey,
            revision: HCRevision(connectionGeneration: 1, sequence: 12), kind: .finished, hcReason: "holder_lost")
        registry.seed(identity)
        registry.publish(identity: identity, lifecycle: .ended(proof))
        registry.recordCreation(panelID: identity.panelID, creationID: attempt, replacing: proof)
        registry.recordCreationOutcome(panelID: identity.panelID, creationID: attempt,
            result: .unresolved(identity, .connectionLost))
        registry.publish(identity: identity, lifecycle: .unresolved(identity, .creationPending))
        var entry = try XCTUnwrap(registry.entry(for: identity.panelID))
        XCTAssertEqual(entry.identity.key, oldKey)
        XCTAssertEqual(entry.creation?.replaces?.id, proof.id)
        XCTAssertEqual(entry.creation?.outcome, .unresolved)
        // An unrelated/superseded creation cannot acquire this provenance.
        registry.publish(identity: identity, lifecycle: .live(HCTerminalRecord(key: newKey,
            state: .running, labels: ["c11.creation": UUID().uuidString])))
        XCTAssertEqual(registry.entry(for: identity.panelID)?.creation?.outcome, .unresolved)
        registry.publish(identity: identity, lifecycle: .live(HCTerminalRecord(key: newKey,
            state: .running, labels: ["c11.creation": attempt.uuidString])))
        entry = try XCTUnwrap(registry.entry(for: identity.panelID))
        XCTAssertEqual(entry.creation?.outcome, .reconciled)
        XCTAssertEqual(entry.creation?.boundKey, newKey)
        XCTAssertEqual(entry.creation?.replaces?.hcReason, "holder_lost")
    }

    @MainActor
    func testUnavailableCompositionNeverErasesRestoredIdentity() {
        let composition = HCBackendComposition()
        let freshID = UUID()
        defer { HCPanelRestoreState.shared.remove(panelID: freshID) }
        let legacy = composition.makePanelSession(panelID: freshID)
        XCTAssertNil(legacy, "legacy-no-backend: an unseeded panel must keep its exec shell")
        XCTAssertNil(HCPanelRestoreState.shared.entry(for: freshID))
        legacy?.detachSurface()
        XCTAssertTrue(HCPanelNativeLaunchPolicy.permitsExec(identity: nil))

        let identity = HCPanelIdentity(panelID: UUID(), key: HCTerminalKey(owningCoreID: "own", localAddress: "t1"))
        HCPanelRestoreState.shared.seed(identity)
        defer { HCPanelRestoreState.shared.remove(panelID: identity.panelID) }
        let runtime = composition.makePanelSession(panelID: identity.panelID)
        XCTAssertEqual(runtime?.identity, identity)
        XCTAssertFalse(HCPanelNativeLaunchPolicy.permitsExec(identity: identity),
            "persistent-no-exec: an hc panel must never spawn an exec PTY")
        runtime?.publish(.unresolved(identity, .coreUnreachable))
        runtime?.detachSurface()
        XCTAssertEqual(runtime?.identity, identity)
        XCTAssertEqual(HCPanelRestoreState.shared.entry(for: identity.panelID)?.identity, identity)

        let fallback = HCPanelIdentity(panelID: UUID(), persistence: .nonpersistent)
        HCPanelRestoreState.shared.seed(fallback)
        defer { HCPanelRestoreState.shared.remove(panelID: fallback.panelID) }
        let inactiveFallback = composition.makePanelSession(panelID: fallback.panelID)
        XCTAssertNil(inactiveFallback, "nonpersistent-inactive: fallback must not acquire hc while inactive")
        inactiveFallback?.detachSurface()
        composition.activate(session: HCUnavailableRuntime(), inventory: HCUnavailableRuntime()) { _ in }
        let activeFallback = composition.makePanelSession(panelID: fallback.panelID)
        XCTAssertNil(activeFallback, "nonpersistent-active: fallback must not also acquire hc after activation")
        activeFallback?.detachSurface()
        XCTAssertEqual(HCPanelRestoreState.shared.entry(for: fallback.panelID)?.identity, fallback)
        XCTAssertTrue(HCPanelNativeLaunchPolicy.permitsExec(identity: fallback))
    }

    @MainActor
    func testAdmissionInstallsBeforeFreshPersistentPanelsBecomeVisible() {
        let composition = HCBackendComposition()
        var installationOrder: [String] = []
        composition.installSessionEnd = { _ in
            XCTAssertNil(composition.session)
            installationOrder.append("end-policy")
        }
        composition.activate(session: HCUnavailableRuntime(), inventory: HCUnavailableRuntime()) { _ in
            XCTAssertNil(composition.session)
            installationOrder.append("admission")
        }
        XCTAssertEqual(installationOrder, ["admission", "end-policy"])
        let panel = composition.makePanelSession(panelID: UUID())
        XCTAssertEqual(panel?.identity.persistence, .persistent)
        XCTAssertEqual(panel?.identity.origin, .fresh)
        XCTAssertNil(panel?.identity.key)
    }
}


private actor HCInterfaceHeldResolution: HCSession {
    let entered: @Sendable () -> Void
    private var continuation: CheckedContinuation<HCLifecycle, Never>?
    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }
    nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation { HCObservation() }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle {
        await withCheckedContinuation { continuation in self.continuation = continuation; entered() }
    }
    func release(_ lifecycle: HCLifecycle) { continuation?.resume(returning: lifecycle); continuation = nil }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { .rejectedBeforeTransmission(.backendNotInstalled) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment { throw HCUnavailableReason.backendNotInstalled }
    func end(_ key: HCTerminalKey) async -> HCEndResult { .unresolved(key, .backendNotInstalled) }
    func diagnostics() async -> HCDiagnostics { await HCUnavailableRuntime().diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .refused(.backendNotInstalled) }
}
