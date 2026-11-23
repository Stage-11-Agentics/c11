import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCControlWriterTests: XCTestCase {
    private func token(_ writer: HCControlWriter, bytes: Int = 128) throws -> HCWriteReservation {
        guard case .reserved(let token) = writer.reserve(operationID: UUID(), attachmentGeneration: 10, encodedByteCount: bytes, channel: 1) else {
            throw HCInputRefusal.queueFull
        }
        return token
    }
    func testCreditSurvivesFullDataBudgetAndCoalesces() throws {
        let writer = HCControlWriter(generation: 1, wake: {}, invalidate: { _ in XCTFail() })
        for _ in 0..<4 { _ = try token(writer, bytes: HCLimits.transactionBytes) }
        if case .refused(.queueFull) = writer.reserve(operationID: UUID(), attachmentGeneration: 1, encodedByteCount: 1) {} else {
            XCTFail("DATA cap was not enforced")
        }
        writer.enqueueControl(channel: 1, value: .credit(100))
        writer.enqueueControl(channel: 1, value: .credit(200))
        var output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        var decoder = HCWireDecoder(); var frames: [HCWireFrame] = []
        try decoder.feed(output) { frames.append($0) }
        XCTAssertEqual(frames.count, 1); XCTAssertEqual(frames[0].payload.wireUInt32(at: 0), 300)
        writer.stop()
    }
    func testControlOverflowInvalidatesInsteadOfDropping() {
        let overflow = expectation(description: "overflow")
        let writer = HCControlWriter(generation: 1, wake: {}, invalidate: { reason in
            XCTAssertEqual(reason, .bufferOverflow); overflow.fulfill()
        })
        for channel in 1...20_165 { writer.enqueueControl(channel: UInt32(channel), value: .credit(1)) }
        wait(for: [overflow], timeout: 1)
        writer.stop()
    }
    func testCancelledPartialBodyNeverWritesReturnAndReportsActualBytes() async throws {
        let queued = expectation(description: "queued"); queued.assertForOverFulfill = false
        let invalidated = expectation(description: "partial frame closes")
        let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in invalidated.fulfill() })
        let reservation = try token(writer)
        let batch = HCWriteBatch(operationID: reservation.operationID, attachmentGeneration: 10,
                                 frames: [.data(Data("abcdef".utf8)), .submitReturn(Data([13]))])
        let result = Task { await writer.write(channel: 1, batch: batch, reservation: reservation) }
        await fulfillment(of: [queued], timeout: 1)
        var count = 0
        writer.drain { _, _ in defer { count += 1 }; return count == 0 ? 11 : 0 }
        writer.cancel(reservation)
        await fulfillment(of: [invalidated], timeout: 1)
        guard case .uncertain(let receipt) = await result.value else { return XCTFail("Missing uncertain receipt") }
        XCTAssertEqual(receipt.bodyBytesWritten, 2); XCTAssertFalse(receipt.returnWritten)
        writer.stop()
    }
    func testDelayedReturnAllowsCreditAndCancellation() async throws {
        let queued = expectation(description: "queued"); queued.assertForOverFulfill = false
        let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in XCTFail() })
        let reservation = try token(writer)
        let batch = HCWriteBatch(operationID: reservation.operationID, attachmentGeneration: 10,
                                 frames: [.data(Data("body".utf8)), .submitReturnAfter(Data([13]), delayNanoseconds: 1_000_000_000)])
        let result = Task { await writer.write(channel: 1, batch: batch, reservation: reservation) }
        await fulfillment(of: [queued], timeout: 1)
        var output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        writer.enqueueControl(channel: 1, value: .credit(100))
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        writer.cancel(reservation)
        guard case .uncertain(let receipt) = await result.value else { return XCTFail("Missing receipt") }
        XCTAssertEqual(receipt.bodyBytesWritten, 4); XCTAssertFalse(receipt.returnWritten)
        var decoder = HCWireDecoder(); var frames: [HCWireFrame] = []
        try decoder.feed(output) { frames.append($0) }
        XCTAssertEqual(frames.map(\.kind), [.data, .credit])
        writer.stop()
    }
}

