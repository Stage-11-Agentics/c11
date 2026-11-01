import Foundation

// Pure feed projection. No I/O, no app types. Compiled into the app and the CLI.
// One row per tab from the journal row, an attention sibling, and a display note.
// Generic `input` is not a kind: the journal has no such fact.

enum FeedScope: String {
    case attention
    case all
}

enum FeedKind: String, Equatable {
    case question
    case plan
    case permission
    case error
    case turnEnd = "turn_end"
}

enum FeedNoteError: String, Error, Equatable {
    case oversize = "note_oversize"
    case overflow = "note_overflow"
    case unmatched = "note_unmatched"
}

/// A named flag carries a stable identifier and an immutable display snapshot.
/// The generic flag has no kind and remains violet. Only these named tokens
/// may tint a flag; gray, blue, gold and violet retain their existing meanings.
enum PanelFlagColorToken: String, CaseIterable, Codable, Hashable, Sendable {
    case green
    case red
    case pink
    case teal

    func hex(lightBackground: Bool) -> String {
        switch (self, lightBackground) {
        case (.green, true): return "#167A42"
        case (.green, false): return "#49C980"
        case (.red, true): return "#B42331"
        case (.red, false): return "#FF6B78"
        case (.pink, true): return "#A91D70"
        case (.pink, false): return "#ED72B6"
        case (.teal, true): return "#00786F"
        case (.teal, false): return "#58C8BE"
        }
    }

    var localizedName: String {
        switch self {
        case .green: return String(localized: "flag.kind.color.green", defaultValue: "Green")
        case .red: return String(localized: "flag.kind.color.red", defaultValue: "Red")
        case .pink: return String(localized: "flag.kind.color.pink", defaultValue: "Pink")
        case .teal: return String(localized: "flag.kind.color.teal", defaultValue: "Teal")
        }
    }
}

/// Registry value and the display data copied onto an active flag. Keeping the
/// same value shape in metadata and events means registry edits cannot repaint
/// an existing flag or rewrite its event history.
struct PanelFlagKind: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let color: PanelFlagColorToken
    let emoji: String?

    var displayLabel: String {
        [emoji, name].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " ")
    }

    func displayText(reason: String) -> String {
        "\(displayLabel): \(reason)"
    }

    func colorHex(lightBackground: Bool) -> String {
        color.hex(lightBackground: lightBackground)
    }

    var isValid: Bool {
        guard Self.isValidSlug(id), Self.isValidName(name) else { return false }
        if let emoji {
            let forbiddenCharacters = CharacterSet.newlines.union(.controlCharacters)
            guard emoji.count == 1,
                  emoji.unicodeScalars.count <= 16,
                  emoji.utf8.count <= 64,
                  emoji == emoji.trimmingCharacters(in: .whitespacesAndNewlines),
                  !emoji.unicodeScalars.contains(where: { forbiddenCharacters.contains($0) })
            else { return false }
        }
        return true
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "name": name,
            "color": color.rawValue,
        ]
        if let emoji { object["emoji"] = emoji }
        return object
    }

    static func fromJSON(_ value: Any?) -> PanelFlagKind? {
        guard let object = value as? [String: Any],
              let id = object["id"] as? String,
              let name = object["name"] as? String,
              let colorRaw = object["color"] as? String,
              let color = PanelFlagColorToken(rawValue: colorRaw) else { return nil }
        let emoji: String?
        if let rawEmoji = object["emoji"], !(rawEmoji is NSNull) {
            guard let parsed = rawEmoji as? String else { return nil }
            emoji = parsed
        } else {
            emoji = nil
        }
        let kind = PanelFlagKind(id: id, name: name, color: color, emoji: emoji)
        return kind.isValid ? kind : nil
    }

    static func isValidSlug(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 48,
              value.first != "-", value.last != "-" else { return false }
        var previousWasHyphen = false
        for scalar in value.unicodeScalars {
            if scalar == "-" {
                guard !previousWasHyphen else { return false }
                previousWasHyphen = true
            } else {
                let isLower = scalar.value >= 97 && scalar.value <= 122
                let isDigit = scalar.value >= 48 && scalar.value <= 57
                guard isLower || isDigit else { return false }
                previousWasHyphen = false
            }
        }
        return true
    }

    static func isValidName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbiddenCharacters = CharacterSet.newlines.union(.controlCharacters)
        return !trimmed.isEmpty && trimmed == value && value.count <= 48
            && !value.unicodeScalars.contains(where: { forbiddenCharacters.contains($0) })
    }
}

