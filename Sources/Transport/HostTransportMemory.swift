import Foundation

// C11H-71 part A: the in-memory reference implementation of `HostTransport`.
// It defines the contract's behavior executably, it runs the T1-T9
// conformance suite, and it is the fake every consumer's tests run against
// with no relay present (T7). The network's state stands in for each side's
// durable storage, so an endpoint "restart" keeps everything that was durable.

final class HostTransportMemoryNetwork: @unchecked Sendable {
    private struct Lane: Hashable { let from: String; let to: String }
    private struct Queue {
        /// Accepted by the receiving side and not yet acknowledged, in order.
        var pending: [HostEnvelope] = []
        /// How many of `pending` this connection has handed out.
        var handed = 0
        /// Kept by the sender for a receiver that is away.
        var held: [HostEnvelope] = []
    }
    /// A send to a silent peer, parked until the test releases a late accept.
    private struct Parked { let envelope: HostEnvelope; let from: String; let to: String }
    /// One quarantined arrival (A6: an invalid arrival is kept, never applied).
    struct Quarantined: Equatable { let id: String; let code: HostTransportRefusal; let envelope: HostEnvelope }

    private let lock = NSLock()
    private var queues: [Lane: Queue] = [:]
    private var acknowledged: [String: [String: Date]] = [:] // receiver -> id -> when
    /// A6 Amendment 1: each receiver's stale-state check (durable here).
    private var staleState: [String: HostStaleStateFilter] = [:]
    private var quarantine: [String: [Quarantined]] = [:]  // receiver -> rejected arrivals
    private var awaySince: [String: Date] = [:]
    private var silentHosts: Set<String> = []
    private var parked: [Parked] = []

    // Fault and policy controls for the conformance suite and consumer tests.
    /// How long `send` waits for a silent peer.
    var sendDeadline: TimeInterval
    /// True: a timed-out send is cancelled and answers `delivery: none`, and a
    /// later accept of it loses the race. False: models an implementation that
    /// cannot cancel (`unknown`): a later accept applies it, once.
    var cancelsAtDeadline = true
    /// Changes body or topic bytes in transit (T8). Routing fields are not
    /// passed to it.
    var tamper: (@Sendable (inout Data, inout Data?) -> Void)?
    /// The receiving side's identity or policy check, after admission.
    var admit: @Sendable (HostEnvelope, _ to: String) -> HostTransportRefusal? = { _, _ in nil }
    var holdLimit = HostTransportBounds.maximumHeldEnvelopes
    /// The relay stamps `relay: true`; the reference implementation does not.
    var stampsRelay = false
    private let baseClock: @Sendable () -> Date
    private var clockOffset: TimeInterval = 0

    init(sendDeadline: TimeInterval = HostTransportBounds.sendDeadline,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.sendDeadline = min(sendDeadline, HostTransportBounds.sendDeadline)
        self.baseClock = clock
    }

    private func now() -> Date { baseClock().addingTimeInterval(clockOffset) }

    func endpoint(_ host: String) -> HostTransportMemory { HostTransportMemory(host: host, network: self) }

    // MARK: Link, process and time faults

    /// A host whose link is down. On return, what others held for it is
    /// delivered first, in order, before anything sent after the return.
    func setAway(_ host: String, _ away: Bool) {
        lock.lock(); defer { lock.unlock() }
        if away {
            if awaySince[host] == nil { awaySince[host] = now() }
            for lane in queues.keys where lane.to == host || lane.from == host { queues[lane]?.handed = 0 }
            return
        }
        awaySince[host] = nil
        for lane in queues.keys where lane.to == host || lane.from == host {
            guard var queue = queues[lane], awaySince[lane.from] == nil, awaySince[lane.to] == nil else { continue }
            for envelope in queue.held { appendLocked(envelope, to: &queue, receiver: lane.to) }
            queue.held = []
            queues[lane] = queue
        }
    }

    /// A peer that answers nothing within any deadline. Its sends are parked;
    /// `releaseLateAccepts` lets the peer try to accept them later.
    func setSilent(_ host: String, _ silent: Bool) {
        lock.lock(); defer { lock.unlock() }
        if silent { silentHosts.insert(host) } else { silentHosts.remove(host) }
    }

    /// The silent peer now accepts every parked send. Returns how many it
    /// attempted. A cancelling implementation already won each race, so none
    /// is applied; one that cannot cancel applies each, once (ids dedupe), and
    /// through the same receive path as any arrival (stale state is dropped).
    @discardableResult
    func releaseLateAccepts() -> Int {
        lock.lock()
        let released = parked
        parked = []
        lock.unlock()
        for late in released where !cancelsAtDeadline {
            _ = accept(late.envelope, from: late.from, to: late.to)
        }
        return released.count
    }

