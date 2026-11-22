import AppKit
import Foundation

/// The first thing c11 2.0 does (C11H-266), from the first stored property of
/// `cmuxApp`, so it runs before any other initializer reads a setting or a file.
///
/// It returns only when normal startup may go ahead. Work that can copy state,
/// a running c11h, an error, or a record it cannot act on hands off to the
/// migration gate: a separate process
/// of this same app that shows one plain, non-modal window saying what happened,
/// that c11h's own state is untouched, and how to go back; this process exits
/// before creating any state, hc session or window.
enum C11MigrationLaunch {
    static let gateArgument = "--c11-migration-gate"

    static func bootstrap(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let index = CommandLine.arguments.firstIndex(of: gateArgument) {
            C11MigrationGate.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
        }
        let bundle = bundleIdentifier ?? ""
        let layout = makeLayout(home: home, bundle: bundle, environment: environment)
        guard isAllowed(layout, environment: environment) else { return }
        let log = makeLog(layout)
        do {
            try withMigrationLock(layout) {
                // A source app may take arbitrarily long to save. The visible gate
                // owns that wait and every operation that can copy or scan a tree.
                if !runningLegacyApp().isEmpty { handOff(.reconcile, log: log) }
                let record = try C11MigrationState.load(home: home)
                switch record?.phase {
                case .fresh?, .inPlace1x?:
                    guard record?.owner == bundle else { throw Failure.unavailable("migration record owner") }
                case .converged?:
                    try C11MigrationExecutor(layout: layout, log: log, defaults: .system).verifyCommittedLayout()
                case .adopted?:
                    let prepared = try prepare(layout, defaults: .system, environment: environment, log: log)
                    guard prepared == .stayAdopted else { handOff(.reconcile, log: log) }
                    do {
                        try C11MigrationExecutor(layout: layout, log: log, defaults: .system).verifyCommittedLayout()
                    } catch {
                        // A link missing after interruption is repaired from disk by
                        // the worker, never by a normal startup state consumer.
                        handOff(.reconcile, log: log)
                    }
                default:
                    handOff(.reconcile, log: log)
                }
            }
        } catch {
            log.line("plan", "failed", ["error": String(describing: error)])
            handOff(.error(String(describing: error)), log: log)
        }
        if C11AdoptionRecord.resolve(home: home, bundleIdentifier: bundle) != nil {
            C11AdoptionSocketLink.install(layout: layout)
        }
    }

    enum Failure: Error { case unavailable(String) }

    private static func makeLayout(home: URL, bundle: String, environment: [String: String]) -> C11MigrationLayout {
        var layout = C11MigrationLayout(home: home)
        layout.destSupportName = C11Identity.stateDirectoryName
        layout.destBundleIdentifier = bundle
        layout.destHCBase = destinationBase(environment: environment, bundleIdentifier: bundle)
        return layout
    }

    private static func isAllowed(_ layout: C11MigrationLayout, environment: [String: String]) -> Bool {
        layout.destSupportName != layout.sourceSupportName && C11MigrationPlanner.allowed(
            bundleIdentifier: layout.destBundleIdentifier, destBundleIdentifier: C11Identity.releaseBundleIdentifier,
            environment: environment)
    }

    private static func makeLog(_ layout: C11MigrationLayout) -> C11MigrationLog {
        C11MigrationLog(url: layout.logsDirectory.appendingPathComponent(C11Migration.logFileName),
                        run: String(UUID().uuidString.prefix(8)).lowercased())
    }

