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

    func parseWindows(_ response: String) -> [WindowInfo] {
        guard response != "No windows" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let key = raw.hasPrefix("*")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2 else { return nil }
                let indexText = parts[0].replacingOccurrences(of: ":", with: "")
                guard let index = Int(indexText) else { return nil }
                let id = parts[1]

                var selectedWorkspaceId: String?
                var workspaceCount: Int = 0
                for token in parts.dropFirst(2) {
                    if token.hasPrefix("selected_workspace=") {
                        let v = token.replacingOccurrences(of: "selected_workspace=", with: "")
                        selectedWorkspaceId = (v == "none") ? nil : v
                    } else if token.hasPrefix("workspaces=") {
                        let v = token.replacingOccurrences(of: "workspaces=", with: "")
                        workspaceCount = Int(v) ?? 0
                    }
                }

                return WindowInfo(
                    index: index,
                    id: id,
                    key: key,
                    selectedWorkspaceId: selectedWorkspaceId,
                    workspaceCount: workspaceCount
                )
            }
    }

    func parseNotifications(_ response: String) -> [NotificationInfo] {
        guard response != "No notifications" else { return [] }
        return response
            .split(separator: "\n")
            .compactMap { line in
                let raw = String(line)
                let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let payload = parts[1].split(separator: "|", maxSplits: 6, omittingEmptySubsequences: false)
                guard payload.count >= 7 else { return nil }
                let notifId = String(payload[0])
                let workspaceId = String(payload[1])
                let surfaceRaw = String(payload[2])
                let surfaceId = surfaceRaw == "none" ? nil : surfaceRaw
                let readText = String(payload[3])
                let title = String(payload[4])
                let subtitle = String(payload[5])
                let body = String(payload[6])
                return NotificationInfo(
                    id: notifId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    isRead: readText == "read",
                    title: title,
                    subtitle: subtitle,
                    body: body
                )
            }
    }

    func resolveWorkspaceId(_ raw: String?, client: SocketClient) throws -> String {
        // An explicit empty value almost always means an unset env var leaked
        // into `--workspace ""`. Refuse to fall back to the focused workspace —
        // that silent fallback has landed agent work on the wrong tab. Pass a
        // real ref or omit the flag.
        if let raw, raw.isEmpty {
            throw CLIError(message: "--workspace received an empty value (likely from an unset shell variable). Pass a real ref or omit the flag.")
        }
        if let raw, client.scopedWindow != nil {
            let listed = try client.sendV2(method: "workspace.list")
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            for item in items {
                let id = item["id"] as? String
                let ref = item["ref"] as? String
                if id?.caseInsensitiveCompare(raw) == .orderedSame
                    || ref.map(Self.canonicalHandle) == Self.canonicalHandle(raw)
                    || (Int(raw) != nil && intFromAny(item["index"]) == Int(raw)),
                   let id {
                    return id
                }
            }
            throw CLIError(message: "not_found: " + String(localized: "cli.window.scope.workspaceNotFound", defaultValue: "Workspace not found in scoped window") + ": \(raw)")
        }
        if let raw, isUUID(raw) {
            return raw
        }
        if let raw, isHandleRef(raw) {
            // Resolve ref to UUID — search across all windows
            let windows = try client.sendV2(method: "window.list")
            let windowList = windows["windows"] as? [[String: Any]] ?? []
            for window in windowList {
                guard let windowId = window["id"] as? String else { continue }
                let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowId])
                let items = listed["workspaces"] as? [[String: Any]] ?? []
                for item in items where (item["ref"] as? String).map(Self.canonicalHandle) == Self.canonicalHandle(raw) {
                    if let id = item["id"] as? String { return id }
                }
            }
            throw CLIError(message: "not_found: Workspace ref not found: \(raw)")
        }

        if let raw, let index = Int(raw) {
            let listed = try client.sendV2(method: "workspace.list")
            let items = listed["workspaces"] as? [[String: Any]] ?? []
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "not_found: Workspace index not found: \(raw)")
        }

        // A supplied value that is not a UUID, ref or index is a typo or a stale
        // environment value; only an absent value (nil) means the current workspace.
        if let raw {
            throw CLIError(message: "not_found: " + String(localized: "cli.workspace.handle.invalid", defaultValue: "Invalid workspace handle: \(raw) (expected UUID, ref like workspace:1, or index)"))
        }

        let current = try client.sendV2(method: "workspace.current")
        if let wsId = current["workspace_id"] as? String { return wsId }
        throw CLIError(message: "No workspace selected")
    }

    /// Layout commands require caller scope even when --window is supplied:
    /// a window's selected workspace is never an implicit mutation target.
    func resolveLayoutWorkspaceId(_ raw: String?, client: SocketClient) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let target = raw ?? environment["C11_WORKSPACE_ID"] ?? environment["CMUX_WORKSPACE_ID"] else {
            throw CLIError(message: String(localized: "cli.layout.workspace.required", defaultValue: "Layout commands require --workspace or C11_WORKSPACE_ID; the selected workspace is never used."))
        }
        return try resolveWorkspaceId(target, client: client)
    }

    func resolveSurfaceId(_ raw: String?, workspaceId: String, client: SocketClient) throws -> String {
        // See resolveWorkspaceId — same hazard. Empty string is a programming
        // error, not a request for "focused surface". Fall through to focused
        // is reserved for the nil case where no flag was passed at all.
        _ = try validatedPanelTargetValue(raw, wasProvided: raw != nil)
        if let raw, client.scopedWindow != nil, !isUUID(raw), !isHandleRef(raw), Int(raw) == nil {
            throw CLIError(message: "not_found: " + String(localized: "cli.window.scope.workspaceTabNotFound", defaultValue: "Panel not found in scoped workspace") + ": \(raw)")
        }
        if let raw, isUUID(raw) {
            if client.scopedWindow != nil {
                let listed = try client.sendV2(method: "panel.list", params: ["workspace_id": workspaceId])
                let items = listed["panels"] as? [[String: Any]] ?? []
                guard items.contains(where: { ($0["id"] as? String)?.caseInsensitiveCompare(raw) == .orderedSame }) else {
                    throw CLIError(message: "not_found: " + String(localized: "cli.window.scope.workspaceTabNotFound", defaultValue: "Panel not found in scoped workspace"))
                }
            }
            return raw
        }
        if let raw, isHandleRef(raw) {
            let listed = try client.sendV2(method: "panel.list", params: ["workspace_id": workspaceId])
            let items = listed["panels"] as? [[String: Any]] ?? []
            for item in items where (item["ref"] as? String).map(Self.canonicalHandle) == Self.canonicalHandle(raw) {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "not_found: Panel ref not found: \(raw)")
        }

        let listed = try client.sendV2(method: "panel.list", params: ["workspace_id": workspaceId])
        let items = listed["panels"] as? [[String: Any]] ?? []

        if let raw, let index = Int(raw) {
            for item in items where intFromAny(item["index"]) == index {
                if let id = item["id"] as? String { return id }
            }
            throw CLIError(message: "not_found: Panel index not found: \(raw)")
        }

        if let raw {
            throw CLIError(message: "not_found: " + String(localized: "cli.panel.handle.invalid", defaultValue: "Invalid panel handle: \(raw) (expected UUID, ref like panel:1, or index)"))
        }

        if let focused = items.first(where: { ($0["focused"] as? Bool) == true }) {
            if let id = focused["id"] as? String { return id }
        }

        throw CLIError(message: "Unable to resolve panel ID")
    }
}
