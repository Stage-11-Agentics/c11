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

    func run() throws {
        let processEnv = ProcessInfo.processInfo.environment
        let envSocketPath: String? = {
            for key in ["C11_SOCKET", "C11_SOCKET_PATH", "CMUX_SOCKET_PATH", "CMUX_SOCKET"] {
                guard let raw = processEnv[key] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }()
        var socketPath = envSocketPath ?? CLISocketPathResolver.defaultSocketPath
        var socketPathSource: CLISocketPathSource
        if let envSocketPath {
            socketPathSource = CLISocketPathResolver.isImplicitDefaultPath(envSocketPath) ? .implicitDefault : .environment
        } else {
            socketPathSource = .implicitDefault
        }
        var jsonOutput = false
        var idFormatArg: String? = nil
        var windowId: String? = nil
        var socketPasswordArg: String? = nil

        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--socket" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--socket requires a path")
                }
                socketPath = args[index + 1]
                socketPathSource = .explicitFlag
                index += 2
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                index += 1
                continue
            }
            if arg == "--id-format" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--id-format requires a value (refs|uuids|both)")
                }
                idFormatArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "--window" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--window requires a window id")
                }
                windowId = args[index + 1]
                index += 2
                continue
            }
            if arg == "--password" {
                guard index + 1 < args.count else {
                    throw CLIError(message: "--password requires a value")
                }
                socketPasswordArg = args[index + 1]
                index += 2
                continue
            }
            if arg == "-v" || arg == "--version" {
                print(versionSummary())
                return
            }
            if arg == "--skill" {
                try runGuide(commandArgs: Array(args.dropFirst(index + 1)), jsonOutput: jsonOutput)
                return
            }
            if arg == "-h" || arg == "--help" {
                print(usage())
                return
            }
            break
        }

        guard index < args.count else {
            print(usage())
            throw CLIError(message: "Missing command")
        }

        let command = Self.canonicalCommandName(args[index])
        var commandArgs = Array(args[(index + 1)...])
        if command == "claude-mailbox" {
            if let flag = commandArgs.first(where: { $0.hasPrefix("-") && $0 != "-" }) {
                throw CLIError(message: unknownFlagMessage(command: command, flag: flag))
            }
            // Internal, launch-scoped hook. Do not run discovery, telemetry,
            // journal capture, or a generic request timeout on this stream.
            // An unavailable hook is silent and leaves typed delivery intact.
            guard commandArgs.isEmpty, envSocketPath != nil || socketPathSource == .explicitFlag,
                  let binding = ClaudeMailboxCommand.Binding(
                    environment: processEnv,
                    input: FileHandle.standardInput.readDataToEndOfFile()
                  ) else { return }
            let priorDeadline = SocketClient.processDeadline
            defer { SocketClient.processDeadline = priorDeadline }
            SocketClient.processDeadline = Date().addingTimeInterval(1)
            let client = SocketClient(path: socketPath)
            client.usesSingleLineResponses = true
            defer { client.close() }
            do {
                try client.connect()
                try authenticateClientIfNeeded(client, explicitPassword: socketPasswordArg, socketPath: socketPath)
                SocketClient.processDeadline = priorDeadline
                try ClaudeMailboxCommand.run(binding: binding, descriptor: client.takeConnectedDescriptor())
            } catch {
                // No hook error banner, and no raw input, token, or transcript
                // contents enter a diagnostic. The app owns fallback logging.
            }
            return
        }
        let isSendText = ["send", "send-panel", "paste"].contains(command)
        let sendWantsHelp = isSendText && commandArgs.prefix(while: { $0 != "--" })
            .contains(where: { $0 == "--help" || $0 == "-h" })
        // Guide (including its help) is bundled, offline content. Socket
        // discovery probes listeners, so return before resolving any path.
        if command == "guide" {
            if !commandArgs.contains("--help"), !commandArgs.contains("-h") {
                let preflight = try preflightCommandFlags(command: command, args: commandArgs)
                commandArgs = preflight.args
                jsonOutput = jsonOutput || preflight.requestsJSON
            }
            #if DEBUG
            CLIFlagReadLog.arm()
            #endif
            try runGuide(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }
        // Offline analytics read local files in this CLI process only, even with the app down.
        if command == "usage" || command == "report" {
            if !commandArgs.contains("--help"), !commandArgs.contains("-h") {
                let preflight = try preflightCommandFlags(command: command, args: commandArgs)
                commandArgs = preflight.args
                jsonOutput = jsonOutput || preflight.requestsJSON
            }
            #if DEBUG
            CLIFlagReadLog.arm()
            #endif
            try ActivityAnalysisCommand.run(command: command, args: commandArgs, json: jsonOutput)
            return
        }

        var rpcCall: (method: String, params: [String: Any])?
        if command == "rpc" {
            if commandArgs == ["--help"] || commandArgs == ["-h"] {
                _ = dispatchSubcommandHelp(command: command, commandArgs: commandArgs)
                return
            }
            do {
                rpcCall = try CapabilityFeatures.current.dispatch(.rpc) {
                    try RpcCommand.parse(commandArgs)
                }
            } catch let error as RpcCommand.ValidationError {
                throw CLIError(message: error.description)
            }
        }
        // Remove the literal command value before inspecting create flags. A
        // body such as "--layout" is input, not another CLI option.
        let isTerminalCreate = ["new-workspace", "new-split", "new-area", "new-panel"].contains(command)
        var (createCommandText, createArgs) = isTerminalCreate
            ? parseOption(commandArgs, name: "--command") : (nil, commandArgs)
        let mailboxHelp = Self.mailboxHelpScan(command: command, commandArgs: commandArgs)
        let feedAnswerValueOptions: Set<String> =
            command == "feed" && commandArgs.first?.lowercased() == "answer" ? ["--text"] : []
        let helpValueOptions = feedAnswerValueOptions.union(mailboxHelp.valueOptions)
        let hasSubcommandHelp = CLIHelpFlagScanner.containsHelpFlag(
            in: createArgs,
            valueOptions: helpValueOptions,
            stopAtEndOfOptions: mailboxHelp.stopAtEndOfOptions
        )
        // tmux's own `-h` (split-window) is not a help request; the shim has no help.
        if !hasSubcommandHelp || command == "__tmux-compat" {
            try validatePanelTargetArguments(command: command, args: commandArgs)
            let preflight = try preflightCommandFlags(command: command, args: commandArgs)
            commandArgs = preflight.args
            jsonOutput = jsonOutput || preflight.requestsJSON
            try requireExplicitCloseTarget(command: command, args: commandArgs)
            if isTerminalCreate {
                (createCommandText, createArgs) = parseOption(commandArgs, name: "--command")
            }
        }
        #if DEBUG
        CLIFlagReadLog.arm()
        #endif
        let sendInput: SendTextParse?
        if isSendText && !sendWantsHelp {
            sendInput = try SendTextParse.parse(commandArgs, paste: command == "paste")
            jsonOutput = jsonOutput || sendInput?.json == true
        } else {
            sendInput = nil
        }
        var validatedCreateProfile: String?
        // Validate create input before socket discovery or any routing query.
        if isTerminalCreate, !createArgs.contains("--help"), !createArgs.contains("-h") {
            if createArgs.contains("--command"), createCommandText == nil {
                throw CLIError(message: String(localized: "cli.create.command.requiresValue", defaultValue: "--command requires text"))
            }
            if command == "new-panel" || command == "new-area" {
                validatedCreateProfile = try validatedBrowserProfileOption(createArgs)
                if validatedCreateProfile != nil,
                   optionValue(createArgs, name: "--type")?.lowercased() != "browser" {
                    throw CLIError(message: String(localized: "browser.profile.error.browserOnly", defaultValue: "--profile is only valid for browser panels"))
                }
            }
            _ = try resolvedCreateInput(
                raw: createCommandText,
                panelType: command == "new-workspace" || command == "new-split" ? "terminal" : optionValue(createArgs, name: "--type"),
                hasLayout: command == "new-workspace" && createArgs.contains("--layout")
            )
        }

        // Resize has a command-local target and validates before discovery,
        // connection, authentication or the legacy global-window focus prelude.
        let resizeArguments: (window: String, width: Double?, height: Double?)?
        if command == "resize-window", !commandArgs.contains("--help"), !commandArgs.contains("-h") {
            guard windowId == nil else { throw resizeWindowUsageError() }
            resizeArguments = try parseResizeWindowArguments(commandArgs)
        } else {
            resizeArguments = nil
        }

        let cliTelemetry = CLISocketSentryTelemetry(
            command: command,
            commandArgs: commandArgs,
            socketPath: socketPath,
            processEnv: processEnv
        )
        let resolvedSocketPath = CLISocketPathResolver.resolve(
            requestedPath: socketPath,
            source: socketPathSource,
            environment: processEnv
        )

        if command == "agent-event" {
            try JournalCommand.run(commandArgs, socketPath: resolvedSocketPath, explicitPassword: socketPasswordArg)
            return
        }

        if command == "journal" {
            try CapabilityFeatures.current.dispatch(.journalAnalytics) {
                try JournalQueryCommand.run(commandArgs, socketPath: resolvedSocketPath,
                                            explicitPassword: socketPasswordArg, globalJSON: jsonOutput)
            }
            return
        }

        if command == "version" {
            print(versionSummary())
            return
        }

        if command == "remote-daemon-status" {
            if (commandArgs.contains("--help") || commandArgs.contains("-h")),
               dispatchSubcommandHelp(command: command, commandArgs: commandArgs) {
                return
            }
            try runRemoteDaemonStatus(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        // If the argument looks like a path (not a known command), open a workspace there.
        if looksLikePath(command) {
            try openPath(command, socketPath: resolvedSocketPath)
            return
        }

        // Check for --help/-h on subcommands before connecting to the socket,
        // so help text is available even when cmux is not running.
        if command != "rpc",
           command != "__tmux-compat",
           command != "claude-teams",
           (!isSendText || sendWantsHelp),
           hasSubcommandHelp {
            if dispatchSubcommandHelp(
                command: command,
                commandArgs: commandArgs,
                valueOptions: helpValueOptions,
                stopAtEndOfOptions: mailboxHelp.stopAtEndOfOptions
            ) {
                return
            }
            print("Unknown command '\(command)'. Run 'c11 help' to see available commands.")
            return
        }


        if command == "health" {
            try runHealth(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        if command == "doctor" {
            try runDoctor(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        if command == "welcome" {
            printWelcome()
            return
        }

        if command == "shortcuts" {
            try runShortcuts(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "feedback" {
            try runFeedback(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "terminal-theme" {
            try runThemes(
                commandArgs: commandArgs,
                jsonOutput: jsonOutput
            )
            return
        }

        if command == "claude-teams" {
            try runClaudeTeams(
                commandArgs: commandArgs,
                socketPath: resolvedSocketPath,
                explicitPassword: socketPasswordArg
            )
            return
        }

        if command == "skill" {
            try runSkillCommand(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        // C11-131: `c11 state verify` is a read-only parse + on-disk stat. It
        // doubles as a post-crash diagnostic and the Tier-2 test oracle, so it
        // must work with no running app — handle it before the socket connect.
        if command == "state",
           (commandArgs.first?.lowercased() ?? "") == "verify" {
            try runStateVerify(
                subArgs: Array(commandArgs.dropFirst()),
                jsonOutput: jsonOutput
            )
            return
        }

        // C11-163: `c11 events tail` reads the NDJSON event log directly — the
        // file is the contract, so it must work with no running app. Handle it
        // before the socket connect, like `state verify`.
        if command == "events" {
            try CapabilityFeatures.current.dispatch(.offlineEvents) {
                try runEventsCommand(commandArgs: commandArgs, jsonOutput: jsonOutput)
            }
            return
        }

        // C11-180: `c11 config` reads/mutations operate on the state-root files
        // directly (app-down capable) — handle them before the socket connect
        // like `state verify` / `events`. Only `config launch` needs the running
        // app (it spawns a surface) and falls through to the post-connect switch.
        if command == "config",
           (commandArgs.first?.lowercased() ?? "") != "launch" {
            try runConfigCommand(commandArgs: commandArgs, jsonOutput: jsonOutput)
            return
        }

        // Agent-maintained model token-cost catalog feeding the launch
        // picker's cost column: file-first like `config`, never needs the
        // socket.
        if command == "model-costs" {
            try runModelCostsCommand(commandArgs: commandArgs)
            return
        }

        // Capture the original event identity before any socket operation. Offline retry
        // and online append use this same structural draft, never raw hook input.
        let journalHookInput: String? = command == "claude-hook"
            ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) : nil
        let journalHookObject = journalHookInput.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let journalHookDraft = journalHookObject.flatMap { input -> JournalDraft? in
            // Only `claude-hook` has a hook object, so only it reads these options.
            let journalHookArgs = Array(commandArgs.dropFirst())
            let journalWorkspace = optionValue(journalHookArgs, name: "--workspace") ?? processEnv["CMUX_WORKSPACE_ID"] ?? processEnv["C11_WORKSPACE_ID"]
            let journalPanel = optionValue(journalHookArgs, name: "--panel") ?? Self.callerPanelEnv()
            return JournalCommand.claudeDraft(subcommand: commandArgs.first ?? "", input: input,
                panelID: journalPanel.flatMap(UUID.init(uuidString:)), workspaceID: journalWorkspace.flatMap(UUID.init(uuidString:)))
        }

        // C11-308 / cmux #15980: reject a sequence before authentication or
        // --window routing can send anything to the app. The command arms
        // retain their target validation and command-specific missing-key text.
        if command == "send-key" || command == "send-key-panel" {
            let (_, remainder) = parseOption(commandArgs, name: "--workspace")
            let (_, keyRemainder) = parseOption(remainder, name: "--panel")
            let keys = keyRemainder.first == "--" ? Array(keyRemainder.dropFirst()) : keyRemainder
            do {
                _ = try SendKeyArgs.single(keys)
            } catch SendKeyArgs.Failure.missingKey {
                throw CLIError(message: "\(command) requires a key")
            }
        }

        // Admission and advertised support share the feature registry. The
        // send handlers below still enforce the explicit-tab contract.
        if ["send", "paste", "send-key", "send-panel", "send-key-panel"].contains(command) {
            try CapabilityFeatures.current.dispatch(.explicitPanel) {}
        }
        let client = SocketClient(path: resolvedSocketPath)
        if resolvedSocketPath != socketPath {
            cliTelemetry.breadcrumb(
                "socket.path.autodiscovered",
                data: [
                    "requested_path": socketPath,
                    "resolved_path": resolvedSocketPath
                ]
            )
            emitAutoDiscoveryNotice(
                resolvedPath: resolvedSocketPath,
                environment: processEnv
            )
        }
        // C11-257: a process that may claim mailbox mail at a turn boundary
        // bounds every socket request it makes (auth and probes included) to
        // its claim cutoff, before the first one.
        if Self.isMailboxHookDrain(command: command, commandArgs: commandArgs) {
            Self.boundSocketToClaimCutoff()
        }
        // Claude hooks have one aggregate budget. Keep it armed through
        // authentication, owner resolution, journal append, and the neutral
        // fallback path; resetting it after connect lets a silent peer or a
        // credential lookup consume the hook's entire timeout. The one reset
        // is Stop's, after its mailbox lookup and drain (`runClaudeHook`).
        let priorProcessDeadline = SocketClient.processDeadline
        if command == "claude-hook" {
            // Hook auth and compatibility commands each return one line. Do
            // not spend the aggregate budget waiting for multiline idle gaps.
            client.usesSingleLineResponses = true
            SocketClient.processDeadline = min(
                priorProcessDeadline ?? .distantFuture,
                Date().addingTimeInterval(Self.claudeHookSocketWindowSeconds)
            )
        }
        defer {
            if command == "claude-hook" {
                SocketClient.processDeadline = priorProcessDeadline
            }
        }
        cliTelemetry.breadcrumb(
            "socket.connect.attempt",
            data: [
                "command": command,
                "path": resolvedSocketPath
            ]
        )
        do {
            try client.connect()
            cliTelemetry.breadcrumb("socket.connect.success", data: ["path": resolvedSocketPath])
        } catch {
            cliTelemetry.breadcrumb("socket.connect.failure", data: ["path": resolvedSocketPath])
            cliTelemetry.captureError(stage: "socket_connect", error: error)
            // Advisory commands (claude-hook) should never error a Claude Code
            // banner on every prompt just because c11 isn't listening. Exit
            // cleanly when the eager connect fails for a connectivity reason.
            // Real hook bugs still propagate from inside the subcommand.
            if command == "claude-hook",
               let cliError = error as? CLIError,
               isAdvisoryHookConnectivityError(cliError) {
                if let journalHookDraft { _ = JournalCommand.spool(journalHookDraft) }
                cliTelemetry.breadcrumb("claude-hook.socket-unreachable")
                if commandArgs.first?.lowercased() == "permission-request" { print("{}") }
                return
            }
            // A harness hook drain (`mailbox recv --hook-format`) runs on every
            // turn; with c11 unreachable there is nothing to deliver, and it
            // must not error the harness.
            if command == "mailbox", commandArgs.contains("--hook-format") {
                return
            }
            if command == "agents" {
                try runAgentsOffline(commandArgs: commandArgs, jsonOutput: jsonOutput)
                return
            }
            throw error
        }
        defer { client.close() }

        do {
            try authenticateClientIfNeeded(
                client,
                explicitPassword: socketPasswordArg,
                socketPath: resolvedSocketPath
            )
        } catch {
            if command == "claude-hook" {
                if let journalHookDraft { _ = JournalCommand.spool(journalHookDraft) }
                if commandArgs.first?.lowercased() == "permission-request" { print("{}") }
                return
            }
            throw error
        }

        let idFormat = try resolvedIDFormat(jsonOutput: jsonOutput, raw: idFormatArg)

        // History is app-wide: even an explicit --window must not select a
        // window before listing, or override a navigation destination.
        if command == "history" {
            try runHistoryCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)
            return
        }
        if command == "agents" {
            try runAgentsLive(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)
            return
        }

        // A routing flag is not a focus command. Resolve once, then carry the
        // selected window on requests and their ref-resolution lookups.
        if let rawWindow = windowId {
            windowId = try CapabilityFeatures.current.dispatch(.windowRouteWithoutFocus) {
                try resolveScopedWindow(rawWindow, client: client)
            }
            if command != "browser", command != "markdown" {
                client.scopedWindow = windowId
            }
        }

        switch command {
        case "ping":
            let response = try sendV1Command("ping", client: client)
            print(response)

        case "capabilities":
            var response = try client.sendV2(method: "system.capabilities")
            let identity = bundledCLIIdentity()
            response["cli"] = identity.payload
            let server = response["server"] as? [String: Any]
            response["sha_match"] = C11BuildIdentity.commitsMatch(identity.commit, server?["commit"] as? String) as Any? ?? NSNull()
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "rpc":
            guard let rpcCall else { preconditionFailure("rpc must be parsed before connect") }
            let response = try CapabilityFeatures.current.dispatch(.rpc) {
                try client.sendV2(method: rpcCall.method, params: rpcCall.params)
            }
            print(jsonString(response))

        case "brand":
            let response = try client.sendV2(method: "system.brand")
            if jsonOutput || hasFlag(commandArgs, name: "--json") {
                print(jsonString(response))
            } else {
                printBrandHuman(response)
            }

        case "identify":
            var params: [String: Any] = [:]
            let includeCaller = !hasFlag(commandArgs, name: "--no-caller")
            if includeCaller {
                let idWsFlag = optionValue(commandArgs, name: "--workspace")
                let workspaceArg = idWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
                let surfaceArg = optionValue(commandArgs, name: "--panel") ?? (idWsFlag == nil && windowId == nil ? Self.callerPanelEnv() : nil)
                if workspaceArg != nil || surfaceArg != nil {
                    let workspaceId = try normalizeWorkspaceHandle(
                        workspaceArg,
                        client: client,
                        allowCurrent: surfaceArg != nil
                    )
                    var caller: [String: Any] = [:]
                    if let workspaceId {
                        caller["workspace_id"] = workspaceId
                    }
                    if surfaceArg != nil {
                        guard let surfaceId = try normalizeSurfaceHandle(
                            surfaceArg,
                            client: client,
                            workspaceHandle: workspaceId
                        ) else {
                            throw CLIError(message: "Invalid panel handle")
                        }
                        caller["panel_id"] = surfaceId
                    }
                    if !caller.isEmpty {
                        params["caller"] = caller
                    }
                }
            }
            let response = try client.sendV2(method: "system.identify", params: params)
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "list-windows":
            let response = try sendV1Command("list_windows", client: client)
            if jsonOutput {
                let windows = parseWindows(response)
                let payload = windows.map { item -> [String: Any] in
                    var dict: [String: Any] = [
                        "index": item.index,
                        "id": item.id,
                        "key": item.key,
                        "workspace_count": item.workspaceCount,
                    ]
                    dict["selected_workspace_id"] = item.selectedWorkspaceId ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "current-window":
            let response = try sendV1Command("current_window", client: client)
            if jsonOutput {
                print(jsonString(["window_id": response]))
            } else {
                print(response)
            }

        case "new-window":
            let response = try sendV1Command("new_window", client: client)
            print(response)

        case "focus-window":
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "focus-window requires --window")
            }
            let windowId = try resolveScopedWindow(target, client: client)
            let response = try sendV1Command("focus_window \(windowId)", client: client)
            print(response)

        case "close-window":
            try rejectEmptyTargetFlags(commandArgs)
            guard let target = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "close-window requires --window")
            }
            let windowId: String
            if target.lowercased() == "self" {
                // The window holding the caller's own workspace, never the key window.
                guard let workspace = try resolvedSelfCloseTarget("self", kind: "workspace") else {
                    throw CLIError(message: "close-window requires --window")
                }
                var caller: [String: Any] = ["workspace_id": workspace]
                if let panel = Self.callerPanelEnv() { caller["panel_id"] = panel }
                let identified = try client.sendV2(method: "system.identify", params: ["caller": caller])
                guard let callerWindow = (identified["caller"] as? [String: Any])?["window_id"] as? String else {
                    throw CLIError(message: String(localized: "cli.close.window.selfUnresolved", defaultValue: "close-window --window self: c11 did not report the calling workspace's window."))
                }
                windowId = callerWindow
            } else {
                windowId = try resolveScopedWindow(target, client: client)
            }
            let response = try sendV1Command("close_window \(windowId)", client: client)
            print(response)

        case "resize-window":
            guard let arguments = resizeArguments else { throw resizeWindowUsageError() }
            var params: [String: Any] = [:]
            params["window_id"] = try normalizeWindowHandle(arguments.window, client: client)
            if let width = arguments.width { params["width"] = width }
            if let height = arguments.height { params["height"] = height }
            let response = try CapabilityFeatures.current.dispatch(.windowResize) {
                try client.sendV2(method: "window.resize", params: params)
            }
            print(jsonString(formatIDs(response, mode: idFormat)))

        case "move-workspace-to-window":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "move-workspace-to-window requires --workspace")
            }
            guard let windowRaw = optionValue(commandArgs, name: "--window") else {
                throw CLIError(message: "move-workspace-to-window requires --window")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let winId = try normalizeWindowHandle(windowRaw, client: client)
            if let winId { params["window_id"] = winId }
            let payload = try client.sendV2(method: "workspace.move_to_window", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace", "window"]))

        case "move-panel":
            try runMoveSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-panel":
            try runReorderSurface(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "reorder-workspace":
            try runReorderWorkspace(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "workspace-group":
            try runWorkspaceGroup(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "reorder-workspaces":
            try runReorderWorkspaces(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "workspace-action":
            try rejectEmptyTargetFlags(commandArgs)
            try runWorkspaceAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "panel-action":
            try rejectEmptyTargetFlags(commandArgs)
            try runPanelAction(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "rename-panel":
            try runRenamePanel(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowId)

        case "set-title":
            try runSetTitle(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "set-description":
            try runSetDescription(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "set-panel-icon":
            try runSetPanelMarker(key: "icon", commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "set-panel-color":
            try runSetPanelMarker(key: "color", commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "get-titlebar-state":
            try runGetTitleBarState(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "list-workspaces":
            let payload = try client.sendV2(method: "workspace.list")
            let workspaceJSONOut = jsonOutput || commandArgs.contains("--json")
            if workspaceJSONOut {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
                if workspaces.isEmpty {
                    print("No workspaces")
                } else {
                    for ws in workspaces {
                        let selected = (ws["selected"] as? Bool) == true
                        let handle = textHandle(ws, idFormat: idFormat)
                        let title = (ws["title"] as? String) ?? ""
                        let remoteTag: String = {
                            guard let remote = ws["remote"] as? [String: Any],
                                  (remote["enabled"] as? Bool) == true else {
                                return ""
                            }
                            let state = (remote["state"] as? String) ?? "unknown"
                            return "  [ssh:\(state)]"
                        }()
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        let titlePart = title.isEmpty ? "" : "  \(title)"
                        print("\(prefix)\(handle)\(titlePart)\(remoteTag)\(selTag)")
                    }
                }
            }

        case "ssh":
            try runSSH(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "ssh-session-end":
            try runSSHSessionEnd(commandArgs: commandArgs, client: client)

        case "workspace":
            // CMUX-37: `c11 workspace <subcommand>`. Subcommands added across
            // phases: apply (Phase 0), new + export-blueprint (Phase 2).
            guard let sub = commandArgs.first else {
                throw CLIError(message: "workspace: missing subcommand. Known subcommands: apply, new, export-blueprint, recents")
            }
            let subArgs = Array(commandArgs.dropFirst())
            switch sub {
            case "apply":
                try runWorkspaceApply(
                    subArgs,
                    client: client,
                    commandLabel: "workspace apply",
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )
            case "new":
                try runWorkspaceBlueprintNew(
                    subArgs,
                    client: client,
                    jsonOutput: jsonOutput,
                    idFormat: idFormat
                )
            case "export-blueprint":
                try runWorkspaceExportBlueprint(
                    subArgs,
                    client: client,
                    jsonOutput: jsonOutput
                )
            case "recents":
                try runWorkspaceRecents(subArgs, client: client, jsonOutput: jsonOutput)
            default:
                throw CLIError(message: "workspace: unknown subcommand '\(sub)'. Known subcommands: apply, new, export-blueprint, recents")
            }

        case "workspace-apply":
            // Back-compat alias for the Phase 0 `c11 workspace apply` form
            // that shipped before the review cycle 1 rename. Prefer the
            // subcommand form going forward.
            try runWorkspaceApply(
                commandArgs,
                client: client,
                commandLabel: "workspace-apply",
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )

        case "snapshot":
            // CMUX-37 Phase 1: `c11 snapshot [--workspace <ref>] [--out <path>]`
            // captures the current workspace (or a named one) to
            // `~/.c11-snapshots/<ulid>.json`. Backed by the `snapshot.create`
            // v2 method.
            try runSnapshotCreate(
                commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        case "restore":
            // CMUX-37 Phase 1: `c11 restore <snapshot-id|path>`. Reads
            // `C11_SESSION_RESUME` / `CMUX_SESSION_RESUME` at this site and,
            // when set, threads the `phase1` restart registry into
            // `snapshot.restore` so cc terminals resume via
            // `cc --resume <session-id>`.
            try runSnapshotRestore(
                commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )

        case "list-snapshots":
            // CMUX-37 Phase 1: `c11 list-snapshots [--json]`. Merges
            // `~/.c11-snapshots/` + legacy `~/.cmux-snapshots/`.
            try runListSnapshots(
                commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        case "new-workspace":
            let commandOpt = createCommandText
            let rem0 = createArgs
            let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
            let (rootOpt, rem2) = parseOption(rem1, name: "--root")
            let (layoutOpt, rem3) = parseOption(rem2, name: "--layout")
            let (titleOpt, remaining) = parseOption(rem3, name: "--title")
            if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
                throw CLIError(message: "new-workspace: unknown flag '\(unknown)'. Known flags: --command <text>, --cwd <path>, --root <path>, --layout <path|name>, --title <text>")
            }
            var params: [String: Any] = [:]
            if let input = try resolvedCreateInput(raw: commandOpt, panelType: "terminal", hasLayout: layoutOpt != nil) {
                params["initial_input"] = input
            }
            if let cwdOpt {
                let resolved = resolvePath(cwdOpt)
                params["cwd"] = resolved
            }
            if let rootOpt {
                params["root_directory"] = resolvePath(rootOpt)
            }
            if let titleOpt {
                let trimmed = titleOpt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { params["title"] = trimmed }
            }
            if let layoutRef = layoutOpt {
                // Resolve blueprint path or name -> {plan: ...} dict for workspace.create layout param.
                params["layout"] = try resolveBlueprintPlan(layoutRef, client: client)
            }
            try addCallingPanel(to: &params)
            let response = try client.sendV2(method: "workspace.create", params: params)
            printV2Payload(response, jsonOutput: jsonOutput, idFormat: idFormat,
                           fallbackText: createOKSummary(response, idFormat: idFormat, kinds: ["workspace"]))

        case "new-split":
            let (wsArg, rem0) = parseOption(createArgs, name: "--workspace")
            let (panelValues, rem2) = parseRepeatedOption(rem0, name: "--panel")
            guard panelValues.count <= 1 else {
                throw CLIError(message: "new-split: pass --panel once")
            }
            let (titleArg, rem3) = parseOption(rem2, name: "--title")
            let (cwdArg, rem4) = parseOption(rem3, name: "--cwd")
            let rem5 = rem4
            let createCommand = createCommandText
            let initialInput = try resolvedCreateInput(raw: createCommand, panelType: "terminal")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceRaw = panelValues.first ?? (wsArg == nil && windowId == nil ? Self.callerPanelEnv() : nil)
            // The direction is the first non-flag token (so `--allow-undersized` can
            // appear on either side of it).
            guard let direction = rem5.first(where: { !$0.hasPrefix("-") }) else {
                throw CLIError(message: "new-split requires a direction")
            }
            var params: [String: Any] = ["direction": direction]
            if let initialInput { params["initial_input"] = initialInput }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }
            if let titleArg, !titleArg.isEmpty { params["title"] = titleArg }
            // --cwd <path> sets the new shell's working directory. `inherit`
            // (or omitting the flag) keeps the default: the workspace root,
            // else the parent surface's cwd. An explicit path is resolved
            // relative to where the CLI ran so `--cwd .` works; the app
            // validates it server-side.
            if let cwdArg = cwdArg?.trimmingCharacters(in: .whitespaces), !cwdArg.isEmpty {
                params["cwd"] = cwdArg.lowercased() == "inherit" ? "inherit" : resolvePath(cwdArg)
            }
            // --allow-undersized (alias --force) bypasses the size-aware split policy
            // for this one call.
            if createArgs.contains("--allow-undersized") || createArgs.contains("--force") {
                params["allow_undersized"] = true
            }
            try addCallingPanel(to: &params)
            let payload = try client.sendV2(method: "panel.split", params: params)
            printSizeWarning(payload)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: createOKSummary(payload, idFormat: idFormat))

        case "list-areas":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "area.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let panes = payload["areas"] as? [[String: Any]] ?? []
                if panes.isEmpty {
                    print("No areas")
                } else {
                    for pane in panes {
                        let focused = (pane["focused"] as? Bool) == true
                        let handle = textHandle(pane, idFormat: idFormat)
                        let count = pane["panel_count"] as? Int ?? 0
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        print("\(prefix)\(handle)  [\(count) panel\(count == 1 ? "" : "s")]\(focusTag)")
                    }
                }
            }

        case "list-area-panels":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let paneRaw = optionValue(commandArgs, name: "--area")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["area_id"] = paneId }
            let payload = try client.sendV2(method: "area.panels", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["panels"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No panels in area")
                } else {
                    for surface in surfaces {
                        let selected = (surface["selected"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = selected ? "* " : "  "
                        let selTag = selected ? "  [selected]" : ""
                        print("\(prefix)\(handle)  \(title)\(selTag)")
                    }
                }
            }

        case "tree":
            try runTreeCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "family":
            try runPanelFamilyCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-area":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let paneRaw = optionValue(commandArgs, name: "--area") ?? commandArgs.first else {
                throw CLIError(message: "focus-area requires --area <id|ref>")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["area_id"] = paneId }
            let payload = try client.sendV2(method: "area.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["area", "workspace"]))

        case "new-area":
            let workspaceArg = workspaceFromArgsOrEnv(createArgs, windowOverride: windowId)
            let type = optionValue(createArgs, name: "--type")
            let initialInput = try resolvedCreateInput(raw: createCommandText, panelType: type)
            let direction = optionValue(createArgs, name: "--direction") ?? "right"
            let url = optionValue(createArgs, name: "--url")
            let file = optionValue(createArgs, name: "--file")
            let title = optionValue(createArgs, name: "--title")
            let cwd = optionValue(createArgs, name: "--cwd")
            let profile = validatedCreateProfile
            if profile != nil, type?.lowercased() != "browser" {
                throw CLIError(message: String(localized: "browser.profile.error.browserOnly", defaultValue: "--profile is only valid for browser panels"))
            }
            var params: [String: Any] = ["direction": direction]
            if let initialInput { params["initial_input"] = initialInput }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            if let file { params["file"] = file }
            if let title, !title.isEmpty { params["title"] = title }
            if let profile { params["profile"] = profile }
            // --cwd <path> sets the new terminal's working directory. `inherit`
            // (or omitting the flag) keeps the default: the workspace root,
            // else the parent surface's cwd. Resolved relative to the CLI's
            // cwd; validated server-side.
            if let cwd = cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
                params["cwd"] = cwd.lowercased() == "inherit" ? "inherit" : resolvePath(cwd)
            }
            // --allow-undersized (alias --force) bypasses the size-aware split policy
            // for this one call.
            if createArgs.contains("--allow-undersized") || createArgs.contains("--force") {
                params["allow_undersized"] = true
            }
            try addCallingPanel(to: &params)
            let payload = try client.sendV2(method: "area.create", params: params)
            printSizeWarning(payload)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: createOKSummary(payload, idFormat: idFormat, kinds: ["panel", "area", "workspace"]))

        case "launch-agent":
            // Typed-agent launch: one command that owns per-agent invocation
            // quirks, identity-at-birth, and machine-readable refs. Thin
            // client over `agent.launch` (docs/launch-agent-reference.md).
            guard let agentKind = optionValue(commandArgs, name: "--type") else {
                throw CLIError(message: "launch-agent requires --type <kind> (built-in: claude-code, codex, grok, kimi, opencode, github-copilot, pi, omp; or a kebab-case custom kind with ~/.config/c11/agents/<kind>.json)")
            }
            let launchNewWorkspace = commandArgs.contains("--new-workspace")
            let launchPaneRaw = optionValue(commandArgs, name: "--area")
            let launchWorkspaceRaw = optionValue(commandArgs, name: "--workspace")
            if launchNewWorkspace && (launchPaneRaw != nil || launchWorkspaceRaw != nil) {
                throw CLIError(message: "launch-agent: --new-workspace is mutually exclusive with --area/--workspace")
            }
            let launchPromptInline = optionValue(commandArgs, name: "--prompt")
            let launchPromptFile = optionValue(commandArgs, name: "--prompt-file")
            if launchPromptInline != nil && launchPromptFile != nil {
                throw CLIError(message: "launch-agent: --prompt and --prompt-file are mutually exclusive")
            }
            var launchPrompt = launchPromptInline
            if let launchPromptFile {
                let path = resolvePath(launchPromptFile)
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
                      !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: "launch-agent: failed to read --prompt-file: \(path)")
                }
                launchPrompt = contents
            }
            // Repeatable --env KEY=VALUE.
            var launchEnv: [String: Any] = [:]
            var launchEnvIdx = 0
            while launchEnvIdx < commandArgs.count {
                if commandArgs[launchEnvIdx] == "--env", launchEnvIdx + 1 < commandArgs.count {
                    let entry = commandArgs[launchEnvIdx + 1]
                    guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else {
                        throw CLIError(message: "launch-agent: --env expects KEY=VALUE (got: \(entry))")
                    }
                    launchEnv[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
                    launchEnvIdx += 2
                } else {
                    launchEnvIdx += 1
                }
            }
            // System-prompt axis: --system-prompt-mode gates the axis; the text
            // rides --system-prompt (inline) or --system-prompt-file (path),
            // mutually exclusive like --prompt. Empty text is allowed (blank
            // slate on replace), so --system-prompt-file does not reject an
            // empty file the way --prompt-file rejects an empty prompt.
            let sysPromptModeRaw = optionValue(commandArgs, name: "--system-prompt-mode")
            let sysPromptInline = optionValue(commandArgs, name: "--system-prompt")
            let sysPromptFile = optionValue(commandArgs, name: "--system-prompt-file")
            if sysPromptInline != nil && sysPromptFile != nil {
                throw CLIError(message: "launch-agent: --system-prompt and --system-prompt-file are mutually exclusive")
            }
            var sysPromptText = sysPromptInline
            if let sysPromptFile {
                let path = resolvePath(sysPromptFile)
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw CLIError(message: "launch-agent: failed to read --system-prompt-file: \(path)")
                }
                sysPromptText = contents
            }

            var params: [String: Any] = ["type": agentKind]
            let callerPanelId = try resolveCallingSurface(
                environment: ProcessInfo.processInfo.environment
            )
            if let callerPanelId {
                params["caller_panel_id"] = callerPanelId
            }
            if let flagReason = optionValue(commandArgs, name: "--flag") {
                params["flag"] = flagReason
                let actor = optionValue(commandArgs, name: "--by") ?? "operator"
                guard ["operator", "agent"].contains(actor) else {
                    throw CLIError(message: "launch-agent: --by must be operator or agent")
                }
                params["by"] = actor
                if actor == "agent", callerPanelId == nil {
                    throw CLIError(
                        message: "launch-agent: agent-raised flags require C11_PANEL_ID"
                    )
                }
            } else if optionValue(commandArgs, name: "--by") != nil {
                throw CLIError(message: "launch-agent: --by requires --flag")
            }
            if commandArgs.contains("--delegated") || commandArgs.contains("--suppressed") {
                params["delegated"] = true
                // Keep the old spelling alongside the new one for an app
                // version that predates delegated metadata.
                params["suppressed"] = true
            }
            if let v = optionValue(commandArgs, name: "--model") { params["model"] = v }
            if let v = optionValue(commandArgs, name: "--effort") { params["effort"] = v }
            if let sysPromptModeRaw {
                let mode = sysPromptModeRaw.lowercased()
                guard ["inherit", "append", "replace"].contains(mode) else {
                    throw CLIError(message: "launch-agent: --system-prompt-mode must be inherit|append|replace (got: \(sysPromptModeRaw))")
                }
                params["system_prompt_mode"] = mode
                if let sysPromptText { params["system_prompt"] = sysPromptText }
            } else if sysPromptText != nil {
                throw CLIError(message: "launch-agent: --system-prompt/--system-prompt-file requires --system-prompt-mode append|replace")
            }
            if let v = optionValue(commandArgs, name: "--task") { params["task"] = v }
            if let v = optionValue(commandArgs, name: "--title") { params["title"] = v }
            if let launchPrompt { params["prompt"] = launchPrompt }
            if let v = optionValue(commandArgs, name: "--cwd") { params["cwd"] = resolvePath(v) }
            if !launchEnv.isEmpty { params["env"] = launchEnv }
            if launchNewWorkspace {
                params["new_workspace"] = true
            } else {
                let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
                let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
                if let wsId { params["workspace_id"] = wsId }
                let paneId = try normalizePaneHandle(launchPaneRaw, client: client, workspaceHandle: wsId)
                if let paneId { params["area_id"] = paneId }
            }
            if commandArgs.contains("--no-focus") { params["focus"] = false }
            let launchPayload = try client.sendV2(method: "agent.launch", params: params)
            // Accept --json in trailing position too (the documented form);
            // the global parser only consumes it before the subcommand.
            let launchJSONOut = jsonOutput || commandArgs.contains("--json")
            let warningDetails = launchPayload["warning_details"] as? [[String: Any]] ?? []
            var detailedMessages = Set<String>()
            for warning in warningDetails {
                guard let code = warning["code"] as? String,
                      !code.isEmpty,
                      let message = warning["message"] as? String,
                      !message.isEmpty else { continue }
                detailedMessages.insert(message)
                FileHandle.standardError.c11SafeWrite(
                    Data(("warning[" + code + "]: " + message + "\n").utf8)
                )
            }
            if let warnings = launchPayload["warnings"] as? [String] {
                for warning in warnings where !warning.isEmpty && !detailedMessages.contains(warning) {
                    FileHandle.standardError.c11SafeWrite(Data(("warning: " + warning + "\n").utf8))
                }
            }
            printV2Payload(launchPayload, jsonOutput: launchJSONOut, idFormat: idFormat, fallbackText: v2OKSummary(launchPayload, idFormat: idFormat, kinds: ["panel", "area", "workspace"]))

        case "raise-flag", "lower-flag", "delegate", "undelegate", "suppress", "unsuppress":
            guard let rawSurface = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "\(command) requires --panel <id|ref>")
            }
            guard !rawSurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: "\(command): --panel received an empty value")
            }
            let workspaceRaw = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            guard let surfaceHandle = try normalizeSurfaceHandle(
                rawSurface,
                client: client,
                workspaceHandle: workspaceHandle,
                allowFocused: false
            ) else {
                throw CLIError(message: "\(command): panel not found")
            }
            var params: [String: Any] = ["panel_id": surfaceHandle]
            if let workspaceHandle { params["workspace_id"] = workspaceHandle }
            let actor = optionValue(commandArgs, name: "--by") ?? "agent"
            guard ["operator", "agent"].contains(actor) else {
                throw CLIError(message: "\(command): --by must be operator or agent")
            }
            params["by"] = actor

            let method: String
            switch command {
            case "raise-flag":
                method = "flag.raise"
                var positionals: [String] = []
                var index = 0
                while index < commandArgs.count {
                    let value = commandArgs[index]
                    if Self.isFlag(value, "--panel") || ["--workspace", "--window", "--by"].contains(value) {
                        index += 2
                    } else if value == "--json" {
                        index += 1
                    } else {
                        positionals.append(value)
                        index += 1
                    }
                }
                guard positionals.count == 1 else {
                    throw CLIError(message: "raise-flag requires exactly one reason argument")
                }
                params["reason"] = positionals[0]
                let callerPanelId = try resolveCallingSurface(
                    environment: ProcessInfo.processInfo.environment
                )
                if actor == "agent", callerPanelId == nil {
                    throw CLIError(
                        message: "raise-flag: agent-raised flags require C11_PANEL_ID"
                    )
                }
                if let callerPanelId {
                    params["caller_panel_id"] = callerPanelId
                }
            case "lower-flag": method = "flag.lower"
            case "delegate", "suppress":
                method = "flag.delegate"
                let callerPanelId = try resolveCallingSurface(
                    environment: ProcessInfo.processInfo.environment
                )
                if actor == "agent", callerPanelId == nil {
                    throw CLIError(message: "\(command): agent delegation requires C11_PANEL_ID")
                }
                if let callerPanelId { params["caller_panel_id"] = callerPanelId }
            case "undelegate", "unsuppress": method = "flag.undelegate"
            default: method = "flag.undelegate"
            }
            let payload: [String: Any]
            do {
                payload = try client.sendV2(method: method, params: params)
            } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
                let legacyMethod: String?
                switch method {
                case "flag.delegate": legacyMethod = "flag.suppress"
                case "flag.undelegate": legacyMethod = "flag.unsuppress"
                default: legacyMethod = nil
                }
                guard let legacyMethod else { throw error }
                payload = try client.sendV2(method: legacyMethod, params: params)
            }
            let attentionJSON = jsonOutput || commandArgs.contains("--json")
            printV2Payload(
                payload,
                jsonOutput: attentionJSON,
                idFormat: idFormat,
                fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["panel", "workspace"])
            )

        case "config":
            // Only `config launch` reaches here — the app-down subcommands
            // returned before the socket connect. Thin client over the
            // `config.launch` socket method (design §6).
            let cfgSub = commandArgs.first?.lowercased() ?? ""
            guard cfgSub == "launch" else {
                throw CLIError(message: "config: '\(cfgSub)' should have been handled app-down; this is a bug")
            }
            var (cfgParams, cfgJSON) = try buildConfigLaunchParams(subArgs: Array(commandArgs.dropFirst()))
            if client.scopedWindow != nil {
                if let workspace = cfgParams["workspace"] as? String {
                    cfgParams["workspace"] = try resolveWorkspaceId(workspace, client: client)
                }
                if let pane = cfgParams["pane"] as? String {
                    cfgParams["pane"] = try normalizePaneHandle(pane, client: client, workspaceHandle: cfgParams["workspace"] as? String)
                }
            }
            let cfgPayload = try client.sendV2(method: "config.launch", params: cfgParams)
            let cfgJSONOut = jsonOutput || cfgJSON
            printV2Payload(cfgPayload, jsonOutput: cfgJSONOut, idFormat: idFormat, fallbackText: v2OKSummary(cfgPayload, idFormat: idFormat, kinds: ["panel", "area", "workspace"]))

        case "new-panel":
            let workspaceArg = workspaceFromArgsOrEnv(createArgs, windowOverride: windowId)
            let type = optionValue(createArgs, name: "--type")
            let initialInput = try resolvedCreateInput(raw: createCommandText, panelType: type)
            let paneRaw = optionValue(createArgs, name: "--area")
            let url = optionValue(createArgs, name: "--url")
            let file = optionValue(createArgs, name: "--file")
            let cwd = optionValue(createArgs, name: "--cwd")
            let profile = validatedCreateProfile
            if profile != nil, type?.lowercased() != "browser" {
                throw CLIError(message: String(localized: "browser.profile.error.browserOnly", defaultValue: "--profile is only valid for browser panels"))
            }
            let noFocus = createArgs.contains("--no-focus")
            var params: [String: Any] = [:]
            if let initialInput { params["initial_input"] = initialInput }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let paneId = try normalizePaneHandle(paneRaw, client: client, workspaceHandle: wsId)
            if let paneId { params["area_id"] = paneId }
            if let type { params["type"] = type }
            if let url { params["url"] = url }
            if let file { params["file"] = file }
            if let profile { params["profile"] = profile }
            // --cwd <path> wins over the workspace root for a terminal surface.
            // Resolved relative to the CLI's cwd; validated server-side.
            if let cwd = cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
                params["cwd"] = cwd.lowercased() == "inherit" ? "inherit" : resolvePath(cwd)
            }
            if noFocus { params["focus"] = false }
            try addCallingPanel(to: &params)
            let payload = try client.sendV2(method: "panel.create", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: createOKSummary(payload, idFormat: idFormat, kinds: ["panel", "area", "workspace"]))

        case "close-panel":
            try rejectEmptyTargetFlags(commandArgs)
            let csWsFlag = try resolvedSelfCloseTarget(optionValue(commandArgs, name: "--workspace"), kind: "workspace")
            let workspaceArg = csWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            // Preflight requires --panel; `self` is the caller's own panel.
            let surfaceRaw = try resolvedSelfCloseTarget(optionValue(commandArgs, name: "--panel"), kind: "panel")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }
            let payload = try client.sendV2(method: "panel.close", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "area-confirm":
            // Present a confirmation dialog anchored on a specific panel and wait for
            // the user's decision. Maps to the pane.confirm socket method (plan §3.6).
            guard let panelRaw = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "area-confirm requires --panel <id|ref>")
            }
            guard let title = optionValue(commandArgs, name: "--title") else {
                throw CLIError(message: "area-confirm requires --title <text>")
            }
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            let panelId = try normalizeSurfaceHandle(panelRaw, client: client, workspaceHandle: wsId)
            var params: [String: Any] = ["title": title]
            if let panelId { params["panel_id"] = panelId }
            if let wsId { params["workspace_id"] = wsId }
            if let message = optionValue(commandArgs, name: "--message") {
                params["message"] = message
            }
            if commandArgs.contains("--destructive") {
                params["role"] = "destructive"
            }
            if let timeoutStr = optionValue(commandArgs, name: "--timeout") {
                // Fail loudly on unparseable input instead of silently dropping
                // the flag — "cmux pane-confirm ... --timeout abc" used to wait
                // forever.
                guard let timeout = Double(timeoutStr) else {
                    throw CLIError(message: "area-confirm: invalid --timeout '\(timeoutStr)' (expected a number in seconds)")
                }
                params["timeout"] = timeout
            }
            if let confirmLabel = optionValue(commandArgs, name: "--confirm-label") {
                params["confirm_label"] = confirmLabel
            }
            if let cancelLabel = optionValue(commandArgs, name: "--cancel-label") {
                params["cancel_label"] = cancelLabel
            }
            let payload = try client.sendV2(method: "area.confirm", params: params, deadline: .none)
            // Exit code maps to outcome: 0=ok, 2=cancel, 3=dismissed, 1=error.
            // Note: socket reports timeout as "dismissed" (exit 3); the user
            // cannot distinguish a timeout from a panel-teardown from the CLI.
            let outcome = (payload["result"] as? [String: Any])?["result"] as? String
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else if let outcome {
                print(outcome)
            } else {
                print(jsonString(payload))
            }
            switch outcome {
            case "ok": exit(0)
            case "cancel": exit(2)
            case "dismissed": exit(3)
            default: exit(1)
            }

        case "drag-panel-to-split":
            let (panelArg, rem1) = parseOption(commandArgs, name: "--panel")
            guard let panelArg else {
                throw CLIError(message: "drag-panel-to-split requires --panel <id|index>")
            }
            let (workspaceArg, remaining) = parseOption(rem1, name: "--workspace")
            let json = jsonOutput || remaining.contains("--json")
            let directionArgs = remaining.filter { $0 != "--json" }
            guard directionArgs.count == 1, let direction = directionArgs.first else {
                throw CLIError(message: String(localized: "cli.dragPanelToSplit.direction.count", defaultValue: "drag-panel-to-split takes exactly one direction (left|right|up|down)"))
            }
            let workspaceId = try resolveLayoutWorkspaceId(workspaceArg, client: client)
            let panelId = try resolveSurfaceId(panelArg, workspaceId: workspaceId, client: client)
            let payload = try client.sendV2(method: "panel.drag_to_split", params: [
                "workspace_id": workspaceId, "panel_id": panelId, "direction": direction
            ])
            if json {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print("OK \(formatHandle(payload, kind: "area", idFormat: idFormat) ?? "unknown")")
            }

        case "refresh-panels":
            let (workspaceArg, remaining) = parseOption(commandArgs, name: "--workspace")
            let json = jsonOutput || remaining.contains("--json")
            guard remaining.filter({ $0 != "--json" }).isEmpty else {
                throw CLIError(message: String(localized: "cli.layout.arguments.invalid", defaultValue: "Unexpected layout arguments; pass --workspace followed by a workspace handle."))
            }
            let workspaceId = try resolveLayoutWorkspaceId(workspaceArg, client: client)
            let payload = try client.sendV2(method: "panel.refresh", params: ["workspace_id": workspaceId])
            if json {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print("OK Refreshed \(intFromAny(payload["refreshed"]) ?? 0) panels")
            }

        case "panel-health":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "panel.health", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["panels"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No panels")
                } else {
                    for surface in surfaces {
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let inWindow = surface["in_window"]
                        let inWindowStr: String
                        if let b = inWindow as? Bool {
                            inWindowStr = " in_window=\(b)"
                        } else {
                            inWindowStr = ""
                        }
                        print("\(handle)  type=\(sType)\(inWindowStr)")
                    }
                }
            }

        case "debug-terminals":
            let unexpected = commandArgs.filter { $0 != "--" }
            if let extra = unexpected.first {
                throw CLIError(message: "debug-terminals: unexpected argument '\(extra)'")
            }
            let payload = try client.sendV2(method: "debug.terminals")
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print(formatDebugTerminalsPayload(payload, idFormat: idFormat))
            }

        case "trigger-flash":
            let tfWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = tfWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = optionValue(commandArgs, name: "--panel") ?? (tfWsFlag == nil && windowId == nil ? Self.callerPanelEnv() : nil)
            let colorArg = optionValue(commandArgs, name: "--color")
            if let colorArg, !isValidFlashColorHex(colorArg) {
                throw CLIError(message: "--color must be a hex value like #F5C518.")
            }
            let persistent = hasFlag(commandArgs, name: "--persistent")
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }
            if let colorArg { params["color"] = colorArg }
            if persistent { params["persistent"] = true }
            let payload = try client.sendV2(method: "panel.trigger_flash", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "cancel-flash":
            let cfWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = cfWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = optionValue(commandArgs, name: "--panel") ?? (cfWsFlag == nil && windowId == nil ? Self.callerPanelEnv() : nil)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }
            let payload = try client.sendV2(method: "panel.cancel_flash", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "list-panels":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "panel.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let surfaces = payload["panels"] as? [[String: Any]] ?? []
                if surfaces.isEmpty {
                    print("No panels")
                } else {
                    for surface in surfaces {
                        let focused = (surface["focused"] as? Bool) == true
                        let handle = textHandle(surface, idFormat: idFormat)
                        let sType = (surface["type"] as? String) ?? ""
                        let title = (surface["title"] as? String) ?? ""
                        let prefix = focused ? "* " : "  "
                        let focusTag = focused ? "  [focused]" : ""
                        let titlePart = title.isEmpty ? "" : "  \"\(title)\""
                        print("\(prefix)\(handle)  \(sType)\(focusTag)\(titlePart)")
                    }
                }
            }

        case "focus-panel":
            let workspaceArg = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId)
            guard let panelRaw = optionValue(commandArgs, name: "--panel") else {
                throw CLIError(message: "focus-panel requires --panel")
            }
            var params: [String: Any] = [:]
            let wsId: String?
            let workspaceOptionIndex = commandArgs.firstIndex(where: {
                $0 == "--workspace" || $0.hasPrefix("--workspace=")
            })
            if let workspaceOptionIndex {
                let option = commandArgs[workspaceOptionIndex]
                let explicitWorkspace: String?
                if option == "--workspace" {
                    explicitWorkspace = workspaceOptionIndex + 1 < commandArgs.count
                        ? commandArgs[workspaceOptionIndex + 1]
                        : nil
                } else {
                    explicitWorkspace = String(option.dropFirst("--workspace=".count))
                }
                guard let explicitWorkspace else {
                    throw CLIError(message: String(localized: "cli.focus.workspace.requiresValue", defaultValue: "--workspace requires a value"))
                }
                wsId = try resolveWorkspaceId(explicitWorkspace, client: client)
            } else {
                wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            }
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelRaw, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }
            let payload = try client.sendV2(method: "panel.focus", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "close-workspace":
            try rejectEmptyTargetFlags(commandArgs)
            guard let workspaceRaw = try resolvedSelfCloseTarget(optionValue(commandArgs, name: "--workspace"), kind: "workspace") else {
                throw CLIError(message: "close-workspace requires --workspace")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "workspace.close", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "select-workspace":
            guard let workspaceRaw = optionValue(commandArgs, name: "--workspace") else {
                throw CLIError(message: "select-workspace requires --workspace")
            }
            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let payload = try client.sendV2(method: "workspace.select", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "rename-workspace", "rename-window":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let titleArgs = rem0.dropFirst(rem0.first == "--" ? 1 : 0)
            let title = titleArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CLIError(message: "\(command) requires a title")
            }
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let params: [String: Any] = ["title": title, "workspace_id": wsId]
            let payload = try client.sendV2(method: "workspace.rename", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat, kinds: ["workspace"]))

        case "set-workspace-root":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let clear = rem0.contains("--clear")
            let pathArgs = rem0.filter { $0 != "--clear" && $0 != "--" }
            if clear && !pathArgs.isEmpty {
                throw CLIError(message: "set-workspace-root: --clear is mutually exclusive with a path")
            }
            if !clear && pathArgs.count != 1 {
                throw CLIError(message: "set-workspace-root requires one <path> or --clear")
            }
            let workspaceArg = wsArg
                ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            var params: [String: Any] = ["workspace_id": wsId]
            params["root_directory"] = clear ? NSNull() : resolvePath(pathArgs[0])
            let payload = try client.sendV2(method: "workspace.set_root", params: params)
            printV2Payload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallbackText: clear ? "OK cleared workspace root" : "OK \(pathArgs[0])"
            )

        case "get-workspace-root":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let rootJSONOut = jsonOutput || rem0.contains("--json")
            let trailing = rem0.filter { $0 != "--" && $0 != "--json" }
            if !trailing.isEmpty {
                throw CLIError(message: "get-workspace-root: unexpected arguments: \(trailing.joined(separator: " "))")
            }
            let workspaceArg = wsArg
                ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let wsId = try resolveWorkspaceId(workspaceArg, client: client)
            let payload = try client.sendV2(method: "workspace.get_root", params: ["workspace_id": wsId])
            let root = (payload["root_directory"] as? String) ?? ""
            let fallbackText: String
            if root.isEmpty {
                fallbackText = (payload["root_adoption_armed"] as? Bool) == true
                    ? "(none: adopts the first directory its shell visits other than ~ or /)"
                    : "(none)"
            } else if (payload["root_exists"] as? Bool) == false {
                fallbackText = "\(root) (missing: new panels fall back to the focused panel)"
            } else {
                fallbackText = root
            }
            printV2Payload(payload, jsonOutput: rootJSONOut, idFormat: idFormat, fallbackText: fallbackText)

        case "current-workspace":
            let response = client.scopedWindow != nil
                ? try resolveWorkspaceId(nil, client: client)
                : try sendV1Command("current_workspace", client: client)
            if jsonOutput {
                print(jsonString(["workspace_id": response]))
            } else {
                print(response)
            }

        case "read-selection":
            let (wsRaw, rem0) = parseOption(commandArgs, name: "--workspace")
            let (tabRaw, rem1) = parseOption(rem0, name: "--panel")
            let selectionJSONOut = jsonOutput || rem1.contains("--json")
            let trailing = rem1.filter { $0 != "--json" }
            guard trailing.isEmpty else {
                throw CLIError(message: String(format: String(localized: "cli.read_selection.arguments", defaultValue: "read-selection: unexpected arguments: %@"), trailing.joined(separator: " ")))
            }
            let wsArg = try requireNonEmptyHandle(wsRaw, flag: "--workspace", command: "read-selection")
            let tabArg = try requireNonEmptyHandle(tabRaw, flag: "--panel", command: "read-selection")
            let workspaceArg = wsArg ?? (windowId == nil ? nonEmptyEnv("CMUX_WORKSPACE_ID") : nil)
            let surfaceArg = tabArg ?? (wsArg == nil && windowId == nil ? Self.callerPanelEnv() : nil)
            var params: [String: Any] = [:]
            let wsID = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsID { params["workspace_id"] = wsID }
            let panelID = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsID)
            if let panelID { params["panel_id"] = panelID }
            let payload = try client.sendV2(method: "panel.read_selection", params: params)
            if selectionJSONOut {
                print(jsonString(payload))
            } else if payload["has_selection"] as? Bool == true {
                print((payload["text"] as? String) ?? "")
            } else {
                print(String(localized: "cli.read_selection.none", defaultValue: "No selection."))
            }

        case "input-state":
            let (wsRaw, rem0) = parseOption(commandArgs, name: "--workspace")
            // Every spelling (`--panel`, `--tab`, `--surface`) counts toward the one allowed target.
            let (tabValues, rem2) = parseRepeatedOption(rem0, name: "--panel")
            let inputStateJSON = jsonOutput || rem2.contains("--json")
            let trailing = rem2.filter { $0 != "--json" }
            guard trailing.isEmpty else {
                throw CLIError(message: String(format: String(
                    localized: "cli.input_state.arguments",
                    defaultValue: "input-state: unexpected arguments: %@"
                ), trailing.joined(separator: " ")))
            }
            guard tabValues.count <= 1 else {
                throw CLIError(message: String(localized: "cli.input_state.duplicate_tab", defaultValue: "input-state: pass --panel once"))
            }
            let explicitPanel = try requireNonEmptyHandle(tabValues.first, flag: "--panel", command: "input-state")
            guard let explicitPanel else {
                throw CLIError(message: String(localized: "cli.input_state.tab_required", defaultValue: "input-state requires --panel <id|ref>"))
            }
            let workspaceArg = wsRaw ?? nonEmptyEnv("C11_WORKSPACE_ID")
            var params: [String: Any] = [:]
            let workspaceID = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let workspaceID { params["workspace_id"] = workspaceID }
            guard let panelID = try normalizeSurfaceHandle(explicitPanel, client: client, workspaceHandle: workspaceID) else {
                throw CLIError(message: String(localized: "cli.input_state.tab_required", defaultValue: "input-state requires --panel <id|ref>"))
            }
            params["panel_id"] = panelID
            let payload = try client.sendV2(method: "panel.input_state", params: params)
            if inputStateJSON {
                printV2Payload(payload, jsonOutput: true, idFormat: idFormat, fallbackText: "")
            } else {
                let state = payload["input_state"] as? String ?? "unknown"
                let draftLength = debugString(payload["draft_length"]) ?? "null"
                let source = debugString(payload["source"]) ?? "null"
                let observedAt = debugString(payload["observed_at_ms"]) ?? "null"
                print("input_state: \(state) draft_length: \(draftLength) source: \(source) observed_at_ms: \(observedAt)")
            }

        case "read-screen":
            let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArg, rem1) = parseOption(rem0, name: "--panel")
            let (linesArg, rem2) = parseOption(rem1, name: "--lines")
            let trailing = rem2.filter { $0 != "--scrollback" }
            if !trailing.isEmpty {
                throw CLIError(message: "read-screen: unexpected arguments: \(trailing.joined(separator: " "))")
            }

            let workspaceArg = wsArg ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? Self.callerPanelEnv() : nil)

            var params: [String: Any] = [:]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }

            let includeScrollback = rem2.contains("--scrollback")
            if includeScrollback {
                params["scrollback"] = true
            }
            if let linesArg {
                guard let lineCount = Int(linesArg), lineCount > 0 else {
                    throw CLIError(message: "--lines must be greater than 0")
                }
                params["lines"] = lineCount
                params["scrollback"] = true
            }

            let payload = try client.sendV2(method: "panel.read_text", params: params)
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print((payload["text"] as? String) ?? "")
            }

        case "send", "send-panel", "paste":
            guard let parsed = sendInput else { throw CLIError(message: "send requires text") }
            let wsArg = try requireNonEmptyHandle(parsed.workspace, flag: "--workspace", command: command)
            let tabArg = try requireNonEmptyHandle(parsed.panel, flag: "--panel", command: command)
            let envPanel = Self.callerPanelEnv()
            let workspaceArg = wsArg ?? (windowId == nil ? nonEmptyEnv("CMUX_WORKSPACE_ID") : nil)
            let surfaceArg = tabArg ?? (wsArg == nil && windowId == nil ? envPanel : nil)
            // Admit only the effective target after caller-env suppression.
            // send-panel additionally requires its explicit flag, even unscoped.
            guard surfaceArg != nil && (command != "send-panel" || tabArg != nil) else {
                throw CLIError(message: "send requires --panel <id|ref> (or run inside a c11 panel so C11_PANEL_ID is set)")
            }
            if parsed.raw { try requireRawSendSupport(client: client) }
            let stdin = parsed.input == .stdin ? FileHandle.standardInput.readDataToEndOfFile() : Data()
            let text = try parsed.text(stdin: stdin)
            var params: [String: Any] = ["text": text, "submit": parsed.submit]
            if parsed.raw { params["preserve_newlines"] = true }
            if parsed.allowUnguarded { params["allow_unguarded"] = true }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }
            if let callerPanelId = try? resolveCallingSurface(environment: ProcessInfo.processInfo.environment) {
                params["caller_panel_id"] = callerPanelId
            }
            let payload: [String: Any]
            do {
                let response = try client.sendV2(method: "panel.send_text", params: params)
                payload = sendGuardCompatibilityFields(response)
            } catch let error as CLIError where error.structuredResponse != nil {
                if jsonOutput, let structured = error.structuredResponse {
                    print(jsonString(structured))
                }
                throw CLIError(message: error.message)
            }
            printV2Payload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallbackText: sendTextSummary(payload, idFormat: idFormat)
            )

        case "send-key":
            let (wsArgRaw, rem0) = parseOption(commandArgs, name: "--workspace")
            let (sfArgRaw, rem1) = parseOption(rem0, name: "--panel")
            let wsArg = try requireNonEmptyHandle(wsArgRaw, flag: "--workspace", command: "send-key")
            let sfArg = try requireNonEmptyHandle(sfArgRaw, flag: "--panel", command: "send-key")
            let envSurface = Self.callerPanelEnv()
            let workspaceArg = wsArg ?? (windowId == nil ? nonEmptyEnv("CMUX_WORKSPACE_ID") : nil)
            let surfaceArg = sfArg ?? (wsArg == nil && windowId == nil ? envSurface : nil)
            // Require explicit surface targeting (same policy as send).
            // windowId alone is excluded for the same reason: it still routes to focusedPanelId.
            guard surfaceArg != nil else {
                throw CLIError(message: "send-key requires --panel <id|ref> (or run inside a c11 panel so C11_PANEL_ID is set)")
            }
            let keyArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
            let key: String
            do {
                key = try SendKeyArgs.single(keyArgs)
            } catch SendKeyArgs.Failure.missingKey {
                throw CLIError(message: "send-key requires a key")
            }
            var params: [String: Any] = ["key": key]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }
            if let callerPanelId = try? resolveCallingSurface(environment: ProcessInfo.processInfo.environment) {
                params["caller_panel_id"] = callerPanelId
            }
            let payload = try client.sendV2(method: "panel.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "send-key-panel":
            let (wsArgRaw, rem0) = parseOption(commandArgs, name: "--workspace")
            let (panelArgRaw, rem1) = parseOption(rem0, name: "--panel")
            let wsArg = try requireNonEmptyHandle(wsArgRaw, flag: "--workspace", command: "send-key-panel")
            let workspaceArg = wsArg ?? (windowId == nil ? nonEmptyEnv("CMUX_WORKSPACE_ID") : nil)
            guard let panelArg = try requireNonEmptyHandle(panelArgRaw, flag: "--panel", command: "send-key-panel") else {
                throw CLIError(message: "send-key-panel requires --panel")
            }
            let skpArgs = rem1.first == "--" ? Array(rem1.dropFirst()) : rem1
            let key: String
            do {
                key = try SendKeyArgs.single(skpArgs)
            } catch SendKeyArgs.Failure.missingKey {
                throw CLIError(message: "send-key-panel requires a key")
            }
            guard !key.isEmpty else { throw CLIError(message: "send-key-panel requires a key") }
            var params: [String: Any] = ["key": key]
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(panelArg, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }
            if let callerPanelId = try? resolveCallingSurface(environment: ProcessInfo.processInfo.environment) {
                params["caller_panel_id"] = callerPanelId
            }
            let payload = try client.sendV2(method: "panel.send_key", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "notify":
            let title = optionValue(commandArgs, name: "--title") ?? "Notification"
            let subtitle = optionValue(commandArgs, name: "--subtitle") ?? ""
            let body = optionValue(commandArgs, name: "--body") ?? ""

            let notifyWsFlag = optionValue(commandArgs, name: "--workspace")
            let workspaceArg = notifyWsFlag ?? (windowId == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
            let surfaceArg = optionValue(commandArgs, name: "--panel") ?? (notifyWsFlag == nil && windowId == nil ? Self.callerPanelEnv() : nil)

            var params: [String: Any] = ["title": title, "subtitle": subtitle, "body": body]
            if let payload = nonEmptyEnv("C11_CODEX_NOTIFY_PAYLOAD_B64") {
                params["legacy_codex_notify_payload_b64"] = payload
                // The interactive Codex's own PID (inherited from its c11
                // wrapper): the turn-complete edge opens the mailbox gate
                // only for that process.
                if let raw = nonEmptyEnv("C11_AGENT_INTERACTIVE_PID"), let pid = Int32(raw), pid > 1 {
                    params["agent_pid"] = Int(pid)
                }
            }
            let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client)
            if let wsId { params["workspace_id"] = wsId }
            let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId)
            if let sfId { params["panel_id"] = sfId }

            let method = sfId != nil ? "notification.create_for_panel" : "notification.create"
            let payload = try client.sendV2(method: method, params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2OKSummary(payload, idFormat: idFormat))

        case "feed":
            try FeedCommand.run(
                arguments: commandArgs,
                jsonOutput: jsonOutput,
                client: client,
                reconnect: {
                    client.close()
                    try client.connect()
                    try authenticateClientIfNeeded(client, explicitPassword: socketPasswordArg, socketPath: resolvedSocketPath)
                },
                defaultWorkspace: { workspaceFromArgsOrEnv(commandArgs, windowOverride: windowId) },
                // feed.answer runs on a socket worker and accepts exact UUIDs;
                // canonicalize the public short refs here after the normal CLI
                // resolver has applied the same workspace/tab scoping rules.
                resolveWorkspace: { raw in
                    guard let handle = try normalizeWorkspaceHandle(raw, client: client) else { return nil }
                    return try canonicalWorkspaceID(handle, client: client)
                },
                resolvePanel: { raw, ws in
                    guard let handle = try normalizeSurfaceHandle(raw, client: client, workspaceHandle: ws) else { return nil }
                    return try canonicalPanelID(handle, workspaceID: ws, client: client)
                }
            )

        case "list-notifications":
            let response = try sendV1Command("list_notifications", client: client)
            if jsonOutput {
                let notifications = parseNotifications(response)
                let payload = notifications.map { item in
                    var dict: [String: Any] = [
                        "id": item.id,
                        "workspace_id": item.workspaceId,
                        "is_read": item.isRead,
                        "title": item.title,
                        "subtitle": item.subtitle,
                        "body": item.body
                    ]
                    dict["panel_id"] = item.surfaceId ?? NSNull()
                    return dict
                }
                print(jsonString(payload))
            } else {
                print(response)
            }

        case "clear-notifications":
            var socketCmd = "clear_notifications"
            if let wsFlag = optionValue(commandArgs, name: "--workspace") {
                let wsId = try resolveWorkspaceId(wsFlag, client: client)
                socketCmd += " --tab=\(wsId)"
            } else if windowId != nil {
                let wsId = try resolveWorkspaceId(nil, client: client)
                socketCmd += " --tab=\(wsId)"
            } else if let envWs = ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"], !envWs.isEmpty {
                // A malformed value must fail here: swallowing it would send an
                // untargeted clear_notifications, which clears every workspace.
                let wsId = try resolveWorkspaceId(envWs, client: client)
                socketCmd += " --tab=\(wsId)"
            }
            let response = try sendV1Command(socketCmd, client: client)
            print(response)

        case "set-status":
            let response = try forwardSidebarMetadataCommand(
                "set_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-status":
            let response = try forwardSidebarMetadataCommand(
                "clear_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "list-status":
            let response = try forwardSidebarMetadataCommand(
                "list_status",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "set-progress":
            let response = try forwardSidebarMetadataCommand(
                "set_progress",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-progress":
            let response = try forwardSidebarMetadataCommand(
                "clear_progress",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "log":
            let response = try forwardSidebarMetadataCommand(
                "log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "clear-log":
            let response = try forwardSidebarMetadataCommand(
                "clear_log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "list-log":
            let response = try forwardSidebarMetadataCommand(
                "list_log",
                commandArgs: commandArgs,
                client: client,
                windowOverride: windowId
            )
            print(response)

        case "sidebar-state":
            // --json emits the v2 sidebar.state response (includes agent_chip).
            if commandArgs.contains("--json") || jsonOutput {
                let workspaceRaw = optionValue(commandArgs, name: "--workspace")
                    ?? sidebarWorkspaceFromEnv()
                let workspaceId: String
                if let workspaceRaw {
                    workspaceId = try resolveWorkspaceId(workspaceRaw, client: client)
                } else {
                    throw CLIError(message: String(localized: "cli.sidebar.target.required", defaultValue: "sidebar command requires --workspace or C11_WORKSPACE_ID; it will not use the selected workspace"))
                }
                let params: [String: Any] = [
                    "workspace_id": workspaceId
                ]
                let payload = try client.sendV2(method: "sidebar.state", params: params)
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let response = try forwardSidebarMetadataCommand(
                    "sidebar_state",
                    commandArgs: commandArgs,
                    client: client,
                    windowOverride: windowId
                )
                print(response)
            }

        case "set-agent":
            try runSetAgentCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "default-agent":
            try runDefaultAgentCommand(
                commandArgs: commandArgs,
                client: client
            )

        case "set-metadata":
            try runSetMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "get-metadata":
            try runGetMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "clear-metadata":
            try runClearMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "set-workspace-metadata":
            try runSetWorkspaceMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "get-workspace-metadata":
            try runGetWorkspaceMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "clear-workspace-metadata":
            try runClearWorkspaceMetadataCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "set-workspace-description":
            try runSetWorkspaceCanonicalKeyCommand(
                key: "description",
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "set-workspace-icon":
            try runSetWorkspaceCanonicalKeyCommand(
                key: "icon",
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "conversation":
            try runConversationCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        case "state":
            // C11-131: `c11 state save|verify`. `save` forces a synchronous
            // full-app snapshot via the running app; `verify` is a read-only
            // resume-decision dry run that needs no running app.
            try runStateCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        case "app":
            // C11-131: `c11 app restart [--no-resume]` — clean bounce of the
            // running instance.
            try runAppCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        case "claude-hook":
            cliTelemetry.breadcrumb("claude-hook.dispatch")
            do {
                try runClaudeHook(commandArgs: commandArgs, client: client, telemetry: cliTelemetry, rawInput: journalHookInput ?? "", journalDraft: journalHookDraft, socketCeiling: priorProcessDeadline)
                cliTelemetry.breadcrumb("claude-hook.completed")
            } catch let error as CLIError where isAdvisoryHookConnectivityError(error)
                || error.message == SocketClient.commandTimedOutMessage {
                // claude-hook is advisory — it signals c11 about Claude Code
                // lifecycle events (prompt submitted, notification, etc.) so
                // the sidebar can update. When c11 isn't running (socket
                // missing / refused / path orphaned from a crashed process),
                // there's nothing to signal. Exit cleanly so Claude Code
                // doesn't surface a hook-error banner on every prompt. Real
                // hook bugs (malformed input, logic errors) still propagate.
                cliTelemetry.breadcrumb("claude-hook.socket-unreachable")
                if let journalHookDraft { _ = JournalCommand.spool(journalHookDraft) }
                if commandArgs.first?.lowercased() == "permission-request" { print("{}") }
            } catch {
                cliTelemetry.breadcrumb("claude-hook.failure")
                cliTelemetry.captureError(stage: "claude_hook_dispatch", error: error)
                throw error
            }

        case "agent-hook", "codex-hook":
            try runAgentHook(
                commandName: command,
                commandArgs: commandArgs,
                client: client
            )

        case "set-app-focus":
            guard let value = commandArgs.first else { throw CLIError(message: "set-app-focus requires a value") }
            let response = try sendV1Command("set_app_focus \(value)", client: client)
            print(response)

        case "simulate-app-active":
            let response = try sendV1Command("simulate_app_active", client: client)
            print(response)

        case "__tmux-compat":
            try runClaudeTeamsTmuxCompat(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "capture-pane",
             "resize-pane",
             "pipe-pane",
             "wait-for",
             "swap-pane",
             "break-pane",
             "join-pane",
             "last-window",
             "last-pane",
             "next-window",
             "previous-window",
             "find-window",
             "clear-history",
             "set-hook",
             "popup",
             "bind-key",
             "unbind-key",
             "copy-mode",
             "set-buffer",
             "paste-buffer",
             "list-buffers",
             "respawn-pane",
             "display-message":
            try runTmuxCompatCommand(
                command: command,
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowId
            )

        case "help":
            print(usage())

        // Browser commands
        case "browser":
            try runBrowserCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Legacy aliases shimmed onto the v2 browser command surface.
        case "open-browser":
            try runBrowserCommand(commandArgs: ["open"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "navigate":
            try runBrowserCommand(commandArgs: ["navigate"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-back":
            try runBrowserCommand(commandArgs: ["back"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-forward":
            try runBrowserCommand(commandArgs: ["forward"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "browser-reload":
            try runBrowserCommand(commandArgs: ["reload"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "get-url":
            try runBrowserCommand(commandArgs: ["get-url"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus-webview":
            try runBrowserCommand(commandArgs: ["focus-webview"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "is-webview-focused":
            try runBrowserCommand(commandArgs: ["is-webview-focused"] + commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // Markdown commands
        case "markdown":
            try runMarkdownCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        case "markdown-content":
            try runMarkdownGetContentCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)

        // c11 chrome theme commands.
        case "themes":
            try runUiThemes(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                allowAuthoringHelpers: false
            )

        // Legacy UI / theme commands (CMUX-35)
        case "ui":
            try runUi(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)

        case "workspace-color":
            try runWorkspaceColor(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)

        case "panel-color":
            try runSurfaceColor(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)

        // C11-13 Stage 2: inter-agent mailbox (send/recv/trace/tail + helpers).
        case "mailbox":
            try runMailboxCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput
            )

        // C11-257 D: the messages page is the durable, visual view over both
        // explicit sends and mailbox traffic.
        case "messages":
            try runMessagesCommand(
                commandArgs: commandArgs,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat
            )

        default:
            print(usage())
            throw CLIError(message: "Unknown command: \(command)")
        }
    }
}
