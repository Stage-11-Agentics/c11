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

    func connectClient(
        socketPath: String,
        explicitPassword: String?,
        launchIfNeeded: Bool
    ) throws -> SocketClient {
        let client = SocketClient(path: socketPath)
        if launchIfNeeded && (try? client.connect()) == nil {
            client.close()
            try launchApp()
            let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
            try authenticateClientIfNeeded(
                launchedClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath
            )
            return launchedClient
        }

        try client.connect()
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath
        )
        return client
    }

    func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath,
            deadline: SocketClient.processDeadline
        ) {
            let authResponse = try client.send(command: "auth \(socketPassword)")
            if authResponse.hasPrefix("ERROR:"),
               !authResponse.contains("Unknown command 'auth'") {
                throw CLIError(message: authResponse)
            }
        }
    }

    func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "c11"]
        try process.run()
        process.waitUntilExit()
    }

    func activateApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "c11"]
        try process.run()
        process.waitUntilExit()
    }

    func resolvedIDFormat(jsonOutput: Bool, raw: String?) throws -> CLIIDFormat {
        _ = jsonOutput
        if let parsed = try CLIIDFormat.parse(raw) {
            return parsed
        }
        return .refs
    }

    func sendV1Command(_ command: String, client: SocketClient) throws -> String {
        let response = try client.send(command: command)
        if response.hasPrefix("ERROR:") {
            throw CLIError(message: response)
        }
        return response
    }

    func formatIDs(_ object: Any, mode: CLIIDFormat) -> Any {
        switch object {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = formatIDs(v, mode: mode)
            }

            switch mode {
            case .both:
                break
            case .refs:
                if out["ref"] != nil && out["id"] != nil {
                    out.removeValue(forKey: "id")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_id") {
                    let prefix = String(key.dropLast(3))
                    if out["\(prefix)_ref"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_ids") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_refs"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            case .uuids:
                if out["id"] != nil && out["ref"] != nil {
                    out.removeValue(forKey: "ref")
                }
                let keys = Array(out.keys)
                for key in keys where key.hasSuffix("_ref") {
                    let prefix = String(key.dropLast(4))
                    if out["\(prefix)_id"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
                for key in keys where key.hasSuffix("_refs") {
                    let prefix = String(key.dropLast(5))
                    if out["\(prefix)_ids"] != nil {
                        out.removeValue(forKey: key)
                    }
                }
            }
            return out

        case let array as [Any]:
            return array.map { formatIDs($0, mode: mode) }

        default:
            return object
        }
    }

    func intFromAny(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    func doubleFromAny(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float { return Double(f) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    func parseBoolString(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    func parsePositiveInt(_ raw: String?, label: String) throws -> Int? {
        guard let raw else { return nil }
        guard let value = Int(raw) else {
            throw CLIError(message: "\(label) must be an integer")
        }
        return value
    }

    func isHandleRef(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        let kind = String(pieces[0]).lowercased()
        guard ["window", "workspace", "area", "panel", "tab", "pane", "surface"].contains(kind) else { return false }
        return Int(String(pieces[1])) != nil
    }

    /// The workspace to send beside a panel target when no `--workspace` was
    /// given. C11_WORKSPACE_ID is where the caller's shell started and goes
    /// stale once its panel moves (C11-491). c11 finds a panel named by UUID
    /// or ref in any workspace, so the environment's workspace is sent only
    /// when the panel needs one to resolve in: an index, or no panel at all.
    func envWorkspaceForPanelTarget(_ panel: String?) -> String? {
        let trimmed = panel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isUUID(trimmed) || isHandleRef(trimmed) { return nil }
        return ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
    }

    func normalizeWindowHandle(_ raw: String?, client: SocketClient, allowCurrent: Bool = false) throws -> String? {
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "window.current")
            return (current["window_id"] as? String) ?? (current["window_ref"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) {
            return trimmed
        }
        // V1 focus/close and several V2 methods accept only a UUID in
        // `window_id`. Resolve refs and indexes here so every CLI command that
        // accepts a window handle sends the same live identifier downstream.
        return try resolveScopedWindow(trimmed, client: client)
    }

    func resolveScopedWindow(_ raw: String, client: SocketClient) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = try client.sendV2(method: "window.list")
        let windows = listed["windows"] as? [[String: Any]] ?? []
        for window in windows {
            let id = window["id"] as? String
            let ref = window["ref"] as? String
            if !token.isEmpty,
               id?.caseInsensitiveCompare(token) == .orderedSame
                || ref?.caseInsensitiveCompare(token) == .orderedSame
                || (Int(token) != nil && intFromAny(window["index"]) == Int(token)),
               let handle = id ?? ref {
                return handle
            }
        }
        throw CLIError(message: String(format:
            String(localized: "cli.window.unknown", defaultValue: "Unknown window '%@'."), raw))
    }

    func normalizeWorkspaceHandle(
        _ raw: String?,
        client: SocketClient,
        windowHandle: String? = nil,
        allowCurrent: Bool = false
    ) throws -> String? {
        let windowHandle = windowHandle ?? client.scopedWindow
        guard let raw else {
            if !allowCurrent { return nil }
            let current = try client.sendV2(method: "workspace.current")
            return (current["workspace_ref"] as? String) ?? (current["workspace_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid workspace handle: \(trimmed) (expected UUID, ref like workspace:1, or index)")
        }

        if let windowHandle {
            // Caller scoped to a specific window — list only that window's workspaces.
            let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowHandle])
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            for item in items where intFromAny(item["index"]) == wantedIndex {
                return (item["ref"] as? String) ?? (item["id"] as? String)
            }
        } else {
            // No window filter: scan all windows so --workspace 1 finds the correct workspace
            // even if it lives in a different window than the socket's default context.
            let windowsPayload = try client.sendV2(method: "window.list")
            let windows = windowsPayload["windows"] as? [[String: Any]] ?? []
            for window in windows {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where intFromAny(item["index"]) == wantedIndex {
                    return (item["ref"] as? String) ?? (item["id"] as? String)
                }
            }
        }
        throw CLIError(message: "Workspace index not found")
    }

    func canonicalWorkspaceID(_ handle: String, client: SocketClient) throws -> String? {
        if isUUID(handle) { return handle }
        let windowsPayload = try client.sendV2(method: "window.list")
        let windows = windowsPayload["windows"] as? [[String: Any]] ?? []
        for window in windows {
            guard let windowID = window["id"] as? String else { continue }
            let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowID])
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            if let item = items.first(where: {
                ($0["ref"] as? String)?.caseInsensitiveCompare(handle) == .orderedSame
                    || ($0["id"] as? String)?.caseInsensitiveCompare(handle) == .orderedSame
            }) {
                return item["id"] as? String
            }
        }
        throw CLIError(message: "Workspace handle no longer resolves: \(handle)")
    }

    func canonicalPanelID(_ handle: String, workspaceID: String?, client: SocketClient) throws -> String? {
        if isUUID(handle) { return handle }
        var params: [String: Any] = [:]
        if let workspaceID { params["workspace_id"] = workspaceID }
        let listed = try client.sendV2(method: "panel.list", params: params)
        let items = listed["panels"] as? [[String: Any]] ?? []
        // `panel:N`, `tab:N` and `surface:N` (any case) name the same panel.
        let wanted = Self.canonicalHandle(handle).lowercased()
        guard let item = items.first(where: {
            ($0["ref"] as? String).map { Self.canonicalHandle($0).lowercased() == wanted } == true
                || ($0["id"] as? String)?.caseInsensitiveCompare(handle) == .orderedSame
        }), let id = item["id"] as? String else {
            throw CLIError(message: "Panel handle no longer resolves: \(handle)")
        }
        return id
    }

    func normalizePaneHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["area_ref"] as? String) ?? (focused["area_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid area handle: \(trimmed) (expected UUID, ref like area:1, or index)")
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let listed = try client.sendV2(method: "area.list", params: params)
        let items = listed["areas"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Area index not found")
    }

    /// C11-173: an explicitly-passed but empty ref — `--surface "$REF"` where the
    /// shell lookup produced nothing — must be an error, not a fallback. Empty
    /// used to trim to nil, the CLI then omitted `surface_id`, and the server
    /// fell back to the focused pane of the workspace it defaulted from the
    /// *caller's* environment: the caller's own input box. Silent, and aimed at
    /// the wrong target.
    func requireNonEmptyHandle(_ raw: String?, flag: String, command: String) throws -> String? {
        guard let raw else { return nil }
        if Self.isFlag(flag, "--panel") {
            return try validatedPanelTargetValue(raw, wasProvided: true)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "\(command): \(flag) was empty. Pass an id, ref (e.g. panel:2), or index.")
        }
        return trimmed
    }

    /// One contract for every explicit panel target, before command dispatch can
    /// turn an empty or missing option into the caller-panel default.
    func validatedPanelTargetValue(_ raw: String?, wasProvided: Bool) throws -> String? {
        guard wasProvided else { return nil }
        guard let raw else {
            throw CLIError(message: String(localized: "cli.panel_ref.requires_value", defaultValue: "--panel requires a value"))
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: String(localized: "cli.panel_ref.empty_ref", defaultValue: "empty_ref: --panel was provided but empty"))
        }
        return trimmed
    }

    struct PanelTargetPreflightSpec {
        let valueOptions: Set<String>
        let valueOptionsRejectingLongFlags: Set<String>
        let honorsEndOfOptions: Bool
        let literalEvalScriptTailStart: Int?
        let literalPanelFlagArgumentIndices: Set<Int>

        init(
            valueOptions: Set<String>,
            valueOptionsRejectingLongFlags: Set<String> = [],
            honorsEndOfOptions: Bool,
            literalEvalScriptTailStart: Int? = nil,
            literalPanelFlagArgumentIndices: Set<Int> = []
        ) {
            self.valueOptions = valueOptions
            self.valueOptionsRejectingLongFlags = valueOptionsRejectingLongFlags
            self.honorsEndOfOptions = honorsEndOfOptions
            self.literalEvalScriptTailStart = literalEvalScriptTailStart
            self.literalPanelFlagArgumentIndices = literalPanelFlagArgumentIndices
        }
    }

    /// Command-local accepted options for the pre-connect unknown-flag check.
    /// Each command declares its accepted options alongside the preflight
    /// parser; aliases are expanded from the same table used by
    /// `parseOption`/`optionValue`. Three rules apply to every spec, so no
    /// command lists them: `--json` is the global output switch, a declared
    /// value option also accepts `--name=value` (rewritten to `--name value`
    /// before any parser runs), and alias spellings come from `flagAliasGroups`.
    /// DEBUG builds check the declarations against the names each parser reads
    /// (`CLIFlagReadLog`).
    struct CLIFlagPreflightSpec {
        var flags: Set<String>
        var valueOptions: Set<String>
        var literalFlagArgumentIndices: Set<Int>
        var literalTailStart: Int?
        /// From this index the parser takes words it does not recognize as
        /// text, but still reads its own options there (browser `type`).
        /// Declared options are checked and rewritten; other flag-shaped words
        /// pass as text; `--` makes the rest literal.
        var textStart: Int?
        var honorsEndOfOptions: Bool
        /// How many positional words the parser reads, set from
        /// `declaredPositionalArity` (subcommand words included).
        var positionals: CLIPositionalArity = .unchecked

        init(
            flags: Set<String> = [],
            valueOptions: Set<String> = [],
            literalFlagArgumentIndices: Set<Int> = [],
            literalTailStart: Int? = nil,
            textStart: Int? = nil,
            honorsEndOfOptions: Bool = false
        ) {
            self.flags = flags.union(valueOptions)
            self.valueOptions = valueOptions
            self.literalFlagArgumentIndices = literalFlagArgumentIndices
            self.literalTailStart = literalTailStart
            self.textStart = textStart
            self.honorsEndOfOptions = honorsEndOfOptions
        }
    }

    /// Positional words outside text regions. A parser that reads none, or a
    /// fixed few, gets a bound so a stray word (`close-panel panel:268`) fails
    /// before the socket instead of being ignored.
    enum CLIPositionalArity: Equatable {
        /// Not declared yet. DEBUG builds' declaration test fails on it.
        case unchecked
        /// The parser reads a variable list or joins words into text.
        case any
        case atMost(Int)

        static let none = CLIPositionalArity.atMost(0)

        var logValue: String {
            switch self {
            case .unchecked: return "unchecked"
            case .any: return "any"
            case .atMost(let count): return "atMost:\(count)"
            }
        }
    }

    struct CLIFlagPreflightResult {
        /// The command's argv with each `--name=value` for a declared value
        /// option split into `--name value`. Text regions are untouched.
        var args: [String]
        /// A post-command `--json` in a flag position: the same switch as
        /// `c11 --json <command>`.
        var requestsJSON: Bool
    }

    func preflightCommandFlags(command: String, args: [String]) throws -> CLIFlagPreflightResult {
        if command == "__tmux-compat" {
            try validateClaudeTeamsTmuxFlags(args)
            return CLIFlagPreflightResult(args: args, requestsJSON: false)
        }
        if let separator = args.firstIndex(of: "--"), args.index(after: separator) < args.endIndex,
           command == "clear-notifications" || (command == "state" && args.first?.lowercased() == "save") {
            let unexpected = args[args.index(after: separator)]
            let commandName = command == "state" ? "state save" : command
            throw CLIError(message: unexpectedArgumentMessage(command: commandName, argument: unexpected))
        }
        // Browser and markdown choose their declaration by the verb after the
        // target options, so split a leading `--panel=<ref>` first to make
        // `browser --panel=<ref> click` select `click`. Every other command's
        // options are rewritten by the declaration-aware scan below. A command
        // with no declaration (claude-teams) forwards argv untouched.
        let originalArgs = args
        let args = command == "browser" || command == "markdown" ? splittingLeadingTargetOptions(args) : args
        guard var spec = commandFlagPreflightSpec(command: command, args: args) else {
            return CLIFlagPreflightResult(args: originalArgs, requestsJSON: false)
        }
        for flag in Array(spec.flags) {
            let spellings = Self.flagSpellings(flag)
            spec.flags.formUnion(spellings)
            if spec.valueOptions.contains(flag) { spec.valueOptions.formUnion(spellings) }
        }
        spec.positionals = declaredPositionalArity(command: command, args: args)
        var normalized: [String] = []
        var requestsJSON = false
        var positionalCount = 0
        func countPositional(_ word: String) throws {
            positionalCount += 1
            if case .atMost(let limit) = spec.positionals, positionalCount > limit {
                throw CLIError(message: unexpectedPositionalMessage(command: command, word: word, valueOptions: spec.valueOptions))
            }
        }
        var index = 0
        while index < args.count {
            if spec.literalFlagArgumentIndices.contains(index) {
                try countPositional(args[index])
                normalized.append(args[index])
                index += 1
                continue
            }
            if spec.literalTailStart.map({ index >= $0 }) ?? false {
                normalized.append(args[index])
                index += 1
                continue
            }
            let inText = spec.textStart.map { index >= $0 } ?? false
            if args[index] == "--" {
                if spec.honorsEndOfOptions || inText {
                    normalized.append(contentsOf: args[index...])
                    break
                }
                normalized.append(args[index])
                index += 1
                continue
            }
            let argument = args[index]
            guard argument.range(
                of: #"^--?[A-Za-z][A-Za-z0-9-]*(?:=.*)?$"#,
                options: .regularExpression
            ) != nil else {
                if !inText { try countPositional(argument) }
                normalized.append(argument)
                index += 1
                continue
            }
            if spec.flags.contains(argument), !spec.valueOptions.contains(argument) {
                // A boolean, including literal `--name=value` spellings a
                // parser compares whole (`--auto-expand=true`).
                if argument == "--json" { requestsJSON = true }
                normalized.append(argument)
                index += 1
                continue
            }
            let equalsIndex = argument.firstIndex(of: "=")
            let name = equalsIndex.map { String(argument[..<$0]) } ?? argument
            if spec.valueOptions.contains(name) {
                if let equalsIndex {
                    normalized.append(name)
                    normalized.append(String(argument[argument.index(after: equalsIndex)...]))
                    index += 1
                    continue
                }
                guard index + 1 < args.count, args[index + 1] != "--" else {
                    throw CLIError(message: requiresValueMessage(command: command, flag: name))
                }
                // Match the CLI's existing permissive value helpers: a token
                // after a value option is that value even when it starts with
                // dashes (for example a shell command or a title).
                normalized.append(argument)
                normalized.append(args[index + 1])
                index += 2
                continue
            }
            if argument == "--json" {
                requestsJSON = true
                normalized.append(argument)
                index += 1
                continue
            }
            if inText {
                normalized.append(argument)
                index += 1
                continue
            }
            throw CLIError(message: unknownFlagMessage(command: command, flag: argument))
        }
        #if DEBUG
        CLIFlagReadLog.recordAccepted(
            command: command,
            flags: spec.flags.union(["--json"]),
            arity: spec.positionals.logValue,
            positionals: positionalCount
        )
        #endif
        return CLIFlagPreflightResult(args: normalized, requestsJSON: requestsJSON)
    }

    /// How many positional words each command's parser reads, counting the
    /// subcommand words themselves (`config list` reads 1, `browser <ref> get
    /// attr <sel> <attr>` reads 5). Text a parser joins, a variable list, and a
    /// parser that treats every `--word` as taking a value are `.any`, so the
    /// bound never rejects a word a parser reads. Help-dispatch and
    /// unsupported commands keep their own errors (`.any`).
    func declaredPositionalArity(command: String, args: [String]) -> CLIPositionalArity {
        let first = args.first?.lowercased()
        func sub(_ table: [String: Int], bare: Int = 0) -> CLIPositionalArity {
            guard let first else { return .atMost(bare) }
            return table[first].map { .atMost($0) } ?? .any
        }
        switch command {
        case "workspace-action", "panel-action", "rename-panel", "set-title", "set-description", "ssh",
             "rename-workspace", "rename-window", "send", "send-panel", "paste", "set-status", "clear-status",
             "set-progress", "log", "set-workspace-metadata", "get-workspace-metadata", "clear-workspace-metadata",
             "set-workspace-description", "set-workspace-icon", "pipe-pane", "find-window", "set-hook",
             "set-buffer", "respawn-pane", "display-message", "open-browser", "navigate",
             "popup", "bind-key", "unbind-key", "copy-mode", "claude-teams":
            return .any
        case "ping", "capabilities", "brand", "identify", "list-windows", "current-window", "new-window",
             "focus-window", "close-window", "move-workspace-to-window", "reorder-workspaces", "get-titlebar-state",
             "list-workspaces", "ssh-session-end", "workspace-apply", "snapshot", "list-snapshots", "new-workspace",
             "list-areas", "list-area-panels", "tree", "family", "launch-agent", "lower-flag", "delegate",
             "undelegate", "suppress", "unsuppress", "new-panel", "close-panel", "area-confirm", "refresh-panels",
             "panel-health", "debug-terminals", "trigger-flash", "cancel-flash", "list-panels", "focus-panel",
             "close-workspace", "select-workspace", "get-workspace-root", "current-workspace", "read-selection",
             "input-state", "read-screen", "notify", "list-notifications", "clear-notifications", "list-status",
             "clear-progress", "clear-log", "list-log", "sidebar-state", "set-agent", "set-metadata",
             "get-metadata", "clear-metadata", "simulate-app-active", "markdown-content", "usage", "report",
             "remote-daemon-status", "health", "doctor", "feedback", "agents", "capture-pane",
             "swap-pane", "break-pane", "join-pane", "last-window", "next-window", "previous-window", "last-pane",
             "clear-history", "paste-buffer", "list-buffers", "browser-back", "browser-forward",
             "browser-reload", "get-url", "focus-webview", "is-webview-focused":
            return .none
        case "move-panel", "reorder-panel", "reorder-workspace", "set-panel-icon", "set-panel-color", "restore",
             "new-split", "new-area", "focus-area", "raise-flag", "drag-panel-to-split", "set-workspace-root",
             "send-key", "send-key-panel", "set-app-focus", "guide", "wait-for", "agent-event", "history",
             "agent-hook", "codex-hook", "resize-pane":
            return .atMost(1)
        case "rpc", "resize-window":
            return .atMost(2)
        case "workspace":
            if first == "recents" {
                switch args.dropFirst().first?.lowercased() {
                case "list": return .atMost(2)
                case "pin", "unpin", "remove": return .atMost(3)
                case nil: return .atMost(1)
                default: return .any
                }
            }
            return sub(["apply": 1, "new": 1, "export-blueprint": 1])
        case "feed":
            switch firstCommandWord(args, valueOptions: Set(Self.flagSpellings("--panel")).union(["--workspace", "--scope", "--text", "--by"])) {
            case "list", "watch": return .atMost(1)
            case "open", "answer": return .atMost(2)
            default: return .any
            }
        case "default-agent": return sub(["get": 1, "set": 2, "launch": 1])
        case "conversation":
            return sub(["capture-runtime": 1, "claim": 1, "push": 1, "tombstone": 1, "list": 1, "get": 1,
                        "clear": 1, "resume": 1, "help": 1])
        case "state": return sub(["save": 1, "verify": 2, "help": 1])
        case "app": return sub(["restart": 1, "help": 1])
        case "claude-hook":
            return sub(["session-start": 1, "active": 1, "stop": 1, "idle": 1, "prompt-submit": 1,
                        "notification": 1, "notify": 1, "session-end": 1, "pre-tool-use": 1, "post-tool-use": 1,
                        "stop-failure": 1, "subagent-start": 1, "subagent-stop": 1, "pre-compact": 1,
                        "permission-request": 1, "help": 1])
        case "messages": return sub(["view": 1, "help": 1])
        case "journal": return sub(["query": 1, "export": 1, "clear": 1])
        case "skill":
            return sub(["path": 1, "status": 1, "list": 1, "install": 1, "remove": 1, "uninstall": 1, "help": 1])
        case "terminal-theme": return sub(["list": 1, "clear": 1])
        case "model-costs": return sub(["list": 1, "help": 1])
        case "events": return sub(["tail": 1, "help": 1])
        case "config": return sub(["list": 1, "recent": 1, "stats": 1])
        case "themes":
            return sub(["list": 1, "get": 1, "clear": 1, "reload": 1, "path": 1, "dump": 1, "set": 2, "validate": 2, "diff": 3])
        case "ui":
            guard first == "themes" else { return first == nil ? .none : .any }
            switch args.dropFirst().first?.lowercased() {
            case nil: return .atMost(1)
            case "list", "get", "clear", "reload", "path", "dump": return .atMost(2)
            case "set", "validate", "inherit": return .atMost(3)
            case "diff": return .atMost(4)
            default: return .any
            }
        case "workspace-color", "panel-color": return sub(["set": 2, "get": 1, "clear": 1, "list-palette": 1])
        case "workspace-group":
            return sub(["list": 1, "create": 1, "rename": 1, "delete": 1, "ungroup": 1, "collapse": 1,
                        "expand": 1, "pin": 1, "unpin": 1, "focus": 1, "add": 1, "remove": 1, "move": 1,
                        "set-color": 1, "set-icon": 1])
        case "markdown":
            var routed = args
            for name in ["--workspace", "--window", "--panel", "--area"] { routed = parseOption(routed, name: name).1 }
            switch routed.first?.lowercased() {
            case "scroll", "visible", "theme", "typeface", "font", "open-external", "history", "links", "backlinks":
                return .atMost(1)
            case "open": return .atMost(2)
            case nil: return .none
            default: return .atMost(1)
            }
        case "mailbox":
            return sub(["send": 2, "trace": 2, "recv": 1, "view": 1, "inbox-dir": 1, "outbox-dir": 1, "tail": 1,
                        "panel-name": 1, "tab-name": 1, "surface-name": 1, "sender-from": 1, "new-id": 1,
                        "watch": 1, "help": 1])
        case "browser":
            return browserPositionalArity(args)
        default:
            return .unchecked
        }
    }

    /// Positional words of `browser [<ref>] <verb> ...`: the panel handle
    /// when given as a word, the verb, and what the verb's parser reads.
    func browserPositionalArity(_ args: [String]) -> CLIPositionalArity {
        guard let located = browserVerbArgumentIndex(args) else { return .any }
        let panelSpellings = Set(Self.flagSpellings("--panel"))
        let handleWords = args[..<located.index].contains { !$0.hasPrefix("-") }
            && !args[..<located.index].contains(where: panelSpellings.contains) ? 1 : 0
        let verbArgs: [String: Int] = [
            "identify": 0, "back": 0, "forward": 0, "reload": 0, "url": 0, "get-url": 0, "focus-webview": 0,
            "focus_webview": 0, "is-webview-focused": 0, "is_webview_focused": 0, "snapshot": 0, "screenshot": 0,
            "input_mouse": 0, "input_keyboard": 0, "input_touch": 0, "dom": 0, "locator": 0,
            "wait": 1, "click": 1, "dblclick": 1, "hover": 1, "focus": 1, "check": 1, "uncheck": 1,
            "scroll-into-view": 1, "scrollintoview": 1, "scrollinto": 1, "press": 1, "key": 1, "keydown": 1,
            "keyup": 1, "scroll": 1, "frame": 1, "console": 1, "errors": 1, "highlight": 1, "keep-live": 1,
            "keep_live": 1, "offline": 1, "screencast": 1,
            "select": 2, "is": 2, "download": 2, "state": 2, "viewport": 2, "geolocation": 2, "geo": 2,
            "trace": 2, "network": 2,
            "get": 3, "find": 3, "cookies": 3, "storage": 4,
        ]
        guard let count = verbArgs[located.verb] else { return .any }
        return .atMost(handleWords + 1 + count)
    }

    /// Close verbs never fall back to the caller or the focused target: every
    /// subprocess of an agent inherits `C11_PANEL_ID`, so a malformed close
    /// from a helper would close the agent itself. `--panel self` /
    /// `--workspace self` name the caller explicitly.
    func requireExplicitCloseTarget(command: String, args: [String]) throws {
        func has(_ name: String) -> Bool {
            let spellings = Set(Self.flagSpellings(name))
            let options = args.prefix(while: { $0 != "--" })
            return options.indices.contains { spellings.contains(options[$0]) && $0 + 1 < options.endIndex }
        }
        // The action the handler will run, parsed the way `runPanelAction` /
        // `runWorkspaceAction` parse it (the last `--action` wins, else the
        // first remaining word) and normalized the way the server does.
        func action() -> String? {
            let options = command == "panel-action"
                ? ["--workspace", "--panel", "--panel", "--action", "--title", "--url"]
                : ["--workspace", "--action", "--title"]
            var remaining = args
            var actionOption: String?
            for name in options {
                let (value, rest) = parseOption(remaining, name: name)
                if name == "--action" { actionOption = value }
                remaining = rest
            }
            return actionOption ?? remaining.first
        }
        let closeAction = action().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "-", with: "_").hasPrefix("close")
        } ?? false
        switch command {
        case "close-panel" where !has("--panel"):
            throw CLIError(message: String(localized: "cli.close.panel.requiresTarget", defaultValue: "close-panel requires --panel <ref>. Use --panel self to close the calling panel."))
        case "panel-action" where closeAction && !has("--panel"):
            throw CLIError(message: String(localized: "cli.close.panelAction.requiresTarget", defaultValue: "panel-action close actions require --panel <ref>. Use --panel self for the calling panel."))
        case "workspace-action" where closeAction && !has("--workspace"):
            throw CLIError(message: String(localized: "cli.close.workspaceAction.requiresTarget", defaultValue: "workspace-action close actions require --workspace <ref>. Use --workspace self for the calling workspace."))
        default:
            return
        }
    }

    /// `self` for a close target: the caller's own panel or workspace from the
    /// environment, never the focused one.
    func resolvedSelfCloseTarget(_ raw: String?, kind: String) throws -> String? {
        guard raw?.lowercased() == "self" else { return raw }
        let value: String?
        if kind == "panel" {
            value = Self.callerPanelEnv()
        } else {
            let env = ProcessInfo.processInfo.environment
            value = [env["C11_WORKSPACE_ID"], env["CMUX_WORKSPACE_ID"]]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        guard let value else {
            let format = String(localized: "cli.close.self.unavailable", defaultValue: "--%@ self needs a c11 terminal: %@ is not set.")
            throw CLIError(message: String(format: format, kind, kind == "panel" ? "C11_PANEL_ID" : "C11_WORKSPACE_ID"))
        }
        return value
    }

    /// `close-panel: unexpected argument 'panel:268'.` plus, when the word is
    /// a handle the command takes through an option, `Did you mean --panel panel:268?`
    func unexpectedPositionalMessage(command: String, word: String, valueOptions: Set<String>) -> String {
        let message = unexpectedArgumentMessage(command: command, argument: word) + "."
        let lowered = word.lowercased()
        let option: String?
        if ["panel:", "tab:", "surface:"].contains(where: lowered.hasPrefix) || UUID(uuidString: word) != nil {
            option = "--panel"
        } else if lowered.hasPrefix("workspace:") {
            option = "--workspace"
        } else if lowered.hasPrefix("window:") {
            option = "--window"
        } else if lowered.hasPrefix("area:") || lowered.hasPrefix("pane:") {
            option = "--area"
        } else {
            option = nil
        }
        guard let option, valueOptions.contains(option) else { return message }
        let format = String(localized: "cli.command.unexpectedArgument.optionHint", defaultValue: "Did you mean %@ %@?")
        return message + " " + String(format: format, option, word)
    }

    /// Rewrites `--panel=<ref>` (any spelling), `--area=`, `--workspace=` and
    /// `--window=` into separated form while argv starts with target options.
    /// It stops at the first word, `--`, or any other option, so a value of
    /// another option is never read as a target.
    func splittingLeadingTargetOptions(_ args: [String]) -> [String] {
        let targets = Set(["--panel", "--area", "--workspace", "--window"].flatMap(Self.flagSpellings))
        var result: [String] = []
        var index = 0
        while index < args.count {
            let argument = args[index]
            guard argument.hasPrefix("-"), argument != "--" else { break }
            if targets.contains(argument), index + 1 < args.count {
                result.append(contentsOf: args[index...(index + 1)])
                index += 2
                continue
            }
            guard let equals = argument.firstIndex(of: "="), targets.contains(String(argument[..<equals])) else { break }
            result.append(String(argument[..<equals]))
            result.append(String(argument[argument.index(after: equals)...]))
            index += 1
        }
        return result + args[index...]
    }

    func unknownFlagMessage(command: String, flag: String) -> String {
        let format = String(localized: "cli.command.unknownFlag", defaultValue: "%@: unknown flag '%@'")
        return String(format: format, command, flag)
    }

    func requiresValueMessage(command: String, flag: String) -> String {
        let format = String(localized: "cli.command.flagRequiresValue", defaultValue: "%@: %@ requires a value")
        return String(format: format, command, flag)
    }

    func unexpectedArgumentMessage(command: String, argument: String) -> String {
        let format = String(localized: "cli.command.unexpectedArgument", defaultValue: "%@: unexpected argument '%@'")
        return String(format: format, command, argument)
    }

    func commandFlagPreflightSpec(command: String, args: [String]) -> CLIFlagPreflightSpec? {
        switch command {
        case "browser":
            return browserFlagPreflightSpec(args)
        case "open-browser":
            return browserFlagPreflightSpec(["open"] + args)
        case "navigate":
            return browserFlagPreflightSpec(["navigate"] + args)
        case "browser-back":
            return browserFlagPreflightSpec(["back"] + args)
        case "browser-forward":
            return browserFlagPreflightSpec(["forward"] + args)
        case "browser-reload":
            return browserFlagPreflightSpec(["reload"] + args)
        case "get-url":
            return browserFlagPreflightSpec(["get-url"] + args)
        case "focus-webview":
            return browserFlagPreflightSpec(["focus-webview"] + args)
        case "is-webview-focused":
            return browserFlagPreflightSpec(["is-webview-focused"] + args)
        case "feed":
            return feedFlagPreflightSpec(args)
        case "workspace":
            if args.first?.lowercased() == "recents" {
                let recentsArgs = Array(args.dropFirst())
                return workspaceRecentsFlagPreflightSpec(recentsArgs)
            }
            return workspaceFlagPreflightSpec(args)
        case "workspace-apply":
            return CLIFlagPreflightSpec(valueOptions: ["--file"])
        case "themes":
            return themesFlagPreflightSpec(args, allowInherit: false)
        case "ui":
            let themeArgs = args.first?.lowercased() == "themes" ? Array(args.dropFirst()) : []
            return themesFlagPreflightSpec(themeArgs, allowInherit: true)
        case "workspace-color":
            return colorFlagPreflightSpec(args, panel: false)
        case "panel-color":
            return colorFlagPreflightSpec(args, panel: true)
        case "history":
            return historyFlagPreflightSpec(args)
        case "usage", "report":
            return activityAnalysisFlagPreflightSpec()
        case "journal":
            return journalFlagPreflightSpec(args)
        case "agent-event":
            return CLIFlagPreflightSpec(flags: ["--stdin"])
        case "brand", "list-workspaces", "capabilities":
            return CLIFlagPreflightSpec(flags: ["--json"])
        case "app":
            if firstCommandWord(args, valueOptions: []) == "restart" {
                return CLIFlagPreflightSpec(flags: ["--no-resume", "--json"])
            }
            return CLIFlagPreflightSpec()
        case "skill":
            return skillFlagPreflightSpec(args)
        case "agent-hook", "codex-hook":
            return CLIFlagPreflightSpec(valueOptions: ["--native-event"])
        case "new-split", "new-area", "new-panel", "launch-agent", "break-pane", "join-pane":
            return createCommandFlagPreflightSpec(command, args: args)
        case "claude-teams":
            // This command forwards its remaining argv verbatim to Claude Code.
            // Those flags belong to the child CLI, not c11's parser.
            return nil
        case "terminal-theme":
            return terminalThemeFlagPreflightSpec(args)
        case "model-costs":
            return modelCostsFlagPreflightSpec(args)
        case "workspace-group":
            return workspaceGroupFlagPreflightSpec(args)
        case "markdown":
            return markdownFlagPreflightSpec(args)
        case "config":
            return configFlagPreflightSpec(args)
        case "default-agent":
            return defaultAgentFlagPreflightSpec(args)
        case "conversation":
            return conversationFlagPreflightSpec(args)
        case "state":
            return stateFlagPreflightSpec(args)
        case "events":
            return eventsFlagPreflightSpec(args)
        case "messages":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace"])
        case "mailbox":
            return mailboxFlagPreflightSpec(args)
        case "set-status", "clear-status", "list-status", "set-progress", "clear-progress", "log", "clear-log", "list-log", "sidebar-state":
            return sidebarMetadataFlagPreflightSpec(command, args: args)
        case "set-metadata":
            return CLIFlagPreflightSpec(
                valueOptions: ["--json", "--json-input", "--body", "--key", "--value", "--type", "--mode", "--source", "--panel", "--area", "--workspace"]
            )
        case "get-metadata":
            return CLIFlagPreflightSpec(
                flags: ["--sources", "--include-sources"],
                valueOptions: ["--key", "--panel", "--area", "--workspace"]
            )
        case "get-workspace-metadata":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace", "--key"])
        case "set-workspace-description", "set-workspace-icon":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace", "--value"])
        case "clear-notifications":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace"])
        case "raise-flag", "lower-flag", "delegate", "undelegate", "suppress", "unsuppress":
            return CLIFlagPreflightSpec(
                flags: ["--json"],
                valueOptions: ["--panel", "--workspace", "--window", "--by"]
            )
        default:
            return declaredCommandFlagPreflightSpec(command, args: args)
        }
    }

    func sidebarMetadataFlagPreflightSpec(_ command: String, args: [String]) -> CLIFlagPreflightSpec {
        var flags: Set<String> = []
        var values: Set<String> = ["--workspace", "--panel"]
        switch command {
        case "set-status":
            values.formUnion(["--icon", "--color", "--url", "--link", "--priority", "--format", "--pid"])
        case "set-progress":
            values.insert("--label")
        case "log":
            values.formUnion(["--level", "--source"])
        case "list-log":
            values.insert("--limit")
        case "sidebar-state":
            flags.insert("--json")
        default:
            break
        }
        for flag in Array(values) {
            values.formUnion(Self.flagSpellings(flag))
        }
        flags.formUnion(values)
        return CLIFlagPreflightSpec(
            flags: flags,
            valueOptions: values,
            literalTailStart: command == "set-status" ? setStatusLiteralTailStart(args, valueOptions: values) : nil,
            honorsEndOfOptions: command == "log"
        )
    }

    func workspaceFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        switch args.first?.lowercased() {
        case "apply":
            return CLIFlagPreflightSpec(valueOptions: ["--file"])
        case "new":
            return CLIFlagPreflightSpec(
                flags: ["--agent"],
                valueOptions: ["--blueprint", "--dir", "--layout", "--name"]
            )
        case "export-blueprint":
            return CLIFlagPreflightSpec(
                flags: ["--force"],
                valueOptions: ["--name", "--workspace", "--description", "--format", "--out"]
            )
        default:
            return CLIFlagPreflightSpec()
        }
    }

    func createCommandFlagPreflightSpec(_ command: String, args: [String]) -> CLIFlagPreflightSpec {
        switch command {
        case "new-split":
            return CLIFlagPreflightSpec(
                flags: ["--allow-undersized", "--force", "--json"],
                valueOptions: ["--workspace", "--panel", "--title", "--cwd", "--command"]
            )
        case "new-area":
            return CLIFlagPreflightSpec(
                flags: ["--allow-undersized", "--force", "--json"],
                valueOptions: ["--type", "--command", "--direction", "--workspace", "--url", "--file", "--title", "--cwd", "--profile"]
            )
        case "new-panel":
            return CLIFlagPreflightSpec(
                flags: ["--no-focus", "--json"],
                valueOptions: ["--type", "--command", "--area", "--workspace", "--url", "--file", "--cwd", "--title", "--profile"]
            )
        case "launch-agent":
            return CLIFlagPreflightSpec(
                flags: ["--new-workspace", "--delegated", "--suppressed", "--no-focus", "--json"],
                valueOptions: ["--type", "--model", "--effort", "--system-prompt-mode", "--system-prompt", "--system-prompt-file", "--task", "--area", "--workspace", "--cwd", "--prompt", "--prompt-file", "--title", "--flag", "--by", "--env"]
            )
        case "break-pane":
            return CLIFlagPreflightSpec(
                flags: ["--no-focus"],
                valueOptions: ["--workspace", "--pane", "--surface"]
            )
        case "join-pane":
            return CLIFlagPreflightSpec(
                flags: ["--no-focus"],
                valueOptions: ["--target-pane", "--workspace", "--pane", "--surface"]
            )
        default:
            return CLIFlagPreflightSpec()
        }
    }

    /// Accepted command options are declared here beside the preflight parser.
    /// Keep these lists aligned with the command's argv parser; help text is a
    /// user-facing description and is never parsed as an option schema.
    func declaredCommandFlagPreflightSpec(_ command: String, args: [String]) -> CLIFlagPreflightSpec {
        let panelAndWorkspace: Set<String> = ["--workspace", "--panel"]
        switch command {
        case "agents":
            return CLIFlagPreflightSpec(valueOptions: ["--bundle-id"])
        case "feedback":
            return CLIFlagPreflightSpec(valueOptions: ["--email", "--body", "--image"])
        case "shortcuts":
            return CLIFlagPreflightSpec(flags: ["--customized", "--all"])
        case "rpc", "guide", "sidebar-state":
            return CLIFlagPreflightSpec()
        case "identify":
            return CLIFlagPreflightSpec(flags: ["--no-caller", "--json"], valueOptions: ["--workspace", "--panel"])
        case "remote-daemon-status":
            return CLIFlagPreflightSpec(valueOptions: ["--os", "--arch"])
        case "focus-window", "close-window", "resize-window":
            return CLIFlagPreflightSpec(valueOptions: ["--window"])
        case "move-workspace-to-window":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace", "--window"])
        case "move-panel":
            return CLIFlagPreflightSpec(
                valueOptions: ["--panel", "--area", "--workspace", "--window", "--before", "--before-panel", "--after", "--after-panel", "--index", "--focus"]
            )
        case "reorder-panel":
            return CLIFlagPreflightSpec(
                valueOptions: ["--panel", "--workspace", "--before", "--before-panel", "--after", "--after-panel", "--index"]
            )
        case "reorder-workspace":
            return CLIFlagPreflightSpec(
                valueOptions: ["--workspace", "--window", "--before", "--before-workspace", "--after", "--after-workspace", "--index"]
            )
        case "reorder-workspaces":
            return CLIFlagPreflightSpec(flags: ["--dry-run"], valueOptions: ["--order", "--window"])
        case "workspace-action":
            return CLIFlagPreflightSpec(valueOptions: ["--action", "--workspace", "--title"])
        case "panel-action":
            return CLIFlagPreflightSpec(valueOptions: ["--action", "--panel", "--workspace", "--title", "--url"])
        case "rename-panel":
            return CLIFlagPreflightSpec(
                valueOptions: panelAndWorkspace.union(["--title"]),
                honorsEndOfOptions: true
            )
        case "set-title":
            return CLIFlagPreflightSpec(
                valueOptions: panelAndWorkspace.union(["--from-file", "--source"]),
                honorsEndOfOptions: true
            )
        case "set-description":
            return CLIFlagPreflightSpec(
                flags: ["--auto-expand=true", "--auto-expand=false", "--json"],
                valueOptions: panelAndWorkspace.union(["--from-file", "--source"]),
                honorsEndOfOptions: true
            )
        case "set-panel-icon", "set-panel-color":
            return CLIFlagPreflightSpec(flags: ["--clear", "--json"], valueOptions: panelAndWorkspace.union(["--source"]), honorsEndOfOptions: true)
        case "get-titlebar-state":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: panelAndWorkspace)
        case "ssh":
            // Words after the destination are the remote command.
            let values: Set<String> = ["--name", "--port", "--identity", "--ssh-option"]
            return CLIFlagPreflightSpec(
                valueOptions: values,
                literalTailStart: firstPositionalArgumentIndex(args, valueOptions: values).map { $0 + 1 },
                honorsEndOfOptions: true
            )
        case "ssh-session-end":
            return CLIFlagPreflightSpec(valueOptions: ["--relay-port", "--workspace", "--panel"])
        case "snapshot":
            return CLIFlagPreflightSpec(flags: ["--all"], valueOptions: ["--workspace", "--out"])
        case "restore":
            return CLIFlagPreflightSpec(flags: ["--in-place", "--replace"])
        case "list-snapshots":
            return CLIFlagPreflightSpec(flags: ["--sets", "--all"])
        case "new-workspace":
            return CLIFlagPreflightSpec(valueOptions: ["--cwd", "--root", "--command", "--title", "--layout"])
        case "list-areas":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace"])
        case "list-area-panels":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace", "--area"])
        case "tree":
            return CLIFlagPreflightSpec(
                flags: ["--all", "--window", "--layout", "--no-layout", "--report", "--markdown"],
                valueOptions: ["--workspace", "--canvas-cols", "--out"]
            )
        case "family":
            return CLIFlagPreflightSpec(valueOptions: ["--panel"])
        case "focus-area":
            return CLIFlagPreflightSpec(valueOptions: ["--area", "--workspace"])
        case "close-panel":
            return CLIFlagPreflightSpec(valueOptions: panelAndWorkspace)
        case "area-confirm":
            return CLIFlagPreflightSpec(
                flags: ["--destructive"],
                valueOptions: ["--panel", "--workspace", "--title", "--message", "--timeout", "--confirm-label", "--cancel-label"]
            )
        case "drag-panel-to-split":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: panelAndWorkspace)
        case "refresh-panels":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--workspace"])
        case "panel-health", "list-panels":
            return CLIFlagPreflightSpec(flags: command == "list-panels" ? ["--json"] : [], valueOptions: ["--workspace"])
        case "focus-panel":
            return CLIFlagPreflightSpec(valueOptions: panelAndWorkspace)
        case "close-workspace", "select-workspace":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace"])
        case "health":
            return CLIFlagPreflightSpec(flags: ["--since-boot"], valueOptions: ["--since", "--rail"])
        case "trigger-flash":
            return CLIFlagPreflightSpec(flags: ["--persistent"], valueOptions: panelAndWorkspace.union(["--color"]))
        case "cancel-flash":
            return CLIFlagPreflightSpec(valueOptions: panelAndWorkspace)
        case "rename-workspace", "rename-window":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace"], honorsEndOfOptions: true)
        case "set-workspace-root":
            return CLIFlagPreflightSpec(flags: ["--clear"], valueOptions: ["--workspace"], honorsEndOfOptions: true)
        case "get-workspace-root":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--workspace"])
        case "capture-pane":
            return CLIFlagPreflightSpec(flags: ["--scrollback"], valueOptions: ["--workspace", "--panel", "--lines"])
        case "resize-pane":
            return CLIFlagPreflightSpec(flags: ["-L", "-R", "-U", "-D"], valueOptions: ["--pane", "--workspace", "--amount"])
        case "pipe-pane":
            // The parser takes the words after its options as the shell command.
            let values: Set<String> = ["--command", "--workspace", "--panel"]
            return CLIFlagPreflightSpec(
                valueOptions: values,
                literalTailStart: firstPositionalArgumentIndex(args, valueOptions: values),
                honorsEndOfOptions: true
            )
        case "wait-for":
            return CLIFlagPreflightSpec(flags: ["-S", "--signal"], valueOptions: ["--timeout"])
        case "swap-pane":
            return CLIFlagPreflightSpec(valueOptions: ["--pane", "--target-pane", "--workspace"])
        case "last-pane":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace"])
        case "find-window":
            return CLIFlagPreflightSpec(flags: ["--content", "--select"])
        case "clear-history":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace", "--panel"])
        case "set-hook":
            // `set-hook <event> <command...>`: every word after the event is the command.
            let eventIndex = firstPositionalArgumentIndex(args, valueOptions: [])
            return CLIFlagPreflightSpec(
                flags: ["--list", "--unset"],
                literalTailStart: eventIndex.map { $0 + 1 }
            )
        case "set-buffer":
            // Every word other than `--name <name>` is buffer text.
            let values: Set<String> = ["--name"]
            return CLIFlagPreflightSpec(
                valueOptions: values,
                literalTailStart: firstPositionalArgumentIndex(args, valueOptions: values),
                honorsEndOfOptions: true
            )
        case "paste-buffer":
            return CLIFlagPreflightSpec(valueOptions: ["--name", "--workspace", "--panel"])
        case "respawn-pane":
            // The parser takes the words after its options as the command line.
            let values: Set<String> = ["--workspace", "--panel", "--command"]
            return CLIFlagPreflightSpec(
                valueOptions: values,
                literalTailStart: firstPositionalArgumentIndex(args, valueOptions: values),
                honorsEndOfOptions: true
            )
        case "display-message":
            return CLIFlagPreflightSpec(flags: ["-p", "--print"])
        case "read-selection":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: panelAndWorkspace)
        case "markdown-content":
            return CLIFlagPreflightSpec(valueOptions: ["--panel"])
        case "input-state":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: panelAndWorkspace)
        case "read-screen":
            return CLIFlagPreflightSpec(flags: ["--scrollback"], valueOptions: ["--workspace", "--panel", "--lines"])
        case "send", "send-panel", "paste":
            return CLIFlagPreflightSpec(
                flags: ["--raw", "--no-submit", "--allow-unguarded"],
                valueOptions: panelAndWorkspace,
                honorsEndOfOptions: true
            )
        case "send-key", "send-key-panel":
            return CLIFlagPreflightSpec(valueOptions: panelAndWorkspace, honorsEndOfOptions: true)
        case "notify":
            return CLIFlagPreflightSpec(valueOptions: ["--title", "--subtitle", "--body", "--workspace", "--panel"])
        case "list-notifications":
            return CLIFlagPreflightSpec()
        case "set-agent":
            return CLIFlagPreflightSpec(valueOptions: ["--type", "--model", "--task", "--role", "--panel", "--workspace"])
        case "set-workspace-metadata":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace", "--key", "--value", "--json"])
        case "clear-metadata":
            return CLIFlagPreflightSpec(valueOptions: ["--key", "--source", "--panel", "--area", "--workspace"])
        case "clear-workspace-metadata":
            return CLIFlagPreflightSpec(valueOptions: ["--key", "--workspace"])
        case "claude-hook":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace", "--panel"])
        case "set-app-focus":
            return CLIFlagPreflightSpec()
        case "simulate-app-active", "ping", "list-windows", "current-window", "new-window", "current-workspace", "doctor", "debug-terminals", "popup", "bind-key", "unbind-key", "copy-mode", "list-buffers":
            return CLIFlagPreflightSpec()
        default:
            return CLIFlagPreflightSpec()
        }
    }

    func setStatusLiteralTailStart(_ args: [String], valueOptions: Set<String>) -> Int? {
        guard let separator = args.firstIndex(of: "--") else { return nil }
        var positionalCount = 0
        var index = 0
        while index < separator {
            let argument = args[index]
            if valueOptions.contains(argument), index + 1 < separator {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                positionalCount += 1
                index += 1
            }
        }
        // The separator starts the status text only when the required key/value
        // pair has not already been supplied. Extra arguments after a complete
        // pair remain subject to strict flag validation.
        return positionalCount < 2 && separator + 1 < args.endIndex ? separator + 1 : nil
    }

    /// The first word that is neither an option nor an option's value; a
    /// word after `--` counts. Options themselves are checked by preflight.
    func firstPositionalArgumentIndex(_ args: [String], valueOptions: Set<String>) -> Int? {
        let values = Set(valueOptions.flatMap(Self.flagSpellings))
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return index + 1 < args.count ? index + 1 : nil }
            let name = argument.firstIndex(of: "=").map { String(argument[..<$0]) } ?? argument
            if values.contains(argument) {
                index += 2
            } else if values.contains(name) || (argument.hasPrefix("-") && argument != "-") {
                index += 1
            } else {
                return index
            }
        }
        return nil
    }

    func themesFlagPreflightSpec(_ args: [String], allowInherit: Bool) -> CLIFlagPreflightSpec {
        switch args.first?.lowercased() {
        case "get": return CLIFlagPreflightSpec(valueOptions: ["--slot"])
        case "set": return CLIFlagPreflightSpec(valueOptions: ["--slot"])
        case "dump": return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--color-scheme"])
        case "inherit" where allowInherit:
            return CLIFlagPreflightSpec(valueOptions: ["--as"])
        default: return CLIFlagPreflightSpec()
        }
    }

    func colorFlagPreflightSpec(_ args: [String], panel: Bool) -> CLIFlagPreflightSpec {
        let workspace: Set<String> = ["--workspace"]
        let flags: Set<String> = []
        let values = panel ? workspace.union(["--panel"]) : workspace
        switch args.first?.lowercased() {
        case "set", "get", "clear": return CLIFlagPreflightSpec(flags: flags, valueOptions: values)
        default: return CLIFlagPreflightSpec()
        }
    }

    func historyFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        switch firstCommandWord(args, valueOptions: ["--limit"]) {
        case "back", "forward": return CLIFlagPreflightSpec(flags: ["--json"])
        default: return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--limit"])
        }
    }

    func firstCommandWord(_ args: [String], valueOptions: Set<String>) -> String? {
        var index = 0
        while index < args.count {
            let argument = args[index]
            let equalsIndex = argument.firstIndex(of: "=")
            let name = equalsIndex.map { String(argument[..<$0]) } ?? argument
            if valueOptions.contains(name) {
                index += equalsIndex == nil ? 2 : 1
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return argument.lowercased()
        }
        return nil
    }

    func workspaceRecentsFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        switch args.first?.lowercased() {
        case "list": return CLIFlagPreflightSpec(flags: ["--json", "--pinned"])
        case "pin": return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--at"])
        case "unpin", "remove": return CLIFlagPreflightSpec(flags: ["--json"])
        default: return CLIFlagPreflightSpec()
        }
    }

    func feedFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        let verb = firstCommandWord(
            args,
            valueOptions: Set(Self.flagSpellings("--panel")).union(["--workspace", "--scope", "--text", "--by"])
        )
        switch verb {
        case "list", "watch":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--scope"])
        case "open":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--workspace", "--panel"])
        case "answer":
            return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--workspace", "--panel", "--text", "--by"])
        default:
            return CLIFlagPreflightSpec()
        }
    }

    func activityAnalysisFlagPreflightSpec() -> CLIFlagPreflightSpec {
        CLIFlagPreflightSpec(
            flags: ["--json", "--utc", "--all-instances"],
            valueOptions: ["--since", "--until", "--by", "--instance", "--format", "--state-root", "--claude-root", "--codex-root", "--journal"]
        )
    }

    func journalFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        var flags: Set<String> = ["--json"]
        var values: Set<String> = ["--agent", "--model", "--workspace", "--from", "--to", "--stall-ms", "--bundle-id"]
        switch args.first?.lowercased() {
        case "export": values.insert("--output")
        case "clear": flags.insert("--yes")
        default: break
        }
        return CLIFlagPreflightSpec(flags: flags, valueOptions: values)
    }

    func skillFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        switch args.first?.lowercased() {
        case "path": return CLIFlagPreflightSpec(flags: ["--json"])
        case "status", "list": return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--tool", "--home"])
        case "install": return CLIFlagPreflightSpec(flags: ["--json", "--force", "--dry-run"], valueOptions: ["--tool", "--home"])
        case "remove", "uninstall": return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--tool", "--home"])
        default: return CLIFlagPreflightSpec()
        }
    }

    func terminalThemeFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        guard args.first?.lowercased() == "set" else { return CLIFlagPreflightSpec() }
        return CLIFlagPreflightSpec(valueOptions: ["--light", "--dark"])
    }

    func modelCostsFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        switch args.first?.lowercased() {
        case "list", "get": return CLIFlagPreflightSpec(flags: ["--json"])
        case "set":
            return CLIFlagPreflightSpec(valueOptions: ["--in", "--out", "--cache-read", "--cache-write", "--cache-write-1h", "--source", "--notes"])
        case "import": return CLIFlagPreflightSpec(flags: ["--replace"])
        default: return CLIFlagPreflightSpec()
        }
    }

    func workspaceGroupFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec {
        var values: Set<String> = ["--window"]
        var flags: Set<String> = ["--json"]
        switch args.first?.lowercased() {
        case "list": break
        case "create": values.insert("--name")
        case "rename": values.formUnion(["--group", "--name"])
        case "delete", "ungroup", "collapse", "expand", "pin", "unpin", "focus": values.insert("--group")
        case "add", "remove": values.formUnion(["--group", "--workspaces"])
        case "move": values.formUnion(["--group", "--workspace", "--to-group", "--before", "--after", "--index"])
        case "set-color": values.formUnion(["--group", "--color"]); flags.insert("--clear")
        case "set-icon": values.formUnion(["--group", "--icon"]); flags.insert("--clear")
        default: break
        }
        return CLIFlagPreflightSpec(flags: flags, valueOptions: values)
    }

    func markdownFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec? {
        var commandArgs = args
        for name in ["--workspace", "--window", "--panel", "--area"] {
            commandArgs = parseOption(commandArgs, name: name).1
        }
        let openTargetValues: Set<String> = ["--workspace", "--window", "--panel", "--area"]
        let panelTargetValue: Set<String> = ["--panel"]
        switch commandArgs.first?.lowercased() {
        case "scroll": return CLIFlagPreflightSpec(valueOptions: panelTargetValue.union(["--heading"]))
        case "visible": return CLIFlagPreflightSpec(flags: ["--json", "--watch"], valueOptions: panelTargetValue)
        case "theme", "typeface": return CLIFlagPreflightSpec(flags: ["--list"], valueOptions: panelTargetValue.union(["--set"]))
        case "font": return CLIFlagPreflightSpec(valueOptions: panelTargetValue.union(["--scale"]))
        case "open-external": return CLIFlagPreflightSpec(valueOptions: panelTargetValue)
        case "history": return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: panelTargetValue)
        case "links": return CLIFlagPreflightSpec(flags: ["--broken", "--json"], valueOptions: panelTargetValue)
        case "backlinks": return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: panelTargetValue)
        case "open": return CLIFlagPreflightSpec(valueOptions: openTargetValues)
        default:
            if commandArgs.first.map({ !$0.hasPrefix("-") }) ?? false {
                return CLIFlagPreflightSpec(valueOptions: openTargetValues)
            }
            return CLIFlagPreflightSpec(valueOptions: openTargetValues)
        }
    }

    struct TmuxFlagSpec {
        var valueFlags: Set<String> = []
        var booleanFlags: Set<String> = []
        var valueLongFlags: Set<String> = []
        var booleanLongFlags: Set<String> = []
    }

    func validateClaudeTeamsTmuxFlags(_ commandArgs: [String]) throws {
        let globalValues: Set<String> = ["-L", "-S", "-f"]
        var index = 0
        while index < commandArgs.count {
            let argument = commandArgs[index]
            guard argument.hasPrefix("-"), argument != "-" else { break }
            if argument == "--" { break }
            guard let flag = globalValues.first(where: { argument == $0 || argument.hasPrefix($0) }) else {
                throw CLIError(message: "__tmux-compat: unknown flag '\(argument)'")
            }
            if argument == flag {
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "__tmux-compat: \(flag) requires a value")
                }
                index += 2
            } else {
                index += 1
            }
        }

        let (command, rawArgs) = try splitTmuxCommand(commandArgs)
        guard let spec = claudeTeamsTmuxFlagSpec(command) else { return }

        // tmux stops reading options at the first word that is not one: the
        // rest is the command or keys (`send-keys -t %1 git log --oneline`).
        var cursor = 0
        while cursor < rawArgs.count {
            let argument = rawArgs[cursor]
            if argument == "--" { return }
            guard argument.hasPrefix("-"), argument != "-" else { return }
            if argument.hasPrefix("--") {
                let equals = argument.firstIndex(of: "=")
                let name = equals.map { String(argument[..<$0]) } ?? argument
                if spec.booleanLongFlags.contains(name) {
                    guard equals == nil else { throw CLIError(message: "__tmux-compat: \(name) does not take a value") }
                    cursor += 1
                    continue
                }
                if spec.valueLongFlags.contains(name) {
                    if equals != nil { cursor += 1 }
                    else if cursor + 1 < rawArgs.count { cursor += 2 }
                    else { throw CLIError(message: "__tmux-compat: \(name) requires a value") }
                    continue
                }
                throw CLIError(message: "__tmux-compat: unknown flag '\(name)'")
            }
            let cluster = Array(argument.dropFirst())
            var position = 0
            while position < cluster.count {
                let flag = "-" + String(cluster[position])
                if spec.booleanFlags.contains(flag) {
                    position += 1
                    continue
                }
                if spec.valueFlags.contains(flag) {
                    if position + 1 < cluster.count {
                        break
                    }
                    guard cursor + 1 < rawArgs.count else {
                        throw CLIError(message: "__tmux-compat: \(flag) requires a value")
                    }
                    cursor += 1
                    break
                }
                throw CLIError(message: "__tmux-compat: unknown flag '\(flag)'")
            }
            cursor += 1
        }
    }

    func claudeTeamsTmuxFlagSpec(_ command: String) -> TmuxFlagSpec? {
        switch command {
        case "new-session", "new": return TmuxFlagSpec(valueFlags: ["-c", "-F", "-n", "-s"], booleanFlags: ["-A", "-d", "-P"])
        case "new-window", "neww": return TmuxFlagSpec(valueFlags: ["-c", "-F", "-n", "-t"], booleanFlags: ["-d", "-P"])
        case "split-window", "splitw": return TmuxFlagSpec(valueFlags: ["-c", "-F", "-l", "-t"], booleanFlags: ["-P", "-b", "-d", "-h", "-v"])
        case "select-window", "selectw", "kill-window", "killw", "kill-pane", "killp", "last-pane", "has-session", "has":
            return TmuxFlagSpec(valueFlags: ["-t"])
        case "select-pane", "selectp": return TmuxFlagSpec(valueFlags: ["-P", "-T", "-t"])
        case "send-keys", "send": return TmuxFlagSpec(valueFlags: ["-t"], booleanFlags: ["-l"])
        case "capture-pane", "capturep": return TmuxFlagSpec(valueFlags: ["-E", "-S", "-t"], booleanFlags: ["-J", "-N", "-p"])
        case "display-message", "display", "displayp": return TmuxFlagSpec(valueFlags: ["-F", "-t"], booleanFlags: ["-p"], booleanLongFlags: ["--print"])
        case "list-windows", "lsw", "list-panes", "lsp": return TmuxFlagSpec(valueFlags: ["-F", "-t"])
        case "rename-window", "renamew": return TmuxFlagSpec(valueFlags: ["-t"])
        case "resize-pane", "resizep": return TmuxFlagSpec(valueFlags: ["-t", "-x", "-y"], booleanFlags: ["-D", "-L", "-R", "-U"])
        case "wait-for": return TmuxFlagSpec(booleanFlags: ["-S"], valueLongFlags: ["--timeout"], booleanLongFlags: ["--signal"])
        case "show-buffer", "showb", "save-buffer", "saveb": return TmuxFlagSpec(valueFlags: ["-b"])
        case "set-hook": return TmuxFlagSpec(valueLongFlags: ["--unset"], booleanLongFlags: ["--list"])
        case "set-buffer": return TmuxFlagSpec(valueLongFlags: ["--name"])
        case "select-layout", "set-option", "set", "set-window-option", "setw", "source-file", "refresh-client", "attach-session", "detach-client":
            // These are deliberate successful no-ops in the tmux compatibility layer.
            return nil
        case "last-window", "next-window", "previous-window", "list-buffers", "popup", "bind-key", "unbind-key", "copy-mode":
            return TmuxFlagSpec()
        default: return nil
        }
    }

    func configFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec? {
        let json: Set<String> = ["--json"]
        switch args.first?.lowercased() {
        case "list", "recent": return CLIFlagPreflightSpec(flags: json)
        case "stats": return CLIFlagPreflightSpec(flags: json, valueOptions: ["--window", "--by"])
        case "save", "edit":
            return CLIFlagPreflightSpec(
                flags: json,
                valueOptions: ["--harness", "--model", "--effort", "--system-prompt", "--system-prompt-file", "--system-prompt-mode", "--command", "--initial-prompt", "--env"]
            )
        case "rm": return CLIFlagPreflightSpec(flags: json)
        case "reorder": return CLIFlagPreflightSpec(flags: json, valueOptions: ["--to"])
        case "default": return CLIFlagPreflightSpec(flags: json.union(["--pin-current"]))
        case "launch":
            return CLIFlagPreflightSpec(
                flags: json.union(["--new-workspace"]),
                valueOptions: ["--prompt", "--prompt-file", "--area", "--pane", "--workspace", "--cwd"]
            )
        default: return CLIFlagPreflightSpec()
        }
    }

    func defaultAgentFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec? {
        guard args.first?.lowercased() == "launch" else { return CLIFlagPreflightSpec() }
        return CLIFlagPreflightSpec(
            flags: ["--json"],
            valueOptions: ["--agent", "--in-panel", "--area", "--workspace", "--cwd", "--prompt", "--prompt-file"]
        )
    }

    func conversationFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec? {
        switch args.first?.lowercased() {
        case "capture-runtime": return CLIFlagPreflightSpec()
        case "claim": return CLIFlagPreflightSpec(valueOptions: ["--panel", "--kind", "--cwd", "--id", "--expected-resume-id", "--ttl-ms"])
        case "push": return CLIFlagPreflightSpec(valueOptions: ["--panel", "--kind", "--id", "--source", "--state", "--cwd", "--reason", "--payload"])
        case "tombstone": return CLIFlagPreflightSpec(valueOptions: ["--panel", "--kind", "--id", "--reason"])
        case "list", "get": return CLIFlagPreflightSpec(flags: ["--json"], valueOptions: ["--panel"])
        case "clear": return CLIFlagPreflightSpec(valueOptions: ["--panel"])
        case "resume": return CLIFlagPreflightSpec(flags: ["--all-skipped", "--dry-run", "--json"], valueOptions: ["--panel"])
        default: return CLIFlagPreflightSpec()
        }
    }

    func stateFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec? {
        switch args.first?.lowercased() {
        case "save": return CLIFlagPreflightSpec(flags: ["--scrollback"], valueOptions: ["--out"])
        case "verify": return CLIFlagPreflightSpec(valueOptions: ["--mode"])
        default: return CLIFlagPreflightSpec()
        }
    }

    func eventsFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec? {
        guard args.first?.lowercased() == "tail" else { return CLIFlagPreflightSpec() }
        return CLIFlagPreflightSpec(flags: ["--follow", "-f"], valueOptions: ["--filter", "--since", "--instance"])
    }

    func mailboxFlagPreflightSpec(_ args: [String]) -> CLIFlagPreflightSpec? {
        switch args.first?.lowercased() {
        case "send":
            return CLIFlagPreflightSpec(
                flags: ["--urgent", "--json", "--to-parent"],
                valueOptions: MailboxSendArguments.valueFlags,
                honorsEndOfOptions: true
            )
        case "recv":
            return CLIFlagPreflightSpec(
                flags: ["--drain", "--peek", "--ack"],
                valueOptions: MailboxRecvArguments.valueFlags
            )
        case "view":
            return CLIFlagPreflightSpec(valueOptions: ["--workspace"])
        case "inbox-dir":
            return CLIFlagPreflightSpec(valueOptions: ["--panel"])
        default:
            return CLIFlagPreflightSpec()
        }
    }

    func browserFlagPreflightSpec(_ commandArgs: [String]) -> CLIFlagPreflightSpec? {
        guard let located = browserVerbArgumentIndex(commandArgs) else { return nil }
        let verb = located.verb
        let subArgs = parseOption(Array(commandArgs[(located.index + 1)...]), name: "--panel").1
        var flags: Set<String> = ["--json"]
        var values: Set<String> = ["--id-format"]
        values.insert("--panel")
        switch verb {
        case "open", "open-split", "new":
            flags.insert("--allow-insecure-http")
            values.formUnion(["--workspace", "--window", "--profile"])
        case "profiles":
            switch subArgs.first?.lowercased() {
            case "add", "rename":
                flags.insert("--yes")
                values.formUnion(["--profile", "--name"])
            case "clear", "delete":
                flags.insert("--yes")
                values.insert("--profile")
            default: break
            }
        case "goto", "navigate": flags.formUnion(["--snapshot-after", "--allow-insecure-http"])
        case "back", "forward", "reload": flags.insert("--snapshot-after")
        case "snapshot":
            flags.formUnion(["--interactive", "-i", "--cursor", "--compact"])
            values.formUnion(["--max-depth", "--selector"])
        case "eval": values.insert("--script")
        case "wait": values.formUnion(["--selector", "--text", "--url-contains", "--url", "--load-state", "--function", "--timeout-ms", "--timeout"])
        case "click", "dblclick", "hover", "focus", "check", "uncheck", "scroll-into-view", "scrollintoview", "scrollinto":
            flags.insert("--snapshot-after")
            values.insert("--selector")
        case "type", "fill":
            flags.insert("--snapshot-after")
            values.formUnion(["--selector", "--text"])
        case "press", "key", "keydown", "keyup":
            flags.insert("--snapshot-after")
            values.insert("--key")
        case "select":
            flags.insert("--snapshot-after")
            values.formUnion(["--selector", "--value"])
        case "scroll":
            flags.insert("--snapshot-after")
            values.formUnion(["--selector", "--dx", "--dy"])
        case "screenshot": values.insert("--out")
        case "get":
            switch subArgs.first?.lowercased() {
            case "text", "html", "value", "count", "box": values.insert("--selector")
            case "attr": values.formUnion(["--selector", "--attr"])
            case "styles": values.formUnion(["--selector", "--property"])
            default: break
            }
        case "is": values.insert("--selector")
        case "find":
            flags.insert("--exact")
            switch subArgs.first?.lowercased() {
            case "role": values.insert("--name")
            case "first", "last": values.insert("--selector")
            case "nth": values.formUnion(["--index", "--selector"])
            default: break
            }
        case "frame": if subArgs.first?.lowercased() != "main" { values.insert("--selector") }
        case "addinitscript", "addscript": values.insert("--script")
        case "addstyle": values.insert("--css")
        case "download": values.formUnion(["--path", "--timeout-ms", "--timeout"])
        case "cookies":
            flags.formUnion(["--secure", "--all"])
            values.formUnion(["--name", "--value", "--url", "--domain", "--path", "--expires"])
        case "highlight": values.insert("--selector")
        case "network":
            if subArgs.first?.lowercased() == "route" {
                flags.insert("--abort")
                values.insert("--body")
            }
        case "locator": values.formUnion(["--name", "--selector", "--index"])
        case "dom": values.formUnion(["--selector", "--max-depth"])
        default: break
        }
        for flag in Array(flags.union(values)) {
            for spelling in Self.flagSpellings(flag) {
                flags.insert(spelling)
                if values.contains(flag) { values.insert(spelling) }
            }
        }
        return CLIFlagPreflightSpec(
            flags: flags,
            valueOptions: values,
            literalFlagArgumentIndices: verb == "state" ? browserPositionalStatePathIndex(commandArgs).map { Set([$0]) } ?? [] : [],
            literalTailStart: verb == "dialog" && subArgs.first?.lowercased() == "accept" ? located.index + 2 : nil,
            textStart: browserTextStart(verb: verb, verbIndex: located.index, subArgs: subArgs),
            honorsEndOfOptions: verb == "type" || verb == "fill"
        )
    }

    /// Where a text verb starts taking unrecognized words as text. `eval`
    /// with `--script` (either spelling) takes no positional script, so an
    /// unknown flag there stays an error.
    func browserTextStart(verb: String, verbIndex: Int, subArgs: [String]) -> Int? {
        switch verb {
        case "type", "fill", "addinitscript", "addscript", "addstyle":
            return verbIndex + 1
        case "eval":
            let options = subArgs.prefix(while: { $0 != "--" })
            let hasScriptOption = options.contains { $0 == "--script" || $0.hasPrefix("--script=") }
            return hasScriptOption ? nil : verbIndex + 1
        default:
            return nil
        }
    }

    /// The browser verb and its index in argv. Without `--panel`, a leading
    /// word that is not a browser verb is the panel handle, as in
    /// `runBrowserCommand`; a leading verb stays the verb, so its own options
    /// are checked even when the panel handle is missing.
    func browserVerbArgumentIndex(_ commandArgs: [String]) -> (index: Int, verb: String)? {
        let panelSpellings = Set(Self.flagSpellings("--panel"))
        let separator = commandArgs.firstIndex(of: "--") ?? commandArgs.endIndex
        let hasPanelOption = commandArgs[..<separator].indices.contains {
            panelSpellings.contains(commandArgs[$0]) && $0 + 1 < commandArgs.count
        }
        var surfaceTaken = hasPanelOption
        var index = 0
        while index < commandArgs.count {
            let argument = commandArgs[index]
            if index < separator, panelSpellings.contains(argument), index + 1 < commandArgs.count {
                index += 2
                continue
            }
            if !surfaceTaken, !argument.hasPrefix("-"), !Self.browserVerbs.contains(argument.lowercased()) {
                surfaceTaken = true
                index += 1
                continue
            }
            return (index, argument.lowercased())
        }
        return nil
    }

    /// Every verb `runBrowserCommand` dispatches, including its spelling aliases.
    static let browserVerbs: Set<String> = [
        "open", "open-split", "new", "identify", "profiles", "goto", "navigate", "back", "forward", "reload",
        "url", "get-url", "focus-webview", "focus_webview", "is-webview-focused", "is_webview_focused", "snapshot",
        "eval", "wait", "click", "dblclick", "hover", "focus", "check", "uncheck", "scroll-into-view",
        "scrollintoview", "scrollinto", "type", "fill", "press", "key", "keydown", "keyup", "select", "scroll",
        "screenshot", "get", "is", "find", "frame", "dialog", "download", "cookies", "storage", "panel", "tab",
        "console", "errors", "highlight", "state", "addinitscript", "addscript", "addstyle", "viewport",
        "geolocation", "geo", "keep-live", "keep_live", "offline", "trace", "network", "screencast", "input",
        "input_mouse", "input_keyboard", "input_touch", "dom", "locator",
    ]

    /// Validate panel target flags for readers before socket discovery/connect.
    /// Value boundaries are specific to the command parser: a value option from
    /// some unrelated command must not hide a dangling `--panel` here.
    func validatePanelTargetArguments(command: String, args: [String]) throws {
        let arguments = command == "browser" ? browserArgsForPanelTargetPreflight(args) : args
        guard let spec = panelTargetPreflightSpec(command: command, args: arguments) else { return }
        let spellings = Set(Self.flagSpellings("--panel"))
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if spec.honorsEndOfOptions, argument == "--" { return }
            if let equalsIndex = argument.firstIndex(of: "=") {
                let name = String(argument[..<equalsIndex])
                if spellings.contains(name) {
                    if spec.literalPanelFlagArgumentIndices.contains(index) {
                        index += 1
                        continue
                    }
                    if let literalTailStart = spec.literalEvalScriptTailStart, index >= literalTailStart {
                        index += 1
                        continue
                    }
                    let raw = String(argument[argument.index(after: equalsIndex)...])
                    _ = try validatedPanelTargetValue(raw, wasProvided: true)
                    index += 1
                    continue
                }
                if spec.valueOptions.contains(name) {
                    index += 1
                    continue
                }
            }
            if spec.literalPanelFlagArgumentIndices.contains(index), spellings.contains(argument) {
                index += 1
                continue
            }
            if spec.valueOptions.contains(argument),
               index + 1 < arguments.count,
               !spec.valueOptionsRejectingLongFlags.contains(argument) || !arguments[index + 1].hasPrefix("--") {
                index += 2
                continue
            }
            if let literalTailStart = spec.literalEvalScriptTailStart,
               index >= literalTailStart,
               spellings.contains(argument),
               index + 1 == arguments.count {
                // browser's positional eval form joins the remaining tokens as
                // JavaScript; a final flag-shaped token has no value to consume
                // as a browser target, so it is script text.
                index += 1
                continue
            }
            guard spellings.contains(argument) else {
                index += 1
                continue
            }
            let nextIndex = index + 1
            let raw = nextIndex < arguments.count && arguments[nextIndex] != "--" && !arguments[nextIndex].hasPrefix("-")
                ? arguments[nextIndex]
                : nil
            _ = try validatedPanelTargetValue(raw, wasProvided: true)
            index += raw == nil ? 1 : 2
        }
    }

    func browserArgsForPanelTargetPreflight(_ commandArgs: [String]) -> [String] {
        var args = commandArgs
        while !args.isEmpty, !args.contains("--") {
            if args.last == "--json" {
                args.removeLast()
                continue
            }
            if args.count >= 2, args[args.count - 2] == "--id-format" {
                args.removeLast(2)
                continue
            }
            break
        }
        return args
    }

    func panelTargetPreflightSpec(command: String, args: [String]) -> PanelTargetPreflightSpec? {
        switch command {
        case "identify":
            // identify uses optionValue/hasFlag directly, both of which scan
            // past `--` and only consume --workspace as a value.
            return PanelTargetPreflightSpec(valueOptions: ["--workspace"], honorsEndOfOptions: false)
        case "read-screen", "capture-pane", "capturep":
            return PanelTargetPreflightSpec(
                valueOptions: ["--workspace", "--lines"],
                valueOptionsRejectingLongFlags: ["--lines"],
                honorsEndOfOptions: true
            )
        case "pipe-pane":
            return PanelTargetPreflightSpec(
                valueOptions: ["--command"],
                valueOptionsRejectingLongFlags: ["--command"],
                honorsEndOfOptions: true
            )
        case "read-selection", "input-state":
            return PanelTargetPreflightSpec(valueOptions: ["--workspace"], honorsEndOfOptions: true)
        case "get-metadata":
            // These values are extracted by optionValue/collectRepeatedOption.
            return PanelTargetPreflightSpec(
                valueOptions: ["--workspace", "--area", "--key"],
                valueOptionsRejectingLongFlags: ["--key"],
                honorsEndOfOptions: false
            )
        case "get-titlebar-state":
            return PanelTargetPreflightSpec(valueOptions: ["--workspace"], honorsEndOfOptions: true)
        case "family", "markdown-content":
            return PanelTargetPreflightSpec(valueOptions: [], honorsEndOfOptions: true)
        case "panel-color":
            guard args.first?.lowercased() == "get" else { return nil }
            return PanelTargetPreflightSpec(valueOptions: ["--workspace"], honorsEndOfOptions: true)
        case "markdown":
            var remaining = args
            for name in ["--workspace", "--window", "--panel", "--area"] {
                remaining = parseOption(remaining, name: name).1
            }
            var valueOptions: Set<String> = ["--workspace", "--window", "--area"]
            switch remaining.first?.lowercased() {
            case "scroll": valueOptions.insert("--heading")
            case "theme", "typeface": valueOptions.insert("--set")
            case "font": valueOptions.insert("--scale")
            default: break
            }
            return PanelTargetPreflightSpec(valueOptions: valueOptions, honorsEndOfOptions: true)
        case "browser":
            return browserPanelTargetPreflightSpec(args)
        case "get-url", "is-webview-focused":
            return PanelTargetPreflightSpec(valueOptions: ["--id-format"], honorsEndOfOptions: true)
        case "conversation":
            switch args.first?.lowercased() {
            case "list": return PanelTargetPreflightSpec(valueOptions: ["--workspace"], honorsEndOfOptions: false)
            case "get", "resume", "clear": return PanelTargetPreflightSpec(valueOptions: [], honorsEndOfOptions: false)
            default: return nil
            }
        case "mailbox":
            switch args.first?.lowercased() {
            case "recv": return PanelTargetPreflightSpec(
                valueOptions: ["--hook-format", "--event"],
                valueOptionsRejectingLongFlags: ["--hook-format", "--event"],
                honorsEndOfOptions: true
            )
            case "inbox-dir": return PanelTargetPreflightSpec(valueOptions: [], honorsEndOfOptions: false)
            default: return nil
            }
        case "close-panel":
            return PanelTargetPreflightSpec(valueOptions: ["--workspace"], honorsEndOfOptions: false)
        default:
            return nil
        }
    }

    func browserPanelTargetPreflightSpec(_ commandArgs: [String]) -> PanelTargetPreflightSpec? {
        let (surfaceOpt, afterPanel) = parseOption(commandArgs, name: "--panel")
        var args = afterPanel
        let verbsWithoutPanel: Set<String> = ["open", "open-split", "new", "identify", "profiles"]
        let knownPanelVerbs: Set<String> = [
            "snapshot", "url", "get-url", "is-webview-focused", "is_webview_focused",
            "console", "errors", "storage", "screenshot", "get", "wait", "cookies",
            "highlight", "locator", "download", "dom", "eval", "is", "find", "frame",
            "panel", "tab", "state", "network",
        ]
        if surfaceOpt == nil,
           let first = args.first,
           !first.hasPrefix("-"),
           !verbsWithoutPanel.contains(first.lowercased()),
           !knownPanelVerbs.contains(first.lowercased()) {
            args.removeFirst()
        }
        guard let subcommand = args.first?.lowercased() else { return nil }
        var valueOptions: Set<String> = ["--id-format"]
        switch subcommand {
        case "identify", "url", "get-url", "is-webview-focused", "is_webview_focused", "console", "errors", "storage":
            break
        case "snapshot": valueOptions.formUnion(["--selector", "--max-depth"])
        case "screenshot": valueOptions.insert("--out")
        case "get":
            switch args.dropFirst().first?.lowercased() {
            case "text", "html", "value", "count", "box": valueOptions.insert("--selector")
            case "attr": valueOptions.formUnion(["--selector", "--attr"])
            case "styles": valueOptions.formUnion(["--selector", "--property"])
            default: break
            }
        case "wait": valueOptions.formUnion(["--selector", "--text", "--url-contains", "--url", "--load-state", "--function", "--timeout-ms", "--timeout"])
        case "cookies": valueOptions.formUnion(["--name", "--value", "--url", "--domain", "--path", "--expires"])
        case "eval": valueOptions.insert("--script")
        case "is": valueOptions.insert("--selector")
        case "find":
            switch args.dropFirst().first?.lowercased() {
            case "role": valueOptions.insert("--name")
            case "first", "last": valueOptions.insert("--selector")
            case "nth": valueOptions.formUnion(["--index", "--selector"])
            default: break
            }
        case "frame":
            if args.dropFirst().first?.lowercased() != "main" {
                valueOptions.insert("--selector")
            }
        case "network":
            if args.dropFirst().first?.lowercased() == "route" {
                valueOptions.insert("--body")
            }
        case "panel", "tab", "state": break
        case "highlight": valueOptions.insert("--selector")
        case "locator": valueOptions.formUnion(["--name", "--selector", "--index"])
        case "download": valueOptions.formUnion(["--path", "--timeout-ms", "--timeout"])
        case "dom": valueOptions.formUnion(["--selector", "--max-depth"])
        default:
            return nil
        }
        let literalEvalScriptTailStart = subcommand == "eval"
            ? browserPositionalEvalScriptTailStart(commandArgs)
            : nil
        let literalPanelFlagArgumentIndices = subcommand == "state"
            ? browserPositionalStatePathIndex(commandArgs).map { Set([$0]) } ?? []
            : []
        // Browser's panel selector parser stops at `--`; other reader flags
        // in these subcommands use the same parseOption behavior.
        return PanelTargetPreflightSpec(
            valueOptions: valueOptions,
            honorsEndOfOptions: true,
            literalEvalScriptTailStart: literalEvalScriptTailStart,
            literalPanelFlagArgumentIndices: literalPanelFlagArgumentIndices
        )
    }

    func browserPositionalStatePathIndex(_ commandArgs: [String]) -> Int? {
        let panelSpellings = Set(Self.flagSpellings("--panel"))
        let verbsWithoutSurface: Set<String> = ["open", "open-split", "new", "identify", "profiles"]
        var remaining: [(index: Int, value: String)] = []
        var surface: String?
        var pastTerminator = false
        var index = 0
        while index < commandArgs.count {
            let argument = commandArgs[index]
            if argument == "--" {
                pastTerminator = true
                remaining.append((index, argument))
                index += 1
                continue
            }
            if !pastTerminator, panelSpellings.contains(argument), index + 1 < commandArgs.count {
                surface = commandArgs[index + 1]
                index += 2
                continue
            }
            remaining.append((index, argument))
            index += 1
        }
        if surface == nil,
           let first = remaining.first,
           !first.value.hasPrefix("-"),
           !verbsWithoutSurface.contains(first.value.lowercased()) {
            surface = first.value
            remaining.removeFirst()
        }
        guard let surface,
              !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let subcommand = remaining.first,
              subcommand.value.lowercased() == "state",
              remaining.count >= 3,
              ["save", "load"].contains(remaining[1].value.lowercased()) else {
            return nil
        }
        return remaining[2].index
    }

    func browserPositionalEvalScriptTailStart(_ commandArgs: [String]) -> Int? {
        let panelSpellings = Set(Self.flagSpellings("--panel"))
        let verbsWithoutSurface: Set<String> = ["open", "open-split", "new", "identify", "profiles"]
        var remaining: [(index: Int, value: String)] = []
        var surface: String?
        var pastTerminator = false
        var index = 0
        while index < commandArgs.count {
            let argument = commandArgs[index]
            if argument == "--" {
                pastTerminator = true
                remaining.append((index, argument))
                index += 1
                continue
            }
            if !pastTerminator, panelSpellings.contains(argument), index + 1 < commandArgs.count {
                surface = commandArgs[index + 1]
                index += 2
                continue
            }
            remaining.append((index, argument))
            index += 1
        }
        if surface == nil,
           let first = remaining.first,
           !first.value.hasPrefix("-"),
           !verbsWithoutSurface.contains(first.value.lowercased()) {
            surface = first.value
            remaining.removeFirst()
        }
        guard surface != nil,
              let subcommand = remaining.first,
              subcommand.value.lowercased() == "eval" else {
            return nil
        }
        let scriptArgs = remaining.dropFirst().map(\.value)
        guard optionValue(scriptArgs, name: "--script") == nil else { return nil }
        return subcommand.index + 1
    }

    /// C11-173: a bare `OK` used to mean only "bytes accepted by the socket".
    /// Say so when the target had no PTY yet and the payload is waiting to flush
    /// on attach — that is the one case where the send has *not* reached anyone.
    func sendTextSummary(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let status = SendTextDelivery.summary(
            queued: (payload["queued"] as? Bool) ?? false,
            submitted: (payload["submitted"] as? Bool) ?? false
        )
        let inputGuard = payload["input_guard"] as? String ?? "unguarded"
        return v2OKSummary(payload, idFormat: idFormat) + " " + status
            + " " + String(format: String(localized: "cli.send.input_guard", defaultValue: "input_guard: %@"), inputGuard)
    }

    func sendGuardCompatibilityFields(_ response: [String: Any]) -> [String: Any] {
        var payload = response
        if payload["input_guard"] == nil {
            payload["input_guard"] = "unguarded"
            payload["input_state"] = "unknown"
            payload["draft_length"] = NSNull()
            payload["source"] = NSNull()
            payload["observed_at_ms"] = NSNull()
        }
        return payload
    }

    func requireRawSendSupport(client: SocketClient) throws {
        let unavailable = CLIError(message: String(
            localized: "cli.send.raw_unavailable",
            defaultValue: "This server does not support raw/paste delivery. Use a build advertising send.raw."
        ))
        guard CapabilityFeatures.current.supports(.rawSend) else { throw unavailable }
        let payload: [String: Any]
        do {
            payload = try client.sendV2(method: "system.capabilities")
        } catch let error as CLIError where error.message.contains("method_not_found") {
            throw unavailable
        }
        let supported = (payload["features"] as? [[String: Any]])?.contains {
            $0["id"] as? String == CapabilityFeatures.ID.rawSend.rawValue && ($0["version"] as? Int ?? 0) >= 1
        } ?? false
        guard supported else {
            throw unavailable
        }
    }

    /// An exported-but-empty env var is not a target. Treat it as unset so the
    /// "requires --surface" guard fires instead of silently defaulting.
    func nonEmptyEnv(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizeSurfaceHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            if !allowFocused { return nil }
            let ident = try client.sendV2(method: "system.identify")
            let focused = ident["focused"] as? [String: Any] ?? [:]
            return (focused["panel_ref"] as? String) ?? (focused["panel_id"] as? String)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isUUID(trimmed) || isHandleRef(trimmed) {
            return trimmed
        }
        guard let wantedIndex = Int(trimmed) else {
            throw CLIError(message: "Invalid panel handle: \(trimmed) (expected UUID, ref like panel:1, or index)")
        }

        var params: [String: Any] = [:]
        if let workspaceHandle {
            params["workspace_id"] = workspaceHandle
        }
        let listed = try client.sendV2(method: "panel.list", params: params)
        let items = listed["panels"] as? [[String: Any]] ?? []
        for item in items where intFromAny(item["index"]) == wantedIndex {
            return (item["ref"] as? String) ?? (item["id"] as? String)
        }
        throw CLIError(message: "Panel index not found")
    }

    func canonicalSurfaceHandleFromPanelInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              ["panel", "tab", "surface"].contains(String(pieces[0]).lowercased()),
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "panel:\(ordinal)"
    }

    func normalizeCanonicalPanelHandle(
        _ raw: String?,
        client: SocketClient,
        workspaceHandle: String? = nil,
        allowFocused: Bool = false
    ) throws -> String? {
        guard let raw else {
            return try normalizeSurfaceHandle(
                nil,
                client: client,
                workspaceHandle: workspaceHandle,
                allowFocused: allowFocused
            )
        }

        let canonical = canonicalSurfaceHandleFromPanelInput(raw)
        return try normalizeSurfaceHandle(
            canonical,
            client: client,
            workspaceHandle: workspaceHandle,
            allowFocused: false
        )
    }

    func displayPanelHandle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              ["panel", "tab", "surface"].contains(String(pieces[0]).lowercased()),
              let ordinal = Int(String(pieces[1])) else {
            return trimmed
        }
        return "panel:\(ordinal)"
    }

    func formatHandle(_ payload: [String: Any], kind: String, idFormat: CLIIDFormat) -> String? {
        let id = payload["\(kind)_id"] as? String
        let ref = payload["\(kind)_ref"] as? String
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    func formatPanelHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["panel_id"] as? String)
        let refRaw = (payload["panel_ref"] as? String)
        let ref = displayPanelHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    func formatCreatedPanelHandle(_ payload: [String: Any], idFormat: CLIIDFormat) -> String? {
        let id = (payload["created_panel_id"] as? String)
        let refRaw = (payload["created_panel_ref"] as? String)
        let ref = displayPanelHandle(refRaw)
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    func printV2Payload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallbackText)
        }
    }

    /// Surface the size-aware split policy's non-blocking `size_warning` (axis flip,
    /// near-threshold, tab fallback) to stderr so it stays out of machine-readable
    /// stdout. The warning is also present in the JSON payload for scripted callers.
    func printSizeWarning(_ payload: [String: Any]) {
        guard let warning = payload["size_warning"] as? String, !warning.isEmpty else { return }
        FileHandle.standardError.c11SafeWrite(Data(("note: " + warning + "\n").utf8))
    }
}