    /// The connection between two hosts drops and comes back: unacknowledged
    /// envelopes are handed out again, in order.
    func reconnect(_ a: String, _ b: String) {
        lock.lock(); defer { lock.unlock() }
        queues[Lane(from: a, to: b)]?.handed = 0
        queues[Lane(from: b, to: a)]?.handed = 0
    }

    /// A host's process restarts. Durable state (pending, held, acknowledged,
    /// quarantine, stale-state) survives; nothing in flight does.
    func restart(_ host: String) {
        lock.lock(); defer { lock.unlock() }
        for lane in queues.keys where lane.to == host || lane.from == host { queues[lane]?.handed = 0 }
    }

    /// Moves this network's clock (acknowledged-id retention).
    func advanceClock(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        clockOffset += seconds
    }

    // MARK: Observations

    func heldCount(from: String, for host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return queues[Lane(from: from, to: host)]?.held.count ?? 0
    }

    /// What `host` quarantined on arrival.
    func quarantined(by host: String) -> [Quarantined] {
        lock.lock(); defer { lock.unlock() }
        return quarantine[host] ?? []
    }

    /// Whether `host` holds an acknowledgement for `id` within the retention.
    func isAcknowledged(_ id: String, by host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return acknowledgedLocked(id, by: host)
    }

    // MARK: Operations (called by the endpoint)

    fileprivate func send(_ envelope: HostEnvelope, from: String, to: String) async -> HostTransportResult {
        if let refusal = HostEnvelopeAdmission.refusal(envelope) { return .refused(refusal) }
        lock.lock()
        if let since = awaySince[to] ?? awaySince[from] { lock.unlock(); return .away(since: since) }
        if silentHosts.contains(to) {
            parked.append(Parked(envelope: envelope, from: from, to: to))
            lock.unlock()
            try? await Task.sleep(nanoseconds: UInt64(sendDeadline * 1_000_000_000))
            // The claim/cancel race is decided here: a cancelling
            // implementation's late accept always loses.
            return .unreachable(reason: "no answer within \(sendDeadline) s", delivery: cancelsAtDeadline ? .none : .unknown)
        }
        lock.unlock()
        return accept(envelope, from: from, to: to)
    }

    fileprivate func hold(_ envelope: HostEnvelope, from: String, for to: String) -> HostTransportResult {
        if let refusal = HostEnvelopeAdmission.refusal(envelope) { return .refused(refusal) }
        lock.lock()
        guard let since = awaySince[to] ?? awaySince[from] else { lock.unlock(); return accept(envelope, from: from, to: to) }
        let lane = Lane(from: from, to: to)
        var queue = queues[lane] ?? Queue()
        // A retry of an id this side already keeps (or the peer already has)
        // is that same envelope: never refused, never charged twice.
        if queue.held.contains(where: { $0.id == envelope.id }) { lock.unlock(); return .held(since: since) }
        if queue.pending.contains(where: { $0.id == envelope.id }) || acknowledgedLocked(envelope.id, by: to) {
            lock.unlock(); return .delivered
        }
        guard queue.held.count < holdLimit,
              queue.held.reduce(envelope.body.count, { $0 + $1.body.count }) <= HostTransportBounds.maximumHeldBytes else {
            lock.unlock(); return .refused(.holdFull)
        }
        queue.held.append(stamped(envelope, from: from))
        queues[lane] = queue
        lock.unlock()
        return .held(since: since)
    }

    @discardableResult
    private func accept(_ envelope: HostEnvelope, from: String, to: String) -> HostTransportResult {
        if let refusal = admit(envelope, to) { return .refused(refusal) }
        lock.lock(); defer { lock.unlock() }
        let lane = Lane(from: from, to: to)
        var queue = queues[lane] ?? Queue()
        appendLocked(stamped(envelope, from: from), to: &queue, receiver: to)
        queues[lane] = queue
        return .delivered
    }

    /// Deduped by `id`: one already pending, or acknowledged within the
    /// retention, is not added again.
    private func appendLocked(_ envelope: HostEnvelope, to queue: inout Queue, receiver: String) {
        guard !acknowledgedLocked(envelope.id, by: receiver),
              !queue.pending.contains(where: { $0.id == envelope.id }) else { return }
        queue.pending.append(envelope)
    }

