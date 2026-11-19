import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private final class ManualClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    /// Seconds the clock moves on every read, to model a recorder that takes real
    /// time to walk a large snapshot. Zero keeps the clock still between reads.
    var step: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
    func now() -> Date {
        defer { date.addTimeInterval(step) }
        return date
    }
}

final class HCDiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAttachmentProgressRecordsIdentityOutcomeAndWaitWithoutTerminalContents() {
        let recorder = makeRecorder()
        let panel = HCPanelIdentity(panelID: UUID(), creationID: UUID(), origin: .restored)
        recorder.record(.attachmentProgress(panel: panel, phase: "resolve", outcome: "inventory_pending",
            waitNanoseconds: 12_345_000_000))
        let log = recorder.logText()
        XCTAssertTrue(log.contains("event=attachment_progress panel_id=\(panel.panelID.uuidString) terminal=none"))
        XCTAssertTrue(log.contains("creation_id=\(panel.creationID!.uuidString)"))
        XCTAssertTrue(log.contains("phase=resolve outcome=inventory_pending wait_ms=12345"))
        recorder.record(.attachmentProgress(panel: panel, phase: "fixture secret", outcome: "fixture\nsecret",
            waitNanoseconds: 0))
        XCTAssertFalse(recorder.logText().contains("fixture"))
        XCTAssertTrue((recorder.jsonObject()["panels"] as? [[String: Any]] ?? []).isEmpty,
                      "progress is observational and never invents a live terminal")
    }

    func testUnreachableCoreLogsFallbackAndUnresolved() throws {
        let recorder = makeRecorder()
        let freshID = UUID()
        let restoredID = UUID()
        let keyedRestoredID = UUID()
        let keyedFreshID = UUID()
        let fresh = HCPanelIdentity(panelID: freshID, persistence: .persistent, origin: .fresh)
        let restored = HCPanelIdentity(panelID: restoredID, persistence: .persistent, origin: .restored)
        let keyedRestored = HCPanelIdentity(
            panelID: keyedRestoredID,
            key: HCTerminalKey(owningCoreID: "core_a", localAddress: "t3"),
            persistence: .persistent,
            origin: .restored
        )
        let keyedFresh = HCPanelIdentity(
            panelID: keyedFreshID,
            key: HCTerminalKey(owningCoreID: "core_a", localAddress: "t1b"),
            persistence: .persistent,
            origin: .fresh
        )
        let diagnostics = HCDiagnostics(
            inventory: HCInventorySnapshot(
                readiness: .pending(.coreUnreachable),
                revision: HCRevision(connectionGeneration: 1, sequence: 1)
            ),
            expectedPin: .current,
            unavailableReason: .coreUnreachable
        )
        recorder.ingest(diagnostics, panels: [fresh, restored, keyedRestored, keyedFresh])

        let log = recorder.logText()
        let json = try jsonObject(recorder)
        XCTAssertTrue(log.contains("panel_id=\(freshID.uuidString)"))
        XCTAssertTrue(log.contains("panel_id=\(restoredID.uuidString)"))
        XCTAssertTrue(log.contains("reason=core_unreachable"))
        XCTAssertTrue(log.contains("configured_build=\(HCPin.current.version)"))
        XCTAssertTrue(log.contains("event=fallback panel_id=\(freshID.uuidString) reason=core_unreachable configured_build=\(HCPin.current.version) lifecycle=fallback"))
        XCTAssertTrue(log.contains("event=unresolved panel_id=\(restoredID.uuidString) reason=core_unreachable configured_build=\(HCPin.current.version) lifecycle=unresolved"))
        XCTAssertNotNil(log.range(
            of: #"^ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z event=fallback"#,
            options: .regularExpression
        ))
        XCTAssertEqual(json["readiness"] as? String, "pending")
        XCTAssertEqual(json["readiness_reason"] as? String, "core_unreachable")
        XCTAssertEqual(json["connection_generation"] as? Int, 1)
        XCTAssertEqual(json["sequence"] as? Int, 1)

        let panels = json["panels"] as? [[String: Any]] ?? []
        let freshRow = try XCTUnwrap(panels.first { $0["panel_id"] as? String == freshID.uuidString })
        let restoredRow = try XCTUnwrap(panels.first { $0["panel_id"] as? String == restoredID.uuidString })
        XCTAssertEqual(freshRow["lifecycle"] as? String, "fallback")
        XCTAssertEqual(freshRow["persistence"] as? String, "nonpersistent")
        XCTAssertEqual(restoredRow["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(restoredRow["persistence"] as? String, "persistent")
        XCTAssertEqual(freshRow["configured_build"] as? String, HCPin.current.version)
        XCTAssertTrue(freshRow["serving_build"] is NSNull)
        XCTAssertEqual(freshRow["reason"] as? String, "core_unreachable")
        XCTAssertNil(freshRow["readiness"])
        XCTAssertTrue(freshRow["terminal"] is NSNull)

        let keyedRestoredRow = try XCTUnwrap(panels.first { $0["panel_id"] as? String == keyedRestoredID.uuidString })
        let keyedFreshRow = try XCTUnwrap(panels.first { $0["panel_id"] as? String == keyedFreshID.uuidString })
        XCTAssertEqual(keyedRestoredRow["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(keyedRestoredRow["terminal"] as? String, "t3")
        XCTAssertEqual(keyedRestoredRow["persistence"] as? String, "persistent")
        XCTAssertEqual(keyedRestoredRow["reason"] as? String, "core_unreachable")
        XCTAssertEqual(keyedFreshRow["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(keyedFreshRow["terminal"] as? String, "t1b")
        XCTAssertEqual(keyedFreshRow["persistence"] as? String, "persistent")
        XCTAssertFalse(log.contains("event=fallback panel_id=\(keyedFreshID.uuidString)"))
        XCTAssertTrue(log.contains("terminal=t3"))

        recorder.ingest(diagnostics, panels: [fresh, restored, keyedRestored, keyedFresh])
        let repeated = try jsonObject(recorder)
        let freshAgain = try XCTUnwrap((repeated["panels"] as? [[String: Any]])?.first { $0["panel_id"] as? String == freshID.uuidString })
        XCTAssertEqual(freshAgain["lifecycle"] as? String, "fallback")
        XCTAssertEqual(freshAgain["persistence"] as? String, "nonpersistent")
        let repeatedLog = recorder.logText()
        XCTAssertEqual(fieldCount(repeatedLog, "event=fallback"), 1)
        XCTAssertFalse(repeatedLog.contains("event=unresolved panel_id=\(freshID.uuidString)"))

        let registeredID = UUID()
        let registered = HCPanelIdentity(panelID: registeredID, persistence: .persistent, origin: .fresh)
        recorder.record(.panelNew(panel: registered))
        recorder.ingest(diagnostics, panels: [registered])
        let registeredObject = try jsonObject(recorder)
        let registeredRow = try XCTUnwrap((registeredObject["panels"] as? [[String: Any]])?.first { $0["panel_id"] as? String == registeredID.uuidString })
        XCTAssertEqual(registeredRow["lifecycle"] as? String, "fallback")
        XCTAssertEqual(registeredRow["persistence"] as? String, "nonpersistent")
        XCTAssertTrue(registeredRow["terminal"] is NSNull)
        let registeredLog = recorder.logText()
        XCTAssertTrue(registeredLog.contains("event=fallback panel_id=\(registeredID.uuidString) reason=core_unreachable configured_build=\(HCPin.current.version) lifecycle=fallback"))
        XCTAssertFalse(registeredLog.contains("event=unresolved panel_id=\(registeredID.uuidString)"))
        XCTAssertEqual(fieldCount(registeredLog, "event=fallback"), 2)
    }

    func testAttachFailureLogsNotFound() throws {
        let recorder = makeRecorder()
        let panelID = UUID()
        recorder.record(.attachFailed(
            panelID: panelID,
            terminal: "t4",
            servingBuild: HCPin.current.version,
            reason: "not_found"
        ))
        let log = recorder.logText()
        XCTAssertTrue(log.contains("event=attach_failed"))
        XCTAssertTrue(log.contains("panel_id=\(panelID.uuidString)"))
        XCTAssertTrue(log.contains("terminal=t4"))
        XCTAssertTrue(log.contains("serving_build=\(HCPin.current.version)"))
        XCTAssertTrue(log.contains("reason=not_found"))

        let json = try jsonObject(recorder)
        let row = try XCTUnwrap((json["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["panel_id"] as? String, panelID.uuidString)
        XCTAssertEqual(row["terminal"] as? String, "t4")
        XCTAssertEqual(row["serving_build"] as? String, HCPin.current.version)
        XCTAssertEqual(row["reason"] as? String, "not_found")
        XCTAssertEqual(row["lifecycle"] as? String, "new")

        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t4")
        let identity = makeIdentity(core: "core_a", pid: 9, start: 8)
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [key: makeRecord(key: key, state: .running, endReason: nil, tty: nil, pid: 44)],
            bindings: [panelID: key],
            generation: 2,
            sequence: 2
        )
        let running = try jsonObject(recorder)
        let live = try XCTUnwrap((running["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(live["lifecycle"] as? String, "live")
        XCTAssertEqual(live["reason"] as? String, "not_found")
        XCTAssertEqual(live["terminal"] as? String, "t4")
        XCTAssertEqual(fieldCount(recorder.logText(), "event=attach"), 0)
        XCTAssertEqual(fieldCount(recorder.logText(), "event=reattach"), 0)
        XCTAssertEqual(fieldCount(recorder.logText(), "event=attach_failed"), 1)

        let endedKey = key
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [endedKey: makeRecord(key: endedKey, state: .finished, endReason: "killed", tty: nil, pid: 44)],
            bindings: [panelID: endedKey],
            generation: 2,
            sequence: 3
        )
        let ended = try jsonObject(recorder)
        let endedRow = try XCTUnwrap((ended["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(endedRow["lifecycle"] as? String, "ended")
        XCTAssertEqual(endedRow["reason"] as? String, "killed")
    }

    func testGateRefusalLogsPidAncestryAndReason() {
        let recorder = makeRecorder()
        recorder.record(.gateRefused(callerPid: 4242, ancestry: "not_owned", reason: "foreign_session"))
        let log = recorder.logText()
        XCTAssertTrue(log.contains("event=gate gate refused"))
        XCTAssertTrue(log.contains("gate refused"))
        XCTAssertTrue(log.contains("caller_pid=4242"))
        XCTAssertTrue(log.contains("ancestry=not_owned"))
        XCTAssertTrue(log.contains("reason=foreign_session"))
        recorder.record(.gateRefused(callerPid: 7, ancestry: "owned", reason: HCInputRefusal.guardRefused.rawValue))
        XCTAssertTrue(recorder.logText().contains("reason=guard_refused"))
    }

    func testFileLimitAndHolderLossCountSurvivesRestart() {
        let recorder = makeRecorder()
        recorder.record(.fileLimit(soft: 8192, hard: UInt64.max, kernelCap: 9223372036854775807, beforeSoft: 256))
        let log = recorder.logText()
        XCTAssertTrue(log.contains("event=rlimit_nofile soft=8192 hard=\(UInt64.max)"))
        XCTAssertTrue(log.contains("kernel_cap=9223372036854775807"))
        XCTAssertTrue(log.contains("before_soft=256"))

        recorder.record(.holderLost(coreID: "core_a", terminal: "t1", discriminator: "p77:10", holderID: "p2064:10"))
        recorder.record(.holderLost(coreID: "core_a", terminal: "t1", discriminator: "p77:10", holderID: "p2064:10"))
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(holderLostLines(recorder.logText()), 1)
        XCTAssertTrue(recorder.logText().contains("event=holder_lost core_id=core_a count=1"))

        let restarted = makeRecorder()
        XCTAssertEqual(restarted.holderLostCount, 1)
        restarted.record(.holderLost(coreID: "core_a", terminal: "t1", discriminator: "p77:10", holderID: "p2064:10"))
        XCTAssertEqual(restarted.holderLostCount, 1)
        XCTAssertEqual(restarted.jsonObject()["holder_lost_count"] as? Int, 1)
        XCTAssertTrue(restarted.jsonObject()["holder_lost_count_error"] is NSNull)
    }

    func testOneHolderDeathStaysOneAcrossRevisionsAndRestart() throws {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        ingestHolderLoss(recorder, addresses: ["t1", "t2"], sequence: 4, generation: 3, killedAddress: "t9")
        XCTAssertEqual(recorder.holderLostCount, 1)
        ingestHolderLoss(recorder, addresses: ["t3"], sequence: 5, generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(holderLostLines(recorder.logText()), 1)

        ingestHolderLoss(recorder, addresses: ["t1", "t2", "t3"], sequence: 8, generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)

        let restarted = makeRecorder(clock: clock)
        XCTAssertEqual(restarted.holderLostCount, 1)
        ingestHolderLoss(restarted, addresses: ["t1", "t2", "t3"], sequence: 1, generation: 9)
        XCTAssertEqual(restarted.holderLostCount, 1)

        // A second death needs a new holder in between: a live terminal on the core.
        ingestLiveTerminal(restarted, address: "t9", sequence: 2, generation: 9)
        clock.advance(3)
        ingestHolderLoss(restarted, addresses: ["t4", "t5"], sequence: 3, generation: 9, pidBase: 40)
        XCTAssertEqual(restarted.holderLostCount, 2)
        XCTAssertEqual(holderLostLines(restarted.logText()), 2)
        XCTAssertTrue(restarted.logText().contains("count=2"))
    }

    func testHolderIdentityCoalescesOutsideTheTimeWindow() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        recorder.record(.holderLost(coreID: "core_a", terminal: "t1", discriminator: "p10:100", holderID: "p2064:900"))
        clock.advance(30)
        recorder.record(.holderLost(coreID: "core_a", terminal: "t2", discriminator: "p11:100", holderID: "p2064:900"))
        XCTAssertEqual(recorder.holderLostCount, 1)

        let restarted = makeRecorder(clock: clock)
        restarted.record(.holderLost(coreID: "core_a", terminal: "t3", discriminator: "p12:100", holderID: "p2064:900"))
        XCTAssertEqual(restarted.holderLostCount, 1)
        restarted.record(.holderLost(coreID: "core_a", terminal: "t9", discriminator: "p19:100", holderID: "p9999:1"))
        XCTAssertEqual(restarted.holderLostCount, 2)
    }

    func testUnkeyedHolderLossCountsAndShowsInTheLog() throws {
        let recorder = makeRecorder()
        ingestBareHolderLoss(recorder, address: "t1", generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(unkeyedLines(recorder.logText()), 1)
        XCTAssertTrue(recorder.logText().contains("event=holder_lost_unkeyed core_id=core_a terminal=t1"))
        let row = try XCTUnwrap((jsonObject(recorder)["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["lifecycle"] as? String, "ended")
        XCTAssertEqual(row["reason"] as? String, "holder_lost")

        ingestBareHolderLoss(recorder, address: "t1", generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)

        let restarted = makeRecorder()
        ingestBareHolderLoss(restarted, address: "t1", generation: 9)
        XCTAssertEqual(restarted.holderLostCount, 2)
        XCTAssertEqual(unkeyedLines(restarted.logText()), 2)
    }

    func testUnkeyedGenerationOvercountIsOneIncident() {
        let recorder = makeRecorder()
        ingestBareHolderLoss(recorder, address: "t1", generation: 3)
        ingestBareHolderLoss(recorder, address: "t2", generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)

        let restarted = makeRecorder()
        ingestBareHolderLoss(restarted, address: "t1", generation: 9)
        ingestBareHolderLoss(restarted, address: "t2", generation: 9)
        XCTAssertEqual(restarted.holderLostCount, 2)
        XCTAssertEqual(unkeyedLines(restarted.logText()), 4)
    }

    func testFinishedHolderLossInheritsTheLiveDiscriminator() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        let panelID = UUID()
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        let process = HCProcessIdentity(pid: 11, startTimeMicroseconds: 100)
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [key: makeRecord(key: key, state: .running, endReason: nil, tty: nil, pid: 11, process: process)],
            bindings: [panelID: key],
            generation: 3,
            sequence: 1
        )
        XCTAssertEqual(recorder.holderLostCount, 0)

        ingestSnapshot(
            recorder,
            identity: identity,
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil)],
            bindings: [panelID: key],
            generation: 3,
            sequence: 4
        )
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(unkeyedLines(recorder.logText()), 0)
        XCTAssertTrue(recorder.logText().contains("ts=2023-11-14T22:13:20.000Z "))

        let restarted = makeRecorder(clock: clock)
        ingestSnapshot(
            restarted,
            identity: identity,
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil)],
            bindings: [panelID: key],
            generation: 9,
            sequence: 1
        )
        XCTAssertEqual(restarted.holderLostCount, 1)
        XCTAssertEqual(unkeyedLines(restarted.logText()), 0)
    }

    func testCreationIDDoesNotReplaceTheCachedDiscriminator() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        let panelID = UUID()
        let creationID = UUID()
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        let process = HCProcessIdentity(pid: 11, startTimeMicroseconds: 100)
        let panel = HCPanelIdentity(panelID: panelID, creationID: creationID, origin: .restored)
        let live = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: 3, sequence: 1)),
            revision: HCRevision(connectionGeneration: 3, sequence: 1),
            records: [key: makeRecord(key: key, state: .running, endReason: nil, tty: nil, pid: 11, process: process)],
            buildIdentity: identity,
            panelBindings: [panelID: key]
        )
        recorder.ingest(HCDiagnostics(inventory: live, servingBuild: identity), panels: [panel])
        let finished = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: 3, sequence: 4)),
            revision: HCRevision(connectionGeneration: 3, sequence: 4),
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil)],
            buildIdentity: identity,
            panelBindings: [panelID: key]
        )
        recorder.ingest(HCDiagnostics(inventory: finished, servingBuild: identity), panels: [panel])
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(unkeyedLines(recorder.logText()), 0)

        let restarted = makeRecorder(clock: clock)
        let again = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: 9, sequence: 1)),
            revision: HCRevision(connectionGeneration: 9, sequence: 1),
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil)],
            buildIdentity: identity,
            panelBindings: [panelID: key]
        )
        restarted.ingest(HCDiagnostics(inventory: again, servingBuild: identity))
        XCTAssertEqual(restarted.holderLostCount, 1)
        XCTAssertEqual(unkeyedLines(restarted.logText()), 0)
    }

    func testRememberLiveKeepsTheDiscriminatorAdoptedFromDisk() {
        let first = makeRecorder()
        let second = makeRecorder()
        let panelID = UUID()
        let creationID = UUID()
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        let process = HCProcessIdentity(pid: 11, startTimeMicroseconds: 100)
        ingestSnapshot(
            first,
            identity: identity,
            records: [key: makeRecord(key: key, state: .running, endReason: nil, tty: nil, pid: 11, process: process)],
            bindings: [panelID: key],
            generation: 3,
            sequence: 1
        )
        ingestSnapshot(
            first,
            identity: identity,
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil)],
            bindings: [panelID: key],
            generation: 3,
            sequence: 4
        )
        XCTAssertEqual(first.holderLostCount, 1)

        let panel = HCPanelIdentity(panelID: panelID, creationID: creationID, origin: .restored)
        let live = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: 4, sequence: 1)),
            revision: HCRevision(connectionGeneration: 4, sequence: 1),
            records: [key: makeRecord(key: key, state: .running, endReason: nil, tty: nil)],
            buildIdentity: identity,
            panelBindings: [panelID: key]
        )
        second.ingest(HCDiagnostics(inventory: live, servingBuild: identity), panels: [panel])

        let third = makeRecorder()
        ingestSnapshot(
            third,
            identity: identity,
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil)],
            bindings: [UUID(): key],
            generation: 9,
            sequence: 1
        )
        XCTAssertEqual(third.holderLostCount, 1)
        XCTAssertEqual(unkeyedLines(third.logText()), 0)
    }

    func testHcPidFallbackCountsWithoutAProcessIdentity() {
        let recorder = makeRecorder()
        let panelID = UUID()
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t4")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil, pid: 55)],
            bindings: [panelID: key],
            generation: 2,
            sequence: 1
        )
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(unkeyedLines(recorder.logText()), 0)

        let restarted = makeRecorder()
        ingestSnapshot(
            restarted,
            identity: identity,
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil, pid: 55)],
            bindings: [UUID(): key],
            generation: 8,
            sequence: 1
        )
        XCTAssertEqual(restarted.holderLostCount, 1)
    }

    func testIngestThenRecordSharesTheHolder() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        ingestHolderLoss(recorder, addresses: ["t1"], sequence: 1, generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)
        recorder.record(.holderLost(coreID: "core_a", terminal: "t1", discriminator: "p11:100", holderID: "p2064:900"))
        XCTAssertEqual(recorder.holderLostCount, 1)
        clock.advance(30)
        recorder.record(.holderLost(coreID: "core_a", terminal: "t2", discriminator: "p12:100", holderID: "p2064:900"))
        XCTAssertEqual(recorder.holderLostCount, 1)
    }

    func testRecordThenIngestDoesNotDoubleCount() {
        let recorder = makeRecorder()
        recorder.record(.holderLost(coreID: "core_a", terminal: "t1", discriminator: "p11:100", holderID: "p2064:900"))
        XCTAssertEqual(recorder.holderLostCount, 1)
        ingestHolderLoss(recorder, addresses: ["t1"], sequence: 4, generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(holderLostLines(recorder.logText()), 1)
    }

    func testTwoRecordersDoNotClobberTheCount() {
        let first = makeRecorder()
        let second = makeRecorder()
        first.record(.holderLost(coreID: "core_a", terminal: "t1", discriminator: "p11:100", holderID: "p2064:900"))
        second.record(.holderLost(coreID: "core_a", terminal: "t2", discriminator: "p12:100", holderID: "p9999:1"))
        let reloaded = makeRecorder()
        XCTAssertEqual(reloaded.holderLostCount, 2)
    }

    func testCoreIdFromCoreJsonShapeIsLogged() {
        let recorder = makeRecorder()
        let core = "0123456789abcdef0123456789abcdef"
        recorder.record(.holderLost(coreID: core, terminal: "t1", discriminator: "p11:100", holderID: nil))
        XCTAssertTrue(recorder.logText().contains("core_id=\(core)"))
        XCTAssertEqual(recorder.holderLostCount, 1)
    }

    func testTransportReportLogsAllowlistedTokensOnly() {
        let recorder = makeRecorder()
        recorder.recordTransport(event: "hc_hello_start", connectionGeneration: 3, elapsedNanoseconds: nil)
        recorder.recordTransport(event: "hc_hello_complete", connectionGeneration: 3, elapsedNanoseconds: 1500)
        recorder.recordTransport(event: "hc_wire_fault_drop_reply", connectionGeneration: 4, elapsedNanoseconds: nil)
        recorder.recordTransport(event: "secret value", connectionGeneration: 3, elapsedNanoseconds: 9)
        let log = recorder.logText()
        XCTAssertTrue(log.contains("event=hc_hello_start connection_generation=3"))
        XCTAssertTrue(log.contains("event=hc_hello_complete connection_generation=3 elapsed_ns=1500"))
        XCTAssertTrue(log.contains("event=hc_wire_fault_drop_reply connection_generation=4"))
        XCTAssertFalse(log.contains("secret"))
        XCTAssertFalse(log.contains("elapsed_ns=9"))
    }

    func testDiagnosticsResponseCarriesTheC11VersionLine() throws {
        let recorder = makeRecorder()
        let response = recorder.diagnosticsResponse(appInfo: [
            "CFBundleShortVersionString": "1.6.0", "C11Version": "1.6.0-h3",
        ])
        XCTAssertEqual(response["c11_version"] as? String, "1.6.0-h3")
        XCTAssertEqual(response["holder_lost_count"] as? Int, 0)
        XCTAssertNotNil(try JSONSerialization.data(withJSONObject: response))
        let plain = recorder.diagnosticsResponse(appInfo: ["CFBundleShortVersionString": "1.6.0"])
        XCTAssertEqual(plain["c11_version"] as? String, "1.6.0")
        XCTAssertTrue(recorder.diagnosticsResponse(appInfo: [:])["c11_version"] is NSNull)
    }

    func testEmptyDiagnosticsAreNulls() throws {
        let recorder = makeRecorder()
        let json = try jsonObject(recorder)
        XCTAssertEqual(json["holder_lost_count"] as? Int, 0)
        XCTAssertTrue(json["holder_lost_count_error"] is NSNull)
        XCTAssertTrue(json["readiness"] is NSNull)
        XCTAssertTrue(json["readiness_reason"] is NSNull)
        XCTAssertTrue(json["connection_generation"] is NSNull)
        XCTAssertTrue(json["sequence"] is NSNull)
        XCTAssertEqual((json["panels"] as? [[String: Any]])?.count, 0)
    }

    func testUnreadableCounterIsNotReplacedWithZero() throws {
        let counter = directory.appendingPathComponent("holder-lost.json")
        try Data("not-json".utf8).write(to: counter)
        let recorder = makeRecorder()
        XCTAssertEqual(recorder.holderLostCount, 0)
        XCTAssertEqual(recorder.jsonObject()["holder_lost_count_error"] as? String, "unreadable")
        XCTAssertTrue(recorder.logText().contains("event=counter_disabled reason=unreadable"))
        recorder.record(.holderLost(coreID: "core_a", terminal: "t1", discriminator: "p77:10", holderID: nil))
        XCTAssertEqual(recorder.holderLostCount, 1)
        let preserved = try Data(contentsOf: counter)
        XCTAssertEqual(preserved, Data("not-json".utf8))
    }

    func testDiagnosticsJSONListsTerminalRowsWithoutContents() throws {
        let recorder = makeRecorder()
        let panelID = UUID()
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t3")
        let secret = "C11_SECRET_sek_should_not_leak"
        let content = "content-screen-blob-should-not-leak"
        let record = HCTerminalRecord(
            key: key,
            state: .running,
            labels: ["c11.panel": secret],
            pid: 4321,
            cwd: "/tmp/\(secret)",
            foreground: HCForeground(pid: 1, name: secret, argv: [content], cwd: content),
            title: secret,
            status: content,
            endReason: nil,
            tty: "/dev/ttys004"
        )
        let identity = makeIdentity(core: "core_a", pid: 9, start: 8)
        let snapshot = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: 2, sequence: 2)),
            revision: HCRevision(connectionGeneration: 2, sequence: 2),
            records: [key: record],
            buildIdentity: identity,
            panelBindings: [panelID: key]
        )
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))

        let log = recorder.logText()
        XCTAssertEqual(fieldCount(log, "event=attach"), 0)
        XCTAssertEqual(fieldCount(log, "event=reattach"), 0)
        XCTAssertEqual(fieldCount(log, "event=lifecycle"), 1)
        XCTAssertTrue(log.contains("lifecycle=live"))
        XCTAssertFalse(log.contains(secret))
        XCTAssertFalse(log.contains(content))

        let moved = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: 5, sequence: 6)),
            revision: HCRevision(connectionGeneration: 5, sequence: 6),
            records: [key: record],
            buildIdentity: identity,
            panelBindings: [panelID: key]
        )
        recorder.ingest(HCDiagnostics(inventory: moved, servingBuild: identity))
        let after = recorder.logText()
        XCTAssertEqual(fieldCount(after, "event=reattach"), 0)
        XCTAssertEqual(fieldCount(after, "event=attach"), 0)
        XCTAssertEqual(fieldCount(after, "event=lifecycle"), 1)
        XCTAssertFalse(after.contains(secret))

        let json = try jsonText(recorder)
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains(content))
        let object = try jsonObject(recorder)
        XCTAssertEqual(object["readiness"] as? String, "ready")
        XCTAssertTrue(object["readiness_reason"] is NSNull)
        XCTAssertEqual(object["connection_generation"] as? Int, 5)
        XCTAssertEqual(object["sequence"] as? Int, 6)
        let row = try XCTUnwrap((object["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["panel_id"] as? String, panelID.uuidString)
        XCTAssertEqual(row["terminal"] as? String, "t3")
        XCTAssertEqual(row["tty"] as? String, "/dev/ttys004")
        XCTAssertEqual(row["pid"] as? Int, 4321)
        XCTAssertEqual(row["lifecycle"] as? String, "live")
        XCTAssertNil(row["readiness"])
        XCTAssertEqual(row["serving_build"] as? String, HCPin.current.version)
        XCTAssertEqual(row["configured_build"] as? String, HCPin.current.version)
        XCTAssertEqual((object["panels"] as? [[String: Any]])?.count, 1)

        let finishedRecord = HCTerminalRecord(
            key: key,
            state: .finished,
            labels: ["c11.panel": secret],
            pid: 4321,
            cwd: "/tmp/\(secret)",
            foreground: HCForeground(pid: 1, name: secret, argv: [content], cwd: content),
            title: secret,
            status: content,
            endReason: "killed",
            tty: "/dev/ttys004"
        )
        let finished = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: 5, sequence: 7)),
            revision: HCRevision(connectionGeneration: 5, sequence: 7),
            records: [key: finishedRecord],
            buildIdentity: identity,
            panelBindings: [panelID: key]
        )
        recorder.ingest(HCDiagnostics(inventory: finished, servingBuild: identity))
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
        XCTAssertEqual(fieldCount(recorder.logText(), "event=lifecycle"), 3)
        XCTAssertEqual(fieldCount(recorder.logText(), "event=attach"), 0)
        XCTAssertFalse(recorder.logText().contains(secret))
    }

    func testRemoteTerminalAddressAndPanelLifecycle() throws {
        let recorder = makeRecorder()
        let panelID = UUID()
        recorder.record(.attach(
            panelID: panelID,
            terminal: "studio/t8",
            servingBuild: HCPin.current.version,
            tty: nil
        ))
        recorder.record(.panelNew(panel: HCPanelIdentity(
            panelID: panelID,
            key: HCTerminalKey(owningCoreID: "core_a", localAddress: "studio/t8"),
            persistence: .persistent,
            origin: .fresh
        )))
        var object = try jsonObject(recorder)
        var row = try XCTUnwrap((object["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["terminal"] as? String, "studio/t8")
        XCTAssertEqual(row["lifecycle"] as? String, "new")

        recorder.record(.panelEnded(panelID: panelID, reason: "exited"))
        object = try jsonObject(recorder)
        row = try XCTUnwrap((object["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["lifecycle"] as? String, "ended")
        XCTAssertEqual(row["reason"] as? String, "exited")
        XCTAssertEqual(row["terminal"] as? String, "studio/t8")

        recorder.record(.panelClosed(panelID: panelID))
        object = try jsonObject(recorder)
        XCTAssertEqual((object["panels"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue(recorder.logText().contains("event=close panel_id=\(panelID.uuidString)"))
    }

    /// C11H-205: the session keeps a closed panel's finished terminal bound, so
    /// every later snapshot still names it. A closed panel's row stays gone.
    func testAClosedPanelStaysGoneWhileTheSessionStillBindsItsFinishedTerminal() throws {
        let recorder = makeRecorder()
        let panelID = UUID()
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t4")
        let identity = makeIdentity(core: "core_a", pid: 9, start: 8)
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let snapshot = HCInventorySnapshot(
            readiness: .ready(revision), revision: revision,
            records: [key: HCTerminalRecord(key: key, state: .finished, endReason: "killed")],
            buildIdentity: identity, panelBindings: [panelID: key]
        )
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
        XCTAssertEqual(try row(recorder, panelID)["lifecycle"] as? String, "ended")

        recorder.record(.panelClosed(panelID: panelID))
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
        let response = recorder.diagnosticsResponse(appInfo: [:])
        let data = try JSONSerialization.data(withJSONObject: response)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let panels = try XCTUnwrap(decoded["panels"] as? [[String: Any]])
        XCTAssertFalse(panels.contains { $0["panel_id"] as? String == panelID.uuidString },
                       "a closed panel's stale binding does not bring its row back")
    }

    /// C11H-205: a close for good reaches the recorder through the restore
    /// state's close observer, so its row leaves for good. A move is no close.
    @MainActor
    func testClosingForGoodRemovesTheRowAndAMoveKeepsIt() throws {
        let recorder = makeRecorder()
        let lineage = PanelLineage()
        HCPanelRestoreState.installCloseObserver(lineage: lineage, state: HCPanelRestoreState(),
                                                 diagnostics: { recorder.record($0) })
        let closed = UUID(), moved = UUID()
        let closedKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let movedKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t2")
        let identity = makeIdentity(core: "core_a", pid: 9, start: 8)
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let snapshot = HCInventorySnapshot(
            readiness: .ready(revision), revision: revision,
            records: [
                closedKey: HCTerminalRecord(key: closedKey, state: .finished, endReason: "killed"),
                movedKey: HCTerminalRecord(key: movedKey, state: .running),
            ],
            buildIdentity: identity, panelBindings: [closed: closedKey, moved: movedKey]
        )
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
        lineage.panelsClosedForGood([moved], isDetaching: true)
        lineage.panelsClosedForGood([closed])
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))

        let panels = try XCTUnwrap(try jsonObject(recorder)["panels"] as? [[String: Any]])
        XCTAssertEqual(panels.compactMap { $0["panel_id"] as? String }, [moved.uuidString])
        XCTAssertTrue(recorder.logText().contains("event=close panel_id=\(closed.uuidString)"))
    }

    /// C11H-196: five predecessors, newest first; the oldest falls off.
    func testLogRotatesAndKeepsFivePredecessors() throws {
        let recorder = makeRecorder(maxLogBytes: 1)
        for pid in Int32(100)...Int32(106) {
            recorder.record(.gateRefused(callerPid: pid, ancestry: "owned", reason: "foreign_session"))
        }
        func generation(_ n: Int) throws -> String {
            try String(contentsOf: directory.appendingPathComponent("hc-diagnostics.log.\(n)"), encoding: .utf8)
        }
        XCTAssertTrue(recorder.logText().contains("caller_pid=106"))
        XCTAssertTrue(try generation(1).contains("caller_pid=105"))
        XCTAssertTrue(try generation(5).contains("caller_pid=101"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("hc-diagnostics.log.6").path))
        let all = try (1...5).map(generation).joined() + recorder.logText()
        XCTAssertFalse(all.contains("caller_pid=100"), "the sixth-oldest line is dropped")
    }

    func testSecretsStayOutOfLogAndJSON() throws {
        let recorder = makeRecorder()
        let secret = "C11_SECRET_sek_should_not_leak"
        let content = "content-screen-blob-should-not-leak"
        let panelID = UUID()
        recorder.record(.attachFailed(panelID: panelID, terminal: secret, servingBuild: secret, reason: content))
        recorder.record(.gateRefused(callerPid: 12, ancestry: secret, reason: content))
        recorder.record(.recovery(reason: secret, result: "recovered", servingBuild: secret))
        recorder.record(.holderLost(coreID: secret, terminal: secret, discriminator: secret, holderID: secret))
        let key = HCTerminalKey(owningCoreID: secret, localAddress: secret)
        let record = HCTerminalRecord(
            key: key,
            state: .running,
            title: secret,
            status: content,
            endReason: content,
            tty: "/tmp/\(secret)"
        )
        let snapshot = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: 1, sequence: 1)),
            revision: HCRevision(connectionGeneration: 1, sequence: 1),
            records: [key: record],
            panelBindings: [panelID: key]
        )
        recorder.ingest(HCDiagnostics(inventory: snapshot, expectedPin: HCPin(version: secret, archiveSHA256: secret, executableSHA256: secret, protocolGeneration: 1)))

        let log = recorder.logText()
        let json = try jsonText(recorder)
        XCTAssertFalse(log.contains(secret))
        XCTAssertFalse(log.contains(content))
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains(content))
        XCTAssertEqual(recorder.holderLostCount, 0)
    }

    func testReasonTokensCoverEveryContractCase() {
        let unavailable: [(HCUnavailableReason, String)] = [
            (.backendNotInstalled, "backend_not_installed"),
            (.coreUnreachable, "core_unreachable"),
            (.inventoryPending, "inventory_pending"),
            (.connectionLost, "connection_lost"),
            (.incompatibleProtocol, "incompatible_protocol"),
            (.foreignBuild, "foreign_build"),
            (.foreignSession, "foreign_session"),
            (.pinMismatch, "pin_mismatch"),
            (.invalidLaunchTuple, "invalid_launch_tuple"),
            (.fileDescriptorLimit, "file_descriptor_limit"),
            (.intentStoreFailure, "intent_store_failure"),
            (.creationPending, "creation_pending"),
            (.creationUncertain, "creation_uncertain"),
            (.recoveryRequired, "recovery_required"),
            (.inputFault, "input_fault"),
            (.screenUnavailable, "screen_unavailable"),
            (.staleIdentity, "stale_identity"),
            (.ambiguousIdentity, "ambiguous_identity"),
            (.deadlineExceeded, "deadline_exceeded"),
            (.malformedResponse, "malformed_response"),
            (.bufferOverflow, "buffer_overflow"),
            (.cancelled, "cancelled"),
        ]
        for (reason, token) in unavailable {
            XCTAssertEqual(HCDiagnosticTokens.unavailable(reason), token)
            XCTAssertEqual(HCDiagnosticTokens.reason(reason.rawValue), token)
        }
        let recovery: [(HCRecoveryReason, String)] = [
            (.foreignBuild, "foreign_build"),
            (.creationUncertain, "creation_uncertain"),
            (.inputFault, "input_fault"),
        ]
        for (reason, token) in recovery {
            XCTAssertEqual(HCDiagnosticTokens.recoveryReason(reason), token)
            XCTAssertEqual(HCDiagnosticTokens.reason(reason.rawValue), token)
        }
        let refusals: [(HCInputRefusal, String)] = [
            (.unavailable, "unavailable"),
            (.staleIdentity, "stale_identity"),
            (.guardRefused, "guard_refused"),
            (.screenUnavailable, "screen_unavailable"),
            (.tooLarge, "too_large"),
            (.queueFull, "queue_full"),
            (.inputFault, "input_fault"),
            (.cancelled, "cancelled"),
        ]
        for (reason, token) in refusals {
            XCTAssertEqual(HCDiagnosticTokens.inputRefusal(reason), token)
            XCTAssertEqual(HCDiagnosticTokens.reason(reason.rawValue), token)
        }
        XCTAssertEqual(HCDiagnosticTokens.reason("not_found"), "not_found")
        XCTAssertEqual(HCDiagnosticTokens.reason("holder_lost"), "holder_lost")
        XCTAssertNil(HCDiagnosticTokens.reason("C11_SECRET_sek_should_not_leak"))
        XCTAssertNil(HCDiagnosticTokens.reason("not a token"))
        XCTAssertNil(HCDiagnosticTokens.reason("holderLost"))
    }

    func testInputOutcomeMapping() {
        let refused = HCDiagnosticInputMapping.verdict(for: .refused(.guardRefused))
        XCTAssertEqual(refused.outcome, "refused")
        XCTAssertEqual(refused.exitStatus, "nonzero")
        XCTAssertEqual(refused.byteCount, 0)
        XCTAssertEqual(refused.retry, "safe")
        XCTAssertFalse(refused.submitted)

        let receipt = HCWriteReceipt(
            operationID: UUID(),
            attachmentGeneration: 1,
            bodyBytesWritten: 4,
            returnWritten: false
        )
        let written = HCDiagnosticInputMapping.verdict(for: .written(receipt))
        XCTAssertEqual(written.exitStatus, "zero")
        XCTAssertEqual(written.byteCount, 4)
        XCTAssertFalse(written.submitted)
        XCTAssertEqual(written.replay, "never")

        let submitted = HCWriteReceipt(
            operationID: receipt.operationID,
            attachmentGeneration: 1,
            bodyBytesWritten: 4,
            returnWritten: true
        )
        XCTAssertTrue(HCDiagnosticInputMapping.verdict(for: .written(submitted)).submitted)

        let uncertain = HCDiagnosticInputMapping.verdict(for: .uncertain(receipt))
        XCTAssertEqual(uncertain.exitStatus, "nonzero")
        XCTAssertEqual(uncertain.byteCount, 4)
        XCTAssertEqual(uncertain.retry, "unsafe")
        XCTAssertEqual(uncertain.replay, "never")
        XCTAssertFalse(uncertain.submitted)

        let uncertainWritten = HCDiagnosticInputMapping.verdict(for: .uncertain(submitted))
        XCTAssertEqual(uncertainWritten.outcome, "uncertain")
        XCTAssertEqual(uncertainWritten.exitStatus, "nonzero")
        XCTAssertEqual(uncertainWritten.byteCount, 4)
        XCTAssertEqual(uncertainWritten.retry, "unsafe")
        XCTAssertEqual(uncertainWritten.replay, "never")
        XCTAssertTrue(uncertainWritten.submitted)

        let queued = HCDiagnosticInputMapping.queued()
        XCTAssertEqual(queued.outcome, "queued")
        XCTAssertTrue(queued.pending)
        XCTAssertEqual(queued.byteCount, 0)
        XCTAssertEqual(queued.replay, "never")
    }

    func testRetainedBindingIsUnresolvedWhenTheCoreIsUnreachable() throws {
        let recorder = makeRecorder()
        let panelID = UUID()
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t4")
        let identity = makeIdentity(core: "core_a", pid: 9, start: 8)
        let running = makeRecord(key: key, state: .running, endReason: nil, tty: "/dev/ttys004", pid: 44)
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [key: running],
            bindings: [panelID: key],
            generation: 2,
            sequence: 1
        )
        let pending = HCInventorySnapshot(
            readiness: .pending(.coreUnreachable),
            revision: HCRevision(connectionGeneration: 2, sequence: 3),
            records: [key: running],
            buildIdentity: identity,
            panelBindings: [panelID: key]
        )
        let diagnostics = HCDiagnostics(
            inventory: pending,
            expectedPin: .current,
            servingBuild: identity,
            unavailableReason: .coreUnreachable
        )
        recorder.ingest(diagnostics)
        recorder.ingest(diagnostics)
        let row = try XCTUnwrap((jsonObject(recorder)["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(row["terminal"] as? String, "t4")
        XCTAssertEqual(row["tty"] as? String, "/dev/ttys004")
        XCTAssertEqual(row["reason"] as? String, "core_unreachable")
        let log = recorder.logText()
        XCTAssertEqual(fieldCount(log, "event=attach"), 0)
        XCTAssertEqual(fieldCount(log, "event=reattach"), 0)
        XCTAssertEqual(fieldCount(log, "event=fallback"), 0)
        XCTAssertEqual(fieldCount(log, "event=unresolved"), 1)
    }

    func testRecordedAttachThenIngestWritesNoReattach() {
        let recorder = makeRecorder()
        let panelID = UUID()
        recorder.record(.attach(
            panelID: panelID,
            terminal: "t1",
            servingBuild: HCPin.current.version,
            tty: nil
        ))
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let identity = makeIdentity(core: "core_a", pid: 9, start: 8)
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [key: makeRecord(key: key, state: .running, endReason: nil, tty: nil, pid: 11)],
            bindings: [panelID: key],
            generation: 4,
            sequence: 2
        )
        XCTAssertEqual(fieldCount(recorder.logText(), "event=attach"), 1)
        XCTAssertEqual(fieldCount(recorder.logText(), "event=reattach"), 0)
    }

    func testRecordedTransitionsLogEveryOccurrence() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        let panelID = UUID()
        let build = HCPin.current.version
        recorder.record(.attachFailed(panelID: panelID, terminal: "t4", servingBuild: build, reason: "not_found"))
        clock.advance(1)
        recorder.record(.attach(panelID: panelID, terminal: "t4", servingBuild: build, tty: nil))
        clock.advance(1)
        recorder.record(.attachFailed(panelID: panelID, terminal: "t4", servingBuild: build, reason: "not_found"))
        let failed = lines(recorder.logText(), field: "event=attach_failed")
        XCTAssertEqual(failed.count, 2)
        XCTAssertTrue(failed[0].contains("ts=2023-11-14T22:13:20.000Z"))
        XCTAssertTrue(failed[1].contains("ts=2023-11-14T22:13:22.000Z"))

        recorder.record(.recovery(reason: "foreign_build", result: "recovered", servingBuild: build))
        clock.advance(1)
        recorder.record(.recovery(reason: "foreign_build", result: "recovered", servingBuild: build))
        XCTAssertEqual(fieldCount(recorder.logText(), "event=recovery"), 2)

        recorder.record(.reattach(panelID: panelID, terminal: "t4", servingBuild: build, tty: nil))
        clock.advance(1)
        recorder.record(.reattach(panelID: panelID, terminal: "t4", servingBuild: build, tty: nil))
        let reattached = lines(recorder.logText(), field: "event=reattach")
        XCTAssertEqual(reattached.count, 2)
        XCTAssertNotEqual(reattached[0].split(separator: " ").first, reattached[1].split(separator: " ").first)
    }

    func testUnreachableLogsAgainAfterTheSessionIsReady() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        let panelID = UUID()
        let panel = HCPanelIdentity(panelID: panelID, persistence: .persistent, origin: .restored)
        func pending(generation: UInt64) -> HCDiagnostics {
            HCDiagnostics(
                inventory: HCInventorySnapshot(
                    readiness: .pending(.coreUnreachable),
                    revision: HCRevision(connectionGeneration: generation, sequence: 1)
                ),
                expectedPin: .current,
                unavailableReason: .coreUnreachable
            )
        }
        recorder.ingest(pending(generation: 1), panels: [panel])
        recorder.ingest(pending(generation: 1), panels: [panel])
        XCTAssertEqual(fieldCount(recorder.logText(), "event=unresolved"), 1)
        clock.advance(5)
        recorder.ingest(
            HCDiagnostics(
                inventory: HCInventorySnapshot(
                    readiness: .ready(HCRevision(connectionGeneration: 2, sequence: 1)),
                    revision: HCRevision(connectionGeneration: 2, sequence: 1)
                ),
                expectedPin: .current
            ),
            panels: [panel]
        )
        recorder.ingest(pending(generation: 3), panels: [panel])
        let unresolved = lines(recorder.logText(), field: "event=unresolved")
        XCTAssertEqual(unresolved.count, 2)
        XCTAssertNotEqual(unresolved[0].split(separator: " ").first, unresolved[1].split(separator: " ").first)
    }

    func testReplacementBindingDropsThePreviousTerminalFacts() throws {
        let recorder = makeRecorder()
        let panelID = UUID()
        let identity = makeIdentity(core: "core_a", pid: 9, start: 8)
        let first = HCTerminalKey(owningCoreID: "core_a", localAddress: "t3")
        let process = HCProcessIdentity(pid: 4321, startTimeMicroseconds: 100)
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [first: makeRecord(key: first, state: .running, endReason: nil, tty: "/dev/ttys004", pid: 4321, process: process)],
            bindings: [panelID: first],
            generation: 2,
            sequence: 1
        )
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [first: makeRecord(key: first, state: .running, endReason: nil, tty: nil, pid: nil, process: process)],
            bindings: [panelID: first],
            generation: 2,
            sequence: 2
        )
        var row = try XCTUnwrap((jsonObject(recorder)["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["terminal"] as? String, "t3")
        XCTAssertEqual(row["pid"] as? Int, 4321)
        XCTAssertEqual(row["tty"] as? String, "/dev/ttys004")

        ingestSnapshot(
            recorder,
            identity: identity,
            records: [first: makeRecord(key: first, state: .finished, endReason: "killed", tty: "/dev/ttys004", pid: 4321, process: process)],
            bindings: [panelID: first],
            generation: 2,
            sequence: 3
        )
        let replacement = HCTerminalKey(owningCoreID: "core_a", localAddress: "t4")
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [replacement: makeRecord(key: replacement, state: .starting, endReason: nil, tty: nil, pid: nil)],
            bindings: [panelID: replacement],
            generation: 2,
            sequence: 4
        )
        row = try XCTUnwrap((jsonObject(recorder)["panels"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["terminal"] as? String, "t4")
        XCTAssertEqual(row["lifecycle"] as? String, "live")
        XCTAssertTrue(row["pid"] is NSNull)
        XCTAssertTrue(row["tty"] is NSNull)

        let unreachableID = UUID()
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [first: makeRecord(key: first, state: .running, endReason: nil, tty: "/dev/ttys004", pid: 4321, process: process)],
            bindings: [unreachableID: first],
            generation: 3,
            sequence: 1
        )
        let pending = HCInventorySnapshot(
            readiness: .pending(.coreUnreachable),
            revision: HCRevision(connectionGeneration: 3, sequence: 2),
            records: [replacement: makeRecord(key: replacement, state: .starting, endReason: nil, tty: nil, pid: nil)],
            buildIdentity: identity,
            panelBindings: [unreachableID: replacement]
        )
        recorder.ingest(HCDiagnostics(
            inventory: pending,
            expectedPin: .current,
            servingBuild: identity,
            unavailableReason: .coreUnreachable
        ))
        let panels = try XCTUnwrap(jsonObject(recorder)["panels"] as? [[String: Any]])
        let unresolved = try XCTUnwrap(panels.first { $0["panel_id"] as? String == unreachableID.uuidString })
        XCTAssertEqual(unresolved["terminal"] as? String, "t4")
        XCTAssertEqual(unresolved["lifecycle"] as? String, "unresolved")
        XCTAssertTrue(unresolved["pid"] is NSNull)
        XCTAssertTrue(unresolved["tty"] is NSNull)
    }

    func testDirectUnreachableLogsAgainAfterReattach() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        let panelID = UUID()
        let build = HCPin.current.version
        let panel = HCPanelIdentity(
            panelID: panelID,
            key: HCTerminalKey(owningCoreID: "core_a", localAddress: "t4"),
            persistence: .persistent,
            origin: .restored
        )
        recorder.record(.coreUnreachable(panel: panel, configuredBuild: build))
        recorder.record(.coreUnreachable(panel: panel, configuredBuild: build))
        XCTAssertEqual(lines(recorder.logText(), field: "event=unresolved").count, 1)
        clock.advance(1)
        recorder.record(.reattach(panelID: panelID, terminal: "t4", servingBuild: build, tty: nil))
        clock.advance(1)
        recorder.record(.coreUnreachable(panel: panel, configuredBuild: build))
        let outages = lines(recorder.logText(), field: "event=unresolved")
        XCTAssertEqual(outages.count, 2)
        XCTAssertTrue(outages[0].contains("ts=2023-11-14T22:13:20.000Z"))
        XCTAssertTrue(outages[1].contains("ts=2023-11-14T22:13:22.000Z"))
    }

    func testPinAddressesCountThePathfinderHolderLoss() throws {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        var records: [HCTerminalKey: HCTerminalRecord] = [:]
        var bindings: [UUID: HCTerminalKey] = [:]
        for (offset, address) in ["t2x", "t2y", "t2z"].enumerated() {
            let key = HCTerminalKey(owningCoreID: "core_a", localAddress: address)
            let process = HCProcessIdentity(pid: Int32(21 + offset), startTimeMicroseconds: 100)
            records[key] = makeRecord(
                key: key,
                state: .finished,
                endReason: "holder_lost",
                tty: nil,
                pid: process.pid,
                process: process
            )
            bindings[UUID()] = key
        }
        let killed = HCTerminalKey(owningCoreID: "core_a", localAddress: "t30")
        records[killed] = makeRecord(key: killed, state: .finished, endReason: "killed", tty: nil, pid: 80)
        bindings[UUID()] = killed
        ingestSnapshot(
            recorder,
            identity: identity,
            records: records,
            bindings: bindings,
            generation: 3,
            sequence: 4
        )
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(holderLostLines(recorder.logText()), 1)

        let panels = try XCTUnwrap(jsonObject(recorder)["panels"] as? [[String: Any]])
        let terminals = Set(panels.compactMap { $0["terminal"] as? String })
        XCTAssertEqual(terminals, Set(["t2x", "t2y", "t2z", "t30"]))
        let killedRow = try XCTUnwrap(panels.first { $0["terminal"] as? String == "t30" })
        XCTAssertEqual(killedRow["reason"] as? String, "killed")
        XCTAssertEqual(killedRow["lifecycle"] as? String, "ended")

        // Each later death is a new holder's: a live terminal came in between.
        ingestLiveTerminal(recorder, address: "t88", sequence: 5, generation: 3)
        clock.advance(3)
        recorder.record(.holderLost(coreID: "core_a", terminal: "t1b", discriminator: "p40:1", holderID: nil))
        XCTAssertEqual(recorder.holderLostCount, 2)
        ingestLiveTerminal(recorder, address: "t89", sequence: 6, generation: 3)
        clock.advance(3)
        recorder.record(.holderLost(coreID: "core_a", terminal: "studio/t2x", discriminator: "p41:1", holderID: nil))
        XCTAssertEqual(recorder.holderLostCount, 3)

        recorder.record(.attachFailed(
            panelID: UUID(),
            terminal: "t1b",
            servingBuild: HCPin.current.version,
            reason: "not_found"
        ))
        recorder.record(.attachFailed(
            panelID: UUID(),
            terminal: "studio/t2x",
            servingBuild: HCPin.current.version,
            reason: "not_found"
        ))
        let log = recorder.logText()
        XCTAssertTrue(log.contains("terminal=t1b"))
        XCTAssertTrue(log.contains("terminal=studio/t2x"))

        clock.advance(3)
        recorder.record(.holderLost(coreID: "core_a", terminal: "t0", discriminator: "p70:1", holderID: "p9000:1"))
        recorder.record(.holderLost(coreID: "core_a", terminal: "t2a", discriminator: "p71:1", holderID: "p9001:1"))
        XCTAssertEqual(recorder.holderLostCount, 3)
        recorder.record(.attachFailed(
            panelID: UUID(),
            terminal: "t0",
            servingBuild: HCPin.current.version,
            reason: "not_found"
        ))
        recorder.record(.attachFailed(
            panelID: UUID(),
            terminal: "t2a",
            servingBuild: HCPin.current.version,
            reason: "not_found"
        ))
        let rejected = recorder.logText()
        XCTAssertFalse(rejected.contains("terminal=t0"))
        XCTAssertFalse(rejected.contains("terminal=t2a"))
    }

    private func row(_ recorder: HCDiagnosticRecorder, _ panelID: UUID) throws -> [String: Any] {
        let panels = try XCTUnwrap(jsonObject(recorder)["panels"] as? [[String: Any]])
        return try XCTUnwrap(panels.first { $0["panel_id"] as? String == panelID.uuidString })
    }

    /// P2-F1: a Studio panel stayed `live` in the CLI while its link was down and
    /// the chip said Reconnecting; the row carried no machine and lost the
    /// `studio/` prefix.
    func testARemotePanelRowNamesItsMachineAndReadsUnresolvedWhileTheLinkIsDown() throws {
        let recorder = makeRecorder()
        let remotePanel = UUID(), localPanel = UUID()
        let remoteKey = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t15")
        let localKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        var sequence: UInt64 = 0
        func ingest(_ link: HCMachineAvailability) {
            sequence += 1
            let revision = HCRevision(connectionGeneration: 3, sequence: sequence)
            let records = [
                remoteKey: HCTerminalRecord(key: remoteKey, state: .running, machineName: "studio",
                                            machineAvailability: link, pid: 4242),
                localKey: HCTerminalRecord(key: localKey, state: .running, pid: 99),
            ]
            let snapshot = HCInventorySnapshot(
                readiness: .ready(revision), revision: revision, records: records, buildIdentity: identity,
                panelBindings: [remotePanel: remoteKey, localPanel: localKey], machines: ["studio": link])
            recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
        }

        ingest(.connected)
        var remote = try row(recorder, remotePanel)
        XCTAssertEqual(remote["machine"] as? String, "studio")
        XCTAssertEqual(remote["terminal"] as? String, "studio/t15")
        XCTAssertEqual(remote["lifecycle"] as? String, "live")
        let local = try row(recorder, localPanel)
        XCTAssertTrue(local["machine"] is NSNull)
        XCTAssertEqual(local["terminal"] as? String, "t1")

        ingest(.disconnected)
        ingest(.disconnected)
        remote = try row(recorder, remotePanel)
        XCTAssertEqual(remote["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(remote["reason"] as? String, "connection_lost")
        XCTAssertEqual(remote["machine"] as? String, "studio")
        XCTAssertEqual(try row(recorder, localPanel)["lifecycle"] as? String, "live")
        XCTAssertEqual(lines(recorder.logText(), field: "reason=connection_lost").count, 1)

        ingest(.connected)
        remote = try row(recorder, remotePanel)
        XCTAssertEqual(remote["lifecycle"] as? String, "live")
        XCTAssertTrue(remote["reason"] is NSNull)
    }

    private final class PidLog: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [Int32] = []
        func add(_ pid: Int32) { lock.lock(); pids.append(pid); lock.unlock() }
        var all: [Int32] { lock.lock(); defer { lock.unlock() }; return pids }
    }

    /// F2: every row carried `tty: null` because nothing filled it. The core does
    /// not report one; a local running terminal's comes from the kernel, once.
    func testALocalTerminalsTTYIsReadFromTheKernelOnceAndARemoteOneIsNotRead() throws {
        let reads = PidLog()
        let recorder = makeRecorder(ttyResolver: { pid in
            reads.add(pid)
            return (HCProcessIdentity(pid: pid, startTimeMicroseconds: 7), "/dev/ttys042")
        })
        let localPanel = UUID(), remotePanel = UUID()
        let localKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let remoteKey = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t2")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        for sequence in UInt64(1)...3 {
            let revision = HCRevision(connectionGeneration: 3, sequence: sequence)
            let records = [
                localKey: HCTerminalRecord(key: localKey, state: .running, pid: 4242),
                remoteKey: HCTerminalRecord(key: remoteKey, state: .running, machineName: "studio",
                                            machineAvailability: .connected, pid: 77),
            ]
            let snapshot = HCInventorySnapshot(
                readiness: .ready(revision), revision: revision, records: records, buildIdentity: identity,
                panelBindings: [localPanel: localKey, remotePanel: remoteKey], machines: ["studio": .connected])
            recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
        }
        XCTAssertEqual(try row(recorder, localPanel)["tty"] as? String, "/dev/ttys042")
        XCTAssertEqual(try row(recorder, localPanel)["pid"] as? Int, 4242)
        XCTAssertTrue(try row(recorder, remotePanel)["tty"] is NSNull)
        XCTAssertEqual(reads.all, [4242], "one read for the local terminal, none for the remote one, none on later snapshots")
    }

    /// C11H-137: hc reports the setuid-root `/usr/bin/login` pid. `proc_pidinfo`
    /// refuses that effective uid, which is why every row was `tty: null`.
    /// The login's own controlling tty (sysctl) is the session pty. A root
    /// process whose real uid is not ours is not our session, and a remote
    /// pid is not looked up on this Mac.
    func testASetuidRootLoginStillYieldsItsTTYAndAForeignRootDoesNot() throws {
        let login = Int32(4242)
        let device: UInt32 = 42
        let identity = HCProcessIdentity(pid: login, startTimeMicroseconds: 99)
        let ours = UInt32(501)
        let loginRecord = HCSessionTTY.RecordedProcess(
            identity: identity, effectiveUID: 0, realUID: ours, controllingTTYDevice: device)
        let resolve: (Int32) -> (process: HCProcessIdentity, tty: String)? = { pid in
            HCSessionTTY.resolve(pid: pid, ourUID: ours, owned: { _ in nil }, recorded: { asked in
                asked == login ? loginRecord : nil
            }, ttyName: { $0 == device ? "ttys016" : nil })
        }
        XCTAssertEqual(resolve(login)?.tty, "/dev/ttys016")
        XCTAssertEqual(resolve(login)?.process, identity)

        let shell = HCProcessIdentity(pid: 50, startTimeMicroseconds: 3)
        let fellThrough = PidLog()
        let owned = HCSessionTTY.resolve(pid: 50, ourUID: ours, owned: { _ in
            HCAgentRecoveryProcessFacts(identity: shell, controllingTTYDevice: 7)
        }, recorded: { _ in
            fellThrough.add(50)
            return nil
        }, ttyName: { $0 == 7 ? "ttys003" : nil })
        XCTAssertEqual(owned?.tty, "/dev/ttys003")
        XCTAssertEqual(owned?.process, shell)
        XCTAssertEqual(fellThrough.all, [], "a same-uid tty must not fall through to the login read")

        let foreign = HCSessionTTY.resolve(pid: 9, ourUID: ours, owned: { _ in nil }, recorded: { _ in
            HCSessionTTY.RecordedProcess(
                identity: HCProcessIdentity(pid: 9, startTimeMicroseconds: 1),
                effectiveUID: 0, realUID: 0, controllingTTYDevice: device)
        }, ttyName: { _ in "ttys016" })
        XCTAssertNil(foreign, "another user's setuid root process is not this session")

        let noTTY = HCSessionTTY.resolve(pid: login, ourUID: ours, owned: { _ in nil }, recorded: { _ in
            HCSessionTTY.RecordedProcess(
                identity: identity, effectiveUID: 0, realUID: ours, controllingTTYDevice: nil)
        }, ttyName: { _ in "ttys016" })
        XCTAssertNil(noTTY)

        let reads = PidLog()
        let recorder = makeRecorder(ttyResolver: { pid in
            reads.add(pid)
            return resolve(pid)
        })
        let localPanel = UUID(), remotePanel = UUID()
        let localKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let remoteKey = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t2")
        let build = makeIdentity(core: "core_a", pid: 18267, start: 9)
        recorder.ingest(readySnapshot([
            localKey: HCTerminalRecord(key: localKey, state: .running, pid: login),
            remoteKey: HCTerminalRecord(key: remoteKey, state: .running, machineName: "studio",
                                       machineAvailability: .connected, pid: 77),
        ], identity: build, bindings: [localPanel: localKey, remotePanel: remoteKey]))
        XCTAssertEqual(try row(recorder, localPanel)["tty"] as? String, "/dev/ttys016")
        XCTAssertEqual(try row(recorder, localPanel)["pid"] as? Int, Int(login))
        XCTAssertTrue(try row(recorder, remotePanel)["tty"] is NSNull)
        XCTAssertEqual(reads.all, [login], "the remote pid is not resolved on this Mac")
        XCTAssertNil(HCSessionTTY.readRecorded(Int32.max))
        XCTAssertNil(HCSessionTTY.readRecorded(1))
    }

    /// F2: a terminal panel of a hidden workspace, known to the app but not yet
    /// bound, had no row at all.
    func testAKnownPanelThatNeverBoundStillGetsARow() throws {
        let recorder = makeRecorder()
        let keyedPanel = UUID(), freshPanel = UUID()
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: "t7")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        let revision = HCRevision(connectionGeneration: 3, sequence: 1)
        let snapshot = HCInventorySnapshot(
            readiness: .ready(revision), revision: revision,
            records: [key: HCTerminalRecord(key: key, state: .running, pid: 31)],
            buildIdentity: identity, panelBindings: [:])
        recorder.ingest(
            HCDiagnostics(inventory: snapshot, servingBuild: identity),
            panels: [
                HCPanelIdentity(panelID: keyedPanel, key: key, persistence: .persistent, origin: .restored),
                HCPanelIdentity(panelID: freshPanel, persistence: .persistent, origin: .fresh),
            ])
        let keyed = try row(recorder, keyedPanel)
        XCTAssertEqual(keyed["terminal"] as? String, "t7")
        XCTAssertEqual(keyed["lifecycle"] as? String, "live")
        XCTAssertEqual(keyed["pid"] as? Int, 31)
        let fresh = try row(recorder, freshPanel)
        XCTAssertEqual(fresh["lifecycle"] as? String, "new")
        XCTAssertTrue(fresh["terminal"] is NSNull)
    }

    private func readySnapshot(
        _ records: [HCTerminalKey: HCTerminalRecord],
        identity: HCBuildIdentity,
        bindings: [UUID: HCTerminalKey] = [:],
        readiness: HCReadiness? = nil,
        sequence: UInt64 = 1
    ) -> HCDiagnostics {
        let revision = HCRevision(connectionGeneration: 3, sequence: sequence)
        return HCDiagnostics(
            inventory: HCInventorySnapshot(
                readiness: readiness ?? .ready(revision), revision: revision, records: records,
                buildIdentity: identity, panelBindings: bindings, machines: ["studio": .connected]),
            servingBuild: identity)
    }

    /// Review 1 of #114: a restored Studio panel in a hidden workspace, a ready
    /// local inventory, the remote mirror not back yet. The panel was left out,
    /// or kept a stale `live`. A saved key the inventory does not show is
    /// uncertainty, never absence.
    func testAKnownRemotePanelWhoseRecordIsMissingIsUnresolvedNotAbsentOrStaleLive() throws {
        let recorder = makeRecorder()
        let panel = UUID(), gone = UUID()
        let key = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t15")
        let finishedKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t3")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        let known = [
            HCPanelIdentity(panelID: panel, key: key, persistence: .persistent, origin: .restored),
            HCPanelIdentity(panelID: gone, key: finishedKey, persistence: .persistent, origin: .restored),
        ]
        // First sight is an empty ready inventory: a row, unresolved, with the saved identity.
        recorder.ingest(readySnapshot([:], identity: identity), panels: known)
        var remote = try row(recorder, panel)
        XCTAssertEqual(remote["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(remote["reason"] as? String, "connection_lost")
        XCTAssertEqual(remote["terminal"] as? String, "t15")

        // The mirror returns: live, with its machine.
        let running = HCTerminalRecord(key: key, state: .running, machineName: "studio",
                                       machineAvailability: .connected, pid: 4242)
        let finished = HCTerminalRecord(key: finishedKey, state: .finished, endReason: "exit")
        recorder.ingest(readySnapshot([key: running, finishedKey: finished], identity: identity, sequence: 2), panels: known)
        XCTAssertEqual(try row(recorder, panel)["lifecycle"] as? String, "live")
        XCTAssertEqual(try row(recorder, panel)["terminal"] as? String, "studio/t15")
        XCTAssertEqual(try row(recorder, gone)["lifecycle"] as? String, "ended")

        // It drops out again: no stale `live`, the identity stays, an end is not undone.
        recorder.ingest(readySnapshot([:], identity: identity, sequence: 3), panels: known)
        remote = try row(recorder, panel)
        XCTAssertEqual(remote["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(remote["reason"] as? String, "connection_lost")
        XCTAssertEqual(remote["terminal"] as? String, "studio/t15")
        XCTAssertEqual(remote["machine"] as? String, "studio")
        XCTAssertEqual(try row(recorder, gone)["lifecycle"] as? String, "ended")
    }

    /// Review 1 of #114: a keyless panel whose creation is outstanding, or whose
    /// inventory is not ready, is unresolved with the resolver's reason. It is
    /// `new` only with authoritative absence and no pending intent.
    func testAnOutstandingCreationOrAPendingInventoryIsNotReportedAsNew() throws {
        let recorder = makeRecorder()
        let pending = UUID(), fresh = UUID(), waiting = UUID()
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        let panels = [
            HCPanelIdentity(panelID: pending, persistence: .persistent, creationID: UUID(), origin: .restored),
            HCPanelIdentity(panelID: fresh, persistence: .persistent, origin: .fresh),
        ]
        recorder.ingest(readySnapshot([:], identity: identity), panels: panels)
        XCTAssertEqual(try row(recorder, pending)["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(try row(recorder, pending)["reason"] as? String, "creation_pending")
        XCTAssertEqual(try row(recorder, fresh)["lifecycle"] as? String, "new")

        // The inventory has not been read yet: nothing is known to be absent.
        let notReady = [HCPanelIdentity(panelID: waiting, persistence: .persistent, origin: .fresh)]
        recorder.ingest(
            readySnapshot([:], identity: identity, readiness: .pending(.inventoryPending), sequence: 2),
            panels: notReady)
        XCTAssertEqual(try row(recorder, waiting)["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(try row(recorder, waiting)["reason"] as? String, "inventory_pending")
    }

    /// Review 1 of #114: the machine and `studio/t15` survive the local core being
    /// unreachable, which is when remote identity is most needed. Also from a
    /// first snapshot that is already an outage.
    func testAnAtlasRowKeepsItsMachineAndAddressThroughALocalCoreOutage() throws {
        let panel = UUID()
        let key = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t15")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        let running = HCTerminalRecord(key: key, state: .running, machineName: "studio",
                                       machineAvailability: .connected, pid: 4242)
        let outage: (UInt64, [HCTerminalKey: HCTerminalRecord]) -> HCDiagnostics = { sequence, records in
            self.readySnapshot(records, identity: identity, bindings: [panel: key],
                               readiness: .pending(.coreUnreachable), sequence: sequence)
        }

        let recorder = makeRecorder()
        recorder.ingest(readySnapshot([key: running], identity: identity, bindings: [panel: key]))
        recorder.ingest(outage(2, [key: running]))
        var remote = try row(recorder, panel)
        XCTAssertEqual(remote["lifecycle"] as? String, "unresolved")
        XCTAssertEqual(remote["reason"] as? String, "core_unreachable")
        XCTAssertEqual(remote["terminal"] as? String, "studio/t15")
        XCTAssertEqual(remote["machine"] as? String, "studio")
        // The retained snapshot may not carry the record at all.
        recorder.ingest(outage(3, [:]))
        remote = try row(recorder, panel)
        XCTAssertEqual(remote["terminal"] as? String, "studio/t15")
        XCTAssertEqual(remote["machine"] as? String, "studio")

        let firstSight = makeRecorder()
        firstSight.ingest(outage(1, [key: running]))
        remote = try row(firstSight, panel)
        XCTAssertEqual(remote["terminal"] as? String, "studio/t15")
        XCTAssertEqual(remote["machine"] as? String, "studio")
    }

    /// The Glass Perf Monitor saw `t12` for both the laptop's own terminal and
    /// Studio's, and `tty` null on every row. The reply names the machine, and
    /// the text form of `hc-diagnostics` prints it, so the two cannot be mixed.
    func testALocalAndAnAtlasTerminalWithTheSameLocalAddressAreTwoRowsInTheReplyAndTheText() throws {
        let recorder = makeRecorder(ttyResolver: { pid in
            (HCProcessIdentity(pid: pid, startTimeMicroseconds: 7), "/dev/ttys042")
        })
        let localPanel = UUID(), atlasPanel = UUID()
        let localKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t12")
        let atlasKey = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t12")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        recorder.ingest(readySnapshot([
            localKey: HCTerminalRecord(key: localKey, state: .running, pid: 4242),
            atlasKey: HCTerminalRecord(key: atlasKey, state: .running, machineName: "studio",
                                       machineAvailability: .connected, pid: 77),
        ], identity: identity, bindings: [localPanel: localKey, atlasPanel: atlasKey]))
        let local = try row(recorder, localPanel), studio = try row(recorder, atlasPanel)
        XCTAssertEqual(local["terminal"] as? String, "t12")
        XCTAssertTrue(local["machine"] is NSNull)
        XCTAssertEqual(local["tty"] as? String, "/dev/ttys042")
        XCTAssertEqual(studio["terminal"] as? String, "studio/t12")
        XCTAssertEqual(studio["machine"] as? String, "studio")
        XCTAssertTrue(studio["tty"] is NSNull, "a remote terminal's tty is the other machine's")
        let text = HCDiagnosticsText.lines(try jsonObject(recorder)).filter { $0.contains("panel_id=") }
        XCTAssertEqual(text.filter { $0.contains("terminal=t12 ") && $0.contains("tty=/dev/ttys042") }.count, 1)
        XCTAssertEqual(text.filter { $0.contains("terminal=studio/t12 ") && $0.contains("machine=studio") }.count, 1)
    }

    /// C11H-235: each live local terminal reports its root form (the kernel's
    /// answer for the pid it already read for the tty), the summary counts the
    /// login-rooted ones, and a remote terminal's pid never reaches the kernel.
    func testRootFormIsReadForLiveLocalTerminalsOnlyAndLoginRootsAreCounted() throws {
        final class Asked: @unchecked Sendable { let lock = NSLock(); var pids: [Int32] = [] }
        let asked = Asked()
        let recorder = makeRecorder(ttyResolver: { pid in
            (HCProcessIdentity(pid: pid, startTimeMicroseconds: 7), "/dev/ttys042")
        }, rootResolver: { pid, process in
            asked.lock.lock(); asked.pids.append(pid); asked.lock.unlock()
            XCTAssertEqual(process.startTimeMicroseconds, 7)
            return pid == 4242 ? HCTerminalRootForm.login : HCTerminalRootForm.shell
        })
        let loginPanel = UUID(), shellPanel = UUID(), atlasPanel = UUID()
        let loginKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t1")
        let shellKey = HCTerminalKey(owningCoreID: "core_a", localAddress: "t2")
        let atlasKey = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t3")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        recorder.ingest(readySnapshot([
            loginKey: HCTerminalRecord(key: loginKey, state: .running, pid: 4242),
            shellKey: HCTerminalRecord(key: shellKey, state: .running, pid: 4343),
            // The remote record even names a process identity for pid 77, so
            // only the machine guard keeps that pid from a local syscall.
            atlasKey: HCTerminalRecord(key: atlasKey, state: .running, machineName: "studio",
                                       machineAvailability: .connected, pid: 77,
                                       localProcessIdentity: HCProcessIdentity(pid: 77, startTimeMicroseconds: 7)),
        ], identity: identity, bindings: [loginPanel: loginKey, shellPanel: shellKey, atlasPanel: atlasKey]))
        XCTAssertEqual(try row(recorder, loginPanel)["root"] as? String, "login")
        XCTAssertEqual(try row(recorder, shellPanel)["root"] as? String, "shell")
        XCTAssertEqual(try row(recorder, atlasPanel)["root"] as? String, "n/a")
        XCTAssertEqual(try jsonObject(recorder)["login_rooted"] as? Int, 1)
        asked.lock.lock(); let pids = asked.pids; asked.lock.unlock()
        XCTAssertFalse(pids.contains(77), "a remote terminal's pid is the other machine's")
        let text = HCDiagnosticsText.lines(try jsonObject(recorder))
        XCTAssertTrue(text.contains("login_rooted=1"))
        XCTAssertEqual(text.filter { $0.contains("terminal=t1 ") && $0.contains("root=login") }.count, 1)
    }

    func testRootFormNamesTheShellLoginAndAnyOtherProgram() {
        XCTAssertEqual(HCTerminalRootForm.classify(command: "zsh"), "shell")
        XCTAssertEqual(HCTerminalRootForm.classify(command: "-zsh"), "shell")
        XCTAssertEqual(HCTerminalRootForm.classify(command: "bash"), "shell")
        XCTAssertEqual(HCTerminalRootForm.classify(command: "login"), "login")
        XCTAssertEqual(HCTerminalRootForm.classify(command: "node"), "other")
    }

    /// C11H-124: an inventory refresh after a panel opens or closes is pending for a
    /// few milliseconds with the link up. The recorder read that as a lost link
    /// and logged connection_lost, then live, for every remote panel at once.
    func testAPendingInventoryRefreshWithTheLinkUpIsNotALostLink() throws {
        let recorder = makeRecorder()
        let panel = UUID()
        let key = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t2c")
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        let running = HCTerminalRecord(key: key, state: .running, machineName: "studio",
                                       machineAvailability: .connected, pid: 4242)
        recorder.ingest(readySnapshot([key: running], identity: identity, bindings: [panel: key]))
        recorder.ingest(readySnapshot([key: running], identity: identity, bindings: [panel: key],
                                      readiness: .pending(.inventoryPending), sequence: 2))
        XCTAssertEqual(try row(recorder, panel)["lifecycle"] as? String, "live")
        recorder.ingest(readySnapshot([key: running], identity: identity, bindings: [panel: key], sequence: 3))
        XCTAssertEqual(try row(recorder, panel)["lifecycle"] as? String, "live")
        XCTAssertEqual(lines(recorder.logText(), field: "reason=connection_lost").count, 0)
        XCTAssertEqual(lines(recorder.logText(), field: "lifecycle=live").count, 1, "one live line, not one per refresh")
    }

    /// C11H-196: with Studio unreachable after the reboot, any shard's ready
    /// snapshot cleared every `unresolved:` line and the owning shard wrote all
    /// 28 again on its next snapshot (~700 lines/s across nine shards). A
    /// shard's ready snapshots after its first no longer clear anything.
    func testAnotherShardsReadySnapshotsDoNotRewriteAnOutage() throws {
        let recorder = makeRecorder()
        let shardA = HCShardIdentity(session: "c11", index: 0)
        let shardB = HCShardIdentity(session: "c11-s1", index: 1)
        let panels = (0..<28).map { n in
            HCPanelIdentity(panelID: UUID(), key: HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t\(n)"))
        }
        func ready(_ sequence: UInt64, core: String) -> HCDiagnostics {
            let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
            return HCDiagnostics(inventory: HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: [:], buildIdentity: makeIdentity(core: core, pid: 100, start: 1),
                machines: ["studio": .disconnected]), expectedPin: .current)
        }
        for sequence in UInt64(1)...40 {
            recorder.ingest(ready(sequence, core: "core_a"), panels: panels, shard: shardA,
                            shardOf: { _ in shardA })
            recorder.ingest(ready(sequence, core: "core_b"), panels: [], shard: shardB, shardOf: { _ in shardA })
        }
        let outages = lines(recorder.logText(), field: "event=unresolved").count
        XCTAssertLessThanOrEqual(outages, 2 * panels.count, "each panel's outage is written once, plus once after the other shard's first ready")
    }

    /// C11H-196 (9): shard s1 still binds the panel to its finished pre-reboot
    /// terminal while its replacement runs on s2. Reads must not flap.
    func testAStaleEndedBindingOnAnotherShardDoesNotHideTheLiveReplacement() throws {
        let recorder = makeRecorder()
        let panelID = UUID()
        let old = HCTerminalKey(owningCoreID: "core_s1", localAddress: "t2")
        let fresh = HCTerminalKey(owningCoreID: "core_s2", localAddress: "t10")
        let s1 = HCShardIdentity(session: "c11-s1", index: 1), s2 = HCShardIdentity(session: "c11-s2", index: 2)
        let identity = [HCPanelIdentity(panelID: panelID, key: fresh)]
        func snapshot(_ key: HCTerminalKey, _ state: HCTerminalState, core: String, sequence: UInt64) -> HCDiagnostics {
            let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
            let record = HCTerminalRecord(key: key, state: state, labels: ["c11.panel": panelID.uuidString],
                                          pid: state == .running ? 77 : nil, endReason: state == .finished ? "stopped_by_restart" : nil)
            return HCDiagnostics(inventory: HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                records: [key: record], buildIdentity: makeIdentity(core: core, pid: 10, start: 1),
                panelBindings: [panelID: key]), expectedPin: .current)
        }
        for sequence in UInt64(1)...5 {
            recorder.ingest(snapshot(fresh, .running, core: "core_s2", sequence: sequence), panels: identity, shard: s2)
            recorder.ingest(snapshot(old, .finished, core: "core_s1", sequence: sequence), panels: identity, shard: s1)
            XCTAssertEqual(try row(recorder, panelID)["lifecycle"] as? String, "live")
            XCTAssertEqual(try row(recorder, panelID)["terminal"] as? String, "t10")
        }
    }

    func testPendingRefreshKeepsAnAlreadyDownRemoteLinkDown() throws {
        // Both ingest routes must carry the previous row: an attached binding
        // and a known panel found through the retained inventory record.
        for bound in [true, false] {
            let recorder = HCDiagnosticRecorder(
                logFile: directory.appendingPathComponent("churn-\(bound).log"),
                counterFile: directory.appendingPathComponent("churn-\(bound).json"),
                ttyResolver: { _ in nil })
            let panel = UUID(), key = HCTerminalKey(owningCoreID: "core_atlas", localAddress: "t2c")
            let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
            var sequence: UInt64 = 0
            func ingest(_ link: HCMachineAvailability, pending: HCUnavailableReason? = nil) {
                sequence += 1
                let revision = HCRevision(connectionGeneration: 3, sequence: sequence)
                let record = HCTerminalRecord(key: key, state: .running, machineName: "studio",
                                              machineAvailability: link, pid: 4242)
                let snapshot = HCInventorySnapshot(readiness: pending.map { .pending($0) } ?? .ready(revision),
                    revision: revision, records: [key: record], buildIdentity: identity,
                    panelBindings: bound ? [panel: key] : [:], machines: ["studio": link])
                recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity),
                                panels: [HCPanelIdentity(panelID: panel, key: key)])
            }
            ingest(.connected)
            ingest(.disconnected)
            ingest(.disconnected, pending: .inventoryPending)
            XCTAssertEqual(try row(recorder, panel)["lifecycle"] as? String, "unresolved")
            XCTAssertEqual(try row(recorder, panel)["reason"] as? String, "connection_lost")
            ingest(.disconnected)
            XCTAssertEqual(lines(recorder.logText(), field: "reason=connection_lost").count, 1)
            XCTAssertEqual(lines(recorder.logText(), field: "lifecycle=live").count, 1)
            ingest(.connected)
            ingest(.connected, pending: .connectionLost)
            XCTAssertEqual(try row(recorder, panel)["lifecycle"] as? String, "unresolved",
                           "only inventoryPending preserves the previous live verdict")
        }
    }

    /// F11: one holder kill ended 150 terminals and counted 2. The Validator's
    /// log stamped the two counts 2.4 s apart: the recorder took longer than the
    /// 2 s incident window to walk the one snapshot, so the terminals past the
    /// window opened a second incident. One snapshot is one observation.
    func testOneHolderKillIsOneCountHoweverLongTheSnapshotTakesToWalk() {
        let clock = ManualClock()
        clock.step = 0.5
        let recorder = makeRecorder(clock: clock)
        let addresses = (1...60).map { "t\($0)" }
        ingestHolderLoss(recorder, addresses: addresses, sequence: 1, generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)
        XCTAssertEqual(holderLostLines(recorder.logText()), 1)

        // A different kill, well after, is its own count: the fix merges one
        // snapshot's endings, it does not blind the counter.
        clock.step = 0
        ingestLiveTerminal(recorder, address: "t91", sequence: 2, generation: 4)
        clock.advance(30)
        ingestHolderLoss(recorder, addresses: ["t90"], sequence: 3, generation: 4, pidBase: 500)
        XCTAssertEqual(recorder.holderLostCount, 2)
        XCTAssertEqual(holderLostLines(recorder.logText()), 2)
    }

    /// F11, Grok's review of #101: the Validator's log had `count=1`, an attach
    /// 12 ms later, then `count=2` 2.4 s after the first, so the kill reached the
    /// recorder as two snapshots and the clock inside each walk did not join them.
    /// One holder kill is one count until a later snapshot shows a live terminal
    /// on the core (a new holder).
    ///
    /// The per-terminal `event=lifecycle … reason=holder_lost` lines are
    /// `panelEnded`, not the count; they stay (T9.4 counts them separately).
    func testOneHolderKillDeliveredAsTwoSnapshotsPastTheWindowIsOneCount() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        ingestHolderLoss(recorder, addresses: ["t1", "t2", "t3"], sequence: 1, generation: 3)
        XCTAssertEqual(recorder.holderLostCount, 1)
        clock.advance(3)
        ingestHolderLoss(recorder, addresses: ["t4", "t5"], sequence: 2, generation: 3, pidBase: 40)
        XCTAssertEqual(recorder.holderLostCount, 1, "the same kill, seen again 3 s later, counted twice")
        XCTAssertEqual(holderLostLines(recorder.logText()), 1)

        ingestLiveTerminal(recorder, address: "t20", sequence: 3, generation: 3)
        clock.advance(3)
        ingestHolderLoss(recorder, addresses: ["t20x"], sequence: 4, generation: 3, pidBase: 80)
        XCTAssertEqual(recorder.holderLostCount, 2, "a new holder's death after a live snapshot is its own count")
        XCTAssertEqual(holderLostLines(recorder.logText()), 2)
    }

    /// A snapshot that still carries the dying terminals and the new holder's
    /// first live row closes the incident after its walk, not part-way through.
    func testALiveRowInTheSnapshotThatOpensTheIncidentDoesNotCloseItEarly() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        var records: [HCTerminalKey: HCTerminalRecord] = [:]
        var bindings: [UUID: HCTerminalKey] = [:]
        let live = HCTerminalKey(owningCoreID: "core_a", localAddress: "t0")
        records[live] = makeRecord(key: live, state: .running, endReason: nil, tty: nil, pid: 7,
                                   process: HCProcessIdentity(pid: 7, startTimeMicroseconds: 5))
        bindings[UUID()] = live
        for address in ["t1", "t2"] {
            let key = HCTerminalKey(owningCoreID: "core_a", localAddress: address)
            let process = HCProcessIdentity(pid: 10 + Int32(address.dropFirst())!, startTimeMicroseconds: 100)
            records[key] = makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil, pid: process.pid, process: process)
            bindings[UUID()] = key
        }
        ingestSnapshot(recorder, identity: identity, records: records, bindings: bindings, generation: 3, sequence: 1)
        XCTAssertEqual(recorder.holderLostCount, 1)
        clock.advance(3)
        ingestHolderLoss(recorder, addresses: ["t3"], sequence: 2, generation: 3, pidBase: 40)
        XCTAssertEqual(recorder.holderLostCount, 1)
    }

    private func ingestLiveTerminal(_ recorder: HCDiagnosticRecorder, address: String, sequence: UInt64, generation: UInt64) {
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: address)
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [key: makeRecord(key: key, state: .running, endReason: nil, tty: nil, pid: 900 + Int32(sequence),
                                      process: HCProcessIdentity(pid: 900 + Int32(sequence), startTimeMicroseconds: 5))],
            bindings: [UUID(): key],
            generation: generation,
            sequence: sequence
        )
    }

    private func holderLostLines(_ log: String) -> Int {
        log.split(separator: "\n").filter { $0.contains(" event=holder_lost ") }.count
    }

    private func unkeyedLines(_ log: String) -> Int {
        log.split(separator: "\n").filter { $0.contains("event=holder_lost_unkeyed") }.count
    }

    /// C11H-103 (L4 amendment, condition 5): every return home is one
    /// diagnostics line naming the panel, terminal, workspace and reason.
    func testEveryReturnHomeWritesOneLine() {
        let recorder = makeRecorder()
        let panel = UUID(), workspace = UUID()
        recorder.record(.recoveredHome(panelID: panel, terminal: "t2v", workspaceID: workspace, reason: "owner_missing_from_layout"))
        recorder.record(.recoveredHome(panelID: panel, terminal: "t2v", workspaceID: workspace, reason: "owner_missing_from_layout"))
        let returned = lines(recorder.logText(), field: "event=recovered_home")
        XCTAssertEqual(returned.count, 2, "never silent, never coalesced")
        for line in returned {
            XCTAssertTrue(line.contains("panel_id=\(panel.uuidString)"), line)
            XCTAssertTrue(line.contains("terminal=t2v"), line)
            XCTAssertTrue(line.contains("workspace_id=\(workspace.uuidString)"), line)
            XCTAssertTrue(line.contains("reason=owner_missing_from_layout"), line)
        }
    }

    private func fieldCount(_ log: String, _ field: String) -> Int {
        lines(log, field: field).count
    }

    private func lines(_ log: String, field: String) -> [String] {
        log.split(separator: "\n").filter { line in
            line.split(separator: " ").contains(Substring(field))
        }.map(String.init)
    }

    private func makeRecorder(
        maxLogBytes: Int = 1_048_576,
        clock: ManualClock? = nil,
        ttyResolver: @escaping HCDiagnosticRecorder.TTYResolver = { _ in nil },
        rootResolver: @escaping HCDiagnosticRecorder.RootResolver = { _, _ in nil }
    ) -> HCDiagnosticRecorder {
        let now: @Sendable () -> Date = {
            clock?.now() ?? Date()
        }
        return HCDiagnosticRecorder(
            logFile: directory.appendingPathComponent("hc-diagnostics.log"),
            counterFile: directory.appendingPathComponent("holder-lost.json"),
            maxLogBytes: maxLogBytes,
            now: now,
            ttyResolver: ttyResolver,
            rootResolver: rootResolver
        )
    }

    private func makeIdentity(core: String, pid: Int32, start: UInt64) -> HCBuildIdentity {
        HCBuildIdentity(
            pin: .current,
            executablePath: "/Users/example/.local/share/c11/hc",
            fileIdentity: HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5),
            process: HCProcessIdentity(pid: pid, startTimeMicroseconds: start),
            coreID: core,
            protocolGeneration: 1
        )
    }

    private func makeRecord(
        key: HCTerminalKey,
        state: HCTerminalState,
        endReason: String?,
        tty: String?,
        pid: Int32? = nil,
        process: HCProcessIdentity? = nil
    ) -> HCTerminalRecord {
        HCTerminalRecord(key: key, state: state, pid: pid, endReason: endReason, tty: tty, localProcessIdentity: process)
    }

    private func ingestBareHolderLoss(_ recorder: HCDiagnosticRecorder, address: String, generation: UInt64) {
        let key = HCTerminalKey(owningCoreID: "core_a", localAddress: address)
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        ingestSnapshot(
            recorder,
            identity: identity,
            records: [key: makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil)],
            bindings: [UUID(): key],
            generation: generation,
            sequence: generation
        )
    }

    private func ingestSnapshot(
        _ recorder: HCDiagnosticRecorder,
        identity: HCBuildIdentity,
        records: [HCTerminalKey: HCTerminalRecord],
        bindings: [UUID: HCTerminalKey],
        generation: UInt64,
        sequence: UInt64
    ) {
        let snapshot = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: generation, sequence: sequence)),
            revision: HCRevision(connectionGeneration: generation, sequence: sequence),
            records: records,
            buildIdentity: identity,
            panelBindings: bindings
        )
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
    }

    private func ingestHolderLoss(
        _ recorder: HCDiagnosticRecorder,
        addresses: [String],
        sequence: UInt64,
        generation: UInt64,
        killedAddress: String? = nil,
        pidBase: Int32 = 10
    ) {
        let identity = makeIdentity(core: "core_a", pid: 18267, start: 9)
        var records: [HCTerminalKey: HCTerminalRecord] = [:]
        var bindings: [UUID: HCTerminalKey] = [:]
        for address in addresses {
            let key = HCTerminalKey(owningCoreID: "core_a", localAddress: address)
            let suffix = Int32(address.dropFirst()) ?? 0
            let process = HCProcessIdentity(pid: pidBase + suffix, startTimeMicroseconds: 100)
            records[key] = makeRecord(key: key, state: .finished, endReason: "holder_lost", tty: nil, pid: process.pid, process: process)
            bindings[UUID()] = key
        }
        if let killedAddress {
            let key = HCTerminalKey(owningCoreID: "core_a", localAddress: killedAddress)
            records[key] = makeRecord(key: key, state: .finished, endReason: "killed", tty: nil, pid: 80)
            bindings[UUID()] = key
        }
        let snapshot = HCInventorySnapshot(
            readiness: .ready(HCRevision(connectionGeneration: generation, sequence: sequence)),
            revision: HCRevision(connectionGeneration: generation, sequence: sequence),
            records: records,
            buildIdentity: identity,
            panelBindings: bindings
        )
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity))
    }

    private func jsonObject(_ recorder: HCDiagnosticRecorder) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: recorder.jsonObject())
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonText(_ recorder: HCDiagnosticRecorder) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: recorder.jsonObject())
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
