import Darwin
import Foundation

// C11H-72: one line-framed Unix stream connection to the bus core, and the
// request channel the adapter runs over it. Nothing here touches the main
// thread: each connection has one reader thread, and callers are async.

/// One connected Unix stream socket that reads and writes whole lines.
final class CbusLineSocket: @unchecked Sendable {
    private let fd: Int32
    private let stateLock = NSLock()
    private var closing = false
    private var started = false
    /// Held while writing and while the descriptor is released, so a write
    /// never lands on a descriptor number the reader has given back.
    private let writeLock = NSLock()
    private var released = false
    /// Sees each line's raw bytes, newline excluded, before it is decoded. Set
    /// before `start`; tests use it to capture the wire for CBUS-19's checker.
    var lineObserver: (@Sendable (Data) -> Void)?

    /// Wraps a connected descriptor (the adapter's, or the fake core's accepted one).
    init(descriptor: Int32) {
        fd = descriptor
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Connects to `path`, or nil when nothing listens there (missing socket,
    /// refused connection, or a path too long for a Unix address), or when
    /// CBUS-19 rule 1.3's checks fail: the path must be a socket, not a symlink,
    /// owned by this process's uid, and the peer must run as that uid.
    static func connect(path: String) -> CbusLineSocket? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { return nil }
        guard var address = unixAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return nil }
        var peerUID = uid_t(), peerGID = gid_t()
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else { Darwin.close(fd); return nil }
        return CbusLineSocket(descriptor: fd)
    }

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// The pid of the process on the other end (`LOCAL_PEERPID`).
    var peerPID: pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL (0) and LOCAL_PEERPID (0x002), from <sys/un.h>.
        guard getsockopt(fd, 0, 0x002, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Starts the reader thread. `onLine` gets each decoded frame in order;
    /// `onClose` runs once, after the descriptor is released.
    func start(onFrame: @escaping @Sendable ([String: Any]) -> Void, onClose: @escaping @Sendable () -> Void) {
        stateLock.lock()
        started = true
        stateLock.unlock()
        let thread = Thread { [self] in
            readLoop(onFrame: onFrame)
            writeLock.lock()
            released = true
            Darwin.close(fd)
            writeLock.unlock()
            onClose()
        }
        thread.name = "c11.cbus.reader"
        thread.start()
    }

    private var isClosing: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closing
    }

    private func readLoop(onFrame: @Sendable ([String: Any]) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            // A long-lived thread drains its pool per iteration (CLAUDE.md).
            let keepReading: Bool = autoreleasepool {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 250)
                if ready < 0 { return errno == EINTR }
                if ready == 0 { return !isClosing }
                let count = read(fd, &chunk, chunk.count)
                if count < 0 { return errno == EAGAIN || errno == EINTR }
                if count == 0 { return false }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    lineObserver?(line)
                    if let frame = CbusWire.decodeLine(line) { onFrame(frame) }
                }
                // An incomplete line is never acted on; an over-long one ends the link.
                return buffer.count <= CbusWire.maximumLineBytes
            }
            if !keepReading { return }
        }
    }

    /// Writes all of `data` by `deadline`. False means it did not all leave; the
    /// caller then closes the socket, so the partial line is never completed
    /// and the far side discards it.
    func write(_ data: Data, deadline: Date) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !released, !isClosing else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base + offset, raw.count - offset)
                if count > 0 { offset += count; continue }
                guard count < 0, errno == EAGAIN || errno == EINTR else { return false }
                let milliseconds = Int32(min(Double(Int32.max), max(0, deadline.timeIntervalSinceNow * 1000)))
                guard milliseconds > 0 else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, milliseconds)
            }
            return true
        }
    }

    /// Ends the connection. The reader thread releases the descriptor and runs
    /// `onClose`; a socket never started is released here.
    func close() {
        stateLock.lock()
        let wasStarted = started
        let already = closing
        closing = true
        stateLock.unlock()
        guard !already else { return }
        if wasStarted {
            shutdown(fd, SHUT_RDWR)
        } else {
            writeLock.lock()
            if !released { released = true; Darwin.close(fd) }
            writeLock.unlock()
        }
    }
}

