import Darwin
import Foundation

/// `c11-core` (C11H-37): `Resources/bin/c11-core` runs the bundled `c11` with
/// `C11_INVOKED_AS=c11-core`, and `main()` lands here before any app-socket
/// code. Talks only to c11's own verified hc core (see `HCCoreUtility`).
enum C11CoreCLI {
    static let usage = """
    c11-core: c11's hc core, from any terminal

    Usage:
      c11-core [--all] [--json]          the core, its holder, terminals and machines
      c11-core show <terminal> [--json]  one terminal in detail
      c11-core watch                     the same, refreshed every 2 s (keys: ↑↓ o O r q)
      c11-core open <terminal> [--take-over] [--yes]
                                          open it in Terminal.app: watch only by default;
                                          --take-over types and takes the size (asks first)
      c11-core restart [--yes] [--json]  restart the core; the holder keeps every terminal
      c11-core reconnect <machine> [--yes] [--json]
      c11-core link <machine> [--yes] [--json]
                                          link a machine; --yes is refused inside a c11 terminal
      c11-core abandoned [--all] [--json]
                                          hc sessions whose core and holder are gone,
                                          with what their terminals left running
      c11-core end-abandoned <session> [--grace <s>] [--yes] [--json]
                                          end that session's leftovers: SIGHUP, then
                                          SIGKILL after the grace (default 3 s)

    The core commands (status, show, watch, open, restart, reconnect, link) use
    c11's own session and socket for this build (HC_SESSION and HC_SOCKET are
    ignored there), and only after checking the core is c11's pinned build.
    abandoned and end-abandoned read other sessions' records; HC_SESSION only
    adds the caller's own session to those they never touch. Never starts a
    core of its own, never updates hc, never kills by name.
    Exit codes: 0 ok · 2 usage · 3 not c11's core · 4 core not running · 5 action failed · 6 declined
    · 7 not abandoned (this build's session, a running core or a live holder).
    """

    struct Options {
        var json = false
        var all = false
        var yes = false
        var takeOver = false
        var grace: TimeInterval?
        var positional: [String] = []
    }

    static func run(_ arguments: [String]) -> Int32 {
        var options = Options()
        var pendingGrace = false
        for argument in arguments {
            if pendingGrace {
                pendingGrace = false
                guard let seconds = TimeInterval(argument), seconds >= 0, seconds <= 60 else {
                    return usageError("--grace takes seconds, 0 to 60")
                }
                options.grace = seconds
                continue
            }
            switch argument {
            case "--grace": pendingGrace = true
            case "--json": options.json = true
            case "--all": options.all = true
            case "--yes", "-y": options.yes = true
            case "--take-over": options.takeOver = true
            case "--help", "-h", "help":
                print(usage)
                return HCCoreExit.ok
            default:
                if argument.hasPrefix("-") {
                    return usageError("unknown option \(argument)")
                }
                options.positional.append(argument)
            }
        }
        if pendingGrace { return usageError("--grace takes seconds, 0 to 60") }
        let verb = options.positional.first ?? "status"
        let rest = Array(options.positional.dropFirst())
        switch verb {
        case "status": return rest.isEmpty ? status(options) : usageError("status takes no arguments")
        case "show": return rest.count == 1 ? show(rest[0], options) : usageError("show <terminal>")
        case "watch": return rest.isEmpty ? watch() : usageError("watch takes no arguments")
        case "open": return rest.count == 1 ? open(rest[0], options) : usageError("open <terminal> [--take-over]")
        case "restart": return rest.isEmpty ? restart(options) : usageError("restart takes no arguments")
        case "reconnect": return rest.count == 1 ? reconnect(rest[0], options) : usageError("reconnect <machine>")
        case "link": return rest.count == 1 ? link(rest[0], options) : usageError("link <machine>")
        case "abandoned": return rest.isEmpty ? abandoned(options) : usageError("abandoned takes no arguments")
        case "end-abandoned": return rest.count == 1 ? endAbandoned(rest[0], options) : usageError("end-abandoned <session>")
        case "update", "start", "stop", "kill":
            fail("c11's hc is pinned and its lifetime is c11's: \(verb) is not something c11-core does. Updates arrive with c11.")
            return HCCoreExit.usage
        default:
            return usageError("unknown command \(verb)")
        }
    }