    private static func withMigrationLock<T>(_ layout: C11MigrationLayout, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: layout.appSupport, withIntermediateDirectories: true)
        let path = layout.appSupport.appendingPathComponent("\(layout.destSupportName).migration.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.unavailable("migration lock: errno \(errno)") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure.unavailable("Another copy of c11 is moving your workspaces right now.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// The gate's main run loop remains available while this worker waits, probes,
    /// stamps and copies. Only UserDefaults and AppKit discovery hop onto main.
    static func reconcileInGate(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        precondition(!Thread.isMainThread)
        var layout = makeLayout(home: home, bundle: bundleIdentifier ?? "", environment: environment)
        guard isAllowed(layout, environment: environment) else { throw Failure.unavailable("migration is not enabled for this app") }
        let log = makeLog(layout)
        try withMigrationLock(layout) {
            layout.sourceApp = onMain { legacyAppPath() }
            let running = onMain { runningLegacyApp() }
            if !running.isEmpty {
                log.line("wait_c11h", "quitting", ["pids": running.map { Int($0) }])
                for pid in running { kill(pid, SIGTERM) }
                let deadline = ProcessInfo.processInfo.systemUptime + C11MigrationGate.legacyQuitBudget
                var alive = running
                while !alive.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
                    autoreleasepool {
                        usleep(200_000)
                        alive = alive.filter { kill($0, 0) == 0 || errno == EPERM }
                    }
                }
                guard alive.isEmpty else { throw Failure.unavailable("c11h has not quit, so nothing has moved.") } // c11-2.0:legacy
                log.line("wait_c11h", "ok")
            }
            let defaults = mainThreadDefaults(.system)
            let decision = try prepare(layout, defaults: defaults, environment: environment, log: log)
            var executor = C11MigrationExecutor(layout: layout, log: log, defaults: defaults)
            if environment["C11_MIGRATION_QA"] == "1", let target = environment["C11_MIGRATION_FAULT"], !target.isEmpty {
                executor.fault = { step in
                    guard step == target else { return }
                    log.line(step, "fault_injected")
                    exit(86)
                }
            }
            do {
                try executor.run(decision)
            } catch {
                log.line("plan", "failed", ["error": String(describing: error)])
                throw error
            }
        }
    }

    static func mainThreadDefaults(_ defaults: C11MigrationDefaults) -> C11MigrationDefaults {
        C11MigrationDefaults(read: { domain in onMain { defaults.read(domain) } },
                             replace: { domain, values in onMain { defaults.replace(domain, values) } })
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private static func prepare(_ layout: C11MigrationLayout, defaults: C11MigrationDefaults,
                                environment: [String: String], log: C11MigrationLog) throws -> C11MigrationDecision {
        let record = try C11MigrationState.load(home: layout.home)
        let legacyState = FileManager.default.fileExists(atPath: layout.sourceSnapshot.path)
            || FileManager.default.fileExists(atPath: layout.sourceSupport.appendingPathComponent("workspaces").path)
        let converge = C11MigrationPlanner.convergeEnabled(environment: environment)
        let needsProbe = needsLivenessProbe(record: record, legacyState: legacyState, convergeEnabled: converge)
        let liveness = needsProbe ? adoptedWorldLiveness(layout) : nil
        if case .unknown(let reason)? = liveness {
            log.line("plan", "stop", ["world_state": "unknown", "reason": reason])
            throw Failure.unavailable("The adopted terminals could not be checked: \(reason)")
        }
        let inventory = C11MigrationInventory.read(layout, oneXDefaults: defaults.read(layout.oneXBundleIdentifier),
                                                   worldAlive: liveness == .alive)
        let decision = C11MigrationPlanner.decide(record: record, inventory: inventory, legacyRunning: false,
                                                  allowed: true, owner: layout.destBundleIdentifier, convergeEnabled: converge)
        log.line("plan", "ok", ["decision": String(describing: decision), "c11h_state": inventory.legacyState, // c11-2.0:legacy
                                "c11_1x_state": inventory.oneXState, "world_state": liveness?.label ?? "skipped",
                                "record": record?.phase.rawValue ?? "none", "bundle": layout.destBundleIdentifier])
        if case .stop(let reason) = decision { throw Failure.unavailable(reason) }
        return decision
    }

    /// 2.0's own pool after convergence: `c11[-sN]`, or `c11-<tag>[-sN]` on a tagged build.
    static func destinationBase(environment: [String: String], bundleIdentifier: String) -> String {
        HCShardID.base(tag: SocketControlSettings.hcLaunchTag(environment: environment, bundleIdentifier: bundleIdentifier))
    }

    /// The liveness probe runs only when the plan needs its answer: a first launch
    /// over c11h's state, an adopted Mac deciding whether to converge, or a
    /// convergence under way checking the world has not come back (Rule B).
    /// With convergence off, nothing depends on the answer, so it never runs.
    static func needsLivenessProbe(record: C11MigrationState?, legacyState: Bool, convergeEnabled: Bool) -> Bool {
        guard convergeEnabled else { return false }
        guard let record else { return legacyState }
        return record.phase == .adopted || record.phase == .converging
    }

    enum HandOff {
        case reconcile
        case waitForLegacy([pid_t])
        case error(String)
    }

    /// Starts the gate (this app again, with the gate argument) and exits this
    /// process before it creates any state.
    static func handOff(_ reason: HandOff, log: C11MigrationLog) -> Never {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        var arguments = [gateArgument]
        switch reason {
        case .reconcile: arguments += ["reconcile"]
        case .waitForLegacy(let pids): arguments += ["wait"] + pids.map(String.init)
        case .error(let message): arguments += ["error", message]
        }
        do {
            try launchAfterParentExit(executable: executable, arguments: arguments, parentPID: getpid())
        } catch {
            log.line("gate", "failed", ["error": String(describing: error)])
            // If creating the child itself fails, display the same gate here.
            // Normal app initializers still never run, and Quit closes the lock.
            C11MigrationGate.run(arguments: ["error", String(describing: error)])
        }
        exit(0)
    }

    static func launchAfterParentExit(executable: String, arguments: [String], parentPID: pid_t,
                                      start: (Process) throws -> Void = { try $0.run() }) throws {
        let task = Process()
        // Starting the gate while this instance is still registered lets the
        // ordinary duplicate-instance guard discard it. Wait outside both apps.
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; shift; exec \"$@\"",
                          "migration-gate", String(parentPID), executable] + arguments
        try start(task)
    }

