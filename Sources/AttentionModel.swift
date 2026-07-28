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
    let suppressed: Bool

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
final class SurfaceAttentionService: @unchecked Sendable {
    static let shared = SurfaceAttentionService()

    private let lock = NSLock()

    private init() {}

    @discardableResult
    func raise(
        workspaceId: UUID,
        surfaceId: UUID,
        reason: String,
        title: String?
    ) throws -> SurfaceMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: .raise(reason),
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
        lock.lock()
        defer { lock.unlock() }
        SurfaceMetadataStore.shared.restoreAttention(snapshot)
        commitProjection(snapshot)
    }

    func remove(workspaceId: UUID, surfaceId: UUID) {
        commitOnMain {
            SurfaceAttentionIndex.shared.remove(workspaceId: workspaceId, surfaceId: surfaceId)
            AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?
                .tabs.first(where: { $0.id == workspaceId })?
                .setAttentionSnapshot(nil, forSurface: surfaceId)
            TerminalNotificationStore.shared.refreshSignalEligibility()
        }
    }

    func prune(workspaceId: UUID, validSurfaceIds: Set<UUID>) {
        commitOnMain {
            SurfaceAttentionIndex.shared.prune(
                workspaceId: workspaceId,
                validSurfaceIds: validSurfaceIds
            )
            TerminalNotificationStore.shared.refreshSignalEligibility()
        }
    }

    private func mutate(
        workspaceId: UUID,
        surfaceId: UUID,
        flag: SurfaceAttentionFlagMutation = .unchanged,
        suppression: SurfaceAttentionSuppressionMutation = .unchanged,
        actor: SurfaceAttentionActor = .agent,
        title: String? = nil
    ) throws -> SurfaceMetadataStore.WriteResult {
        lock.lock()
        defer { lock.unlock() }

        let transaction = try SurfaceMetadataStore.shared.mutateAttention(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: flag,
            suppression: suppression
        )
        let flagChanged = transaction.result.applied[MetadataKey.flag] == true
        let suppressionChanged = transaction.result.applied[MetadataKey.suppressed] == true
        guard flagChanged || suppressionChanged else { return transaction.result }

        commitOnMain {
            self.publishProjection(transaction.after)
            TerminalNotificationStore.shared.refreshSignalEligibility()

            if flagChanged {
                if let reason = transaction.after.flagReason {
                    EventEmitter.shared.emitFlagRaised(
                        workspace: workspaceId,
                        surface: surfaceId,
                        reason: reason
                    )
                    // Operator decision 2026-07-28: direct flag delivery is
                    // exempt from suppression. Routine waiting delivery is not.
                    let deliversDirectFlagWhileSuppressed = true
                    if !transaction.after.suppressed || deliversDirectFlagWhileSuppressed {
                        TerminalNotificationStore.shared.deliverFlagNotification(
                            workspaceId: workspaceId,
                            surfaceId: surfaceId,
                            title: title,
                            reason: reason
                        )
                    }
                } else {
                    EventEmitter.shared.emitFlagLowered(
                        workspace: workspaceId,
                        surface: surfaceId,
                        by: actor
                    )
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
        }
        return transaction.result
    }

    private func commitProjection(_ snapshot: SurfaceAttentionSnapshot) {
        commitOnMain {
            self.publishProjection(snapshot)
            TerminalNotificationStore.shared.refreshSignalEligibility()
        }
    }

    @MainActor
    private func publishProjection(_ snapshot: SurfaceAttentionSnapshot) {
        SurfaceAttentionIndex.shared.publish(snapshot)
        AppDelegate.shared?.tabManagerFor(tabId: snapshot.workspaceId)?
            .tabs.first(where: { $0.id == snapshot.workspaceId })?
            .setAttentionSnapshot(snapshot, forSurface: snapshot.surfaceId)
    }

    private func commitOnMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body() }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
