import Darwin
import Foundation

// C11H-72: `HostTransport` over the Constellation bus, on the bus's
// HostTransport socket protocol version 1 (CBUS-19), bus SPEC 12.5 at
// constellation-bus 521dfb2, and contract A6 with its Amendment 1. The relay
// stays the production transport; this one carries test traffic only until a
// separate go (HostTransportSelection).
//
// Bodies and topics are opaque: they go into the carried envelope and come out
// of it unread. Logs carry ids, byte counts, durations and result codes only.

struct BusHostTransportConfiguration: Sendable {
    /// `$CBUS_HOME/cbus.sock`.
    var socketPath: String
    /// This adapter's own state (A3 `transport/bus/`): the stale-state table.
    var stateDirectory: URL
    /// The c11 session every host of this c11 declares (CBUS-19 rule 2.1).
    var session = "c11h"
    /// True only on the host where c11.app runs; the bus registers it as the
    /// session's app host against its credential (CBUS-19 rule 4.6).
    var appHost = false
    /// `send` and `hold` answer within this (A6: 2 s; CBUS-19 rule 10.3).
    var sendDeadline: TimeInterval = HostTransportBounds.sendDeadline
    var peerPolicy: BusPeerPolicy = .refuseAll
    var client = "c11h"
    var log: @Sendable (String) -> Void = { _ in }
    /// A test-only capture of the wire; nil in production.
    var wireTap: CbusWireTap?
}

final class BusHostTransport: HostTransport, @unchecked Sendable {
    let host: String
    private let configuration: BusHostTransportConfiguration
    private let channel: CbusChannel

    init(host: String, configuration: BusHostTransportConfiguration) {
        self.host = host
        self.configuration = configuration
        channel = CbusChannel(socketPath: configuration.socketPath, host: host, session: configuration.session,
                              appHost: configuration.appHost, client: configuration.client,
                              peerPolicy: configuration.peerPolicy, wireTap: configuration.wireTap)
    }

    deinit { channel.close() }

    func send(_ envelope: HostEnvelope, to host: String) async -> HostTransportResult {
        await carry("send", envelope, to: host)
    }

    func hold(_ envelope: HostEnvelope, for host: String) async -> HostTransportResult {
        await carry("hold", envelope, to: host)
    }

    func receive(from host: String) -> any HostTransportInbox {
        BusInbox(receiver: self.host, from: host, configuration: configuration)
    }

    /// Says `hello` now, without sending anything, so this host's endpoint is
    /// bound in the session (CBUS-19 rules 4.2 and 4.3) before a peer sends to
    /// it; until then a peer's `send` is `unreachable(host_unknown)` (rule 6.2
    /// row 8). True once the daemon has greeted this host.
    func bind() async -> Bool {
        await channel.open(timeout: configuration.sendDeadline)
    }

    /// CBUS-23 rule 4.6: where this host's app-host registration stands, after
    /// a `hello`: `granted`, `provisional`, `refused` or `none`; nil when the
    /// daemon could not be greeted. Only a `granted` app host's forwarded
    /// origins are kept by receivers (rule 5.5).
    func appHostRegistration() async -> String? {
        _ = await bind()
        return channel.appHostRegistration
    }

