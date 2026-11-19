import Darwin
import Foundation

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11H-72: an in-process stand-in for the bus daemons, speaking the
// HostTransport socket protocol version 1 (CBUS-19, repair 1 at bbe5a85) on
// real Unix sockets in a test folder, one socket per host. The hosts share one
// core state, as copies would after replication. Nothing is launched or
// signalled: "restart" closes connections and keeps what was committed.
//
// By CBUS-19 rule: hello and the session's app host (2, 4.6); request ids (3);
// rule 6.2's rows 1 to 10 in order, sizes on original bytes (5.7); commit then
// store (6.6); `send` answers `delivered` once stored, else
// `unreachable(no_answer, unknown)` at the daemon's deadline (6.7); away (6.3);
// the backlog admitted on projected totals (6.4); repeats (6.5, 7.3); `hold`
// answers at commit (7.5); one subscription per sending host (8.2);
// redelivery from the earliest unacknowledged (8.4); the window of 64 (8.6);
// `envelope` frames with `from_app_host` (8.7); `rejected` frames with raw
// bytes in chunks after rows 1 to 5 re-run on arrival (8.8); ack with unknown
// ids (8.11); 7 days' memory on its own clock (8.12); the stale-state check at
// first hand-out (9). The app host (4.6, with the Lead's C2 ruling of 01:05):
// only a machine whose join certificate makes it eligible can register;
// another's `app_host: true` hello is `app_host_taken`. The test controls are section 11's: `setSilent` parks a
// `send` before its commit and `releaseLateAccepts` commits it later, after
// anything sent since, through rows 6 onward.

final class FakeCbusCore: @unchecked Sendable {
    private struct Lane: Hashable { let from: String; let to: String }
    private struct Entry {
        let id: String
        let json: String
        let size: Int
        let state: HostEnvelope.StateHeader?
    }
    private struct Queue {
        /// Committed by the sending daemon, not yet stored by the receiver's.
        var outbound: [Entry] = []
        /// Stored by the receiver's daemon, not yet acknowledged, in order.
        var stored: [Entry] = []
        var carried: Set<String> = []
    }
    private struct Parked { let lane: Lane; let text: String; let object: [String: Any] }

    private final class Connection {
        let host: String
        let name: String
        let socket: CbusLineSocket
        /// A section 11 test-control connection (`cbus-test.sock`).
        let control: Bool
        var greeted = false
        var session = ""
        init(host: String, name: String, socket: CbusLineSocket, control: Bool) {
            self.host = host; self.name = name; self.socket = socket; self.control = control
        }
    }

    private struct Subscriber {
        let connection: Connection
        var handed = 0
        var unacknowledged: Set<String> = []
    }

    private struct StaleKey: Hashable { let to: String; let from: String; let panel: UUID; let key: String }

    let directory: URL
    private let lock = NSLock()
    private var queues: [Lane: Queue] = [:]
    /// Receiver -> id -> when it was acknowledged, on the core's clock.
    private var acknowledged: [String: [String: Date]] = [:]
    /// Each daemon's own clock for the 7-day memory (section 11's `advance_clock`).
    private var clockOffset: [String: TimeInterval] = [:]
    private func now(_ host: String) -> Date { Date().addingTimeInterval(clockOffset[host] ?? 0) }
    /// The arrivals each host's daemon sent as `rejected` frames (section 11's `quarantined`).
    private var rejectedLog: [String: [(id: String, code: String)]] = [:]
    private var controlListeners: [String: Int32] = [:]
    private var awaySince: [String: Date] = [:]
    private var silent: Set<String> = []
    private var parked: [Parked] = []
    private var appHost: String?
    private var subscribers: [Lane: Subscriber] = [:]
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var listeners: [String: Int32] = [:]
    private var staleTable: [StaleKey: (seq: UInt64, id: String)] = [:]
    private var stopped = false
    private var methods: [String: Int] = [:]
    private var ackRequests: Set<String> = []
    private var connectionCount = 0
    /// `session/host` endpoints bound by a `hello` (CBUS-19 rules 4.2 and 4.3).
    private var bound: Set<String> = []
    private var controlRequests = 0
    /// Rule 6.2 row 8: a `send` to a host not bound in the session is
    /// `unreachable(host_unknown)`; a `hold` waits for the binding.
    var enforcesSessionBindings = true
    /// The wire, both directions, in CBUS-19's checker format (`# @conn`, `C:`,
    /// `D:`), only when the gate set `C11_BUS_WIRE_DIR` for its run.
    private let capture: FileHandle?
    private let captureLock = NSLock()

