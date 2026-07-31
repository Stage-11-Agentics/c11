import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation
import Bonsplit
import WebKit

// C11-159: the socket command dispatch, relocated verbatim out of
// TerminalController.swift. Holds the v1 (`processCommand`) and v2
// (`processV2Command`) entry points, the off-main socket-worker fast paths, the
// pure parser helpers, and the v2DispatchExtracted per-domain router. Threading
// tiers are preserved exactly: nonisolated members stay nonisolated (off-main);
// processCommand/processV2Command stay main-actor. Mechanical relocation only.
extension TerminalController {
    private nonisolated func parseV2SocketRequest(_ command: String) -> V2SocketRequest? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !method.isEmpty else {
            return nil
        }

        return V2SocketRequest(
            id: dict["id"],
            method: method,
            params: dict["params"] as? [String: Any] ?? [:]
        )
    }

    private nonisolated func socketWorkerV2ResponseIfNeeded(for command: String) -> String? {
        guard let request = parseV2SocketRequest(command),
              Self.executionPolicy(forV2Method: request.method) == .socketWorker else {
            return nil
        }

        return withSocketCommandPolicy(commandKey: request.method, isV2: true) {
            socketWorkerV2Response(request)
        }
    }

    nonisolated func socketWorkerV2Response(_ request: V2SocketRequest) -> String {
        // C11-26 review M1: emit the off-main diagnostic at the dispatcher seam
        // so future migrated methods get it for free instead of "we forgot."
        #if DEBUG
        dlog("v2.\(request.method) isMain=\(Thread.isMainThread) tid=\(pthread_mach_thread_np(pthread_self()))")
        #endif

        switch request.method {
        case "surface.send_text":
            return v2Result(id: request.id, v2SurfaceSendText(params: request.params))
        case "surface.send_key":
            return v2Result(id: request.id, v2SurfaceSendKey(params: request.params))
        case "surface.read_text":
            return v2Result(id: request.id, v2SurfaceReadText(params: request.params))
        case "surface.clear_history":
            return v2Result(id: request.id, v2SurfaceClearHistory(params: request.params))
        // C11-165 COR-3: off-main handlers that block on a user click / async
        // submission. Each must have a matching entry in socketWorkerV2Methods;
        // a mismatch here would return method_not_found instead of executing.
        case "pane.confirm":
            return v2Result(id: request.id, v2PaneConfirm(params: request.params))
        case "feedback.submit":
            return v2Result(id: request.id, v2FeedbackSubmit(params: request.params))
        // C11-180: config reads/mutations run off-main (pure file I/O).
        case "config.list", "config.recent", "config.stats",
             "config.save", "config.edit", "config.rm", "config.reorder", "config.default":
            return v2Result(id: request.id, TerminalController.v2ConfigNonLaunch(method: request.method, params: request.params))
        case "flag.raise", "flag.lower", "flag.list", "flag.suppress", "flag.unsuppress":
            return v2Result(
                id: request.id,
                self.v2FlagWorker(method: request.method, params: request.params)
            )
        case "agent.ingest":
            return v2Result(id: request.id, self.v2AgentIngest(params: request.params))
        default:
            return v2Error(id: request.id, code: "method_not_found", message: "Unknown method")
        }
    }

    nonisolated func processCommandUsingSocketExecutionPolicy(_ command: String) -> String {
        if let response = Self.socketWorkerImmediateV1Response(command) {
            return withSocketCommandPolicy(commandKey: "ping", isV2: false) {
                response
            }
        }

        if let response = socketWorkerV2ResponseIfNeeded(for: command) {
            return response
        }

        if let response = socketWorkerV1ResponseIfNeeded(for: command) {
            return response
        }

        if let response = asyncAckResponseIfNeeded(for: command) {
            return response
        }

        if Thread.isMainThread {
            return MainActor.assumeIsolated { self.processCommand(command) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.processCommand(command) }
        }
    }

    /// Context-free v1 commands that can answer entirely on the socket worker.
    ///
    /// The bundled agent wrappers use `ping` as a bounded startup gate before
    /// installing their lifecycle hooks. Routing that probe through the main
    /// actor made rapid A-button launches fail open whenever surface creation
    /// kept the UI busy for longer than the wrapper's 750 ms timeout.
    nonisolated static func socketWorkerImmediateV1Response(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return nil }
        let head = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.lowercased()
        guard head == "ping" else { return nil }
        return "PONG"
    }

    /// C11-156: ack a fire-and-forget telemetry command off-main and apply its
    /// mutation via `main.async`, instead of blocking a socket-worker thread on
    /// `DispatchQueue.main.sync`. Returns nil for anything not in
    /// `asyncAckV1Commands` (and for v2/JSON requests) so the dispatcher falls
    /// through to its normal path. The existing `@MainActor` handler is reused
    /// verbatim — only the scheduling changes — so behaviour is identical
    /// except that the caller is acked before the mutation lands, which is safe
    /// precisely because these handlers return a bare "OK" the hook discards.
    private nonisolated func asyncAckResponseIfNeeded(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return nil }
        let head = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        guard Self.asyncAckV1Commands.contains(head) else { return nil }

        DispatchQueue.main.async {
            MainActor.assumeIsolated { _ = self.processCommand(command) }
        }
        return "OK"
    }

    /// v1 telemetry worker entry. Parses head and args off-main, checks the
    /// allowlist, and routes to a per-command worker variant when the args
    /// carry an explicit `--tab=`/`--panel=` selector. Returns nil to make
    /// the dispatcher fall through to the existing main-sync path when:
    ///   - The command is not a v1 telemetry command we know how to migrate.
    ///   - The args do not contain an explicit selector (handler would need
    ///     a focused-tab read, which requires a main hop anyway — the
    ///     current main-sync path already handles that correctly).
    private nonisolated func socketWorkerV1ResponseIfNeeded(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return nil }
        let head = parts[0].lowercased()
        guard Self.socketWorkerV1Commands.contains(head) else { return nil }
        let args = parts.count > 1 ? parts[1] : ""

        return withSocketCommandPolicy(commandKey: head, isV2: false) {
            socketWorkerV1Response(head: head, args: args)
        }
    }

    /// Dispatch a v1 telemetry command to its nonisolated worker variant.
    /// Each variant returns nil if the command must fall through to the
    /// main-actor path (slow-path callers without an explicit selector).
    private nonisolated func socketWorkerV1Response(head: String, args: String) -> String? {
        switch head {
        case "report_pwd":
            return reportPwdWorker(args)
        case "report_shell_state":
            return reportShellStateWorker(args)
        case "report_agent_activity":
            return reportAgentActivityWorker(args)
        case "report_git_branch":
            return reportGitBranchWorker(args)
        case "clear_git_branch":
            return clearGitBranchWorker(args)
        case "ports_kick":
            return portsKickWorker(args)
        case "agent_kick":
            return agentKickWorker(args)
        default:
            return nil
        }
    }

    nonisolated static func tokenizeArgsStatic(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    nonisolated static func parseOptionsStatic(
        _ args: String
    ) -> (positional: [String], options: [String: String]) {
        let tokens = tokenizeArgsStatic(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = true
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    private nonisolated func reportPwdWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing path — usage: report_pwd <path> [--tab=X] [--panel=Y]"
        }

        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        // Note: the @MainActor `reportPwd` early-returns "ERROR: TabManager
        // not available" when `self.tabManager` is nil. The worker variant
        // skips that guard intentionally — when `--tab=<uuid>` is provided,
        // we resolve the manager via `AppDelegate.shared?.tabManagerFor(...)`
        // below, which finds the correct manager regardless of the
        // controller's bound `tabManager`. The visible behavioral diff is
        // "ERROR: TabManager not available" → silent async no-op when
        // neither path can resolve a manager. In practice this fires only
        // before the app finishes wiring its TabManager, well before any
        // socket accepts commands.
        let directory = parsed.positional.joined(separator: " ")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.updateSurfaceDirectory(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId,
                    directory: directory
                )
            }
        }
        return "OK"
    }

    private nonisolated func reportShellStateWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let rawState = parsed.positional.first, !rawState.isEmpty else {
            return "ERROR: Missing shell state — usage: report_shell_state <prompt|running> [--tab=X] [--panel=Y]"
        }
        guard let state = Self.parseReportedShellActivityState(rawState) else {
            return "ERROR: Invalid shell state '\(rawState)' — expected prompt or running"
        }

        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        guard Self.socketFastPathState.shouldPublishShellActivity(
            workspaceId: scope.workspaceId,
            panelId: scope.panelId,
            state: state
        ) else {
            return "OK"
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let app = AppDelegate.shared else { return }
                // C11-171: resolve the workspace from the PANEL, not from `--tab`
                // (shell integration sends the surface uuid in `--tab`). Without
                // this the report silently no-ops and derived liveness never fires.
                guard let target = TerminalController.resolveShellActivityTarget(
                    panelId: scope.panelId,
                    workspaceForPanel: { panel in
                        app.workspaceContainingPanel(
                            panelId: panel,
                            preferredWorkspaceId: scope.workspaceId
                        )?.workspace.id
                    }
                ), let tabManager = app.tabManagerFor(tabId: target.workspaceId) else { return }
                tabManager.updateSurfaceShellActivity(
                    tabId: target.workspaceId,
                    surfaceId: target.panelId,
                    state: state
                )
            }
        }
        return "OK"
    }

    private nonisolated func reportAgentActivityWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let rawActivity = parsed.positional.first, !rawActivity.isEmpty else {
            return "ERROR: Missing agent activity — usage: report_agent_activity <working|idle> [--tab=X] [--panel=Y]"
        }
        guard let activity = Self.parseReportedAgentActivity(rawActivity) else {
            return "ERROR: Invalid agent activity '\(rawActivity)' — expected working or idle"
        }
        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let app = AppDelegate.shared else { return }
                guard let target = TerminalController.resolveShellActivityTarget(
                    panelId: scope.panelId,
                    workspaceForPanel: { panel in
                        app.workspaceContainingPanel(
                            panelId: panel,
                            preferredWorkspaceId: scope.workspaceId
                        )?.workspace.id
                    }
                ) else { return }
                SurfaceLivenessDeriver.onAgentLifecycleChanged(
                    surfaceId: target.panelId,
                    workspaceId: target.workspaceId,
                    activity: activity
                )
            }
        }
        return "OK"
    }

    private nonisolated func reportGitBranchWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let branch = parsed.positional.first else {
            return "ERROR: Missing branch name — usage: report_git_branch <branch> [--status=dirty] [--tab=X]"
        }
        let isDirty = parsed.options["status"]?.lowercased() == "dirty"

        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.updateSurfaceGitBranch(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId,
                    branch: branch,
                    isDirty: isDirty
                )
            }
        }
        return "OK"
    }

    private nonisolated func clearGitBranchWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                tabManager.clearSurfaceGitBranch(
                    tabId: scope.workspaceId,
                    surfaceId: scope.panelId
                )
            }
        }
        return "OK"
    }

    private nonisolated func portsKickWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                PortScanner.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
            }
        }
        return "OK"
    }

    private nonisolated func agentKickWorker(_ args: String) -> String? {
        let parsed = Self.parseOptionsStatic(args)
        guard let scope = Self.explicitSocketScope(options: parsed.options) else {
            return nil
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId),
                      let tab = tabManager.tabs.first(where: { $0.id == scope.workspaceId }) else {
                    return
                }
                let validSurfaceIds = Set(tab.panels.keys)
                guard validSurfaceIds.contains(scope.panelId) else { return }
                AgentDetector.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
            }
        }
        return "OK"
    }

    func processCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Empty command" }

        // v2 protocol: newline-delimited JSON.
        if trimmed.hasPrefix("{") {
            return processV2Command(trimmed)
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else { return "ERROR: Empty command" }

        let cmd = parts[0].lowercased()
        let args = parts.count > 1 ? parts[1] : ""

        return withSocketCommandPolicy(commandKey: cmd, isV2: false) {
            switch cmd {
        case "ping":
            return "PONG"

        case "auth":
            return "OK: Authentication not required"

        case "list_windows":
            return listWindows()

        case "current_window":
            return currentWindow()

        case "focus_window":
            return focusWindow(args)

        case "new_window":
            return newWindow()

        case "close_window":
            return closeWindow(args)

        case "move_workspace_to_window":
            return moveWorkspaceToWindow(args)

        case "list_workspaces":
            return listWorkspaces()

	        case "new_workspace":
	            return newWorkspace()

	        case "new_split":
	            return newSplit(args)

        case "list_surfaces":
            return listSurfaces(args)

        case "focus_surface":
            return focusSurface(args)

        case "close_workspace":
            return closeWorkspace(args)

        case "select_workspace":
            return selectWorkspace(args)

        case "current_workspace":
            return currentWorkspace()

        case "send":
            return sendInput(args)

        case "send_key":
            return sendKey(args)

        case "send_surface":
            return sendInputToSurface(args)

        case "send_key_surface":
            return sendKeyToSurface(args)

        case "notify":
            return notifyCurrent(args)

        case "notify_surface":
            return notifySurface(args)

        case "notify_target":
            return notifyTarget(args)

        case "list_notifications":
            return listNotifications()

        case "clear_notifications":
            return clearNotifications(args)

        case "set_app_focus":
            return setAppFocusOverride(args)

        case "simulate_app_active":
            return simulateAppDidBecomeActive()

        case "set_status":
            return setStatus(args)

        case "report_meta":
            return reportMeta(args)

        case "report_meta_block":
            return reportMetaBlock(args)

        case "clear_status":
            return clearStatus(args)

        case "set_agent_pid":
            return setAgentPID(args)

        case "clear_agent_pid":
            return clearAgentPID(args)

        case "clear_meta":
            return clearMeta(args)

        case "clear_meta_block":
            return clearMetaBlock(args)

        case "list_status":
            return listStatus(args)

        case "list_meta":
            return listMeta(args)

        case "list_meta_blocks":
            return listMetaBlocks(args)

        case "log":
            return appendLog(args)

        case "clear_log":
            return clearLog(args)

        case "list_log":
            return listLog(args)

        case "set_progress":
            return setProgress(args)

        case "clear_progress":
            return clearProgress(args)

        case "report_git_branch":
            return reportGitBranch(args)

        case "clear_git_branch":
            return clearGitBranch(args)

        case "report_pr":
            return reportPullRequest(args)

        case "report_review":
            return reportPullRequest(args)

        case "clear_pr":
            return clearPullRequest(args)

        case "report_ports":
            return reportPorts(args)

        case "clear_ports":
            return clearPorts(args)

        case "report_tty":
            return reportTTY(args)

        case "ports_kick":
            return portsKick(args)

        case "agent_kick":
            return agentKick(args)

        case "report_shell_state":
            return reportShellState(args)

        case "report_agent_activity":
            return reportAgentActivity(args)

        case "report_pwd":
            return reportPwd(args)

        case "sidebar_state":
            return sidebarState(args)

        case "reset_sidebar":
            return resetSidebar(args)

        case "read_screen":
            return readScreenText(args)


#if DEBUG
        case "send_workspace":
            return sendInputToWorkspace(args)

        case "set_shortcut":
            return setShortcut(args)

        case "simulate_shortcut":
            return simulateShortcut(args)

        case "simulate_type":
            return simulateType(args)

        case "simulate_file_drop":
            return simulateFileDrop(args)

        case "seed_drag_pasteboard_fileurl":
            return seedDragPasteboardFileURL()

        case "seed_drag_pasteboard_tabtransfer":
            return seedDragPasteboardTabTransfer()

        case "seed_drag_pasteboard_sidebar_reorder":
            return seedDragPasteboardSidebarReorder()

        case "seed_drag_pasteboard_types":
            return seedDragPasteboardTypes(args)

        case "clear_drag_pasteboard":
            return clearDragPasteboard()

        case "drop_hit_test":
            return dropHitTest(args)

        case "drag_hit_chain":
            return dragHitChain(args)

        case "overlay_hit_gate":
            return overlayHitGate(args)

        case "overlay_drop_gate":
            return overlayDropGate(args)

        case "portal_hit_gate":
            return portalHitGate(args)

        case "sidebar_overlay_gate":
            return sidebarOverlayGate(args)

        case "terminal_drop_overlay_probe":
            return terminalDropOverlayProbe(args)

        case "activate_app":
            return activateApp()

        case "is_terminal_focused":
            return isTerminalFocused(args)

        case "read_terminal_text":
            return readTerminalText(args)

        case "render_stats":
            return renderStats(args)

        case "layout_debug":
            return layoutDebug()

        case "bonsplit_underflow_count":
            return bonsplitUnderflowCount()

        case "reset_bonsplit_underflow_count":
            return resetBonsplitUnderflowCount()

        case "empty_panel_count":
            return emptyPanelCount()

        case "reset_empty_panel_count":
            return resetEmptyPanelCount()

        case "focus_notification":
            return focusFromNotification(args)

        case "flash_count":
            return flashCount(args)

        case "reset_flash_counts":
            return resetFlashCounts()

        case "panel_snapshot":
            return panelSnapshot(args)

        case "panel_snapshot_reset":
            return panelSnapshotReset(args)

        case "screenshot":
            return captureScreenshot(args)
#endif

        case "help":
            return helpText()

        // Browser panel commands
        case "open_browser":
            return openBrowser(args)

        case "navigate":
            return navigateBrowser(args)

        case "browser_back":
            return browserBack(args)

        case "browser_forward":
            return browserForward(args)

        case "browser_reload":
            return browserReload(args)

        case "get_url":
            return getUrl(args)

        case "focus_webview":
            return focusWebView(args)

        case "is_webview_focused":
            return isWebViewFocused(args)

        case "list_panes":
            return listPanes()

        case "list_pane_surfaces":
            return listPaneSurfaces(args)

	        case "focus_pane":
	            return focusPane(args)

	        case "focus_surface_by_panel":
	            return focusSurfaceByPanel(args)

	        case "drag_surface_to_split":
	            return dragSurfaceToSplit(args)

	        case "new_pane":
	            return newPane(args)

        case "new_surface":
            return newSurface(args)

        // C11-14: read/write the default agent + per-agent configuration. Same
        // store the Settings UI binds to; live updates fan out via UserDefaults.
        case "default_agent":
            return defaultAgentCommand(args)

        case "agent_config":
            return agentConfigCommand(args)

        case "close_surface":
            return closeSurface(args)

        case "reload_config":
            return reloadConfig(args)

        case "refresh_surfaces":
            return refreshSurfaces()

            case "surface_health":
                return surfaceHealth(args)

            default:
                return "ERROR: Unknown command '\(cmd)'. Use 'help' for available commands."
            }
        }
    }

    func processV2Command(_ jsonLine: String) -> String {
        // v1 access-mode gating applies to v2 as well. We can't know which v2 method maps
        // to which v1 command without parsing, so parse first and then apply allow-list.

        guard let data = jsonLine.data(using: .utf8) else {
            return v2Encode(["ok": false, "error": ["code": "invalid_utf8", "message": "Invalid UTF-8"]])
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return v2Encode(["ok": false, "error": ["code": "parse_error", "message": "Invalid JSON"]])
        }

        guard let dict = object as? [String: Any] else {
            return v2Encode(["ok": false, "error": ["code": "invalid_request", "message": "Expected JSON object"]])
        }

        let id: Any? = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let params = dict["params"] as? [String: Any] ?? [:]

        guard !method.isEmpty else {
            return v2Error(id: id, code: "invalid_request", message: "Missing method")
        }

        // C11-26: Methods on the socket-worker policy must be dispatched via
        // socketWorkerV2Response (off main); reaching processV2Command for one of
        // them means the routing layer mis-targeted the request, and falling
        // through to the main-actor handler would re-introduce the deadlock the
        // worker policy exists to avoid.
        guard Self.executionPolicy(forV2Method: method) == .mainActor else {
            // C11-26 review M2: in DEBUG, this routing bug should fail loudly so
            // CI catches it before it ships. Release-mode behavior (return an
            // invalid_dispatch error) is unchanged.
            #if DEBUG
            dlog("v2.invalid_dispatch method=\(method) — worker-policy method reached processV2Command")
            assertionFailure("\(method) is on the socket-worker policy and must not reach processV2Command")
            #endif
            return v2Error(
                id: id,
                code: "invalid_dispatch",
                message: "\(method) must run on the socket worker"
            )
        }

        v2MainSync { self.v2RefreshKnownRefs() }


        return withSocketCommandPolicy(commandKey: method, isV2: true) {
            // surface.send_text / send_key / read_text / clear_history run on the
            // socket worker (off-main) via socketWorkerV2Response; the invalid_dispatch
            // guard above catches any mis-routed request before it reaches here.
            // All other methods route to their per-domain handler unit under
            // Sources/SocketHandlers/ via the v2DispatchExtracted seam (C11-159).
            if let extracted = v2DispatchExtracted(method, id: id, params: params) {
                return extracted
            }
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    /// C11-159 dispatcher seam (v2). Routes a method whose per-domain handler
    /// unit lives under `Sources/SocketHandlers/` by its domain prefix. Returns
    /// nil only when no relocated domain owns the prefix, so the caller falls
    /// back to the identical `method_not_found` response. This is the handler
    /// seam DX-1 asks for; the router (parse/auth-gate/policy/main-sync) is
    /// unchanged. Runs on the main actor exactly like the switch it replaces.
    func v2DispatchExtracted(_ method: String, id: Any?, params: [String: Any]) -> String? {
        if method.hasPrefix("agent.") { return v2DispatchAgent(method, id: id, params: params) }
        if method.hasPrefix("config.") { return v2DispatchConfig(method, id: id, params: params) }
        if method.hasPrefix("window.") { return v2DispatchWindow(method, id: id, params: params) }
        if method.hasPrefix("workspace.") { return v2DispatchWorkspace(method, id: id, params: params) }
        if method.hasPrefix("pane.") { return v2DispatchPane(method, id: id, params: params) }
        if method.hasPrefix("surface.") { return v2DispatchSurface(method, id: id, params: params) }
        if method.hasPrefix("debug.") { return v2DispatchDebug(method, id: id, params: params) }
        if method.hasPrefix("browser.") { return v2DispatchBrowser(method, id: id, params: params) }
        if method.hasPrefix("theme.") { return v2DispatchTheme(method, id: id, params: params) }
        if method.hasPrefix("system.") || method.hasPrefix("auth.") || method.hasPrefix("app.") { return v2DispatchSystem(method, id: id, params: params) }
        if method.hasPrefix("snapshot.") { return v2DispatchSnapshot(method, id: id, params: params) }
        if method.hasPrefix("conversation.") { return v2DispatchConversation(method, id: id, params: params) }
        if method.hasPrefix("notification.") { return v2DispatchNotification(method, id: id, params: params) }
        if method.hasPrefix("flag.") { return v2Error(id: id, code: "invalid_dispatch", message: "\(method) must run on the socket worker") }
        if method.hasPrefix("markdown.") || method.hasPrefix("feedback.") { return v2DispatchMarkdownFeedback(method, id: id, params: params) }
        if method.hasPrefix("settings.") || method.hasPrefix("sidebar.") || method.hasPrefix("session.") || method.hasPrefix("tab.") || method.hasPrefix("mailbox.") { return v2DispatchMisc(method, id: id, params: params) }
        return nil
    }

}

// MARK: - agent.* domain (launch-agent)

extension TerminalController {
    /// v2 dispatch slice for the `agent.*` domain — the typed-agent launch
    /// primitive behind `c11 launch-agent` (docs/launch-agent-reference.md).
    func v2DispatchAgent(_ method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "agent.launch":
            return v2Result(id: id, self.v2AgentLaunch(params: params))
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    /// `agent.launch` — resolve a typed agent's launch plan, create the target
    /// surface (pane / workspace / fresh workspace), inject the identity env,
    /// stamp metadata, and type the composed command, atomically server-side.
    /// Parsing/planning runs off-main; only surface creation + stamping is
    /// main-synced (socket threading policy).
    func v2AgentLaunch(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let kindRaw = v2RawString(params, "type")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !kindRaw.isEmpty else {
            return .err(code: "invalid_params", message: "Missing required param: type", data: nil)
        }

        let launchFlagReason: String?
        if params["flag"] != nil {
            switch SurfaceAttentionReason.validate(params["flag"]) {
            case .success(let reason):
                launchFlagReason = reason
            case .failure(let error):
                return .err(code: "invalid_params", message: error.message, data: error.detailData)
            }
        } else {
            launchFlagReason = nil
        }
        let launchFlagActor: SurfaceAttentionActor
        if let rawActor = params["by"] as? String {
            guard let parsed = SurfaceAttentionActor(rawValue: rawActor) else {
                return .err(
                    code: "invalid_params",
                    message: "by must be one of: operator, agent",
                    data: nil
                )
            }
            launchFlagActor = parsed
        } else {
            launchFlagActor = .operator
        }
        let launchCallerSurfaceId: UUID?
        if let rawCaller = params["caller_surface_id"] as? String {
            let trimmedCaller = rawCaller.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCaller.isEmpty, let parsed = UUID(uuidString: trimmedCaller) else {
                return .err(
                    code: "invalid_params",
                    message: "caller_surface_id must be a UUID",
                    data: nil
                )
            }
            launchCallerSurfaceId = parsed
        } else if params["caller_surface_id"] != nil {
            return .err(
                code: "invalid_params",
                message: "caller_surface_id must be a UUID",
                data: nil
            )
        } else {
            launchCallerSurfaceId = nil
        }
        if launchFlagReason != nil,
           launchFlagActor == .agent,
           launchCallerSurfaceId == nil {
            return .err(
                code: "missing_caller_surface",
                message: "agent-raised flags require caller_surface_id",
                data: nil
            )
        }
        if params["suppressed"] != nil, !(params["suppressed"] is Bool) {
            return .err(code: "invalid_params", message: "suppressed must be a boolean", data: nil)
        }
        let launchSuppressed = params["suppressed"] as? Bool ?? false

        let newWorkspace = v2Bool(params, "new_workspace") ?? false
        let paneParam = v2UUID(params, "pane_id")
        if newWorkspace && (paneParam != nil || params["workspace_id"] != nil) {
            return .err(code: "invalid_params", message: "new_workspace is mutually exclusive with pane_id/workspace_id", data: nil)
        }

        var cwdOverride: String?
        if let err = v2ResolveCwdParam(params, resolved: &cwdOverride) {
            return err
        }

        // Config + (for custom kinds) template I/O happens here, off-main.
        let lookupCwd = cwdOverride ?? FileManager.default.currentDirectoryPath
        let userDefault = DefaultAgentConfigStore.shared.current
        let projectConfig = DefaultAgentProjectConfig.find(from: lookupCwd)
        let userTemplate: UserAgentLaunchTemplate? =
            AgentType(rawValue: kindRaw) == nil ? UserAgentLaunchTemplate.load(kind: kindRaw) : nil

        // System prompt (append/replace/inherit + free-form text). The mode
        // gates the axis; text may be empty (blank slate on replace). An
        // unparseable mode string maps to nil (no override) rather than erroring
        // here — the planner is the single validation authority for the axis.
        var systemPromptSetting: SystemPromptSetting?
        if let modeRaw = v2RawString(params, "system_prompt_mode")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let mode = SystemPromptSetting.Mode(rawValue: modeRaw.lowercased()) {
            systemPromptSetting = SystemPromptSetting(mode: mode, text: v2RawString(params, "system_prompt") ?? "")
        }

        let request = AgentLaunchRequest(
            kind: kindRaw,
            model: v2RawString(params, "model"),
            effort: v2RawString(params, "effort"),
            task: v2RawString(params, "task"),
            prompt: v2RawString(params, "prompt"),
            systemPrompt: systemPromptSetting,
            extraEnv: v2StringMap(params, "env") ?? [:],
            // C11-180: `config launch` rides its saved config's full-command
            // recipe field through here so this stays the one launch composer.
            commandOverride: v2RawString(params, "command_override")
        )
        let plan: AgentLaunchPlan
        switch AgentLaunchPlanner.plan(
            request: request,
            userDefault: userDefault,
            projectConfig: projectConfig,
            userTemplate: userTemplate
        ) {
        case .failure(let error):
            return .err(code: error.code, message: error.message, data: nil)
        case .success(let composed):
            plan = composed
        }

        var warnings = plan.warnings
        if let binaryWarning = Self.agentLaunchBinaryWarning(launchLine: plan.launchLine) {
            warnings.append(binaryWarning)
        }

        let title = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to launch agent", data: nil)
        guard v2MainSyncWithDeadline({
            if launchFlagReason != nil,
               let launchCallerSurfaceId,
               AppDelegate.shared?.workspaceContainingPanel(
                   panelId: launchCallerSurfaceId,
                   preferredWorkspaceId: nil
               ) == nil {
                result = .err(
                    code: "caller_surface_not_found",
                    message: "Calling surface not found",
                    data: nil
                )
                return
            }
            let callerWantsFocus = self.v2Bool(params, "focus") ?? true
            let focus = self.v2FocusAllowed(requested: callerWantsFocus)

            let ws: Workspace
            let panel: TerminalPanel
            let paneUUID: UUID?
            if newWorkspace {
                // Identity env rides workspace creation so it is present at
                // PTY birth; the launch line is *typed* into the interactive
                // shell below (queue-until-ready, same as the A button) rather
                // than baked as the ghostty spawn command — a spawn command
                // execs over the shell (agent exit kills the surface) and
                // skips shell rc, which changes PATH-wrapper resolution.
                // autoWelcome is suppressed: this workspace hosts an agent,
                // not the onboarding grid.
                let created = tabManager.addWorkspace(
                    workingDirectory: cwdOverride,
                    initialTerminalEnvironment: plan.env,
                    select: focus,
                    eagerLoadTerminal: !focus,
                    autoWelcomeIfNeeded: false
                )
                guard let initialPanel = created.focusedTerminalPanel else {
                    result = .err(code: "internal_error", message: "New workspace has no terminal surface", data: nil)
                    return
                }
                ws = created
                panel = initialPanel
                paneUUID = created.bonsplitController.focusedPaneId?.id
            } else {
                guard let target = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                if focus {
                    self.v2MaybeFocusWindow(for: tabManager)
                    self.v2MaybeSelectWorkspace(tabManager, workspace: target)
                }
                let paneId: PaneID? = {
                    if let paneParam {
                        return target.bonsplitController.allPaneIds.first(where: { $0.id == paneParam })
                    }
                    return target.bonsplitController.focusedPaneId
                }()
                guard let paneId else {
                    result = .err(code: "not_found", message: "Pane not found", data: nil)
                    return
                }
                guard let created = target.newTerminalSurface(
                    inPane: paneId,
                    focus: focus,
                    workingDirectory: cwdOverride,
                    startupEnvironment: plan.env
                ) else {
                    result = .err(code: "internal_error", message: "Failed to create surface", data: nil)
                    return
                }
                ws = target
                panel = created
                paneUUID = paneId.id
                // A surface created in an unselected workspace stays lazily
                // unattached (`tty: null`) and would never flush a queued
                // command — kick the background start like
                // `launchInExistingSurface` does (C11-121), then use the same
                // queue-until-ready delivery as the A button.
                if panel.surface.surface == nil {
                    panel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }

            do {
                try AgentLaunchAttentionSequencer.stampThenSend(
                    stampIdentity: {
                        ws.stampAgentLaunchIdentity(
                            surfaceId: panel.id,
                            kind: plan.kind,
                            model: plan.model,
                            task: request.task,
                            title: title
                        )
                    },
                    stampSuppression: {
                        if launchSuppressed {
                            _ = try SurfaceAttentionService.shared.suppress(
                                workspaceId: ws.id,
                                surfaceId: panel.id,
                                by: .operator
                            )
                        }
                    },
                    stampFlag: {
                        if let launchFlagReason {
                            _ = try SurfaceAttentionService.shared.raise(
                                workspaceId: ws.id,
                                surfaceId: panel.id,
                                reason: launchFlagReason,
                                callerSurfaceId: launchCallerSurfaceId,
                                by: launchFlagActor,
                                title: ws.panelTitle(panelId: panel.id) ?? panel.displayTitle
                            )
                        }
                    },
                    sendCommand: {
                        // Attention is committed before the launch line can
                        // run, so even a fast completion cannot escape
                        // dispatch-time suppression.
                        panel.sendText(plan.launchLine + "\n")
                    }
                )
            } catch let error as SurfaceMetadataStore.WriteError {
                result = .err(code: "invalid_params", message: error.message, data: error.detailData)
                return
            } catch {
                result = .err(code: "internal_error", message: "\(error)", data: nil)
                return
            }

            if let delayedPrompt = plan.delayedPrompt {
                // Post-boot delivery for TUIs with no argv prompt. Same fixed
                // delay rail as `default-agent launch` (readiness detection is
                // a follow-up there too).
                let panelId = panel.id
                let wsId = ws.id
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2500)) { [weak tabManager] in
                    guard let tabManager,
                          let liveWs = tabManager.tabs.first(where: { $0.id == wsId }),
                          let livePanel = liveWs.terminalPanel(for: panelId) else { return }
                    livePanel.surface.sendSubmitFormText(delayedPrompt)
                }
            }

            // Make the just-minted refs resolvable by the caller's next command.
            self.v2RefreshKnownRefs()

            let windowId = self.v2ResolveWindowId(tabManager: tabManager)
            var agent: [String: Any] = ["type": plan.kind]
            agent["model"] = plan.model.isEmpty ? NSNull() : plan.model
            agent["effort"] = plan.effort.isEmpty ? NSNull() : plan.effort
            agent["task"] = self.v2OrNull(request.task)
            agent["flag"] = self.v2OrNull(launchFlagReason)
            agent["suppressed"] = launchSuppressed
            result = .ok([
                "agent": agent,
                "command": plan.launchLine,
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": self.v2OrNull(paneUUID?.uuidString),
                "pane_ref": paneUUID.map { self.v2Ref(kind: .pane, uuid: $0) } ?? NSNull(),
                "surface_id": panel.id.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: panel.id),
                "warnings": warnings
            ])

            // C11-178 rail-1: record the resolved launch. `plan` exposes model/
            // effort as scalars ("" = inherit → normalized to nil). Dispatched
            // off-main. C11-180: `config launch` passes `source=socket` +
            // `config_id` + the resolved system-prompt mode so config-originated
            // launches are honestly tagged and carry their config id.
            let launchSource = AgentLaunchSource(rawValue: self.v2RawString(params, "source") ?? "")
                ?? .launchAgent
            let launchConfigId = self.v2RawString(params, "config_id")
            let systemPromptMode = request.systemPrompt?.mode.rawValue
            if let store = AgentLaunchStatsStore.shared {
                let stats = ResolvedLaunch(
                    harness: plan.kind,
                    model: plan.model,
                    effort: plan.effort,
                    systemPromptMode: systemPromptMode,
                    configId: launchConfigId
                )
                DispatchQueue.global(qos: .utility).async { store.recordLaunch(stats, source: launchSource) }
            }
            // C11-180 (R2): a `config launch` keeps the follow-recent pointer in
            // `agent-configs.json` live so `effectiveDefault()` resolves against a
            // fresh observation. Off the critical path; never fails the launch.
            if let launchConfigId {
                let recent = RecentAgentConfig(
                    configId: launchConfigId,
                    harness: plan.kind,
                    model: plan.model.isEmpty ? nil : plan.model,
                    effort: plan.effort.isEmpty ? nil : plan.effort,
                    observedAt: Date(),
                    source: "launch",
                    fieldSources: ["model": "launch", "effort": "launch"]
                )
                DispatchQueue.global(qos: .utility).async {
                    try? AgentConfigLibraryStore.shared.recordRecent(recent)
                }
            }
        }) != nil else {
            return .err(code: "main_thread_timeout", message: "main thread did not respond within deadline", data: nil)
        }
        return result
    }

    /// Best-effort binary availability check for the launch line's argv[0].
    /// A warning, never a hard error: the app process PATH (especially when
    /// c11 was launched from Finder) is poorer than the login-shell PATH a
    /// surface actually gets, so an absent binary here may still resolve in
    /// the pane. Searches the bundled wrapper dir, the app PATH, and the
    /// common user-install dirs.
    nonisolated static func agentLaunchBinaryWarning(launchLine: String) -> String? {
        guard let binary = launchLine.split(separator: " ").first.map(String.init),
              !binary.isEmpty else { return nil }
        let fm = FileManager.default
        if binary.contains("/") {
            return fm.isExecutableFile(atPath: (binary as NSString).expandingTildeInPath)
                ? nil
                : "launch binary not found: \(binary)"
        }
        var dirs: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            dirs.append(bundled)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        let home = fm.homeDirectoryForCurrentUser.path
        dirs.append(contentsOf: [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/bin", "\(home)/.grok/bin"
        ])
        for dir in dirs where fm.isExecutableFile(atPath: "\(dir)/\(binary)") {
            return nil
        }
        return "binary '\(binary)' not found on the app PATH or common install dirs; the pane's login shell may still resolve it"
    }
}
