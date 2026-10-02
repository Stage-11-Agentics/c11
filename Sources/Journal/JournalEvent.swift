import Foundation

// Structural lifecycle evidence only. Never add a free-form payload to this type.
enum JournalError: String, Error {
    case invalidEvent = "invalid_event"
    case expired
    case conflict = "idempotency_conflict"
    case busy = "journal_busy"
    case full = "journal_full"
    case unavailable = "storage_unavailable"
    case unsupportedVersion = "unsupported_version"
}

enum JournalKind: String, Codable, CaseIterable {
    case sessionStarted = "agent.session.started", sessionEnded = "agent.session.ended"
    case turnStarted = "agent.turn.started", turnCompleted = "agent.turn.completed"
    case turnInterrupted = "agent.turn.interrupted"
    case childSpawned = "agent.child.spawned", childCompleted = "agent.child.completed", childFailed = "agent.child.failed"
    case approvalRequested = "agent.approval.requested", questionRequested = "agent.question.requested"
    case planReviewRequested = "agent.plan_review.requested", errorReported = "agent.error.reported"
    case stateChanged = "agent.state.changed", idleObserved = "agent.idle.observed"
    case attentionResolved = "agent.attention.resolved", messagePublished = "agent.message.published"
}

enum JournalSource: String, Codable {
    case hook, plugin, transcript, screen, shell, keypress, selfReport = "self_report", c11
    var rank: Int {
        switch self {
        case .hook: return 60
        case .plugin: return 50
        case .transcript: return 40
        case .screen: return 30
        case .shell: return 20
        case .keypress, .selfReport: return 10
        case .c11: return 0
        }
    }
}

enum JournalAdapter: String, Codable {
    case claudeHook = "claude_hook", opencodePlugin = "opencode_plugin", piPlugin = "pi_plugin"
    case codexNotify = "codex_notify", codexTranscript = "codex_transcript", grokTranscript = "grok_transcript"
    case shell, keypress, selfReport = "self_report", c11
    var source: JournalSource {
        switch self {
        case .claudeHook, .codexNotify: return .hook
        case .opencodePlugin, .piPlugin: return .plugin
        case .codexTranscript, .grokTranscript: return .transcript
        case .shell: return .shell
        case .keypress: return .keypress
        case .selfReport: return .selfReport
        case .c11: return .c11
        }
    }
    var capabilities: [String] {
        switch self {
        case .claudeHook: return ["session", "turn", "blocked", "error"]
        case .opencodePlugin: return ["session", "turn", "blocked", "error"]
        case .piPlugin, .codexNotify: return ["turn"]
        case .codexTranscript, .grokTranscript: return ["turn", "interrupt"]
        case .c11: return ["control"]
        default: return []
        }
    }
}

enum JournalTimeQuality: String, Codable { case nativeLocal = "native_local", observed, missing }
enum JournalToolClass: String, Codable { case askUserQuestion = "ask_user_question", exitPlanMode = "exit_plan_mode", other }
enum JournalSignal: String, Codable {
    case toolActivity = "tool_activity", operatorResponse = "operator_response", connectionLost = "connection_lost"
    case adapterGap = "adapter_gap", adapterRecovered = "adapter_recovered"
    case legacyWorking = "legacy_working", legacyIdle = "legacy_idle", observation
}
enum JournalResolution: String, Codable { case resumed, cancelled, unknown }
enum JournalReason: String, Codable { case approval, question, planReview = "plan_review", sessionFailure = "session_failure", toolFailure = "tool_failure", observation }

struct JournalOwner: Codable, Hashable {
    let tabID: UUID
    let agentKind: String
    let sessionID: String
    // JSON is unambiguous even when an opaque session ID contains punctuation.
    var key: String { String(data: try! JSONEncoder().encode([tabID.uuidString, agentKind, sessionID]), encoding: .utf8)! }
}

