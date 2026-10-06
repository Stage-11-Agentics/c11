import Foundation

/// The c11 events-stream envelope (C11-163; schema v2 since C11-337). One `EventEnvelope`
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
/// `spec/event-envelope.v2.schema.json`. v2 renamed the subject refs
/// (`surface`/`pane` → `panel`/`area`), three event types (see
/// `legacyTypeAliases`), the `metadata.changed` scope values, and the caller
/// payload key (`caller_panel_id`). Old logs are never rewritten, so every
/// reader goes through the helpers at the bottom of this file, which accept
/// both v1 and v2 lines.
struct EventEnvelope {

    /// Current envelope schema version. Bumps are breaking.
    static let schemaVersion = 2

    // MARK: - Field-name constants (shared writer/reader vocabulary)

    enum Key {
        static let seq = "seq"
        static let ts = "ts"
        static let type = "type"
        static let instance = "instance"
        static let workspace = "workspace"
        static let panel = "panel"
        static let area = "area"
        // C11-337: v1 spellings of the subject refs. Read-only, accepted forever.
        static let surface = "surface"
        static let pane = "pane"
        static let payload = "payload"
        static let version = "v"
    }

    /// Payload keys whose spelling changed in v2. Writers use the canonical
    /// key; readers go through `callerPanelId(inPayload:)` /
    /// `lifecyclePanel(inPayload:)`, which also accept the legacy spellings.
    enum PayloadKey {
        static let callerPanelId = "caller_panel_id"
        // C11-337: legacy spellings, accepted forever on read.
        static let legacyCallerTabId = "caller_tab_id"
        static let legacyCallerSurfaceId = "caller_surface_id"
        /// `lifecycle.changed` subject panel.
        static let panel = "panel"
        // C11-337: legacy spelling (nightly-only), accepted forever on read.
        static let legacyTab = "tab"
        static let scope = "scope"
    }

    /// `metadata.changed` scope values.
    enum Scope {
        static let panel = "panel"
        static let area = "area"
        // C11-337: v1 spellings, accepted forever on read.
        static let legacySurface = "surface"
        static let legacyPane = "pane"
    }

    // MARK: - Taxonomy

    /// The event-type taxonomy (EVT-2, v2 spellings). Dotted strings; the wire value is the
    /// `rawValue`. `logOpened` / `logRotated` / `logDropped` are stream-control
    /// markers (not taxonomy members) that let consumers detect instance
    /// boundaries, rotation, and backpressure drops.
    enum EventType: String, CaseIterable {
        case surfaceCreated = "panel.created"
        case surfaceClosed = "panel.closed"
        case workspaceSelected = "workspace.selected"
        case workspaceSwitchBlocked = "workspace.switch_blocked"
        case workspaceReordered = "workspace.reordered"
        case metadataChanged = "metadata.changed"
        case livenessDerived = "liveness.derived"
        case waitingEntered = "waiting.entered"
        case waitingLeft = "waiting.left"
        case lifecycleChanged = "lifecycle.changed"
        case flagRaised = "flag.raised"
        case flagLowered = "flag.lowered"
        case flagSuppressed = "flag.suppressed"
        case flagUnsuppressed = "flag.unsuppressed"
        case mailboxAccepted = "mailbox.accepted"
        case tabInputSent = "panel.input_sent"
        case mailboxDelivered = "mailbox.delivered"
        case conversationResumeMode = "conversation.resume.mode"
        case conversationResumeDecision = "conversation.resume.decision"
        case hangPrecursor = "hang.precursor"
        case askOpened = "ask.opened"
        case askClosed = "ask.closed"
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

    /// Produces one NDJSON line (trailing `\n`) with `seq` spliced in. The
    /// stored `surface`/`pane` refs serialize under the v2 keys `panel`/`area`. Keys are
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
        if let surface { object[Key.panel] = surface }
        if let pane { object[Key.area] = pane }
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
        object(fromLine: line)?[key]
    }

    /// Full decode of one raw line into its JSON object; nil for a malformed line.
    static func object(fromLine line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    // MARK: - v1/v2 reader compatibility (C11-337)

    /// v1 event-type spellings mapped to their v2 names. Old logs keep these
    /// spellings forever; readers and filters compare `canonicalType` on both
    /// sides so either spelling matches either line.
    static let legacyTypeAliases: [String: String] = [
        "surface.created": EventType.surfaceCreated.rawValue,
        "surface.closed": EventType.surfaceClosed.rawValue,
        "tab.input_sent": EventType.tabInputSent.rawValue,
    ]

    /// The v2 spelling of an event type (identity for anything not renamed).
    static func canonicalType(_ type: String) -> String {
        legacyTypeAliases[type] ?? type
    }

    /// The canonical type of a raw line, accepting v1 and v2 spellings.
    static func canonicalType(fromLine line: String) -> String? {
        type(fromLine: line).map(canonicalType(_:))
    }

    /// The subject panel of a decoded line: v2 `panel`, then v1 `surface`.
    static func panelRef(in object: [String: Any]) -> String? {
        (object[Key.panel] as? String) ?? (object[Key.surface] as? String)
    }

    /// The subject area of a decoded line: v2 `area`, then v1 `pane`.
    static func areaRef(in object: [String: Any]) -> String? {
        (object[Key.area] as? String) ?? (object[Key.pane] as? String)
    }

    static func panelRef(fromLine line: String) -> String? {
        object(fromLine: line).flatMap(panelRef(in:))
    }

    static func areaRef(fromLine line: String) -> String? {
        object(fromLine: line).flatMap(areaRef(in:))
    }

    /// The caller panel id of a payload: `caller_panel_id`, then
    /// `caller_tab_id`, then `caller_surface_id`. JSON null reads as nil.
    static func callerPanelId(inPayload payload: [String: Any]) -> String? {
        for key in [PayloadKey.callerPanelId, PayloadKey.legacyCallerTabId, PayloadKey.legacyCallerSurfaceId] {
            if let value = payload[key] as? String { return value }
        }
        return nil
    }

    /// The subject panel of a `lifecycle.changed` payload: `panel`, then `tab`.
    static func lifecyclePanel(inPayload payload: [String: Any]) -> String? {
        (payload[PayloadKey.panel] as? String) ?? (payload[PayloadKey.legacyTab] as? String)
    }

    /// The v2 spelling of a `metadata.changed` scope (`surface` → `panel`,
    /// `pane` → `area`; anything else unchanged).
    static func canonicalScope(_ scope: String) -> String {
        switch scope {
        case Scope.legacySurface: return Scope.panel
        case Scope.legacyPane: return Scope.area
        default: return scope
        }
    }
}
