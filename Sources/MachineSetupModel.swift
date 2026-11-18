import AppKit
import Combine
import Foundation

/// C11H-126 part 2: the app side of Add Machine and Remove Machine. The steps
/// themselves are `HCMachineSetupFlow` (shared with `c11 machine link`); this
/// file runs them off the main thread for Settings, ends a removed machine's
/// terminals, and reads each machine's hc version so a row can offer an update.

/// One Add Machine run, observed by the Settings sheet.
@MainActor
final class MachineSetupModel: ObservableObject {
    struct StepRow: Identifiable, Equatable {
        let step: HCMachineSetupStep
        var state: HCMachineSetupState?
        var detail: String?
        var id: String { step.rawValue }
    }

    @Published private(set) var rows: [StepRow] = HCMachineSetupStep.allCases.map { StepRow(step: $0) }
    @Published private(set) var running = false
    @Published private(set) var failure: String?
    @Published private(set) var result: HCMachineSetupResult?

    /// Test seam: replaces the process runner.
    var runner: any HCMachineSetupRunner = HCMachineSetupProcessRunner()
    /// Test seam: the composition whose link session the steps run in.
    var composition: HCBackendComposition = .shared
    /// Test seam: builds the steps for the session `start` chose.
    var makeFlow: ((HCLaunchConfiguration) -> HCMachineSetupFlow)?

    func start(host: String, name: String?, update: Bool = false) {
        guard !running else { return }
        // C11H-391: c11's own session, the links session while adopted.
        guard let configuration = composition.linkConfiguration else {
            failure = HCMachineSetupFailure.coreUnavailable("no hc session").message
            return
        }
        let links = composition.linksSession
        rows = HCMachineSetupStep.allCases.map { StepRow(step: $0) }
        failure = nil
        result = nil
        running = true
        let flow = makeFlow?(configuration) ?? HCMachineSetupFlow(
            configuration: configuration,
            resources: .inBundle(Bundle.main.bundleURL),
            runner: runner,
            localHome: FileManager.default.homeDirectoryForCurrentUser,
            verifyCore: MachineRemoval.coreCheck(configuration),
            origin: "settings",
            linuxFiles: .forBundle(Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
        )
        let request = HCMachineSetupRequest(host: host, name: name, update: update)
        Task.detached(priority: .userInitiated) { [weak self] in
            // C11H-391: the links session's core starts first; the flow then
            // proves it is c11's own pinned core before any hc command.
            if let links { _ = await links.startServing() }
            let outcome = flow.run(request) { progress in
                Task { @MainActor [weak self] in self?.apply(progress) }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.running = false
                switch outcome {
                case .success(let value):
                    self.result = value
                    NSLog("machine.setup.linked name=%@ host=%@ installed=%d", value.name, value.host, value.installedHC ? 1 : 0)
                    MachineHCStatus.shared.refresh()
                case .failure(let error):
                    self.failure = error.message
                    NSLog("machine.setup.failed code=%@", error.code)
                }
            }
        }
    }

    private func apply(_ progress: HCMachineSetupProgress) {
        guard let index = rows.firstIndex(where: { $0.step == progress.step }) else { return }
        rows[index].state = progress.state
        rows[index].detail = progress.detail
    }
}

/// hc's own view of each linked machine (state and version), read off-main
/// from `hc machine ls`, so a row can say its hc is older than this app's.
/// C11H-391: read from every session that links machines here: c11's own
/// (the links session while adopted) and the adopted c11h one beside it.
@MainActor
final class MachineHCStatus: ObservableObject {
    static let shared = MachineHCStatus()

    /// Each name once: c11's own session's entry when it lists the name, else
    /// the other session's (what a row shows and Update acts on).
    @Published private(set) var machines: [String: HCMachineSetup.ListedMachine] = [:]
    /// Session name to hc's list there.
    @Published private(set) var bySession: [String: [String: HCMachineSetup.ListedMachine]] = [:]
    var runner: any HCMachineSetupRunner = HCMachineSetupProcessRunner()
    /// Where c11's via files live (this user's home; a test passes its own).
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// The sessions `refresh` reads, c11's own first. Tests set their own.
    var sessions: () -> [HCLaunchConfiguration] = {
        let composition = HCBackendComposition.shared
        return MachineHCStatus.reads(links: composition.linksSession?.configuration, primary: composition.configuration)
    }
    private var refreshing = false
    /// A refresh asked for while one runs runs again when it ends.
    private var refreshAgain = false

    var pinVersion: String? { HCBackendComposition.shared.configuration?.pin.version }