struct JournalDraft: Codable, Equatable {
    var schemaVersion = 1
    var eventID = UUID()
    var kind: JournalKind
    var emittedAtMs: Int64
    var occurredAtMs: Int64? = nil
    var timeQuality: JournalTimeQuality = .missing
    var tabID: UUID? = nil
    var workspaceID: UUID? = nil
    var sessionID: String? = nil
    var agentKind: String
    var isChild = false
    var parentSessionID: String? = nil
    var source: JournalSource
    var adapter: JournalAdapter
    var adapterVersion = "1"
    var nativeEvent = "other"
    var turnID: String? = nil
    var requestID: String? = nil
    var toolClass: JournalToolClass? = nil
    var reasonCode: JournalReason? = nil
    var signal: JournalSignal? = nil
    var resolution: JournalResolution? = nil

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", eventID = "event_id", kind, emittedAtMs = "emitted_at_ms"
        case occurredAtMs = "occurred_at_ms", timeQuality = "time_quality", tabID = "tab_id", workspaceID = "workspace_id"
        case sessionID = "session_id", agentKind = "agent_kind", isChild = "is_child", parentSessionID = "parent_session_id"
        case source, adapter, adapterVersion = "adapter_version", nativeEvent = "native_event"
        case turnID = "turn_id", requestID = "request_id", toolClass = "tool_class", reasonCode = "reason_code", signal, resolution
    }

    var owner: JournalOwner? {
        guard let tabID, let sessionID else { return nil }
        return JournalOwner(tabID: tabID, agentKind: agentKind, sessionID: sessionID)
    }

    static func decode(_ data: Data) throws -> JournalDraft {
        guard data.count <= 4096,
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else { throw JournalError.invalidEvent }
        for (key, value) in ["time_quality": "missing", "is_child": false, "adapter_version": "1", "native_event": "other"] as [String: Any] where object[key] == nil {
            object[key] = value
        }
        let normalized = try JSONSerialization.data(withJSONObject: object)
        guard let draft = try? JSONDecoder().decode(Self.self, from: normalized) else { throw JournalError.invalidEvent }
        try draft.validate()
        return draft
    }

    func validate() throws {
        func opaque(_ s: String?, _ limit: Int = 128) -> Bool {
            guard let s else { return true }
            return !s.isEmpty && s.utf8.count <= limit && s.utf8.allSatisfy { $0 >= 33 && $0 <= 126 && $0 != 47 && $0 != 92 }
        }
        let nativeNames: Set<String> = ["other", "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "PermissionRequest", "session.created", "session.status", "session.idle", "session.error", "permission.asked", "chat.message", "agent_start", "agent_settled", "agent-turn-complete", "turn.started", "turn.completed", "turn.interrupted", "adapter_gap", "adapter_recovered", "connection_lost", "operator_response"]
        guard schemaVersion == 1 else { throw JournalError.unsupportedVersion }
        guard source == adapter.source, emittedAtMs >= 0, occurredAtMs.map({ $0 >= 0 }) ?? true,
              (occurredAtMs == nil) == (timeQuality == .missing),
              (tabID == nil) == (workspaceID == nil),
              opaque(agentKind, 64), agentKind.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
              opaque(sessionID), opaque(parentSessionID), opaque(turnID), opaque(requestID),
              opaque(adapterVersion, 64), adapterVersion.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }), nativeNames.contains(nativeEvent),
              signal == nil || kind == .stateChanged,
              resolution == nil || kind == .attentionResolved else { throw JournalError.invalidEvent }
        guard try canonicalData().count <= 4096 else { throw JournalError.invalidEvent }
    }

    func canonicalData() throws -> Data {
        let encoded = try JSONEncoder().encode(self)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in CodingKeys.allCases where object[key.rawValue] == nil { object[key.rawValue] = NSNull() }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

enum JournalPhase: String, Codable { case unknown, working, blocked, idle, error }
enum JournalConfirmation: String, Codable { case confirmed, unconfirmed }
enum JournalConnection: String, Codable { case live, disconnected, unknown }
enum JournalHealth: String, Codable { case ok, degraded }
enum JournalEffect: String, Codable { case applied, duplicateEvidence = "duplicate_evidence", stale, unattributed, child, advisory, observation }

struct JournalSnapshot: Codable, Equatable {
    var owner: JournalOwner
    var workspaceID: UUID?
    var phase: JournalPhase = .unknown
    var reason: JournalReason? = nil
    var requestID: String? = nil
    var turnID: String? = nil
    var turnOutcome: String? = nil
    var source: JournalSource = .c11
    var adapter: JournalAdapter = .c11
    var rank = 0
    var sinceMs: Int64 = 0
    var observedAtMs: Int64 = 0
    var observedTickNs: UInt64 = 0
    var appInstanceID: UUID
    var lastSequence: Int64 = 0
    var nativeWatermarks: [String: Int64] = [:]
    var terminalBarrier = false
    var terminalRank = 0
    var confirmation: JournalConfirmation = .unconfirmed
    var connection: JournalConnection = .unknown
    var health: JournalHealth = .ok
    var timingUncertain = false
    var lastLiveSequence: Int64 = 0
    var lastLiveEmittedAtMs: Int64 = 0
    var modelID: String? = nil
    var isHistorical: Bool { confirmation == .unconfirmed || connection != .live }
    var paintsAttention: Bool { phase == .blocked || phase == .error }
    func isFresh(at now: Int64) -> Bool { now >= observedAtMs && now - observedAtMs <= 30_000 }
}

struct JournalContext {
    var eligible: Bool
    var historical = false
    var modelID: String? = nil
    // Set by a registered adapter only after its fixture verifies the clock.
    var verifiedNativeClock = false
}

struct JournalEvent: Codable {
    let sequence: Int64
    let committedAtMs: Int64
    let observedTickNs: UInt64
    let appInstanceID: UUID
    let draft: JournalDraft
    let draftHash: String
    let attribution: String
    let confidenceRank: Int
    let capabilities: [String]
    let modelID: String?
    let foldVersion: Int
    let effect: JournalEffect
    let effectReason: String
    let fromPhase: JournalPhase?
    let toPhase: JournalPhase?
    let fromSinceMs: Int64?
    enum CodingKeys: String, CodingKey {
        case sequence, committedAtMs = "committed_at_ms", observedTickNs = "observed_tick_ns"
        case appInstanceID = "app_instance_id", draft, draftHash = "draft_hash", attribution
        case confidenceRank = "confidence_rank", capabilities, modelID = "model_id", foldVersion = "fold_version"
        case effect = "projection_effect", effectReason = "effect_reason"
        case fromPhase = "from_phase", toPhase = "to_phase", fromSinceMs = "from_since_ms"
    }
}

struct JournalReceipt: Codable, Equatable {
    let eventID: UUID
    let sequence: Int64
    let committedAtMs: Int64
    var replayed: Bool
    let projectionEffect: JournalEffect
    enum CodingKeys: String, CodingKey {
        case eventID = "event_id", sequence, committedAtMs = "committed_at_ms", replayed, projectionEffect = "projection_effect"
    }
}
