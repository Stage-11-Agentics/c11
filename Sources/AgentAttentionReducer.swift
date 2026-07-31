import Foundation

enum AgentProvider: String, Sendable, CaseIterable {
    case codex
    case claude
    case opencode
    case pi
    case grok
    case unknown
}

struct AgentProviderCapabilities: Sendable, Equatable {
    let exactActorThread: Bool
    let parentRelationship: Bool
    let attentionWaits: Bool
    let goalLifecycle: Bool
    let continuableStop: Bool

    static let codexLegacy = AgentProviderCapabilities(
        exactActorThread: true,
        parentRelationship: false,
        attentionWaits: false,
        goalLifecycle: false,
        continuableStop: true
    )

    static let codexTypedHooks = AgentProviderCapabilities(
        exactActorThread: false,
        parentRelationship: true,
        attentionWaits: true,
        goalLifecycle: false,
        continuableStop: true
    )

    static let codexAppServer = AgentProviderCapabilities(
        exactActorThread: true,
        parentRelationship: true,
        attentionWaits: true,
        goalLifecycle: true,
        continuableStop: true
    )

    /// App Server remains a follow-up transport. Its parity gate must cover
    /// fresh launch/resume, approvals and input, child start/stop/abort,
    /// every /goal terminal state, crash/socket/restart fallback, native TUI
    /// behavior, and latency/resource overhead before it can own lifecycle.
    static let appServerIsFollowUp = true
}

enum AgentAttentionReason: String, Sendable, CaseIterable {
    case approval
    case userInput
    case resultReady
    case goalBlocked
    case usageLimited
    case budgetLimited
}

enum AgentGoalStatus: String, Sendable, CaseIterable {
    case active
    case paused
    case completed
    case blocked
    case usageLimited
    case budgetLimited
}

enum AgentRunState: String, Sendable {
    case idle
    case working
}

enum AgentEvidenceAuthority: Int, Sendable, Comparable {
    case launchSeed = 1
    case terminalSubmission = 2
    case providerLifecycle = 3
    case exactRootCompletion = 4
    case structuredProvider = 5

