import Foundation

// C11H-71 part A: `HostTransport`, the only way between hosts
// (docs/c11-agent-layer-contract.md, A6, frozen at 77bfbec4).
//
// Every byte that crosses hosts is an envelope v1, and it travels only
// through this interface. The relay is implementation 1 (part C); the bus is a
// later, second one (C11H-72). The layer, away-merge (C11H-73) and the
// transcript index (C11H-74) call this interface and nothing else.

/// An envelope as the transport sees it. Routing, ordering, holding and dedupe
/// use only `id`, `from`, `to`, `replyTo` / `inReplyTo` and the two hosts.
/// `body` and `topic` are opaque bytes: measured against the bounds, never
/// parsed, indexed, logged or validated in transit (A6, "Opaque body and
/// topic"). The other header fields travel as `passthrough`, unchanged.
struct HostEnvelope: Equatable, Sendable {
    let id: String
    let from: String
    let to: String?
    let replyTo: String?
    let inReplyTo: String?
    /// Opaque. A consumer reads it only on the recipient host, after `receive`.
    let body: Data
    /// Opaque, like `body`.
    let topic: Data?
    /// Set when the sender gave a `body_ref`. Its value is never read; a file
    /// path on the sender's machine means nothing on the receiver's.
    let hasBodyRef: Bool
    /// The sender's other envelope v1 headers, as the JSON object it encoded:
    /// any of `version`, `ts`, `urgent`, `ttl_seconds`, `content_type` and
    /// `ext` (empty when there are none). Carried unchanged; read only to
    /// measure the original envelope (A6 Amendment 2). Anything that is not
    /// such an object is `invalid_envelope`.
    let passthrough: Data
    /// What the carrying implementation added under `ext.c11h`
    /// (`origin_host`, `machine`, and `relay` on the relay only).
    var stamps: [String: String]
    /// Bytes a sealing layer added to `body` (and `topic`). They are not
    /// counted against the bounds (A6: overhead is not counted), so a body the
    /// sender gave at the bound stays deliverable once sealed.
    let bodyOverhead: Int
    /// A6 Amendment 2: the size of the ORIGINAL envelope v1, the length of
    /// its canonical (RFC 8785) JSON serialization with every
    /// implementation-owned key removed (`HostEnvelopeMeasure`). Every
    /// implementation computes the same number from the envelope itself, at
    /// every hop. A sealed copy keeps the size measured before sealing.
    let originalBytes: Int
    /// Whether `passthrough` is a JSON object of the other v1 headers only.
    let passthroughIsHeaders: Bool
    /// A6 Amendment 1: `ext.c11h.state` on a state-setting record. The one
    /// header beyond the routing fields the transport reads: a key and a
    /// number, never a value.
    let state: StateHeader?

    struct StateHeader: Hashable, Sendable {
        /// The panel whose state this sets.
        let panel: UUID
        /// `metadata.<raw key>`, `flag` or `delegate` (disjoint namespaces).
        let key: String
        /// The panel's sequence from its owning host.
        let seq: UInt64

        struct Slot: Hashable, Sendable { let panel: UUID; let key: String }
        var slot: Slot { Slot(panel: panel, key: key) }
    }

    init(id: String, from: String, to: String?, replyTo: String? = nil, inReplyTo: String? = nil,
         body: Data, topic: Data? = nil, hasBodyRef: Bool = false, passthrough: Data = Data(),
         stamps: [String: String] = [:], state: StateHeader? = nil, bodyOverhead: Int = 0,
         originalBytes: Int? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.replyTo = replyTo
        self.inReplyTo = inReplyTo
        self.body = body
        self.topic = topic
        self.hasBodyRef = hasBodyRef
        self.passthrough = passthrough
        self.stamps = stamps
        self.state = state
        self.bodyOverhead = max(0, bodyOverhead)
        let headers = HostEnvelopeMeasure.headers(passthrough)
        self.passthroughIsHeaders = headers != nil
        // Only a size measured before sealing is carried in; everything else
        // is measured here. A sealed body built directly is measured less its
        // overhead.
        self.originalBytes = originalBytes ?? HostEnvelopeMeasure.original(
            id: id, from: from, to: to, replyTo: replyTo, inReplyTo: inReplyTo,
            body: body.prefix(max(0, body.count - max(0, bodyOverhead))),
            topic: topic.map { $0.prefix(max(0, $0.count - max(0, bodyOverhead))) },
            headers: headers ?? NSDictionary(), state: state)
    }

    /// The same envelope with other opaque bytes (sealing, transit faults).
    func replacingOpaque(body: Data, topic: Data?, bodyOverhead: Int) -> HostEnvelope {
        HostEnvelope(id: id, from: from, to: to, replyTo: replyTo, inReplyTo: inReplyTo, body: body, topic: topic,
                     hasBodyRef: hasBodyRef, passthrough: passthrough, stamps: stamps, state: state,
                     bodyOverhead: bodyOverhead, originalBytes: originalBytes)
    }

