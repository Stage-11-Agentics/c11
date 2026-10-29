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

enum PanelFlagKindRegistryError: Error {
    case invalidKind
    case tooManyKinds
    case encodingFailed

    var message: String {
        switch self {
        case .invalidKind:
            return "kind requires a lowercase slug, a non-empty display name, a supported color, and an optional short emoji"
        case .tooManyKinds:
            return "at most 64 flag kinds may be registered"
        case .encodingFailed:
            return "failed to save flag kinds"
        }
    }
}

/// c11-owned registry for named flags. Built-in entries always exist; edits
/// are stored as UserDefaults overrides in c11's own app domain, and removing
/// a built-in restores its shipped default.
final class PanelFlagKindRegistry: @unchecked Sendable {
    static let shared = PanelFlagKindRegistry()
    static let storageKey = "attention.flagKinds.v1"
    static let didChangeNotification = Notification.Name("c11.panelFlagKindsDidChange")
    static let builtIns: [PanelFlagKind] = [
        PanelFlagKind(id: "chief-of-staff", name: "Chief of Staff", color: .green, emoji: nil),
        PanelFlagKind(id: "merge-issue", name: "Merge Issue", color: .red, emoji: nil),
    ]

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [PanelFlagKind] {
        lock.lock()
        defer { lock.unlock() }
        let overrides = readOverrides()
        var values = Dictionary(uniqueKeysWithValues: Self.builtIns.map { ($0.id, $0) })
        for (id, kind) in overrides { values[id] = kind }
        return values.values.sorted { $0.id < $1.id }
    }

    func kind(id: String) -> PanelFlagKind? {
        all().first { $0.id == id }
    }

