import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `workspace.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchWorkspace(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "workspace.group.set_metadata", "workspace.group.get_metadata", "workspace.group.clear_metadata":
            return v2Result(id: id, v2WorkspaceGroupMetadata(method, params: params))
        default: break
        }
        if method.hasPrefix("workspace.group.") || method == "workspace.reorder_batch" {
            return v2Result(id: id, v2WorkspaceGroupCommand(method, params: params))
        }
        switch method {
        case "workspace.list":
            return v2Result(id: id, self.v2WorkspaceList(params: params))
        case "workspace.create":
            return v2Result(id: id, self.v2WorkspaceCreate(params: params))
        case "workspace.select":
            return v2Result(id: id, self.v2WorkspaceSelect(params: params))
        case "workspace.current":
            return v2Result(id: id, self.v2WorkspaceCurrent(params: params))
        case "workspace.close":
            return v2Result(id: id, self.v2RejectUnresolvedTargetRefs(params) ?? self.v2WorkspaceClose(params: params))
        case "workspace.move_to_window":
            return v2Result(id: id, self.v2WorkspaceMoveToWindow(params: params))
        case "workspace.reorder":
            return v2Result(id: id, self.v2WorkspaceReorder(params: params))
        case "workspace.rename":
            return v2Result(id: id, self.v2WorkspaceRename(params: params))
        case "workspace.set_root":
            return v2Result(id: id, self.v2WorkspaceSetRoot(params: params))
        case "workspace.get_root":
            return v2Result(id: id, self.v2WorkspaceGetRoot(params: params))
        case "workspace.action":
            return v2Result(id: id, self.v2RejectUnresolvedTargetRefs(params) ?? self.v2WorkspaceAction(params: params))
        case "workspace.next":
            return v2Result(id: id, self.v2WorkspaceNext(params: params))
        case "workspace.previous":
            return v2Result(id: id, self.v2WorkspacePrevious(params: params))
        case "workspace.last":
            return v2Result(id: id, self.v2WorkspaceLast(params: params))
        case "workspace.remote.configure":
            return v2Result(id: id, self.v2WorkspaceRemoteConfigure(params: params))
        case "workspace.remote.reconnect":
            return v2Result(id: id, self.v2WorkspaceRemoteReconnect(params: params))
        case "workspace.remote.disconnect":
            return v2Result(id: id, self.v2WorkspaceRemoteDisconnect(params: params))
        case "workspace.remote.status":
            return v2Result(id: id, self.v2WorkspaceRemoteStatus(params: params))
        case "workspace.remote.terminal_session_end":
            return v2Result(id: id, self.v2WorkspaceRemoteTerminalSessionEnd(params: params))
        case "workspace.set_metadata", "workspace.get_metadata", "workspace.clear_metadata":
            return v2Result(id: id, self.v2WorkspaceMetadata(method, params: params))
        case "workspace.set_custom_color":
            return v2Result(id: id, self.v2WorkspaceSetCustomColor(params: params))
        case "workspace.apply":
            return v2Result(id: id, self.v2WorkspaceApply(params: params))
        case "workspace.list_blueprints":
            return v2Result(id: id, self.v2WorkspaceListBlueprints(params: params))
        case "workspace.export_blueprint":
            return v2Result(id: id, self.v2WorkspaceExportBlueprint(params: params))
        case "workspace.parse_blueprint":
            return v2Result(id: id, self.v2WorkspaceParseBlueprint(params: params))
        case "workspace.recents.list", "workspace.recents.pin", "workspace.recents.unpin",
             "workspace.recents.remove", "workspace.recents.resolve", "workspace.create_in_directory":
            return v2DispatchWorkspaceRecents(method, id: id, params: params)
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2WorkspaceList(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var workspaces: [[String: Any]] = []
        // C11H-371: a relayed caller lists only its own workspace.
        let relayScope = SocketCommandContext.current?.relayReadScope
        v2MainSync {
            workspaces = workspaceManager.workspaces.enumerated().compactMap { index, ws in
                if let relayScope, ws.id != relayScope.workspace { return nil }
                return [
                    "id": ws.id.uuidString,
                    "ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "index": index,
                    "title": ws.title,
                    "selected": ws.id == workspaceManager.selectedWorkspaceId,
                    "pinned": ws.isPinned,
                    "group_id": v2OrNull(ws.groupId?.uuidString),
                    "listening_ports": ws.listeningPorts,
                    "remote": ws.remoteStatusPayload(),
                    "current_directory": v2OrNull(ws.currentDirectory),
                    "root_directory": v2OrNull(ws.rootDirectory),
                    "custom_color": v2OrNull(ws.customColor)
                ]
            }
        }

        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspaces": workspaces
        ])
    }

    private func v2WorkspaceCreate(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            // C11-576: a named window that is gone is not found, not "unavailable".
            if let window = params["window_id"] as? String {
                return .err(code: "not_found", message: "Window not found: \(window)", data: ["window_id": window])
            }
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var initialInput: String?
        if let error = v2ResolveCreateInitialInput(
            params: params, panelType: "terminal", hasLayout: params.keys.contains("layout"), resolved: &initialInput
        ) {
            return error
        }

        let requestedWorkingDirectory = v2RawString(params, "working_directory")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = (requestedWorkingDirectory?.isEmpty == false) ? requestedWorkingDirectory : nil

        let requestedInitialCommand = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil

        let rawInitialEnv = v2StringMap(params, "initial_env") ?? [:]
        let initialEnv = rawInitialEnv.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = pair.value
        }
        let rawCwd: Any?
        if let workingDirectory {
            rawCwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let str = raw as? String else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            rawCwd = str
        } else {
            rawCwd = nil
        }

        var cwd: String?
        if let err = v2ResolveWorkspaceDirectoryParam(rawCwd, field: "cwd", resolved: &cwd) {
            return err
        }
        let rootWasSpecified = params.keys.contains("root_directory") || rawCwd != nil
        var rootDirectory: String?
        if params.keys.contains("root_directory") {
            if let err = v2ResolveWorkspaceDirectoryParam(
                params["root_directory"],
                field: "root_directory",
                resolved: &rootDirectory
            ) {
                return err
            }
        } else {
            rootDirectory = cwd
        }
        let initialWorkingDirectory = cwd ?? rootDirectory

        // Layout path: let WorkspaceLayoutExecutor own creation so exactly one workspace is created.
        // Pre-creating a workspace here causes a ghost tab on every successful layout apply (B1).
        if let layoutDict = params["layout"] as? [String: Any], !layoutDict.isEmpty {
            let layoutResult = v2WorkspaceApply(params: layoutDict)

            if case .err = layoutResult {
                return layoutResult
            }

            guard case .ok(let resultAny) = layoutResult,
                  let resultDict = resultAny as? [String: Any] else {
                return .err(code: "internal_error", message: "Unexpected apply result", data: nil)
            }

            // Transactional: non-empty failures mean partial apply — roll back the workspace.
            let failures = resultDict["failures"] as? [[String: Any]] ?? []
            if !failures.isEmpty {
                if let refStr = resultDict["workspaceRef"] as? String,
                   let wsUUID = v2ResolveHandleRef(refStr) {
                    v2MainSync {
                        if let ws = workspaceManager.workspaces.first(where: { $0.id == wsUUID }) {
                            workspaceManager.closeWorkspace(ws)
                        }
                    }
                }
                return .err(code: "apply_failed", message: "Layout application partially failed", data: resultDict)
            }

            // Normalize to the standard snake_case workspace creation envelope (B2).
            let workspaceRef = resultDict["workspaceRef"] as? String ?? ""
            let wsUUID = v2ResolveHandleRef(workspaceRef)

            // An explicit --title wins over any title the blueprint set, and is
            // applied via the same customTitle path that workspace.rename uses.
            let layoutTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let appliedLayoutTitle = (layoutTitle?.isEmpty == false) ? layoutTitle : nil
            if let appliedLayoutTitle, let wsUUID {
                v2MainSync {
                    if workspaceManager.workspaces.contains(where: { $0.id == wsUUID }) {
                        workspaceManager.setCustomTitle(workspaceId: wsUUID, title: appliedLayoutTitle)
                    }
                }
            }
            if rootWasSpecified, let wsUUID {
                v2MainSync {
                    workspaceManager.workspaces.first(where: { $0.id == wsUUID })?
                        .setRootDirectory(rootDirectory)
                }
            }

            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
            return .ok([
                "workspace_id": v2OrNull(wsUUID?.uuidString),
                "workspace_ref": workspaceRef as Any,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "title": v2OrNull(appliedLayoutTitle),
                "root_directory": v2OrNull(rootDirectory),
                "layout_result": resultAny
            ])
        }

        // Optional title: set the same customTitle field that workspace.rename writes,
        // so `new-workspace --title` is atomic with creation (no follow-up rename).
        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = (requestedTitle?.isEmpty == false) ? requestedTitle : nil

        // No layout: create workspace normally.
        var newId: UUID?
        let shouldFocus = v2FocusAllowed()
        guard v2MainSyncWithDeadline({
            let ws = PanelLineage.shared.withCreator(self.v2UUID(params, "caller_panel_id")) {
                workspaceManager.addWorkspace(
                    workingDirectory: initialWorkingDirectory,
                    rootDirectory: rootDirectory,
                    establishRootFromWorkingDirectory: false,
                    initialTerminalCommand: initialCommand,
                    initialTerminalInput: initialInput,
                    initialTerminalEnvironment: initialEnv,
                    select: shouldFocus,
                    eagerLoadTerminal: !shouldFocus
                )
            }
            newId = ws.id
            if let customTitle {
                workspaceManager.setCustomTitle(workspaceId: ws.id, title: customTitle)
            }
            return
        }) != nil else {
            return .err(code: "main_thread_timeout", message: "main thread did not respond within deadline", data: nil)
        }

        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }

        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        var ok: [String: Any] = [
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
            "title": v2OrNull(customTitle),
            "root_directory": v2OrNull(rootDirectory)
        ]
        if initialInput != nil { ok["initial_input"] = "queued" }
        return .ok(ok)
    }

    private func v2WorkspaceSelect(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        var success = false
        v2MainSync {
            if let ws = workspaceManager.workspaces.first(where: { $0.id == wsId }) {
                workspaceManager.selectWorkspace(ws)
                success = true
            }
        }

        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        return success
            ? .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
            : .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
    }

    private func v2WorkspaceCurrent(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var wsId: UUID?
        var wsPayload: [String: Any]?
        // C11H-371: through the relay the current workspace is the caller's,
        // never the operator's selection.
        let relayScope = SocketCommandContext.current?.relayReadScope
        v2MainSync {
            wsId = relayScope.map { scope in
                workspaceManager.workspaces.contains { $0.id == scope.workspace } ? scope.workspace : nil
            } ?? workspaceManager.selectedWorkspaceId
            if let wsId, let workspace = workspaceManager.workspaces.first(where: { $0.id == wsId }) {
                wsPayload = [
                    "id": workspace.id.uuidString,
                    "ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "title": workspace.title,
                    "selected": workspace.id == workspaceManager.selectedWorkspaceId,
                    "pinned": workspace.isPinned,
                    "listening_ports": workspace.listeningPorts,
                    "remote": workspace.remoteStatusPayload(),
                    "root_directory": v2OrNull(workspace.rootDirectory),
                ]
            }
        }
        guard let wsId else {
            return .err(code: "not_found", message: "No workspace selected", data: nil)
        }
        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": wsId.uuidString,
            "previous_workspace_id": v2OrNull(relayScope == nil ? workspaceManager.previousWorkspaceId?.uuidString : nil),
            "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
            "workspace": wsPayload ?? NSNull()
        ])
    }

    private func v2WorkspaceClose(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        var found = false
        var endingPanelIds: [UUID] = []
        v2MainSync {
            if let ws = workspaceManager.workspaces.first(where: { $0.id == wsId }) {
                // C11H-24: the hc panels whose sessions this close ends.
                if HCSessionEnd.coordinator != nil {
                    endingPanelIds = ws.panels.keys.filter { ws.closeHoldsHCSession(panelIds: [$0]) }
                }
                workspaceManager.closeWorkspace(ws)
                // closeWorkspace keeps a window's last workspace; nothing ended.
                if workspaceManager.workspaces.contains(where: { $0.id == wsId }) { endingPanelIds = [] }
                found = true
            }
        }

        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        return found
            ? .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                "session_end_panel_ids": endingPanelIds.map(\.uuidString).sorted()
            ])
            : .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
    }

    private func v2WorkspaceMoveToWindow(params: [String: Any]) -> V2CallResult {
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move workspace", data: nil)
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.workspaceManagerFor(workspaceId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard let dstTM = AppDelegate.shared?.workspaceManagerFor(windowId: windowId) else {
                result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowId.uuidString])
                return
            }
            guard let ws = srcTM.detachWorkspace(workspaceId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }

            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveWorkspaceManager(dstTM)
            }
            result = .ok([
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    private func v2WorkspaceReorder(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        let index = v2Int(params, "index")
        let beforeId = v2UUID(params, "before_workspace_id")
        let afterId = v2UUID(params, "after_workspace_id")

        let targetCount = (index != nil ? 1 : 0) + (beforeId != nil ? 1 : 0) + (afterId != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(
                code: "invalid_params",
                message: "Specify exactly one target: index, before_workspace_id, or after_workspace_id",
                data: nil
            )
        }

        var moved = false
        var newIndex: Int?
        v2MainSync {
            if let index {
                moved = workspaceManager.reorderWorkspace(workspaceId: workspaceId, toIndex: index)
            } else {
                moved = workspaceManager.reorderWorkspace(workspaceId: workspaceId, before: beforeId, after: afterId)
            }
            newIndex = workspaceManager.workspaces.firstIndex(where: { $0.id == workspaceId })
        }

        guard moved else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }

        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "index": v2OrNull(newIndex)
        ])
    }

    private func v2WorkspaceSetCustomColor(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        // Accept either a hex string to set, or `clear: true` to reset.
        let clear = (params["clear"] as? Bool) ?? false
        let hex = params["hex"] as? String

        if !clear && hex == nil {
            return .err(code: "invalid_params", message: "Provide either 'hex' or 'clear=true'", data: nil)
        }
        // Resolve off-main: a value that is neither #RRGGBB nor a palette name
        // is an error, never a silent clear.
        if !clear, let hex, WorkspaceColorSettings.resolvedColorHex(hex) == nil {
            return .err(
                code: "invalid_params",
                message: "Invalid color (use #RRGGBB or a palette name: \(WorkspaceColorSettings.paletteNameList()))",
                data: ["hex": hex]
            )
        }

        var applied: String? = nil
        var found = false
        v2MainSync {
            guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else { return }
            found = true
            if clear {
                workspace.setCustomColor(nil)
                applied = nil
            } else if let hex {
                workspace.setCustomColor(hex)
                applied = workspace.customColor
            }
        }

        guard found else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "hex": v2OrNull(applied),
            "cleared": clear
        ])
    }

    private func v2WorkspaceRename(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let titleRaw = v2String(params, "title"),
              !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        }

        let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        var renamed = false
        v2MainSync {
            guard workspaceManager.workspaces.contains(where: { $0.id == workspaceId }) else { return }
            workspaceManager.setCustomTitle(workspaceId: workspaceId, title: title)
            renamed = true
        }

        guard renamed else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "title": title
        ])
    }

    private func v2WorkspaceSetRoot(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard params.keys.contains("root_directory") else {
            return .err(code: "invalid_params", message: "Missing root_directory", data: nil)
        }

        var rootDirectory: String?
        if let err = v2ResolveWorkspaceDirectoryParam(
            params["root_directory"],
            field: "root_directory",
            resolved: &rootDirectory
        ) {
            return err
        }

        var updated = false
        v2MainSync {
            guard let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else { return }
            workspace.setRootDirectory(rootDirectory)
            updated = true
        }
        guard updated else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "root_directory": v2OrNull(rootDirectory)
        ])
    }

    /// Read pair for `workspace.set_root` (C11-238). `current_directory` is the
    /// focused surface's cwd, so a caller can see drift from the root;
    /// `root_exists` is false when the root was deleted (new surfaces then fall
    /// back to the focused surface's cwd); `root_adoption_armed` is true while a
    /// rootless workspace is still waiting to adopt its first shell cwd.
    private func v2WorkspaceGetRoot(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        // Main only for the model snapshot (Workspace is main-actor state); the
        // existence stat runs off-main after it.
        var payload: [String: Any]?
        var rootDirectory: String?
        v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else { return }
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
            rootDirectory = workspace.rootDirectory
            payload = [
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "root_directory": v2OrNull(workspace.rootDirectory),
                "root_adoption_armed": workspace.rootAdoptionArmed,
                "current_directory": v2OrNull(workspace.currentDirectory)
            ]
        }
        guard var payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        payload["root_exists"] = Workspace.usableRootDirectory(rootDirectory) != nil
        return .ok(payload)
    }

    private func v2ResolveWorkspaceDirectoryParam(
        _ raw: Any?,
        field: String,
        resolved: inout String?
    ) -> V2CallResult? {
        resolved = nil
        if raw is NSNull { return nil }
        switch CwdParamResolution.resolve(raw) {
        case .inherit:
            return nil
        case .path(let path):
            resolved = path
            return nil
        case .invalid(let code, let message, let path):
            let fieldMessage = field == "cwd"
                ? message
                : message.replacingOccurrences(of: "cwd", with: field)
            return .err(
                code: code,
                message: fieldMessage,
                data: path.map { ["path": $0] }
            )
        }
    }

    private func v2WorkspaceNext(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard workspaceManager.selectedWorkspaceId != nil else { return }
            workspaceManager.selectNextWorkspace()
            guard let workspaceId = workspaceManager.selectedWorkspaceId else { return }
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    private func v2WorkspacePrevious(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard workspaceManager.selectedWorkspaceId != nil else { return }
            workspaceManager.selectPreviousWorkspace()
            guard let workspaceId = workspaceManager.selectedWorkspaceId else { return }
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    private func v2WorkspaceLast(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No previous workspace in history", data: nil)
        v2MainSync {
            guard let before = workspaceManager.selectedWorkspaceId else { return }
            workspaceManager.navigateBack()
            guard let after = workspaceManager.selectedWorkspaceId, after != before else { return }
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
            result = .ok([
                "workspace_id": after.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: after),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    private func v2WorkspaceRemoteConfigure(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackWorkspaceManager = v2ResolveWorkspaceManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackWorkspaceManager?.selectedWorkspaceId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        guard let destination = v2String(params, "destination") else {
            return .err(code: "invalid_params", message: "Missing destination", data: nil)
        }

        var sshPort: Int?
        if v2HasNonNullParam(params, "port") {
            guard let parsedPort = v2StrictInt(params, "port"),
                  parsedPort > 0,
                  parsedPort <= 65535 else {
                return .err(code: "invalid_params", message: "port must be 1-65535", data: nil)
            }
            sshPort = parsedPort
        }

        // Internal deterministic test hook: pin the local proxy listener port to force bind conflicts.
        var localProxyPort: Int?
        if v2HasNonNullParam(params, "local_proxy_port") {
            guard let parsedLocalProxyPort = v2StrictInt(params, "local_proxy_port"),
                  parsedLocalProxyPort > 0,
                  parsedLocalProxyPort <= 65535 else {
                return .err(code: "invalid_params", message: "local_proxy_port must be 1-65535", data: nil)
            }
            localProxyPort = parsedLocalProxyPort
        }

        let identityFile = v2RawString(params, "identity_file")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sshOptions = v2StringArray(params, "ssh_options") ?? []
        let autoConnect = v2Bool(params, "auto_connect") ?? true
        var relayPort: Int?
        if v2HasNonNullParam(params, "relay_port") {
            guard let parsedRelayPort = v2StrictInt(params, "relay_port"),
                  parsedRelayPort > 0,
                  parsedRelayPort <= 65535 else {
                return .err(code: "invalid_params", message: "relay_port must be 1-65535", data: nil)
            }
            relayPort = parsedRelayPort
        }
        // relay_port remains an opaque terminal-session identifier for older clients.
        // Credentials and local socket paths no longer enable a command relay.
        let terminalStartupCommand = v2RawString(params, "terminal_startup_command")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

#if DEBUG
        dlog(
            "workspace.remote.configure.request workspace=\(workspaceId.uuidString.prefix(8)) " +
            "target=\(destination) port=\(sshPort.map(String.init) ?? "nil") " +
            "autoConnect=\(autoConnect ? 1 : 0) relayPort=\(relayPort.map(String.init) ?? "nil") " +
            "sshOptions=\(sshOptions.joined(separator: "|"))"
        )
#endif
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because Workspace.configureRemoteConnection mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                  let workspace = owner.workspaces.first(where: { $0.id == workspaceId }) else {
                return
            }

            let config = WorkspaceRemoteConfiguration(
                destination: destination,
                port: sshPort,
                identityFile: identityFile?.isEmpty == true ? nil : identityFile,
                sshOptions: sshOptions,
                localProxyPort: localProxyPort,
                relayPort: relayPort,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: terminalStartupCommand?.isEmpty == true ? nil : terminalStartupCommand
            )
            workspace.configureRemoteConnection(config, autoConnect: autoConnect)

            let windowId = v2ResolveWindowId(workspaceManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    private func v2WorkspaceRemoteDisconnect(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackWorkspaceManager = v2ResolveWorkspaceManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackWorkspaceManager?.selectedWorkspaceId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        let clearConfiguration = v2Bool(params, "clear") ?? false
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because disconnect mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                  let workspace = owner.workspaces.first(where: { $0.id == workspaceId }) else {
                return
            }

            workspace.disconnectRemoteConnection(clearConfiguration: clearConfiguration)
            let windowId = v2ResolveWindowId(workspaceManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    private func v2WorkspaceRemoteReconnect(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackWorkspaceManager = v2ResolveWorkspaceManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackWorkspaceManager?.selectedWorkspaceId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because reconnect mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                  let workspace = owner.workspaces.first(where: { $0.id == workspaceId }) else {
                return
            }

            guard workspace.remoteConfiguration != nil else {
                result = .err(code: "invalid_state", message: "Remote workspace is not configured", data: [
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                ])
                return
            }

            workspace.reconnectRemoteConnection()
            let windowId = v2ResolveWindowId(workspaceManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    private func v2WorkspaceRemoteStatus(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let fallbackWorkspaceManager = v2ResolveWorkspaceManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackWorkspaceManager?.selectedWorkspaceId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because Workspace.remoteStatusPayload reads TabManager/UI-owned state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                  let workspace = owner.workspaces.first(where: { $0.id == workspaceId }) else {
                return
            }
            let windowId = v2ResolveWindowId(workspaceManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    private func v2WorkspaceRemoteTerminalSessionEnd(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid panel_id", data: nil)
        }
        guard let relayPort = v2StrictInt(params, "relay_port"),
              relayPort > 0,
              relayPort <= 65535 else {
            return .err(code: "invalid_params", message: "Missing or invalid relay_port", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "relay_port": relayPort,
        ])

        v2MainSync {
            guard let owner = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                  let workspace = owner.workspaces.first(where: { $0.id == workspaceId }) else {
                return
            }
            workspace.markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: relayPort)
            let windowId = v2ResolveWindowId(workspaceManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "relay_port": relayPort,
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    /// CMUX-37 Phase 0: `workspace.apply` v2 handler. Decodes a
    /// `WorkspaceApplyPlan` from params, runs it through
    /// `WorkspaceLayoutExecutor` on the main actor, and returns the
    /// `ApplyResult` as a JSON object. The debug/test surface for the
    /// Phase 0 primitive — Blueprints (Phase 2) and Snapshots (Phase 1)
    /// layer on top of the same executor.
    private func v2WorkspaceApply(params: [String: Any]) -> V2CallResult {
        // Decode the plan and (optional) options off-main. Validation
        // failures never touch the main actor.
        guard let planRaw = params["plan"] else {
            return .err(code: "invalid_params", message: "Missing 'plan'", data: nil)
        }
        let plan: WorkspaceApplyPlan
        do {
            let planData = try JSONSerialization.data(withJSONObject: planRaw, options: [])
            plan = try WorkspaceBlueprintStore.decodeJSONPlan(planData)
        } catch {
            return .err(
                code: "invalid_params",
                message: "Failed to decode WorkspaceApplyPlan: \(error)",
                data: nil
            )
        }

        let options: ApplyOptions
        if let optionsRaw = params["options"] {
            do {
                let optionsData = try JSONSerialization.data(withJSONObject: optionsRaw, options: [])
                options = try JSONDecoder().decode(ApplyOptions.self, from: optionsData)
            } catch {
                return .err(
                    code: "invalid_params",
                    message: "Failed to decode ApplyOptions: \(error)",
                    data: nil
                )
            }
        } else {
            options = ApplyOptions()
        }

        // Pre-validate off-main. Per review cycle 1 I3, the v2 handler
        // must not ride MainActor for pure validation — this block runs
        // entirely on the socket worker thread. A malformed plan returns
        // a typed `invalid_params` error (JSON-RPC clients parse as
        // failure), not an `ok` envelope with an ApplyFailure body —
        // cycle 2 IM2 fix.
        if let validationFailure = WorkspaceLayoutExecutor.validate(plan: plan) {
            let data: [String: Any] = [
                "failure": [
                    "code": validationFailure.code,
                    "step": validationFailure.step,
                    "message": validationFailure.message
                ]
            ]
            return .err(
                code: "invalid_params",
                message: "WorkspaceApplyPlan validation failed: \(validationFailure.message)",
                data: data
            )
        }

        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        // Apply the socket focus policy (CLAUDE.md: "Socket/CLI commands
        // must not steal macOS app focus"). workspace.apply is not in
        // `focusIntentV2Methods`, so `v2FocusAllowed` returns false for
        // this command regardless of caller intent. Zero out
        // `options.select` before dispatch so the executor does not
        // raise the window / select the created workspace. Cycle 2 IM1
        // fix.
        var effectiveOptions = options
        if options.select && !v2FocusAllowed(requested: true) {
            effectiveOptions.select = false
        }

        var result: ApplyResult?
        v2MainSync {
            let deps = WorkspaceLayoutExecutorDependencies(
                workspaceManager: workspaceManager,
                workspaceRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .workspace, uuid: uuid) ?? "workspace:\(uuid.uuidString)"
                },
                surfaceRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .surface, uuid: uuid) ?? "panel:\(uuid.uuidString)"
                },
                paneRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .pane, uuid: uuid) ?? "area:\(uuid.uuidString)"
                }
            )
            result = WorkspaceLayoutExecutor.apply(plan, options: effectiveOptions, dependencies: deps)
        }

        guard let applyResult = result else {
            return .err(code: "internal_error", message: "Executor returned no result", data: nil)
        }

        // Encode ApplyResult back to [String: Any] for the v2 JSON envelope.
        do {
            let encoded = try JSONEncoder().encode(applyResult)
            let asAny = try JSONSerialization.jsonObject(with: encoded, options: [])
            return .ok(asAny)
        } catch {
            return .err(
                code: "internal_error",
                message: "Failed to encode ApplyResult: \(error)",
                data: nil
            )
        }
    }

    /// `workspace.list_blueprints`: returns a merged index of all discovered
    /// blueprint files. Optional `cwd` param enables per-repo discovery.
    /// Returns `{blueprints: [...WorkspaceBlueprintIndex...], starter_aliases: {...}}`.
    private func v2WorkspaceListBlueprints(params: [String: Any]) -> V2CallResult {
        let cwdURL: URL?
        if let cwdStr = params["cwd"] as? String, !cwdStr.isEmpty {
            cwdURL = URL(fileURLWithPath: cwdStr)
        } else {
            cwdURL = nil
        }
        let store = WorkspaceBlueprintStore()
        let entries = store.merged(cwd: cwdURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let encoded = try encoder.encode(entries)
            let asAny = try JSONSerialization.jsonObject(with: encoded, options: [])
            return .ok(["blueprints": asAny, "starter_aliases": WorkspaceBlueprintStore.starterLayoutFiles])
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }

    /// `workspace.export_blueprint`: captures the live workspace as a
    /// `WorkspaceBlueprintFile` and writes it to the user blueprint directory
    /// under `~/.config/c11/blueprints/<sanitized-name>.<ext>` (default
    /// extension `.md`; `.json` selectable via the `format` param).
    /// Required param: `name`. Optional: `workspace_id`, `description`,
    /// `force` (bool), `format` (`"md"` default | `"json"`).
    /// Returns `{path: "...", name: "...", format: "md|json"}`.
    private func v2WorkspaceExportBlueprint(params: [String: Any]) -> V2CallResult {
        guard let name = params["name"] as? String, !name.isEmpty else {
            return .err(code: "invalid_params", message: "Missing or empty 'name'", data: nil)
        }
        guard !WorkspaceBlueprintStore().isReservedLayoutReference(name) else {
            return .err(code: "invalid_params", message: "Blueprint name '\(name)' is reserved for starter layouts or saved references", data: nil)
        }
        guard !WorkspaceBlueprintStore.looksLikeLayoutPath(name) else {
            return .err(code: "invalid_params", message: "Blueprint name '\(name)' must not look like a file path", data: nil)
        }
        let description = params["description"] as? String
        let force = params["force"] as? Bool ?? false
        let formatRaw = (params["format"] as? String)?.lowercased() ?? "md"
        let formatExt: String
        switch formatRaw {
        case "md", "markdown": formatExt = "md"
        case "json":           formatExt = "json"
        default:
            return .err(
                code: "invalid_params",
                message: "Unsupported format '\(formatRaw)'. Expected 'md' or 'json'.",
                data: nil
            )
        }

        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var blueprintFile: WorkspaceBlueprintFile?
        v2MainSync {
            let exporter = WorkspaceBlueprintExporter(workspaceManager: workspaceManager)
            guard let workspace = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else { return }
            blueprintFile = exporter.export(workspaceId: workspace.id, name: name, description: description)
        }

        guard let file = blueprintFile else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }

        // Sanitize name to a filesystem-safe filename.
        let sanitized = String(name
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        let filename = sanitized.isEmpty ? "blueprint" : sanitized

        let fm = FileManager.default
        let dir = WorkspaceBlueprintStore.userBlueprintDirectory(
            home: fm.homeDirectoryForCurrentUser
        )
        let url = dir.appendingPathComponent("\(filename).\(formatExt)")

        if !force && fm.fileExists(atPath: url.path) {
            return .err(
                code: "BLUEPRINT_ALREADY_EXISTS",
                message: "A blueprint named '\(name)' already exists at \(url.path). Use --force to overwrite.",
                data: nil
            )
        }

        let store = WorkspaceBlueprintStore()
        do {
            try store.write(file, to: url)
        } catch let err as WorkspaceBlueprintStore.StoreError {
            return .err(code: err.code, message: "\(err)", data: nil)
        } catch {
            return .err(code: "export_failed", message: "\(error)", data: nil)
        }

        return .ok(["path": url.path, "name": name, "format": formatExt])
    }

    /// `workspace.parse_blueprint`: pure parser for a markdown or JSON
    /// blueprint envelope passed by content. Required params: `content`
    /// (string), `format` (`"md"` or `"json"`). Returns the decoded
    /// envelope as `{name, description, plan}` so the CLI can forward
    /// `plan` to `workspace.apply` without bringing the parser into the
    /// CLI binary's link surface.
    ///
    /// File reads happen in the CLI process (caller's real FS
    /// permissions); the socket only sees content already in memory. No
    /// disk access here, no path resolution — keeps this immune to the
    /// arbitrary-file-read class of attacks `snapshot.restore` already
    /// guards against.
    private func v2WorkspaceParseBlueprint(params: [String: Any]) -> V2CallResult {
        guard let content = params["content"] as? String else {
            return .err(code: "invalid_params", message: "Missing 'content'", data: nil)
        }
        let formatRaw = ((params["format"] as? String) ?? "md").lowercased()
        let limit: Int
        switch formatRaw {
        case "md", "markdown":
            limit = WorkspaceBlueprintStore.maximumMarkdownBlueprintBytes
        case "json":
            limit = WorkspaceBlueprintStore.maximumJSONBlueprintBytes
        default:
            return .err(
                code: "invalid_params",
                message: "Unsupported format '\(formatRaw)'. Expected 'md' or 'json'.",
                data: nil
            )
        }
        guard content.utf8.count <= limit else {
            return .err(
                code: "invalid_params",
                message: "Blueprint content exceeds the \(limit)-byte limit",
                data: nil
            )
        }
        guard let data = content.data(using: .utf8) else {
            return .err(code: "invalid_params", message: "Content is not valid UTF-8", data: nil)
        }
        let file: WorkspaceBlueprintFile
        do {
            if formatRaw == "json" {
                file = try WorkspaceBlueprintStore.decodeJSONBlueprint(data)
            } else {
                file = try WorkspaceBlueprintMarkdown.parse(data)
            }
        } catch {
            return .err(code: "blueprint_decode_failed", message: "\(error)", data: nil)
        }
        do {
            let encoded = try JSONEncoder().encode(file)
            guard let asAny = try JSONSerialization.jsonObject(with: encoded, options: []) as? [String: Any],
                  let plan = asAny["plan"] else {
                return .err(code: "internal_error", message: "Failed to materialize parsed blueprint", data: nil)
            }
            var payload: [String: Any] = [
                "plan": plan,
                "name": file.name
            ]
            if let desc = file.description {
                payload["description"] = desc
            }
            return .ok(payload)
        } catch {
            return .err(code: "internal_error", message: "Failed to encode parsed blueprint: \(error)", data: nil)
        }
    }

    /// JSON validation, precedence and persistence run on the socket worker.
    /// Only live topology/ref capture touches main, with a cancellable deadline.
    nonisolated func v2WorkspaceMetadata(_ method: String, params: [String: Any], timeout: TimeInterval = 5) -> V2CallResult {
        v2ScopedMetadata(method, params: params, scope: .workspace, timeout: timeout)
    }

    /// C11H-299: the same object, commands and rules for a workspace group
    /// (`workspace.group.set_metadata` / `.get_metadata` / `.clear_metadata`).
    /// The group is found in whichever window holds it; groups are window-local.
    nonisolated func v2WorkspaceGroupMetadata(_ method: String, params: [String: Any], timeout: TimeInterval = 5) -> V2CallResult {
        v2ScopedMetadata(method, params: params, scope: .workspaceGroup, timeout: timeout)
    }

    nonisolated private func v2ScopedMetadata(_ method: String, params: [String: Any],
                                               scope: WorkspaceMetadataStore.Scope, timeout: TimeInterval) -> V2CallResult {
        let grouped = scope == .workspaceGroup
        let notFound: V2CallResult = grouped
            ? .err(code: "group_not_found", message: WorkspaceGroupOperationError.groupNotFound.message, data: nil)
            : .err(code: "not_found", message: "Workspace not found", data: nil)
        if grouped {
            guard let raw = params["group_id"] as? String,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .err(code: SocketPanelRefValidator.missingRefCode, message: "group_id is required", data: nil)
            }
        } else {
            if let rejection = SocketPanelRefValidator.rejection(
                params: params, targetKeys: ["workspace_id"], requiredAnyOf: ["workspace_id"]
            ) {
                return .err(code: rejection.code, message: rejection.message, data: nil)
            }
            guard params["workspace_id"] is String else { return notFound }
        }
        let reading = method.hasSuffix(".get_metadata")
        // C11H-360: a write relayed from a linked machine never sets or clears
        // c11's own keys (the Captain route, the Recovered mark), and never
        // replaces or clears the whole object. Only the relay executor sets
        // `relayMachine`; the check runs before any lookup or store write.
        if !reading, SocketCommandContext.current?.relayMachine != nil,
           let refusal = C11RelayPolicy.workspaceWriteRefusal(params, method: method) {
            return .err(code: refusal.code, message: refusal.message, data: nil)
        }
        var mode = PanelMetadataStore.WriteMode.merge
        var source = MetadataSource.explicit
        var partial: [String: Any] = [:]
        var keys: [String]?
        var legacyClear = false
        do {
            if let rawKeys = params["keys"], !(rawKeys is NSNull) {
                guard let parsed = rawKeys as? [String] else { throw PanelMetadataStore.WriteError.invalidKeysParam }
                keys = parsed
            } else if let rawKey = params["key"] {
                guard let key = rawKey as? String else { throw PanelMetadataStore.WriteError.invalidKeysParam }
                keys = [key]
            }
            for key in keys ?? [] { try WorkspaceMetadataValidator.validateKey(key) }
            if !reading {
                if let raw = params["source"] {
                    guard let text = raw as? String, let parsed = MetadataSource(rawValue: text.lowercased()) else {
                        throw PanelMetadataStore.WriteError.invalidSource(String(localized: "workspace.metadata.invalidSource", defaultValue: "expected explicit, declare, osc or heuristic"))
                    }
                    source = parsed
                }
                if let rejection = SocketMetadataSourceValidator.externalRejectionMessage(for: source) {
                    return .err(code: rejection.code, message: rejection.message, data: nil)
                }
            }
            if method.hasSuffix(".set_metadata") {
                if let raw = params["mode"] {
                    guard let text = raw as? String, let parsed = PanelMetadataStore.WriteMode(rawValue: text.lowercased()) else {
                        throw PanelMetadataStore.WriteError.invalidMode(String(localized: "workspace.metadata.invalidMode", defaultValue: "expected merge or replace"))
                    }
                    mode = parsed
                }
                if let raw = params["metadata"] {
                    guard let object = raw as? [String: Any] else {
                        throw PanelMetadataStore.WriteError.invalidJSON(String(localized: "workspace.metadata.invalidObject", defaultValue: "metadata must be a JSON object"))
                    }
                    partial = object
                } else if let key = params["key"] as? String, let value = params["value"] {
                    // Legacy key/value null deletes. Object null remains JSON.
                    legacyClear = value is NSNull
                    if !legacyClear { partial[key] = value }
                } else {
                    return .err(code: "invalid_params", message: "Provide 'metadata' object or 'key'/'value' pair", data: nil)
                }
                if mode == .replace && source != .explicit { throw PanelMetadataStore.WriteError.replaceRequiresExplicit }
                for (key, value) in partial {
                    partial[key] = try WorkspaceMetadataValidator.normalizedValue(key: key, value: value)
                }
                guard JSONSerialization.isValidJSONObject(partial) else {
                    throw PanelMetadataStore.WriteError.invalidJSON(String(localized: "workspace.metadata.invalidJSON", defaultValue: "metadata must contain JSON values"))
                }
                let data = try JSONSerialization.data(withJSONObject: partial)
                guard data.count <= WorkspaceMetadataStore.payloadCapBytes else {
                    throw PanelMetadataStore.WriteError.payloadTooLarge
                }
            }
        } catch let error as WorkspaceMetadataValidator.ValidationError {
            return .err(code: error.code, message: error.message, data: error.detail)
        } catch let error as PanelMetadataStore.WriteError {
            return .err(code: error.code, message: error.message, data: error.detailData)
        } catch {
            return .err(code: "invalid_json", message: "\(error)", data: nil)
        }

        let operation = SelectionReadOperation<V2CallResult>(timeout: timeout)
        let context = SocketCommandContext.current
        let store = grouped ? WorkspaceMetadataStore.groups : WorkspaceMetadataStore.shared
        let capture = {
            MainActor.assumeIsolated {
                guard operation.beginCapture() else { return }
                SocketCommandContext.withContext(context) {
                    if grouped {
                        operation.complete(self.v2WorkspaceGroupMetadataTarget(params: params, notFound: notFound))
                        return
                    }
                    // No selected-workspace fallback, even when the target closed.
                    guard let workspaceId = self.v2UUID(params, "workspace_id"),
                          let app = AppDelegate.shared,
                          let manager = app.workspaceManagerFor(workspaceId: workspaceId),
                          manager.workspaces.contains(where: { $0.id == workspaceId }),
                          let generation = WorkspaceMetadataStore.shared.registrationGeneration(workspaceId: workspaceId) else {
                        operation.complete(.err(code: "not_found", message: "Workspace not found", data: nil))
                        return
                    }
                    if params["window_id"] != nil,
                       self.v2UUID(params, "window_id") != app.windowId(for: manager) {
                        operation.complete(.err(code: "not_found", message: String(localized: "workspace.metadata.notInWindow", defaultValue: "Workspace not found in window"), data: nil))
                        return
                    }
                    let windowId = app.windowId(for: manager)
                    operation.complete(.ok([
                        "workspace_id": workspaceId.uuidString,
                        "_metadata_generation": generation,
                        "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                        "window_id": windowId?.uuidString as Any? ?? NSNull(),
                        "window_ref": self.v2Ref(kind: .window, uuid: windowId)
                    ]))
                }
            }
        }
        if Thread.isMainThread { capture() } else { DispatchQueue.main.async(execute: capture) }
        guard let target = operation.wait(), operation.canPublish else {
            return .err(code: "main_thread_timeout", message: String(localized: "workspace.metadata.targetTimeout", defaultValue: "Workspace metadata target lookup timed out; no change was made"), data: nil)
        }
        guard case .ok(let rawPayload) = target else { return target }
        guard var payload = rawPayload as? [String: Any],
              let rawID = payload[grouped ? "group_id" : "workspace_id"] as? String, let workspaceId = UUID(uuidString: rawID),
              let generation = payload.removeValue(forKey: "_metadata_generation") as? UInt64 else {
            return notFound
        }
        do {
            if reading {
                guard store.registrationGeneration(workspaceId: workspaceId) == generation else { throw WorkspaceMetadataStore.TargetError.notFound }
                let snapshot = store.getMetadata(workspaceId: workspaceId)
                let metadata = keys.map { filter in snapshot.metadata.filter { filter.contains($0.key) } } ?? snapshot.metadata
                payload["metadata"] = metadata
                if params["include_sources"] as? Bool == true || params["sources"] as? Bool == true {
                    payload["metadata_sources"] = snapshot.sources.filter { metadata[$0.key] != nil }
                }
                if let key = params["key"] as? String {
                    payload["key"] = key
                    payload["value"] = metadata[key] ?? NSNull()
                }
            } else {
                let result: PanelMetadataStore.WriteResult
                if method.hasSuffix(".clear_metadata") || legacyClear {
                    result = try store.clearMetadata(workspaceId: workspaceId, keys: keys, source: source, requireRegistered: true, expectedGeneration: generation)
                } else {
                    result = try store.setMetadata(workspaceId: workspaceId, partial: partial, mode: mode, source: source, requireRegistered: true, expectedGeneration: generation)
                }
                payload["metadata"] = result.metadata
                payload["metadata_sources"] = result.sources
                payload["applied"] = result.applied
                payload["reasons"] = result.reasons
                payload["removed_keys"] = result.removedKeys.sorted()
            }
            return .ok(payload)
        } catch is WorkspaceMetadataStore.TargetError where grouped {
            return notFound
        } catch let error as WorkspaceMetadataStore.TargetError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch let error as WorkspaceMetadataValidator.ValidationError {
            return .err(code: error.code, message: error.message, data: error.detail)
        } catch let error as PanelMetadataStore.WriteError {
            return .err(code: error.code, message: error.message, data: error.detailData)
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }

    /// Main-thread lookup of a live group in any window. Accepts a UUID or a
    /// `workspace_group:N` ref; never falls back to a selected or current group.
    private func v2WorkspaceGroupMetadataTarget(params: [String: Any], notFound: V2CallResult) -> V2CallResult {
        guard let app = AppDelegate.shared else { return notFound }
        let managers = app.fleetWorkspaceManagers()
        for (windowId, manager) in managers {
            _ = v2EnsureHandleRef(kind: .window, uuid: windowId)
            for group in manager.workspaceGroups { _ = v2EnsureHandleRef(kind: .workspaceGroup, uuid: group.id) }
        }
        guard let raw = (params["group_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return notFound }
        let groupId: UUID? = UUID(uuidString: raw)
            ?? (raw.hasPrefix(V2HandleKind.workspaceGroup.rawValue + ":") ? v2UUIDByRef[.workspaceGroup]?[raw] : nil)
        guard let groupId,
              let windowId = managers.first(where: { $0.manager.workspaceGroups.contains { $0.id == groupId } })?.windowId,
              let generation = WorkspaceMetadataStore.groups.registrationGeneration(workspaceId: groupId) else {
            return notFound
        }
        if params["window_id"] != nil, v2UUID(params, "window_id") != windowId {
            return .err(code: "wrong_window", message: String(localized: "workspaceGroup.error.wrongWindow", defaultValue: "The target does not belong to this window."), data: nil)
        }
        return .ok([
            "group_id": groupId.uuidString,
            "_metadata_generation": generation,
            "group_ref": v2Ref(kind: .workspaceGroup, uuid: groupId),
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    private func v2WorkspaceAction(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }

        let supportedActions = [
            "pin", "unpin", "rename", "clear_name",
            "move_up", "move_down", "move_top",
            "close_above", "close_below",
            "mark_read", "mark_unread"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown workspace action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            let requestedWorkspaceId = v2UUID(params, "workspace_id") ?? workspaceManager.selectedWorkspaceId
            guard let workspaceId = requestedWorkspaceId,
                  let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)

            @MainActor
            func closeWorkspaces(_ workspaces: [Workspace]) -> Int {
                var closed = 0
                for candidate in workspaces where candidate.id != workspace.id {
                    let existedBefore = workspaceManager.workspaces.contains(where: { $0.id == candidate.id })
                    guard existedBefore else { continue }
                    workspaceManager.closeWorkspace(candidate)
                    if !workspaceManager.workspaces.contains(where: { $0.id == candidate.id }) {
                        closed += 1
                    }
                }
                return closed
            }

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            switch action {
            case "pin":
                workspaceManager.setPinned(workspace, pinned: true)
                finish(["pinned": true])

            case "unpin":
                workspaceManager.setPinned(workspace, pinned: false)
                finish(["pinned": false])

            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                workspaceManager.setCustomTitle(workspaceId: workspace.id, title: title)
                finish(["title": title])

            case "clear_name":
                workspaceManager.clearCustomTitle(workspaceId: workspace.id)
                finish(["title": workspace.title])

            case "move_up", "move_down":
                guard workspaceManager.workspaces.contains(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                // C11H-342: one sidebar step, as the menu and the row take: an
                // ungrouped workspace passes a group, a member stays in its group.
                _ = workspaceManager.stepWorkspaceInSidebar(workspace.id, by: action == "move_up" ? -1 : 1)
                finish(["index": v2OrNull(workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }))])

            case "move_top":
                workspaceManager.moveWorkspaceToTop(workspace.id)
                finish(["index": v2OrNull(workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }))])

            case "close_above":
                guard let index = workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates = Array(workspaceManager.workspaces.prefix(index)).filter { !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_below":
                guard let index = workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates: [Workspace]
                if index + 1 < workspaceManager.workspaces.count {
                    candidates = Array(workspaceManager.workspaces.suffix(from: index + 1)).filter { !$0.isPinned }
                } else {
                    candidates = []
                }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "mark_read":
                AppDelegate.shared?.notificationStore?.markRead(forWorkspaceId: workspace.id)
                finish()

            case "mark_unread":
                AppDelegate.shared?.notificationStore?.markUnread(forWorkspaceId: workspace.id)
                finish()

            default:
                result = .err(code: "invalid_params", message: "Unknown workspace action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }
}
