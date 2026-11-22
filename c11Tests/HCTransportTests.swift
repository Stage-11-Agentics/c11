import XCTest
import Darwin
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class HCTransportTests: XCTestCase {
    func testFragmentedFramesAndPayloadBounds() throws {
        let first = HCWireFrame(channel: 7, kind: .data, payload: Data("abc".utf8))
        let second = try HCWireFrame.control(channel: 7, .resize(HCGridSize(columns: 123, rows: 45)))
        let bytes = try first.encoded() + second.encoded()
        var decoder = HCWireDecoder(); var frames: [HCWireFrame] = []
        for byte in bytes { try decoder.feed(Data([byte])) { frames.append($0) } }
        XCTAssertEqual(frames, [first, second]); XCTAssertNoThrow(try decoder.finish())
        var oversized = Data(); oversized.appendLE(UInt32(1)); oversized.append(0); oversized.appendLE(UInt32(HCLimits.frameBytes + 1))
        XCTAssertThrowsError(try decoder.feed(oversized) { _ in XCTFail("Oversized frame delivered") })
    }

    func testTruncatedAndMalformedControl() throws {
        var decoder = HCWireDecoder()
        try decoder.feed(Data([0, 1])) { _ in XCTFail() }
        XCTAssertThrowsError(try decoder.finish())
        decoder = HCWireDecoder()
        var malformed = Data(); malformed.appendLE(UInt32(2)); malformed.append(1); malformed.appendLE(UInt32(3))
        XCTAssertThrowsError(try decoder.feed(malformed) { _ in XCTFail() })
    }

    func testEventLinesSplitAcrossFrames() throws {
        var lines = HCEventLines(); var values: [HCJSONValue] = []
        try lines.feed(Data("{\"seq\":".utf8)) { values.append($0) }
        XCTAssertTrue(values.isEmpty)
        try lines.feed(Data("12}\n{\"seq\":13}\n".utf8)) { values.append($0) }
        XCTAssertEqual(values.map { $0["seq"].integer }, [12, 13])
        XCTAssertTrue(lines.pending.isEmpty)
        XCTAssertThrowsError(try lines.feed(Data(repeating: 65, count: HCLimits.eventBufferBytes + 1)) { _ in XCTFail() })
    }

    func testDeadlineDoesNotWaitForUncooperativeWork() async {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let _: Int = try await HCDeadline.perform(until: start + 100_000_000, onTimeout: {}) {
                // Deliberately ignores cancellation, like a blocking identity probe.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { continuation.resume(returning: 1) }
                }
            }
            XCTFail("Deadline did not win")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .deadlineExceeded) }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 0.5)
    }

    func testFactsUsePinnedWireSchema() throws {
        let frame = try HCWireFrame.control(channel: 1, .facts(HCDisplayFacts(
            foreground: HCRGBColor(red: 1, green: 2, blue: 255), cellWidth: 9, cellHeight: 18)))
        let json = try HCJSONValue.decode(frame.payload)
        XCTAssertEqual(json["fg"], .string("#0102ff"))
        XCTAssertEqual(json["cell"], .array([.integer(9), .integer(18)]))
    }
}

