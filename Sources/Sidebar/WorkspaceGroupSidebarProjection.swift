import Foundation
import Combine
import Bonsplit

struct WorkspaceGroupHeaderSummary: Equatable {
    var memberCount: Int = 0
    var flaggedCount: Int = 0
    var waitingCount: Int = 0
    var unreadCount: Int = 0
    static let zero = Self()
}

/// Capture resolved attention, including plain and suppressed tabs. No agent-kind filter.
struct WorkspaceGroupPanelAttention: Equatable {
    let isFlagged: Bool
    let isWaiting: Bool
    let isSuppressed: Bool
}

/// What one agent tab's sidebar pulse mark shows. Headers ignore it; a change
/// republishes the projection so rows rebuild their pulse, since a lifecycle
/// edge (cold above all) often arrives with no notification to do it.
struct WorkspaceGroupPanelLifecycle: Equatable {
    let state: BonsplitTabActivityState
    let promptCacheExpired: Bool
    /// Delegate hops, so a lineage change above this panel redraws its baseline.
    var lineageDepth: Int = 0
}

struct WorkspaceGroupMemberAttention: Equatable {
    let flaggedCount: Int
    let waitingCount: Int
    let unreadCount: Int
    let lifecycleByPanel: [UUID: WorkspaceGroupPanelLifecycle]
    /// C11H-296: the store's card-context revision (a panel's title or
    /// description). Headers ignore it; a change alone republishes the
    /// projection, throttled, so agent rows show a new description.
    let cardContextRevision: UInt64

    init(
        panels: [WorkspaceGroupPanelAttention] = [],
        unreadCount: Int = 0,
        lifecycleByPanel: [UUID: WorkspaceGroupPanelLifecycle] = [:],
        cardContextRevision: UInt64 = 0
    ) {
        flaggedCount = panels.reduce(0) { $0 + ($1.isFlagged ? 1 : 0) }
        waitingCount = panels.reduce(0) { $0 + ($1.isWaiting && !$1.isSuppressed ? 1 : 0) }
        // Raw unread history includes suppressed and workspace-scoped entries once.
        // Do not sum per-tab notification counts or WorkspacePulse's synthetic waiting fallback.
        self.unreadCount = unreadCount
        self.lifecycleByPanel = lifecycleByPanel
        self.cardContextRevision = cardContextRevision
    }

    static let zero = Self()
}

struct WorkspaceGroupSidebarHeader: Equatable {
    let group: WorkspaceGroup
    let summary: WorkspaceGroupHeaderSummary
    let isActive: Bool
    /// The group's own Captain (C11H-299), shown once on the header.
    var captain: WorkspaceCaptainSummary = .unset
}

struct WorkspaceGroupSidebarWorkspaceRow: Equatable {
    let workspaceId: UUID
    let groupId: UUID?
    let canonicalIndex: Int
    let isPinned: Bool
    var moveUpTarget: UUID? = nil
    var moveDownTarget: UUID? = nil
    var isLastGroupMember: Bool = false
}

enum WorkspaceGroupSidebarRow: Equatable, Identifiable {
    enum ID: Hashable {
        case group(UUID)
        case workspace(UUID)
    }

    case group(WorkspaceGroupSidebarHeader)
    case workspace(WorkspaceGroupSidebarWorkspaceRow)

    var id: ID {
        switch self {
        case .group(let header): return .group(header.group.id)
        case .workspace(let row): return .workspace(row.workspaceId)
        }
    }
}

/// Full-width folder headers separate row-major tile runs. Stable IDs preserve
/// reveal and drag targeting when the number of columns changes.
struct WorkspaceSidebarTileRun: Identifiable {
    let rows: [WorkspaceGroupSidebarRow]
    var id: WorkspaceGroupSidebarRow.ID { rows[0].id }

