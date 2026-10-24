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

    func debugString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    func debugBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return parseBoolString(string)
        }
        return nil
    }

    func debugFlag(_ value: Any?) -> String {
        guard let bool = debugBool(value) else { return "nil" }
        return bool ? "1" : "0"
    }

    func formatDebugRect(_ value: Any?) -> String? {
        guard let rect = value as? [String: Any],
              let x = doubleFromAny(rect["x"]),
              let y = doubleFromAny(rect["y"]),
              let width = doubleFromAny(rect["width"]),
              let height = doubleFromAny(rect["height"]) else {
            return nil
        }
        return String(format: "{%.1f,%.1f %.1fx%.1f}", x, y, width, height)
    }

    func formatDebugPorts(_ value: Any?) -> String {
        guard let array = value as? [Any], !array.isEmpty else { return "[]" }
        let ports = array
            .compactMap { intFromAny($0) }
            .map(String.init)
        return ports.isEmpty ? "[]" : ports.joined(separator: ",")
    }

    func formatDebugList(_ value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        let items = array.compactMap { item -> String? in
            if let string = item as? String {
                return string
            }
            return debugString(item)
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: ">")
    }

    func formatDebugAge(_ value: Any?) -> String? {
        guard let seconds = doubleFromAny(value) else { return nil }
        return String(format: "%.3fs", seconds)
    }

    func formatDebugTerminalsPayload(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        guard !terminals.isEmpty else { return "No terminal panels" }

        return terminals.map { item in
            let index = intFromAny(item["index"]) ?? 0
            let surface = formatHandle(item, kind: "panel", idFormat: idFormat) ?? "?"
            let window = formatHandle(item, kind: "window", idFormat: idFormat) ?? "nil"
            let workspace = formatHandle(item, kind: "workspace", idFormat: idFormat) ?? "nil"
            let pane = formatHandle(item, kind: "area", idFormat: idFormat) ?? "nil"
            let bonsplitTab = debugString(item["bonsplit_tab_id"]) ?? "nil"
            let lastKnownWorkspace = debugString(item["last_known_workspace_ref"]) ?? debugString(item["last_known_workspace_id"]) ?? "nil"
            let titleSuffix: String = {
                guard let title = debugString(item["panel_title"]), !title.isEmpty else { return "" }
                let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
                return " \"\(escaped)\""
            }()
            let branchLabel: String = {
                guard let branch = debugString(item["git_branch"]), !branch.isEmpty else { return "nil" }
                return debugBool(item["git_dirty"]) == true ? "\(branch)*" : branch
            }()
            let teardownLabel: String = {
                guard debugBool(item["teardown_requested"]) == true else { return "nil" }
                let reason = debugString(item["teardown_requested_reason"]) ?? "requested"
                let age = formatDebugAge(item["teardown_requested_age_seconds"]) ?? "unknown"
                return "\(reason)@\(age)"
            }()
            let portalHostLabel: String = {
                let hostId = debugString(item["portal_host_id"]) ?? "nil"
                let area = doubleFromAny(item["portal_host_area"]).map { String(format: "%.1f", $0) } ?? "nil"
                let inWindow = debugFlag(item["portal_host_in_window"])
                return "\(hostId)/win=\(inWindow)/area=\(area)"
            }()
            let windowMetaLabel: String = {
                let title = debugString(item["window_title"]) ?? "nil"
                let windowClass = debugString(item["window_class"]) ?? "nil"
                let controllerClass = debugString(item["window_controller_class"]) ?? "nil"
                let delegateClass = debugString(item["window_delegate_class"]) ?? "nil"
                return "title=\(title) class=\(windowClass) controller=\(controllerClass) delegate=\(delegateClass)"
            }()

            let line1 =
                "[\(index)] \(surface)\(titleSuffix) " +
                "mapped=\(debugFlag(item["mapped"])) tree=\(debugFlag(item["tree_visible"])) " +
                "window=\(window) workspace=\(workspace) area=\(pane) bonsplitTab=\(bonsplitTab) " +
                "ctx=\(debugString(item["panel_context"]) ?? "nil")"

            let line2 =
                "    runtime=\(debugFlag(item["runtime_panel_ready"])) " +
                "focused=\(debugFlag(item["panel_focused"])) " +
                "selected=\(debugFlag(item["panel_selected_in_area"])) " +
                "pinned=\(debugFlag(item["panel_pinned"])) " +
                "terminal=\(debugString(item["terminal_object_ptr"]) ?? "nil") " +
                "hosted=\(debugString(item["hosted_view_ptr"]) ?? "nil") " +
                "ghostty=\(debugString(item["ghostty_surface_ptr"]) ?? "nil") " +
                "portal=\(debugString(item["portal_binding_state"]) ?? "nil")#\(debugString(item["portal_binding_generation"]) ?? "nil") " +
                "teardown=\(teardownLabel)"

            let line3 =
                "    tty=\(debugString(item["tty"]) ?? "nil") " +
                "cwd=\(debugString(item["current_directory"]) ?? debugString(item["requested_working_directory"]) ?? "nil") " +
                "branch=\(branchLabel) " +
                "ports=\(formatDebugPorts(item["listening_ports"])) " +
                "visible=\(debugFlag(item["hosted_view_visible_in_ui"])) " +
                "inWindow=\(debugFlag(item["hosted_view_in_window"])) " +
                "superview=\(debugFlag(item["hosted_view_has_superview"])) " +
                "hidden=\(debugFlag(item["hosted_view_hidden"])) " +
                "ancestorHidden=\(debugFlag(item["hosted_view_hidden_or_ancestor_hidden"])) " +
                "firstResponder=\(debugFlag(item["panel_view_first_responder"])) " +
                "windowNum=\(debugString(item["window_number"]) ?? "nil") " +
                "windowKey=\(debugFlag(item["window_key"])) " +
                "frame=\(formatDebugRect(item["hosted_view_frame_in_window"]) ?? "nil")"

            let line4 =
                "    created=\(formatDebugAge(item["panel_age_seconds"]) ?? "nil") " +
                "runtimeCreated=\(formatDebugAge(item["runtime_panel_age_seconds"]) ?? "nil") " +
                "lastWorkspace=\(lastKnownWorkspace) " +
                "initialCommand=\(debugString(item["initial_command"]) ?? "nil") " +
                "portalHost=\(portalHostLabel)"

            let line5 =
                "    window=\(windowMetaLabel) " +
                "chain=\(formatDebugList(item["hosted_view_superview_chain"]) ?? "nil")"

            return [line1, line2, line3, line4, line5].joined(separator: "\n")
        }
        .joined(separator: "\n")
    }
}