    static func < (lhs: AgentEvidenceAuthority, rhs: AgentEvidenceAuthority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum AgentLifecycleEventKind: Sendable, Equatable {
    case launchSeedIdle
    case runStarted(resumesAttention: Bool)
    case runBecameIdle
    case rootResultReady
    case rootWaiting(AgentAttentionReason)
    case childStarted
    case childStopped
    case goalChanged(AgentGoalStatus)

    var requiresExactRootOwnership: Bool {
        switch self {
        case .rootResultReady, .rootWaiting, .goalChanged:
            return true
        case .launchSeedIdle, .runStarted, .runBecameIdle, .childStarted, .childStopped:
            return false
        }
    }
}

struct AgentLifecycleEnvelope: Sendable, Equatable {
    let version: Int
    let eventID: String
    let workspaceID: UUID
    let surfaceID: UUID
    let provider: AgentProvider
    let launchEpoch: UUID
    let rootThreadID: String?
    let actorThreadID: String?
    let parentThreadID: String?
    let turnID: String?
    let kind: AgentLifecycleEventKind
    let authority: AgentEvidenceAuthority
    let providerSequence: Int64?
    let occurredAt: Date

    init(
        version: Int = 1,
        eventID: String,
        workspaceID: UUID,
        surfaceID: UUID,
        provider: AgentProvider,
        launchEpoch: UUID,
        rootThreadID: String? = nil,
        actorThreadID: String? = nil,
        parentThreadID: String? = nil,
        turnID: String? = nil,
        kind: AgentLifecycleEventKind,
        authority: AgentEvidenceAuthority,
        providerSequence: Int64? = nil,
        occurredAt: Date
    ) {
        self.version = version
        self.eventID = eventID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.provider = provider
        self.launchEpoch = launchEpoch
        self.rootThreadID = rootThreadID
        self.actorThreadID = actorThreadID
        self.parentThreadID = parentThreadID
        self.turnID = turnID
        self.kind = kind
        self.authority = authority
        self.providerSequence = providerSequence
        self.occurredAt = occurredAt
    }
}

enum AgentOwnershipClassification: String, Sendable {
    case root
    case child
    case unknown
    case staleEpoch
    case mismatched
}

enum AgentReducerDisposition: String, Sendable {
    case applied
    case duplicate
    case outOfOrder
    case ignoredChild
    case ignoredUnknown
    case ignoredStaleEpoch
    case ignoredMismatch
    case unsupportedVersion
}

struct AgentAttentionEpisode: Sendable, Equatable {
    let id: String
    let reason: AgentAttentionReason
    let startedAt: Date
}

struct AgentAttentionState: Sendable, Equatable {
    static let processedEventLimit = 256

    let workspaceID: UUID
    let surfaceID: UUID
    let launchEpoch: UUID
    private(set) var rootThreadID: String?
    private(set) var runState: AgentRunState = .idle
    private(set) var activeChildThreadIDs: Set<String> = []
    private(set) var goalStatus: AgentGoalStatus?
    private(set) var attentionEpisode: AgentAttentionEpisode?
    private(set) var pendingResultDuringGoal = false
    private(set) var processedEventIDs: [String] = []
    private(set) var lastProviderSequence: [AgentProvider: Int64] = [:]
    private(set) var lastRootEvidenceAt: Date?
    private(set) var lastRootAuthority: AgentEvidenceAuthority?

    init(workspaceID: UUID, surfaceID: UUID, launchEpoch: UUID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.launchEpoch = launchEpoch
    }

    @discardableResult
    mutating func bindRootThread(_ threadID: String) -> Bool {
        let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if let rootThreadID {
            return rootThreadID == normalized
        }
        rootThreadID = normalized
        return true
    }

    mutating func remember(eventID: String) {
        processedEventIDs.append(eventID)
        if processedEventIDs.count > Self.processedEventLimit {
            processedEventIDs.removeFirst(processedEventIDs.count - Self.processedEventLimit)
        }
    }

    mutating func record(sequence: Int64, provider: AgentProvider) {
        lastProviderSequence[provider] = sequence
    }

    mutating func recordRootEvidence(_ envelope: AgentLifecycleEnvelope) {
        lastRootEvidenceAt = envelope.occurredAt
        lastRootAuthority = envelope.authority
    }

    mutating func setRunState(_ state: AgentRunState) {
        runState = state
    }

    mutating func setAttention(_ episode: AgentAttentionEpisode?) {
        attentionEpisode = episode
    }

    mutating func setGoal(_ status: AgentGoalStatus?) {
        goalStatus = status
    }

    mutating func setPendingResultDuringGoal(_ value: Bool) {
        pendingResultDuringGoal = value
    }

    mutating func addChild(_ threadID: String) {
        activeChildThreadIDs.insert(threadID)
    }

    mutating func removeChild(_ threadID: String) {
        activeChildThreadIDs.remove(threadID)
    }
}

struct AgentAttentionReduction: Sendable, Equatable {
    let state: AgentAttentionState
    let ownership: AgentOwnershipClassification
    let disposition: AgentReducerDisposition
    let priorEpisode: AgentAttentionEpisode?

    var enteredAttention: Bool {
        priorEpisode == nil && state.attentionEpisode != nil
    }

    var leftAttention: Bool {
        priorEpisode != nil && state.attentionEpisode == nil
    }

    var attentionChanged: Bool {
        priorEpisode != state.attentionEpisode
    }
}

struct AgentAttentionReducer {
    static func reduce(
        state initial: AgentAttentionState,
        envelope: AgentLifecycleEnvelope
    ) -> AgentAttentionReduction {
        var state = initial
        let priorEpisode = state.attentionEpisode

        guard envelope.version == 1 else {
            return result(
                state,
                ownership: .unknown,
                disposition: .unsupportedVersion,
                priorEpisode: priorEpisode
            )
        }
        guard envelope.workspaceID == state.workspaceID,
              envelope.surfaceID == state.surfaceID else {
            return result(
                state,
                ownership: .mismatched,
                disposition: .ignoredMismatch,
                priorEpisode: priorEpisode
            )
        }
        guard envelope.launchEpoch == state.launchEpoch else {
            return result(
                state,
                ownership: .staleEpoch,
                disposition: .ignoredStaleEpoch,
                priorEpisode: priorEpisode
            )
        }
        guard !state.processedEventIDs.contains(envelope.eventID) else {
            return result(
                state,
                ownership: classify(state: state, envelope: envelope),
                disposition: .duplicate,
                priorEpisode: priorEpisode
            )
        }
        if let sequence = envelope.providerSequence,
           let last = state.lastProviderSequence[envelope.provider],
           sequence <= last {
            return result(
                state,
                ownership: classify(state: state, envelope: envelope),
                disposition: .outOfOrder,
                priorEpisode: priorEpisode
            )
        }

        if let suppliedRoot = envelope.rootThreadID,
           !state.bindRootThread(suppliedRoot) {
            return result(
                state,
                ownership: .mismatched,
                disposition: .ignoredMismatch,
                priorEpisode: priorEpisode
            )
        }

        let ownership = classify(state: state, envelope: envelope)
        if envelope.kind.requiresExactRootOwnership {
            switch ownership {
            case .root:
                break
            case .child:
                return result(
                    state,
                    ownership: .child,
                    disposition: .ignoredChild,
                    priorEpisode: priorEpisode
                )
            case .unknown:
                return result(
                    state,
                    ownership: .unknown,
                    disposition: .ignoredUnknown,
                    priorEpisode: priorEpisode
                )
            case .staleEpoch:
                return result(
                    state,
                    ownership: .staleEpoch,
                    disposition: .ignoredStaleEpoch,
                    priorEpisode: priorEpisode
                )
            case .mismatched:
                return result(
                    state,
                    ownership: .mismatched,
                    disposition: .ignoredMismatch,
                    priorEpisode: priorEpisode
                )
            }
        }

        if isOutOfOrderRootEvidence(state: state, envelope: envelope) {
            return result(
                state,
                ownership: ownership,
                disposition: .outOfOrder,
                priorEpisode: priorEpisode
            )
        }

        state.remember(eventID: envelope.eventID)
        if let sequence = envelope.providerSequence {
            state.record(sequence: sequence, provider: envelope.provider)
        }

        switch envelope.kind {
        case .launchSeedIdle:
            state.setRunState(.idle)
            state.recordRootEvidence(envelope)

        case .runStarted(let resumesAttention):
            state.setRunState(.working)
            state.setPendingResultDuringGoal(false)
            if state.attentionEpisode?.reason == .resultReady || resumesAttention {
                state.setAttention(nil)
            }
            state.recordRootEvidence(envelope)

        case .runBecameIdle:
            state.setRunState(.idle)
            state.recordRootEvidence(envelope)

        case .rootResultReady:
            if state.goalStatus == .active {
                state.setRunState(.working)
                state.setPendingResultDuringGoal(true)
            } else {
                enterAttention(.resultReady, envelope: envelope, state: &state)
                state.setRunState(.idle)
            }
            state.recordRootEvidence(envelope)

        case .rootWaiting(let reason):
            enterAttention(reason, envelope: envelope, state: &state)
            state.setRunState(.idle)
            state.recordRootEvidence(envelope)

        case .childStarted:
            if ownership == .child, let child = envelope.actorThreadID {
                state.addChild(child)
            }

        case .childStopped:
            if ownership == .child, let child = envelope.actorThreadID {
                state.removeChild(child)
            }

        case .goalChanged(let status):
            state.setGoal(status)
            switch status {
            case .active:
                state.setRunState(.working)
                state.setAttention(nil)
            case .paused:
                state.setRunState(.idle)
                state.setAttention(nil)
            case .completed:
                state.setRunState(.idle)
                if state.pendingResultDuringGoal {
                    enterAttention(.resultReady, envelope: envelope, state: &state)
                } else {
                    state.setAttention(nil)
                }
                state.setPendingResultDuringGoal(false)
            case .blocked:
                enterAttention(.goalBlocked, envelope: envelope, state: &state)
                state.setRunState(.idle)
            case .usageLimited:
                enterAttention(.usageLimited, envelope: envelope, state: &state)
                state.setRunState(.idle)
            case .budgetLimited:
                enterAttention(.budgetLimited, envelope: envelope, state: &state)
                state.setRunState(.idle)
            }
            state.recordRootEvidence(envelope)
        }

        return result(
            state,
            ownership: ownership,
            disposition: .applied,
            priorEpisode: priorEpisode
        )
    }

    private static func classify(
        state: AgentAttentionState,
        envelope: AgentLifecycleEnvelope
    ) -> AgentOwnershipClassification {
        guard envelope.launchEpoch == state.launchEpoch else { return .staleEpoch }
        guard let root = state.rootThreadID else { return .unknown }
        if envelope.actorThreadID == root {
            return .root
        }
        if let actor = envelope.actorThreadID,
           envelope.parentThreadID == root || state.activeChildThreadIDs.contains(actor) {
            return .child
        }
        if envelope.actorThreadID == nil,
           !envelope.kind.requiresExactRootOwnership {
            return .root
        }
        return .mismatched
    }

    private static func isOutOfOrderRootEvidence(
        state: AgentAttentionState,
        envelope: AgentLifecycleEnvelope
    ) -> Bool {
        switch envelope.kind {
        case .childStarted, .childStopped:
            return false
        case .launchSeedIdle, .runStarted, .runBecameIdle,
             .rootResultReady, .rootWaiting, .goalChanged:
            break
        }
        guard let lastAt = state.lastRootEvidenceAt,
              let lastAuthority = state.lastRootAuthority else {
            return false
        }
        if envelope.occurredAt < lastAt {
            return envelope.authority <= lastAuthority
        }
        if envelope.occurredAt == lastAt {
            return envelope.authority < lastAuthority
        }
        return false
    }

    private static func enterAttention(
        _ reason: AgentAttentionReason,
        envelope: AgentLifecycleEnvelope,
        state: inout AgentAttentionState
    ) {
        if state.attentionEpisode?.reason == reason {
            return
        }
        state.setAttention(
            AgentAttentionEpisode(
                id: [
                    envelope.surfaceID.uuidString.lowercased(),
                    envelope.launchEpoch.uuidString.lowercased(),
                    envelope.eventID,
                    reason.rawValue,
                ].joined(separator: ":"),
                reason: reason,
                startedAt: envelope.occurredAt
            )
        )
    }

    private static func result(
        _ state: AgentAttentionState,
        ownership: AgentOwnershipClassification,
        disposition: AgentReducerDisposition,
        priorEpisode: AgentAttentionEpisode?
    ) -> AgentAttentionReduction {
        AgentAttentionReduction(
            state: state,
            ownership: ownership,
            disposition: disposition,
            priorEpisode: priorEpisode
        )
    }
}
