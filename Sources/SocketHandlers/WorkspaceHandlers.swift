import AppKit
import Foundation

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `workspace.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchWorkspace(_ method: String, id: Any?, params: [String: Any]) -> String {
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
            return v2Result(id: id, self.v2WorkspaceClose(params: params))
        case "workspace.move_to_window":
            return v2Result(id: id, self.v2WorkspaceMoveToWindow(params: params))
        case "workspace.reorder":
            return v2Result(id: id, self.v2WorkspaceReorder(params: params))
        case "workspace.rename":
            return v2Result(id: id, self.v2WorkspaceRename(params: params))
        case "workspace.action":
            return v2Result(id: id, self.v2WorkspaceAction(params: params))
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
        case "workspace.set_metadata":
            return v2Result(id: id, self.v2WorkspaceSetMetadata(params: params))
        case "workspace.get_metadata":
            return v2Result(id: id, self.v2WorkspaceGetMetadata(params: params))
        case "workspace.clear_metadata":
            return v2Result(id: id, self.v2WorkspaceClearMetadata(params: params))
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
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2WorkspaceList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var workspaces: [[String: Any]] = []
        v2MainSync {
            workspaces = tabManager.tabs.enumerated().map { index, ws in
                return [
                    "id": ws.id.uuidString,
                    "ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "index": index,
                    "title": ws.title,
                    "selected": ws.id == tabManager.selectedTabId,
                    "pinned": ws.isPinned,
                    "listening_ports": ws.listeningPorts,
                    "remote": ws.remoteStatusPayload(),
                    "current_directory": v2OrNull(ws.currentDirectory),
                    "custom_color": v2OrNull(ws.customColor)
                ]
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspaces": workspaces
        ])
    }

    private func v2WorkspaceCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
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
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let str = raw as? String else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            cwd = str
        } else {
            cwd = nil
        }

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
                        if let ws = tabManager.tabs.first(where: { $0.id == wsUUID }) {
                            tabManager.closeWorkspace(ws)
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
                    if tabManager.tabs.contains(where: { $0.id == wsUUID }) {
                        tabManager.setCustomTitle(tabId: wsUUID, title: appliedLayoutTitle)
                    }
                }
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "workspace_id": v2OrNull(wsUUID?.uuidString),
                "workspace_ref": workspaceRef as Any,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "title": v2OrNull(appliedLayoutTitle),
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
            let ws = tabManager.addWorkspace(
                workingDirectory: cwd,
                initialTerminalCommand: initialCommand,
                initialTerminalEnvironment: initialEnv,
                select: shouldFocus,
                eagerLoadTerminal: !shouldFocus
            )
            newId = ws.id
            if let customTitle {
                tabManager.setCustomTitle(tabId: ws.id, title: customTitle)
            }
            return
        }) != nil else {
            return .err(code: "main_thread_timeout", message: "main thread did not respond within deadline", data: nil)
        }

        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
            "title": v2OrNull(customTitle)
        ])
    }

    private func v2WorkspaceSelect(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        var success = false
        v2MainSync {
            if let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                // If this workspace belongs to another window, bring it forward so focus is visible.
                if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                    _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                    setActiveTabManager(tabManager)
                    // Bring c11 to the macOS foreground for explicit focus-intent commands.
                    // workspace.select is in focusIntentV2Methods, so this is intentional.
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                tabManager.selectWorkspace(ws)
                success = true
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
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
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var wsId: UUID?
        var wsPayload: [String: Any]?
        v2MainSync {
            wsId = tabManager.selectedTabId
            if let wsId, let workspace = tabManager.tabs.first(where: { $0.id == wsId }) {
                wsPayload = [
                    "id": workspace.id.uuidString,
                    "ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "title": workspace.title,
                    "selected": true,
                    "pinned": workspace.isPinned,
                    "listening_ports": workspace.listeningPorts,
                    "remote": workspace.remoteStatusPayload(),
                ]
            }
        }
        guard let wsId else {
            return .err(code: "not_found", message: "No workspace selected", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": wsId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
            "workspace": wsPayload ?? NSNull()
        ])
    }

    private func v2WorkspaceClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        var found = false
        v2MainSync {
            if let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                tabManager.closeWorkspace(ws)
                found = true
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return found
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
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowId.uuidString])
                return
            }
            guard let ws = srcTM.detachWorkspace(tabId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }

            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
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
        guard let tabManager = v2ResolveTabManager(params: params) else {
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
                moved = tabManager.reorderWorkspace(tabId: workspaceId, toIndex: index)
            } else {
                moved = tabManager.reorderWorkspace(tabId: workspaceId, before: beforeId, after: afterId)
            }
            newIndex = tabManager.tabs.firstIndex(where: { $0.id == workspaceId })
        }

        guard moved else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "index": v2OrNull(newIndex)
        ])
    }

    private func v2WorkspaceSetCustomColor(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
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

        var applied: String? = nil
        var found = false
        v2MainSync {
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
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
        guard let tabManager = v2ResolveTabManager(params: params) else {
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
            guard tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return }
            tabManager.setCustomTitle(tabId: workspaceId, title: title)
            renamed = true
        }

        guard renamed else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "title": title
        ])
    }

    private func v2WorkspaceNext(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard tabManager.selectedTabId != nil else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.selectNextTab()
            guard let workspaceId = tabManager.selectedTabId else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
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
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard tabManager.selectedTabId != nil else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.selectPreviousTab()
            guard let workspaceId = tabManager.selectedTabId else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
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
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No previous workspace in history", data: nil)
        v2MainSync {
            guard let before = tabManager.selectedTabId else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.navigateBack()
            guard let after = tabManager.selectedTabId, after != before else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
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
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
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
        let relayID = v2RawString(params, "relay_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayToken = v2RawString(params, "relay_token")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localSocketPath = v2RawString(params, "local_socket_path")
        let terminalStartupCommand = v2RawString(params, "terminal_startup_command")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if relayPort != nil {
            guard let relayID, !relayID.isEmpty else {
                return .err(code: "invalid_params", message: "relay_id is required when relay_port is set", data: nil)
            }
            guard let relayToken,
                  relayToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                return .err(code: "invalid_params", message: "relay_token must be 64 lowercase hex characters when relay_port is set", data: nil)
            }
        }

#if DEBUG
        dlog(
            "workspace.remote.configure.request workspace=\(workspaceId.uuidString.prefix(8)) " +
            "target=\(destination) port=\(sshPort.map(String.init) ?? "nil") " +
            "autoConnect=\(autoConnect ? 1 : 0) relayPort=\(relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(localSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? localSocketPath! : "nil") " +
            "sshOptions=\(sshOptions.joined(separator: "|"))"
        )
#endif
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because Workspace.configureRemoteConnection mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            let config = WorkspaceRemoteConfiguration(
                destination: destination,
                port: sshPort,
                identityFile: identityFile?.isEmpty == true ? nil : identityFile,
                sshOptions: sshOptions,
                localProxyPort: localProxyPort,
                relayPort: relayPort,
                relayID: relayID?.isEmpty == true ? nil : relayID,
                relayToken: relayToken?.isEmpty == true ? nil : relayToken,
                localSocketPath: localSocketPath,
                terminalStartupCommand: terminalStartupCommand?.isEmpty == true ? nil : terminalStartupCommand
            )
            workspace.configureRemoteConnection(config, autoConnect: autoConnect)

            let windowId = v2ResolveWindowId(tabManager: owner)
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
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
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
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            workspace.disconnectRemoteConnection(clearConfiguration: clearConfiguration)
            let windowId = v2ResolveWindowId(tabManager: owner)
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
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because reconnect mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
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
            let windowId = v2ResolveWindowId(tabManager: owner)
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
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because Workspace.remoteStatusPayload reads TabManager/UI-owned state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }
            let windowId = v2ResolveWindowId(tabManager: owner)
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
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
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
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }
            workspace.markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: relayPort)
            let windowId = v2ResolveWindowId(tabManager: owner)
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
            plan = try JSONDecoder().decode(WorkspaceApplyPlan.self, from: planData)
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

        guard let tabManager = v2ResolveTabManager(params: params) else {
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
                tabManager: tabManager,
                workspaceRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .workspace, uuid: uuid) ?? "workspace:\(uuid.uuidString)"
                },
                surfaceRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .surface, uuid: uuid) ?? "surface:\(uuid.uuidString)"
                },
                paneRefMinter: { [weak self] uuid in
                    self?.v2EnsureHandleRef(kind: .pane, uuid: uuid) ?? "pane:\(uuid.uuidString)"
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
    /// Returns `{blueprints: [...WorkspaceBlueprintIndex...]}`.
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
            return .ok(["blueprints": asAny])
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

        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var blueprintFile: WorkspaceBlueprintFile?
        v2MainSync {
            let exporter = WorkspaceBlueprintExporter(tabManager: tabManager)
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
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
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/c11/blueprints")
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
        guard let data = content.data(using: .utf8) else {
            return .err(code: "invalid_params", message: "Content is not valid UTF-8", data: nil)
        }
        let file: WorkspaceBlueprintFile
        do {
            switch formatRaw {
            case "md", "markdown":
                file = try WorkspaceBlueprintMarkdown.parse(data)
            case "json":
                file = try JSONDecoder().decode(WorkspaceBlueprintFile.self, from: data)
            default:
                return .err(
                    code: "invalid_params",
                    message: "Unsupported format '\(formatRaw)'. Expected 'md' or 'json'.",
                    data: nil
                )
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

    private func v2WorkspaceSetMetadata(params: [String: Any]) -> V2CallResult {
        // Parse + validate off-main per the socket command threading policy
        // (CLAUDE.md "Socket command threading policy").
        let rawMetadata = v2StringMap(params, "metadata")
        let singleKey = v2String(params, "key")
        let singleValueRaw = params["value"]

        var writes: [String: String?] = [:]
        if let rawMetadata {
            for (k, v) in rawMetadata { writes[k] = v }
        }
        if let singleKey {
            if singleValueRaw is NSNull {
                writes[singleKey] = nil
            } else if let s = singleValueRaw as? String {
                writes[singleKey] = s
            } else if singleValueRaw == nil {
                return .err(code: "invalid_params", message: "Missing 'value' for key '\(singleKey)'", data: nil)
            } else {
                return .err(code: "invalid_params", message: "metadata value must be a string or null", data: nil)
            }
        }

        if writes.isEmpty {
            return .err(
                code: "invalid_params",
                message: "Provide 'metadata' object or 'key'/'value' pair",
                data: nil
            )
        }

        // Validate all keys and non-nil values off-main before taking the
        // main-actor critical section.
        for (k, maybeValue) in writes {
            do {
                if let value = maybeValue {
                    try WorkspaceMetadataValidator.validate(key: k, value: value)
                } else {
                    try WorkspaceMetadataValidator.validateKey(k)
                }
            } catch let err as WorkspaceMetadataValidator.ValidationError {
                return .err(code: err.code, message: err.message, data: err.detail)
            } catch {
                return .err(code: "internal_error", message: "\(error)", data: nil)
            }
        }

        guard let resolved = v2ResolveWorkspaceForMetadata(params: params) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }

        var capacityError: WorkspaceMetadataValidator.CapacityError?
        var resultMetadata: [String: String] = [:]
        // Workspace is @MainActor; the mutation must run on the main actor.
        // Precedent: workspace.rename handler (v2WorkspaceRename).
        v2MainSync {
            guard let ws = resolved.tabManager.tabs.first(where: { $0.id == resolved.workspaceId }) else {
                return
            }
            var next = ws.metadata
            for (k, maybeValue) in writes {
                if let value = maybeValue {
                    next[k] = value
                } else {
                    next.removeValue(forKey: k)
                }
            }
            do {
                try WorkspaceMetadataValidator.validateCapacity(after: next)
            } catch let err as WorkspaceMetadataValidator.CapacityError {
                capacityError = err
                return
            } catch {
                // Unreachable: validateCapacity only throws CapacityError.
                return
            }
            ws.metadata = next
            resultMetadata = next
        }

        if let err = capacityError {
            return .err(code: err.code, message: err.message, data: err.detail)
        }

        let windowId = v2ResolveWindowId(tabManager: resolved.tabManager)
        return .ok([
            "workspace_id": resolved.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: resolved.workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "metadata": resultMetadata
        ])
    }

    private func v2WorkspaceGetMetadata(params: [String: Any]) -> V2CallResult {
        let requestedKey = v2String(params, "key")
        let requestedKeys = v2StringArray(params, "keys")

        guard let resolved = v2ResolveWorkspaceForMetadata(params: params) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }

        var full: [String: String] = [:]
        v2MainSync {
            guard let ws = resolved.tabManager.tabs.first(where: { $0.id == resolved.workspaceId }) else {
                return
            }
            full = ws.metadata
        }

        var metadataOut: [String: String] = full
        if let filterKeys = requestedKeys {
            metadataOut = [:]
            for k in filterKeys {
                if let v = full[k] { metadataOut[k] = v }
            }
        } else if let single = requestedKey {
            metadataOut = [:]
            if let v = full[single] { metadataOut[single] = v }
        }

        let windowId = v2ResolveWindowId(tabManager: resolved.tabManager)
        var payload: [String: Any] = [
            "workspace_id": resolved.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: resolved.workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "metadata": metadataOut
        ]
        if let single = requestedKey {
            payload["key"] = single
            payload["value"] = v2OrNull(metadataOut[single])
        }
        return .ok(payload)
    }

    private func v2WorkspaceClearMetadata(params: [String: Any]) -> V2CallResult {
        let keys: [String]?
        if params["keys"] == nil || params["keys"] is NSNull {
            keys = nil
        } else if let arr = v2StringArray(params, "keys") {
            keys = arr
        } else {
            return .err(code: "invalid_keys_param", message: "keys must be an array of strings", data: nil)
        }

        // Validate key grammar off-main when a filter is provided; malformed
        // keys could never have been written but reject them explicitly so
        // callers see a consistent error shape.
        if let keys {
            for k in keys {
                do {
                    try WorkspaceMetadataValidator.validateKey(k)
                } catch let err as WorkspaceMetadataValidator.ValidationError {
                    return .err(code: err.code, message: err.message, data: err.detail)
                } catch {
                    return .err(code: "internal_error", message: "\(error)", data: nil)
                }
            }
        }

        guard let resolved = v2ResolveWorkspaceForMetadata(params: params) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }

        var resultMetadata: [String: String] = [:]
        v2MainSync {
            guard let ws = resolved.tabManager.tabs.first(where: { $0.id == resolved.workspaceId }) else {
                return
            }
            if let keys {
                var next = ws.metadata
                for k in keys { next.removeValue(forKey: k) }
                ws.metadata = next
            } else {
                ws.metadata = [:]
            }
            resultMetadata = ws.metadata
        }

        let windowId = v2ResolveWindowId(tabManager: resolved.tabManager)
        return .ok([
            "workspace_id": resolved.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: resolved.workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "metadata": resultMetadata
        ])
    }

    private func v2WorkspaceAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }

        let supportedActions = [
            "pin", "unpin", "rename", "clear_name",
            "move_up", "move_down", "move_top",
            "close_others", "close_above", "close_below",
            "mark_read", "mark_unread"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown workspace action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            let requestedWorkspaceId = v2UUID(params, "workspace_id") ?? tabManager.selectedTabId
            guard let workspaceId = requestedWorkspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)

            @MainActor
            func closeWorkspaces(_ workspaces: [Workspace]) -> Int {
                var closed = 0
                for candidate in workspaces where candidate.id != workspace.id {
                    let existedBefore = tabManager.tabs.contains(where: { $0.id == candidate.id })
                    guard existedBefore else { continue }
                    tabManager.closeWorkspace(candidate)
                    if !tabManager.tabs.contains(where: { $0.id == candidate.id }) {
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
                tabManager.setPinned(workspace, pinned: true)
                finish(["pinned": true])

            case "unpin":
                tabManager.setPinned(workspace, pinned: false)
                finish(["pinned": false])

            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                tabManager.setCustomTitle(tabId: workspace.id, title: title)
                finish(["title": title])

            case "clear_name":
                tabManager.clearCustomTitle(tabId: workspace.id)
                finish(["title": workspace.title])

            case "move_up":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: max(currentIndex - 1, 0))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_down":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: min(currentIndex + 1, tabManager.tabs.count - 1))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_top":
                tabManager.moveTabToTop(workspace.id)
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "close_others":
                let candidates = tabManager.tabs.filter { $0.id != workspace.id && !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_above":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates = Array(tabManager.tabs.prefix(index)).filter { !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_below":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates: [Workspace]
                if index + 1 < tabManager.tabs.count {
                    candidates = Array(tabManager.tabs.suffix(from: index + 1)).filter { !$0.isPinned }
                } else {
                    candidates = []
                }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "mark_read":
                AppDelegate.shared?.notificationStore?.markRead(forTabId: workspace.id)
                finish()

            case "mark_unread":
                AppDelegate.shared?.notificationStore?.markUnread(forTabId: workspace.id)
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
