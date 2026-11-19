import Foundation

// C11H-72: what c11's bus adapter writes on `$CBUS_HOME/cbus.sock`, per the
// bus's HostTransport socket protocol version 1 (CBUS-19,
// `docs/hosttransport-socket.md` in constellation-bus PR 2, repair 1 at bbe5a85).
//
// One JSON object per line. Requests are `{"id", "method", "params"}` with a
// string request id; responses echo the id with `result` or `error`; stream
// frames carry `frame`. The carried c11 envelope is a c11 envelope v1 JSON
// string: the daemon checks its headers and lengths, stores and forwards its
// bytes, and never reads a body or topic.

enum CbusWire {
    static let protocolVersion = 1
    static let role = "hosttransport"
    /// CBUS-19 rule 1.4: a line is at most 1 MiB, its newline included.
    static let maximumLineBytes = 1 << 20

    // MARK: Lines

    /// One line, newline-terminated, or nil when it cannot be encoded.
    static func encodeLine(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }

    static func decodeLine(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    // MARK: The carried envelope (c11 envelope v1)

    /// The header fields `HostEnvelope.passthrough` may carry, unread (A6
    /// Amendment 2: the JSON object of these v1 fields, and nothing else).
    static let passthroughKeys: Set<String> = ["version", "ts", "urgent", "ttl_seconds", "content_type", "ext"]
    /// What the adapter may add under `ext.c11h` and removes again on arrival.
    /// `relay` is never carried. `origin_host` and `machine` ride along only on
    /// an envelope that already has them (one being forwarded, A8); the
    /// receiving side trusts them only from the app host (see `hostEnvelope`).
    private static let adapterKeys: Set<String> = ["state", "encoding", "ts_added", "body_overhead",
                                                   "origin_host", "machine", "relay"]
    /// What the receiving adapter strips from the `ext` it keeps (CBUS-19 rule
    /// 5.5, repair 2): its own keys and the carried stamps. `state` stays: the
    /// sender's `ext` passes through unchanged (A6), and `HostEnvelope.state`
    /// carries the same header for the consumer.
    private static let strippedOnArrival: Set<String> = ["encoding", "ts_added", "body_overhead",
                                                         "origin_host", "machine", "relay"]

    /// c11 envelope v1's topic token.
    static func isV1Topic(_ topic: String) -> Bool {
        guard let first = topic.unicodeScalars.first, topic.utf8.count <= 256 else { return false }
        func word(_ c: Unicode.Scalar) -> Bool { c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_") }
        return word(first) && topic.unicodeScalars.allSatisfy { word($0) || $0 == "." || $0 == "-" }
    }

    /// The envelope as c11 envelope v1 JSON (CBUS-19 rule 5.2). A body or topic
    /// that is not v1 text (sealed bytes, say) travels as base64 in its own
    /// field, marked in `ext.c11h.encoding`; both come back byte for byte. Nil
    /// when `passthrough` is not a JSON object.
    static func envelopeJSON(_ envelope: HostEnvelope, now: Date = Date()) -> Data? {
        var object: [String: Any] = [:]
        if !envelope.passthrough.isEmpty {
            // Raw bytes, an array, a routing field or an unknown key cannot ride
            // as envelope v1: refused, never silently dropped (A6 Amendment 2).
            guard let fields = (try? JSONSerialization.jsonObject(with: envelope.passthrough)) as? [String: Any],
                  Set(fields.keys).isSubset(of: passthroughKeys) else { return nil }
            for (key, value) in fields { object[key] = value }
        }
        var ext = object["ext"] as? [String: Any] ?? [:]
        var c11 = ext["c11h"] as? [String: Any] ?? [:]
        for key in adapterKeys { c11.removeValue(forKey: key) }
        object["version"] = 1
        object["id"] = envelope.id
        object["from"] = envelope.from
        if let to = envelope.to { object["to"] = to }
        if let replyTo = envelope.replyTo { object["reply_to"] = replyTo }
        if let inReplyTo = envelope.inReplyTo { object["in_reply_to"] = inReplyTo }
        var encoding: [String: String] = [:]
        if let text = String(data: envelope.body, encoding: .utf8) {
            object["body"] = text
        } else {
            object["body"] = envelope.body.base64EncodedString()
            encoding["body"] = "base64"
        }
        if let topic = envelope.topic {
            if let text = String(data: topic, encoding: .utf8), isV1Topic(text) {
                object["topic"] = text
            } else {
                object["topic"] = topic.base64EncodedString()
                encoding["topic"] = "base64"
            }
        }
        if !encoding.isEmpty { c11["encoding"] = encoding }
        if object["ts"] == nil {
            object["ts"] = timestamp(now)
            c11["ts_added"] = true
        }
        if let origin = envelope.stamps["origin_host"], let machine = envelope.stamps["machine"] {
            c11["origin_host"] = origin
            c11["machine"] = machine
        }
        if envelope.bodyOverhead > 0 {
            // A sealing layer's overhead: a length, so the bound still measures what the sender gave.
            c11["body_overhead"] = envelope.bodyOverhead
        }
        if let state = envelope.state {
            c11["state"] = ["panel": state.panel.uuidString, "key": state.key, "seq": NSNumber(value: state.seq)]
        }
        if !c11.isEmpty { ext["c11h"] = c11 }
        if !ext.isEmpty { object["ext"] = ext } else { object.removeValue(forKey: "ext") }
        if envelope.hasBodyRef { object["body_ref"] = "" }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The envelope back from v1 JSON, stamped with the origin the daemon
    /// attested. Stamps carried inside the envelope count only when
    /// `trustCarriedOrigin`: the frame's `from_app_host`, the bus's word that the
    /// hop is the session's registered app host forwarding (A8; CBUS-19 rules 4.6,
    /// 5.5). Otherwise they are dropped. Nil when the bytes are not a v1 envelope
    /// this adapter can read.
    static func hostEnvelope(json: Data, originHost: String, machine: String,
                             trustCarriedOrigin: Bool = false) -> HostEnvelope? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == 1,
              let id = object["id"] as? String, let from = object["from"] as? String,
              let bodyText = object["body"] as? String else { return nil }
        var ext = object["ext"] as? [String: Any] ?? [:]
        let c11 = ext["c11h"] as? [String: Any] ?? [:]
        let encoding = c11["encoding"] as? [String: Any] ?? [:]
        guard let body = (encoding["body"] as? String) == "base64" ? Data(base64Encoded: bodyText) : Data(bodyText.utf8)
        else { return nil }
        var topic: Data?
        if let raw = object["topic"] {
            guard let text = raw as? String else { return nil }
            if (encoding["topic"] as? String) == "base64" {
                guard let decoded = Data(base64Encoded: text) else { return nil }
                topic = decoded
            } else {
                topic = Data(text.utf8)
            }
        }
        var state: HostEnvelope.StateHeader?
        if let raw = c11["state"] {
            guard let fields = raw as? [String: Any],
                  let panelText = fields["panel"] as? String, let panel = UUID(uuidString: panelText),
                  let key = fields["key"] as? String, !key.isEmpty,
                  let seq = (fields["seq"] as? NSNumber)?.uint64Value, seq >= 1 else { return nil }
            state = .init(panel: panel, key: key, seq: seq)
        }
        var rest = c11
        for key in strippedOnArrival { rest.removeValue(forKey: key) }
        if rest.isEmpty { ext.removeValue(forKey: "c11h") } else { ext["c11h"] = rest }
        var passthrough: [String: Any] = [:]
        for key in passthroughKeys where key != "ext" && key != "version" { if let value = object[key] { passthrough[key] = value } }
        if (c11["ts_added"] as? Bool) == true { passthrough.removeValue(forKey: "ts") }
        if !ext.isEmpty { passthrough["ext"] = ext }
        let passthroughData = passthrough.isEmpty
            ? Data() : ((try? JSONSerialization.data(withJSONObject: passthrough, options: [.sortedKeys])) ?? Data())
        var stamps = ["origin_host": originHost, "machine": machine]
        if trustCarriedOrigin, let carriedOrigin = c11["origin_host"] as? String, !carriedOrigin.isEmpty,
           let carriedMachine = c11["machine"] as? String, !carriedMachine.isEmpty {
            stamps = ["origin_host": carriedOrigin, "machine": carriedMachine]
        }
        let overhead = (c11["body_overhead"] as? NSNumber)?.intValue ?? 0
        func optional(_ name: String) -> String? { object[name] as? String }
        return HostEnvelope(id: id, from: from, to: optional("to"), replyTo: optional("reply_to"),
                            inReplyTo: optional("in_reply_to"), body: body, topic: topic,
                            hasBodyRef: object["body_ref"] != nil, passthrough: passthroughData,
                            stamps: stamps, state: state, bodyOverhead: overhead)
    }

    // MARK: Times

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
