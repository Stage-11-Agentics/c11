import Foundation

enum PanelAttentionReason {
    static let maxLength = 256

    static func validate(_ raw: Any?) -> Result<String, PanelMetadataStore.WriteError> {
        guard let reason = raw as? String else {
            return .failure(.reservedKeyInvalidType(MetadataKey.flag, "expected string"))
        }
        if let error = PanelMetadataStore.validateReservedKey(MetadataKey.flag, reason) {
            return .failure(error)
        }
        return .success(reason)
    }
}

enum PanelAttentionActor: String, CaseIterable {
    case `operator`
    case agent
    case c11
}

enum PanelAttentionFlagMutation {
    case unchanged
    case raise(String)
    case lower
}

enum PanelAttentionDelegationMutation {
    case unchanged
    case delegate(ownerPanelId: UUID?)
    case undelegate
}

struct PanelAttentionSnapshot: Equatable, Identifiable {
    let workspaceId: UUID
    let surfaceId: UUID
    let flagReason: String?
    let flagRaisedAt: Date?
    let flagCallerPanelId: UUID?
    let delegated: Bool
    let delegatedBy: UUID?
    var suppressed: Bool { delegated }

    init(
        workspaceId: UUID,
        surfaceId: UUID,
        flagReason: String?,
        flagRaisedAt: Date?,
        flagCallerPanelId: UUID? = nil,
        delegated: Bool,
        delegatedBy: UUID? = nil
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.flagReason = flagReason
        self.flagRaisedAt = flagRaisedAt
        self.flagCallerPanelId = flagCallerPanelId
        self.delegated = delegated
        self.delegatedBy = delegatedBy
    }

    init(
        workspaceId: UUID,
        surfaceId: UUID,
        flagReason: String?,
        flagRaisedAt: Date?,
        flagCallerPanelId: UUID? = nil,
        suppressed: Bool
    ) {
        self.init(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flagReason: flagReason,
            flagRaisedAt: flagRaisedAt,
            flagCallerPanelId: flagCallerPanelId,
            delegated: suppressed
        )
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
    static func orderedFlags(_ snapshots: [PanelAttentionSnapshot]) -> [PanelAttentionSnapshot] {
        snapshots.filter(\.isFlagged).sorted {
            AttentionOrder.precedes(
                time: $0.flagRaisedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                target: .init(workspaceID: $0.workspaceId, panelID: $0.surfaceId),
                time: $1.flagRaisedAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) },
                target: .init(workspaceID: $1.workspaceId, panelID: $1.surfaceId)
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
        stampDelegation: () throws -> Void,
        stampFlag: () throws -> Void,
        sendCommand: () -> Void
    ) rethrows {
        stampIdentity()
        try stampDelegation()
        try stampFlag()
        sendCommand()
    }
}

/// Pure lifecycle decision for delegates whose owner panel is closing or did
/// not return during restore. Kept separate from Workspace so `c11-logic` can
/// prove close/move/simultaneous-teardown rules without constructing AppKit.
enum PanelAttentionReleasePlanner {
    static func forClosingPanels(
        _ closingPanelIds: Set<UUID>,
        attention: [PanelAttentionSnapshot]
    ) -> [PanelAttentionSnapshot] {
        attention
            .filter { snapshot in
                snapshot.delegated
                    && !closingPanelIds.contains(snapshot.surfaceId)
                    && snapshot.delegatedBy.map(closingPanelIds.contains) == true
            }
            .sorted(by: stableOrder)
    }

    static func forMissingOwners(
        livePanelIds: Set<UUID>,
        attention: [PanelAttentionSnapshot]
    ) -> [PanelAttentionSnapshot] {
        attention
            .filter { snapshot in
                snapshot.delegated
                    && snapshot.delegatedBy.map { !livePanelIds.contains($0) } == true
            }
            .sorted(by: stableOrder)
    }