    func set(_ kind: PanelFlagKind) throws {
        guard kind.isValid else { throw PanelFlagKindRegistryError.invalidKind }
        lock.lock()
        var changed = false
        defer {
            lock.unlock()
            if changed {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
        var overrides = readOverrides()
        overrides[kind.id] = kind
        let registeredIDs = Set(Self.builtIns.map(\.id)).union(overrides.keys)
        guard registeredIDs.count <= 64 else { throw PanelFlagKindRegistryError.tooManyKinds }
        try write(overrides)
        changed = true
    }

    /// Removing a built-in clears its override and restores the default.
    @discardableResult
    func remove(id: String) throws -> Bool {
        guard PanelFlagKind.isValidSlug(id) else { throw PanelFlagKindRegistryError.invalidKind }
        lock.lock()
        var changed = false
        defer {
            lock.unlock()
            if changed {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
        var overrides = readOverrides()
        let existed = overrides.removeValue(forKey: id) != nil
            || Self.builtIns.contains(where: { $0.id == id })
        guard existed else { return false }
        try write(overrides)
        changed = true
        return true
    }

    static func isBuiltIn(_ id: String) -> Bool {
        builtIns.contains { $0.id == id }
    }

    private func readOverrides() -> [String: PanelFlagKind] {
        guard let data = defaults.data(forKey: Self.storageKey), data.count <= 32_768,
              let decoded = try? JSONDecoder().decode([PanelFlagKind].self, from: data) else { return [:] }
        return Dictionary(decoded.filter(\.isValid).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func write(_ values: [String: PanelFlagKind]) throws {
        let ordered = values.values.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(ordered), data.count <= 32_768 else {
            throw PanelFlagKindRegistryError.encodingFailed
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum PanelAttentionActor: String, CaseIterable {
    case `operator`
    case agent
    case c11
}

enum PanelAttentionFlagMutation {
    case unchanged
    case raise(String, kind: PanelFlagKind?)
    case lower
}

enum PanelAttentionDelegationMutation {
    case unchanged
    case delegate(ownerPanelId: UUID?)
    case undelegate
}

enum PanelAttentionDelegationPolicy {
    static func requiresCaller(
        actor: PanelAttentionActor,
        callerPanelId: UUID?,
        isLegacyOwnerlessSuppression: Bool
    ) -> Bool {
        actor == .agent && callerPanelId == nil && !isLegacyOwnerlessSuppression
    }

    static func isSelfDelegation(callerPanelId: UUID?, targetPanelId: UUID) -> Bool {
        callerPanelId == targetPanelId
    }
}

struct PanelAttentionSnapshot: Equatable, Identifiable {
    let workspaceId: UUID
    let surfaceId: UUID
    let flagReason: String?
    let flagKind: PanelFlagKind?
    let flagRaisedAt: Date?
    let flagCallerPanelId: UUID?
    let delegated: Bool
    let delegatedBy: UUID?
    var suppressed: Bool { delegated }

    init(
        workspaceId: UUID,
        surfaceId: UUID,
        flagReason: String?,
        flagKind: PanelFlagKind? = nil,
        flagRaisedAt: Date?,
        flagCallerPanelId: UUID? = nil,
        delegated: Bool,
        delegatedBy: UUID? = nil
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.flagReason = flagReason
        self.flagKind = flagKind
        self.flagRaisedAt = flagRaisedAt
        self.flagCallerPanelId = flagCallerPanelId
        self.delegated = delegated
        self.delegatedBy = delegatedBy
    }

    init(
        workspaceId: UUID,
        surfaceId: UUID,
        flagReason: String?,
        flagKind: PanelFlagKind? = nil,
        flagRaisedAt: Date?,
        flagCallerPanelId: UUID? = nil,
        suppressed: Bool
    ) {
        self.init(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flagReason: flagReason,
            flagKind: flagKind,
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

/// Delegate lineage read from the live `delegated_by` links. Nothing here is
/// persisted: depth is recomputed from the current delegate records.
enum DelegateLineage {
    /// Consecutive delegate hops ending at `surfaceId`. A panel that is not a
    /// delegate is 0; a delegate of a normal panel is 1; each delegate
    /// ancestor adds one. `owners` maps every delegated surface to its owner
    /// (nil for a legacy delegate with no recorded owner). A cycle stops the
    /// walk at the first repeated surface.
    static func depth(of surfaceId: UUID, owners: [UUID: UUID?]) -> Int {
        var depth = 0
        var current = surfaceId
        var visited: Set<UUID> = []
        while let entry = owners[current], visited.insert(current).inserted {
            depth += 1
            guard let owner = entry else { break }
            current = owner
        }
        return depth
    }

    /// Every delegate whose lineage passes through `surfaceId`, nearest first.
    /// Their depth changes when that panel's delegation changes.
    static func descendants(of surfaceId: UUID, owners: [UUID: UUID?]) -> [UUID] {
        var children: [UUID: [UUID]] = [:]
        for (delegate, owner) in owners {
            if let owner { children[owner, default: []].append(delegate) }
        }
        var result: [UUID] = []
        var visited: Set<UUID> = [surfaceId]
        var frontier = [surfaceId]
        while !frontier.isEmpty {
            var next: [UUID] = []
            for owner in frontier {
                let sorted = (children[owner] ?? []).sorted { $0.uuidString < $1.uuidString }
                for child in sorted where visited.insert(child).inserted {
                    result.append(child)
                    next.append(child)
                }
            }
            frontier = next
        }
        return result
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
    private var delegateKeysByOwner: [UUID: Set<String>] = [:]
    /// Every delegated surface and its owner, for lineage depth.
    private(set) var delegationOwners: [UUID: UUID?] = [:]

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
        if let prior = snapshots[key], prior.delegated {
            if !snapshot.delegated || prior.delegatedBy != snapshot.delegatedBy {
                removeDelegateKey(key, ownerPanelId: prior.delegatedBy)
            }
        }
        if !snapshot.isFlagged && !snapshot.suppressed {
            snapshots.removeValue(forKey: key)
        } else if snapshots[key] != snapshot {
            snapshots[key] = snapshot
        }
        if snapshot.delegated, let ownerPanelId = snapshot.delegatedBy {
            delegateKeysByOwner[ownerPanelId, default: []].insert(key)
        }
        if snapshot.delegated {
            delegationOwners[snapshot.surfaceId] = .some(snapshot.delegatedBy)
        } else {
            delegationOwners.removeValue(forKey: snapshot.surfaceId)
        }
    }

    func remove(workspaceId: UUID, surfaceId: UUID) {
        let key = Self.key(workspaceId: workspaceId, surfaceId: surfaceId)
        let prior = snapshots.removeValue(forKey: key)
        removeDelegateKey(key, ownerPanelId: prior?.delegatedBy)
        if prior != nil {
            delegationOwners.removeValue(forKey: surfaceId)
        }
    }

    /// Delegate hops ending at this surface (0 when it is not a delegate).
    func delegationDepth(of surfaceId: UUID) -> Int {
        DelegateLineage.depth(of: surfaceId, owners: delegationOwners)
    }

    func delegateDescendants(of surfaceId: UUID) -> [UUID] {
        DelegateLineage.descendants(of: surfaceId, owners: delegationOwners)
    }

    func delegatesOwned(by ownerPanelId: UUID) -> [PanelAttentionSnapshot] {
        (delegateKeysByOwner[ownerPanelId] ?? [])
            .compactMap { snapshots[$0] }
            .filter { $0.delegated && $0.delegatedBy == ownerPanelId }
            .sorted {
                if $0.workspaceId != $1.workspaceId {
                    return $0.workspaceId.uuidString < $1.workspaceId.uuidString
                }
                return $0.surfaceId.uuidString < $1.surfaceId.uuidString
            }
    }

    func prune(workspaceId: UUID, validSurfaceIds: Set<UUID>) {
        snapshots = snapshots.filter {
            $0.value.workspaceId != workspaceId || validSurfaceIds.contains($0.value.surfaceId)
        }
        rebuildDelegateIndex()
    }

    private func removeDelegateKey(_ key: String, ownerPanelId: UUID?) {
        guard let ownerPanelId else { return }
        delegateKeysByOwner[ownerPanelId]?.remove(key)
        if delegateKeysByOwner[ownerPanelId]?.isEmpty == true {
            delegateKeysByOwner.removeValue(forKey: ownerPanelId)
        }
    }

    private func rebuildDelegateIndex() {
        delegateKeysByOwner.removeAll(keepingCapacity: true)
        delegationOwners.removeAll(keepingCapacity: true)
        for (key, snapshot) in snapshots where snapshot.delegated {
            if let ownerPanelId = snapshot.delegatedBy {
                delegateKeysByOwner[ownerPanelId, default: []].insert(key)
            }
            delegationOwners[snapshot.surfaceId] = .some(snapshot.delegatedBy)
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
    private var didInstallCloseObserver = false

    init(feedProjection: FeedProjectionBridge = .shared) {
        self.feedProjection = feedProjection
    }

    func installCloseObserver() {
        guard !didInstallCloseObserver else { return }
        didInstallCloseObserver = true
        PanelLineage.shared.addPanelClosedForGoodObserver { [weak self] closingPanelIds in
            self?.releaseDelegatesForClosingPanels(closingPanelIds)
        }
    }

    @discardableResult
    func raise(
        workspaceId: UUID,
        surfaceId: UUID,
        reason: String,
        kind: PanelFlagKind? = nil,
        callerPanelId: UUID? = nil,
        by actor: PanelAttentionActor = .agent,
        title: String?
    ) throws -> PanelMetadataStore.WriteResult {
        try mutate(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flag: .raise(reason, kind: kind),
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
            ownerTitle = owner.workspace.panelTitle(panelId: ownerPanelId) ?? panel.displayTitle
        } else {
            ownerTitle = nil
        }
        for entry in PanelAttentionIndex.shared.delegatesOwned(by: ownerPanelId) {
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
        // Restore replays panels before their workspaces are registered, so a
        // delegate restored ahead of its delegate owner missed its depth.
        refreshAllDelegationDepths()
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
                owner.workspace.panelTitle(panelId: ownerPanelId) ?? ownerPanel.displayTitle,
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

    /// Re-read every delegate's depth; for restores that replay panels before
    /// their workspaces are registered.
    func refreshAllDelegationDepths() {
        refreshDelegationDepths(of: Array(PanelAttentionIndex.shared.delegationOwners.keys))
    }

    private func refreshDelegationDepths(below surfaceId: UUID) {
        refreshDelegationDepths(of: PanelAttentionIndex.shared.delegateDescendants(of: surfaceId))
    }

    private func refreshDelegationDepths(of surfaceIds: [UUID]) {
        for surfaceId in surfaceIds {
            AppDelegate.shared?.workspaceContainingPanel(panelId: surfaceId)?
                .workspace.refreshDelegationDepth(forSurface: surfaceId)
        }
    }

    func remove(workspaceId: UUID, surfaceId: UUID) {
        remove(workspaceId: workspaceId, surfaceId: surfaceId, closing: true)
    }

    /// C11-490: a panel leaving for another workspace. The source drops it as
    /// `remove` does, but its open ask stays in the feed: the ask follows its
    /// journal owner to the destination, so a move neither closes nor reopens it.
    func detach(workspaceId: UUID, surfaceId: UUID) {
        remove(workspaceId: workspaceId, surfaceId: surfaceId, closing: false)
    }

    private func remove(workspaceId: UUID, surfaceId: UUID, closing: Bool) {
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
        let descendants = PanelAttentionIndex.shared.delegateDescendants(of: surfaceId)
        PanelAttentionIndex.shared.remove(workspaceId: workspaceId, surfaceId: surfaceId)
        refreshDelegationDepths(of: descendants)
        if closing {
            feedProjection.removePanel(workspaceID: workspaceId, panelID: surfaceId)
        } else {
            feedProjection.detachPanel(workspaceID: workspaceId, panelID: surfaceId)
        }
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
        // Only delegates below a dropped panel change depth; most prunes drop
        // nothing and skip the refresh.
        let droppedDescendants = PanelAttentionIndex.shared.snapshots.values
            .filter { $0.workspaceId == workspaceId && !validSurfaceIds.contains($0.surfaceId) }
            .flatMap { PanelAttentionIndex.shared.delegateDescendants(of: $0.surfaceId) }
        PanelAttentionIndex.shared.prune(
            workspaceId: workspaceId,
            validSurfaceIds: validSurfaceIds
        )
        if !droppedDescendants.isEmpty {
            refreshDelegationDepths(of: Array(Set(droppedDescendants)))
        }
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
                    kind: transaction.after.flagKind,
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
                    reason: reason,
                    kind: transaction.after.flagKind
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
        let prior = PanelAttentionIndex.shared.snapshot(
            workspaceId: snapshot.workspaceId,
            surfaceId: snapshot.surfaceId
        )
        let lineageChanged = prior.delegated != snapshot.delegated
            || prior.delegatedBy != snapshot.delegatedBy
        PanelAttentionIndex.shared.publish(snapshot)
        let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: snapshot.surfaceId,
            preferredWorkspaceId: snapshot.workspaceId
        )?.workspace
        if snapshot.delegated, let ownerPanelId = snapshot.delegatedBy,
           let owner = AppDelegate.shared?.workspaceContainingPanel(panelId: ownerPanelId),
           let ownerPanel = owner.workspace.panels[ownerPanelId] {
            workspace?.setDelegationOwnerTitle(
                owner.workspace.panelTitle(panelId: ownerPanelId) ?? ownerPanel.displayTitle,
                forSurface: snapshot.surfaceId
            )
        } else {
            workspace?.setDelegationOwnerTitle(nil, forSurface: snapshot.surfaceId)
        }
        workspace?.setAttentionSnapshot(snapshot, forSurface: snapshot.surfaceId)
        // A delegation change moves every delegate below this panel up or
        // down one hop; they can live in other workspaces.
        if lineageChanged {
            refreshDelegationDepths(below: snapshot.surfaceId)
        }
        // Copy the snapshot off main. Do not project the feed row here.
        feedProjection.noteAttention(snapshot)
    }
}
