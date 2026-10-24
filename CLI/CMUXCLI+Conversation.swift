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

    /// `c11 conversation <capture-runtime|claim|push|tombstone|list|get|clear>` — wraps the
    /// `conversation.*` v2 socket methods.
    ///
    /// Per the C11-24 plan: every verb resolves `--surface` from
    /// `CMUX_SURFACE_ID` if unset. **No focused-fallback** — that path is
    /// the silent-misroute footgun the architecture exists to fix. If the
    /// env var is missing and no flag was given, error out cleanly.
    func runConversationCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let subArgs = Array(commandArgs.dropFirst())

        switch subcommand {
        case "capture-runtime":
            try runConversationCaptureRuntime(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "claim":
            try runConversationClaim(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "push":
            try runConversationPush(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "tombstone":
            try runConversationTombstone(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "list":
            try runConversationList(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "get":
            try runConversationGet(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "clear":
            try runConversationClear(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "resume":
            try runConversationResume(subArgs: subArgs, client: client, jsonOutput: jsonOutput)
        case "help", "--help", "-h":
            print(conversationUsage())
        default:
            throw CLIError(message: "Unknown conversation subcommand: \(subcommand)")
        }
    }

    func conversationUsage() -> String {
        return """
        Usage: c11 conversation <subcommand> [flags]

        Subcommands:
          capture-runtime
          claim --kind <k> [--cwd <path>] [--id <id>]
                [--expected-resume-id <uuid>] [--ttl-ms <n>]
          push --kind <k> --id <id> --source <hook|scrape|manual>
               [--state <alive|suspended|tombstoned|unknown|ended>]
               [--cwd <path>] [--reason <text>]
               [--payload <json> | --payload @<path>]
          tombstone --kind <k> --id <id> [--reason <text>]
          list [--panel <id>] [--json]
          get [--panel <id>] [--json]
          clear [--panel <id>]
          resume (--panel <id> | --all-skipped) [--dry-run] [--json]
                 Rerun this launch's resume decision and type the command
                 only into panels nobody has used since launch.

        --panel defaults to $C11_PANEL_ID for every subcommand except
        resume, which needs it explicitly. There is NO focused-panel
        fallback; commands error out if the env var is missing and no flag
        was given.
        """
    }

    /// Resolve the target process's c11 surface identity. This command is a
    /// cooperative causal-report rail: the target Codex process invokes it
    /// from its own tool subprocess, so identities must come from that
    /// subprocess's environment rather than caller-supplied arguments.
    func resolveCallingSurface(environment: [String: String]) throws -> String? {
        // Same key order as `callerTabEnv`, compared per prefix.
        let canonicalValue = Self.callerPanelEnv(environment.filter { $0.key.hasPrefix("C11_") })
        let compatValue = Self.callerPanelEnv(environment.filter { $0.key.hasPrefix("CMUX_") })

        if let canonicalValue, let compatValue, canonicalValue != compatValue {
            throw CLIError(message: "surface_env_mismatch: the C11_PANEL_ID and CMUX_* panel environment variables disagree")
        }
        guard let surface = canonicalValue ?? compatValue else { return nil }
        guard UUID(uuidString: surface) != nil else {
            throw CLIError(message: "invalid_surface: runtime panel environment must contain a UUID")
        }
        return surface
    }

    func addCallingPanel(to params: inout [String: Any]) throws {
        do {
            if let panelId = try resolveCallingSurface(environment: ProcessInfo.processInfo.environment) {
                params["caller_panel_id"] = panelId
            }
        } catch let error as CLIError
            where error.message.hasPrefix("surface_env_mismatch:") || error.message.hasPrefix("invalid_surface:") {
            // A stale or conflicting caller environment must not prevent a
            // panel-creation command that worked outside c11 from succeeding.
            // Without one unambiguous UUID, create the panel as a root.
            return
        }
    }

    func resolveRuntimeConversationSurface(environment: [String: String]) throws -> String {
        guard let surface = try resolveCallingSurface(environment: environment) else {
            throw CLIError(message: "missing_surface: C11_PANEL_ID required")
        }
        return surface
    }

    func runConversationCaptureRuntime(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard subArgs.isEmpty else {
            throw CLIError(message: "capture-runtime accepts no arguments; identity, panel, and cwd come from the target subprocess")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let rawThreadId = environment["CODEX_THREAD_ID"] else {
            throw CLIError(message: "missing_runtime_id: CODEX_THREAD_ID required")
        }
        let threadId = rawThreadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadId.isEmpty else {
            throw CLIError(message: "missing_runtime_id: CODEX_THREAD_ID required")
        }
        guard UUID(uuidString: threadId) != nil else {
            throw CLIError(message: "invalid_runtime_id: CODEX_THREAD_ID must be a UUID")
        }
        let surface = try resolveRuntimeConversationSurface(environment: environment)
        let cwd = FileManager.default.currentDirectoryPath
        let response = try client.sendV2(
            method: "conversation.capture_runtime",
            params: [
                "panel_id": surface,
                "id": threadId,
                "cwd": cwd
            ],
            deadline: .custom(0.75)
        )
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK conversation.capture-runtime kind=codex panel=\(surface)")
        }
    }

    /// Resolve `--surface` strictly — env-var or flag, no focused fallback.
    /// Returns the raw surface handle; the server resolves it to a UUID.
    func resolveConversationSurface(_ args: [String]) throws -> String {
        if let raw = optionValue(args, name: "--panel") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let envRaw = Self.callerPanelEnv()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envRaw.isEmpty {
            return envRaw
        }
        throw CLIError(message: "missing_surface: --panel flag or C11_PANEL_ID env var required (no focused-fallback)")
    }

    /// `--payload <json>` or `--payload @<path>` (mirrors HOOKS_FILE in
    /// Resources/bin/claude). Returns parsed JSON object or nil.
    func readConversationPayload(_ args: [String]) throws -> [String: Any]? {
        guard let raw = optionValue(args, name: "--payload") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let jsonText: String
        if trimmed.hasPrefix("@") {
            let path = String(trimmed.dropFirst())
            do {
                jsonText = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw CLIError(message: "payload_file_unreadable: \(path): \(error.localizedDescription)")
            }
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw CLIError(message: "invalid_json: --payload is not valid UTF-8")
        }
        let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw CLIError(message: "invalid_json: --payload must be a JSON object")
        }
        return dict
    }

    func runConversationClaim(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let kind = optionValue(subArgs, name: "--kind"),
              !kind.isEmpty else {
            throw CLIError(message: "claim requires --kind <kind>")
        }
        let surface = try resolveConversationSurface(subArgs)
        var params: [String: Any] = [
            "panel_id": surface,
            "kind": kind
        ]
        if let cwd = optionValue(subArgs, name: "--cwd") { params["cwd"] = cwd }
        if let id = optionValue(subArgs, name: "--id") { params["placeholder_id"] = id }
        if let expectedResumeId = optionValue(subArgs, name: "--expected-resume-id") {
            guard UUID(uuidString: expectedResumeId) != nil else {
                throw CLIError(message: "--expected-resume-id must be a UUID")
            }
            params["expected_resume_id"] = expectedResumeId
        }
        if subArgs.contains("--ttl-ms") {
            guard let rawTTL = optionValue(subArgs, name: "--ttl-ms"),
                  let ttlMilliseconds = Int64(rawTTL), ttlMilliseconds > 0 else {
                throw CLIError(message: "--ttl-ms requires a positive integer")
            }
            let nowMilliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
            guard ttlMilliseconds <= Int64.max - nowMilliseconds else {
                throw CLIError(message: "--ttl-ms is too large")
            }
            params["expires_at_epoch_ms"] = nowMilliseconds + ttlMilliseconds
        }
        let payload = try client.sendV2(method: "conversation.claim", params: params)
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print("OK conversation.claim kind=\(kind) panel=\(surface)")
        }
    }

    func runConversationPush(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let kind = optionValue(subArgs, name: "--kind"),
              !kind.isEmpty else {
            throw CLIError(message: "push requires --kind <kind>")
        }
        guard let id = optionValue(subArgs, name: "--id"),
              !id.isEmpty else {
            throw CLIError(message: "push requires --id <id>")
        }
        guard let source = optionValue(subArgs, name: "--source"),
              !source.isEmpty else {
            throw CLIError(message: "push requires --source <hook|scrape|manual>")
        }
        let allowedSources: Set<String> = ["hook", "scrape", "manual"]
        guard allowedSources.contains(source) else {
            throw CLIError(
                message: "--source must be one of: \(allowedSources.sorted().joined(separator: ", ")); runtimeEnv is reserved for conversation capture-runtime"
            )
        }
        let surface = try resolveConversationSurface(subArgs)
        var params: [String: Any] = [
            "panel_id": surface,
            "kind": kind,
            "id": id,
            "source": source
        ]
        if let state = optionValue(subArgs, name: "--state") {
            // C11-24 review (I2): mirror the server-side strict validation
            // so typos fail at the CLI boundary instead of round-tripping
            // to the socket only to come back with `invalid_state`.
            let allowed: Set<String> = ["alive", "suspended", "ended", "tombstoned", "unknown", "unsupported"]
            guard allowed.contains(state.lowercased()) else {
                throw CLIError(message: "--state must be one of: \(allowed.sorted().joined(separator: ", "))")
            }
            params["state"] = state.lowercased()
        }
        if let cwd = optionValue(subArgs, name: "--cwd") { params["cwd"] = cwd }
        if let reason = optionValue(subArgs, name: "--reason") { params["diagnostic_reason"] = reason }
        if let payloadObj = try readConversationPayload(subArgs) {
            params["payload"] = payloadObj
        }
        let response = try client.sendV2(method: "conversation.push", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK conversation.push kind=\(kind) panel=\(surface) source=\(source)")
        }
    }

    func runConversationTombstone(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let kind = optionValue(subArgs, name: "--kind"),
              !kind.isEmpty else {
            throw CLIError(message: "tombstone requires --kind <kind>")
        }
        guard let id = optionValue(subArgs, name: "--id"),
              !id.isEmpty else {
            throw CLIError(message: "tombstone requires --id <id>")
        }
        let surface = try resolveConversationSurface(subArgs)
        var params: [String: Any] = [
            "panel_id": surface,
            "kind": kind,
            "id": id
        ]
        if let reason = optionValue(subArgs, name: "--reason") { params["reason"] = reason }
        let response = try client.sendV2(method: "conversation.tombstone", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK conversation.tombstone kind=\(kind) panel=\(surface)")
        }
    }

    func runConversationList(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        var params: [String: Any] = [:]
        if let s = optionValue(subArgs, name: "--panel") { params["panel_id"] = s }
        // C11-24 review (I3): --workspace is not implemented in v1. The
        // store doesn't track per-workspace partitioning today; the
        // server has been silently ignoring `workspace_id` and returning
        // every conversation across every workspace. Reject explicitly
        // rather than lying about the filter; revisit in v1.1 if the
        // store grows workspace partitioning.
        if optionValue(subArgs, name: "--workspace") != nil {
            throw CLIError(message: "--workspace is not supported in v1; conversations are stored process-wide. Filter with --panel instead.")
        }
        let response = try client.sendV2(method: "conversation.list", params: params)
        if jsonOutput || hasFlag(subArgs, name: "--json") {
            print(jsonString(response))
            return
        }
        let entries = response["conversations"] as? [[String: Any]] ?? []
        if entries.isEmpty {
            print("(no conversations)")
            return
        }
        for entry in entries {
            let kind = entry["kind"] as? String ?? "?"
            let id = entry["id"] as? String ?? "?"
            let state = entry["state"] as? String ?? "?"
            let surface = entry["panel_id"] as? String ?? "?"
            print("\(surface)  \(kind)  \(id)  [\(state)]")
        }
    }

    func runConversationGet(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let surface = try resolveConversationSurface(subArgs)
        let params: [String: Any] = ["panel_id": surface]
        let response = try client.sendV2(method: "conversation.get", params: params)
        if jsonOutput || hasFlag(subArgs, name: "--json") {
            print(jsonString(response))
            return
        }
        guard let active = response["active"] as? [String: Any] else {
            print("(no conversation for panel)")
            return
        }
        let kind = active["kind"] as? String ?? "?"
        let id = active["id"] as? String ?? "?"
        let state = active["state"] as? String ?? "?"
        let source = active["captured_via"] as? String ?? "?"
        let reason = active["diagnostic_reason"] as? String ?? ""
        let resumable = (response["can_resume"] as? Bool) ?? false
        print("kind=\(kind) id=\(id) state=\(state) source=\(source) resumable=\(resumable)")
        if !reason.isEmpty {
            print("reason: \(reason)")
        }
    }

    func runConversationClear(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let surface = try resolveConversationSurface(subArgs)
        let params: [String: Any] = ["panel_id": surface]
        let response = try client.sendV2(method: "conversation.clear", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK conversation.clear panel=\(surface)")
        }
    }

    /// C11-468: the agent-drivable recovery for panels this launch did not
    /// resume. The caller names the targets; the app decides per panel.
    func runConversationResume(
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let allSkipped = hasFlag(subArgs, name: "--all-skipped")
        let panel = try validatedPanelTargetValue(
            optionValue(subArgs, name: "--panel"),
            wasProvided: hasFlag(subArgs, name: "--panel")
        )
        guard allSkipped != (panel != nil) else {
            throw CLIError(message: "conversation resume needs exactly one of --panel <ref> or --all-skipped")
        }
        var params: [String: Any] = [
            "all_skipped": allSkipped,
            "dry_run": hasFlag(subArgs, name: "--dry-run"),
        ]
        if let panel { params["panel_id"] = panel }
        let response = try client.sendV2(method: "conversation.resume", params: params)
        if jsonOutput || hasFlag(subArgs, name: "--json") {
            print(jsonString(response))
            return
        }
        let rows = response["panels"] as? [[String: Any]] ?? []
        if rows.isEmpty {
            print("(no skipped panels this launch)")
            return
        }
        for row in rows {
            let panelId = row["panel_id"] as? String ?? "?"
            let kind = row["kind"] as? String ?? "-"
            let outcome = row["outcome"] as? String ?? "?"
            var line = "\(outcome) panel=\(panelId) kind=\(kind)"
            if let code = row["skip_code"] as? String { line += " code=\(code)" }
            if let reason = row["reason"] as? String { line += " reason=\(reason)" }
            if let command = row["command"] as? String, outcome != "scheduled" {
                line += " command=\(command)"
            }
            print(line)
        }
    }
}
