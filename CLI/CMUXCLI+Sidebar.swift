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

    func forwardSidebarMetadataCommand(
        _ socketCommand: String,
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> String {
        func insertArgumentBeforeSeparator(_ value: String, into args: inout [String]) {
            if let separatorIndex = args.firstIndex(of: "--") {
                args.insert(value, at: separatorIndex)
            } else {
                args.append(value)
            }
        }

        var forwardedArgs: [String] = []
        var resolvedExplicitWorkspace = false
        var resolvedWorkspaceId: String?
        // C11-171: a raw (unresolved) surface ref carried through from the
        // command line, held until the workspace it resolves against is known.
        var pendingSurfaceRaw: String?
        // True when the pending ref came from `--tab` (not `--surface` / `--panel`).
        var pendingFromTabFlag = false
        var index = 0

        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--workspace", index + 1 < commandArgs.count {
                let workspaceId = try resolveWorkspaceId(commandArgs[index + 1], client: client)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                resolvedWorkspaceId = workspaceId
                index += 2
                continue
            }
            if arg.hasPrefix("--workspace=") {
                let rawWorkspace = String(arg.dropFirst("--workspace=".count))
                let workspaceId = try resolveWorkspaceId(rawWorkspace, client: client)
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                resolvedWorkspaceId = workspaceId
                index += 1
                continue
            }
            // C11-171: capture the surface/panel ref (do not forward it raw); it
            // is resolved to a uuid and re-emitted once the workspace is known so
            // the app can mirror canonical status/progress onto the right surface.
            if Self.isFlag(arg, "--panel"), index + 1 < commandArgs.count {
                pendingSurfaceRaw = commandArgs[index + 1]
                pendingFromTabFlag = arg == "--tab"
                index += 2
                continue
            }
            if arg.hasPrefix("--surface=") {
                pendingSurfaceRaw = String(arg.dropFirst("--surface=".count))
                pendingFromTabFlag = false
                index += 1
                continue
            }
            if arg.hasPrefix("--tab=") {
                pendingSurfaceRaw = String(arg.dropFirst("--tab=".count))
                pendingFromTabFlag = true
                index += 1
                continue
            }
            if arg.hasPrefix("--panel=") {
                pendingSurfaceRaw = String(arg.dropFirst("--panel=".count))
                pendingFromTabFlag = false
                index += 1
                continue
            }
            forwardedArgs.append(arg)
            index += 1
        }

        // `--tab` once named a workspace on these commands. A workspace-shaped value
        // (`workspace:N`, or the UUID of a workspace) keeps that meaning and is exactly
        // `--workspace`; `tab:N`, `surface:N` and any other UUID stay a tab. A bare
        // integer is ambiguous between the two, so it must be disambiguated.
        if pendingFromTabFlag, !resolvedExplicitWorkspace, let rawTab = pendingSurfaceRaw {
            let trimmed = rawTab.trimmingCharacters(in: .whitespacesAndNewlines)
            var asWorkspace: String?
            if trimmed.lowercased().hasPrefix("workspace:") {
                asWorkspace = try resolveWorkspaceId(trimmed, client: client)
            } else if isUUID(trimmed), try isWorkspaceUUID(trimmed, client: client) {
                asWorkspace = try resolveWorkspaceId(trimmed, client: client)
            } else if Int(trimmed) != nil {
                throw CLIError(message: "ambiguous --tab \(trimmed): use --workspace \(trimmed) or panel:\(trimmed)")
            }
            if let workspaceId = asWorkspace {
                forwardedArgs.append("--tab=\(workspaceId)")
                resolvedExplicitWorkspace = true
                resolvedWorkspaceId = workspaceId
                pendingSurfaceRaw = nil
            }
        }

        if !resolvedExplicitWorkspace,
           let workspaceArg = sidebarWorkspaceFromEnv() {
            let workspaceId = try resolveWorkspaceId(workspaceArg, client: client)
            insertArgumentBeforeSeparator("--tab=\(workspaceId)", into: &forwardedArgs)
            resolvedWorkspaceId = workspaceId
        }
        // v1 sidebar commands have no window parameter and never use the selected
        // workspace: a global --window alone is not a target.
        if resolvedWorkspaceId == nil {
            throw CLIError(message: String(localized: "cli.sidebar.target.required", defaultValue: "sidebar command requires --workspace or C11_WORKSPACE_ID; it will not use the selected workspace"))
        }

        // C11-171: resolve an explicit surface ref against the resolved workspace
        // and forward it as a uuid, so the app mirrors the canonical key onto the
        // agent's own surface rather than falling back to the focused one.
        if let pendingSurfaceRaw {
            // A named tab is never dropped: without a workspace to resolve it in, the
            // command would silently act on the operator's selected workspace.
            guard let resolvedWorkspaceId else {
                throw CLIError(message: "--panel <ref> needs a workspace; pass --workspace or run inside a c11 panel")
            }
            let surfaceId = try resolveSurfaceId(pendingSurfaceRaw, workspaceId: resolvedWorkspaceId, client: client)
            insertArgumentBeforeSeparator("--surface=\(surfaceId)", into: &forwardedArgs)
        }

        let command = ([socketCommand] + forwardedArgs)
            .map(shellQuote)
            .joined(separator: " ")
        return try sendV1Command(command, client: client)
    }

    /// Resolve only explicit workspace context for sidebar commands. CMUX is
    /// retained as a hidden compatibility alias; current selection is never a
    /// fallback for commands that require a workspace target.
    func sidebarWorkspaceFromEnv() -> String? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["C11_WORKSPACE_ID", "CMUX_WORKSPACE_ID"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// True when `uuid` names a workspace in any window (as opposed to a tab).
    func isWorkspaceUUID(_ uuid: String, client: SocketClient) throws -> Bool {
        let windows = try client.sendV2(method: "window.list")
        for window in windows["windows"] as? [[String: Any]] ?? [] {
            guard let windowId = window["id"] as? String else { continue }
            let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
            for item in listed["workspaces"] as? [[String: Any]] ?? [] {
                if let id = item["id"] as? String, id.caseInsensitiveCompare(uuid) == .orderedSame { return true }
            }
        }
        return false
    }

    /// Pick the display handle for an item dict based on --id-format.
    func textHandle(_ item: [String: Any], idFormat: CLIIDFormat) -> String {
        let ref = item["ref"] as? String
        let id = item["id"] as? String
        switch idFormat {
        case .refs:  return ref ?? id ?? "?"
        case .uuids: return id ?? ref ?? "?"
        case .both:  return [ref, id].compactMap({ $0 }).joined(separator: " ")
        }
    }

    func resolvedCreateInput(raw: String?, panelType: String?, hasLayout: Bool = false) throws -> String? {
        let decision = CreateInitialInput.decide(raw: raw, panelType: panelType, hasLayout: hasLayout)
        if let message = decision.errorMessage(panelType: panelType) { throw CLIError(message: message) }
        guard let input = decision.queuedInput else { return nil }
        return try CapabilityFeatures.current.dispatch(.initialInput) { input }
    }

    func createOKSummary(_ payload: [String: Any], idFormat: CLIIDFormat,
                                 kinds: [String] = ["panel", "workspace"]) -> String {
        let summary = v2OKSummary(payload, idFormat: idFormat, kinds: kinds)
        guard payload["initial_input"] as? String == "queued" else { return summary }
        return summary + " input=queued"
    }

    func v2OKSummary(_ payload: [String: Any], idFormat: CLIIDFormat, kinds: [String] = ["panel", "workspace"]) -> String {
        var parts = ["OK"]
        for kind in kinds {
            if let handle = formatHandle(payload, kind: kind, idFormat: idFormat) {
                parts.append(handle)
            }
        }
        if let startup = payload["startup"] as? String {
            parts.append("startup=\(startup)")
        }
        return parts.joined(separator: " ")
    }
}
