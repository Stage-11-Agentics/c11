import Foundation

/// c11 mailbox envelope, v1.
///
/// Single source of truth for building (send path) and validating (dispatch
/// path) envelopes. CLI, raw-bash, and Python parity test all round-trip
/// through this type. See `spec/mailbox-envelope.v1.schema.json` for the
/// matching schema and `docs/c11-messaging-primitive-design.md` §3 for the
/// rationale.
///
/// Backed by a `[String: Any]` dict so JSONSerialization can encode with
/// `.sortedKeys` for byte-parity across sender paths, and so `ext` carries
/// forward-compat unknown values unchanged.
struct MailboxEnvelope: Equatable {

    // MARK: - Constants

    static let schemaVersion = 1
    static let maxBodyBytes = 4096
    static let maxStringFieldBytes = 256
    static let ulidPattern = #"^[0-9A-HJKMNP-TV-Z]{26}$"#
    static let topicPattern = #"^[A-Za-z0-9_][A-Za-z0-9_.\-]*$"#
    static let timestampPattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$"#

    /// Every key the schema declares. Anything else at the top level is rejected.
    static let allowedKeys: Set<String> = [
        "version", "id", "from", "ts", "body",
        "to", "topic", "reply_to", "in_reply_to",
        "urgent", "ttl_seconds", "body_ref", "content_type", "ext",
    ]

    // MARK: - Storage

    /// Raw JSON object. Keys sort-encoded on serialization for byte-parity.
    let raw: [String: Any]

    private init(raw: [String: Any]) {
        self.raw = raw
    }

    // MARK: - Typed accessors

    var version: Int { (raw["version"] as? NSNumber)?.intValue ?? 0 }
    var id: String { raw["id"] as? String ?? "" }
    var from: String { raw["from"] as? String ?? "" }
    var ts: String { raw["ts"] as? String ?? "" }
    var body: String { raw["body"] as? String ?? "" }
    var to: String? { raw["to"] as? String }
    var topic: String? { raw["topic"] as? String }
    var replyTo: String? { raw["reply_to"] as? String }
    var inReplyTo: String? { raw["in_reply_to"] as? String }
    var urgent: Bool? { (raw["urgent"] as? NSNumber).flatMap(asBool(_:)) }
    var ttlSeconds: Int? { (raw["ttl_seconds"] as? NSNumber)?.intValue }
    var bodyRef: String? { raw["body_ref"] as? String }
    var contentType: String? { raw["content_type"] as? String }
    var ext: [String: Any]? { raw["ext"] as? [String: Any] }

    static func == (lhs: MailboxEnvelope, rhs: MailboxEnvelope) -> Bool {
        // Byte-equivalent when sort-encoded is the right notion of equality for
        // mailbox envelopes; anything deeper would double-encode ext's Any values.
        (try? lhs.encode()) == (try? rhs.encode())
    }

    // MARK: - Encoding

