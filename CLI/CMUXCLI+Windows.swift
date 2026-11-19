import Foundation

// c11 (C11H-197): window names, window placement, and displays.
// Every frame is in global points with the origin at the main display's
// top-left corner, y down, so `window move --frame` takes what `list` prints.

extension CMUXCLI {
    func runWindowCommand(
        commandArgs: [String], client: SocketClient, jsonOutput: Bool, idFormat: CLIIDFormat, idFormatExplicit: Bool
    ) throws {
        guard let first = commandArgs.first else {
            throw CLIError(message: "window requires list, name, or move. Run 'c11 window --help'.")
        }
        let rest = Array(commandArgs.dropFirst())
        switch first.lowercased() {
        case "list", "ls":
            try runListWindows(client: client, jsonOutput: jsonOutput, idFormat: idFormatExplicit ? idFormat : .both)
        case "name", "rename":
            try runWindowName(args: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "move":
            try runWindowMove(args: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "Unknown window subcommand: \(first). Use list, name, or move.")
        }
    }

    func runDisplayCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        let first = commandArgs.first?.lowercased() ?? "list"
        guard first == "list" || first == "ls" else {
            throw CLIError(message: "Unknown display subcommand: \(first). Use list.")
        }
        let response = try CapabilityFeatures.current.dispatch(.displayList) {
            try client.sendV2(method: "display.list")
        }
        if jsonOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
            return
        }
        let displays = response["displays"] as? [[String: Any]] ?? []
        guard !displays.isEmpty else {
            print("No displays")
            return
        }
        for display in displays {
            print(displayLine(display))
        }
    }

    /// `list-windows` and `window list`. JSON is the `window.list` entries as an
    /// array; text keeps the old line's tokens first and adds display and name.
    func runListWindows(client: SocketClient, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        let response = try client.sendV2(method: "window.list")
        let windows = response["windows"] as? [[String: Any]] ?? []
        if jsonOutput {
            print(jsonString(formatIDs(windows, mode: idFormat)))
            return
        }
        guard !windows.isEmpty else {
            print("No windows")
            return
        }
        for window in windows {
            let marker = (window["key"] as? Bool) == true ? "*" : " "
            let index = intFromAny(window["index"]) ?? 0
            let id = window["id"] as? String ?? "?"
            let selected = window["selected_workspace_id"] as? String ?? "none"
            let count = intFromAny(window["workspace_count"]) ?? 0
            var line = "\(marker) \(index): \(id) selected_workspace=\(selected) workspaces=\(count)"
            if let ref = window["ref"] as? String { line += " ref=\(ref)" }
            if let display = window["display"] as? [String: Any], let displayRef = display["ref"] as? String {
                line += " display=\(displayRef)"
            }
            if let frame = window["frame"] as? [String: Any] { line += " frame=\(frameText(frame))" }
            if let theme = window["theme"] as? [String: Any], let override = theme["override"] as? String {
                line += " theme=\(override)"
            }
            if let name = window["name"] as? String { line += " name=\(quotedName(name))" }
            print(line)
        }
    }

    /// Resolves `--window`: `self` is the caller's own window; anything else is
    /// a UUID, `window:N`, an index, or a window name.
    func resolveWindowTarget(_ raw: String, client: SocketClient) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError(message: "--window was provided but empty") }
        guard trimmed.lowercased() == "self" else {
            return try normalizeWindowHandle(trimmed, client: client) ?? trimmed
        }
        guard let workspace = try resolvedSelfCloseTarget("self", kind: "workspace") else {
            throw CLIError(message: "--window self needs C11_PANEL_ID or C11_WORKSPACE_ID from a c11 terminal")
        }
        var caller: [String: Any] = ["workspace_id": workspace]
        if let panel = Self.callerPanelEnv() { caller["panel_id"] = panel }
        let identified = try client.sendV2(method: "system.identify", params: ["caller": caller])
        guard let window = (identified["caller"] as? [String: Any])?["window_id"] as? String else {
            throw CLIError(message: "--window self: c11 did not report the calling panel's window")
        }
        return window
    }

    private func runWindowName(args: [String], client: SocketClient, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        let (windowRaw, afterWindow) = parseOption(args, name: "--window")
        let (rest, clear) = parseFlag(afterWindow, name: "--clear")
        guard let windowRaw = windowRaw ?? client.scopedWindow else {
            throw CLIError(message: "window name requires --window <ref> (a ref, UUID, index, name, or self)")
        }
        let words = rest.filter { $0 != "--" }
        if let flag = words.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: unknownFlagMessage(command: "window name", flag: flag))
        }
        let name = words.joined(separator: " ")
        if clear, !name.isEmpty {
            throw CLIError(message: "window name: give a name or --clear, not both")
        }
        if !clear, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CLIError(message: "window name requires a name, or --clear to remove it")
        }
        let windowId = try resolveWindowTarget(windowRaw, client: client)
        let response = try CapabilityFeatures.current.dispatch(.windowName) {
            try client.sendV2(method: "window.set_name", params: [
                "window_id": windowId,
                "name": clear ? NSNull() : name,
            ])
        }
        if jsonOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
            return
        }
        let ref = response["window_ref"] as? String ?? windowId
        if let applied = response["name"] as? String {
            print("OK window=\(ref) name=\(quotedName(applied))")
        } else {
            print("OK window=\(ref) name cleared")
        }
    }

    private func runWindowMove(args: [String], client: SocketClient, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        let (windowRaw, a1) = parseOption(args, name: "--window")
        let (displayRaw, a2) = parseOption(a1, name: "--display")
        let (frameRaw, a3) = parseOption(a2, name: "--frame")
        let (a4, fill) = parseFlag(a3, name: "--fill")
        let (a5, leftHalf) = parseFlag(a4, name: "--left-half")
        let (rest, rightHalf) = parseFlag(a5, name: "--right-half")
        if let extra = rest.first(where: { $0 != "--" }) {
            throw CLIError(message: extra.hasPrefix("-")
                ? unknownFlagMessage(command: "window move", flag: extra)
                : "window move: unexpected argument '\(extra)'")
        }
        guard let windowRaw = windowRaw ?? client.scopedWindow else {
            throw CLIError(message: "window move requires --window <ref> (a ref, UUID, index, name, or self)")
        }
        let presets = [(fill, "fill"), (leftHalf, "left-half"), (rightHalf, "right-half")].filter(\.0).map(\.1)
        if presets.count > 1 { throw CLIError(message: "window move: give one of --fill, --left-half, --right-half") }
        if frameRaw != nil, !presets.isEmpty {
            throw CLIError(message: "window move: give --frame or a preset, not both")
        }
        if displayRaw == nil, frameRaw == nil, presets.isEmpty {
            throw CLIError(message: "window move needs --display, --frame, or one of --fill, --left-half, --right-half")
        }
        var params: [String: Any] = ["window_id": try resolveWindowTarget(windowRaw, client: client)]
        if let displayRaw { params["display"] = displayRaw }
        if let frameRaw {
            let parts = frameRaw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
                  [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else {
                throw CLIError(message: "--frame takes x,y,width,height in points, e.g. --frame -5120,-271,1280,1440")
            }
            params["frame"] = ["x": x, "y": y, "width": w, "height": h]
        }
        if let preset = presets.first { params["preset"] = preset }
        let response = try CapabilityFeatures.current.dispatch(.windowMove) {
            try client.sendV2(method: "window.move", params: params)
        }
        if jsonOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
            return
        }
        let ref = response["window_ref"] as? String ?? "?"
        var line = "OK window=\(ref)"
        if let display = response["display"] as? [String: Any] {
            line += " display=\(display["ref"] as? String ?? "?") (\(display["name"] as? String ?? "?"))"
        }
        if let frame = response["frame"] as? [String: Any] { line += " frame=\(frameText(frame))" }
        if (response["changed"] as? Bool) == false { line += " unchanged" }
        print(line)
    }

    private func displayLine(_ display: [String: Any]) -> String {
        let ref = display["ref"] as? String ?? "?"
        let name = display["name"] as? String ?? "?"
        var line = "\(ref)  \(quotedName(name))"
        if let frame = display["frame"] as? [String: Any] { line += "  frame=\(frameText(frame))" }
        if let visible = display["visible_frame"] as? [String: Any] { line += "  visible=\(frameText(visible))" }
        if let scale = display["scale"] as? Double { line += "  scale=\(formatNumber(scale))" }
        if (display["main"] as? Bool) == true { line += "  main" }
        if (display["builtin"] as? Bool) == true { line += "  builtin" }
        if let uuid = display["uuid"] as? String { line += "  uuid=\(uuid)" }
        let windows = (display["windows"] as? [[String: Any]] ?? []).map { window -> String in
            let ref = window["ref"] as? String ?? "?"
            return (window["name"] as? String).map { "\(ref)=\(quotedName($0))" } ?? ref
        }
        line += "  windows=" + (windows.isEmpty ? "none" : windows.joined(separator: ","))
        return line
    }

    private func frameText(_ frame: [String: Any]) -> String {
        ["x", "y", "width", "height"]
            .map { key in (frame[key] as? Double).map(formatNumber) ?? intFromAny(frame[key]).map(String.init) ?? "?" }
            .joined(separator: ",")
    }

    private func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func quotedName(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
