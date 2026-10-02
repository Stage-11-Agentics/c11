import Foundation

struct WorkspaceReorderPlan: Equatable, Sendable {
    struct Move: Equatable, Sendable {
        let workspaceId: UUID
        let fromIndex: Int
        let toIndex: Int
    }
    let finalWorkspaceIds: [UUID]
    let changed: Bool
    let moves: [Move]
}

enum WorkspaceReorderPlanner {
    static func batch(workspaces: [WorkspaceOrderEntry], orderedWorkspaceIds: [UUID]) throws -> WorkspaceReorderPlan {
        try validateTargets(orderedWorkspaceIds, workspaces: workspaces)
        let byId = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let requested = orderedWorkspaceIds.compactMap { byId[$0] }
        let requestedIds = Set(orderedWorkspaceIds)
        let remaining = workspaces.filter { !requestedIds.contains($0.id) }
        let final = requested.filter(\.isPinned) + remaining.filter(\.isPinned)
            + requested.filter { !$0.isPinned } + remaining.filter { !$0.isPinned }
        return plan(original: workspaces, final: final, requested: orderedWorkspaceIds)
    }

    /// Target indexes are final indexes. Relative targets are resolved after removing source.
    static func move(workspaces: [WorkspaceOrderEntry], workspaceId: UUID, toIndex: Int? = nil,
                     before: UUID? = nil, after: UUID? = nil) throws -> WorkspaceReorderPlan {
        try validateTargets([workspaceId], workspaces: workspaces)
        guard [toIndex != nil, before != nil, after != nil].filter({ $0 }).count == 1 else {
            throw WorkspaceGroupOperationError.invalidParams
        }
        let source = workspaces.first { $0.id == workspaceId }!
        if before == workspaceId || after == workspaceId {
            return plan(original: workspaces, final: workspaces, requested: [workspaceId])
        }
        var remaining = workspaces.filter { $0.id != workspaceId }
        var target = toIndex ?? remaining.count
        if let relative = before ?? after {
            guard let index = remaining.firstIndex(where: { $0.id == relative }) else {
                throw WorkspaceGroupOperationError.workspaceNotFound
            }
            target = index + (after != nil ? 1 : 0)
        }
        let pinnedCount = remaining.filter(\.isPinned).count
        let lower = source.isPinned ? 0 : pinnedCount
        let upper = source.isPinned ? pinnedCount : remaining.count
        remaining.insert(source, at: max(lower, min(target, upper)))
        return plan(original: workspaces, final: remaining, requested: [workspaceId])
    }

    /// Transfer membership without toggling pin, then place within destination's pin segment.
    static func transfer(workspaces: [WorkspaceOrderEntry], workspaceId: UUID, groupId: UUID?,
                         before: UUID? = nil, after: UUID? = nil) throws -> WorkspaceReorderPlan {
        try validateTargets([workspaceId], workspaces: workspaces)
        guard before == nil || after == nil else { throw WorkspaceGroupOperationError.invalidParams }
        let source = workspaces.first { $0.id == workspaceId }!
        if let relative = before ?? after {
            guard let target = workspaces.first(where: { $0.id == relative }) else {
                throw WorkspaceGroupOperationError.workspaceNotFound
            }
            guard target.groupId == groupId else { throw WorkspaceGroupOperationError.notMember }
            // Clamp relative placement to destination member pin segment, including mixed-pin targets.
            if target.isPinned == source.isPinned {
                return try move(workspaces: workspaces, workspaceId: workspaceId, before: before, after: after)
            }
        }
        let members = workspaces.filter { $0.id != workspaceId && $0.groupId == groupId && $0.isPinned == source.isPinned }
        if let relative = before ?? after,
           let target = workspaces.first(where: { $0.id == relative }),
           target.isPinned && !source.isPinned, let first = members.first {
            return try move(workspaces: workspaces, workspaceId: workspaceId, before: first.id)
        }
        if let last = members.last {
            return try move(workspaces: workspaces, workspaceId: workspaceId, after: last.id)
        }
        // Empty member segment: insert at its global pin boundary.
        let finalIndex = source.isPinned ? workspaces.filter(\.isPinned).count - 1 : workspaces.count - 1
        return try move(workspaces: workspaces, workspaceId: workspaceId, toIndex: finalIndex)
    }

    static func validateTargets(_ ids: [UUID], workspaces: [WorkspaceOrderEntry]) throws {
        guard !ids.isEmpty else { throw WorkspaceGroupOperationError.invalidParams }
        guard Set(ids).count == ids.count else { throw WorkspaceGroupOperationError.duplicateWorkspace }
        let existing = Set(workspaces.map(\.id))
        guard ids.allSatisfy({ existing.contains($0) }) else { throw WorkspaceGroupOperationError.workspaceNotFound }
    }

    private static func plan(original: [WorkspaceOrderEntry], final: [WorkspaceOrderEntry], requested: [UUID]) -> WorkspaceReorderPlan {
        let from = Dictionary(uniqueKeysWithValues: original.enumerated().map { ($1.id, $0) })
        let to = Dictionary(uniqueKeysWithValues: final.enumerated().map { ($1.id, $0) })
        return WorkspaceReorderPlan(finalWorkspaceIds: final.map(\.id), changed: original.map(\.id) != final.map(\.id),
                                    moves: requested.map { .init(workspaceId: $0, fromIndex: from[$0]!, toIndex: to[$0]!) })
    }
}