    enum Liveness: Equatable {
        case alive
        case dead
        case unknown(String)

        var label: String {
            switch self { case .alive: return "alive"; case .dead: return "dead"; case .unknown: return "unknown" }
        }
    }

    static func adoptedWorldLiveness(_ layout: C11MigrationLayout) -> Liveness {
        let links = linkedMachineLiveness(layout)
        if links == .alive { return .alive }
        let cores = coreLiveness(layout)
        if cores == .alive { return .alive }
        if case .unknown = links { return links }
        return cores
    }

    /// Compatibility callers must conservatively hold adoption on uncertainty.
    static func adoptedWorldAlive(_ layout: C11MigrationLayout) -> Bool { adoptedWorldLiveness(layout) != .dead }

    /// Inspect only the release base and eight known shards. Unreadable or malformed
    /// link inventories are not empty; a linked remote outlives its local core.
    static func linkedMachineLiveness(_ layout: C11MigrationLayout) -> Liveness {
        let state = layout.home.appendingPathComponent(".local/state/herdr-core", isDirectory: true)
        for session in [layout.sourceHCBase] + (1...8).map({ "\(layout.sourceHCBase)-s\($0)" }) {
            let file = state.appendingPathComponent(session).appendingPathComponent("machines.json")
            var info = stat()
            if lstat(file.path, &info) != 0 {
                if errno == ENOENT { continue }
                return .unknown("machine inventory \(session): errno \(errno)")
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1_048_576 else {
                return .unknown("invalid machine inventory \(session)")
            }
            do {
                let data = try Data(contentsOf: file)
                guard let machines = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                    return .unknown("invalid machine inventory \(session)")
                }
                if !machines.isEmpty { return .alive }
            } catch { return .unknown("unreadable machine inventory \(session)") }
        }
        return .dead
    }

    /// The probe's retry schedule: three passes, 0.2 s apart (0.4 s for a dead world).
    static let coreProbeRetryInterval: TimeInterval = 0.2
    /// The whole probe's bound. Five times the schedule, so a loaded launch (a Mac
    /// still starting its login items after a reboot, when every socket is stale)
    /// is not cut short and reported unknown, which stops the launch.
    static let coreProbeBudget: TimeInterval = 2

