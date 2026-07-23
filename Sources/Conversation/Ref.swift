import Foundation

/// Source that captured a `ConversationRef`. Used for diagnostic provenance,
/// evidence strength, and same-tier reconciliation tiebreaking.
enum CaptureSource: String, Codable, Sendable {
    case hook
    /// Exact identity read by the target agent's own tool subprocess from
    /// its runtime environment (for Codex, `CODEX_THREAD_ID`). Like `hook`,
    /// this is causal evidence tied to one live surface, not an inference
    /// from cwd or transcript timestamps.
    case runtimeEnv
    case scrape
    case wrapperClaim
    case manual
}

/// Strength of the evidence that associated an exact conversation id with a
/// surface. Ownership decisions use this tier before timestamps: inferred
/// evidence can never displace causal evidence, however new it is.
enum CaptureEvidenceTier: Int, Sendable, Comparable {
    case placeholder = 0
    case inferred = 1
    case causal = 2

    static func < (lhs: CaptureEvidenceTier, rhs: CaptureEvidenceTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Typed, persisted reason an otherwise exact ref is not globally owned.
///
/// This is deliberately orthogonal to `ConversationState`: quarantining sets
/// lifecycle state to `.unknown`, which keeps every existing strategy fail-
/// closed without adding a new enum case to all downstream strategy switches.
/// The optional field is backwards-compatible with pre-C11-206 snapshots.
enum ConversationQuarantineReason: String, Codable, Sendable, Equatable {
    case duplicateInferredIdentity = "duplicate_inferred_identity"
    case conflictingCausalIdentity = "conflicting_causal_identity"
    case displacedByCausalOwner = "displaced_by_causal_owner"
    case sameCwdWithoutCausalIdentity = "same_cwd_without_causal_identity"
    case ambiguousGlobalAssignment = "ambiguous_global_assignment"
}

/// Lifecycle state of a `ConversationRef`.
///
/// - `alive`: TUI is running and the strategy has confidence the ref is
///   the active conversation.
/// - `suspended`: c11 is shutting down or has shut down cleanly; resume
///   on next launch is expected.
/// - `tombstoned`: explicitly ended (operator action, or scrape confirmed
///   the session file is gone for a strategy that can be confident — e.g.
///   Claude with hook history). Not auto-resumable.
/// - `unknown`: the strategy cannot classify this ref; resume() returns
///   `.skip` until pull-scrape promotes it. Resting state for refs found
///   after a crash, ambiguous Codex matches, etc.
/// - `unsupported`: ref kind not registered in this binary's strategy
///   registry. Retain (don't tombstone) so a future c11 release with the
///   strategy can promote it.
enum ConversationState: String, Codable, Sendable {
    case alive
    case suspended
    case tombstoned
    case unknown
    case unsupported
}

/// Persistable pointer to a continuation of agent work. Owned by c11,
/// lives across TUI process death, opaque-id keyed to a per-kind strategy.
///
/// `cwd` is core (not payload) — universal for local-process software-
/// engineering agents and load-bearing for the Codex scrape filter; nil
/// for cloud/remote/MCP strategies that don't have a meaningful cwd.
///
/// `placeholder` is `true` while only a wrapper-claim has been seen and
/// the real id has not been resolved yet. Strategies must replace before
/// any ResumeAction is emitted; `resume()` returns `.skip` if placeholder
/// remains true.
///
/// `diagnosticReason` is populated on every update so operators can answer
/// "why did this pane resume that session?" without instrumentation.
struct ConversationRef: Codable, Sendable, Equatable {
    var kind: String
    var id: String
    var placeholder: Bool
    var cwd: String?
    var capturedAt: Date
    var capturedVia: CaptureSource
    var state: ConversationState
    var quarantineReason: ConversationQuarantineReason?
    var diagnosticReason: String?
    var payload: [String: PersistedJSONValue]?

    init(
        kind: String,
        id: String,
        placeholder: Bool = false,
        cwd: String? = nil,
        capturedAt: Date = Date(),
        capturedVia: CaptureSource,
        state: ConversationState,
        quarantineReason: ConversationQuarantineReason? = nil,
        diagnosticReason: String? = nil,
        payload: [String: PersistedJSONValue]? = nil
    ) {
        self.kind = kind
        self.id = id
        self.placeholder = placeholder
        self.cwd = cwd
        self.capturedAt = capturedAt
        self.capturedVia = capturedVia
        self.state = state
        self.quarantineReason = quarantineReason
        self.diagnosticReason = diagnosticReason
        self.payload = payload
    }
}

/// Surface ↔ Conversation mapping persisted on each `SessionPanelSnapshot`.
/// v1 only ever populates `active`; `history` is written explicitly as an
/// empty array (not omitted) so JSON output is stable across v1/v2.
struct SurfaceConversations: Codable, Sendable, Equatable {
    var active: ConversationRef?
    var history: [ConversationRef]

    init(active: ConversationRef? = nil, history: [ConversationRef] = []) {
        self.active = active
        self.history = history
    }

    static let empty = SurfaceConversations(active: nil, history: [])
}

extension CaptureSource {
    var evidenceTier: CaptureEvidenceTier {
        switch self {
        case .hook, .runtimeEnv:
            return .causal
        case .scrape, .manual:
            return .inferred
        case .wrapperClaim:
            return .placeholder
        }
    }

    var isCausal: Bool { evidenceTier == .causal }

    /// Tiebreaker priority used by `ConversationStore` reconciliation
    /// when two writes carry close `capturedAt` timestamps. Higher wins.
    var priority: Int {
        switch self {
        case .runtimeEnv:   return 5
        case .hook:         return 4
        case .scrape:       return 3
        case .manual:       return 2
        case .wrapperClaim: return 1
        }
    }
}

extension ConversationRef {
    var isQuarantined: Bool { quarantineReason != nil }

    /// Causal exact refs are the only refs allowed to resolve duplicate or
    /// same-cwd ownership. A quarantined causal claim remains causal evidence
    /// for conflict detection, but is not an eligible owner until a later
    /// non-conflicting report refreshes it.
    var hasCausalExactEvidence: Bool {
        !placeholder && capturedVia.isCausal
    }

    var isEligibleCausalOwner: Bool {
        hasCausalExactEvidence && !isQuarantined
    }
}
