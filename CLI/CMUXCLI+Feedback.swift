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

    func runFeedback(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let (emailOpt, rem0) = parseOption(commandArgs, name: "--email")
        let (bodyOpt, rem1) = parseOption(rem0, name: "--body")
        let (imagePaths, rem2) = parseRepeatedOption(rem1, name: "--image")
        let remaining = rem2.filter { $0 != "--" }

        if let unknown = remaining.first {
            throw CLIError(message: "feedback: unknown flag '\(unknown)'. Known flags: --email <email>, --body <text>, --image <path>")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        if emailOpt == nil && bodyOpt == nil && imagePaths.isEmpty {
            var params: [String: Any] = [:]
            let env = ProcessInfo.processInfo.environment
            if let workspaceId = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceId.isEmpty {
                params["workspace_id"] = workspaceId
                params["activate"] = false
            } else {
                params["activate"] = true
            }
            let response = try client.sendV2(method: "feedback.open", params: params)
            if jsonOutput {
                print(jsonString(response))
            } else {
                print("OK")
            }
            return
        }

        guard let email = emailOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.isEmpty == false else {
            throw CLIError(message: "feedback requires --email <email> when sending feedback")
        }
        guard let body = bodyOpt, body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CLIError(message: "feedback requires --body <text> when sending feedback")
        }

        let resolvedImages = imagePaths.map(resolvePath)
        let response = try client.sendV2(method: "feedback.submit", params: [
            "email": email,
            "body": body,
            "image_paths": resolvedImages,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    func runShortcuts(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        let verb = remaining.first
        let words = Array(remaining.dropFirst())

        var params: [String: Any] = [:]
        let method: String
        switch verb {
        case nil:
            method = "settings.open"
            params = ["target": "keyboardShortcuts", "activate": true]
        case "list":
            if let extra = words.first(where: { $0 != "--customized" }) {
                throw CLIError(message: "shortcuts list: unexpected argument '\(extra)'")
            }
            method = "settings.shortcuts.list"
            if words.contains("--customized") { params = ["customized": true] }
        case "set":
            guard words.count == 2 else {
                throw CLIError(message: "Usage: c11 shortcuts set <action> <combo|none>")
            }
            method = "settings.shortcuts.set"
            params = ["action": words[0], "shortcut": words[1]]
        case "reset":
            if words == ["--all"] {
                params = ["all": true]
            } else if words.count == 1, !words[0].hasPrefix("-") {
                params = ["action": words[0]]
            } else {
                throw CLIError(message: "Usage: c11 shortcuts reset <action> | --all")
            }
            method = "settings.shortcuts.reset"
        case let other?:
            throw CLIError(message: "shortcuts: unknown verb or flag '\(other)'; see c11 shortcuts --help")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: verb == nil
        )
        defer { client.close() }

        let response = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(response))
            return
        }

        switch verb {
        case nil:
            print("OK")
        case "set":
            printShortcutRow(response)
        default:
            let rows = response["shortcuts"] as? [[String: Any]] ?? []
            if rows.isEmpty, verb == "list" {
                print("No customized shortcuts")
            }
            rows.forEach(printShortcutRow)
        }
    }

    private func printShortcutRow(_ row: [String: Any]) {
        print(shortcutLine(row))
        let conflicts = row["conflicts"] as? [String] ?? []
        if !conflicts.isEmpty {
            print("warning: \(row["display"] as? String ?? "") is also bound to \(conflicts.joined(separator: ", ")); only one of them fires")
        }
    }

    private func shortcutLine(_ row: [String: Any]) -> String {
        let action = row["action"] as? String ?? "?"
        let display = row["display"] as? String ?? "?"
        let combo = row["shortcut"] as? String ?? "?"
        var line = "\(action.padding(toLength: max(32, action.count + 1), withPad: " ", startingAt: 0))"
            + "\(display.padding(toLength: max(8, display.count + 1), withPad: " ", startingAt: 0))\(combo)"
        if row["customized"] as? Bool == true {
            line += "  (default \(row["default_display"] as? String ?? "?"))"
        }
        return line
    }
}