    static func pack(_ rows: [WorkspaceGroupSidebarRow]) -> [Self] {
        var runs: [Self] = []
        var pending: [WorkspaceGroupSidebarRow] = []
        var previousGroup: UUID?
        func flush() {
            if !pending.isEmpty { runs.append(Self(rows: pending)); pending.removeAll(keepingCapacity: true) }
        }
        for row in rows {
            switch row {
            case .group:
                flush()
                runs.append(Self(rows: [row]))
                previousGroup = nil
            case .workspace(let item):
                if !pending.isEmpty && item.groupId != previousGroup { flush() }
                pending.append(row)
                previousGroup = item.groupId
            }
        }
        flush()
        return runs
    }

    /// Splits a run of workspace rows into grid lines of at most `columns`
    /// rows, in order. Each line is drawn as one row of full cards.
    func lines(columns: Int) -> [Self] {
        let width = max(1, columns)
        return stride(from: 0, to: rows.count, by: width).map {
            Self(rows: Array(rows[$0..<min($0 + width, rows.count)]))
        }
    }
}

struct WorkspaceGroupSidebarProjection: Equatable {
    let rows: [WorkspaceGroupSidebarRow]
    let visibleWorkspaceIds: [UUID]
    let headersById: [UUID: WorkspaceGroupSidebarHeader]
    /// Bumped when any member's agent lifecycle changes, so the sidebar
    /// rebuilds row pulses even when no header count moved.
    var pulseRevision = 0

    static let empty = Self(rows: [], visibleWorkspaceIds: [], headersById: [:])

    /// Selection uses stable IDs; canonical indexes can change after a menu or CLI move.
    static func selectionRange(anchor: UUID?, target: UUID, visibleWorkspaceIds: [UUID]) -> [UUID]? {
        guard let anchor, let start = visibleWorkspaceIds.firstIndex(of: anchor),
              let end = visibleWorkspaceIds.firstIndex(of: target) else { return nil }
        return Array(visibleWorkspaceIds[min(start, end)...max(start, end)])
    }

    /// One membership/index pass and one folder pass: O(workspaces + groups).
    /// Canonical indexes are never derived from visible rows or folder positions.
    static func make(
        groups: [WorkspaceGroup],
        workspaces: [WorkspaceOrderEntry],
        attentionByWorkspace: [UUID: WorkspaceGroupMemberAttention] = [:],
        selectedWorkspaceId: UUID? = nil,
        captainByGroup: [UUID: WorkspaceCaptainSummary] = [:],
        rootOrder: [UUID]? = nil
    ) -> Self {
        var seenGroups = Set<UUID>()
        let groups = groups.filter { seenGroups.insert($0.id).inserted }
        var members: [UUID: [WorkspaceGroupSidebarWorkspaceRow]] = [:]
        var summaries: [UUID: WorkspaceGroupHeaderSummary] = [:]
        var activeGroups = Set<UUID>()
        var ungroupedRows: [UUID: WorkspaceGroupSidebarWorkspaceRow] = [:]
        for (index, workspace) in workspaces.enumerated() {
            // A transient orphan remains reachable as an ungrouped row.
            let groupId = workspace.groupId.flatMap { seenGroups.contains($0) ? $0 : nil }
            let row = WorkspaceGroupSidebarWorkspaceRow(workspaceId: workspace.id, groupId: groupId, canonicalIndex: index, isPinned: workspace.isPinned)
            if let groupId {
                members[groupId, default: []].append(row)
                let attention = attentionByWorkspace[workspace.id] ?? .zero
                summaries[groupId, default: .zero].memberCount += 1
                summaries[groupId, default: .zero].flaggedCount += attention.flaggedCount
                summaries[groupId, default: .zero].waitingCount += attention.waitingCount
                summaries[groupId, default: .zero].unreadCount += attention.unreadCount
                if workspace.id == selectedWorkspaceId { activeGroups.insert(groupId) }
            } else {
                ungroupedRows[workspace.id] = row
            }
        }
        var rows: [WorkspaceGroupSidebarRow] = []
        var visibleWorkspaceIds: [UUID] = []
        var headersById: [UUID: WorkspaceGroupSidebarHeader] = [:]
        func appendWorkspaces(_ workspaces: [WorkspaceGroupSidebarWorkspaceRow]) {
            for (index, original) in workspaces.enumerated() {
                var row = original
                if index > 0, workspaces[index - 1].isPinned == row.isPinned {
                    row.moveUpTarget = workspaces[index - 1].workspaceId
                }
                if index + 1 < workspaces.count, workspaces[index + 1].isPinned == row.isPinned {
                    row.moveDownTarget = workspaces[index + 1].workspaceId
                }
                row.isLastGroupMember = row.groupId != nil && index == workspaces.count - 1
                rows.append(.workspace(row))
                visibleWorkspaceIds.append(row.workspaceId)
            }
        }
        // C11H-342: groups and ungrouped workspaces in one root order. An
        // ungrouped row's move neighbours are its root neighbours (a group too).
        let root = WorkspaceRootOrder.resolve(stored: rootOrder, groups: groups, workspaces: workspaces)
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        for (index, entry) in root.enumerated() {
            if entry.isGroup {
                guard let group = groupsById[entry.id] else { continue }
                let header = WorkspaceGroupSidebarHeader(group: group, summary: summaries[group.id] ?? .zero,
                                                         isActive: activeGroups.contains(group.id),
                                                         captain: captainByGroup[group.id] ?? .unset)
                headersById[group.id] = header
                rows.append(.group(header))
                if !group.isCollapsed { appendWorkspaces(members[group.id] ?? []) }
            } else if var row = ungroupedRows[entry.id] {
                if index > 0, root[index - 1].isPinned == entry.isPinned { row.moveUpTarget = root[index - 1].id }
                if index + 1 < root.count, root[index + 1].isPinned == entry.isPinned {
                    row.moveDownTarget = root[index + 1].id
                }
                rows.append(.workspace(row))
                visibleWorkspaceIds.append(row.workspaceId)
            }
        }
        return Self(rows: rows, visibleWorkspaceIds: visibleWorkspaceIds, headersById: headersById)
    }
}

