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
    /// `rawValue`. `logOpened` / `logRotated` / `logDropped` / `logPolicy` / `logRetention` are stream-control
    /// markers (not taxonomy members) that let consumers detect instance
    /// boundaries, rotation, and backpressure drops.
    enum EventType: String, CaseIterable {
        case surfaceCreated = "panel.created"
        case surfaceClosed = "panel.closed"
        case appActivated = "app.activated"
        case appDeactivated = "app.deactivated"
        case screenLocked = "screen.locked"
        case screenUnlocked = "screen.unlocked"
        case systemSleep = "system.sleep"
        case systemWake = "system.wake"
        case instanceSample = "instance.sample"
        case workspaceCreated = "workspace.created"
        case workspaceRenamed = "workspace.renamed"
        case workspaceClosed = "workspace.closed"
        case workspaceSelected = "workspace.selected"
        case workspaceSwitchBlocked = "workspace.switch_blocked"
        case workspaceReordered = "workspace.reordered"
        // c11 (C11H-197): display and window geometry.
        case displayChanged = "display.changed"
        case windowMoved = "window.moved"
        case areaSplit = "area.split"
        case areaClosed = "area.closed"
        case flashRequested = "flash.requested"
        case flashDrawn = "flash.drawn"
        case metadataChanged = "metadata.changed"
        case livenessDerived = "liveness.derived"
        case waitingEntered = "waiting.entered"
        case waitingLeft = "waiting.left"
        case lifecycleChanged = "lifecycle.changed"
        case supervisorWaitingOnPermission = "supervisor.waiting_on_permission"
        case supervisorPermissionCleared = "supervisor.permission_cleared"
        case supervisorTurnInterrupted = "supervisor.turn_interrupted"
        case supervisorStalled = "supervisor.stalled"
        case supervisorStallCleared = "supervisor.stall_cleared"
        /// C11H-320 PR 3: one agent's `blocked` and `stalled` verdicts (as
        /// `c11 fleet` shows them) starting, changing and ending.
        case agentBlocked = "agent.blocked"
        case agentUnblocked = "agent.unblocked"
        case agentStalled = "agent.stalled"
        case agentUnstalled = "agent.unstalled"
        /// A seat's agent did not come back after a host end and waits for
        /// the operator (`c11 restore run`); once per seat per launch.
        case agentRestoreNeedsOperator = "agent.restore_needs_operator"
        case flagRaised = "flag.raised"
        case flagLowered = "flag.lowered"
        case flagSuppressed = "flag.suppressed"
        case flagUnsuppressed = "flag.unsuppressed"
        // c11 (C11H-246): a flag's system notification posted, replaced,
        // skipped because the operator was looking, failed, or removed.
        case notificationFlag = "notification.flag"
        // c11 (C11H-319): a turn-end or needs-you system notification posted
        // or failed, with the sound it played.
        case notificationRoutine = "notification.routine"
        case mailboxAccepted = "mailbox.accepted"
        case panelInputSent = "panel.input_sent"
        case mailboxDelivered = "mailbox.delivered"
        case mailboxNativeUnconfirmed = "mailbox.native_unconfirmed"
        case appRelaunched = "app.relaunched"
        case conversationResumeMode = "conversation.resume.mode"
        case conversationResumeDecision = "conversation.resume.decision"
        case conversationResumeRefused = "conversation.resume.refused"
        case conversationStartupAudit = "conversation.startup_audit"
        case hangPrecursor = "hang.precursor"
        // c11 (C11H-238): every ended main-thread stall.
        case mainStall = "main.stall"
        case askOpened = "ask.opened"
        case askClosed = "ask.closed"
        // c11 (C11H-235): a signal c11 did not send ended a local terminal's
        // root, and several such ends together.
        case terminalEndedBySignal = "terminal.ended_by_signal"
        case terminalMassSignalEnd = "terminal.mass_signal_end"
        // Stream-control markers:
        case logPolicy = "log.policy"
        case logRetention = "log.retention"
        case logOpened = "log.opened"
        case logRotated = "log.rotated"
        case logDropped = "log.dropped"
    }

    // MARK: - Stored fields

    /// Closed membership for the CLI's supervisor subscription.
    static let supervisorTypes: Set<String> = [
        EventType.lifecycleChanged.rawValue,
        EventType.supervisorWaitingOnPermission.rawValue,
        EventType.supervisorPermissionCleared.rawValue,
        EventType.supervisorTurnInterrupted.rawValue,
        EventType.supervisorStalled.rawValue,
        EventType.supervisorStallCleared.rawValue,
    ]

    /// Closed membership for `events tail --filter agent` (C11H-320 PR 3).
    static let agentTypes: Set<String> = [
        EventType.agentBlocked.rawValue,
        EventType.agentUnblocked.rawValue,
        EventType.agentStalled.rawValue,
        EventType.agentUnstalled.rawValue,
        EventType.agentRestoreNeedsOperator.rawValue,
    ]

    static func matchesFilter(_ filter: String?, type: String?) -> Bool {
        guard let filter else { return true }
        guard let type else { return false }
        switch filter {
        case "supervisor": return supervisorTypes.contains(type)
        case "agent": return agentTypes.contains(type)
        default: return canonicalType(filter) == canonicalType(type)
        }
    }

    /// `events tail`'s `--filter` values (C11H-320 PR 3), each given once or
    /// more. Every value is one predicate and a line must pass them all:
    /// `type=<t>` (or a bare dotted type) the exact type, `supervisor` and
    /// `agent` their closed sets, `workspace=<uuid>` and `panel=<uuid>` the
    /// line's subject. A type outside the closed taxonomy (its documented v1
    /// spellings included), a malformed UUID or an unknown keyword is an
    /// error, never an empty stream.
    struct TailFilter: Equatable {
        enum Predicate: Equatable {
            case type(String)
            case group(String)
            case workspace(String)
            case panel(String)
        }

        var predicates: [Predicate] = []

        static let groupNames: Set<String> = ["supervisor", "agent"]

        /// Every type this build writes or reads: the v2 enum and the v1 spellings.
        static var knownTypes: Set<String> {
            Set(EventType.allCases.map(\.rawValue)).union(legacyTypeAliases.keys)
        }

        static func parse(_ values: [String]) -> Result<TailFilter, TailFilterError> {
            var filter = TailFilter()
            func typePredicate(_ raw: String) -> Result<Predicate, TailFilterError> {
                guard !raw.isEmpty else { return .failure(.init("--filter type= needs an event type")) }
                guard knownTypes.contains(raw) else {
                    return .failure(.init("--filter: '\(raw)' is not an event type this build writes; see c11 guide events"))
                }
                return .success(.type(canonicalType(raw)))
            }
            for raw in values {
                let value = raw.trimmingCharacters(in: .whitespaces)
                let predicate: Result<Predicate, TailFilterError>
                if groupNames.contains(value) {
                    predicate = .success(.group(value))
                } else if let type = value.dropPrefix("type=") {
                    predicate = typePredicate(type)
                } else if let id = value.dropPrefix("workspace=") {
                    predicate = UUID(uuidString: id).map { .success(.workspace($0.uuidString)) }
                        ?? .failure(.init("--filter workspace= takes a workspace UUID (events tail reads the log without the app, so it cannot resolve workspace:N)"))
                } else if let id = value.dropPrefix("panel=") {
                    predicate = UUID(uuidString: id).map { .success(.panel($0.uuidString)) }
                        ?? .failure(.init("--filter panel= takes a panel UUID (events tail reads the log without the app, so it cannot resolve panel:N)"))
                } else if !value.contains("="), value.contains(".") {
                    // A bare event type, as `--filter panel.closed` always read.
                    predicate = typePredicate(value)
                } else {
                    predicate = .failure(.init("--filter takes type=<type>, supervisor, agent, workspace=<uuid> or panel=<uuid>, not '\(raw)'"))
                }
                switch predicate {
                case .success(let parsed): filter.predicates.append(parsed)
                case .failure(let error): return .failure(error)
                }
            }
            return .success(filter)
        }

        /// Whether a line with this type and subject passes every predicate.
        func matches(type: String?, workspace: String?, panel: String?) -> Bool {
            let canonical = type.map(canonicalType)
            let workspace = workspace.flatMap(UUID.init(uuidString:))?.uuidString
            let panel = panel.flatMap(UUID.init(uuidString:))?.uuidString
            for predicate in predicates {
                switch predicate {
                case .type(let wanted): guard canonical == wanted else { return false }
                case .group(let name): guard matchesFilter(name, type: canonical) else { return false }
                case .workspace(let id): guard workspace == id else { return false }
                case .panel(let id): guard panel == id else { return false }
                }
            }
            return true
        }

        /// One raw NDJSON line against the filters and `--since` (a seq floor
        /// or a time), as `events tail` prints it; one decode.
        func admits(line: String, sinceSeq: UInt64? = nil, sinceDate: Date? = nil) -> Bool {
            guard !predicates.isEmpty || sinceSeq != nil || sinceDate != nil else { return true }
            guard let object = EventEnvelope.object(fromLine: line) else { return false }
            if let sinceSeq {
                guard let raw = object[Key.seq] as? NSNumber, raw.uint64Value >= sinceSeq else { return false }
            }
            if let sinceDate {
                guard let text = object[Key.ts] as? String, let ts = formatter.date(from: text), ts >= sinceDate else { return false }
            }
            return matches(type: object[Key.type] as? String, workspace: object[Key.workspace] as? String,
                           panel: EventEnvelope.panelRef(in: object))
        }

        func matches(line: String) -> Bool { admits(line: line) }
    }

    struct TailFilterError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

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
        "tab.input_sent": EventType.panelInputSent.rawValue,
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

private extension String {
    /// The rest after `prefix`, or nil when the string does not start with it.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