    nonisolated static func distinct(_ configurations: [HCLaunchConfiguration]) -> [HCLaunchConfiguration] {
        var seen: Set<String> = []
        return configurations.filter { seen.insert($0.session).inserted }
    }

    /// C11H-391: the sessions Settings reads, c11's own first. `hc machine ls`
    /// starts a core for the session it names, so the links session is read
    /// only once its own `machines.json` lists a machine (when its core starts
    /// at restore anyway): opening Settings never starts it.
    nonisolated static func reads(links: HCLaunchConfiguration?, primary: HCLaunchConfiguration?,
                                  listsMachines: (URL) -> Bool = HCBackendComposition.listsMachines(stateDirectory:))
        -> [HCLaunchConfiguration] {
        distinct([links.flatMap { listsMachines($0.stateDirectory) ? $0 : nil }, primary].compactMap { $0 })
    }

    /// C11H-332: its via doesn't check a pin, or isn't one of c11's own files;
    /// C11H-361: or still lets ssh forward. Review migrates such a via, so one
    /// still here is one c11 couldn't update, and won't use.
    func linkUnchecked(_ name: String) -> Bool {
        guard let machine = machines[name] else { return false }
        guard let via = HCStoredLinks.ownedVia(machine.target, home: home) else { return true }
        return !HCStoredLinks.isCurrent(via)
    }

    func needsUpdate(_ name: String) -> Bool {
        if linkUnchecked(name) { return true }
        guard let machine = machines[name], let pin = pinVersion else { return false }
        // C11H-332: a via that doesn't check this build's pin at every dial
        // (one linked before the pin was required) needs Update too.
        let sha = HCBackendComposition.shared.configuration?.pin.executableSHA256
        let via = HCMachineSetup.viaScript(for: machine, home: home)
        // C11H-392: a Linux machine's via checks this build's Linux hc pin.
        return HCMachineSetup.needsUpdate(machine, pinVersion: pin, pinSHA256: sha, viaScript: via, otherPins: Set([linuxPin].compactMap { $0 }))
    }

    /// C11H-392: this build's Linux hc pin, read from its signed manifest once.
    private var linuxPin: String? { HCRemoteArtifactManifest.bundledLinuxHCPin }

    /// hc's list, as `refresh` read it (one session's, the single-session case).
    func apply(_ listed: [HCMachineSetup.ListedMachine]) {
        apply(sessions: ["": listed], order: [""])
    }

    /// C11H-391: every session's list; `order` puts c11's own session first.
    func apply(sessions listed: [String: [HCMachineSetup.ListedMachine]], order: [String]) {
        bySession = listed.mapValues { Dictionary($0.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }) }
        var merged: [String: HCMachineSetup.ListedMachine] = [:]
        for session in order.reversed() {
            for (name, machine) in bySession[session] ?? [:] { merged[name] = machine }
        }
        machines = merged
    }

    func refresh() {
        let configurations = sessions()
        guard !configurations.isEmpty else { return }
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let runner = self.runner
        let reads = configurations.map { configuration -> (String, [String], [String: String]) in
            var environment = configuration.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            return (configuration.session, [configuration.executableURL.path, "machine", "ls", "--json"], environment)
        }
        Task.detached(priority: .utility) { [weak self] in
            var listed: [String: [HCMachineSetup.ListedMachine]] = [:]
            for (session, argv, environment) in reads {
                let output = runner.run(argv, stdin: nil, environment: environment, timeout: 10)
                // A session whose core isn't running (the links session before
                // its first Add Machine) keeps what it listed last.
                if output.status == 0, let parsed = HCMachineSetup.parseMachineList(output.stdout) { listed[session] = parsed }
            }
            let order = reads.map(\.0)
            let read = listed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshing = false
                if !read.isEmpty {
                    var all = self.bySession.mapValues { Array($0.values) }
                    for session in all.keys where !order.contains(session) { all.removeValue(forKey: session) }
                    all.merge(read) { _, fresh in fresh }
                    self.apply(sessions: all, order: order)
                }
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }
}

/// Remove Machine: list c11's terminals on it, end them, then unlink it.
@MainActor
enum MachineRemoval {
    struct Terminal: Equatable, Identifiable {
        let workspaceId: UUID
        let panelId: UUID
        let title: String
        let workspaceTitle: String
        var id: UUID { panelId }
    }

