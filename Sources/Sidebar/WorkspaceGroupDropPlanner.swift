import Foundation

/// A drag preview and commit use the same W1 ordering rules. Inputs are a fresh
/// window-local value snapshot; this type never mutates a manager or a workspace.
enum WorkspaceGroupDropPlanner {
    enum Source: Equatable, Sendable {
        case workspace(id: UUID, windowId: UUID)
        case group(id: UUID, windowId: UUID)
    }

    enum Edge: Equatable, Sendable {
        case top
        case bottom
    }

    enum Target: Equatable, Sendable {
        case groupBody(UUID)
        case memberEdge(workspaceId: UUID, edge: Edge)
        case ungroupedEdge(workspaceId: UUID?, edge: Edge)
        case groupEdge(groupId: UUID, edge: Edge)
    }

    /// With a group, a workspace's `before`/`after` name members of it. At the
    /// root (no group), and for a group, they name a root item (C11H-342).
    enum Command: Equatable, Sendable {
        case moveWorkspace(workspaceId: UUID, groupId: UUID?, before: UUID?, after: UUID?)
        case moveGroup(groupId: UUID, before: UUID?, after: UUID?)
    }

    enum DropError: Error, Equatable, Sendable {
        case wrongWindow
        case invalidSnapshot
        case workspaceNotFound
        case groupNotFound
        case invalidTarget
    }

    struct Plan: Equatable, Sendable {
        let command: Command
        let finalWorkspaces: [WorkspaceOrderEntry]
        let finalGroups: [WorkspaceGroup]
        /// C11H-342: the root order after the drop (groups and ungrouped workspaces).
        let finalRoot: [WorkspaceRootEntry]
        /// A visible stable-ID target for the actual pin-clamped placement.
        let indicator: Target
        let changed: Bool
    }

    /// C11H-207: a window's order with a workspace from another window added
    /// where `WorkspaceManager.attachWorkspace` puts it (ungrouped, at the end
    /// of its pin segment), so a drop from another window plans like a local one.
    static func entries(_ entries: [WorkspaceOrderEntry], attaching foreign: WorkspaceOrderEntry) -> [WorkspaceOrderEntry] {
        var result = entries.filter { $0.id != foreign.id }
        var entry = foreign
        entry.groupId = nil
        result.insert(entry, at: entry.isPinned ? result.filter(\.isPinned).count : result.count)
        return result
    }

    /// C11H-342: a workspace over a group header. The top third drops at the
    /// root before the group; the bottom third of a collapsed or empty group
    /// drops after it; the rest of the header joins the group.
    static func headerTarget(groupId: UUID, locationY: CGFloat, height: CGFloat, showsMembers: Bool) -> Target {
        let y = min(max(locationY, 0), max(height, 0))
        if height > 0, y < height / 3 { return .groupEdge(groupId: groupId, edge: .top) }
        if height > 0, !showsMembers, y > height * 2 / 3 { return .groupEdge(groupId: groupId, edge: .bottom) }
        return .groupBody(groupId)
    }