    /// Waits for the authority's decision on a provisional claim (the `app_host`
    /// frame): the registration once it is `granted` or `refused`, or the last
    /// state seen when `timeout` passes first.
    func awaitAppHostDecision(timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var state = await appHostRegistration()
        while state == "provisional", Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            state = channel.appHostRegistration
        }
        return state
    }

    /// CBUS-19 rule 6.2: the adapter passes the envelope as c11 gave it and
    /// neither normalizes nor pre-refuses; the daemon's admission answers.
    private func carry(_ method: String, _ envelope: HostEnvelope, to peer: String) async -> HostTransportResult {
        let started = Date()
        let result: HostTransportResult
        if let json = CbusWire.envelopeJSON(envelope) {
            let params: [String: Any] = ["to_host": peer, "envelope": String(decoding: json, as: UTF8.self)]
            let deadline = started.addingTimeInterval(configuration.sendDeadline)
            var outcome = await channel.call(method, params, timeout: configuration.sendDeadline)
            // Rules 10.3 and 10.4: within the deadline, resend once with the same
            // envelope after a closed connection, a stopping daemon or a full queue.
            if Self.resendable(outcome), deadline.timeIntervalSinceNow > 0.05 {
                outcome = await channel.call(method, params, timeout: deadline.timeIntervalSinceNow)
            }
            result = Self.result(outcome)
        } else {
            result = .refused(.invalidEnvelope)
        }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        configuration.log("\(method) id=\(envelope.id) peer=\(peer) body_bytes=\(envelope.body.count) "
                          + "result=\(Self.code(result)) ms=\(milliseconds)")
        return result
    }

    // MARK: Results

    static func resendable(_ outcome: CbusCallOutcome) -> Bool {
        switch outcome {
        case .lost: return true
        case .reply(let reply):
            let code = (reply.fields["error"] as? [String: Any])?["code"] as? String
            return code == "daemon_stopping" || code == "too_many_requests"
        default: return false
        }
    }

    /// CBUS-19 rule 10.4. Every `unreachable` says `delivery: unknown`: the bus
    /// answers `delivered`, `away`, `unknown` or `refused` (A6 Amendment 1, D65).
    static func result(_ outcome: CbusCallOutcome) -> HostTransportResult {
        switch outcome {
        case .notSent(let reason): return .unreachable(reason: reason, delivery: .unknown)
        case .lost: return .unreachable(reason: "daemon_closed", delivery: .unknown)
        case .timedOut: return .unreachable(reason: "daemon_timeout", delivery: .unknown)
        case .refused(let refusal): return .refused(refusal)
        case .reply(let reply): return result(response: reply.fields)
        }
    }

    /// Protocol errors that mean the adapter sent something malformed (rule 10.4).
    static let adapterDefect: Set<String> = ["bad_request", "unknown_method", "duplicate_request_id", "bad_frame",
                                             "line_too_long", "hello_repeated"]

    static func result(response fields: [String: Any]) -> HostTransportResult {
        if let error = fields["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "unknown"
            if adapterDefect.contains(code) { return .refused(.protocolError) }
            return .unreachable(reason: code, delivery: .unknown)
        }
        guard let result = fields["result"] as? [String: Any] else {
            return .unreachable(reason: "daemon_reply_unrecognized", delivery: .unknown)
        }
        let since = CbusWire.date(result["since"]) ?? Date()
        switch result["outcome"] as? String {
        case "delivered": return .delivered
        case "held": return .held(since: since)
        case "away": return .away(since: since)
        case "unreachable":
            return .unreachable(reason: (result["reason"] as? String) ?? "unreachable",
                                delivery: (result["delivery"] as? String) == "none" ? .none : .unknown)
        case "refused":
            return .refused(HostTransportRefusal(rawValue: (result["code"] as? String) ?? HostTransportRefusal.invalidEnvelope.rawValue))
        default:
            return .unreachable(reason: "daemon_reply_unrecognized", delivery: .unknown)
        }
    }

    static func code(_ result: HostTransportResult) -> String {
        switch result {
        case .delivered: return "delivered"
        case .held: return "held"
        case .away: return "away"
        case .unreachable(let reason, let delivery): return "unreachable(\(reason),\(delivery.rawValue))"
        case .refused(let refusal): return "refused(\(refusal.rawValue))"
        }
    }
}

/// One sending host's stream on this host (CBUS-19 section 8). It subscribes
/// on first use and again after a reconnect; the daemon then hands every
/// unacknowledged envelope again, in order, before anything newer.
final class BusInbox: HostTransportInbox, @unchecked Sendable {
    private let from: String
    private let configuration: BusHostTransportConfiguration
    private let store: BusStateSeqStore
    private let quarantine: BusQuarantineStore
    private var channel: CbusChannel!

