import Foundation

enum SurfaceAttentionReason {
    static let maxLength = 256

    static func validate(_ raw: Any?) -> Result<String, SurfaceMetadataStore.WriteError> {
        guard let reason = raw as? String else {
            return .failure(.reservedKeyInvalidType(MetadataKey.flag, "expected string"))
        }
        if let error = SurfaceMetadataStore.validateReservedKey(MetadataKey.flag, reason) {
            return .failure(error)
        }
        return .success(reason)
    }
}

enum SurfaceAttentionActor: String, CaseIterable {
    case `operator`
    case agent
}

enum SurfaceAttentionFlagMutation {
    case unchanged
    case raise(String)
    case lower
}

enum SurfaceAttentionSuppressionMutation {
    case unchanged
    case suppress
    case unsuppress
}

struct SurfaceAttentionSnapshot: Equatable, Identifiable {
    let workspaceId: UUID
    let surfaceId: UUID
    let flagReason: String?
    let flagRaisedAt: Date?
    let flagCallerSurfaceId: UUID?
    let suppressed: Bool

    init(
        workspaceId: UUID,
        surfaceId: UUID,
        flagReason: String?,
        flagRaisedAt: Date?,
        flagCallerSurfaceId: UUID? = nil,
        suppressed: Bool
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.flagReason = flagReason
        self.flagRaisedAt = flagRaisedAt
        self.flagCallerSurfaceId = flagCallerSurfaceId
        self.suppressed = suppressed
    }

    var id: String { "\(workspaceId.uuidString):\(surfaceId.uuidString)" }
    var isFlagged: Bool { flagReason != nil }
    var isSignalEligible: Bool { !suppressed || isFlagged }

    static func presentedState(
        _ rawState: WorkspacePulseState,
        flagged: Bool,
        suppressed: Bool
    ) -> WorkspacePulseState {
        suppressed && !flagged && rawState == .waiting ? .idle : rawState
    }
}

enum AttentionJumpSelector {
    static func orderedFlags(_ snapshots: [SurfaceAttentionSnapshot]) -> [SurfaceAttentionSnapshot] {
        snapshots.filter(\.isFlagged).sorted {
            let lhsDate = $0.flagRaisedAt ?? .distantPast
            let rhsDate = $1.flagRaisedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            if $0.workspaceId != $1.workspaceId {
                return $0.workspaceId.uuidString < $1.workspaceId.uuidString
            }
            return $0.surfaceId.uuidString < $1.surfaceId.uuidString
        }
    }
}

/// A worker-to-queue commit gate with fail-closed timeout semantics.
///
/// If the deadline expires while work is still pending, the gate atomically
/// cancels it and a later queue turn becomes a no-op. If the operation has
/// already started, the waiter follows it through completion instead of
/// returning an ambiguous timeout that could be followed by a late commit.
final class FailClosedCommitGate<Result>: @unchecked Sendable {
    private enum State {
        case pending
        case running
        case cancelled
        case completed(Result)
    }

    private let condition = NSCondition()
    private let operation: () -> Result
    private var state: State = .pending

    init(operation: @escaping () -> Result) {
        self.operation = operation
    }

    func enqueueOnMain() {
        enqueue { work in
            DispatchQueue.main.async(execute: work)
        }
    }

    func enqueue(using schedule: (@escaping @Sendable () -> Void) -> Void) {
        schedule { [self] in
            condition.lock()
            guard case .pending = state else {
                condition.unlock()
                return
            }
            state = .running
            condition.unlock()

            let result = operation()

            condition.lock()
            state = .completed(result)
            condition.broadcast()
            condition.unlock()
        }
    }

    func wait(timeout: TimeInterval) -> Result? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            switch state {
            case .pending:
                if !condition.wait(until: deadline), case .pending = state {
                    state = .cancelled
                    return nil
                }
            case .running:
                condition.wait()
            case .cancelled:
                return nil
            case .completed(let result):
                return result
            }
        }
    }
}

/// Production seam for the launch invariant: identity and attention metadata
/// are durable before the first byte of the agent command reaches the PTY.
@MainActor
enum AgentLaunchAttentionSequencer {
    static func stampThenSend(
        stampIdentity: () -> Void,
        stampSuppression: () throws -> Void,
        stampFlag: () throws -> Void,
        sendCommand: () -> Void
    ) rethrows {
        stampIdentity()
        try stampSuppression()
        try stampFlag()
        sendCommand()
    }
}

