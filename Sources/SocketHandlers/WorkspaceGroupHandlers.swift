import AppKit
import Foundation

extension TerminalController {
    /// Each group's record, with its JSON object and its Captain's presence
    /// (C11H-299). Presence is instance-wide: the holder may be in any window.
    /// Without a caller's projection, panels are walked only when one of this
    /// window's groups declares a Captain (C11H-301).
    func v2WorkspaceGroupRecords(_ manager: WorkspaceManager,
                                 captainProjection: WorkspaceCaptainProjection? = nil) -> [[String: Any]] {
        guard !manager.workspaceGroups.isEmpty else { return [] }
        let groupMetadata = WorkspaceMetadataStore.groups.readSnapshot()
        let projection = captainProjection ?? WorkspaceCaptainProjection.groupPresence(
            groups: manager.workspaceGroups, groupMetadata: groupMetadata,
            holders: { WorkspaceCaptainCoordinator.holders(in: AppDelegate.shared?.fleetWorkspaces() ?? []) })
        return manager.workspaceGroups.map { group in
            let members = manager.workspaces.filter { $0.groupId == group.id }.map { $0.id.uuidString }
            var record: [String: Any] = [
                "id": group.id.uuidString,
                "ref": v2Ref(kind: .workspaceGroup, uuid: group.id),
                "name": group.name,
                "color": v2OrNull(group.color),
                "icon": v2OrNull(group.icon),
                "is_collapsed": group.isCollapsed,
                "is_pinned": group.isPinned,
                "member_workspace_ids": members,
                "member_count": members.count,
                "metadata": groupMetadata.metadata[group.id] ?? [:],
                "metadata_sources": groupMetadata.sources[group.id] ?? [:]
            ]
            record.merge(projection.groupSummary(for: group.id).presenceJSONObject) { _, derived in derived }
            return record
        }
    }

    /// C11H-342: the sidebar's root items in draw order, pinned segment first.
    func v2WorkspaceRootOrder(_ manager: WorkspaceManager) -> [[String: Any]] {
        manager.workspaceRootEntries.map { entry in
            let kind: V2HandleKind = entry.isGroup ? .workspaceGroup : .workspace
            return ["kind": entry.isGroup ? "group" : "workspace", "id": entry.id.uuidString,
                    "ref": v2Ref(kind: kind, uuid: entry.id), "is_pinned": entry.isPinned]
        }
    }