    private let lock = NSLock()
    private var frames: [(generation: Int, fields: [String: Any])] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var subscribed: Int?
    /// Another subscription to this host replaced this one (rule 8.2): it
    /// stays quiet rather than take the stream back.
    private var replaced = false
    /// Chunks of a rejected arrival seen so far, by envelope id (rule 8.8).
    private var rejectedChunks: [String: Int] = [:]
    private var backoff: TimeInterval = 0.25
    private var retryAt = Date.distantPast

    init(receiver: String, from: String, configuration: BusHostTransportConfiguration) {
        self.from = from
        self.configuration = configuration
        // One table per session and attested sending host (CBUS-19 rule 9.1): a
        // record naming another host's panel can never shadow its owner's stream.
        store = BusStateSeqStore.at(configuration.stateDirectory.appendingPathComponent("state-seq", isDirectory: true)
            .appendingPathComponent(configuration.session, isDirectory: true).appendingPathComponent("\(from).json"))
        quarantine = BusQuarantineStore.at(configuration.stateDirectory)
        channel = CbusChannel(socketPath: configuration.socketPath, host: receiver, session: configuration.session,
                              appHost: configuration.appHost, client: configuration.client,
                              peerPolicy: configuration.peerPolicy,
                              onEvent: { [weak self] generation, fields in self?.enqueue(generation, fields) },
                              onDisconnect: { [weak self] in self?.wake() }, wireTap: configuration.wireTap)
    }

    deinit { channel.close() }

