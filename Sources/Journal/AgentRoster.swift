import Foundation

enum JournalReplayPolicy {
    static func restored(_ baseline: JournalSnapshot) -> JournalSnapshot {
        var copy = baseline
        copy.confirmation = .unconfirmed
        copy.connection = .disconnected
        return copy
    }

    static func attention(_ baseline: JournalSnapshot, matching owner: JournalOwner?) -> JournalSnapshot? {
        guard baseline.owner == owner, baseline.paintsAttention else { return nil }
        return restored(baseline)
    }
}

/// Pure join of live tab facts and journal rows. No I/O, no AppKit, no focus.
enum AgentRoster {
    static let restoreLimit = 64
    /// Device-independent Shift, Control, Option, and Command bits.
    static let shiftModifier: UInt = 1 << 17
    static let controlModifier: UInt = 1 << 18
    static let optionModifier: UInt = 1 << 19
    static let commandModifier: UInt = 1 << 20
    static let blockedModifiers: UInt = shiftModifier | controlModifier | optionModifier | commandModifier

    struct RetainedEvent {
        let event: JournalEvent

        var sequence: Int64 { event.sequence }
        var committedAtMs: Int64 { event.committedAtMs }
        var draft: JournalDraft { event.draft }
        var effect: JournalEffect { event.effect }
        var attribution: String { event.attribution }
        var toPhase: JournalPhase? { event.toPhase }
    }

    struct LiveTab {
        var tabID: UUID
        var workspaceID: UUID
        var sessionID: String?
        var kind: String?
        var snapshot: JournalSnapshot?
        var turnStartedMs: Int64?
        var flagged: Bool
        var suppressed: Bool
        var lastSeenAt: Date?
    }

    struct RestoreClassification: Equatable {
        var label: String
        var coverage: String
        var connection: String
    }

    enum SheetActivity {
        case running, idle, waiting, other
    }

    struct SheetClock: Equatable {
        var applies: Bool
        var since: Date?
    }

    static let pickerCommitKeyCode: UInt16? = nil

    static func isPotentialSubmitKey(_ keyCode: UInt16) -> Bool {
        keyCode == 36 || keyCode == 76 || (pickerCommitKeyCode.map { $0 == keyCode } ?? false)
    }

    private static func isBehindBaseline(_ event: RetainedEvent, through sequence: Int64?) -> Bool {
        guard let sequence else { return true }
        return event.sequence <= sequence
    }

    static func waitingReason(_ reason: JournalReason?) -> String? {
        switch reason {
        case .approval, .question, .planReview: return reason?.rawValue
        default: return nil
        }
    }

    static func isoSeconds(ms: Int64) -> String {
        isoSeconds(date: Date(timeIntervalSince1970: Double(ms / 1000)))
    }

