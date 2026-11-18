import Foundation
import Darwin

/// Required verifier is supplied by 2A; there is no permissive production
/// default. The same absolute deadline covers it and the handshake.
struct HCLiveConnectionFactory: HCConnectionFactory {
    private let report: HCTransportReport
    #if DEBUG
    private var faults = HCDebugWireFaults()
    init(faults: HCDebugWireFaults = HCDebugWireFaults(), diagnostics: @escaping HCTransportReport = { _, _, _ in }) {
        self.faults = faults; report = diagnostics
    }
    init(environment: [String: String], diagnostics: @escaping HCTransportReport = { _, _, _ in }) throws {
        faults = try HCDebugWireFaults.environment(environment); report = diagnostics
    }
    #else
    init(diagnostics: @escaping HCTransportReport = { _, _, _ in }) { report = diagnostics }
    #endif

    func connect(_ request: HCConnectionRequest, verify: @escaping HCServingBuildVerifier) async throws -> any HCConnection {
        let diagnostics = HCTransportReporter(report)
        let started = DispatchTime.now().uptimeNanoseconds
        diagnostics.emit("hc_hello_start", generation: request.generation, elapsedNanoseconds: 0)
        let engine = HCUnixEngine(request: request, diagnostics: diagnostics)
        #if DEBUG
        engine.debugFaults = faults
        #endif
        do {
            let connection = try await HCDeadline.perform(until: request.deadlineUptimeNanoseconds, onTimeout: {
                engine.close(reason: .deadlineExceeded)
            }) {
                let peer = try await engine.open()
                let verification = try await verify(peer)
                guard DispatchTime.now().uptimeNanoseconds < request.deadlineUptimeNanoseconds else {
                    throw HCUnavailableReason.deadlineExceeded
                }
                return HCUnixConnection(engine: engine, peer: peer, verification: verification)
            }
            diagnostics.emit("hc_hello_complete", generation: request.generation,
                             elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started)
            return connection
        } catch {
            let reason = HCUnavailableReason.transportReason(error)
            diagnostics.emit(reason == .deadlineExceeded ? "hc_hello_deadline" : "hc_hello_failed", generation: request.generation,
                             elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - started)
            engine.close(reason: reason); throw error
        }
    }
}

#if DEBUG
/// Faults operate on bytes from the real owned socket. No proxy peer replaces
/// the core, no launch tuple changes, and Verify remains mandatory. The guest
/// helper selects this factory at composition; Release has no injection API.
struct HCDebugWireFaults: Sendable {
    static let environmentKey = "C11_HC_FAULTS"
    var helloByteDelayNanoseconds: UInt64 = 0
    var dropEventsForNanoseconds: UInt64 = 0
    var delayReplyNanoseconds: [String: UInt64] = [:]
    var failMethods: [String: (kind: String, count: Int)] = [:]
    var dropReplies: [String: Int] = [:]
    var severAfterBytes: Int?
    var severAfterNanoseconds: UInt64?
    var throttleBytesPerSecond: Int?

    static func environment(_ environment: [String: String]) throws -> Self {
        guard let text = environment[environmentKey], !text.isEmpty else { return Self() }
        guard text.utf8.count <= HCLimits.helloBytes, let data = text.data(using: .utf8),
              let fields = try HCJSONValue.decode(data).object else { throw HCUnavailableReason.invalidLaunchTuple }
        let allowed: Set<String> = ["hello_trickle_ms", "drop_events_ms", "delay_ms", "fail", "drop_reply", "sever_after_bytes", "sever_after_ms", "throttle_bps"]
        guard Set(fields.keys).isSubset(of: allowed) else { throw HCUnavailableReason.invalidLaunchTuple }
        func integer(_ value: HCJSONValue, maximum: Int64 = 1_000_000_000) throws -> Int {
            guard let count = value.integer, count >= 0, count <= maximum else { throw HCUnavailableReason.invalidLaunchTuple }
            return Int(count)
        }
        func nanos(_ value: HCJSONValue) throws -> UInt64 { UInt64(try integer(value, maximum: 600_000)) * 1_000_000 }
        var result = Self()
        for (key, value) in fields {
            switch key {
            case "hello_trickle_ms": result.helloByteDelayNanoseconds = try nanos(value)
            case "drop_events_ms": result.dropEventsForNanoseconds = try nanos(value)
            case "sever_after_ms": result.severAfterNanoseconds = try nanos(value)
            case "sever_after_bytes": result.severAfterBytes = try integer(value)
            case "throttle_bps":
                let n = try integer(value); guard n > 0 else { throw HCUnavailableReason.invalidLaunchTuple }
                result.throttleBytesPerSecond = n
            case "delay_ms", "fail", "drop_reply":
                guard let methods = value.object, methods.count <= HCLimits.pendingRPCs else { throw HCUnavailableReason.invalidLaunchTuple }
                for (method, setting) in methods {
                    guard !method.isEmpty, method.utf8.count <= 128 else { throw HCUnavailableReason.invalidLaunchTuple }
                    if key == "delay_ms" { result.delayReplyNanoseconds[method] = try nanos(setting) }
                    else if key == "drop_reply" { result.dropReplies[method] = try integer(setting) }
                    else {
                        guard let object = setting.object, Set(object.keys).isSubset(of: ["kind", "count"]),
                              let kind = setting["kind"].string, !kind.isEmpty, kind.utf8.count <= 128 else {
                            throw HCUnavailableReason.invalidLaunchTuple
                        }
                        result.failMethods[method] = (kind, try integer(setting["count"] == .null ? .integer(1) : setting["count"]))
                    }
                }
            default: throw HCUnavailableReason.invalidLaunchTuple
            }
        }
        return result
    }
}
#endif

