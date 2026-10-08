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
        /// A visible stable-ID target for the actual pin-clamped placement.
        let indicator: Target
        let changed: Bool
    }

    /// Recompute this on performDrop. A hover plan is not a stale-state commit token.
    static func plan(
        windowId: UUID,
        groups: [WorkspaceGroup],
        workspaces: [WorkspaceOrderEntry],
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
            case .ungroupedEdge(let targetId, let edge):
                destination = nil
                if let targetId {
                    guard let member = workspaceById[targetId] else { throw DropError.workspaceNotFound }
                    guard member.groupId == nil else { throw DropError.invalidTarget }
                    if edge == .top { before = targetId } else { after = targetId }
                } else {
                    // The root lane exists even when every workspace is grouped.
                    // No relative target means W1 appends in the source pin segment.
                    let ungrouped = workspaces.filter { $0.id != id && $0.groupId == nil }
                    if edge == .top { before = ungrouped.first?.id }
                    else { after = ungrouped.last?.id }
                }
            case .groupEdge:
                throw DropError.invalidTarget
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
                indicator: workspaceIndicator(id: id, groupId: destination, groups: groupById, workspaces: final),
                changed: order.changed || original.groupId != destination
            )

        case .group(let id, _):
            guard groupById[id] != nil else { throw DropError.groupNotFound }
            guard case .groupEdge(let targetId, let edge) = target else { throw DropError.invalidTarget }
            guard groupById[targetId] != nil else { throw DropError.groupNotFound }
            let before = edge == .top ? targetId : nil
            let after = edge == .bottom ? targetId : nil
            let order = try WorkspaceReorderPlanner.move(
                workspaces: groups.map { WorkspaceOrderEntry(id: $0.id, isPinned: $0.isPinned) },
                workspaceId: id, before: before, after: after
            )
            let final = order.finalWorkspaceIds.map { groupById[$0]! }
            return Plan(
                command: .moveGroup(groupId: id, before: before, after: after),
                finalWorkspaces: workspaces, finalGroups: final,
                indicator: groupIndicator(id: id, groups: final), changed: order.changed
            )
        }
    }

    private static func workspaceIndicator(
        id: UUID, groupId: UUID?, groups: [UUID: WorkspaceGroup], workspaces: [WorkspaceOrderEntry]
    ) -> Target {
        if let groupId, groups[groupId]?.isCollapsed == true { return .groupBody(groupId) }
        let source = workspaces.first { $0.id == id }!
        // Ungrouped pin segments are separated by folder blocks at the root.
        // Inside a folder the two member pin segments are adjacent.
        let members = workspaces.filter {
            $0.groupId == groupId && (groupId != nil || $0.isPinned == source.isPinned)
        }.map(\.id)
        let index = members.firstIndex(of: id)!
        let next = index + 1 < members.count ? members[index + 1] : nil
        let previous = index > 0 ? members[index - 1] : nil
        if let groupId {
            if let next { return .memberEdge(workspaceId: next, edge: .top) }
            if let previous { return .memberEdge(workspaceId: previous, edge: .bottom) }
            return .groupBody(groupId)
        }
        if let next { return .ungroupedEdge(workspaceId: next, edge: .top) }
        if let previous { return .ungroupedEdge(workspaceId: previous, edge: .bottom) }
        return .ungroupedEdge(workspaceId: nil, edge: source.isPinned ? .top : .bottom)
    }

    private static func groupIndicator(id: UUID, groups: [WorkspaceGroup]) -> Target {
        let source = groups.first { $0.id == id }!
        let segment = groups.filter { $0.isPinned == source.isPinned }
        let index = segment.firstIndex { $0.id == id }!
        if index + 1 < segment.count { return .groupEdge(groupId: segment[index + 1].id, edge: .top) }
        if index > 0 { return .groupEdge(groupId: segment[index - 1].id, edge: .bottom) }
        return .groupEdge(groupId: id, edge: .top)
    }
}
