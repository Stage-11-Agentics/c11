import Darwin
import Foundation

/// C11H-126 part 2: `c11 machine link` and `c11 machine unlink`, the CLI
/// side of Settings > Herder Topography > Add Machine and Remove. Operator actions:
/// both ask first in a terminal and need `--yes` anywhere else.
/// C11H-332: link's question carries the consent the Add Machine sheet asks
/// for, and inside a c11 terminal only a typed answer counts: `--yes` is
/// refused there, so an agent's tool shell (no terminal) can never link.
extension CMUXCLI {
    /// The c11 .app this CLI belongs to (it runs from `Contents/Resources/bin/c11`).
    func enclosingAppBundle() -> URL? {
        // The real executable path: `c11` found on PATH arrives as a bare name.
        var url = URL(fileURLWithPath: currentExecutablePath() ?? CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func confirm(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return false }
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// A c11 terminal's environment (local or on a linked machine); the rule
    /// `c11-core link` shares.
    static func insideC11Terminal(_ environment: [String: String]) -> Bool {
        HCCoreUtility.insideC11Terminal(environment)
    }

    /// The same statement the Add Machine sheet shows before it links.
    static func linkConsent(host: String) -> String {
        """
        Linking gives c11 a shell on \(host) as you.
          c11 signs in with your SSH keys, installs its own hc there and starts it whenever this Mac connects, and never forwards your SSH agent, X11 or ports there.
          Anything you or an agent runs in a c11 terminal there runs as you, with your files and keys on that machine.
          Any program running as you on \(host) can read and type into the c11 terminals there; hc has no per-program check.
          c11 checks hc's hash before it runs it, keeps hc's folders private, and records every cross-machine action (c11 machine audit).
          For a Linux machine, c11 first gets its Linux hc and c11 (about 75 MB, once) from c11's release, or from --artifacts <folder>, and checks each against this build's hash.
          How c11 trusts a linked machine: c11 guide trust
        """
    }

    func runMachineAudit(_ args: [String], json: Bool) throws {
        if C11RelayCLI.isActive {
            throw CLIError(message: "machine audit reads c11's audit log on the operator's Mac; run it there.")
        }
        var filter = C11AuditLog.Filter(limit: 50)
        if let raw = optionValue(args, name: "--limit") {
            guard let limit = Int(raw), limit >= 0 else { throw CLIError(message: "machine audit: --limit takes a number (0 for all)") }
            filter.limit = limit == 0 ? nil : limit
        }
        filter.machine = optionValue(args, name: "--machine")
        if let kind = optionValue(args, name: "--kind") {
            guard C11AuditKind(rawValue: kind) != nil else {
                throw CLIError(message: "machine audit: --kind is one of \(C11AuditKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            filter.kind = kind
        }
        let log = C11AuditLog.shared
        // C11H-332: refused dials the via named while c11 was closed.
        log.ingestLinkLog()
        let records = log.read(filter)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let rows = records.compactMap { record -> Any? in
                guard let data = try? encoder.encode(record) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            }
            Self.printJSON(["path": log.directory.path, "records": rows])
            return
        }
        if records.isEmpty {
            print("No audit records in \(log.directory.path).")
            return
        }
        for record in records { print(C11AuditLog.text(record)) }
    }

    private static func printJSON(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    func runMachineLink(_ args: [String], json: Bool, socketPath: String? = nil, socketPassword: String? = nil) throws {
        guard let host = optionValue(args, name: "--host")?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
            throw CLIError(message: "machine link requires --host <ssh-target> (a Host from ~/.ssh/config, a host name, or user@host)")
        }
        let requestedName = optionValue(args, name: "--name")?.trimmingCharacters(in: .whitespaces)
        let update = args.contains("--update")
        let name = requestedName?.lowercased() ?? HCMachineSetup.defaultName(forHost: host)
        // C11H-392: a Linux machine's hc and CLI, from c11's cache, --artifacts
        // (a folder of files that hash to this build's pins) or the release. The
        // folder is checked before the consent question, not after its answer.
        var importDirectory: URL?
        if let raw = optionValue(args, name: "--artifacts") {
            let folder = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError(message: "machine link: --artifacts \(raw) is not a folder")
            }
            importDirectory = folder
        }
        if !update, args.contains("--yes"), Self.insideC11Terminal(ProcessInfo.processInfo.environment) {
            throw CLIError(message: "machine link: --yes isn't accepted inside a c11 terminal. Linking gives c11 a shell on \(host) as you, so the operator answers the question here, or uses Settings > Herder Topography > Add Machine.")
        }
        if !args.contains("--yes") {
            if !update { print(Self.linkConsent(host: host)); fflush(stdout) }
            guard Self.confirm(update ? "Update c11's hc on \(host) (\(name))?" : "Link \(host) to c11 as \(name)?") else {
                throw CLIError(message: "machine link: not confirmed. In a terminal answer y; elsewhere pass --yes (an operator action, not an agent's).")
            }
        }
        // C11H-391: c11's own session, the links session while adopted.
        let configuration: HCLaunchConfiguration
        do { configuration = try C11CoreCLI.linkConfiguration() } catch {
            throw CLIError(message: "machine link: could not resolve c11's hc session: \(error)")
        }
        if C11CoreCLI.adopted, let socketPath {
            // Consent is behind us: ask the app to start that session's core
            // (it starts only when a link asks). Best effort; the flow's own
            // core check says why if it still isn't serving.
            startLinkSession(socketPath: socketPath, password: socketPassword)
        }
        guard let bundle = enclosingAppBundle() else {
            throw CLIError(message: "machine link: run the c11 CLI inside c11.app (Contents/Resources/bin/c11)")
        }
        let coreHost = C11CoreCLI.host
        let home = FileManager.default.homeDirectoryForCurrentUser
        let flow = HCMachineSetupFlow(
            configuration: configuration,
            resources: .inBundle(bundle),
            runner: HCMachineSetupProcessRunner(),
            localHome: FileManager.default.homeDirectoryForCurrentUser,
            verifyCore: { HCMachineSetup.verifyOwnCore(configuration: configuration, host: coreHost) },
            origin: "cli",
            linuxFiles: .forBundle(bundle, home: home, importDirectory: importDirectory)
        )
        defer { C11AuditLog.shared.flush() }
        var steps: [[String: Any]] = []
        let outcome = flow.run(HCMachineSetupRequest(host: host, name: requestedName, update: update)) { progress in
            steps.append(["step": progress.step.rawValue, "state": progress.state.rawValue,
                          "detail": progress.detail as Any? ?? NSNull()])
            guard !json, progress.state != .running else { return }
            let mark: String
            switch progress.state {
            case .done: mark = "ok"
            case .skipped: mark = "already"
            case .failed: mark = "FAILED"
            case .running: mark = ""
            }
            let detail = progress.state == .failed ? "" : progress.detail.map { " (\($0))" } ?? ""
            print("\(mark)\t\(progress.step.title)\(detail)")
        }
        switch outcome {
        case .success(let result):
            if json {
                Self.printJSON(["ok": true, "steps": steps, "machine": [
                    "name": result.name, "host": result.host, "via": result.viaScript,
                    "installed_hc": result.installedHC, "version": result.version,
                ]])
            } else {
                print("\(result.name) is linked. Open a terminal there: c11 new-panel --on \(result.name)")
            }
        case .failure(let failure):
            if json { Self.printJSON(["ok": false, "steps": steps, "error": ["code": failure.code, "message": failure.message]]) }
            throw CLIError(message: failure.message)
        }
    }

    /// C11H-391: `machine.link_session` on the app's socket; failures are ignored.
    private func startLinkSession(socketPath: String, password: String?) {
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        guard (try? client.connect()) != nil,
              (try? authenticateClientIfNeeded(client, explicitPassword: password, socketPath: socketPath)) != nil else { return }
        _ = try? client.sendV2(method: "machine.link_session", params: [:], deadline: .custom(30))
    }

    func runMachineUnlink(_ args: [String], json: Bool, client: SocketClient, idFormat: CLIIDFormat) throws {
        guard let id = optionValue(args, name: "--id")?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            throw CLIError(message: "machine unlink requires --id <machine>")
        }
        // C11H-391: whose link, when c11 and c11h both link the name.
        var base: [String: Any] = ["id": id]
        if let session = optionValue(args, name: "--session")?.trimmingCharacters(in: .whitespaces), !session.isEmpty {
            base["session"] = session
        }
        func params(_ extra: [String: Any] = [:]) -> [String: Any] { base.merging(extra) { _, new in new } }
        if args.contains("--dry-run") {
            let preview = try client.sendV2(method: "machine.unlink", params: params(["dry_run": true]))
            printV2Payload(preview, jsonOutput: true, idFormat: idFormat, fallbackText: "OK")
            return
        }
        if !args.contains("--yes") {
            let preview = try client.sendV2(method: "machine.unlink", params: params(["dry_run": true]))
            let terminals = preview["terminals"] as? [[String: Any]] ?? []
            let machine = preview["machine"] as? String ?? id
            if terminals.isEmpty {
                print("No c11 terminals are open on \(machine).")
            } else {
                print(terminals.count == 1
                      ? "This c11 terminal on \(machine) will end, with everything it started:"
                      : "These \(terminals.count) c11 terminals on \(machine) will end, with everything they started:")
                for terminal in terminals {
                    print("  \(terminal["workspace_title"] as? String ?? "") · \(terminal["title"] as? String ?? "")")
                }
            }
            guard Self.confirm("Remove \(machine)?") else {
                throw CLIError(message: "machine unlink: not confirmed. In a terminal answer y; elsewhere pass --yes (see what would end with --dry-run). An operator action, not an agent's.")
            }
        }
        // Ending terminals, stopping the far core and unlinking can take a while.
        let payload = try client.sendV2(method: "machine.unlink", params: params(), deadline: .custom(180))
        if json {
            printV2Payload(payload, jsonOutput: true, idFormat: idFormat, fallbackText: "OK")
        } else {
            let machine = payload["machine"] as? String ?? id
            let ended = payload["ended"] as? Int ?? 0
            print(ended == 1 ? "Removed \(machine); 1 c11 terminal ended." : "Removed \(machine); \(ended) c11 terminals ended.")
            if payload["c11h_link"] as? Bool == true {
                print(payload["link_was_up"] as? Bool == false
                      ? "warning: \(machine)'s link was down, so its c11h terminals and c11h's hc there may still run; c11 stops only an hc it installed."
                      : "note: \(machine) was linked by c11h; its c11h terminals ended, and c11h's hc still runs there with no terminals (c11 stops only an hc it installed).")
            } else if payload["stop_refused"] as? Bool == true {
                print("warning: c11 couldn't confirm the hc serving c11 on \(machine) is its own (its hash or its serving core didn't match), so it didn't stop it; it keeps running until it ends there.")
            } else if payload["left_running"] as? Bool == true {
                print("warning: \(machine)'s link was down, so c11 couldn't end what it runs there; that keeps running until the machine's hc stops.")
            }
        }
    }
}