    private func acknowledgedLocked(_ id: String, by host: String) -> Bool {
        guard let when = acknowledged[host]?[id] else { return false }
        return now().timeIntervalSince(when) < HostTransportBounds.acknowledgedRetention
    }

    /// The origin is set where the envelope first entered a transport; a hop
    /// that forwards an already-carried envelope keeps it (A8).
    private func stamped(_ envelope: HostEnvelope, from: String) -> HostEnvelope {
        var copy = envelope
        if copy.stamps["origin_host"] == nil {
            copy.stamps["origin_host"] = from
            copy.stamps["machine"] = from
        }
        if stampsRelay { copy.stamps["relay"] = "true" } else { copy.stamps.removeValue(forKey: "relay") }
        return copy
    }

    fileprivate func nextIncoming(from: String, to: String) -> HostTransportIncoming? {
        lock.lock(); defer { lock.unlock() }
        return nextIncomingLocked(from: from, to: to)
    }

    private func nextIncomingLocked(from: String, to: String) -> HostTransportIncoming? {
        guard awaySince[from] == nil, awaySince[to] == nil else { return nil }
        let lane = Lane(from: from, to: to)
        guard var queue = queues[lane], queue.handed < queue.pending.count else { return nil }
        var envelope = queue.pending[queue.handed]
        if let tamper {
            // In transit: only the opaque bytes are touched.
            var body = envelope.body, topic = envelope.topic
            tamper(&body, &topic)
            envelope = envelope.replacingOpaque(body: body, topic: topic, bodyOverhead: envelope.bodyOverhead)
        }
        // Receive-side validation: headers and lengths only. An invalid
        // arrival is quarantined (kept, never applied) and reported.
        if let refusal = HostEnvelopeAdmission.refusal(envelope) {
            queue.pending.remove(at: queue.handed)
            queues[lane] = queue
            quarantine[to, default: []].append(Quarantined(id: envelope.id, code: refusal, envelope: envelope))
            return .refused(id: envelope.id, refusal)
        }
        // A6 Amendment 1: stale state is acknowledged and never handed over.
        var filter = staleState[to] ?? HostStaleStateFilter()
        guard filter.admit(envelope) else {
            staleState[to] = filter
            queue.pending.remove(at: queue.handed)
            queues[lane] = queue
            acknowledged[to, default: [:]][envelope.id] = now()
            return nextIncomingLocked(from: from, to: to)
        }
        staleState[to] = filter
        queue.handed += 1
        queues[lane] = queue
        return .envelope(envelope)
    }

    fileprivate func acknowledge(_ id: String, from: String, to: String) {
        lock.lock(); defer { lock.unlock() }
        let at = now()
        acknowledged[to, default: [:]][id] = at
        acknowledged[to] = acknowledged[to]?.filter { at.timeIntervalSince($0.value) < HostTransportBounds.acknowledgedRetention }
        let lane = Lane(from: from, to: to)
        guard var queue = queues[lane], let index = queue.pending.firstIndex(where: { $0.id == id }) else { return }
        queue.pending.remove(at: index)
        if index < queue.handed { queue.handed -= 1 }
        queues[lane] = queue
    }
}

/// One host's endpoint on a `HostTransportMemoryNetwork`.
final class HostTransportMemory: HostTransport, @unchecked Sendable {
    let host: String
    private let network: HostTransportMemoryNetwork

    init(host: String, network: HostTransportMemoryNetwork) {
        self.host = host
        self.network = network
    }

    func send(_ envelope: HostEnvelope, to host: String) async -> HostTransportResult {
        await network.send(envelope, from: self.host, to: host)
    }

    func hold(_ envelope: HostEnvelope, for host: String) async -> HostTransportResult {
        network.hold(envelope, from: self.host, for: host)
    }

    func receive(from host: String) -> any HostTransportInbox {
        HostTransportMemoryInbox(network: network, from: host, to: self.host)
    }
}

private final class HostTransportMemoryInbox: HostTransportInbox, @unchecked Sendable {
    private let network: HostTransportMemoryNetwork
    private let from: String
    private let to: String

    init(network: HostTransportMemoryNetwork, from: String, to: String) {
        self.network = network
        self.from = from
        self.to = to
    }

    func next(timeout: TimeInterval) async -> HostTransportIncoming? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let incoming = network.nextIncoming(from: from, to: to) { return incoming }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func acknowledge(_ id: String) async {
        network.acknowledge(id, from: from, to: to)
    }
}