    static func isoSeconds(date: Date) -> String {
        let whole = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: whole)
    }

    static func unavailableDocument() -> [String: Any] {
        [
            "schema_version": 1,
            "live_identity": "unavailable",
            "coverage": ["health": "degraded", "storage": "unavailable", "unattributed": 0],
            "tabs": [],
            "restore_candidates": [],
        ]
    }

    static func document(
        live: [LiveTab],
        currents: [JournalSnapshot],
        eventsByOwner: [String: [RetainedEvent]],
        truncatedOwners: Set<String>,
        unattributed: Int,
        storePruned: Bool,
        storageAvailable: Bool,
        healthDegraded: Bool,
        now: Int64,
        liveIdentity: String
    ) -> [String: Any] {
        let tabs = live.sorted { $0.tabID.uuidString < $1.tabID.uuidString }.map { tabJSON($0, now: now) }
        let candidates: [[String: Any]]
        if storageAvailable {
            candidates = currents.filter(\.isHistorical).sorted { $0.owner.key < $1.owner.key }.map { row in
                let events = eventsByOwner[row.owner.key] ?? []
                let classified = classifyRestore(
                    eventsNewestFirst: events,
                    throughSequence: row.lastSequence,
                    truncated: truncatedOwners.contains(row.owner.key),
                    storePruned: storePruned
                )
                return candidateJSON(row, classification: classified)
            }
        } else {
            candidates = []
        }
        return [
            "schema_version": 1,
            "live_identity": liveIdentity,
            "coverage": [
                "health": healthDegraded || !storageAvailable ? "degraded" : "ok",
                "storage": storageAvailable ? "ok" : "unavailable",
                "unattributed": storageAvailable ? unattributed : 0,
            ],
            "tabs": tabs,
            "restore_candidates": candidates,
        ]
    }

    static func classifyRestore(
        eventsNewestFirst: [RetainedEvent],
        throughSequence: Int64? = nil,
        truncated: Bool,
        storePruned: Bool
    ) -> RestoreClassification {
        var sawStart = false
        var endedAfter = false
        var lostAfter = false
        let committedEvidence = eventsNewestFirst.filter {
            $0.effect == .applied && $0.attribution == "exact" && isBehindBaseline($0, through: throughSequence)
        }
        for event in committedEvidence.reversed() {
            if event.draft.kind == .sessionStarted {
                sawStart = true
                endedAfter = false
                lostAfter = false
            } else if event.draft.kind == .sessionEnded, sawStart {
                endedAfter = true
            } else if event.draft.signal == .connectionLost, sawStart {
                lostAfter = true
            }
        }
        if sawStart && endedAfter {
            return RestoreClassification(label: "ended", coverage: "retained", connection: "disconnected")
        }
        if sawStart {
            return RestoreClassification(
                label: "historical_candidate",
                coverage: "retained",
                connection: lostAfter ? "disconnected" : "unknown"
            )
        }
        let lost = committedEvidence.contains { $0.draft.signal == .connectionLost }
        return RestoreClassification(
            label: "unknown",
            coverage: truncated || storePruned ? "event_pruned" : "retained",
            connection: lost ? "disconnected" : "unknown"
        )
    }

    static func turnStartMs(turnID: String?, throughSequence: Int64? = nil, eventsNewestFirst: [RetainedEvent]) -> Int64? {
        guard let turnID,
              let row = eventsNewestFirst.first(where: {
                  $0.effect == .applied && $0.attribution == "exact"
                      && isBehindBaseline($0, through: throughSequence)
                      && $0.toPhase == .working && $0.draft.kind == .turnStarted && $0.draft.turnID == turnID
              }) else {
            return nil
        }
        if row.draft.timeQuality == .nativeLocal { return row.draft.occurredAtMs }
        return row.committedAtMs
    }

    static func restoredAsk(
        snapshot: JournalSnapshot,
        eventsNewestFirst: [RetainedEvent]
    ) -> (requestID: String?, eventID: UUID, openedAtMs: Int64, draft: JournalDraft)? {
        guard snapshot.phase == .blocked,
              let row = eventsNewestFirst.first(where: {
                  $0.effect == .applied && $0.attribution == "exact" && $0.sequence <= snapshot.lastSequence
                      && $0.toPhase == .blocked && isAsk($0.draft.kind)
                      && (snapshot.requestID == nil || $0.draft.requestID == snapshot.requestID)
              }) else { return nil }
        let opened = row.draft.timeQuality == .nativeLocal ? (row.draft.occurredAtMs ?? row.committedAtMs) : row.committedAtMs
        return (row.draft.requestID, row.draft.eventID, opened, row.draft)
    }

    static func isAsk(_ kind: JournalKind) -> Bool {
        kind == .questionRequested || kind == .approvalRequested || kind == .planReviewRequested
    }

    static func lifecyclePayload(
        effect: JournalEffect,
        from: JournalPhase?,
        to: JournalPhase?,
        tab: UUID,
        agent: String,
        reason: JournalReason?
    ) -> [String: Any]? {
        guard effect == .applied, let to, from != to else { return nil }
        return [
            "tab": tab.uuidString,
            "agent": agent,
            "from": from?.rawValue ?? NSNull(),
            "to": to.rawValue,
            "reason": waitingReason(reason) ?? NSNull(),
        ]
    }

    /// Q2 wait is response time minus ask-open time. Missing evidence is nil.
    static func waitMs(responseAt: Int64?, askOpenedAt: Int64?) -> Int64? {
        guard let responseAt, let askOpenedAt, responseAt >= askOpenedAt else { return nil }
        return responseAt - askOpenedAt
    }

    static func isTerminalSubmit(keyCode: UInt16, modifierRaw: UInt, isRepeat: Bool, synthesizing: Bool, hasMarkedText: Bool) -> Bool {
        guard !isRepeat, !synthesizing, !hasMarkedText, keyCode == 36 || keyCode == 76 else { return false }
        return modifierRaw & blockedModifiers == 0
    }

    /// `pickerKeyCode` nil means no fixture has named a commit key, so nothing matches.
    static func isPickerCommit(
        keyCode: UInt16,
        modifierRaw: UInt,
        isRepeat: Bool,
        synthesizing: Bool,
        hasMarkedText: Bool,
        pickerKeyCode: UInt16?,
        pickerModifierRaw: UInt
    ) -> Bool {
        guard let pickerKeyCode, keyCode == pickerKeyCode, !isRepeat, !synthesizing, !hasMarkedText else { return false }
        return (modifierRaw & blockedModifiers) == (pickerModifierRaw & blockedModifiers)
    }

    static func isOperatorSubmit(
        keyCode: UInt16,
        modifierRaw: UInt,
        isRepeat: Bool,
        synthesizing: Bool,
        hasMarkedText: Bool,
        requiresPickerCommit: Bool,
        pickerKeyCode: UInt16?,
        pickerModifierRaw: UInt
    ) -> Bool {
        if requiresPickerCommit {
            return isPickerCommit(
                keyCode: keyCode, modifierRaw: modifierRaw, isRepeat: isRepeat,
                synthesizing: synthesizing, hasMarkedText: hasMarkedText,
                pickerKeyCode: pickerKeyCode, pickerModifierRaw: pickerModifierRaw)
        }
        return isTerminalSubmit(
            keyCode: keyCode, modifierRaw: modifierRaw, isRepeat: isRepeat,
            synthesizing: synthesizing, hasMarkedText: hasMarkedText)
    }

    static func sheetClock(phase: JournalPhase, activity: SheetActivity, flagged: Bool, historical: Bool, sinceMs: Int64) -> SheetClock {
        if flagged || (activity == .waiting && phase != .blocked) { return SheetClock(applies: false, since: nil) }
        if historical { return SheetClock(applies: true, since: nil) }
        switch (phase, activity) {
        case (.working, .running), (.idle, .idle), (.blocked, .waiting):
            return SheetClock(applies: true, since: Date(timeIntervalSince1970: Double(sinceMs / 1000)))
        default:
            return SheetClock(applies: false, since: nil)
        }
    }

    private static func tabJSON(_ row: LiveTab, now: Int64) -> [String: Any] {
        let snap = row.snapshot
        return [
            "panel_id": row.tabID.uuidString,
            // C11-337: legacy spelling, emitted beside panel_id.
            "tab_id": row.tabID.uuidString,
            "workspace_id": row.workspaceID.uuidString,
            "session_id": row.sessionID ?? NSNull(),
            "kind": row.kind ?? NSNull(),
            "model": snap?.modelID ?? NSNull(),
            "state": snap?.phase.rawValue ?? NSNull(),
            "reason": waitingReason(snap?.reason) ?? NSNull(),
            "since": snap.map { isoSeconds(ms: $0.sinceMs) } ?? NSNull(),
            "source": snap?.source.rawValue ?? NSNull(),
            "freshness": snap.map { $0.isFresh(at: now) ? "fresh" : "stale" } ?? NSNull(),
            "confirmation": snap?.confirmation.rawValue ?? NSNull(),
            "connection": snap?.connection.rawValue ?? NSNull(),
            "health": snap?.health.rawValue ?? NSNull(),
            "turn_outcome": snap?.turnOutcome ?? NSNull(),
            "turn_started_at": row.turnStartedMs.map { isoSeconds(ms: $0) } ?? NSNull(),
            "flag": row.flagged,
            "suppressed": row.suppressed,
            "last_seen_at": row.lastSeenAt.map { isoSeconds(date: $0) } ?? NSNull(),
        ]
    }

    private static func candidateJSON(_ row: JournalSnapshot, classification: RestoreClassification) -> [String: Any] {
        [
            "panel_id": row.owner.tabID.uuidString,
            // C11-337: legacy spelling, emitted beside panel_id.
            "tab_id": row.owner.tabID.uuidString,
            "workspace_id": row.workspaceID?.uuidString ?? NSNull(),
            "session_id": row.owner.sessionID,
            "agent_kind": row.owner.agentKind,
            "model": row.modelID ?? NSNull(),
            "state": row.phase.rawValue,
            "reason": waitingReason(row.reason) ?? NSNull(),
            "since": isoSeconds(ms: row.sinceMs),
            "source": row.source.rawValue,
            "label": classification.label,
            "confirmation": "unconfirmed",
            "connection": classification.connection,
            "coverage": classification.coverage,
        ]
    }
}

struct OperatorResponseGate: Equatable {
    struct Key: Hashable { var tab: UUID; var ask: UUID }
    private var pending: Set<Key> = []
    private var recorded: Set<Key> = []

    mutating func begin(tab: UUID, ask: UUID) -> Bool {
        let key = Key(tab: tab, ask: ask)
        guard !pending.contains(key), !recorded.contains(key) else { return false }
        pending.insert(key)
        return true
    }

    mutating func succeed(tab: UUID, ask: UUID) {
        let key = Key(tab: tab, ask: ask)
        pending.remove(key)
        recorded.insert(key)
    }

    mutating func fail(tab: UUID, ask: UUID) {
        pending.remove(Key(tab: tab, ask: ask))
    }

    mutating func clear(tab: UUID) {
        pending.subtract(pending.filter { $0.tab == tab })
        recorded.subtract(recorded.filter { $0.tab == tab })
    }
}