    /// The routing fields alone: two envelopes equal here route, order, hold
    /// and dedupe identically, whatever their bodies and topics (T8).
    var routingKey: RoutingKey {
        RoutingKey(id: id, from: from, to: to, replyTo: replyTo, inReplyTo: inReplyTo)
    }

    struct RoutingKey: Hashable, Sendable {
        let id: String
        let from: String
        let to: String?
        let replyTo: String?
        let inReplyTo: String?
    }
}

/// `unreachable`'s promise about the envelope (A6).
enum HostTransportDelivery: String, Equatable, Sendable {
    /// Cancelled at the deadline: it will never be applied.
    case none
    /// It may still be applied later, once, because of its `id`.
    case unknown
}

/// A refusal code: never deliverable, never retried automatically.
struct HostTransportRefusal: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }

    static let envelopeTooLarge = Self(rawValue: "envelope_too_large")
    static let bodyRefCrossHost = Self(rawValue: "body_ref_cross_host")
    static let topicOnlyCrossHost = Self(rawValue: "topic_only_cross_host")
    static let invalidEnvelope = Self(rawValue: "invalid_envelope")
    static let holdFull = Self(rawValue: "transport_hold_full")
    static let notAllowed = Self(rawValue: "relay_not_allowed")
    static let layerIdentityRefused = Self(rawValue: "layer_identity_refused")
    static let layerWrongHost = Self(rawValue: "layer_wrong_host")
    static let unknownHost = Self(rawValue: "transport_unknown_host")
}

/// Every operation answers one of these and nothing else (A6 table).
enum HostTransportResult: Equatable, Sendable {
    /// The peer's transport accepted it; it will reach `receive` there.
    case delivered
    /// `hold` only: the host is away; kept, and delivered on its return.
    case held(since: Date)
    /// `send` only: the host is known to be down; nothing was kept.
    case away(since: Date)
    /// No answer within the deadline.
    case unreachable(reason: String, delivery: HostTransportDelivery)
    /// Never deliverable.
    case refused(HostTransportRefusal)
}

/// What a `receive` stream hands its consumer.
enum HostTransportIncoming: Equatable, Sendable {
    /// In the order the sending host sent it, at least once.
    case envelope(HostEnvelope)
    /// Failed validation on arrival (headers and lengths only): quarantined,
    /// never applied.
    case refused(id: String, HostTransportRefusal)
}

/// One sending host's ordered stream on the receiving host.
protocol HostTransportInbox: AnyObject, Sendable {
    /// The next envelope, or nil when none arrives within `timeout` (or the
    /// host is away: a suspended stream invents nothing). Unacknowledged
    /// envelopes come again, in order, after a reconnect.
    func next(timeout: TimeInterval) async -> HostTransportIncoming?
    /// Record that `id` is applied durably. The transport never delivers an
    /// acknowledged `id` again (for the retention window).
    func acknowledge(_ id: String) async
}

/// The interface (A6). Consumers apply idempotently by `id`: the applied `id`
/// goes in the same atomic write as the effect, then they acknowledge.
protocol HostTransport: AnyObject, Sendable {
    /// This host's name (hc's machine name; the app host's own name).
    var host: String { get }
    /// Deliver now or fail fast: `delivered`, `away`, `unreachable` or
    /// `refused`, within `HostTransportBounds.sendDeadline`.
    func send(_ envelope: HostEnvelope, to host: String) async -> HostTransportResult
    /// Keep it for a host that is away and deliver it on return, before
    /// anything sent after the return: `delivered`, `held` or `refused`.
    func hold(_ envelope: HostEnvelope, for host: String) async -> HostTransportResult
    /// `from`'s envelopes to this host, in its sending order.
    func receive(from host: String) -> any HostTransportInbox
}

/// A6 Amendment 1: the stale-state check every implementation's `receive`
/// applies. For each `(panel, key)` it keeps the highest `seq` delivered and
/// that envelope's `id`. A state envelope is dropped (acknowledged, never
/// handed over) when its `seq` is lower, or equal under a different `id`. The
/// same `id` redelivered before its acknowledgement still comes again.
/// Envelopes without a state header (mail, journal, lineage) pass untouched.
struct HostStaleStateFilter: Sendable {
    private var delivered: [HostEnvelope.StateHeader.Slot: (seq: UInt64, id: String)] = [:]

    /// True when `envelope` may be handed over; records it when it is.
    mutating func admit(_ envelope: HostEnvelope) -> Bool {
        guard let state = envelope.state else { return true }
        if let last = delivered[state.slot] {
            if state.seq < last.seq { return false }
            if state.seq == last.seq && envelope.id != last.id { return false }
        }
        delivered[state.slot] = (state.seq, envelope.id)
        return true
    }
}

