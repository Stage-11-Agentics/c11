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
    static func items(groups: [WorkspaceGroup], workspaces: [WorkspaceOrderEntry]) -> [WorkspaceSidebarItem] {
        func segment(pinned: Bool) -> [WorkspaceSidebarItem] {
            let folders: [WorkspaceSidebarItem] = groups.filter { $0.isPinned == pinned }.map { group in
                .group(group, memberWorkspaceIds: workspaces.filter { $0.groupId == group.id }.map(\.id))
            }
            let ungrouped: [WorkspaceSidebarItem] = workspaces.filter {
                $0.groupId == nil && $0.isPinned == pinned
            }.map { .workspace($0.id) }
            return folders + ungrouped
        }
        return segment(pinned: true) + segment(pinned: false)
    }

    /// Old and corrupt snapshots retain their workspaces; first duplicate folder wins.
    static func restoredGroups(_ groups: [WorkspaceGroup]?) -> [WorkspaceGroup] {
        var seen = Set<UUID>()
        let unique = (groups ?? []).filter { seen.insert($0.id).inserted }
        return unique.filter(\.isPinned) + unique.filter { !$0.isPinned }
    }
}
