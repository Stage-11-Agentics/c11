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

    func runHistoryCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        var verb: String? = nil
        var limit: Int? = nil
        var wantsJSON = jsonOutput
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--json":
                wantsJSON = true
            case "--limit":
                guard limit == nil, index + 1 < commandArgs.count,
                      let value = Int(commandArgs[index + 1]), (1...200).contains(value) else {
                    throw CLIError(message: "limit must be an integer from 1 to 200")
                }
                limit = value
                index += 1
            case "list", "back", "forward":
                guard verb == nil else {
                    throw CLIError(message: "history accepts one verb: list, back, or forward")
                }
                verb = arg
            default:
                throw CLIError(message: "Unknown history argument '\(arg)'. Run 'c11 history --help' for usage.")
            }
            index += 1
        }
        let action = verb ?? "list"
        if action != "list", limit != nil {
            throw CLIError(message: "limit applies to history listing")
        }
        var params: [String: Any] = [:]
        if let limit { params["limit"] = limit }
        let payload = try client.sendV2(method: "history.\(action)", params: params)
        if wantsJSON {
            // Both durable UUIDs and live refs are part of the history contract.
            print(jsonString(payload))
            return
        }
        if action != "list" {
            print("\(payload["panel_ref"] as? String ?? payload["panel_id"] as? String ?? "")  \(payload["title"] as? String ?? "")")
            return
        }
        let entries = payload["entries"] as? [[String: Any]] ?? []
        guard !entries.isEmpty else {
            print("No focus history.")
            return
        }
        let total = payload["total"] as? Int ?? entries.count
        let position = (payload["position"] as? Int).map(String.init) ?? "none"
        print("\(total) entries, showing \(entries.count), position \(position)")
        for entry in entries {
            let panel = entry["panel_ref"] as? String ?? entry["panel_id"] as? String ?? ""
            let title = entry["title"] as? String ?? ""
            let dwell = entry["dwell_seconds"] as? Double ?? 0
            let seconds = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), dwell)
            let seenAt = entry["seen_at"] as? String ?? ""
            let marker = entry["current"] as? Bool == true ? "  ←" : ""
            print("\(panel)  \(title)  \(seconds)s  \(seenAt)\(marker)")
        }
    }
}