    /// c11's terminals running on `machine`, in every window. C11H-391: with
    /// `session`, only those of that session's link (the same name can be
    /// linked by c11 and by c11h; removing one link ends only its terminals).
    static func terminals(on machine: String, session: String? = nil) -> [Terminal] {
        guard let app = AppDelegate.shared else { return [] }
        return app.allMainWindowWorkspaces().flatMap { workspace in
            workspace.panels.values.compactMap { panel -> Terminal? in
                guard let terminal = panel as? TerminalPanel,
                      terminal.hcRemoteTarget?.machine.caseInsensitiveCompare(machine) == .orderedSame,
                      session == nil || panelSession(terminal.id) == session else { return nil }
                return Terminal(workspaceId: workspace.id, panelId: terminal.id,
                                title: workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                                workspaceTitle: workspace.title)
            }
        }
        .sorted { ($0.workspaceTitle, $0.title) < ($1.workspaceTitle, $1.title) }
    }

    /// C11H-391: the session a panel's terminal lives in: its home shard's,
    /// else (not resolved yet) shard 0's, where a remote terminal went before.
    static func panelSession(_ panel: UUID) -> String? {
        let composition = HCBackendComposition.shared
        return HCShardPlacement.shared.home(forPanel: panel).flatMap { composition.pool?.shard($0)?.name }
            ?? composition.configuration?.session
    }

    /// Ends each of c11's terminals on `machine` (closing a c11 panel ends
    /// its session, remote ones included). Returns how many were ended.
    static func endTerminals(on machine: String, session: String? = nil) -> Int {
        guard let app = AppDelegate.shared else { return 0 }
        var ended = 0
        for terminal in terminals(on: machine, session: session) {
            guard let workspace = app.allMainWindowWorkspaces().first(where: { $0.id == terminal.workspaceId }) else { continue }
            if workspace.closePanel(terminal.panelId, force: true) { ended += 1 }
        }
        NSLog("machine.remove.ended name=%@ terminals=%d", machine, ended)
        return ended
    }

    struct UnlinkOutcome: Equatable, Sendable {
        /// c11's hc there wasn't confirmed stopped: the link was down, or
        /// (`stopRefused`) its hc didn't hash to the pin, so c11 didn't run it.
        let leftRunning: Bool
        /// C11H-332: the hc there isn't this build's; c11 never runs an
        /// unchecked binary, so it stays running until it ends there.
        var stopRefused: Bool = false
        /// C11H-274: c11h made this link (an adopted c11h session's via), so
        /// the hc there is c11h's: c11 doesn't stop an hc it didn't install,
        /// and it keeps running there with no terminals.
        var c11hLink: Bool = false
        /// hc reported the link connected when Remove began, so its terminals
        /// there were ended.
        var linkWasUp: Bool = true

        /// The audit line's detail.
        var auditDetail: String? {
            if c11hLink {
                return linkWasUp
                    ? "ended its c11h terminals; c11h's hc there still runs, with no terminals (c11 stops only an hc it installed)"
                    : "its link was down: c11h's terminals and hc there may still run (c11 stops only an hc it installed)"
            }
            if stopRefused { return "c11 couldn't confirm the hc there is its own, so it didn't stop it" }
            return leftRunning ? "its link was down; what c11 ran there may still run" : nil
        }
    }

    /// C11H-274: a link an adopted c11h made: its via is c11h's (in c11h's
    /// folder, or naming a c11h session), not one c11 rendered.
    nonisolated static func isC11hLink(viaPath: String?, session: String?, home: URL) -> Bool {
        if let viaPath, viaPath.hasPrefix(home.path + "/.local/share/c11h/") { return true }  // c11-2.0:legacy
        if let session, session == "c11h" || session.hasPrefix("c11h-") { return true }  // c11-2.0:legacy
        return false
    }

    /// The core check both Add Machine and Remove run first.
    nonisolated static func coreCheck(_ configuration: HCLaunchConfiguration) -> @Sendable () -> String? {
        let bundleID = Bundle.main.bundleIdentifier
        return { HCMachineSetup.verifyOwnCore(configuration: configuration, host: HCCoreSystemHost(bundleIdentifier: bundleID)) }
    }

