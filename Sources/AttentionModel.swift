import Foundation

enum TabAttentionReason {
    static let maxLength = 256

    static func validate(_ raw: Any?) -> Result<String, TabMetadataStore.WriteError> {
        guard let reason = raw as? String else {
            return .failure(.reservedKeyInvalidType(MetadataKey.flag, "expected string"))
        }
        if let error = TabMetadataStore.validateReservedKey(MetadataKey.flag, reason) {
            return .failure(error)
        }
        return .success(reason)
    }
}

enum TabAttentionActor: String, CaseIterable {
    case `operator`
    case agent
}

enum TabAttentionFlagMutation {
    case unchanged
    case raise(String)
    case lower
}

enum TabAttentionSuppressionMutation {
    case unchanged
    case suppress
    case unsuppress
}

struct TabAttentionSnapshot: Equatable, Identifiable {
    let workspaceId: UUID
    let surfaceId: UUID
    let flagReason: String?
    let flagRaisedAt: Date?
    let flagCallerTabId: UUID?
    let suppressed: Bool

    init(
        workspaceId: UUID,
        surfaceId: UUID,
        flagReason: String?,
        flagRaisedAt: Date?,
        flagCallerTabId: UUID? = nil,
        suppressed: Bool
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.flagReason = flagReason
        self.flagRaisedAt = flagRaisedAt
        self.flagCallerTabId = flagCallerTabId
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
    static func orderedFlags(_ snapshots: [TabAttentionSnapshot]) -> [TabAttentionSnapshot] {
        snapshots.filter(\.isFlagged).sorted {
            AttentionOrder.precedes(
                time: $0.flagRaisedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                target: .init(workspaceID: $0.workspaceId, tabID: $0.surfaceId),
                time: $1.flagRaisedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                target: .init(workspaceID: $1.workspaceId, tabID: $1.surfaceId)
            )
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
final class TabAttentionIndex: ObservableObject {
    static let shared = TabAttentionIndex()

    @Published private(set) var snapshots: [String: TabAttentionSnapshot] = [:]

    var flaggedCount: Int { snapshots.values.lazy.filter(\.isFlagged).count }
    var oldestFlags: [TabAttentionSnapshot] {
        AttentionJumpSelector.orderedFlags(Array(snapshots.values))
    }

    func snapshot(workspaceId: UUID, surfaceId: UUID) -> TabAttentionSnapshot {
        snapshots[Self.key(workspaceId: workspaceId, surfaceId: surfaceId)]
            ?? TabAttentionSnapshot(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                flagReason: nil,
                flagRaisedAt: nil,
                suppressed: false
            )
    }

    func publish(_ snapshot: TabAttentionSnapshot) {
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
final class TabAttentionService {
    static let shared = TabAttentionService()

    private let feedProjection: FeedProjectionBridge

    init(feedProjection: FeedProjectionBridge = .shared) {
        self.feedProjection = feedProjection
    }

    @discardableResult
    func raise(
        workspaceId: UUID,
        surfaceId: UUID,
        reason: String,
        callerTabId: UUID? = nil,
        by actor: TabAttentionActor = .agent,
        title: String?
    ) throws -> TabMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: .raise(reason),
            callerTabId: callerTabId,
            actor: actor,
            title: title
        )
    }

    @discardableResult
    func lower(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: TabAttentionActor,
        answer: String? = nil,
        expectedFlagEpoch: Date? = nil
    ) throws -> TabMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: .lower,
            actor: actor,
            answer: answer,
            expectedFlagEpoch: expectedFlagEpoch
        )
    }

    /// Typing-hot-path variant of `lower`: a no-op (nil) unless a flag is
    /// currently raised, so callers can invoke it unconditionally per keystroke.
    @discardableResult
    func lowerIfFlagged(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: TabAttentionActor
    ) throws -> TabMetadataStore.WriteResult? {
        guard TabAttentionIndex.shared.snapshot(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        ).isFlagged else { return nil }
        return try lower(workspaceId: workspaceId, surfaceId: surfaceId, by: actor)
    }

    @discardableResult
    func suppress(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: TabAttentionActor
    ) throws -> TabMetadataStore.WriteResult {
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
        by actor: TabAttentionActor
    ) throws -> TabMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            suppression: .unsuppress,
            actor: actor
        )
    }

    func syncFromMetadata(workspaceId: UUID, surfaceId: UUID) {
        let snapshot = TabMetadataStore.shared.attentionSnapshot(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        commitProjection(snapshot)
    }

    func restore(_ snapshot: TabAttentionSnapshot) {
        TabMetadataStore.shared.restoreAttention(snapshot)
        let canonical = TabMetadataStore.shared.attentionSnapshot(
            workspaceId: snapshot.workspaceId,
            surfaceId: snapshot.surfaceId
        )
        publishProjection(canonical)
        TerminalNotificationStore.shared.refreshSignalEligibility()
    }

    func remove(workspaceId: UUID, surfaceId: UUID) {
        let attention = TabAttentionIndex.shared.snapshot(
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
            forWorkspaceId: workspaceId,
            surfaceId: surfaceId
        )
        TabMetadataStore.shared.removeSurface(workspaceId: workspaceId, surfaceId: surfaceId)
        TabAttentionIndex.shared.remove(workspaceId: workspaceId, surfaceId: surfaceId)
        feedProjection.removeTab(workspaceID: workspaceId, tabID: surfaceId)
        AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId)?
            .workspaces.first(where: { $0.id == workspaceId })?
            .setAttentionSnapshot(nil, forSurface: surfaceId)
    }

    func prune(workspaceId: UUID, validSurfaceIds: Set<UUID>) {
        for attention in TabAttentionIndex.shared.oldestFlags
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
            forWorkspaceId: workspaceId,
            excludingSurfaceIds: validSurfaceIds
        )
        TabMetadataStore.shared.pruneWorkspace(
            workspaceId: workspaceId,
            validSurfaceIds: validSurfaceIds
        )
        TabAttentionIndex.shared.prune(
            workspaceId: workspaceId,
            validSurfaceIds: validSurfaceIds
        )
        feedProjection.pruneWorkspace(workspaceID: workspaceId, validTabIDs: validSurfaceIds)
    }

    private func mutate(
        workspaceId: UUID,
        surfaceId: UUID,
        flag: TabAttentionFlagMutation = .unchanged,
        suppression: TabAttentionSuppressionMutation = .unchanged,
        callerTabId: UUID? = nil,
        actor: TabAttentionActor = .agent,
        answer: String? = nil,
        expectedFlagEpoch: Date? = nil,
        title: String? = nil
    ) throws -> TabMetadataStore.WriteResult {
        let transaction = try TabMetadataStore.shared.mutateAttention(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: flag,
            suppression: suppression,
            callerTabId: callerTabId,
            expectedFlagEpoch: expectedFlagEpoch
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
                    callerTabId: transaction.after.flagCallerTabId,
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
                    by: actor,
                    answer: answer
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

    private func commitProjection(_ snapshot: TabAttentionSnapshot) {
        publishProjection(snapshot)
        TerminalNotificationStore.shared.refreshSignalEligibility()
    }

    private func publishProjection(_ snapshot: TabAttentionSnapshot) {
        TabAttentionIndex.shared.publish(snapshot)
        AppDelegate.shared?.workspaceManagerFor(workspaceId: snapshot.workspaceId)?
            .workspaces.first(where: { $0.id == snapshot.workspaceId })?
            .setAttentionSnapshot(snapshot, forSurface: snapshot.surfaceId)
        // Copy the snapshot off main. Do not project the feed row here.
        feedProjection.noteAttention(snapshot)
    }
}
