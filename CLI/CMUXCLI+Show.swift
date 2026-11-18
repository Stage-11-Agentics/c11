import Foundation

// C11H-228: `c11 show <path|url>` and `c11 show close [<path|url>]`. Thin
// glue: target resolution and the relay's durable record are in
// `ShowCLIRecord` (Sources/Show/ShowCLIRecord.swift).
extension CMUXCLI {
    func runShowCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        let (dirOption, afterDir) = parseOption(commandArgs, name: "--dir")
        let (waitOption, remaining) = parseOption(afterDir, name: "--wait")
        var words = remaining.filter { $0 != "--" }
        let closing = words.first?.lowercased() == "close"
        if closing { words.removeFirst() }
        if let extra = words.dropFirst().first {
            throw CLIError(message: unexpectedArgumentMessage(command: closing ? "show close" : "show", argument: extra))
        }
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let cwd = FileManager.default.currentDirectoryPath

        var params: [String: Any] = [:]
        try addCallingPanel(to: &params)
        guard let caller = (params["caller_panel_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw CLIError(message: ShowSpec.Code.noCaller + ": " + String(localized: "show.cli.error.noCaller",
                defaultValue: "run c11 show inside a c11 panel"))
        }
        let relay = client.isRelayed ? C11RelayCLI.current : nil

        if closing {
            let source = words.first.map { ShowCLIRecord.resolveForClose(target: $0, dir: dirOption, cwd: cwd, home: home) }
            if let source { params["source"] = source.dictionary }
            let send = { try client.sendV2(method: ShowSpec.closeMethod, params: params) }
            let payload: [String: Any]
            if let relay {
                let store = C11RelayHCStore(socketPath: relay.hcSocket)
                defer { store.close() }
                switch try mappingShowFailure({ try ShowCLIRecord.closeRelayed(source: source, store: store, panel: caller, call: send) }) {
                case .recorded:
                    print(jsonOutput ? jsonString(["recorded": true, "closed": 0]) : ShowCLIRecord.awayCloseLine())
                    return
                case .answered(let answer): payload = answer
                }
            } else {
                payload = try send()
            }
            let closed = (payload["closed"] as? NSNumber)?.intValue
                ?? (payload["closed_panel_ids"] as? [Any])?.count ?? 0
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK closed \(closed)")
            return
        }

        guard let target = words.first else {
            throw CLIError(message: ShowSpec.Code.badSource + ": " + String(localized: "show.cli.error.noTarget",
                defaultValue: "c11 show needs a file path or a URL"))
        }
        let wait = try mappingShowFailure { try ShowCLIRecord.waitSeconds(waitOption) }
        params["wait_seconds"] = wait
        let open = { (source: ShowSourceSpec, recordID: String?) throws -> [String: Any] in
            var request = params
            request["source"] = source.dictionary
            if let recordID { request["record_id"] = recordID }
            return try client.sendV2(method: ShowSpec.openMethod, params: request, deadline: .custom(wait + 10))
        }
        let payload: [String: Any]
        if let relay {
            let store = C11RelayHCStore(socketPath: relay.hcSocket)
            defer { store.close() }
            let outcome = try mappingShowFailure {
                try ShowCLIRecord.openRelayed(target: target, dir: dirOption, cwd: cwd, home: home,
                                              store: store, panel: caller,
                                              credential: relay.caller?.credential, call: open)
            }
            switch outcome {
            case .recorded:
                print(jsonOutput ? jsonString(["recorded": true]) : ShowCLIRecord.awayLine())
                return
            case .answered(let answer): payload = answer
            }
        } else {
            let source = try mappingShowFailure { try ShowCLIRecord.resolve(target: target, dir: dirOption, cwd: cwd, home: home) }
            payload = try open(source, nil)
        }
        try printShowResult(payload, wait: wait, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    /// Runs `body`, turning a `ShowCLIRecord.Failure` into the CLI's error line.
    private func mappingShowFailure<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as ShowCLIRecord.Failure {
            throw CLIError(message: failure.description)
        }
    }

    /// `OK <action> <address> → panel:<handle> (<status>)`, the warnings, and
    /// exit 1 unless the load check says loaded.
    func printShowResult(_ payload: [String: Any], wait: Double, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        let load = payload["load"] as? [String: Any] ?? [:]
        let status = load["status"] as? String ?? "unknown"
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let handle = formatHandle(payload, kind: "viewer_panel", idFormat: idFormat) ?? "?"
            let panel = handle.hasPrefix("panel:") ? handle : "panel:" + handle
            let action = payload["action"] as? String ?? "opened"
            let address = payload["address"] as? String ?? ""
            print("\(status == "loaded" ? "OK " : "")\(action) \(address) → \(panel) (\(status))")
            let scriptErrors = (load["script_errors"] as? NSNumber)?.intValue ?? 0
            if scriptErrors > 0 {
                print(String(format: String(localized: "show.cli.warning.scriptErrors",
                    defaultValue: "warning: %lld script errors"), Int64(scriptErrors)))
            }
            let refused = (load["refused_assets"] as? NSNumber)?.intValue ?? 0
            if refused > 0 {
                print(String(format: String(localized: "show.cli.warning.refusedAssets",
                    defaultValue: "warning: %lld assets refused (outside --dir or not allowed; pass --dir <folder>)"), Int64(refused)))
            }
        }
        switch status {
        case "loaded":
            return
        case "blank":
            throw CLIError(message: "show_blank: " + String(localized: "show.cli.error.blank",
                defaultValue: "the page rendered no text and almost no elements"))
        case "timeout":
            throw CLIError(message: "show_load_timeout: " + String(format: String(localized: "show.cli.error.loadTimeout",
                defaultValue: "not loaded within %@ s"), String(format: "%g", wait)))
        default:
            let reason = (load["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(format: String(localized: "show.cli.error.loadStatus", defaultValue: "load status %@"), status)
            throw CLIError(message: "show_load_failed: " + reason)
        }
    }
}