/// Sees every line the adapter writes (`C:`) and reads (`D:`), by connection,
/// for a wire capture checked by CBUS-19's own checker. Nil in production.
typealias CbusWireTap = @Sendable (_ direction: String, _ connection: String, _ line: Data) -> Void

/// Who the adapter will talk to on `cbus.sock` (plan section 4). The socket is
/// in a user-writable folder, so any process of the user could listen there;
/// the peer's pid is checked on every connect.
struct BusPeerPolicy: Sendable {
    let admits: @Sendable (pid_t) -> Bool

    /// Refuses every peer. The production default until the pinned-helper rule
    /// (C11H-108's evaluator, PR 2) lands.
    static let refuseAll = BusPeerPolicy { _ in false }
    /// The fake core in tests runs in the test process itself.
    static let sameProcess = BusPeerPolicy { $0 == getpid() }
}

extension HostTransportRefusal {
    /// CBUS-23 rule 4.6: this machine's join certificate does not make it
    /// eligible to be the app host. Final: never retried.
    static let appHostIneligible = Self(rawValue: "app_host_ineligible")
    /// The daemon refused a request as malformed: an adapter defect, never the envelope's.
    static let protocolError = Self(rawValue: "transport_protocol_error")
}

/// A reply, with the connection generation it came on.
struct CbusReply: @unchecked Sendable {
    let fields: [String: Any]
    let generation: Int
}

/// How one request ended, before CBUS-19 rule 10.4 turns it into an A6 result.
enum CbusCallOutcome: Sendable {
    case reply(CbusReply)
    /// No complete line reached a daemon: not running, a failed rule 1.3
    /// check, a `hello` error, or a write that did not finish.
    case notSent(reason: String)
    /// The whole request went out, and the connection closed before a response.
    case lost
    /// The whole request went out, and no response came by the deadline.
    case timedOut
    /// Kept for channel errors that are never the daemon's to answer.
    case refused(HostTransportRefusal)
}

/// Requests and replies over one lazily connected `CbusLineSocket`, matched by
/// request id (CBUS-19 section 3). Lines with `frame` are stream events for `onEvent`. A
/// closed connection is replaced on the next call (a new generation).
final class CbusChannel: @unchecked Sendable {
    private enum Stage { case writing, written }
    private struct Waiter {
        let continuation: CheckedContinuation<CbusCallOutcome, Never>
        let generation: Int
        let deadline: Date
        var stage: Stage
    }

    private let socketPath: String
    private let host: String
    private let client: String
    private let session: String
    private let appHost: Bool
    private let peerPolicy: BusPeerPolicy
    private let onEvent: @Sendable (Int, [String: Any]) -> Void
    private let onDisconnect: @Sendable () -> Void
    private let wireTap: CbusWireTap?
    private static let serials = NSLock()
    private static var nextSerial = 0
    private let serial: Int

    private let lock = NSLock()
    private var socket: CbusLineSocket?
    private var ready = false
    private var generation = 0
    private var connecting = false
    private var connectWaiters: [CheckedContinuation<Result<(CbusLineSocket, Int), Failure>?, Never>] = []
    private var pending: [Int: Waiter] = [:]
    private var nextRid = 0
    private var shut = false
    /// CBUS-23 rule 2.2 and the `app_host` frame of rule 4.6: where this
    /// host's app-host registration stands (`granted`, `provisional`,
    /// `refused` or `none`); nil before the first `hello`.
    private var registration: String?
    /// `app_host_ineligible` is final: the channel never connects again.
    private var ineligible = false

    enum Failure: Error { case notSent(String), refused(HostTransportRefusal) }