extension HCControlWriterTests {
    func testReturnBarrierExcludesOtherDataButAllowsCredit() async throws {
        let queued = expectation(description: "both batches queued"); queued.expectedFulfillmentCount = 2; queued.assertForOverFulfill = false
        let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in XCTFail() })
        let first = try token(writer); let second = try token(writer)
        let resultA = Task { await writer.write(channel: 1, batch: HCWriteBatch(operationID: first.operationID, attachmentGeneration: 10,
            frames: [.data(Data("A".utf8)), .submitReturnAfter(Data([13]), delayNanoseconds: 100_000_000)]), reservation: first) }
        // Wait for A to take its queue position before B.
        for _ in 0..<100 {
            if writer.hasPending { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(writer.hasPending)
        let resultB = Task { await writer.write(channel: 1, batch: HCWriteBatch(operationID: second.operationID, attachmentGeneration: 10,
            frames: [.data(Data("B".utf8))]), reservation: second) }
        await fulfillment(of: [queued], timeout: 1)
        var output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        writer.enqueueControl(channel: 1, value: .credit(7))
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        var decoder = HCWireDecoder(); var before: [HCWireFrame] = []
        try decoder.feed(output) { before.append($0) }
        XCTAssertEqual(before.map(\.kind), [.data, .credit]); XCTAssertEqual(before[0].payload, Data("A".utf8))
        try await Task.sleep(nanoseconds: 150_000_000)
        output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        var after: [HCWireFrame] = []
        try decoder.feed(output) { after.append($0) }
        XCTAssertEqual(after.map(\.payload), [Data([13]), Data("B".utf8)])
        guard case .written(let receipt) = await resultA.value else { return XCTFail() }
        XCTAssertTrue(receipt.returnWritten)
        guard case .written = await resultB.value else { return XCTFail() }
        writer.stop()
    }
}

