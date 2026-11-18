import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-235: a mass outside-signal end (three or more kept agent panels whose
/// terminal roots a signal from outside c11 ended within 5 seconds) is
/// reported once and offers Resume all, with no flag (C11H-240); one end alone
/// stays C11H-232's single offer.
@MainActor
final class HCMassSignalEndTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_900_000)

    // MARK: detector

    private func end(_ n: Int, at seconds: TimeInterval, signal: Int32 = SIGTERM) -> HCMassSignalEndDetector.End {
        HCMassSignalEndDetector.End(panelID: UUID(), endedKey: HCTerminalKey(owningCoreID: "core_a", localAddress: "t\(n)"),
                                    signal: signal, endedAt: t0.addingTimeInterval(seconds))
    }

    func testThreeEndsWithinTheWindowFormOneMassEndOnTheThird() {
        var detector = HCMassSignalEndDetector()
        XCTAssertEqual(detector.add(end(1, at: 0)), .none)
        XCTAssertEqual(detector.add(end(2, at: 1.5)), .none)
        guard case .formed(let id) = detector.add(end(3, at: 4.9)) else { return XCTFail("three ends within 5 s") }
        XCTAssertEqual(detector.mass(id)?.members.count, 3)
    }

    func testThreeEndsSpreadWiderThanTheWindowNeverChainIntoAMassEnd() {
        var detector = HCMassSignalEndDetector()
        XCTAssertEqual(detector.add(end(1, at: 0)), .none)
        XCTAssertEqual(detector.add(end(2, at: 4)), .none)
        XCTAssertEqual(detector.add(end(3, at: 8)), .none, "each pair is within 5 s, the three are not")
        XCTAssertTrue(detector.masses.isEmpty)
    }

    func testEndsArrivingOutOfOrderGroupByTheirEndTimesAndLateOnesJoin() {
        var detector = HCMassSignalEndDetector()
        XCTAssertEqual(detector.add(end(1, at: 3)), .none)
        XCTAssertEqual(detector.add(end(2, at: 0.5)), .none)
        guard case .formed(let id) = detector.add(end(3, at: 2)) else { return XCTFail("three ends within 5 s") }
        XCTAssertEqual(detector.add(end(4, at: 4.5)), .joined(id))
        XCTAssertEqual(detector.add(end(5, at: 30)), .none, "far later: not the same accident")
        XCTAssertEqual(detector.mass(id)?.members.count, 4)
    }

    func testTheSameEndReportedTwiceCountsOnce() {
        var detector = HCMassSignalEndDetector()
        let once = end(1, at: 0)
        XCTAssertEqual(detector.add(once), .none)
        XCTAssertEqual(detector.add(once), .none)
        XCTAssertEqual(detector.add(end(2, at: 1)), .none, "two distinct ends are not three")
        XCTAssertTrue(detector.masses.isEmpty)
    }

    // MARK: coordinator

    private final class Harness {
        var records: [UUID: HCRestoreProgress.Record] = [:]
        var resumes: [UUID] = []
        var reports = 0
        var autoResume = false
    }

    private func make(_ harness: Harness) -> HCMassSignalEnd {
        let mass = HCMassSignalEnd(window: 5, threshold: 3, settle: 3600)
        mass.autoResumeEnabled = { harness.autoResume }
        mass.record = { harness.records[$0] }
        mass.resume = { panel in
            guard var record = harness.records[panel] else { return "no record" }
            harness.resumes.append(panel)
            record.status.phase = .queued
            harness.records[panel] = record
            return nil
        }
        mass.report = { _, _ in harness.reports += 1 }
        return mass
    }

    private func kept(_ n: Int, at seconds: TimeInterval, signal: Int32 = SIGTERM) -> HCHostEndStatus {
        HCHostEndStatus(endedKey: HCTerminalKey(owningCoreID: "core_a", localAddress: "t\(n)"),
                        cause: .outsideSignal(at: t0.addingTimeInterval(seconds), signal: signal),
                        phase: .notResumed(reason: HCHostEndStatus.outsideSignalReason),
                        conversation: ConversationRef(kind: "claude-code", id: "1c9b6374-0000-4000-8000-00000000000\(n)",
                                                      capturedVia: .wrapperClaim, state: .alive))
    }

    /// Feed one record as `HCRestoreProgress.update` does, keeping the harness's view in step.
    private func feed(_ mass: HCMassSignalEnd, _ harness: Harness, _ panel: UUID, _ status: HCHostEndStatus?,
                      carried: Bool = false) {
        let old = harness.records[panel]?.status
        if let status {
            harness.records[panel] = HCRestoreProgress.Record(id: panel, workspaceID: UUID(), status: status, carried: carried)
        } else {
            harness.records.removeValue(forKey: panel)
        }
        mass.observe(panelID: panel, old: old, new: status, carried: carried)
    }

    private func massOfThree(_ mass: HCMassSignalEnd, _ harness: Harness) -> [UUID] {
        let panels = [UUID(), UUID(), UUID()]
        for (n, panel) in panels.enumerated() { feed(mass, harness, panel, kept(n, at: Double(n))) }
        return panels
    }

    func testAMassEndIsReportedOnceAndResumesNothingUnasked() throws {
        let harness = Harness()
        let mass = make(harness)
        _ = massOfThree(mass, harness)
        let incident = try XCTUnwrap(mass.incidents.first)
        XCTAssertNil(mass.stripIncident, "nothing shows before the settle")
        mass.announce(incident.id)
        mass.announce(incident.id)
        XCTAssertEqual(harness.reports, 1, "one event and one log line")
        XCTAssertEqual(mass.stripIncident?.id, incident.id)
        XCTAssertEqual(mass.stripIncident?.headline, "3 agents ended by SIGTERM at \(HCHostEndStatus.displayTime(t0)).")
        XCTAssertTrue(harness.resumes.isEmpty, "setting off (the default): nothing resumes unasked")
    }

    func testTheReportComesAfterTheSettleByItself() async throws {
        let harness = Harness()
        let mass = make(harness)
        mass.settle = 0
        mass.sleep = { _ in }
        _ = massOfThree(mass, harness)
        for _ in 0..<20 where harness.reports == 0 { await Task.yield() }
        XCTAssertEqual(harness.reports, 1)
    }

    func testOneEndAloneOrTwoNeverFormAMassEnd() {
        let harness = Harness()
        let mass = make(harness)
        feed(mass, harness, UUID(), kept(1, at: 0))
        feed(mass, harness, UUID(), kept(2, at: 1))
        XCTAssertTrue(mass.incidents.isEmpty)
        XCTAssertNil(mass.stripIncident)
    }

    func testPlainShellsStillDecidingAndCarriedRecordsNeverCount() throws {
        let harness = Harness()
        let mass = make(harness)
        var deciding = kept(1, at: 0)
        deciding.phase = .deciding
        feed(mass, harness, UUID(), deciding)
        var shell = kept(2, at: 0.5)
        shell.phase = .noConversation
        feed(mass, harness, UUID(), shell)
        // C11H-209: an earlier launch's offers never count again, even when
        // later phase changes (a failed Resume, then another) report them as this launch's.
        let carried = [UUID(), UUID(), UUID()]
        for (n, panel) in carried.enumerated() { feed(mass, harness, panel, kept(3 + n, at: 1 + Double(n) / 2), carried: true) }
        for panel in carried {
            var failed = try XCTUnwrap(harness.records[panel]?.status)
            failed.phase = .failed(reason: "a fresh terminal could not be started for it.")
            feed(mass, harness, panel, failed)
            failed.phase = .notResumed(reason: "declined")
            feed(mass, harness, panel, failed)
        }
        XCTAssertTrue(mass.incidents.isEmpty)
    }

    func testResumeAllResumesEachWaitingPanelOnceEvenWhenClickedTwiceOrAfterABannerResume() throws {
        let harness = Harness()
        let mass = make(harness)
        let panels = massOfThree(mass, harness)
        let id = try XCTUnwrap(mass.incidents.first?.id)
        mass.announce(id)
        // Panel 1 was resumed from its own banner first.
        _ = mass.resume(panels[1])
        harness.resumes.removeAll()
        mass.resumeAll(id)
        mass.resumeAll(id)
        XCTAssertEqual(Set(harness.resumes), [panels[0], panels[2]])
        XCTAssertEqual(harness.resumes.count, 2, "once each, never twice")
        XCTAssertNil(mass.stripIncident, "nothing left to resume")
    }

    func testResumeAllCoversEveryWaitingMassEndAndTheStripCountsThemAll() throws {
        let harness = Harness()
        let mass = make(harness)
        let first = massOfThree(mass, harness)
        let second = [UUID(), UUID(), UUID()]
        for (n, panel) in second.enumerated() { feed(mass, harness, panel, kept(10 + n, at: 60 + Double(n))) }
        XCTAssertEqual(mass.incidents.count, 2)
        for incident in mass.incidents { mass.announce(incident.id) }
        XCTAssertEqual(harness.reports, 2, "one report per mass end")
        XCTAssertEqual(mass.stripIncident?.headline, "6 agents ended by SIGTERM at \(HCHostEndStatus.displayTime(t0)).")
        mass.resumeAllWaiting()
        mass.resumeAllWaiting()
        XCTAssertEqual(harness.resumes.sorted { $0.uuidString < $1.uuidString },
                       (first + second).sorted { $0.uuidString < $1.uuidString }, "each once")
        XCTAssertNil(mass.stripIncident)
    }

    func testWithTheSettingOnTheMassEndResumesItselfOnceEach() async throws {
        let harness = Harness()
        harness.autoResume = true
        let mass = make(harness)
        let panels = massOfThree(mass, harness)
        mass.announce(try XCTUnwrap(mass.incidents.first?.id))
        XCTAssertEqual(harness.resumes, panels)
        // A fourth end in the same span joins after the report: resumed, no second report.
        let late = UUID()
        feed(mass, harness, late, kept(4, at: 4))
        for _ in 0..<20 where harness.resumes.count < 4 { await Task.yield() }
        XCTAssertEqual(harness.resumes, panels + [late])
        XCTAssertEqual(harness.reports, 1)
    }

    func testMixedSignalsAreNamedPlainly() throws {
        let harness = Harness()
        let mass = make(harness)
        feed(mass, harness, UUID(), kept(1, at: 0, signal: SIGTERM))
        feed(mass, harness, UUID(), kept(2, at: 1, signal: SIGKILL))
        feed(mass, harness, UUID(), kept(3, at: 2, signal: SIGTERM))
        let incident = try XCTUnwrap(mass.incidents.first)
        XCTAssertEqual(incident.headline, "3 agents ended by outside signals at \(HCHostEndStatus.displayTime(t0)).")
    }
}