struct FeedAttentionFact: Equatable {
    var workspaceID: UUID
    var panelID: UUID
    var flagReason: String?
    var flagRaisedAtMs: Int64?
    var flagCallerPanelID: UUID?
    var flagKind: PanelFlagKind? = nil
    var suppressed: Bool

    var isFlagged: Bool { flagReason != nil }
}

struct FeedFlagFact: Equatable {
    var reason: String
    var raisedAtMs: Int64?
    var callerPanelID: UUID?
    var kind: PanelFlagKind? = nil
}

struct FeedDisplayNote: Equatable {
    var eventID: UUID
    var requestID: String
    var prompt: String?
    var options: [String]?
}

struct FeedRow: Equatable {
    var workspaceID: UUID
    var panelID: UUID
    var kind: FeedKind?
    var prompt: String?
    var options: [String]?
    var promptAvailable: Bool
    var source: String?
    var sourceRank: Int?
    var openedAtMs: Int64?
    var state: String?
    var requestID: String?
    var confirmation: String?
    var blocking: Bool?
    var flag: FeedFlagFact?
    var usageLimit: JournalUsageLimitKind? = nil

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "workspace_id": workspaceID.uuidString,
            "panel_id": panelID.uuidString,
            "kind": kind?.rawValue ?? NSNull(),
            "prompt": prompt ?? NSNull(),
            "options": options ?? NSNull(),
            "prompt_available": promptAvailable,
            "source": source ?? NSNull(),
            "source_rank": sourceRank.map { NSNumber(value: $0) } ?? NSNull(),
            "opened_at_ms": openedAtMs.map { NSNumber(value: $0) } ?? NSNull(),
            "state": state ?? NSNull(),
            "request_id": requestID ?? NSNull(),
            "confirmation": confirmation ?? NSNull(),
            "blocking": blocking ?? NSNull(),
            "usage_limit": usageLimit?.rawValue ?? NSNull(),
        ]
        if let flag {
            object["flag"] = [
                "reason": flag.reason,
                "raised_at_ms": flag.raisedAtMs.map { NSNumber(value: $0) } ?? NSNull(),
                "caller_panel_id": flag.callerPanelID?.uuidString ?? NSNull(),
                "kind": flag.kind?.jsonObject ?? NSNull(),
            ]
        }
        return object
    }
}

enum FeedProjector {
    static func blockingKind(_ snapshot: JournalSnapshot) -> FeedKind? {
        guard snapshot.phase == .blocked else { return nil }
        switch snapshot.reason {
        case .question: return .question
        case .planReview: return .plan
        case .approval: return .permission
        default: return nil
        }
    }

    static func isTurnEnd(_ snapshot: JournalSnapshot) -> Bool {
        snapshot.phase == .idle && snapshot.turnOutcome == "completed"
    }

    /// Infer a close resolution from the fold that replaced the blocked request.
    /// Replacement, tab close, error, and a completed turn stay null.
    static func resolution(after snapshot: JournalSnapshot?) -> String? {
        guard let snapshot else { return nil }
        if snapshot.phase == .working, snapshot.requestID == nil { return "resumed" }
        if snapshot.phase == .unknown, snapshot.requestID == nil { return "unknown" }
        if snapshot.phase == .idle, snapshot.turnOutcome == nil, snapshot.requestID == nil, snapshot.terminalBarrier {
            return "cancelled"
        }
        return nil
    }