    /// Machines whose join certificate makes them eligible to be the app host
    /// (one per constellation; the laptop today). Set by the harness, as `cbus join` would.
    var eligibleAppHosts: Set<String> = []
    /// True: an eligible host's `app_host: true` hello is granted at once (an
    /// authority in reach). False: it is `provisional` until decided, by the
    /// authority (`decideAppHost`) or section 11's `set_app_host_registration`.
    var grantsAppHostAtHello = true
    /// One world behind every control socket (as a single mock process is):
    /// `advance_clock` on any of them moves every daemon's clock.
    var sharesOneWorld = false
    /// Each claimant's registration (CBUS-23 rule 4.6).
    private var registrations: [String: String] = [:]

    // Fault and policy controls (section 11).
    var holdLimit = HostTransportBounds.maximumHeldEnvelopes
    var holdByteLimit = HostTransportBounds.maximumHeldBytes
    var receiverRefusal: String?
    var tamper: (@Sendable (inout Data, inout Data?) -> Void)?
    /// The daemon answers `send` by this (CBUS-19: 1,800 ms; tests use less).
    var daemonDeadline: TimeInterval = 1.8
    /// The protocol a successful `hello` reports.
    var helloProtocol = CbusWire.protocolVersion
    /// A `hello` error to answer with, then close (rule 2.3).
    var helloError: String?
    /// Methods on which the daemon closes the connection without answering.
    var dropOnMethods: Set<String> = []
    /// A fixed response for a method, in place of the normal handling.
    var responseFor: [String: [String: Any]] = [:]
    /// Section 9's check. Off, it leaves the adapter's own check alone on the path.
    var enforcesStaleState = true
    /// SPEC 12.5 at c4a7fd0: the daemon discards any carried `origin_host` and
    /// `machine` before handing an envelope over, even one the app host forwards.
    var discardsCarriedOrigin = false
    static let window = 64

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cbus-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture = BusWireCapture.newFile()
    }

    deinit { stop() }

    private func record(_ tag: String, _ connection: String, _ line: Data) {
        guard let capture else { return }
        var entry = Data("# @\(connection)\n\(tag) ".utf8)
        entry.append(line)
        entry.append(0x0A)
        captureLock.lock()
        capture.write(entry)
        captureLock.unlock()
    }

    /// The socket a host's adapter connects to; its daemon starts on first use.
    func socketPath(_ host: String) -> String {
        let path = directory.appendingPathComponent("\(host).sock").path
        lock.lock(); defer { lock.unlock() }
        guard listeners[host] == nil, !stopped else { return path }
        unlink(path)
        guard var address = CbusLineSocket.unixAddress(path) else { return path }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 16) == 0 else { if fd >= 0 { close(fd) }; return path }
        listeners[host] = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd, host: host, control: false) }
        thread.name = "fake.cbus.accept.\(host)"
        thread.start()
        return path
    }

    /// Section 11's `cbus-test.sock` for a host's daemon; it starts on first use.
    func controlSocketPath(_ host: String) -> String {
        let path = directory.appendingPathComponent("\(host)-test.sock").path
        lock.lock(); defer { lock.unlock() }
        guard controlListeners[host] == nil, !stopped, var address = CbusLineSocket.unixAddress(path) else { return path }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 16) == 0 else { if fd >= 0 { close(fd) }; return path }
        controlListeners[host] = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd, host: host, control: true) }
        thread.name = "fake.cbus.control.\(host)"
        thread.start()
        return path
    }

    func stop() {
        lock.lock()
        stopped = true
        let open = Array(connections.values)
        let fds = Array(listeners.values) + Array(controlListeners.values)
        listeners = [:]
        controlListeners = [:]
        lock.unlock()
        for connection in open { connection.socket.close() }
        for fd in fds { close(fd) }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Section 11's controls

    func setAway(_ host: String, _ away: Bool) {
        lock.lock(); defer { lock.unlock() }
        if away {
            if awaySince[host] == nil { awaySince[host] = Date() }
            return
        }
        awaySince[host] = nil
        for lane in Array(queues.keys) where lane.to == host || lane.from == host { flush(lane) }
    }

    /// While silent, every `send` to `host` is parked before commit.
    func setSilent(_ host: String, _ isSilent: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isSilent { silent.insert(host) } else { silent.remove(host) }
    }

    /// Commits every parked `send`, in park order, from rule 6.2 row 6 on.
    func releaseLateAccepts() -> Int {
        lock.lock(); defer { lock.unlock() }
        let released = parked
        parked = []
        for item in released { _ = commit(item.lane, item.text, item.object) }
        return released.count
    }

    /// Every daemon's clock (the in-process harness); `advance_clock` moves one.
    func advanceClock(by seconds: TimeInterval, host: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        let hosts = host.map { [$0] } ?? Array(Set(listeners.keys).union(clockOffset.keys))
        for one in hosts { clockOffset[one, default: 0] += seconds }
    }

    /// The link between two hosts drops: the subscriptions each holds from the
    /// other end with `closed`, reason `reconnect`.
    func reconnect(_ a: String, _ b: String) {
        lock.lock(); defer { lock.unlock() }
        for lane in [Lane(from: a, to: b), Lane(from: b, to: a)] {
            guard let subscriber = subscribers.removeValue(forKey: lane) else { continue }
            write(["frame": "closed", "from_host": lane.from, "reason": "reconnect"], to: subscriber.connection)
        }
    }

    /// A host's daemon restarts on the same store: every connection it is part of closes.
    func restart(_ host: String) {
        lock.lock()
        var closing = connections.values.filter { $0.host == host }
        closing += subscribers.filter { $0.key.from == host }.map(\.value.connection)
        lock.unlock()
        for connection in closing { connection.socket.close() }
    }

    /// Writes a raw frame to the subscriber of `from` → `to`.
    func inject(from: String, to: String, _ frame: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard let subscriber = subscribers[Lane(from: from, to: to)] else { return }
        write(frame, to: subscriber.connection)
    }

    // MARK: Observations

    /// Section 11 operations this core's control sockets received.
    func controlRequestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return controlRequests
    }

    func count(_ method: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return methods[method] ?? 0
    }

    /// True when an adapter asked to acknowledge `id`, known or not.
    func wasAcknowledgeRequested(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ackRequests.contains(id)
    }

    func isAcknowledged(_ id: String, by host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isAcknowledgedLocked(id, by: host)
    }

    private func isAcknowledgedLocked(_ id: String, by host: String) -> Bool {
        guard let at = acknowledged[host]?[id] else { return false }
        return now(host).timeIntervalSince(at) < HostTransportBounds.acknowledgedRetention
    }

    // MARK: Serving

    private func acceptLoop(_ listener: Int32, host: String, control: Bool) {
        while true {
            let keepGoing: Bool = autoreleasepool {
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                lock.lock()
                let done = stopped
                lock.unlock()
                if done { return false }
                guard ready > 0 else { return true }
                let fd = Darwin.accept(listener, nil, nil)
                guard fd >= 0 else { return true }
                lock.lock()
                connectionCount += 1
                let connection = Connection(host: host, name: "\(control ? "ctl-" : "")\(host)-\(connectionCount)",
                                            socket: CbusLineSocket(descriptor: fd), control: control)
                connections[ObjectIdentifier(connection)] = connection
                lock.unlock()
                let name = connection.name
                connection.socket.lineObserver = { [weak self] line in self?.record("C:", name, line) }
                connection.socket.start(onFrame: { [weak self] line in self?.handle(line, on: connection) },
                                        onClose: { [weak self] in self?.closed(connection) })
                return true
            }
            if !keepGoing { return }
        }
    }

    private func closed(_ connection: Connection) {
        lock.lock(); defer { lock.unlock() }
        connections.removeValue(forKey: ObjectIdentifier(connection))
        for (lane, subscriber) in subscribers where subscriber.connection === connection { subscribers.removeValue(forKey: lane) }
    }

    /// Lock held.
    private func write(_ line: [String: Any], to connection: Connection) {
        guard let data = CbusWire.encodeLine(line) else { return }
        record("D:", connection.name, data.dropLast())
        _ = connection.socket.write(data, deadline: Date().addingTimeInterval(1))
    }

    private func respond(_ connection: Connection, _ id: Any?, result: [String: Any]) {
        write(["id": id ?? NSNull(), "result": result], to: connection)
    }

    private func fail(_ connection: Connection, _ id: Any?, _ code: String, close: Bool = false) {
        write(["id": id ?? NSNull(), "error": ["code": code, "message": code]], to: connection)
        if close { connection.socket.close() }
    }

    private func handle(_ line: [String: Any], on connection: Connection) {
        if connection.control { return handleControl(line, on: connection) }
        lock.lock(); defer { lock.unlock() }
        let method = (line["method"] as? String) ?? ""
        let id = line["id"]
        let params = (line["params"] as? [String: Any]) ?? [:]
        methods[method, default: 0] += 1
        if dropOnMethods.contains(method) { connection.socket.close(); return }
        if let fixed = responseFor[method] {
            var response = fixed
            response["id"] = id
            write(response, to: connection)
            return
        }
        guard connection.greeted || method == "hello" else { return fail(connection, id, "hello_required", close: true) }
        switch method {
        case "hello":
            if let code = helloError { return fail(connection, id, code, close: true) }
            guard (params["role"] as? String) == CbusWire.role, (params["host"] as? String) == connection.host else {
                write(["id": id ?? NSNull(), "error": ["code": "host_mismatch", "bound_host": connection.host,
                                                       "message": "this daemon serves host \(connection.host)"]], to: connection)
                connection.socket.close()
                return
            }
            if (params["app_host"] as? Bool) == true {
                // C2: eligibility comes from the join certificate, never from a claim
                // or first arrival. Anyone else claiming the app host is refused.
                // CBUS-23 (06c0522): an ineligible claimant is app_host_ineligible, with no detail field.
                guard eligibleAppHosts.contains(connection.host) else {
                    write(["id": id ?? NSNull(), "error": ["code": "app_host_ineligible",
                                                           "message": "\(connection.host) is not eligible to be the app host"]],
                          to: connection)
                    connection.socket.close()
                    return
                }
                if registrations[connection.host] == nil || registrations[connection.host] == "none" {
                    registrations[connection.host] = grantsAppHostAtHello ? "granted" : "provisional"
                }
                if registrations[connection.host] == "granted" { appHost = connection.host }
            }
            connection.greeted = true
            connection.session = (params["session"] as? String) ?? ""
            bound.insert("\(connection.session)/\(connection.host)")
            for lane in Array(queues.keys) where lane.to == connection.host { flush(lane) }
            respond(connection, id, result: [
                "protocol": helloProtocol, "daemon": "c11 fake cbus", "executable_sha256": String(repeating: "0", count: 64),
                "features": [String](), "host": connection.host, "session": params["session"] ?? "",
                "app_host": params["app_host"] ?? false, "machine": connection.host, "origin": "\(connection.host).1",
                "limits": ["max_line_bytes": CbusWire.maximumLineBytes, "max_envelope_bytes": 65_536,
                           "max_body_bytes": HostTransportBounds.maximumBodyBytes,
                           "max_topic_bytes": HostTransportBounds.maximumTopicBytes, "max_requests_in_flight": 256,
                           "receive_window": Self.window, "ack_batch": 64, "send_deadline_ms": Int(daemonDeadline * 1000),
                           "hold_max_envelopes": holdLimit, "hold_max_bytes": holdByteLimit],
                // CBUS-23 rule 2.2: where this host's app-host registration stands.
                "app_host_registration": (params["app_host"] as? Bool) == true
                    ? (registrations[connection.host] ?? "none") : "none"])
        case "send", "hold":
            carry(method, params, on: connection, id: id)
        case "receive":
            guard let from = params["from_host"] as? String, from != connection.host else {
                return fail(connection, id, "bad_request")
            }
            let lane = Lane(from: from, to: connection.host)
            if let old = subscribers[lane], old.connection !== connection {
                write(["frame": "closed", "from_host": from, "reason": "replaced"], to: old.connection)
            }
            subscribers[lane] = Subscriber(connection: connection)
            respond(connection, id, result: ["subscribed": from])
            pump(lane)
        case "ack":
            guard let ids = params["ids"] as? [String], !ids.isEmpty, ids.count <= 64 else {
                return fail(connection, id, "bad_request")
            }
            var acked: [String] = [], unknown: [String] = []
            ackRequests.formUnion(ids)
            for envelopeId in ids {
                if acknowledge(envelopeId, by: connection.host) { acked.append(envelopeId) } else { unknown.append(envelopeId) }
            }
            respond(connection, id, result: ["acked": acked, "unknown": unknown])
            for lane in Array(subscribers.keys) where lane.to == connection.host { pump(lane) }
        default:
            fail(connection, id, "unknown_method")
        }
    }

    /// Lock held. True when `host` was handed `id` (or had acknowledged it).
    private func acknowledge(_ id: String, by host: String) -> Bool {
        var known = isAcknowledgedLocked(id, by: host)
        for lane in Array(queues.keys) where lane.to == host {
            guard var queue = queues[lane], let index = queue.stored.firstIndex(where: { $0.id == id }) else { continue }
            known = true
            queue.stored.remove(at: index)
            queues[lane] = queue
            if var subscriber = subscribers[lane] {
                if index < subscriber.handed { subscriber.handed -= 1 }
                subscriber.unacknowledged.remove(id)
                subscribers[lane] = subscriber
            }
        }
        if known { acknowledged[host, default: [:]][id] = now(host) }
        return known
    }

    // MARK: Admission (rule 6.2 rows 1 to 5; sizes by rule 5.7)

    static func isUppercaseULID(_ value: Any?) -> Bool {
        guard let text = value as? String, text.count == 26 else { return false }
        return text.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }
    }

    /// The refusal code, or nil and the envelope's size (rule 5.7).
    static func admission(_ text: String) -> (code: String?, size: Int) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return ("invalid_envelope", 0)
        }
        func length(_ key: String, _ range: ClosedRange<Int>) -> Bool {
            guard let value = object[key] else { return true }
            guard let text = value as? String else { return false }
            return range.contains(text.unicodeScalars.count)
        }
        guard (object["version"] as? NSNumber)?.intValue == 1, isUppercaseULID(object["id"]),
              object["from"] is String, length("from", 1...256), length("reply_to", 1...256), length("to", 0...256),
              object["in_reply_to"] == nil || isUppercaseULID(object["in_reply_to"]),
              let bodyText = object["body"] as? String, object["topic"] == nil || object["topic"] is String else {
            return ("invalid_envelope", 0)
        }
        let ext = object["ext"]
        guard ext == nil || ext is [String: Any] else { return ("invalid_envelope", 0) }
        let c11Raw = (ext as? [String: Any])?["c11h"]
        guard c11Raw == nil || c11Raw is [String: Any] else { return ("invalid_envelope", 0) }
        let c11 = c11Raw as? [String: Any] ?? [:]
        let encoding = c11["encoding"] as? [String: Any] ?? [:]
        if let raw = c11["encoding"] {
            guard let map = raw as? [String: Any], Set(map.keys).isSubset(of: ["body", "topic"]),
                  map.values.allSatisfy({ ($0 as? String) == "base64" }) else { return ("invalid_envelope", 0) }
        }
        func decoded(_ text: String?, _ key: String) -> Data? {
            guard let text else { return Data() }
            return (encoding[key] as? String) == "base64" ? Data(base64Encoded: text) : Data(text.utf8)
        }
        guard let body = decoded(bodyText, "body"), let topic = decoded(object["topic"] as? String, "topic") else {
            return ("invalid_envelope", 0)
        }
        let overhead = (c11["body_overhead"] as? NSNumber)?.intValue ?? 0
        guard c11["body_overhead"] == nil || (0...body.count).contains(overhead) else { return ("invalid_envelope", 0) }
        if let raw = c11["state"] {
            guard let state = raw as? [String: Any], let panel = state["panel"] as? String, UUID(uuidString: panel) != nil,
                  let key = state["key"] as? String, !key.isEmpty,
                  let seq = (state["seq"] as? NSNumber)?.int64Value, (1...(Int64(1) << 53) - 1).contains(seq) else {
                return ("invalid_envelope", 0)
            }
        }
        // A6 Amendment 2: every number in the headers is a safe integer literal.
        var rest = object
        rest["body"] = ""
        rest.removeValue(forKey: "topic")
        guard JCS.onlySafeIntegers(rest) else { return ("invalid_envelope", 0) }
        guard let to = object["to"] as? String, !to.isEmpty else { return ("topic_only_cross_host", 0) }
        if object["body_ref"] != nil { return ("body_ref_cross_host", 0) }
        // Rule 5.7 (repair 1, decision (a)): a sealing layer's overhead comes off a base64 topic too.
        let topicOverhead = (encoding["topic"] as? String) == "base64" ? overhead : 0
        if body.count - overhead > HostTransportBounds.maximumBodyBytes
            || topic.count - topicOverhead > HostTransportBounds.maximumTopicBytes {
            return ("envelope_too_large", 0)
        }
        // A6 Amendment 2's one measure: body and topic as given (less sealing
        // overhead), plus the JCS bytes of the rest without implementation keys.
        if rest["version"] == nil { rest["version"] = 1 }
        if var ext = rest["ext"] as? [String: Any] {
            if var c11Keys = ext["c11h"] as? [String: Any] {
                if (c11Keys["ts_added"] as? Bool) == true { rest.removeValue(forKey: "ts") }
                for key in ["origin_host", "machine", "relay", "encoding", "body_overhead", "ts_added"] {
                    c11Keys.removeValue(forKey: key)
                }
                if c11Keys.isEmpty { ext.removeValue(forKey: "c11h") } else { ext["c11h"] = c11Keys }
            }
            if ext.isEmpty { rest.removeValue(forKey: "ext") } else { rest["ext"] = ext }
        }
        let size = max(0, body.count - overhead) + max(0, topic.count - topicOverhead) + JCS.encode(rest).utf8.count
        if size > 65_536 { return ("envelope_too_large", size) }
        return (nil, size)
    }

    // MARK: send and hold

    private func carry(_ method: String, _ params: [String: Any], on connection: Connection, id: Any?) {
        let from = connection.host
        guard let to = params["to_host"] as? String, to != from, let text = params["envelope"] as? String else {
            return fail(connection, id, "bad_request")
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        let envelopeId = object["id"] as? String
        func answer(_ result: [String: Any]) {
            var result = result
            // Null only when the envelope's id is not a ULID (the schema's outcome_refused).
            result["envelope_id"] = Self.isUppercaseULID(envelopeId) ? envelopeId! : NSNull()
            respond(connection, id, result: result)
        }
        let (code, size) = Self.admission(text)
        if let code { return answer(["outcome": "refused", "code": code, "message": code]) }
        let lane = Lane(from: from, to: to)
        let envelope = envelopeId ?? ""
        // Row 6: a repeat writes nothing and answers from the first (rules 6.5, 7.3).
        if queues[lane]?.carried.contains(envelope) == true {
            if isStored(envelope, lane: lane) { return answer(["outcome": "delivered"]) }
            if method == "hold" {
                return answer(["outcome": "held", "since": CbusWire.timestamp(awaySince[to] ?? awaySince[from] ?? Date())])
            }
            return awaitProof(envelope, lane: lane, answer: answer)
        }
        // Row 7.
        if let refusal = receiverRefusal { return answer(["outcome": "refused", "code": refusal, "message": refusal]) }
        // Row 8: a `send` to a host not bound in this session writes nothing.
        if method == "send", enforcesSessionBindings, !bound.contains("\(connection.session)/\(to)") {
            return answer(["outcome": "unreachable", "reason": "host_unknown", "delivery": "unknown"])
        }
        // Row 9: `send` to an away host writes nothing.
        if method == "send", let since = awaySince[to] ?? awaySince[from] {
            return answer(["outcome": "away", "since": CbusWire.timestamp(since)])
        }
        // Section 11: a silent receiver parks a `send` before its commit.
        if method == "send", silent.contains(to) {
            parked.append(Parked(lane: lane, text: text, object: object))
            DispatchQueue.global().asyncAfter(deadline: .now() + daemonDeadline) {
                answer(["outcome": "unreachable", "reason": "no_answer", "delivery": "unknown"])
            }
            return
        }
        // Row 10: the backlog, admitted and reserved on projected totals.
        let backlog = queues[lane]?.outbound ?? []
        if backlog.count + 1 > holdLimit || backlog.reduce(size, { $0 + $1.size }) > holdByteLimit {
            return answer(["outcome": "refused", "code": HostTransportRefusal.holdFull.rawValue,
                           "message": "the backlog for this host is full"])
        }
        _ = commit(lane, text, object)
        if method == "hold" {
            // Rule 7.5: at commit, never waiting for proof.
            return answer(["outcome": "held", "since": CbusWire.timestamp(awaySince[to] ?? awaySince[from] ?? Date())])
        }
        if isStored(envelope, lane: lane) { return answer(["outcome": "delivered"]) }
        awaitProof(envelope, lane: lane, answer: answer)
    }

    /// Lock held. Rule 6.7: `delivered` once stored, else `unreachable` at the deadline.
    private func awaitProof(_ id: String, lane: Lane, answer: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + daemonDeadline) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            answer(self.isStored(id, lane: lane)
                   ? ["outcome": "delivered"] : ["outcome": "unreachable", "reason": "no_answer", "delivery": "unknown"])
        }
    }

    /// Lock held. Rule 6.6, from row 6: a repeat writes nothing.
    @discardableResult
    private func commit(_ lane: Lane, _ text: String, _ object: [String: Any]) -> Bool {
        let id = (object["id"] as? String) ?? ""
        var queue = queues[lane] ?? Queue()
        guard !queue.carried.contains(id) else { return false }
        let state = CbusWire.hostEnvelope(json: Data(text.utf8), originHost: lane.from, machine: lane.from)?.state
        queue.outbound.append(Entry(id: id, json: text, size: Self.admission(text).size, state: state))
        queue.carried.insert(id)
        queues[lane] = queue
        flush(lane)
        return true
    }

    /// Lock held.
    private func isStored(_ id: String, lane: Lane) -> Bool {
        isAcknowledgedLocked(id, by: lane.to) || (queues[lane]?.stored.contains { $0.id == id } ?? false)
    }

    /// Lock held. The receiver's daemon stores what it can, in order.
    private func flush(_ lane: Lane) {
        guard awaySince[lane.from] == nil, awaySince[lane.to] == nil, var queue = queues[lane] else { return }
        // Rule 7.2: what is held for a host not yet bound waits for its binding.
        if enforcesSessionBindings, !bound.contains(where: { $0.hasSuffix("/\(lane.to)") }) { return }
        while let first = queue.outbound.first {
            queue.outbound.removeFirst()
            if !isAcknowledgedLocked(first.id, by: lane.to), !queue.stored.contains(where: { $0.id == first.id }) {
                queue.stored.append(first)
            }
        }
        queues[lane] = queue
        pump(lane)
    }

    /// Lock held. Hands stored envelopes in order, within the window.
    private func pump(_ lane: Lane) {
        guard var subscriber = subscribers[lane], var queue = queues[lane] else { return }
        while subscriber.unacknowledged.count < Self.window, subscriber.handed < queue.stored.count {
            let entry = queue.stored[subscriber.handed]
            var text = entry.json
            if let tamper, var envelope = CbusWire.hostEnvelope(json: Data(text.utf8), originHost: lane.from, machine: lane.from) {
                // In transit, inside the implementation: only the opaque bytes change.
                var body = envelope.body, topic = envelope.topic
                tamper(&body, &topic)
                envelope = envelope.replacingOpaque(body: body, topic: topic, bodyOverhead: envelope.bodyOverhead)
                envelope.stamps = [:]
                text = CbusWire.envelopeJSON(envelope).map { String(decoding: $0, as: UTF8.self) } ?? text
            }
            // Rule 8.8: rows 1 to 5 again on arrival; a failure goes as raw bytes.
            if let code = Self.admission(text).code {
                let raw = Data(text.utf8)
                rejectedLog[lane.to, default: []].append((entry.id, code))
                write(["frame": "rejected", "from_host": lane.from, "envelope_id": entry.id, "code": code,
                       "raw_bytes": raw.count, "chunk": 0, "chunks": 1, "raw": raw.base64EncodedString()],
                      to: subscriber.connection)
                subscriber.handed += 1
                subscriber.unacknowledged.insert(entry.id)
                continue
            }
            if enforcesStaleState, let state = entry.state {
                let key = StaleKey(to: lane.to, from: lane.from, panel: state.panel, key: state.key)
                if let kept = staleTable[key], state.seq < kept.seq || (state.seq == kept.seq && entry.id != kept.id) {
                    // Rule 9.2: acknowledged as this host and never handed.
                    queue.stored.remove(at: subscriber.handed)
                    acknowledged[lane.to, default: [:]][entry.id] = now(lane.to)
                    continue
                }
                staleTable[key] = (state.seq, entry.id)
            }
            if discardsCarriedOrigin, var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
               var ext = object["ext"] as? [String: Any], var c11 = ext["c11h"] as? [String: Any],
               c11["origin_host"] != nil || c11["machine"] != nil {
                c11.removeValue(forKey: "origin_host")
                c11.removeValue(forKey: "machine")
                ext["c11h"] = c11
                object["ext"] = ext
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                    text = String(decoding: data, as: UTF8.self)
                }
            }
            write(["frame": "envelope", "from_host": lane.from, "envelope_id": entry.id, "envelope": text,
                   "stamps": ["origin_host": lane.from, "machine": lane.from], "from_app_host": lane.from == appHost],
                  to: subscriber.connection)
            subscriber.handed += 1
            subscriber.unacknowledged.insert(entry.id)
        }
        queues[lane] = queue
        subscribers[lane] = subscriber
    }

    /// Each daemon's clock offset, in seconds.
    func clockOffsets() -> [String: TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return clockOffset
    }

    /// An arrival `host`'s daemon quarantined (as if it had sent a `rejected` frame).
    func recordRejected(host: String, id: String, code: String) {
        lock.lock(); defer { lock.unlock() }
        rejectedLog[host, default: []].append((id, code))
    }

    /// Decides a provisional app-host claim as the authority would (rule 4.6):
    /// `granted` or `refused` once, an `app_host` frame on each of that host's
    /// connections, and a later grant for an ended claim ignored. Returns the
    /// state after the call.
    @discardableResult
    func decideAppHost(_ host: String, _ decision: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let current = registrations[host] ?? "none"
        guard current == "provisional", decision == "granted" || decision == "refused" else {
            if current == "none", decision == "provisional" { registrations[host] = "provisional"; return "provisional" }
            return current
        }
        registrations[host] = decision
        if decision == "granted" { appHost = host }
        for connection in connections.values where connection.host == host && !connection.control && connection.greeted {
            write(["frame": "app_host", "host": host, "registration": decision], to: connection)
        }
        return decision
    }

    // MARK: Section 11's control socket

    /// One operation per harness call. Each daemon applies the part that
    /// concerns it; the harness sends every operation to every daemon.
    private func handleControl(_ line: [String: Any], on connection: Connection) {
        let id = line["id"]
        let params = (line["params"] as? [String: Any]) ?? [:]
        let mine = connection.host
        lock.withLock { controlRequests += 1 }
        var result: [String: Any] = ["applied": true]
        switch (line["method"] as? String) ?? "" {
        case "set_silent":
            if let host = params["host"] as? String { setSilent(host, (params["silent"] as? Bool) ?? false) }
        case "release_late_accepts":
            result = ["released": releaseLateAccepts()]
        case "set_away":
            if let host = params["host"] as? String { setAway(host, (params["away"] as? Bool) ?? false) }
        case "advance_clock":
            advanceClock(by: Double((params["ms"] as? NSNumber)?.intValue ?? 0) / 1000, host: sharesOneWorld ? nil : mine)
        case "reconnect":
            if let a = params["a"] as? String, let b = params["b"] as? String, mine == a || mine == b { reconnect(a, b) }
        case "restart":
            if (params["host"] as? String) == mine { restart(mine) }
        case "quarantined":
            let host = (params["host"] as? String) ?? mine
            let list = lock.withLock { rejectedLog[host] ?? [] }
            result = ["quarantined": list.map { ["id": $0.id, "code": $0.code] }]
        case "is_acknowledged":
            result = ["acknowledged": isAcknowledged((params["id"] as? String) ?? "", by: (params["host"] as? String) ?? mine)]
        case "hold_max_envelopes":
            lock.withLock { holdLimit = (params["n"] as? NSNumber)?.intValue ?? holdLimit }
        case "set_tamper":
            let reverse = (params["body_reverse"] as? Bool) ?? false
            let append = (params["body_append"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            let xor = (params["topic_xor"] as? NSNumber).map { UInt8($0.intValue) }
            var change: (@Sendable (inout Data, inout Data?) -> Void)?
            if !params.isEmpty {
                change = { (body: inout Data, topic: inout Data?) in
                    if reverse { body = Data(body.reversed()) }
                    body.append(append)
                    if let xor { topic = topic.map { Data($0.map { $0 ^ xor }) } }
                }
            }
            let chosen = change
            lock.withLock { tamper = chosen }
        case "set_receiver_refusal":
            lock.withLock { receiverRefusal = params["code"] as? String }
        case "set_app_host_registration":
            let host = (params["host"] as? String) ?? mine
            let state = host == mine ? decideAppHost(host, (params["registration"] as? String) ?? "") : "none"
            result = ["registration": state]
        default:
            lock.withLock {
                write(["id": id ?? NSNull(), "error": ["code": "unknown_method", "message": "unknown control operation"]],
                      to: connection)
            }
            return
        }
        lock.withLock { write(["id": id ?? NSNull(), "result": result], to: connection) }
    }
}

/// RFC 8785 (JCS) for the values an envelope header holds: objects with keys
/// sorted by UTF-16 code units, strings with JSON's minimal escaping, safe
/// integers as decimal digits, booleans and null.
enum JCS {
    static func encode(_ value: Any) -> String {
        switch value {
        case let object as [String: Any]:
            let keys = object.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            return "{" + keys.map { string($0) + ":" + encode(object[$0]!) }.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(encode).joined(separator: ",") + "]"
        case let text as String:
            return string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return String(number.int64Value)
        default:
            return "null"
        }
    }

    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// True when every number in `value` is an integer from -(2^53-1) to 2^53-1.
    static func onlySafeIntegers(_ value: Any) -> Bool {
        switch value {
        case let object as [String: Any]: return object.values.allSatisfy(onlySafeIntegers)
        case let array as [Any]: return array.allSatisfy(onlySafeIntegers)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return true }
            if CFNumberIsFloatType(number) { return false }
            let limit: Int64 = (1 << 53) - 1
            if number.int64Value < 0 { return number.int64Value >= -limit }
            return number.uint64Value <= UInt64(limit)
        default: return true
        }
    }
}