    /// Unlink without leaving anything running there. A connected machine:
    /// kill every c11 terminal still live there (`hc kill`) and wait until hc
    /// shows none (if they won't end, nothing is removed). Then `hc machine
    /// rm`, then stop c11's hc there over ssh with the binary its via names.
    /// An unconfirmed stop (a down machine, a via c11 can't read) is reported
    /// as left running. Blocking; never on main.
    nonisolated static func unlink(machine: String, configuration: HCLaunchConfiguration,
                                   runner: any HCMachineSetupRunner = HCMachineSetupProcessRunner(),
                                   verifyCore: (() -> String?)? = nil,
                                   viaScript: String? = nil,
                                   keyring: (any C11RelayLinkSecrets)? = nil,
                                   pickups: ((String) -> C11RelayPickupLedger)? = nil,
                                   sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                   audit: C11AuditLog = .shared,
                                   origin: String = "settings",
                                   linkScript: URL? = HCMachineSetupResources.inBundle(Bundle.main.bundleURL).linkScript) -> Result<UnlinkOutcome, HCMachineSetupFailure> {
        // C11H-332: every unlink, done or refused, is a line in c11's audit log.
        let outcome = performUnlink(machine: machine, configuration: configuration, runner: runner, verifyCore: verifyCore,
                                    viaScript: viaScript, keyring: keyring, pickups: pickups, sleep: sleep,
                                    linkScript: linkScript)
        switch outcome {
        case .success(let done):
            audit.record(C11AuditRecord(kind: .unlink, via: origin, outcome: "ok",
                                        machine: HCCoreUtility.isLinkMachineName(machine) ? machine : "invalid", session: configuration.session,
                                        detail: done.auditDetail))
        case .failure(let failure):
            // Codes and a checked name only: a failure's message can carry
            // hc's or ssh's own output.
            audit.record(C11AuditRecord(kind: .unlink, via: origin, outcome: "failed",
                                        machine: HCCoreUtility.isLinkMachineName(machine) ? machine : "invalid",
                                        session: configuration.session, code: failure.code))
        }
        return outcome
    }

    nonisolated private static func performUnlink(machine: String, configuration: HCLaunchConfiguration,
                                                  runner: any HCMachineSetupRunner, verifyCore: (() -> String?)?,
                                                  viaScript: String?, keyring: (any C11RelayLinkSecrets)?,
                                                  pickups: ((String) -> C11RelayPickupLedger)?,
                                                  sleep: (TimeInterval) -> Void, linkScript: URL?) -> Result<UnlinkOutcome, HCMachineSetupFailure> {
        if let why = (verifyCore ?? coreCheck(configuration))() { return .failure(.coreUnavailable(why)) }
        var environment = configuration.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let hc = configuration.executableURL.path
        func run(_ arguments: [String], _ timeout: TimeInterval) -> HCMachineSetupOutput {
            runner.run([hc] + arguments, stdin: nil, environment: environment, timeout: timeout)
        }
        let listed = run(["machine", "ls", "--json"], 10)
        guard listed.status == 0, let machines = HCMachineSetup.parseMachineList(listed.stdout) else {
            return .failure(.coreUnavailable("hc machine ls failed"))
        }
        guard let entry = machines.first(where: { $0.name == machine }) else {
            return .failure(.removeFailed(machine, "not linked"))
        }
        let connected = entry.state == "connected"
        if connected {
            func liveThere() -> [String]? {
                let output = run(["ls", "--json"], 10)
                return output.status == 0 ? HCMachineSetup.liveTerminals(on: machine, lsJSON: output.stdout) : nil
            }
            guard var live = liveThere() else { return .failure(.removeIncomplete(machine, "hc ls failed")) }
            for address in live { _ = run(["kill", address], 5) }
            var polls = 0
            while !live.isEmpty, polls < 20 {
                sleep(0.25)
                live = liveThere() ?? live
                polls += 1
            }
            guard live.isEmpty else {
                return .failure(.removeIncomplete(machine, "\(live.count) terminals still running"))
            }
        }
        let output = run(["machine", "rm", machine, "--json"], 20)
        guard output.status == 0 else {
            let why = (output.stderr.isEmpty ? output.stdout : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.removeFailed(machine, why.isEmpty ? "exit \(output.status)" : String(why.prefix(300))))
        }
        // C11H-176: every relay credential this link gave that machine's
        // terminals stops verifying, here and after the machine is added
        // again. C11H-391: only in the session whose link this removes. The
        // same name can be linked in another of this app's sessions (c11's
        // links session beside c11h's old link); that link's terminals keep
        // their credentials and their pickups.
        let revoked = (keyring ?? C11RelayKeyring.shared).revoke(machine: machine, sessions: [configuration.session])
        NSLog("machine.remove.relay_revoked name=%@ session=%@ secrets=%d", machine, configuration.session, revoked)
        (pickups ?? { C11RelayPickupLedger.shared(session: $0) })(configuration.session).forget(machine: machine)
        // The link is gone, so hc can't start the far core again: stop it
        // over the ssh target it dials. C11H-332: through the staged link
        // script's checked stop, which runs the via's own hc only after it
        // hashes to the via's pin (this build's for a via from before the
        // pin), and sends `server stop` only to a core it identifies from the
        // kernel as that pin; a foreign or unknown core is never stopped or
        // signalled. Only a confirmed stop counts.
        var stoppedThere = false
        var stopRefused = false
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pin = configuration.pin.executableSHA256.lowercased()
        let script = viaScript ?? HCMachineSetup.viaScript(for: entry, home: home)
        let parsed = script.flatMap { HCMachineSetup.ViaInfo.parse($0) }
        // C11H-274: c11h's link names c11h's session and hc there; c11's
        // checked stop refuses that session, and c11 never stops an hc it
        // didn't install. Its terminals ended above; say so, not "link down".
        // The via is read for its session name only; nothing runs from it.
        let viaSession = script.flatMap { HCMachineSetup.ViaInfo.parse($0, adopted: true)?.session }
        if isC11hLink(viaPath: entry.target, session: viaSession, home: home) {
            NSLog("machine.remove.unlinked name=%@ connected=%d c11h_link=1", machine, connected ? 1 : 0)
            return .success(UnlinkOutcome(leftRunning: true, c11hLink: true, linkWasUp: connected))
        }
        if let info = parsed {
            var sshEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path]
            if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !agent.isEmpty { sshEnvironment["SSH_AUTH_SOCK"] = agent }
            func ssh(_ command: String, stdin: URL? = nil, timeout: TimeInterval = 30) -> HCMachineSetupOutput {
                runner.run(HCMachineSetup.sshArgv(host: info.target, remoteCommand: command), stdin: stdin,
                           environment: sshEnvironment, timeout: timeout)
            }
            if let linkScript, FileManager.default.isReadableFile(atPath: linkScript.path) {
                let dir = HCMachineSetup.remoteSetupDir(run: String(UUID().uuidString.prefix(8)).lowercased())
                if ssh(HCMachineSetup.writeRemoteFileCommand("c11-atlas-link.sh", dir: dir), stdin: linkScript).status == 0 {
                    let stopped = ssh(HCMachineSetup.stopCoreCommand(session: info.session, socket: info.socket, hc: info.hc,
                                                                    sha256: info.sha256 ?? pin, allow: info.allowedServing(pin: pin), dir: dir))
                    stoppedThere = stopped.status == 0
                    stopRefused = stopped.status == 7 || stopped.status == 8
                }
                _ = ssh(HCMachineSetup.cleanupCommand(dir: dir))
            } else {
                // Without its checked stop, c11 can't confirm the core is its own.
                stopRefused = true
            }
        }
        let via = HCMachineSetup.viaURL(home: home, name: machine)
        try? FileManager.default.removeItem(at: via)
        NSLog("machine.remove.unlinked name=%@ connected=%d far_core_stopped=%d", machine, connected ? 1 : 0, stoppedThere ? 1 : 0)
        return .success(UnlinkOutcome(leftRunning: !stoppedThere, stopRefused: stopRefused, linkWasUp: connected))
    }