    init(socketPath: String, host: String, session: String, appHost: Bool, client: String, peerPolicy: BusPeerPolicy,
         onEvent: @escaping @Sendable (Int, [String: Any]) -> Void = { _, _ in },
         onDisconnect: @escaping @Sendable () -> Void = {}, wireTap: CbusWireTap? = nil) {
        self.socketPath = socketPath
        self.host = host
        self.client = client
        self.session = session
        self.appHost = appHost
        self.peerPolicy = peerPolicy
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
        self.wireTap = wireTap
        serial = Self.serials.withLock {
            Self.nextSerial += 1
            return Self.nextSerial
        }
    }

    /// This channel's connection `generation`, named for a wire capture.
    private func connectionName(_ generation: Int) -> String { "\(host)-\(serial)-\(generation)" }

    var appHostRegistration: String? { lock.withLock { registration } }

    /// The generation of the live, greeted connection, if there is one.
    var liveGeneration: Int? {
        lock.lock(); defer { lock.unlock() }
        return socket != nil && ready ? generation : nil
    }

    /// One request and its reply, connecting first if needed.
    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) async -> CbusCallOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        switch await connection(deadline: deadline) {
        case .failure(.notSent(let reason)): return .notSent(reason: reason)
        case .failure(.refused(let refusal)): return .refused(refusal)
        case .success(let (socket, generation)):
            return await exchange(method, params, on: socket, generation: generation, deadline: deadline)
        }
    }

    /// Connects and greets now; true once the daemon answered `hello`.
    func open(timeout: TimeInterval) async -> Bool {
        if case .success = await connection(deadline: Date().addingTimeInterval(timeout)) { return true }
        return false
    }

    /// Ends the channel for good (its owner is gone).
    func close() {
        lock.lock()
        shut = true
        let current = socket
        lock.unlock()
        current?.close()
    }

    // MARK: Connecting

    private enum Admission { case closed, live(CbusLineSocket, Int), wait, lead }

    private func connection(deadline: Date) async -> Result<(CbusLineSocket, Int), Failure> {
        while true {
            let latched = lock.withLock { ineligible }
            if latched { return .failure(.refused(.appHostIneligible)) }
            let admission: Admission = lock.withLock {
                if shut { return .closed }
                if let socket, ready { return .live(socket, generation) }
                if connecting { return .wait }
                connecting = true
                return .lead
            }
            switch admission {
            case .closed:
                return .failure(.notSent("bus_channel_closed"))
            case .live(let socket, let generation):
                return .success((socket, generation))
            case .lead:
                let result = await establish(deadline: deadline)
                let waiters = lock.withLock {
                    connecting = false
                    defer { connectWaiters = [] }
                    return connectWaiters
                }
                for waiter in waiters { waiter.resume(returning: result) }
                return result
            case .wait:
                // Joins the connect in progress; one that already finished is looked at again.
                let joined = await withCheckedContinuation { (continuation: CheckedContinuation<Result<(CbusLineSocket, Int), Failure>?, Never>) in
                    let queued = lock.withLock {
                        if connecting { connectWaiters.append(continuation) }
                        return connecting
                    }
                    if !queued { continuation.resume(returning: nil) }
                }
                if let joined { return joined }
            }
        }
    }

    private func establish(deadline: Date) async -> Result<(CbusLineSocket, Int), Failure> {
        // CBUS-19 rule 10.4: a missing socket, a refused connection or a failed
        // rule 1.3 check all answer as a daemon that is not running.
        guard let socket = CbusLineSocket.connect(path: socketPath) else { return .failure(.notSent("daemon_down")) }
        guard let pid = socket.peerPID, peerPolicy.admits(pid) else {
            socket.close()
            return .failure(.notSent("daemon_down"))
        }
        let current: Int = lock.withLock {
            generation += 1
            self.socket = socket
            ready = false
            return generation
        }
        if let wireTap {
            let name = connectionName(current)
            socket.lineObserver = { line in wireTap("D:", name, line) }
        }
        socket.start(onFrame: { [weak self] frame in self?.handle(frame, generation: current) },
                     onClose: { [weak self] in self?.closed(generation: current) })
        let hello: [String: Any] = ["protocol": CbusWire.protocolVersion, "role": CbusWire.role, "session": session,
                                    "host": host, "app_host": appHost, "client": client]
        switch await exchange("hello", hello, on: socket, generation: current, deadline: deadline) {
        case .reply(let reply) where ((reply.fields["result"] as? [String: Any])?["protocol"] as? NSNumber)?.intValue
                                    == CbusWire.protocolVersion:
            let reported = (reply.fields["result"] as? [String: Any])?["app_host_registration"] as? String
            let live: Bool = lock.withLock {
                if self.socket === socket { ready = true }
                if let reported { registration = reported }
                return self.socket === socket
            }
            return live ? .success((socket, current)) : .failure(.notSent("daemon_closed"))
        case .reply(let reply):
            // CBUS-19 rule 2.3: a hello error closes the connection, and nothing was sent.
            socket.close()
            let code = ((reply.fields["error"] as? [String: Any])?["code"] as? String) ?? "protocol_unsupported"
            if code == HostTransportRefusal.appHostIneligible.rawValue {
                // A refusal, never a retry loop: no later call connects again.
                lock.withLock { ineligible = true }
                return .failure(.refused(.appHostIneligible))
            }
            return .failure(.notSent(code))
        default:
            socket.close()
            return .failure(.notSent("daemon_down"))
        }
    }

    // MARK: Requests

    private func exchange(_ method: String, _ params: [String: Any], on socket: CbusLineSocket, generation: Int,
                          deadline: Date) async -> CbusCallOutcome {
        let rid: Int = lock.withLock {
            nextRid += 1
            return nextRid
        }
        let request: [String: Any] = ["id": String(rid), "method": method, "params": params]
        guard let data = CbusWire.encodeLine(request) else { return .notSent(reason: "request_unencodable") }
        return await withCheckedContinuation { continuation in
            lock.lock()
            pending[rid] = Waiter(continuation: continuation, generation: generation, deadline: deadline, stage: .writing)
            lock.unlock()
            wireTap?("C:", connectionName(generation), data.dropLast())
            let complete = socket.write(data, deadline: deadline)
            if !complete {
                // Part of a line at most: the core never acts on it.
                socket.close()
                resume(rid, with: .notSent(reason: "daemon_closed"))
                return
            }
            lock.lock()
            pending[rid]?.stage = .written
            let dead = self.generation != generation || self.socket == nil
            lock.unlock()
            if dead { resume(rid, with: .lost); return }
            if Date() >= deadline { resume(rid, with: .timedOut); return }
            let delay = deadline.timeIntervalSinceNow
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
                self?.resumeIfWritten(rid, with: .timedOut)
            }
        }
    }

    private func handle(_ frame: [String: Any], generation: Int) {
        if frame["frame"] as? String == "app_host", let decided = frame["registration"] as? String {
            // Rule 4.6: the authority's decision on a provisional claim.
            lock.withLock { registration = decided }
        }
        if frame["frame"] == nil, let rid = (frame["id"] as? String).flatMap(Int.init) {
            lock.lock()
            let known = pending[rid] != nil
            lock.unlock()
            if known { resume(rid, with: .reply(CbusReply(fields: frame, generation: generation))); return }
        }
        onEvent(generation, frame)
    }

    private func closed(generation: Int) {
        lock.lock()
        if self.generation == generation { socket = nil; ready = false }
        let lost = pending.filter { $0.value.generation == generation && $0.value.stage == .written }.map(\.key)
        lock.unlock()
        for rid in lost { resume(rid, with: .lost) }
        onDisconnect()
    }

    private func resume(_ rid: Int, with outcome: CbusCallOutcome) {
        lock.lock()
        let waiter = pending.removeValue(forKey: rid)
        lock.unlock()
        waiter?.continuation.resume(returning: outcome)
    }

    /// A timer never decides a frame still being written; the writer does.
    private func resumeIfWritten(_ rid: Int, with outcome: CbusCallOutcome) {
        lock.lock()
        guard let waiter = pending[rid], waiter.stage == .written else { lock.unlock(); return }
        pending.removeValue(forKey: rid)
        lock.unlock()
        waiter.continuation.resume(returning: outcome)
    }
}