/// Bounds every implementation keeps (A6, "Bounds").
enum HostTransportBounds {
    /// An envelope body, as the sender gave it. Implementation overhead
    /// (framing, stamps, sealing) is not counted.
    static let maximumBodyBytes = 4096
    /// A topic is opaque too; it is bounded like a header field.
    static let maximumTopicBytes = 256
    /// The app host holds at most this many envelopes for one host.
    static let maximumHeldEnvelopes = 4096
    static let maximumHeldBytes = 16 << 20
    /// `send` answers within this.
    static let sendDeadline: TimeInterval = 2
    /// A6 Amendment 2: the whole original envelope, equal to the bus line bound.
    static let maximumEnvelopeBytes = 65_536
    /// A6 Amendment 2: `from`, `to` and `reply_to`, each, in Unicode code
    /// points (the bus's header rule).
    static let maximumAddressCharacters = 256
    /// Acknowledged ids are remembered this long, matching retention (A3).
    static let acknowledgedRetention: TimeInterval = 7 * 24 * 3600
    /// Stamp keys an implementation may write under `ext.c11h`.
    static let stampKeys: Set<String> = ["origin_host", "machine", "relay"]
}

/// The checks every implementation runs before carrying an envelope across
/// hosts: headers and lengths only, never body or topic content.
enum HostEnvelopeAdmission {
    static func refusal(_ envelope: HostEnvelope) -> HostTransportRefusal? {
        // A6 Amendment 2 header rules: an uppercase ULID id, and addresses
        // of at most 256 characters.
        guard isULID(envelope.id), !envelope.from.isEmpty, isAddress(envelope.from),
              envelope.replyTo.map(isAddress) ?? true, envelope.passthroughIsHeaders,
              (envelope.state?.seq ?? 0) <= HostEnvelopeMeasure.maximumSafeInteger else { return .invalidEnvelope }
        guard let to = envelope.to, !to.isEmpty else { return .topicOnlyCrossHost }
        guard isAddress(to) else { return .invalidEnvelope }
        guard !envelope.hasBodyRef else { return .bodyRefCrossHost }
        // A6 Amendment 2: the whole original envelope, at original admission.
        guard envelope.originalBytes <= HostTransportBounds.maximumEnvelopeBytes else { return .envelopeTooLarge }
        // Measured as the sender gave it: a sealing layer's overhead is not counted.
        guard envelope.body.count - envelope.bodyOverhead <= HostTransportBounds.maximumBodyBytes,
              (envelope.topic?.count ?? 0) - envelope.bodyOverhead <= HostTransportBounds.maximumTopicBytes else {
            return .envelopeTooLarge
        }
        return nil
    }

    /// Envelope v1's id: 26 characters of UPPERCASE Crockford base32
    /// (`MailboxEnvelope.ulidPattern`); a lowercase id is invalid.
    static func isULID(_ raw: String) -> Bool {
        let scalars = raw.unicodeScalars
        return scalars.count == 26 && scalars.allSatisfy { ulidAlphabet.contains($0) }
    }

    private static let ulidAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ".unicodeScalars)

    /// An address within the header bound, counted in Unicode code points.
    static func isAddress(_ raw: String) -> Bool {
        raw.unicodeScalars.count <= HostTransportBounds.maximumAddressCharacters
    }
}

/// A6 Amendment 2: the one measure of an original envelope v1, agreed with
/// the bus (C11H-72) and the same in every implementation and at every hop.
/// The size is the body's bytes plus the topic's bytes, each as the sender
/// gave it (sealing overhead excluded), plus the UTF-8 length of the
/// RFC 8785 (JCS) serialization of the rest of the envelope v1 object, with
/// `body` as `""` and `topic` left out:
/// - JCS: compact; strings as raw UTF-8, escaping only `"`, `\` and
///   U+0000-U+001F (`\b \t \n \f \r`, others `\u00xx`); `/` is not
///   escaped. Key order never changes the length;
/// - numbers: every number in the headers is a safe integer (an integer
///   literal in [-(2^53-1), 2^53-1]), which JCS and every implementation
///   print as the same decimal digits. Anything else is `invalid_envelope`;
/// - `version` always counts (as `1` when the sender's headers lack it);
/// - every implementation-owned `ext.c11h` key is removed, with a `ts` the
///   bus adapter synthesized (`ts_added`), and then ANY empty `ext.c11h` or
///   `ext`, original or emptied, so a hop never changes the number.
/// Body and topic are counted, never scanned. Objects are walked as
/// Foundation dictionaries, so keys that differ only by Unicode
/// normalization (`é`, `e\u{301}`) both stay counted.
enum HostEnvelopeMeasure {
    /// Keys an implementation adds under `ext.c11h`; never counted.
    static let implementationKeys: [String] = [
        "origin_host", "machine", "relay", "encoding", "body_overhead", "ts_added",
    ]
    /// The v1 header fields `passthrough` may hold.
    static let headerKeys: Set<String> = ["version", "ts", "urgent", "ttl_seconds", "content_type", "ext"]
    /// 2^53 - 1: the largest integer binary64 (and so JCS) holds exactly.
    static let maximumSafeInteger: UInt64 = (1 << 53) - 1

