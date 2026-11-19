import Foundation

/// A window-local folder. Membership lives only on Workspace.groupId.
struct WorkspaceGroup: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    var name: String
    var color: String? = nil
    var icon: String? = nil
    var isCollapsed: Bool = false
    var isPinned: Bool = false
}

struct WorkspaceGroupOperationError: Error, LocalizedError, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }

    static let invalidParams = Self(code: "invalid_params", message: String(localized: "workspaceGroup.error.invalidParams", defaultValue: "Provide a valid, nonempty set of targets and one placement option."))
    static let duplicateWorkspace = Self(code: "duplicate_workspace", message: String(localized: "workspaceGroup.error.duplicateWorkspace", defaultValue: "A workspace appears more than once."))
    static let workspaceNotFound = Self(code: "workspace_not_found", message: String(localized: "workspaceGroup.error.workspaceNotFound", defaultValue: "The workspace does not exist in this window."))
    static let groupNotFound = Self(code: "group_not_found", message: String(localized: "workspaceGroup.error.groupNotFound", defaultValue: "The workspace group does not exist in this window."))
    static let alreadyGrouped = Self(code: "already_grouped", message: String(localized: "workspaceGroup.error.alreadyGrouped", defaultValue: "The workspace already belongs to a group. Use move to transfer it."))
    static let notMember = Self(code: "not_member", message: String(localized: "workspaceGroup.error.notMember", defaultValue: "The workspace does not belong to the destination group."))
    static let emptyGroup = Self(code: "empty_group", message: String(localized: "workspaceGroup.error.emptyGroup", defaultValue: "The workspace group is empty."))
    static let notRootItem = Self(code: "not_root_item", message: String(localized: "workspaceGroup.error.notRootItem", defaultValue: "The target is inside a group. Name a group or a workspace that is in no group."))
}

/// Immutable inputs shared by model operations, sidebar projection, and planning.
struct WorkspaceOrderEntry: Equatable, Sendable {
    let id: UUID
    let isPinned: Bool
    var groupId: UUID? = nil
}

enum WorkspaceSidebarItem: Equatable, Sendable {
    case group(WorkspaceGroup, memberWorkspaceIds: [UUID])
    case workspace(UUID)
}

enum WorkspaceGroupProjection {
    static func items(groups: [WorkspaceGroup], workspaces: [WorkspaceOrderEntry],
                      rootOrder: [UUID]? = nil) -> [WorkspaceSidebarItem] {
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return WorkspaceRootOrder.resolve(stored: rootOrder, groups: groups, workspaces: workspaces).map { entry in
            guard entry.isGroup, let group = byId[entry.id] else { return .workspace(entry.id) }
            return .group(group, memberWorkspaceIds: workspaces.filter { $0.groupId == group.id }.map(\.id))
        }
    }

    /// Old and corrupt snapshots retain their workspaces; first duplicate folder wins.
    static func restoredGroups(_ groups: [WorkspaceGroup]?) -> [WorkspaceGroup] {
        var seen = Set<UUID>()
        let unique = (groups ?? []).filter { seen.insert($0.id).inserted }
        return unique.filter(\.isPinned) + unique.filter { !$0.isPinned }
    }
}

/// A root item of the sidebar: a group, or a workspace in no group.
struct WorkspaceRootEntry: Equatable, Sendable {
    let id: UUID
    let isGroup: Bool
    let isPinned: Bool
}

