import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
extension TerminalController {
    /// v2 dispatch slice for the `settings.*,sidebar.*,session.*,tab.*,mailbox.*` domain(s).
    /// Byte-identical routing and wire responses to the original processV2Command cases.
    func v2DispatchMisc(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "settings.open":
            return v2Result(id: id, self.v2SettingsOpen(params: params))
        case "tab.action":
            return v2Result(id: id, self.v2TabAction(params: params))
        case "session.save":
            return v2Result(id: id, self.v2SessionSave(params: params))
        case "mailbox.resolve":
            return v2Result(id: id, self.v2MailboxResolve(params: params))
        case "sidebar.state":
            return v2Result(id: id, self.v2SidebarState(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    func v2TabAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }

        // C11-165 COR-1: rename (rename-tab) is a surface/tab-scoped write; an
        // empty or absent ref must not rename the operator-focused tab. Here
        // `tab_id` and `surface_id` both pin the target (line 57 resolves both
        // to a surface id). Other tab.action verbs (close_*, pin, duplicate, …)
        // are outside COR-1's enumerated 10 and keep their focused-tab default.
        if action == "rename",
           let reject = v2RejectInvalidSurfaceRef(
               params,
               targetKeys: ["surface_id", "tab_id", "workspace_id"],
               requiredAnyOf: ["surface_id", "tab_id"]
           ) {
            return reject
        }

        let supportedActions = [
            "rename", "clear_name",
            "close_left", "close_right", "close_others",
            "new_terminal_right", "new_browser_right",
            "reload", "duplicate",
            "pin", "unpin", "mark_read", "mark_unread"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown tab action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") ?? workspace.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused tab", data: nil)
                return
            }
            guard workspace.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: [
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "tab_id": surfaceId.uuidString,
                    "tab_ref": v2TabRef(uuid: surfaceId)
                ])
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "tab_id": surfaceId.uuidString,
                    "tab_ref": v2TabRef(uuid: surfaceId)
                ]
                if let paneId = workspace.paneId(forPanelId: surfaceId)?.id {
                    payload["pane_id"] = paneId.uuidString
                    payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneId)
                } else {
                    payload["pane_id"] = NSNull()
                    payload["pane_ref"] = NSNull()
                }
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            @MainActor
            func insertionIndexToRight(anchorTabId: TabID, inPane paneId: PaneID) -> Int {
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
                let pinnedCount = tabs.reduce(into: 0) { count, tab in
                    if let panelId = workspace.panelIdFromSurfaceId(tab.id),
                       workspace.isPanelPinned(panelId) {
                        count += 1
                    }
                }
                let rawTarget = min(anchorIndex + 1, tabs.count)
                return max(rawTarget, pinnedCount)
            }

            @MainActor
            func closeTabs(_ tabIds: [TabID]) -> (closed: Int, skippedPinned: Int) {
                var closed = 0
                var skippedPinned = 0
                for tabId in tabIds {
                    guard let panelId = workspace.panelIdFromSurfaceId(tabId) else { continue }
                    if workspace.isPanelPinned(panelId) {
                        skippedPinned += 1
                        continue
                    }
                    if workspace.panels.count <= 1 {
                        break
                    }
                    if workspace.closePanel(panelId, force: true) {
                        closed += 1
                    }
                }
                return (closed, skippedPinned)
            }

            switch action {
            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                workspace.setPanelCustomTitle(panelId: surfaceId, title: title)
                finish(["title": title])

            case "clear_name":
                workspace.setPanelCustomTitle(panelId: surfaceId, title: nil)
                finish()

            case "pin":
                workspace.setPanelPinned(panelId: surfaceId, pinned: true)
                finish(["pinned": true])

            case "unpin":
                workspace.setPanelPinned(panelId: surfaceId, pinned: false)
                finish(["pinned": false])

            case "mark_read":
                workspace.markPanelRead(surfaceId)
                finish()

            case "mark_unread", "mark_as_unread":
                workspace.markPanelUnread(surfaceId)
                finish()

            case "reload", "reload_tab":
                guard let browserPanel = workspace.browserPanel(for: surfaceId) else {
                    result = .err(code: "invalid_state", message: "Reload is only available for browser tabs", data: nil)
                    return
                }
                browserPanel.reload()
                finish()

            case "duplicate", "duplicate_tab":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId),
                      let browserPanel = workspace.browserPanel(for: surfaceId) else {
                    result = .err(code: "invalid_state", message: "Duplicate is only available for browser tabs", data: nil)
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newBrowserSurface(
                    inPane: paneId,
                    url: browserPanel.currentURL,
                    focus: true
                ) else {
                    result = .err(code: "internal_error", message: "Failed to duplicate tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "new_terminal_right", "new_terminal_to_right", "new_terminal_tab_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newTerminalSurface(inPane: paneId, focus: true) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "new_browser_right", "new_browser_to_right", "new_browser_tab_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }

                let urlRaw = v2String(params, "url")
                let url = urlRaw.flatMap { URL(string: $0) }
                if urlRaw != nil && url == nil {
                    result = .err(code: "invalid_params", message: "Invalid URL", data: ["url": v2OrNull(urlRaw)])
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newBrowserSurface(inPane: paneId, url: url, focus: true) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "close_left", "close_to_left":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                    result = .err(code: "not_found", message: "Tab not found in pane", data: nil)
                    return
                }
                let targetIds = Array(tabs.prefix(index).map(\.id))
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            case "close_right", "close_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                    result = .err(code: "not_found", message: "Tab not found in pane", data: nil)
                    return
                }
                let targetIds = (index + 1 < tabs.count) ? Array(tabs.suffix(from: index + 1).map(\.id)) : []
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            case "close_others", "close_other_tabs":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let targetIds = workspace.bonsplitController.tabs(inPane: paneId)
                    .map(\.id)
                    .filter { $0 != anchorTabId }
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            default:
                result = .err(code: "invalid_params", message: "Unknown tab action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    /// C11-131 `session.save` — production cousin of the DEBUG-only
    /// `debug.session.save_and_load`. Forces a synchronous full-app session
    /// snapshot while the app keeps running and returns the path + counts.
    ///
    /// Main-actor handling (`v2MainSync`) is intentional and permitted by the
    /// socket threading policy: this is an operator-grade, low-frequency verb
    /// that must build the snapshot from live AppKit/window state and read it
    /// back — it is not a telemetry hot path.
    private func v2SessionSave(params: [String: Any]) -> V2CallResult {
        let includeScrollback = (params["include_scrollback"] as? Bool) ?? false
        let outPath = (params["out"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: AppDelegate.SessionSaveResult?
        v2MainSync {
            guard let app = AppDelegate.shared else { return }
            result = app.forceSessionSave(
                includeScrollback: includeScrollback,
                outPath: (outPath?.isEmpty == false) ? outPath : nil
            )
        }
        guard let result else {
            return .err(code: "session_save_failed",
                        message: "forceSessionSave returned nil (no windows or write failed)",
                        data: nil)
        }
        var payload: [String: Any] = [
            "snapshot_path": result.snapshotPath,
            "windows": result.windows,
            "workspaces": result.workspaces,
            "terminal_panels": result.terminalPanels,
            "refs": result.refs
        ]
        if let out = result.outPath { payload["out_path"] = out }
        return .ok(payload)
    }

    /// Resolves a mailbox recipient name to the workspace its envelope should
    /// be delivered into, scanning every live surface across all windows.
    /// Backs `c11 mailbox send`, which routes the envelope into the resolved
    /// workspace's outbox so that workspace's own dispatcher delivers it.
    ///
    /// Params:
    ///   * `to` (string, required) — recipient surface name.
    ///   * `sender_workspace_id` (uuid, required) — the sender's workspace, so
    ///     a local match takes precedence over same-named surfaces elsewhere.
    ///   * `workspace` (string, optional) — disambiguates a name that lives in
    ///     more than one workspace; a workspace UUID or a `workspace:*` ref.
    ///
    /// Returns `{ resolution: "unique"|"ambiguous"|"unresolved",
    /// target_workspace_id?, target_workspace_ref?, surface_ids?, candidates }`.
    private func v2MailboxResolve(params: [String: Any]) -> V2CallResult {
        guard let to = v2String(params, "to"), !to.isEmpty else {
            return .err(code: "invalid_to", message: "to is required", data: nil)
        }
        guard let senderWorkspaceId = v2UUID(params, "sender_workspace_id") else {
            return .err(code: "invalid_sender_workspace_id", message: "sender_workspace_id must be a UUID", data: nil)
        }
        let qualifierStr = v2String(params, "workspace")

        return v2MainSync {
            let surfaces = AppDelegate.shared?.mailboxAddressableSurfaces() ?? []

            // Translate the optional workspace qualifier (UUID or ref string)
            // into a concrete workspace UUID. A raw UUID is honored even when
            // that workspace currently has no addressable surface (it then
            // resolves to `unresolved`, the honest answer). Otherwise match the
            // qualifier against the ref strings of the live workspaces.
            var qualifierUUID: UUID?
            if let qualifierStr, !qualifierStr.isEmpty {
                if let direct = UUID(uuidString: qualifierStr) {
                    qualifierUUID = direct
                } else {
                    let workspaceIds = Set(surfaces.map(\.workspaceId))
                    qualifierUUID = workspaceIds.first { wsId in
                        if let ref = v2Ref(kind: .workspace, uuid: wsId) as? String {
                            return ref == qualifierStr
                        }
                        return false
                    }
                    if qualifierUUID == nil {
                        // Unknown workspace ref → nothing can match it.
                        return .ok([
                            "resolution": "unresolved",
                            "candidates": self.mailboxCandidatePayload(
                                MailboxMatcher.select(
                                    MailboxAddress.parse(to),
                                    from: surfaces,
                                    identity: { $0.identity }
                                )
                            )
                        ])
                    }
                }
            }

            let resolver = MailboxGlobalResolver(surfaces: { surfaces })
            let resolution = resolver.resolve(
                name: to,
                senderWorkspaceId: senderWorkspaceId,
                workspaceQualifier: qualifierUUID
            )

            let candidates = self.mailboxCandidatePayload(
                MailboxMatcher.select(
                    MailboxAddress.parse(to),
                    from: surfaces,
                    identity: { $0.identity }
                )
            )
            switch resolution {
            case .unique(let workspaceId, let surfaceIds):
                return .ok([
                    "resolution": "unique",
                    "target_workspace_id": workspaceId.uuidString,
                    "target_workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                    "surface_ids": surfaceIds.map(\.uuidString),
                    "candidates": candidates
                ])
            case .ambiguous:
                return .ok([
                    "resolution": "ambiguous",
                    "candidates": candidates
                ])
            case .unresolved:
                return .ok([
                    "resolution": "unresolved",
                    "candidates": candidates
                ])
            }
        }
    }

    private func v2SettingsOpen(params: [String: Any]) -> V2CallResult {
        let targetRaw = v2String(params, "target")
        let shouldActivate = v2Bool(params, "activate") ?? true

        let navigationTarget: SettingsNavigationTarget?
        switch targetRaw {
        case nil:
            navigationTarget = nil
        case SettingsNavigationTarget.keyboardShortcuts.rawValue:
            navigationTarget = .keyboardShortcuts
        default:
            return .err(code: "invalid_params", message: "Unknown settings target", data: ["target": targetRaw ?? ""])
        }

        DispatchQueue.main.async {
            if shouldActivate {
                AppDelegate.presentPreferencesWindow(navigationTarget: navigationTarget)
            } else {
                SettingsWindowController.shared.show(navigationTarget: navigationTarget)
            }
        }
        return .ok([
            "opened": true,
            "target": navigationTarget?.rawValue ?? "general",
        ])
    }

    /// Structured `sidebar_state` — JSON variant that includes the M3 `agent_chip` block.
    private func v2SidebarState(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let statusEntries = ws.sidebarStatusEntriesInDisplayOrder()
            let metadataBlocks = ws.sidebarMetadataBlocksInDisplayOrder()

            var out: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "status_count": statusEntries.count,
                "meta_block_count": metadataBlocks.count,
                "log_count": ws.logEntries.count
            ]
            if let focused = ws.focusedPanelId {
                out["focused_surface_id"] = focused.uuidString
                out["focused_surface_ref"] = v2Ref(kind: .surface, uuid: focused)
            }

            // Agent chip resolution.
            let chipDict: [String: Any] = self.resolveAgentChipDict(workspace: ws)
            out["agent_chip"] = chipDict

            payload = out
        }
        guard let out = payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(out)
    }
}
