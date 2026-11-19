import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11H-72 (Orchestrator 23:16): part A's T1-T9 suite on the RELAY, before
// C11H-71 part C makes the relay a `HostTransport`. This is a thin, test-only
// adapter, never production, and part C's real implementation replaces it.
//
// What is the relay's own code here: the sending side is `C11RelayClient`
// unchanged, so request slots, the compare-and-set claim/cancel race (the
// source of `delivery: none`), the heartbeat document that tells a down link
// from a silent one, and the spool (what `hold` keeps while a host is away)
// all run as shipped, against an in-memory hc document store with hc's
// compare-and-set rule. What is the test's: the claiming side (a small pump
// standing in for `C11RelayService`, which only runs socket commands today)
// and the receiving queue with its acknowledgements.
//
// No hc core, no live c11 session, no real mail: every document lives in this
// process and every envelope is test traffic.

/// hc's per-core document store, in memory: `set` succeeds only at the
/// current version, as hc's compare-and-set does.
final class RelayMemoryDocStore: C11RelayDocStore, @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [String: (value: Any?, version: UInt64)] = [:]

    func get(_ name: String) throws -> (value: Any?, version: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return documents[name] ?? (nil, 0)
    }

    func set(_ name: String, value: Any?, version: UInt64) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let current = documents[name]?.version ?? 0
        guard version == current else { throw C11RelayStoreError.conflict }
        documents[name] = (value, current + 1)
        return current + 1
    }
}

final class RelayTestNetwork: @unchecked Sendable {
    /// C11H-176: every test host signs with one credential; this stand-in
    /// for the service signs its replies with it (it checks no requests).
    static let credential = C11RelayAuth.Credential(linkID: "0011223344556677", creation: UUID(),
                                                     key: Data(repeating: 9, count: 32))
    struct Lane: Hashable { let from: String; let to: String }
    private struct Queue { var pending: [HostEnvelope] = []; var handed = 0 }

    static let method = "c11.transport.carry"

    private let lock = NSLock()
    private var stores: [Lane: RelayMemoryDocStore] = [:]
    private var queues: [Lane: Queue] = [:]
    /// Receiver -> id -> when it was acknowledged, on the network's clock.
    private var acknowledged: [String: [String: Date]] = [:]
    private var quarantine: [String: [(id: String, code: HostTransportRefusal)]] = [:]
    private var clockOffset: TimeInterval = 0
    private var now: Date { Date().addingTimeInterval(clockOffset) }
    /// Requests a silent peer saw and did not claim: (lane, slot, version, request).
    private var parked: [(lane: Lane, slot: String, version: UInt64, request: C11Relay.Request)] = []
    /// The app host: the only hop whose carried origin is kept (A8).
    static let appHostName = "laptop"
    private var staleState: [String: HostStaleStateFilter] = [:]
    private var awaySince: [String: Date] = [:]
    private var linkDownAt: [Lane: Int64] = [:]
    private var linkUpAt: [Lane: Int64] = [:]
    private var silent: Set<String> = []
    private var running = true
    /// Runs once on the pump thread at the start of the next slot scan.
    private var slotScanGate: (() -> Void)?

    /// The relay's claim bound, at the bottom of its allowed range.
    let claimMilliseconds = C11Relay.claimMillisecondsRange.lowerBound
    var tamper: (@Sendable (inout Data, inout Data?) -> Void)?
    var receiverRefusal: HostTransportRefusal?
    var holdLimit = HostTransportBounds.maximumHeldEnvelopes