private final class HCWirePeer: @unchecked Sendable {
    enum Behavior { case normal, trickle, wrongPID, slowRun, events, attachment, overlongHello, slowFirstMachine, gapEvents, malformedEvents, creditOverrun, heldPut, missedEvents, heldRun }
    let url: URL
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32 = -1
    private var stopped = false
    private var credited = 0
    private var calls: [String: Int] = [:]
    private let resubscribeGate = DispatchSemaphore(value: 0)
    func releaseResubscribe() { resubscribeGate.signal() }
    /// `.heldPut`: a `terminal.put` reply waits for this while other calls
    /// are answered, as hc runs calls side by side.
    private let putGate = DispatchSemaphore(value: 0)
    private let sendLock = NSLock()
    func releasePut() { putGate.signal() }
    /// `.heldRun`: a `terminal.run` reply waits for this while other calls are answered.
    private let runGate = DispatchSemaphore(value: 0)
    func releaseRun() { runGate.signal() }
    func callCount(_ method: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls[method, default: 0] }
    /// C11H-306: what an attach sends back. `attachPaint` is queued on a fresh channel before the reply, as hc
    /// queues its first paint; `attachEnds` closes that channel after it; `attachSilent` never replies.
    private var paint: Data?
    private var paintRest: Data?
    private var paintRestDelay: TimeInterval = 0
    private var paintEnds = false
    private var silentAttach = false
    /// C11H-327: a silent attach's reply, sent late when the test releases it; `close()` lets every waiter go.
    private let attachGate = DispatchSemaphore(value: 0)
    private var attachWaiters = 0
    func releaseHeldAttach() { attachGate.signal() }
    private var nextPaintChannel: UInt32 = 9
    private var attachParams: [HCJSONValue] = []
    private var clientClosed: [UInt32] = []
    func configureAttach(paint: Data?, ends: Bool = false, silent: Bool = false, rest: Data? = nil, restAfter: TimeInterval = 0) {
        lock.lock(); self.paint = paint; paintEnds = ends; silentAttach = silent
        paintRest = rest; paintRestDelay = restAfter; lock.unlock()
    }
    var attachRequests: [HCJSONValue] { lock.lock(); defer { lock.unlock() }; return attachParams }
    var closedByClient: [UInt32] { lock.lock(); defer { lock.unlock() }; return clientClosed }
    var creditBytes: Int { lock.lock(); defer { lock.unlock() }; return credited }
    private let behavior: Behavior
    init(_ behavior: Behavior) throws {
        self.behavior = behavior
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("c11-test-evidence/C11H-21")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("p-\(UUID().uuidString.prefix(8)).sock")
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HCUnavailableReason.coreUnreachable }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8) + [UInt8(0)]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw HCUnavailableReason.invalidLaunchTuple }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard result == 0, Darwin.listen(listener, 1) == 0 else { throw HCUnavailableReason.coreUnreachable }
        DispatchQueue.global().async { [self] in serve() }
    }
    func close() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true
        let client = self.client; lock.unlock()
        resubscribeGate.signal()
        putGate.signal()
        runGate.signal()
        lock.lock(); let waiters = attachWaiters; lock.unlock()
        for _ in 0..<waiters { attachGate.signal() }
        if client >= 0 { Darwin.shutdown(client, SHUT_RDWR) }
        Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener)
        try? FileManager.default.removeItem(at: url)
    }
    private func serve() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        lock.lock(); client = fd; let stop = stopped; lock.unlock()
        defer { Darwin.close(fd) }
        if stop { return }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        func read(_ count: Int) -> Data? {
            var result = Data()
            // Bounded chunks: a multi-megabyte frame (an 8 MiB put) must not
            // reallocate its whole remainder on every recv.
            var bytes = [UInt8](repeating: 0, count: min(count, 64 * 1024))
            while result.count < count {
                let n = Darwin.recv(fd, &bytes, min(bytes.count, count - result.count), 0)
                guard n > 0 else { return nil }; result.append(contentsOf: bytes.prefix(n))
            }
            return result
        }
        func send(_ bytes: Data) -> Bool {
            sendLock.lock(); defer { sendLock.unlock() }
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
                guard n > 0 else { return false }; offset += n
            }
            return true
        }
        var line = Data()
        while let byte = read(1) { line.append(byte); if byte[0] == 10 { break } }
        guard line.last == 10 else { return }
        let hello: HCJSONValue = .object(["jsonrpc": .string("2.0"), "id": .integer(0), "result": .object([
            "generation": .integer(1), "version": .string("0.1.16"), "core": .object(["id": .string("fixture")]),
            "framed": .bool(true), "methods": .array(["server.status", "terminal.run", "terminal.attach", "events.subscribe"].map(HCJSONValue.string)),
            "features": .array(["framed", "attach", "events", "status"].map(HCJSONValue.string))])])
        guard var helloBytes = try? hello.encoded() else { return }; helloBytes.append(10)
        if behavior == .overlongHello {
            guard send(Data(repeating: 65, count: HCLimits.helloBytes + 1)) else { return }
        } else if behavior == .trickle {
            for byte in helloBytes {
                guard send(Data([byte])) else { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
        } else if !send(helloBytes) { return }
        while true {
            let keepGoing: Bool = autoreleasepool {
                guard let header = read(9), let payload = read(Int(header.wireUInt32(at: 5))) else { return false }
                if header.wireUInt32(at: 0) != 0 {
                    if header[4] == 1, payload.count == 4 {
                        lock.lock(); credited += Int(payload.wireUInt32(at: 0)); lock.unlock()
                    }
                    if header[4] == 2 { lock.lock(); clientClosed.append(header.wireUInt32(at: 0)); lock.unlock() }
                    return true
                }
                guard let request = try? HCJSONValue.decode(payload) else { return false }
                let method = request["method"].string
                if let method { lock.lock(); calls[method, default: 0] += 1; lock.unlock() }
                let result: HCJSONValue
                if method == "server.status" {
                    result = .object(["pid": .integer(Int64(getpid()) + (behavior == .wrongPID ? 1 : 0)),
                        "core": .object(["id": .string("fixture")]), "version": .string("0.1.16")])
                } else if method == "machine.list" {
                    if behavior == .slowFirstMachine, callCount("machine.list") == 1 { Thread.sleep(forTimeInterval: 0.4) }
                    result = .object(["machines": .array([])])
                } else if method == "terminal.attach", let configured: (Data?, Bool, Bool, UInt32, Data?, TimeInterval) = {
                    lock.lock(); defer { lock.unlock() }
                    guard paint != nil || silentAttach || paintEnds else { return nil }
                    attachParams.append(request["params"])
                    nextPaintChannel += 2
                    return (paint, paintEnds, silentAttach, nextPaintChannel, paintRest, paintRestDelay)
                }() {
                    let (bytes, ends, silent, channel, rest, restAfter) = configured
                    if let rest, !rest.isEmpty {
                        // The rest of the paint in a later frame, after a pause longer than any quiet window.
                        DispatchQueue.global().asyncAfter(deadline: .now() + restAfter) {
                            if let frame = try? HCWireFrame(channel: channel, kind: .data, payload: rest).encoded() { _ = send(frame) }
                        }
                    }
                    if silent {
                        let id = request["id"], gate = attachGate
                        lock.lock(); attachWaiters += 1; lock.unlock()
                        DispatchQueue.global().async { [self] in
                            let released = gate.wait(timeout: .now() + 10) == .success
                            lock.lock(); attachWaiters -= 1; let stop = stopped; lock.unlock()
                            guard released, !stop else { return }
                            let envelope: HCJSONValue = .object(["jsonrpc": .string("2.0"), "id": id,
                                "result": .object(["channel": .integer(Int64(channel)),
                                                   "terminal": .object(["cols": .integer(80), "rows": .integer(24)])])])
                            if let body = try? envelope.encoded(), let bytes = try? HCWireFrame(channel: 0, kind: .data, payload: body).encoded() {
                                _ = send(bytes)
                            }
                        }
                        return true
                    }
                    if let bytes, !bytes.isEmpty {
                        guard let frame = try? HCWireFrame(channel: channel, kind: .data, payload: bytes).encoded(),
                              send(frame) else { return false }
                    }
                    if ends {
                        guard let frame = try? HCWireFrame(channel: channel, kind: .close, payload: Data()).encoded(),
                              send(frame) else { return false }
                    }
                    result = .object(["channel": .integer(Int64(channel)),
                                      "terminal": .object(["cols": .integer(80), "rows": .integer(24)])])
                } else if method == "terminal.attach" {
                    guard let bytes = try? HCWireFrame(channel: 3, kind: .data, payload: behavior == .creditOverrun ? Data(repeating: 65, count: HCLimits.initialCreditBytes + 1) : Data("OUTPUT".utf8)).encoded(), send(bytes) else { return false }
                    result = .object(["channel": .integer(3)])
                } else if method == "fixture.event", behavior == .missedEvents {
                    // hc replaced a burst of events (a spool doc event among them) with a snapshot.
                    let record: HCJSONValue = .object(["address": .string("t1"), "state": .string("live"), "pid": .integer(99),
                        "labels": .object([:]), "cols": .integer(80), "rows": .integer(24)])
                    let missed: HCJSONValue = .object(["jsonrpc": .string("2.0"), "method": .string("missed"),
                        "params": .object(["seq": .integer(14), "terminals": .array([record])])])
                    guard var line = try? missed.encoded() else { return false }; line.append(10)
                    guard let frame = try? HCWireFrame(channel: 3, kind: .data, payload: line).encoded(), send(frame) else { return false }
                    result = .object([:])
                } else if method == "fixture.event" {
                    let gap: HCJSONValue = .object(["jsonrpc": .string("2.0"), "method": .string("event"),
                        "params": .object(["seq": .integer(13), "type": .string("removed"), "terminal": .string("t1")])])
                    var line = behavior == .malformedEvents ? Data("not-json".utf8) : try! gap.encoded()
                    line.append(10)
                    guard let frame = try? HCWireFrame(channel: 3, kind: .data, payload: line).encoded(), send(frame) else { return false }
                    result = .object([:])
                } else if method == "events.subscribe" {
                    let attempt = callCount("events.subscribe")
                    if attempt == 2, behavior == .gapEvents || behavior == .malformedEvents {
                        _ = resubscribeGate.wait(timeout: .now() + 3)
                    }
                    let channel = UInt32(attempt + 2)
                    let sequence = Int64(attempt * 10)
                    let record: HCJSONValue = .object(["address": .string("t1"), "state": .string("live"), "pid": .integer(99),
                        "labels": .object([:]), "cols": .integer(80), "rows": .integer(24)])
                    let event: HCJSONValue = .object(["jsonrpc": .string("2.0"), "method": .string("event"), "params": .object([
                        "seq": .integer(sequence + 1), "type": .string("created"), "terminal": .string("t1"), "data": record])])
                    guard var line = try? event.encoded() else { return false }; line.append(10)
                    guard let early = try? HCWireFrame(channel: channel, kind: .data, payload: line).encoded(), send(early) else { return false }
                    result = .object(["seq": .integer(sequence), "terminals": .array([]), "channel": .integer(Int64(channel))])
                } else if method == "terminal.put", behavior == .heldPut {
                    let id = request["id"]
                    let gate = putGate
                    DispatchQueue.global().async {
                        _ = gate.wait(timeout: .now() + 10)
                        let envelope: HCJSONValue = .object(["jsonrpc": .string("2.0"), "id": id,
                            "result": .object(["path": .string("/remote/put/1/shot.png"), "bytes": .integer(1)])])
                        if let body = try? envelope.encoded(), let bytes = try? HCWireFrame(channel: 0, kind: .data, payload: body).encoded() {
                            _ = send(bytes)
                        }
                    }
                    return true
                } else if method == "terminal.run", behavior == .heldRun {
                    let id = request["id"]
                    let gate = runGate
                    DispatchQueue.global().async {
                        _ = gate.wait(timeout: .now() + 10)
                        let envelope: HCJSONValue = .object(["jsonrpc": .string("2.0"), "id": id,
                            "result": .object(["address": .string("t1")])])
                        if let body = try? envelope.encoded(), let bytes = try? HCWireFrame(channel: 0, kind: .data, payload: body).encoded() {
                            _ = send(bytes)
                        }
                    }
                    return true
                } else if method == "terminal.run" {
                    if behavior == .slowRun { Thread.sleep(forTimeInterval: HCTransportTests.scaledSlowRunSeconds) }
                    result = .object(["address": .string("t1")])
                } else { result = .object([:]) }
                let envelope: HCJSONValue = .object(["jsonrpc": .string("2.0"), "id": request["id"], "result": result])
                guard let body = try? envelope.encoded(), let bytes = try? HCWireFrame(channel: 0, kind: .data, payload: body).encoded() else { return false }
                return send(bytes)
            }
            if !keepGoing { return }
        }
    }
}