    private static func stableOrder(
        _ lhs: PanelAttentionSnapshot,
        _ rhs: PanelAttentionSnapshot
    ) -> Bool {
        if lhs.workspaceId != rhs.workspaceId {
            return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
        }
        return lhs.surfaceId.uuidString < rhs.surfaceId.uuidString
    }
}

@MainActor
final class PanelAttentionIndex: ObservableObject {
    static let shared = PanelAttentionIndex()

    @Published private(set) var snapshots: [String: PanelAttentionSnapshot] = [:]

    var flaggedCount: Int { snapshots.values.lazy.filter(\.isFlagged).count }
    var oldestFlags: [PanelAttentionSnapshot] {
        AttentionJumpSelector.orderedFlags(Array(snapshots.values))
    }

    func snapshot(workspaceId: UUID, surfaceId: UUID) -> PanelAttentionSnapshot {
        snapshots[Self.key(workspaceId: workspaceId, surfaceId: surfaceId)]
            ?? PanelAttentionSnapshot(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                flagReason: nil,
                flagRaisedAt: nil,
                suppressed: false
            )
    }

    func publish(_ snapshot: PanelAttentionSnapshot) {
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
final class PanelAttentionService {
    static let shared = PanelAttentionService()

    private let feedProjection: FeedProjectionBridge

    init(feedProjection: FeedProjectionBridge = .shared) {
        self.feedProjection = feedProjection
    }

    @discardableResult
    func raise(
        workspaceId: UUID,
        surfaceId: UUID,
        reason: String,
        callerPanelId: UUID? = nil,
        by actor: PanelAttentionActor = .agent,
        title: String?
    ) throws -> PanelMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: .raise(reason),
            callerPanelId: callerPanelId,
            actor: actor,
            title: title
        )
    }

    @discardableResult
    func lower(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: PanelAttentionActor,
        answer: String? = nil,
        expectedFlagEpoch: Date? = nil
    ) throws -> PanelMetadataStore.WriteResult {
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
        by actor: PanelAttentionActor
    ) throws -> PanelMetadataStore.WriteResult? {
        guard PanelAttentionIndex.shared.snapshot(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        ).isFlagged else { return nil }
        return try lower(workspaceId: workspaceId, surfaceId: surfaceId, by: actor)
    }

    func syncFromMetadata(workspaceId: UUID, surfaceId: UUID) {
        let snapshot = PanelMetadataStore.shared.attentionSnapshot(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        commitProjection(snapshot)
    }

    func restore(_ snapshot: PanelAttentionSnapshot) {
        PanelMetadataStore.shared.restoreAttention(snapshot)
        let canonical = PanelMetadataStore.shared.attentionSnapshot(
            workspaceId: snapshot.workspaceId,
            surfaceId: snapshot.surfaceId
        )
        publishProjection(canonical)
        TerminalNotificationStore.shared.refreshSignalEligibility()
    }

    @discardableResult
    func delegate(
        workspaceId: UUID,
        surfaceId: UUID,
        ownerPanelId: UUID?,
        by actor: PanelAttentionActor
    ) throws -> PanelMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            delegation: .delegate(ownerPanelId: ownerPanelId),
            actor: actor
        )
    }

