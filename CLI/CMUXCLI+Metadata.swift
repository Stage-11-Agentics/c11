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

    /// Resolve `(workspace_id, surface_id)` for a metadata-style CLI call.
    /// Honors --surface, --workspace, `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, and falls back
    /// to the focused surface when no explicit target is supplied.
    func resolveMetadataTarget(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?,
        allowFocused: Bool = true
    ) throws -> (workspaceId: String?, surfaceId: String?) {
        let workspaceRaw = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
        let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client)

        // Only fall back to CMUX_SURFACE_ID when the caller did not explicitly pass
        // --workspace. workspaceRaw includes the env-derived workspace, so gating
        // on workspaceRaw == nil defeats the env-surface fallback whenever the
        // agent is running inside c11 (CMUX_WORKSPACE_ID is always set).
        let explicitWorkspaceFlag = optionValue(commandArgs, name: "--workspace")
        let surfaceRaw = optionValue(commandArgs, name: "--panel")
            ?? optionValue(commandArgs, name: "--panel")
            ?? (explicitWorkspaceFlag == nil && windowOverride == nil
                ? Self.callerPanelEnv()
                : nil)
        // C11-165 COR-1: writes pass allowFocused:false, so a ref-less external
        // caller (no --surface, no CMUX_SURFACE_ID) sends no surface_id and the
        // server rejects (missing_ref) rather than the CLI resolving the
        // operator-focused surface client-side. Reads keep the focused fallback.
        let surfaceId = try normalizeSurfaceHandle(
            surfaceRaw,
            client: client,
            workspaceHandle: workspaceId,
            allowFocused: allowFocused && surfaceRaw == nil
        )
        return (workspaceId, surfaceId)
    }

    /// Result of resolving a metadata command's target when either a pane or
    /// a surface may be specified. `--surface` and `--pane` are mutually
    /// exclusive; default (neither) routes to the caller's current surface
    /// per existing behavior.
    enum MetadataCommandTarget {
        case surface(workspaceId: String?, surfaceId: String?)
        case pane(workspaceId: String?, paneId: String)
    }

    func resolveMetadataCommandTarget(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?,
        allowFocused: Bool = true
    ) throws -> MetadataCommandTarget {
        let surfaceRaw = optionValue(commandArgs, name: "--panel")
            ?? optionValue(commandArgs, name: "--panel")
        let paneRaw = optionValue(commandArgs, name: "--area")

        if surfaceRaw != nil, paneRaw != nil {
            throw CLIError(message: "usage: --panel and --area are mutually exclusive")
        }

        if let paneRaw {
            let workspaceRaw = workspaceFromArgsOrEnv(commandArgs, windowOverride: windowOverride)
            let workspaceId = try normalizeWorkspaceHandle(workspaceRaw, client: client)
            guard let paneId = try normalizePaneHandle(
                paneRaw,
                client: client,
                workspaceHandle: workspaceId
            ) else {
                throw CLIError(message: "Invalid area handle: \(paneRaw)")
            }
            return .pane(workspaceId: workspaceId, paneId: paneId)
        }

        let (workspaceId, surfaceId) = try resolveMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride,
            allowFocused: allowFocused
        )
        return .surface(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// `c11 default-agent {get|set|launch}` — sugar over the v1 `default_agent`
    /// socket command. Resolves surface refs client-side to UUIDs (the v1
    /// handler accepts UUIDs only), then forwards the composed v1 string.
    func runDefaultAgentCommand(
        commandArgs: [String],
        client: SocketClient
    ) throws {
        guard let sub = commandArgs.first else {
            throw CLIError(message: "default-agent requires a subcommand: get | set <type> | launch [flags]")
        }

        switch sub {
        case "get":
            let response = try sendV1Command("default_agent get", client: client)
            print(response)

        case "set":
            guard commandArgs.count >= 2 else {
                let valid = ["claude-code", "codex", "grok", "kimi", "opencode", "github-copilot", "pi", "omp", "custom"].joined(separator: ", ")
                throw CLIError(message: "default-agent set requires <type>. Valid: \(valid)")
            }
            let response = try sendV1Command("default_agent set \(commandArgs[1])", client: client)
            print(response)

        case "launch":
            try runDefaultAgentLaunchCommand(
                commandArgs: Array(commandArgs.dropFirst()),
                client: client
            )

        default:
            throw CLIError(message: "default-agent: unknown subcommand '\(sub)' (expected get|set|launch)")
        }
    }

    func runDefaultAgentLaunchCommand(
        commandArgs: [String],
        client: SocketClient
    ) throws {
        let agentArg = optionValue(commandArgs, name: "--agent")
        let inSurfaceRaw = optionValue(commandArgs, name: "--in-panel")
        let paneArg = optionValue(commandArgs, name: "--area")
        let cwdArg = optionValue(commandArgs, name: "--cwd")
        let promptArg = optionValue(commandArgs, name: "--prompt")
        let promptFileArg = optionValue(commandArgs, name: "--prompt-file")

        if inSurfaceRaw != nil && paneArg != nil {
            throw CLIError(message: "default-agent launch: --in-panel and --area are mutually exclusive")
        }
        if promptArg != nil && promptFileArg != nil {
            throw CLIError(message: "default-agent launch: --prompt and --prompt-file are mutually exclusive")
        }

        // Resolve --in-surface ref → UUID. The v1 handler accepts UUIDs only;
        // short refs and indexes get resolved here.
        //
        // C11-121: previously this listed only the *focused* workspace
        // (`surface.list` with empty params), so a `surface:N` ref belonging to
        // any other workspace failed with "Surface not found" — even though
        // `send`/`read-screen`, given an explicit `--workspace`, resolved the
        // same ref fine. `default-agent launch` has no `--workspace` flag, so we
        // align with send's resolution by searching every workspace in every
        // window. A `surface:N` ref / index is unique within a workspace; the
        // first match across the fleet is the target. An explicit `--workspace`
        // (or `CMUX_WORKSPACE_ID` in the caller's env) scopes the search when
        // provided, matching how send narrows resolution.
        var launchWorkspace: String? = nil
        var inSurfaceUUID: String? = nil
        if client.scopedWindow != nil {
            let explicitWorkspace = optionValue(commandArgs, name: "--workspace")
            launchWorkspace = try resolveWorkspaceId(explicitWorkspace, client: client)
            if let raw = inSurfaceRaw {
                // UUIDs and refs can name a tab in a nonselected workspace
                // within the scoped window. Numeric indexes stay workspace-local.
                if explicitWorkspace == nil && Int(raw) == nil {
                    let listed = try client.sendV2(method: "workspace.list")
                    for workspace in listed["workspaces"] as? [[String: Any]] ?? [] {
                        guard let id = workspace["id"] as? String else { continue }
                        let panels = try client.sendV2(method: "panel.list", params: ["workspace_id": id])
                        if (panels["panels"] as? [[String: Any]] ?? []).contains(where: {
                            ($0["id"] as? String)?.caseInsensitiveCompare(raw) == .orderedSame
                                || ($0["ref"] as? String).map(Self.canonicalHandle) == Self.canonicalHandle(raw)
                        }) {
                            launchWorkspace = id
                            break
                        }
                    }
                }
                inSurfaceUUID = try resolveSurfaceId(raw, workspaceId: launchWorkspace!, client: client)
            }
        } else if let raw = inSurfaceRaw {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUUID(trimmed) {
                inSurfaceUUID = trimmed
            } else {
                let asIndex = Int(trimmed)
                let matches: (_ item: [String: Any]) -> Bool = { item in
                    if (item["ref"] as? String).map(Self.canonicalHandle) == Self.canonicalHandle(trimmed) { return true }
                    if let asIndex, intFromAny(item["index"]) == asIndex { return true }
                    return false
                }

                // Build the set of workspaces to search: an explicit/env
                // workspace narrows it; otherwise every workspace in every window.
                let wsScope = workspaceFromArgsOrEnv(commandArgs)
                var workspaceIds: [String] = []
                let scopedWorkspaceId: String? = wsScope.flatMap { try? normalizeWorkspaceHandle($0, client: client) } ?? nil
                if let scopedWorkspaceId {
                    workspaceIds = [scopedWorkspaceId]
                } else {
                    let windows = try client.sendV2(method: "window.list")
                    let windowList = windows["windows"] as? [[String: Any]] ?? []
                    for window in windowList {
                        guard let windowId = window["id"] as? String else { continue }
                        let wsListed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                        let wsItems = wsListed["workspaces"] as? [[String: Any]] ?? []
                        for ws in wsItems {
                            if let id = ws["id"] as? String { workspaceIds.append(id) }
                        }
                    }
                }

                for wsId in workspaceIds {
                    let listed = try client.sendV2(method: "panel.list", params: ["workspace_id": wsId])
                    let items = listed["panels"] as? [[String: Any]] ?? []
                    if let hit = items.first(where: matches), let id = hit["id"] as? String {
                        inSurfaceUUID = id
                        break
                    }
                }
                if inSurfaceUUID == nil {
                    throw CLIError(message: "Panel not found: \(raw)")
                }
            }
        }

        // Compose v1 command. Multi-word values get quoted so tokenizeArgs
        // on the server reconstructs them as single tokens.
        var parts: [String] = ["default_agent", "launch"]
        if let launchWorkspace { parts.append("--workspace"); parts.append(launchWorkspace) }
        if let agentArg { parts.append("--agent"); parts.append(agentArg) }
        if let inSurfaceUUID { parts.append("--in-surface"); parts.append(inSurfaceUUID) }
        if let paneArg { parts.append("--pane"); parts.append(paneArg) }
        // --cwd resolves relative to where the CLI ran (so `--cwd .` works), the
        // same as new-split/new-pane/new-surface; `inherit` means "no explicit
        // cwd" and is not forwarded.
        if let cwdArg = cwdArg?.trimmingCharacters(in: .whitespaces),
           !cwdArg.isEmpty, cwdArg.lowercased() != "inherit" {
            parts.append("--cwd"); parts.append(v1QuoteForTokenizer(resolvePath(cwdArg)))
        }
        if let promptArg { parts.append("--prompt"); parts.append(v1QuoteForTokenizer(promptArg)) }
        if let promptFileArg { parts.append("--prompt-file"); parts.append(v1QuoteForTokenizer(promptFileArg)) }

        let v1Cmd = parts.joined(separator: " ")
        let response = try sendV1Command(v1Cmd, client: client)
        print(response)
    }

    /// Quote a string for the v1 server-side `tokenizeArgs` parser. Uses
    /// double quotes with backslash escapes (the tokenizer's escape grammar:
    /// `\\`, `\"`, `\n`, `\r`, `\t`).
    func v1QuoteForTokenizer(_ value: String) -> String {
        var escaped = ""
        for char in value {
            switch char {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(char)
            }
        }
        return "\"\(escaped)\""
    }

    /// `cmux set-agent` — M1 sugar over `surface.set_metadata { source: declare, mode: merge }`.
    func runSetAgentCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let type = optionValue(commandArgs, name: "--type") else {
            throw CLIError(message: "set-agent requires --type <terminal_type>")
        }
        // Pre-validate per spec: kebab-case, ≤ 32 chars.
        let kebab = try NSRegularExpression(pattern: "^[a-z][a-z0-9-]*$")
        let range = NSRange(type.startIndex..<type.endIndex, in: type)
        guard type.count <= 32,
              kebab.firstMatch(in: type, options: [], range: range) != nil else {
            throw CLIError(message: "invalid_value: --type must be kebab-case and ≤ 32 chars (got: \(type))")
        }

        var metadata: [String: Any] = ["terminal_type": type]
        if let model = optionValue(commandArgs, name: "--model") { metadata["model"] = model }
        if let task = optionValue(commandArgs, name: "--task") { metadata["task"] = task }
        if let role = optionValue(commandArgs, name: "--role") { metadata["role"] = role }

        let (workspaceId, surfaceId) = try resolveMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride,
            allowFocused: false  // C11-165 COR-1: set-agent is a write — no client-side focused fallback
        )
        var params: [String: Any] = [
            "metadata": metadata,
            "mode": "merge",
            "source": "declare"
        ]
        if let workspaceId { params["workspace_id"] = workspaceId }
        if let surfaceId { params["panel_id"] = surfaceId }

        let payload = try client.sendV2(method: "panel.set_metadata", params: params)
        printMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// `cmux set-metadata` — M2 sugar over `surface.set_metadata { source: explicit }`.
    func runSetMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        var metadata: [String: Any] = [:]
        if let jsonStr = optionValue(commandArgs, name: "--json-input")
            ?? optionValue(commandArgs, name: "--body") {
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "invalid_json: --json must be a JSON object string")
            }
            metadata = obj
        } else if let rawJSON = optionValue(commandArgs, name: "--json"),
                  let data = rawJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Accept --json '{...}' when it parses as an object. If it doesn't parse
            // (e.g. user meant the output toggle), fall through to key/value handling.
            metadata = obj
        }

        if metadata.isEmpty {
            guard let key = optionValue(commandArgs, name: "--key"),
                  let valueRaw = optionValue(commandArgs, name: "--value") else {
                throw CLIError(message: "set-metadata requires --key/--value or --json '{...}'")
            }
            let typeHint = (optionValue(commandArgs, name: "--type") ?? "string").lowercased()
            switch typeHint {
            case "string": metadata[key] = valueRaw
            case "number":
                if let n = Int(valueRaw) {
                    metadata[key] = n
                } else if let d = Double(valueRaw) {
                    metadata[key] = d
                } else {
                    throw CLIError(message: "invalid_value: --value is not a number (got: \(valueRaw))")
                }
            case "bool", "boolean":
                let v = valueRaw.lowercased()
                if v == "true" || v == "1" || v == "yes" { metadata[key] = true }
                else if v == "false" || v == "0" || v == "no" { metadata[key] = false }
                else { throw CLIError(message: "invalid_value: --value is not a bool (got: \(valueRaw))") }
            case "json":
                guard let data = valueRaw.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    throw CLIError(message: "invalid_json: --value is not JSON (got: \(valueRaw))")
                }
                metadata[key] = parsed
            default:
                throw CLIError(message: "invalid_value: --type must be string|number|bool|json")
            }
        }

        let mode = (optionValue(commandArgs, name: "--mode") ?? "merge").lowercased()
        let source = (optionValue(commandArgs, name: "--source") ?? "explicit").lowercased()
        let target = try resolveMetadataCommandTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride,
            allowFocused: false  // C11-165 COR-1: set-metadata is a write — no client-side focused fallback
        )
        var params: [String: Any] = [
            "metadata": metadata,
            "mode": mode,
            "source": source
        ]
        let method: String
        switch target {
        case .surface(let workspaceId, let surfaceId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            if let surfaceId { params["panel_id"] = surfaceId }
            method = "panel.set_metadata"
        case .pane(let workspaceId, let paneId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            params["area_id"] = paneId
            method = "area.set_metadata"
        }

        let payload = try client.sendV2(method: method, params: params)
        printMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// `cmux get-metadata` — M2 sugar over `surface.get_metadata` (or
    /// `pane.get_metadata` when `--pane` is supplied).
    func runGetMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let includeSources = hasFlag(commandArgs, name: "--sources")
            || hasFlag(commandArgs, name: "--include-sources")
        let keys = collectRepeatedOption(commandArgs, name: "--key")
        let target = try resolveMetadataCommandTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [:]
        if !keys.isEmpty { params["keys"] = keys }
        if includeSources { params["include_sources"] = true }
        let method: String
        switch target {
        case .surface(let workspaceId, let surfaceId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            if let surfaceId { params["panel_id"] = surfaceId }
            method = "panel.get_metadata"
        case .pane(let workspaceId, let paneId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            params["area_id"] = paneId
            method = "area.get_metadata"
        }

        let payload = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let metadata = payload["metadata"] as? [String: Any] ?? [:]
        let sources = payload["metadata_sources"] as? [String: [String: Any]] ?? [:]
        if metadata.isEmpty {
            print("(empty)")
            return
        }
        let keyOrder = metadata.keys.sorted()
        for k in keyOrder {
            guard let v = metadata[k] else { continue }
            let valueText = renderScalarOrJSON(v)
            if includeSources, let sidecar = sources[k] {
                let src = (sidecar["source"] as? String) ?? "?"
                let ts = (sidecar["ts"] as? Double).map { String(format: "%.3f", $0) } ?? "?"
                print("\(k) = \(valueText)  [\(src) @ \(ts)]")
            } else {
                print("\(k) = \(valueText)")
            }
        }
    }

    /// `cmux clear-metadata` — M2 sugar over `surface.clear_metadata` (or
    /// `pane.clear_metadata` when `--pane` is supplied).
    func runClearMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let keys = collectRepeatedOption(commandArgs, name: "--key")
        let source = (optionValue(commandArgs, name: "--source") ?? "explicit").lowercased()
        let target = try resolveMetadataCommandTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride,
            allowFocused: false  // C11-165 COR-1: clear-metadata is a write — no client-side focused fallback
        )
        var params: [String: Any] = ["source": source]
        if !keys.isEmpty { params["keys"] = keys }
        let method: String
        switch target {
        case .surface(let workspaceId, let surfaceId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            if let surfaceId { params["panel_id"] = surfaceId }
            method = "panel.clear_metadata"
        case .pane(let workspaceId, let paneId):
            if let workspaceId { params["workspace_id"] = workspaceId }
            params["area_id"] = paneId
            method = "area.clear_metadata"
        }

        let payload = try client.sendV2(method: method, params: params)
        printMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// Resolve the `workspace_id` param for a workspace metadata CLI call.
    /// Honors `--workspace`, `CMUX_WORKSPACE_ID`, then falls back to the
    /// currently selected workspace (server-side default).
    func resolveWorkspaceMetadataTarget(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> String {
        // C11-251: explicit --workspace or the caller's workspace environment only;
        // never the selected workspace, and a global --window is not a target.
        guard let raw = optionValue(commandArgs, name: "--workspace") ?? sidebarWorkspaceFromEnv() else {
            throw CLIError(message: String(localized: "cli.workspace.target.required", defaultValue: "workspace command requires --workspace or C11_WORKSPACE_ID; it will not use the selected workspace"))
        }
        return try resolveWorkspaceId(raw, client: client)
    }

    /// `c11 set-workspace-metadata <key> <value>` — wraps workspace.set_metadata.
    func runSetWorkspaceMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let positional = commandArgs.filter { !$0.hasPrefix("--") }
        var metadata: [String: String] = [:]
        var singleKey: String?
        var singleValue: String?

        if let jsonStr = optionValue(commandArgs, name: "--json") {
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "invalid_json: --json must be a JSON object string")
            }
            for (k, v) in obj {
                guard let s = v as? String else {
                    throw CLIError(message: "invalid_value: workspace metadata values must be strings (key '\(k)')")
                }
                metadata[k] = s
            }
        } else if let keyOpt = optionValue(commandArgs, name: "--key"),
                  let valueOpt = optionValue(commandArgs, name: "--value") {
            singleKey = keyOpt
            singleValue = valueOpt
        } else if positional.count >= 2 {
            singleKey = positional[0]
            singleValue = positional.dropFirst().joined(separator: " ")
        } else {
            throw CLIError(message: "set-workspace-metadata requires <key> <value>, --key/--value, or --json '{...}'")
        }

        let workspaceId = try resolveWorkspaceMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )

        var params: [String: Any] = [:]
        params["workspace_id"] = workspaceId
        if !metadata.isEmpty {
            params["metadata"] = metadata
        } else if let singleKey, let singleValue {
            params["key"] = singleKey
            params["value"] = singleValue
        }

        let payload = try client.sendV2(method: "workspace.set_metadata", params: params)
        printWorkspaceMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// `cmux get-workspace-metadata [<key>]` — wraps workspace.get_metadata.
    func runGetWorkspaceMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let positional = commandArgs.filter { !$0.hasPrefix("--") }
        let keyFilter = optionValue(commandArgs, name: "--key") ?? positional.first

        let workspaceId = try resolveWorkspaceMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [:]
        params["workspace_id"] = workspaceId
        if let keyFilter { params["key"] = keyFilter }

        let payload = try client.sendV2(method: "workspace.get_metadata", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let metadata = payload["metadata"] as? [String: String] ?? [:]
        if let keyFilter {
            if let v = metadata[keyFilter] {
                print(v)
            } else {
                print("(unset)")
            }
            return
        }
        if metadata.isEmpty {
            print("(empty)")
            return
        }
        for key in metadata.keys.sorted() {
            print("\(key) = \(metadata[key] ?? "")")
        }
    }

    /// `cmux clear-workspace-metadata [<key>]` — wraps workspace.clear_metadata.
    func runClearWorkspaceMetadataCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let positional = commandArgs.filter { !$0.hasPrefix("--") }
        var keys: [String] = collectRepeatedOption(commandArgs, name: "--key")
        if keys.isEmpty, let first = positional.first {
            keys = [first]
        }

        let workspaceId = try resolveWorkspaceMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = [:]
        params["workspace_id"] = workspaceId
        if !keys.isEmpty { params["keys"] = keys }

        let payload = try client.sendV2(method: "workspace.clear_metadata", params: params)
        printWorkspaceMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// `c11 set-workspace-description <text>` / `c11 set-workspace-icon <glyph>`
    /// — thin sugar over `set-workspace-metadata <canonical-key> <value>`.
    func runSetWorkspaceCanonicalKeyCommand(
        key: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let positional = commandArgs.filter { !$0.hasPrefix("--") }
        guard let value = optionValue(commandArgs, name: "--value") ?? positional.first else {
            throw CLIError(message: "set-workspace-\(key) requires a value")
        }

        let workspaceId = try resolveWorkspaceMetadataTarget(
            commandArgs: commandArgs,
            client: client,
            windowOverride: windowOverride
        )
        var params: [String: Any] = ["key": key, "value": value]
        params["workspace_id"] = workspaceId
        let payload = try client.sendV2(method: "workspace.set_metadata", params: params)
        printWorkspaceMetadataResult(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// Print a workspace.set_metadata / workspace.clear_metadata result.
    func printWorkspaceMetadataResult(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        var parts = ["OK"]
        if let handle = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            parts.append(handle)
        }
        print(parts.joined(separator: " "))
        let metadata = payload["metadata"] as? [String: String] ?? [:]
        if metadata.isEmpty {
            print("  (empty)")
            return
        }
        for key in metadata.keys.sorted() {
            print("  \(key) = \(metadata[key] ?? "")")
        }
    }

    /// Print a `surface.set_metadata` / `surface.clear_metadata` result.
    func printMetadataResult(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let applied = payload["applied"] as? [String: Any] ?? [:]
        let reasons = payload["reasons"] as? [String: Any] ?? [:]
        var parts = ["OK"]
        if let handle = formatHandle(payload, kind: "panel", idFormat: idFormat) {
            parts.append(handle)
        }
        print(parts.joined(separator: " "))
        for key in applied.keys.sorted() {
            let ok = (applied[key] as? Bool) == true
            if ok {
                print("  \(key): applied")
            } else {
                let reason = (reasons[key] as? String) ?? "not_applied"
                print("  \(key): skipped (\(reason))")
            }
        }
    }
}
