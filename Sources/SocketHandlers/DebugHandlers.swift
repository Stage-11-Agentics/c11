import AppKit
import Foundation

// C11-159: per-domain socket handler unit extracted verbatim from
// TerminalController.swift. Mechanical relocation, zero behavior change.
// debug.terminals is available in all configs; every other debug.* method is
// #if DEBUG only, exactly as before.
extension TerminalController {
    /// v2 dispatch slice for the `debug.*` domain. Preserves the original
    /// #if DEBUG gating: only debug.terminals is compiled in release.
    func v2DispatchDebug(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "debug.terminals":
            return v2Result(id: id, self.v2DebugTerminals(params: params))
#if DEBUG
        case "debug.session.save_and_load":
            return v2Result(id: id, self.v2DebugSessionSaveAndLoad(params: params))
        case "debug.shortcut.set":
            return v2Result(id: id, self.v2DebugShortcutSet(params: params))
        case "debug.shortcut.simulate":
            return v2Result(id: id, self.v2DebugShortcutSimulate(params: params))
        case "debug.type":
            return v2Result(id: id, self.v2DebugType(params: params))
        case "debug.app.activate":
            return v2Result(id: id, self.v2DebugActivateApp())
        case "debug.command_palette.toggle":
            return v2Result(id: id, self.v2DebugToggleCommandPalette(params: params))
        case "debug.command_palette.rename_tab.open":
            return v2Result(id: id, self.v2DebugOpenCommandPaletteRenameTabInput(params: params))
        case "debug.command_palette.visible":
            return v2Result(id: id, self.v2DebugCommandPaletteVisible(params: params))
        case "debug.command_palette.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteSelection(params: params))
        case "debug.command_palette.results":
            return v2Result(id: id, self.v2DebugCommandPaletteResults(params: params))
        case "debug.command_palette.rename_input.interact":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputInteraction(params: params))
        case "debug.command_palette.rename_input.delete_backward":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputDeleteBackward(params: params))
        case "debug.command_palette.rename_input.selection":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelection(params: params))
        case "debug.command_palette.rename_input.select_all":
            return v2Result(id: id, self.v2DebugCommandPaletteRenameInputSelectAll(params: params))
        case "debug.browser.address_bar_focused":
            return v2Result(id: id, self.v2DebugBrowserAddressBarFocused(params: params))
        case "debug.browser.favicon":
            return v2Result(id: id, self.v2DebugBrowserFavicon(params: params))
        case "debug.sidebar.visible":
            return v2Result(id: id, self.v2DebugSidebarVisible(params: params))
        case "debug.terminal.is_focused":
            return v2Result(id: id, self.v2DebugIsTerminalFocused(params: params))
        case "debug.terminal.read_text":
            return v2Result(id: id, self.v2DebugReadTerminalText(params: params))
        case "debug.terminal.render_stats":
            return v2Result(id: id, self.v2DebugRenderStats(params: params))
        case "debug.layout":
            return v2Result(id: id, self.v2DebugLayout())
        case "debug.portal.stats":
            return v2Result(id: id, self.v2DebugPortalStats())
        case "debug.bonsplit_underflow.count":
            return v2Result(id: id, self.v2DebugBonsplitUnderflowCount())
        case "debug.bonsplit_underflow.reset":
            return v2Result(id: id, self.v2DebugResetBonsplitUnderflowCount())
        case "debug.empty_panel.count":
            return v2Result(id: id, self.v2DebugEmptyPanelCount())
        case "debug.empty_panel.reset":
            return v2Result(id: id, self.v2DebugResetEmptyPanelCount())
        case "debug.notification.focus":
            return v2Result(id: id, self.v2DebugFocusNotification(params: params))
        case "debug.flash.count":
            return v2Result(id: id, self.v2DebugFlashCount(params: params))
        case "debug.flash.reset":
            return v2Result(id: id, self.v2DebugResetFlashCounts())
        case "debug.panel_snapshot":
            return v2Result(id: id, self.v2DebugPanelSnapshot(params: params))
        case "debug.panel_snapshot.reset":
            return v2Result(id: id, self.v2DebugPanelSnapshotReset(params: params))
        case "debug.window.screenshot":
            return v2Result(id: id, self.v2DebugScreenshot(params: params))
        case "debug.session.round_trip":
            return v2Result(id: id, self.v2DebugSessionRoundTrip(params: params))
        case "debug.session.round_trip_workspaces":
            return v2Result(id: id, self.v2DebugSessionRoundTripWorkspaces(params: params))
