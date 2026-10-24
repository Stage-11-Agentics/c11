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

    // MARK: - C11-131: app restart

    func appUsage() -> String {
        return """
        Usage: c11 app <subcommand> [flags]

        Subcommands:
          restart [--no-resume]   Clean-bounce the running instance: suspend
                                  conversations, snapshot, promote the shutdown
                                  sentinel to clean, then relaunch. --no-resume
                                  restores layout without typing resume commands
                                  into panels.
        """
    }

    func runAppCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let subArgs = Array(commandArgs.dropFirst())
        switch subcommand {
        case "restart":
            var params: [String: Any] = [:]
            if hasFlag(subArgs, name: "--no-resume") { params["no_resume"] = true }
            let response = try client.sendV2(method: "app.restart", params: params)
            if jsonOutput {
                print(jsonString(response))
            } else {
                let resume = (response["resume"] as? Bool) ?? true
                print("OK app restart — relaunching\(resume ? "" : " (no resume)")")
            }
        case "help", "--help", "-h":
            print(appUsage())
        default:
            throw CLIError(message: "Unknown app subcommand: \(subcommand)")
        }
    }

    /// Render an arbitrary JSON-ish metadata value for the human CLI output.
    func renderScalarOrJSON(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // NSNumber can wrap Bool — distinguish.
            let cfType = CFNumberGetType(n)
            if CFGetTypeID(n) == CFBooleanGetTypeID() || cfType == .charType {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }
}
