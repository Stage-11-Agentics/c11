import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-79 (SH5): diagnostics per shard. A holder kill is diagnosed to its shard
/// from the log and the CLI text alone. Everything runs against a temp recorder
/// and snapshots built here; nothing signals a process or opens an hc socket.
final class HCShardDiagnosticsTests: XCTestCase {
    private var directory: URL!
    /// root pid -> parent pid. The recorder asks this instead of the kernel.
    private let parents = ParentTable()

    private let s1 = HCShardIdentity.parse(session: "c11-s1")
    private let s2 = HCShardIdentity.parse(session: "c11-s2")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("c11-shard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        parents.set([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: identity

    func testSessionNamesMapToTheirShard() {
        XCTAssertEqual(HCShardIdentity.parse(session: "c11").index, 0)
        XCTAssertEqual(HCShardIdentity.parse(session: "c11-3a").index, 0)
        XCTAssertEqual(HCShardIdentity.parse(session: "c11-s1").index, 1)
        XCTAssertEqual(HCShardIdentity.parse(session: "c11-s8").index, 8)
        XCTAssertEqual(HCShardIdentity.parse(session: "c11-3a-s5").index, 5)
        // Outside the pool of 8, or not a number: the legacy shard.
        XCTAssertEqual(HCShardIdentity.parse(session: "c11-s9").index, 0)
        XCTAssertEqual(HCShardIdentity.parse(session: "c11-s0").index, 0)
        XCTAssertEqual(HCShardIdentity.parse(session: "c11-s").index, 0)
        XCTAssertEqual(HCShardIdentity.parse(session: "c11-s2x").index, 0)
        XCTAssertTrue(HCShardIdentity.parse(session: "c11-3a").isLegacy)
    }

    func testHolderIsTheParentOfEveryTerminalRootAndOtherwiseUnknown() {
        let table: [Int32: Int32] = [10: 5, 11: 5, 12: 6, 13: 1]
        XCTAssertEqual(HCShardHolder.holderPID(terminalPIDs: [10, 11], parentOf: { table[$0] }), 5)
        // Two parents is not one holder.
        XCTAssertNil(HCShardHolder.holderPID(terminalPIDs: [10, 12], parentOf: { table[$0] }))
        // Parented by launchd, or a process that is gone: no holder.
        XCTAssertNil(HCShardHolder.holderPID(terminalPIDs: [13], parentOf: { table[$0] }))
        XCTAssertNil(HCShardHolder.holderPID(terminalPIDs: [99], parentOf: { table[$0] }))
        XCTAssertNil(HCShardHolder.holderPID(terminalPIDs: [], parentOf: { table[$0] }))
    }

    /// C11H-205: every terminal root is setuid-root `/usr/bin/login`, which
    /// `proc_pidinfo` will not read for another uid, so after a relaunch the
    /// holder was never learned. A root daemon launchd started stands in for
    /// such a root: its parent still reads. Read-only; nothing is signalled.
    func testKernelParentReadsAProcessUnderAnotherUID() throws {
        guard let daemon = Self.rootDaemonPIDs().first else {
            throw XCTSkip("no root daemon parented by launchd on this machine")
        }
        XCTAssertEqual(HCShardHolder.kernelParent(of: daemon), 1, "pid \(daemon)")
    }

    // MARK: listing

    func testEachShardListsSessionCoreHolderAndItsTerminals() throws {
        let recorder = makeRecorder()
        parents.set([101: 50, 201: 60])
        let panelA = UUID(), panelB = UUID()
        ingest(recorder, shard: s1, core: "core_a", live: [(panelA, "t1", 101)])
        ingest(recorder, shard: s2, core: "core_b", live: [(panelB, "t1", 201)])

        let shards = try shardList(recorder)
        XCTAssertEqual(shards.map { $0["session"] as? String }, ["c11-s1", "c11-s2"])
        let first = try XCTUnwrap(shards.first)
        XCTAssertEqual(first["core_id"] as? String, "core_a")
        XCTAssertEqual(first["holder_pid"] as? Int, 50)
        XCTAssertEqual(first["terminals"] as? Int, 1)
        XCTAssertEqual(first["index"] as? Int, 1)
        let second = try XCTUnwrap(shards.last)
        XCTAssertEqual(second["core_id"] as? String, "core_b")
        XCTAssertEqual(second["holder_pid"] as? Int, 60)
        XCTAssertEqual(second["terminals"] as? Int, 1)

        // A panel row names the shard that owns it.
        let rows = try XCTUnwrap(try json(recorder)["panels"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["panel_id"] as? String == panelA.uuidString }?["shard"] as? String, "c11-s1")
        XCTAssertEqual(rows.first { $0["panel_id"] as? String == panelB.uuidString }?["shard"] as? String, "c11-s2")
        // The same terminal address in two shards is two terminals.
        XCTAssertEqual(rows.compactMap { $0["terminal"] as? String }, ["t1", "t1"])
    }

    func testAShardIsListedBeforeItsFirstSnapshot() throws {
        let recorder = makeRecorder()
        recorder.install(PushSession(), shard: s2)
        let shards = try shardList(recorder)
        XCTAssertEqual(shards.map { $0["session"] as? String }, ["c11-s2"])
        XCTAssertTrue(shards[0]["core_id"] is NSNull)
        XCTAssertEqual(shards[0]["terminals"] as? Int, 0)
    }

    func testInstallTagsEverySnapshotWithTheShardItWasInstalledWith() throws {
        let recorder = makeRecorder()
        parents.set([201: 60])
        let first = PushSession(), second = PushSession()
        recorder.install(first, shard: s1)
        recorder.install(second, shard: s2)
        let panel = UUID()
        let key = HCTerminalKey(owningCoreID: "core_b", localAddress: "t1")
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        second.push(HCInventorySnapshot(
            readiness: .ready(revision), revision: revision,
            records: [key: HCTerminalRecord(key: key, state: .running, pid: 201,
                                            localProcessIdentity: HCProcessIdentity(pid: 201, startTimeMicroseconds: 1))],
            buildIdentity: identity(core: "core_b"), panelBindings: [panel: key]
        ))
        // The delivery queue is asynchronous: wait for the row, at most a second.
        var rows: [[String: Any]] = []
        for _ in 0..<100 {
            rows = try XCTUnwrap(try json(recorder)["panels"] as? [[String: Any]])
            if !rows.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(rows.first?["shard"] as? String, "c11-s2")
        let shards = try shardList(recorder)
        XCTAssertEqual(shards.map { $0["session"] as? String }, ["c11-s1", "c11-s2"])
        XCTAssertEqual(shards.last?["terminals"] as? Int, 1)
        XCTAssertEqual(shards.first?["terminals"] as? Int, 0)
    }

    // MARK: the holder kill

    func testAHolderKillIsDiagnosedToItsShardFromTheLogAndTheTextAlone() throws {
        let recorder = makeRecorder()
        parents.set([101: 50, 201: 60])
        let panelA = UUID(), panelB = UUID()
        ingest(recorder, shard: s1, core: "core_a", live: [(panelA, "t1", 101)], sequence: 1)
        ingest(recorder, shard: s2, core: "core_b", live: [(panelB, "t1", 201)], sequence: 1)

        // Shard 1's holder dies: its terminal finishes holder_lost. Shard 2 is untouched.
        ingest(recorder, shard: s1, core: "core_a", lost: [(panelA, "t1", 101)], sequence: 2)

        // Log: one holder_lost line, naming shard 1, its core and the holder that died.
        let log = recorder.logText()
        let lost = log.split(separator: "\n").filter { $0.contains(" event=holder_lost ") }
        XCTAssertEqual(lost.count, 1)
        let line = String(try XCTUnwrap(lost.first))
        XCTAssertTrue(line.contains("event=holder_lost core_id=core_a count=1"), line)
        XCTAssertTrue(line.contains(" shard=c11-s1 "), line)
        XCTAssertTrue(line.contains(" holder_pid=50 "), line)
        XCTAssertTrue(line.hasSuffix(" shard_count=1"), line)
        XCTAssertFalse(line.contains("c11-s2"))

        // CLI text: shard 1 shows the loss and the dead holder; shard 2 is intact.
        let text = HCDiagnosticsText.lines(recorder.jsonObject())
        let shard1 = try XCTUnwrap(text.first { $0.hasPrefix("shard ") && $0.contains("session=c11-s1") })
        XCTAssertTrue(shard1.contains("holder_lost_count=1"), shard1)
        XCTAssertTrue(shard1.contains("last_lost_holder_pid=50"), shard1)
        XCTAssertFalse(shard1.contains(" holder_pid="), shard1)
        XCTAssertTrue(shard1.contains(" terminals=0 "), shard1)
        XCTAssertTrue(shard1.contains(" ended=1 "), shard1)
        let shard2 = try XCTUnwrap(text.first { $0.hasPrefix("shard ") && $0.contains("session=c11-s2") })
        XCTAssertTrue(shard2.contains("holder_lost_count=0"), shard2)
        XCTAssertTrue(shard2.contains("holder_pid=60"), shard2)
        XCTAssertTrue(shard2.contains(" terminals=1 "), shard2)
        // The ended panel row says which shard it was in.
        let endedRow = try XCTUnwrap(text.first { $0.contains("panel_id=\(panelA.uuidString)") })
        XCTAssertTrue(endedRow.contains("reason=holder_lost"), endedRow)
        XCTAssertTrue(endedRow.hasSuffix("shard=c11-s1"), endedRow)
    }

    func testTwoShardsLosingTheirHoldersAreTwoIncidentsEachInItsOwnShard() throws {
        let recorder = makeRecorder()
        parents.set([101: 50, 201: 60])
        let panelA = UUID(), panelB = UUID()
        ingest(recorder, shard: s1, core: "core_a", live: [(panelA, "t1", 101)], sequence: 1)
        ingest(recorder, shard: s2, core: "core_b", live: [(panelB, "t1", 201)], sequence: 1)
        ingest(recorder, shard: s1, core: "core_a", lost: [(panelA, "t1", 101)], sequence: 2)
        ingest(recorder, shard: s2, core: "core_b", lost: [(panelB, "t1", 201)], sequence: 2)

        XCTAssertEqual(recorder.holderLostCount, 2)
        let lines = recorder.logText().split(separator: "\n").filter { $0.contains(" event=holder_lost ") }.map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("shard=c11-s1") && lines[0].contains("holder_pid=50"))
        XCTAssertTrue(lines[1].contains("shard=c11-s2") && lines[1].contains("holder_pid=60"))
        let shards = try shardList(recorder)
        XCTAssertEqual(shards.map { $0["holder_lost_count"] as? Int }, [1, 1])
    }

    func testTheNextTerminalAfterAKillSamplesTheNewHolder() throws {
        let recorder = makeRecorder()
        parents.set([101: 50, 102: 77])
        let first = UUID(), second = UUID()
        ingest(recorder, shard: s1, core: "core_a", live: [(first, "t1", 101)], sequence: 1)
        ingest(recorder, shard: s1, core: "core_a", lost: [(first, "t1", 101)], sequence: 2)
        // hc starts a new holder for the next terminal.
        ingest(recorder, shard: s1, core: "core_a", live: [(second, "t2", 102)], sequence: 3)

        let shard = try XCTUnwrap(try shardList(recorder).first)
        XCTAssertEqual(shard["holder_pid"] as? Int, 77)
        XCTAssertEqual(shard["last_lost_holder_pid"] as? Int, 50)
        XCTAssertEqual(shard["holder_lost_count"] as? Int, 1)
    }

    func testAHolderLostEventWithoutAShardFindsItByCore() throws {
        let recorder = makeRecorder()
        parents.set([101: 50, 201: 60])
        ingest(recorder, shard: s1, core: "core_a", live: [(UUID(), "t1", 101)], sequence: 1)
        ingest(recorder, shard: s2, core: "core_b", live: [(UUID(), "t1", 201)], sequence: 1)

        recorder.record(.holderLost(coreID: "core_b", terminal: "t1", discriminator: "p201:100", holderID: nil))

        let line = try XCTUnwrap(recorder.logText().split(separator: "\n").first { $0.contains(" event=holder_lost ") })
        XCTAssertTrue(line.contains("shard=c11-s2"), String(line))
        XCTAssertTrue(line.contains("holder_pid=60"), String(line))
    }

    func testTheLegacyShardReadsAsShardZeroInLogAndText() throws {
        let recorder = makeRecorder()
        parents.set([101: 50])
        let legacy = HCShardIdentity.parse(session: "c11")
        let panel = UUID()
        ingest(recorder, shard: legacy, core: "core_a", live: [(panel, "t1", 101)], sequence: 1)
        ingest(recorder, shard: legacy, core: "core_a", lost: [(panel, "t1", 101)], sequence: 2)

        XCTAssertTrue(recorder.logText().contains("event=holder_lost core_id=core_a count=1 shard=c11 holder_pid=50 shard_count=1"))
        let text = HCDiagnosticsText.lines(recorder.jsonObject())
        let line = try XCTUnwrap(text.first { $0.hasPrefix("shard ") })
        XCTAssertTrue(line.contains("session=c11 index=0"), line)
        XCTAssertTrue(line.hasSuffix("legacy=true"), line)
    }

    // MARK: review of d030f9da: mixed holders, and terminal totals from the inventory

    func testALostHolderIsNamedByItsOwnTerminalWhileAnotherHolderSurvives() throws {
        let recorder = makeRecorder()
        // Terminal A runs under holder 50. After a recovery, terminal B runs under holder 60.
        parents.set([101: 50, 201: 60])
        let a = UUID(), b = UUID()
        ingest(recorder, shard: s1, core: "core_a", live: [(a, "t1", 101), (b, "t2", 201)], sequence: 1)
        var shard = try XCTUnwrap(try shardList(recorder).first)
        XCTAssertEqual(shard["holder_pids"] as? [Int], [50, 60])
        XCTAssertTrue(shard["holder_pid"] is NSNull, "two holders: no single holder to name")
        let both = try XCTUnwrap(HCDiagnosticsText.lines(recorder.jsonObject()).first { $0.hasPrefix("shard ") })
        XCTAssertTrue(both.contains("holder_pids=50,60"), both)

        // Holder 50 dies: A ends holder_lost, B keeps running under 60.
        ingest(recorder, shard: s1, core: "core_a", live: [(b, "t2", 201)], lost: [(a, "t1", 101)], sequence: 2)

        let line = String(try XCTUnwrap(recorder.logText().split(separator: "\n").first { $0.contains(" event=holder_lost ") }))
        XCTAssertTrue(line.contains(" holder_pid=50 "), "the loss names the holder that died: \(line)")
        shard = try XCTUnwrap(try shardList(recorder).first)
        XCTAssertEqual(shard["last_lost_holder_pid"] as? Int, 50)
        XCTAssertEqual(shard["holder_pid"] as? Int, 60, "the surviving holder is still reported")
        XCTAssertEqual(shard["holder_pids"] as? [Int], [60])
        XCTAssertEqual(shard["terminals"] as? Int, 1)
        XCTAssertEqual(shard["ended"] as? Int, 1)
    }

    func testALossAndANewTerminalInOneSnapshotStillNameTheDeadHolder() throws {
        let recorder = makeRecorder()
        parents.set([101: 50, 301: 70])
        let a = UUID(), c = UUID()
        ingest(recorder, shard: s1, core: "core_a", live: [(a, "t1", 101)], sequence: 1)
        // One coalesced snapshot: A's end and a new terminal C under a new holder.
        ingest(recorder, shard: s1, core: "core_a", live: [(c, "t3", 301)], lost: [(a, "t1", 101)], sequence: 2)

        let line = String(try XCTUnwrap(recorder.logText().split(separator: "\n").first { $0.contains(" event=holder_lost ") }))
        XCTAssertTrue(line.contains(" holder_pid=50 "), line)
        let shard = try XCTUnwrap(try shardList(recorder).first)
        XCTAssertEqual(shard["holder_pid"] as? Int, 70)
        XCTAssertEqual(shard["last_lost_holder_pid"] as? Int, 50)
    }

    func testTerminalTotalsComeFromTheShardsInventoryNotItsPanelRows() throws {
        let recorder = makeRecorder()
        parents.set([101: 50, 102: 50])
        let bound = UUID()
        // One bound terminal and one an agent created that no panel has claimed.
        ingest(recorder, shard: s1, core: "core_a", live: [(bound, "t1", 101)], unbound: [("t2", 102)], sequence: 1)
        var shard = try XCTUnwrap(try shardList(recorder).first)
        XCTAssertEqual(shard["terminals"] as? Int, 2, "an unclaimed running terminal is still the shard's")

        // The unclaimed terminal's record goes away: the total follows the inventory.
        ingest(recorder, shard: s1, core: "core_a", live: [(bound, "t1", 101)], sequence: 2)
        shard = try XCTUnwrap(try shardList(recorder).first)
        XCTAssertEqual(shard["terminals"] as? Int, 1)

        // A pending inventory does not zero the totals: the last ready answer stands.
        let down = HCInventorySnapshot(
            readiness: .pending(.connectionLost),
            revision: HCRevision(connectionGeneration: 2, sequence: 1)
        )
        recorder.ingest(HCDiagnostics(inventory: down, unavailableReason: .connectionLost), shard: s1)
        shard = try XCTUnwrap(try shardList(recorder).first)
        XCTAssertEqual(shard["terminals"] as? Int, 1)
        XCTAssertEqual(shard["readiness"] as? String, "pending")
    }

    /// C11H-205: a shard's `terminals` and `ended` are its own core's. Records
    /// mirrored from another machine count apart, in the `remote_` pair.
    func testShardTotalsCountThisCoresTerminalsAndMirrorsApart() throws {
        let recorder = makeRecorder()
        parents.set([101: 50])
        let core = "core_a"
        let live = HCTerminalKey(owningCoreID: core, localAddress: "t1")
        let ended = HCTerminalKey(owningCoreID: core, localAddress: "t2")
        let mirrorLive = HCTerminalKey(owningCoreID: core, localAddress: "studio/t7")
        let mirrorEndedA = HCTerminalKey(owningCoreID: core, localAddress: "studio/t8")
        let mirrorEndedB = HCTerminalKey(owningCoreID: core, localAddress: "orion/t3")
        let records: [HCTerminalKey: HCTerminalRecord] = [
            live: HCTerminalRecord(key: live, state: .running, pid: 101),
            ended: HCTerminalRecord(key: ended, state: .finished, endReason: "exit"),
            mirrorLive: HCTerminalRecord(key: mirrorLive, state: .running, machineName: "studio",
                                         machineAvailability: .connected, pid: 4242),
            mirrorEndedA: HCTerminalRecord(key: mirrorEndedA, state: .finished, machineName: "studio",
                                           machineAvailability: .connected, endReason: "killed"),
            mirrorEndedB: HCTerminalRecord(key: mirrorEndedB, state: .finished, machineName: "orion",
                                           machineAvailability: .disconnected, endReason: "exit"),
        ]
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let snapshot = HCInventorySnapshot(
            readiness: .ready(revision), revision: revision, records: records, buildIdentity: identity(core: core)
        )
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity(core: core)), inferFallback: false, shard: s1)