/// Publisher/snapshot boundary keeps coordinator tests independent of AppKit/terminal creation.
/// Each provider is read after its publisher's pre-mutation notification has returned.
@MainActor
struct WorkspaceGroupSidebarObservedWorkspace {
    let identity: ObjectIdentifier
    let id: UUID
    let changes: AnyPublisher<Void, Never>
    let orderEntry: () -> WorkspaceOrderEntry
    let attention: () -> WorkspaceGroupMemberAttention
}

@MainActor
struct WorkspaceGroupSidebarObservationSource {
    let structureChanges: AnyPublisher<Void, Never>
    let selectionChanges: AnyPublisher<Void, Never>
    let notificationChanges: AnyPublisher<Void, Never>
    let groups: () -> [WorkspaceGroup]
    let workspaces: () -> [WorkspaceGroupSidebarObservedWorkspace]
    let selectedWorkspaceId: () -> UUID?
    /// Each group's Captain summary; a change arrives on `structureChanges`.
    var groupCaptains: () -> [UUID: WorkspaceCaptainSummary] = { [:] }
    /// C11H-342: the stored root order; a change arrives on `structureChanges`.
    var rootOrder: () -> [UUID]? = { nil }
}

/// A single sidebar/window subscription owner, independent of visible rows and mounted bodies.
/// Workspace output can invalidate a capture; equality prevents unchanged header publications.
@MainActor
final class WorkspaceGroupSidebarCoordinator: ObservableObject {
    typealias RefreshScheduler = (@escaping @MainActor () -> Void) -> Void
    typealias DelayedScheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    @Published private(set) var projection: WorkspaceGroupSidebarProjection = .empty

    /// C11H-296: a title or description change alone republishes at most once
    /// in this window, so a burst of writes from many agents costs a bounded
    /// number of sidebar list evaluations and a lone write shows at once.
    static let cardContextWindow: TimeInterval = 0.25