    init() {
        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                autoreleasepool { self.pumpAll() }
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        thread.name = "relay.test.pump"
        thread.start()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func stop() { lock.lock(); running = false; lock.unlock() }

    /// The document store on `from`'s core that `to`'s side watches.
    func store(from: String, to: String) -> RelayMemoryDocStore {
        lock.lock(); defer { lock.unlock() }
        return storeLocked(Lane(from: from, to: to))
    }

    private func storeLocked(_ lane: Lane) -> RelayMemoryDocStore {
        if let store = stores[lane] { return store }
        let store = RelayMemoryDocStore()
        stores[lane] = store
        // A lane first used while one end is away starts with its link down.
        if isDownLocked(lane) { linkDownAt[lane] = Self.wallMilliseconds() }
        writeHeartbeatLocked(lane)
        return store
    }

    // MARK: Faults

    func setAway(_ host: String, _ away: Bool) {
        lock.lock(); defer { lock.unlock() }
        if away { if awaySince[host] == nil { awaySince[host] = Date() } } else { awaySince[host] = nil }
        let now = Self.wallMilliseconds()
        for lane in stores.keys where lane.from == host || lane.to == host {
            // Each edge is later than the last, even within one millisecond.
            let last = max(linkDownAt[lane] ?? 0, linkUpAt[lane] ?? 0)
            if isDownLocked(lane) { linkDownAt[lane] = max(now, last + 1) } else { linkUpAt[lane] = max(now, last + 1) }
            writeHeartbeatLocked(lane)
        }
    }

    func setSilent(_ host: String, _ isSilent: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isSilent { silent.insert(host) } else { silent.remove(host) }
    }

    /// The silent peer now tries to claim every request it saw, at the version
    /// it saw: the compare-and-set loses to the client's cancel, so nothing a
    /// caller was told `none` about ever runs. Returns how many it attempted.
    func releaseLateAccepts() -> Int {
        lock.lock()
        let attempts = parked
        parked = []
        let lanes = stores
        lock.unlock()
        for attempt in attempts {
            guard let store = lanes[attempt.lane],
                  let claimed = try? store.set(attempt.slot, value: C11Relay.claimedValue(attempt.request),
                                               version: attempt.version) else { continue }
            let outcome = apply(attempt.request.line, lane: attempt.lane, store: store).map {
                C11Relay.refusedValue(attempt.request, code: $0.rawValue, message: "", key: RelayTestNetwork.credential.key)
            } ?? C11Relay.doneValue(attempt.request, response: "{\"ok\":true}", key: RelayTestNetwork.credential.key)
            _ = try? store.set(attempt.slot, value: outcome, version: claimed)
        }
        return attempts.count
    }

    /// How many requests the silent peer has parked, without releasing them.
    var parkedCount: Int { lock.lock(); defer { lock.unlock() }; return parked.count }

    /// Holds the pump's next slot scan in `gate`, which runs on the pump thread.
    func holdNextSlotScan(_ gate: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        slotScanGate = gate
    }

    func advanceClock(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        clockOffset += seconds
    }

    func isAcknowledged(_ id: String, by host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isAcknowledgedLocked(id, by: host)
    }

    private func isAcknowledgedLocked(_ id: String, by host: String) -> Bool {
        guard let at = acknowledged[host]?[id] else { return false }
        return now.timeIntervalSince(at) < HostTransportBounds.acknowledgedRetention
    }

    func quarantined(by host: String) -> [(id: String, code: HostTransportRefusal)] {
        lock.lock(); defer { lock.unlock() }
        return quarantine[host] ?? []
    }

    func reconnect(_ a: String, _ b: String) {
        lock.lock(); defer { lock.unlock() }
        queues[Lane(from: a, to: b)]?.handed = 0
        queues[Lane(from: b, to: a)]?.handed = 0
    }

    /// Durable state (documents, queues, acknowledgements) survives.
    func restart(_ host: String) {
        lock.lock(); defer { lock.unlock() }
        for lane in queues.keys where lane.from == host || lane.to == host { queues[lane]?.handed = 0 }
    }

    private func isDownLocked(_ lane: Lane) -> Bool { awaySince[lane.from] != nil || awaySince[lane.to] != nil }

    /// c11's real heartbeat document (`c11h.relay.seen`), with when the link
    /// last went down and came back.
    private func writeHeartbeatLocked(_ lane: Lane) {
        guard let store = stores[lane] else { return }
        let value = C11Relay.seenValue(at: Self.wallMilliseconds(), upAt: linkUpAt[lane], downAt: linkDownAt[lane])
        for _ in 0..<4 {
            guard let current = try? store.get(C11Relay.seenName) else { return }
            if (try? store.set(C11Relay.seenName, value: value, version: current.version)) != nil { return }
        }
    }

    static func wallMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// When the link to `lane.to` went down, from the heartbeat document as
    /// the relay CLI reads it; nil while it is up.
    func linkDownSince(_ store: RelayMemoryDocStore) -> Date? {
        guard let object = (try? store.get(C11Relay.seenName))?.value as? [String: Any],
              let down = (object["down_at"] as? NSNumber)?.int64Value else { return nil }
        let up = (object["up_at"] as? NSNumber)?.int64Value ?? Int64.min
        return down > up ? Date(timeIntervalSince1970: Double(down) / 1000) : nil
    }

    // MARK: The claiming side (stands in for C11RelayService)

    private func pumpAll() {
        lock.lock()
        let lanes = stores.filter { !isDownLocked($0.key) }
        lock.unlock()
        for (lane, store) in lanes { pump(lane, store) }
    }

    private func pump(_ lane: Lane, _ store: RelayMemoryDocStore) {
        // The spool first: what was held arrives before anything sent after the return.
        if let spool = try? store.get(C11Relay.spoolName) {
            let records = C11Relay.spoolRecords(spool.value)
            if !records.isEmpty, (try? store.set(C11Relay.spoolName, value: C11Relay.emptySpool, version: spool.version)) != nil {
                for record in records { _ = apply(record.line, lane: lane, store: store) }
            }
        }
        lock.lock()
        let gate = slotScanGate
        slotScanGate = nil
        lock.unlock()
        gate?()
        for slot in 0..<C11Relay.slotCount {
            let name = C11Relay.slotName(slot)
            guard let (value, version) = try? store.get(name), let request = C11Relay.Request(value) else { continue }
            // Silence is read after the request, never once per scan: a request
            // written after the peer stopped being silent was never seen while
            // it was silent, however long this scan was descheduled (C11H-346).
            lock.lock()
            let isSilent = silent.contains(lane.to)
            if isSilent, !parked.contains(where: { $0.request.id == request.id }) {
                // A silent peer sees the request and does not claim it in time.
                parked.append((lane, name, version, request))
            }
            lock.unlock()
            if isSilent { continue }
            guard let claimed = try? store.set(name, value: C11Relay.claimedValue(request), version: version) else { continue }
            let outcome: [String: Any]
            if let refusal = apply(request.line, lane: lane, store: store) {
                outcome = C11Relay.refusedValue(request, code: refusal.rawValue, message: "", key: RelayTestNetwork.credential.key)
            } else {
                outcome = C11Relay.doneValue(request, response: "{\"ok\":true}", key: RelayTestNetwork.credential.key)
            }
            _ = try? store.set(name, value: outcome, version: claimed)
        }
    }

    /// Accepts one carried envelope into the receiving host's durable queue,
    /// deduped by id, or answers the receiver's refusal.
    private func apply(_ line: String, lane: Lane, store: RelayMemoryDocStore) -> HostTransportRefusal? {
        guard let envelope = Self.envelope(line, origin: lane.from, store: store) else { return .invalidEnvelope }
        lock.lock(); defer { lock.unlock() }
        if let receiverRefusal { return receiverRefusal }
        var queue = queues[lane] ?? Queue()
        if !isAcknowledgedLocked(envelope.id, by: lane.to), !queue.pending.contains(where: { $0.id == envelope.id }) {
            queue.pending.append(envelope)
        }
        queues[lane] = queue
        return nil
    }

    /// The envelope travels in its own hc document, and the request line (or
    /// spool record) names it. The relay's request line is bounded at
    /// `C11Relay.maxLineBytes` (64 KiB), below A6 Amendment 2's 65,536-byte
    /// envelope plus any wrapper, so the wrapper stays outside the bound: the
    /// size check is #155's own `HostEnvelopeAdmission`, on the original envelope.
    static func park(_ envelope: HostEnvelope, in store: RelayMemoryDocStore) -> String? {
        guard let json = CbusWire.envelopeJSON(envelope) else { return nil }
        let name = "c11.transport.env.\(UUID().uuidString)"
        guard (try? store.set(name, value: String(decoding: json, as: UTF8.self), version: 0)) != nil else { return nil }
        let object: [String: Any] = ["method": method, "params": ["doc": name]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func envelope(_ line: String, origin: String, store: RelayMemoryDocStore) -> HostEnvelope? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["method"] as? String == method, let params = object["params"] as? [String: Any],
              let name = params["doc"] as? String, let text = (try? store.get(name))?.value as? String,
              var envelope = CbusWire.hostEnvelope(json: Data(text.utf8), originHost: origin, machine: origin,
                                                   trustCarriedOrigin: origin == appHostName) else { return nil }
        envelope.stamps["relay"] = "true"
        return envelope
    }

    // MARK: Receiving (the test's queue)

    func nextIncoming(from: String, to: String) -> HostTransportIncoming? {
        lock.lock(); defer { lock.unlock() }
        let lane = Lane(from: from, to: to)
        while true {
            guard !isDownLocked(lane), var queue = queues[lane], queue.handed < queue.pending.count else { return nil }
            var envelope = queue.pending[queue.handed]
            if let tamper {
                var body = envelope.body, topic = envelope.topic
                tamper(&body, &topic)
                envelope = envelope.replacingOpaque(body: body, topic: topic, bodyOverhead: envelope.bodyOverhead)
            }
            if let refusal = HostEnvelopeAdmission.refusal(envelope) {
                // Quarantined (kept, never applied), and never handed again.
                queue.pending.remove(at: queue.handed)
                queues[lane] = queue
                quarantine[to, default: []].append((envelope.id, refusal))
                acknowledged[to, default: [:]][envelope.id] = now
                return .refused(id: envelope.id, refusal)
            }
            var filter = staleState[to] ?? HostStaleStateFilter()
            let admitted = filter.admit(envelope)
            staleState[to] = filter
            guard admitted else {
                queue.pending.remove(at: queue.handed)
                queues[lane] = queue
                acknowledged[to, default: [:]][envelope.id] = now
                continue
            }
            queue.handed += 1
            queues[lane] = queue
            return .envelope(envelope)
        }
    }

    func acknowledge(_ id: String, from: String, to: String) {
        lock.lock(); defer { lock.unlock() }
        acknowledged[to, default: [:]][id] = now
        let lane = Lane(from: from, to: to)
        guard var queue = queues[lane], let index = queue.pending.firstIndex(where: { $0.id == id }) else { return }
        queue.pending.remove(at: index)
        if index < queue.handed { queue.handed -= 1 }
        queues[lane] = queue
    }

    func heldCount(_ store: RelayMemoryDocStore) -> Int {
        C11Relay.spoolRecords((try? store.get(C11Relay.spoolName))?.value).count
    }

    /// Whether the spool already holds this envelope id (a retry of a held id).
    func isHeld(_ id: String, in store: RelayMemoryDocStore) -> Bool {
        C11Relay.spoolRecords((try? store.get(C11Relay.spoolName))?.value)
            .contains { Self.envelope($0.line, origin: "", store: store)?.id == id }
    }
}

/// One host's endpoint: `send` and `hold` run the relay's own client.
final class RelayTestHostTransport: HostTransport, @unchecked Sendable {
    let host: String
    private let network: RelayTestNetwork
    private let caller = C11RelayClient.Caller(panel: UUID().uuidString, workspace: nil, term: "c11-transport-test",
                                                credential: RelayTestNetwork.credential)

    init(host: String, network: RelayTestNetwork) {
        self.host = host
        self.network = network
    }

    private func client(_ store: RelayMemoryDocStore) -> C11RelayClient {
        C11RelayClient(store: store, caller: caller, claimMilliseconds: network.claimMilliseconds,
                        sleep: { Thread.sleep(forTimeInterval: min($0, 0.0005)) })
    }

    private func blocking<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    func send(_ envelope: HostEnvelope, to host: String) async -> HostTransportResult {
        if let refusal = HostEnvelopeAdmission.refusal(envelope) { return .refused(refusal) }
        let store = network.store(from: self.host, to: host)
        if let since = network.linkDownSince(store) { return .away(since: since) }
        guard let line = RelayTestNetwork.park(envelope, in: store) else { return .refused(.invalidEnvelope) }
        let relayClient = client(store)
        return await blocking {
            do {
                _ = try relayClient.call(line: line, framing: .json, timeout: 1)
                return .delivered
            } catch let error as C11RelayCallError {
                return Self.result(error)
            } catch {
                return .unreachable(reason: "relay_unavailable", delivery: .none)
            }
        }
    }

    func hold(_ envelope: HostEnvelope, for host: String) async -> HostTransportResult {
        if let refusal = HostEnvelopeAdmission.refusal(envelope) { return .refused(refusal) }
        let store = network.store(from: self.host, to: host)
        guard let since = network.linkDownSince(store) else { return await send(envelope, to: host) }
        if network.isHeld(envelope.id, in: store) { return .held(since: since) }
        guard network.heldCount(store) < network.holdLimit else { return .refused(.holdFull) }
        guard let line = RelayTestNetwork.park(envelope, in: store) else { return .refused(.invalidEnvelope) }
        let relayClient = client(store)
        let request = C11Relay.Request(id: UUID().uuidString, at: RelayTestNetwork.wallMilliseconds(), panel: caller.panel,
                                        workspace: nil, term: caller.term, framing: .json,
                                        line: line, timeoutMilliseconds: 10_000).signed(with: RelayTestNetwork.credential)
        let spooled = await blocking { (try? relayClient.spool(C11Relay.SpoolRecord(request))) ?? false }
        return spooled ? .held(since: since) : .refused(.holdFull)
    }

    func receive(from host: String) -> any HostTransportInbox {
        RelayTestInbox(network: network, from: host, to: self.host)
    }

    /// The relay client's errors as A6 results. `unreachable` means the cancel
    /// won the compare-and-set, so nothing will ever run: `delivery: none`.
    static func result(_ error: C11RelayCallError) -> HostTransportResult {
        switch error {
        case .unreachable: return .unreachable(reason: "relay_unreachable", delivery: .none)
        case .busy: return .unreachable(reason: "relay_busy", delivery: .none)
        case .store(let detail): return .unreachable(reason: "relay_unavailable: \(detail)", delivery: .none)
        case .outcomeUnknown: return .unreachable(reason: "relay_outcome_unknown", delivery: .unknown)
        case .replyUnverified: return .unreachable(reason: "relay_reply_unverified", delivery: .unknown)
        case .tooLarge: return .refused(.envelopeTooLarge)
        case .refused(let code, _): return .refused(HostTransportRefusal(rawValue: code))
        }
    }
}

private final class RelayTestInbox: HostTransportInbox, @unchecked Sendable {
    private let network: RelayTestNetwork
    private let from: String
    private let to: String

    init(network: RelayTestNetwork, from: String, to: String) {
        self.network = network
        self.from = from
        self.to = to
    }

    func next(timeout: TimeInterval) async -> HostTransportIncoming? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let incoming = network.nextIncoming(from: from, to: to) { return incoming }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func acknowledge(_ id: String) async { network.acknowledge(id, from: from, to: to) }
}

final class RelayHostTransportHarness: HostTransportHarness {
    let network = RelayTestNetwork()
    deinit { network.stop() }
    func endpoint(_ host: String) -> any HostTransport { RelayTestHostTransport(host: host, network: network) }
    func setAway(_ host: String, _ away: Bool) { network.setAway(host, away) }
    func setSilent(_ host: String, _ silent: Bool) { network.setSilent(host, silent) }
    func releaseLateAccepts() -> Int { network.releaseLateAccepts() }
    func quarantined(by host: String) -> [(id: String, code: HostTransportRefusal)] { network.quarantined(by: host) }
    func isAcknowledged(_ id: String, by host: String) -> Bool { network.isAcknowledged(id, by: host) }
    func advanceClock(by seconds: TimeInterval) { network.advanceClock(by: seconds) }
    func reconnect(_ a: String, _ b: String) { network.reconnect(a, b) }
    func restart(_ host: String) { network.restart(host) }
    func setTamper(_ tamper: (@Sendable (inout Data, inout Data?) -> Void)?) { network.tamper = tamper }
    func setReceiverRefusal(_ refusal: HostTransportRefusal?) { network.receiverRefusal = refusal }
    func setHoldLimit(_ limit: Int) { network.holdLimit = limit }
    var sendDeadline: TimeInterval { Double(network.claimMilliseconds) / 1000 }
    /// The relay cancels at its claim deadline by compare-and-set.
    var timeoutDelivery: HostTransportDelivery { .none }
    var stampsRelay: Bool { true }
}

/// Part A's T1-T9, unchanged, on the relay's own client.
final class RelayHostTransportConformanceTests: HostTransportConformanceSuite {
    override func makeHarness() -> HostTransportHarness? { RelayHostTransportHarness() }
}

/// The same suite with every body and topic sealed by the endpoints (T8).
final class RelayHostTransportSealedConformanceTests: HostTransportConformanceSuite {
    override func makeHarness() -> HostTransportHarness? { HostTransportSealedHarness(RelayHostTransportHarness()) }
}

/// C11H-346: the relay fake's silent peer on its own.
final class RelayTestNetworkSilenceTests: XCTestCase {
    /// A pump scan that began while the peer was silent, and was held until
    /// after the peer answered again, never parks a request written after that.
    func testARequestWrittenAfterSilenceEndsIsNeverParked() async throws {
        let h = RelayHostTransportHarness()
        let a = h.endpoint("studio")
        let store = h.network.store(from: "studio", to: "laptop")
        func write(_ seq: UInt64) -> HostEnvelope {
            HostEnvelope(id: HostTransportTestIDs.make(), from: "id:sender", to: "c11:layer", body: Data("v".utf8),
                         state: .init(panel: UUID(), key: "metadata.title", seq: seq))
        }
        h.setSilent("laptop", true)
        guard case .unreachable = await a.send(write(5), to: "laptop") else { return XCTFail("not unreachable") }
        XCTAssertEqual(h.network.parkedCount, 1, "a scan that saw the peer silent parked the first request")
        // Scans run one after another, so the next one also began while the peer was silent.
        let held = expectation(description: "the pump holds its next slot scan")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        h.network.holdNextSlotScan { held.fulfill(); _ = release.wait(timeout: .now() + 10) }
        await fulfillment(of: [held], timeout: 5)
        h.setSilent("laptop", false)
        let sending = Task { await a.send(write(6), to: "laptop") }
        // Release the held scan once the second request sits in its slot.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(0..<C11Relay.slotCount).contains(where: {
            C11Relay.Request((try? store.get(C11Relay.slotName($0)))?.value) != nil
        }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        release.signal()
        let sent = await sending.value
        XCTAssertEqual(sent, .delivered)
        XCTAssertEqual(h.releaseLateAccepts(), 1, "only the request sent while the peer was silent was parked")
    }
}
