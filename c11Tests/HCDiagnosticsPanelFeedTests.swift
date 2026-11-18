import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// The recorder's `install` observer called `ingest` with no panels, so rows
/// reported no persistence (an ended terminal) and a panel whose core was
/// unreachable before it ever bound got no row. The app now hands the observer
/// the panel identities it knows.
private struct SnapshotSession: HCSession {
    let snapshot: HCInventorySnapshot
    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        queue.async { handler(snapshot) }
        return HCObservation()
    }
    func resolve(_ identity: HCPanelIdentity) async -> HCLifecycle { .unresolved(identity, .backendNotInstalled) }
    func create(_ request: HCCreateRequest) async -> HCCreateResult { .rejectedBeforeTransmission(.backendNotInstalled) }
    func attach(_ key: HCTerminalKey, sink: any HCOutputSink, display: HCDisplayState) async throws -> any HCAttachment {
        throw HCUnavailableReason.backendNotInstalled
    }
    func end(_ key: HCTerminalKey) async -> HCEndResult { .unresolved(key, .backendNotInstalled) }
    func diagnostics() async -> HCDiagnostics { await HCUnavailableRuntime().diagnostics() }
    func recoverSession(reason: HCRecoveryReason) async -> HCRecoveryResult { .refused(.backendNotInstalled) }
}

final class HCDiagnosticsPanelFeedTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-panel-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeRecorder() -> HCDiagnosticRecorder {
        HCDiagnosticRecorder(logFile: directory.appendingPathComponent("hc-diagnostics.log"),
                             counterFile: directory.appendingPathComponent("holder-lost.json"))
    }

    private func rows(_ recorder: HCDiagnosticRecorder) -> [[String: Any]] {
        recorder.jsonObject()["panels"] as? [[String: Any]] ?? []
    }

    /// The observer delivers on the recorder's own queue.
    private func waitForRows(_ recorder: HCDiagnosticRecorder, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while rows(recorder).count < count, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    private let key = HCTerminalKey(owningCoreID: "core", localAddress: "t1b")

    func testPanelsThatNeverBoundGetRowsWhenTheCoreIsUnreachable() {
        let fresh = HCPanelIdentity(panelID: UUID(), persistence: .persistent, origin: .fresh)
        let fellBack = HCPanelIdentity(panelID: UUID(), persistence: .nonpersistent, origin: .fresh)
        let restored = HCPanelIdentity(panelID: UUID(), key: HCTerminalKey(owningCoreID: "core", localAddress: "t2c"),
                                       persistence: .persistent, origin: .restored)
        let unreachable = HCInventorySnapshot(readiness: .pending(.coreUnreachable),
                                              revision: HCRevision(connectionGeneration: 1, sequence: 0))

        let without = makeRecorder()
        without.install(SnapshotSession(snapshot: unreachable))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(rows(without).isEmpty, "control: without the panel feed nothing is listed")

        let recorder = makeRecorder()
        recorder.install(SnapshotSession(snapshot: unreachable), panels: { [fresh, fellBack, restored] })
        waitForRows(recorder, count: 3)

        func row(_ id: UUID) -> [String: Any]? { rows(recorder).first { $0["panel_id"] as? String == id.uuidString } }
        XCTAssertEqual(rows(recorder).count, 3)
        // A fresh panel that has not created anything is waiting, not a shell; only
        // the nonpersistent identity the fallback branch assigns is a fallback.
        XCTAssertEqual(row(fresh.panelID)?["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(row(fresh.panelID)?["persistence"] as? String, "persistent")
        XCTAssertEqual(row(fellBack.panelID)?["lifecycle"] as? String, "fallback")
        XCTAssertEqual(row(fellBack.panelID)?["persistence"] as? String, "nonpersistent")
        XCTAssertEqual(row(restored.panelID)?["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(row(restored.panelID)?["terminal"] as? String, "t2c")
        XCTAssertEqual(row(restored.panelID)?["reason"] as? String, "core_unreachable")
    }

    func testABoundRowTakesItsPersistenceFromThePanelFeed() {
        let panel = UUID()
        let identity = HCPanelIdentity(panelID: panel, key: key, persistence: .persistent, origin: .restored)
        let ended = HCTerminalRecord(key: key, state: .finished, endReason: "exited")
        let revision = HCRevision(connectionGeneration: 1, sequence: 5)
        let snapshot = HCInventorySnapshot(readiness: .ready(revision), revision: revision, records: [key: ended],
                                           panelBindings: [panel: key])

        let without = makeRecorder()
        without.install(SnapshotSession(snapshot: snapshot))
        waitForRows(without, count: 1)
        XCTAssertEqual(rows(without).first?["lifecycle"] as? String, "ended", "control")
        XCTAssertTrue(rows(without).first?["persistence"] is NSNull, "control: no feed, no persistence")

        let recorder = makeRecorder()
        recorder.install(SnapshotSession(snapshot: snapshot), panels: { [identity] })
        waitForRows(recorder, count: 1)
        XCTAssertEqual(rows(recorder).first?["persistence"] as? String, "persistent")
    }

    func testTheRestoreRegistryListsEveryPublishedIdentity() {
        let a = HCPanelIdentity(panelID: UUID(), key: key, persistence: .persistent, origin: .restored)
        let b = HCPanelIdentity(panelID: UUID(), persistence: .nonpersistent, origin: .fresh)
        defer { HCPanelRestoreState.shared.remove(panelID: a.panelID); HCPanelRestoreState.shared.remove(panelID: b.panelID) }
        XCTAssertFalse(HCPanelRestoreState.shared.identities().contains { $0.panelID == a.panelID }, "control")

        HCPanelRestoreState.shared.publish(identity: a, lifecycle: .unresolved(a, .inventoryPending))
        HCPanelRestoreState.shared.publish(identity: b, lifecycle: .new)

        let listed = HCPanelRestoreState.shared.identities()
        XCTAssertTrue(listed.contains(a))
        XCTAssertTrue(listed.contains(b))
    }

    /// The feed can run before the panel session's own event reaches the recorder.
    /// That order must not leave a fresh, still-waiting panel labelled a fallback.
    func testTheFeedRunningBeforeThePanelsOwnEventLeavesItUnresolved() {
        let fresh = HCPanelIdentity(panelID: UUID(), persistence: .persistent, origin: .fresh)
        let unreachable = HCInventorySnapshot(readiness: .pending(.coreUnreachable),
                                              revision: HCRevision(connectionGeneration: 1, sequence: 0))
        let recorder = makeRecorder()
        recorder.install(SnapshotSession(snapshot: unreachable), panels: { [fresh] })
        waitForRows(recorder, count: 1)

        recorder.record(.coreUnresolved(panel: fresh, configuredBuild: HCPin.current.version))

        XCTAssertEqual(rows(recorder).first?["lifecycle"] as? String, "unresolved")
        XCTAssertFalse(recorder.logText().contains("event=fallback"))
    }

    /// The composition's install is what the app runs at launch: it must hand the
    /// recorder the restore registry's identities, not just subscribe it.
    func testTheCompositionInstallFeedsTheRecorderTheRestoreRegistry() {
        let waiting = HCPanelIdentity(panelID: UUID(), key: HCTerminalKey(owningCoreID: "core", localAddress: "t3d"),
                                      persistence: .persistent, origin: .restored)
        defer { HCPanelRestoreState.shared.remove(panelID: waiting.panelID) }
        HCPanelRestoreState.shared.publish(identity: waiting, lifecycle: .unresolved(waiting, .inventoryPending))
        let unreachable = HCInventorySnapshot(readiness: .pending(.coreUnreachable),
                                              revision: HCRevision(connectionGeneration: 1, sequence: 0))
        let recorder = makeRecorder()

        HCCompositionDiagnostics.install(SnapshotSession(snapshot: unreachable), recorder: recorder)
        waitForRows(recorder, count: 1)

        let row = rows(recorder).first { $0["panel_id"] as? String == waiting.panelID.uuidString }
        XCTAssertEqual(row?["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(row?["terminal"] as? String, "t3d")
        XCTAssertEqual(row?["persistence"] as? String, "persistent")
    }
}
