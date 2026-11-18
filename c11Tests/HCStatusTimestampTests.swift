import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCStatusTimestampTests: XCTestCase {
    private let key = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t1")

    func testMirrorTimesAreUntrustedAndWordChangesInvalidateEnrichedTimes() throws {
        var reducer = try readyReducer()
        XCTAssertNil(reducer.snapshot.records[key]?.statusTimestampMilliseconds)
        let target = try XCTUnwrap(reducer.statusTarget(for: key, status: "done", turn: 1))
        XCTAssertEqual(reducer.installStatusTimestamp(timestampRecord(), matching: target)?.statusTimestampMilliseconds, 900)
        // Child/record changes with the same root word retain the verified time.
        try reducer.apply(statusEvent(sequence: 2, status: "done"), generation: 1)
        XCTAssertEqual(reducer.snapshot.records[key]?.statusTimestampMilliseconds, 900)
        try reducer.apply(statusEvent(sequence: 3, status: "working"), generation: 1)
        XCTAssertNil(reducer.snapshot.records[key]?.statusTimestampMilliseconds)
        XCTAssertEqual(reducer.snapshot.records[key]?.status, "working")
    }

    func testDelayedRepliesCannotInstallAfterStatusTurnRouteRemovalOrReadinessChange() throws {
        for change in 0..<5 {
            var reducer = try readyReducer()
            let target = try XCTUnwrap(reducer.statusTarget(for: key, status: "done", turn: 1))
            switch change {
            case 0: try reducer.apply(statusEvent(sequence: 2, status: "blocked"), generation: 1)
            case 1: try reducer.apply(timestampEvent(2, "turn", .object(["turn": .integer(2)])), generation: 1)
            case 2: try reducer.setMachines(timestampMachines(core: "replacement-core"))
            case 3: try reducer.apply(timestampEvent(2, "removed", .object([:])), generation: 1)
            default: reducer.invalidate(.connectionLost)
            }
            XCTAssertNil(reducer.installStatusTimestamp(timestampRecord(), matching: target), "change \(change)")
        }
    }

    func testOwningCoreRequestCoalescesAndPublishesWithoutInventingASequence() async throws {
        let connection = TimestampConnection()
        let coalesced = expectation(description: "second caller shares request")
        let source = HCLiveInventorySource(connection: connection, diagnostics: { event, _, _ in
            if event == "hc_status_enrichment_coalesced" { coalesced.fulfill() }
        })
        let before = await source.refresh()
        let first = Task { await source.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 1, connectionGeneration: 1) }
        try await waitForGets(1, connection)
        let second = Task { await source.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 1, connectionGeneration: 1) }
        await fulfillment(of: [coalesced], timeout: 1)
        let calls = await connection.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.params["terminal"].string, "atlas-core/t1")
        XCTAssertLessThanOrEqual(try XCTUnwrap(calls.first).deadlineUptimeNanoseconds, HCMonotonic.deadline(after: 2))
        let observed = expectation(description: "enriched observation")
        let observedKey = key
        let observation = source.observe(on: DispatchQueue(label: "timestamp-test")) { snapshot in
            if snapshot.records[observedKey]?.statusTimestampMilliseconds == 900 { observed.fulfill() }
        }
        await connection.release(0, reply: timestampRecord())
        let result1 = await first.value
        let result2 = await second.value
        XCTAssertEqual(result1?.statusTimestampMilliseconds, 900)
        XCTAssertEqual(result2?.statusTimestampMilliseconds, 900)
        await fulfillment(of: [observed], timeout: 2)
        let after = await source.snapshot()
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.readiness, before.readiness)
        withExtendedLifetime(observation) {}
    }

    func testWrongReplyIdentityStatusTurnOrMissingTimeNeverBecomesCompletionEvidence() async throws {
        for field in ["address", "status", "turn", "status_ms"] {
            let connection = TimestampConnection()
            let source = HCLiveInventorySource(connection: connection)
            _ = await source.refresh()
            let job = Task { await source.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 1, connectionGeneration: 1) }
            try await waitForGets(1, connection)
            var reply = timestampRecord().object!
            switch field {
            case "address": reply[field] = .string("other/t1")
            case "status": reply[field] = .object(["state": .string("working")])
            case "turn": reply[field] = .integer(99)
            default: reply[field] = .null
            }
            await connection.release(0, reply: .object(reply))
            let result = await job.value
            XCTAssertNil(result, field)
            let snapshot = await source.snapshot()
            XCTAssertNil(snapshot.records[key]?.statusTimestampMilliseconds, field)
        }
    }

    func testDeadlineReleasesCallerAndLateReplyCannotFinishTheNextRequest() async throws {
        let connection = TimestampConnection()
        let source = HCLiveInventorySource(connection: connection)
        _ = await source.refresh()
        let start = HCMonotonic.now
        let old = Task { await source.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 1, connectionGeneration: 1) }
        try await waitForGets(1, connection)
        let fallback = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { await connection.release(0, reply: timestampRecord(time: 123)) }
        }
        let expired = await old.value
        fallback.cancel()
        XCTAssertNil(expired)
        XCTAssertLessThan(Double(HCMonotonic.now - start) / 1e9, 2.7)
        let next = Task { await source.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 1, connectionGeneration: 1) }
        try await waitForGets(2, connection)
        await connection.release(0, reply: timestampRecord(time: 123))
        await connection.release(1, reply: timestampRecord(time: 456))
        let result = await next.value
        XCTAssertEqual(result?.statusTimestampMilliseconds, 456)
        let snapshot = await source.snapshot()
        XCTAssertEqual(snapshot.records[key]?.statusTimestampMilliseconds, 456)
    }

    func testAdmissionIsBoundedAndInvalidationRetiresAllWaitingCallers() async throws {
        let connection = TimestampConnection(count: 17)
        let source = HCLiveInventorySource(connection: connection)
        _ = await source.refresh()
        var tasks: [Task<HCTerminalRecord?, Never>] = []
        for index in 1...16 {
            let terminal = HCTerminalKey(owningCoreID: "atlas-core", localAddress: "t\(index)")
            tasks.append(Task { await source.enrichStatusTimestamp(for: terminal, matchingStatus: "done", turn: 1, connectionGeneration: 1) })
        }
        try await waitForGets(16, connection)
        // If the admission guard regresses, still release the deliberately
        // admitted fake request so the assertion fails without hanging XCTest.
        let admissionFallback = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { await connection.release(16, reply: timestampRecord("studio/t17")) }
        }
        let saturated = await source.enrichStatusTimestamp(for: .init(owningCoreID: "atlas-core", localAddress: "t17"),
            matchingStatus: "done", turn: 1, connectionGeneration: 1)
        admissionFallback.cancel()
        XCTAssertNil(saturated)
        let wrongGeneration = await source.enrichStatusTimestamp(for: key, matchingStatus: "done", turn: 1, connectionGeneration: 2)
        XCTAssertNil(wrongGeneration)
        let count = await connection.calls.count
        XCTAssertEqual(count, 16)
        source.invalidate(.connectionLost)
        for task in tasks { let result = await task.value; XCTAssertNil(result) }
        for index in 0..<count { await connection.release(index, reply: timestampRecord()) }
        let snapshot = await source.snapshot()
        XCTAssertEqual(snapshot.readiness, .pending(.connectionLost))
        XCTAssertNil(snapshot.records[key]?.statusTimestampMilliseconds)
    }

    private func readyReducer() throws -> HCInventoryReducer {
        var reducer = HCInventoryReducer(generation: 1, coreID: "local-core")
        try reducer.setMachines(timestampMachines())
        try reducer.install(timestampSnapshot())
        return reducer
    }

    private func waitForGets(_ count: Int, _ connection: TimestampConnection) async throws {
        let deadline = HCMonotonic.deadline(after: 1)
        while await connection.calls.count < count, HCMonotonic.now < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        let actual = await connection.calls.count
        XCTAssertEqual(actual, count)
    }
}

