import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCInventoryTests: XCTestCase {
    private func record(_ address: String, pid: Int64 = 42) -> HCJSONValue {
        .object(["address": .string(address), "state": .string("live"), "pid": .integer(pid),
                 "labels": .object([:]), "cols": .integer(80), "rows": .integer(24), "title": .string("old")])
    }
    private func snapshot(_ seq: Int64, _ records: [HCJSONValue]) -> HCJSONValue {
        .object(["seq": .integer(seq), "terminals": .array(records)])
    }
    private func event(_ seq: Int64, _ kind: String, _ address: String = "t1", _ data: HCJSONValue = .object([:])) -> HCJSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string("event"), "params": .object([
            "seq": .integer(seq), "type": .string(kind), "terminal": .string(address), "data": data])])
    }
    private func notification(_ method: String, _ params: HCJSONValue) -> HCJSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
    }
    func testMissedReplacesAndDuplicateDoesNotRewind() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local")
        try reducer.install(snapshot(10, [record("t1"), record("t2")]))
        try reducer.apply(notification("missed", snapshot(15, [record("t3", pid: 90)])), generation: 1)
        XCTAssertEqual(Set(reducer.snapshot.records.keys.map(\.localAddress)), ["t3"])
        try reducer.apply(event(14, "created", "t4", record("t4")), generation: 1)
        XCTAssertEqual(reducer.sequence, 15)
        XCTAssertEqual(reducer.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 15)))
        XCTAssertEqual(reducer.snapshot.records.count, 1)
    }
    func testGapMalformedAndStaleGenerationNeverConferReadiness() throws {
        var reducer = HCInventoryReducer(generation: 8, coreID: "local")
        try reducer.install(snapshot(10, [record("t1")]))
        try reducer.apply(event(11, "removed"), generation: 7)
        XCTAssertEqual(reducer.snapshot.records.count, 1)
        try reducer.apply(event(12, "removed"), generation: 8)
        XCTAssertEqual(reducer.readiness, .pending(.inventoryPending))
        XCTAssertEqual(reducer.snapshot.records.count, 1)
        try reducer.install(snapshot(20, [record("t1")]))
        XCTAssertThrowsError(try reducer.apply(event(21, "size"), generation: 8))
        XCTAssertEqual(reducer.readiness, .pending(.malformedResponse))
    }
    func testUnrelatedEventsAdvanceAndBirthGetsItsPID() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local")
        var pending = record("t1").object!; pending["pid"] = .null
        try reducer.install(snapshot(4, [.object(pending)]))
        XCTAssertEqual(reducer.snapshot.records.values.first?.state, .starting)
        try reducer.apply(event(5, "doc"), generation: 1)
        try reducer.apply(event(6, "created", "t1", record("t1", pid: 99)), generation: 1)
        XCTAssertEqual(reducer.snapshot.records.values.first?.pid, 99)
        XCTAssertEqual(reducer.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 6)))
        try reducer.apply(event(7, "finished", "t1", .object(["reason": .string("holder_lost"), "exit_code": .null,
            "signal": .integer(9), "finished_ms": .integer(10)])), generation: 1)
        XCTAssertEqual(reducer.snapshot.records.values.first?.endReason, "holder_lost")
        XCTAssertEqual(reducer.snapshot.records.values.first?.state, .finished)
        // C11H-205: hc's own end time reaches the record and its end evidence.
        XCTAssertEqual(reducer.snapshot.records.values.first?.finishedMilliseconds, 10)
        let identity = HCPanelIdentity(panelID: UUID(), key: HCTerminalKey(owningCoreID: "local", localAddress: "t1"))
        guard case .ended(let evidence) = HCLifecycleResolver.resolve(identity, snapshot: reducer.snapshot, intent: nil) else {
            return XCTFail("a finished record resolves ended")
        }
        XCTAssertEqual(evidence.endedAtMilliseconds, 10)
        XCTAssertEqual(evidence.endedAt, Date(timeIntervalSince1970: 0.010))
    }
    func testRemoteAliasNeverBecomesIdentity() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local")
        try reducer.setMachines(.object(["machines": .array([.object(["name": .string("studio"), "id": .string("stable"), "state": .string("connected")])])]))
        try reducer.install(snapshot(1, [record("studio/t1")]))
        XCTAssertEqual(reducer.snapshot.records.values.first?.key.owningCoreID, "stable")
        XCTAssertNil(reducer.snapshot.records.values.first?.localProcessIdentity)
        try reducer.apply(event(2, "removed", "studio/t1"), generation: 1)
        XCTAssertTrue(reducer.snapshot.records.isEmpty)
    }
    func testHeartbeatAheadRevokesReadinessAndRequestsRefresh() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local")
        try reducer.install(snapshot(10, [record("t1")]))
        try reducer.apply(notification("heartbeat", .object(["seq": .integer(10)])), generation: 1)
        XCTAssertFalse(reducer.needsRefresh)
        try reducer.apply(notification("heartbeat", .object(["seq": .integer(11)])), generation: 1)
        XCTAssertEqual(reducer.readiness, .pending(.inventoryPending))
        XCTAssertTrue(reducer.needsRefresh)
        XCTAssertEqual(reducer.sequence, 10)
        XCTAssertEqual(reducer.snapshot.records.count, 1)
    }

    func testUnknownEventAdvancesSequenceAndRequestsRefreshOnlyOnce() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local")
        try reducer.install(snapshot(10, [record("t1")]))
        try reducer.apply(event(11, "future_kind"), generation: 1)
        XCTAssertEqual(reducer.sequence, 11)
        XCTAssertTrue(reducer.needsRefresh)
        try reducer.install(snapshot(11, [record("t1")]))
        XCTAssertFalse(reducer.needsRefresh)
        try reducer.apply(event(12, "future_kind"), generation: 1)
        XCTAssertEqual(reducer.sequence, 12)
        XCTAssertFalse(reducer.needsRefresh)
        XCTAssertEqual(reducer.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 12)))
    }


    // MARK: C11H-359: hc-reported machines and addresses are judged where c11 uses them

    private func machines(_ entries: [[String: String?]]) -> HCJSONValue {
        .object(["machines": .array(entries.map { entry in
            .object(entry.compactMapValues { $0 }.mapValues(HCJSONValue.string))
        })])
    }
    private func born(_ address: String, created: Int64, pid: Int64 = 42) -> HCJSONValue {
        var object = record(address, pid: pid).object!
        object["created_ms"] = .integer(created)
        return .object(object)
    }

    /// M6: one machine listed with no core id used to fail the whole list, so
    /// the shard never installed and every terminal on it stalled. It is now
    /// refused alone; this core's terminals and every other machine's install.
    func testAMachineWithNoCoreIDIsRefusedAloneAndTheShardInstalls() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local")
        try reducer.setMachines(machines([
            ["name": "studio", "id": "stable", "state": "connected"],
            ["name": "rigel", "id": "", "state": "connected"],
            ["name": "orion", "id": nil, "state": "connected"],
            ["name": nil, "id": "nameless", "state": "connected"],
        ]))
        XCTAssertEqual(reducer.refusedMachines, ["rigel": .missingID, "orion": .missingID])
        try reducer.install(snapshot(5, [record("t1"), record("studio/t2"), record("rigel/t3"), record("orion/t4"), record("/t5")]))
        XCTAssertEqual(reducer.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 5)))
        XCTAssertEqual(Set(reducer.snapshot.records.keys), [HCTerminalKey(owningCoreID: "local", localAddress: "t1"),
                                                            HCTerminalKey(owningCoreID: "stable", localAddress: "t2")])
        XCTAssertEqual(reducer.snapshot.machines, ["studio": .connected])
        // A refused machine's events are skipped; the stream stays ready.
        try reducer.apply(event(6, "created", "rigel/t9", record("rigel/t9")), generation: 1)
        try reducer.apply(event(7, "removed", "rigel/t3"), generation: 1)
        XCTAssertEqual(reducer.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 7)))
        XCTAssertEqual(reducer.snapshot.records.count, 2)
    }

    /// L2: a linked machine that answers with this core's id, or a sibling
    /// shard's, would put its terminals in this app's own key space. It is
    /// refused, and none of its terminals enters the inventory.
    func testAMachineClaimingOneOfThisAppsCoreIDsIsRefused() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local", reservedCoreIDs: { ["sibling-shard"] })
        try reducer.setMachines(machines([
            ["name": "studio", "id": "sibling-shard", "state": "connected"],
            ["name": "lyra", "id": "local", "state": "connected"],
            ["name": "rigel", "id": "rigel-core", "state": "connected"],
        ]))
        XCTAssertEqual(reducer.refusedMachines, ["studio": .localCoreID, "lyra": .localCoreID])
        try reducer.install(snapshot(3, [record("t1"), record("studio/t3"), record("lyra/t1"), record("rigel/t4")]))
        XCTAssertEqual(Set(reducer.snapshot.records.keys), [HCTerminalKey(owningCoreID: "local", localAddress: "t1"),
                                                            HCTerminalKey(owningCoreID: "rigel-core", localAddress: "t4")])
        XCTAssertNil(reducer.snapshot.records[HCTerminalKey(owningCoreID: "sibling-shard", localAddress: "t3")],
                     "a sibling shard's key is never another machine's terminal")
    }

    /// M6: a name or a core id listed twice can't be told apart: both are refused.
    func testADoubledMachineNameOrCoreIDRefusesEveryCopy() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local")
        try reducer.setMachines(machines([
            ["name": "studio", "id": "a", "state": "connected"],
            ["name": "studio", "id": "b", "state": "connected"],
            ["name": "rigel", "id": "shared", "state": "connected"],
            ["name": "orion", "id": "shared", "state": "disconnected"],
            ["name": "lyra", "id": "lyra-core", "state": "connected"],
        ]))
        XCTAssertEqual(reducer.refusedMachines, ["studio": .duplicate, "rigel": .duplicate, "orion": .duplicate])
        try reducer.install(snapshot(2, [record("lyra/t1"), record("rigel/t2"), record("orion/t2")]))
        XCTAssertEqual(Array(reducer.snapshot.records.keys), [HCTerminalKey(owningCoreID: "lyra-core", localAddress: "t1")])
        XCTAssertEqual(reducer.snapshot.machines, ["lyra": .connected])
    }

    /// REPAIR-1 (B3): every entry is judged against the whole list, so the
    /// verdicts never depend on its order: an empty state is refused; a name
    /// listed twice refuses every copy, and so does a core id one of them shares.
    func testJudgingAMachineListNeverDependsOnItsOrder() throws {
        var empty = HCInventoryReducer(generation: 1, coreID: "local")
        try empty.setMachines(machines([["name": "studio", "id": "a", "state": ""]]))
        XCTAssertEqual(empty.refusedMachines, ["studio": .missingID])
        let overlap: [[String: String?]] = [["name": "studio", "id": "a", "state": "connected"],
                                             ["name": "studio", "id": "b", "state": "connected"],
                                             ["name": "rigel", "id": "b", "state": "connected"]]
        for rotation in 0..<overlap.count {
            var reducer = HCInventoryReducer(generation: 1, coreID: "local")
            try reducer.setMachines(machines(Array(overlap[rotation...] + overlap[..<rotation])))
            XCTAssertEqual(reducer.refusedMachines, ["studio": .duplicate, "rigel": .duplicate], "rotation \(rotation)")
            XCTAssertEqual(reducer.snapshot.machines, [:], "rotation \(rotation)")
        }
        for pair in [[["name": "studio", "id": "local", "state": "connected"], ["name": "studio", "id": "x", "state": "connected"]],
                     [["name": "studio", "id": "x", "state": "connected"], ["name": "studio", "id": "local", "state": "connected"]]] {
            var reducer = HCInventoryReducer(generation: 1, coreID: "local")
            try reducer.setMachines(machines(pair))
            XCTAssertEqual(reducer.refusedMachines, ["studio": .duplicate])
        }
    }

    /// REPAIR-1 (B5): a `missed` snapshot that lists an address twice is
    /// logged like a subscribe's, once, and the shard stays ready with the
    /// first record.
    func testADoubledMissedSnapshotIsLoggedAndKeepsTheFirstRecord() async throws {
        final class Events: @unchecked Sendable {
            private let lock = NSLock()
            private var names: [String] = []
            func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
        }
        let events = Events()
        let own = born("t1", created: 100, pid: 42)
        let connection = DoubledAddressConnection(first: .object(["channel": .integer(1), "seq": .integer(1), "terminals": .array([own])]),
                                                  then: .object(["channel": .integer(1), "seq": .integer(1), "terminals": .array([own])]))
        let source = HCLiveInventorySource(connection: connection, diagnostics: { name, _, _ in events.add(name) }, refreshTimeout: 1)
        guard case .ready = await source.refresh().readiness else { return XCTFail("the first snapshot installs") }
        let registered = await connection.sink
        let sink = try XCTUnwrap(registered)
        let missed = notification("missed", .object(["seq": .integer(2), "terminals": .array([own, born("t1", created: 900, pid: 7)])]))
        let stale = notification("missed", .object(["seq": .integer(1), "terminals": .array([own])]))
        _ = await sink.consume(HCOutputChunk(attachmentGeneration: 1, watermark: 0, bytes: try missed.encoded() + Data([10])))
        _ = await sink.consume(HCOutputChunk(attachmentGeneration: 1, watermark: 0, bytes: try stale.encoded() + Data([10])))
        let settled = await source.snapshot()
        guard case .ready = settled.readiness else { return XCTFail("the shard stays ready") }
        XCTAssertEqual(settled.records[HCTerminalKey(owningCoreID: "local-core", localAddress: "t1")]?.pid, 42)
        for _ in 0..<100 where !events.all.contains("hc_inventory_duplicate_address") { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(events.all.filter { $0 == "hc_inventory_duplicate_address" }.count, 1, "\(events.all)")
    }

    /// M7: a snapshot listing a bare address twice keeps the first listing,
    /// this core's own (hc lists it first), instead of refusing the shard.
    func testADoubledAddressKeepsThisCoresOwnRecordAndTheShardStaysReady() throws {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local")
        try reducer.install(snapshot(4, [born("t1", created: 100, pid: 42), born("t2", created: 101, pid: 43),
                                         born("t1", created: 900, pid: 7), born("t2", created: 901, pid: 8)]))
        XCTAssertEqual(reducer.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 4)))
        XCTAssertEqual(reducer.droppedDuplicateAddresses, 2)
        XCTAssertEqual(reducer.snapshot.records[HCTerminalKey(owningCoreID: "local", localAddress: "t1")]?.pid, 42)
        XCTAssertEqual(reducer.snapshot.records[HCTerminalKey(owningCoreID: "local", localAddress: "t2")]?.pid, 43)
    }

    /// M7: hc keeps a terminal's created_ms for its life, restarts included.
    /// A created or restarted event carrying another terminal's never replaces
    /// the record; its own (a birth, a restart) still applies.
    func testACreatedOrRestartedEventNeverReplacesAnotherTerminalsRecord() throws {
        for kind in ["created", "restarted"] {
            var reducer = HCInventoryReducer(generation: 1, coreID: "local")
            try reducer.install(snapshot(4, [born("t1", created: 100, pid: 42)]))
            try reducer.apply(event(5, kind, "t1", born("t1", created: 100, pid: 77)), generation: 1)
            XCTAssertEqual(reducer.snapshot.records.values.first?.pid, 77, "\(kind): the terminal's own event applies")
            XCTAssertThrowsError(try reducer.apply(event(6, kind, "t1", born("t1", created: 900, pid: 7)), generation: 1), kind)
            XCTAssertEqual(reducer.readiness, .pending(.malformedResponse), "\(kind): the reducer refreshes")
            XCTAssertEqual(reducer.snapshot.records.values.first?.pid, 77, "\(kind): the record is not replaced")
        }
    }

    /// M7 through the live source, fed hc's line sequence byte for byte:
    /// `created` events for this core's own addresses carrying another
    /// terminal's records, then a `missed` snapshot listing both twice. The
    /// shard ends ready, holding this core's own records.
    func testTheLiveSourceKeepsThisCoresRecordsThroughHcsLineSequence() async throws {
        let own = [born("t1", created: 100, pid: 42), born("t2", created: 101, pid: 43)]
        let far = [born("t1", created: 900, pid: 7), born("t2", created: 901, pid: 8)]
        let doubled: HCJSONValue = .object(["channel": .integer(1), "seq": .integer(3), "terminals": .array(own + far)])
        for frame in [[event(2, "created", "t1", far[0]), event(3, "created", "t2", far[1]),
                       notification("missed", .object(["seq": .integer(3), "terminals": .array(own + far)]))],
                      [event(2, "created", "t1", far[0])]] {
            let connection = DoubledAddressConnection(first: .object(["channel": .integer(1), "seq": .integer(1),
                                                                       "terminals": .array(own)]), then: doubled)
            let source = HCLiveInventorySource(connection: connection, refreshTimeout: 1)
            guard case .ready = await source.refresh().readiness else { return XCTFail("the first snapshot installs") }
            let registered = await connection.sink
            let sink = try XCTUnwrap(registered)
            let bytes = try frame.map { try $0.encoded() + Data([10]) }.reduce(Data(), +)
            _ = await sink.consume(HCOutputChunk(attachmentGeneration: 1, watermark: 0, bytes: bytes))
            var settled = await source.snapshot()
            for _ in 0..<200 {
                if case .ready = settled.readiness, settled.revision.sequence >= 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
                settled = await source.snapshot()
            }
            guard case .ready = settled.readiness else { return XCTFail("\(frame.count) lines: the shard stalls \(settled.readiness)") }
            XCTAssertEqual(settled.records[HCTerminalKey(owningCoreID: "local-core", localAddress: "t1")]?.pid, 42, "\(frame.count) lines")
            XCTAssertEqual(settled.records[HCTerminalKey(owningCoreID: "local-core", localAddress: "t2")]?.pid, 43, "\(frame.count) lines")
        }
    }
}