/// Unlike a task-group race, the deadline does not wait for an uncooperative
/// verifier to finish. Its late result is ignored, and cannot expose a socket.
enum HCDeadline {
    private final class Gate<T: Sendable>: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<T, Error>?
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        @discardableResult
        func finish(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            let continuation = self.continuation; self.continuation = nil
            let worker = self.worker; let timer = self.timer
            self.worker = nil; self.timer = nil
            lock.unlock()
            guard let continuation else { return false }
            worker?.cancel(); timer?.cancel(); continuation.resume(with: result)
            return true
        }
        func install(worker: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            if continuation == nil { lock.unlock(); worker.cancel(); timer.cancel() }
            else { self.worker = worker; self.timer = timer; lock.unlock() }
        }
    }
    static func perform<T: Sendable>(until deadline: UInt64, onTimeout: @escaping @Sendable () -> Void,
                                    operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.lock.lock(); gate.continuation = continuation; gate.lock.unlock()
                let worker = Task {
                    do { gate.finish(.success(try await operation())) }
                    catch { gate.finish(.failure(error)) }
                }
                let timer = Task {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if deadline > now {
                        do { try await Task.sleep(nanoseconds: deadline - now) } catch { return }
                    }
                    if gate.finish(.failure(HCUnavailableReason.deadlineExceeded)) { onTimeout() }
                }
                gate.install(worker: worker, timer: timer)
                if Task.isCancelled, gate.finish(.failure(HCUnavailableReason.cancelled)) { onTimeout() }
            }
        } onCancel: { if gate.finish(.failure(HCUnavailableReason.cancelled)) { onTimeout() } }
    }
}

final class HCUnixConnection: HCConnection, @unchecked Sendable {
    let peer: HCPeerEvidence
    let verification: HCVerifiedPeer
    let engine: HCUnixEngine
    var generation: UInt64 { engine.configuration.generation }
    init(engine: HCUnixEngine, peer: HCPeerEvidence, verification: HCVerifiedPeer) {
        self.engine = engine; self.peer = peer; self.verification = verification
    }
    func request(_ request: HCRPCRequest) async throws -> HCJSONValue {
        guard verification.isPinnedBuild || ["server.status", "server.restart"].contains(request.method) else {
            throw HCRPCFailure(reason: .foreignBuild, transmission: .none, remoteCode: nil)
        }
        return try await engine.rpc(request)
    }
    func registerChannel(_ channel: UInt32, attachmentGeneration: UInt64, sink: any HCOutputSink) async throws -> any HCChannel {
        guard verification.isPinnedBuild else { throw HCUnavailableReason.foreignBuild }
        return try await engine.register(channel, attachmentGeneration: attachmentGeneration, sink: sink)
    }
    func close(reason: HCUnavailableReason) { engine.close(reason: reason) }
    deinit { engine.close(reason: .cancelled) }
}

final class HCUnixChannel: HCChannel, @unchecked Sendable {
    let channelID: UInt32
    let connectionGeneration: UInt64
    private let engine: HCUnixEngine
    private let attachmentGeneration: UInt64
    init(channel: UInt32, generation: UInt64, engine: HCUnixEngine) {
        channelID = channel; self.attachmentGeneration = generation; self.engine = engine; connectionGeneration = engine.configuration.generation
    }
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        guard attachmentGeneration == self.attachmentGeneration else { return .refused(.staleIdentity) }
        return engine.writer.reserve(operationID: operationID, attachmentGeneration: attachmentGeneration, encodedByteCount: encodedByteCount, channel: channelID)
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        await engine.writer.write(channel: channelID, batch: batch, reservation: reservation)
    }
    func cancel(_ reservation: HCWriteReservation) { engine.writer.cancel(reservation) }
    func control(_ control: HCControl) async -> HCControlOutcome {
        if case .close = control { engine.closeChannel(channelID); return .coalesced }
        return await engine.writer.control(channel: channelID, value: control)
    }
    func activate() async throws { try await engine.activate(channelID) }
    func close() { engine.closeChannel(channelID) }
}

