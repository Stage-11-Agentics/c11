import Foundation

extension CMUXCLI {
    func runHCDiagnostics(client: SocketClient, jsonOutput: Bool) throws {
        let response = try client.sendV2(method: "hc.diagnostics")
        if jsonOutput {
            print(jsonString(response))
            return
        }
        for line in HCDiagnosticsText.lines(response) { print(line) }
    }
}

extension CMUXCLI {
    /// `restore status` and `restore run` are the host-end restore; any other
    /// first word is a snapshot id or path for `restore <snapshot>`.
    static func isHostEndRestoreCommand(_ commandArgs: [String]) -> Bool {
        guard let first = commandArgs.first?.lowercased() else { return false }
        return first == "status" || first == "run"
    }

    /// C11H-196: `c11 restore status|run`. The app decides per panel; this
    /// prints what it answered.
    func runRestore(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: "restore requires status or run")
        }
        let args = Array(commandArgs.dropFirst())
        let json = jsonOutput || args.contains("--json")
        switch subcommand {
        case "status":
            let response = try client.sendV2(method: "restore.status")
            if json { print(jsonString(response)); return }
            for line in Self.restoreStatusLines(response) { print(line) }
        case "run":
            let all = hasFlag(args, name: "--all")
            let panel = try validatedPanelTargetValue(optionValue(args, name: "--panel"),
                                                      wasProvided: hasFlag(args, name: "--panel"))
            guard all != (panel != nil) else {
                throw CLIError(message: "restore run needs exactly one of --panel <ref> or --all")
            }
            var params: [String: Any] = ["all": all, "dry_run": hasFlag(args, name: "--dry-run")]
            if let panel { params["panel_id"] = panel }
            let response = try client.sendV2(method: "restore.run", params: params)
            if json { print(jsonString(response)); return }
            let rows = response["panels"] as? [[String: Any]] ?? []
            if rows.isEmpty { print("(nothing to restore)"); return }
            for row in rows {
                var line = "\(row["outcome"] as? String ?? "?") panel=\(row["panel_id"] as? String ?? "?")"
                if let title = row["panel_title"] as? String { line += " title=\(title)" }
                if let reason = row["reason"] as? String { line += " reason=\(reason)" }
                print(line)
            }
        default:
            throw CLIError(message: "Unknown restore subcommand: \(subcommand)")
        }
    }

    static func restoreStatusLines(_ response: [String: Any]) -> [String] {
        var lines: [String] = []
        if let summary = response["summary"] as? [String: Any] {
            let n = { (key: String) in summary[key] as? Int ?? 0 }
            lines.append("restored \(n("resumed")) of \(n("total")); pending \(n("pending")), resuming \(n("resuming")), " +
                         "failed \(n("failed")), skipped \(n("skipped")); need you \(n("need_you"))")
        }
        for row in response["panels"] as? [[String: Any]] ?? [] {
            var line = "\(row["state"] as? String ?? "?")\t\(row["panel_id"] as? String ?? "?")\t" +
                "\(row["workspace_title"] as? String ?? "-") · \(row["panel_title"] as? String ?? "-")"
            if let reason = row["reason"] as? String { line += "\t\(reason)" }
            lines.append(line)
        }
        return lines
    }
}