    private let scheduleRefresh: RefreshScheduler
    private let scheduleAfter: DelayedScheduler
    private let now: () -> TimeInterval
    private var lastPublishAt: TimeInterval?
    private var cardContextPending = false
    private var cardContextTrailingScheduled = false
    private var source: WorkspaceGroupSidebarObservationSource?
    private var rootSubscriptions: [AnyCancellable] = []
    private var memberSubscriptions: [UUID: AnyCancellable] = [:]
    private var observedMembers: [UUID: WorkspaceGroupSidebarObservedWorkspace] = [:]
    private var memberIds: [UUID] = []
    private var orderEntries: [UUID: WorkspaceOrderEntry] = [:]
    private var attentionByWorkspace: [UUID: WorkspaceGroupMemberAttention] = [:]
    private var dirtyMembers = Set<UUID>()
    private var needsStructure = false
    private var needsAllAttention = false
    private var refreshScheduled = false
    private var generation = 0
    private var attachmentIdentity: [ObjectIdentifier]?
    private var projectedGroups: [WorkspaceGroup] = []
    private var projectedGroupCaptains: [UUID: WorkspaceCaptainSummary] = [:]
    private var projectedRootOrder: [UUID]?
    private var projectedMemberIds: [UUID] = []
    private var projectedSelection: UUID?
    private var hasProjectedSource = false

    init(
        scheduleRefresh: @escaping RefreshScheduler = { work in DispatchQueue.main.async { work() } },
        scheduleAfter: @escaping DelayedScheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.scheduleRefresh = scheduleRefresh
        self.scheduleAfter = scheduleAfter
        self.now = now
    }

    func attach(manager: WorkspaceManager, notificationStore: TerminalNotificationStore) {
        let identity = [ObjectIdentifier(manager), ObjectIdentifier(notificationStore)]
        guard attachmentIdentity != identity else { return }
        let source = WorkspaceGroupSidebarObservationSource(
            structureChanges: Publishers.Merge4(manager.$workspaces.map { _ in () }, manager.$workspaceGroups.map { _ in () },
                                                manager.workspaceGroupCaptainBoard.$summaries.map { _ in () },
                                                manager.$workspaceRootOrder.map { _ in () })
                .eraseToAnyPublisher(),
            selectionChanges: manager.$storedSelectedWorkspaceId.map { _ in () }.eraseToAnyPublisher(),
            notificationChanges: notificationStore.objectWillChange.eraseToAnyPublisher(),
            groups: { [weak manager] in manager?.workspaceGroups ?? [] },
            workspaces: { [weak manager, weak notificationStore] in
                (manager?.workspaces ?? []).map { workspace in
                    let workspaceId = workspace.id
                    return WorkspaceGroupSidebarObservedWorkspace(
                        identity: ObjectIdentifier(workspace), id: workspace.id,
                        changes: workspace.objectWillChange.eraseToAnyPublisher(),
                        orderEntry: { [weak workspace] in
                            WorkspaceOrderEntry(id: workspaceId, isPinned: workspace?.isPinned ?? false,
                                                groupId: workspace?.groupId)
                        },
                        attention: { [weak workspace, weak notificationStore] in
                            guard let workspace, let notificationStore else { return .zero }
                            var lifecycle: [UUID: WorkspaceGroupPanelLifecycle] = [:]
                            let panels = workspace.panels.keys.map { panelId in
                                let attention = workspace.attentionSnapshot(panelId: panelId)
                                let state = workspace.resolvedSurfacePanelActivityState(
                                    panelId: panelId,
                                    hasExactSurfaceNotification: notificationStore.hasUnreadNotification(
                                        forWorkspaceId: workspace.id, surfaceId: panelId))
                                if let state {
                                    lifecycle[panelId] = WorkspaceGroupPanelLifecycle(
                                        state: state,
                                        promptCacheExpired: workspace.promptCacheExpiredAgentIds.contains(panelId),
                                        lineageDepth: workspace.delegationDepth(panelId: panelId))
                                }
                                return WorkspaceGroupPanelAttention(isFlagged: attention.isFlagged,
                                                                  isWaiting: state == .waiting,
                                                                  isSuppressed: attention.suppressed)
                            }
                            return WorkspaceGroupMemberAttention(panels: panels,
                                unreadCount: notificationStore.unreadCount(forWorkspaceId: workspace.id),
                                lifecycleByPanel: lifecycle,
                                cardContextRevision: PanelMetadataStore.shared.cardContextRevision(
                                    workspaceId: workspace.id))
                        })
                }
            },
            selectedWorkspaceId: { [weak manager] in manager?.selectedWorkspaceId },
            groupCaptains: { [weak manager] in manager?.workspaceGroupCaptainBoard.summaries ?? [:] },
            rootOrder: { [weak manager] in manager?.workspaceRootOrder })
        attach(source: source)
        attachmentIdentity = identity
    }

