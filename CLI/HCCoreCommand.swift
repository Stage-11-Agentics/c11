import Foundation

enum HCCoreCommand {
    static func run(arguments: [String], client: SocketClient, prepare: () throws -> Void = {}) throws {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
            print(String(localized: "hc.cli.help", defaultValue: "Usage: c11 hc server status|restart; c11 hc ls; c11 hc machine ls; c11 hc get <terminal>; c11 hc run [--cwd <path>] [--env K=V] [--label K=V] -- <program> [args]. This adapter uses c11's existing core; start, stop and update are managed by c11."))
            return
        }
        let command: HCManagedCommand
        do {
            command = try HCManagedCommandParser.parse(arguments, environment: ProcessInfo.processInfo.environment,
                                                       cwd: FileManager.default.currentDirectoryPath)
        } catch let error as HCManagedCommandError {
            throw CLIError(message: error.rawValue + ": " + message(for: error))
        }
        let encoded = try JSONEncoder().encode(command)
        guard let params = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CLIError(message: HCManagedCommandError.hcInvalidArguments.rawValue + ": " + message(for: .hcInvalidArguments))
        }
        // Reads have a 12 s backend budget, with 4 s for CLI setup/response.
        // Writes retain 36 s, above the 20 s run / 30 s recovery deadlines.
        // One CLI deadline includes connect, auth and capability discovery.
        let seconds: TimeInterval = command.verb.isReadOnly ? 16 : 36
        let previousDeadline = SocketClient.processDeadline
        SocketClient.processDeadline = min(previousDeadline ?? .distantFuture, Date().addingTimeInterval(seconds))
        defer { SocketClient.processDeadline = previousDeadline }
        let payload: [String: Any]
        do {
            try prepare()
            payload = try client.sendV2(method: "hc.call", params: params, deadline: .custom(seconds))
        } catch {
            let cli = error as? CLIError
            let detail = cli?.message ?? String(describing: error)
            if command.verb.isReadOnly {
                let guidance = String(localized: "hc.cli.retryRead",
                    defaultValue: "Retrying this read-only command is safe; run the same command again. Unavailable inventory does not mean sessions ended.")
                throw CLIError(message: detail + "\nretry_safe=true: " + guidance,
                               structuredResponse: cli?.structuredResponse)
            }
            let data = (cli?.structuredResponse?["error"] as? [String: Any])?["data"] as? [String: Any]
            if let retrySafe = data?["retry_safe"] as? Bool {
                throw CLIError(message: detail + "\nretry_safe=\(retrySafe)", structuredResponse: cli?.structuredResponse)
            }
            throw error
        }
        let output = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed])
        print(String(decoding: output, as: UTF8.self))
    }

    private static func message(for error: HCManagedCommandError) -> String {
        switch error {
        case .hcSessionRequired:
            return String(localized: "hc.cli.sessionRequired", defaultValue: "Run this command from a c11 terminal.")
        case .hcManagedRuntime:
            return String(localized: "hc.cli.managedRuntime", defaultValue: "c11 manages the core's identity and lifetime.")
        case .hcCommandUnsupported:
            return String(localized: "hc.cli.unsupported", defaultValue: "This hc command or option is not supported by c11.")
        case .hcInvalidArguments:
            return String(localized: "hc.cli.invalidArguments", defaultValue: "The hc command arguments are invalid.")
        }
    }

}