    /// Compact, lexicographically key-sorted JSON. This is the byte form both
    /// the CLI and raw-file senders must produce to satisfy the parity test.
    ///
    /// `.withoutEscapingSlashes` is load-bearing: without it Swift escapes
    /// `/` as `\/` while Python's `json.dumps` does not, so `body_ref`
    /// envelopes drift the moment byte-equality is asserted.
    func encode() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: raw,
            options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        )
    }

    // MARK: - Errors

    enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case notAJSONObject
        case unknownTopLevelKey(String)
        case missingField(String)
        case wrongFieldType(String)
        case wrongVersionValue(Int)
        case emptyString(String)
        case stringTooLong(field: String, bytes: Int)
        case invalidULID(field: String, value: String)
        case invalidTimestamp(String)
        case invalidTopic(String)
        case invalidTTLSeconds
        case bodyTooLarge(bytes: Int)
        case bodyRefNotAbsolute(String)
        case bodyAndBodyRefConflict
        case noRecipient
        case extNotObject

        var description: String {
            switch self {
            case .notAJSONObject:
                return "top-level value is not a JSON object"
            case .unknownTopLevelKey(let key):
                return "unknown top-level key '\(key)' (unknown keys belong under 'ext')"
            case .missingField(let f):
                return "missing required field '\(f)'"
            case .wrongFieldType(let f):
                return "wrong type for field '\(f)'"
            case .wrongVersionValue(let v):
                return "unsupported envelope version \(v); expected \(schemaVersion)"
            case .emptyString(let f):
                return "field '\(f)' must be a non-empty string"
            case .stringTooLong(let f, let bytes):
                return "field '\(f)' exceeds \(maxStringFieldBytes)-byte cap (was \(bytes))"
            case .invalidULID(let f, let v):
                return "field '\(f)' is not a Crockford base32 ULID: \(v)"
            case .invalidTimestamp(let v):
                return "ts '\(v)' is not an RFC3339 UTC timestamp"
            case .invalidTopic(let v):
                return "topic '\(v)' does not match the dotted-token pattern"
            case .invalidTTLSeconds:
                return "ttl_seconds must be an integer ≥ 1"
            case .bodyTooLarge(let bytes):
                return "inline body exceeds \(maxBodyBytes)-byte cap (was \(bytes))"
            case .bodyRefNotAbsolute(let p):
                return "body_ref '\(p)' must be an absolute path"
            case .bodyAndBodyRefConflict:
                return "body must be empty when body_ref is set"
            case .noRecipient:
                return "envelope must declare 'to' or 'topic' (or both)"
            case .extNotObject:
                return "ext must be a JSON object"
            }
        }
    }

    // MARK: - Validation (dispatch-side)

    @discardableResult
    static func validate(data: Data) throws -> MailboxEnvelope {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw Error.notAJSONObject
        }
        guard let dict = parsed as? [String: Any] else {
            throw Error.notAJSONObject
        }

        // Unknown key check comes first so fixtures like invalid-unknown-top-level-key
        // fail deterministically regardless of other issues.
        for key in dict.keys where !allowedKeys.contains(key) {
            throw Error.unknownTopLevelKey(key)
        }

        for required in ["version", "id", "from", "ts", "body"] {
            if dict[required] == nil {
                throw Error.missingField(required)
            }
        }

        // version: integer, not Bool (NSNumber bool bridges to Int).
        let versionInt = try requireInteger(dict["version"], field: "version")
        guard versionInt == schemaVersion else {
            throw Error.wrongVersionValue(versionInt)
        }

        // id: ULID.
        let idValue = try requireString(dict["id"], field: "id")
        try validateULID(idValue, field: "id")

        // from: non-empty ≤ 256 bytes.
        let fromValue = try requireNonEmptyString(dict["from"], field: "from")
        try ensureStringByteCap(fromValue, field: "from")

        // ts: RFC3339 UTC.
        let tsValue = try requireString(dict["ts"], field: "ts")
        guard tsValue.range(of: timestampPattern, options: .regularExpression) != nil else {
            throw Error.invalidTimestamp(tsValue)
        }

        // body: string ≤ 4096 bytes UTF-8.
        let bodyValue = try requireString(dict["body"], field: "body")
        let bodyBytes = bodyValue.utf8.count
        if bodyBytes > maxBodyBytes {
            throw Error.bodyTooLarge(bytes: bodyBytes)
        }

        // Optional fields.
        if let raw = dict["to"] {
            let toValue = try requireNonEmptyString(raw, field: "to")
            try ensureStringByteCap(toValue, field: "to")
        }

        if let raw = dict["topic"] {
            let topicValue = try requireNonEmptyString(raw, field: "topic")
            try ensureStringByteCap(topicValue, field: "topic")
            guard topicValue.range(of: topicPattern, options: .regularExpression) != nil else {
                throw Error.invalidTopic(topicValue)
            }
        }

        if let raw = dict["reply_to"] {
            let replyTo = try requireNonEmptyString(raw, field: "reply_to")
            try ensureStringByteCap(replyTo, field: "reply_to")
        }

        if let raw = dict["in_reply_to"] {
            let inReplyTo = try requireString(raw, field: "in_reply_to")
            try validateULID(inReplyTo, field: "in_reply_to")
        }

        if let raw = dict["urgent"] {
            _ = try requireBool(raw, field: "urgent")
        }

        if let raw = dict["ttl_seconds"] {
            let ttl = try requireInteger(raw, field: "ttl_seconds")
            guard ttl >= 1 else { throw Error.invalidTTLSeconds }
        }

        var hasBodyRef = false
        if let raw = dict["body_ref"] {
            let bodyRef = try requireNonEmptyString(raw, field: "body_ref")
            guard bodyRef.hasPrefix("/") else {
                throw Error.bodyRefNotAbsolute(bodyRef)
            }
            hasBodyRef = true
        }

        if let raw = dict["content_type"] {
            _ = try requireNonEmptyString(raw, field: "content_type")
        }

        if let raw = dict["ext"] {
            guard raw is [String: Any] else { throw Error.extNotObject }
        }

        // Cross-field: at least one of to/topic.
        if dict["to"] == nil && dict["topic"] == nil {
            throw Error.noRecipient
        }

        // Cross-field: body non-empty is mutually exclusive with body_ref.
        if hasBodyRef && !bodyValue.isEmpty {
            throw Error.bodyAndBodyRefConflict
        }

        return MailboxEnvelope(raw: dict)
    }

    // MARK: - Build (send-side)

    /// Constructs a valid envelope. Auto-fills `version`, `id`, `ts` when the
    /// caller omits them. Throws the same errors the dispatcher would on
    /// invalid inputs so senders fail fast instead of writing a rejected file.
    static func build(
        from: String,
        to: String? = nil,
        topic: String? = nil,
        body: String,
        id: String? = nil,
        ts: String? = nil,
        replyTo: String? = nil,
        inReplyTo: String? = nil,
        urgent: Bool? = nil,
        ttlSeconds: Int? = nil,
        bodyRef: String? = nil,
        contentType: String? = nil,
        ext: [String: Any]? = nil,
        now: Date = Date()
    ) throws -> MailboxEnvelope {
        var raw: [String: Any] = [
            "version": schemaVersion,
            "id": id ?? MailboxULID.make(now: now),
            "from": from,
            "ts": ts ?? currentRFC3339(now: now),
            "body": body,
        ]
        if let to { raw["to"] = to }
        if let topic { raw["topic"] = topic }
        if let replyTo { raw["reply_to"] = replyTo }
        if let inReplyTo { raw["in_reply_to"] = inReplyTo }
        if let urgent { raw["urgent"] = urgent }
        if let ttlSeconds { raw["ttl_seconds"] = ttlSeconds }
        if let bodyRef { raw["body_ref"] = bodyRef }
        if let contentType { raw["content_type"] = contentType }
        if let ext { raw["ext"] = ext }

        // Re-validate via the same validator the dispatcher uses — single source
        // of truth per drift-prevention rule #1.
        let data = try JSONSerialization.data(
            withJSONObject: raw,
            options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        )
        return try validate(data: data)
    }

    static func currentRFC3339(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: now)
    }

    // MARK: - Internal primitives

    private static func requireString(_ value: Any?, field: String) throws -> String {
        guard let str = value as? String else {
            throw Error.wrongFieldType(field)
        }
        return str
    }

    private static func requireNonEmptyString(_ value: Any?, field: String) throws -> String {
        let str = try requireString(value, field: field)
        if str.isEmpty {
            throw Error.emptyString(field)
        }
        return str
    }

    private static func ensureStringByteCap(_ value: String, field: String) throws {
        let bytes = value.utf8.count
        if bytes > maxStringFieldBytes {
            throw Error.stringTooLong(field: field, bytes: bytes)
        }
    }

    private static func requireInteger(_ value: Any?, field: String) throws -> Int {
        guard let number = value as? NSNumber else {
            throw Error.wrongFieldType(field)
        }
        // JSONSerialization encodes booleans as NSNumber with objCType "c".
        // `as? Int` would silently coerce true → 1; reject that explicitly.
        let typeCode = String(cString: number.objCType)
        if typeCode == "c" {
            throw Error.wrongFieldType(field)
        }
        // Reject non-integer doubles (e.g. 1.5). Whole doubles like 1.0 are OK.
        if typeCode == "d" || typeCode == "f" {
            let d = number.doubleValue
            if d != d.rounded() {
                throw Error.wrongFieldType(field)
            }
        }
        return number.intValue
    }

    private static func requireBool(_ value: Any, field: String) throws -> Bool {
        guard
            let number = value as? NSNumber,
            String(cString: number.objCType) == "c"
        else {
            throw Error.wrongFieldType(field)
        }
        return number.boolValue
    }

    private static func validateULID(_ value: String, field: String) throws {
        if value.count != 26
            || value.range(of: ulidPattern, options: .regularExpression) == nil
        {
            throw Error.invalidULID(field: field, value: value)
        }
    }
}

// MARK: - NSNumber Bool bridging helper

private func asBool(_ number: NSNumber) -> Bool? {
    String(cString: number.objCType) == "c" ? number.boolValue : nil
}