    @discardableResult
    func undelegate(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: PanelAttentionActor
    ) throws -> PanelMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            delegation: .undelegate,
            actor: actor
        )
    }

    /// Compatibility entry point for the established suppression handler. New
    /// callers may supply an owner; old ownerless suppression remains readable.
    @discardableResult
    func suppress(
        workspaceId: UUID,
        surfaceId: UUID,
        ownerPanelId: UUID? = nil,
        by actor: PanelAttentionActor
    ) throws -> PanelMetadataStore.WriteResult {
        try delegate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            ownerPanelId: ownerPanelId,
            by: actor
        )
    }

    @discardableResult
    func unsuppress(
        workspaceId: UUID,
        surfaceId: UUID,
        by actor: PanelAttentionActor
    ) throws -> PanelMetadataStore.WriteResult {
        try undelegate(workspaceId: workspaceId, surfaceId: surfaceId, by: actor)
    }

    /// Releases every live delegate owned by a panel. The caller passes panels
    /// that are part of a simultaneous teardown so they do not briefly emit a
    /// newly eligible stop signal immediately before they are removed too.
    func releaseDelegatesOwned(
        by ownerPanelId: UUID,
        excludingPanelIds: Set<UUID> = []
    ) {
        releaseDelegatesForClosingPanels(excludingPanelIds.union([ownerPanelId]))
    }

    func releaseDelegatesForClosingPanels(_ closingPanelIds: Set<UUID>) {
        let candidates = PanelAttentionIndex.shared.snapshots.values
        let releases = PanelAttentionReleasePlanner.forClosingPanels(
            closingPanelIds,
            attention: Array(candidates)
        )
        for snapshot in releases {
            guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: snapshot.surfaceId,
                preferredWorkspaceId: snapshot.workspaceId
            )?.workspace else { continue }
            _ = try? undelegate(
                workspaceId: workspace.id,
                surfaceId: snapshot.surfaceId,
                by: .c11
            )
        }
    }

    /// Rebuild the tooltip and panel-sheet relationship text when an owner's
    /// displayed title changes. Delegates can live in another workspace, so
    /// the owner workspace cannot refresh those projections itself.
    func refreshDelegatePresentations(ownedBy ownerPanelId: UUID) {
        let ownerTitle: String?
        if let owner = AppDelegate.shared?.workspaceContainingPanel(panelId: ownerPanelId),
           let panel = owner.workspace.panels[ownerPanelId] {
            ownerTitle = owner.workspace.resolvedPanelTitle(
                panelId: ownerPanelId,
                fallback: panel.displayTitle
            )
        } else {
            ownerTitle = nil
        }
        for entry in PanelMetadataStore.shared.delegateEntries(ownerPanelId: ownerPanelId) {
            guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: entry.surfaceId,
                preferredWorkspaceId: entry.workspaceId
            )?.workspace else { continue }
            workspace.setDelegationOwnerTitle(ownerTitle, forSurface: entry.surfaceId)
        }
    }

    /// A session restore can bring back a delegate without its owner (for
    /// example, after a crash during close). Legacy suppressed records have no
    /// owner and are deliberately absent from this query.
    func releaseDelegatesWithMissingOwners(livePanelIds: Set<UUID>) {
        let candidates = PanelAttentionIndex.shared.snapshots.values
        let candidateSnapshots = Array(candidates)
        let releases = PanelAttentionReleasePlanner.forMissingOwners(
            livePanelIds: livePanelIds,
            attention: candidateSnapshots
        )
        let releasedIds = Set(releases.map(\.surfaceId))
        for snapshot in candidateSnapshots
        where snapshot.delegated && !releasedIds.contains(snapshot.surfaceId) {
            guard let ownerPanelId = snapshot.delegatedBy,
                  livePanelIds.contains(ownerPanelId),
                  let owner = AppDelegate.shared?.workspaceContainingPanel(panelId: ownerPanelId),
                  let ownerPanel = owner.workspace.panels[ownerPanelId],
                  let delegateWorkspace = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: snapshot.surfaceId,
                    preferredWorkspaceId: snapshot.workspaceId
                  )?.workspace else { continue }
            delegateWorkspace.setDelegationOwnerTitle(
                owner.workspace.resolvedPanelTitle(
                    panelId: ownerPanelId,
                    fallback: ownerPanel.displayTitle
                ),
                forSurface: snapshot.surfaceId
            )
        }
        for snapshot in releases {
            guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: snapshot.surfaceId,
                preferredWorkspaceId: snapshot.workspaceId
            )?.workspace else { continue }
            _ = try? undelegate(
                workspaceId: workspace.id,
                surfaceId: snapshot.surfaceId,
                by: .c11
            )
        }
    }

    func remove(workspaceId: UUID, surfaceId: UUID) {
        let attention = PanelAttentionIndex.shared.snapshot(
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
        PanelMetadataStore.shared.removeSurface(workspaceId: workspaceId, surfaceId: surfaceId)
        PanelAttentionIndex.shared.remove(workspaceId: workspaceId, surfaceId: surfaceId)
        feedProjection.removePanel(workspaceID: workspaceId, panelID: surfaceId)
        AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId)?
            .workspaces.first(where: { $0.id == workspaceId })?
            .setAttentionSnapshot(nil, forSurface: surfaceId)
    }

    func prune(workspaceId: UUID, validSurfaceIds: Set<UUID>) {
        for attention in PanelAttentionIndex.shared.oldestFlags
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
        PanelMetadataStore.shared.pruneWorkspace(
            workspaceId: workspaceId,
            validSurfaceIds: validSurfaceIds
        )
        PanelAttentionIndex.shared.prune(
            workspaceId: workspaceId,
            validSurfaceIds: validSurfaceIds
        )
        feedProjection.pruneWorkspace(workspaceID: workspaceId, validPanelIDs: validSurfaceIds)
    }

    private func mutate(
        workspaceId: UUID,
        surfaceId: UUID,
        flag: PanelAttentionFlagMutation = .unchanged,
        delegation: PanelAttentionDelegationMutation = .unchanged,
        callerPanelId: UUID? = nil,
        actor: PanelAttentionActor = .agent,
        answer: String? = nil,
        expectedFlagEpoch: Date? = nil,
        title: String? = nil
    ) throws -> PanelMetadataStore.WriteResult {
        let transaction = try PanelMetadataStore.shared.mutateAttention(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: flag,
            delegation: delegation,
            callerPanelId: callerPanelId,
            expectedFlagEpoch: expectedFlagEpoch
        )
        let flagChanged = transaction.result.applied[MetadataKey.flag] == true
        let delegationChanged = transaction.result.applied[MetadataKey.delegated] == true
        guard flagChanged || delegationChanged else { return transaction.result }

        publishProjection(transaction.after)
        TerminalNotificationStore.shared.refreshSignalEligibility()

        if flagChanged {
            if let reason = transaction.after.flagReason,
               let epoch = transaction.after.flagRaisedAt {
                EventEmitter.shared.emitFlagRaised(
                    workspace: workspaceId,
                    surface: surfaceId,
                    reason: reason,
                    callerPanelId: transaction.after.flagCallerPanelId,
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
        if delegationChanged {
            if transaction.after.delegated {
                EventEmitter.shared.emitFlagSuppressed(
                    workspace: workspaceId,
                    surface: surfaceId,
                    delegatedBy: transaction.after.delegatedBy,
                    priorDelegatedBy: transaction.before.delegatedBy,
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
                    delegatedBy: transaction.before.delegatedBy,
                    by: actor
                )
            }
        }
        return transaction.result
    }

    private func commitProjection(_ snapshot: PanelAttentionSnapshot) {
        publishProjection(snapshot)
        TerminalNotificationStore.shared.refreshSignalEligibility()
    }

    private func publishProjection(_ snapshot: PanelAttentionSnapshot) {
        PanelAttentionIndex.shared.publish(snapshot)
        let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: snapshot.surfaceId,
            preferredWorkspaceId: snapshot.workspaceId
        )?.workspace
        if snapshot.delegated, let ownerPanelId = snapshot.delegatedBy,
           let owner = AppDelegate.shared?.workspaceContainingPanel(panelId: ownerPanelId),
           let ownerPanel = owner.workspace.panels[ownerPanelId] {
            workspace?.setDelegationOwnerTitle(
                owner.workspace.resolvedPanelTitle(
                    panelId: ownerPanelId,
                    fallback: ownerPanel.displayTitle
                ),
                forSurface: snapshot.surfaceId
            )
        } else {
            workspace?.setDelegationOwnerTitle(nil, forSurface: snapshot.surfaceId)
        }
        workspace?.setAttentionSnapshot(snapshot, forSurface: snapshot.surfaceId)
        // Copy the snapshot off main. Do not project the feed row here.
        feedProjection.noteAttention(snapshot)
    }
}
