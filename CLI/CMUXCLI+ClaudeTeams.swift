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

    struct ClaudeTeamsFocusedContext {
        let socketPath: String
        let workspaceId: String
        let windowId: String?
        let paneHandle: String
        let paneId: String?
        let surfaceId: String?
    }

    func claudeTeamsResolvedSocketPath(processEnvironment: [String: String]) -> String {
        let envSocketPath: String? = {
            for key in ["C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
                guard let raw = processEnvironment[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }()

        let requestedSocketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        let source: CLISocketPathSource
        if let envSocketPath {
            source = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            source = .implicitDefault
        }

        return CLISocketPathResolver.resolve(
            requestedPath: requestedSocketPath,
            source: source,
            environment: processEnvironment
        )
    }

    func claudeTeamsFocusedContext(
        processEnvironment: [String: String],
        explicitPassword: String?
    ) -> ClaudeTeamsFocusedContext? {
        let socketPath = claudeTeamsResolvedSocketPath(processEnvironment: processEnvironment)
        let client = SocketClient(path: socketPath)

        do {
            try client.connect()
            try authenticateClientIfNeeded(
                client,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            defer { client.close() }

            let payload = try client.sendV2(method: "system.identify")
            let focused = payload["focused"] as? [String: Any] ?? [:]

            let workspaceId = (focused["workspace_id"] as? String)
                ?? (focused["workspace_ref"] as? String)
            let paneId = (focused["area_id"] as? String)
                ?? (focused["area_ref"] as? String)

            guard let workspaceId, let paneId else {
                return nil
            }

            let paneHandle = paneId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneHandle.isEmpty else {
                return nil
            }

            let windowId = (focused["window_id"] as? String)
                ?? (focused["window_ref"] as? String)
            let surfaceId = (focused["panel_id"] as? String)
                ?? (focused["panel_ref"] as? String)

            return ClaudeTeamsFocusedContext(
                socketPath: socketPath,
                workspaceId: workspaceId,
                windowId: windowId,
                paneHandle: paneHandle,
                paneId: focused["area_id"] as? String,
                surfaceId: surfaceId
            )
        } catch {
            client.close()
            return nil
        }
    }

    func isCmuxClaudeWrapper(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let prefixData = data.prefix(512)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    func resolveClaudeExecutable(searchPath: String?) -> String? {
        let entries = searchPath?.split(separator: ":").map(String.init) ?? []
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent("claude", isDirectory: false)
                .path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            guard !isCmuxClaudeWrapper(at: candidate) else { continue }
            return candidate
        }
        return nil
    }

    func claudeTeamsHasExplicitTeammateMode(commandArgs: [String]) -> Bool {
        commandArgs.contains { arg in
            arg == "--teammate-mode" || arg.hasPrefix("--teammate-mode=")
        }
    }

    func claudeTeamsLaunchArguments(commandArgs: [String]) -> [String] {
        guard !claudeTeamsHasExplicitTeammateMode(commandArgs: commandArgs) else {
            return commandArgs
        }
        return ["--teammate-mode", "auto"] + commandArgs
    }

    func configureClaudeTeamsEnvironment(
        processEnvironment: [String: String],
        shimDirectory: URL,
        executablePath: String,
        socketPath: String,
        explicitPassword: String?,
        focusedContext: ClaudeTeamsFocusedContext?
    ) {
        let updatedPath = prependPathEntries(
            [shimDirectory.path],
            to: processEnvironment["PATH"]
        )
        let fakeTmuxValue: String = {
            if let focusedContext {
                let windowToken = focusedContext.windowId ?? focusedContext.workspaceId
                return "/tmp/cmux-claude-teams/\(focusedContext.workspaceId),\(windowToken),\(focusedContext.paneHandle)"
            }
            return processEnvironment["TMUX"] ?? "/tmp/cmux-claude-teams/default,0,0"
        }()
        let fakeTmuxPane = focusedContext.map { "%\($0.paneHandle)" }
            ?? processEnvironment["TMUX_PANE"]
            ?? "%1"
        let fakeTerm = processEnvironment["CMUX_CLAUDE_TEAMS_TERM"] ?? "screen-256color"

        setenv("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "1", 1)
        setenv("CMUX_CLAUDE_TEAMS_CMUX_BIN", executablePath, 1)
        setenv("PATH", updatedPath, 1)
        setenv("TMUX", fakeTmuxValue, 1)
        setenv("TMUX_PANE", fakeTmuxPane, 1)
        setenv("TERM", fakeTerm, 1)
        setenv("CMUX_SOCKET_PATH", socketPath, 1)
        setenv("CMUX_SOCKET", socketPath, 1)
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setenv("CMUX_SOCKET_PASSWORD", explicitPassword, 1)
        }
        unsetenv("TERM_PROGRAM")
        if let focusedContext {
            setenv("CMUX_WORKSPACE_ID", focusedContext.workspaceId, 1)
            if let surfaceId = focusedContext.surfaceId, !surfaceId.isEmpty {
                setenv("CMUX_SURFACE_ID", surfaceId, 1)
                setenv("C11_PANEL_ID", surfaceId, 1)
                setenv("C11_TAB_ID", surfaceId, 1)
            }
        }
    }

    func createClaudeTeamsShimDirectory() throws -> URL {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let rootPath = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("claude-teams-bin", isDirectory: true)
            .path
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let tmuxURL = root.appendingPathComponent("tmux", isDirectory: false)
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        exec "${CMUX_CLAUDE_TEAMS_CMUX_BIN:-cmux}" __tmux-compat "$@"
        """
        let normalizedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingScript = try? String(contentsOf: tmuxURL, encoding: .utf8)
        if existingScript?.trimmingCharacters(in: .whitespacesAndNewlines) != normalizedScript {
            try script.write(to: tmuxURL, atomically: false, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmuxURL.path)
        return root
    }

    func runClaudeTeams(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        var launcherEnvironment = processEnvironment
        launcherEnvironment["CMUX_SOCKET_PATH"] = socketPath
        launcherEnvironment["CMUX_SOCKET"] = socketPath
        if let explicitPassword,
           !explicitPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            launcherEnvironment["CMUX_SOCKET_PASSWORD"] = explicitPassword
        }
        let shimDirectory = try createClaudeTeamsShimDirectory()
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let focusedContext = claudeTeamsFocusedContext(
            processEnvironment: launcherEnvironment,
            explicitPassword: explicitPassword
        )
        let bundledClaudePath = resolvedExecutableURL()?
            .deletingLastPathComponent()
            .appendingPathComponent("claude", isDirectory: false)
            .path
        let claudeExecutablePath = resolveClaudeExecutable(searchPath: launcherEnvironment["PATH"])
            ?? {
                guard let bundledClaudePath,
                      FileManager.default.isExecutableFile(atPath: bundledClaudePath) else { return nil }
                return bundledClaudePath
            }()
        configureClaudeTeamsEnvironment(
            processEnvironment: launcherEnvironment,
            shimDirectory: shimDirectory,
            executablePath: executablePath,
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            focusedContext: focusedContext
        )

        let launchPath = claudeExecutablePath ?? "claude"
        let launchArguments = claudeTeamsLaunchArguments(commandArgs: commandArgs)
        var argv = ([launchPath] + launchArguments).map { strdup($0) }
        defer {
            for item in argv {
                free(item)
            }
        }
        argv.append(nil)

        // c11 ignores SIGPIPE for its own safe writes; the child must start
        // with the normal disposition. Restore it if exec returns an error.
        let priorSIGPIPE = signal(SIGPIPE, SIG_DFL)
        if claudeExecutablePath != nil {
            execv(launchPath, &argv)
        } else {
            execvp("claude", &argv)
        }
        let code = errno
        _ = signal(SIGPIPE, priorSIGPIPE)
        throw CLIError(message: "Failed to launch claude: \(String(cString: strerror(code)))")
    }

    func runClaudeTeamsTmuxCompat(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (command, rawArgs) = try splitTmuxCommand(commandArgs)

        switch command {
        case "new-session", "new":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-s"],
                boolFlags: ["-A", "-d", "-P"]
            )
            if parsed.hasFlag("-A") {
                throw CLIError(message: "new-session -A is not supported in c11 claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            try addCallingPanel(to: &params)
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n") ?? parsed.value("-s"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: "panel.send_text", params: [
                    "workspace_id": workspaceId,
                    "panel_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "new-window", "neww":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-n", "-t"],
                boolFlags: ["-d", "-P"]
            )
            if parsed.value("-t") != nil {
                throw CLIError(message: "new-window -t is not supported in c11 claude-teams mode")
            }
            var params: [String: Any] = ["focus": false]
            if let cwd = parsed.value("-c") {
                params["cwd"] = resolvePath(cwd)
            }
            try addCallingPanel(to: &params)
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let workspaceId = created["workspace_id"] as? String else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            if let title = parsed.value("-n"),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try client.sendV2(method: "workspace.rename", params: [
                    "workspace_id": workspaceId,
                    "title": title
                ])
            }
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                let surfaceId = try resolveSurfaceId(nil, workspaceId: workspaceId, client: client)
                _ = try client.sendV2(method: "panel.send_text", params: [
                    "workspace_id": workspaceId,
                    "panel_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: "@\(workspaceId)"))
            }

        case "split-window", "splitw":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-c", "-F", "-l", "-t"],
                boolFlags: ["-P", "-b", "-d", "-h", "-v"]
            )
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let direction: String
            if parsed.hasFlag("-h") {
                direction = parsed.hasFlag("-b") ? "left" : "right"
            } else {
                direction = parsed.hasFlag("-b") ? "up" : "down"
            }
            var params: [String: Any] = [
                "workspace_id": target.workspaceId,
                "panel_id": target.surfaceId,
                "direction": direction
            ]
            try addCallingPanel(to: &params)
            let created = try client.sendV2(method: "panel.split", params: params)
            guard let surfaceId = created["panel_id"] as? String else {
                throw CLIError(message: "panel.split did not return panel_id")
            }
            let paneId = created["area_id"] as? String
            // Keep the leader pane focused while Claude starts teammates beside it.
            if let text = tmuxShellCommandText(commandTokens: parsed.positional, cwd: parsed.value("-c")) {
                _ = try client.sendV2(method: "panel.send_text", params: [
                    "workspace_id": target.workspaceId,
                    "panel_id": surfaceId,
                    "text": text
                ])
            }
            if parsed.hasFlag("-P") {
                let context = try tmuxFormatContext(
                    workspaceId: target.workspaceId,
                    paneId: paneId,
                    surfaceId: surfaceId,
                    client: client
                )
                let fallback = context["pane_id"] ?? surfaceId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "select-window", "selectw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": workspaceId])

        case "select-pane", "selectp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-P", "-T", "-t"], boolFlags: [])
            if parsed.value("-P") != nil || parsed.value("-T") != nil {
                return
            }
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "area.focus", params: [
                "workspace_id": target.workspaceId,
                "area_id": target.paneId
            ])

        case "kill-window", "killw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            // No default target: a kill without -t would close the caller.
            guard parsed.value("-t").map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? false else {
                throw CLIError(message: String(localized: "cli.tmux.killWindow.requiresTarget", defaultValue: "kill-window requires -t <target>"))
            }
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])

        case "kill-pane", "killp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            guard parsed.value("-t").map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? false else {
                throw CLIError(message: String(localized: "cli.tmux.killPane.requiresTarget", defaultValue: "kill-pane requires -t <target>"))
            }
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "panel.close", params: [
                "workspace_id": target.workspaceId,
                "panel_id": target.surfaceId
            ])

        case "send-keys", "send":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: ["-l"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let text = tmuxSendKeysText(from: parsed.positional, literal: parsed.hasFlag("-l"))
            if !text.isEmpty {
                _ = try client.sendV2(method: "panel.send_text", params: [
                    "workspace_id": target.workspaceId,
                    "panel_id": target.surfaceId,
                    "text": text
                ])
            }

        case "capture-pane", "capturep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-E", "-S", "-t"],
                boolFlags: ["-J", "-N", "-p"]
            )
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            var params: [String: Any] = [
                "workspace_id": target.workspaceId,
                "panel_id": target.surfaceId,
                "scrollback": true
            ]
            if let start = parsed.value("-S"), let lines = Int(start), lines < 0 {
                params["lines"] = abs(lines)
            }
            let payload = try client.sendV2(method: "panel.read_text", params: params)
            let text = (payload["text"] as? String) ?? ""
            if parsed.hasFlag("-p") {
                print(text)
            } else {
                var store = loadTmuxCompatStore()
                store.buffers["default"] = text
                try saveTmuxCompatStore(store)
            }

        case "display-message", "display", "displayp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: ["-p"])
            let target = try tmuxResolveSurfaceTarget(parsed.value("-t"), client: client)
            let context = try tmuxFormatContext(
                workspaceId: target.workspaceId,
                paneId: target.paneId,
                surfaceId: target.surfaceId,
                client: client
            )
            let format = parsed.positional.isEmpty ? parsed.value("-F") : parsed.positional.joined(separator: " ")
            let rendered = tmuxRenderFormat(format, context: context, fallback: "")
            if parsed.hasFlag("-p") || !rendered.isEmpty {
                print(rendered)
            }

        case "list-windows", "lsw":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            let items = try tmuxWorkspaceItems(client: client)
            for item in items {
                guard let workspaceId = item["id"] as? String else { continue }
                let context = try tmuxFormatContext(workspaceId: workspaceId, client: client)
                let fallback = [
                    context["window_index"] ?? "?",
                    context["window_name"] ?? workspaceId
                ].joined(separator: " ")
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "list-panes", "lsp":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-F", "-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            let payload = try client.sendV2(method: "area.list", params: ["workspace_id": workspaceId])
            let panes = payload["areas"] as? [[String: Any]] ?? []
            for pane in panes {
                guard let paneId = pane["id"] as? String else { continue }
                let context = try tmuxFormatContext(workspaceId: workspaceId, paneId: paneId, client: client)
                let fallback = context["pane_id"] ?? paneId
                print(tmuxRenderFormat(parsed.value("-F"), context: context, fallback: fallback))
            }

        case "rename-window", "renamew":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let title = parsed.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "rename-window requires a title")
            }
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "workspace.rename", params: [
                "workspace_id": workspaceId,
                "title": title
            ])

        case "resize-pane", "resizep":
            let parsed = try parseTmuxArguments(
                rawArgs,
                valueFlags: ["-t", "-x", "-y"],
                boolFlags: ["-D", "-L", "-R", "-U"]
            )
            let hasDirectionalFlags = parsed.hasFlag("-L")
                || parsed.hasFlag("-R")
                || parsed.hasFlag("-U")
                || parsed.hasFlag("-D")
            if !hasDirectionalFlags {
                return
            }
            let target = try tmuxResolvePaneTarget(parsed.value("-t"), client: client)
            let direction: String
            if parsed.hasFlag("-L") {
                direction = "left"
            } else if parsed.hasFlag("-U") {
                direction = "up"
            } else if parsed.hasFlag("-D") {
                direction = "down"
            } else {
                direction = "right"
            }
            let rawAmount = (parsed.value("-x") ?? parsed.value("-y") ?? "5")
                .replacingOccurrences(of: "%", with: "")
            let amount = Int(rawAmount) ?? 5
            _ = try client.sendV2(method: "area.resize", params: [
                "workspace_id": target.workspaceId,
                "area_id": target.paneId,
                "direction": direction,
                "amount": max(1, amount)
            ])

        case "wait-for":
            try runTmuxCompatCommand(
                command: "wait-for",
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "last-pane":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            let workspaceId = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)
            _ = try client.sendV2(method: "area.last", params: ["workspace_id": workspaceId])

        case "show-buffer", "showb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            if let buffer = store.buffers[name] {
                print(buffer)
            }

        case "save-buffer", "saveb":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-b"], boolFlags: [])
            let name = parsed.value("-b") ?? "default"
            let store = loadTmuxCompatStore()
            guard let buffer = store.buffers[name] else {
                throw CLIError(message: "Buffer not found: \(name)")
            }
            if let outputPath = parsed.positional.last, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try buffer.write(toFile: resolvePath(outputPath), atomically: true, encoding: .utf8)
            } else {
                print(buffer)
            }

        case "last-window", "next-window", "previous-window", "set-hook", "set-buffer", "list-buffers":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: rawArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )

        case "has-session", "has":
            let parsed = try parseTmuxArguments(rawArgs, valueFlags: ["-t"], boolFlags: [])
            _ = try tmuxResolveWorkspaceTarget(parsed.value("-t"), client: client)

        case "select-layout", "set-option", "set", "set-window-option", "setw", "source-file", "refresh-client", "attach-session", "detach-client":
            return

        default:
            throw CLIError(message: "Unsupported tmux compatibility command: \(command)")
        }
    }
}