/// C11H-342: one root order per pin segment, groups and ungrouped workspaces
/// interleaved. `workspaces` keeps the order of ungrouped workspaces. The
/// stored list says where each group sits among its segment's ungrouped
/// workspaces: right after the nearest of them that precedes it in the list
/// (closed or regrouped ids are passed over), else at the segment top; groups
/// sharing a place keep the list's order. A nil list, or a group the list does
/// not name, sits at the top in `groups` order: groups first, the order every
/// older build drew. The manager mirrors a reorder of `workspaces` into the
/// list (`mirrorFlatReorder`), so a group never rides along with a workspace.
enum WorkspaceRootOrder {
    static func resolve(stored: [UUID]?, groups: [WorkspaceGroup],
                        workspaces: [WorkspaceOrderEntry]) -> [WorkspaceRootEntry] {
        var seenGroups = Set<UUID>()
        let groups = groups.filter { seenGroups.insert($0.id).inserted }
        let position = Dictionary((stored ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [WorkspaceRootEntry] = []
        result.reserveCapacity(groups.count + workspaces.count)
        for pinned in [true, false] {
            // An orphan membership stays reachable as an ungrouped workspace.
            let ungrouped = workspaces.filter {
                $0.isPinned == pinned && ($0.groupId.map { !seenGroups.contains($0) } ?? true)
            }
            let ungroupedIds = Set(ungrouped.map(\.id))
            var anchored: [UUID?: [UUID]] = [:]
            for group in groups where group.isPinned == pinned {
                var anchor: UUID?
                if let stored, let index = position[group.id] {
                    anchor = stored[..<index].last { ungroupedIds.contains($0) }
                }
                anchored[anchor, default: []].append(group.id)
            }
            func appendGroups(after anchor: UUID?) {
                // Stable: groups the list does not name keep `groups` order, after named ones.
                let bucket = (anchored[anchor] ?? []).enumerated().sorted {
                    (position[$0.element] ?? Int.max, $0.offset) < (position[$1.element] ?? Int.max, $1.offset)
                }
                for (_, id) in bucket { result.append(.init(id: id, isGroup: true, isPinned: pinned)) }
            }
            appendGroups(after: nil)
            for workspace in ungrouped {
                result.append(.init(id: workspace.id, isGroup: false, isPinned: pinned))
                appendGroups(after: workspace.id)
            }
        }
        return result
    }

    /// The outcome of a root move, applied as one unit by the manager. Feeding
    /// the three finals back to `resolve` yields `finalRoot` exactly.
    struct Plan: Equatable, Sendable {
        let finalWorkspaces: [WorkspaceOrderEntry]
        let finalGroups: [WorkspaceGroup]
        let finalRoot: [WorkspaceRootEntry]
        let changed: Bool
    }

    /// A group moves among its segment's root items. Pin never changes: a
    /// target in the other segment clamps to this segment's near end. An index
    /// counts groups only (the group at that index is displaced downward).
    static func moveGroup(groups: [WorkspaceGroup], workspaces: [WorkspaceOrderEntry], stored: [UUID]?,
                          groupId: UUID, toIndex: Int? = nil, before: UUID? = nil, after: UUID? = nil) throws -> Plan {
        guard [toIndex != nil, before != nil, after != nil].filter({ $0 }).count == 1 else {
            throw WorkspaceGroupOperationError.invalidParams
        }
        guard groups.contains(where: { $0.id == groupId }) else { throw WorkspaceGroupOperationError.groupNotFound }
        let root = resolve(stored: stored, groups: groups, workspaces: workspaces)
        var before = before
        var after = after
        if let toIndex {
            guard toIndex >= 0 else { throw WorkspaceGroupOperationError.invalidParams }
            let others = root.filter { $0.isGroup && $0.id != groupId }
            if toIndex < others.count { before = others[toIndex].id } else { after = others.last?.id }
            if before == nil && after == nil { after = groupId }
        }
        let final = try place(groupId, in: root, before: before, after: after)
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let finalGroups = final.filter(\.isGroup).compactMap { byId[$0.id] }
        return Plan(finalWorkspaces: workspaces, finalGroups: finalGroups, finalRoot: final,
                    changed: final != root || finalGroups != groups)
    }

    /// A workspace leaves its group (if any) for the root, before or after a
    /// root item; with neither, it goes to the end of its pin segment. The
    /// canonical move is the W1 transfer next to its nearest ungrouped neighbour.
    static func moveWorkspaceToRoot(groups: [WorkspaceGroup], workspaces: [WorkspaceOrderEntry], stored: [UUID]?,
                                    workspaceId: UUID, before: UUID? = nil, after: UUID? = nil) throws -> Plan {
        try WorkspaceReorderPlanner.validateTargets([workspaceId], workspaces: workspaces)
        guard before == nil || after == nil else { throw WorkspaceGroupOperationError.invalidParams }
        let source = workspaces.first { $0.id == workspaceId }!
        let root = resolve(stored: stored, groups: groups, workspaces: workspaces)
        var detached = root.filter { $0.id != workspaceId }
        let entry = WorkspaceRootEntry(id: workspaceId, isGroup: false, isPinned: source.isPinned)
        let index = root.firstIndex(of: entry) ?? segmentEnd(entry.isPinned, in: detached)
        detached.insert(entry, at: index)
        let final = try place(workspaceId, in: detached, before: before,
                              after: (before ?? after) == nil ? lastInSegment(entry, of: detached) : after)
        let segment = final.filter { !$0.isGroup && $0.isPinned == entry.isPinned }
        let groupIds = Set(groups.map(\.id))
        let peersInPlace = workspaces.filter {
            $0.isPinned == entry.isPinned
                && ($0.id == workspaceId || $0.groupId.map { !groupIds.contains($0) } ?? true)
        }.map(\.id)
        var finalOrder = workspaces.map(\.id)
        if peersInPlace != segment.map(\.id) {
            // Its place among the ungrouped workspaces changed: W1 transfer
            // beside its new nearest ungrouped neighbour.
            let at = segment.firstIndex(of: entry)!
            finalOrder = try WorkspaceReorderPlanner.transfer(
                workspaces: workspaces, workspaceId: workspaceId, groupId: nil,
                before: at == 0 && segment.count > 1 ? segment[1].id : nil,
                after: at > 0 ? segment[at - 1].id : nil).finalWorkspaceIds
        }
        let byId = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let finalWorkspaces = finalOrder.map { id -> WorkspaceOrderEntry in
            var value = byId[id]!
            if id == workspaceId { value.groupId = nil }
            return value
        }
        return Plan(finalWorkspaces: finalWorkspaces, finalGroups: ordered(groups, by: final), finalRoot: final,
                    changed: final != root || finalWorkspaces != workspaces)
    }

    /// A group's members take its place at the root when it is deleted; members
    /// pinned differently from the group fall where their order puts them.
    static func dissolveGroup(groups: [WorkspaceGroup], workspaces: [WorkspaceOrderEntry], stored: [UUID]?,
                              groupId: UUID) throws -> Plan {
        guard let group = groups.first(where: { $0.id == groupId }) else { throw WorkspaceGroupOperationError.groupNotFound }
        let root = resolve(stored: stored, groups: groups, workspaces: workspaces)
        let members = workspaces.filter { $0.groupId == groupId }.map(\.id)
        let remaining = groups.filter { $0.id != groupId }
        let freed = workspaces.map { entry -> WorkspaceOrderEntry in
            var value = entry
            if value.groupId == groupId { value.groupId = nil }
            return value
        }
        var final = resolve(stored: root.map(\.id), groups: remaining, workspaces: freed)
        let moving = Set(members.filter { id in freed.first { $0.id == id }?.isPinned == group.isPinned })
        if !moving.isEmpty {
            let groupIndex = root.firstIndex { $0.id == groupId }!
            let previous = root[..<groupIndex].last { $0.isPinned == group.isPinned }?.id
            let placed = final.filter { moving.contains($0.id) }
            final.removeAll { moving.contains($0.id) }
            let insertAt = previous.flatMap { id in final.firstIndex { $0.id == id }.map { $0 + 1 } }
                ?? (group.isPinned ? 0 : final.filter(\.isPinned).count)
            final.insert(contentsOf: placed.sorted { a, b in
                members.firstIndex(of: a.id)! < members.firstIndex(of: b.id)!
            }, at: insertAt)
        }
        let finalWorkspaces = ungroupedFollowing(final, in: freed)
        return Plan(finalWorkspaces: finalWorkspaces, finalGroups: ordered(remaining, by: final), finalRoot: final,
                    changed: true)
    }

    /// A reorder of `workspaces` that no root plan made (a notification moving
    /// a workspace to the top, Move to Top, a batch or index move), mirrored
    /// into the root order: the moved workspaces take their new places beside
    /// their new ungrouped neighbours and every other root item keeps its
    /// order. `moved` names them when the caller knows; otherwise they are the
    /// workspaces outside the longest run that kept its relative order. Nil
    /// when the drawn order needs no change.
    static func mirrorFlatReorder(stored: [UUID]?, groups: [WorkspaceGroup], old: [WorkspaceOrderEntry],
                                  new: [WorkspaceOrderEntry], moved hint: Set<UUID>? = nil) -> [WorkspaceRootEntry]? {
        guard stored != nil, Set(old.map(\.id)) == Set(new.map(\.id)) else { return nil }
        let before = resolve(stored: stored, groups: groups, workspaces: old)
        let rootIds = Set(before.lazy.filter { !$0.isGroup }.map(\.id))
        var final = before
        for pinned in [true, false] {
            let oldOrder = old.filter { $0.isPinned == pinned && rootIds.contains($0.id) }.map(\.id)
            let newOrder = new.filter { $0.isPinned == pinned && rootIds.contains($0.id) }.map(\.id)
            guard oldOrder != newOrder else { continue }
            // A hint counts only if everything else really kept its relative order.
            let hinted = hint.map { $0.intersection(newOrder) }.flatMap { named -> Set<UUID>? in
                named.isEmpty || oldOrder.filter { !named.contains($0) } != newOrder.filter { !named.contains($0) }
                    ? nil : named
            }
            let moved = hinted ?? Set(newOrder).subtracting(longestKeptRun(old: oldOrder, new: newOrder))
            let entries = Dictionary(uniqueKeysWithValues: final.map { ($0.id, $0) })
            final.removeAll { moved.contains($0.id) }
            for (index, id) in newOrder.enumerated() where moved.contains(id) {
                let entry = entries[id]!
                if index > 0, let at = final.firstIndex(where: { $0.id == newOrder[index - 1] }) {
                    final.insert(entry, at: at + 1)
                } else if let next = newOrder[(index + 1)...].first(where: { candidate in
                    final.contains { $0.id == candidate } }), let at = final.firstIndex(where: { $0.id == next }) {
                    final.insert(entry, at: at)
                } else {
                    final.insert(entry, at: pinned ? final.filter(\.isPinned).count : final.count)
                }
            }
        }
        return final == before ? nil : final
    }

    /// The longest subsequence of `new` already in `old`'s relative order.
    private static func longestKeptRun(old: [UUID], new: [UUID]) -> Set<UUID> {
        let rank = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($1, $0) })
        let ranks = new.map { rank[$0] ?? 0 }
        var length = [Int](repeating: 1, count: ranks.count)
        var previous = [Int](repeating: -1, count: ranks.count)
        for i in ranks.indices {
            for j in 0..<i where ranks[j] < ranks[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                previous[i] = j
            }
        }
        guard var at = length.indices.max(by: { length[$0] < length[$1] }) else { return [] }
        var kept = Set<UUID>()
        while at >= 0 { kept.insert(new[at]); at = previous[at] }
        return kept
    }