/// hc's subscribe replies: the first snapshot, then every later one.
private actor DoubledAddressConnection: HCConnection {
    nonisolated let generation: UInt64 = 1
    nonisolated let peer = HCPeerEvidence(uid: 1, pid: 42, statusPID: 42, coreID: "local-core", version: "0.1.16",
        protocolGeneration: 1, methods: [], features: [])
    nonisolated let verification = HCVerifiedPeer(identity: HCBuildIdentity(pin: .current, executablePath: "/test/hc",
        fileIdentity: HCFileIdentity(device: 1, inode: 1, size: 1, modifiedSeconds: 1, modifiedNanoseconds: 0),
        process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 1), coreID: "local-core", protocolGeneration: 1), isPinnedBuild: true)
    private let first: HCJSONValue
    private let then: HCJSONValue
    private var subscribes = 0
    private(set) var sink: (any HCOutputSink)?
    init(first: HCJSONValue, then: HCJSONValue) { self.first = first; self.then = then }
    func request(_ request: HCRPCRequest) async throws -> HCJSONValue {
        switch request.method {
        case "machine.list": return .object(["machines": .array([])])
        case "events.subscribe":
            subscribes += 1
            return subscribes == 1 ? first : then
        default: throw HCUnavailableReason.malformedResponse
        }
    }
    func registerChannel(_ channel: UInt32, attachmentGeneration: UInt64, sink: any HCOutputSink) async throws -> any HCChannel {
        self.sink = sink
        return DoubledAddressChannel()
    }
    nonisolated func close(reason: HCUnavailableReason) {}
}

private struct DoubledAddressChannel: HCChannel {
    let channelID: UInt32 = 1
    let connectionGeneration: UInt64 = 1
    func activate() async throws {}
    func close() {}
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome { .refused(.unavailable) }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome { .refused(.unavailable) }
    func cancel(_ reservation: HCWriteReservation) {}
    func control(_ control: HCControl) async -> HCControlOutcome { .unavailable(.backendNotInstalled) }
}