    func next(timeout: TimeInterval) async -> HostTransportIncoming? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await subscribe(deadline: deadline), let frame = pop() {
                if let incoming = await process(frame) { return incoming }
                continue
            }
            if Date() >= deadline { return nil }
            await wait(until: deadline)
        }
    }

    func acknowledge(_ id: String) async {
        let outcome = await channel.call("ack", ["ids": [id]], timeout: configuration.sendDeadline)
        if case .reply(let reply) = outcome, let result = reply.fields["result"] as? [String: Any] {
            if let unknown = result["unknown"] as? [String], unknown.contains(id) {
                configuration.log("ack id=\(id) from=\(from) result=unknown")
            }
            return
        }
        // Not recorded: the daemon hands it again, and the consumer acknowledges again.
        configuration.log("ack id=\(id) from=\(from) result=\(BusHostTransport.code(BusHostTransport.result(outcome)))")
    }

    // MARK: Subscription

    /// True once the live connection carries this stream.
    private func subscribe(deadline: Date) async -> Bool {
        let state: (subscribed: Int?, replaced: Bool, retryAt: Date) = lock.withLock { (subscribed, replaced, retryAt) }
        if state.replaced { return false }
        if let live = channel.liveGeneration, live == state.subscribed { return true }
        guard Date() >= state.retryAt else { return false }
        let timeout = min(configuration.sendDeadline, max(0.05, deadline.timeIntervalSinceNow))
        let outcome = await channel.call("receive", ["from_host": from], timeout: timeout)
        if case .refused(.appHostIneligible) = outcome {
            // Final (CBUS-23): this stream never subscribes again.
            lock.withLock { replaced = true }
            configuration.log("receive from=\(from) result=refused(app_host_ineligible)")
            return false
        }
        guard case .reply(let reply) = outcome,
              ((reply.fields["result"] as? [String: Any])?["subscribed"] as? String) == from else {
            lock.withLock {
                retryAt = Date().addingTimeInterval(backoff)
                backoff = min(backoff * 2, 5)
            }
            configuration.log("receive from=\(from) result=\(BusHostTransport.code(BusHostTransport.result(outcome)))")
            return false
        }
        lock.withLock {
            subscribed = reply.generation
            backoff = 0.25
            retryAt = .distantPast
            // Whatever an older connection was handed comes again on this one.
            frames.removeAll { $0.generation != reply.generation }
        }
        return true
    }

    private func enqueue(_ generation: Int, _ fields: [String: Any]) {
        lock.lock()
        frames.append((generation, fields))
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }

    /// The connection dropped: a waiting `next` resubscribes now, not at its deadline.
    private func wake() {
        lock.lock()
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }

    private func pop() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        while let first = frames.first {
            frames.removeFirst()
            if first.generation == subscribed { return first.fields }
        }
        return nil
    }

    /// Sleeps until a frame arrives, the deadline passes, or a reconnect is due.
    private func wait(until deadline: Date) async {
        let wake = min(deadline, max(retryAtValue, Date().addingTimeInterval(0.01)))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !frames.isEmpty { lock.unlock(); continuation.resume(); return }
            waiter?.resume()
            waiter = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, wake.timeIntervalSinceNow)) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let waiting = self.waiter
                self.waiter = nil
                self.lock.unlock()
                waiting?.resume()
            }
        }
    }

    private var retryAtValue: Date {
        lock.lock(); defer { lock.unlock() }
        // A live subscription waits for frames, not for a retry.
        return subscribed != nil && channel.liveGeneration == subscribed ? .distantFuture : retryAt
    }

    // MARK: One frame

    private func process(_ fields: [String: Any]) async -> HostTransportIncoming? {
        guard (fields["from_host"] as? String) == from else { return nil }
        switch fields["frame"] as? String {
        case "envelope":
            return await envelope(fields)
        case "rejected":
            return await rejected(fields)
        case "closed":
            let reason = (fields["reason"] as? String) ?? ""
            configuration.log("receive from=\(from) closed=\(reason)")
            lock.withLock {
                subscribed = nil
                if reason == "replaced" { replaced = true }
            }
            return nil
        default:
            return nil
        }
    }

    private func envelope(_ fields: [String: Any]) async -> HostTransportIncoming? {
        let id = (fields["envelope_id"] as? String) ?? ""
        // Stamps come from the daemon's attested frame (rule 5.3), never from
        // the carried envelope, and must name the stream's own host.
        guard let text = fields["envelope"] as? String,
              let stamps = fields["stamps"] as? [String: Any],
              let origin = stamps["origin_host"] as? String, origin == from,
              let machine = stamps["machine"] as? String, !machine.isEmpty,
              // Rule 5.5: a carried origin counts only on the bus's word that this
              // hop is the session's registered app host, never on adapter config.
              let envelope = CbusWire.hostEnvelope(json: Data(text.utf8), originHost: origin, machine: machine,
                                                   trustCarriedOrigin: (fields["from_app_host"] as? Bool) == true),
              envelope.id == id else {
            return await refuse(id, .invalidEnvelope)
        }
        // Headers and lengths only, never the body or topic.
        if let refusal = HostEnvelopeAdmission.refusal(envelope) { return await refuse(id, refusal) }
        // A6 Amendment 1, after the seal is open: stale state is acknowledged
        // and never handed over. The table is durable before the hand-out.
        guard store.admit(envelope, log: configuration.log) else {
            configuration.log("receive id=\(id) from=\(from) result=stale_state")
            await acknowledge(id)
            return nil
        }
        return .envelope(envelope)
    }

    /// The receiving daemon's checks failed (rule 8.8). The arrival comes as raw
    /// bytes in `chunks` consecutive frames; it is quarantined, reported and
    /// acknowledged once, when the last chunk is in.
    private func rejected(_ fields: [String: Any]) async -> HostTransportIncoming? {
        let id = (fields["envelope_id"] as? String) ?? ""
        let code = HostTransportRefusal(rawValue: (fields["code"] as? String) ?? HostTransportRefusal.invalidEnvelope.rawValue)
        let chunk = (fields["chunk"] as? NSNumber)?.intValue ?? 0
        let chunks = max(1, (fields["chunks"] as? NSNumber)?.intValue ?? 1)
        let complete: Bool = lock.withLock {
            let seen = (rejectedChunks[id] ?? 0) + 1
            guard chunk == seen - 1, seen < chunks else {
                rejectedChunks.removeValue(forKey: id)
                return true
            }
            rejectedChunks[id] = seen
            return false
        }
        guard complete else { return nil }
        return await refuse(id, code)
    }

    /// Quarantined: recorded (id and code, never the bytes), reported once,
    /// acknowledged so it never comes again, never applied.
    private func refuse(_ id: String, _ refusal: HostTransportRefusal) async -> HostTransportIncoming {
        quarantine.record(id: id, code: refusal, from: from)
        configuration.log("receive id=\(id) from=\(from) result=refused(\(refusal.rawValue))")
        if !id.isEmpty { await acknowledge(id) }
        return .refused(id: id, refusal)
    }
}