    /// Internal injection seam also used by the production adapter above.
    func attach(source: WorkspaceGroupSidebarObservationSource) {
        clearSubscriptions()
        self.source = source
        needsStructure = true
        needsAllAttention = true
        rootSubscriptions = [
            source.structureChanges.sink { [weak self] in
                self?.needsStructure = true
                self?.requestRefresh()
            },
            source.selectionChanges.sink { [weak self] in self?.requestRefresh() },
            source.notificationChanges.sink { [weak self] in
                self?.needsAllAttention = true
                self?.requestRefresh()
            }
        ]
        // Initial attachment runs after the model exists, not from objectWillChange.
        refresh()
    }

    func detach() {
        clearSubscriptions()
        if projection != .empty { projection = .empty }
    }

    private func clearSubscriptions() {
        generation &+= 1
        attachmentIdentity = nil
        rootSubscriptions.removeAll()
        memberSubscriptions.removeAll()
        observedMembers.removeAll()
        memberIds.removeAll()
        orderEntries.removeAll()
        attentionByWorkspace.removeAll()
        projectedGroups.removeAll()
        projectedGroupCaptains.removeAll()
        projectedRootOrder = nil
        projectedMemberIds.removeAll()
        projectedSelection = nil
        hasProjectedSource = false
        dirtyMembers.removeAll()
        source = nil
        needsStructure = false
        needsAllAttention = false
        refreshScheduled = false
        lastPublishAt = nil
        cardContextPending = false
        cardContextTrailingScheduled = false
    }

    private func requestRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let expectedGeneration = generation
        scheduleRefresh { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        refreshProjection()
        publishPendingCardContext()
    }

    /// Every publication rebuilds the rows' pulses, so each one also carries
    /// a pending card-context change.
    private func publish(_ next: WorkspaceGroupSidebarProjection) {
        cardContextPending = false
        lastPublishAt = now()
        projection = next
    }

