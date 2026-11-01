// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

extension CMUXCLI {

    func runFleetCommand(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "system.fleet")
        if jsonOutput {
            // The versioned fleet schema always carries UUIDs, never short refs.
            print(jsonString(response))
            return
        }
        func cell(_ value: Any?, width: Int) -> String {
            let text = value is NSNull || value == nil ? "-" : String(describing: value!)
            let safe = String(String.UnicodeScalarView(text.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(32)! : $0
            }))
            let clipped = safe.count > width ? String(safe.prefix(width - 1)) + "…" : safe
            return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        // Headers are schema field names, shared with JSON and the API reference.
        let columns = [("workspace_title", 24), ("panel_title", 28), ("agent_type", 12),
                       ("model", 20), ("lifecycle", 9), ("flag", 5), ("mailbox_unread_count", 20)]
        print(columns.map { cell($0.0, width: $0.1) }.joined(separator: "  "))
        for panel in response["panels"] as? [[String: Any]] ?? [] {
            print(columns.map { cell(panel[$0.0], width: $0.1) }.joined(separator: "  "))
        }
    }

    enum TreeScope: String {
        case workspace
        case window
        case all
    }

    struct TreeCommandOptions {
        let scope: TreeScope
        let workspaceHandle: String?
        let jsonOutput: Bool
        /// Floor plan: nil = default per scope, true = force on, false = force off.
        let layoutOverride: Bool?
        let canvasColsOverride: Int?
        /// `--report`/`--markdown`: emit a human-readable Markdown fleet snapshot
        /// (layout + per-surface manifest) instead of the ASCII tree.
        let report: Bool
        /// `--out <path>`: write the report to a file instead of stdout.
        let outPath: String?
    }

    struct TreePath {
        let windowHandle: String?
        let workspaceHandle: String?
        let paneHandle: String?
        let surfaceHandle: String?
    }

    func runPanelFamilyCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (panelRaw, remaining) = parseOption(commandArgs, name: "--panel")
        let wantsJSON = jsonOutput || commandArgs.contains("--json")
        let rest = remaining.filter { $0 != "--json" }
        guard rest.isEmpty else {
            throw CLIError(message: "family: unknown argument '\(rest[0])'. Usage: c11 family [--panel <ref>] [--json]")
        }

        let panelId: String
        if let panelRaw {
            guard let normalized = try normalizeSurfaceHandle(panelRaw, client: client, workspaceHandle: nil) else {
                throw CLIError(message: "family: invalid panel ref '\(panelRaw)'")
            }
            panelId = normalized
        } else if let caller = try resolveCallingSurface(environment: ProcessInfo.processInfo.environment) {
            panelId = caller
        } else {
            throw CLIError(message: "family: pass --panel <ref> or run from a panel with C11_PANEL_ID")
        }

        let payload: [String: Any]
        do {
            payload = try client.sendV2(method: "panel.family", params: ["panel_id": panelId])
        } catch let error as CLIError where error.message.contains("method_not_found") {
            throw CLIError(message: "family requires a c11 server with panel.family support; update the app and CLI together")
        }

        if wantsJSON {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }

        let nodes = payload["nodes"] as? [[String: Any]] ?? []
        guard !nodes.isEmpty else { throw CLIError(message: "family: server returned no lineage nodes") }
        let byId = Dictionary(uniqueKeysWithValues: nodes.compactMap { node -> (String, [String: Any])? in
            guard let id = node["id"] as? String else { return nil }
            return (id, node)
        })
        for node in nodes {
            let id = node["id"] as? String ?? ""
            var depth = 0
            var parentId = node["parent_panel_id"] as? String
            var seen: Set<String> = [id]
            while let parent = parentId, byId[parent] != nil, seen.insert(parent).inserted {
                depth += 1
                parentId = byId[parent]?["parent_panel_id"] as? String
            }
            let marker = depth == 0 ? "" : String(repeating: "  ", count: depth - 1) + "└── "
            let ref = formatPanelHandle(
                ["panel_id": id, "panel_ref": node["ref"] as? String ?? ""],
                idFormat: idFormat
            ) ?? id
            let type = node["type"] as? String ?? "panel"
            let title = (node["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let state = node["state"] as? String ?? "unknown"
            let delegation = (node["delegated"] as? Bool) == true ? " [delegate]" : ""
            let workspaceRef = node["workspace_ref"] as? String ?? "workspace"
            let workspaceTitle = (node["workspace_title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let workspace = workspaceTitle.isEmpty
                ? workspaceRef
                : "\(workspaceRef) \"\(workspaceTitle)\""
            print("\(marker)\(ref) [\(type)]\(title.isEmpty ? "" : " \(title)") [\(state)]\(delegation) — \(workspace)")
        }
    }

    func runTreeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseTreeCommandOptions(commandArgs)
        let payload = try buildTreePayload(options: options, client: client)
        if options.report {
            try emitFleetReport(payload: payload, options: options, client: client)
            return
        }
        if jsonOutput || options.jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(renderTreeText(payload: payload, options: options, idFormat: idFormat))
        }
    }

    // MARK: - Fleet report (`c11 tree --report`)

    /// Build a human-readable Markdown snapshot of the tree payload, enriched
    /// with each surface's manifest, and either print it or write it to a file.
    func emitFleetReport(
        payload: [String: Any],
        options: TreeCommandOptions,
        client: SocketClient
    ) throws {
        let metadata = fetchFleetMetadata(payload: payload, client: client)
        let markdown = renderFleetReport(
            payload: payload,
            metadata: metadata,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        guard let outRaw = options.outPath else {
            print(markdown)
            return
        }
        let resolved = resolvePath(outRaw)
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: resolved).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(markdown.utf8).write(to: URL(fileURLWithPath: resolved))
        } catch {
            throw CLIError(message: "tree --report: failed to write \(resolved): \(error)")
        }
        print("OK fleet-report path=\(resolved) bytes=\(markdown.utf8.count)")
    }

    /// One `surface.get_metadata` call per surface in the payload, keyed by the
    /// surface's short ref. Failures degrade to an empty manifest for that
    /// surface rather than aborting the whole report.
    func fetchFleetMetadata(
        payload: [String: Any],
        client: SocketClient
    ) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for win in (payload["windows"] as? [[String: Any]] ?? []) {
            for ws in (win["workspaces"] as? [[String: Any]] ?? []) {
                let wsRef = ws["ref"] as? String
                for pane in (ws["areas"] as? [[String: Any]] ?? []) {
                    for surf in (pane["panels"] as? [[String: Any]] ?? []) {
                        guard let sRef = surf["ref"] as? String else { continue }
                        var params: [String: Any] = ["panel_id": sRef]
                        if let wsRef { params["workspace_id"] = wsRef }
                        if let resp = try? client.sendV2(method: "panel.get_metadata", params: params),
                           let md = resp["metadata"] as? [String: Any] {
                            out[sRef] = md
                        }
                    }
                }
            }
        }
        return out
    }

    func renderFleetReport(
        payload: [String: Any],
        metadata: [String: [String: Any]],
        generatedAt: String
    ) -> String {
        let windows = payload["windows"] as? [[String: Any]] ?? []
        var wsCount = 0
        var surfCount = 0
        for win in windows {
            let wss = win["workspaces"] as? [[String: Any]] ?? []
            wsCount += wss.count
            for ws in wss {
                for pane in (ws["areas"] as? [[String: Any]] ?? []) {
                    surfCount += (pane["panels"] as? [[String: Any]])?.count ?? 0
                }
            }
        }

        var out = "# c11 Fleet Snapshot\n\n"
        out += "_Generated \(generatedAt) · "
        out += "\(windows.count) \(plural(windows.count, "window")) · "
        out += "\(wsCount) \(plural(wsCount, "workspace")) · "
        out += "\(surfCount) \(plural(surfCount, "panel"))_\n"

        var summaryRows: [String] = []
        for (wi, win) in windows.enumerated() {
            let wss = win["workspaces"] as? [[String: Any]] ?? []
            out += "\n## Window \(wi + 1)\n"
            for ws in wss {
                let wsTitle = (ws["title"] as? String) ?? "(untitled)"
                let wsRef = (ws["ref"] as? String) ?? "?"
                let panes = ws["areas"] as? [[String: Any]] ?? []
                let sCount = panes.reduce(0) { $0 + (($1["panels"] as? [[String: Any]])?.count ?? 0) }
                out += "\n### \(wsTitle) (\(wsRef)) — "
                out += "\(panes.count) \(plural(panes.count, "area")), "
                out += "\(sCount) \(plural(sCount, "panel"))\n"
                summaryRows.append("| \(wi + 1) | \(mdCell(wsTitle)) | \(panes.count) | \(sCount) |")
                for pane in panes {
                    let pRef = (pane["ref"] as? String) ?? "?"
                    let pos = panePositionLabel(pane)
                    out += "\n**Area** \(pRef)\(pos.isEmpty ? "" : " — \(pos)")\n"
                    for surf in (pane["panels"] as? [[String: Any]] ?? []) {
                        out += renderSurfaceLine(surf, metadata: metadata)
                    }
                }
            }
        }

        out += "\n## Summary\n\n"
        out += "| Window | Workspace | Areas | Panels |\n"
        out += "|---|---|---|---|\n"
        out += summaryRows.joined(separator: "\n")
        out += "\n"
        return out
    }

    func renderSurfaceLine(
        _ surf: [String: Any],
        metadata: [String: [String: Any]]
    ) -> String {
        let sRef = (surf["ref"] as? String) ?? "?"
        let md = metadata[sRef] ?? [:]
        // Prefer the canonical manifest title; the tree's title can be a stale
        // auto-title.
        let title = (md["title"] as? String) ?? (surf["title"] as? String) ?? "(untitled)"
        let kind = (surf["type"] as? String) ?? "terminal"

        var chips: [String] = []
        if let t = md["terminal_type"] as? String, !t.isEmpty { chips.append(t) }
        if let m = md["model"] as? String, !m.isEmpty { chips.append(m) }
        if let st = (md["status"] as? String) ?? (md["lifecycle_state"] as? String), !st.isEmpty {
            chips.append(st)
        }
        if let role = md["role"] as? String, !role.isEmpty { chips.append("role=\(role)") }

        var marker = ""
        if (surf["here"] as? Bool) == true { marker = " ← here" }
        else if (surf["focused"] as? Bool) == true { marker = " ← focused" }

        var line = "- **\(mdInline(title))** (\(sRef))"
        if kind != "terminal" { line += " · _\(kind)_" }
        if !chips.isEmpty { line += " — `\(chips.joined(separator: " · "))`" }
        line += marker + "\n"

        if kind == "browser", let url = surf["url"] as? String, !url.isEmpty {
            line += "  - \(url)\n"
        }
        if let desc = md["description"] as? String, !desc.isEmpty {
            line += "  - \(desc.replacingOccurrences(of: "\n", with: " "))\n"
        }
        if let addr = md["mailbox.address"] as? String, !addr.isEmpty {
            line += "  - mailbox: `\(addr)`\n"
        }
        return line
    }

    /// `H a–b% · V c–d%` derived from the pane's percent rect; empty when the
    /// layout block is absent.
    func panePositionLabel(_ pane: [String: Any]) -> String {
        guard let layout = pane["layout"] as? [String: Any],
              let pct = layout["percent"] as? [String: Any],
              let h = pct["H"] as? [Any], h.count == 2,
              let v = pct["V"] as? [Any], v.count == 2 else { return "" }
        func pctInt(_ x: Any) -> Int {
            let d = (x as? Double) ?? Double("\(x)") ?? 0
            return Int((d * 100).rounded())
        }
        return "H \(pctInt(h[0]))–\(pctInt(h[1]))% · V \(pctInt(v[0]))–\(pctInt(v[1]))%"
    }

    func plural(_ n: Int, _ word: String) -> String {
        n == 1 ? word : "\(word)s"
    }

    /// Escape a value for a Markdown table cell (pipes + newlines).
    func mdCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Escape a value used inside inline emphasis (`**…**`).
    func mdInline(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }

    func parseTreeCommandOptions(_ args: [String]) throws -> TreeCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: "tree requires --workspace <id|ref|index>")
        }

        let (canvasOpt, rem1) = parseOption(rem0, name: "--canvas-cols")
        if rem1.contains("--canvas-cols") {
            throw CLIError(message: "tree requires --canvas-cols <N>")
        }

        let (outOpt, rem2) = parseOption(rem1, name: "--out")
        if rem2.contains("--out") {
            throw CLIError(message: "tree requires --out <path>")
        }

        var includeAll = false
        var includeWindow = false
        var jsonOutput = false
        var layoutForceOn = false
        var layoutForceOff = false
        var report = false
        var remaining: [String] = []
        for arg in rem2 {
            switch arg {
            case "--all":
                includeAll = true
            case "--window":
                includeWindow = true
            case "--layout":
                layoutForceOn = true
            case "--no-layout":
                layoutForceOff = true
            case "--json":
                jsonOutput = true
            case "--report", "--markdown":
                report = true
            default:
                remaining.append(arg)
            }
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "tree: unknown flag '\(unknown)'. Known flags: --all --window --workspace <id|ref|index> --layout --no-layout --canvas-cols <N> --json --report [--out <path>]")
        }
        if let extra = remaining.first {
            throw CLIError(message: "tree: unexpected argument '\(extra)'")
        }

        // Conflict detection per spec: at most one of --all, --window, --workspace.
        var scopeFlags: [String] = []
        if includeAll { scopeFlags.append("--all") }
        if includeWindow { scopeFlags.append("--window") }
        if workspaceOpt != nil { scopeFlags.append("--workspace") }
        if scopeFlags.count > 1 {
            let payload: [String: Any] = ["flags": scopeFlags]
            throw CLIError(message: makeStructuredErrorMessage(
                code: "conflicting_flags",
                message: "tree: conflicting scope flags \(scopeFlags.joined(separator: ", "))",
                data: payload
            ))
        }

        if layoutForceOn && layoutForceOff {
            throw CLIError(message: "tree: --layout and --no-layout are mutually exclusive")
        }

        let scope: TreeScope
        if includeAll {
            scope = .all
        } else if includeWindow {
            scope = .window
        } else if report && workspaceOpt == nil {
            // A fleet report is cross-workspace by default; narrow it with an
            // explicit --window or --workspace.
            scope = .all
        } else {
            // Default and --workspace both produce a single workspace in the response.
            scope = .workspace
        }

        var canvasOverride: Int? = nil
        if let raw = canvasOpt {
            guard let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                let payload: [String: Any] = ["value": raw]
                throw CLIError(message: makeStructuredErrorMessage(
                    code: "invalid_canvas_cols",
                    message: "tree: --canvas-cols must be an integer",
                    data: payload
                ))
            }
            guard (40...200).contains(n) else {
                let payload: [String: Any] = ["value": n]
                throw CLIError(message: makeStructuredErrorMessage(
                    code: "invalid_canvas_cols",
                    message: "tree: --canvas-cols must be in [40, 200]",
                    data: payload
                ))
            }
            canvasOverride = n
        }

        let layoutOverride: Bool?
        if layoutForceOn { layoutOverride = true }
        else if layoutForceOff { layoutOverride = false }
        else { layoutOverride = nil }

        return TreeCommandOptions(
            scope: scope,
            workspaceHandle: workspaceOpt,
            jsonOutput: jsonOutput,
            layoutOverride: layoutOverride,
            canvasColsOverride: canvasOverride,
            report: report,
            outPath: outOpt
        )
    }

    /// Encode an error code + structured data into the message string CLIError
    /// exposes today. Tests look for the `code: ` prefix.
    func makeStructuredErrorMessage(code: String, message: String, data: [String: Any]) -> String {
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
           let str = String(data: bytes, encoding: .utf8) {
            return "\(code): \(message) (\(str))"
        }
        return "\(code): \(message)"
    }

    func buildTreePayload(
        options: TreeCommandOptions,
        client: SocketClient
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "scope": options.scope.rawValue,
            // Keep `all_windows` for older servers that haven't seen `scope` yet.
            "all_windows": options.scope == .all
        ]
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = client.scopedWindow != nil
                ? try resolveWorkspaceId(workspaceRaw, client: client)
                : try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }
            params["workspace_id"] = workspaceHandle
        } else if client.scopedWindow != nil, options.scope == .workspace {
            params["workspace_id"] = try resolveWorkspaceId(nil, client: client)
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        do {
            var payload = try client.sendV2(method: "system.tree", params: params)
            if let scopedWindow = client.scopedWindow {
                let nodes = payload["windows"] as? [[String: Any]] ?? []
                let scopedNodes = nodes.filter { treeItemMatchesHandle($0, handle: scopedWindow) }
                if scopedNodes.isEmpty {
                    // Older system.tree implementations ignore window_id and
                    // snapshot ambient focus. Resolve the target's nodes here.
                    return try buildLegacyTreePayload(options: options, params: params, client: client)
                }
                payload["windows"] = scopedNodes
            }
            return treePayloadWithMarkers(payload)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            // Back-compat fallback for older servers that don't support system.tree.
            return try buildLegacyTreePayload(options: options, params: params, client: client)
        }
    }

    func buildLegacyTreePayload(
        options: TreeCommandOptions,
        params: [String: Any],
        client: SocketClient
    ) throws -> [String: Any] {
        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }

        let identifyPayload = try client.sendV2(method: "system.identify", params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: focused)
        let windows = try buildTreeWindowNodes(options: options, activePath: activePath, client: client)

        return treePayloadWithMarkers([
            "active": focused.isEmpty ? NSNull() : focused,
            "caller": caller.isEmpty ? NSNull() : caller,
            "windows": windows
        ])
    }

    func buildTreeWindowNodes(
        options: TreeCommandOptions,
        activePath: TreePath,
        client: SocketClient
    ) throws -> [[String: Any]] {
        let windowsPayload = try client.sendV2(method: "window.list")
        let allWindows = windowsPayload["windows"] as? [[String: Any]] ?? []

        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = client.scopedWindow != nil
                ? try resolveWorkspaceId(workspaceRaw, client: client)
                : try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }

            let workspaceListPayload = try client.sendV2(method: "workspace.list", params: ["workspace_id": workspaceHandle])
            let workspaceWindowHandle = (workspaceListPayload["window_ref"] as? String) ?? (workspaceListPayload["window_id"] as? String)
            let window = allWindows.first(where: { treeItemMatchesHandle($0, handle: workspaceWindowHandle) })
                ?? treeFallbackWindow(from: workspaceListPayload)

            // workspace.list enumerates the manager; workspace_id selects its
            // owner, not an individual row. Filter the explicit tree target.
            let workspaces = (workspaceListPayload["workspaces"] as? [[String: Any]] ?? [])
                .filter { treeItemMatchesHandle($0, handle: workspaceHandle) }
            if workspaces.isEmpty {
                throw CLIError(message: "Workspace not found")
            }
            let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
            var node = window
            let isActiveWindow = treeItemMatchesHandle(node, handle: activePath.windowHandle)
            node["current"] = isActiveWindow
            node["active"] = isActiveWindow
            node["workspaces"] = workspaceNodes
            node["workspace_count"] = workspaceNodes.count
            node["workspace_groups"] = try legacyTreeGroups(window: node, client: client)
            return [node]
        }

        let targetWindows: [[String: Any]]
        if let scopedWindow = client.scopedWindow {
            targetWindows = allWindows.filter { treeItemMatchesHandle($0, handle: scopedWindow) }
        } else if options.scope == .all {
            targetWindows = allWindows
        } else if let currentWindowHandle = activePath.windowHandle {
            let currentOnly = allWindows.filter { treeItemMatchesHandle($0, handle: currentWindowHandle) }
            targetWindows = currentOnly.isEmpty ? Array(allWindows.prefix(1)) : currentOnly
        } else {
            targetWindows = Array(allWindows.prefix(1))
        }

        return try targetWindows.map {
            try buildTreeWindowNode(
                window: $0,
                selectedWorkspaceOnly: client.scopedWindow != nil && options.scope == .workspace,
                activePath: activePath,
                client: client
            )
        }
    }

    func treeFallbackWindow(from payload: [String: Any]) -> [String: Any] {
        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
        let selectedWorkspace = workspaces.first(where: { ($0["selected"] as? Bool) == true })
        return [
            "id": payload["window_id"] ?? NSNull(),
            "ref": payload["window_ref"] ?? NSNull(),
            "index": 0,
            "key": false,
            "visible": true,
            "workspace_count": workspaces.count,
            "selected_workspace_id": selectedWorkspace?["id"] ?? NSNull(),
            "selected_workspace_ref": selectedWorkspace?["ref"] ?? NSNull(),
        ]
    }

    func buildTreeWindowNode(
        window: [String: Any],
        selectedWorkspaceOnly: Bool,
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceParams: [String: Any] = [:]
        if let windowHandle = treeItemHandle(window) {
            workspaceParams["window_id"] = windowHandle
        }
        let workspacePayload = try client.sendV2(method: "workspace.list", params: workspaceParams)
        let listedWorkspaces = workspacePayload["workspaces"] as? [[String: Any]] ?? []
        let workspaces = selectedWorkspaceOnly
            ? listedWorkspaces.filter { ($0["selected"] as? Bool) == true }
            : listedWorkspaces
        let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
        var windowNode = window
        let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
        windowNode["current"] = isActiveWindow
        windowNode["active"] = isActiveWindow
        windowNode["workspaces"] = workspaceNodes
        windowNode["workspace_count"] = workspaceNodes.count
        windowNode["workspace_groups"] = try legacyTreeGroups(window: windowNode, client: client)
        return windowNode
    }

    func legacyTreeGroups(window: [String: Any], client: SocketClient) throws -> [[String: Any]] {
        guard let handle = treeItemHandle(window) else { return [] }
        do {
            let payload = try client.sendV2(method: "workspace.group.list", params: ["window_id": handle])
            return payload["workspace_groups"] as? [[String: Any]] ?? []
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            return [] // Older apps retain the flat tree.
        }
    }

    func buildTreeWorkspaceNode(
        workspace: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceNode = workspace
        guard let workspaceHandle = treeItemHandle(workspace) else {
            workspaceNode["areas"] = []
            workspaceNode.removeValue(forKey: "panes")
            return workspaceNode
        }

        let panePayload = try client.sendV2(method: "area.list", params: ["workspace_id": workspaceHandle])
        let surfacePayload = try client.sendV2(method: "panel.list", params: ["workspace_id": workspaceHandle])
        let panes = panePayload["areas"] as? [[String: Any]] ?? []
        let surfaces = surfacePayload["panels"] as? [[String: Any]] ?? []
        let browserURLsByHandle = fetchTreeBrowserURLs(
            workspaceHandle: workspaceHandle,
            surfaces: surfaces,
            client: client
        )

        var surfacesByPane: [String: [[String: Any]]] = [:]
        for surface in surfaces {
            var surfaceNode = surface
            if surfaceNode["selected"] == nil {
                surfaceNode["selected"] = (surfaceNode["selected_in_area"] as? Bool) == true
            }
            surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)

            let surfaceType = ((surfaceNode["type"] as? String) ?? "").lowercased()
            if surfaceType == "browser",
               let url = treeBrowserURL(surface: surfaceNode, urlsByHandle: browserURLsByHandle),
               !url.isEmpty {
                surfaceNode["url"] = url
            } else {
                surfaceNode["url"] = NSNull()
            }

            guard let paneHandle = treeRelatedHandle(surfaceNode, refKey: "area_ref", idKey: "area_id") else {
                continue
            }
            surfacesByPane[paneHandle, default: []].append(surfaceNode)
        }

        for paneHandle in surfacesByPane.keys {
            surfacesByPane[paneHandle]?.sort {
                let lhs = intFromAny($0["index_in_area"]) ?? intFromAny($0["index"]) ?? Int.max
                let rhs = intFromAny($1["index_in_area"]) ?? intFromAny($1["index"]) ?? Int.max
                return lhs < rhs
            }
        }

        let paneNodes: [[String: Any]] = panes.map { pane in
            var paneNode = pane
            paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)
            let panelNodes: [[String: Any]]
            if let paneHandle = treeItemHandle(paneNode) {
                panelNodes = surfacesByPane[paneHandle] ?? []
            } else {
                panelNodes = []
            }
            // Output carries only `panels`; an older app's `tabs` / `surfaces` are dropped.
            paneNode["panels"] = panelNodes
            paneNode.removeValue(forKey: "tabs")
            paneNode.removeValue(forKey: "surfaces")
            return paneNode
        }

        workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)
        workspaceNode["areas"] = paneNodes
        workspaceNode.removeValue(forKey: "panes")
        return workspaceNode
    }

    func treeItemHandle(_ item: [String: Any]) -> String? {
        if let ref = item["ref"] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    func treeRelatedHandle(_ item: [String: Any], refKey: String, idKey: String) -> String? {
        if let ref = item[refKey] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item[idKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    func parseTreePath(payload: [String: Any]) -> TreePath {
        return TreePath(
            windowHandle: treeRelatedHandle(payload, refKey: "window_ref", idKey: "window_id"),
            workspaceHandle: treeRelatedHandle(payload, refKey: "workspace_ref", idKey: "workspace_id"),
            paneHandle: treeRelatedHandle(payload, refKey: "area_ref", idKey: "area_id"),
            surfaceHandle: treeRelatedHandle(payload, refKey: "panel_ref", idKey: "panel_id")
        )
    }

    func treeCallerContextFromEnvironment() -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        let workspaceRaw = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceRaw = Self.callerPanelEnv(env)
        var caller: [String: Any] = [:]
        if let workspaceRaw, !workspaceRaw.isEmpty {
            caller["workspace_id"] = workspaceRaw
        }
        if let surfaceRaw, !surfaceRaw.isEmpty {
            caller["panel_id"] = surfaceRaw
        }
        return caller.isEmpty ? nil : caller
    }

    func treePayloadWithMarkers(_ payload: [String: Any]) -> [String: Any] {
        let active = payload["active"] as? [String: Any] ?? [:]
        let caller = payload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: active)
        let callerPath = parseTreePath(payload: caller)
        var result = payload
        let windows = payload["windows"] as? [[String: Any]] ?? []
        result["windows"] = treeApplyMarkers(windows: windows, activePath: activePath, callerPath: callerPath)
        if result["active"] == nil {
            result["active"] = active.isEmpty ? NSNull() : active
        }
        if result["caller"] == nil {
            result["caller"] = caller.isEmpty ? NSNull() : caller
        }
        return result
    }

    func treeApplyMarkers(
        windows: [[String: Any]],
        activePath: TreePath,
        callerPath: TreePath
    ) -> [[String: Any]] {
        return windows.map { window in
            var windowNode = window
            let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
            windowNode["current"] = isActiveWindow
            windowNode["active"] = isActiveWindow

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let workspaceNodes = workspaces.map { workspace in
                var workspaceNode = workspace
                workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)

                let panes = workspace["areas"] as? [[String: Any]] ?? []
                let paneNodes = panes.map { pane in
                    var paneNode = pane
                    paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)

                    let surfaces = pane["panels"] as? [[String: Any]] ?? []
                    let panelNodes = surfaces.map { surface in
                        var surfaceNode = surface
                        surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)
                        surfaceNode["here"] = treeItemMatchesHandle(surfaceNode, handle: callerPath.surfaceHandle)
                        return surfaceNode
                    }
                    // Output carries only `panels`; an older app's `tabs` / `surfaces` are dropped.
                    paneNode["panels"] = panelNodes
                    paneNode.removeValue(forKey: "tabs")
                    paneNode.removeValue(forKey: "surfaces")
                    return paneNode
                }

                workspaceNode["areas"] = paneNodes
                workspaceNode.removeValue(forKey: "panes")
                return workspaceNode
            }

            windowNode["workspaces"] = workspaceNodes
            return windowNode
        }
    }

    func fetchTreeBrowserURLs(
        workspaceHandle: String,
        surfaces: [[String: Any]],
        client: SocketClient
    ) -> [String: String] {
        let hasBrowserSurfaces = surfaces.contains {
            (($0["type"] as? String) ?? "").lowercased() == "browser"
        }
        guard hasBrowserSurfaces else { return [:] }

        if let payload = try? client.sendV2(
            method: "browser.panel.list",
            params: ["workspace_id": workspaceHandle]
        ) {
            let panels = payload["panels"] as? [[String: Any]] ?? []
            var urlByHandle: [String: String] = [:]
            for panel in panels {
                guard let url = panel["url"] as? String, !url.isEmpty else { continue }
                if let id = panel["id"] as? String, !id.isEmpty {
                    urlByHandle[id] = url
                }
                if let ref = panel["ref"] as? String, !ref.isEmpty {
                    urlByHandle[ref] = url
                }
            }
            return urlByHandle
        }

        // Fallback for older servers that may not support browser.tab.list.
        var fallbackURLs: [String: String] = [:]
        for surface in surfaces {
            guard ((surface["type"] as? String) ?? "").lowercased() == "browser" else { continue }
            guard let surfaceHandle = treeItemHandle(surface) else { continue }
            guard let payload = try? client.sendV2(
                method: "browser.url.get",
                params: ["workspace_id": workspaceHandle, "panel_id": surfaceHandle]
            ),
            let url = payload["url"] as? String,
            !url.isEmpty else {
                continue
            }
            fallbackURLs[surfaceHandle] = url
            if let id = surface["id"] as? String, !id.isEmpty {
                fallbackURLs[id] = url
            }
            if let ref = surface["ref"] as? String, !ref.isEmpty {
                fallbackURLs[ref] = url
            }
        }
        return fallbackURLs
    }

    func treeBrowserURL(surface: [String: Any], urlsByHandle: [String: String]) -> String? {
        if let id = surface["id"] as? String, let url = urlsByHandle[id] {
            return url
        }
        if let ref = surface["ref"] as? String, let url = urlsByHandle[ref] {
            return url
        }
        if let handle = treeItemHandle(surface), let url = urlsByHandle[handle] {
            return url
        }
        return nil
    }

    func treeItemMatchesHandle(_ item: [String: Any], handle: String?) -> Bool {
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
            return false
        }
        return (item["id"] as? String) == handle || (item["ref"] as? String).map(Self.canonicalHandle) == Self.canonicalHandle(handle)
    }

    /// Render `cmux tree` text output.
    ///
    /// Output ordering (per M8 spec):
    /// 1. Floor plan(s) — when enabled (default for single-workspace scope).
    /// 2. Hierarchical tree — pane lines now carry `size=`, `px=`, `split=` badges.
    func renderTreeText(payload: [String: Any], options: TreeCommandOptions, idFormat: CLIIDFormat) -> String {
        let windows = payload["windows"] as? [[String: Any]] ?? []
        guard !windows.isEmpty else { return "No windows" }

        // Decide whether to render floor plan(s).
        // Default: on for single-workspace scope, off for --window/--all.
        // Override: --layout forces on, --no-layout forces off. Both ignored under --json (handled by caller).
        let defaultPlanOn = (options.scope == .workspace)
        let planEnabled: Bool
        if let override = options.layoutOverride {
            planEnabled = override
        } else {
            planEnabled = defaultPlanOn
        }

        var sections: [String] = []

        if planEnabled {
            // Render one floor plan per workspace in the response.
            let canvasWidth = resolveFloorPlanCanvasWidth(override: options.canvasColsOverride)
            for window in windows {
                let workspaces = window["workspaces"] as? [[String: Any]] ?? []
                for workspace in workspaces {
                    if let plan = renderFloorPlan(workspace: workspace, canvasWidth: canvasWidth, idFormat: idFormat) {
                        sections.append(plan)
                    }
                }
            }
        }

        // Keep the wire workspaces array flat; grouping is a text-only projection.
        var treeLines: [String] = []
        func appendWorkspace(_ workspace: [String: Any], prefix: String, isLast: Bool) {
            let branch = isLast ? "└── " : "├── "
            let indent = prefix + (isLast ? "    " : "│   ")
            treeLines.append("\(prefix)\(branch)\(treeWorkspaceLabel(workspace, idFormat: idFormat))")
            let areas = workspace["areas"] as? [[String: Any]] ?? []
            for (index, area) in areas.enumerated() {
                let last = index == areas.count - 1
                treeLines.append("\(indent)\(last ? "└── " : "├── ")\(treePaneLabel(area, idFormat: idFormat))")
                let panels = area["panels"] as? [[String: Any]] ?? []
                for (panelIndex, panel) in panels.enumerated() {
                    treeLines.append("\(indent)\(last ? "    " : "│   ")\(panelIndex == panels.count - 1 ? "└── " : "├── ")\(treeSurfaceLabel(panel, idFormat: idFormat))")
                }
            }
        }
        for window in windows {
            treeLines.append(treeWindowLabel(window, idFormat: idFormat))
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let groups = window["workspace_groups"] as? [[String: Any]] ?? []
            if groups.isEmpty {
                for (index, workspace) in workspaces.enumerated() {
                    appendWorkspace(workspace, prefix: "", isLast: index == workspaces.count - 1)
                }
                continue
            }
            let groupIDs = Set(groups.compactMap { ($0["id"] as? String)?.lowercased() })
            let ungrouped = workspaces.filter { workspace in
                guard let id = workspace["group_id"] as? String else { return true }
                return !groupIDs.contains(id.lowercased())
            }
            // Shared sidebar order: pinned groups, pinned ungrouped, other groups, other ungrouped.
            var roots: [(isGroup: Bool, item: [String: Any])] = []
            for pinned in [true, false] {
                roots += groups.filter { (($0["is_pinned"] as? Bool) == true) == pinned }.map { (true, $0) }
                roots += ungrouped.filter { (($0["pinned"] as? Bool) == true) == pinned }.map { (false, $0) }
            }
            for (index, root) in roots.enumerated() {
                let last = index == roots.count - 1
                guard root.isGroup else {
                    appendWorkspace(root.item, prefix: "", isLast: last)
                    continue
                }
                let group = root.item
                let id = (group["id"] as? String)?.lowercased()
                let members = workspaces.filter { id != nil && ($0["group_id"] as? String)?.lowercased() == id }
                let pin = (group["is_pinned"] as? Bool) == true ? " [pinned]" : ""
                let collapse = (group["is_collapsed"] as? Bool) == true ? " [collapsed]" : ""
                treeLines.append("\(last ? "└── " : "├── ")workspace_group \(textHandle(group, idFormat: idFormat)) \(group["name"] as? String ?? "")\(pin)\(collapse) members=\(group["member_count"] ?? members.count)")
                // Inspection always includes members, including collapsed folders.
                for (memberIndex, workspace) in members.enumerated() {
                    appendWorkspace(workspace, prefix: last ? "    " : "│   ", isLast: memberIndex == members.count - 1)
                }
            }
        }
        sections.append(treeLines.joined(separator: "\n"))

        return sections.joined(separator: "\n")
    }

    func treeWindowLabel(_ window: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["window \(textHandle(window, idFormat: idFormat))"]
        if (window["current"] as? Bool) == true {
            parts.append("[current]")
        }
        if (window["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    func treeWorkspaceLabel(_ workspace: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["workspace \(textHandle(workspace, idFormat: idFormat))"]
        let title = (workspace["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if let root = (workspace["root_directory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !root.isEmpty {
            parts.append("root=\((root as NSString).abbreviatingWithTildeInPath)")
        }
        if (workspace["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (workspace["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    func treePaneLabel(_ pane: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["area \(textHandle(pane, idFormat: idFormat))"]

        // M8 badges: size=W%×H% px=W×H split=...
        // Render between the pane ref and the bracketed markers.
        let layout = pane["layout"] as? [String: Any]
        let percent = layout?["percent"] as? [String: Any]
        let pixels = layout?["pixels"] as? [String: Any]

        let sizeBadge: String
        if let pct = percent,
           let hArr = pct["H"] as? [Any], hArr.count == 2,
           let vArr = pct["V"] as? [Any], vArr.count == 2,
           let h0 = doubleValue(hArr[0]), let h1 = doubleValue(hArr[1]),
           let v0 = doubleValue(vArr[0]), let v1 = doubleValue(vArr[1]) {
            let widthPct = Int(((h1 - h0) * 100).rounded())
            let heightPct = Int(((v1 - v0) * 100).rounded())
            sizeBadge = "size=\(widthPct)%×\(heightPct)%"
        } else {
            sizeBadge = "size=?"
        }
        parts.append(sizeBadge)

        let pxBadge: String
        if let pix = pixels,
           let hArr = pix["H"] as? [Any], hArr.count == 2,
           let vArr = pix["V"] as? [Any], vArr.count == 2,
           let h0 = doubleValue(hArr[0]), let h1 = doubleValue(hArr[1]),
           let v0 = doubleValue(vArr[0]), let v1 = doubleValue(vArr[1]) {
            pxBadge = "px=\(Int((h1 - h0).rounded()))×\(Int((v1 - v0).rounded()))"
        } else {
            pxBadge = "px=?"
        }
        parts.append(pxBadge)

        let splitBadge: String
        if let path = layout?["split_path"] as? [String] {
            splitBadge = path.isEmpty ? "split=none" : "split=\(path.joined(separator: ","))"
        } else {
            splitBadge = "split=?"
        }
        parts.append(splitBadge)

        if (pane["focused"] as? Bool) == true {
            parts.append("[focused]")
        }
        if (pane["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    func treeSurfaceLabel(_ surface: [String: Any], idFormat: CLIIDFormat) -> String {
        let rawType = ((surface["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceType = rawType.isEmpty ? "unknown" : rawType
        var parts = ["panel \(textHandle(surface, idFormat: idFormat))", "[\(surfaceType)]"]
        let title = (surface["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (surface["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (surface["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        if (surface["here"] as? Bool) == true {
            parts.append("◀ here")
        }
        if let parentRef = surface["parent_panel_ref"] as? String,
           !parentRef.isEmpty {
            let parentTitle = (surface["parent_panel_title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            parts.append("↳ child of \(parentRef)\(parentTitle.isEmpty ? "" : " \(parentTitle)")")
        }
        if surfaceType.lowercased() == "browser",
           let url = surface["url"] as? String,
           !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

    func isUUID(_ value: String) -> Bool {
        return UUID(uuidString: value) != nil
    }
}