    static func project(
        journalRows: [JournalSnapshot],
        attention: [FeedAttentionFact],
        notes: [UUID: [String: FeedDisplayNote]],
        scope: FeedScope
    ) -> [FeedRow] {
        var journals: [UUID: JournalSnapshot] = [:]
        for row in journalRows { journals[row.owner.panelID] = row }
        var flags: [UUID: FeedAttentionFact] = [:]
        for fact in attention { flags[fact.panelID] = fact }
        var rows: [FeedRow] = []
        for panelID in Set(journals.keys).union(flags.keys) {
            if let row = row(panelID: panelID, journal: journals[panelID], attention: flags[panelID], notes: notes[panelID] ?? [:], scope: scope) {
                rows.append(row)
            }
        }
        return AttentionOrder.ordered(rows)
    }

    private static func row(
        panelID: UUID,
        journal: JournalSnapshot?,
        attention: FeedAttentionFact?,
        notes: [String: FeedDisplayNote],
        scope: FeedScope
    ) -> FeedRow? {
        let blocking = journal.flatMap(blockingKind)
        let turn = journal.map(isTurnEnd) ?? false
        let flagged = attention?.isFlagged == true
        let suppressed = attention?.suppressed == true
        let workspaceID = journal?.workspaceID ?? attention?.workspaceID
        guard let workspaceID else { return nil }

        let showBlocking = blocking != nil && (!suppressed || flagged)
        let showTurn = turn && !suppressed && scope == .all
        let limit = journal?.usageLimit
        if !showBlocking && !showTurn && !flagged && limit == nil { return nil }

        let flag = flagged ? FeedFlagFact(
            reason: attention?.flagReason ?? "",
            raisedAtMs: attention?.flagRaisedAtMs,
            callerPanelID: attention?.flagCallerPanelID,
            kind: attention?.flagKind
        ) : nil

        if showBlocking, let journal, let blocking {
            let request = journal.requestID
            let note = request.flatMap { notes[$0] }
            return FeedRow(
                workspaceID: workspaceID,
                panelID: panelID,
                kind: blocking,
                prompt: note?.prompt,
                options: note?.options,
                promptAvailable: note?.prompt != nil || note?.options != nil,
                source: journal.source.rawValue,
                sourceRank: journal.rank,
                openedAtMs: journal.sinceMs > 0 ? journal.sinceMs : nil,
                state: "open",
                requestID: request,
                confirmation: journal.confirmation.rawValue,
                blocking: true,
                flag: flag,
                usageLimit: limit?.kind
            )
        }
        if let limit, let journal {
            return FeedRow(workspaceID: workspaceID, panelID: panelID, kind: .error,
                prompt: nil, options: nil, promptAvailable: false,
                source: journal.source.rawValue, sourceRank: journal.rank,
                openedAtMs: limit.sinceMs, state: "open", requestID: nil,
                confirmation: journal.confirmation.rawValue, blocking: false, flag: flag,
                usageLimit: limit.kind)
        }
        if showTurn, let journal {
            return FeedRow(
                workspaceID: workspaceID,
                panelID: panelID,
                kind: .turnEnd,
                prompt: nil,
                options: nil,
                promptAvailable: false,
                source: journal.source.rawValue,
                sourceRank: journal.rank,
                openedAtMs: journal.sinceMs > 0 ? journal.sinceMs : nil,
                state: nil,
                requestID: nil,
                confirmation: journal.confirmation.rawValue,
                blocking: false,
                flag: flag
            )
        }
        return FeedRow(
            workspaceID: workspaceID,
            panelID: panelID,
            kind: nil,
            prompt: nil,
            options: nil,
            promptAvailable: false,
            source: nil,
            sourceRank: nil,
            openedAtMs: nil,
            state: nil,
            requestID: nil,
            confirmation: nil,
            blocking: nil,
            flag: flag
        )
    }
}

struct FeedAskEvent: Equatable {
    enum Action: String, Equatable { case opened = "ask.opened", closed = "ask.closed" }
    var action: Action
    var workspaceID: UUID?
    var panelID: UUID
    var kind: String
    var source: String
    var sourceRank: Int
    var openedAtMs: Int64
    var state: String
    var requestID: String?
    var confirmation: String
    var blocking: Bool
    var resolution: String?

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "kind": kind,
            "source": source,
            "source_rank": NSNumber(value: sourceRank),
            "opened_at_ms": NSNumber(value: openedAtMs),
            "state": state,
            "request_id": requestID ?? NSNull(),
            "confirmation": confirmation,
            "blocking": blocking,
        ]
        if action == .closed { object["resolution"] = resolution ?? NSNull() }
        return object
    }
}