extension HCTransportTests {
    private func request(_ peer: HCWirePeer, deadlineSeconds: TimeInterval = 2) -> HCConnectionRequest {
        let config = HCLaunchConfiguration(executableURL: URL(fileURLWithPath: "/fixture/not-launched"), session: "c11-test",
            socketURL: peer.url, stateDirectory: peer.url.deletingLastPathComponent(), intentDirectory: peer.url.deletingLastPathComponent(),
            environment: [:], pin: .current)
        return HCConnectionRequest(configuration: config, generation: 1,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(deadlineSeconds * 1e9))
    }
    func testTrickleHelloHasOneTotalDeadlineAndMainQueueStaysResponsive() async throws {
        // The peer trickles its hello one byte every 20 ms (about 5 s in all);
        // the 0.4 s connection deadline covers the whole handshake.
        let peer = try HCWirePeer(.trickle); defer { peer.close() }
        let heartbeat = expectation(description: "main queue remains live")
        let start = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 0.3)
            heartbeat.fulfill()
        }
        do {
            _ = try await HCLiveConnectionFactory().connect(request(peer, deadlineSeconds: 0.4), verify: { _ in XCTFail("Incomplete handshake reached verifier"); throw HCUnavailableReason.malformedResponse })
            XCTFail("Trickling peer connected")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .deadlineExceeded) }
        await fulfillment(of: [heartbeat], timeout: 1)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        XCTAssertGreaterThan(elapsed, 0.3); XCTAssertLessThan(elapsed, 0.9)
    }
    func testKernelPeerMismatchNeverReachesVerifier() async throws {
        let peer = try HCWirePeer(.wrongPID); defer { peer.close() }
        do {
            _ = try await HCLiveConnectionFactory().connect(request(peer), verify: { _ in XCTFail("Wrong pid accepted"); throw HCUnavailableReason.malformedResponse })
            XCTFail("Wrong pid connected")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .foreignSession) }
    }
    func testVerifierIsRequiredBeforeConnectionEscapes() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        do {
            _ = try await HCLiveConnectionFactory().connect(request(peer), verify: { _ in throw HCUnavailableReason.pinMismatch })
            XCTFail("Failed verification accepted")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .pinMismatch) }
    }
    /// Pathfinder saw valid runs take up to 16 s through hc. The production run
    /// budget must exceed that; the transport rule below is proven at 1/50 scale.
    static let pathfinderWorstRunSeconds: TimeInterval = 16
    static let scaledRunBudgetNanoseconds: UInt64 = 600_000_000
    static let scaledSlowRunSeconds: TimeInterval = 0.3

    func testRunMayOutliveFifteenSecondsWithoutHandshakeTimeout() async throws {
        XCTAssertGreaterThan(HCLimits.runSeconds, Self.pathfinderWorstRunSeconds,
                             "the run budget must cover pathfinder's slowest valid run")
        let peer = try HCWirePeer(.slowRun); defer { peer.close() }
        var scaled = request(peer)
        scaled.runBudgetNanoseconds = Self.scaledRunBudgetNanoseconds
        let connection = try await HCLiveConnectionFactory().connect(scaled, verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        // The caller's deadline is far shorter than the peer's reply; a transmitted
        // run still keeps the full run budget, so the slow reply is accepted.
        let value = try await connection.request(HCRPCRequest(method: "terminal.run", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 50_000_000))
        XCTAssertEqual(value["address"], .string("t1"))
        let status = try await connection.request(HCRPCRequest(method: "server.status", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertEqual(status["pid"].integer, Int64(getpid()))
    }

    /// C11H-308, the other side: a run hc never answers is silence, and its
    /// ambiguous creation still closes the transmitting connection (2A).
    func testASilentRunStillFailsTheConnection() async throws {
        let peer = try HCWirePeer(.heldRun); defer { peer.close() }
        var scaled = request(peer)
        scaled.runBudgetNanoseconds = 300_000_000
        let connection = try await HCLiveConnectionFactory().connect(scaled, verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        do {
            _ = try await connection.request(HCRPCRequest(method: "terminal.run", params: .object([:]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 50_000_000))
            XCTFail("a run hc never answers must not report success")
        } catch let failure as HCRPCFailure {
            XCTAssertEqual(failure.reason, .deadlineExceeded)
        }
        do {
            _ = try await connection.request(HCRPCRequest(method: "server.status", params: .object([:]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
            XCTFail("a silent run must close the connection that sent it")
        } catch let failure as HCRPCFailure {
            XCTAssertEqual(failure.reason, .connectionLost)
        }
    }

    /// C11H-308: a caller that stops waiting for a run hc already has (its
    /// panel closed) is not silence. Every terminal shares this connection, so
    /// it keeps serving; only the run's late reply is dropped.
    func testACancelledPendingRunLeavesTheSharedConnectionServing() async throws {
        let peer = try HCWirePeer(.heldRun); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let run = Task {
            try await connection.request(HCRPCRequest(method: "terminal.run", params: .object([:]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000))
        }
        let limit = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while peer.callCount("terminal.run") == 0, DispatchTime.now().uptimeNanoseconds < limit {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(peer.callCount("terminal.run"), 1, "the run must be pending in hc before the cancel")
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("a cancelled run must not report success")
        } catch let failure as HCRPCFailure {
            XCTAssertEqual(failure.reason, .cancelled)
            XCTAssertEqual(failure.transmission, .possible)
        }
        peer.releaseRun()
        let status = try await connection.request(HCRPCRequest(method: "server.status", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertEqual(status["pid"].integer, Int64(getpid()))
    }
}

extension HCTransportTests {
    func testInventoryConsumesEarlyEventsBeforeReadyAndKeepsInitialObservation() async throws {
        let peer = try HCWirePeer(.events); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let inventory = HCLiveInventorySource(connection: connection)
        let observerQueue = DispatchQueue(label: "c11.tests.blocked-observer")
        observerQueue.suspend()
        let initial = expectation(description: "initial pending")
        let ready = expectation(description: "consistent ready")
        let observation = inventory.observe(on: observerQueue) { snapshot in
            switch snapshot.readiness {
            case .pending: initial.fulfill()
            case .ready:
                XCTAssertEqual(snapshot.revision.sequence, 11)
                XCTAssertEqual(snapshot.records.values.first?.pid, 99)
                ready.fulfill()
            }
        }
        let snapshot = await inventory.refresh()
        XCTAssertEqual(snapshot.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 11)))
        XCTAssertEqual(snapshot.records.values.first?.pid, 99)
        observerQueue.resume()
        await fulfillment(of: [initial, ready], timeout: 2, enforceOrder: true)
        observation.cancel(); inventory.invalidate(.cancelled)
    }
    #if DEBUG
    func testDebugTrickleStillUsesActualCoreAndTotalDeadline() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await HCLiveConnectionFactory(faults: HCDebugWireFaults(helloByteDelayNanoseconds: 100_000_000)).connect(request(peer, deadlineSeconds: 0.3), verify: { _ in XCTFail("Incomplete hello verified"); throw HCUnavailableReason.malformedResponse })
            XCTFail("Debug trickle escaped deadline")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .deadlineExceeded) }
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 0.8)
    }
    #endif
}

private final class HCBlockedSink: HCOutputSink, @unchecked Sendable {
    let received: XCTestExpectation
    private let lock = NSLock()
    private var completion: CheckedContinuation<HCOutputConsumption, Never>?
    var hasReceived: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    init(received: XCTestExpectation) { self.received = received }
    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption {
        await withCheckedContinuation { continuation in
            XCTAssertEqual(chunk.attachmentGeneration, 42)
            lock.lock(); completion = continuation; lock.unlock()
            received.fulfill()
        }
    }
    func release() {
        lock.lock(); let continuation = completion; completion = nil; lock.unlock()
        continuation?.resume(returning: .consumed)
    }
    func retire(completion: @escaping @Sendable () -> Void) { release(); completion() }
}

extension HCTransportTests {
    func testStreamCreditFollowsConsumptionIncludingEarlyOutput() async throws {
        let peer = try HCWirePeer(.attachment); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let attached = try await connection.request(HCRPCRequest(method: "terminal.attach", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertEqual(attached["channel"].integer, 3)
        let received = expectation(description: "sink receives early output")
        let sink = HCBlockedSink(received: received)
        let registrationFinished = HCCompletionFlag()
        let channel = try await connection.registerChannel(3, attachmentGeneration: 42, sink: sink)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(sink.hasReceived)
        let registered = Task {
            try await channel.activate()
            registrationFinished.mark(); return channel
        }
        await fulfillment(of: [received], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(peer.creditBytes, 0)
        XCTAssertFalse(registrationFinished.isSet)
        sink.release()
        _ = try await registered.value
        for _ in 0..<100 {
            if peer.creditBytes == 6 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(peer.creditBytes, 6)
        channel.close()
    }
}

/// C11H-327: what a session over a real engine on the wire peer needs: the fixture's verification, no core
/// launch, and one running terminal on the connection it is bound to.
private struct HCFixtureVerifier: HCPeerVerifying {
    func verify(_ peer: HCPeerEvidence, configuration: HCLaunchConfiguration) async throws -> HCVerifiedPeer {
        try await fixtureVerification(peer)
    }
    func validateOwnedState(_ configuration: HCLaunchConfiguration, coreID: String) async throws {}
}

private struct HCNoCoreLaunch: HCCoreLaunching {
    func start(_ configuration: HCLaunchConfiguration, deadlineUptimeNanoseconds: UInt64) async throws -> HCLaunchLimitReport {
        throw HCUnavailableReason.coreUnreachable
    }
}

private actor HCOneTerminalInventory: HCInventorySource {
    let key: HCTerminalKey
    private var generation: UInt64 = 0
    init(key: HCTerminalKey) { self.key = key }
    func bind(_ generation: UInt64) { self.generation = generation }
    nonisolated func observe(on queue: DispatchQueue, handler: @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation {
        HCObservation()
    }
    func snapshot() async -> HCInventorySnapshot {
        let revision = HCRevision(connectionGeneration: generation, sequence: 1)
        return HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                                   records: [key: HCTerminalRecord(key: key, state: .running, labels: [:], pid: 7)],
                                   buildIdentity: nil)
    }
    func refresh() async -> HCInventorySnapshot { await snapshot() }
}

/// True for the first caller only.
private final class HCFirstCall: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
}

private let fixtureVerification: HCServingBuildVerifier = { peer in
    HCVerifiedPeer(identity: HCBuildIdentity(pin: .current, executablePath: "/fixture/not-launched",
        fileIdentity: HCFileIdentity(device: 1, inode: 1, size: 1, modifiedSeconds: 1, modifiedNanoseconds: 1),
        process: HCProcessIdentity(pid: peer.pid, startTimeMicroseconds: 1), coreID: peer.coreID,
        protocolGeneration: peer.protocolGeneration), isPinnedBuild: true)
}

#if DEBUG
extension HCTransportTests {
    func testDebugEnvironmentRejectsInvalidConfiguration() throws {
        XCTAssertThrowsError(try HCDebugWireFaults.environment(["C11_HC_FAULTS": "{\"unknown\":1}"]))
        XCTAssertThrowsError(try HCDebugWireFaults.environment(["C11_HC_FAULTS": "{\"hello_trickle_ms\":-1}"]))
        XCTAssertThrowsError(try HCDebugWireFaults.environment(["C11_HC_FAULTS": "{\"throttle_bps\":0}"]))
        let faults = try HCDebugWireFaults.environment(["C11_HC_FAULTS": "{\"fail\":{\"terminal.attach\":{\"kind\":\"not_found\"}},\"delay_ms\":{\"terminal.get\":123}}"])
        XCTAssertEqual(faults.failMethods["terminal.attach"]?.count, 1)
        XCTAssertEqual(faults.delayReplyNanoseconds["terminal.get"], 123_000_000)
    }
    func testDebugFailBeforeTransmissionThenNamedDelay() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let factory = try HCLiveConnectionFactory(environment: ["C11_HC_FAULTS": "{\"fail\":{\"terminal.get\":{\"kind\":\"internal\",\"count\":1}},\"delay_ms\":{\"terminal.get\":150}}"])
        let connection = try await factory.connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        func query() -> HCRPCRequest { HCRPCRequest(method: "terminal.get", params: .object([:]), deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000) }
        do { _ = try await connection.request(query()); XCTFail("Injected rejection missing") }
        catch let error as HCRPCFailure { XCTAssertEqual(error.remoteCode, "internal") }
        XCTAssertEqual(peer.callCount("terminal.get"), 0)
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await connection.request(query())
        XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - start, 140_000_000)
        XCTAssertEqual(peer.callCount("terminal.get"), 1)
    }
    func testDebugDroppedReplyStillExecutesAndThenTimesOut() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let factory = try HCLiveConnectionFactory(environment: ["C11_HC_FAULTS": "{\"drop_reply\":{\"terminal.get\":1}}"])
        let connection = try await factory.connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        do {
            _ = try await connection.request(HCRPCRequest(method: "terminal.get", params: .object([:]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 200_000_000))
            XCTFail("Dropped reply delivered")
        } catch let error as HCRPCFailure { XCTAssertEqual(error.reason, .deadlineExceeded) }
        XCTAssertEqual(peer.callCount("terminal.get"), 1)
        let status = try await connection.request(HCRPCRequest(method: "server.status", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertEqual(status["pid"].integer, Int64(getpid()))
    }
    /// Each fault on its own connection. The sever timer starts at connect, so on
    /// one connection it raced the throttled request: under load the request was
    /// still being written when the timer cut it (`connectionLost`).
    func testDebugSeverTimerAndWriteThrottle() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let throttled = try await HCLiveConnectionFactory(environment: ["C11_HC_FAULTS": "{\"throttle_bps\":3000}"])
            .connect(request(peer), verify: fixtureVerification)
        defer { throttled.close(reason: .cancelled) }
        let start = DispatchTime.now().uptimeNanoseconds
        // About 650 bytes at 3000 bytes/s: the throttle holds the request past 0.15 s.
        // Load only lengthens it; the deadline is a guard, not the claim.
        _ = try await throttled.request(HCRPCRequest(method: "terminal.get", params: .object(["padding": .string(String(repeating: "x", count: 600))]),
            deadlineUptimeNanoseconds: start + 10_000_000_000))
        XCTAssertGreaterThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 0.15)

        // The fixture peer serves one client, so the sever runs against its own.
        let severPeer = try HCWirePeer(.normal); defer { severPeer.close() }
        let fired = expectation(description: "sever timer fired")
        let severing = try HCLiveConnectionFactory(environment: ["C11_HC_FAULTS": "{\"sever_after_ms\":800}"],
                                                   diagnostics: { event, _, _ in if event == "hc_wire_fault_sever_timer" { fired.fulfill() } })
        let armedBefore = DispatchTime.now().uptimeNanoseconds
        let severed = try await severing.connect(request(severPeer), verify: fixtureVerification)
        defer { severed.close(reason: .cancelled) }
        await fulfillment(of: [fired], timeout: 10)
        let armedFor = DispatchTime.now().uptimeNanoseconds - armedBefore
        XCTAssertGreaterThanOrEqual(armedFor, 800_000_000, "The timer never cuts early")
        // Loose: six times the delay, so load cannot reach it, while a units slip (10x or more) does.
        XCTAssertLessThan(armedFor, 5_000_000_000, "sever_after_ms counts milliseconds")
        do {
            _ = try await severed.request(HCRPCRequest(method: "server.status", params: .object([:]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000))
            XCTFail("Severed connection still available")
        } catch let error as HCRPCFailure { XCTAssertEqual(error.reason, .connectionLost) }
    }
}
#endif

private final class HCCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func mark() { lock.lock(); value = true; lock.unlock() }
}

extension HCTransportTests {
    func testEventAndEarlyStorageShareOneBudget() {
        let budget = HCInboundBudget()
        XCTAssertTrue(budget.reserve(HCLimits.eventBufferBytes - 100))
        XCTAssertTrue(budget.reserve(100))
        XCTAssertFalse(budget.reserve(1))
        budget.release(100)
        XCTAssertTrue(budget.reserve(100))
        budget.release(HCLimits.eventBufferBytes)
        XCTAssertTrue(budget.reserve(HCLimits.eventBufferBytes))
        budget.release(HCLimits.eventBufferBytes)
    }
}

extension HCTransportTests {
    func testRetiredChannelsCompactWithoutRetiringLiveHoles() {
        var retired = HCChannelRetirements()
        for channel in 2...10_000 { retired.insert(UInt32(channel)) }
        XCTAssertEqual(retired.rangeCount, 1)
        XCTAssertFalse(retired.contains(1)); XCTAssertTrue(retired.contains(5000))
        retired.insert(10_002)
        XCTAssertFalse(retired.contains(10_001)); XCTAssertEqual(retired.rangeCount, 2)
        retired.insert(10_001)
        XCTAssertEqual(retired.rangeCount, 1)
        retired.insert(UInt32.max)
        XCTAssertTrue(retired.contains(UInt32.max)); XCTAssertFalse(retired.contains(UInt32.max - 1))
    }
}

#if DEBUG
extension HCTransportTests {
    func testInventoryTimeoutKeepsExistingConnectionAndReportsPending() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let factory = try HCLiveConnectionFactory(environment: ["C11_HC_FAULTS": "{\"delay_ms\":{\"machine.list\":600}}"])
        let connection = try await factory.connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let inventory = HCLiveInventorySource(connection: connection, refreshTimeout: 0.2)
        let snapshot = await inventory.refresh()
        XCTAssertEqual(snapshot.readiness, .pending(.deadlineExceeded))
        let status = try await connection.request(HCRPCRequest(method: "server.status", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertEqual(status["pid"].integer, Int64(getpid()))
        inventory.invalidate(.cancelled)
    }
}
#endif

#if DEBUG
extension HCTransportTests {
    func testDebugDropEventsKeepsSnapshotAndCreditsRealStream() async throws {
        let peer = try HCWirePeer(.events); defer { peer.close() }
        let factory = try HCLiveConnectionFactory(environment: ["C11_HC_FAULTS": "{\"drop_events_ms\":10000}"])
        let connection = try await factory.connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let inventory = HCLiveInventorySource(connection: connection)
        let snapshot = await inventory.refresh()
        XCTAssertEqual(snapshot.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 10)))
        XCTAssertTrue(snapshot.records.isEmpty)
        for _ in 0..<100 {
            if peer.creditBytes > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(peer.creditBytes, 0)
        inventory.invalidate(.cancelled)
    }

    func testDebugSeverByteBudgetClosesDuringLargeRequest() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let factory = try HCLiveConnectionFactory(environment: ["C11_HC_FAULTS": "{\"sever_after_bytes\":1500}"])
        let connection = try await factory.connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        do {
            _ = try await connection.request(HCRPCRequest(method: "terminal.get",
                params: .object(["padding": .string(String(repeating: "x", count: 2000))]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
            XCTFail("Byte sever did not interrupt request")
        } catch let error as HCRPCFailure { XCTAssertEqual(error.reason, .connectionLost) }
        XCTAssertEqual(peer.callCount("terminal.get"), 0)
    }
}
#endif

private final class HCReportProbe: @unchecked Sendable {
    let started: XCTestExpectation
    let last: XCTestExpectation
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var records: [(String, UInt64, UInt64?)] = []
    init(started: XCTestExpectation, last: XCTestExpectation) { self.started = started; self.last = last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
    func record(_ event: String, _ generation: UInt64, _ elapsed: UInt64?) {
        lock.lock(); records.append((event, generation, elapsed)); lock.unlock()
        XCTAssertEqual(generation, 1)
        if event == "hc_hello_start" {
            XCTAssertEqual(elapsed, 0)
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
        }
        if event == "hc_test_refresh", elapsed == 499 { last.fulfill() }
    }
    func release() { gate.signal() }
}

extension HCTransportTests {
    func testSlowDiagnosticsCannotBlockIOOrAccumulateUnboundedFacts() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let probe = HCReportProbe(started: expectation(description: "recorder blocked"), last: expectation(description: "newest fact delivered"))
        defer { probe.release() }
        let factory = HCLiveConnectionFactory(diagnostics: { probe.record($0, $1, $2) })
        let connection = try await factory.connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        await fulfillment(of: [probe.started], timeout: 1)
        let status = try await connection.request(HCRPCRequest(method: "server.status", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000))
        XCTAssertEqual(status["pid"].integer, Int64(getpid()))
        let reporter = try XCTUnwrap((connection as? HCUnixConnection)?.engine.diagnostics)
        for value in 0..<500 { reporter.emit("hc_test_refresh", generation: 1, elapsedNanoseconds: UInt64(value)) }
        probe.release()
        await fulfillment(of: [probe.last], timeout: 1)
        XCTAssertLessThanOrEqual(probe.count, 65)
    }
}


extension HCTransportTests {
    func testOverlongHelloFailsBeforeVerification() async throws {
        let peer = try HCWirePeer(.overlongHello); defer { peer.close() }
        do {
            _ = try await HCLiveConnectionFactory().connect(request(peer), verify: { _ in
                XCTFail("Overlong hello reached verification")
                throw HCUnavailableReason.pinMismatch
            })
            XCTFail("Overlong hello connected")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .bufferOverflow) }
        XCTAssertEqual(peer.callCount("server.status"), 0)
    }

    func testInboundCreditOverrunClosesConnectionBeforeDelivery() async throws {
        let peer = try HCWirePeer(.creditOverrun); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let reply = try await connection.request(HCRPCRequest(method: "terminal.attach", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertEqual(reply["channel"].integer, 3)
        let received = expectation(description: "overrun never reaches sink"); received.isInverted = true
        let sink = HCBlockedSink(received: received)
        do {
            let channel = try await connection.registerChannel(3, attachmentGeneration: 42, sink: sink)
            channel.close()
            XCTFail("Peer exceeded its initial credit without closing the connection")
        } catch { XCTAssertEqual(error as? HCUnavailableReason, .bufferOverflow) }
        do {
            _ = try await connection.request(HCRPCRequest(method: "server.status", params: .object([:]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000))
            XCTFail("Credit overrun left the connection usable")
        } catch let error as HCRPCFailure { XCTAssertEqual(error.reason, .connectionLost) }
        await fulfillment(of: [received], timeout: 0.1)
        XCTAssertEqual(peer.creditBytes, 0)
    }

    func testInventoryRetriesAfterFirstRefreshDeadlineWithoutCaller() async throws {
        let peer = try HCWirePeer(.slowFirstMachine); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        // The peer answers the first machine.list after 0.4 s, past the 0.25 s refresh.
        let inventory = HCLiveInventorySource(connection: connection, refreshTimeout: 0.25)
        defer { inventory.invalidate(.cancelled) }
        let recovered = expectation(description: "automatic recovery after slow first request")
        recovered.assertForOverFulfill = false
        let observation = inventory.observe(on: .global()) { snapshot in
            if case .ready = snapshot.readiness { recovered.fulfill() }
        }
        defer { observation.cancel() }
        let pending = await inventory.refresh()
        XCTAssertEqual(pending.readiness, .pending(.deadlineExceeded))
        // No second refresh: the source alone must recover its subscription.
        await fulfillment(of: [recovered], timeout: 4)
        let ready = await inventory.snapshot()
        XCTAssertEqual(ready.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 11)))
        XCTAssertEqual(ready.records.values.first?.pid, 99)
        XCTAssertEqual(peer.callCount("machine.list"), 2)
        XCTAssertEqual(peer.callCount("events.subscribe"), 1)
    }

    #if DEBUG
    func testInventoryRetriesAfterFirstSubscribeFailureWithoutCaller() async throws {
        let peer = try HCWirePeer(.events); defer { peer.close() }
        let factory = try HCLiveConnectionFactory(environment: ["C11_HC_FAULTS":
            "{\"fail\":{\"events.subscribe\":{\"kind\":\"internal\",\"count\":1}}}"])
        let connection = try await factory.connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let inventory = HCLiveInventorySource(connection: connection)
        defer { inventory.invalidate(.cancelled) }
        let recovered = expectation(description: "automatic recovery after failed subscribe")
        recovered.assertForOverFulfill = false
        let observation = inventory.observe(on: .global()) { snapshot in
            if case .ready = snapshot.readiness { recovered.fulfill() }
        }
        defer { observation.cancel() }
        let pending = await inventory.refresh()
        XCTAssertEqual(pending.readiness, .pending(.malformedResponse))
        await fulfillment(of: [recovered], timeout: 3)
        let ready = await inventory.snapshot()
        XCTAssertEqual(ready.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 11)))
        XCTAssertEqual(peer.callCount("machine.list"), 2)
        XCTAssertEqual(peer.callCount("events.subscribe"), 1)
    }
    #endif

    private func assertInventoryResubscribes(_ behavior: HCWirePeer.Behavior) async throws {
        let peer = try HCWirePeer(behavior); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let inventory = HCLiveInventorySource(connection: connection)
        defer { inventory.invalidate(.cancelled) }
        let first = await inventory.refresh()
        XCTAssertEqual(first.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 11)))
        let pending = expectation(description: "inconsistent stream revokes readiness")
        let recovered = expectation(description: "second subscription is consistent")
        pending.assertForOverFulfill = false; recovered.assertForOverFulfill = false
        let observation = inventory.observe(on: .global()) { snapshot in
            if case .pending = snapshot.readiness { pending.fulfill() }
            if snapshot.readiness == .ready(HCRevision(connectionGeneration: 1, sequence: 21)) { recovered.fulfill() }
        }
        defer { observation.cancel() }
        _ = try await connection.request(HCRPCRequest(method: "fixture.event", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        await fulfillment(of: [pending], timeout: 1)
        peer.releaseResubscribe()
        await fulfillment(of: [recovered], timeout: 2)
        let ready = await inventory.snapshot()
        XCTAssertEqual(ready.readiness, .ready(HCRevision(connectionGeneration: 1, sequence: 21)))
        XCTAssertEqual(ready.records.values.first?.pid, 99)
        XCTAssertEqual(peer.callCount("events.subscribe"), 2)
    }

    /// C11H-16: a `missed` snapshot can swallow the spool's doc event; the
    /// inventory's signal makes the relay rescan the spool (never the slots).
    func testMissedSnapshotMakesTheRelayRescanTheSpool() async throws {
        let peer = try HCWirePeer(.missedEvents); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let panel = UUID()
        let record = HCTerminalRecord(key: HCTerminalKey(owningCoreID: "atlascore", localAddress: "t3"), state: .running,
                                      labels: ["c11.panel": panel.uuidString.lowercased(),
                                               "c11.creation": relayTestCreation(panel).uuidString.lowercased()],
                                      machineName: "studio", machineAvailability: .connected, pid: 42)
        let revision = HCRevision(connectionGeneration: 1, sequence: 1)
        let host = FakeRelayHost(HCInventorySnapshot(readiness: .ready(revision), revision: revision,
                                                     records: [record.key: record], machines: ["studio": .connected]))
        let executor = RecordingExecutor()
        let service = C11RelayService(retryDelay: { _ in 0.001 }, keyring: relayTestKeyring, workspaceOf: { _ in relayTestWorkspace })
        await service.install(host: host, executor: executor)
        service.machinesChanged(["studio": .connected])
        await service.settle()
        let inventory = HCLiveInventorySource(connection: connection,
                                              docSignals: HCBackendComposition.relaySignalRouter(to: service))
        defer { inventory.invalidate(.cancelled) }
        _ = await inventory.refresh()
        await service.settle()
        // A Studio CLI spools while its doc event is lost in the burst.
        let spooled = relayTestSigned(C11Relay.Request(id: UUID().uuidString,
                                                        at: Int64(Date().timeIntervalSince1970 * 1000),
                                                        panel: panel.uuidString, workspace: nil, term: "t3",
                                                        framing: .text, line: "set_status k v", timeoutMilliseconds: 1000))
        guard case .appended(let value) = C11Relay.appending(.init(relayTestSigned(spooled, mode: .spool)), to: nil) else { return XCTFail() }
        _ = try host.docs.set(C11Relay.spoolName, value: value, version: 0)
        await service.settle()
        XCTAssertEqual(executor.count, 0, "nothing drains without a signal")
        _ = try await connection.request(HCRPCRequest(method: "fixture.event", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        for _ in 0..<200 where executor.count == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
            await service.settle()
        }
        XCTAssertEqual(executor.lines, ["set_status k v"])
        XCTAssertTrue(C11Relay.spoolRecords(host.docs.value(C11Relay.spoolName)).isEmpty)
        XCTAssertEqual(peer.callCount("events.subscribe"), 1, "a missed snapshot is not a resubscribe")
    }

    func testLiveInventoryResubscribesAfterSequenceGap() async throws {
        try await assertInventoryResubscribes(.gapEvents)
    }

    func testLiveInventoryResubscribesAfterMalformedEventLine() async throws {
        try await assertInventoryResubscribes(.malformedEvents)
    }
}

extension HCTransportTests {
    /// Ticket 12 (T12.5): hc's largest put, an 8 MiB file as base64 in one
    /// RPC, fits the real connection's RPC lane and reaches the peer; an
    /// equally large RPC of any other method is still refused before a byte
    /// is sent by the ordinary 4 MiB lane.
    func testLargestFilePutFitsTheRPCLaneWhileOtherRPCsKeepTheirBound() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer, deadlineSeconds: 10), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let file = Data(repeating: 0x5a, count: HCRemoteFileDrop.maximumBytes).base64EncodedString()
        func send(_ method: String) async throws -> HCJSONValue {
            try await connection.request(HCRPCRequest(method: method,
                params: .object(["terminal": .string("studio/t3"), "name": .string("shot.png"), "data": .string(file)]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000))
        }
        _ = try await send("terminal.put")
        XCTAssertEqual(peer.callCount("terminal.put"), 1, "An 8 MiB put must reach hc")
        do {
            _ = try await send("terminal.get")
            XCTFail("Control: a non-file RPC this large keeps the 4 MiB lane")
        } catch let reason as HCUnavailableReason {
            XCTAssertEqual(reason, .bufferOverflow)
        } catch let failure as HCRPCFailure {
            XCTAssertEqual(failure.reason, .bufferOverflow)
        }
        XCTAssertEqual(peer.callCount("terminal.get"), 0)
    }
}

extension HCTransportTests {
    /// Ticket 12 (T12.5 with T12.7): while hc is still answering an 8 MiB
    /// put, the small `machine.list` that gates every key into a remote
    /// terminal is still admitted and answered, so typing into a live Studio
    /// panel during a large file drop is not refused as "reconnecting".
    func testSmallRPCsStillGoThroughWhileALargePutIsInFlight() async throws {
        let peer = try HCWirePeer(.heldPut); defer { peer.close() }
        let connection = try await HCLiveConnectionFactory().connect(request(peer, deadlineSeconds: 10), verify: fixtureVerification)
        defer { connection.close(reason: .cancelled) }
        let file = Data(repeating: 0x5a, count: HCRemoteFileDrop.maximumBytes).base64EncodedString()
        let put = Task {
            try await connection.request(HCRPCRequest(method: "terminal.put",
                params: .object(["terminal": .string("studio/t3"), "name": .string("shot.png"), "data": .string(file)]),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000))
        }
        for _ in 0..<500 where peer.callCount("terminal.put") == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(peer.callCount("terminal.put"), 1, "The put must be in flight at hc")
        let list = try await connection.request(HCRPCRequest(method: "machine.list", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertNotNil(list["machines"].array, "A key's line check must not wait for, or be refused by, a put")
        peer.releasePut()
        let landed = try await put.value
        XCTAssertEqual(landed["path"].string, "/remote/put/1/shot.png")
    }

    /// The writer's RPC lane: a queued put never takes the ordinary lane's
    /// room; a non-file RPC that large is still refused.
    func testWriterKeepsFileTransfersInTheirOwnLane() {
        let writer = HCControlWriter(generation: 1, wake: {}, invalidate: { _ in })
        let put = Data(repeating: 1, count: 11 * 1024 * 1024)
        XCTAssertTrue(writer.enqueueRPC(put, fileTransfer: true) { _, _ in })
        XCTAssertTrue(writer.enqueueRPC(Data(repeating: 2, count: 3 * 1024 * 1024)) { _, _ in },
                      "Small RPCs keep their whole lane while a put is queued")
        XCTAssertFalse(writer.enqueueRPC(Data(repeating: 3, count: HCLimits.queuedInputBytes + 1)) { _, _ in },
                       "Control: the ordinary lane keeps its 4 MiB bound")
    }
}

// C11H-306: a composer read is a watch-only attach on the connection every terminal shares. Whatever happens to
// the read (a paint too large, not a paint, an attach that never answers, a cancel, a terminal that ends), it ends
// that read's own channel and nothing else: the connection keeps answering and the next read works.
extension HCTransportTests {
    private static let goodPaint = HCPaint.prelude + Data("❯ \u{1B}[21;3H\u{1B}[?9001l\u{1B}]7501;state=idle\u{1B}\\".utf8)

    private func connectForReads(_ peer: HCWirePeer) async throws -> any HCConnection {
        try await HCLiveConnectionFactory().connect(request(peer), verify: fixtureVerification)
    }

    /// The shared connection still answers, and a fresh read still works.
    private func assertConnectionLives(_ connection: any HCConnection, _ peer: HCWirePeer,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let status = try await connection.request(HCRPCRequest(method: "server.status", params: .object([:]),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertEqual(status["pid"].integer, Int64(getpid()), file: file, line: line)
        peer.configureAttach(paint: Self.goodPaint)
        let again = await HCComposerPaintRead.read(connection: connection, address: "t1",
                                                   grid: HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(try? again.get().bytes, Self.goodPaint, "the next read works", file: file, line: line)
    }

    private func waitForClose(_ peer: HCWirePeer, count: Int) async throws {
        for _ in 0..<200 where peer.closedByClient.count < count { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Until the peer has read `count` attaches (bounded, 2 s).
    private func waitForAttach(_ peer: HCWirePeer, count: Int) async throws {
        for _ in 0..<400 where peer.attachRequests.count < count { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testAComposerReadAttachesAsAnObserverWithNoHistoryAndClosesItsChannel() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        peer.configureAttach(paint: Self.goodPaint)
        let read = await HCComposerPaintRead.read(connection: connection, address: "t7",
                                                  grid: HCGridSize(columns: 100, rows: 30))
        let paint = try read.get()
        XCTAssertEqual(paint.bytes, Self.goodPaint)
        XCTAssertEqual(paint.grid, HCGridSize(columns: 80, rows: 24), "the attach reply's size wins")
        let params = try XCTUnwrap(peer.attachRequests.first)
        XCTAssertEqual(params["observe"], .bool(true), "watch only: hc never resizes for it or takes its input")
        XCTAssertEqual(params["history"].integer, 0)
        XCTAssertEqual(params["terminal"].string, "t7")
        try await waitForClose(peer, count: 1)
        XCTAssertEqual(peer.closedByClient, [11], "the read closes its own channel")
        try await assertConnectionLives(connection, peer)
    }

    func testAnOversizePaintEndsOnlyItsOwnRead() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        let saved = HCComposerPaintRead.byteLimit
        HCComposerPaintRead.byteLimit = 16
        peer.configureAttach(paint: Data(repeating: 0x41, count: 4096))
        let read = await HCComposerPaintRead.read(connection: connection, address: "t1", grid: HCGridSize(columns: 80, rows: 24))
        HCComposerPaintRead.byteLimit = saved
        XCTAssertEqual(read.failure, .oversize)
        try await assertConnectionLives(connection, peer)
    }

    /// Repair 1: completion is hc's end of the screen, never a quiet time. A paint whose second half comes 100 ms
    /// later is read whole; one whose end never comes holds, and ends only its own read.
    func testAPaintSplitAcrossFramesIsReadWholeAndOneWithoutItsEndHolds() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        // Past hc's prelude, before its end of the screen: what arrives first reads like a whole screen.
        let split = HCPaint.prelude.count + 4
        peer.configureAttach(paint: Self.goodPaint.prefix(split), rest: Self.goodPaint.suffix(from: split), restAfter: 0.1)
        let whole = await HCComposerPaintRead.read(connection: connection, address: "t1", grid: HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(try whole.get().bytes, Self.goodPaint, "reassembled across the pause")
        let saved = HCComposerPaintRead.capNanoseconds
        HCComposerPaintRead.capNanoseconds = 200_000_000
        defer { HCComposerPaintRead.capNanoseconds = saved }
        peer.configureAttach(paint: Self.goodPaint.prefix(split))
        let cut = await HCComposerPaintRead.read(connection: connection, address: "t1", grid: HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(cut.failure, .unterminated)
        try await assertConnectionLives(connection, peer)
    }

    func testWhatIsNotAPaintEndsOnlyItsOwnRead() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        peer.configureAttach(paint: Data("not a paint".utf8))
        let read = await HCComposerPaintRead.read(connection: connection, address: "t1", grid: HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(read.failure, .noPaint)
        try await assertConnectionLives(connection, peer)
    }

    func testAnAttachThatNeverAnswersEndsOnlyItsOwnRead() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        let saved = HCComposerPaintRead.attachSeconds
        HCComposerPaintRead.attachSeconds = 0.2
        defer { HCComposerPaintRead.attachSeconds = saved }
        peer.configureAttach(paint: nil, silent: true)
        let started = Date()
        let read = await HCComposerPaintRead.read(connection: connection, address: "t1", grid: HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(read.failure, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the reply's bound, from transmission, not the queue's")
        try await assertConnectionLives(connection, peer)
    }

    /// C11H-327: an attach that is not answered in time stays counted by the engine until hc's late reply, and the
    /// read's mark says so; the late reply takes it out (the engine closes the channel it names), and the mark says
    /// that too. A read the caller cancels is counted the same way.
    func testAnUnansweredAttachIsMarkedUntilItsLateReplyComes() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        let saved = HCComposerPaintRead.attachSeconds
        HCComposerPaintRead.attachSeconds = 0.2
        defer { HCComposerPaintRead.attachSeconds = saved }
        peer.configureAttach(paint: nil, silent: true)
        let mark = HCLateReply()
        let read = await HCComposerPaintRead.read(connection: connection, address: "t1",
                                                  grid: HCGridSize(columns: 80, rows: 24), lateReply: mark)
        XCTAssertEqual(read.failure, .timedOut)
        XCTAssertTrue(mark.outstanding, "the engine still counts the attach")
        peer.releaseHeldAttach()
        try await waitForClose(peer, count: 1)
        XCTAssertEqual(peer.closedByClient.count, 1, "the engine closed the channel the late reply named")
        XCTAssertFalse(mark.outstanding, "and the mark says the attach is answered")

        // The cancelled half: a bound no scheduling delay reaches, and the cancel only once hc has the attach.
        HCComposerPaintRead.attachSeconds = 30
        let cancelledMark = HCLateReply()
        let task = Task { await HCComposerPaintRead.read(connection: connection, address: "t1",
                                                         grid: HCGridSize(columns: 80, rows: 24), lateReply: cancelledMark) }
        try await waitForAttach(peer, count: 2)
        XCTAssertEqual(peer.attachRequests.count, 2, "the peer has the second attach")
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.failure, .cancelled)
        XCTAssertTrue(cancelledMark.outstanding, "a cancelled read's attach is still counted")
        peer.releaseHeldAttach()
        try await waitForClose(peer, count: 2)
        XCTAssertFalse(cancelledMark.outstanding)
        try await assertConnectionLives(connection, peer)
    }

    /// C11H-327 repair 1: a composer read through the real session over the real engine. The engine is held just
    /// after it wakes the timed-out read, so whatever the session does next happens before anything else the
    /// engine does: the attach must already be marked (marked before its caller resumes). A minute on, the session
    /// still sends no second attach; hc's late reply ends the hold.
    func testASessionOverTheRealEngineHoldsAnUnansweredAttachUntilItsLateReply() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hc327-\(UUID().uuidString.prefix(6))")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = HCTerminalKey(owningCoreID: "fixture", localAddress: "t1")
        let inventory = HCOneTerminalInventory(key: key)
        let session = HCManagedSession(configuration: request(peer).configuration, connections: HCLiveConnectionFactory(),
            verifier: HCFixtureVerifier(), launcher: HCNoCoreLaunch(), intents: HCCreationIntentStore(directory: directory),
            prepareAttachment: { _, _, _, display in display },
            makeInventory: { connection, _ in await inventory.bind(connection.generation); return inventory })
        _ = await session.resolve(HCPanelIdentity(panelID: UUID(), origin: .fresh))
        let saved = HCComposerPaintRead.attachSeconds
        HCComposerPaintRead.attachSeconds = 0.2
        defer { HCComposerPaintRead.attachSeconds = saved }
        peer.configureAttach(paint: nil, silent: true)
        let held = DispatchSemaphore(value: 0), first = HCFirstCall()
        HCUnixEngine.afterExpiryForTesting = { method in
            guard method == "terminal.attach", first.take() else { return }
            _ = held.wait(timeout: .now() + 5)
        }
        defer { HCUnixEngine.afterExpiryForTesting = nil; held.signal() }

        guard case .failure(.timedOut) = await session.readComposerPaint(key) else { return XCTFail("the attach timed out") }
        let pastAMinute: Result<HCComposerPaint, HCComposerReadFailure>
        do {
            HCMonotonic.advancedForTesting = 61_000_000_000
            defer { HCMonotonic.advancedForTesting = 0 }
            pastAMinute = await session.readComposerPaint(key)
        }
        held.signal()
        XCTAssertEqual(pastAMinute.failure, .attachUnanswered, "a minute on, the first attach is still unanswered")
        XCTAssertEqual(peer.attachRequests.count, 1, "no second attach on the wire")

        peer.releaseHeldAttach()
        try await waitForClose(peer, count: 1)      // the engine took the late reply and closed its channel
        XCTAssertEqual(peer.closedByClient.count, 1)
        guard case .failure(.timedOut) = await session.readComposerPaint(key) else {
            return XCTFail("after the late reply the read attaches again")
        }
        XCTAssertEqual(peer.attachRequests.count, 2)
    }

    /// Repair 1b, the fleet burst: another panel's write holds its Return for a 1.5 s paste settle, and every RPC on
    /// the shared connection waits behind it. A read queued there is delayed, not failed: its 1 s reply bound starts
    /// when it reaches the socket.
    func testAReadQueuedBehindADelayedReturnIsDelayedNotFailed() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        peer.configureAttach(paint: Self.goodPaint)
        let reply = try await connection.request(HCRPCRequest(method: "terminal.attach", params: .object([:]),
            deadlineUptimeNanoseconds: HCMonotonic.deadline(after: 2)))
        let channelID = try XCTUnwrap(reply["channel"].integer.flatMap(UInt32.init(exactly:)))
        let channel = try await connection.registerChannel(channelID, attachmentGeneration: 7,
                                                           sink: HCComposerPaintSink(limit: 1 << 20))
        try await channel.activate()
        guard case .reserved(let reservation) = channel.reserve(operationID: UUID(), attachmentGeneration: 7,
                                                                encodedByteCount: 64) else { return XCTFail("no reservation") }
        let held = Task {
            await channel.write(HCWriteBatch(operationID: reservation.operationID, attachmentGeneration: 7,
                frames: [.data(Data("x".utf8)), .submitReturnAfter(Data([13]), delayNanoseconds: 1_500_000_000)]),
                reservation: reservation)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let saved = HCComposerPaintRead.attachSeconds
        HCComposerPaintRead.attachSeconds = 1
        defer { HCComposerPaintRead.attachSeconds = saved }
        let started = Date()
        let read = await HCComposerPaintRead.read(connection: connection, address: "t1", grid: HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(try read.get().bytes, Self.goodPaint, "delayed behind the Return, then read")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.2, "it did wait behind the Return")
        _ = await held.value
        try await assertConnectionLives(connection, peer)
    }

    func testACancelledReadEndsOnlyItself() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        peer.configureAttach(paint: nil, silent: true)
        let task = Task { await HCComposerPaintRead.read(connection: connection, address: "t1",
                                                         grid: HCGridSize(columns: 80, rows: 24)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let read = await task.value
        XCTAssertEqual(read.failure, .cancelled)
        try await assertConnectionLives(connection, peer)
    }

    func testATerminalThatEndsDuringTheReadEndsOnlyItsRead() async throws {
        let peer = try HCWirePeer(.normal); defer { peer.close() }
        let connection = try await connectForReads(peer)
        defer { connection.close(reason: .cancelled) }
        peer.configureAttach(paint: nil, ends: true)
        let read = await HCComposerPaintRead.read(connection: connection, address: "t1", grid: HCGridSize(columns: 80, rows: 24))
        XCTAssertEqual(read.failure, .ended)
        try await assertConnectionLives(connection, peer)
    }
}

private extension Result where Failure == HCComposerReadFailure {
    var failure: HCComposerReadFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