    /// Core and holder probes share one monotonic deadline, including connect waits.
    /// Only an absent socket or a refused connection proves that endpoint is dead.
    /// `now` and `sleep` are the clock (monotonic uptime) and the retry wait.
    static func coreLiveness(_ layout: C11MigrationLayout, budget: TimeInterval = coreProbeBudget,
                             now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                             sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Liveness {
        let deadline = now() + max(0, budget)
        let run = layout.home.appendingPathComponent(layout.sourceHCRoot).appendingPathComponent("run", isDirectory: true)
        var info = stat()
        if lstat(run.path, &info) != 0 {
            return errno == ENOENT ? .dead : .unknown("core inventory: errno \(errno)")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .unknown("core inventory is not a directory") }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: run.path) }
        catch { return .unknown("unreadable core inventory") }
        guard names.count <= 4096 else { return .unknown("core inventory is too large") }
        let base = layout.sourceHCBase
        let sockets = names.filter { name in
            guard name.hasSuffix(".sock") else { return false }
            let stem = String(name.dropLast(5).split(separator: ".", maxSplits: 1).first ?? "")
            return stem == base || C11MigrationExecutor.rehomeSessionName(stem, from: base, to: base) != nil
        }.map { run.appendingPathComponent($0).path }
        if sockets.isEmpty { return .dead }
        var uncertainty: Liveness?
        for pass in 0..<3 {
            for path in sockets {
                guard now() < deadline else { return .unknown("core probe deadline") }
                let result = socketLiveness(path, deadline: deadline, now: now)
                if result == .alive { return .alive }
                if case .unknown = result { uncertainty = result }
            }
            if pass < 2 {
                let remaining = deadline - now()
                guard remaining > coreProbeRetryInterval else { return .unknown("core probe deadline") }
                sleep(coreProbeRetryInterval)
            }
        }
        return uncertainty ?? .dead
    }

    static func coresAlive(_ layout: C11MigrationLayout) -> Bool { coreLiveness(layout) != .dead }

    static func socketLiveness(_ path: String, deadline: TimeInterval,
                               now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Liveness {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .unknown("socket: errno \(errno)") }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return .unknown("nonblocking socket: errno \(errno)")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return .unknown("socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .alive }
        let code = errno
        if code == ECONNREFUSED || code == ENOENT { return .dead }
        guard code == EINPROGRESS else { return .unknown("connect: errno \(code)") }
        let remaining = deadline - now()
        guard remaining > 0 else { return .unknown("socket probe deadline") }
        var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&descriptorPoll, 1, Int32(min(remaining, 0.05) * 1000))
        guard ready > 0 else { return .unknown("socket did not answer") }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
            return .unknown("socket result: errno \(errno)")
        }
        if error == 0 { return .alive }
        return error == ECONNREFUSED || error == ENOENT ? .dead : .unknown("connect: errno \(error)")
    }

    static func connects(_ path: String) -> Bool {
        // The adoption socket bridge may remove a stale socket only on proven
        // absence; an uncertain endpoint must remain untouched.
        socketLiveness(path, deadline: ProcessInfo.processInfo.systemUptime + 0.05) != .dead
    }

    /// The installed c11h app: a running c11h's bundle, else LaunchServices' copy.  c11-2.0:legacy
    static func legacyAppPath() -> String? {
        let id = C11MigrationLayout(home: URL(fileURLWithPath: "/")).sourceBundleIdentifier
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL {
            return running.path
        }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).first?.path
    }

    /// A running c11h release, found by bundle id alone, whatever its path or name.  c11-2.0:legacy
    /// Tagged c11h builds have their own ids and their own state and are left alone.  c11-2.0:legacy
    static func runningLegacyApp() -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: C11MigrationLayout(home: URL(fileURLWithPath: "/")).sourceBundleIdentifier)
            .filter { !$0.isTerminated }
            .map { $0.processIdentifier }
    }
}

/// While adopted, surviving c11h agents call c11h's socket path from their  c11-2.0:legacy
/// inherited `C11_SOCKET`. Link it to this app's socket once the listener is up,
/// and take the link down at quit, so c11h finds its own path free if the  c11-2.0:legacy
/// operator goes back (C11H-266).  c11-2.0:legacy
enum C11AdoptionSocketLink {
    private static var observers: [NSObjectProtocol] = []
    private static var linkedTarget: String?

    static func install(layout: C11MigrationLayout) {
        guard observers.isEmpty else { return }
        let legacy = layout.sourceSupport.appendingPathComponent(layout.sourceSocketName).path
        observers.append(NotificationCenter.default.addObserver(forName: .socketListenerDidStart, object: nil, queue: .main) { note in
            guard let path = note.userInfo?["path"] as? String else { return }
            link(legacy: legacy, to: path, log: layout)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            unlink(legacy: legacy)
        })
    }

    static func link(legacy: String, to appSocket: String, log layout: C11MigrationLayout) {
        let fm = FileManager.default
        let log = C11MigrationLog(url: layout.logsDirectory.appendingPathComponent(C11Migration.logFileName), run: "socket")
        var info = stat()
        if lstat(legacy, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                try? fm.removeItem(atPath: legacy)
            case S_IFSOCK where !C11MigrationLaunch.connects(legacy):
                // c11h's socket from its last run, nobody listening.  c11-2.0:legacy
                try? fm.removeItem(atPath: legacy)
            default:
                log.line("socket_link", "occupied", ["path": legacy])
                return
            }
        }
        do {
            try fm.createSymbolicLink(atPath: legacy, withDestinationPath: appSocket)
            linkedTarget = appSocket
            log.line("socket_link", "ok", ["legacy": legacy, "target": appSocket])
        } catch {
            log.line("socket_link", "failed", ["error": String(describing: error)])
        }
    }

    static func unlink(legacy: String) {
        guard let target = linkedTarget,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: legacy)) == target else { return }
        try? FileManager.default.removeItem(atPath: legacy)
        linkedTarget = nil
    }
}
