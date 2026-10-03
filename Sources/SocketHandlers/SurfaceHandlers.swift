import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

private enum TerminalSelectionCapture {
    case success(bytes: Data, originalCount: Int, hasSelection: Bool, routing: [String: Any])
    case failure(TerminalController.V2CallResult)
}

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    private static let seenTimestampFormatter = ISO8601DateFormatter()

    /// C11-243: set `last_seen_at` (ISO-8601 to the second, "now" while being
    /// seen, null if never seen) and `being_seen` on a surface item. Main-actor
    /// read; formats one timestamp string per surface, with a shared formatter.
    func v2SetSeenFields(_ item: inout [String: Any], panelId: UUID) {
        let tracker = TabSeenTracker.shared
        item["last_seen_at"] = tracker.lastSeenAt(panelId: panelId)
            .map { Self.seenTimestampFormatter.string(from: $0) } ?? NSNull()
        item["being_seen"] = tracker.isBeingSeen(panelId: panelId)
    }

    /// v2 dispatch slice for the `surface.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchSurface(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "tab.list":
            return v2Result(id: id, self.v2SurfaceList(params: params))
        case "tab.current":
            return v2Result(id: id, self.v2SurfaceCurrent(params: params))
        case "tab.set_custom_color":
            return v2Result(id: id, self.v2SurfaceSetCustomColor(params: params))
        case "tab.focus":
            return v2Result(id: id, self.v2SurfaceFocus(params: params))
        case "tab.split":
            return v2Result(id: id, self.v2SurfaceSplit(params: params))
        case "tab.create":
            return v2Result(id: id, self.v2SurfaceCreate(params: params))
        case "tab.close":
            return v2Result(id: id, self.v2RejectUnresolvedTargetRefs(params) ?? self.v2SurfaceClose(params: params))
        case "tab.move":
            return v2Result(id: id, self.v2SurfaceMove(params: params))
        case "tab.reorder":
            return v2Result(id: id, self.v2SurfaceReorder(params: params))
        case "tab.drag_to_split":
            return v2Result(id: id, self.v2SurfaceDragToSplit(params: params))
        case "tab.refresh":
            return v2Result(id: id, self.v2SurfaceRefresh(params: params))
        case "tab.health":
            return v2Result(id: id, self.v2SurfaceHealth(params: params))
        case "tab.trigger_flash":
            return v2Result(id: id, self.v2SurfaceTriggerFlash(params: params))
        case "tab.cancel_flash":
            return v2Result(id: id, self.v2SurfaceCancelFlash(params: params))
        case "tab.set_metadata":
            return v2Result(id: id, self.v2SurfaceSetMetadata(params: params))
        case "tab.get_metadata":
            return v2Result(id: id, self.v2SurfaceGetMetadata(params: params))
        case "tab.clear_metadata":
            return v2Result(id: id, self.v2SurfaceClearMetadata(params: params))
        case "tab.get_titlebar_state":
            return v2Result(id: id, self.v2SurfaceGetTitleBarState(params: params))
        case "tab.set_titlebar_visibility":
            return v2Result(id: id, self.v2SurfaceSetTitleBarVisibility(params: params))
        case "tab.set_titlebar_collapsed":
            return v2Result(id: id, self.v2SurfaceSetTitleBarCollapsed(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2SurfaceList(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else { return }

            // Map panel_id -> pane_id and index/selection within that pane.
            var paneByPanelId: [UUID: UUID] = [:]
            var indexInPaneByPanelId: [UUID: Int] = [:]
            var selectedInPaneByPanelId: [UUID: Bool] = [:]
            for paneId in ws.bonsplitController.allPaneIds {
                let bonsplitTabs = ws.bonsplitController.tabs(inPane: paneId)
                let selected = ws.bonsplitController.selectedTab(inPane: paneId)
                for (idx, bonsplitTab) in bonsplitTabs.enumerated() {
                    guard let panelId = ws.tabIdFromBonsplitTabId(bonsplitTab.id) else { continue }
                    paneByPanelId[panelId] = paneId.id
                    indexInPaneByPanelId[panelId] = idx
                    selectedInPaneByPanelId[panelId] = (bonsplitTab.id == selected?.id)
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
                    "title": ws.tabTitle(panelId: panel.id) ?? panel.displayTitle,
                    "focused": panel.id == focusedSurfaceId,
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                    "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id]),
                    "tty": v2OrNull(ws.tabTTYNames[panel.id]),
                    "custom_color": v2OrNull(ws.tabCustomColor(panelId: panel.id))
                ]
                v2SetSeenFields(&item, panelId: panel.id)
                if let browserTab = panel as? BrowserTab {
                    item["developer_tools_visible"] = browserTab.isDeveloperToolsVisible()
                    item["profile_id"] = browserTab.profileID.uuidString
                }
                if let markdownTab = panel as? MarkdownTab {
                    item["file_path"] = markdownTab.filePath
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
                    let sample = TabMetricsSampler.shared.sample(forSurfaceId: panel.id)
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
                "tabs": surfaces,
                "surfaces": surfaces
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        var out = payload
        let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
        out["window_id"] = v2OrNull(windowId?.uuidString)
        out["window_ref"] = v2Ref(kind: .window, uuid: windowId)
        return .ok(out)
    }

    private func v2SurfaceCurrent(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else { return }

            // Focus can be transiently nil during startup/reparenting; fall back to first
            // ordered panel so callers always get a usable current surface.
            let surfaceId = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
            let paneId = surfaceId.flatMap { ws.paneId(forPanelId: $0)?.id }
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)

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
                "custom_color": v2OrNull(surfaceId.flatMap { ws.tabCustomColor(panelId: $0) })
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    private func v2SurfaceSetCustomColor(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid tab_id", data: nil)
        }

        let clear = (params["clear"] as? Bool) ?? false
        let hex = params["hex"] as? String

        if !clear && hex == nil {
            return .err(code: "invalid_params", message: "Provide either 'hex' or 'clear=true'", data: nil)
        }
        if clear && hex != nil {
            return .err(code: "invalid_params", message: "'clear' and 'hex' are mutually exclusive", data: nil)
        }
        if !clear, let hex, WorkspaceColorSettings.normalizedHex(hex) == nil {
            return .err(code: "invalid_params", message: "Invalid hex color (use #RRGGBB)", data: ["hex": hex])
        }

        var applied: String? = nil
        var workspaceUUID: UUID? = nil
        var found = false
        v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else { return }
            guard workspace.panels[surfaceId] != nil else { return }
            workspaceUUID = workspace.id
            found = true
            if clear {
                workspace.setTabCustomColor(panelId: surfaceId, color: nil)
                applied = nil
            } else if let hex {
                workspace.setTabCustomColor(panelId: surfaceId, color: hex)
                applied = workspace.tabCustomColor(panelId: surfaceId)
            }
        }

        guard found else {
            return .err(code: "not_found", message: "Tab not found", data: [
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
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid tab_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Tab not found", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }



            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            ws.focusPanel(surfaceId)
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager))])
        }
        return result
    }

    /// Validate startup input before any layout or terminal mutation. Admission
    /// shares the advertised capability policy; absent/blank input stays inert.
    func v2ResolveCreateInitialInput(
        params: [String: Any],
        panelType: String? = nil,
        hasLayout: Bool = false,
        resolved: inout String?
    ) -> V2CallResult? {
        resolved = nil
        if let raw = params["initial_input"], !(raw is String) {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.create.initialInput.invalidType", defaultValue: "initial_input must be a string"),
                data: nil
            )
        }
        let decision = CreateInitialInput.decide(
            raw: params["initial_input"] as? String, panelType: panelType, hasLayout: hasLayout
        )
        if let message = decision.errorMessage(panelType: panelType) {
            return .err(code: "invalid_params", message: message, data: nil)
        }
        guard let input = decision.queuedInput else { return nil }
        do {
            resolved = try CapabilityFeatures.current.dispatch(.initialInput) { input }
            return nil
        } catch {
            return .err(
                code: "unavailable",
                message: String(localized: "socket.create.initialInput.unavailable", defaultValue: "create.initial_input is unavailable"),
                data: ["feature": CapabilityFeatures.ID.initialInput.rawValue]
            )
        }
    }

    func v2SurfaceSplit(params: [String: Any]) -> V2CallResult {
        v2RefreshKnownRefs()
        if let error = v2RejectUnresolvedTargetRefs(params) { return error }
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }
        let titleSeed = v2String(params, "title")
        let force = splitForceFlag(params)
        var initialInput: String?
        if let error = v2ResolveCreateInitialInput(params: params, panelType: "terminal", resolved: &initialInput) {
            return error
        }

        // Validate the optional --cwd override server-side before spawning so a
        // bad path returns a clear error instead of silently landing in $HOME.
        var cwdOverride: String?
        if let err = v2ResolveCwdParam(params, resolved: &cwdOverride) {
            return err
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create split", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let targetSurfaceId: UUID? = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let targetSurfaceId else {
                result = .err(code: "not_found", message: "No focused tab", data: nil)
                return
            }
            guard ws.panels[targetSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: ["surface_id": targetSurfaceId.uuidString])
                return
            }

            v2MaybeFocusWindow(for: workspaceManager)
            v2MaybeSelectWorkspace(workspaceManager, workspace: ws)

            // new-split always creates a terminal.
            let plan = self.planSizeAwareSplit(ws: ws, sourcePanelId: targetSurfaceId, requested: direction, newIsTerminal: true, force: force)
            switch plan {
            case .refuse(let message, let data):
                result = .err(code: "pane_too_small", message: message, data: data)

            case .tab(let paneId, let warning):
                guard let panel = ws.newTerminalSurface(inPane: paneId, focus: self.v2FocusAllowed(), workingDirectory: cwdOverride, initialInput: initialInput) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                self.v2SeedPaneTitle(workspaceId: ws.id, paneUUID: paneId.id, title: titleSeed)
                let windowId = self.v2ResolveWindowId(workspaceManager: workspaceManager)
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
                if initialInput != nil { ok["initial_input"] = "queued" }
                self.annotateSizeOutcome(&ok, requested: direction, applied: direction, becameTab: true, warning: warning)
                result = .ok(ok)

            case .split(let actualDirection, let requested, let warning):
                if let newId = workspaceManager.newSplit(workspaceId: ws.id, surfaceId: targetSurfaceId, direction: actualDirection, workingDirectory: cwdOverride, initialInput: initialInput) {
                    let paneUUID = ws.paneId(forPanelId: newId)?.id
                    // Seed pane title atomic with pane id becoming valid.
                    self.v2SeedPaneTitle(workspaceId: ws.id, paneUUID: paneUUID, title: titleSeed)
                    let windowId = self.v2ResolveWindowId(workspaceManager: workspaceManager)
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
                    if initialInput != nil { ok["initial_input"] = "queued" }
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
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let panelType = v2PanelType(params, "type") ?? .terminal
        if let denial = v2SurfaceTypeDenial(panelType) { return denial }
        var initialInput: String?
        if let error = v2ResolveCreateInitialInput(params: params, panelType: panelType.rawValue, resolved: &initialInput) {
            return error
        }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let filePath = v2String(params, "file")
        let hasProfileArgument = params.keys.contains("profile")
        if hasProfileArgument, panelType != .browser {
            return .err(
                code: "invalid_params",
                message: String(localized: "browser.profile.error.browserOnly", defaultValue: "--profile is only valid for browser tabs"),
                data: nil
            )
        }

        // Validate and resolve markdown file path
        var resolvedMarkdownPath: String?
        if panelType == .markdown {
            if let err = v2ValidateMarkdownPath(filePath, context: "surface", resolved: &resolvedMarkdownPath) {
                return err
            }
        }

        // Optional --cwd: validated off-main so a bad path errors instead of
        // landing elsewhere. Omitted (or `inherit`) takes the workspace's
        // new-surface rule: root, then the pane's terminal cwd, then home.
        var cwdOverride: String?
        if let err = v2ResolveCwdParam(params, resolved: &cwdOverride) {
            return err
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create tab", data: nil)
        guard v2MainSyncWithDeadline({
            guard let ws = self.v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            var preferredProfileID: UUID?
            var sticksAsPreferred = true
            switch self.v2ResolveBrowserProfileParam(params: params) {
            case .none:
                break
            case .error(let error):
                result = error
                return
            case .profile(let profile):
                guard !ws.isRemoteWorkspace else {
                    result = .err(code: "invalid_params", message: String(localized: "browser.profile.error.remoteUnsupported", defaultValue: "Browser profiles are not supported in remote workspaces"), data: nil)
                    return
                }
                guard !BrowserProfileStore.shared.isReserved(profile.id) else {
                    result = self.v2BrowserProfileError(.busy)
                    return
                }
                preferredProfileID = profile.id
                sticksAsPreferred = false
            }
            // Caller may pass focus: false to opt out of focus (--no-focus in CLI).
            // surface.create is NOT in focusIntentV2Methods, so v2FocusAllowed returns false
            // regardless of callerWantsFocus. The focus param is accepted for forward-compatibility
            // if surface.create is added to focusIntentV2Methods in the future.
            let callerWantsFocus = self.v2Bool(params, "focus") ?? true
            let focus = self.v2FocusAllowed(requested: callerWantsFocus)
            if focus {
                self.v2MaybeFocusWindow(for: workspaceManager)
                self.v2MaybeSelectWorkspace(workspaceManager, workspace: ws)
            }

            let paneUUID = self.v2UUID(params, "pane_id")
            let paneId: PaneID? = {
                if let paneUUID {
                    return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                }
                return ws.bonsplitController.focusedPaneId
            }()

            guard let paneId else {
                result = .err(code: "not_found", message: "Area not found", data: nil)
                return
            }

            let newPanelId: UUID?
            switch panelType {
            case .browser:
                newPanelId = ws.newBrowserSurface(
                    inPane: paneId,
                    url: url,
                    focus: focus,
                    preferredProfileID: preferredProfileID,
                    sticksAsPreferred: sticksAsPreferred
                )?.id
            case .markdown:
                newPanelId = ws.newMarkdownTab(inPane: paneId, filePath: resolvedMarkdownPath!, focus: focus)?.id
            case .terminal:
                newPanelId = ws.newTerminalSurface(inPane: paneId, focus: focus, workingDirectory: cwdOverride, initialInput: initialInput)?.id
            }

            guard let newPanelId else {
                result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                return
            }

            let windowId = self.v2ResolveWindowId(workspaceManager: workspaceManager)
            var ok: [String: Any] = [
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneId.id.uuidString,
                "pane_ref": self.v2Ref(kind: .pane, uuid: paneId.id),
                "surface_id": newPanelId.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: newPanelId),
                "type": panelType.rawValue
            ]
            if let browserProfileID = ws.browserPanel(for: newPanelId)?.profileID {
                ok["profile_id"] = browserProfileID.uuidString
            }
            if initialInput != nil { ok["initial_input"] = "queued" }
            result = .ok(ok)
        }) != nil else {
            return .err(code: "main_thread_timeout", message: "main thread did not respond within deadline", data: nil)
        }
        return result
    }

    private func v2SurfaceClose(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to close tab", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused tab", data: nil)
                return
            }

            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last tab", data: nil)
                return
            }

            // Socket API must be non-interactive: bypass close-confirmation gating.
            ws.closeTab(surfaceId, force: true)
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager))])
        }
        return result
    }

    private func v2SurfaceDragToSplit(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid tab_id", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }

        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
        let insertFirst = (direction == .left || direction == .up)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move tab", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let bonsplitTabId = ws.bonsplitTabIdFromTabId(surfaceId) else {
                result = .err(code: "not_found", message: "Tab not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let newPaneId = ws.bonsplitController.splitPane(
                orientation: orientation,
                movingTab: bonsplitTabId,
                insertFirst: insertFirst
            ) else {
                result = .err(code: "internal_error", message: "Failed to split area", data: nil)
                return
            }
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
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
            return .err(code: "invalid_params", message: "Missing or invalid tab_id", data: nil)
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
            return .err(code: "invalid_params", message: "Specify at most one of before_tab_id or after_tab_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move tab", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared else {
                result = .err(code: "unavailable", message: "AppDelegate not available", data: nil)
                return
            }

            guard let source = app.locateSurface(surfaceId: surfaceId),
                  let sourceWorkspace = source.workspaceManager.workspaces.first(where: { $0.id == source.workspaceId }) else {
                result = .err(code: "not_found", message: "Tab not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let sourcePane = sourceWorkspace.paneId(forPanelId: surfaceId)
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)

            var targetWindowId = source.windowId
            var targetWorkspaceManager = source.workspaceManager
            var targetWorkspace = sourceWorkspace
            var targetPane = sourcePane ?? sourceWorkspace.bonsplitController.focusedPaneId ?? sourceWorkspace.bonsplitController.allPaneIds.first
            var targetIndex = explicitIndex

            if let anchorSurfaceId = beforeSurfaceId ?? afterSurfaceId {
                guard let anchor = app.locateSurface(surfaceId: anchorSurfaceId),
                      let anchorWorkspace = anchor.workspaceManager.workspaces.first(where: { $0.id == anchor.workspaceId }),
                      let anchorPane = anchorWorkspace.paneId(forPanelId: anchorSurfaceId),
                      let anchorIndex = anchorWorkspace.indexInPane(forPanelId: anchorSurfaceId) else {
                    result = .err(code: "not_found", message: "Anchor tab not found", data: ["surface_id": anchorSurfaceId.uuidString])
                    return
                }
                targetWindowId = anchor.windowId
                targetWorkspaceManager = anchor.workspaceManager
                targetWorkspace = anchorWorkspace
                targetPane = anchorPane
                targetIndex = (beforeSurfaceId != nil) ? anchorIndex : (anchorIndex + 1)
            } else if let paneUUID = requestedPaneUUID {
                guard let located = v2LocatePane(paneUUID) else {
                    result = .err(code: "not_found", message: "Area not found", data: ["pane_id": paneUUID.uuidString])
                    return
                }
                targetWindowId = located.windowId
                targetWorkspaceManager = located.workspaceManager
                targetWorkspace = located.workspace
                targetPane = located.paneId
            } else if let workspaceUUID = requestedWorkspaceUUID {
                guard let tm = app.workspaceManagerFor(workspaceId: workspaceUUID),
                      let ws = tm.workspaces.first(where: { $0.id == workspaceUUID }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceUUID.uuidString])
                    return
                }
                targetWorkspaceManager = tm
                targetWorkspace = ws
                targetWindowId = app.windowId(for: tm) ?? targetWindowId
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            } else if let windowUUID = requestedWindowUUID {
                guard let tm = app.workspaceManagerFor(windowId: windowUUID) else {
                    result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWindowId = windowUUID
                targetWorkspaceManager = tm
                guard let selectedWorkspaceId = tm.selectedWorkspaceId,
                      let ws = tm.workspaces.first(where: { $0.id == selectedWorkspaceId }) else {
                    result = .err(code: "not_found", message: "Target window has no selected workspace", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWorkspace = ws
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            }

            guard let destinationPane = targetPane else {
                result = .err(code: "not_found", message: "No destination area", data: nil)
                return
            }

            if targetWorkspace.id == sourceWorkspace.id {
                guard sourceWorkspace.moveSurface(panelId: surfaceId, toPane: destinationPane, atIndex: targetIndex, focus: focus) else {
                    result = .err(code: "internal_error", message: "Failed to move tab", data: nil)
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

            guard let transfer = sourceWorkspace.detachTab(panelId: surfaceId) else {
                result = .err(code: "internal_error", message: "Failed to detach tab", data: nil)
                return
            }

            if targetWorkspace.attachDetachedTab(transfer, inPane: destinationPane, atIndex: targetIndex, focus: focus) == nil {
                // Roll back to source workspace if attach fails.
                let rollbackPane = sourcePane.flatMap { sp in sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0 == sp }) }
                    ?? sourceWorkspace.bonsplitController.focusedPaneId
                    ?? sourceWorkspace.bonsplitController.allPaneIds.first
                if let rollbackPane {
                    _ = sourceWorkspace.attachDetachedTab(transfer, inPane: rollbackPane, atIndex: sourceIndex, focus: focus)
                }
                result = .err(code: "internal_error", message: "Failed to attach tab to destination", data: nil)
                return
            }

            if focus {
                _ = app.focusMainWindow(windowId: targetWindowId)
                setActiveWorkspaceManager(targetWorkspaceManager)
                targetWorkspaceManager.selectWorkspace(targetWorkspace)
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
            return .err(code: "invalid_params", message: "Missing or invalid tab_id", data: nil)
        }

        let index = v2Int(params, "index")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let targetCount = (index != nil ? 1 : 0) + (beforeSurfaceId != nil ? 1 : 0) + (afterSurfaceId != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(code: "invalid_params", message: "Specify exactly one of index, before_tab_id, or after_tab_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to reorder tab", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared,
                  let located = app.locateSurface(surfaceId: surfaceId),
                  let ws = located.workspaceManager.workspaces.first(where: { $0.id == located.workspaceId }),
                  let sourcePane = ws.paneId(forPanelId: surfaceId) else {
                result = .err(code: "not_found", message: "Tab not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let targetIndex: Int
            if let index {
                targetIndex = index
            } else if let beforeSurfaceId {
                guard let anchorPane = ws.paneId(forPanelId: beforeSurfaceId),
                      anchorPane == sourcePane,
                      let anchorIndex = ws.indexInPane(forPanelId: beforeSurfaceId) else {
                    result = .err(code: "invalid_params", message: "Anchor tab must be in the same area", data: nil)
                    return
                }
                targetIndex = anchorIndex
            } else if let afterSurfaceId {
                guard let anchorPane = ws.paneId(forPanelId: afterSurfaceId),
                      anchorPane == sourcePane,
                      let anchorIndex = ws.indexInPane(forPanelId: afterSurfaceId) else {
                    result = .err(code: "invalid_params", message: "Anchor tab must be in the same area", data: nil)
                    return
                }
                targetIndex = anchorIndex + 1
            } else {
                result = .err(code: "invalid_params", message: "Missing reorder target", data: nil)
                return
            }

            guard ws.reorderSurface(panelId: surfaceId, toIndex: targetIndex) else {
                result = .err(code: "internal_error", message: "Failed to reorder tab", data: nil)
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
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .ok(["refreshed": 0])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            var refreshedCount = 0
            for panel in ws.panels.values {
                if let terminalTab = panel as? TerminalTab {
                    terminalTab.surface.forceRefresh(reason: "terminalController.v2SurfaceRefresh")
                    refreshedCount += 1
                }
            }
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
            result = .ok(["window_id": v2OrNull(windowId?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowId), "workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "refreshed": refreshedCount])
        }
        return result
    }

    private func v2SurfaceHealth(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else { return }
            let panels = orderedPanels(in: ws)
            let items: [[String: Any]] = panels.enumerated().map { index, panel in
                var inWindow: Any = NSNull()
                if let tp = panel as? TerminalTab {
                    inWindow = tp.surface.isViewInWindow
                } else if let bp = panel as? BrowserTab {
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
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "tabs": items,
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
        let preserveNewlines = v2Bool(params, "preserve_newlines") ?? false
        if preserveNewlines {
            // Raw admission and capabilities discovery consume the same policy.
            // Validate off-main before resolving a target or queueing any bytes.
            guard CapabilityFeatures.current.supports(.rawSend) else {
                return .err(code: "unsupported_feature", message: String(
                    localized: "socket.send.raw_unavailable", defaultValue: "Raw/paste delivery is unavailable."
                ), data: ["feature": CapabilityFeatures.ID.rawSend.rawValue])
            }
            guard !text.isEmpty else {
                return .err(code: "invalid_params", message: String(
                    localized: "cli.send.text_required", defaultValue: "send requires text"
                ), data: nil)
            }
        }

        let phaseASema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var phaseAOutcome: TabSendPhaseAOutcome = .err(.err(code: "internal_error", message: "Failed to send text", data: nil))
        Task { @MainActor in
            defer { phaseASema.signal() }
            phaseAOutcome = resolveSurfaceSendTargets(params: params)
        }
        phaseASema.wait()

        let resolved: TabSendPhaseAResolved
        switch phaseAOutcome {
        case .err(let err):
            return err
        case .ok(let r):
            resolved = r
        }

        #if DEBUG
        let sendStart = ProcessInfo.processInfo.systemUptime
        #endif

        if resolved.initialSurface == nil {
            // This pointer is only a readiness indication. Phase B re-reads the
            // exact tab and its live surface on main before capture or delivery.
            _ = waitForTerminalSurfaceOffMain(resolved.terminalPanel, waitUpTo: 2.0)
        }

        // C11-173: what actually happened, for an honest response. `submitted`
        // is the effective submit (a trailing newline in the payload means Enter
        // even when `submit` is false, unless preserve_newlines keeps it as
        // content); `queued` means the surface had no PTY, so
        // nothing has reached the target yet and the payload flushes on attach.
        nonisolated(unsafe) var queued = false
        nonisolated(unsafe) var submitted = false
        let wantsReturn = SendTextDelivery(text, submit: submit, preserveNewlines: preserveNewlines).wantsReturn
        let allowUnguarded = v2Bool(params, "allow_unguarded") ?? false
        nonisolated(unsafe) var phaseBFields: [String: Any] = [:]
        nonisolated(unsafe) var phaseBError: V2CallResult?
        let phaseBSema = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { phaseBSema.signal() }
            let targetIsCurrent = SendInputGuard.targetIsCurrent(
                expectedWorkspace: resolved.workspace,
                currentWorkspaces: resolved.workspaceManager.workspaces,
                expectedTab: resolved.terminalPanel,
                currentTab: resolved.workspace.terminalPanel(for: resolved.tabId)
            )
            let liveSurface = targetIsCurrent ? resolved.terminalPanel.surface.surface : nil
            let observation: PromptInputObservation
            if !targetIsCurrent {
                observation = .unavailable
            } else if let liveSurface, let region = capturePromptInputRegion(surface: liveSurface) {
                observation = .activeScreen(region)
            } else {
                // A cold live exact tab and a busy/unavailable capture preserve
                // today's queue/delivery behavior, with the uncertainty exposed.
                observation = .unknown
            }

            let decision = SendInputGuard.perform(
                state: observation.classification.state,
                allowUnguarded: allowUnguarded,
                targetAvailable: targetIsCurrent
            ) {
                if let liveSurface {
                    submitted = deliverSocketSendText(
                        text,
                        submit: submit,
                        preserveNewlines: preserveNewlines,
                        terminalSurface: resolved.terminalPanel.surface,
                        surface: liveSurface
                    )
                    resolved.terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendText")
                } else {
                    // Use the same submit helper as attached delivery so a
                    // queued Return is dispatched after the bracketed paste.
                    resolved.terminalPanel.surface.sendQueuedSocketText(
                        text, submit: submit, preserveNewlines: preserveNewlines
                    )
                    submitted = wantsReturn
                    queued = true
                }
            }

            switch decision {
            case .unavailable:
                var data = observation.responseFields
                data["reason"] = "target_unavailable"
                phaseBError = .err(
                    code: "not_found",
                    message: String(localized: "socket.send.target_unavailable", defaultValue: "Target tab is no longer available."),
                    data: data
                )
            case .refuse(let reason):
                var data = observation.responseFields
                data["input_guard"] = SendInputGuardStatus.refused.rawValue
                data["reason"] = reason
                phaseBError = .err(
                    code: "input_guard_refused",
                    message: String(format: String(
                        localized: "socket.send.guard_refused",
                        defaultValue: "Input guard refused the send because a %@ is present. Nothing was sent; do not press Enter. If the operator is mid-draft, raise a flag (c11 raise-flag) instead of retrying."
                    ), reason),
                    data: data
                )
            case .deliver(let status):
                phaseBFields = observation.responseFields
                phaseBFields["input_guard"] = status.rawValue
            }
        }
        phaseBSema.wait()
        if let phaseBError { return phaseBError }

        #if DEBUG
        let sendMs = (ProcessInfo.processInfo.systemUptime - sendStart) * 1000.0
        dlog(
            "socket.surface.send_text workspace=\(resolved.workspaceIdString.prefix(8)) surface=\(resolved.tabIdString.prefix(8)) queued=\(queued ? 1 : 0) chars=\(text.count) ms=\(String(format: "%.2f", sendMs))"
        )
        #endif

        var envelope = resolved.responseEnvelope
        envelope["submitted"] = submitted
        envelope["queued"] = queued
        envelope["delivered"] = !queued
        for (key, value) in phaseBFields { envelope[key] = value }
        EventEmitter.shared.emitTabInputSent(
            workspace: resolved.workspaceId,
            surface: resolved.tabId,
            callerTabId: resolved.callerTabId,
            callerTitle: resolved.callerTitle,
            targetTitle: resolved.targetTitle,
            kind: "text",
            text: text,
            submitted: submitted,
            queued: queued
        )
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
        nonisolated(unsafe) var phaseAOutcome: TabSendPhaseAOutcome = .err(.err(code: "internal_error", message: "Failed to send key", data: nil))
        Task { @MainActor in
            defer { phaseASema.signal() }
            phaseAOutcome = resolveSurfaceSendTargets(params: params)
        }
        phaseASema.wait()

        let resolved: TabSendPhaseAResolved
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
            return .err(code: "internal_error", message: "Tab not ready", data: ["surface_id": resolved.tabIdString])
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
            guard resolved.terminalPanel.surface.surface != nil else {
                phaseBOutcome = .surfaceNotReady
                return
            }
            guard TerminalController.namedKeyEvent(for: key) != nil else {
                phaseBOutcome = .unknownKey
                return
            }
            // An input transaction like every programmatic writer: a key sent
            // while another writer's paste-then-Return is in flight waits for
            // it instead of landing inside it.
            let terminalSurface = resolved.terminalPanel.surface
            terminalSurface.performInputTransaction { [weak self, weak terminalSurface] finish in
                defer { finish() }
                guard let self, let terminalSurface, let liveSurface = terminalSurface.surface else { return }
                _ = self.sendNamedKey(liveSurface, keyName: key, stillLive: { [weak terminalSurface] in terminalSurface?.surface })
                terminalSurface.forceRefresh(reason: "terminalController.v2SurfaceSendKey")
            }
            phaseBOutcome = .ok
        }
        phaseBSema.wait()

        switch phaseBOutcome {
        case .ok:
            EventEmitter.shared.emitTabInputSent(
                workspace: resolved.workspaceId,
                surface: resolved.tabId,
                callerTabId: resolved.callerTabId,
                callerTitle: resolved.callerTitle,
                targetTitle: resolved.targetTitle,
                kind: "key",
                text: key,
                submitted: TerminalController.namedKeySubmits(key)
            )
            return .ok(resolved.responseEnvelope)
        case .unknownKey:
            return .err(code: "invalid_params", message: "Unknown key", data: ["key": key])
        case .surfaceNotReady:
            return .err(code: "internal_error", message: "Tab not ready", data: ["surface_id": resolved.tabIdString])
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
            if let rejection = v2RejectUnresolvedTargetRefs(params) {
                result = rejection
                return
            }

            guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused tab", data: nil)
                return
            }
            guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Tab is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }

            guard terminalPanel.performBindingAction("clear_screen") else {
                result = .err(code: "not_supported", message: "clear_screen binding action is unavailable", data: nil)
                return
            }

            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceClearHistory")
            let windowId = v2ResolveWindowId(workspaceManager: workspaceManager)
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

    /// Surface teardown is serialized on main, so try-lock and bounded native
    /// copying stay in one main turn. Caller-owned buffers need no native free;
    /// classification runs on this socket worker after the capture completes.
    nonisolated func v2SurfaceInputState(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.terminalInputState) else {
            return .err(code: "not_supported", message: String(localized: "socket.input_state.unsupported", defaultValue: "Terminal input-state inspection is unavailable."), data: nil)
        }
        guard let tabRef = params["surface_id"] as? String,
              !tabRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: String(localized: "socket.input_state.tab_required", defaultValue: "A tab identifier is required."), data: nil)
        }

        typealias Capture = (PromptRegionSnapshot?, [String: Any])
        let operation = SelectionReadOperation<Result<Capture, V2CallResult>>()
        Task { @MainActor in
            guard operation.beginCapture() else { return }
            switch resolveSurfaceSendTargets(params: params) {
            case .err(let error):
                var data = PromptInputClassification(state: .unavailable, draftLength: nil)
                    .responseFields(source: nil, observedAtMs: nil)
                let code: String
                let message: String
                switch error {
                case .err(let errorCode, let errorMessage, _):
                    code = errorCode
                    message = errorMessage
                case .ok(_):
                    code = "internal_error"
                    message = "Surface target resolution returned success without a resolved target."
                }
                data["target_error"] = code
                operation.complete(.failure(.err(code: code, message: message, data: data)))
            case .ok(let resolved):
                guard SendInputGuard.targetIsCurrent(
                    expectedWorkspace: resolved.workspace,
                    currentWorkspaces: resolved.workspaceManager.workspaces,
                    expectedTab: resolved.terminalPanel,
                    currentTab: resolved.workspace.terminalPanel(for: resolved.tabId)
                ) else {
                    let data = PromptInputClassification(state: .unavailable, draftLength: nil)
                        .responseFields(source: nil, observedAtMs: nil)
                    operation.complete(.failure(.err(
                        code: "not_found",
                        message: String(localized: "socket.send.target_unavailable", defaultValue: "Target tab is no longer available."),
                        data: data
                    )))
                    return
                }
                let snapshot = resolved.terminalPanel.surface.surface.flatMap {
                    capturePromptInputRegion(surface: $0)
                }
                operation.complete(.success((snapshot, resolved.responseEnvelope)))
            }
        }

        guard let result = operation.wait() else {
            return .err(code: "timeout", message: String(localized: "socket.input_state.timeout", defaultValue: "Terminal input-state inspection timed out."), data: nil)
        }
        switch result {
        case .failure(let error):
            return operation.canPublish ? error : .err(
                code: "timeout", message: String(localized: "socket.input_state.timeout", defaultValue: "Terminal input-state inspection timed out."), data: nil
            )
        case .success(let (snapshot, routing)):
            let observation = snapshot.map(PromptInputObservation.activeScreen) ?? .unavailable
            var payload = routing
            for (key, value) in observation.responseFields { payload[key] = value }
            guard operation.canPublish else {
                return .err(code: "timeout", message: String(localized: "socket.input_state.timeout", defaultValue: "Terminal input-state inspection timed out."), data: nil)
            }
            return .ok(payload)
        }
    }

    nonisolated func v2SurfaceReadSelection(params: [String: Any]) -> V2CallResult {
        guard CapabilityFeatures.current.supports(.terminalSelection) else {
            return .err(code: "not_supported", message: String(localized: "socket.read_selection.unsupported", defaultValue: "Terminal selection reading is unavailable."), data: nil)
        }
        let operation = SelectionReadOperation<TerminalSelectionCapture>()
        let started = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor in
            guard operation.beginCapture() else { return }
            let captureStarted = DispatchTime.now().uptimeNanoseconds
            func fail(_ code: String, _ message: String) {
                operation.complete(.failure(.err(code: code, message: message, data: nil)))
            }
            v2RefreshKnownRefs()
            for key in ["window_id", "workspace_id", "surface_id"] where params[key] != nil {
                guard let raw = params[key] as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let uuid = v2UUID(params, key) else {
                    fail("invalid_params", String(format: String(localized: "socket.read_selection.invalid_target", defaultValue: "Invalid or unavailable target: %@."), LegacyWireAliases.displayKey(key)))
                    return
                }
                let live: Bool
                switch key {
                case "window_id": live = AppDelegate.shared?.workspaceManagerFor(windowId: uuid) != nil
                case "workspace_id": live = AppDelegate.shared?.workspaceManagerFor(workspaceId: uuid) != nil
                default: live = AppDelegate.shared?.locateSurface(surfaceId: uuid) != nil
                }
                guard live else {
                    fail("not_found", String(format: String(localized: "socket.read_selection.invalid_target", defaultValue: "Invalid or unavailable target: %@."), LegacyWireAliases.displayKey(key)))
                    return
                }
            }
            guard let manager = v2ResolveWorkspaceManager(params: params),
                  let workspace = v2ResolveWorkspace(params: params, workspaceManager: manager),
                  let tabID = v2UUID(params, "surface_id") ?? workspace.focusedPanelId,
                  let tab = workspace.panels[tabID] else {
                fail("not_found", String(localized: "socket.terminalRead.not_found", defaultValue: "Terminal tab not found."))
                return
            }
            guard let terminal = tab as? TerminalTab else {
                fail("invalid_params", String(localized: "socket.error.tab_not_terminal", defaultValue: "Tab is not a terminal."))
                return
            }
            // Resolve and fetch the live surface here, not on the worker or in
            // an earlier callback. A queued close/replacement cannot leak a ptr.
            guard manager.workspaces.contains(where: { $0 === workspace }),
                  workspace.terminalPanel(for: tabID) === terminal,
                  let surface = terminal.surface.surface else {
                fail("not_ready", String(localized: "socket.terminalRead.unavailable", defaultValue: "Terminal surface is not ready."))
                return
            }
            let windowID = v2ResolveWindowId(workspaceManager: manager)
            let routing: [String: Any] = [
                "workspace_id": workspace.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "surface_id": tabID.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: tabID),
                "window_id": v2OrNull(windowID?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowID)
            ]
            var native = ghostty_text_s()
            let nativeStarted = DispatchTime.now().uptimeNanoseconds
            let status = ghostty_surface_try_read_selection(surface, &native)
            let nativeEnded = DispatchTime.now().uptimeNanoseconds
            var bytes = Data()
            var originalCount = 0
            switch status {
            case GHOSTTY_TEXT_READ_OK:
                // Only OK transfers ownership; every OK exit frees on main,
                // including timeout while native formatting is already running.
                defer { ghostty_surface_free_text(surface, &native) }
                originalCount = Int(native.text_len)
                if originalCount > 0 {
                    guard let pointer = native.text else {
                        fail("internal_error", String(localized: "socket.terminalRead.failed", defaultValue: "Failed to read terminal selection."))
                        return
                    }
                    bytes = Data(bytes: pointer, count: min(originalCount, SelectionRead.byteLimit))
                }
            case GHOSTTY_TEXT_READ_NO_SELECTION:
                break
            case GHOSTTY_TEXT_READ_BUSY:
                fail("busy", String(localized: "socket.terminalRead.busy", defaultValue: "Terminal renderer is busy; retry."))
                return
            default:
                fail("internal_error", String(localized: "socket.terminalRead.failed", defaultValue: "Failed to read terminal selection."))
                return
            }
            let copied = DispatchTime.now().uptimeNanoseconds
            operation.complete(.success(bytes: bytes, originalCount: originalCount,
                hasSelection: status == GHOSTTY_TEXT_READ_OK, routing: routing))
            #if DEBUG
            dlog("selection.read queue_ms=\(Double(captureStarted - started) / 1e6) native_ms=\(Double(nativeEnded - nativeStarted) / 1e6) copy_free_ms=\(Double(copied - nativeEnded) / 1e6) original_bytes=\(originalCount) copied_bytes=\(bytes.count)")
            #endif
        }
        func timeout() -> V2CallResult {
            .err(code: "timeout", message: String(localized: "socket.terminalRead.timeout", defaultValue: "Terminal read timed out."), data: nil)
        }
        guard let capture = operation.wait() else { return timeout() }
        switch capture {
        case .failure(let error): return operation.canPublish ? error : timeout()
        case .success(let bytes, let originalCount, let hasSelection, var routing):
            let encodeStarted = DispatchTime.now().uptimeNanoseconds
            let clipped = SelectionRead.utf8Prefix(bytes, originalCount: originalCount)
            routing["has_selection"] = hasSelection
            routing["kind"] = "terminal"
            routing["text"] = String(decoding: clipped.data, as: UTF8.self)
            routing["base64"] = clipped.data.base64EncodedString()
            routing["truncated"] = clipped.truncated
            #if DEBUG
            dlog("selection.read encode_ms=\(Double(DispatchTime.now().uptimeNanoseconds - encodeStarted) / 1e6) isMain=\(Thread.isMainThread)")
            #endif
            guard operation.canPublish else { return timeout() }
            return .ok(routing)
        }
    }

    // C11-295: one five-second caller deadline covers both main hops and
    // C11-296's existing off-main startup wait. Native formatting after a
    // successful try-lock is still on main and cannot be preempted by timeout.
    nonisolated func v2SurfaceReadText(params: [String: Any], timeout: TimeInterval = 5.0) -> V2CallResult {
        let deadline = DispatchTime.now() + timeout
        let lineLimit = v2Int(params, "lines")
        if let lineLimit, lineLimit <= 0 {
            return .err(code: "invalid_params", message: "lines must be greater than 0", data: nil)
        }
        let includeScrollback = lineLimit != nil || (v2Bool(params, "scrollback") ?? false)
        typealias Target = (WorkspaceManager, Workspace, TerminalTab)
        let resolution = TerminalReadCompletion<Result<Target, V2CallResult>>(deadline: deadline)
        Task { @MainActor in
            guard !resolution.isAbandoned else { return }
            v2RefreshKnownRefs()
            if let error = v2RejectUnresolvedTargetRefs(params) {
                resolution.complete(.failure(error))
                return
            }
            guard let manager = v2ResolveWorkspaceManager(params: params) else {
                resolution.complete(.failure(.err(code: "unavailable", message: "TabManager not available", data: nil)))
                return
            }
            guard let workspace = v2ResolveWorkspace(params: params, workspaceManager: manager) else {
                resolution.complete(.failure(.err(code: "not_found", message: "Workspace not found", data: nil)))
                return
            }
            guard let id = v2UUID(params, "surface_id") ?? workspace.focusedPanelId else {
                resolution.complete(.failure(.err(code: "not_found", message: "No focused tab", data: nil)))
                return
            }
            guard let terminal = workspace.terminalPanel(for: id) else {
                resolution.complete(.failure(.err(code: "invalid_params", message: "Tab is not a terminal", data: ["surface_id": id.uuidString])))
                return
            }
            resolution.complete(.success((manager, workspace, terminal)))
        }
        guard let resolved = resolution.wait() else { return Self.terminalReadTimeout() }
        let target: Target
        switch resolved {
        case .failure(let error): return error
        case .success(let value): target = value
        }
        let (manager, workspace, terminal) = target
        let now = DispatchTime.now()
        guard now < deadline else { return Self.terminalReadTimeout() }
        let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
        // The pointer is a readiness indication only; re-read on main below.
        _ = waitForTerminalSurfaceOffMain(terminal, waitUpTo: min(2.0, remaining))

        typealias Capture = (TerminalReadBytes, [String: Any])
        let capture = TerminalReadCompletion<Result<Capture, V2CallResult>>(deadline: deadline)
        Task { @MainActor in
            guard !capture.isAbandoned else { return }
            let id = terminal.id
            guard manager.workspaces.contains(where: { $0 === workspace }),
                  workspace.terminalPanel(for: id) === terminal,
                  terminal.surface.canAcceptPortalBinding(expectedSurfaceId: id, expectedGeneration: nil) else {
                capture.complete(.failure(.err(code: "not_found", message: "Terminal surface not found", data: ["surface_id": id.uuidString])))
                return
            }
            guard let surface = terminal.surface.surface else {
                capture.complete(.failure(.err(code: "internal_error", message: "ERROR: Terminal surface not found", data: nil)))
                return
            }
            let native = captureTerminalReadBytes(
                surface: surface, includeScrollback: includeScrollback,
                isAbandoned: { capture.isAbandoned }
            )
            switch native {
            case .failure(let error): capture.complete(.failure(error))
            case .success(let bytes):
                let windowId = v2ResolveWindowId(workspaceManager: manager)
                capture.complete(.success((bytes, [
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "surface_id": id.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: id),
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ])))
            }
        }
        guard let captured = capture.wait() else { return Self.terminalReadTimeout() }
        switch captured {
        case .failure(let error): return error
        case .success(let (bytes, envelope)):
            // Formatting owns only Swift bytes. Keep the socket caller on the
            // same deadline even if a large conversion continues after timeout.
            let formatted = TerminalReadCompletion<V2CallResult>(deadline: deadline)
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    guard !formatted.isAbandoned else { return }
#if DEBUG
                    let workerStart = ProcessInfo.processInfo.systemUptime
#endif
                    guard let text = bytes.formatted(includeScrollback: includeScrollback, lineLimit: lineLimit) else {
                        formatted.complete(.err(code: "internal_error", message: "ERROR: Failed to read terminal text", data: nil))
                        return
                    }
                    guard !formatted.isAbandoned else { return }
                    var response = envelope
                    response["text"] = text
                    response["base64"] = Data(text.utf8).base64EncodedString()
#if DEBUG
                    dlog("terminal.read.worker bytes=\(text.utf8.count) ms=\((ProcessInfo.processInfo.systemUptime - workerStart) * 1000)")
#endif
                    formatted.complete(.ok(response))
                }
            }
            return formatted.wait() ?? Self.terminalReadTimeout()
        }
    }

    /// Resolve `(Workspace, surfaceId)` for M7 title bar handlers from the generic
    /// `surface_id` / `workspace_id` / focused-surface fallback.
    private func v2ResolveWorkspaceForTitleBar(params: [String: Any]) -> (Workspace, UUID)? {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else { return nil }
        var located: (Workspace, UUID)?
        v2MainSync {
            if let surfaceId = v2UUID(params, "surface_id") {
                if let ws = workspaceManager.workspaces.first(where: { $0.panels[surfaceId] != nil }) {
                    located = (ws, surfaceId)
                    return
                }
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager),
                  let focused = ws.focusedPanelId else { return }
            located = (ws, focused)
        }
        return located
    }

    private func v2SurfaceGetTitleBarState(params: [String: Any]) -> V2CallResult {
        guard let (ws, surfaceId) = v2ResolveWorkspaceForTitleBar(params: params) else {
            return .err(code: "surface_not_found", message: "Tab not found", data: nil)
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
            return .err(code: "surface_not_found", message: "Tab not found", data: nil)
        }
        guard let visible = params["visible"] as? Bool else {
            return .err(code: "invalid_params", message: "visible (bool) required", data: nil)
        }
        v2MainSync { ws.titleBarVisible = visible }
        return .ok(["visible": visible, "workspace_id": ws.id.uuidString])
    }

    private func v2SurfaceSetTitleBarCollapsed(params: [String: Any]) -> V2CallResult {
        guard let (ws, surfaceId) = v2ResolveWorkspaceForTitleBar(params: params) else {
            return .err(code: "surface_not_found", message: "Tab not found", data: nil)
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
        workspaceManager: WorkspaceManager
    ) -> (workspace: Workspace, surfaceId: UUID)? {
        if let surfaceId = v2UUID(params, "surface_id") {
            guard let owner = workspaceManager.workspaces.first(where: { $0.panels[surfaceId] != nil }) else {
                return nil
            }
            return (owner, surfaceId)
        }
        guard let ws = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager),
              let focused = ws.focusedPanelId else {
            return nil
        }
        return (ws, focused)
    }

    /// Shared not-found error for the surface-target verbs: distinguishes an
    /// explicit ref we couldn't locate from the no-surface-and-no-focus case.
    private func v2SurfaceTargetNotFound(params: [String: Any]) -> V2CallResult {
        if let surfaceId = v2UUID(params, "surface_id") {
            return .err(code: "not_found", message: "Tab not found",
                        data: ["surface_id": surfaceId.uuidString])
        }
        return .err(code: "not_found", message: "No focused tab", data: nil)
    }

    private func v2SurfaceTriggerFlash(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
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
            guard let (ws, surfaceId) = v2ResolveTargetSurface(params: params, workspaceManager: workspaceManager) else {
                result = v2SurfaceTargetNotFound(params: params)
                return
            }

            v2MaybeFocusWindow(for: workspaceManager)
            v2MaybeSelectWorkspace(workspaceManager, workspace: ws)

            ws.triggerFocusFlash(panelId: surfaceId, appearance: appearance, persistent: persistent)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(v2ResolveWindowId(workspaceManager: workspaceManager)?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(workspaceManager: workspaceManager)),
                "persistent": persistent
            ])
        }
        return result
    }

    /// CMUX-10: cancel an in-flight persistent flash on a single surface.
    /// Idempotent — succeeds even when no flash is registered (the operator
    /// or agent doesn't need to know the current state to cancel).
    private func v2SurfaceCancelFlash(params: [String: Any]) -> V2CallResult {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to cancel flash", data: nil)
        v2MainSync {
            guard let (ws, surfaceId) = v2ResolveTargetSurface(params: params, workspaceManager: workspaceManager) else {
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
    ) -> (workspaceId: UUID, surfaceId: UUID, workspaceManager: WorkspaceManager)? {
        guard let workspaceManager = v2ResolveWorkspaceManager(params: params) else {
            return nil
        }
        return v2MainSync {
            let ws: Workspace?
            if let surfaceId = v2UUID(params, "surface_id") {
                ws = workspaceManager.workspaces.first(where: { $0.panels[surfaceId] != nil })
                guard let workspace = ws else { return nil }
                return (workspace.id, surfaceId, workspaceManager)
            }
            // Fallback: explicit workspace_id, then default to focused.
            guard let workspace = v2ResolveWorkspace(params: params, workspaceManager: workspaceManager) else {
                return nil
            }
            if let focused = workspace.focusedPanelId {
                return (workspace.id, focused, workspaceManager)
            }
            return nil
        }
    }

    private func v2SurfaceSetMetadata(params: [String: Any]) -> V2CallResult {
        guard let metadataObj = params["metadata"] as? [String: Any] else {
            return .err(code: "invalid_json", message: "metadata must be a JSON object", data: nil)
        }

        let modeStr = (v2String(params, "mode") ?? "merge").lowercased()
        guard let mode = TabMetadataStore.WriteMode(rawValue: modeStr) else {
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
            return .err(code: "surface_not_found", message: "Tab not found", data: nil)
        }

        let attentionKeys = Set([
            MetadataKey.flag,
            MetadataKey.legacyFlagCallerSurfaceId,
            MetadataKey.flagCallerTabId,
            MetadataKey.suppressed,
        ])
        let existingAttention = TabMetadataStore.shared.attentionSnapshot(
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
            let result = try TabMetadataStore.shared.setMetadata(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                partial: metadataObj,
                mode: mode,
                source: source
            )
            applyTitleDescriptionSideEffects(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                workspaceManager: resolved.workspaceManager,
                applied: result.applied,
                removedKeys: result.removedKeys,
                autoExpand: (params["auto_expand"] as? Bool) ?? true
            )
            return .ok(buildMetadataOkPayload(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                workspaceManager: resolved.workspaceManager,
                result: result
            ))
        } catch let err as TabMetadataStore.WriteError {
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
            return .err(code: "surface_not_found", message: "Tab not found", data: nil)
        }

        let (storedMetadata, fullSources) = TabMetadataStore.shared.getMetadata(
            workspaceId: resolved.workspaceId,
            surfaceId: resolved.surfaceId
        )

        var fullMetadata = storedMetadata
        fullMetadata["journal"] = JournalCoordinator.shared.readback(tabID: resolved.surfaceId)
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
            return .err(code: "surface_not_found", message: "Tab not found", data: nil)
        }

        let attentionKeys = Set([
            MetadataKey.flag,
            MetadataKey.legacyFlagCallerSurfaceId,
            MetadataKey.flagCallerTabId,
            MetadataKey.suppressed,
        ])
        let existingAttention = TabMetadataStore.shared.attentionSnapshot(
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
            let result = try TabMetadataStore.shared.clearMetadata(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                keys: keys,
                source: source
            )
            applyTitleDescriptionSideEffects(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                workspaceManager: resolved.workspaceManager,
                applied: result.applied,
                removedKeys: result.removedKeys,
                autoExpand: false
            )
            return .ok(buildMetadataOkPayload(
                workspaceId: resolved.workspaceId,
                surfaceId: resolved.surfaceId,
                workspaceManager: resolved.workspaceManager,
                result: result
            ))
        } catch let err as TabMetadataStore.WriteError {
            return .err(code: err.code, message: err.message, data: err.detailData)
        } catch {
            return .err(code: "internal_error", message: "\(error)", data: nil)
        }
    }
}