    /// Recompute this on performDrop. A hover plan is not a stale-state commit token.
    static func plan(
        windowId: UUID,
        groups: [WorkspaceGroup],
        workspaces: [WorkspaceOrderEntry],
        rootOrder: [UUID]? = nil,
        source: Source,
        target: Target
    ) throws -> Plan {
        let sourceWindow: UUID
        switch source {
        case .workspace(_, let window), .group(_, let window): sourceWindow = window
        }
        guard sourceWindow == windowId else { throw DropError.wrongWindow }
        let groupIds = Set(groups.map(\.id))
        guard groupIds.count == groups.count,
              Set(workspaces.map(\.id)).count == workspaces.count,
              workspaces.allSatisfy({ $0.groupId == nil || groupIds.contains($0.groupId!) }) else {
            throw DropError.invalidSnapshot
        }
        let workspaceById = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let groupById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let root = WorkspaceRootOrder.resolve(stored: rootOrder, groups: groups, workspaces: workspaces)

        /// A root placement: before or after a root item, or the top or end of the root lane.
        func rootRelative(excluding id: UUID) throws -> (before: UUID?, after: UUID?) {
            switch target {
            case .ungroupedEdge(let targetId, let edge):
                if let targetId {
                    guard let item = workspaceById[targetId] else { throw DropError.workspaceNotFound }
                    guard item.groupId == nil else { throw DropError.invalidTarget }
                    return edge == .top ? (targetId, nil) : (nil, targetId)
                }
                // The root lane exists even when every workspace is grouped.
                let others = root.filter { $0.id != id }
                return edge == .top ? (others.first?.id, nil) : (nil, others.last?.id)
            case .groupEdge(let targetId, let edge):
                guard groupById[targetId] != nil else { throw DropError.groupNotFound }
                return edge == .top ? (targetId, nil) : (nil, targetId)
            case .groupBody, .memberEdge:
                throw DropError.invalidTarget
            }
        }

        switch source {
        case .workspace(let id, _):
            guard let original = workspaceById[id] else { throw DropError.workspaceNotFound }
            let destination: UUID?
            var before: UUID?
            var after: UUID?
            switch target {
            case .groupBody(let groupId):
                guard groupById[groupId] != nil else { throw DropError.groupNotFound }
                destination = groupId
            case .memberEdge(let targetId, let edge):
                guard let member = workspaceById[targetId] else { throw DropError.workspaceNotFound }
                guard let groupId = member.groupId else { throw DropError.invalidTarget }
                destination = groupId
                if edge == .top { before = targetId } else { after = targetId }
            case .ungroupedEdge, .groupEdge:
                destination = nil
                (before, after) = try rootRelative(excluding: id)
            }
            if destination == nil {
                let plan = try WorkspaceRootOrder.moveWorkspaceToRoot(
                    groups: groups, workspaces: workspaces, stored: rootOrder,
                    workspaceId: id, before: before, after: after)
                return Plan(
                    command: .moveWorkspace(workspaceId: id, groupId: nil, before: before, after: after),
                    finalWorkspaces: plan.finalWorkspaces, finalGroups: groups, finalRoot: plan.finalRoot,
                    indicator: rootIndicator(id: id, root: plan.finalRoot), changed: plan.changed)
            }
            let order = try WorkspaceReorderPlanner.transfer(
                workspaces: workspaces, workspaceId: id, groupId: destination,
                before: before, after: after
            )
            let final = order.finalWorkspaceIds.map { workspaceId -> WorkspaceOrderEntry in
                var entry = workspaceById[workspaceId]!
                if workspaceId == id { entry.groupId = destination }
                return entry
            }
            return Plan(
                command: .moveWorkspace(workspaceId: id, groupId: destination, before: before, after: after),
                finalWorkspaces: final, finalGroups: groups,
                finalRoot: WorkspaceRootOrder.resolve(stored: root.map(\.id), groups: groups, workspaces: final),
                indicator: workspaceIndicator(id: id, groupId: destination!, groups: groupById, workspaces: final),
                changed: order.changed || original.groupId != destination
            )

        case .group(let id, _):
            guard groupById[id] != nil else { throw DropError.groupNotFound }
            var (before, after) = try rootRelative(excluding: id)
            if before == nil && after == nil { before = id }  // Alone at the root: stays.
            let plan = try WorkspaceRootOrder.moveGroup(
                groups: groups, workspaces: workspaces, stored: rootOrder,
                groupId: id, before: before, after: after)
            return Plan(
                command: .moveGroup(groupId: id, before: before, after: after),
                finalWorkspaces: workspaces, finalGroups: plan.finalGroups, finalRoot: plan.finalRoot,
                indicator: rootIndicator(id: id, root: plan.finalRoot), changed: plan.changed
            )
        }
    }

    /// A member's indicator: its next member's top edge, else the previous
    /// member's bottom edge, else the group body. Inside a folder the two
    /// member pin segments are adjacent.
    private static func workspaceIndicator(
        id: UUID, groupId: UUID, groups: [UUID: WorkspaceGroup], workspaces: [WorkspaceOrderEntry]
    ) -> Target {
        if groups[groupId]?.isCollapsed == true { return .groupBody(groupId) }
        let members = workspaces.filter { $0.groupId == groupId }.map(\.id)
        let index = members.firstIndex(of: id)!
        if index + 1 < members.count { return .memberEdge(workspaceId: members[index + 1], edge: .top) }
        if index > 0 { return .memberEdge(workspaceId: members[index - 1], edge: .bottom) }
        return .groupBody(groupId)
    }

    /// A root item's indicator: the top edge of the next root item of its pin
    /// segment, else the bottom edge of the previous one (an expanded group's
    /// is drawn under its last member), else the empty root lane.
    private static func rootIndicator(id: UUID, root: [WorkspaceRootEntry]) -> Target {
        let source = root.first { $0.id == id }!
        let segment = root.filter { $0.isPinned == source.isPinned }
        let index = segment.firstIndex { $0.id == id }!
        func edge(_ entry: WorkspaceRootEntry, _ edge: Edge) -> Target {
            entry.isGroup ? .groupEdge(groupId: entry.id, edge: edge) : .ungroupedEdge(workspaceId: entry.id, edge: edge)
        }
        if index + 1 < segment.count { return edge(segment[index + 1], .top) }
        if index > 0 { return edge(segment[index - 1], .bottom) }
        return source.isGroup ? .groupEdge(groupId: id, edge: .top)
            : .ungroupedEdge(workspaceId: nil, edge: source.isPinned ? .top : .bottom)
    }
}