struct FeedAskTracker {
    private struct Tracked: Equatable {
        var kind: FeedKind
        var requestID: String?
        var workspaceID: UUID?
        var source: String
        var sourceRank: Int
        var openedAtMs: Int64
        var confirmation: String
        var emittedOpen: Bool
    }

    private var tracked: [UUID: Tracked] = [:]
    private var sequences: [UUID: Int64] = [:]

    mutating func consume(panelID: UUID, snapshot: JournalSnapshot?) -> [FeedAskEvent] {
        if let snapshot {
            if let seen = sequences[panelID], snapshot.lastSequence < seen { return [] }
            sequences[panelID] = snapshot.lastSequence
        } else {
            sequences.removeValue(forKey: panelID)
        }
        let nextKind = snapshot.flatMap(FeedProjector.blockingKind)
        guard let snapshot, let nextKind else {
            return retire(panelID: panelID, after: snapshot)
        }
        let identityMatches = tracked[panelID].map { $0.kind == nextKind && $0.requestID == snapshot.requestID } ?? false
        if identityMatches {
            tracked[panelID]?.confirmation = snapshot.confirmation.rawValue
            tracked[panelID]?.source = snapshot.source.rawValue
            tracked[panelID]?.sourceRank = snapshot.rank
            return []
        }
        var events = retire(panelID: panelID, after: snapshot, replacement: true)
        let openedAt = snapshot.sinceMs > 0 ? snapshot.sinceMs : 0
        let emitOpen = snapshot.confirmation == .confirmed
        tracked[panelID] = Tracked(
            kind: nextKind,
            requestID: snapshot.requestID,
            workspaceID: snapshot.workspaceID,
            source: snapshot.source.rawValue,
            sourceRank: snapshot.rank,
            openedAtMs: openedAt,
            confirmation: snapshot.confirmation.rawValue,
            emittedOpen: emitOpen
        )
        if emitOpen {
            events.append(FeedAskEvent(
                action: .opened,
                workspaceID: snapshot.workspaceID,
                panelID: panelID,
                kind: nextKind.rawValue,
                source: snapshot.source.rawValue,
                sourceRank: snapshot.rank,
                openedAtMs: openedAt,
                state: "open",
                requestID: snapshot.requestID,
                confirmation: snapshot.confirmation.rawValue,
                blocking: true,
                resolution: nil
            ))
        }
        return events
    }

    private mutating func retire(panelID: UUID, after snapshot: JournalSnapshot?, replacement: Bool = false) -> [FeedAskEvent] {
        guard let previous = tracked.removeValue(forKey: panelID), previous.emittedOpen else { return [] }
        let resolution = replacement && snapshot.flatMap(FeedProjector.blockingKind) != nil
            ? nil
            : FeedProjector.resolution(after: snapshot)
        return [FeedAskEvent(
            action: .closed,
            workspaceID: previous.workspaceID ?? snapshot?.workspaceID,
            panelID: panelID,
            kind: previous.kind.rawValue,
            source: previous.source,
            sourceRank: previous.sourceRank,
            openedAtMs: previous.openedAtMs,
            state: "closed",
            requestID: previous.requestID,
            confirmation: snapshot?.confirmation.rawValue ?? previous.confirmation,
            blocking: true,
            resolution: resolution
        )]
    }
}

enum FeedWatchSignal: Equatable {
    case continuityUnavailable
    case followedEvent(String)
}

struct FeedWatchParser {
    static let followed: Set<String> = [
        "ask.opened", "ask.closed",
        "flag.raised", "flag.lowered", "flag.suppressed", "flag.unsuppressed",
        "log.opened", "log.rotated", "log.dropped",
    ]

    private(set) var partial = ""
    private(set) var lastSeq: Int64?