    nonisolated func v2WorkspaceGroupCommand(_ method: String, params: [String: Any]) -> V2CallResult {
        // Parse container types before touching the UI-owned collection. Unlike
        // v2StringArray, malformed elements must never be silently discarded.
        for key in ["workspace_ids", "ordered_workspace_ids"] where params[key] != nil {
            guard let values = params[key] as? [String], !values.isEmpty,
                  values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return .err(code: "invalid_params", message: WorkspaceGroupOperationError.invalidParams.message, data: nil)
            }
        }
        for key in ["window_id", "group_id", "workspace_id", "before_id", "after_id", "name"] where params[key] != nil {
            guard let value = params[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: "invalid_params", message: WorkspaceGroupOperationError.invalidParams.message, data: nil)
            }
        }
        if let dryRun = params["dry_run"], !(dryRun is Bool) {
            return .err(code: "invalid_params", message: WorkspaceGroupOperationError.invalidParams.message, data: nil)
        }

        // Main is required for an exact window-local collection snapshot and
        // synchronous validation/commit. No telemetry, I/O, or await happens here.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { v2WorkspaceGroupCommit(method, params: params) }
        }
        return DispatchQueue.main.sync { self.v2WorkspaceGroupCommit(method, params: params) }
    }

    private func v2WorkspaceGroupCommit(_ method: String, params: [String: Any]) -> V2CallResult {
        // Resolve group refs only; do not walk every terminal/area on a group operation.
        if let app = AppDelegate.shared {
            for window in app.listMainWindowSummaries() {
                _ = v2EnsureHandleRef(kind: .window, uuid: window.windowId)
                guard let manager = app.workspaceManagerFor(windowId: window.windowId) else { continue }
                for group in manager.workspaceGroups { _ = v2EnsureHandleRef(kind: .workspaceGroup, uuid: group.id) }
                for workspace in manager.workspaces { _ = v2EnsureHandleRef(kind: .workspace, uuid: workspace.id) }
            }
        }
        do {
            func invalid() -> WorkspaceGroupOperationError {
                WorkspaceGroupOperationError.invalidParams
            }
            func resolve(_ raw: Any?, kind: V2HandleKind) throws -> UUID {
                guard let value = raw as? String else { throw invalid() }
                let valueTrimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let uuid = UUID(uuidString: valueTrimmed) { return uuid }
                guard valueTrimmed.hasPrefix(kind.rawValue + ":"),
                      let uuid = v2UUIDByRef[kind]?[valueTrimmed] else { throw invalid() }
                return uuid
            }
            let manager: WorkspaceManager
            if let raw = params["window_id"] {
                let windowId = try resolve(raw, kind: .window)
                guard let scoped = AppDelegate.shared?.workspaceManagerFor(windowId: windowId) else {
                    throw WorkspaceGroupOperationError(code: "wrong_window", message: String(localized: "workspaceGroup.error.wrongWindow", defaultValue: "The target does not belong to this window."))
                }
                manager = scoped
            } else {
                guard let current = workspaceManager else { throw invalid() }
                manager = current
            }
            let windowId = AppDelegate.shared?.windowId(for: manager)
            let allManagers = AppDelegate.shared?.listMainWindowSummaries().compactMap {
                AppDelegate.shared?.workspaceManagerFor(windowId: $0.windowId)
            } ?? [manager]
            func groupId(_ raw: Any?) throws -> UUID {
                let id = try resolve(raw, kind: .workspaceGroup)
                guard manager.workspaceGroups.contains(where: { $0.id == id }) else {
                    let elsewhere = allManagers.contains { $0.workspaceGroups.contains { $0.id == id } }
                    throw WorkspaceGroupOperationError(code: elsewhere ? "wrong_window" : "group_not_found", message: WorkspaceGroupOperationError.groupNotFound.message)
                }
                return id
            }
            func workspaceId(_ raw: Any?) throws -> UUID {
                let id = try resolve(raw, kind: .workspace)
                guard manager.workspaces.contains(where: { $0.id == id }) else {
                    let elsewhere = allManagers.contains { $0.workspaces.contains { $0.id == id } }
                    throw WorkspaceGroupOperationError(code: elsewhere ? "wrong_window" : "workspace_not_found", message: WorkspaceGroupOperationError.workspaceNotFound.message)
                }
                return id
            }
            /// C11H-342: a root item, a group or an ungrouped workspace, by ref or UUID.
            func rootItemId(_ raw: Any?) throws -> UUID {
                guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw invalid() }
                let namesGroup = value.hasPrefix(V2HandleKind.workspaceGroup.rawValue + ":")
                    || UUID(uuidString: value).map { uuid in
                        allManagers.contains { $0.workspaceGroups.contains { $0.id == uuid } }
                    } == true
                if namesGroup { return try groupId(value) }
                let id = try workspaceId(value)
                guard manager.workspaces.first(where: { $0.id == id })?.groupId == nil else {
                    throw WorkspaceGroupOperationError.notRootItem
                }
                return id
            }
            /// A member move's before/after: a workspace. A group named there
            /// (a group is never inside a group) is `not_member`, not unknown.
            func memberTargetId(_ raw: Any?) throws -> UUID {
                if let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   value.hasPrefix(V2HandleKind.workspaceGroup.rawValue + ":")
                    || UUID(uuidString: value).map({ uuid in
                        allManagers.contains { $0.workspaceGroups.contains { $0.id == uuid } } }) == true {
                    throw WorkspaceGroupOperationError.notMember
                }
                return try workspaceId(raw)
            }
            if method == "workspace.reorder_batch" {
                guard let raw = params["ordered_workspace_ids"] as? [String], !raw.isEmpty else { throw invalid() }
                let ids = try raw.map { try workspaceId($0) }
                let dryRun = params["dry_run"] as? Bool ?? false
                let plan = try (dryRun ? manager.batchWorkspaceReorderPlan(orderedWorkspaceIds: ids) : manager.applyBatchWorkspaceReorder(orderedWorkspaceIds: ids))
                if !dryRun && plan.changed {
                    EventEmitter.shared.emitWorkspaceReordered(windowId: windowId, workspaceIds: plan.finalWorkspaceIds)
                }
                return .ok([
                    "window_id": v2OrNull(windowId?.uuidString), "dry_run": dryRun,
                    "changed": plan.changed, "final_workspace_ids": plan.finalWorkspaceIds.map(\.uuidString),
                    "moves": plan.moves.map { ["workspace_id": $0.workspaceId.uuidString, "from_index": $0.fromIndex, "to_index": $0.toIndex] as [String: Any] }
                ])
            }
            let verb = String(method.dropFirst("workspace.group.".count))
            var affectedId: UUID?
            var focusedId: UUID?
            switch verb {
            case "list": break
            case "create":
                guard let name = params["name"] as? String else { throw invalid() }
                affectedId = try manager.createWorkspaceGroup(name: name).id
            case "move" where params["workspace_id"] != nil:
                let id = try workspaceId(params["workspace_id"])
                guard let destination = params["to_group_id"] else { throw invalid() }
                let targetGroup = destination is NSNull ? nil : try groupId(destination)
                // At the root, before/after name a group or an ungrouped workspace.
                let relative: (Any?) throws -> UUID = targetGroup == nil ? rootItemId : memberTargetId
                let before = try params["before_id"].map { try relative($0) }
                let after = try params["after_id"].map { try relative($0) }
                guard params["index"] == nil, before == nil || after == nil else { throw invalid() }
                try manager.moveWorkspaceToGroup(workspaceId: id, groupId: targetGroup, before: before, after: after)
                affectedId = targetGroup
            default:
                let id = try groupId(params["group_id"])
                affectedId = id
                switch verb {
                case "rename":
                    guard let name = params["name"] as? String else { throw invalid() }
                    try manager.renameWorkspaceGroup(id: id, name: name)
                case "delete", "ungroup": try manager.deleteWorkspaceGroup(id: id)
                case "collapse", "expand": try manager.setWorkspaceGroupCollapsed(id: id, collapsed: verb == "collapse")
                case "pin", "unpin": try manager.setWorkspaceGroupPinned(id: id, pinned: verb == "pin")
                case "set_color", "set_icon":
                    let key = verb == "set_color" ? "color" : "icon"
                    let clear = params["clear"] as? Bool ?? false
                    let raw = params[key]
                    guard clear || raw != nil else { throw invalid() }
                    guard raw == nil || raw is NSNull || raw is String else { throw invalid() }
                    guard !clear || raw == nil || raw is NSNull else { throw invalid() }
                    let value = clear ? nil : raw as? String
                    if key == "color" { try manager.setWorkspaceGroupColor(id: id, color: value) }
                    else { try manager.setWorkspaceGroupIcon(id: id, icon: value) }
                case "add", "remove":
                    guard let raw = params["workspace_ids"] as? [String], !raw.isEmpty else { throw invalid() }
                    let ids = try raw.map { try workspaceId($0) }
                    if verb == "add" { try manager.addWorkspacesToGroup(id: id, workspaceIds: ids) }
                    else { try manager.removeWorkspacesFromGroup(id: id, workspaceIds: ids) }
                case "move":
                    let before = try params["before_id"].map { try rootItemId($0) }
                    let after = try params["after_id"].map { try rootItemId($0) }
                    let index = params["index"] as? Int
                    guard params["index"] == nil || index != nil,
                          (before == nil ? 0 : 1) + (after == nil ? 0 : 1) + (index == nil ? 0 : 1) == 1 else { throw invalid() }
                    try manager.reorderWorkspaceGroup(id: id, toIndex: index, before: before, after: after)
                case "focus": focusedId = try manager.focusWorkspaceGroup(id: id)
                default: return .err(code: "method_not_found", message: "Unknown method", data: nil)
                }
            }
            let groups = v2WorkspaceGroupRecords(manager)
            var payload: [String: Any] = ["window_id": v2OrNull(windowId?.uuidString), "workspace_groups": groups,
                                          "root_order": v2WorkspaceRootOrder(manager)]
            if let affectedId {
                payload["group_id"] = affectedId.uuidString
                payload["group"] = groups.first { $0["id"] as? String == affectedId.uuidString } ?? ["id": affectedId.uuidString]
            }
            if let focusedId { payload["workspace_id"] = focusedId.uuidString }
            return .ok(payload)
        } catch let error as WorkspaceGroupOperationError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: WorkspaceGroupOperationError.invalidParams.message, data: nil)
        }
    }
}
