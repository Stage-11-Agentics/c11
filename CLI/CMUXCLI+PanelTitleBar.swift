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

    func runWorkspaceAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceRawOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (actionOpt, rem1) = parseOption(rem0, name: "--action")
        let (titleOpt, rem2) = parseOption(rem1, name: "--title")

        var positional = rem2
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "workspace-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "workspace-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceOpt = try resolvedSelfCloseTarget(workspaceRawOpt, kind: "workspace")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "workspace-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }

        let payload = try client.sendV2(method: "workspace.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let windowHandle = formatHandle(payload, kind: "window", idFormat: idFormat) {
            summaryParts.append("window=\(windowHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let index = payload["index"] {
            summaryParts.append("index=\(index)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    func runPanelAction(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceRawOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (panelRawOpt, rem1) = parseOption(rem0, name: "--panel")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--panel")
        let (actionOpt, rem3) = parseOption(rem2, name: "--action")
        let (titleOpt, rem4) = parseOption(rem3, name: "--title")
        let (urlOpt, rem5) = parseOption(rem4, name: "--url")

        var positional = rem5
        let actionRaw: String
        if let actionOpt {
            actionRaw = actionOpt
        } else if let first = positional.first {
            actionRaw = first
            positional.removeFirst()
        } else {
            throw CLIError(message: "panel-action requires --action <name>")
        }

        if let unknown = positional.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "panel-action: unknown flag '\(unknown)'")
        }

        let action = actionRaw.lowercased().replacingOccurrences(of: "-", with: "_")
        let workspaceOpt = try resolvedSelfCloseTarget(workspaceRawOpt, kind: "workspace")
        let panelOpt = try resolvedSelfCloseTarget(panelRawOpt ?? surfaceOpt, kind: "panel")
        let workspaceArg = workspaceOpt ?? (windowOverride == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let tabArg = panelOpt
            ?? surfaceOpt
            ?? (workspaceOpt == nil && windowOverride == nil
                ? Self.callerPanelEnv()
                : nil)

        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, allowCurrent: true)
        // If a workspace is explicitly targeted and no tab/surface is provided, let server-side
        // tab.action resolve that workspace's focused tab instead of using global focus.
        // C11-165 COR-1: rename is a surface/tab-scoped write — never resolve the
        // operator-focused tab client-side; a ref-less rename must be rejected
        // server-side (missing_ref). Other tab actions keep their focused fallback.
        let allowFocusedFallback = (workspaceId == nil) && action != "rename"
        let surfaceId = try normalizeCanonicalPanelHandle(
            tabArg,
            client: client,
            workspaceHandle: workspaceId,
            allowFocused: allowFocusedFallback
        )

        let inferredTitle = positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?.trimmingCharacters(in: .whitespacesAndNewlines)

        if action == "rename", (title?.isEmpty ?? true) {
            throw CLIError(message: "panel-action rename requires --title <text> (or a trailing title)")
        }

        var params: [String: Any] = ["action": action]
        if let workspaceId {
            params["workspace_id"] = workspaceId
        }
        if let surfaceId {
            params["panel_id"] = surfaceId
        }
        if let title, !title.isEmpty {
            params["title"] = title
        }
        if let urlOpt, !urlOpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["url"] = urlOpt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        try addCallingPanel(to: &params)
        let payload = try client.sendV2(method: "panel.action", params: params)
        var summaryParts = ["OK", "action=\(action)"]
        if let panelHandle = formatPanelHandle(payload, idFormat: idFormat) {
            summaryParts.append("panel=\(panelHandle)")
        }
        if let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("workspace=\(workspaceHandle)")
        }
        if let closed = payload["closed"] {
            summaryParts.append("closed=\(closed)")
        }
        if let created = formatCreatedPanelHandle(payload, idFormat: idFormat) {
            summaryParts.append("created=\(created)")
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summaryParts.joined(separator: " "))
    }

    func runRenamePanel(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (panelOpt, rem1) = parseOption(rem0, name: "--panel")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--panel")
        let (titleOpt, rem3) = parseOption(rem2, name: "--title")

        if rem3.contains("--action") {
            throw CLIError(message: "rename-panel does not accept --action (it always performs rename)")
        }
        if let unknown = rem3.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "rename-panel: unknown flag '\(unknown)'")
        }

        let inferredTitle = rem3
            .dropFirst(rem3.first == "--" ? 1 : 0)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            throw CLIError(message: "rename-panel requires a title")
        }

        var forwarded: [String] = ["--action", "rename", "--title", title]
        if let workspaceOpt {
            forwarded += ["--workspace", workspaceOpt]
        }
        if let panel = try validatedPanelTargetValue(panelOpt ?? surfaceOpt, wasProvided: panelOpt != nil || surfaceOpt != nil) {
            forwarded += ["--panel", panel]
        }

        // `forwarded` is c11's own argv, not the caller's: its reads are not
        // options of rename-panel.
        func forward() throws {
            try runPanelAction(
                commandArgs: forwarded,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        }
        #if DEBUG
        try CLIFlagReadLog.withoutRecording { try forward() }
        #else
        try forward()
        #endif
    }

    // MARK: - M7: Surface title bar CLI

    func runSetTitle(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        try runSetTitleBarText(
            key: "title",
            commandArgs: commandArgs,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    func runSetDescription(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        try runSetTitleBarText(
            key: "description",
            commandArgs: commandArgs,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat
        )
    }

    func runSetTitleBarText(
        key: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let commandName = key == "title" ? "set-title" : "set-description"

        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (surfaceOpt, rem1) = parseOption(rem0, name: "--panel")
        let (fromFileOpt, rem2) = parseOption(rem1, name: "--from-file")
        let (sourceOpt, rem3) = parseOption(rem2, name: "--source")

        var autoExpand = true
        var remaining: [String] = []
        for arg in rem3 {
            if arg == "--auto-expand=false" {
                autoExpand = false
            } else if arg == "--auto-expand=true" {
                autoExpand = true
            } else {
                remaining.append(arg)
            }
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "\(commandName): unknown flag '\(unknown)'")
        }

        let value: String
        if let fromFileOpt {
            value = try readFromFileArgument(fromFileOpt, commandName: commandName)
        } else {
            let positional = remaining
                .dropFirst(remaining.first == "--" ? 1 : 0)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            value = positional
        }

        if key == "title" && value.isEmpty {
            throw CLIError(message: "missing_title: \(commandName) requires a non-empty title (or --from-file <path>). To clear: c11 clear-metadata --key title")
        }

        let surfaceRaw = surfaceOpt ?? (client.scopedWindow == nil ? Self.callerPanelEnv() : nil)
        let workspaceRaw = workspaceOpt ?? (client.scopedWindow == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceId = try resolveWorkspaceId(workspaceRaw, client: client)

        let source = sourceOpt?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "explicit"

        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "mode": "merge",
            "source": source,
            "metadata": [key: value]
        ]
        // C11-165 COR-1: only send surface_id when the caller supplied one (flag
        // or CMUX_SURFACE_ID). A ref-less external call must NOT resolve the
        // operator-focused surface client-side — omit it so the server rejects
        // (missing_ref) instead of stomping a peer's surface.
        if let surfaceRaw {
            params["panel_id"] = try resolveSurfaceId(surfaceRaw, workspaceId: workspaceId, client: client)
        }
        if key == "description" && !autoExpand {
            params["auto_expand"] = false
        }

        let payload = try client.sendV2(method: "panel.set_metadata", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let applied = (payload["applied"] as? [String: Any])?[key] as? Bool ?? false
            let reason = (payload["reasons"] as? [String: Any])?[key] as? String
            if applied {
                print("OK \(key) applied=true source=\(source)")
            } else {
                let reasonText = reason ?? "unknown"
                FileHandle.standardError.c11SafeWrite(Data("Error: \(key) applied=false reason=\(reasonText)\n".utf8))
                exit(1)
            }
        }
    }

    /// `c11 set-panel-icon` / `c11 set-panel-color` — sugar over `panel.set_metadata`
    /// for the canonical `icon` / `color` keys. An empty value or `--clear`
    /// clears the key (the store treats a blank write as removal).
    func runSetPanelMarker(
        key: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let commandName = "set-panel-\(key)"
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (surfaceOpt, rem1) = parseOption(rem0, name: "--panel")
        let (sourceOpt, rem2) = parseOption(rem1, name: "--source")
        let (clear, rem3a) = parseBoolFlag(rem2, name: "--clear")
        let (jsonFlag, rem3) = parseBoolFlag(rem3a, name: "--json")
        let jsonOutput = jsonOutput || jsonFlag

        if let unknown = rem3.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "\(commandName): unknown flag '\(unknown)'")
        }
        let positional = rem3.dropFirst(rem3.first == "--" ? 1 : 0)
        guard positional.count <= 1 else {
            throw CLIError(message: "\(commandName): expected one value; quote it (got \(positional.count) arguments)")
        }
        let value = (positional.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if clear && !value.isEmpty {
            throw CLIError(message: "\(commandName): pass a value or --clear, not both")
        }
        if !clear && positional.isEmpty {
            throw CLIError(message: "\(commandName) requires a value, \"\" or --clear (see c11 \(commandName) --help)")
        }

        let surfaceRaw = surfaceOpt ?? (client.scopedWindow == nil ? Self.callerPanelEnv() : nil)
        let workspaceRaw = workspaceOpt ?? (client.scopedWindow == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceId = try resolveWorkspaceId(workspaceRaw, client: client)
        let source = sourceOpt?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "explicit"

        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "mode": "merge",
            "source": source,
            "metadata": [key: value]
        ]
        // C11-165 COR-1: a ref-less external call omits the panel so the server
        // rejects it instead of writing to the operator-focused panel.
        if let surfaceRaw {
            params["panel_id"] = try resolveSurfaceId(surfaceRaw, workspaceId: workspaceId, client: client)
        }

        let payload = try client.sendV2(method: "panel.set_metadata", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let applied = (payload["applied"] as? [String: Any])?[key] as? Bool ?? false
        guard applied else {
            let reason = (payload["reasons"] as? [String: Any])?[key] as? String ?? "unknown"
            FileHandle.standardError.c11SafeWrite(Data("Error: \(key) applied=false reason=\(reason)\n".utf8))
            exit(1)
        }
        if let stored = (payload["metadata"] as? [String: Any])?[key] as? String {
            print("OK \(key)=\(stored) source=\(source)")
        } else {
            print("OK \(key) cleared")
        }
    }

    func runGetTitleBarState(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (surfaceOpt, remaining) = parseOption(rem0, name: "--panel")

        if let unknown = remaining.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "get-titlebar-state: unknown flag '\(unknown)'")
        }

        let surfaceRaw = surfaceOpt ?? (client.scopedWindow == nil ? Self.callerPanelEnv() : nil)
        let workspaceRaw = workspaceOpt ?? (client.scopedWindow == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceId = try resolveWorkspaceId(workspaceRaw, client: client)
        let surfaceId = try resolveSurfaceId(surfaceRaw, workspaceId: workspaceId, client: client)

        let params: [String: Any] = [
            "panel_id": surfaceId,
            "workspace_id": workspaceId
        ]
        let payload = try client.sendV2(method: "panel.get_titlebar_state", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceStr = (payload["panel_id"] as? String) ?? surfaceId
            var lines: [String] = ["panel=\(surfaceStr)"]
            if let ref = payload["panel_ref"] as? String {
                lines.append("ref=\(ref)")
            }
            if let title = payload["title"] as? String {
                let src = (payload["title_source"] as? String) ?? "?"
                lines.append("title=\(title)   [\(src)]")
            }
            if let desc = payload["description"] as? String {
                let src = (payload["description_source"] as? String) ?? "?"
                lines.append("description=\(desc)   [\(src)]")
            }
            let collapsed = (payload["collapsed"] as? Bool) ?? true
            let visible = (payload["visible"] as? Bool) ?? true
            lines.append("collapsed=\(collapsed)  visible=\(visible)")
            if let sidebar = payload["sidebar_label"] as? String {
                lines.append("sidebar_label=\(sidebar)")
            }
            print(lines.joined(separator: "\n"))
        }
    }

    func readFromFileArgument(_ path: String, commandName: String) throws -> String {
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = URL(fileURLWithPath: resolvePath(path))
        do {
            let data = try Data(contentsOf: url)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw CLIError(message: "\(commandName): unable to read --from-file '\(path)': \(error)")
        }
    }
}
