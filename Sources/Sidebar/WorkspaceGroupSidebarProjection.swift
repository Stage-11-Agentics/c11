import Foundation
import Combine

struct WorkspaceGroupHeaderSummary: Equatable {
    var memberCount: Int = 0
    var flaggedCount: Int = 0
    var waitingCount: Int = 0
    var unreadCount: Int = 0
    static let zero = Self()
}

/// Capture resolved attention, including plain and suppressed tabs. No agent-kind filter.
struct WorkspaceGroupTabAttention: Equatable {
    let isFlagged: Bool
    let isWaiting: Bool
    let isSuppressed: Bool
}

struct WorkspaceGroupMemberAttention: Equatable {
    let flaggedCount: Int
    let waitingCount: Int
    let unreadCount: Int

    init(tabs: [WorkspaceGroupTabAttention] = [], unreadCount: Int = 0) {
        flaggedCount = tabs.reduce(0) { $0 + ($1.isFlagged ? 1 : 0) }
        waitingCount = tabs.reduce(0) { $0 + ($1.isWaiting && !$1.isSuppressed ? 1 : 0) }
        // The workspace notification index includes workspace-scoped demand once.
        // Do not sum per-tab notification counts or WorkspacePulse's synthetic waiting fallback.
        self.unreadCount = unreadCount
    }

    static let zero = Self()
}

struct WorkspaceGroupSidebarHeader: Equatable {
    let group: WorkspaceGroup
    let summary: WorkspaceGroupHeaderSummary
    let isActive: Bool
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

struct WorkspaceGroupSidebarProjection: Equatable {
    let rows: [WorkspaceGroupSidebarRow]
    let visibleWorkspaceIds: [UUID]
    let headersById: [UUID: WorkspaceGroupSidebarHeader]

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
        selectedWorkspaceId: UUID? = nil
    ) -> Self {
        var seenGroups = Set<UUID>()
        let groups = groups.filter { seenGroups.insert($0.id).inserted }
        var members: [UUID: [WorkspaceGroupSidebarWorkspaceRow]] = [:]
        var summaries: [UUID: WorkspaceGroupHeaderSummary] = [:]
        var activeGroups = Set<UUID>()
        var pinnedUngrouped: [WorkspaceGroupSidebarWorkspaceRow] = []
        var unpinnedUngrouped: [WorkspaceGroupSidebarWorkspaceRow] = []
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
            } else if workspace.isPinned {
                pinnedUngrouped.append(row)
            } else {
                unpinnedUngrouped.append(row)
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
        for pinned in [true, false] {
            for group in groups where group.isPinned == pinned {
                let header = WorkspaceGroupSidebarHeader(group: group, summary: summaries[group.id] ?? .zero,
                                                         isActive: activeGroups.contains(group.id))
                headersById[group.id] = header
                rows.append(.group(header))
                if !group.isCollapsed { appendWorkspaces(members[group.id] ?? []) }
            }
            appendWorkspaces(pinned ? pinnedUngrouped : unpinnedUngrouped)
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
}

/// A single sidebar/window subscription owner, independent of visible rows and mounted bodies.
/// Workspace output can invalidate a capture; equality prevents unchanged header publications.
@MainActor
final class WorkspaceGroupSidebarCoordinator: ObservableObject {
    typealias RefreshScheduler = (@escaping @MainActor () -> Void) -> Void
    @Published private(set) var projection: WorkspaceGroupSidebarProjection = .empty

    private let scheduleRefresh: RefreshScheduler
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
    private var projectedMemberIds: [UUID] = []
    private var projectedSelection: UUID?
    private var hasProjectedSource = false

    init(scheduleRefresh: @escaping RefreshScheduler = { work in DispatchQueue.main.async { work() } }) {
        self.scheduleRefresh = scheduleRefresh
    }

    func attach(manager: WorkspaceManager, notificationStore: TerminalNotificationStore) {
        let identity = [ObjectIdentifier(manager), ObjectIdentifier(notificationStore)]
        guard attachmentIdentity != identity else { return }
        let source = WorkspaceGroupSidebarObservationSource(
            structureChanges: Publishers.Merge(manager.$workspaces.map { _ in () }, manager.$workspaceGroups.map { _ in () })
                .eraseToAnyPublisher(),
            selectionChanges: manager.$selectedWorkspaceId.map { _ in () }.eraseToAnyPublisher(),
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
                            let tabs = workspace.panels.keys.map { tabId in
                                let attention = workspace.attentionSnapshot(panelId: tabId)
                                let state = workspace.resolvedSurfaceTabActivityState(
                                    panelId: tabId,
                                    hasExactSurfaceNotification: notificationStore.hasUnreadNotification(
                                        forWorkspaceId: workspace.id, surfaceId: tabId))
                                return WorkspaceGroupTabAttention(isFlagged: attention.isFlagged,
                                                                  isWaiting: state == .waiting,
                                                                  isSuppressed: attention.suppressed)
                            }
                            return WorkspaceGroupMemberAttention(tabs: tabs,
                                unreadCount: notificationStore.unreadCount(forWorkspaceId: workspace.id))
                        })
                }
            },
            selectedWorkspaceId: { [weak manager] in manager?.selectedWorkspaceId })
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
        projectedMemberIds.removeAll()
        projectedSelection = nil
        hasProjectedSource = false
        dirtyMembers.removeAll()
        source = nil
        needsStructure = false
        needsAllAttention = false
        refreshScheduled = false
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
        let selected = source.selectedWorkspaceId()
        var structureChanged = !hasProjectedSource || groups != projectedGroups || memberIds != projectedMemberIds
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
        if structureChanged {
            // Rebuild membership and canonical-index lookup only on structural changes.
            let next = WorkspaceGroupSidebarProjection.make(
                groups: groups, workspaces: memberIds.compactMap { orderEntries[$0] },
                attentionByWorkspace: attentionByWorkspace, selectedWorkspaceId: selected)
            projectedGroups = groups
            projectedMemberIds = memberIds
            projectedSelection = selected
            hasProjectedSource = true
            if next != projection { projection = next }
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
            headers[groupId] = WorkspaceGroupSidebarHeader(group: header.group, summary: summary, isActive: header.isActive)
        }
        let selectedGroupId = selected.flatMap { orderEntries[$0]?.groupId }
        if selected != projectedSelection {
            for (id, header) in headers {
                let isActive = id == selectedGroupId
                if header.isActive != isActive {
                    headers[id] = WorkspaceGroupSidebarHeader(group: header.group, summary: header.summary, isActive: isActive)
                }
            }
            projectedSelection = selected
        }
        guard headers != projection.headersById else { return }
        let rows = projection.rows.map { row -> WorkspaceGroupSidebarRow in
            if case .group(let header) = row, let updated = headers[header.group.id] { return .group(updated) }
            return row
        }
        projection = WorkspaceGroupSidebarProjection(rows: rows, visibleWorkspaceIds: projection.visibleWorkspaceIds,
                                                     headersById: headers)
    }
}