    // MARK: context

    static var bundleIdentifier: String? {
        if let id = ProcessInfo.processInfo.environment["CMUX_BUNDLE_ID"], !id.isEmpty { return id }
        var url = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func launchConfiguration() throws -> HCLaunchConfiguration {
        try HCLaunchPolicy.configuration(home: home, tag: launchTag, inherited: [:])
    }

    private static var launchTag: String? {
        C11Identity.hcLaunchTag(environment: ProcessInfo.processInfo.environment, bundleIdentifier: bundleIdentifier)
    }

    /// C11H-391: the session `c11 machine link` links in: c11's own shard 0,
    /// the links session while this app has adopted c11h's (never c11h's).
    static func linkConfiguration() throws -> HCLaunchConfiguration {
        try HCLaunchPolicy.linksConfiguration(home: home, tag: launchTag, inherited: [:]) ?? launchConfiguration()
    }

    /// Whether this app runs c11h's adopted sessions (C11H-391).
    static var adopted: Bool { HCLaunchPolicy.processNamespace != nil }

    /// One host per process, so `watch` keeps the verifier's pin-hash cache.
    static let host = HCCoreSystemHost(bundleIdentifier: bundleIdentifier)

    static var insideC11h: Bool {
        let env = ProcessInfo.processInfo.environment
        return (env["C11_PANEL_ID"] ?? env["CMUX_SURFACE_ID"]).map { !$0.isEmpty } ?? false
    }

    static var style: HCCoreStyle {
        let tty = isatty(STDOUT_FILENO) != 0
        return HCCoreStyle(color: tty && ProcessInfo.processInfo.environment["NO_COLOR"] == nil, links: tty && insideC11h)
    }

    static func usageError(_ message: String) -> Int32 {
        fail(message + "\n\n" + usage)
        return HCCoreExit.usage
    }

    static func fail(_ message: String) {
        FileHandle.standardError.c11SafeWrite(Data(("c11-core: " + message + "\n").utf8))
    }

    /// Verifies c11's core, or prints the refusal and returns its exit code.
    static func connect(json: Bool) -> (HCCoreConnection?, Int32) {
        let configuration: HCLaunchConfiguration
        do { configuration = try launchConfiguration() } catch {
            fail("this build has no valid hc session (\(error))")
            return (nil, HCCoreExit.usage)
        }
        let env = ProcessInfo.processInfo.environment
        if !json, env["HC_SESSION"] != nil || env["HC_SOCKET"] != nil {
            FileHandle.standardError.c11SafeWrite(Data("note: ignoring HC_SESSION and HC_SOCKET. c11-core only talks to session \(configuration.session).\n".utf8))
        }
        switch HCCoreUtility.open(configuration, host: host) {
        case .verified(let connection):
            return (connection, HCCoreExit.ok)
        case .refused(let refusal, let checks, let detail):
            if json {
                print(HCCoreUtility.encode(HCCoreUtility.refusalJSON(refusal, checks: checks, detail: detail, configuration: configuration)))
            } else if refusal == .coreNotRunning {
                fail("c11's core is not running (\(detail)). Open c11; it starts its own core. c11-core never starts one.")
            } else {
                fail("refused. The core on \(configuration.socketURL.path) is not c11's \(configuration.session) core: \(detail). Nothing was read or changed; c11-core never kills by name.")
            }
            return (nil, refusal.exitCode)
        }
    }

    // MARK: read

    static func status(_ options: Options) -> Int32 {
        let (connection, code) = connect(json: options.json)
        guard let connection else { return code }
        defer { connection.link.close() }
        do {
            let snapshot = try HCCoreUtility.snapshot(connection, host: host)
            // C11H-352: other sessions' leftovers, counted (an added field within c11.core/1).
            let scan = HCAbandonedSessions.scan(abandonedContext(), host: abandonedHost)
            if options.json {
                var object = HCCoreUtility.json(snapshot)
                object["abandoned"] = ["sessions": scan.sessions.count, "processes": scan.processCount,
                                       "unreadable": scan.unreadableCount]
                print(HCCoreUtility.encode(object))
            } else {
                print(HCCoreUtility.renderStatus(snapshot, style: style, home: home.path, all: options.all, insideC11h: insideC11h))
                if !scan.sessions.isEmpty {
                    print("abandoned: \(scan.sessions.count) hc session(s) whose core is gone still run \(scan.processCount) process(es). c11-core abandoned lists them.")
                }
                if scan.unreadableCount > 0 {
                    print("abandoned: could not read \(scan.unreadableCount) hc session(s); c11-core abandoned --all names them.")
                }
            }
            return HCCoreExit.ok
        } catch {
            fail("could not read the core: \(HCCoreUtility.printable("\(error)"))")
            return HCCoreExit.actionFailed
        }
    }

    /// C11H-357: `show` and `open` take only hc's address shape, before connecting.
    static func addressError(_ verb: String, _ address: String) -> Int32 {
        usageError(HCCoreUtility.addressRefusal(verb, address))
    }

    static func find(_ address: String, in snapshot: HCCoreSnapshot) -> HCCoreTerminal? {
        snapshot.terminals.first { $0.address == address }
    }

    static func show(_ address: String, _ options: Options) -> Int32 {
        guard HCCoreUtility.isTerminalAddress(address) else { return addressError("show", address) }
        let (connection, code) = connect(json: options.json)
        guard let connection else { return code }
        defer { connection.link.close() }
        guard let snapshot = try? HCCoreUtility.snapshot(connection, host: host) else {
            fail("could not read the core")
            return HCCoreExit.actionFailed
        }
        guard let terminal = find(address, in: snapshot) else {
            fail("no terminal \(address) on c11's core.")
            return HCCoreExit.usage
        }
        if options.json {
            let items = (HCCoreUtility.json(snapshot)["terminals"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            print(HCCoreUtility.encode(items.first { $0["address"] as? String == address } ?? [:]))
        } else {
            print(HCCoreUtility.renderShow(terminal, snapshot: snapshot, style: style, home: home.path, insideC11h: insideC11h))
        }
        return HCCoreExit.ok
    }

    // MARK: confirm

    /// Asks only when `HCCoreUtility.shouldAsk` says so; the decision itself
    /// is `HCCoreUtility.consent`, which the tests drive.
    static func consent(_ question: String, _ options: Options, required: Bool = true) -> HCCoreConsent {
        let tty = isatty(STDIN_FILENO) != 0
        var answer: Bool?
        if HCCoreUtility.shouldAsk(required: required, yes: options.yes, json: options.json, tty: tty) {
            print("\(question) [y/N] ", terminator: "")
            fflush(stdout)
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            answer = line == "y" || line == "yes"
        }
        return HCCoreUtility.consent(required: required, yes: options.yes, json: options.json, tty: tty, answer: answer)
    }

    static func needsYes(_ options: Options) -> Int32 {
        if options.json {
            print(HCCoreUtility.encode(["ok": false, "error": ["code": "needs_yes", "detail": "actions need --yes with --json or without a TTY"]]))
        } else {
            fail("actions need --yes without a TTY.")
        }
        return HCCoreExit.usage
    }

    static func declined() -> Int32 {
        print("Nothing changed.")
        return HCCoreExit.declined
    }

    static func actionResult(_ action: String, ok: Bool, _ fields: [String: Any], options: Options, text: String) -> Int32 {
        if options.json {
            var object: [String: Any] = ["schema": HCCoreUtility.actionSchema, "action": action, "ok": ok]
            object.merge(fields) { _, new in new }
            print(HCCoreUtility.encode(object))
        } else {
            print(text)
        }
        return ok ? HCCoreExit.ok : HCCoreExit.actionFailed
    }

    // MARK: abandoned sessions (C11H-352)

    static let abandonedHost = HCKernelAbandonedHost()

    /// This build's session family and the caller's are never candidates.
    static func abandonedContext() -> HCAbandonedSessions.Context {
        let environment = ProcessInfo.processInfo.environment
        let tag = C11Identity.hcLaunchTag(environment: environment, bundleIdentifier: bundleIdentifier)
        return HCAbandonedSessions.Context.local(home: home, ownSessions: [try? launchConfiguration().session, HCShardID.base(tag: tag)],
                                                 environment: environment)
    }

    static func abandoned(_ options: Options) -> Int32 {
        let context = abandonedContext()
        let scan = HCAbandonedSessions.scan(context, host: abandonedHost)
        if options.json {
            print(HCCoreUtility.encode(HCAbandonedSessions.json(scan, context: context)))
            return HCCoreExit.ok
        }
        if scan.sessions.isEmpty && scan.unreadableCount == 0 {
            print("No abandoned hc sessions: every c11 session under \(context.stateRoot.path) has a core, a live holder or nothing left running.")
        } else if scan.sessions.isEmpty {
            print("No abandoned hc sessions found, but could not read \(scan.unreadableCount) of them, so that is not a proven none. c11-core abandoned --all names them.")
        } else if scan.unreadableCount > 0 {
            print("Could not read \(scan.unreadableCount) other hc session(s); c11-core abandoned --all names them.")
        }
        for session in scan.sessions { print(HCAbandonedSessions.line(session)) }
        if options.all {
            for skipped in scan.skipped { print("skipped session=\(skipped.session) why=\(skipped.verdict.code)") }
        }
        if let first = scan.sessions.first {
            print("End one with: c11-core end-abandoned \(first.session)")
        }
        return HCCoreExit.ok
    }

    static func endAbandoned(_ session: String, _ options: Options) -> Int32 {
        guard (try? launchConfiguration()) != nil else {
            fail("this build has no valid hc session, so it cannot tell its own sessions apart. Nothing was changed.")
            return HCCoreExit.usage
        }
        let context = abandonedContext()
        let verdict = HCAbandonedSessions.evaluate(session, context, host: abandonedHost)
        guard case .abandoned(let found) = verdict else {
            return abandonedRefusal(session, verdict, options: options)
        }
        let grace = options.grace ?? HCAbandonedSessions.grace
        if !options.json {
            print(HCAbandonedSessions.line(found))
            print("Ends \(found.leftovers.count) process(es) left by \(found.terminalsLeft) terminal(s) of \(session): SIGHUP, then SIGKILL after \(String(format: "%g", grace)) s.")
            if found.unverified > 0 {
                print("\(found.unverified) process(es) in those sessions failed the identity checks and are left alone.")
            }
        }
        switch consent("End \(session)'s leftovers now?", options) {
        case .needsYes: return needsYes(options)
        case .declined: return declined()
        case .proceed: break
        }
        let started = Date()
        switch HCAbandonedSessions.end(session, context, host: abandonedHost, grace: grace) {
        case .failure(let refused):
            return abandonedRefusal(session, refused, options: options)
        case .success(let result):
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let text: String
            if let refused = result.escalationRefused {
                text = "Sent SIGHUP to \(result.hungUp) process(es) of \(session), then stopped: after the grace it was no longer abandoned (\(refused)), so nothing got SIGKILL."
            } else if let unconfirmed = result.unconfirmed {
                text = "Sent SIGHUP to \(result.hungUp) and SIGKILL to \(result.killed) process(es) of \(session), but could not confirm the result (\(unconfirmed)): remaining unknown."
            } else if result.succeeded {
                text = "Ended \(result.hungUp) process(es) of \(session) (\(result.killed) by SIGKILL) in \(String(format: "%.1f", Double(elapsed) / 1000)) s."
            } else {
                text = "\(result.remaining ?? 0) process(es) of \(session) are still running after SIGKILL. c11-core abandoned --json lists them."
            }
            var fields: [String: Any] = [
                "session": session,
                "terminals": result.terminals,
                "processes": ["hung_up": result.hungUp, "killed": result.killed, "remaining": HCCoreUtility.n(result.remaining),
                              "unverified": result.unverified],
                "elapsed_ms": elapsed,
            ]
            if let refused = result.escalationRefused { fields["escalation_refused"] = refused }
            if let unconfirmed = result.unconfirmed { fields["unconfirmed"] = unconfirmed }
            return actionResult("end-abandoned", ok: result.succeeded, fields, options: options, text: text)
        }
    }

    static func abandonedRefusal(_ session: String, _ verdict: HCAbandonedVerdict, options: Options) -> Int32 {
        let detail: String
        let code: Int32
        switch verdict {
        case .clean:
            return actionResult("end-abandoned", ok: true, ["session": session, "changed": false], options: options,
                                text: "Nothing of \(session)'s terminals is still running. Nothing to do.")
        case .unverifiedOnly(let count):
            return actionResult("end-abandoned", ok: true, ["session": session, "changed": false, "unverified": count], options: options,
                                text: "\(count) process(es) in \(session)'s terminal sessions could not be proven to be its, so nothing was ended.")
        case .notFound:
            detail = "no c11 hc session named \(session) under ~/.local/state/herdr-core"
            code = HCCoreExit.usage
        case .current:
            detail = "\(session) is this build's session (or the one you are in); its own core ends what its terminals leave"
            code = HCCoreExit.notAbandoned
        case .coreRunning:
            detail = "a core still serves \(session); hc ends its lost terminals itself"
            code = HCCoreExit.notAbandoned
        case .holderAlive:
            detail = "a holder still holds \(session)'s terminals; they are live, not leftovers"
            code = HCCoreExit.notAbandoned
        case .unreadable(let why):
            detail = "\(session) could not be read (\(why)); nothing is ended on a guess"
            code = HCCoreExit.actionFailed
        case .abandoned:
            detail = "abandoned"
            code = HCCoreExit.ok
        }
        if options.json {
            print(HCCoreUtility.encode(["schema": HCCoreUtility.actionSchema, "action": "end-abandoned", "ok": false,
                                        "session": session, "error": ["code": verdict.code, "detail": detail]]))
        } else {
            fail("refused: \(detail). Nothing was changed.")
        }
        return code
    }

    // MARK: open

    static func open(_ address: String, _ options: Options) -> Int32 {
        guard HCCoreUtility.isTerminalAddress(address) else { return addressError("open", address) }
        let (connection, code) = connect(json: options.json)
        guard let connection else { return code }
        defer { connection.link.close() }
        guard let snapshot = try? HCCoreUtility.snapshot(connection, host: host),
              let terminal = find(address, in: snapshot), terminal.state == "live" else {
            fail("no live terminal \(address) on c11's core.")
            return HCCoreExit.usage
        }
        if options.takeOver, !options.json { print(HCCoreUtility.takeOverWarning(terminal)) }
        switch consent("Take over \(address) in Terminal.app?", options, required: options.takeOver) {
        case .needsYes: return needsYes(options)
        case .declined: return declined()
        case .proceed: break
        }
        do {
            let plan = try HCCoreUtility.openPlan(address: address, takeOver: options.takeOver, configuration: connection.configuration)
            try launchInTerminal(plan)
        } catch {
            return actionResult("open", ok: false, ["address": address, "error": "\(error)"], options: options,
                                text: "Could not open Terminal.app: \(HCCoreUtility.printable("\(error)"))")
        }
        return actionResult("open", ok: true, ["address": address, "mode": options.takeOver ? "take_over" : "watch"], options: options,
                            text: options.takeOver
                                ? "Opened \(address) in Terminal.app, taking it over (ctrl+\\ detaches)."
                                : "Opened \(address) in Terminal.app, watch only: typing there is ignored and c11 keeps its size (ctrl+\\ detaches).")
    }

    static func launchInTerminal(_ plan: HCCoreOpenPlan) throws {
        let directory = home.appendingPathComponent(".local/share/c11/core", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(plan.fileName)
        try Data(plan.script.utf8).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: file)
            throw HCCoreRPCError(code: "open", message: "open -a Terminal exited \(process.terminationStatus)")
        }
    }

    // MARK: restart

    static func restart(_ options: Options) -> Int32 {
        let (connection, code) = connect(json: options.json)
        guard let connection else { return code }
        let before = try? HCCoreUtility.snapshot(connection, host: host)
        let liveBefore = Set(before?.live.filter(\.isLocal).map(\.address) ?? [])
        if !options.json {
            for check in connection.checks { print("  ✓ \(check.check): \(check.detail)") }
            print("A restart keeps your terminals: the holder\(before?.holderPID.map { " (pid \($0))" } ?? "") keeps every program running,")
            print("and c11 reconnects its panels by itself.")
        }
        switch consent("Restart c11's core now?", options) {
        case .needsYes: connection.link.close(); return needsYes(options)
        case .declined: connection.link.close(); return declined()
        case .proceed: break
        }
        let started = Date()
        let outcome = HCCoreUtility.restart(connection, host: host)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        switch outcome {
        case .restarted(let next):
            defer { next.link.close() }
            let after = try? HCCoreUtility.snapshot(next, host: host)
            let liveAfter = Set(after?.live.filter(\.isLocal).map(\.address) ?? [])
            let adopted = liveBefore.intersection(liveAfter).count
            let exact = after?.live.filter { $0.isLocal && $0.screenCopy == "exact" }.count ?? 0
            return actionResult("restart", ok: true, [
                "before": ["core_pid": connection.corePID, "holder_pid": HCCoreUtility.n(before?.holderPID)],
                "after": ["core_pid": next.corePID, "holder_pid": HCCoreUtility.n(after?.holderPID), "pin_ok": true],
                "terminals": ["adopted": adopted, "lost": liveBefore.subtracting(liveAfter).count, "screens_exact": exact],
                "elapsed_ms": elapsed,
            ], options: options, text: "  new core pid \(next.corePID) · \(adopted)/\(liveBefore.count) terminals adopted · \(exact) screen copies exact\nDone in \(String(format: "%.1f", Double(elapsed) / 1000)) s.")
        case .failed(let detail):
            return actionResult("restart", ok: false, ["error": ["code": "action_failed", "detail": detail], "elapsed_ms": elapsed],
                                options: options, text: "Restart failed: \(detail)")
        }
    }

    // MARK: reconnect and link

    static func reconnect(_ machine: String, _ options: Options) -> Int32 {
        let (connection, code) = connect(json: options.json)
        guard let connection else { return code }
        defer { connection.link.close() }
        let machines = ((try? connection.link.call("machine.list"))?["machines"] as? [[String: Any]]) ?? []
        guard let entry = machines.first(where: { $0["name"] as? String == machine }) else {
            let names = machines.compactMap { ($0["name"] as? String).map { HCCoreUtility.printable($0) } }
            fail("no machine named \(HCCoreUtility.printable(machine)) on c11's core. Linked: \(names.isEmpty ? "none" : names.joined(separator: ", ")).")
            return HCCoreExit.usage
        }
        if entry["state"] as? String == "connected" {
            return actionResult("reconnect", ok: true, ["machine": machine, "state": "connected", "changed": false], options: options,
                                text: "\(HCCoreUtility.printable(machine)) is connected. Nothing to do.")
        }
        switch consent("Reconnect \(HCCoreUtility.printable(machine)) now?", options) {
        case .needsYes: return needsYes(options)
        case .declined: return declined()
        case .proceed: break
        }
        let result = HCCoreUtility.runPinned(HCCoreUtility.reconnectPlan(machine: machine), configuration: connection.configuration, interactive: !options.json)
        let state = (((try? connection.link.call("machine.list"))?["machines"] as? [[String: Any]]) ?? [])
            .first { $0["name"] as? String == machine }?["state"] as? String ?? "unknown"
        let shown = HCCoreUtility.printable(machine)
        return actionResult("reconnect", ok: state == "connected", ["machine": machine, "state": state, "exit": result.status],
                            options: options, text: state == "connected" ? "\(shown) connected."
                                : "\(shown) is still \(HCCoreUtility.printable(state)). \(HCCoreUtility.printable(result.output, keepLineFeeds: true))")
    }

    /// `machine` is hc's name for the remote machine, the one its via script reaches.
    static func link(_ machine: String, _ options: Options) -> Int32 {
        guard HCCoreUtility.isLinkMachineName(machine) else {
            return usageError(HCCoreUtility.linkNameRefusal(machine))
        }
        // C11H-365: refused before anything is read, as `c11 machine link --yes` is.
        if let refusal = HCCoreUtility.linkYesRefusal(machine: machine, yes: options.yes,
                                                      environment: ProcessInfo.processInfo.environment) {
            if options.json {
                print(HCCoreUtility.encode(["ok": false, "error": ["code": "yes_refused_in_c11", "detail": refusal]]))
            } else {
                fail(refusal)
            }
            return HCCoreExit.usage
        }
        let (connection, code) = connect(json: options.json)
        guard let connection else { return code }
        defer { connection.link.close() }
        // An existing link keeps its installed via script and serving core.
        // Validate the current build's script only when adding a new link.
        let machines = ((try? connection.link.call("machine.list"))?["machines"] as? [[String: Any]]) ?? []
        if let entry = machines.first(where: { $0["name"] as? String == machine }) {
            // C11H-332: an existing link is kept only when its via checks a pin.
            let script = HCCoreBinary.appBundle(main: Bundle.main.bundleURL, executable: Bundle.main.executableURL)
                .map { HCMachineSetupResources.inBundle($0).linkScript }
            switch HCCoreUtility.reviewExistingLink(machine: machine, viaPath: entry["target"] as? String, home: home,
                                                    configuration: connection.configuration, linkScript: script) {
            case .pinned, .migrated:
                return actionResult("link", ok: true, ["machine": machine, "changed": false], options: options,
                                    text: "\(machine) is already linked. Use c11-core reconnect \(machine) if it is down.")
            case .unusable(let code):
                return actionResult("link", ok: false, ["machine": machine, "error": ["code": "link_unusable",
                                    "detail": code]], options: options,
                                    text: "c11 won't use \(machine)'s link: it doesn't check c11's hc, or its ssh may forward your agent, X11 or ports, and c11 couldn't update it (\(code)). hc may still redial it until you Update or Remove it in Settings > Herder Topography.")
            }
        }
        let via = home.appendingPathComponent(".local/share/c11/atlas-via.sh")
        let script = HCStoredLinks.ownedVia(via.path, home: home)
        let plan = HCCoreUtility.admitLink(via: via, script: script,
                                           machine: machine, configuration: connection.configuration)
        guard case .ready(let argv) = plan else {
            if case .refused(let reason) = plan {
                return actionResult("link", ok: false, ["error": ["code": "action_failed", "detail": reason]], options: options,
                                    text: "Not linked: \(reason)")
            }
            return HCCoreExit.actionFailed
        }
        if !options.json {
            for line in HCCoreUtility.linkPlanLines(machine: machine, viaPath: via.path, script: script) { print(line) }
        }
        switch consent("Link \(machine) now?", options) {
        case .needsYes: return needsYes(options)
        case .declined: return declined()
        case .proceed: break
        }
        let result = HCCoreUtility.runPinned(argv, configuration: connection.configuration)
        let entry = (((try? connection.link.call("machine.list"))?["machines"] as? [[String: Any]]) ?? [])
            .first { $0["name"] as? String == machine }
        let state = entry?["state"] as? String ?? "absent"
        let version = entry?["version"] as? String
        // A link that reports no version is not known to run the pin.
        let ok = state == "connected" && version == connection.configuration.pin.version
        // C11H-332: this link entry point is audited like Add Machine.
        C11AuditLog.shared.append(C11AuditRecord(kind: .link, via: "c11-core", outcome: ok ? "ok" : "failed",
                                                  machine: machine, session: connection.configuration.session,
                                                  path: via.path, code: ok ? nil : "not_connected"))
        return actionResult("link", ok: ok, ["machine": machine, "state": state, "version": HCCoreUtility.n(version), "exit": result.status,
                                             "ssh_target": HCCoreUtility.n(HCCoreUtility.linkSSHTarget(script: script))],
                            options: options, text: ok ? "Linked: \(machine) connected (hc \(version ?? "?"))."
                                : "\(machine) is \(HCCoreUtility.printable(state)). \(HCCoreUtility.printable(result.output, keepLineFeeds: true))")
    }

    // MARK: watch

    static func watch() -> Int32 {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            fail("watch needs a terminal.")
            return HCCoreExit.usage
        }
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        print("\u{1B}[?25l", terminator: "")
        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            print("\u{1B}[?25h")
        }
        var selected = 0
        var message = ""
        while true {
            var frame = ""
            var live: [HCCoreTerminal] = []
            let (connection, code) = connectQuietly()
            if let connection {
                if let snapshot = try? HCCoreUtility.snapshot(connection, host: host) {
                    live = snapshot.live
                    selected = min(selected, max(0, live.count - 1))
                    frame = HCCoreUtility.renderWatch(snapshot, selected: selected, style: style, home: home.path, insideC11h: insideC11h)
                }
                connection.link.close()
            } else {
                frame = code == HCCoreExit.notRunning
                    ? "c11's core is not running. Open c11; it starts its own core. (q quits)"
                    : "The core on c11's socket is not c11's pinned build; nothing is read. (q quits)"
            }
            print("\u{1B}[H\u{1B}[2J" + frame + (message.isEmpty ? "" : "\n\n" + message), terminator: "")
            fflush(stdout)
            message = ""
            guard let key = readKey(timeout: 2) else { continue }
            switch key {
            case "q", "\u{1B}": return HCCoreExit.ok
            case "up": selected = max(0, selected - 1)
            case "down": selected = min(max(0, live.count - 1), selected + 1)
            case "o", "O":
                guard live.indices.contains(selected) else { continue }
                tcsetattr(STDIN_FILENO, TCSANOW, &original)
                print("\u{1B}[H\u{1B}[2J", terminator: "")
                let code = open(live[selected].address, Options(takeOver: key == "O"))
                tcsetattr(STDIN_FILENO, TCSANOW, &raw)
                message = code == HCCoreExit.ok ? "Opened \(live[selected].address) in Terminal.app." : "Open did not complete."
            case "r":
                tcsetattr(STDIN_FILENO, TCSANOW, &original)
                print("\u{1B}[H\u{1B}[2J", terminator: "")
                _ = restart(Options())
                print("\nPress any key.", terminator: "")
                fflush(stdout)
                tcsetattr(STDIN_FILENO, TCSANOW, &raw)
                _ = readKey(timeout: 30)
            default: continue
            }
        }
    }

    static func connectQuietly() -> (HCCoreConnection?, Int32) {
        guard let configuration = try? launchConfiguration() else { return (nil, HCCoreExit.usage) }
        switch HCCoreUtility.open(configuration, host: host) {
        case .verified(let connection): return (connection, HCCoreExit.ok)
        case .refused(let refusal, _, _): return (nil, refusal.exitCode)
        }
    }

    static func readKey(timeout: TimeInterval) -> String? {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        let count = read(STDIN_FILENO, &bytes, bytes.count)
        guard count > 0 else { return "q" }
        let input = Array(bytes[0..<count])
        if input == [27, 91, 65] { return "up" }
        if input == [27, 91, 66] { return "down" }
        return String(decoding: input.prefix(1), as: UTF8.self)
    }
}