/// One serial queue owns fd, parser and RPC routing. Each channel has one
/// outstanding sink task; queued payload remains charged to peer stream credit.
final class HCUnixEngine: @unchecked Sendable {
    let configuration: HCConnectionRequest
    let inboundBudget = HCInboundBudget()
    let diagnostics: HCTransportReporter
    private let queue = DispatchQueue(label: "c11.hc.connection", qos: .userInitiated)
    private var fd: Int32 = -1
    private var fdLease: HCFDLease?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeResumed = false
    private var connected = false
    private var closed = false
    private var hello = Data()
    private var helloResult: HCJSONValue?
    private var decoder = HCWireDecoder()
    private var openContinuation: CheckedContinuation<HCPeerEvidence, Error>?
    private var nextID: Int64 = 1
    private struct Pending {
        let continuation: CheckedContinuation<HCJSONValue, Error>
        let method: String
        var timer: DispatchWorkItem
        var transmitted = false
        let token: HCRPCCancellation
        var lateReply: HCLateReply? = nil
    }
    private var pending: [Int64: Pending] = [:]
    private var expiredChannelCalls: Set<Int64> = []
    /// C11H-327: the callers' marks for expired channel calls that asked for one, told when the late reply comes.
    private var expiredLateReplies: [Int64: HCLateReply] = [:]
    #if DEBUG
    /// C11H-327 test seam: runs on the engine queue just after an expired call's caller is resumed, with its method.
    nonisolated(unsafe) static var afterExpiryForTesting: ((String) -> Void)?
    #endif
    private let rpcAdmission = HCRPCAdmission()
    private var awaitingChannels: Set<UInt32> = []
    private var early: [UInt32: [HCWireFrame]] = [:]
    private var earlyBytes = 0
    private var channels: [UInt32: Stream] = [:]
    private var eventChannels: Set<UInt32> = []
    #if DEBUG
    var debugFaults = HCDebugWireFaults()
    private var debugHelloBytes = Data()
    private var debugHelloScheduled = false
    private var debugDropUntil: UInt64?
    private var debugBytes = 0
    private var debugDelayedBytes = 0
    private var debugDelayedIDs: Set<Int64> = []
    private var debugReportedFaults: Set<String> = []
    private var debugNextWrite: UInt64 = 0
    private var debugThrottleScheduled = false
    #endif
    private var closedChannels = HCChannelRetirements()
    // Mutable state stays on queue; tasks only read the immutable Sendable sink.
    private final class Stream: @unchecked Sendable {
        let sink: any HCOutputSink
        let generation: UInt64
        var chunks: [Data] = []
        var buffered = 0
        var remainingCredit = HCLimits.initialCreditBytes
        var busy = false
        var ending = false
        var watermark: UInt64 = 0
        var consumed: UInt64 = 0
        var active = false
        var activationTarget: UInt64 = 0
        var activation: CheckedContinuation<Void, Error>?
        var eventBytes = 0
        init(sink: any HCOutputSink, generation: UInt64) { self.sink = sink; self.generation = generation }
    }
    private let wakeLock = NSLock()
    private var wakePending = false
    lazy var writer: HCControlWriter = HCControlWriter(generation: configuration.generation, wake: { [weak self] in
        self?.wakeWriter()
    }, invalidate: { [weak self] reason in self?.close(reason: reason) })

    init(request: HCConnectionRequest, diagnostics: HCTransportReporter) {
        configuration = request; self.diagnostics = diagnostics
    }
    #if DEBUG
    private func debugFault(_ token: String) {
        guard debugReportedFaults.insert(token).inserted else { return }
        diagnostics.emit("hc_wire_fault_" + token, generation: configuration.generation)
    }
    #endif

