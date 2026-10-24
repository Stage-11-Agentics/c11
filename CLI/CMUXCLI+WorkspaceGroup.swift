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

    /// Strict parsing keeps misspelled or conflicting mutation options from being ignored.
    func parseWorkspaceGroupOptions(
        _ args: [String], values: Set<String>, flags: Set<String>
    ) throws -> (values: [String: String], flags: Set<String>) {
        var parsed: [String: String] = [:]
        var present = Set<String>()
        var index = 0
        while index < args.count {
            let option = args[index]
            guard parsed[option] == nil, !present.contains(option) else {
                throw CLIError(message: String(localized: "cli.workspaceGroup.error.duplicateOption",
                    defaultValue: "Duplicate option: \(option)"))
            }
            if flags.contains(option) {
                present.insert(option)
                index += 1
            } else if values.contains(option) {
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--"),
                      !args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIError(message: String(localized: "cli.workspaceGroup.error.emptyOptionValue",
                        defaultValue: "\(option) requires a nonempty value"))
                }
                parsed[option] = args[index + 1]
                index += 2
            } else {
                throw CLIError(message: String(localized: "cli.workspaceGroup.error.unexpectedArgument",
                    defaultValue: "Unexpected argument: \(option)"))
            }
        }
        return (parsed, present)
    }

    func workspaceGroupWindow(_ raw: String?, client: SocketClient) throws -> String {
        if let raw, let window = try normalizeWindowHandle(raw, client: client) { return window }
        let environment = ProcessInfo.processInfo.environment
        if let workspace = environment["C11_WORKSPACE_ID"] ?? environment["CMUX_WORKSPACE_ID"],
           !workspace.isEmpty {
            let payload = try client.sendV2(method: "workspace.list", params: ["workspace_id": workspace])
            if let window = (payload["window_id"] as? String) ?? (payload["window_ref"] as? String) {
                return window
            }
        }
        guard let window = try normalizeWindowHandle(nil, client: client, allowCurrent: true) else {
            throw CLIError(message: String(localized: "cli.workspaceGroup.error.noCurrentWindow",
                defaultValue: "No current window"))
        }
        return window
    }

    func workspaceGroupRequest(_ method: String, params: [String: Any], client: SocketClient) throws -> [String: Any] {
        do {
            return try client.sendV2(method: method, params: params)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            throw CLIError(message: String(localized: "cli.workspaceGroup.error.unsupportedMethod",
                defaultValue: "\(method) is unavailable: this c11 app does not support workspace groups/batch reorder. Update the app."))
        }
    }

    func normalizeWorkspaceGroupHandle(_ raw: String, window: String, client: SocketClient) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUUID(value) { return value }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "workspace_group", let ordinal = Int(parts[1]), ordinal > 0 else {
            throw CLIError(message: String(localized: "cli.workspaceGroup.error.invalidHandle",
                defaultValue: "Invalid group handle: \(value) (expected UUID or \("workspace_group:N"))"))
        }
        let payload = try workspaceGroupRequest("workspace.group.list", params: ["window_id": window], client: client)
        let groups = payload["workspace_groups"] as? [[String: Any]] ?? []
        guard let group = groups.first(where: { ($0["ref"] as? String) == value }), let id = group["id"] as? String else {
            throw CLIError(message: "group_not_found: " + String(localized: "cli.workspaceGroup.error.groupNotFound",
                defaultValue: "\(value) in window \(window)"))
        }
        return id
    }

    func workspaceGroupWorkspaceIDs(_ raw: String, window: String, client: SocketClient) throws -> [String] {
        let values = raw.split(separator: ",", omittingEmptySubsequences: false)
        return try values.map { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let id = try normalizeWorkspaceHandle(trimmed, client: client, windowHandle: window) else {
                throw CLIError(message: String(localized: "cli.workspaceGroup.error.invalidWorkspaceList",
                    defaultValue: "Workspace lists must be nonempty comma-separated handles"))
            }
            return id
        }
    }

    func runWorkspaceGroup(
        commandArgs: [String], client: SocketClient, jsonOutput: Bool,
        idFormat: CLIIDFormat, windowOverride: String?
    ) throws {
        guard let verb = commandArgs.first else {
            throw CLIError(message: String(localized: "cli.workspaceGroup.error.missingVerb",
                defaultValue: "\("workspace-group") requires a verb; see \("--help")"))
        }
        var values: Set<String> = ["--window"]
        var flags: Set<String> = ["--json"]
        switch verb {
        case "list": break
        case "create": values.insert("--name")
        case "rename": values.formUnion(["--group", "--name"])
        case "delete", "ungroup", "collapse", "expand", "pin", "unpin", "focus": values.insert("--group")
        case "add", "remove": values.formUnion(["--group", "--workspaces"])
        case "move": values.formUnion(["--group", "--workspace", "--to-group", "--before", "--after", "--index"])
        case "set-color": values.formUnion(["--group", "--color"]); flags.insert("--clear")
        case "set-icon": values.formUnion(["--group", "--icon"]); flags.insert("--clear")
        default:
            throw CLIError(message: String(localized: "cli.workspaceGroup.error.unknownVerb",
                defaultValue: "Unknown \("workspace-group") verb: \(verb)"))
        }
        let options = try parseWorkspaceGroupOptions(Array(commandArgs.dropFirst()), values: values, flags: flags)
        func required(_ key: String) throws -> String {
            guard let value = options.values[key] else {
                throw CLIError(message: String(localized: "cli.workspaceGroup.error.missingOption",
                    defaultValue: "\("workspace-group") \(verb) requires \(key)"))
            }
            return value
        }
        let window = try workspaceGroupWindow(options.values["--window"] ?? windowOverride, client: client)
        var params: [String: Any] = ["window_id": window]
        if verb != "list", verb != "create", !(verb == "move" && options.values["--workspace"] != nil) {
            params["group_id"] = try normalizeWorkspaceGroupHandle(required("--group"), window: window, client: client)
        }
        if verb == "create" || verb == "rename" {
            params["name"] = try required("--name").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if verb == "add" || verb == "remove" {
            params["workspace_ids"] = try workspaceGroupWorkspaceIDs(required("--workspaces"), window: window, client: client)
        }
        if verb == "set-color" || verb == "set-icon" {
            let key = verb == "set-color" ? "color" : "icon"
            guard (options.values["--\(key)"] != nil) != options.flags.contains("--clear") else {
                throw CLIError(message: String(localized: "cli.workspaceGroup.error.propertyOrClear",
                    defaultValue: "Specify exactly one of \("--" + key) or \("--clear")"))
            }
            if options.flags.contains("--clear") { params[key] = NSNull() }
            else { params[key] = options.values["--\(key)"]! }
        }
        if verb == "move" {
            let memberMove = options.values["--workspace"] != nil
            let placement = ["--before", "--after", "--index"].filter { options.values[$0] != nil }
            guard placement.count <= 1 else {
                throw CLIError(message: String(localized: "cli.workspaceGroup.error.conflictingPlacement",
                    defaultValue: "Specify only one of \("--before"), \("--after") or \("--index")"))
            }
            if memberMove {
                guard options.values["--group"] == nil, options.values["--index"] == nil else {
                    throw CLIError(message: String(localized: "cli.workspaceGroup.error.invalidMemberMove",
                        defaultValue: "Member moves do not accept \("--group") or \("--index")"))
                }
                params["workspace_id"] = try normalizeWorkspaceHandle(required("--workspace"), client: client, windowHandle: window)
                let destination = try required("--to-group")
                if destination == "none" { params["to_group_id"] = NSNull() }
                else { params["to_group_id"] = try normalizeWorkspaceGroupHandle(destination, window: window, client: client) }
            } else {
                guard options.values["--to-group"] == nil, placement.count == 1 else {
                    throw CLIError(message: String(localized: "cli.workspaceGroup.error.invalidGroupMove",
                        defaultValue: "Group moves require one of \("--before"), \("--after") or \("--index") and do not accept \("--to-group")"))
                }
            }
            for key in ["before", "after"] {
                if let raw = options.values["--\(key)"] {
                    if memberMove {
                        params["\(key)_id"] = try normalizeWorkspaceHandle(raw, client: client, windowHandle: window)
                    } else {
                        params["\(key)_id"] = try normalizeWorkspaceGroupHandle(raw, window: window, client: client)
                    }
                }
            }
            if let raw = options.values["--index"] {
                guard let index = Int(raw), index >= 0 else {
                    throw CLIError(message: String(localized: "cli.workspaceGroup.error.invalidIndex",
                        defaultValue: "\("--index") requires a nonnegative integer"))
                }
                params["index"] = index
            }
        }
        let payload = try workspaceGroupRequest("workspace.group.\(verb.replacingOccurrences(of: "-", with: "_"))", params: params, client: client)
        if verb == "list", !(jsonOutput || options.flags.contains("--json")) {
            let groups = payload["workspace_groups"] as? [[String: Any]] ?? []
            if groups.isEmpty {
                print(String(localized: "cli.workspaceGroup.list.empty", defaultValue: "No workspace groups"))
            }
            for group in groups {
                print("\(textHandle(group, idFormat: idFormat)) \(group["name"] as? String ?? "") members=\(group["member_count"] ?? 0)\((group["is_pinned"] as? Bool) == true ? " [pinned]" : "")\((group["is_collapsed"] as? Bool) == true ? " [collapsed]" : "")")
            }
        } else {
            let group = payload["group"] as? [String: Any]
            let handle = group.map { textHandle($0, idFormat: idFormat) }
                ?? formatHandle(payload, kind: "group", idFormat: idFormat) ?? ""
            printV2Payload(payload, jsonOutput: jsonOutput || options.flags.contains("--json"), idFormat: idFormat, fallbackText: "OK \(verb) \(handle)")
        }
    }

    func runReorderWorkspaces(
        commandArgs: [String], client: SocketClient, jsonOutput: Bool,
        idFormat: CLIIDFormat, windowOverride: String?
    ) throws {
        let options = try parseWorkspaceGroupOptions(commandArgs, values: ["--window", "--order"], flags: ["--json", "--dry-run"])
        guard let order = options.values["--order"] else {
            throw CLIError(message: String(localized: "cli.reorderWorkspaces.error.missingOrder",
                defaultValue: "\("reorder-workspaces") requires \("--order") <comma-separated-handles>"))
        }
        let window = try workspaceGroupWindow(options.values["--window"] ?? windowOverride, client: client)
        let ids = try workspaceGroupWorkspaceIDs(order, window: window, client: client)
        let payload = try workspaceGroupRequest("workspace.reorder_batch", params: [
            "window_id": window, "ordered_workspace_ids": ids, "dry_run": options.flags.contains("--dry-run")
        ], client: client)
        printV2Payload(payload, jsonOutput: jsonOutput || options.flags.contains("--json"), idFormat: idFormat,
                       fallbackText: "OK dry_run=\(payload["dry_run"] ?? false) changed=\(payload["changed"] ?? false) order=\((payload["final_workspace_ids"] as? [String] ?? []).joined(separator: ","))")
    }
}