    mutating func consume(_ chunk: String) -> [FeedWatchSignal] {
        partial.append(contentsOf: chunk)
        var signals: [FeedWatchSignal] = []
        while let newline = partial.firstIndex(of: "\n") {
            var line = String(partial[..<newline])
            partial = String(partial[partial.index(after: newline)...])
            if line.hasSuffix("\r") { line.removeLast() }
            signals.append(contentsOf: consumeLine(line))
        }
        return signals
    }

    private mutating func consumeLine(_ line: String) -> [FeedWatchSignal] {
        if line.isEmpty { return [] }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seq = Self.int64(object["seq"]),
              let type = object["type"] as? String else { return [] }
        var continuity = type == "log.dropped"
        if let lastSeq {
            if seq < lastSeq || seq > lastSeq + 1 { continuity = true }
            if type == "log.opened" { continuity = true }
        }
        self.lastSeq = seq
        if continuity { return [.continuityUnavailable] }
        if Self.followed.contains(type) { return [.followedEvent(type)] }
        return []
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as Int: return Int64(number)
        case let number as Int64: return number
        case let number as NSNumber: return number.int64Value
        default: return nil
        }
    }
}

enum FeedNoteLimits {
    static let maxNotes = 256
    static let maxBytes = 512 * 1024
    static let maxPromptBytes = 1024
    static let maxOptions = 12
    static let maxLabelBytes = 128

    /// Keep a UTF-8 prefix. A scalar that would be split is left out.
    static func prefix(_ text: String, maxBytes: Int) -> String {
        if maxBytes <= 0 { return "" }
        let utf8 = Array(text.utf8)
        if utf8.count <= maxBytes { return text }
        var end = maxBytes
        while end > 0, (utf8[end] & 0xC0) == 0x80 { end -= 1 }
        let lead = utf8[end]
        let width: Int
        if lead < 0x80 { width = 1 }
        else if lead & 0xE0 == 0xC0 { width = 2 }
        else if lead & 0xF0 == 0xE0 { width = 3 }
        else if lead & 0xF8 == 0xF0 { width = 4 }
        else { width = 1 }
        if end + width > maxBytes { /* drop the partial scalar */ }
        else { end += width }
        return String(decoding: Data(utf8[0..<end]), as: UTF8.self)
    }

    static func bound(prompt: String?, options: [String]?) -> (prompt: String?, options: [String]?) {
        let boundedPrompt = prompt.map { prefix($0, maxBytes: maxPromptBytes) }
        let boundedOptions = options.map { labels in
            labels.prefix(maxOptions).map { prefix($0, maxBytes: maxLabelBytes) }
        }
        return (boundedPrompt, boundedOptions)
    }
}

enum FeedDisplayExtract {
    /// Copy only the bounded display fields a hook already has. Unknown shape stays null.
    /// An empty options array means the hook extracted zero labels.
    static func claude(toolName: String?, object: [String: Any]?) -> (prompt: String?, options: [String]?) {
        let raw = unbounded(toolName: toolName, object: object)
        return FeedNoteLimits.bound(prompt: raw.prompt, options: raw.options)
    }

    private static func unbounded(toolName: String?, object: [String: Any]?) -> (prompt: String?, options: [String]?) {
        guard let object, let input = object["tool_input"] as? [String: Any] else { return (nil, nil) }
        if toolName == "ExitPlanMode" {
            return (input["plan"] as? String, nil)
        }
        guard toolName == "AskUserQuestion",
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first else { return (nil, nil) }
        let prompt: String?
        if let question = first["question"] as? String, !question.isEmpty {
            prompt = question
        } else if let header = first["header"] as? String, !header.isEmpty {
            prompt = header
        } else {
            prompt = nil
        }
        let options: [String]?
        if let raw = first["options"] as? [String] {
            return (prompt, raw)
        }
        if let raw = first["options"] as? [[String: Any]] {
            let labels = raw.compactMap { $0["label"] as? String }
            return labels.count == raw.count ? (prompt, labels) : (prompt, nil)
        }
        if first["options"] != nil { return (prompt, nil) }
        return (prompt, nil)
    }
}