@MainActor
final class SurfaceAttentionIndex: ObservableObject {
    static let shared = SurfaceAttentionIndex()

    @Published private(set) var snapshots: [String: SurfaceAttentionSnapshot] = [:]

    var flaggedCount: Int { snapshots.values.lazy.filter(\.isFlagged).count }
    var oldestFlags: [SurfaceAttentionSnapshot] {
        AttentionJumpSelector.orderedFlags(Array(snapshots.values))
    }

    func snapshot(workspaceId: UUID, surfaceId: UUID) -> SurfaceAttentionSnapshot {
        snapshots[Self.key(workspaceId: workspaceId, surfaceId: surfaceId)]
            ?? SurfaceAttentionSnapshot(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                flagReason: nil,
                flagRaisedAt: nil,
                suppressed: false
            )
    }

    func publish(_ snapshot: SurfaceAttentionSnapshot) {
        let key = Self.key(workspaceId: snapshot.workspaceId, surfaceId: snapshot.surfaceId)
        if !snapshot.isFlagged && !snapshot.suppressed {
            snapshots.removeValue(forKey: key)
        } else if snapshots[key] != snapshot {
            snapshots[key] = snapshot
        }
    }

    func remove(workspaceId: UUID, surfaceId: UUID) {
        snapshots.removeValue(forKey: Self.key(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    func prune(workspaceId: UUID, validSurfaceIds: Set<UUID>) {
        snapshots = snapshots.filter {
            $0.value.workspaceId != workspaceId || validSurfaceIds.contains($0.value.surfaceId)
        }
    }

    private static func key(workspaceId: UUID, surfaceId: UUID) -> String {
        "\(workspaceId.uuidString):\(surfaceId.uuidString)"
    }
}

/// Serialized boundary for canonical attention mutation and every projection.
/// A caller receives a result only after metadata, render cache, signal index,
/// events, and optional direct delivery are all committed.
@MainActor
final class SurfaceAttentionService {
    static let shared = SurfaceAttentionService()

    private init() {}

    @discardableResult
    func raise(
        workspaceId: UUID,
        surfaceId: UUID,
        reason: String,
        callerSurfaceId: UUID? = nil,
        by actor: SurfaceAttentionActor = .agent,
        title: String?
    ) throws -> SurfaceMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: .raise(reason),
            callerSurfaceId: callerSurfaceId,
            actor: actor,
            title: title
        )
    }

    @discardableResult
    func lower(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: SurfaceAttentionActor
    ) throws -> SurfaceMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: .lower,
            actor: actor
        )
    }

    @discardableResult
    func suppress(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: SurfaceAttentionActor
    ) throws -> SurfaceMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            suppression: .suppress,
            actor: actor
        )
    }

    @discardableResult
    func unsuppress(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: SurfaceAttentionActor
    ) throws -> SurfaceMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            suppression: .unsuppress,
            actor: actor
        )
    }

    func syncFromMetadata(workspaceId: UUID, surfaceId: UUID) {
        let snapshot = SurfaceMetadataStore.shared.attentionSnapshot(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        commitProjection(snapshot)
    }

    func restore(_ snapshot: SurfaceAttentionSnapshot) {
        SurfaceMetadataStore.shared.restoreAttention(snapshot)
        let canonical = SurfaceMetadataStore.shared.attentionSnapshot(
            workspaceId: snapshot.workspaceId,
            surfaceId: snapshot.surfaceId
        )
        publishProjection(canonical)
        TerminalNotificationStore.shared.refreshSignalEligibility()
    }

    func remove(workspaceId: UUID, surfaceId: UUID) {
        let attention = SurfaceAttentionIndex.shared.snapshot(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        if let epoch = attention.flagRaisedAt {
            TerminalNotificationStore.shared.cancelFlagNotification(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                flagRaisedAt: epoch
            )
        }
        // Raw notification history must disappear while suppression is still
        // projected. Removing the modifier first would transiently manufacture
        // a waiting edge for a surface that is already gone.
        TerminalNotificationStore.shared.clearNotifications(
            forTabId: workspaceId,
            surfaceId: surfaceId
        )
        SurfaceMetadataStore.shared.removeSurface(workspaceId: workspaceId, surfaceId: surfaceId)
        SurfaceAttentionIndex.shared.remove(workspaceId: workspaceId, surfaceId: surfaceId)
        AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?
            .tabs.first(where: { $0.id == workspaceId })?
            .setAttentionSnapshot(nil, forSurface: surfaceId)
    }

    func prune(workspaceId: UUID, validSurfaceIds: Set<UUID>) {
        for attention in SurfaceAttentionIndex.shared.oldestFlags
        where attention.workspaceId == workspaceId
            && !validSurfaceIds.contains(attention.surfaceId) {
            if let epoch = attention.flagRaisedAt {
                TerminalNotificationStore.shared.cancelFlagNotification(
                    workspaceId: workspaceId,
                    surfaceId: attention.surfaceId,
                    flagRaisedAt: epoch
                )
            }
        }
        // As with single-surface removal, clear raw history before removing the
        // attention projection that currently keeps it signal-ineligible.
        TerminalNotificationStore.shared.clearNotifications(
            forTabId: workspaceId,
            excludingSurfaceIds: validSurfaceIds
        )
        SurfaceMetadataStore.shared.pruneWorkspace(
            workspaceId: workspaceId,
            validSurfaceIds: validSurfaceIds
        )
        SurfaceAttentionIndex.shared.prune(
            workspaceId: workspaceId,
            validSurfaceIds: validSurfaceIds
        )
    }

    private func mutate(
        workspaceId: UUID,
        surfaceId: UUID,
        flag: SurfaceAttentionFlagMutation = .unchanged,
        suppression: SurfaceAttentionSuppressionMutation = .unchanged,
        callerSurfaceId: UUID? = nil,
        actor: SurfaceAttentionActor = .agent,
        title: String? = nil
    ) throws -> SurfaceMetadataStore.WriteResult {
        let transaction = try SurfaceMetadataStore.shared.mutateAttention(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: flag,
            suppression: suppression,
            callerSurfaceId: callerSurfaceId
        )
        let flagChanged = transaction.result.applied[MetadataKey.flag] == true
        let suppressionChanged = transaction.result.applied[MetadataKey.suppressed] == true
        guard flagChanged || suppressionChanged else { return transaction.result }

        publishProjection(transaction.after)
        TerminalNotificationStore.shared.refreshSignalEligibility()

        if flagChanged {
            if let reason = transaction.after.flagReason,
               let epoch = transaction.after.flagRaisedAt {
                EventEmitter.shared.emitFlagRaised(
                    workspace: workspaceId,
                    surface: surfaceId,
                    reason: reason,
                    callerSurfaceId: transaction.after.flagCallerSurfaceId,
                    by: actor
                )
                // Operator decision 2026-07-28: direct flag delivery pierces
                // suppression. Its stable epoch identity also replaces a
                // prior reason revision instead of accumulating alerts.
                TerminalNotificationStore.shared.deliverFlagNotification(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    flagRaisedAt: epoch,
                    title: title,
                    reason: reason
                )
            } else {
                EventEmitter.shared.emitFlagLowered(
                    workspace: workspaceId,
                    surface: surfaceId,
                    by: actor
                )
                if let epoch = transaction.before.flagRaisedAt {
                    TerminalNotificationStore.shared.cancelFlagNotification(
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        flagRaisedAt: epoch
                    )
                }
            }
        }
        if suppressionChanged {
            if transaction.after.suppressed {
                EventEmitter.shared.emitFlagSuppressed(
                    workspace: workspaceId,
                    surface: surfaceId,
                    by: actor
                )
                TerminalNotificationStore.shared.cancelRoutineExternalNotifications(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
            } else {
                EventEmitter.shared.emitFlagUnsuppressed(
                    workspace: workspaceId,
                    surface: surfaceId,
                    by: actor
                )
            }
        }
        return transaction.result
    }

    private func commitProjection(_ snapshot: SurfaceAttentionSnapshot) {
        publishProjection(snapshot)
        TerminalNotificationStore.shared.refreshSignalEligibility()
    }

    private func publishProjection(_ snapshot: SurfaceAttentionSnapshot) {
        SurfaceAttentionIndex.shared.publish(snapshot)
        AppDelegate.shared?.tabManagerFor(tabId: snapshot.workspaceId)?
            .tabs.first(where: { $0.id == snapshot.workspaceId })?
            .setAttentionSnapshot(snapshot, forSurface: snapshot.surfaceId)
    }
}