    func open() async throws -> HCPeerEvidence {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.closed else { continuation.resume(throwing: HCUnavailableReason.connectionLost); return }
                self.openContinuation = continuation
                do { try self.startSocket() } catch { self.fail((error as? HCUnavailableReason) ?? .coreUnreachable) }
            }
        }
    }

    private func startSocket() throws {
        let path = configuration.configuration.socketURL.path
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw HCUnavailableReason.invalidLaunchTuple
        }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HCUnavailableReason.coreUnreachable }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw HCUnavailableReason.coreUnreachable
        }
        var noSIGPIPE: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw HCUnavailableReason.coreUnreachable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: Array(path.utf8) + [0])
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 || errno == EINPROGRESS else { throw HCUnavailableReason.coreUnreachable }
        let lease = HCFDLease(fd: fd); fdLease = lease
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource?.setCancelHandler { lease.retire() }
        writeSource?.setCancelHandler { lease.retire() }
        readSource?.setEventHandler { [weak self] in autoreleasepool { self?.readReady() } }
        writeSource?.setEventHandler { [weak self] in autoreleasepool { self?.writeReady() } }
        readSource?.resume(); writeSource?.resume(); writeResumed = true
        if result == 0 { try didConnect() }
    }

    private func didConnect() throws {
        guard !connected else { return }
        var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
            throw HCUnavailableReason.coreUnreachable
        }
        connected = true
        #if DEBUG
        if let delay = debugFaults.severAfterNanoseconds {
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                guard !self.closed else { return }
                self.debugFault("sever_timer"); self.fail(.connectionLost)
            }
        }
        #endif
        var bytes = try HCJSONValue.object(["jsonrpc": .string("2.0"), "id": .integer(0), "method": .string("hello"),
            "params": .object(["generation": .integer(Int64(configuration.configuration.pin.protocolGeneration)), "framed": .bool(true)])]).encoded()
        bytes.append(10)
        guard writer.enqueueRPC(bytes, completion: { [weak self] _, success in if !success { self?.close(reason: .connectionLost) } }) else {
            throw HCUnavailableReason.bufferOverflow
        }
    }

    private func writeReady() {
        guard !closed else { return }
        do { if !connected { try didConnect() } } catch { fail(.coreUnreachable); return }
        #if DEBUG
        if let rate = debugFaults.throttleBytesPerSecond, DispatchTime.now().uptimeNanoseconds < debugNextWrite {
            if writeResumed { writeSource?.suspend(); writeResumed = false }
            scheduleDebugWrite(rate: rate)
            return
        }
        #endif
        writer.drain { bytes, offset in
            var limit = bytes.count - offset
            #if DEBUG
            if let cut = debugFaults.severAfterBytes {
                limit = min(limit, max(0, cut - debugBytes))
                if limit == 0 { debugFault("sever_bytes"); throw HCUnavailableReason.connectionLost }
            }
            if let rate = debugFaults.throttleBytesPerSecond {
                if DispatchTime.now().uptimeNanoseconds < debugNextWrite { return 0 }
                limit = min(limit, max(1, rate / 20))
            }
            #endif
            let count = bytes.withUnsafeBytes { raw in Darwin.send(fd, raw.baseAddress!.advanced(by: offset), limit, 0) }
            #if DEBUG
            if count > 0 {
                debugBytes += count
                if let rate = debugFaults.throttleBytesPerSecond {
                    debugFault("throttle")
                    debugNextWrite = DispatchTime.now().uptimeNanoseconds + max(1, UInt64(count) * 1_000_000_000 / UInt64(rate))
                }
                if let cut = debugFaults.severAfterBytes, debugBytes >= cut { debugFault("sever_bytes"); close(reason: .connectionLost) }
            }
            #endif
            if count >= 0 { return count }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return 0 }
            throw HCUnavailableReason.connectionLost
        }
        #if DEBUG
        if let rate = debugFaults.throttleBytesPerSecond, DispatchTime.now().uptimeNanoseconds < debugNextWrite {
            if writeResumed { writeSource?.suspend(); writeResumed = false }
            scheduleDebugWrite(rate: rate)
        }
        #endif
        if !writer.hasPending, writeResumed { writeSource?.suspend(); writeResumed = false }
    }

    #if DEBUG
    private func scheduleDebugWrite(rate: Int) {
        guard !debugThrottleScheduled, !closed else { return }
        debugThrottleScheduled = true
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: debugNextWrite)) {
            self.debugThrottleScheduled = false
            if !self.closed { self.wakeWriter() }
        }
    }
    #endif

    private func wakeWriter() {
        wakeLock.lock()
        guard !wakePending else { wakeLock.unlock(); return }
        wakePending = true; wakeLock.unlock()
        queue.async {
            self.wakeLock.lock(); self.wakePending = false; self.wakeLock.unlock()
            guard !self.closed else { return }
            if !self.writeResumed { self.writeSource?.resume(); self.writeResumed = true }
            self.writeReady()
        }
    }

    private func readReady() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: HCLimits.outputChunkBytes)
        for _ in 0..<32 {
            var readLimit = buffer.count
            #if DEBUG
            if let cut = debugFaults.severAfterBytes {
                readLimit = min(readLimit, max(0, cut - debugBytes))
                if readLimit == 0 { debugFault("sever_bytes"); fail(.connectionLost); return }
            }
            #endif
            let count = Darwin.recv(fd, &buffer, readLimit, 0)
            if count == 0 { fail(.connectionLost); return }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                fail(.connectionLost); return
            }
            #if DEBUG
            debugBytes += count
            #endif
            do { try receive(Data(buffer.prefix(count))) }
            catch { fail((error as? HCUnavailableReason) ?? .malformedResponse); return }
            #if DEBUG
            if let cut = debugFaults.severAfterBytes, debugBytes >= cut { debugFault("sever_bytes"); fail(.connectionLost); return }
            #endif
        }
    }

    private func receive(_ bytes: Data) throws {
        #if DEBUG
        if helloResult == nil, debugFaults.helloByteDelayNanoseconds > 0 {
            guard debugHelloBytes.count + bytes.count <= HCLimits.helloBytes else { throw HCUnavailableReason.bufferOverflow }
            debugFault("hello_trickle")
            debugHelloBytes.append(bytes)
            scheduleDebugHello()
            return
        }
        #endif
        try receiveActual(bytes)
    }

    #if DEBUG
    private func scheduleDebugHello() {
        guard !debugHelloScheduled, !debugHelloBytes.isEmpty, !closed else { return }
        debugHelloScheduled = true
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(self.debugFaults.helloByteDelayNanoseconds, UInt64(Int.max))))) {
            self.debugHelloScheduled = false
            guard !self.closed, !self.debugHelloBytes.isEmpty else { return }
            let byte = self.debugHelloBytes.removeFirst()
            do {
                try self.receiveActual(Data([byte]))
                if self.helloResult != nil {
                    let rest = self.debugHelloBytes; self.debugHelloBytes = Data()
                    if !rest.isEmpty { try self.receiveActual(rest) }
                } else { self.scheduleDebugHello() }
            } catch { self.fail((error as? HCUnavailableReason) ?? .malformedResponse) }
        }
    }
    #endif

    private func receiveActual(_ bytes: Data) throws {
        if helloResult == nil {
            let newline = bytes.firstIndex(of: 10)
            let prefix = newline.map { Data(bytes[..<$0]) } ?? bytes
            guard hello.count + prefix.count <= HCLimits.helloBytes else { throw HCUnavailableReason.bufferOverflow }
            hello.append(prefix)
            guard let newline else { return }
            let envelope = try HCJSONValue.decode(hello)
            let result = try rpcResult(envelope)
            guard envelope["id"].integer == 0, result["framed"].bool == true,
                  result["generation"].integer == Int64(configuration.configuration.pin.protocolGeneration) else {
                throw HCUnavailableReason.incompatibleProtocol
            }
            hello = Data(); helloResult = result
            // Status runs on this same connection under the original deadline.
            Task {
                do {
                    let status = try await self.rpc(HCRPCRequest(method: "server.status", params: .object([:]),
                                                    deadlineUptimeNanoseconds: self.configuration.deadlineUptimeNanoseconds))
                    self.queue.async {
                        do { try self.completeHello(status) } catch { self.fail((error as? HCUnavailableReason) ?? .malformedResponse) }
                    }
                } catch { self.close(reason: HCUnavailableReason.transportReason(error)) }
            }
            let remainder = Data(bytes[(newline + 1)...])
            if !remainder.isEmpty { try decode(remainder) }
        } else { try decode(bytes) }
    }

    private func completeHello(_ status: HCJSONValue) throws {
        guard !closed, let hello = helloResult, let coreID = hello["core"]["id"].string,
              !coreID.isEmpty, status["core"]["id"].string == coreID,
              let version = hello["version"].string, status["version"].string == version,
              let pid = status["pid"].integer.flatMap(Int32.init(exactly:)),
              let methodValues = hello["methods"].array, let featureValues = hello["features"].array,
              methodValues.allSatisfy({ $0.string != nil }), featureValues.allSatisfy({ $0.string != nil }) else {
            throw HCUnavailableReason.malformedResponse
        }
        var uid: uid_t = 0; var gid: gid_t = 0; var peerPID: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &size) == 0, peerPID == pid else {
            throw HCUnavailableReason.foreignSession
        }
        let methods = Set(methodValues.compactMap(\.string)); let features = Set(featureValues.compactMap(\.string))
        guard Set(["server.status", "events.subscribe", "terminal.run", "terminal.attach"]).isSubset(of: methods),
              Set(["framed", "attach", "events", "status"]).isSubset(of: features) else { throw HCUnavailableReason.incompatibleProtocol }
        let peer = HCPeerEvidence(uid: uid, pid: peerPID, statusPID: pid, coreID: coreID, version: version,
                                  protocolGeneration: configuration.configuration.pin.protocolGeneration, methods: methods, features: features)
        let continuation = openContinuation; openContinuation = nil; continuation?.resume(returning: peer)
    }

    /// Ticket 12: a file transfer has its own RPC budget (admission and
    /// writer lane), so a large put in flight never starves small RPCs.
    static func isFileTransfer(_ method: String) -> Bool { method == "terminal.put" }

    func rpc(_ request: HCRPCRequest) async throws -> HCJSONValue {
        let cost = try request.params.encoded().count + request.method.utf8.count + 128
        let fileTransfer = Self.isFileTransfer(request.method)
        guard rpcAdmission.acquire(cost, fileTransfer: fileTransfer) else {
            throw HCRPCFailure(reason: .bufferOverflow, transmission: .none, remoteCode: nil)
        }
        defer { rpcAdmission.release(cost, fileTransfer: fileTransfer) }
        let token = HCRPCCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { self.enqueue(request, token: token, continuation: continuation) }
            }
        } onCancel: {
            token.cancel()
            self.queue.async {
                if let id = self.pending.first(where: { $0.value.token === token })?.key {
                    self.expire(id, reason: .cancelled)
                }
            }
        }
    }

    private func enqueue(_ request: HCRPCRequest, token: HCRPCCancellation, continuation: CheckedContinuation<HCJSONValue, Error>) {
        guard !closed else { continuation.resume(throwing: HCRPCFailure(reason: .connectionLost, transmission: .none, remoteCode: nil)); return }
        guard !token.isCancelled else { continuation.resume(throwing: HCRPCFailure(reason: .cancelled, transmission: .none, remoteCode: nil)); return }
        if ["terminal.attach", "events.subscribe"].contains(request.method), expiredChannelCalls.count >= HCLimits.pendingRPCs {
            continuation.resume(throwing: HCRPCFailure(reason: .bufferOverflow, transmission: .none, remoteCode: nil)); return
        }
        guard pending.count < HCLimits.pendingRPCs else {
            continuation.resume(throwing: HCRPCFailure(reason: .bufferOverflow, transmission: .none, remoteCode: nil)); return
        }
        #if DEBUG
        if var failure = debugFaults.failMethods[request.method], failure.count > 0 {
            debugFault("fail_method")
            failure.count -= 1; debugFaults.failMethods[request.method] = failure
            continuation.resume(throwing: HCRPCFailure(reason: .malformedResponse, transmission: .rejectedByPeer, remoteCode: failure.kind))
            return
        }
        #endif
        let now = DispatchTime.now().uptimeNanoseconds
        guard request.deadlineUptimeNanoseconds > now else {
            continuation.resume(throwing: HCRPCFailure(reason: .deadlineExceeded, transmission: .none, remoteCode: nil)); return
        }
        guard nextID < Int64.max else { continuation.resume(throwing: HCUnavailableReason.bufferOverflow); fail(.bufferOverflow); return }
        let id = nextID; nextID += 1
        do {
            let json = try HCJSONValue.object(["jsonrpc": .string("2.0"), "id": .integer(id), "method": .string(request.method), "params": request.params]).encoded()
            let bytes = try HCWireFrame(channel: 0, kind: .data, payload: json).encoded()
            // Run timeout starts when the complete request reaches the socket;
            // local queue time cannot consume hc's holder+spawn budget.
            let deadline = request.method == "terminal.run" ? max(request.deadlineUptimeNanoseconds, now + configuration.runBudgetNanoseconds) : request.deadlineUptimeNanoseconds
            let timer = DispatchWorkItem { [weak self] in self?.expire(id) }
            pending[id] = Pending(continuation: continuation, method: request.method, timer: timer, token: token,
                                  lateReply: request.lateReply)
            guard writer.enqueueRPC(bytes, fileTransfer: Self.isFileTransfer(request.method), completion: { [weak self] count, success in
                guard let self else { return }
                self.queue.async {
                    guard self.pending[id] != nil else { return }
                    self.pending[id]?.transmitted = count > 0
                    if !success { self.fail(.connectionLost); return }
                    if request.method == "terminal.run" {
                        self.pending[id]?.timer.cancel()
                        let responseTimer = DispatchWorkItem { [weak self] in self?.expire(id) }
                        self.pending[id]?.timer = responseTimer
                        let runDeadline = max(deadline, DispatchTime.now().uptimeNanoseconds + self.configuration.runBudgetNanoseconds)
                        self.queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: runDeadline), execute: responseTimer)
                    } else if let response = request.responseNanosecondsAfterTransmission {
                        // C11H-306: the reply's bound starts now that the request is on the socket.
                        self.pending[id]?.timer.cancel()
                        let responseTimer = DispatchWorkItem { [weak self] in self?.expire(id) }
                        self.pending[id]?.timer = responseTimer
                        let (replyBy, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(response)
                        self.queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: overflow ? .max : replyBy),
                                              execute: responseTimer)
                    }
                }
            }) else {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: HCRPCFailure(reason: .bufferOverflow, transmission: .none, remoteCode: nil)); return
            }
            // A separate bounded queue wait cannot hang forever behind a peer
            // that stopped reading. Once sent, run gets its full response budget.
            queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: timer)
        } catch { continuation.resume(throwing: error) }
    }

    private func expire(_ id: Int64, reason: HCUnavailableReason = .deadlineExceeded) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timer.cancel()
        // C11H-327: counted, and its caller's mark says so, before the caller resumes: a caller that looks at its
        // mark the moment it is woken must find it.
        if ["terminal.attach", "events.subscribe"].contains(call.method) {
            expiredChannelCalls.insert(id)
            if let late = call.lateReply { late.expire(); expiredLateReplies[id] = late }
        }
        call.continuation.resume(throwing: HCRPCFailure(reason: reason, transmission: .possible, remoteCode: nil))
        #if DEBUG
        Self.afterExpiryForTesting?(call.method)
        #endif
        // Silence is not peer death. Keep existing attachments/input through hc
        // backlog; a run is different because its ambiguous creation must close
        // the transmitting connection for 2A's reconciliation policy. A caller
        // that stops waiting is not silence: the peer is fine and every other
        // terminal shares this connection (C11H-308). Its late reply is dropped.
        if reason != .cancelled, ["terminal.run", "server.restart"].contains(call.method) { fail(reason) }
    }

    private func rpcResult(_ envelope: HCJSONValue) throws -> HCJSONValue {
        guard envelope["jsonrpc"].string == "2.0" else { throw HCUnavailableReason.malformedResponse }
        if envelope["error"] != .null {
            throw HCRPCFailure(reason: .malformedResponse, transmission: .rejectedByPeer,
                               remoteCode: envelope["error"]["data"]["kind"].string ?? envelope["error"]["code"].string)
        }
        guard let value = envelope.object?["result"] else { throw HCUnavailableReason.malformedResponse }; return value
    }

    private func decode(_ bytes: Data) throws {
        try decoder.feed(bytes) { try route($0) }
    }

    private func route(_ frame: HCWireFrame) throws {
        if frame.channel == 0 {
            guard frame.kind == .data else { throw HCUnavailableReason.malformedResponse }
            let envelope = try HCJSONValue.decode(frame.payload)
            guard let id = envelope["id"].integer else { throw HCUnavailableReason.malformedResponse }
            if expiredChannelCalls.remove(id) != nil {
                expiredLateReplies.removeValue(forKey: id)?.settle()
                if let value = try? rpcResult(envelope), let channel = value["channel"].integer.flatMap(UInt32.init(exactly:)), channel > 0 {
                    let discarded = early.removeValue(forKey: channel) ?? []
                    let count = discarded.reduce(0) { $0 + $1.payload.count + 9 }
                    earlyBytes -= count; inboundBudget.release(count)
                    closedChannels.insert(channel)
                    writer.closeChannel(channel); writer.enqueueControl(channel: channel, value: .close)
                }
                return
            }
            #if DEBUG
            if let call = pending[id], !debugDelayedIDs.contains(id) {
                if let count = debugFaults.dropReplies[call.method], count > 0 {
                    debugFault("drop_reply")
                    debugFaults.dropReplies[call.method] = count - 1
                    return
                }
                if let delay = debugFaults.delayReplyNanoseconds[call.method], delay > 0 {
                    guard frame.payload.count <= HCLimits.eventBufferBytes - debugDelayedBytes else { throw HCUnavailableReason.bufferOverflow }
                    debugFault("delay_reply")
                    debugDelayedIDs.insert(id); debugDelayedBytes += frame.payload.count
                    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                        self.debugDelayedBytes -= frame.payload.count
                        guard !self.closed else { return }
                        do { try self.route(frame) } catch { self.fail((error as? HCUnavailableReason) ?? .malformedResponse) }
                        self.debugDelayedIDs.remove(id)
                    }
                    return
                }
            }
            #endif
            guard let call = pending.removeValue(forKey: id) else { return } // late/duplicate reply
            call.timer.cancel()
            do {
                let value = try rpcResult(envelope)
                if call.method == "events.subscribe" || call.method == "terminal.attach" {
                    guard let channel = value["channel"].integer.flatMap(UInt32.init(exactly:)), channel > 0,
                          awaitingChannels.count < HCLimits.pendingRPCs,
                          channels[channel] == nil, !awaitingChannels.contains(channel), !closedChannels.contains(channel) else {
                        throw HCUnavailableReason.malformedResponse
                    }
                    awaitingChannels.insert(channel)
                    if call.method == "events.subscribe" { eventChannels.insert(channel) }
                    #if DEBUG
                    if call.method == "events.subscribe", debugDropUntil == nil, debugFaults.dropEventsForNanoseconds > 0 {
                        let (end, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(debugFaults.dropEventsForNanoseconds)
                        guard !overflow else { throw HCUnavailableReason.malformedResponse }
                        debugDropUntil = end
                    }
                    #endif
                }
                call.continuation.resume(returning: value)
            } catch {
                call.continuation.resume(throwing: error)
                if let reason = error as? HCUnavailableReason { fail(reason) }
            }
            return
        }
        guard frame.kind == .data || frame.kind == .close else { throw HCUnavailableReason.malformedResponse }
        if closedChannels.contains(frame.channel) { return }
        guard let stream = channels[frame.channel] else {
            let pendingOpen = !expiredChannelCalls.isEmpty || pending.values.contains { $0.method == "events.subscribe" || $0.method == "terminal.attach" }
            guard awaitingChannels.contains(frame.channel) || pendingOpen else { throw HCUnavailableReason.malformedResponse }
            guard inboundBudget.reserve(frame.payload.count + 9) else { throw HCUnavailableReason.bufferOverflow }
            early[frame.channel, default: []].append(frame); earlyBytes += frame.payload.count + 9; return
        }
        if frame.kind == .close { stream.ending = true; deliver(frame.channel); return }
        #if DEBUG
        if eventChannels.contains(frame.channel), let until = debugDropUntil,
           DispatchTime.now().uptimeNanoseconds < until {
            debugFault("drop_events")
            // Debug-only loss consumes the dropped stream bytes; granting credit
            // keeps the real core running so its next sequence exposes the gap.
            guard frame.payload.count <= stream.remainingCredit else { throw HCUnavailableReason.bufferOverflow }
            writer.enqueueControl(channel: frame.channel, value: .credit(UInt32(frame.payload.count)))
            return
        }
        #endif
        guard !stream.ending, frame.payload.count <= stream.remainingCredit else { throw HCUnavailableReason.bufferOverflow }
        if eventChannels.contains(frame.channel) {
            guard inboundBudget.reserve(frame.payload.count) else { throw HCUnavailableReason.bufferOverflow }
            stream.eventBytes += frame.payload.count
        }
        stream.remainingCredit -= frame.payload.count
        for start in stride(from: 0, to: frame.payload.count, by: HCLimits.outputChunkBytes) {
            let chunk = Data(frame.payload[start..<min(frame.payload.count, start + HCLimits.outputChunkBytes)])
            stream.chunks.append(chunk); stream.buffered += chunk.count
        }
        deliver(frame.channel)
    }

    func register(_ channel: UInt32, attachmentGeneration: UInt64, sink: any HCOutputSink) async throws -> any HCChannel {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.closed, self.awaitingChannels.remove(channel) != nil, self.channels[channel] == nil else {
                    continuation.resume(throwing: HCUnavailableReason.staleIdentity); return
                }
                let stream = Stream(sink: sink, generation: attachmentGeneration)
                self.channels[channel] = stream
                let frames = self.early.removeValue(forKey: channel) ?? []
                do {
                    for frame in frames {
                        self.earlyBytes -= frame.payload.count + 9
                        self.inboundBudget.release(frame.payload.count + 9)
                        try self.route(frame)
                    }
                    continuation.resume(returning: HCUnixChannel(channel: channel, generation: attachmentGeneration, engine: self))
                } catch {
                    continuation.resume(throwing: error)
                    self.fail(HCUnavailableReason.transportReason(error))
                }
            }
        }
    }

    func activate(_ channel: UInt32) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard !self.closed, let stream = self.channels[channel], stream.activation == nil else {
                        continuation.resume(throwing: HCUnavailableReason.staleIdentity); return
                    }
                    if stream.active { continuation.resume(); return }
                    stream.active = true
                    stream.activation = continuation
                    stream.activationTarget = stream.consumed + UInt64(stream.buffered)
                    self.deliver(channel)
                    if self.channels[channel] === stream { self.completeActivation(channel, stream: stream) }
                }
            }
        } onCancel: { self.closeChannel(channel) }
    }

    private func completeActivation(_ channel: UInt32, stream: Stream) {
        guard stream.consumed >= stream.activationTarget, let continuation = stream.activation else { return }
        if eventChannels.contains(channel), stream.busy || !stream.chunks.isEmpty || stream.buffered != 0 { return }
        stream.activation = nil
        continuation.resume()
    }

    private func deliver(_ channel: UInt32) {
        guard let stream = channels[channel], stream.active, !stream.busy else { return }
        if stream.chunks.isEmpty {
            if stream.ending {
                stream.activation?.resume(throwing: HCUnavailableReason.connectionLost); stream.activation = nil
                channels.removeValue(forKey: channel); eventChannels.remove(channel); closedChannels.insert(channel); writer.closeChannel(channel)
                stream.sink.retire {}
            }
            return
        }
        let bytes = stream.chunks.removeFirst(); stream.busy = true; stream.watermark += UInt64(bytes.count)
        let chunk = HCOutputChunk(attachmentGeneration: stream.generation, watermark: stream.watermark, bytes: bytes)
        Task {
            let result = await stream.sink.consume(chunk)
            self.queue.async {
                guard !self.closed, self.channels[channel] === stream else { return }
                stream.busy = false; stream.buffered -= bytes.count
                if self.eventChannels.contains(channel) {
                    stream.eventBytes -= bytes.count; self.inboundBudget.release(bytes.count)
                }
                switch result {
                case .consumed:
                    stream.consumed += UInt64(bytes.count)
                    self.completeActivation(channel, stream: stream)
                    stream.remainingCredit += bytes.count
                    self.writer.enqueueControl(channel: channel, value: .credit(UInt32(bytes.count)))
                    self.deliver(channel)
                case .stale: self.closeChannel(channel)
                case .failed(let reason): self.fail(reason)
                }
            }
        }
    }

    func closeChannel(_ channel: UInt32) {
        queue.async {
            guard !self.closed else { return }
            self.writer.closeChannel(channel)
            if let stream = self.channels.removeValue(forKey: channel) {
                self.inboundBudget.release(stream.eventBytes); stream.eventBytes = 0
                stream.activation?.resume(throwing: HCUnavailableReason.connectionLost); stream.activation = nil
                stream.sink.retire {}
            }
            self.eventChannels.remove(channel)
            self.closedChannels.insert(channel)
            self.writer.enqueueControl(channel: channel, value: .close)
        }
    }

    func close(reason: HCUnavailableReason) { queue.async { self.fail(reason) } }

    private func fail(_ reason: HCUnavailableReason) {
        guard !closed else { return }; closed = true
        writer.stop()
        let opening = openContinuation; openContinuation = nil; opening?.resume(throwing: reason)
        let calls = pending; pending = [:]
        for call in calls.values {
            call.timer.cancel()
            call.continuation.resume(throwing: HCRPCFailure(reason: reason, transmission: .possible, remoteCode: nil))
        }
        for stream in channels.values {
            inboundBudget.release(stream.eventBytes); stream.eventBytes = 0
            stream.activation?.resume(throwing: reason); stream.activation = nil
            stream.sink.retire {}
        }
        inboundBudget.release(earlyBytes)
        for late in expiredLateReplies.values { late.settle() }    // the budget goes with the connection
        channels = [:]; eventChannels = []; early = [:]; earlyBytes = 0; awaitingChannels = []; expiredChannelCalls = []; expiredLateReplies = [:]
        // Both dispatch sources retain the fd until their cancellation handlers
        // have retired. No descriptor reuse can race a still-registered source.
        readSource?.cancel()
        if !writeResumed { writeSource?.resume(); writeResumed = true }
        writeSource?.cancel(); readSource = nil; writeSource = nil
        if fd >= 0 {
            if fdLease == nil { Darwin.close(fd) }
            fd = -1; fdLease = nil
        }
    }
}

/// Two registered dispatch sources, one descriptor owner.
private final class HCFDLease: @unchecked Sendable {
    private let lock = NSLock()
    private let fd: Int32
    private var remaining = 2
    init(fd: Int32) { self.fd = fd }
    func retire() {
        lock.lock(); remaining -= 1; let close = remaining == 0; lock.unlock()
        if close { Darwin.close(fd) }
    }
}

private final class HCRPCAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var bytes = 0
    private var fileBytes = 0
    /// File transfers count against their own budget, never the ordinary one.
    func acquire(_ cost: Int, fileTransfer: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard cost >= 0, count < HCLimits.pendingRPCs else { return false }
        if fileTransfer {
            guard cost <= HCLimits.fileTransferRPCBytes - fileBytes else { return false }
            fileBytes += cost
        } else {
            guard cost <= HCLimits.queuedInputBytes - bytes else { return false }
            bytes += cost
        }
        count += 1; return true
    }
    func release(_ cost: Int, fileTransfer: Bool = false) {
        lock.lock(); count -= 1
        if fileTransfer { fileBytes -= cost } else { bytes -= cost }
        lock.unlock()
    }
}

private final class HCRPCCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
