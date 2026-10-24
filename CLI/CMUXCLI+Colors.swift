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

    func runWorkspaceColor(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let first = commandArgs.first else {
            throw CLIError(message: "workspace-color requires a subcommand. Try: c11 workspace-color get")
        }
        let sub = first.lowercased()
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "set":
            try runWorkspaceColorSet(args: rest, client: client, jsonOutput: jsonOutput)
        case "clear":
            try runWorkspaceColorClear(args: rest, client: client, jsonOutput: jsonOutput)
        case "get":
            try runWorkspaceColorGet(args: rest, client: client, jsonOutput: jsonOutput)
        case "list-palette":
            try runWorkspaceColorListPalette(client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "Unknown workspace-color subcommand: \(first)")
        }
    }

    func runWorkspaceColorSet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, rest) = parseOption(args, name: "--workspace")
        let positional = rest.filter { !$0.hasPrefix("-") }
        guard let hex = positional.first else {
            throw CLIError(message: "workspace-color set <palette-name|#RRGGBB> [--workspace <ref>] (quote hex starting with '#': c11 workspace-color set \"#RRGGBB\")")
        }
        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        var params: [String: Any] = ["hex": hex]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        let response = try client.sendV2(method: "workspace.set_custom_color", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            let applied = response["hex"] as? String ?? hex
            print("OK workspace_color=\(applied)")
        }
    }

    func runWorkspaceColorClear(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, _) = parseOption(args, name: "--workspace")
        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        var params: [String: Any] = ["clear": true]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        let response = try client.sendV2(method: "workspace.set_custom_color", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK workspace color cleared")
        }
    }

    func runWorkspaceColorGet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, _) = parseOption(args, name: "--workspace")
        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        let response = try client.sendV2(method: "workspace.list")
        guard let workspaces = response["workspaces"] as? [[String: Any]] else {
            throw CLIError(message: "workspace-color get: unexpected workspace.list response")
        }
        let match = workspaces.first {
            ($0["id"] as? String) == workspaceHandle || ($0["ref"] as? String) == workspaceHandle
        } ?? workspaces.first { ($0["selected"] as? Bool) == true }
        if jsonOutput {
            print(jsonString(match ?? [:]))
            return
        }
        if let color = match?["color_hex"] as? String {
            print("color: \(color)")
        } else if let color = match?["custom_color"] as? String {
            print("color: \(color)")
        } else {
            print("color: (none)")
        }
    }

    func runWorkspaceColorListPalette(client _: SocketClient, jsonOutput: Bool) throws {
        // Shared with the app (`DefaultColorPalette`): the names `set-panel-color`,
        // `panel-color set`, `workspace-color set` and blueprints resolve. Operator
        // overrides can change a name's hex; the names are fixed.
        let palette = DefaultColorPalette.entries.map { ($0.name.lowercased(), $0.hex) }
        if jsonOutput {
            print(jsonString(["palette": palette.map { ["name": $0.0, "default_hex": $0.1] }]))
            return
        }
        for (name, hex) in palette {
            print("\(name)  \(hex)")
        }
    }

    func resolveCurrentWorkspaceId(client: SocketClient) throws -> String {
        if let id = try normalizeWorkspaceHandle(nil, client: client, allowCurrent: true) {
            return id
        }
        throw CLIError(message: "No current workspace available")
    }

    func resolveWorkspaceColorTarget(_ raw: String?, client: SocketClient) throws -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "@current" || value == "@focused" {
            return try normalizeWorkspaceHandle(nil, client: client, allowCurrent: true)
        }
        if value == nil || value?.isEmpty == true {
            // No --workspace flag: prefer caller's env workspace so commands launched
            // from an unfocused surface still target the caller's own workspace
            // (matches the env-first pattern used at CLI/c11.swift:1762 'identify').
            let env = ProcessInfo.processInfo.environment
            if let envWs = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envWs.isEmpty {
                return try normalizeWorkspaceHandle(envWs, client: client)
            }
            if let envWs = env["C11_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envWs.isEmpty {
                return try normalizeWorkspaceHandle(envWs, client: client)
            }
            return try normalizeWorkspaceHandle(nil, client: client, allowCurrent: true)
        }
        return try normalizeWorkspaceHandle(value, client: client)
    }

    // MARK: - `c11 surface-color` (C11-10)
    //
    // Per-surface tab color: identifies a single surface tab in a pane,
    // distinct from the workspace-level chrome accent. Help text says
    // "surface tab in a pane" to disambiguate from workspace tabs.

    func runSurfaceColor(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let first = commandArgs.first else {
            throw CLIError(message: "panel-color requires a subcommand. Try: c11 panel-color get (operates on the panel in an area)")
        }
        let sub = first.lowercased()
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "set":
            try runSurfaceColorSet(args: rest, client: client, jsonOutput: jsonOutput)
        case "clear":
            try runSurfaceColorClear(args: rest, client: client, jsonOutput: jsonOutput)
        case "get":
            try runSurfaceColorGet(args: rest, client: client, jsonOutput: jsonOutput)
        case "list-palette":
            // Shares the workspace-color palette — same list, same names.
            try runWorkspaceColorListPalette(client: client, jsonOutput: jsonOutput)
        default:
            throw CLIError(message: "Unknown panel-color subcommand: \(first)")
        }
    }

    func runSurfaceColorSet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, rest1) = parseOption(args, name: "--workspace")
        let (surfaceOpt, rest2) = parseOption(rest1, name: "--panel")
        let positional = rest2.filter { !$0.hasPrefix("-") }
        guard let hex = positional.first else {
            throw CLIError(message: "panel-color set <hex|palette-name> [--workspace <ref>] [--panel <ref>] (quote hex starting with '#': c11 panel-color set \"#RRGGBB\")")
        }

        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        let surfaceRef = surfaceOpt ?? Self.callerPanelEnv()
        let surfaceId = try resolveSurfaceId(
            surfaceRef,
            workspaceId: workspaceHandle ?? (try resolveCurrentWorkspaceId(client: client)),
            client: client
        )

        var params: [String: Any] = ["hex": hex, "panel_id": surfaceId]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        let response = try client.sendV2(method: "panel.set_custom_color", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            let applied = response["custom_color"] as? String ?? hex
            print("OK panel_color=\(applied)")
        }
    }

    func runSurfaceColorClear(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, rest1) = parseOption(args, name: "--workspace")
        let (surfaceOpt, rest2) = parseOption(rest1, name: "--panel")
        let extras = rest2.filter { !$0.hasPrefix("-") }
        if !extras.isEmpty {
            throw CLIError(message: "panel-color clear takes no positional arguments. Use 'panel-color set <palette-name|#RRGGBB>' to set a color.")
        }
        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        let surfaceRef = surfaceOpt ?? Self.callerPanelEnv()
        let surfaceId = try resolveSurfaceId(
            surfaceRef,
            workspaceId: workspaceHandle ?? (try resolveCurrentWorkspaceId(client: client)),
            client: client
        )

        var params: [String: Any] = ["clear": true, "panel_id": surfaceId]
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        let response = try client.sendV2(method: "panel.set_custom_color", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK panel color cleared")
        }
    }

    func runSurfaceColorGet(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (workspaceOpt, rest1) = parseOption(args, name: "--workspace")
        let (surfaceOpt, _) = parseOption(rest1, name: "--panel")
        let workspaceHandle = try resolveWorkspaceColorTarget(workspaceOpt, client: client)
        let resolvedWorkspaceId = try workspaceHandle ?? resolveCurrentWorkspaceId(client: client)
        let surfaceRef = surfaceOpt ?? Self.callerPanelEnv()
        let surfaceId = try resolveSurfaceId(
            surfaceRef,
            workspaceId: resolvedWorkspaceId,
            client: client
        )

        let response = try client.sendV2(method: "panel.list", params: ["workspace_id": resolvedWorkspaceId])
        let items = (response["panels"] as? [[String: Any]]) ?? []
        guard let match = items.first(where: { ($0["id"] as? String) == surfaceId }) else {
            // Match the v2 server's not_found semantics. resolveSurfaceId short-circuits
            // any UUID-shaped string without validating membership, so a stale or wrong
            // UUID would otherwise print 'color: (none)' and exit 0 — silently lying.
            throw CLIError(message: "Panel not found: \(surfaceRef ?? surfaceId)")
        }

        if jsonOutput {
            print(jsonString(match))
            return
        }
        if let color = match["custom_color"] as? String {
            print("color: \(color)")
        } else {
            print("color: (none)")
        }
    }
}
