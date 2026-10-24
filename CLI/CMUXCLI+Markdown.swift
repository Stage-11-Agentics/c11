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

    // MARK: - Markdown Commands

    func runMarkdownCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs

        // Parse routing flags
        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        let (surfaceOpt, argsAfterSurface) = parseOption(argsAfterWindow, name: "--panel")
        let (paneOpt, argsAfterPane) = parseOption(argsAfterSurface, name: "--area")
        args = argsAfterPane

        if let first = args.first?.lowercased(),
           ["scroll", "backlinks", "visible", "theme", "typeface", "font", "open-external", "history", "links"].contains(first) {
            try runMarkdownAgentCommand(
                subcommand: first,
                arguments: Array(args.dropFirst()),
                panelRaw: surfaceOpt,
                hasOtherRouting: workspaceOpt != nil || windowOpt != nil || paneOpt != nil,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )
            return
        }

        // Determine subcommand. Explicit "open" is supported, otherwise treat
        // a single positional argument as shorthand path.
        let subArgs: [String]
        if let first = args.first, first.lowercased() == "open" {
            subArgs = Array(args.dropFirst())
        } else if args.count == 1, let first = args.first, !first.hasPrefix("-") {
            subArgs = [first]
        } else {
            // Allow path-like first tokens (e.g. plan.md) with trailing args
            // so we can surface specific trailing-arg/flag errors below.
            if let first = args.first, first.hasPrefix("-") {
                throw CLIError(
                    message:
                        "markdown open: unknown flag '\(first)'. Usage: c11 markdown open <path>[#fragment] [--workspace <id|ref|index>] [--panel <id|ref|index>] [--window <id|ref|index>]"
                )
            } else if let first = args.first, looksLikePath(first) || first.contains(".") {
                subArgs = args
            } else if let first = args.first {
                throw CLIError(message: "Unknown markdown subcommand: \(first). Usage: c11 markdown open <path>[#fragment]")
            } else {
                subArgs = []
            }
        }

        guard let rawPath = subArgs.first, !rawPath.isEmpty else {
            throw CLIError(message: "markdown open requires a file path. Usage: c11 markdown open <path>[#fragment]")
        }
        let trailingArgs = Array(subArgs.dropFirst())
        if let unknownFlag = trailingArgs.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(
                message:
                    "markdown open: unknown flag '\(unknownFlag)'. Usage: c11 markdown open <path>[#fragment] [--workspace <id|ref|index>] [--panel <id|ref|index>] [--window <id|ref|index>]"
            )
        }
        if let extraArg = trailingArgs.first {
            throw CLIError(
                message:
                    "markdown open: unexpected argument '\(extraArg)'. Usage: c11 markdown open <path>[#fragment] [--workspace <id|ref|index>] [--panel <id|ref|index>] [--window <id|ref|index>]"
            )
        }

        let (pathArgument, fragment) = try splitMarkdownTarget(rawPath)
        let absolutePath = resolvePath(pathArgument)

        if let surfaceRaw = surfaceOpt {
            guard workspaceOpt == nil, windowOpt == nil, paneOpt == nil else {
                throw CLIError(message: "markdown open --panel cannot be combined with --workspace, --window, or --area")
            }
            guard !surfaceRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Int(surfaceRaw.trimmingCharacters(in: .whitespacesAndNewlines)) == nil else {
                throw CLIError(message: "markdown open --panel requires a stable ref such as panel:1")
            }
            guard let panelID = try normalizeSurfaceHandle(surfaceRaw, client: client) else {
                throw CLIError(message: "markdown open: invalid panel handle")
            }
            var params: [String: Any] = ["panel_id": panelID, "path": absolutePath]
            if let fragment { params["fragment"] = fragment }
            let payload = try client.sendV2(method: "markdown.navigate", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print("OK navigation=\(payload["outcome"] as? String ?? "navigated") panel=\(formatHandle(payload, kind: "panel", idFormat: idFormat) ?? surfaceRaw) path=\(payload["path"] as? String ?? absolutePath)")
            }
            return
        }

        // Build params
        var params: [String: Any] = ["path": absolutePath]
        if let fragment { params["fragment"] = fragment }
        let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        if let workspaceRaw {
            if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
        }
        if let windowRaw = windowOpt {
            if let window = try normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }
        }
        if let paneRaw = paneOpt {
            let workspaceHandle = params["workspace_id"] as? String
            if let pane = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: workspaceHandle) {
                params["area_id"] = pane
            }
        }

        try addCallingPanel(to: &params)
        let payload = try client.sendV2(method: "markdown.open", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceText = formatHandle(payload, kind: "panel", idFormat: idFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "area", idFormat: idFormat) ?? "unknown"
            let filePath = (payload["path"] as? String) ?? absolutePath
            print("OK panel=\(surfaceText) area=\(paneText) path=\(filePath)")
        }
    }

    func splitMarkdownTarget(_ value: String) throws -> (path: String, fragment: String?) {
        guard value.contains("#") else { return (value, nil) }
        if isExistingMarkdownOpenFile(value) { return (value, nil) }

        var separator = value.startIndex
        var existingPathSeparator: String.Index?
        while let candidate = value[separator...].firstIndex(of: "#") {
            let path = String(value[..<candidate])
            if isExistingMarkdownOpenFile(path) {
                existingPathSeparator = candidate
            }
            guard candidate < value.endIndex else { break }
            separator = value.index(after: candidate)
        }

        if let existingPathSeparator {
            return try markdownPathAndFragment(value, separator: existingPathSeparator)
        }
        guard let firstSeparator = value.firstIndex(of: "#") else { return (value, nil) }
        return try markdownPathAndFragment(value, separator: firstSeparator)
    }

    func isExistingMarkdownOpenFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: resolvePath(path), isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    func markdownPathAndFragment(_ value: String, separator: String.Index) throws -> (path: String, fragment: String?) {
        let path = String(value[..<separator])
        let encodedFragment = String(value[value.index(after: separator)...])
        guard !path.isEmpty, let fragment = encodedFragment.removingPercentEncoding else {
            throw CLIError(message: "markdown open: invalid file fragment")
        }
        return (path, fragment.isEmpty ? nil : fragment)
    }

    func runMarkdownAgentCommand(
        subcommand: String,
        arguments: [String],
        panelRaw: String?,
        hasOtherRouting: Bool,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard !hasOtherRouting else {
            throw CLIError(message: "markdown \(subcommand) accepts only --panel routing")
        }
        guard let panelRaw, !panelRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "markdown \(subcommand) requires --panel <id|ref>")
        }
        if Int(panelRaw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            throw CLIError(message: "markdown \(subcommand) does not accept an unscoped panel index; use a stable ref such as panel:1")
        }
        guard let panelID = try normalizeSurfaceHandle(panelRaw, client: client) else {
            throw CLIError(message: "markdown \(subcommand): invalid panel handle")
        }

        switch subcommand {
        case "backlinks":
            let (jsonFlag, remaining) = removeMarkdownFlag(arguments, name: "--json")
            guard remaining.isEmpty, jsonOutput || jsonFlag else {
                throw CLIError(message: "Usage: c11 markdown backlinks --panel <id|ref> --json")
            }
            let result = try client.sendV2(method: "markdown.backlinks", params: ["panel_id": panelID])
            print(jsonString(formatIDs(result, mode: idFormat)))

        case "scroll":
            let (headings, remaining) = parseRepeatedOption(arguments, name: "--heading")
            guard headings.count == 1, !headings[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  remaining.isEmpty else {
                throw CLIError(message: "Usage: c11 markdown scroll --panel <id|ref> --heading <text>")
            }
            let result = try client.sendV2(method: "markdown.scroll", params: [
                "panel_id": panelID,
                "heading": headings[0]
            ])
            if jsonOutput {
                print(jsonString(formatIDs(result, mode: idFormat)))
            } else {
                let heading = (result["heading"] as? [String: Any])?["text"] as? String ?? headings[0]
                print("OK scrolled to heading: \(heading)")
            }

        case "visible":
            let (jsonFlag, afterJSON) = removeMarkdownFlag(arguments, name: "--json")
            let (watch, afterWatch) = removeMarkdownFlag(afterJSON, name: "--watch")
            guard afterWatch.isEmpty else {
                throw CLIError(message: "Usage: c11 markdown visible --panel <id|ref> --json [--watch]")
            }
            guard jsonOutput || jsonFlag else {
                throw CLIError(message: "markdown visible requires --json")
            }
            let params: [String: Any] = ["panel_id": panelID, "watch": watch]
            if watch {
                try client.sendV2Stream(method: "markdown.visible", params: params) { payload in
                    try writeMarkdownWatchLine(formatIDs(payload, mode: idFormat))
                }
            } else {
                let result = try client.sendV2(method: "markdown.visible", params: params)
                print(jsonString(formatIDs(result, mode: idFormat)))
            }

        case "theme", "typeface":
            let (list, afterList) = removeMarkdownFlag(arguments, name: "--list")
            let (values, remaining) = parseRepeatedOption(afterList, name: "--set")
            guard remaining.isEmpty,
                  (list && values.isEmpty || !list && values.count == 1) else {
                throw CLIError(message: "Usage: c11 markdown \(subcommand) --panel <id|ref> (--list | --set <name>)")
            }
            let method = "markdown.\(subcommand)"
            let params: [String: Any] = list
                ? ["panel_id": panelID, "action": "list"]
                : ["panel_id": panelID, "action": "set", "name": values[0]]
            let result = try client.sendV2(method: method, params: params)
            if jsonOutput {
                print(jsonString(formatIDs(result, mode: idFormat)))
            } else if list {
                let key = subcommand == "theme" ? "themes" : "typefaces"
                let names = result[key] as? [String] ?? []
                print(names.joined(separator: "\n"))
            } else {
                print("OK \(subcommand)=\(values[0])")
            }

        case "font":
            let (scales, remaining) = parseRepeatedOption(arguments, name: "--scale")
            let decimalScale = #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#
            guard scales.count == 1, remaining.isEmpty,
                  scales[0].range(of: decimalScale, options: .regularExpression) != nil,
                  let scale = Double(scales[0]), scale.isFinite, (0.5...3.0).contains(scale) else {
                throw CLIError(message: "Usage: c11 markdown font --panel <id|ref> --scale <0.5..3.0>")
            }
            let result = try client.sendV2(method: "markdown.font", params: [
                "panel_id": panelID,
                "scale": scale
            ])
            if jsonOutput {
                print(jsonString(formatIDs(result, mode: idFormat)))
            } else {
                print("OK font_scale=\(result["font_scale"] ?? scale)")
            }

        case "open-external":
            guard arguments.isEmpty else {
                throw CLIError(message: "Usage: c11 markdown open-external --panel <id|ref>")
            }
            let result = try client.sendV2(method: "markdown.open_external", params: ["panel_id": panelID])
            if jsonOutput {
                print(jsonString(formatIDs(result, mode: idFormat)))
            } else {
                print("OK opened externally: \(result["path"] as? String ?? "")")
            }

        case "history":
            let (jsonFlag, remaining) = removeMarkdownFlag(arguments, name: "--json")
            guard remaining.isEmpty, jsonOutput || jsonFlag else {
                throw CLIError(message: "Usage: c11 markdown history --panel <id|ref> --json")
            }
            let result = try client.sendV2(method: "markdown.history", params: ["panel_id": panelID])
            print(jsonString(formatIDs(result, mode: idFormat)))

        case "links":
            let (broken, afterBroken) = removeMarkdownFlag(arguments, name: "--broken")
            let (jsonFlag, remaining) = removeMarkdownFlag(afterBroken, name: "--json")
            guard broken, remaining.isEmpty, jsonOutput || jsonFlag else {
                throw CLIError(message: "Usage: c11 markdown links --panel <id|ref> --broken --json")
            }
            let result = try client.sendV2(method: "markdown.links", params: ["panel_id": panelID, "broken": true])
            print(jsonString(formatIDs(result, mode: idFormat)))

        default:
            throw CLIError(message: "Unknown markdown subcommand: \(subcommand)")
        }
    }

    func removeMarkdownFlag(_ args: [String], name: String) -> (Bool, [String]) {
        var found = false
        let remaining = args.filter { arg in
            guard arg == name else { return true }
            found = true
            return false
        }
        return (found, remaining)
    }

    func writeMarkdownWatchLine(_ payload: Any) throws {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Markdown watch returned an invalid JSON value")
        }
        let bytes = Array((json + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw CLIError(message: "Markdown watch output closed")
            }
            guard written > 0 else { throw CLIError(message: "Markdown watch output closed") }
            offset += written
        }
    }

    // MARK: - M6 markdown.get_content

    func runMarkdownGetContentCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (surfaceOpt, _) = parseOption(commandArgs, name: "--panel")
        let surfaceArg = surfaceOpt ?? Self.callerPanelEnv()
        guard let surfaceArg else {
            throw CLIError(message: "markdown-content requires --panel <handle> (or C11_PANEL_ID env)")
        }
        guard let surface = try normalizeSurfaceHandle(surfaceArg, client: client) else {
            throw CLIError(message: "markdown-content: invalid panel handle")
        }
        let params: [String: Any] = ["panel_id": surface]
        let payload = try client.sendV2(method: "markdown.get_content", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        if (payload["truncated"] as? Bool) == true {
            let reason = (payload["reason"] as? String) ?? "truncated"
            print("TRUNCATED \(reason)")
            return
        }
        if let content = payload["content"] as? String {
            print(content)
        }
    }

    /// Returns true if the argument looks like a filesystem path rather than a CLI command.
    func looksLikePath(_ arg: String) -> Bool {
        if arg == "." || arg == ".." { return true }
        if arg.hasPrefix("/") || arg.hasPrefix("./") || arg.hasPrefix("../") || arg.hasPrefix("~") { return true }
        if arg.contains("/") { return true }
        return false
    }

    /// Open a path in cmux by creating a new workspace with the given directory.
    /// Launches the app if it isn't already running.
    func openPath(_ path: String, socketPath: String) throws {
        let resolved = resolvePath(path)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)

        let directory: String
        if exists && isDir.boolValue {
            directory = resolved
        } else if exists {
            // It's a file; use its parent directory
            directory = (resolved as NSString).deletingLastPathComponent
        } else {
            throw CLIError(message: "Path does not exist: \(resolved)")
        }

        // Try connecting to the socket. If it fails, launch the app and retry.
        let client = SocketClient(path: socketPath)
        if (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            defer { launchedClient.close() }
            var params: [String: Any] = ["cwd": directory]
            try addCallingPanel(to: &params)
            let response = try launchedClient.sendV2(method: "workspace.create", params: params)
            let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
            if !wsRef.isEmpty {
                print("OK \(wsRef)")
            }
            try activateApp()
            return
        }
        defer { client.close() }

        var params: [String: Any] = ["cwd": directory]
        try addCallingPanel(to: &params)
        let response = try client.sendV2(method: "workspace.create", params: params)
        let wsRef = (response["workspace_ref"] as? String) ?? (response["workspace_id"] as? String) ?? ""
        if !wsRef.isEmpty {
            print("OK \(wsRef)")
        }

        // Bring the app to front
        try activateApp()
    }
}
