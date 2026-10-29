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

    /// Escape and quote a string for safe embedding in a v1 socket command.
    /// The socket tokenizer treats `\` and `"` as special inside quoted strings,
    /// so both must be escaped before wrapping in double quotes. Newlines and
    /// carriage returns must also be escaped since the socket protocol uses
    /// newline as the message terminator.
    func socketQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
    /// Returns `(remaining, found)` — `found` is true when `name` is present.
    func parseFlag(_ args: [String], name: String) -> ([String], Bool) {
        #if DEBUG
        CLIFlagReadLog.read([name])
        #endif
        var remaining: [String] = []
        var found = false
        for arg in args {
            if arg == name {
                found = true
            } else {
                remaining.append(arg)
            }
        }
        return (remaining, found)
    }

    // MARK: - Vocabulary aliases (workspace > area > panel)

    /// Old command name -> canonical (new) name. Old names stay accepted
    /// forever as hidden aliases: absent from help and usage text.
    static let legacyCommandAliases: [String: String] = [
        "list-panes": "list-areas",
        "list-pane-surfaces": "list-area-panels",
        "list-area-tabs": "list-area-panels",
        "focus-pane": "focus-area",
        "new-pane": "new-area",
        "pane-confirm": "area-confirm",
        "move-surface": "move-panel",
        "move-tab": "move-panel",
        "reorder-surface": "reorder-panel",
        "reorder-tab": "reorder-panel",
        "new-surface": "new-panel",
        "new-tab": "new-panel",
        "close-surface": "close-panel",
        "close-tab": "close-panel",
        "rename-tab": "rename-panel",
        "drag-surface-to-split": "drag-panel-to-split",
        "drag-tab-to-split": "drag-panel-to-split",
        "refresh-surfaces": "refresh-panels",
        "refresh-tabs": "refresh-panels",
        "surface-health": "panel-health",
        "tab-health": "panel-health",
        "list-tabs": "list-panels",
        "focus-tab": "focus-panel",
        "send-tab": "send-panel",
        "send-key-tab": "send-key-panel",
        "surface-color": "panel-color",
        "tab-color": "panel-color",
        "set-tab-icon": "set-panel-icon",
        "set-tab-color": "set-panel-color",
        "tab-action": "panel-action",
    ]

    /// The calling panel's UUID from the environment: `C11_PANEL_ID` first, then
    /// the hidden aliases `C11_TAB_ID`, `C11_SURFACE_ID`, `CMUX_PANEL_ID`,
    /// `CMUX_TAB_ID`, `CMUX_SURFACE_ID`.
    static func callerPanelEnv(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in ["C11_PANEL_ID", "C11_TAB_ID", "C11_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SURFACE_ID"] {
            if let raw = environment[key] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func canonicalCommandName(_ command: String) -> String {
        guard CapabilityFeatures.current.supports(.workspaceAreaPanel) else { return command }
        return legacyCommandAliases[command] ?? command
    }

    /// Flag spellings that mean the same thing; the first is canonical. The option helpers
    /// (`parseOption`, `parseRepeatedOption`, `optionValue`, `hasFlag`) match any spelling in a
    /// group, so `--panel` / `--area` (canonical) work beside `--tab` / `--surface` / `--pane`
    /// (hidden aliases) exactly where a command parses a flag, and free-text arguments are never
    /// rewritten. tmux-compat flags (`--target-pane`, `%N`) are not aliased.
    static let flagAliasGroups: [[String]] = [
        ["--panel", "--tab", "--surface"],
        ["--area", "--pane"],
        ["--before-panel", "--before-tab", "--before-surface"],
        ["--after-panel", "--after-tab", "--after-surface"],
        ["--in-panel", "--in-tab", "--in-surface"],
    ]

    static func flagSpellings(_ name: String) -> [String] {
        flagAliasGroups.first(where: { $0.contains(name) }) ?? [name]
    }

    /// Whether `arg` is any spelling of the flag `name` (for parsers that walk argv by hand).
    static func isFlag(_ arg: String, _ name: String) -> Bool {
        #if DEBUG
        CLIFlagReadLog.read(flagSpellings(name))
        #endif
        return flagSpellings(name).contains(arg)
    }

    /// `tab:N` / `surface:N` / `panel:N` -> `panel:N`, `pane:N` -> `area:N` (prefix
    /// case-insensitive); anything else unchanged. Used wherever a user-typed handle is
    /// compared with a handle the app returned, which always carries the canonical prefix.
    static func canonicalHandle(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for prefix in ["panel:", "tab:", "surface:"] where lowered.hasPrefix(prefix) {
            return "panel:" + trimmed.dropFirst(prefix.count)
        }
        if lowered.hasPrefix("area:") { return "area:" + trimmed.dropFirst("area:".count) }
        if lowered.hasPrefix("pane:") { return "area:" + trimmed.dropFirst("pane:".count) }
        return trimmed
    }

    func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        let spellings = Self.flagSpellings(name)
        #if DEBUG
        CLIFlagReadLog.read(spellings)
        #endif
        var remaining: [String] = []
        var value: String?
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, spellings.contains(arg), idx + 1 < args.count {
                value = args[idx + 1]
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (value, remaining)
    }

    func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        let spellings = Self.flagSpellings(name)
        #if DEBUG
        CLIFlagReadLog.read(spellings)
        #endif
        var remaining: [String] = []
        var values: [String] = []
        var skipNext = false
        var pastTerminator = false
        for (idx, arg) in args.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, spellings.contains(arg), idx + 1 < args.count {
                values.append(args[idx + 1])
                skipNext = true
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
    }

    func resizeWindowUsageError() -> CLIError {
        CLIError(message: String(localized: "cli.resize_window.usage", defaultValue: "resize-window requires --window <id> <width> <height>. Use - to keep an edge."))
    }

    func parseResizeWindowArguments(_ args: [String]) throws -> (window: String, width: Double?, height: Double?) {
        try rejectEmptyTargetFlags(args)
        let (window, rest) = parseOption(args, name: "--window")
        var dimensions = rest
        if dimensions.first == "--" { dimensions.removeFirst() }
        guard args.filter({ $0 == "--window" }).count == 1,
              let window, !window.hasPrefix("--"), dimensions.count == 2 else {
            throw resizeWindowUsageError()
        }
        func number(_ token: String) throws -> Double? {
            if token == "-" { return nil }
            guard let value = Double(token), value.isFinite else {
                throw CLIError(message: String(format: String(localized: "cli.resize_window.bad_size", defaultValue: "'%@' is not a width or height. Pass a number or -."), token))
            }
            return value
        }
        return (window, try number(dimensions[0]), try number(dimensions[1]))
    }

    func optionValue(_ args: [String], name: String) -> String? {
        let spellings = Self.flagSpellings(name)
        #if DEBUG
        CLIFlagReadLog.read(spellings)
        #endif
        guard let index = args.firstIndex(where: { spellings.contains($0) }), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Read an explicit profile selector without collapsing malformed or
    /// empty values into the omitted/default-profile case.
    func validatedBrowserProfileOption(_ args: [String]) throws -> String? {
        var value: String?
        var index = 0
        while index < args.count, args[index] != "--" {
            let argument = args[index]
            if argument.hasPrefix("--profile=") {
                throw CLIError(message: String(localized: "browser.profile.error.invalidSelection", defaultValue: "--profile must be a non-empty string"))
            }
            guard argument == "--profile" else {
                index += 1
                continue
            }
            guard value == nil,
                  index + 1 < args.count,
                  args[index + 1] != "--",
                  !args[index + 1].hasPrefix("-") else {
                throw CLIError(message: String(localized: "browser.profile.error.invalidSelection", defaultValue: "--profile must be a non-empty string"))
            }
            let candidate = args[index + 1]
            guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: String(localized: "browser.profile.error.invalidSelection", defaultValue: "--profile must be a non-empty string"))
            }
            value = candidate
            index += 2
        }
        return value
    }

    /// Destructive profile commands accept one selector and `--yes` only.
    /// Rejecting every unrecognized token here prevents a typo such as
    /// `--dry-run` from being discarded before a destructive socket request.
    func parseBrowserProfileDestructiveArguments(
        _ args: [String],
        command: String
    ) throws -> (profile: String, confirmed: Bool) {
        var optionProfile: String?
        var positionals: [String] = []
        var confirmed = false
        var index = 0

        func invalidArguments() -> CLIError {
            CLIError(message: String(
                localized: "browser.profile.cli.invalidDestructiveArguments",
                defaultValue: "browser profiles \(command) requires exactly one profile target; only --profile and --yes are accepted"
            ))
        }

        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--yes":
                guard !confirmed else { throw invalidArguments() }
                confirmed = true
                index += 1
            case "--profile":
                guard optionProfile == nil,
                      index + 1 < args.count,
                      !args[index + 1].hasPrefix("-") else {
                    throw invalidArguments()
                }
                let candidate = args[index + 1]
                guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalidArguments()
                }
                optionProfile = candidate
                index += 2
            default:
                guard !argument.hasPrefix("-") else { throw invalidArguments() }
                positionals.append(argument)
                index += 1
            }
        }

        guard optionProfile == nil || positionals.isEmpty else { throw invalidArguments() }
        let target: String
        if let optionProfile {
            target = optionProfile
        } else if positionals.count == 1 {
            target = positionals[0]
        } else {
            throw invalidArguments()
        }
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalidArguments()
        }
        return (target, confirmed)
    }

    /// Destructive commands refuse an explicitly empty target flag (almost
    /// always an unset shell variable) instead of letting it fall back to the
    /// focused target.
    func rejectEmptyTargetFlags(_ args: [String]) throws {
        #if DEBUG
        try CLIFlagReadLog.withoutRecording { try rejectEmptyTargetFlagsUnrecorded(args) }
        #else
        try rejectEmptyTargetFlagsUnrecorded(args)
        #endif
    }

    func rejectEmptyTargetFlagsUnrecorded(_ args: [String]) throws {
        // Alias groups cover the hidden spellings (--pane, --tab, --surface).
        for name in ["--window", "--workspace", "--area"] {
            if let value = optionValue(args, name: name),
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CLIError(message: "\(name) received an empty value (likely from an unset shell variable). Pass a real ref or omit the flag.")
            }
        }
        let panelSpellings = Set(Self.flagSpellings("--panel"))
        for argument in args {
            guard let equalsIndex = argument.firstIndex(of: "=") else { continue }
            let name = String(argument[..<equalsIndex])
            guard panelSpellings.contains(name) else { continue }
            _ = try validatedPanelTargetValue(String(argument[argument.index(after: equalsIndex)...]), wasProvided: true)
        }
        if let value = optionValue(args, name: "--panel"),
           value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try validatedPanelTargetValue(value, wasProvided: true)
        }
    }

    func hasFlag(_ args: [String], name: String) -> Bool {
        let spellings = Self.flagSpellings(name)
        #if DEBUG
        CLIFlagReadLog.read(spellings)
        #endif
        return args.contains(where: { spellings.contains($0) })
    }

    /// Extract a boolean flag, returning (present, remaining). Respects `--` terminator
    /// so callers that join the remainder as text don't accidentally treat a post-`--`
    /// occurrence of `name` as the flag.
    func parseBoolFlag(_ args: [String], name: String) -> (Bool, [String]) {
        #if DEBUG
        CLIFlagReadLog.read([name])
        #endif
        var present = false
        var remaining: [String] = []
        var pastTerminator = false
        for arg in args {
            if arg == "--" {
                pastTerminator = true
                remaining.append(arg)
                continue
            }
            if !pastTerminator, arg == name {
                present = true
                continue
            }
            remaining.append(arg)
        }
        return (present, remaining)
    }

    /// CMUX-10: client-side hex validation for `--color`. The socket re-validates
    /// authoritatively (server is the source of truth), but rejecting obviously
    /// wrong shapes here gives the operator a fast, clear error without a
    /// round-trip. Accepts `#RRGGBB`, `#RRGGBBAA`, with or without leading `#`.
    func isValidFlashColorHex(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard stripped.count == 6 || stripped.count == 8 else { return false }
        return stripped.allSatisfy { $0.isHexDigit }
    }

    /// Unescape CLI escape sequences to match legacy v1 send behavior.
    /// \n and \r → carriage return (Enter), \t → tab.
    func unescapeSendText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    enum CallerPanelFollow: Equatable {
        case unchanged
        case moved(UUID)
        /// The lookup ended without a reply (timeout or transport failure), so
        /// a late reply could still arrive on this connection: reconnect.
        case connectionSuspect
    }

    /// C11-499: a shell keeps the C11_WORKSPACE_ID it started with, and a
    /// panel can move to another workspace after that. Ask c11 once where the
    /// caller's panel (C11_PANEL_ID) lives now and, when it moved, point this
    /// process's C11_WORKSPACE_ID and CMUX_WORKSPACE_ID at that workspace, so
    /// every command that defaults to the caller's workspace follows the panel.
    /// An app that does not advertise `panel.locate`, or an unknown panel,
    /// leaves the environment.
    static func followCallerPanelWorkspace(client: SocketClient) -> CallerPanelFollow {
        let env = ProcessInfo.processInfo.environment
        guard let panel = callerPanelEnv(env), UUID(uuidString: panel) != nil,
              let start = (env["C11_WORKSPACE_ID"] ?? env["CMUX_WORKSPACE_ID"]).flatMap(UUID.init(uuidString:))
        else { return .unchanged }
        let payload: [String: Any]
        do {
            guard try client.advertisesMethod("panel.locate") else { return .unchanged }
            payload = try client.sendV2(method: "panel.locate", params: ["panel_id": panel])
        } catch let error as CLIError where isServerErrorReply(error.message) {
            return .unchanged
        } catch {
            return .connectionSuspect
        }
        guard let live = (payload["workspace_id"] as? String).flatMap(UUID.init(uuidString:)),
              live != start else { return .unchanged }
        setenv("C11_WORKSPACE_ID", live.uuidString, 1)
        setenv("CMUX_WORKSPACE_ID", live.uuidString, 1)
        return .moved(live)
    }

    /// An app's own error reply (`code: message`, code in snake case), as
    /// opposed to a timeout (`c11: timeout: ...`) or a transport failure.
    static func isServerErrorReply(_ message: String) -> Bool {
        guard let colon = message.firstIndex(of: ":") else { return false }
        let code = message[..<colon]
        return !code.isEmpty && code.allSatisfy { $0 == "_" || ("a"..."z").contains($0) }
    }

    func workspaceFromArgsOrEnv(_ args: [String], windowOverride: String? = nil) -> String? {
        if let explicit = optionValue(args, name: "--workspace") { return explicit }
        // When --window is explicitly targeted, don't fall back to env workspace from a different window
        if windowOverride != nil { return nil }
        let environment = ProcessInfo.processInfo.environment
        return environment["C11_WORKSPACE_ID"] ?? environment["CMUX_WORKSPACE_ID"]
    }

    // MARK: - Module 1 / Module 2 metadata CLI

    /// Collect all `--<name> <value>` and `--<name>=<value>` occurrences.
    /// Used for repeated flags like `--key foo --key bar`.
    func collectRepeatedOption(_ args: [String], name: String) -> [String] {
        #if DEBUG
        CLIFlagReadLog.read([name])
        #endif
        var out: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == name, i + 1 < args.count {
                out.append(args[i + 1])
                i += 2
                continue
            }
            if arg.hasPrefix("\(name)=") {
                out.append(String(arg.dropFirst(name.count + 1)))
                i += 1
                continue
            }
            i += 1
        }
        return out
    }

    /// The words that are neither `--` options nor the value of one of
    /// `valueOptions`, in order. Preflight has already split `--name=value`,
    /// so `--workspace workspace:1 goal` yields `["goal"]`.
    func positionalWords(_ args: [String], valueOptions: [String]) -> [String] {
        let values = Set(valueOptions.flatMap(Self.flagSpellings))
        var words: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if values.contains(arg) {
                i += 2
                continue
            }
            if !arg.hasPrefix("--") { words.append(arg) }
            i += 1
        }
        return words
    }
}