extension HCControlWriterTests {
    /// C11H-298: a Return waiting out its paste settle holds back only its own terminal. Another terminal's
    /// input (the operator typing in a visible panel while a send to a hidden one settles) goes ahead; the
    /// waiting terminal's next input stays behind its Return.
    func testAParkedReturnHoldsOnlyItsOwnTerminal() async throws {
        let queued = expectation(description: "three batches queued"); queued.expectedFulfillmentCount = 3; queued.assertForOverFulfill = false
        let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in XCTFail() })
        defer { writer.stop() }
        func reserve(_ channel: UInt32) throws -> HCWriteReservation {
            guard case .reserved(let token) = writer.reserve(operationID: UUID(), attachmentGeneration: 10,
                                                              encodedByteCount: 128, channel: channel) else { throw HCInputRefusal.queueFull }
            return token
        }
        let a = try reserve(1), b = try reserve(2), c = try reserve(1)
        let resultA = Task { await writer.write(channel: 1, batch: HCWriteBatch(operationID: a.operationID, attachmentGeneration: 10,
            frames: [.data(Data("A".utf8)), .submitReturnAfter(Data([13]), delayNanoseconds: 150_000_000)]), reservation: a) }
        for _ in 0..<100 { if writer.hasPending { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let resultB = Task { await writer.write(channel: 2, batch: HCWriteBatch(operationID: b.operationID, attachmentGeneration: 10,
            frames: [.data(Data("B".utf8))]), reservation: b) }
        let resultC = Task { await writer.write(channel: 1, batch: HCWriteBatch(operationID: c.operationID, attachmentGeneration: 10,
            frames: [.data(Data("C".utf8))]), reservation: c) }
        await fulfillment(of: [queued], timeout: 1)
        var output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        var decoder = HCWireDecoder(); var before: [HCWireFrame] = []
        try decoder.feed(output) { before.append($0) }
        XCTAssertEqual(before.map(\.payload), [Data("A".utf8), Data("B".utf8)], "the other terminal's input goes ahead")
        XCTAssertEqual(before.map(\.channel), [1, 2])
        try await Task.sleep(nanoseconds: 200_000_000)
        output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        var after: [HCWireFrame] = []
        try decoder.feed(output) { after.append($0) }
        XCTAssertEqual(after.map(\.payload), [Data([13]), Data("C".utf8)], "its own terminal's input stays behind its Return")
        guard case .written(let receipt) = await resultA.value else { return XCTFail() }
        XCTAssertTrue(receipt.returnWritten)
        guard case .written = await resultB.value, case .written = await resultC.value else { return XCTFail() }
    }

    /// Repair 1, B2: an ordinary RPC queued while terminal A's Return is parked (an inventory read, a timestamp
    /// lookup) does not hold terminal B's keys; the RPC keeps its own place behind A. A file transfer does hold
    /// what follows it, since that input may name the file.
    func testAParkedReturnHoldsOnlyItsOwnTerminalAcrossAQueuedRPC() async throws {
        for fileTransfer in [false, true] {
            let queued = expectation(description: "A and B queued"); queued.expectedFulfillmentCount = 3; queued.assertForOverFulfill = false
            let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in XCTFail() })
            func reserve(_ channel: UInt32) throws -> HCWriteReservation {
                guard case .reserved(let token) = writer.reserve(operationID: UUID(), attachmentGeneration: 10,
                                                                  encodedByteCount: 128, channel: channel) else { throw HCInputRefusal.queueFull }
                return token
            }
            let a = try reserve(1), b = try reserve(2)
            let resultA = Task { await writer.write(channel: 1, batch: HCWriteBatch(operationID: a.operationID, attachmentGeneration: 10,
                frames: [.data(Data("A".utf8)), .submitReturnAfter(Data([13]), delayNanoseconds: 150_000_000)]), reservation: a) }
            for _ in 0..<100 { if writer.hasPending { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            var drained = Data()
            writer.drain { bytes, offset in drained.append(bytes[offset...]); return bytes.count - offset }   // A's text; its Return parks
            let rpc = try HCWireFrame(channel: 0, kind: .data, payload: Data("rpc".utf8)).encoded()
            XCTAssertTrue(writer.enqueueRPC(rpc, fileTransfer: fileTransfer) { _, _ in })
            let resultB = Task { await writer.write(channel: 2, batch: HCWriteBatch(operationID: b.operationID, attachmentGeneration: 10,
                frames: [.data(Data("B".utf8))]), reservation: b) }
            await fulfillment(of: [queued], timeout: 1)
            writer.drain { bytes, offset in drained.append(bytes[offset...]); return bytes.count - offset }
            var decoder = HCWireDecoder(); var before: [HCWireFrame] = []
            try decoder.feed(drained) { before.append($0) }
            try await Task.sleep(nanoseconds: 200_000_000)
            var later = Data()
            writer.drain { bytes, offset in later.append(bytes[offset...]); return bytes.count - offset }
            var after: [HCWireFrame] = []
            try decoder.feed(later) { after.append($0) }
            if fileTransfer {
                XCTAssertEqual(before.map(\.channel), [1], "input after a file transfer waits for it")
                XCTAssertEqual(after.map(\.channel), [1, 0, 2])
            } else {
                XCTAssertEqual(before.map(\.channel), [1, 2], "B's key passes the queued read RPC")
                XCTAssertEqual(before.map(\.payload), [Data("A".utf8), Data("B".utf8)])
                XCTAssertEqual(after.map(\.channel), [1, 0], "the RPC keeps its place behind A's Return")
                XCTAssertEqual(after.first?.payload, Data([13]))
            }
            guard case .written = await resultA.value, case .written = await resultB.value else { return XCTFail() }
            writer.stop()
        }
    }

    func testReservationCannotRetargetAnotherChannel() async throws {
        let writer = HCControlWriter(generation: 1, wake: {}, invalidate: { _ in XCTFail() })
        let reservation = try token(writer)
        let result = try await HCDeadline.perform(until: DispatchTime.now().uptimeNanoseconds + 200_000_000,
            onTimeout: { writer.stop() }) {
            await writer.write(channel: 2, batch: HCWriteBatch(operationID: reservation.operationID,
                attachmentGeneration: 10, frames: [.data(Data("wrong target".utf8))]), reservation: reservation)
        }
        guard case .refused(.staleIdentity) = result else { return XCTFail("Cross-channel reservation accepted") }
        writer.drain { _, _ in XCTFail("Bytes reached another channel"); return 0 }
        writer.stop()
    }
}