/// The receiving host's stale-state table (A6 Amendment 1), durable in
/// `transport/bus/state-seq.json`. The rule is part A's `HostStaleStateFilter`;
/// this keeps a copy of what it admitted on disk and replays it into a fresh
/// filter on load, so a restart never forgets a newer write.
final class BusStateSeqStore: @unchecked Sendable {
    private struct Entry: Codable, Hashable {
        let panel: UUID
        let key: String
        let seq: UInt64
        let id: String
    }

    private static let registryLock = NSLock()
    private static var registry: [String: BusStateSeqStore] = [:]

    /// One store per file in this process, shared by every inbox on this host.
    static func at(_ url: URL) -> BusStateSeqStore {
        registryLock.lock(); defer { registryLock.unlock() }
        if let store = registry[url.path] { return store }
        let store = BusStateSeqStore(url: url)
        registry[url.path] = store
        return store
    }

    /// Forgets the in-memory copies under `directory`, as a process restart does.
    static func forget(under directory: URL) {
        registryLock.lock(); defer { registryLock.unlock() }
        let prefix = directory.standardizedFileURL.path
        registry = registry.filter { !URL(fileURLWithPath: $0.key).standardizedFileURL.path.hasPrefix(prefix) }
    }

    private let url: URL
    private let lock = NSLock()
    private var filter = HostStaleStateFilter()
    private var entries: [HostEnvelope.StateHeader.Slot: Entry] = [:]

    private init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for entry in saved {
            let state = HostEnvelope.StateHeader(panel: entry.panel, key: entry.key, seq: entry.seq)
            _ = filter.admit(HostEnvelope(id: entry.id, from: "", to: nil, body: Data(), state: state))
            entries[state.slot] = entry
        }
    }

    /// True when `envelope` may be handed over. A state envelope that is
    /// admitted is written to disk before this returns.
    func admit(_ envelope: HostEnvelope, log: (String) -> Void = { _ in }) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard filter.admit(envelope) else { return false }
        guard let state = envelope.state else { return true }
        entries[state.slot] = Entry(panel: state.panel, key: state.key, seq: state.seq, id: envelope.id)
        if !persist() {
            // The consumer applies the same rule in its own atomic write (A6),
            // so a lost table never lets an older write undo a newer one.
            log("state_seq persist_failed id=\(envelope.id)")
        }
        return true
    }

    private func persist() -> Bool {
        let sorted = entries.values.sorted { ($0.panel.uuidString, $0.key) < ($1.panel.uuidString, $1.key) }
        guard let data = try? JSONEncoder().encode(sorted) else { return false }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
        let synced = fsync(fd) == 0
        Darwin.close(fd)
        guard written == data.count, synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }
}

/// What this host quarantined on arrival (A6: kept, reported, never applied),
/// durable in `transport/bus/quarantine.jsonl`. It records the id, the code and
/// the sending host only: the transport never stores a body.
final class BusQuarantineStore: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        let id: String
        let code: String
        let from: String
    }

    private static let registryLock = NSLock()
    private static var registry: [String: BusQuarantineStore] = [:]

    static func at(_ directory: URL) -> BusQuarantineStore {
        let url = directory.appendingPathComponent("quarantine.jsonl")
        registryLock.lock(); defer { registryLock.unlock() }
        if let store = registry[url.path] { return store }
        let store = BusQuarantineStore(url: url)
        registry[url.path] = store
        return store
    }

    private let url: URL
    private let lock = NSLock()

    private init(url: URL) { self.url = url }

    func record(id: String, code: HostTransportRefusal, from: String) {
        guard let line = try? JSONEncoder().encode(Entry(id: id, code: code.rawValue, from: from)) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        var data = line
        data.append(0x0A)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
        Darwin.close(fd)
    }

    /// Every entry on disk, in order, one per id.
    func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var seen: Set<String> = []
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
            .filter { seen.insert($0.id).inserted }
    }
}