private func timestampRecord(_ address: String = "studio/t1", time: Int64 = 900) -> HCJSONValue {
    .object(["address": .string(address), "state": .string("live"), "pid": .integer(42),
        "labels": .object([:]), "cols": .integer(80), "rows": .integer(24),
        "status": .object(["state": .string("done")]), "status_ms": .integer(time), "turn": .integer(1)])
}
private func timestampSnapshot(count: Int = 1) -> HCJSONValue {
    .object(["channel": .integer(1), "seq": .integer(1),
        "terminals": .array((1...count).map { timestampRecord("studio/t\($0)") })])
}
private func timestampMachines(core: String = "atlas-core") -> HCJSONValue {
    .object(["machines": .array([.object(["name": .string("studio"), "id": .string(core), "state": .string("connected")])])])
}
private func timestampEvent(_ sequence: Int64, _ kind: String, _ data: HCJSONValue) -> HCJSONValue {
    .object(["jsonrpc": .string("2.0"), "method": .string("event"), "params": .object([
        "seq": .integer(sequence), "type": .string(kind), "terminal": .string("studio/t1"), "data": data])])
}
private func statusEvent(sequence: Int64, status: String) -> HCJSONValue {
    timestampEvent(sequence, "status", .object(["status": .object(["state": .string(status)]), "records": .array([]), "reported": .null]))
}

private actor TimestampConnection: HCConnection {
    nonisolated let generation: UInt64 = 1
    nonisolated let peer = HCPeerEvidence(uid: 1, pid: 42, statusPID: 42, coreID: "local-core", version: "0.1.16",
        protocolGeneration: 1, methods: [], features: [])
    nonisolated let verification = HCVerifiedPeer(identity: HCBuildIdentity(pin: .current, executablePath: "/test/hc",
        fileIdentity: HCFileIdentity(device: 1, inode: 1, size: 1, modifiedSeconds: 1, modifiedNanoseconds: 0),
        process: HCProcessIdentity(pid: 42, startTimeMicroseconds: 1), coreID: "local-core", protocolGeneration: 1), isPinnedBuild: true)
    let count: Int
    var calls: [HCRPCRequest] = []
    private var pending: [Int: CheckedContinuation<HCJSONValue, Error>] = [:]
    init(count: Int = 1) { self.count = count }
    func request(_ request: HCRPCRequest) async throws -> HCJSONValue {
        switch request.method {
        case "machine.list": return timestampMachines()
        case "events.subscribe": return timestampSnapshot(count: count)
        case "terminal.get":
            let index = calls.count
            calls.append(request)
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        default: throw HCUnavailableReason.malformedResponse
        }
    }
    func release(_ index: Int, reply: HCJSONValue) { pending.removeValue(forKey: index)?.resume(returning: reply) }
    func registerChannel(_ channel: UInt32, attachmentGeneration: UInt64, sink: any HCOutputSink) async throws -> any HCChannel {
        TimestampChannel()
    }
    nonisolated func close(reason: HCUnavailableReason) {}
}

private struct TimestampChannel: HCChannel {
    let channelID: UInt32 = 1
    let connectionGeneration: UInt64 = 1
    func activate() async throws {}
    func close() {}
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome { .refused(.unavailable) }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome { .refused(.unavailable) }
    func cancel(_ reservation: HCWriteReservation) {}
    func control(_ control: HCControl) async -> HCControlOutcome { .unavailable(.backendNotInstalled) }
}