    /// C11H-391: the configuration of the session `session` names (any pool
    /// member, the links session included); nil names c11's own link session.
    static func configuration(forSession session: String?) -> HCLaunchConfiguration? {
        let composition = HCBackendComposition.shared
        guard let session else { return composition.linkConfiguration }
        return composition.pool?.shards.first { $0.name == session }?.configuration
            ?? [composition.linkConfiguration, composition.configuration].compactMap { $0 }.first { $0.session == session }
    }

    /// C11H-391: the session whose link Remove acts on when none is named:
    /// the only one that links the name, else nil (the caller must choose).
    static func soleLinkSession(of machine: String) -> (session: String?, sessions: [String]) {
        let sessions = HCMachineDirectory.shared.links(of: machine).map(\.session)
        return (sessions.count == 1 ? sessions[0] : nil, sessions)
    }

    /// Settings: end the terminals, then unlink off the main thread.
    /// `session`: whose link (C11H-391); nil when the name has one link.
    static func remove(machine: String, session: String? = nil,
                       completion: @escaping @MainActor (Result<(ended: Int, outcome: UnlinkOutcome), HCMachineSetupFailure>) -> Void) {
        let target = session ?? soleLinkSession(of: machine).session
        let resolved = target.map { Self.configuration(forSession: $0) } ?? HCBackendComposition.shared.configuration
        guard let configuration = resolved else {
            completion(.failure(.coreUnavailable("no hc session")))
            return
        }
        let ended = endTerminals(on: machine, session: target)
        Task.detached(priority: .userInitiated) {
            let outcome = unlink(machine: machine, configuration: configuration)
            await MainActor.run {
                MachineHCStatus.shared.refresh()
                completion(outcome.map { (ended: ended, outcome: $0) })
            }
        }
    }
}
