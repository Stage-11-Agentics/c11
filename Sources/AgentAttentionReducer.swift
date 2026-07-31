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

enum ClaudeHookAttentionClassifier {
    static func reason(from object: [String: Any]?) -> AgentAttentionReason {
        guard let object else { return .userInput }
        let nested = (object["notification"] as? [String: Any])
            ?? (object["data"] as? [String: Any])
        let raw = structuredString(
            object,
            keys: ["notification_type", "notificationType"]
        ) ?? nested.flatMap {
            structuredString(
                $0,
                keys: ["notification_type", "notificationType", "type"]
            )
        }
        switch raw?.lowercased() {
        case "permission_prompt", "permission_request", "approval_required":
            return .approval
        default:
            return .userInput
        }
    }

    private static func structuredString(
        _ object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
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

struct AgentAttentionSurfaceSnapshot: Sendable, Equatable {
    let runState: AgentRunState
    let episode: AgentAttentionEpisode?
}

struct AgentAttentionOwnershipSnapshot: Sendable, Equatable {
    let workspaceID: UUID
    let surfaceID: UUID
    let launchEpoch: UUID
    let rootThreadID: String?
}

struct AgentHookIngestResult: Sendable, Equatable {
    let ownership: AgentOwnershipClassification
    let disposition: AgentReducerDisposition
    let snapshot: AgentAttentionSurfaceSnapshot
    let shouldCreateSignalNotification: Bool
    let shouldCreateHistoryOnlyNotification: Bool
}

enum AgentHookPayloadError: Error, Equatable {
    case payloadTooLarge
    case malformedPayload
    case unsupportedProvider
    case unsupportedVersion
    case unsupportedEvent
}

/// Process-wide serialization point for provider lifecycle truth. Provider
/// adapters normalize here; notification history and UI projection are
/// downstream effects and never feed state back into this coordinator.
final class AgentAttentionCoordinator: @unchecked Sendable {
    static let shared = AgentAttentionCoordinator()
    static let maximumPayloadBytes = 64 * 1_024

    private struct SurfaceKey: Hashable {
        let workspaceID: UUID
        let surfaceID: UUID
    }

    private let queue = DispatchQueue(label: "com.stage11.c11.agent-attention")
    private var states: [SurfaceKey: AgentAttentionState] = [:]
    private var compatibilityEpochs: [SurfaceKey: UUID] = [:]
    private var diagnosticCounts: [String: Int] = [:]

    private init() {}

    func snapshot(
        workspaceID: UUID,
        surfaceID: UUID
    ) -> AgentAttentionSurfaceSnapshot? {
        queue.sync {
            states[SurfaceKey(workspaceID: workspaceID, surfaceID: surfaceID)].map {
                AgentAttentionSurfaceSnapshot(
                    runState: $0.runState,
                    episode: $0.attentionEpisode
                )
            }
        }
    }

    func diagnosticSnapshot() -> [String: Int] {
        queue.sync { diagnosticCounts }
    }

    /// Normalize the existing provider lifecycle rail into the same reducer.
    /// Providers without a launch-epoch transport receive one process-local
    /// compatibility epoch per exact surface. This can establish working/idle
    /// truth, but attention is created only by the root-owned methods below.
    @discardableResult
    func applyCompatibilityLifecycle(
        provider: AgentProvider,
        workspaceID: UUID,
        surfaceID: UUID,
        activity: SidebarActivityState,
        occurredAt: Date = Date()
    ) -> AgentAttentionSurfaceSnapshot {
        queue.sync {
            let key = SurfaceKey(workspaceID: workspaceID, surfaceID: surfaceID)
            let epoch = compatibilityEpochs[key] ?? UUID()
            compatibilityEpochs[key] = epoch
            var state = states[key] ?? AgentAttentionState(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                launchEpoch: epoch
            )
            let root = state.rootThreadID ?? "provider-root:\(provider.rawValue):\(surfaceID.uuidString)"
            _ = state.bindRootThread(root)
            let kind: AgentLifecycleEventKind = activity == .working
                ? .runStarted(resumesAttention: true)
                : .runBecameIdle
            let envelope = AgentLifecycleEnvelope(
                eventID: "compat:\(provider.rawValue):\(UUID().uuidString)",
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                provider: provider,
                launchEpoch: epoch,
                rootThreadID: root,
                actorThreadID: root,
                kind: kind,
                authority: .providerLifecycle,
                occurredAt: occurredAt
            )
            let reduction = AgentAttentionReducer.reduce(state: state, envelope: envelope)
            states[key] = reduction.state
            record(reduction)
            return AgentAttentionSurfaceSnapshot(
                runState: reduction.state.runState,
                episode: reduction.state.attentionEpisode
            )
        }
    }

    /// Provider-owned completion/waiting rail for adapters that already prove
    /// their root session before calling c11 (Claude hooks and OpenCode's
    /// root-session-filtering plugin).
    @discardableResult
    func applyOwnedAttention(
        provider: AgentProvider,
        workspaceID: UUID,
        surfaceID: UUID,
        reason: AgentAttentionReason,
        eventID: String = UUID().uuidString,
        occurredAt: Date = Date()
    ) -> AgentHookIngestResult {
        queue.sync {
            let key = SurfaceKey(workspaceID: workspaceID, surfaceID: surfaceID)
            let epoch = states[key]?.launchEpoch
                ?? compatibilityEpochs[key]
                ?? UUID()
            compatibilityEpochs[key] = epoch
            var state = states[key] ?? AgentAttentionState(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                launchEpoch: epoch
            )
            let root = state.rootThreadID ?? "provider-root:\(provider.rawValue):\(surfaceID.uuidString)"
            _ = state.bindRootThread(root)
            let kind: AgentLifecycleEventKind = reason == .resultReady
                ? .rootResultReady
                : .rootWaiting(reason)
            let envelope = AgentLifecycleEnvelope(
                eventID: eventID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                provider: provider,
                launchEpoch: epoch,
                rootThreadID: root,
                actorThreadID: root,
                kind: kind,
                authority: reason == .resultReady ? .exactRootCompletion : .structuredProvider,
                occurredAt: occurredAt
            )
            let reduction = AgentAttentionReducer.reduce(state: state, envelope: envelope)
            states[key] = reduction.state
            record(reduction)
            return ingestResult(
                reduction,
                historyOnly: false
            )
        }
    }

    func ingestLegacyCodex(
        rawPayload: Data,
        ownership: AgentAttentionOwnershipSnapshot?,
        workspaceID: UUID,
        surfaceID: UUID,
        launchEpoch: UUID,
        callbackEnvironmentRootThreadID: String?,
        occurredAt: Date = Date()
    ) throws -> AgentHookIngestResult {
        guard rawPayload.count <= Self.maximumPayloadBytes else {
            throw AgentHookPayloadError.payloadTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: rawPayload),
              let payload = object as? [String: Any] else {
            throw AgentHookPayloadError.malformedPayload
        }
        let version = (payload["version"] as? NSNumber)?.intValue ?? 1
        guard version == 1 else { throw AgentHookPayloadError.unsupportedVersion }
        guard payload["type"] as? String == "agent-turn-complete" else {
            throw AgentHookPayloadError.unsupportedEvent
        }
        let actorThreadID = normalizedUUIDString(payload["thread-id"] as? String)
        let turnID = (payload["turn-id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let callbackRoot = normalizedUUIDString(callbackEnvironmentRootThreadID)

        return queue.sync {
            let key = SurfaceKey(workspaceID: workspaceID, surfaceID: surfaceID)
            let activeEpoch = ownership?.launchEpoch
            guard activeEpoch == launchEpoch else {
                let existing = states[key] ?? AgentAttentionState(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    launchEpoch: activeEpoch ?? launchEpoch
                )
                increment("ownership.staleEpoch")
                return AgentHookIngestResult(
                    ownership: .staleEpoch,
                    disposition: .ignoredStaleEpoch,
                    snapshot: AgentAttentionSurfaceSnapshot(
                        runState: existing.runState,
                        episode: existing.attentionEpisode
                    ),
                    shouldCreateSignalNotification: false,
                    shouldCreateHistoryOnlyNotification: false
                )
            }

            var state = states[key]
            if state?.launchEpoch != launchEpoch {
                state = AgentAttentionState(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    launchEpoch: launchEpoch
                )
            }
            var current = state!
            let claimedRoot = ownership?.rootThreadID
            let effectiveRoot = claimedRoot ?? callbackRoot
            if let effectiveRoot {
                _ = current.bindRootThread(effectiveRoot)
            }

            let classification: AgentOwnershipClassification
            if let claimedRoot, let callbackRoot, claimedRoot != callbackRoot {
                classification = .mismatched
            } else if let effectiveRoot, let actorThreadID {
                classification = actorThreadID == effectiveRoot ? .root : .child
            } else {
                classification = .unknown
            }

            guard classification == .root, let effectiveRoot, let actorThreadID else {
                states[key] = current
                let disposition: AgentReducerDisposition
                switch classification {
                case .child: disposition = .ignoredChild
                case .mismatched: disposition = .ignoredMismatch
                case .unknown: disposition = .ignoredUnknown
                case .staleEpoch: disposition = .ignoredStaleEpoch
                case .root: disposition = .ignoredUnknown
                }
                increment("ownership.\(classification.rawValue)")
                return AgentHookIngestResult(
                    ownership: classification,
                    disposition: disposition,
                    snapshot: AgentAttentionSurfaceSnapshot(
                        runState: current.runState,
                        episode: current.attentionEpisode
                    ),
                    shouldCreateSignalNotification: false,
                    shouldCreateHistoryOnlyNotification: classification == .unknown
                )
            }

            let eventID = "codex-legacy:\(turnID?.isEmpty == false ? turnID! : actorThreadID)"
            let envelope = AgentLifecycleEnvelope(
                eventID: eventID,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                provider: .codex,
                launchEpoch: launchEpoch,
                rootThreadID: effectiveRoot,
                actorThreadID: actorThreadID,
                turnID: turnID,
                kind: .rootResultReady,
                authority: .exactRootCompletion,
                occurredAt: occurredAt
            )
            let reduction = AgentAttentionReducer.reduce(state: current, envelope: envelope)
            states[key] = reduction.state
            record(reduction)
            return ingestResult(reduction, historyOnly: false)
        }
    }

    private func ingestResult(
        _ reduction: AgentAttentionReduction,
        historyOnly: Bool
    ) -> AgentHookIngestResult {
        AgentHookIngestResult(
            ownership: reduction.ownership,
            disposition: reduction.disposition,
            snapshot: AgentAttentionSurfaceSnapshot(
                runState: reduction.state.runState,
                episode: reduction.state.attentionEpisode
            ),
            shouldCreateSignalNotification: reduction.enteredAttention,
            shouldCreateHistoryOnlyNotification: historyOnly
        )
    }

    private func record(_ reduction: AgentAttentionReduction) {
        increment("ownership.\(reduction.ownership.rawValue)")
        increment("disposition.\(reduction.disposition.rawValue)")
    }

    private func increment(_ key: String) {
        diagnosticCounts[key, default: 0] += 1
    }

    private func normalizedUUIDString(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: value) != nil else {
            return nil
        }
        return value.lowercased()
    }
}

extension TerminalController {
    nonisolated func v2AgentIngest(params: [String: Any]) -> V2CallResult {
        guard (params["version"] as? NSNumber)?.intValue == 1 else {
            return .err(code: "unsupported_version", message: "agent ingest version must be 1", data: nil)
        }
        guard let providerRaw = v2String(params, "provider"),
              let provider = AgentProvider(rawValue: providerRaw),
              provider == .codex || provider == .opencode || provider == .claude else {
            return .err(code: "unsupported_provider", message: "unsupported agent ingest provider", data: nil)
        }
        guard let workspaceRaw = v2String(params, "workspace_id"),
              let workspaceID = UUID(uuidString: workspaceRaw),
              let surfaceRaw = v2String(params, "surface_id"),
              let surfaceID = UUID(uuidString: surfaceRaw) else {
            return .err(
                code: "invalid_scope",
                message: "workspace_id and surface_id must be UUIDs",
                data: nil
            )
        }

        let result: AgentHookIngestResult
        if provider == .codex {
            guard let rawEpoch = v2String(params, "launch_epoch"),
                  let launchEpoch = UUID(uuidString: rawEpoch),
                  let rawPayload = params["raw_payload"] as? String,
                  let payload = rawPayload.data(using: .utf8) else {
                return .err(
                    code: "invalid_payload",
                    message: "codex ingest requires launch_epoch and UTF-8 raw_payload",
                    data: nil
                )
            }
            guard payload.count <= AgentAttentionCoordinator.maximumPayloadBytes else {
                return .err(code: "payload_too_large", message: "payload exceeds 64 KiB", data: nil)
            }
            let ownership = conversationStoreSync { store in
                await store.attentionOwnershipSnapshot(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            } ?? nil
            do {
                result = try AgentAttentionCoordinator.shared.ingestLegacyCodex(
                    rawPayload: payload,
                    ownership: ownership,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    launchEpoch: launchEpoch,
                    callbackEnvironmentRootThreadID: v2String(
                        params,
                        "callback_root_thread_id"
                    )
                )
            } catch AgentHookPayloadError.payloadTooLarge {
                return .err(code: "payload_too_large", message: "payload exceeds 64 KiB", data: nil)
            } catch AgentHookPayloadError.unsupportedVersion {
                return .err(code: "unsupported_version", message: "unsupported payload version", data: nil)
            } catch AgentHookPayloadError.unsupportedEvent {
                return .err(code: "unsupported_event", message: "unsupported Codex callback event", data: nil)
            } catch {
                return .err(code: "malformed_payload", message: "malformed Codex callback payload", data: nil)
            }
        } else {
            guard let event = v2String(params, "event") else {
                return .err(code: "invalid_event", message: "OpenCode event required", data: nil)
            }
            let reason: AgentAttentionReason
            switch event {
            case "result-ready": reason = .resultReady
            case "approval": reason = .approval
            case "user-input": reason = .userInput
            case "error": reason = .resultReady
            default:
                return .err(code: "unsupported_event", message: "unsupported OpenCode event", data: nil)
            }
            result = AgentAttentionCoordinator.shared.applyOwnedAttention(
                provider: provider,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                reason: reason,
                eventID: "opencode:\(v2String(params, "actor_thread_id") ?? UUID().uuidString):\(event)"
            )
        }

        publishAgentAttentionEffect(
            result,
            provider: provider,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        return .ok([
            "status": "OK",
            "ownership": result.ownership.rawValue,
            "disposition": result.disposition.rawValue,
            "run_state": result.snapshot.runState.rawValue,
            "attention_reason": result.snapshot.episode?.reason.rawValue as Any,
        ])
    }

    private nonisolated func publishAgentAttentionEffect(
        _ result: AgentHookIngestResult,
        provider: AgentProvider,
        workspaceID: UUID,
        surfaceID: UUID
    ) {
        let activity: SidebarActivityState = result.snapshot.runState == .working
            ? .working
            : .idle
        SurfaceLivenessDeriver.onAgentLifecycleChanged(
            surfaceId: surfaceID,
            workspaceId: workspaceID,
            activity: activity
        )
        guard result.shouldCreateSignalNotification
                || result.shouldCreateHistoryOnlyNotification else {
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let providerTitle: String
                switch provider {
                case .codex: providerTitle = "Codex"
                case .claude: providerTitle = "Claude Code"
                case .opencode: providerTitle = "OpenCode"
                default: providerTitle = "Agent"
                }
                let subtitle = result.shouldCreateHistoryOnlyNotification
                    ? "Unverified completion"
                    : (result.snapshot.episode?.reason.rawValue ?? "Result ready")
                TerminalNotificationStore.shared.addNotification(
                    tabId: workspaceID,
                    surfaceId: surfaceID,
                    title: providerTitle,
                    subtitle: subtitle,
                    body: "",
                    attentionEligible: result.shouldCreateSignalNotification
                )
            }
        }
    }
}