    /// A card-context change no other publication carried: at once when the
    /// last publication is a window old, else once at the window's end.
    private func publishPendingCardContext() {
        guard cardContextPending, !cardContextTrailingScheduled else { return }
        let elapsed = lastPublishAt.map { now() - $0 } ?? .infinity
        guard elapsed < Self.cardContextWindow else {
            var next = projection
            next.pulseRevision &+= 1
            publish(next)
            return
        }
        cardContextTrailingScheduled = true
        let expectedGeneration = generation
        scheduleAfter(Self.cardContextWindow - elapsed) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.cardContextTrailingScheduled = false
            guard self.cardContextPending else { return }
            var next = self.projection
            next.pulseRevision &+= 1
            self.publish(next)
        }
    }

    private func refreshProjection() {
        guard let source else { return }
        if needsStructure {
            needsStructure = false
            let members = source.workspaces()
            let liveIds = Set(members.map(\.id))
            for id in memberSubscriptions.keys.filter({ !liveIds.contains($0) }) {
                memberSubscriptions.removeValue(forKey: id)
                observedMembers.removeValue(forKey: id)
                orderEntries.removeValue(forKey: id)
                attentionByWorkspace.removeValue(forKey: id)
                dirtyMembers.remove(id)
            }
            memberIds = members.map(\.id)
            for member in members {
                if observedMembers[member.id]?.identity != member.identity {
                    let id = member.id
                    memberSubscriptions[id] = member.changes.sink { [weak self] in
                        self?.dirtyMembers.insert(id)
                        self?.requestRefresh()
                    }
                    dirtyMembers.insert(member.id)
                }
                observedMembers[member.id] = member
            }
        }
        let captureIds = needsAllAttention ? Set(memberIds) : dirtyMembers
        needsAllAttention = false
        dirtyMembers.removeAll()
        let groups = source.groups()
        let groupCaptains = source.groupCaptains()
        let rootOrder = source.rootOrder()
        let selected = source.selectedWorkspaceId()
        var structureChanged = !hasProjectedSource || groups != projectedGroups || memberIds != projectedMemberIds
            || groupCaptains != projectedGroupCaptains || rootOrder != projectedRootOrder
        var attentionChanges: [UUID: (old: WorkspaceGroupMemberAttention, new: WorkspaceGroupMemberAttention)] = [:]
        for id in captureIds {
            guard let member = observedMembers[id] else { continue }
            let entry = member.orderEntry()
            let attention = member.attention()
            if entry != orderEntries[id] { structureChanged = true }
            if attention != attentionByWorkspace[id] {
                attentionChanges[id] = (attentionByWorkspace[id] ?? .zero, attention)
            }
            orderEntries[id] = entry
            attentionByWorkspace[id] = attention
        }
        let pulseChanged = attentionChanges.values.contains { $0.old.lifecycleByPanel != $0.new.lifecycleByPanel }
        if attentionChanges.values.contains(where: { $0.old.cardContextRevision != $0.new.cardContextRevision }) {
            cardContextPending = true
        }
        let pulseRevision = projection.pulseRevision + (pulseChanged ? 1 : 0)
        if structureChanged {
            // Rebuild membership and canonical-index lookup only on structural changes.
            var next = WorkspaceGroupSidebarProjection.make(
                groups: groups, workspaces: memberIds.compactMap { orderEntries[$0] },
                attentionByWorkspace: attentionByWorkspace, selectedWorkspaceId: selected,
                captainByGroup: groupCaptains, rootOrder: rootOrder)
            next.pulseRevision = pulseRevision
            projectedGroups = groups
            projectedGroupCaptains = groupCaptains
            projectedRootOrder = rootOrder
            projectedMemberIds = memberIds
            projectedSelection = selected
            hasProjectedSource = true
            if next != projection { publish(next) }
            return
        }
        guard !attentionChanges.isEmpty || selected != projectedSelection else { return }
        var headers = projection.headersById
        for (id, change) in attentionChanges {
            guard let groupId = orderEntries[id]?.groupId, let header = headers[groupId] else { continue }
            var summary = header.summary
            summary.flaggedCount += change.new.flaggedCount - change.old.flaggedCount
            summary.waitingCount += change.new.waitingCount - change.old.waitingCount
            summary.unreadCount += change.new.unreadCount - change.old.unreadCount
            headers[groupId] = WorkspaceGroupSidebarHeader(group: header.group, summary: summary, isActive: header.isActive,
                                                           captain: header.captain)
        }
        let selectedGroupId = selected.flatMap { orderEntries[$0]?.groupId }
        if selected != projectedSelection {
            for (id, header) in headers {
                let isActive = id == selectedGroupId
                if header.isActive != isActive {
                    headers[id] = WorkspaceGroupSidebarHeader(group: header.group, summary: header.summary, isActive: isActive,
                                                              captain: header.captain)
                }
            }
            projectedSelection = selected
        }
        guard headers != projection.headersById || pulseChanged else { return }
        let rows = projection.rows.map { row -> WorkspaceGroupSidebarRow in
            if case .group(let header) = row, let updated = headers[header.group.id] { return .group(updated) }
            return row
        }
        publish(WorkspaceGroupSidebarProjection(rows: rows, visibleWorkspaceIds: projection.visibleWorkspaceIds,
                                                headersById: headers, pulseRevision: pulseRevision))
    }
}
