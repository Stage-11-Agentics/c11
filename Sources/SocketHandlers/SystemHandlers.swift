import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `system.*,auth.*,app.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchSystem(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "system.ping":
            // is_terminating_app: C11-24 — exposed so the claude-hook
            // CLI can query "is the app shutting down?" in 250 ms before
            // deciding whether to skip-clear during SessionEnd. Read off
            // the AppDelegate (single shared instance, BoolGet semantics
            // — no synchronisation needed since the field flips once
            // and never back).
            return v2Ok(id: id, result: [
                "pong": true,
                "is_terminating_app": (AppDelegate.shared?.isTerminatingApp ?? false)
            ])
        case "system.capabilities":
            return v2Ok(id: id, result: v2Capabilities())
        case "system.identify":
            return v2Ok(id: id, result: v2Identify(params: params))
        case "system.brand":
            return v2Ok(id: id, result: v2SystemBrand())
        case "system.tree":
            return v2Result(id: id, self.v2SystemTree(params: params))
        case "auth.login":
            return v2Ok(
                id: id,
                result: [
                    "authenticated": true,
                    "required": accessMode.requiresPasswordAuth
                ]
            )
        case "app.restart":
            return v2Result(id: id, self.v2AppRestart(params: params))
        case "app.focus_override.set":
            return v2Result(id: id, self.v2AppFocusOverride(params: params))
        case "app.simulate_active":
            return v2Result(id: id, self.v2AppSimulateActive())
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2Capabilities() -> [String: Any] {
        var methods: [String] = [
            "system.ping",
            "system.capabilities",
            "system.identify",
            "system.brand",
            "system.tree",
            "auth.login",
            "window.list",
            "window.current",
            "window.focus",
            "window.create",
            "window.close",
            "workspace.list",
            "workspace.create",
            "workspace.select",
            "workspace.current",
            "workspace.close",
            "workspace.move_to_window",
            "workspace.reorder",
            "workspace.rename",
            "workspace.action",
            "workspace.next",
            "workspace.previous",
            "workspace.last",
            "workspace.remote.configure",
            "workspace.remote.reconnect",
            "workspace.remote.disconnect",
            "workspace.remote.status",
            "workspace.remote.terminal_session_end",
            "workspace.set_metadata",
            "workspace.get_metadata",
            "workspace.clear_metadata",
            "workspace.apply",
            "settings.open",
            "feedback.open",
            "feedback.submit",
            "surface.list",
            "surface.current",
            "surface.focus",
            "surface.split",
            "surface.create",
            "surface.close",
            "surface.drag_to_split",
            "surface.move",
            "surface.reorder",
            "surface.action",
            "tab.action",
            "surface.refresh",
            "surface.health",
            "debug.terminals",
            "surface.send_text",
            "surface.send_key",
            "surface.read_text",
            "surface.clear_history",
            "surface.trigger_flash",
            "surface.cancel_flash",
            "surface.set_metadata",
            "surface.get_metadata",
            "surface.clear_metadata",
            "agent.launch",
            "mailbox.resolve",
            "pane.list",
            "pane.focus",
            "pane.surfaces",
            "pane.create",
            "pane.resize",
            "pane.swap",
            "pane.break",
            "pane.join",
            "pane.last",
            "pane.set_metadata",
            "pane.get_metadata",
            "pane.clear_metadata",
            "notification.create",
            "notification.create_for_surface",
            "notification.create_for_target",
            "notification.list",
            "notification.clear",
            "app.focus_override.set",
            "app.simulate_active",
            "markdown.open",
            "markdown.get_content",
            "sidebar.state",
            "browser.open_split",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
            "browser.url.get",
            "browser.snapshot",
            "browser.eval",
            "browser.wait",
            "browser.click",
            "browser.dblclick",
            "browser.hover",
            "browser.focus",
            "browser.type",
            "browser.fill",
            "browser.press",
            "browser.keydown",
            "browser.keyup",
            "browser.check",
            "browser.uncheck",
            "browser.select",
            "browser.scroll",
            "browser.scroll_into_view",
            "browser.screenshot",
            "browser.get.text",
            "browser.get.html",
            "browser.get.value",
            "browser.get.attr",
            "browser.get.title",
            "browser.get.count",
            "browser.get.box",
            "browser.get.styles",
            "browser.is.visible",
            "browser.is.enabled",
            "browser.is.checked",
            "browser.focus_webview",
            "browser.is_webview_focused",
            "browser.find.role",
            "browser.find.text",
            "browser.find.label",
            "browser.find.placeholder",
            "browser.find.alt",
            "browser.find.title",
            "browser.find.testid",
            "browser.find.first",
            "browser.find.last",
            "browser.find.nth",
            "browser.frame.select",
            "browser.frame.main",
            "browser.dialog.accept",
            "browser.dialog.dismiss",
            "browser.download.wait",
            "browser.cookies.get",
            "browser.cookies.set",
            "browser.cookies.clear",
            "browser.storage.get",
            "browser.storage.set",
            "browser.storage.clear",
            "browser.tab.new",
            "browser.tab.list",
            "browser.tab.switch",
            "browser.tab.close",
            "browser.console.list",
            "browser.console.clear",
            "browser.errors.list",
            "browser.highlight",
            "browser.state.save",
            "browser.state.load",
            "browser.addinitscript",
            "browser.addscript",
            "browser.addstyle",
            "browser.viewport.set",
            "browser.geolocation.set",
            "browser.offline.set",
            "browser.trace.start",
            "browser.trace.stop",
            "browser.network.route",
            "browser.network.unroute",
            "browser.network.requests",
            "browser.screencast.start",
            "browser.screencast.stop",
            "browser.input_mouse",
            "browser.input_keyboard",
            "browser.input_touch",
        ]
#if DEBUG
        methods.append(contentsOf: [
            "debug.shortcut.set",
            "debug.shortcut.simulate",
            "debug.type",
            "debug.app.activate",
            "debug.command_palette.toggle",
            "debug.command_palette.rename_tab.open",
            "debug.command_palette.visible",
            "debug.command_palette.selection",
            "debug.command_palette.results",
            "debug.command_palette.rename_input.interact",
            "debug.command_palette.rename_input.delete_backward",
            "debug.command_palette.rename_input.selection",
            "debug.command_palette.rename_input.select_all",
            "debug.browser.address_bar_focused",
            "debug.browser.favicon",
            "debug.sidebar.visible",
            "debug.terminal.is_focused",
            "debug.terminal.read_text",
            "debug.terminal.render_stats",
            "debug.layout",
            "debug.portal.stats",
            "debug.bonsplit_underflow.count",
            "debug.bonsplit_underflow.reset",
            "debug.empty_panel.count",
            "debug.empty_panel.reset",
            "debug.notification.focus",
            "debug.flash.count",
            "debug.flash.reset",
            "debug.panel_snapshot",
            "debug.panel_snapshot.reset",
            "debug.window.screenshot",
            "debug.session.round_trip",
            "debug.session.round_trip_workspaces",
        ])
#endif

        return [
            "protocol": "cmux-socket",
            "version": 2,
            "socket_path": socketPath,
            "access_mode": accessMode.rawValue,
            "methods": methods.sorted()
        ]
    }

    private func v2Identify(params: [String: Any]) -> [String: Any] {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return [
                "socket_path": socketPath,
                "focused": NSNull(),
                "caller": NSNull()
            ]
        }

        var focused: [String: Any] = [:]
        v2MainSync {
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            if let wsId = tabManager.selectedTabId,
               let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                let paneUUID = ws.bonsplitController.focusedPaneId?.id
                let surfaceUUID = ws.focusedPanelId
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": wsId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "surface_id": v2OrNull(surfaceUUID?.uuidString),
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceUUID),
                    "tab_id": v2OrNull(surfaceUUID?.uuidString),
                    "tab_ref": v2TabRef(uuid: surfaceUUID),
                    "surface_type": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType.rawValue }),
                    "is_browser_surface": v2OrNull(surfaceUUID.flatMap { ws.panels[$0]?.panelType == .browser })
                ]
            } else {
                focused = [
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
            }
        }

        // Optionally validate a caller-provided location (useful for agents calling from inside a surface).
        var resolvedCaller: [String: Any]? = nil
        if let callerObj = params["caller"] as? [String: Any],
           let wsId = v2UUIDAny(callerObj["workspace_id"]) {
            let surfaceId = v2UUIDAny(callerObj["surface_id"]) ?? v2UUIDAny(callerObj["tab_id"])
            v2MainSync {
                let callerTabManager = AppDelegate.shared?.tabManagerFor(tabId: wsId) ?? tabManager
                if let ws = callerTabManager.tabs.first(where: { $0.id == wsId }) {
                    let callerWindowId = v2ResolveWindowId(tabManager: callerTabManager)
                    var payload: [String: Any] = [
                        "window_id": v2OrNull(callerWindowId?.uuidString),
                        "window_ref": v2Ref(kind: .window, uuid: callerWindowId),
                        "workspace_id": wsId.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
                    ]

                    if let surfaceId, ws.panels[surfaceId] != nil {
                        let paneUUID = ws.paneId(forPanelId: surfaceId)?.id
                        payload["surface_id"] = surfaceId.uuidString
                        payload["surface_ref"] = v2Ref(kind: .surface, uuid: surfaceId)
                        payload["tab_id"] = surfaceId.uuidString
                        payload["tab_ref"] = v2TabRef(uuid: surfaceId)
                        payload["surface_type"] = v2OrNull(ws.panels[surfaceId]?.panelType.rawValue)
                        payload["is_browser_surface"] = v2OrNull(ws.panels[surfaceId]?.panelType == .browser)
                        payload["pane_id"] = v2OrNull(paneUUID?.uuidString)
                        payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneUUID)
                    } else {
                        payload["surface_id"] = NSNull()
                        payload["surface_ref"] = NSNull()
                        payload["tab_id"] = NSNull()
                        payload["tab_ref"] = NSNull()
                        payload["surface_type"] = NSNull()
                        payload["is_browser_surface"] = NSNull()
                        payload["pane_id"] = NSNull()
                        payload["pane_ref"] = NSNull()
                    }
                    resolvedCaller = payload
                }
            }
        }

        return [
            "socket_path": socketPath,
            "focused": focused.isEmpty ? NSNull() : focused,
            "caller": v2OrNull(resolvedCaller)
        ]
    }

    private func v2SystemBrand() -> [String: Any] {
        // Bundle info is read from the running process — verifies the built
        // plist, not the source tree. Matches socket threading policy: this
        // is a fast snapshot with no UI mutation.
        let infoDict: [String: Any] = Bundle.main.infoDictionary ?? [:]
        let bundleIdentifier = (Bundle.main.bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (infoDict["CFBundleDisplayName"] as? String) ?? (infoDict["CFBundleName"] as? String) ?? ""
        let bundleName = (infoDict["CFBundleName"] as? String) ?? displayName
        let iconName = (infoDict["CFBundleIconName"] as? String)
            ?? (infoDict["CFBundleIconFile"] as? String)
            ?? "AppIcon"
        let shortVersion = (infoDict["CFBundleShortVersionString"] as? String) ?? ""
        let build = (infoDict["CFBundleVersion"] as? String) ?? ""

        let channel: String
        if bundleIdentifier.contains(".debug") {
            channel = "dev"
        } else if bundleIdentifier.hasSuffix(".nightly") {
            channel = "nightly"
        } else if bundleIdentifier.hasSuffix(".staging") {
            channel = "staging"
        } else {
            channel = "stable"
        }

        var palette: [String: String] = [:]
        for (key, hex) in BrandColors.paletteHex {
            palette[key] = hex
        }

        return [
            "channel": channel,
            "bundle": [
                "identifier": bundleIdentifier,
                "display_name": displayName,
                "name": bundleName,
                "icon_name": iconName,
                "short_version": shortVersion,
                "build": build
            ],
            "palette": palette,
            "accent_hex": BrandColors.goldHex,
            "font_family": BrandColors.fontFamily
        ]
    }

    private func v2SystemTree(params: [String: Any]) -> V2CallResult {
        let workspaceFilter = v2UUID(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }

        // Resolve scope: explicit `scope` wins, then legacy `all_windows`, then default workspace.
        // Legal scope values: "workspace" | "window" | "all".
        let rawScope = (params["scope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scope: String
        if let rawScope, !rawScope.isEmpty {
            switch rawScope {
            case "workspace", "window", "all":
                scope = rawScope
            default:
                return .err(
                    code: "invalid_params",
                    message: "Invalid scope: \(rawScope) (expected workspace|window|all)",
                    data: ["scope": rawScope]
                )
            }
        } else if let legacy = v2Bool(params, "all_windows") {
            scope = legacy ? "all" : "window"
        } else if workspaceFilter != nil {
            scope = "workspace"
        } else {
            scope = "workspace"
        }

        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }
        let identifyPayload = v2Identify(params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let focusedWindowId = v2UUIDAny(focused["window_id"]) ?? v2UUIDAny(focused["window_ref"])
        let focusedWorkspaceId = v2UUIDAny(focused["workspace_id"]) ?? v2UUIDAny(focused["workspace_ref"])
        let callerWorkspaceId = v2UUIDAny(caller["workspace_id"]) ?? v2UUIDAny(caller["workspace_ref"])

        var windowNodes: [[String: Any]] = []
        var workspaceFound = (workspaceFilter == nil)

        v2MainSync {
            guard let app = AppDelegate.shared else { return }
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = focusedWindowId ?? summaries.first?.windowId

            // Caller-current-workspace lookup for `scope == "workspace"`. Priority:
            //   1. Explicit --workspace (handled below by workspaceFilter branch)
            //   2. Caller env (CMUX_WORKSPACE_ID, propagated via params.caller)
            //   3. Focused workspace
            //   4. Selected workspace of the current window
            let callerScopeWorkspaceId: UUID? = callerWorkspaceId ?? focusedWorkspaceId

            for (windowIndex, summary) in summaries.enumerated() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = v2TreeWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windowNodes = [
                        v2TreeWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: [workspaceNode]
                        )
                    ]
                    workspaceFound = true
                    break
                }

                switch scope {
                case "all":
                    let workspaceNodesForWindow = manager.tabs.enumerated().map { workspaceIndex, workspace in
                        v2TreeWorkspaceNode(
                            workspace: workspace,
                            index: workspaceIndex,
                            selected: workspace.id == manager.selectedTabId
                        )
                    }
                    windowNodes.append(
                        v2TreeWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: workspaceNodesForWindow
                        )
                    )

                case "window":
                    if summary.windowId != defaultWindowId { continue }
                    let workspaceNodesForWindow = manager.tabs.enumerated().map { workspaceIndex, workspace in
                        v2TreeWorkspaceNode(
                            workspace: workspace,
                            index: workspaceIndex,
                            selected: workspace.id == manager.selectedTabId
                        )
                    }
                    windowNodes.append(
                        v2TreeWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: workspaceNodesForWindow
                        )
                    )

                case "workspace":
                    // Find the caller's current workspace; only include the window that owns it.
                    let target: UUID? = callerScopeWorkspaceId ?? manager.selectedTabId
                    guard let targetId = target,
                          let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == targetId }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = v2TreeWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windowNodes = [
                        v2TreeWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: [workspaceNode]
                        )
                    ]
                    return  // Only one workspace per "workspace" scope; exit the v2MainSync closure.

                default:
                    continue
                }
            }
        }

        if let workspaceFilter, !workspaceFound {
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: [
                    "workspace_id": workspaceFilter.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceFilter)
                ]
            )
        }

        return .ok([
            "active": focused.isEmpty ? (NSNull() as Any) : focused,
            "caller": caller.isEmpty ? (NSNull() as Any) : caller,
            "scope": scope,
            "windows": windowNodes
        ])
    }

    /// C11-131 `app.restart` — clean-shutdown choreography then relaunch.
    /// `no_resume` restores layout without typing resume commands into panes.
    ///
    /// Main-actor handling is intentional: it mutates app lifecycle state
    /// (suspend refs, snapshot, sentinel, terminate). The reply flushes
    /// before the deferred `NSApp.terminate` fires. This verb does not steal
    /// focus beyond the operator's explicit restart intent.
    private func v2AppRestart(params: [String: Any]) -> V2CallResult {
        let noResume = (params["no_resume"] as? Bool) ?? false
        var dispatched = false
        v2MainSync {
            guard let app = AppDelegate.shared else { return }
            app.performCleanRestart(resume: !noResume)
            dispatched = true
        }
        guard dispatched else {
            return .err(code: "app_restart_failed",
                        message: "AppDelegate unavailable", data: nil)
        }
        return .ok(["ok": true, "resume": !noResume])
    }

    private func v2AppFocusOverride(params: [String: Any]) -> V2CallResult {
        // Accept either:
        // - state: "active" | "inactive" | "clear"
        // - focused: true/false/null
        if let state = v2String(params, "state")?.lowercased() {
            switch state {
            case "active":
                AppFocusState.overrideIsFocused = true
            case "inactive":
                AppFocusState.overrideIsFocused = false
            case "clear", "none":
                AppFocusState.overrideIsFocused = nil
            default:
                return .err(code: "invalid_params", message: "Invalid state (active|inactive|clear)", data: ["state": state])
            }
        } else if params.keys.contains("focused") {
            if let focused = v2Bool(params, "focused") {
                AppFocusState.overrideIsFocused = focused
            } else {
                AppFocusState.overrideIsFocused = nil
            }
        } else {
            return .err(code: "invalid_params", message: "Missing state or focused", data: nil)
        }

        let overrideVal: Any = v2OrNull(AppFocusState.overrideIsFocused.map { $0 as Any })
        return .ok(["override": overrideVal])
    }

    private func v2AppSimulateActive() -> V2CallResult {
        v2MainSync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return .ok([:])
    }
}