    /// `passthrough` as a header object, or nil when it is not one: not a
    /// JSON object, a key outside `headerKeys`, an `ext` or `ext.c11h` that
    /// is not an object, or a number that is not a safe integer.
    static func headers(_ passthrough: Data) -> NSDictionary? {
        if passthrough.isEmpty { return NSDictionary() }
        guard let object = try? JSONSerialization.jsonObject(with: passthrough) as? NSDictionary else { return nil }
        for case let key as String in object.allKeys where !headerKeys.contains(key) { return nil }
        guard object.allKeys.allSatisfy({ $0 is String }) else { return nil }
        if let ext = object["ext"] {
            guard let ext = ext as? NSDictionary else { return nil }
            if let c11 = ext["c11h"], !(c11 is NSDictionary) { return nil }
        }
        return numbersAreSafe(object) ? object : nil
    }

    static func numbersAreSafe(_ value: Any) -> Bool {
        switch value {
        case let n as NSNumber: return isSafeInteger(n)
        case let d as NSDictionary: return d.allValues.allSatisfy(numbersAreSafe)
        case let a as NSArray: return a.allSatisfy(numbersAreSafe)
        default: return true
        }
    }

    static func isSafeInteger(_ n: NSNumber) -> Bool {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return true }
        // JSONSerialization hands a fraction or exponent back as a double
        // (or NSDecimalNumber), both "d"; integers come back as q or Q.
        switch String(cString: n.objCType) {
        case "d", "f": return false
        case "Q", "L", "I", "S", "C": return n.uint64Value <= maximumSafeInteger
        default:
            let v = n.int64Value
            return v >= -Int64(maximumSafeInteger) && v <= Int64(maximumSafeInteger)
        }
    }

    static func original(id: String, from: String, to: String?, replyTo: String?, inReplyTo: String?,
                         body: Data, topic: Data?, headers: NSDictionary, state: HostEnvelope.StateHeader?) -> Int {
        var members: [(String, Int)] = [("id", string(id)), ("from", string(from)), ("body", string(""))]
        if let to { members.append(("to", string(to))) }
        if let replyTo { members.append(("reply_to", string(replyTo))) }
        if let inReplyTo { members.append(("in_reply_to", string(inReplyTo))) }
        let top = headers.mutableCopy() as! NSMutableDictionary
        let ext = ((top["ext"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary()
        let c11 = ((ext["c11h"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary()
        let tsAdded = (c11["ts_added"] as? NSNumber)?.boolValue == true
        c11.removeObjects(forKeys: implementationKeys)
        if let state, c11["state"] == nil { c11["state"] = stateObject(state) }
        if c11.count == 0 { ext.removeObject(forKey: "c11h") } else { ext["c11h"] = c11 }
        if ext.count == 0 { top.removeObject(forKey: "ext") } else { top["ext"] = ext }
        if tsAdded { top.removeObject(forKey: "ts") }
        if top["version"] == nil { top["version"] = 1 }
        for (key, value) in top { if let key = key as? String { members.append((key, length(value))) } }
        return object(members) + body.count + (topic?.count ?? 0)
    }

    static func stateObject(_ state: HostEnvelope.StateHeader) -> NSDictionary {
        ["panel": state.panel.uuidString, "key": state.key, "seq": NSNumber(value: state.seq)]
    }

    /// `{"k":v,...}` from member keys and value lengths.
    static func object(_ members: [(String, Int)]) -> Int {
        2 + members.reduce(0) { $0 + string($1.0) + 1 + $1.1 } + max(0, members.count - 1)
    }

    /// The JCS length of a JSON value from the headers.
    static func length(_ value: Any) -> Int {
        switch value {
        case let s as String: return string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 4 : 5 }
            return n.stringValue.utf8.count  // a safe integer: the same digits everywhere
        case let d as NSDictionary:
            var members: [(String, Int)] = []
            for (key, member) in d { if let key = key as? String { members.append((key, length(member))) } }
            return object(members)
        case let a as NSArray: return 2 + a.reduce(0) { $0 + length($1) } + max(0, a.count - 1)
        default: return 4  // null
        }
    }

    /// A JSON string, quotes included.
    static func string(_ s: String) -> Int {
        2 + s.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: return total + 2
            case 0..<0x20: return total + 6
            default: return total + String(scalar).utf8.count
            }
        }
    }
}