    /// The sidebar item one step up (`delta` < 0) or down from a workspace,
    /// which Move Up/Down places it beside: for a workspace in no group, the
    /// next root item of its pin segment (a group too); for a member, the next
    /// member of its pin inside its group. Nil at an end, or for an unknown id.
    static func stepTarget(workspaceId: UUID, by delta: Int, groups: [WorkspaceGroup],
                           workspaces: [WorkspaceOrderEntry], stored: [UUID]?) -> UUID? {
        guard delta != 0, let entry = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        let groupId = entry.groupId.flatMap { id in groups.contains { $0.id == id } ? id : nil }
        let peers = groupId == nil
            ? resolve(stored: stored, groups: groups, workspaces: workspaces)
                .filter { $0.isPinned == entry.isPinned }.map(\.id)
            : workspaces.filter { $0.groupId == groupId && $0.isPinned == entry.isPinned }.map(\.id)
        guard let source = peers.firstIndex(of: workspaceId), peers.indices.contains(source + delta) else { return nil }
        return peers[source + delta]
    }

    /// `groups` in the order a root order draws them; any it does not name keep their order, last.
    static func ordered(_ groups: [WorkspaceGroup], by root: [WorkspaceRootEntry]) -> [WorkspaceGroup] {
        let position = Dictionary(root.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.enumerated().sorted {
            (position[$0.element.id] ?? Int.max, $0.offset) < (position[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
    }

    /// `workspaces` with each segment's ungrouped workspaces put in `root`'s
    /// order. Grouped workspaces keep their indexes; ungrouped ones swap slots.
    static func ungroupedFollowing(_ root: [WorkspaceRootEntry],
                                   in workspaces: [WorkspaceOrderEntry]) -> [WorkspaceOrderEntry] {
        let rootIds = Set(root.lazy.filter { !$0.isGroup }.map(\.id))
        let byId = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        var queue: [Bool: [WorkspaceOrderEntry]] = [:]
        for entry in root where !entry.isGroup {
            if let value = byId[entry.id] { queue[entry.isPinned, default: []].append(value) }
        }
        var cursor: [Bool: Int] = [:]
        return workspaces.map { entry in
            guard rootIds.contains(entry.id) else { return entry }
            let index = cursor[entry.isPinned, default: 0]
            cursor[entry.isPinned] = index + 1
            return queue[entry.isPinned]?[index] ?? entry
        }
    }

    /// Where a root item goes when its pin flips, or a group when it is
    /// created: a re-pinned item at the boundary between the segments (the end
    /// of pinned, the top of unpinned); a new group right after the last other
    /// group of its segment (else the segment top), as appending did.
    static func placing(_ id: UUID, atPinBoundary: Bool, groups: [WorkspaceGroup],
                        workspaces: [WorkspaceOrderEntry], stored: [UUID]?) -> [WorkspaceRootEntry] {
        var root = resolve(stored: stored, groups: groups, workspaces: workspaces)
        guard let index = root.firstIndex(where: { $0.id == id }) else { return root }
        let entry = root.remove(at: index)
        let pinnedCount = root.filter(\.isPinned).count
        let insertAt: Int
        if atPinBoundary {
            insertAt = pinnedCount
        } else if let last = root.lastIndex(where: { $0.isGroup && $0.isPinned == entry.isPinned }) {
            insertAt = last + 1
        } else {
            insertAt = entry.isPinned ? 0 : pinnedCount
        }
        root.insert(entry, at: insertAt)
        return root
    }

    private static func segmentEnd(_ pinned: Bool, in root: [WorkspaceRootEntry]) -> Int {
        pinned ? root.filter(\.isPinned).count : root.count
    }

    private static func lastInSegment(_ entry: WorkspaceRootEntry, of root: [WorkspaceRootEntry]) -> UUID {
        root.last { $0.isPinned == entry.isPinned && $0.id != entry.id }?.id ?? entry.id
    }

    /// W1 placement over root items: a self target is a no-op, a target in the
    /// other pin segment clamps to the source segment's near end.
    private static func place(_ id: UUID, in root: [WorkspaceRootEntry], before: UUID?, after: UUID?) throws -> [WorkspaceRootEntry] {
        guard let relative = before ?? after else { throw WorkspaceGroupOperationError.invalidParams }
        guard let source = root.first(where: { $0.id == id }) else { throw WorkspaceGroupOperationError.workspaceNotFound }
        if relative == id { return root }
        var remaining = root.filter { $0.id != id }
        guard let index = remaining.firstIndex(where: { $0.id == relative }) else {
            throw WorkspaceGroupOperationError.notRootItem
        }
        let pinnedCount = remaining.filter(\.isPinned).count
        let lower = source.isPinned ? 0 : pinnedCount
        let upper = source.isPinned ? pinnedCount : remaining.count
        remaining.insert(source, at: max(lower, min(index + (after != nil ? 1 : 0), upper)))
        return remaining
    }
}

/// C11H-342: the order Move Up / Move Down read and change. `WorkspaceManager`
/// in the app. `reorderWorkspace(workspaceId:toIndex:)` is the flat reorder;
/// Move Up/Down must step the sidebar instead, and tests hold the two apart.
@MainActor
protocol WorkspaceSidebarStepModel: AnyObject {
    var selectedWorkspaceId: UUID? { get }
    var workspaceOrderEntries: [WorkspaceOrderEntry] { get }
    func canStepWorkspaceInSidebar(_ workspaceId: UUID, by delta: Int) -> Bool
    func stepWorkspaceInSidebar(_ workspaceId: UUID, by delta: Int) -> Bool
    func reorderWorkspace(workspaceId: UUID, toIndex targetIndex: Int) -> Bool
}

/// The command palette's Move Up / Move Down for the selected workspace: the
/// context that enables them and the actions it registers, one sidebar step
/// each (C11H-342). The palette in `ContentView` calls exactly these.
@MainActor
enum WorkspaceSidebarStepPalette {
    static let moveUpCommandId = "palette.moveWorkspaceUp"
    static let moveDownCommandId = "palette.moveWorkspaceDown"
    static let hasAboveKey = "workspace.hasAbove"
    static let hasBelowKey = "workspace.hasBelow"
    static let commands: [(commandId: String, delta: Int)] = [(moveUpCommandId, -1), (moveDownCommandId, 1)]

    /// The palette context's enablement values for the selected workspace.
    static func context(_ model: some WorkspaceSidebarStepModel) -> [String: Bool] {
        guard let id = model.selectedWorkspaceId else { return [hasAboveKey: false, hasBelowKey: false] }
        return [hasAboveKey: model.canStepWorkspaceInSidebar(id, by: -1),
                hasBelowKey: model.canStepWorkspaceInSidebar(id, by: 1)]
    }

    /// A registered action: one sidebar step for the selected workspace. The
    /// workspace it moved, or nil (another command id, no selection, an end).
    @discardableResult
    static func perform(_ commandId: String, on model: some WorkspaceSidebarStepModel) -> UUID? {
        guard let delta = commands.first(where: { $0.commandId == commandId })?.delta,
              let id = model.selectedWorkspaceId, model.stepWorkspaceInSidebar(id, by: delta) else { return nil }
        return id
    }
}

/// Each group's Captain summary for the sidebar headers. Only groups with a
/// declared Captain appear. The captain coordinator sets it when a value changes.
final class WorkspaceGroupCaptainBoard: ObservableObject {
    @Published var summaries: [UUID: WorkspaceCaptainSummary] = [:]
}

/// A group's authored JSON object as saved in the session file, beside (never
/// inside) its `WorkspaceGroup` record, so the record's shape is unchanged.
struct SessionWorkspaceGroupMetadataSnapshot: Codable, Sendable, Equatable {
    var metadataValues: [String: PersistedJSONValue]? = nil
    var metadataSources: [String: PersistedMetadataSource]? = nil
}

/// Save and restore of group objects through the group store. A snapshot with
/// no `workspaceGroupMetadata` (every snapshot before C11H-299) restores every
/// group with an empty object; entries naming no restored group are dropped.
enum WorkspaceGroupMetadataPersistence {
    /// Nil when no group has an object, so the saved shape stays as before.
    static func capture(groups: [WorkspaceGroup], store: WorkspaceMetadataStore = .groups)
        -> [String: SessionWorkspaceGroupMetadataSnapshot]? {
        var saved: [String: SessionWorkspaceGroupMetadataSnapshot] = [:]
        for group in groups {
            let snapshot = store.persistenceSnapshot(workspaceId: group.id)
            guard let values = snapshot.metadataValues, !values.isEmpty else { continue }
            saved[group.id.uuidString] = .init(metadataValues: values, metadataSources: snapshot.metadataSources)
        }
        return saved.isEmpty ? nil : saved
    }

    /// Displaced groups not restored lose their objects; every restored group
    /// is registered and receives exactly its saved object (or none).
    static func restore(groups: [WorkspaceGroup], saved: [String: SessionWorkspaceGroupMetadataSnapshot]?,
                        displaced: [UUID], store: WorkspaceMetadataStore = .groups) {
        let restored = Set(groups.map(\.id))
        for id in displaced where !restored.contains(id) { store.removeWorkspace(workspaceId: id) }
        for group in groups {
            store.register(workspaceId: group.id)
            let entry = saved?[group.id.uuidString]
            do {
                try store.restoreMetadata(workspaceId: group.id, legacy: nil,
                    values: entry?.metadataValues ?? [:], sources: entry?.metadataSources)
            } catch {
                // The store keeps the exact saved fields for the next autosave.
                NSLog("workspace_group.metadata.restore retained group=%@ code=%@", group.id.uuidString,
                      WorkspaceMetadataStore.rejectionCategory(error))
            }
        }
    }
}