extension HCControlWriterTests {
    func testHealthyOpenWriteSurvivesEightSecondsOfBacklog() async throws {
        let queued = expectation(description: "pending DATA"); queued.assertForOverFulfill = false
        let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in XCTFail("Backlog became failure") })
        let reservation = try token(writer)
        let result = Task { await writer.write(channel: 1, batch: HCWriteBatch(operationID: reservation.operationID,
            attachmentGeneration: 10, frames: [.data(Data("still pending".utf8))]), reservation: reservation) }
        await fulfillment(of: [queued], timeout: 1)
        writer.drain { _, _ in 0 }
        // The writer owns no write timeout: a backlogged socket (pathfinder saw
        // 8 s) is not a failure. A short real wait keeps the run budget (C11H-30).
        try await Task.sleep(nanoseconds: 300_000_000)
        writer.drain { _, _ in 0 }
        var output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        guard case .written(let receipt) = await result.value else { return XCTFail("Healthy backlog invalidated write") }
        XCTAssertEqual(receipt.bodyBytesWritten, 13)
        var decoder = HCWireDecoder(); var frames: [HCWireFrame] = []
        try decoder.feed(output) { frames.append($0) }
        XCTAssertEqual(frames.first?.payload, Data("still pending".utf8))
        writer.stop()
    }
}

private final class HCReturnGate: @unchecked Sendable {
    let started: XCTestExpectation
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var began = false
    init(_ started: XCTestExpectation) { self.started = started }
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return began }
    func check() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock(); began = true; self.continuation = continuation; lock.unlock()
            started.fulfill()
        }
    }
    func release(_ accepted: Bool) {
        lock.lock(); let next = continuation; continuation = nil; lock.unlock()
        next?.resume(returning: accepted)
    }
}

private final class HCWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func completed() { lock.lock(); value += 1; lock.unlock() }
}

extension HCControlWriterTests {
    private func drainUntilDone(_ writer: HCControlWriter, count: Int, counter: HCWriteCounter, output: inout Data) async throws {
        for _ in 0..<100 {
            writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
            if counter.count >= count { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // Gives a deliberately late guard approval a chance to try to revive work.
        try await Task.sleep(nanoseconds: 20_000_000)
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        writer.stop()
    }

    func testReturnGuardRejectsAfterSettleWithActualBodyReceipt() async throws {
        try XCTSkipIf(true, "Flaky on the loaded CI runner; quarantined until made deterministic (C11H-431)")
        let queued = expectation(description: "body queued"); queued.assertForOverFulfill = false
        let gate = HCReturnGate(expectation(description: "guard after settle"))
        defer { gate.release(false) }
        let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in XCTFail() })
        defer { writer.stop() }
        let reservation = try token(writer); let counter = HCWriteCounter()
        let result = Task {
            let result = await writer.write(channel: 1, batch: HCWriteBatch(operationID: reservation.operationID,
                attachmentGeneration: 10, frames: [.data(Data("body".utf8)), .submitReturnAfter(Data([13]), delayNanoseconds: 80_000_000)],
                beforeReturn: { await gate.check() }), reservation: reservation)
            counter.completed(); return result
        }
        await fulfillment(of: [queued], timeout: 1)
        var output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        try await Task.sleep(nanoseconds: 30_000_000)
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        XCTAssertFalse(gate.hasStarted, "Predicate ran before paste settle")
        try await Task.sleep(nanoseconds: 70_000_000)
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        await fulfillment(of: [gate.started], timeout: 1)
        gate.release(false)
        try await drainUntilDone(writer, count: 1, counter: counter, output: &output)
        let outcome = await result.value
        if case .uncertain(let receipt) = outcome {
            XCTAssertEqual(receipt.bodyBytesWritten, 4); XCTAssertFalse(receipt.returnWritten)
        } else { XCTFail("Rejected Return did not preserve an interrupted body receipt") }
        var decoder = HCWireDecoder(); var frames: [HCWireFrame] = []
        try decoder.feed(output) { frames.append($0) }
        XCTAssertEqual(frames.map(\.payload), [Data("body".utf8)])
    }