        let shard = try XCTUnwrap(try shardList(recorder).first)
        XCTAssertEqual(shard["terminals"] as? Int, 1)
        XCTAssertEqual(shard["ended"] as? Int, 1)
        XCTAssertEqual(shard["remote_terminals"] as? Int, 1)
        XCTAssertEqual(shard["remote_ended"] as? Int, 2)
        XCTAssertEqual(shard["holder_pid"] as? Int, 50, "a mirror's pid is another machine's and names no holder")
        let line = try XCTUnwrap(HCDiagnosticsText.lines(recorder.jsonObject()).first { $0.hasPrefix("shard ") })
        XCTAssertTrue(line.contains(" terminals=1 ended=1 remote_terminals=1 remote_ended=2 "), line)
    }

    // MARK: attribution and aggregates

    func testAPanelPlacedInAnotherShardIsNotUnreachableWhenThisShardIsDown() throws {
        let recorder = makeRecorder()
        let elsewhere = HCPanelIdentity(
            panelID: UUID(),
            key: HCTerminalKey(owningCoreID: "core_b", localAddress: "t4"),
            persistence: .persistent,
            origin: .restored
        )
        let here = HCPanelIdentity(
            panelID: UUID(),
            key: HCTerminalKey(owningCoreID: "core_a", localAddress: "t9"),
            persistence: .persistent,
            origin: .restored
        )
        let s2 = self.s2
        let s1 = self.s1
        let placement: @Sendable (HCPanelIdentity) -> HCShardIdentity? = { panel in
            panel.panelID == elsewhere.panelID ? s2 : s1
        }
        let down = HCInventorySnapshot(
            readiness: .pending(.coreUnreachable),
            revision: HCRevision(connectionGeneration: 1, sequence: 1)
        )
        recorder.ingest(
            HCDiagnostics(inventory: down, unavailableReason: .coreUnreachable),
            panels: [elsewhere, here],
            inferFallback: false,
            shard: s1,
            shardOf: placement
        )
        let rows = try XCTUnwrap(try json(recorder)["panels"] as? [[String: Any]])
        XCTAssertNotNil(rows.first { $0["panel_id"] as? String == here.panelID.uuidString })
        XCTAssertNil(rows.first { $0["panel_id"] as? String == elsewhere.panelID.uuidString },
                     "shard 1 being down must not report a panel that lives in shard 2")
        XCTAssertEqual(rows.first?["shard"] as? String, "c11-s1")
    }

    func testOneShardKeepsTopLevelFieldsAndSeveralDoNotGuess() throws {
        let recorder = makeRecorder()
        parents.set([101: 50, 201: 60])
        ingest(recorder, shard: s1, core: "core_a", live: [(UUID(), "t1", 101)], sequence: 7)
        var top = try json(recorder)
        XCTAssertEqual(top["readiness"] as? String, "ready")
        XCTAssertEqual(top["sequence"] as? Int, 7)
        XCTAssertEqual(top["connection_generation"] as? Int, 1)

        ingest(recorder, shard: s2, core: "core_b", live: [(UUID(), "t1", 201)], sequence: 3)
        top = try json(recorder)
        XCTAssertEqual(top["readiness"] as? String, "ready")
        XCTAssertTrue(top["sequence"] is NSNull, "two shards: a top-level sequence would name an arbitrary one")
        XCTAssertTrue(top["connection_generation"] is NSNull)
        let shards = try shardList(recorder)
        XCTAssertEqual(shards.map { $0["sequence"] as? Int }, [7, 3])

        // One shard going down makes the whole report pending, and says why.
        let down = HCInventorySnapshot(
            readiness: .pending(.connectionLost),
            revision: HCRevision(connectionGeneration: 2, sequence: 1)
        )
        recorder.ingest(HCDiagnostics(inventory: down, unavailableReason: .connectionLost), shard: s2)
        top = try json(recorder)
        XCTAssertEqual(top["readiness"] as? String, "pending")
        XCTAssertEqual(top["readiness_reason"] as? String, "connection_lost")
        let after = try shardList(recorder)
        XCTAssertEqual(after.map { $0["readiness"] as? String }, ["ready", "pending"])
    }

    func testALifecycleLineAboutAShardsPanelNamesTheShard() throws {
        let recorder = makeRecorder()
        parents.set([201: 60])
        let panel = UUID()
        ingest(recorder, shard: s2, core: "core_b", live: [(panel, "t1", 201)])
        let lifecycle = try XCTUnwrap(recorder.logText().split(separator: "\n").first {
            $0.contains("event=lifecycle") && $0.contains(panel.uuidString)
        })
        XCTAssertTrue(lifecycle.hasSuffix(" shard=c11-s2"), String(lifecycle))
        // A later event for the same panel, written outside an ingest, still names it.
        recorder.record(.panelEnded(panelID: panel, reason: "exited"))
        let ended = try XCTUnwrap(recorder.logText().split(separator: "\n").first {
            $0.contains("lifecycle=ended") && $0.contains(panel.uuidString)
        })
        XCTAssertTrue(ended.hasSuffix(" shard=c11-s2"), String(ended))
        let rows = try XCTUnwrap(try json(recorder)["panels"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["shard"] as? String, "c11-s2", "an ended row keeps its shard")
        recorder.record(.panelClosed(panelID: panel))
        let close = try XCTUnwrap(recorder.logText().split(separator: "\n").first { $0.contains("event=close") })
        XCTAssertTrue(close.hasSuffix(" shard=c11-s2"), String(close))
    }

    // MARK: helpers

    /// Live root daemons launchd started (real uid 0, parent 1), lowest pid
    /// first: the longest lived. One `sysctl(KERN_PROC_ALL)` read.
    private static func rootDaemonPIDs() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room for processes started between the two calls.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var infos = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        let result = infos.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return [] }
        return infos.prefix(size / MemoryLayout<kinfo_proc>.stride).filter { info in
            info.kp_proc.p_pid > 1 && info.kp_eproc.e_ppid == 1
                && info.kp_eproc.e_pcred.p_ruid == 0 && info.kp_proc.p_stat != CChar(SZOMB)
        }.map { $0.kp_proc.p_pid }.sorted()
    }

    private func makeRecorder() -> HCDiagnosticRecorder {
        let table = parents
        return HCDiagnosticRecorder(
            logFile: directory.appendingPathComponent("hc-diagnostics.log"),
            counterFile: directory.appendingPathComponent("holder-lost.json"),
            parentOf: { table.parent(of: $0) }
        )
    }

    private func identity(core: String) -> HCBuildIdentity {
        HCBuildIdentity(
            pin: .current,
            executablePath: "/Users/example/.local/share/c11/hc",
            fileIdentity: HCFileIdentity(device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5),
            process: HCProcessIdentity(pid: 18267, startTimeMicroseconds: 9),
            coreID: core,
            protocolGeneration: 1
        )
    }

    /// One snapshot of one shard. `live` terminals run with the given root pid;
    /// `lost` terminals have finished with `holder_lost`.
    private func ingest(
        _ recorder: HCDiagnosticRecorder,
        shard: HCShardIdentity,
        core: String,
        live: [(UUID, String, Int32)] = [],
        lost: [(UUID, String, Int32)] = [],
        unbound: [(String, Int32)] = [],
        sequence: UInt64 = 1
    ) {
        var records: [HCTerminalKey: HCTerminalRecord] = [:]
        var bindings: [UUID: HCTerminalKey] = [:]
        for (panel, address, pid) in live {
            let key = HCTerminalKey(owningCoreID: core, localAddress: address)
            records[key] = HCTerminalRecord(
                key: key, state: .running, pid: pid, tty: "/dev/ttys0\(pid % 100)",
                localProcessIdentity: HCProcessIdentity(pid: pid, startTimeMicroseconds: 100)
            )
            bindings[panel] = key
        }
        for (panel, address, pid) in lost {
            let key = HCTerminalKey(owningCoreID: core, localAddress: address)
            records[key] = HCTerminalRecord(
                key: key, state: .finished, pid: pid, endReason: "holder_lost",
                localProcessIdentity: HCProcessIdentity(pid: pid, startTimeMicroseconds: 100)
            )
            bindings[panel] = key
        }
        // Terminals the shard holds that no panel has claimed yet (an agent made them).
        for (address, pid) in unbound {
            let key = HCTerminalKey(owningCoreID: core, localAddress: address)
            records[key] = HCTerminalRecord(
                key: key, state: .running, pid: pid,
                localProcessIdentity: HCProcessIdentity(pid: pid, startTimeMicroseconds: 100)
            )
        }
        let revision = HCRevision(connectionGeneration: 1, sequence: sequence)
        let snapshot = HCInventorySnapshot(
            readiness: .ready(revision), revision: revision, records: records,
            buildIdentity: identity(core: core), panelBindings: bindings
        )
        recorder.ingest(HCDiagnostics(inventory: snapshot, servingBuild: identity(core: core)), inferFallback: false, shard: shard)
    }

    private func json(_ recorder: HCDiagnosticRecorder) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: recorder.jsonObject())
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func shardList(_ recorder: HCDiagnosticRecorder) throws -> [[String: Any]] {
        try XCTUnwrap(try json(recorder)["shards"] as? [[String: Any]])
    }
}

private final class ParentTable: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int32: Int32] = [:]
    func set(_ new: [Int32: Int32]) { lock.lock(); table = new; lock.unlock() }
    func parent(of pid: Int32) -> Int32? { lock.lock(); defer { lock.unlock() }; return table[pid] }
}

/// A session a test drives by hand: `push` hands a snapshot to whoever observes.
private final class PushSession: HCSession, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(DispatchQueue, @Sendable (HCInventorySnapshot) -> Void)] = []
    func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        lock.lock(); handlers.append((queue, handler)); lock.unlock()
        return HCObservation()
    }
    func push(_ snapshot: HCInventorySnapshot) {
        lock.lock(); let current = handlers; lock.unlock()
        for (queue, handler) in current { queue.async { handler(snapshot) } }
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
