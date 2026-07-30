import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `surface.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchSurface(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "surface.list":
            return v2Result(id: id, self.v2SurfaceList(params: params))
        case "surface.current":
            return v2Result(id: id, self.v2SurfaceCurrent(params: params))
        case "surface.set_custom_color":
            return v2Result(id: id, self.v2SurfaceSetCustomColor(params: params))
        case "surface.focus":
            return v2Result(id: id, self.v2SurfaceFocus(params: params))
        case "surface.split":
            return v2Result(id: id, self.v2SurfaceSplit(params: params))
        case "surface.create":
            return v2Result(id: id, self.v2SurfaceCreate(params: params))
        case "surface.close":
            return v2Result(id: id, self.v2SurfaceClose(params: params))
        case "surface.move":
            return v2Result(id: id, self.v2SurfaceMove(params: params))
        case "surface.reorder":
            return v2Result(id: id, self.v2SurfaceReorder(params: params))
        case "surface.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "surface.drag_to_split":
            return v2Result(id: id, self.v2SurfaceDragToSplit(params: params))
        case "surface.refresh":
            return v2Result(id: id, self.v2SurfaceRefresh(params: params))
        case "surface.health":
            return v2Result(id: id, self.v2SurfaceHealth(params: params))
        case "surface.trigger_flash":
            return v2Result(id: id, self.v2SurfaceTriggerFlash(params: params))
        case "surface.cancel_flash":
            return v2Result(id: id, self.v2SurfaceCancelFlash(params: params))
        case "surface.set_metadata":
            return v2Result(id: id, self.v2SurfaceSetMetadata(params: params))
        case "surface.get_metadata":
            return v2Result(id: id, self.v2SurfaceGetMetadata(params: params))
        case "surface.clear_metadata":
            return v2Result(id: id, self.v2SurfaceClearMetadata(params: params))
        case "surface.get_titlebar_state":
            return v2Result(id: id, self.v2SurfaceGetTitleBarState(params: params))
        case "surface.set_titlebar_visibility":
            return v2Result(id: id, self.v2SurfaceSetTitleBarVisibility(params: params))
        case "surface.set_titlebar_collapsed":
            return v2Result(id: id, self.v2SurfaceSetTitleBarCollapsed(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2SurfaceList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            // Map panel_id -> pane_id and index/selection within that pane.
            var paneByPanelId: [UUID: UUID] = [:]
            var indexInPaneByPanelId: [UUID: Int] = [:]
            var selectedInPaneByPanelId: [UUID: Bool] = [:]
            for paneId in ws.bonsplitController.allPaneIds {
                let tabs = ws.bonsplitController.tabs(inPane: paneId)
                let selected = ws.bonsplitController.selectedTab(inPane: paneId)
                for (idx, tab) in tabs.enumerated() {
                    guard let panelId = ws.panelIdFromSurfaceId(tab.id) else { continue }
                    paneByPanelId[panelId] = paneId.id
                    indexInPaneByPanelId[panelId] = idx
                    selectedInPaneByPanelId[panelId] = (tab.id == selected?.id)
                }
            }

            let focusedSurfaceId = ws.focusedPanelId
            let panels = orderedPanels(in: ws)
            let surfaces: [[String: Any]] = panels.enumerated().map { index, panel in
                let paneUUID = paneByPanelId[panel.id]
                var item: [String: Any] = [
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "type": panel.panelType.rawValue,
                    "title": ws.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                    "focused": panel.id == focusedSurfaceId,
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                    "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id]),
                    "tty": v2OrNull(ws.surfaceTTYNames[panel.id]),
                    "custom_color": v2OrNull(ws.panelCustomColor(panelId: panel.id))
                ]
                if let browserPanel = panel as? BrowserPanel {
                    item["developer_tools_visible"] = browserPanel.isDeveloperToolsVisible()
                }
                if let markdownPanel = panel as? MarkdownPanel {
                    item["file_path"] = markdownPanel.filePath
                }
                // C11-25 fix DoD #5: expose the SurfaceMetricsSampler
                // snapshot for terminal + browser surfaces so callers
                // (smoke harness, `c11 tree --json`) can verify the
                // CPU/RSS sidebar telemetry without a screenshot. Markdown
                // surfaces have no process-level metric — omit the block.
                // Lookup is a lock-protected dictionary read; safe on
                // main. `cpu_pct` / `rss_mb` are NSNull until the sampler
                // converges (~one tick after pid registration).
                switch panel.panelType {
                case .terminal, .browser:
                    let sample = SurfaceMetricsSampler.shared.sample(forSurfaceId: panel.id)
                    var metrics: [String: Any] = [
                        "cpu_pct": v2OrNull(sample?.cpuPct),
                        "rss_mb": v2OrNull(sample?.rssMb)
                    ]
                    if let sampledAt = sample?.sampledAt {
                        metrics["sampled_at"] = ISO8601DateFormatter().string(from: sampledAt)
                    } else {
                        metrics["sampled_at"] = NSNull()
                    }
                    item["metrics"] = metrics
                case .markdown:
                    break
                }
                return item
            }

            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surfaces": surfaces
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        var out = payload
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        out["window_id"] = v2OrNull(windowId?.uuidString)
        out["window_ref"] = v2Ref(kind: .window, uuid: windowId)
        return .ok(out)
    }

    private func v2SurfaceCurrent(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            // Focus can be transiently nil during startup/reparenting; fall back to first
            // ordered panel so callers always get a usable current surface.
            let surfaceId = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
            let paneId = surfaceId.flatMap { ws.paneId(forPanelId: $0)?.id }
            let windowId = v2ResolveWindowId(tabManager: tabManager)

            payload = [
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(paneId?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneId),
                "surface_id": v2OrNull(surfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "surface_type": v2OrNull(surfaceId.flatMap { ws.panels[$0]?.panelType.rawValue }),
                "custom_color": v2OrNull(surfaceId.flatMap { ws.panelCustomColor(panelId: $0) })
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    private func v2SurfaceSetCustomColor(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let clear = (params["clear"] as? Bool) ?? false
        let hex = params["hex"] as? String

        if !clear && hex == nil {
            return .err(code: "invalid_params", message: "Provide either 'hex' or 'clear=true'", data: nil)
        }
        if clear && hex != nil {
            return .err(code: "invalid_params", message: "'clear' and 'hex' are mutually exclusive", data: nil)
        }
        if !clear, let hex, WorkspaceTabColorSettings.normalizedHex(hex) == nil {
            return .err(code: "invalid_params", message: "Invalid hex color (use #RRGGBB)", data: ["hex": hex])
        }

        var applied: String? = nil
        var workspaceUUID: UUID? = nil
        var found = false
        v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            guard workspace.panels[surfaceId] != nil else { return }
            workspaceUUID = workspace.id
            found = true
            if clear {
                workspace.setPanelCustomColor(panelId: surfaceId, color: nil)
                applied = nil
            } else if let hex {
                workspace.setPanelCustomColor(panelId: surfaceId, color: hex)
                applied = workspace.panelCustomColor(panelId: surfaceId)
            }
        }

        guard found else {
            return .err(code: "not_found", message: "Surface not found", data: [
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }

        return .ok([
            "workspace_id": v2OrNull(workspaceUUID?.uuidString),
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceUUID),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "custom_color": v2OrNull(applied),
            "cleared": clear
        ])
    }

    private func v2SurfaceFocus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }

            // Make sure the workspace is selected so focus effects apply to the visible UI.
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }

            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            ws.focusPanel(surfaceId)
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    func v2SurfaceSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }
        let titleSeed = v2String(params, "title")
        let force = splitForceFlag(params)

        // Validate the optional --cwd override server-side before spawning so a
        // bad path returns a clear error instead of silently landing in $HOME.
        var cwdOverride: String?
        if let err = v2ResolveCwdParam(params, resolved: &cwdOverride) {
            return err
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create split", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let targetSurfaceId: UUID? = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let targetSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard ws.panels[targetSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": targetSurfaceId.uuidString])
                return
            }

            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            // new-split always creates a terminal.
            let plan = self.planSizeAwareSplit(ws: ws, sourcePanelId: targetSurfaceId, requested: direction, newIsTerminal: true, force: force)
            switch plan {
            case .refuse(let message, let data):
                result = .err(code: "pane_too_small", message: message, data: data)

            case .tab(let paneId, let warning):
                guard let panel = ws.newTerminalSurface(inPane: paneId, focus: self.v2FocusAllowed(), workingDirectory: cwdOverride) else {
                    result = .err(code: "internal_error", message: "Failed to create surface", data: nil)
                    return
                }
                self.v2SeedPaneTitle(workspaceId: ws.id, paneUUID: paneId.id, title: titleSeed)
                let windowId = self.v2ResolveWindowId(tabManager: tabManager)
                var ok: [String: Any] = [
                    "window_id": self.v2OrNull(windowId?.uuidString),
                    "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": paneId.id.uuidString,
                    "pane_ref": self.v2Ref(kind: .pane, uuid: paneId.id),
                    "surface_id": panel.id.uuidString,
                    "surface_ref": self.v2Ref(kind: .surface, uuid: panel.id),
                    "type": self.v2OrNull(ws.panels[panel.id]?.panelType.rawValue)
                ]
                self.annotateSizeOutcome(&ok, requested: direction, applied: direction, becameTab: true, warning: warning)
                result = .ok(ok)

            case .split(let actualDirection, let requested, let warning):
                if let newId = tabManager.newSplit(tabId: ws.id, surfaceId: targetSurfaceId, direction: actualDirection, workingDirectory: cwdOverride) {
                    let paneUUID = ws.paneId(forPanelId: newId)?.id
                    // Seed pane title atomic with pane id becoming valid.
                    self.v2SeedPaneTitle(workspaceId: ws.id, paneUUID: paneUUID, title: titleSeed)
                    let windowId = self.v2ResolveWindowId(tabManager: tabManager)
                    var ok: [String: Any] = [
                        "window_id": self.v2OrNull(windowId?.uuidString),
                        "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                        "pane_id": self.v2OrNull(paneUUID?.uuidString),
                        "pane_ref": self.v2Ref(kind: .pane, uuid: paneUUID),
                        "surface_id": newId.uuidString,
                        "surface_ref": self.v2Ref(kind: .surface, uuid: newId),
                        "type": self.v2OrNull(ws.panels[newId]?.panelType.rawValue)
                    ]
                    self.annotateSizeOutcome(&ok, requested: requested, applied: actualDirection, becameTab: false, warning: warning)
                    result = .ok(ok)
                } else {
                    result = .err(code: "internal_error", message: "Failed to create split", data: nil)
                }
            }
        }
        return result
    }

    private func v2SurfaceCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let panelType = v2PanelType(params, "type") ?? .terminal
        if let denial = v2SurfaceTypeDenial(panelType) { return denial }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let filePath = v2String(params, "file")

        // Validate and resolve markdown file path
        var resolvedMarkdownPath: String?
        if panelType == .markdown {
            if let err = v2ValidateMarkdownPath(filePath, context: "surface", resolved: &resolvedMarkdownPath) {
                return err
            }
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create surface", data: nil)
        guard v2MainSyncWithDeadline({
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            // Caller may pass focus: false to opt out of focus (--no-focus in CLI).
            // surface.create is NOT in focusIntentV2Methods, so v2FocusAllowed returns false
            // regardless of callerWantsFocus. The focus param is accepted for forward-compatibility
            // if surface.create is added to focusIntentV2Methods in the future.
            let callerWantsFocus = self.v2Bool(params, "focus") ?? true
            let focus = self.v2FocusAllowed(requested: callerWantsFocus)
            if focus {
                self.v2MaybeFocusWindow(for: tabManager)
                self.v2MaybeSelectWorkspace(tabManager, workspace: ws)
            }

            let paneUUID = self.v2UUID(params, "pane_id")
            let paneId: PaneID? = {
                if let paneUUID {
                    return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                }
                return ws.bonsplitController.focusedPaneId
            }()

            guard let paneId else {
                result = .err(code: "not_found", message: "Pane not found", data: nil)
                return
            }

            let newPanelId: UUID?
            switch panelType {
            case .browser:
                newPanelId = ws.newBrowserSurface(inPane: paneId, url: url, focus: focus)?.id
            case .markdown:
                newPanelId = ws.newMarkdownSurface(inPane: paneId, filePath: resolvedMarkdownPath!, focus: focus)?.id
            case .terminal:
                newPanelId = ws.newTerminalSurface(inPane: paneId, focus: focus)?.id
            }

            guard let newPanelId else {
                result = .err(code: "internal_error", message: "Failed to create surface", data: nil)
                return
            }

            let windowId = self.v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneId.id.uuidString,
                "pane_ref": self.v2Ref(kind: .pane, uuid: paneId.id),
                "surface_id": newPanelId.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: newPanelId),
                "type": panelType.rawValue
            ])
        }) != nil else {
            return .err(code: "main_thread_timeout", message: "main thread did not respond within deadline", data: nil)
        }
        return result
    }

    private func v2SurfaceClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to close surface", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }

            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            // Socket API must be non-interactive: bypass close-confirmation gating.
            ws.closePanel(surfaceId, force: true)
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2SurfaceDragToSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }

        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
        let insertFirst = (direction == .left || direction == .up)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move surface", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let bonsplitTabId = ws.surfaceIdFromPanelId(surfaceId) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let newPaneId = ws.bonsplitController.splitPane(
                orientation: orientation,
                movingTab: bonsplitTabId,
                insertFirst: insertFirst
            ) else {
                result = .err(code: "internal_error", message: "Failed to split pane", data: nil)
                return
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "pane_id": newPaneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: newPaneId.id)
            ])
        }
        return result
    }

    func v2SurfaceMove(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let requestedPaneUUID = v2UUID(params, "pane_id")
        let requestedWorkspaceUUID = v2UUID(params, "workspace_id")
        let requestedWindowUUID = v2UUID(params, "window_id")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let explicitIndex = v2Int(params, "index")
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        let anchorCount = (beforeSurfaceId != nil ? 1 : 0) + (afterSurfaceId != nil ? 1 : 0)
        if anchorCount > 1 {
            return .err(code: "invalid_params", message: "Specify at most one of before_surface_id or after_surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move surface", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared else {
                result = .err(code: "unavailable", message: "AppDelegate not available", data: nil)
                return
            }

            guard let source = app.locateSurface(surfaceId: surfaceId),
                  let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let sourcePane = sourceWorkspace.paneId(forPanelId: surfaceId)
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)

            var targetWindowId = source.windowId
            var targetTabManager = source.tabManager
            var targetWorkspace = sourceWorkspace
            var targetPane = sourcePane ?? sourceWorkspace.bonsplitController.focusedPaneId ?? sourceWorkspace.bonsplitController.allPaneIds.first
            var targetIndex = explicitIndex

            if let anchorSurfaceId = beforeSurfaceId ?? afterSurfaceId {
                guard let anchor = app.locateSurface(surfaceId: anchorSurfaceId),
                      let anchorWorkspace = anchor.tabManager.tabs.first(where: { $0.id == anchor.workspaceId }),
                      let anchorPane = anchorWorkspace.paneId(forPanelId: anchorSurfaceId),
                      let anchorIndex = anchorWorkspace.indexInPane(forPanelId: anchorSurfaceId) else {
                    result = .err(code: "not_found", message: "Anchor surface not found", data: ["surface_id": anchorSurfaceId.uuidString])
                    return
                }
                targetWindowId = anchor.windowId
                targetTabManager = anchor.tabManager
                targetWorkspace = anchorWorkspace
                targetPane = anchorPane
                targetIndex = (beforeSurfaceId != nil) ? anchorIndex : (anchorIndex + 1)
            } else if let paneUUID = requestedPaneUUID {
                guard let located = v2LocatePane(paneUUID) else {
                    result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                    return
                }
                targetWindowId = located.windowId
                targetTabManager = located.tabManager
                targetWorkspace = located.workspace
                targetPane = located.paneId
            } else if let workspaceUUID = requestedWorkspaceUUID {
                guard let tm = app.tabManagerFor(tabId: workspaceUUID),
                      let ws = tm.tabs.first(where: { $0.id == workspaceUUID }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceUUID.uuidString])
                    return
                }
                targetTabManager = tm
                targetWorkspace = ws
                targetWindowId = app.windowId(for: tm) ?? targetWindowId
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            } else if let windowUUID = requestedWindowUUID {
                guard let tm = app.tabManagerFor(windowId: windowUUID) else {
                    result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWindowId = windowUUID
                targetTabManager = tm
                guard let selectedWorkspaceId = tm.selectedTabId,
                      let ws = tm.tabs.first(where: { $0.id == selectedWorkspaceId }) else {
                    result = .err(code: "not_found", message: "Target window has no selected workspace", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWorkspace = ws
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            }

            guard let destinationPane = targetPane else {
                result = .err(code: "not_found", message: "No destination pane", data: nil)
                return
            }

            if targetWorkspace.id == sourceWorkspace.id {
                guard sourceWorkspace.moveSurface(panelId: surfaceId, toPane: destinationPane, atIndex: targetIndex, focus: focus) else {
                    result = .err(code: "internal_error", message: "Failed to move surface", data: nil)
                    return
                }
                result = .ok([
                    "window_id": targetWindowId.uuidString,
                    "window_ref": v2Ref(kind: .window, uuid: targetWindowId),
                    "workspace_id": targetWorkspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: targetWorkspace.id),
                    "pane_id": destinationPane.id.uuidString,
                    "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ])
                return
            }

            guard let transfer = sourceWorkspace.detachSurface(panelId: surfaceId) else {
                result = .err(code: "internal_error", message: "Failed to detach surface", data: nil)
                return
            }

            if targetWorkspace.attachDetachedSurface(transfer, inPane: destinationPane, atIndex: targetIndex, focus: focus) == nil {
                // Roll back to source workspace if attach fails.
                let rollbackPane = sourcePane.flatMap { sp in sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0 == sp }) }
                    ?? sourceWorkspace.bonsplitController.focusedPaneId
                    ?? sourceWorkspace.bonsplitController.allPaneIds.first
                if let rollbackPane {
                    _ = sourceWorkspace.attachDetachedSurface(transfer, inPane: rollbackPane, atIndex: sourceIndex, focus: focus)
                }
                result = .err(code: "internal_error", message: "Failed to attach surface to destination", data: nil)
                return
            }

            if focus {
                _ = app.focusMainWindow(windowId: targetWindowId)
                setActiveTabManager(targetTabManager)
                targetTabManager.selectWorkspace(targetWorkspace)
            }

            result = .ok([
                "window_id": targetWindowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: targetWindowId),
                "workspace_id": targetWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: targetWorkspace.id),
                "pane_id": destinationPane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }

        return result
    }

    private func v2SurfaceReorder(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let index = v2Int(params, "index")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let targetCount = (index != nil ? 1 : 0) + (beforeSurfaceId != nil ? 1 : 0) + (afterSurfaceId != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(code: "invalid_params", message: "Specify exactly one of index, before_surface_id, or after_surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to reorder surface", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared,
                  let located = app.locateSurface(surfaceId: surfaceId),
                  let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let sourcePane = ws.paneId(forPanelId: surfaceId) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let targetIndex: Int
            if let index {
                targetIndex = index
            } else if let beforeSurfaceId {
                guard let anchorPane = ws.paneId(forPanelId: beforeSurfaceId),
                      anchorPane == sourcePane,
                      let anchorIndex = ws.indexInPane(forPanelId: beforeSurfaceId) else {
                    result = .err(code: "invalid_params", message: "Anchor surface must be in the same pane", data: nil)
                    return
                }
                targetIndex = anchorIndex
            } else if let afterSurfaceId {
                guard let anchorPane = ws.paneId(forPanelId: afterSurfaceId),
                      anchorPane == sourcePane,
                      let anchorIndex = ws.indexInPane(forPanelId: afterSurfaceId) else {
                    result = .err(code: "invalid_params", message: "Anchor surface must be in the same pane", data: nil)
                    return
                }
                targetIndex = anchorIndex + 1
            } else {
                result = .err(code: "invalid_params", message: "Missing reorder target", data: nil)
                return
            }

            guard ws.reorderSurface(panelId: surfaceId, toIndex: targetIndex) else {
                result = .err(code: "internal_error", message: "Failed to reorder surface", data: nil)
                return
            }

            result = .ok([
                "window_id": located.windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: located.windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": sourcePane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: sourcePane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }

        return result
    }

    private func v2SurfaceRefresh(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .ok(["refreshed": 0])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            var refreshedCount = 0
            for panel in ws.panels.values {
                if let terminalPanel = panel as? TerminalPanel {
                    terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceRefresh")
                    refreshedCount += 1
                }
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok(["window_id": v2OrNull(windowId?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowId), "workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "refreshed": refreshedCount])
        }
        return result
    }

    private func v2SurfaceHealth(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let panels = orderedPanels(in: ws)
            let items: [[String: Any]] = panels.enumerated().map { index, panel in
                var inWindow: Any = NSNull()
                if let tp = panel as? TerminalPanel {
                    inWindow = tp.surface.isViewInWindow
                } else if let bp = panel as? BrowserPanel {
                    inWindow = bp.webView.window != nil
                }
                return [
                    "index": index,
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "type": panel.panelType.rawValue,
                    "in_window": inWindow
                ]
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surfaces": items,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    // C11-26: surface.send_text runs on the socket worker thread (per
    // SocketCommandExecutionPolicy.socketWorker) so it cannot deadlock the main
    // queue when the surface is not yet attached. Phase A resolves refs on
    // @MainActor (no notification waits inside, so it cannot deadlock). Phase B
    // either sends immediately on @MainActor when the surface was already
    // attached, or waits for it on the worker thread via
    // waitForTerminalSurfaceOffMain (a parallel helper, not the legacy
    // v2AwaitCallback — repointing v2AwaitCallback's many @MainActor callers is
    // out of scope per ticket non-goals; this helper avoids touching them) and
    // then re-hops to @MainActor for the actual send.
    nonisolated func v2SurfaceSendText(params: [String: Any]) -> V2CallResult {
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        // C11-108: `submit` defaults to true so `c11 send "..."` types the text AND
        // submits it in one call. Callers building a partial line that should not
        // execute (e.g. typing `cd ` then more) pass `submit: false` (CLI:
        // `--no-submit`) and follow with explicit `c11 send-key enter` when ready.
        // For an attached surface, the synthetic Return fires on the same @MainActor
        // turn that delivered the text. For the queueing fallback (surface not yet
        // attached) the trailing `\r` is appended to the queued payload so the
        // flush on attach submits the line.
        let submit = v2Bool(params, "submit") ?? true

        let phaseASema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var phaseAOutcome: SurfaceSendPhaseAOutcome = .err(.err(code: "internal_error", message: "Failed to send text", data: nil))
        Task { @MainActor in
            defer { phaseASema.signal() }
            phaseAOutcome = resolveSurfaceSendTargets(params: params)
        }
        phaseASema.wait()

        let resolved: SurfaceSendPhaseAResolved
        switch phaseAOutcome {
        case .err(let err):
            return err
        case .ok(let r):
            resolved = r
        }

        #if DEBUG
        let sendStart = ProcessInfo.processInfo.systemUptime
        #endif

        let resolvedSurface: ghostty_surface_t?
        if let initialSurface = resolved.initialSurface {
            resolvedSurface = initialSurface
        } else {
            resolvedSurface = waitForTerminalSurfaceOffMain(resolved.terminalPanel, waitUpTo: 2.0)
        }

        // C11-173: what actually happened, for an honest response. `submitted`
        // is the effective submit (a trailing newline in the payload means Enter
        // even when `submit` is false); `queued` means the surface had no PTY, so
        // nothing has reached the target yet and the payload flushes on attach.
        let queued: Bool
        nonisolated(unsafe) var submitted = false
        let wantsReturn = submit || TerminalController.trimmingTrailingNewlines(text) != text
        let phaseBSema = DispatchSemaphore(value: 0)
        if resolvedSurface != nil {
            // C11-26 review B2: revalidate the live surface pointer inside the
            // Phase B @MainActor turn before passing it to sendSocketText.
            // resolvedSurface was captured in Phase A (or by waitForTerminalSurfaceOffMain
            // on the worker); TerminalSurface.teardownSurface() runs on @MainActor and
            // nils-then-frees the underlying ghostty_surface_t, so it can fire between
            // Phase A and this turn. Calling ghostty_surface_text on a freed pointer is
            // undefined behavior; re-read instead and fall through to the queue path
            // if the surface was torn down across the hop.
            nonisolated(unsafe) var attachedAtPhaseB = false
            Task { @MainActor in
                defer { phaseBSema.signal() }
                if let liveSurface = resolved.terminalPanel.surface.surface {
                    submitted = deliverSocketSendText(
                        text,
                        submit: submit,
                        terminalSurface: resolved.terminalPanel.surface,
                        surface: liveSurface
                    )
                    // Ensure we present a new frame after injecting input so snapshot-based tests
                    // (and socket-driven agents) can observe the updated terminal without requiring
                    // a focus change to trigger a draw.
                    resolved.terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendText")
                    attachedAtPhaseB = true
                } else {
                    // Surface was torn down between Phase A and Phase B. Fall through to
                    // the pending queue as a last resort. Use the canonical submit helper
                    // so the Return is dispatched as a real key event once the queued text
                    // flushes on attach, rather than appending a bare \r that the queue's
                    // bracketed-paste envelope would swallow.
                    // Same newline rule as the live path (see deliverSocketSendText):
                    // a trailing newline means "and press Enter".
                    if wantsReturn {
                        resolved.terminalPanel.surface.sendSubmitFormText(text)
                    } else {
                        resolved.terminalPanel.sendText(text)
                    }
                    submitted = wantsReturn
                }
            }
            phaseBSema.wait()
            queued = !attachedAtPhaseB
        } else {
            // Surface not available within 2s (e.g., terminal not yet attached to any window).
            // Fall back to the pending queue as a last resort. Use the canonical submit
            // helper so the Return flushes as a real key event on attach instead of a
            // bare \r swallowed inside the bracketed-paste envelope. It may have attached
            // during the hop, in which case the text goes straight through — report that
            // rather than claiming it queued.
            nonisolated(unsafe) var attachedLate = false
            Task { @MainActor in
                defer { phaseBSema.signal() }
                if let liveSurface = resolved.terminalPanel.surface.surface {
                    submitted = deliverSocketSendText(
                        text,
                        submit: submit,
                        terminalSurface: resolved.terminalPanel.surface,
                        surface: liveSurface
                    )
                    resolved.terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendText")
                    attachedLate = true
                    return
                }
                if wantsReturn {
                    resolved.terminalPanel.surface.sendSubmitFormText(text)
                } else {
                    resolved.terminalPanel.sendText(text)
                }
                submitted = wantsReturn
            }
            phaseBSema.wait()
            queued = !attachedLate
        }

        #if DEBUG
        let sendMs = (ProcessInfo.processInfo.systemUptime - sendStart) * 1000.0
        dlog(
            "socket.surface.send_text workspace=\(resolved.workspaceIdString.prefix(8)) surface=\(resolved.surfaceIdString.prefix(8)) queued=\(queued ? 1 : 0) chars=\(text.count) ms=\(String(format: "%.2f", sendMs))"
        )
        #endif

        var envelope = resolved.responseEnvelope
        envelope["submitted"] = submitted
        envelope["queued"] = queued
        envelope["delivered"] = !queued
        return .ok(envelope)
    }

    // C11-26: surface.send_key matches surface.send_text's deadlock shape
    // (v2MainSync wrap → waitForTerminalSurface → v2AwaitCallback nesting
    // CFRunLoopRun on a held main queue). Migrate it to the same Phase A /
    // Phase B pattern. See `v2SurfaceSendText` for the full rationale.
    nonisolated func v2SurfaceSendKey(params: [String: Any]) -> V2CallResult {
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        let phaseASema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var phaseAOutcome: SurfaceSendPhaseAOutcome = .err(.err(code: "internal_error", message: "Failed to send key", data: nil))
        Task { @MainActor in
            defer { phaseASema.signal() }
            phaseAOutcome = resolveSurfaceSendTargets(params: params)
        }
        phaseASema.wait()

        let resolved: SurfaceSendPhaseAResolved
        switch phaseAOutcome {
        case .err(let err):
            return err
        case .ok(let r):
            resolved = r
        }

        let resolvedSurface: ghostty_surface_t?
        if let initialSurface = resolved.initialSurface {
            resolvedSurface = initialSurface
        } else {
            resolvedSurface = waitForTerminalSurfaceOffMain(resolved.terminalPanel, waitUpTo: 2.0)
        }
        guard resolvedSurface != nil else {
            return .err(code: "internal_error", message: "Surface not ready", data: ["surface_id": resolved.surfaceIdString])
        }

        enum PhaseBOutcome {
            case ok
            case unknownKey
            case surfaceNotReady
        }
        let phaseBSema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var phaseBOutcome: PhaseBOutcome = .surfaceNotReady
        Task { @MainActor in
            defer { phaseBSema.signal() }
            // C11-26 review B2: revalidate the live surface pointer on
            // @MainActor before sendNamedKey. See v2SurfaceSendText for the
            // teardown-between-phases rationale.
            guard let liveSurface = resolved.terminalPanel.surface.surface else {
                phaseBOutcome = .surfaceNotReady
                return
            }
            if sendNamedKey(liveSurface, keyName: key) {
                resolved.terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendKey")
                phaseBOutcome = .ok
            } else {
                phaseBOutcome = .unknownKey
            }
        }
        phaseBSema.wait()

        switch phaseBOutcome {
        case .ok:
            return .ok(resolved.responseEnvelope)
        case .unknownKey:
            return .err(code: "invalid_params", message: "Unknown key", data: ["key": key])
        case .surfaceNotReady:
            return .err(code: "internal_error", message: "Surface not ready", data: ["surface_id": resolved.surfaceIdString])
        }
    }

    // C11-26: surface.clear_history doesn't have the deadlock vector (no
    // waitForTerminalSurface inside its body), but is migrated to the
    // socketWorker policy for uniformity with the rest of the surface.* family.
    // Single-phase: one Task @MainActor + DispatchSemaphore wraps the whole
    // body, no Phase B waiting.
    nonisolated func v2SurfaceClearHistory(params: [String: Any]) -> V2CallResult {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult = .err(code: "internal_error", message: "Failed to clear history", data: nil)
        Task { @MainActor in
            defer { semaphore.signal() }
            // C11-26: refresh ref handles before resolution; see
            // resolveSurfaceSendTargets for the full rationale.
            v2RefreshKnownRefs()

            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }

            guard terminalPanel.performBindingAction("clear_screen") else {
                result = .err(code: "not_supported", message: "clear_screen binding action is unavailable", data: nil)
                return
            }

            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceClearHistory")
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        semaphore.wait()
        return result
    }

    // C11-26: surface.read_text matches surface.clear_history shape — no
    // waitForTerminalSurface, no deadlock vector — migrated for uniformity.
    nonisolated func v2SurfaceReadText(params: [String: Any]) -> V2CallResult {
        var includeScrollback = v2Bool(params, "scrollback") ?? false
        let lineLimit = v2Int(params, "lines")
        if let lineLimit, lineLimit <= 0 {
            return .err(code: "invalid_params", message: "lines must be greater than 0", data: nil)
        }
        if lineLimit != nil {
            includeScrollback = true
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: V2CallResult = .err(code: "internal_error", message: "Failed to read terminal text", data: nil)
        Task { @MainActor in
            defer { semaphore.signal() }
            // C11-26: refresh ref handles before resolution; see
            // resolveSurfaceSendTargets for the full rationale.
            v2RefreshKnownRefs()

            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let response = readTerminalTextBase64(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
            guard response.hasPrefix("OK ") else {
                result = .err(code: "internal_error", message: response, data: nil)
                return
            }
            let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
            guard let text = decoded ?? (base64.isEmpty ? "" : nil) else {
                result = .err(code: "internal_error", message: "Failed to decode terminal text", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "text": text,
                "base64": base64,
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        semaphore.wait()
        return result
    }

    /// Resolve `(Workspace, surfaceId)` for M7 title bar handlers from the generic
    /// `surface_id` / `workspace_id` / focused-surface fallback.
    private func v2ResolveWorkspaceForTitleBar(params: [String: Any]) -> (Workspace, UUID)? {
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        var located: (Workspace, UUID)?
        v2MainSync {
            if let surfaceId = v2UUID(params, "surface_id") {
                if let ws = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil }) {
                    located = (ws, surfaceId)
                    return
                }
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
                  let focused = ws.focusedPanelId else { return }
            located = (ws, focused)
        }
        return located
    }

    private func v2SurfaceGetTitleBarState(params: [String: Any]) -> V2CallResult {
        guard let (ws, surfaceId) = v2ResolveWorkspaceForTitleBar(params: params) else {
            return .err(code: "surface_not_found", message: "Surface not found", data: nil)
        }
        var payload: [String: Any] = [:]
        v2MainSync { payload = ws.titleBarStatePayload(panelId: surfaceId) }
        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
        payload["workspace_id"] = ws.id.uuidString
        payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: ws.id)
        return .ok(payload)
    }

    private func v2SurfaceSetTitleBarVisibility(params: [String: Any]) -> V2CallResult {
        guard let (ws, _) = v2ResolveWorkspaceForTitleBar(params: params) else {
            return .err(code: "surface_not_found", message: "Surface not found", data: nil)
        }
        guard let visible = params["visible"] as? Bool else {
            return .err(code: "invalid_params", message: "visible (bool) required", data: nil)
        }
        v2MainSync { ws.titleBarVisible = visible }
        return .ok(["visible": visible, "workspace_id": ws.id.uuidString])
    }

    private func v2SurfaceSetTitleBarCollapsed(params: [String: Any]) -> V2CallResult {
        guard let (ws, surfaceId) = v2ResolveWorkspaceForTitleBar(params: params) else {
            return .err(code: "surface_not_found", message: "Surface not found", data: nil)
        }
        guard let collapsed = params["collapsed"] as? Bool else {
            return .err(code: "invalid_params", message: "collapsed (bool) required", data: nil)
        }
        let userInitiated = (params["user"] as? Bool) ?? false
        v2MainSync {
            ws.titleBarCollapsed[surfaceId] = collapsed
            if userInitiated && collapsed {
                ws.titleBarUserCollapsed.insert(surfaceId)
            }
            if !collapsed {
                ws.titleBarUserCollapsed.remove(surfaceId)
            }
        }
        return .ok(["collapsed": collapsed, "surface_id": surfaceId.uuidString])
    }

    /// Resolve the (workspace, surface) target for a surface-addressed command.
    ///
    /// When an explicit `surface_id` is supplied, its owning workspace is found
    /// across ALL workspaces, so a cross-workspace `surface:N` ref resolves even
    /// without `--workspace` — matching how `surface.get_metadata`/`set_metadata`
    /// and the title-bar verbs already resolve (`v2ResolveSurfaceForMetadata`,
    /// `v2ResolveWorkspaceForTitleBar`). Only when no `surface_id` is given do we
    /// fall back to the resolved/focused workspace's focused surface.
    ///
    /// Must be called on the main actor (reads TabManager/Workspace state).
    private func v2ResolveTargetSurface(
        params: [String: Any],
        tabManager: TabManager
    ) -> (workspace: Workspace, surfaceId: UUID)? {
        if let surfaceId = v2UUID(params, "surface_id") {
            guard let owner = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil }) else {
                return nil
            }
            return (owner, surfaceId)
        }
        guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager),
              let focused = ws.focusedPanelId else {
            return nil
        }
        return (ws, focused)
    }

    /// Shared not-found error for the surface-target verbs: distinguishes an
    /// explicit ref we couldn't locate from the no-surface-and-no-focus case.
    private func v2SurfaceTargetNotFound(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            return .err(code: "not_found", message: "Surface not found",
                        data: ["surface_id": surfaceId.uuidString])
        }
        return .err(code: "not_found", message: "No focused surface", data: nil)
    }

    private func v2SurfaceTriggerFlash(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        // C11-165 COR-1: trigger-flash is a surface-scoped write; an empty or
        // absent ref must not flash the operator-focused surface.
        // v2ResolveTargetSurface reads only surface_id (then falls to focus), so
        // surface_id is the granularity-pinning key — do not accept pane_id.
        if let reject = v2RejectInvalidSurfaceRef(
            params,
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        ) {
            return reject
        }

        // CMUX-10: parse + validate the optional color override off-main, before
        // hopping to the main actor. Per CLAUDE.md socket-threading policy.
        let appearance: FlashAppearance
        if let raw = params["color"] as? String {
            guard let color = FlashAppearance.parseHex(raw) else {
                return .err(
                    code: "invalid_argument",
                    message: "--color must be a hex value like #F5C518.",
                    data: ["color": raw]
                )
            }
            appearance = FlashAppearance(color: color, envelope: .paneRing)
        } else {
            appearance = FlashAppearance.current(envelope: .paneRing)
        }
        let persistent = (params["persistent"] as? Bool) ?? false

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to trigger flash", data: nil)
        v2MainSync {
            guard let (ws, surfaceId) = v2ResolveTargetSurface(params: params, tabManager: tabManager) else {
                result = v2SurfaceTargetNotFound(params: params)
                return
            }

            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            ws.triggerFocusFlash(panelId: surfaceId, appearance: appearance, persistent: persistent)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager)),
                "persistent": persistent
            ])
        }
        return result
    }

    /// CMUX-10: cancel an in-flight persistent flash on a single surface.
    /// Idempotent — succeeds even when no flash is registered (the operator
    /// or agent doesn't need to know the current state to cancel).
    private func v2SurfaceCancelFlash(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to cancel flash", data: nil)
        v2MainSync {
            guard let (ws, surfaceId) = v2ResolveTargetSurface(params: params, tabManager: tabManager) else {
                result = v2SurfaceTargetNotFound(params: params)
                return
            }

            ws.cancelPersistentFlash(panelId: surfaceId)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }
        return result
    }

    /// Resolve the (workspaceId, surfaceId) pair for a metadata call.
    /// Resolves on the main actor via `v2MainSync`; safe to call from any
    /// queue. (The earlier comment claimed "Runs off-main" — it does not;
    /// the v2 metadata handlers reach this from a main-sync hop today.)
    private func v2ResolveSurfaceForMetadata(
        params: [String: Any]
    ) -> (workspaceId: UUID, surfaceId: UUID, tabManager: TabManager)? {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return nil
        }
        return v2MainSync {
            let ws: Workspace?
            if let surfaceId = v2UUID(params, "surface_id") {
                ws = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
                guard let workspace = ws else { return nil }
                return (workspace.id, surfaceId, tabManager)
            }
            // Fallback: explicit workspace_id, then default to focused.
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return nil
            }
            if let focused = workspace.focusedPanelId {
                return (workspace.id, focused, tabManager)
            }
            return nil
        }
    }

    private func v2SurfaceSetMetadata(params: [String: Any]) -> V2CallResult {
        guard let metadataObj = params["metadata"] as? [String: Any] else {
            return .err(code: "invalid_json", message: "metadata must be a JSON object", data: nil)
        }

        let modeStr = (v2String(params, "mode") ?? "merge").lowercased()
        guard let mode = SurfaceMetadataStore.WriteMode(rawValue: modeStr) else {
            return .err(code: "invalid_mode", message: "mode must be 'merge' or 'replace'", data: nil)
        }

        let sourceStr = (v2String(params, "source") ?? "explicit").lowercased()
        guard let source = MetadataSource(rawValue: sourceStr) else {
            return .err(code: "invalid_source", message: "source must be one of: explicit, declare, osc, heuristic", data: nil)
        }
        // C11-104 v2 (B5a) — `derived` is reserved for c11-internal
        // writers. External socket/CLI clients are rejected. Without
        // this gate, an agent could write `source=derived` and claim
        // their values are system-computed, nullifying the meaning
        // of the precedence tier.
        //
        // (C11-106 AC16) Logic moved to SocketMetadataSourceValidator
        // so the rejection contract is exercised in
        // c11Tests/SocketDerivedSourceRejectionTests.swift without
        // standing up a full socket frame loop.
        if let rejection = SocketMetadataSourceValidator.externalRejectionMessage(for: source) {
            return .err(code: rejection.code, message: rejection.message, data: nil)
        }

        // C11-165 COR-1: an empty or absent surface ref must never fall back
        // to the operator-focused surface on a write. `surface_id` is the
        // granularity-pinning key (workspace_id/tab_id only reach the
        // focused-surface fallback in v2ResolveSurfaceForMetadata).
        if let reject = v2RejectInvalidSurfaceRef(
            params,
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        ) {
            return reject
        }

        guard let resolved = v2ResolveSurfaceForMetadata(params: params) else {
            return .err(code: "surface_not_found", message: "Surface not found", data: nil)
        }

        let attentionKeys = Set([
            MetadataKey.flag,
            MetadataKey.flagCallerSurfaceId,
            MetadataKey.suppressed,
        ])
        let existingAttention = SurfaceMetadataStore.shared.attentionSnapshot(
            workspaceId: resolved.workspaceId,
            surfaceId: resolved.surfaceId
        )
        if !attentionKeys.isDisjoint(with: metadataObj.keys)
            || (mode == .replace && (existingAttention.isFlagged || existingAttention.suppressed)) {
            return .err(
                code: "attention_requires_flag_method",
                message: "flag attention metadata must be changed through the flag.* methods",
                data: nil
            )
        }

        do {
            let result = try SurfaceMetadataStore.shared.setMetadata(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                partial: metadataObj,
                mode: mode,
                source: source
            )
            applyTitleDescriptionSideEffects(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                tabManager: resolved.tabManager,
                applied: result.applied,
                removedKeys: result.removedKeys,
                autoExpand: (params["auto_expand"] as? Bool) ?? true
            )
            return .ok(buildMetadataOkPayload(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                tabManager: resolved.tabManager,
                result: result
            ))
        } catch let err as SurfaceMetadataStore.WriteError {
            return .err(code: err.code, message: err.message, data: err.detailData)
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }

    private func v2SurfaceGetMetadata(params: [String: Any]) -> V2CallResult {
        let keys: [String]?
        if params["keys"] is NSNull || params["keys"] == nil {
            keys = nil
        } else if let arr = v2StringArray(params, "keys") {
            keys = arr
        } else {
            return .err(code: "invalid_keys_param", message: "keys must be an array of strings", data: nil)
        }

        let includeSources = v2Bool(params, "include_sources") ?? false

        guard let resolved = v2ResolveSurfaceForMetadata(params: params) else {
            return .err(code: "surface_not_found", message: "Surface not found", data: nil)
        }

        let (fullMetadata, fullSources) = SurfaceMetadataStore.shared.getMetadata(
            workspaceId: resolved.workspaceId,
            surfaceId: resolved.surfaceId
        )

        var metadataOut: [String: Any] = fullMetadata
        var sourcesOut: [String: [String: Any]] = fullSources
        if let filterKeys = keys {
            metadataOut = [:]
            sourcesOut = [:]
            for k in filterKeys {
                if let v = fullMetadata[k] { metadataOut[k] = v }
                if let s = fullSources[k] { sourcesOut[k] = s }
            }
        }

        var payload: [String: Any] = [
            "workspace_id": resolved.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: resolved.workspaceId),
            "surface_id": resolved.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: resolved.surfaceId),
            "metadata": metadataOut
        ]
        if includeSources {
            payload["metadata_sources"] = sourcesOut
        }
        return .ok(payload)
    }

    private func v2SurfaceClearMetadata(params: [String: Any]) -> V2CallResult {
        let keys: [String]?
        if params["keys"] == nil || params["keys"] is NSNull {
            keys = nil
        } else if let arr = v2StringArray(params, "keys") {
            keys = arr
        } else {
            return .err(code: "invalid_keys_param", message: "keys must be an array of strings", data: nil)
        }

        let sourceStr = (v2String(params, "source") ?? "explicit").lowercased()
        guard let source = MetadataSource(rawValue: sourceStr) else {
            return .err(code: "invalid_source", message: "source must be one of: explicit, declare, osc, heuristic", data: nil)
        }
        // C11-104 v2 (B5a) — `derived` is reserved for c11-internal
        // writers. External socket/CLI clients are rejected. Without
        // this gate, an agent could write `source=derived` and claim
        // their values are system-computed, nullifying the meaning
        // of the precedence tier.
        //
        // (C11-106 AC16) Logic moved to SocketMetadataSourceValidator
        // so the rejection contract is exercised in
        // c11Tests/SocketDerivedSourceRejectionTests.swift without
        // standing up a full socket frame loop.
        if let rejection = SocketMetadataSourceValidator.externalRejectionMessage(for: source) {
            return .err(code: rejection.code, message: rejection.message, data: nil)
        }

        // C11-165 COR-1: reject empty/absent surface refs on this write;
        // never fall back to the operator-focused surface.
        if let reject = v2RejectInvalidSurfaceRef(
            params,
            targetKeys: ["surface_id", "workspace_id", "tab_id"],
            requiredAnyOf: ["surface_id"]
        ) {
            return reject
        }

        guard let resolved = v2ResolveSurfaceForMetadata(params: params) else {
            return .err(code: "surface_not_found", message: "Surface not found", data: nil)
        }

        let attentionKeys = Set([
            MetadataKey.flag,
            MetadataKey.flagCallerSurfaceId,
            MetadataKey.suppressed,
        ])
        let existingAttention = SurfaceMetadataStore.shared.attentionSnapshot(
            workspaceId: resolved.workspaceId,
            surfaceId: resolved.surfaceId
        )
        if keys.map({ !attentionKeys.isDisjoint(with: $0) })
            ?? (existingAttention.isFlagged || existingAttention.suppressed) {
            return .err(
                code: "attention_requires_flag_method",
                message: "flag attention metadata must be changed through the flag.* methods",
                data: nil
            )
        }

        do {
            let result = try SurfaceMetadataStore.shared.clearMetadata(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                keys: keys,
                source: source
            )
            applyTitleDescriptionSideEffects(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                tabManager: resolved.tabManager,
                applied: result.applied,
                removedKeys: result.removedKeys,
                autoExpand: false
            )
            return .ok(buildMetadataOkPayload(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                tabManager: resolved.tabManager,
                result: result
            ))
        } catch let err as SurfaceMetadataStore.WriteError {
            return .err(code: err.code, message: err.message, data: err.detailData)
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }
}
