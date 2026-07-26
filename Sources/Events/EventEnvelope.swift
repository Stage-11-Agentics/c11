import Foundation

/// The c11 events-stream envelope (C11-163, schema v1). One `EventEnvelope`
/// serializes to exactly one NDJSON line in the per-instance event log.
///
/// Pure Foundation, no app-only imports — compiled into both the app target
/// (the `EventLog` writer builds and serializes envelopes) and the `c11-cli`
/// target (the `c11 events tail` reader uses the field-name constants and the
/// line-parse helpers to filter). `payload` is deliberately an untyped
/// `[String: Any]` so app-only enums (e.g. `MetadataSource`) never leak into
/// this file — the emit site stringifies such values before handing them over.
///
/// Ordering contract: **`seq` is the sequence oracle**, assigned on the writer's
/// serial queue so file order and seq order always agree. `ts` is captured on
/// the emitting thread and is only approximately monotonic — it may invert
/// slightly relative to `seq` across racing threads. Consumers order by `seq`.
///
/// Canonical source of truth for the on-disk shape is
/// `spec/event-envelope.v1.schema.json`.
struct EventEnvelope {

    /// Current envelope schema version. Bumps are breaking.
    static let schemaVersion = 1

    // MARK: - Field-name constants (shared writer/reader vocabulary)

    enum Key {
        static let seq = "seq"
        static let ts = "ts"
        static let type = "type"
        static let instance = "instance"
        static let workspace = "workspace"
        static let surface = "surface"
        static let pane = "pane"
        static let payload = "payload"
        static let version = "v"
    }

    // MARK: - v1 taxonomy

    /// The v1 event-type taxonomy (EVT-2). Dotted strings; the wire value is the
    /// `rawValue`. `logOpened` / `logRotated` / `logDropped` are stream-control
    /// markers (not taxonomy members) that let consumers detect instance
    /// boundaries, rotation, and backpressure drops.
    enum EventType: String, CaseIterable {
        case surfaceCreated = "surface.created"
        case surfaceClosed = "surface.closed"
        case workspaceSelected = "workspace.selected"
        case metadataChanged = "metadata.changed"
        case livenessDerived = "liveness.derived"
        case waitingEntered = "waiting.entered"
        case waitingLeft = "waiting.left"
        case mailboxAccepted = "mailbox.accepted"
        case mailboxDelivered = "mailbox.delivered"
        case conversationResumeMode = "conversation.resume.mode"
        case conversationResumeDecision = "conversation.resume.decision"
        // Stream-control markers:
        case logOpened = "log.opened"
        case logRotated = "log.rotated"
        case logDropped = "log.dropped"
    }

    // MARK: - Stored fields

    /// Captured on the emitting thread; formatted at serialize time.
    let ts: Date
    let type: String
    let instance: String
    let workspace: String?
    let surface: String?
    let pane: String?
    let payload: [String: Any]

    init(
        type: String,
        instance: String,
        ts: Date,
        workspace: String? = nil,
        surface: String? = nil,
        pane: String? = nil,
        payload: [String: Any] = [:]
    ) {
        self.type = type
        self.instance = instance
        self.ts = ts
        self.workspace = workspace
        self.surface = surface
        self.pane = pane
        self.payload = payload
    }

    init(
        type: EventType,
        instance: String,
        ts: Date,
        workspace: String? = nil,
        surface: String? = nil,
        pane: String? = nil,
        payload: [String: Any] = [:]
    ) {
        self.init(
            type: type.rawValue,
            instance: instance,
            ts: ts,
            workspace: workspace,
            surface: surface,
            pane: pane,
            payload: payload
        )
    }

    // MARK: - Serialization

    /// Produces one NDJSON line (trailing `\n`) with `seq` spliced in. Keys are
    /// sort-encoded so tails are byte-stable across runs; nil subject refs are
    /// omitted rather than encoded as `null`. `.withoutEscapingSlashes` keeps
    /// filesystem paths in payloads readable (Swift would otherwise emit `\/`).
    func serialize(seq: UInt64) -> String {
        var object: [String: Any] = [
            Key.seq: seq,
            Key.ts: Self.formatTimestamp(ts),
            Key.type: type,
            Key.instance: instance,
            Key.version: Self.schemaVersion,
        ]
        if let workspace { object[Key.workspace] = workspace }
        if let surface { object[Key.surface] = surface }
        if let pane { object[Key.pane] = pane }
        if !payload.isEmpty { object[Key.payload] = payload }

        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let line = String(data: data, encoding: .utf8)
        else {
            // Never block observability on a bad payload: fall back to a minimal
            // valid line carrying seq/type so the sequence stays gap-free.
            let fallback = "{\"\(Key.seq)\":\(seq),\"\(Key.type)\":\"\(type)\",\"\(Key.version)\":\(Self.schemaVersion)}"
            return fallback + "\n"
        }
        return line + "\n"
    }

    // MARK: - Timestamp

    /// RFC3339 / ISO-8601 UTC with fractional seconds — matches
    /// `MailboxDispatchLog.formatTimestamp` so both logs sort identically.
    static func formatTimestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Reader helpers (CLI filtering, no full decode needed)

    /// Extracts the `type` field from a raw NDJSON line without a full decode.
    static func type(fromLine line: String) -> String? {
        field(Key.type, fromLine: line) as? String
    }

    /// Extracts the `seq` field from a raw NDJSON line.
    static func seq(fromLine line: String) -> UInt64? {
        guard let raw = field(Key.seq, fromLine: line) else { return nil }
        if let n = raw as? UInt64 { return n }
        if let n = raw as? Int, n >= 0 { return UInt64(n) }
        if let n = raw as? NSNumber { return n.uint64Value }
        return nil
    }

    /// Extracts and parses the `ts` field from a raw NDJSON line.
    static func timestamp(fromLine line: String) -> Date? {
        guard let s = field(Key.ts, fromLine: line) as? String else { return nil }
        return formatter.date(from: s)
    }

    /// Generic single-field read from a raw line. Tolerant of malformed lines
    /// (returns nil rather than throwing) so a partial trailing write never
    /// crashes a tailing consumer.
    static func field(_ key: String, fromLine line: String) -> Any? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key]
    }
}