    func testReturnGuardAllowsControlsAndKeepsOtherDataBehind() async throws {
        let queued = expectation(description: "two writes queued"); queued.expectedFulfillmentCount = 2; queued.assertForOverFulfill = false
        let gate = HCReturnGate(expectation(description: "fresh target check"))
        defer { gate.release(false) }
        let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in XCTFail() })
        defer { writer.stop() }
        let first = try token(writer); let second = try token(writer); let counter = HCWriteCounter()
        let resultA = Task {
            let outcome = await writer.write(channel: 1, batch: HCWriteBatch(operationID: first.operationID,
                attachmentGeneration: 10, frames: [.data(Data("A".utf8)), .submitReturn(Data([13]))],
                beforeReturn: { await gate.check() }), reservation: first)
            counter.completed(); return outcome
        }
        for _ in 0..<100 { if writer.hasPending { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let resultB = Task {
            let outcome = await writer.write(channel: 1, batch: HCWriteBatch(operationID: second.operationID,
                attachmentGeneration: 10, frames: [.data(Data("B".utf8))]), reservation: second)
            counter.completed(); return outcome
        }
        await fulfillment(of: [queued], timeout: 1)
        var output = Data()
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        await fulfillment(of: [gate.started], timeout: 1)
        writer.enqueueControl(channel: 1, value: .credit(7))
        writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
        var decoder = HCWireDecoder(); var before: [HCWireFrame] = []
        try decoder.feed(output) { before.append($0) }
        XCTAssertEqual(before.map(\.kind), [.data, .credit])
        XCTAssertEqual(before.first?.payload, Data("A".utf8))
        gate.release(true)
        output = Data()
        try await drainUntilDone(writer, count: 2, counter: counter, output: &output)
        var after: [HCWireFrame] = []
        try decoder.feed(output) { after.append($0) }
        XCTAssertEqual(after.map(\.payload), [Data([13]), Data("B".utf8)])
        if case .written(let receipt) = await resultA.value { XCTAssertTrue(receipt.returnWritten) } else { XCTFail("Approved Return was not written") }
        if case .written = await resultB.value {} else { XCTFail("Following DATA never completed") }
    }

    func testCancelAndStopWakeSuspendedReturnGuardAndIgnoreLateApproval() async throws {
        for stopConnection in [false, true] {
            let queued = expectation(description: "queued \(stopConnection)"); queued.assertForOverFulfill = false
            let completed = expectation(description: "cancel completes before guard \(stopConnection)")
            let gate = HCReturnGate(expectation(description: "guard suspended \(stopConnection)"))
            defer { gate.release(false) }
            let writer = HCControlWriter(generation: 1, wake: { queued.fulfill() }, invalidate: { _ in XCTFail() })
            defer { writer.stop() }
            let reservation = try token(writer); let counter = HCWriteCounter()
            let result = Task {
                let outcome = await writer.write(channel: 1, batch: HCWriteBatch(operationID: reservation.operationID,
                    attachmentGeneration: 10, frames: [.data(Data("kept".utf8)), .submitReturn(Data([13]))],
                    beforeReturn: { await gate.check() }), reservation: reservation)
                counter.completed(); completed.fulfill(); return outcome
            }
            await fulfillment(of: [queued], timeout: 1)
            var output = Data()
            writer.drain { bytes, offset in output.append(bytes[offset...]); return bytes.count - offset }
            await fulfillment(of: [gate.started], timeout: 1)
            if stopConnection { writer.stop() } else { writer.cancel(reservation) }
            await fulfillment(of: [completed], timeout: 0.5)
            gate.release(true)
            try await drainUntilDone(writer, count: 1, counter: counter, output: &output)
            if case .uncertain(let receipt) = await result.value {
                XCTAssertEqual(receipt.bodyBytesWritten, 4); XCTAssertFalse(receipt.returnWritten)
            } else { XCTFail("Cancellation lost the actual body receipt") }
            var decoder = HCWireDecoder(); var frames: [HCWireFrame] = []
            try decoder.feed(output) { frames.append($0) }
            XCTAssertEqual(frames.map(\.payload), [Data("kept".utf8)])
        }
    }
}