#endif
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private func v2DebugTerminals(params _: [String: Any]) -> V2CallResult {
        var payload: [String: Any]?

        v2MainSync {
            guard let app = AppDelegate.shared else { return }

            struct MappedTerminalLocation {
                let windowIndex: Int
                let windowId: UUID
                let window: NSWindow?
                let workspaceIndex: Int
                let workspaceSelected: Bool
                let workspace: Workspace
                let terminalPanel: TerminalPanel
                let paneId: PaneID?
                let paneIndex: Int?
                let surfaceIndex: Int
                let selectedInPane: Bool?
                let bonsplitTabId: TabID?
            }

            func nonEmpty(_ raw: String?) -> String? {
                guard let raw else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            func rectPayload(_ rect: CGRect) -> [String: Double] {
                [
                    "x": Double(rect.origin.x),
                    "y": Double(rect.origin.y),
                    "width": Double(rect.size.width),
                    "height": Double(rect.size.height)
                ]
            }

            func objectPointerString(_ object: AnyObject?) -> String {
                guard let object else { return "nil" }
                return String(describing: Unmanaged.passUnretained(object).toOpaque())
            }

            func ghosttyPointerString(_ surface: ghostty_surface_t?) -> String {
                guard let surface else { return "nil" }
                return String(describing: surface)
            }

            func className(_ object: AnyObject?) -> String? {
                guard let object else { return nil }
                return String(describing: type(of: object))
            }

            let iso8601Formatter = ISO8601DateFormatter()
            let now = Date()

            func iso8601String(_ date: Date?) -> String? {
                guard let date else { return nil }
                return iso8601Formatter.string(from: date)
            }

            func ageSeconds(since date: Date?) -> Double? {
                guard let date else { return nil }
                return (now.timeIntervalSince(date) * 1000).rounded() / 1000
            }

            @MainActor
            func superviewClassChain(for view: NSView, limit: Int = 8) -> [String] {
                var chain: [String] = [String(describing: type(of: view))]
                var currentSuperview = view.superview
                while chain.count < limit, let nextSuperview = currentSuperview {
                    chain.append(String(describing: type(of: nextSuperview)))
                    currentSuperview = nextSuperview.superview
                }
                if currentSuperview != nil {
                    chain.append("...")
                }
                return chain
            }

            let windows = app.scriptableMainWindows()
            let windowIndexById = Dictionary(
                uniqueKeysWithValues: windows.enumerated().map { ($0.element.windowId, $0.offset) }
            )

            @MainActor
            func resolvedWindowMetadata(for window: NSWindow?) -> (windowId: UUID?, windowIndex: Int?) {
                guard let window else { return (nil, nil) }

                if let match = windows.enumerated().first(where: { _, state in
                    guard let stateWindow = state.window else { return false }
                    return stateWindow === window || stateWindow.windowNumber == window.windowNumber
                }) {
                    return (match.element.windowId, match.offset)
                }

                guard let raw = window.identifier?.rawValue else { return (nil, nil) }
                let prefix = "cmux.main."
                guard raw.hasPrefix(prefix),
                      let parsedWindowId = UUID(uuidString: String(raw.dropFirst(prefix.count))) else {
                    return (nil, nil)
                }
                return (parsedWindowId, windowIndexById[parsedWindowId])
            }

            var mappedLocations: [ObjectIdentifier: MappedTerminalLocation] = [:]
            for (windowIndex, state) in windows.enumerated() {
                let tabManager = state.tabManager
                for (workspaceIndex, workspace) in tabManager.tabs.enumerated() {
                    let paneIndexById = Dictionary(
                        uniqueKeysWithValues: workspace.bonsplitController.allPaneIds.enumerated().map {
                            ($0.element.id, $0.offset)
                        }
                    )
                    var selectedInPaneByPanelId: [UUID: Bool] = [:]
                    for paneId in workspace.bonsplitController.allPaneIds {
                        let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
                        for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                            selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
                        }
                    }

                    for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
                        guard let terminalPanel = panel as? TerminalPanel else { continue }
                        mappedLocations[ObjectIdentifier(terminalPanel.surface)] = MappedTerminalLocation(
                            windowIndex: windowIndex,
                            windowId: state.windowId,
                            window: state.window,
                            workspaceIndex: workspaceIndex,
                            workspaceSelected: workspace.id == tabManager.selectedTabId,
                            workspace: workspace,
                            terminalPanel: terminalPanel,
                            paneId: workspace.paneId(forPanelId: terminalPanel.id),
                            paneIndex: workspace.paneId(forPanelId: terminalPanel.id).flatMap { paneIndexById[$0.id] },
                            surfaceIndex: surfaceIndex,
                            selectedInPane: selectedInPaneByPanelId[terminalPanel.id],
                            bonsplitTabId: workspace.surfaceIdFromPanelId(terminalPanel.id)
                        )
                    }
                }
            }

            let surfaces = TerminalSurfaceRegistry.shared.allSurfaces()
            let terminals: [[String: Any]] = surfaces.enumerated().map { index, terminalSurface in
                let mapped = mappedLocations[ObjectIdentifier(terminalSurface)]
                let hostedView = terminalSurface.hostedView
                let hostedWindow = mapped?.window ?? terminalSurface.uiWindow
                let fallbackWindowMetadata = resolvedWindowMetadata(for: hostedWindow)
                let resolvedWindowId = mapped?.windowId ?? fallbackWindowMetadata.windowId
                let resolvedWindowIndex = mapped?.windowIndex ?? fallbackWindowMetadata.windowIndex
                let workspace = mapped?.workspace
                let panelId = mapped?.terminalPanel.id ?? terminalSurface.id
                let portalState = hostedView.portalBindingGuardState()
                let portalHostLease = terminalSurface.debugPortalHostLease()
                let gitBranchState = workspace?.panelGitBranches[panelId]
                let listeningPorts = (workspace?.surfaceListeningPorts[panelId] ?? []).sorted()
                let title = workspace?.panelTitle(panelId: panelId)
                let paneId = mapped?.paneId
                let treeVisible = mapped?.bonsplitTabId != nil && paneId != nil
                let ttyName = workspace?.surfaceTTYNames[panelId]
                let currentDirectory = nonEmpty(workspace?.panelDirectories[panelId] ?? mapped?.terminalPanel.directory)
                let teardownRequest = terminalSurface.debugTeardownRequest()
                let lastKnownWorkspaceId = terminalSurface.debugLastKnownWorkspaceId()

                var item: [String: Any] = [
                    "index": index,
                    "mapped": mapped != nil,
                    "tree_visible": treeVisible,
                    "window_index": v2OrNull(resolvedWindowIndex),
                    "window_id": v2OrNull(resolvedWindowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: resolvedWindowId),
                    "window_number": v2OrNull(hostedWindow?.windowNumber),
                    "window_key": hostedWindow?.isKeyWindow ?? false,
                    "window_main": hostedWindow?.isMainWindow ?? false,
                    "window_visible": hostedWindow?.isVisible ?? false,
                    "window_occluded": hostedWindow.map { !$0.occlusionState.contains(.visible) } ?? false,
                    "window_identifier": v2OrNull(hostedWindow?.identifier?.rawValue),
                    "window_title": v2OrNull(nonEmpty(hostedWindow?.title)),
                    "window_class": v2OrNull(className(hostedWindow)),
                    "window_delegate_class": v2OrNull(className(hostedWindow?.delegate as AnyObject?)),
                    "window_controller_class": v2OrNull(className(hostedWindow?.windowController)),
                    "window_level": v2OrNull(hostedWindow?.level.rawValue),
                    "window_frame": hostedWindow.map { rectPayload($0.frame) } ?? NSNull(),
                    "workspace_index": v2OrNull(mapped?.workspaceIndex),
                    "workspace_id": v2OrNull(workspace?.id.uuidString),
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace?.id),
                    "workspace_title": v2OrNull(workspace?.title),
                    "workspace_selected": v2OrNull(mapped?.workspaceSelected),
                    "pane_index": v2OrNull(mapped?.paneIndex),
                    "pane_id": v2OrNull(paneId?.id.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneId?.id),
                    "surface_index": v2OrNull(mapped?.surfaceIndex),
                    "surface_index_in_pane": v2OrNull(workspace?.indexInPane(forPanelId: panelId)),
                    "surface_id": panelId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: panelId),
                    "surface_title": v2OrNull(title),
                    "surface_focused": v2OrNull(workspace.map { panelId == $0.focusedPanelId }),
                    "surface_selected_in_pane": v2OrNull(mapped?.selectedInPane),
                    "surface_pinned": v2OrNull(workspace.map { $0.isPanelPinned(panelId) }),
                    "surface_context": terminalSurface.debugSurfaceContextLabel(),
                    "surface_created_at": v2OrNull(iso8601String(terminalSurface.debugCreatedAt())),
                    "surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugCreatedAt())),
                    "runtime_surface_created_at": v2OrNull(iso8601String(terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "runtime_surface_age_seconds": v2OrNull(ageSeconds(since: terminalSurface.debugRuntimeSurfaceCreatedAt())),
                    "bonsplit_tab_id": v2OrNull(mapped?.bonsplitTabId?.uuid.uuidString),
                    "terminal_object_ptr": objectPointerString(terminalSurface),
                    "ghostty_surface_ptr": ghosttyPointerString(terminalSurface.surface),
                    "runtime_surface_ready": terminalSurface.surface != nil,
                    "hosted_view_ptr": objectPointerString(hostedView),
                    "hosted_view_class": className(hostedView) ?? "nil",
                    "hosted_view_in_window": terminalSurface.isViewInWindow,
                    "hosted_view_in_headless_bootstrap_window": terminalSurface.isHeadlessStartupWindow(hostedView.window),
                    "hosted_view_has_superview": hostedView.superview != nil,
                    "hosted_view_hidden": hostedView.isHidden,
                    "hosted_view_hidden_or_ancestor_hidden": hostedView.isHiddenOrHasHiddenAncestor,
                    "hosted_view_alpha": hostedView.alphaValue,
                    "hosted_view_visible_in_ui": hostedView.debugPortalVisibleInUI,
                    "hosted_view_superview_chain": superviewClassChain(for: hostedView),
                    "surface_view_first_responder": hostedView.isSurfaceViewFirstResponder(),
                    "hosted_view_frame": rectPayload(hostedView.frame),
                    "hosted_view_bounds": rectPayload(hostedView.bounds),
                    "hosted_view_frame_in_window": rectPayload(hostedView.debugPortalFrameInWindow),
                    "portal_binding_state": portalState.state,
                    "portal_binding_generation": v2OrNull(portalState.generation),
                    "portal_host_id": v2OrNull(portalHostLease.hostId),
                    "portal_host_in_window": v2OrNull(portalHostLease.inWindow),
                    "portal_host_area": v2OrNull(portalHostLease.area.map(Double.init)),
                    "tty": v2OrNull(ttyName),
                    "current_directory": v2OrNull(currentDirectory),
                    "requested_working_directory": v2OrNull(nonEmpty(terminalSurface.requestedWorkingDirectory)),
                    "initial_command": v2OrNull(nonEmpty(terminalSurface.debugInitialCommand())),
                    "git_branch": v2OrNull(nonEmpty(gitBranchState?.branch)),
                    "git_dirty": v2OrNull(gitBranchState?.isDirty),
                    "listening_ports": listeningPorts,
                    "key_state_indicator": v2OrNull(nonEmpty(terminalSurface.currentKeyStateIndicatorText)),
                    "last_known_workspace_id": lastKnownWorkspaceId.uuidString,
                    "last_known_workspace_ref": v2Ref(kind: .workspace, uuid: lastKnownWorkspaceId),
                    "teardown_requested": teardownRequest.requestedAt != nil,
                    "teardown_requested_at": v2OrNull(iso8601String(teardownRequest.requestedAt)),
                    "teardown_requested_age_seconds": v2OrNull(ageSeconds(since: teardownRequest.requestedAt)),
                    "teardown_requested_reason": v2OrNull(nonEmpty(teardownRequest.reason))
                ]

                if title == nil, let fallbackTitle = mapped?.terminalPanel.displayTitle, !fallbackTitle.isEmpty {
                    item["surface_title"] = fallbackTitle
                }
                return item
            }

            payload = [
                "count": terminals.count,
                "terminals": terminals
            ]
        }

        guard let payload else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }

#if DEBUG
    /// DEBUG-only: force an on-disk session snapshot round-trip through
    /// `SurfaceMetadataStore` so `tests_v2/test_metadata_persistence.py`
    /// can prove real disk persistence (not just in-memory encode/decode).
    ///
    /// Phase 1 conceptually had `debug.session.round_trip` but it was not
    /// merged to main; Phase 2's persistence work is the first on-disk
    /// round-trip to need this harness. Gated `#if DEBUG` — not part of
    /// the supported socket API surface.
    private func v2DebugSessionSaveAndLoad(params _: [String: Any]) -> V2CallResult {
        var success = false
        v2MainSync {
            guard let app = AppDelegate.shared else { return }
            success = app.debugForceMetadataSaveAndLoad()
        }
        if success {
            return .ok(["ok": true])
        }
        return .err(code: "debug_save_and_load_failed",
                    message: "debugForceMetadataSaveAndLoad returned false", data: nil)
    }

    private func v2DebugShortcutSet(params: [String: Any]) -> V2CallResult {
        guard let name = v2String(params, "name"),
              let combo = v2String(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing name/combo", data: nil)
        }
        let resp = setShortcut("\(name) \(combo)")
        return resp == "OK"
            ? .ok([:])
            : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugShortcutSimulate(params: [String: Any]) -> V2CallResult {
        guard let combo = v2String(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing combo", data: nil)
        }
        let resp = simulateShortcut(combo)
        return resp == "OK"
            ? .ok([:])
            : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugType(params: [String: Any]) -> V2CallResult {
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "No window", data: nil)
        v2MainSync {
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else {
                result = .err(code: "not_found", message: "No window", data: nil)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            guard let fr = window.firstResponder else {
                result = .err(code: "not_found", message: "No first responder", data: nil)
                return
            }
            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = .ok([:])
                return
            }
            (fr as? NSResponder)?.insertText(text)
            result = .ok([:])
        }
        return result
    }

    private func v2DebugActivateApp() -> V2CallResult {
        let resp = activateApp()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugToggleCommandPalette(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        v2MainSync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: ["window_id": requestedWindowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteToggleRequested, object: targetWindow)
        }
        return result
    }

    private func v2DebugOpenCommandPaletteRenameTabInput(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        v2MainSync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameTabRequested, object: targetWindow)
        }
        return result
    }

    private func v2DebugCommandPaletteVisible(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visible = false
        v2MainSync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible
        ])
    }

    private func v2DebugCommandPaletteSelection(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visible = false
        var selectedIndex = 0
        v2MainSync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
            selectedIndex = AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowId) ?? 0
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible,
            "selected_index": max(0, selectedIndex)
        ])
    }

    private func v2DebugCommandPaletteResults(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let requestedLimit = params["limit"] as? Int
        let limit = max(1, min(100, requestedLimit ?? 20))

        var visible = false
        var selectedIndex = 0
        var snapshot = CommandPaletteDebugSnapshot.empty

        v2MainSync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
            selectedIndex = AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowId) ?? 0
            snapshot = AppDelegate.shared?.commandPaletteSnapshot(windowId: windowId) ?? .empty
        }

        let rows = Array(snapshot.results.prefix(limit)).map { row in
            [
                "command_id": row.commandId,
                "title": row.title,
                "shortcut_hint": v2OrNull(row.shortcutHint),
                "trailing_label": v2OrNull(row.trailingLabel),
                "score": row.score
            ] as [String: Any]
        }

        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible,
            "selected_index": max(0, selectedIndex),
            "query": snapshot.query,
            "mode": snapshot.mode,
            "results": rows
        ])
    }

    private func v2DebugCommandPaletteRenameInputInteraction(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        v2MainSync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameInputInteractionRequested, object: targetWindow)
        }
        return result
    }

    private func v2DebugCommandPaletteRenameInputDeleteBackward(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        v2MainSync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameInputDeleteBackwardRequested, object: targetWindow)
        }
        return result
    }

    private func v2DebugCommandPaletteRenameInputSelection(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }

        var result: V2CallResult = .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "focused": false,
            "selection_location": 0,
            "selection_length": 0,
            "text_length": 0
        ])

        v2MainSync {
            guard let window = AppDelegate.shared?.mainWindow(for: windowId) else {
                result = .err(
                    code: "not_found",
                    message: "Window not found",
                    data: ["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)]
                )
                return
            }
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
                return
            }
            let selectedRange = editor.selectedRange()
            let textLength = (editor.string as NSString).length
            result = .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "focused": true,
                "selection_location": max(0, selectedRange.location),
                "selection_length": max(0, selectedRange.length),
                "text_length": max(0, textLength)
            ])
        }

        return result
    }

    private func v2DebugCommandPaletteRenameInputSelectAll(params: [String: Any]) -> V2CallResult {
        if let rawEnabled = params["enabled"] {
            guard let enabled = rawEnabled as? Bool else {
                return .err(
                    code: "invalid_params",
                    message: "enabled must be a bool",
                    data: ["enabled": rawEnabled]
                )
            }
            v2MainSync {
                UserDefaults.standard.set(
                    enabled,
                    forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey
                )
            }
        }

        var enabled = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
        v2MainSync {
            enabled = CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled()
        }

        return .ok([
            "enabled": enabled
        ])
    }

    private func v2DebugBrowserAddressBarFocused(params: [String: Any]) -> V2CallResult {
        let requestedSurfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "panel_id")
        var focusedSurfaceId: UUID?
        v2MainSync {
            focusedSurfaceId = AppDelegate.shared?.focusedBrowserAddressBarPanelId()
        }

        var payload: [String: Any] = [
            "focused_surface_id": v2OrNull(focusedSurfaceId?.uuidString),
            "focused_surface_ref": v2Ref(kind: .surface, uuid: focusedSurfaceId),
            "focused_panel_id": v2OrNull(focusedSurfaceId?.uuidString),
            "focused_panel_ref": v2Ref(kind: .surface, uuid: focusedSurfaceId),
            "focused": focusedSurfaceId != nil
        ]

        if let requestedSurfaceId {
            payload["surface_id"] = requestedSurfaceId.uuidString
            payload["surface_ref"] = v2Ref(kind: .surface, uuid: requestedSurfaceId)
            payload["panel_id"] = requestedSurfaceId.uuidString
            payload["panel_ref"] = v2Ref(kind: .surface, uuid: requestedSurfaceId)
            payload["focused"] = (focusedSurfaceId == requestedSurfaceId)
        }

        return .ok(payload)
    }

    private func v2DebugBrowserFavicon(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let pngData = browserPanel.faviconPNGData
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "has_favicon": pngData != nil,
                "png_base64": pngData?.base64EncodedString() ?? "",
                "current_url": v2OrNull(browserPanel.currentURL?.absoluteString)
            ])
        }
    }

    private func v2DebugSidebarVisible(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visibility: Bool?
        v2MainSync {
            visibility = AppDelegate.shared?.sidebarVisibility(windowId: windowId)
        }
        guard let visible = visibility else {
            return .err(
                code: "not_found",
                message: "Window not found",
                data: ["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)]
            )
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible
        ])
    }

    private func v2DebugIsTerminalFocused(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = isTerminalFocused(surfaceId)
        if resp.hasPrefix("ERROR") {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        return .ok(["focused": resp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"])
    }

    private func v2DebugReadTerminalText(params: [String: Any]) -> V2CallResult {
        let surfaceArg = v2String(params, "surface_id") ?? ""
        let resp = readTerminalText(surfaceArg)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let b64 = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .ok(["base64": b64])
    }

    private func v2DebugRenderStats(params: [String: Any]) -> V2CallResult {
        let surfaceArg = v2String(params, "surface_id") ?? ""
        let resp = renderStats(surfaceArg)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .err(code: "internal_error", message: "render_stats JSON decode failed", data: ["payload": String(jsonStr.prefix(200))])
        }
        return .ok(["stats": obj])
    }

    private func v2DebugLayout() -> V2CallResult {
        let resp = layoutDebug()
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .err(code: "internal_error", message: "layout_debug JSON decode failed", data: ["payload": String(jsonStr.prefix(200))])
        }
        return .ok(["layout": obj])
    }

    private func v2DebugPortalStats() -> V2CallResult {
        let payload: [String: Any] = v2MainSync {
            TerminalWindowPortalRegistry.debugPortalStats()
        }
        return .ok(payload)
    }

    private func v2DebugBonsplitUnderflowCount() -> V2CallResult {
        let resp = bonsplitUnderflowCount()
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    private func v2DebugResetBonsplitUnderflowCount() -> V2CallResult {
        let resp = resetBonsplitUnderflowCount()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugEmptyPanelCount() -> V2CallResult {
        let resp = emptyPanelCount()
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    private func v2DebugResetEmptyPanelCount() -> V2CallResult {
        let resp = resetEmptyPanelCount()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugFocusNotification(params: [String: Any]) -> V2CallResult {
        guard let wsId = v2String(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let surfaceId = v2String(params, "surface_id")
        let args = surfaceId != nil ? "\(wsId) \(surfaceId!)" : wsId
        let resp = focusFromNotification(args)
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugFlashCount(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = flashCount(surfaceId)
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    private func v2DebugResetFlashCounts() -> V2CallResult {
        let resp = resetFlashCounts()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugPanelSnapshot(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let label = v2String(params, "label") ?? ""
        let args = label.isEmpty ? surfaceId : "\(surfaceId) \(label)"
        let resp = panelSnapshot(args)
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 4).map(String.init)
        guard parts.count == 5 else {
            return .err(code: "internal_error", message: "panel_snapshot parse failed", data: ["payload": payload])
        }
        return .ok([
            "surface_id": parts[0],
            "changed_pixels": Int(parts[1]) ?? -1,
            "width": Int(parts[2]) ?? 0,
            "height": Int(parts[3]) ?? 0,
            "path": parts[4]
        ])
    }

    private func v2DebugPanelSnapshotReset(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = panelSnapshotReset(surfaceId)
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    private func v2DebugScreenshot(params: [String: Any]) -> V2CallResult {
        let label = v2String(params, "label") ?? ""
        let resp = captureScreenshot(label)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return .err(code: "internal_error", message: "screenshot parse failed", data: ["payload": payload])
        }
        return .ok([
            "screenshot_id": parts[0],
            "path": parts[1]
        ])
    }

    /// Test-only: snapshot the resolved workspace and immediately restore the
    /// snapshot onto the same workspace. Phase 1 uses this to assert that panel
    /// UUIDs survive the round-trip without a full app restart.
    ///
    /// Returns `{ "before": [uuid,...], "after": [uuid,...] }` — callers
    /// compare the sets to verify stability.
    private func v2DebugSessionRoundTrip(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var before: [String] = []
        var after: [String] = []
        var failureMessage: String?
        v2MainSync {
            guard let workspace = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                failureMessage = "workspace_not_found"
                return
            }
            before = workspace.panels.keys.map { $0.uuidString }.sorted()
            let snapshot = workspace.sessionSnapshot(includeScrollback: false)
            workspace.restoreSessionSnapshot(snapshot)
            after = workspace.panels.keys.map { $0.uuidString }.sorted()
        }
        if let failureMessage {
            return .err(code: "workspace_not_found", message: failureMessage, data: nil)
        }
        return .ok([
            "before": before,
            "after": after
        ])
    }

    /// Phase 1.5 workspace-id round-trip: snapshot the entire `TabManager`
    /// (all workspaces in the target window), then restore it in place.
    /// Returns the ordered workspace UUIDs before and after so callers can
    /// assert that workspace IDs survive a save/load cycle.
    private func v2DebugSessionRoundTripWorkspaces(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var before: [String] = []
        var after: [String] = []
        v2MainSync {
            before = tabManager.tabs.map { $0.id.uuidString }
            let snapshot = tabManager.sessionSnapshot(includeScrollback: false)
            tabManager.restoreSessionSnapshot(snapshot)
            after = tabManager.tabs.map { $0.id.uuidString }
        }
        return .ok([
            "before": before,
            "after": after
        ])
    }

#endif
}
