import Darwin
import Foundation

/// Observability for the hc backend. `struct HCDiagnostics` stays in
/// `HCContract.swift`. This type records transitions and projects them.
/// It does not open an hc socket, spawn a core, or read the kernel.
///
/// Ticket 2 and ticket 7 call `record` at the decision they already make.
/// The GO interface commit has no diagnostic event stream, so this sink is
/// the schema. The observe callback enqueues and returns.

enum HCDiagnosticEvent: Sendable {
    /// Tokens and identities only, including attempts that never reach attach.
    case attachmentProgress(panel: HCPanelIdentity, phase: String, outcome: String, waitNanoseconds: UInt64)
    case attach(panelID: UUID, terminal: String, servingBuild: String, tty: String?)
    case reattach(panelID: UUID, terminal: String, servingBuild: String, tty: String?)
    /// The core cannot be reached. Whether this panel became a plain-shell
    /// fallback is inferred from its identity (fresh, keyless, no outstanding
    /// creation); a caller that knows says so with `coreUnresolved` or `fallback`.
    case coreUnreachable(panel: HCPanelIdentity, configuredBuild: String)
    /// The core cannot be reached and the panel is still waiting on it: a
    /// pending creation, a remote panel or a restored terminal. Never a fallback.
    case coreUnresolved(panel: HCPanelIdentity, configuredBuild: String)
    /// The panel fell back to a plain local shell: a genuinely new local panel
    /// whose core was unreachable before anything was transmitted.
    case fallback(panel: HCPanelIdentity, configuredBuild: String)
    case attachFailed(panelID: UUID, terminal: String, servingBuild: String, reason: String)
    case recovery(reason: String, result: String, servingBuild: String?)
    case gateRefused(callerPid: Int32, ancestry: String, reason: String)
    case fileLimit(soft: UInt64, hard: UInt64, kernelCap: UInt64?, beforeSoft: UInt64?)
    /// One ended terminal from a holder death. Terminals that share a `holderID`
    /// are one incident, including across restarts. Without a holder id, endings
    /// on the same core within the coalesce window are one incident. The core's
    /// pid is not the key: the holder is a different process.
    case holderLost(coreID: String, terminal: String, discriminator: String, holderID: String?)
    case panelNew(panel: HCPanelIdentity)
    /// Keeps the row so a later read can see `ended`. Does not increment holder-loss.
    case panelEnded(panelID: UUID, reason: String?)
    /// Removes the row. Closing a panel drops it from the diagnostics list for
    /// good: a later snapshot that still binds it does not bring it back.
    case panelClosed(panelID: UUID)
    /// C11H-103 (L4 amendment, condition 5): an orphan went back to its own
    /// workspace instead of Recovered. Every return is one line.
    case recoveredHome(panelID: UUID, terminal: String, workspaceID: UUID, reason: String)
    /// C11H-232: a signal c11 did not send ended a terminal's root. One line
    /// per end, kept or closed, so the next stray `pkill` is visible here.
    case outsideSignalEnd(panelID: UUID, terminal: String, signal: Int32, kept: Bool, agent: String?)
    /// C11H-235: several kept outside-signal ends together, reported once.
    case massSignalEnd(id: UUID, count: Int, signals: [Int32], autoResume: Bool)
}

enum HCDiagnosticTokens {
    static func unavailable(_ reason: HCUnavailableReason) -> String {
        switch reason {
        case .backendNotInstalled: return "backend_not_installed"
        case .coreUnreachable: return "core_unreachable"
        case .inventoryPending: return "inventory_pending"
        case .connectionLost: return "connection_lost"
        case .incompatibleProtocol: return "incompatible_protocol"
        case .foreignBuild: return "foreign_build"
        case .foreignSession: return "foreign_session"
        case .pinMismatch: return "pin_mismatch"
        case .invalidLaunchTuple: return "invalid_launch_tuple"
        case .fileDescriptorLimit: return "file_descriptor_limit"
        case .intentStoreFailure: return "intent_store_failure"
        case .creationPending: return "creation_pending"
        case .creationUncertain: return "creation_uncertain"
        case .recoveryRequired: return "recovery_required"
        case .inputFault: return "input_fault"
        case .screenUnavailable: return "screen_unavailable"
        case .staleIdentity: return "stale_identity"
        case .ambiguousIdentity: return "ambiguous_identity"
        case .deadlineExceeded: return "deadline_exceeded"
        case .malformedResponse: return "malformed_response"
        case .bufferOverflow: return "buffer_overflow"
        case .cancelled: return "cancelled"
        case .appCarriesScope: return "app_carries_scope"
        }
    }

    static func recoveryReason(_ reason: HCRecoveryReason) -> String {
        switch reason {
        case .foreignBuild: return "foreign_build"
        case .creationUncertain: return "creation_uncertain"
        case .inputFault: return "input_fault"
        }
    }

    static func inputRefusal(_ reason: HCInputRefusal) -> String {
        switch reason {
        case .unavailable: return "unavailable"
        case .staleIdentity: return "stale_identity"
        case .guardRefused: return "guard_refused"
        case .screenUnavailable: return "screen_unavailable"
        case .tooLarge: return "too_large"
        case .queueFull: return "queue_full"
        case .inputFault: return "input_fault"
        case .cancelled: return "cancelled"
        }
    }

    /// A string that already matches the token regex is kept. A known enum raw
    /// value is mapped by the switches above. Anything else is dropped.
    static func reason(_ raw: String) -> String? {
        if let direct = token(raw) { return direct }
        if let reason = HCUnavailableReason(rawValue: raw) { return unavailable(reason) }
        if let reason = HCRecoveryReason(rawValue: raw) { return recoveryReason(reason) }
        if let reason = HCInputRefusal(rawValue: raw) { return inputRefusal(reason) }
        return nil
    }

    static func token(_ raw: String) -> String? {
        guard raw.range(of: #"^[a-z0-9_]{1,64}$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }
}

enum HCDiagnosticInputMapping {
    struct Verdict: Equatable {
        var outcome: String
        var exitStatus: String
        var byteCount: Int
        var retry: String
        var submitted: Bool
        var pending: Bool
        var replay: String
    }

    /// Refused, written, and uncertain. The verdict is tokens and counts.
    /// It does not carry payload bytes.
    static func verdict(for outcome: HCInputOutcome) -> Verdict {
        switch outcome {
        case .refused:
            return Verdict(
                outcome: "refused",
                exitStatus: "nonzero",
                byteCount: 0,
                retry: "safe",
                submitted: false,
                pending: false,
                replay: "safe"
            )
        case .written(let receipt):
            return Verdict(
                outcome: "written",
                exitStatus: "zero",
                byteCount: receipt.bodyBytesWritten,
                retry: "unsafe",
                submitted: receipt.returnWritten,
                pending: false,
                replay: "never"
            )
        case .uncertain(let receipt):
            return Verdict(
                outcome: "uncertain",
                exitStatus: "nonzero",
                byteCount: receipt.bodyBytesWritten,
                retry: "unsafe",
                submitted: receipt.returnWritten,
                pending: false,
                replay: "never"
            )
        }
    }

    /// Queued input is an unresolved pending receipt. Do not replay it.
    /// `HCInputOutcome` has no queued case; see the contract-detail consumer rule.
    static func queued() -> Verdict {
        Verdict(
            outcome: "queued",
            exitStatus: "zero",
            byteCount: 0,
            retry: "unsafe",
            submitted: false,
            pending: true,
            replay: "never"
        )
    }
}

/// Controlling tty of one local terminal. The same-uid `proc_pidinfo` read is
/// enough for a shell. hc's terminal root is setuid-root `login`, so that read
/// returns nothing; `sysctl` still sees the login, and its tty is the pty.
enum HCSessionTTY {
    struct RecordedProcess: Equatable, Sendable {
        var identity: HCProcessIdentity
        var effectiveUID: UInt32
        var realUID: UInt32
        /// Nil when the process has no controlling terminal (`e_tdev` is NODEV).
        var controllingTTYDevice: UInt32?
    }

    static func resolve(
        pid: Int32,
        ourUID: UInt32,
        owned: @Sendable (Int32) -> HCAgentRecoveryProcessFacts?,
        recorded: @Sendable (Int32) -> RecordedProcess?,
        ttyName: @Sendable (UInt32) -> String?
    ) -> (process: HCProcessIdentity, tty: String)? {
        if let facts = owned(pid),
           let device = facts.controllingTTYDevice,
           let name = ttyName(device), !name.isEmpty {
            return (facts.identity, "/dev/\(name)")
        }
        // The login is not our effective uid. Accept it only under the same
        // rule as admission: our process, or a setuid-root terminal root whose
        // real uid is ours. Anyone else's root process stays unread.
        guard let process = recorded(pid),
              HCLocalProcess(
                identity: process.identity, parentPID: 0,
                uid: process.effectiveUID, realUID: process.realUID
              ).admitsAsTerminalRoot(uid: ourUID),
              let device = process.controllingTTYDevice,
              let name = ttyName(device), !name.isEmpty else { return nil }
        return (process.identity, "/dev/\(name)")
    }

    /// `sysctl(KERN_PROC_PID)`, the read `HCLocalProcess.read` uses once
    /// `proc_pidinfo` has refused another effective uid. Adds `e_tdev`.
    static func readRecorded(_ pid: Int32) -> RecordedProcess? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid,
              info.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        let start = info.kp_proc.p_starttime
        let rawDevice = info.kp_eproc.e_tdev
        return RecordedProcess(
            identity: HCProcessIdentity(
                pid: pid,
                startTimeMicroseconds: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)),
            effectiveUID: info.kp_eproc.e_ucred.cr_uid,
            realUID: info.kp_eproc.e_pcred.p_ruid,
            controllingTTYDevice: rawDevice < 0 ? nil : UInt32(rawDevice))
    }
}

/// C11H-235: what one local terminal's root process is, read from the kernel
/// only when `hc-diagnostics` is asked (never on an inventory, input or
/// render path). `shell` is the login shell itself (C11H-232's root, `-/bin/zsh`);
/// `login` is `/usr/bin/login -flp <user> /bin/bash --noprofile …`, the root a
/// build before C11H-232 opened and the one a stray `pkill -f <x> -n` matches;
/// `other` is any other program run as the root (`hc run -- <program>`). A
/// remote terminal's pid is never read here: its row says `n/a`.
enum HCTerminalRootForm {
    static let shell = "shell"
    static let login = "login"
    static let other = "other"
    static let notApplicable = "n/a"

    /// The shells a terminal roots at, by the kernel's command name.
    static let shellNames: Set<String> = [
        "zsh", "bash", "sh", "dash", "fish", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "oksh",
    ]

    /// `p_comm` is the executable's name, at most 16 bytes (a login shell's
    /// argv0 `-zsh` does not change it).
    static func classify(command: String) -> String {
        let name = command.hasPrefix("-") ? String(command.dropFirst()) : command
        if name == "login" { return login }
        return shellNames.contains(name) ? shell : other
    }

    /// The root form of a live local terminal's recorded pid, or nil when that
    /// process is gone or a different process (another start time) now holds
    /// the pid. `sysctl(KERN_PROC_PID)` reads any process, setuid-root `login`
    /// included, and sends nothing.
    static func kernel(pid: Int32, expected: HCProcessIdentity) -> String? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid,
              info.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        let start = info.kp_proc.p_starttime
        guard expected.pid == pid,
              UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec) == expected.startTimeMicroseconds else { return nil }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return command.isEmpty ? nil : classify(command: command)
    }
}

final class HCDiagnosticRecorder: @unchecked Sendable {
    #if DEBUG
    private static let liveShared = makeLiveShared()
    private static let fixtureLock = NSLock()
    nonisolated(unsafe) private static var fixture: HCDiagnosticRecorder?
    static var shared: HCDiagnosticRecorder {
        fixtureLock.lock()
        let installed = fixture
        fixtureLock.unlock()
        return installed ?? liveShared
    }

    /// Route every recovery diagnostic, including panel notices, into one
    /// fixture directory without opening the operator's recorder or probing
    /// host PIDs. The reset drains queued records before restoring the override.
    @MainActor
    static func installFixtureForTesting(directory: URL) -> @MainActor () -> Void {
        let installed = HCDiagnosticRecorder(logFile: directory.appendingPathComponent("diagnostics.log"),
            counterFile: directory.appendingPathComponent("counter.json"), parentOf: { _ in nil },
            ttyResolver: { _ in nil }, rootResolver: { _, _ in nil })
        fixtureLock.lock()
        let previous = fixture
        fixture = installed
        fixtureLock.unlock()
        return {
            HCCompositionDiagnostics.queue.sync {}
            installed.deliveryQueue.sync {}
            Self.fixtureLock.lock()
            Self.fixture = previous
            Self.fixtureLock.unlock()
        }
    }
    #else
    static let shared = makeLiveShared()
    #endif

    private static func makeLiveShared() -> HCDiagnosticRecorder {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return HCDiagnosticRecorder(
            logFile: home.appendingPathComponent("Library/Logs/c11/hc-diagnostics.log"),
            counterFile: home.appendingPathComponent("Library/Application Support/c11/diagnostics/holder-lost.json"),
            ttyResolver: HCDiagnosticRecorder.kernelTTY,
            rootResolver: HCTerminalRootForm.kernel
        )
    }

    /// C11H-55 (F2), C11H-137: the terminal's controlling tty.
    /// A same-uid shell answers through `proc_pidinfo`. A terminal opened
    /// before C11H-232 roots at setuid-root `/usr/bin/login`, which that call refuses; the
    /// login's own tty, read with `sysctl`, is the session pty. Callers pass
    /// only a local pid (`kernelFacts` skips a row that names a machine).
    static let kernelTTY: TTYResolver = { pid in
        HCSessionTTY.resolve(
            pid: pid,
            ourUID: getuid(),
            owned: HCAgentRecoveryKernel.readProcess,
            recorded: HCSessionTTY.readRecorded,
            ttyName: HCAgentRecoveryKernel.ttyName(for:)
        )
    }

    private struct PanelRow {
        var panelID: UUID
        var terminal: String?
        /// The machine a remote panel's terminal runs on; nil for this Mac.
        var machine: String?
        var tty: String?
        var pid: Int32?
        var lifecycle: String
        var persistence: String?
        var servingBuild: String?
        var configuredBuild: String?
        var reason: String?
        var attachment: String?
        /// Set only by `record(.attachFailed)`. Inventory does not clear it.
        /// A successful attach, reattach, or an authoritative end does.
        var attachFailure: String?
        /// Terminal key and process incarnation the cached pid and tty belong to.
        var factKey: HCTerminalKey?
        var factProcess: HCProcessIdentity?
        /// The hc session (shard) whose snapshot bound this panel. A terminal never
        /// moves between shards, so a later write keeps it.
        var shard: String?
    }

    /// One hc session's diagnostic state. The legacy `c11` session is shard 0.
    private struct ShardState {
        var shard: HCShardIdentity
        var coreID: String?
        var readiness: String?
        var readinessReason: String?
        var generation: UInt64?
        var sequence: UInt64?
        /// Root pid of each terminal -> the holder that parents it, read once per
        /// root pid. A shard can run several holders at once (a recovered shard
        /// keeps the old one until its terminals end), so the holder of a lost
        /// terminal is looked up by that terminal's own root pid.
        var holderByRoot: [Int32: Int32] = [:]
        /// Root pids of the terminals running in the latest ready inventory.
        var liveRoots: Set<Int32> = []
        /// C11H-205: running and finished terminals this core holds itself
        /// (`.local` records), bound to a panel or not, from the latest ready
        /// inventory. Mirrors of other machines' terminals count apart, in the
        /// `remote_` pair. A pending inventory keeps the last.
        var liveTerminals = 0
        var endedTerminals = 0
        var remoteLiveTerminals = 0
        var remoteEndedTerminals = 0
        /// The distinct holders of the terminals running now.
        var liveHolders: [Int32] {
            Array(Set(liveRoots.compactMap { holderByRoot[$0] })).sorted()
        }
        /// The holder the last `holder_lost` incident ended, kept for diagnosis.
        var lastLostHolderPID: Int32?
        var holderLostCount = 0
    }

    private let lock = NSLock()
    private let logFile: URL
    private let counterFile: URL
    private let maxLogBytes: Int
    private let coalesceMilliseconds: Int64
    private let now: @Sendable () -> Date
    /// A local terminal's controlling tty and process incarnation, read from the
    /// kernel. The core does not report a tty; production passes `kernelTTY`,
    /// and a test passes a fake so no host process is probed.
    typealias TTYResolver = @Sendable (Int32) -> (process: HCProcessIdentity, tty: String)?
    private let ttyResolver: TTYResolver
    /// C11H-235: a live local terminal's root form (`HCTerminalRootForm`), read
    /// only by `jsonObject` (an `hc-diagnostics` request). Tests pass a fake.
    typealias RootResolver = @Sendable (Int32, HCProcessIdentity) -> String?
    private let rootResolver: RootResolver
    private let deliveryQueue = DispatchQueue(label: "c11.hc-diagnostics")
    private var observations: [HCObservation] = []
    private var rows: [UUID: PanelRow] = [:]
    /// C11H-205: panels closed for good. The session keeps a finished terminal
    /// bound to its panel, so without this every later snapshot would bring a
    /// closed panel's row back as ended. Closes are rare; the set is not trimmed.
    private var closedPanels = Set<UUID>()
    private var signatures: [String: String] = [:]
    private var holderLostCountStorage = 0
    /// Counts `ingest` calls. A holder-loss incident remembers the one it opened
    /// in, so a later snapshot can tell it is later.
    private var ingestSequence: UInt64 = 0
    /// Cores with an open holder-loss incident, and the snapshot that opened it.
    /// One holder kill is one incident however many snapshots carry its dead
    /// terminals, however far apart; it stays open until a later snapshot shows a
    /// live terminal on that core (a new holder). In memory only: a restarted app
    /// has no incident open (C11H-55, F11).
    private var openIncidentSequence: [String: UInt64] = [:]
    private var seenTerminals = Set<String>()
    private var seenHolders = Set<String>()
    private var lastIncidentMilliseconds: [String: Int64] = [:]
    /// `core:address` → discriminator seen while the terminal was live.
    private var liveDiscriminators: [String: String] = [:]
    private var countError: String?
    private var loadedCount = 0
    private var persistEnabled = true
    private var sessionReadiness: String?
    private var sessionReadinessReason: String?
    private var connectionGeneration: UInt64?
    private var revisionSequence: UInt64?
    private var shards: [String: ShardState] = [:]
    /// Set for the length of one `ingest`, under the lock: the shard whose
    /// snapshot is being applied. Rows and log lines written meanwhile carry it.
    private var ingestShard: HCShardIdentity?
    private let parentOf: @Sendable (Int32) -> Int32?

    var holderLostCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return holderLostCountStorage
    }

    init(
        logFile: URL,
        counterFile: URL,
        maxLogBytes: Int = 4 * 1_048_576,
        coalesceSeconds: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = { Date() },
        parentOf: @escaping @Sendable (Int32) -> Int32? = HCShardHolder.kernelParent,
        ttyResolver: @escaping TTYResolver = { _ in nil },
        rootResolver: @escaping RootResolver = { _, _ in nil }
    ) {
        self.parentOf = parentOf
        self.ttyResolver = ttyResolver
        self.rootResolver = rootResolver
        self.logFile = logFile
        self.counterFile = counterFile
        self.maxLogBytes = max(maxLogBytes, 1)
        self.coalesceMilliseconds = max(Int64((coalesceSeconds * 1000).rounded()), 1)
        self.now = now
        let loaded = withCounterLock { readCounterFile() }
        holderLostCountStorage = loaded.count
        seenTerminals = Set(loaded.terminals)
        seenHolders = Set(loaded.holders)
        lastIncidentMilliseconds = loaded.cores
        liveDiscriminators = loaded.live
        loadedCount = loaded.count
        persistEnabled = loaded.persist
        countError = loaded.error
        if loaded.error != nil {
            appendLine("event=counter_disabled reason=unreadable")
        }
    }

    /// Subscribe to inventory snapshots. The callback enqueues and returns.
    /// Callers that know panel origin pass `ingest(_:panels:)`.
    /// `panels` names the panels the app knows, read on the delivery queue for
    /// each snapshot: it supplies each row's persistence and creation id, and the
    /// rows of panels that never bound while the core is unreachable.
    /// `shard` names the hc session this snapshot stream belongs to; the pool
    /// calls this once per shard when it starts. `shardOf` says which shard a
    /// known panel lives in, so a panel bound in another shard is not read as
    /// unreachable when this one is down. Without it every panel is this shard's.
    func install(
        _ session: HCSession,
        shard: HCShardIdentity = .legacyDefault,
        panels: @escaping @Sendable () -> [HCPanelIdentity] = { [] },
        shardOf: (@Sendable (HCPanelIdentity) -> HCShardIdentity?)? = nil
    ) {
        registerShard(shard)
        let queue = deliveryQueue
        let observation = session.observe(on: queue) { [weak self] snapshot in
            queue.async {
                guard let self else { return }
                let reason: HCUnavailableReason?
                if case .pending(let pending) = snapshot.readiness {
                    reason = pending
                } else {
                    reason = nil
                }
                self.ingest(HCDiagnostics(
                    inventory: snapshot,
                    expectedPin: .current,
                    servingBuild: snapshot.buildIdentity,
                    unavailableReason: reason
                ), panels: panels(), inferFallback: false, shard: shard, shardOf: shardOf)
            }
        }
        lock.lock()
        observations.append(observation)
        lock.unlock()
    }

    /// A shard is listed from the moment it starts, before its first snapshot.
    private func registerShard(_ shard: HCShardIdentity) {
        lock.lock()
        defer { lock.unlock() }
        if shards[shard.session] == nil { shards[shard.session] = ShardState(shard: shard) }
    }

    func record(_ event: HCDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        recordUnlocked(event)
    }

    /// 2B's transport callback, wired by 2C. The arguments are the event token,
    /// the connection generation, and optional elapsed nanoseconds. Unknown
    /// tokens are dropped. These lines stay out of `hc-diagnostics --json`.
    /// C11H-112: one line for each send refused because the terminal has no screen and hc's status said not to
    /// deliver (terminal, status, caller). The status is a fixed token, never agent text.
    func recordHeadlessSendRefused(panelID: UUID, terminal: String?, status: String, callerPanelID: UUID?) {
        guard Self.headlessSendStatuses.contains(status) else { return }
        lock.lock()
        defer { lock.unlock() }
        writeLine([
            ("event", "headless_send_refused"),
            ("panel_id", panelID.uuidString),
            ("terminal", terminal),
            ("status", status),
            ("caller", callerPanelID?.uuidString),
        ], signature: nil)
    }

    static let headlessSendStatuses: Set<String> = ["blocked", "no_current_status", "not_running"]

    /// C11H-176: a terminal on another machine whose relayed calls were
    /// refused for its credential, said once per panel and code by the relay
    /// service. The panel and terminal are what the request claimed.
    func recordRelayRefused(machine: String, panel: String, terminal: String, code: String) {
        guard Self.relayRefusalCodes.contains(code) else { return }
        lock.lock()
        defer { lock.unlock() }
        writeLine([
            ("event", "relay_refused"),
            ("machine", machine),
            ("panel_id", panel),
            ("terminal", terminal),
            ("code", code),
        ], signature: nil)
    }

    static let relayRefusalCodes: Set<String> = ["relay_auth_missing", "relay_auth_refused", "relay_kit_outdated"]

    /// C11H-349: one line per operator jump (a notification click, a Flagged
    /// or Done button, Feed, a panel link): how it ended and where its window
    /// went. Fixed tokens and ids only; the displays are CGDirectDisplayIDs.
    func recordOperatorJump(
        source: OperatorJumpSource,
        outcome: OperatorJumpOutcome,
        presentation: OperatorJumpPresentation?,
        workspaceID: UUID?,
        panelID: UUID?
    ) {
        lock.lock()
        defer { lock.unlock() }
        writeLine([
            ("event", "operator_jump"),
            ("source", source.rawValue),
            ("outcome", outcome.rawValue),
            ("placement", presentation?.placement.token),
            ("space_moved", presentation.map { $0.movedToActiveSpace ? "1" : "0" }),
            ("window_id", presentation?.windowID?.uuidString),
            ("from_display", presentation?.fromDisplay.map(String.init)),
            ("to_display", presentation?.operatorDisplay.map(String.init)),
            ("workspace_id", workspaceID?.uuidString),
            ("panel_id", panelID?.uuidString),
        ], signature: nil)
    }

    func recordTransport(event: String, connectionGeneration: UInt64, elapsedNanoseconds: UInt64?) {
        guard Self.transportToken(event) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        var fields: [(String, String?)] = [
            ("event", event),
            ("connection_generation", String(connectionGeneration)),
        ]
        if let elapsedNanoseconds {
            fields.append(("elapsed_ns", String(elapsedNanoseconds)))
        }
        let elapsed = elapsedNanoseconds.map(String.init) ?? ""
        writeOnce(
            signature: "transport:\(event):\(connectionGeneration):\(elapsed)",
            fields: fields
        )
    }

    /// `inferFallback` keeps the recorded inference (a fresh, keyless panel with no
    /// outstanding creation, while the core is unreachable, is a fallback). The
    /// app's panel feed turns it off: a registry identity is a fallback only once it
    /// is the nonpersistent identity the fallback branch assigns, because a panel
    /// that has not yet created anything is waiting, not a shell.
    func ingest(
        _ diagnostics: HCDiagnostics,
        panels: [HCPanelIdentity] = [],
        inferFallback: Bool = true,
        shard: HCShardIdentity = .legacyDefault,
        shardOf: (@Sendable (HCPanelIdentity) -> HCShardIdentity?)? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        ingestSequence &+= 1
        // Read before the walk: a snapshot that still carries the dying terminals
        // and shows the new holder's first live row closes the incident after
        // this walk, not part-way through it.
        // The core id is the one `applyBinding` counts a loss under.
        let servingCore = (diagnostics.servingBuild ?? diagnostics.inventory.buildIdentity)?.coreID
        let liveCores = Set(diagnostics.inventory.records.values.compactMap { record -> String? in
            record.state == .running || record.state == .starting
                ? Self.coreToken(servingCore ?? record.key.owningCoreID) : nil
        })
        defer {
            for core in liveCores {
                if let opened = openIncidentSequence[core], opened < ingestSequence {
                    openIncidentSequence.removeValue(forKey: core)
                }
            }
        }
        ingestShard = shard
        defer { ingestShard = nil }
        applySession(diagnostics, shard: shard)
        let configured = Self.pinToken(diagnostics.expectedPin.version)
        let identity = diagnostics.servingBuild ?? diagnostics.inventory.buildIdentity
        let serving = identity.flatMap { Self.pinToken($0.pin.version) }
        let generation = diagnostics.inventory.revision.connectionGeneration
        let unreachable = Self.isCoreUnreachable(diagnostics)

        for (panelID, key) in diagnostics.inventory.panelBindings {
            // C11H-205: a closed panel's binding outlives it; it has no row.
            if closedPanels.contains(panelID) { continue }
            let record = diagnostics.inventory.records[key]
            // C11H-196: after a host end the old shard still binds the panel to
            // its finished pre-reboot terminal while the panel lives on in a
            // replacement (often on another shard). That stale binding must not
            // overwrite the live row: reads flapped ended/live per snapshot.
            if record?.state == .finished,
               let current = panels.first(where: { $0.panelID == panelID })?.key, current != key { continue }
            let persistence = panels.first(where: { $0.panelID == panelID })?.persistence.rawValue
            let creationID = panels.first(where: { $0.panelID == panelID })?.creationID
            // A retained running binding is not proof the panel is attached,
            // and it is not a live session while the core cannot be reached.
            // Finished and holder_lost records still count.
            if unreachable && !Self.isAuthoritativeEnd(record) {
                applyRetainedUnreachable(
                    panelID: panelID,
                    key: key,
                    record: record,
                    configured: configured,
                    persistence: persistence
                )
                continue
            }
            applyBinding(
                panelID: panelID,
                key: key,
                record: record,
                serving: serving,
                configured: configured,
                generation: generation,
                identity: identity,
                persistence: persistence,
                creationID: creationID,
                linkDown: Self.linkDown(record: record, key: key, snapshot: diagnostics.inventory, previous: rows[panelID])
            )
            annotateMachine(panelID: panelID, key: key, record: record)
        }

        guard unreachable else {
            // F2: a panel the app knows but has not bound (a hidden workspace's
            // terminal that was never shown) still gets its row, read the way the
            // panel's own lifecycle is (`HCLifecycleResolver`): the inventory's
            // terminal for it, else uncertainty. Absence is `new` only for a
            // keyless panel with no creation outstanding on a ready inventory.
            let ready: Bool
            if case .ready(let revision) = diagnostics.inventory.readiness,
               revision == diagnostics.inventory.revision { ready = true } else { ready = false }
            let pendingReason: String = {
                if case .pending(let reason) = diagnostics.inventory.readiness {
                    return HCDiagnosticTokens.unavailable(reason)
                }
                return HCDiagnosticTokens.unavailable(.inventoryPending)
            }()
            for panel in panels where diagnostics.inventory.panelBindings[panel.panelID] == nil {
                if let placed = shardOf?(panel), placed.session != shard.session { continue }
                if closedPanels.contains(panel.panelID) { continue }
                let matches: [HCTerminalRecord]
                if let key = panel.key {
                    matches = diagnostics.inventory.records[key].map { [$0] } ?? []
                } else {
                    matches = diagnostics.inventory.records.values.filter { record in
                        record.labels["c11.panel"]?.lowercased() == panel.panelID.uuidString.lowercased()
                            && (panel.creationID == nil
                                || record.labels["c11.creation"]?.lowercased() == panel.creationID?.uuidString.lowercased())
                    }
                }
                if matches.count == 1, let record = matches.first {
                    applyBinding(
                        panelID: panel.panelID,
                        key: record.key,
                        record: record,
                        serving: serving,
                        configured: configured,
                        generation: generation,
                        identity: identity,
                        persistence: panel.persistence.rawValue,
                        creationID: panel.creationID,
                        linkDown: Self.linkDown(record: record, key: record.key, snapshot: diagnostics.inventory, previous: rows[panel.panelID])
                    )
                    annotateMachine(panelID: panel.panelID, key: record.key, record: record)
                    continue
                }
                // An end already read stays: a later missing record is not an undo.
                if rows[panel.panelID]?.lifecycle == "ended" { continue }
                let reason: String?
                if matches.count > 1 {
                    reason = HCDiagnosticTokens.unavailable(.ambiguousIdentity)
                } else if !ready {
                    reason = pendingReason
                } else if panel.creationID != nil {
                    reason = HCDiagnosticTokens.unavailable(.creationPending)
                } else if panel.key != nil {
                    // A saved key whose terminal the inventory does not show is not
                    // new: a missing mirror is uncertainty (L4).
                    reason = HCDiagnosticTokens.unavailable(.connectionLost)
                } else {
                    reason = nil
                }
                if let reason {
                    applyUnreachable(panel: panel, configured: configured, outcome: .unresolved, reason: reason)
                } else if rows[panel.panelID] == nil {
                    upsert(
                        panelID: panel.panelID,
                        terminal: nil,
                        tty: nil,
                        pid: nil,
                        lifecycle: "new",
                        persistence: panel.persistence.rawValue,
                        servingBuild: nil,
                        configuredBuild: configured,
                        reason: nil,
                        attachment: nil,
                        attachFailure: nil,
                        factKey: nil,
                        factProcess: nil
                    )
                }
            }
            return
        }
        for panel in panels where diagnostics.inventory.panelBindings[panel.panelID] == nil {
            // A panel placed in another shard is that shard's to report.
            if let placed = shardOf?(panel), placed.session != shard.session { continue }
            if closedPanels.contains(panel.panelID) { continue }
            let outcome: UnreachableOutcome = inferFallback ? .inferred
                : (panel.persistence == .nonpersistent && panel.key == nil ? .fallback : .unresolved)
            applyUnreachable(panel: panel, configured: configured, outcome: outcome)
        }
    }

    /// The `hc.diagnostics` reply: the recorder's state plus the running c11's version line
    /// (C11H-50), so a report names the build it came from.
    func diagnosticsResponse(appInfo: [String: Any]) -> [String: Any] {
        var object = jsonObject()
        object["c11_version"] = C11BuildIdentity(info: appInfo).versionLine as Any? ?? NSNull()
        return object
    }

    /// C11H-196: each panel's restore notice and host-end recovery, as its
    /// banner shows them, written from main and read off-main with the rows.
    private var recoveryByPanel: [UUID: (notice: String?, hostEnd: [String: Any]?)] = [:]

    func recordPanelRecovery(panelID: UUID, notice: String?, hostEnd: [String: Any]?) {
        lock.lock()
        defer { lock.unlock() }
        if closedPanels.contains(panelID) || (notice == nil && hostEnd == nil) {
            recoveryByPanel.removeValue(forKey: panelID)
        } else {
            recoveryByPanel[panelID] = (notice, hostEnd)
        }
    }

    func jsonObject() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var loginRooted = 0
        let panels = rows.values.sorted { $0.panelID.uuidString < $1.panelID.uuidString }.map { row -> [String: Any] in
            let recovery = recoveryByPanel[row.panelID]
            let root = rootForm(row)
            if root == HCTerminalRootForm.login { loginRooted += 1 }
            return [
                "root": root,
                "restore_notice": Self.json(recovery?.notice),
                "host_end": recovery?.hostEnd ?? NSNull(),
                "panel_id": row.panelID.uuidString,
                "terminal": Self.json(row.terminal),
                "machine": Self.json(row.machine),
                "tty": Self.json(row.tty),
                "pid": Self.json(row.pid),
                "lifecycle": row.lifecycle,
                "persistence": Self.json(row.persistence),
                "serving_build": Self.json(row.servingBuild),
                "configured_build": Self.json(row.configuredBuild),
                "reason": Self.json(row.attachFailure ?? row.reason),
                "shard": Self.json(row.shard),
            ]
        }
        let ordered = shards.values.sorted {
            ($0.shard.index, $0.shard.session) < ($1.shard.index, $1.shard.session)
        }
        let shardList = ordered.map { state -> [String: Any] in
            return [
                "session": state.shard.session,
                "index": state.shard.index,
                "legacy": state.shard.isLegacy,
                // C11H-391: `links (c11)` for an adopted app's links session.
                "label": state.shard.label,
                "core_id": Self.json(state.coreID),
                "holder_pid": state.liveHolders.count == 1 ? Self.json(state.liveHolders[0]) : NSNull(),
                "holder_pids": state.liveHolders.map { Int($0) },
                "last_lost_holder_pid": Self.json(state.lastLostHolderPID),
                "readiness": Self.json(state.readiness),
                "readiness_reason": Self.json(state.readinessReason),
                "connection_generation": Self.json(state.generation),
                "sequence": Self.json(state.sequence),
                "terminals": state.liveTerminals,
                "ended": state.endedTerminals,
                "remote_terminals": state.remoteLiveTerminals,
                "remote_ended": state.remoteEndedTerminals,
                "holder_lost_count": state.holderLostCount,
            ]
        }
        // One shard reads exactly as the single session always did. With several,
        // a top-level generation or sequence would name an arbitrary shard, so it
        // is null and each shard carries its own. Readiness is ready only when
        // every shard is.
        let multiple = ordered.count > 1
        let readiness: String?
        let readinessReason: String?
        if multiple {
            let pending = ordered.first { $0.readiness != "ready" && $0.readiness != nil }
            if let pending {
                readiness = "pending"
                readinessReason = pending.readinessReason
            } else {
                readiness = ordered.contains { $0.readiness == "ready" } ? "ready" : nil
                readinessReason = nil
            }
        } else {
            readiness = sessionReadiness
            readinessReason = sessionReadinessReason
        }
        return [
            "holder_lost_count": holderLostCountStorage,
            "holder_lost_count_error": Self.json(countError),
            "login_rooted": loginRooted,
            "readiness": Self.json(readiness),
            "readiness_reason": Self.json(readinessReason),
            "connection_generation": multiple ? NSNull() : Self.json(connectionGeneration),
            "sequence": multiple ? NSNull() : Self.json(revisionSequence),
            "shards": shardList,
            "panels": panels,
        ]
    }

    /// C11H-235: `shell`, `login` or `other` for a live local terminal whose
    /// root the kernel still holds; `n/a` for a remote terminal (its pid is
    /// that machine's, never read here) or one with no live root.
    /// Only a pid this Mac's kernel already answered for (the tty read, which
    /// runs for local records only, recorded its process) is read again, so a
    /// remote record's pid never reaches a local syscall.
    private func rootForm(_ row: PanelRow) -> String {
        guard row.machine == nil, row.lifecycle == "live", let pid = row.pid,
              let process = row.factProcess, process.pid == pid,
              let form = rootResolver(pid, process) else { return HCTerminalRootForm.notApplicable }
        return form
    }

    private static func json(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func json(_ value: Int32?) -> Any {
        if let value, value > 0 { return Int(value) }
        return NSNull()
    }

    private static func json(_ value: UInt64?) -> Any {
        if let value { return NSNumber(value: value) }
        return NSNull()
    }

    func logText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    private func recordUnlocked(_ event: HCDiagnosticEvent) {
        switch event {
        case .attachmentProgress(let panel, let phase, let outcome, let wait):
            writeLine([
                ("event", "attachment_progress"), ("panel_id", panel.panelID.uuidString),
                ("terminal", panel.key.flatMap { Self.terminalToken($0.localAddress) } ?? "none"),
                ("creation_id", panel.creationID?.uuidString),
                ("phase", HCDiagnosticTokens.token(phase)),
                ("outcome", HCDiagnosticTokens.token(outcome)),
                ("wait_ms", String(wait / 1_000_000))
            ], signature: nil)
        case .attach(let panelID, let terminal, let servingBuild, let tty):
            applyAttach(panelID: panelID, terminal: terminal, servingBuild: servingBuild, tty: tty, reattach: false)
        case .reattach(let panelID, let terminal, let servingBuild, let tty):
            applyAttach(panelID: panelID, terminal: terminal, servingBuild: servingBuild, tty: tty, reattach: true)
        case .coreUnreachable(let panel, let configuredBuild):
            sessionReadiness = "pending"
            sessionReadinessReason = "core_unreachable"
            applyUnreachable(panel: panel, configured: Self.pinToken(configuredBuild), outcome: .inferred)
        case .coreUnresolved(let panel, let configuredBuild):
            sessionReadiness = "pending"
            sessionReadinessReason = "core_unreachable"
            applyUnreachable(panel: panel, configured: Self.pinToken(configuredBuild), outcome: .unresolved)
        case .fallback(let panel, let configuredBuild):
            sessionReadiness = "pending"
            sessionReadinessReason = "core_unreachable"
            applyUnreachable(panel: panel, configured: Self.pinToken(configuredBuild), outcome: .fallback)
        case .attachFailed(let panelID, let terminal, let servingBuild, let reason):
            let previous = rows[panelID]
            let terminalToken = Self.terminalToken(terminal) ?? previous?.terminal
            let build = Self.pinToken(servingBuild)
            let reasonToken = HCDiagnosticTokens.reason(reason)
            // Attachment failed. That is not an end, and a later inventory
            // snapshot must not drop the reason or invent an attach.
            upsert(
                panelID: panelID,
                terminal: terminalToken,
                tty: previous?.tty,
                pid: previous?.pid,
                lifecycle: previous?.lifecycle ?? "new",
                persistence: previous?.persistence,
                servingBuild: build ?? previous?.servingBuild,
                configuredBuild: previous?.configuredBuild ?? build,
                reason: previous?.reason,
                attachment: previous?.attachment,
                attachFailure: reasonToken,
                factKey: previous?.factKey,
                factProcess: previous?.factProcess
            )
            writeLine(
                [
                    ("event", "attach_failed"),
                    ("panel_id", panelID.uuidString),
                    ("terminal", terminalToken),
                    ("serving_build", build),
                    ("reason", reasonToken),
                ],
                signature: nil
            )
        case .recovery(let reason, let result, let servingBuild):
            guard let resultToken = Self.recoveryToken(result) else { return }
            writeLine(
                [
                    ("event", "recovery"),
                    ("reason", HCDiagnosticTokens.reason(reason)),
                    ("result", resultToken),
                    ("serving_build", servingBuild.flatMap(Self.pinToken)),
                ],
                signature: nil
            )
        case .gateRefused(let callerPid, let ancestry, let reason):
            guard callerPid > 0 else { return }
            let ancestryToken = Self.ancestryToken(ancestry)
            let reasonToken = HCDiagnosticTokens.reason(reason)
            // T7.4 greps the adjacent words `gate refused`. `event=gate` keeps a key on the line.
            var parts = ["event=gate", "gate refused", "caller_pid=\(callerPid)"]
            if let ancestryToken { parts.append("ancestry=\(ancestryToken)") }
            if let reasonToken { parts.append("reason=\(reasonToken)") }
            appendLine(parts.joined(separator: " "))
        case .fileLimit(let soft, let hard, let kernelCap, let beforeSoft):
            var fields: [(String, String?)] = [
                ("event", "rlimit_nofile"),
                ("soft", String(soft)),
                ("hard", String(hard)),
            ]
            if let kernelCap { fields.append(("kernel_cap", String(kernelCap))) }
            if let beforeSoft { fields.append(("before_soft", String(beforeSoft))) }
            let signature = fields.compactMap { key, value in value.map { "\(key)=\($0)" } }.joined(separator: " ")
            writeOnce(signature: signature, fields: fields)
        case .holderLost(let coreID, let terminal, let discriminator, let holderID):
            let unkeyed = discriminator.range(of: #"^g[0-9]+$"#, options: .regularExpression) != nil
            noteHolderLost(
                coreID: coreID,
                terminal: terminal,
                discriminator: discriminator,
                holderID: holderID,
                unkeyed: unkeyed,
                rootPID: Self.rootPID(fromDiscriminator: discriminator)
            )
        case .panelNew(let panel):
            let terminal = panel.key.flatMap { Self.terminalToken($0.localAddress) }
            let previous = rows[panel.panelID]
            upsert(
                panelID: panel.panelID,
                terminal: terminal ?? previous?.terminal,
                tty: previous?.tty,
                pid: previous?.pid,
                lifecycle: "new",
                persistence: panel.persistence.rawValue,
                servingBuild: previous?.servingBuild,
                configuredBuild: previous?.configuredBuild,
                reason: nil,
                attachment: previous?.attachment,
                attachFailure: previous?.attachFailure,
                factKey: previous?.factKey,
                factProcess: previous?.factProcess
            )
            writeOnce(
                signature: "lifecycle:\(panel.panelID.uuidString):new",
                fields: [
                    ("event", "lifecycle"),
                    ("panel_id", panel.panelID.uuidString),
                    ("terminal", terminal),
                    ("lifecycle", "new"),
                    ("persistence", HCDiagnosticTokens.token(panel.persistence.rawValue)),
                ]
            )
        case .panelEnded(let panelID, let reason):
            let previous = rows[panelID]
            let reasonToken = reason.flatMap(HCDiagnosticTokens.reason)
            upsert(
                panelID: panelID,
                terminal: previous?.terminal,
                tty: previous?.tty,
                pid: previous?.pid,
                lifecycle: "ended",
                persistence: previous?.persistence,
                servingBuild: previous?.servingBuild,
                configuredBuild: previous?.configuredBuild,
                reason: reasonToken,
                attachment: nil,
                attachFailure: nil,
                factKey: previous?.factKey,
                factProcess: previous?.factProcess
            )
            writeOnce(
                signature: "lifecycle:\(panelID.uuidString):ended:\(reasonToken ?? "")",
                fields: [
                    ("event", "lifecycle"),
                    ("panel_id", panelID.uuidString),
                    ("lifecycle", "ended"),
                    ("reason", reasonToken),
                ]
            )
        case .panelClosed(let panelID):
            writeOnce(
                signature: "close:\(panelID.uuidString)",
                fields: [
                    ("event", "close"),
                    ("panel_id", panelID.uuidString),
                ]
            )
            closedPanels.insert(panelID)
            rows.removeValue(forKey: panelID)
            recoveryByPanel.removeValue(forKey: panelID)
        case .recoveredHome(let panelID, let terminal, let workspaceID, let reason):
            writeLine(
                [
                    ("event", "recovered_home"),
                    ("panel_id", panelID.uuidString),
                    ("terminal", Self.terminalToken(terminal)),
                    ("workspace_id", workspaceID.uuidString),
                    ("reason", HCDiagnosticTokens.reason(reason)),
                ],
                signature: nil
            )
        case .outsideSignalEnd(let panelID, let terminal, let signal, let kept, let agent):
            writeLine(
                [
                    ("event", "outside_signal_end"),
                    ("panel_id", panelID.uuidString),
                    ("terminal", Self.terminalToken(terminal)),
                    ("signal", String(signal)),
                    ("outcome", kept ? "kept" : "closed"),
                    ("agent", agent.flatMap { HCDiagnosticTokens.token($0.replacingOccurrences(of: "-", with: "_")) }),
                ],
                signature: nil
            )
        case .massSignalEnd(let id, let count, let signals, let autoResume):
            writeLine(
                [
                    ("event", "mass_signal_end"),
                    ("mass_end_id", id.uuidString),
                    ("count", String(count)),
                    ("signals", signals.map(String.init).joined(separator: "_")),
                    ("auto_resume", autoResume ? "1" : "0"),
                ],
                signature: nil
            )
        }
    }

    private func applySession(_ diagnostics: HCDiagnostics, shard: HCShardIdentity) {
        var state = shards[shard.session] ?? ShardState(shard: shard)
        switch diagnostics.inventory.readiness {
        case .ready:
            let becameReady = state.readiness != "ready"
            sessionReadiness = "ready"
            sessionReadinessReason = nil
            state.readiness = "ready"
            state.readinessReason = nil
            // The same pending snapshot stays one line. The next outage, after
            // the core has been ready, is a new line. C11H-196: only on this
            // shard's pending-to-ready edge. Clearing on every ready snapshot of
            // any shard rewrote every unreachable panel's line each time
            // (~700 lines/s with a remote machine down and nine shards).
            if becameReady {
                signatures = signatures.filter { key, _ in
                    !key.hasPrefix("fallback:") && !key.hasPrefix("unresolved:")
                }
            }
        case .pending(let reason):
            sessionReadiness = "pending"
            sessionReadinessReason = HCDiagnosticTokens.unavailable(reason)
            state.readiness = "pending"
            state.readinessReason = HCDiagnosticTokens.unavailable(reason)
        }
        connectionGeneration = diagnostics.inventory.revision.connectionGeneration
        revisionSequence = diagnostics.inventory.revision.sequence
        state.generation = diagnostics.inventory.revision.connectionGeneration
        state.sequence = diagnostics.inventory.revision.sequence
        if let identity = diagnostics.servingBuild ?? diagnostics.inventory.buildIdentity,
           let core = Self.coreToken(identity.coreID) {
            state.coreID = core
        }
        sampleHolder(&state, inventory: diagnostics.inventory)
        shards[shard.session] = state
    }

    /// Learn each running local terminal's holder from its root pid, once per
    /// root pid, and count the shard's terminals from its inventory records. A
    /// pending inventory changes neither: the last ready answer stands. A
    /// mapping outlives the snapshot that ends its terminal by one snapshot, so
    /// the end that names a root pid can still find its holder; a loss clears
    /// only the holder that died.
    private func sampleHolder(_ state: inout ShardState, inventory: HCInventorySnapshot) {
        guard case .ready = inventory.readiness else { return }
        let running = inventory.records.values.filter { $0.state == .running || $0.state == .starting }
        let finished = inventory.records.values.filter { $0.state == .finished }
        state.liveTerminals = running.filter { $0.machineAvailability == .local }.count
        state.endedTerminals = finished.filter { $0.machineAvailability == .local }.count
        state.remoteLiveTerminals = running.count - state.liveTerminals
        state.remoteEndedTerminals = finished.count - state.endedTerminals
        let live = Set(running.compactMap { record -> Int32? in
            guard record.machineAvailability == .local, let pid = record.pid, pid > 0 else { return nil }
            return pid
        })
        let recordPIDs = Set(inventory.records.values.compactMap { $0.pid }.filter { $0 > 0 })
        let keep = state.liveRoots.union(live).union(recordPIDs)
        state.holderByRoot = state.holderByRoot.filter { keep.contains($0.key) }
        for pid in live where state.holderByRoot[pid] == nil {
            if let holder = HCShardHolder.holderPID(terminalPIDs: [pid], parentOf: parentOf) {
                state.holderByRoot[pid] = holder
            }
        }
        state.liveRoots = live
    }

    private func applyAttach(panelID: UUID, terminal: String, servingBuild: String, tty: String?, reattach: Bool) {
        let terminalToken = Self.terminalToken(terminal)
        let build = Self.pinToken(servingBuild)
        let ttyToken = tty.flatMap(Self.ttyToken)
        let previous = rows[panelID]
        // A different terminal is a new process. Do not keep the old pid.
        let sameTerminal = terminalToken != nil && terminalToken == previous?.terminal
        upsert(
            panelID: panelID,
            terminal: terminalToken,
            tty: ttyToken,
            pid: sameTerminal ? previous?.pid : nil,
            lifecycle: "live",
            persistence: previous?.persistence ?? "persistent",
            servingBuild: build,
            configuredBuild: previous?.configuredBuild ?? build,
            reason: nil,
            attachment: "\(terminalToken ?? ""):\(build ?? "")",
            attachFailure: nil,
            factKey: sameTerminal ? previous?.factKey : nil,
            factProcess: sameTerminal ? previous?.factProcess : nil
        )
        // The next direct outage is a new occurrence. Snapshot dedupe stays.
        retireOutageSignatures(panelID: panelID)
        let event = reattach ? "reattach" : "attach"
        var fields: [(String, String?)] = [
            ("event", event),
            ("panel_id", panelID.uuidString),
            ("terminal", terminalToken),
        ]
        if !reattach { fields.append(("lifecycle", "live")) }
        fields.append(("serving_build", build))
        // Each record() is one occurrence. Snapshot dedupe does not apply.
        writeLine(fields, signature: nil)
    }

    /// Fallback is a keyless fresh shell that has not become a terminal, and
    /// it stays for the life of that shell. A registered `new` row is not a
    /// terminal. A saved key is unresolved, whatever origin says.
    private enum UnreachableOutcome { case inferred, unresolved, fallback }

    private func applyUnreachable(
        panel: HCPanelIdentity,
        configured: String?,
        outcome: UnreachableOutcome,
        reason: String = "core_unreachable"
    ) {
        let previous = rows[panel.panelID]
        let saved = panel.key.flatMap { Self.terminalToken($0.localAddress) }
        let terminal = previous?.terminal ?? saved
        let fallback: Bool
        switch outcome {
        case .inferred: fallback = projectsFallback(panel: panel, previous: previous, savedTerminal: saved)
        // A shell that fell back stays a fallback for its life.
        case .unresolved: fallback = previous?.lifecycle == "fallback"
        case .fallback: fallback = true
        }
        let lifecycle = fallback ? "fallback" : "unresolved"
        let persistence = fallback
            ? HCPersistence.nonpersistent.rawValue
            : (previous?.persistence ?? panel.persistence.rawValue)
        upsert(
            panelID: panel.panelID,
            terminal: terminal,
            tty: previous?.tty,
            pid: previous?.pid,
            lifecycle: lifecycle,
            persistence: persistence,
            servingBuild: previous?.servingBuild,
            configuredBuild: configured ?? previous?.configuredBuild,
            reason: reason,
            attachment: previous?.attachment,
            attachFailure: previous?.attachFailure,
            factKey: previous?.factKey,
            factProcess: previous?.factProcess
        )
        let event = fallback ? "fallback" : "unresolved"
        var fields: [(String, String?)] = [
            ("event", event),
            ("panel_id", panel.panelID.uuidString),
            ("reason", reason),
            ("configured_build", configured),
            ("lifecycle", lifecycle),
        ]
        if let terminal {
            fields.append(("terminal", terminal))
        }
        writeOnce(
            signature: "\(event):\(panel.panelID.uuidString):\(reason):\(configured ?? "")",
            fields: fields
        )
    }

    /// The binding is still in the last inventory, but the core is pending
    /// unreachable. Keep the terminal. Do not log an attach.
    private func applyRetainedUnreachable(
        panelID: UUID,
        key: HCTerminalKey,
        record: HCTerminalRecord?,
        configured: String?,
        persistence: String?
    ) {
        let previous = rows[panelID]
        let terminal = Self.terminalToken(key.localAddress) ?? previous?.terminal
        let facts = kernelFacts(key: key, record: record, previous: previous)
        upsert(
            panelID: panelID,
            terminal: terminal,
            tty: facts.tty,
            pid: facts.pid,
            lifecycle: "unresolved",
            persistence: persistence ?? previous?.persistence,
            servingBuild: previous?.servingBuild,
            configuredBuild: configured ?? previous?.configuredBuild,
            reason: "core_unreachable",
            attachment: previous?.attachment,
            attachFailure: previous?.attachFailure,
            factKey: facts.factKey,
            factProcess: facts.factProcess
        )
        // The outage does not drop the machine or the qualified address (P2-F1).
        annotateMachine(panelID: panelID, key: key, record: record)
        var fields: [(String, String?)] = [
            ("event", "unresolved"),
            ("panel_id", panelID.uuidString),
            ("reason", "core_unreachable"),
            ("configured_build", configured ?? previous?.configuredBuild),
            ("lifecycle", "unresolved"),
        ]
        if let terminal {
            fields.append(("terminal", terminal))
        }
        writeOnce(
            signature: "unresolved:\(panelID.uuidString):\(configured ?? "")",
            fields: fields
        )
    }

    private func applyBinding(
        panelID: UUID,
        key: HCTerminalKey,
        record: HCTerminalRecord?,
        serving: String?,
        configured: String?,
        generation: UInt64,
        identity: HCBuildIdentity?,
        persistence: String?,
        creationID: UUID?,
        linkDown: Bool = false
    ) {
        let terminal = Self.terminalToken(key.localAddress)
        let previous = rows[panelID]
        // An end names its own facts. A later live record may keep them only
        // when it is still this terminal and this process.
        let endedFacts = kernelFacts(key: key, record: record, previous: nil, readKernel: false)
        if let endReason = record?.endReason, HCDiagnosticTokens.reason(endReason) == "holder_lost" {
            let coreID = identity?.coreID ?? key.owningCoreID
            if let resolved = resolvedDiscriminator(
                record: record,
                creationID: creationID,
                generation: generation,
                coreID: coreID,
                terminal: key.localAddress
            ) {
                noteHolderLost(
                    coreID: coreID,
                    terminal: key.localAddress,
                    discriminator: resolved.token,
                    holderID: nil,
                    unkeyed: resolved.unkeyed,
                    rootPID: record?.pid ?? previous?.pid
                )
            }
            upsert(
                panelID: panelID,
                terminal: terminal,
                tty: endedFacts.tty,
                pid: endedFacts.pid,
                lifecycle: "ended",
                persistence: persistence ?? previous?.persistence,
                servingBuild: serving,
                configuredBuild: configured,
                reason: "holder_lost",
                attachment: nil,
                attachFailure: nil,
                factKey: endedFacts.factKey,
                factProcess: endedFacts.factProcess
            )
            return
        }
        if record?.state == .finished {
            let reason = record?.endReason.flatMap(HCDiagnosticTokens.reason)
            upsert(
                panelID: panelID,
                terminal: terminal,
                tty: endedFacts.tty,
                pid: endedFacts.pid,
                lifecycle: "ended",
                persistence: persistence ?? previous?.persistence,
                servingBuild: serving,
                configuredBuild: configured ?? serving,
                reason: reason,
                attachment: nil,
                attachFailure: nil,
                factKey: endedFacts.factKey,
                factProcess: endedFacts.factProcess
            )
            writeOnce(
                signature: "ended:\(panelID.uuidString):\(reason ?? "")",
                fields: [
                    ("event", "lifecycle"),
                    ("panel_id", panelID.uuidString),
                    ("terminal", terminal),
                    ("lifecycle", "ended"),
                    ("reason", reason),
                ]
            )
            return
        }
        let live: Bool
        switch record?.state {
        case .running?, .starting?: live = true
        default: live = false
        }
        guard live else { return }
        rememberLive(
            coreID: identity?.coreID ?? key.owningCoreID,
            terminal: key.localAddress,
            record: record,
            creationID: creationID
        )
        // Inventory shows a running terminal. It does not mean attach or
        // reattach succeeded, and it does not clear an attach failure.
        // Pid and tty carry forward only for this same terminal and process.
        let becameLive = previous?.lifecycle != "live" && !linkDown
        let facts = kernelFacts(key: key, record: record, previous: previous)
        // A remote terminal whose machine link is down is not live: the same test
        // the panel's chip uses (`HCRemoteStatus.reachable`), so the CLI and the
        // mark agree (P2-F1). It is `unresolved`, never an end.
        upsert(
            panelID: panelID,
            terminal: terminal ?? previous?.terminal,
            tty: facts.tty,
            pid: facts.pid,
            lifecycle: linkDown ? "unresolved" : "live",
            persistence: persistence ?? previous?.persistence ?? "persistent",
            servingBuild: serving ?? previous?.servingBuild,
            configuredBuild: configured ?? serving ?? previous?.configuredBuild,
            reason: linkDown ? "connection_lost" : nil,
            attachment: previous?.attachment,
            attachFailure: previous?.attachFailure,
            factKey: facts.factKey,
            factProcess: facts.factProcess
        )
        if linkDown {
            writeOnce(
                signature: "link:\(panelID.uuidString)",
                fields: [
                    ("event", "unresolved"),
                    ("panel_id", panelID.uuidString),
                    ("reason", "connection_lost"),
                    ("lifecycle", "unresolved"),
                    ("terminal", terminal ?? previous?.terminal),
                ]
            )
        } else {
            // Link back: the next drop is a new line.
            signatures.removeValue(forKey: "link:\(panelID.uuidString)")
        }
        if becameLive {
            writeOnce(
                signature: "lifecycle:\(panelID.uuidString):live",
                fields: [
                    ("event", "lifecycle"),
                    ("panel_id", panelID.uuidString),
                    ("terminal", terminal ?? previous?.terminal),
                    ("lifecycle", "live"),
                    ("serving_build", serving ?? previous?.servingBuild),
                ]
            )
        }
    }

    /// A remote panel's row names its machine and its terminal as the CLI does
    /// (`studio/t15`) (P2-F1).
    private func annotateMachine(panelID: UUID, key: HCTerminalKey, record: HCTerminalRecord?) {
        guard var row = rows[panelID] else { return }
        // No record in this snapshot: the row keeps the machine it already named.
        let machine = record.map { $0.machineName.flatMap(Self.machineToken) } ?? row.machine
        row.machine = machine
        if let machine, let address = Self.terminalToken("\(machine)/\(key.localAddress)") {
            row.terminal = address
        }
        rows[panelID] = row
    }

    private static func linkDown(record: HCTerminalRecord?, key: HCTerminalKey,
                                 snapshot: HCInventorySnapshot, previous: PanelRow?) -> Bool {
        // A resnapshot proves neither loss nor recovery. Keep the previous
        // verdict until fresh inventory arrives; actual loss still reads down.
        if case .pending(.inventoryPending) = snapshot.readiness {
            return previous?.lifecycle == "unresolved" && previous?.reason == "connection_lost"
        }
        return record?.machineName != nil && HCRemoteStatus.reachable(snapshot, key: key) == nil
    }

    private static func machineToken(_ raw: String) -> String? {
        raw.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil ? raw : nil
    }

    /// A terminal is counted once. Endings that share a holder id are one
    /// incident. Without one, endings on the same core inside the coalesce
    /// window are one incident. A holder id whose terminals are already seen
    /// attaches to that incident and does not open another. Seen terminals are
    /// never dropped: dropping one would count a finished record again.
    private func noteHolderLost(
        coreID: String,
        terminal: String,
        discriminator: String,
        holderID: String?,
        unkeyed: Bool,
        rootPID: Int32? = nil
    ) {
        guard let core = Self.coreToken(coreID),
              let address = Self.terminalToken(terminal),
              let disc = Self.discriminatorToken(discriminator) else { return }
        let apply = {
            self.applyHolderLost(
                core: core,
                address: address,
                discriminator: disc,
                holderID: holderID,
                unkeyed: unkeyed,
                rootPID: rootPID
            )
        }
        if persistEnabled {
            withCounterLock {
                adoptDisk()
                apply()
                writeCounterFile()
            }
        } else {
            apply()
        }
    }

    private func applyHolderLost(
        core: String,
        address: String,
        discriminator: String,
        holderID: String?,
        unkeyed: Bool,
        rootPID: Int32?
    ) {
        let cacheKey = "\(core):\(address)"
        let chosen: String
        let chosenUnkeyed: Bool
        // A g<generation> token is not a stable identity. Caching it froze the
        // key, so a later connection generation never counted.
        if let cached = liveDiscriminators[cacheKey],
           Self.discriminatorToken(cached) != nil,
           !Self.isGenerationDiscriminator(cached) {
            chosen = cached
            chosenUnkeyed = false
        } else {
            chosen = discriminator
            chosenUnkeyed = unkeyed
            if !chosenUnkeyed {
                liveDiscriminators[cacheKey] = chosen
            }
        }
        let terminalKey = "\(core):\(address):\(chosen)"
        let already = seenTerminals.contains(terminalKey)
        let replayedGeneration = !already && chosenUnkeyed && hasEarlierGenerationKey(core: core, address: address, terminalKey: terminalKey)
        if !already {
            seenTerminals.insert(terminalKey)
        }
        if chosenUnkeyed {
            writeOnce(
                signature: "unkeyed:\(terminalKey)",
                fields: [
                    ("event", "holder_lost_unkeyed"),
                    ("core_id", core),
                    ("terminal", address),
                ]
            )
        }

        var holderKey: String?
        if let holderID, let holder = Self.holderToken(holderID) {
            holderKey = "\(core):h:\(holder)"
        }
        if already {
            if let holderKey, !seenHolders.contains(holderKey) {
                seenHolders.insert(holderKey)
            }
            return
        }

        let nowMs = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let generationStamp = chosenUnkeyed ? "\(core):\(chosen)" : nil
        let opensIncident: Bool
        if holderKey == nil, !replayedGeneration, openIncidentSequence[core] != nil {
            // The same holder's death, seen again: one kill is one count.
            opensIncident = false
        } else if let holderKey {
            opensIncident = !seenHolders.contains(holderKey)
            seenHolders.insert(holderKey)
        } else if let generationStamp {
            let generationHot = Self.withinCoalesce(nowMs, lastIncidentMilliseconds[generationStamp], coalesceMilliseconds)
            if replayedGeneration {
                // A new generation is the accepted overcount: one extra
                // incident even inside the previous generation's window.
                opensIncident = !generationHot
            } else {
                let coreHot = Self.withinCoalesce(nowMs, lastIncidentMilliseconds[core], coalesceMilliseconds)
                opensIncident = !generationHot && !coreHot
            }
        } else if Self.withinCoalesce(nowMs, lastIncidentMilliseconds[core], coalesceMilliseconds) {
            opensIncident = false
        } else {
            opensIncident = true
        }
        if opensIncident {
            holderLostCountStorage += 1
            openIncidentSequence[core] = ingestSequence
            lastIncidentMilliseconds[core] = nowMs
            if let generationStamp {
                lastIncidentMilliseconds[generationStamp] = nowMs
            }
            var fields: [(String, String?)] = [
                ("event", "holder_lost"),
                ("core_id", core),
                ("count", String(holderLostCountStorage)),
            ]
            // The incident belongs to one shard: its session, the holder that
            // died, and that shard's own running count. Fields come last so
            // `event=holder_lost core_id=... count=...` still matches.
            if let session = ingestShard?.session ?? shardSession(forCore: core),
               var state = shards[session] {
                // The holder that died is the one that parents the lost terminal.
                // Every terminal under it ends with it; a holder that still parents
                // a running terminal is not touched.
                let lostHolder = rootPID.flatMap { state.holderByRoot[$0] }
                state.holderLostCount += 1
                if let lostHolder {
                    state.lastLostHolderPID = lostHolder
                    state.holderByRoot = state.holderByRoot.filter { $0.value != lostHolder }
                }
                shards[session] = state
                fields.append(("shard", session))
                fields.append(("holder_pid", lostHolder.map { String($0) }))
                fields.append(("shard_count", String(state.holderLostCount)))
            }
            writeLine(fields, signature: nil)
        } else if let generationStamp, lastIncidentMilliseconds[generationStamp] == nil {
            lastIncidentMilliseconds[generationStamp] = nowMs
        }
    }

    /// The one shard whose core this is, when an event names a core but no shard.
    private func shardSession(forCore core: String) -> String? {
        let matches = shards.values.filter { $0.coreID == core }
        return matches.count == 1 ? matches[0].shard.session : nil
    }

    /// `p<pid>:<start>` names the terminal's root process.
    private static func rootPID(fromDiscriminator raw: String) -> Int32? {
        guard raw.hasPrefix("p"), let end = raw.firstIndex(of: ":") else { return nil }
        return Int32(raw[raw.index(after: raw.startIndex)..<end])
    }

    /// This address was already counted under a different `g<generation>`.
    private func hasEarlierGenerationKey(core: String, address: String, terminalKey: String) -> Bool {
        let prefix = "\(core):\(address):g"
        return seenTerminals.contains { key in
            guard key != terminalKey, key.hasPrefix(prefix), key.count > prefix.count else { return false }
            return key.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }
    }

    private static func withinCoalesce(_ nowMs: Int64, _ last: Int64?, _ window: Int64) -> Bool {
        guard let last else { return false }
        return nowMs >= last && nowMs - last <= window
    }

    /// The first stable discriminator for this core and address wins, including
    /// over a later creation id. A `g<generation>` token is not cached. On a
    /// miss: process identity, then creation id, then hc pid, then this
    /// connection generation. The last counts and is logged
    /// `holder_lost_unkeyed`. A later generation is a new key.
    private func resolvedDiscriminator(
        record: HCTerminalRecord?,
        creationID: UUID?,
        generation: UInt64,
        coreID: String,
        terminal: String
    ) -> (token: String, unkeyed: Bool)? {
        guard let core = Self.coreToken(coreID), let address = Self.terminalToken(terminal) else { return nil }
        let cacheKey = "\(core):\(address)"
        if let cached = liveDiscriminators[cacheKey],
           Self.discriminatorToken(cached) != nil,
           !Self.isGenerationDiscriminator(cached) {
            return (cached, false)
        }
        if let stable = Self.stableDiscriminator(record: record, creationID: creationID, includePid: false) {
            return (stable, false)
        }
        if let pid = Self.stableDiscriminator(record: record, creationID: nil, includePid: true) {
            return (pid, false)
        }
        return ("g\(generation)", true)
    }

    /// Process identity, else creation id, else hc pid when `includePid`.
    private static func stableDiscriminator(
        record: HCTerminalRecord?,
        creationID: UUID?,
        includePid: Bool
    ) -> String? {
        if let process = record?.localProcessIdentity, process.pid > 0 {
            return "p\(process.pid):\(process.startTimeMicroseconds)"
        }
        if let creationID {
            return creationID.uuidString
        }
        if includePid, let pid = record?.pid, pid > 0 {
            return "hcpid:\(pid)"
        }
        return nil
    }

    private func rememberLive(coreID: String, terminal: String, record: HCTerminalRecord?, creationID: UUID?) {
        guard let core = Self.coreToken(coreID), let address = Self.terminalToken(terminal) else { return }
        guard let disc = Self.stableDiscriminator(record: record, creationID: creationID, includePid: true) else { return }
        let cacheKey = "\(core):\(address)"
        // The first sighting wins, including a value another process already
        // stored. Check again after adoptDisk: the pre-lock read can miss.
        if liveDiscriminators[cacheKey] != nil { return }
        let store = {
            if self.liveDiscriminators[cacheKey] == nil {
                self.liveDiscriminators[cacheKey] = disc
            }
        }
        if persistEnabled {
            withCounterLock {
                adoptDisk()
                store()
                writeCounterFile()
            }
        } else {
            store()
        }
    }

    private func upsert(
        panelID: UUID,
        terminal: String?,
        tty: String?,
        pid: Int32?,
        lifecycle: String,
        persistence: String?,
        servingBuild: String?,
        configuredBuild: String?,
        reason: String?,
        attachment: String?,
        attachFailure: String?,
        factKey: HCTerminalKey?,
        factProcess: HCProcessIdentity?
    ) {
        // C11H-205: a panel closed for good never gets a row back.
        guard !closedPanels.contains(panelID), Self.lifecycleToken(lifecycle) != nil else { return }
        if lifecycle != "live" {
            signatures.removeValue(forKey: "lifecycle:\(panelID.uuidString):live")
        }
        let storedPID = pid.flatMap { $0 > 0 ? $0 : nil }
        let keepsFacts = tty != nil || storedPID != nil
        rows[panelID] = PanelRow(
            panelID: panelID,
            terminal: terminal,
            machine: rows[panelID]?.machine,
            tty: tty,
            pid: storedPID,
            lifecycle: lifecycle,
            persistence: persistence.flatMap(HCDiagnosticTokens.token),
            servingBuild: servingBuild,
            configuredBuild: configuredBuild,
            reason: reason.flatMap(HCDiagnosticTokens.token),
            attachment: attachment,
            attachFailure: attachFailure.flatMap(HCDiagnosticTokens.token),
            factKey: keepsFacts ? factKey : nil,
            factProcess: keepsFacts ? factProcess : nil,
            shard: ingestShard?.session ?? rows[panelID]?.shard
        )
    }

    /// Cached pid and tty stay only while the binding is still that terminal
    /// and that process incarnation. A replacement, or a record that does not
    /// name the process, does not inherit them.
    private func kernelFacts(
        key: HCTerminalKey,
        record: HCTerminalRecord?,
        previous: PanelRow?,
        readKernel: Bool = true
    ) -> (tty: String?, pid: Int32?, factKey: HCTerminalKey?, factProcess: HCProcessIdentity?) {
        let incomingPID: Int32? = {
            guard let value = record?.pid, value > 0 else { return nil }
            return value
        }()
        // The core reports no tty. A local, running terminal's comes from the
        // kernel, once per pid: the cached one stands while the same terminal
        // keeps the same pid, so a snapshot of many terminals reads each once.
        var kernelTTY: String?
        var kernelProcess: HCProcessIdentity?
        if readKernel, record?.tty == nil, record?.machineName == nil, record?.state == .running, let pid = incomingPID {
            if previous?.factKey == key, previous?.pid == pid, let cached = previous?.tty {
                kernelTTY = cached
                kernelProcess = previous?.factProcess
            } else if let read = ttyResolver(pid) {
                kernelTTY = read.tty
                kernelProcess = read.process
            }
        }
        let incomingTTY = record?.tty.flatMap(Self.ttyToken) ?? kernelTTY.flatMap(Self.ttyToken)
        let incomingProcess = record?.localProcessIdentity.flatMap { $0.pid > 0 ? $0 : nil } ?? kernelProcess
        let sameProcess = previous?.factKey == key
            && incomingProcess != nil
            && previous?.factProcess == incomingProcess
        let tty = incomingTTY ?? (sameProcess ? previous?.tty : nil)
        let pid = incomingPID ?? (sameProcess ? previous?.pid : nil)
        guard tty != nil || pid != nil else { return (nil, nil, nil, nil) }
        let process = incomingProcess ?? (sameProcess ? previous?.factProcess : nil)
        return (tty, pid, key, process)
    }

    /// A keyless fresh shell that is not yet a terminal. Once fallback, it stays.
    /// A `new` row only means the panel was registered.
    private func projectsFallback(panel: HCPanelIdentity, previous: PanelRow?, savedTerminal: String?) -> Bool {
        if previous?.lifecycle == "fallback" { return true }
        guard savedTerminal == nil else { return false }
        // An outstanding creation may still be running on the core: it is waiting, not a shell.
        guard panel.creationID == nil else { return false }
        let fresh: Bool
        if case .fresh = panel.origin { fresh = true } else { fresh = false }
        guard fresh else { return false }
        guard let previous else { return true }
        return previous.lifecycle == "new" && previous.terminal == nil
    }

    private func retireOutageSignatures(panelID: UUID) {
        let fallback = "fallback:\(panelID.uuidString):"
        let unresolved = "unresolved:\(panelID.uuidString):"
        signatures = signatures.filter { key, _ in
            !key.hasPrefix(fallback) && !key.hasPrefix(unresolved)
        }
    }

    private func writeOnce(signature: String, fields: [(String, String?)]) {
        writeLine(fields, signature: signature)
    }

    /// Every line about a shard's panel or core names the shard, last, so
    /// existing field-adjacency greps keep matching. During an ingest it is that
    /// snapshot's shard; elsewhere it is the shard the line's panel is bound to.
    private func shardTagged(_ fields: [(String, String?)]) -> [(String, String?)] {
        if fields.contains(where: { $0.0 == "shard" }) { return fields }
        var session = ingestShard?.session
        if session == nil,
           let id = fields.first(where: { $0.0 == "panel_id" })?.1,
           let uuid = UUID(uuidString: id) {
            session = rows[uuid]?.shard
        }
        guard let session else { return fields }
        return fields + [("shard", session)]
    }

    private func writeLine(_ untagged: [(String, String?)], signature: String?) {
        let fields = shardTagged(untagged)
        if let signature {
            let rendered = fields.compactMap { pair -> String? in
                guard let value = pair.1 else { return nil }
                return "\(pair.0)=\(value)"
            }.joined(separator: " ")
            if signatures[signature] == rendered { return }
            signatures[signature] = rendered
        }
        var parts: [String] = []
        for (key, value) in fields {
            guard let value, Self.safeLogValue(value) else { continue }
            parts.append("\(key)=\(value)")
        }
        guard !parts.isEmpty else { return }
        appendLine(parts.joined(separator: " "))
    }

    private func appendLine(_ line: String) {
        let directory = logFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamped = "ts=\(Self.timestamp(now())) \(line)"
        let payload = Data((stamped + "\n").utf8)
        rotateIfNeeded(incoming: payload.count)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: payload)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: payload)
    }

    /// C11H-196: `hc-diagnostics.log.1` … `.log.<keptGenerations>`, newest
    /// first, so a burst cannot erase the evidence of a boot (one predecessor
    /// of 1 MB lost a reboot's lines within minutes). The count file is separate.
    static let keptGenerations = 5

    private func rotateIfNeeded(incoming: Int) {
        guard incoming > 0 else { return }
        let path = logFile.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return }
        let bytes = size.intValue
        guard bytes > 0, incoming > maxLogBytes || bytes > maxLogBytes - incoming else { return }
        let generation = { (n: Int) in self.logFile.appendingPathExtension(String(n)) }
        try? fm.removeItem(at: generation(Self.keptGenerations))
        for n in stride(from: Self.keptGenerations - 1, through: 1, by: -1) where fm.fileExists(atPath: generation(n).path) {
            try? fm.moveItem(at: generation(n), to: generation(n + 1))
        }
        try? fm.moveItem(at: logFile, to: generation(1))
    }

    private struct CounterDisk {
        var count: Int
        var terminals: [String]
        var holders: [String]
        var cores: [String: Int64]
        var live: [String: String]
        var persist: Bool
        var error: String?
    }

    /// A missing file is zero and may be created. A short read, or JSON that is
    /// not the counter object, is `unreadable` and is not replaced with zero.
    private func readCounterFile() -> CounterDisk {
        guard FileManager.default.fileExists(atPath: counterFile.path) else {
            return CounterDisk(count: 0, terminals: [], holders: [], cores: [:], live: [:], persist: true, error: nil)
        }
        guard let data = try? Data(contentsOf: counterFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = object["count"] as? Int,
              count >= 0,
              let terminals = object["terminals"] as? [String] else {
            return CounterDisk(count: 0, terminals: [], holders: [], cores: [:], live: [:], persist: false, error: "unreadable")
        }
        let holders = object["holders"] as? [String] ?? []
        var cores: [String: Int64] = [:]
        if let stored = object["cores"] as? [String: Any] {
            for (core, value) in stored {
                if let number = value as? NSNumber {
                    cores[core] = number.int64Value
                }
            }
        }
        var live: [String: String] = [:]
        if let stored = object["live"] as? [String: String] {
            live = stored.filter { !Self.isGenerationDiscriminator($0.value) }
        }
        return CounterDisk(count: count, terminals: terminals, holders: holders, cores: cores, live: live, persist: true, error: nil)
    }

    /// Pull a higher count and any keys another process stored. Never decreases.
    private func adoptDisk() {
        let disk = readCounterFile()
        if disk.error != nil {
            persistEnabled = false
            countError = disk.error
            return
        }
        if disk.count > holderLostCountStorage {
            holderLostCountStorage = disk.count
        }
        seenTerminals.formUnion(disk.terminals)
        seenHolders.formUnion(disk.holders)
        for (core, milliseconds) in disk.cores {
            let current = lastIncidentMilliseconds[core] ?? milliseconds
            lastIncidentMilliseconds[core] = max(current, milliseconds)
        }
        for (key, value) in disk.live where liveDiscriminators[key] == nil {
            liveDiscriminators[key] = value
        }
    }

    private func writeCounterFile() {
        guard persistEnabled, holderLostCountStorage >= loadedCount else { return }
        let directory = counterFile.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temp = directory.appendingPathComponent(".holder-lost.\(UUID().uuidString).tmp")
            var cores: [String: Int] = [:]
            for (core, milliseconds) in lastIncidentMilliseconds where milliseconds >= 0 && milliseconds <= Int64(Int.max) {
                cores[core] = Int(milliseconds)
            }
            let object: [String: Any] = [
                "count": holderLostCountStorage,
                "terminals": seenTerminals.sorted(),
                "holders": seenHolders.sorted(),
                "cores": cores,
                "live": liveDiscriminators,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if FileManager.default.fileExists(atPath: counterFile.path) {
                _ = try FileManager.default.replaceItemAt(counterFile, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: counterFile)
            }
            loadedCount = holderLostCountStorage
            if data.count > 1_048_576 {
                writeOnce(
                    signature: "counter_size",
                    fields: [
                        ("event", "counter_size"),
                        ("bytes", String(data.count)),
                    ]
                )
            }
        } catch {
            return
        }
    }

    /// One lock file beside the counter. Same-process calls nest; other c11
    /// processes wait. The in-process `lock` is always taken first.
    private func withCounterLock<T>(_ body: () -> T) -> T {
        let directory = counterFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("holder-lost.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 {
            _ = flock(fd, LOCK_EX)
        }
        let value = body()
        if fd >= 0 {
            _ = flock(fd, LOCK_UN)
            _ = Darwin.close(fd)
        }
        return value
    }

    private static func isCoreUnreachable(_ diagnostics: HCDiagnostics) -> Bool {
        if case .coreUnreachable = diagnostics.unavailableReason { return true }
        if case .pending(.coreUnreachable) = diagnostics.inventory.readiness { return true }
        return false
    }

    /// holder_lost and any finished record are ends. A running record is not.
    private static func isAuthoritativeEnd(_ record: HCTerminalRecord?) -> Bool {
        if let endReason = record?.endReason, HCDiagnosticTokens.reason(endReason) == "holder_lost" {
            return true
        }
        return record?.state == .finished
    }

    private static func pinToken(_ raw: String) -> String? {
        guard raw.range(of: #"^[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }

    /// A remote address is one `<machine>/<local>`, such as `studio/t2x`; the
    /// local id's rule is `HCLocalTerminalAddress`.
    private static func terminalToken(_ raw: String) -> String? {
        if isLocalTerminalID(raw) { return raw }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let machine = String(parts[0])
        let local = String(parts[1])
        guard machine.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil else { return nil }
        guard isLocalTerminalID(local) else { return nil }
        return raw
    }

    private static func isLocalTerminalID(_ raw: String) -> Bool { HCLocalTerminalAddress.isValid(raw) }

    private static func ttyToken(_ raw: String) -> String? {
        guard raw.range(of: #"^/dev/tty[A-Za-z0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return raw
    }

    private static func isGenerationDiscriminator(_ raw: String) -> Bool {
        raw.range(of: #"^g[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func discriminatorToken(_ raw: String) -> String? {
        if raw.range(of: #"^p[0-9]+:[0-9]+$"#, options: .regularExpression) != nil { return raw }
        if raw.range(of: #"^hcpid:[0-9]+$"#, options: .regularExpression) != nil { return raw }
        if raw.range(of: #"^g[0-9]+$"#, options: .regularExpression) != nil { return raw }
        if raw.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil {
            return raw
        }
        return nil
    }

    private static func holderToken(_ raw: String) -> String? {
        discriminatorToken(raw) ?? coreToken(raw)
    }

    private static func coreToken(_ raw: String) -> String? {
        if let direct = HCDiagnosticTokens.token(raw) { return direct }
        if raw.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil {
            return raw
        }
        if raw.range(of: #"^[A-Fa-f0-9]{8,64}$"#, options: .regularExpression) != nil {
            return raw
        }
        return nil
    }

    /// Tokens 2B named for hello, inventory, and one fired wire fault per kind.
    private static func transportToken(_ raw: String) -> String? {
        switch raw {
        case "hc_hello_start", "hc_hello_complete", "hc_hello_deadline", "hc_hello_failed",
             "hc_inventory_resnapshot_start", "hc_inventory_resnapshot_complete",
             "hc_inventory_gap", "hc_inventory_missed", "hc_inventory_malformed", "hc_inventory_timeout",
             "hc_wire_fault_hello_trickle", "hc_wire_fault_drop_events", "hc_wire_fault_delay_reply",
             "hc_wire_fault_fail_method", "hc_wire_fault_drop_reply", "hc_wire_fault_sever_bytes",
             "hc_wire_fault_sever_timer", "hc_wire_fault_throttle":
            return raw
        default:
            return nil
        }
    }

    private static func ancestryToken(_ raw: String) -> String? {
        switch raw {
        case "owned", "not_owned", "pending": return raw
        default: return nil
        }
    }

    private static func recoveryToken(_ raw: String) -> String? {
        switch raw {
        case "recovered", "refused", "recovery_required": return raw
        default: return nil
        }
    }

    private static func lifecycleToken(_ raw: String) -> String? {
        switch raw {
        case "new", "live", "ended", "unresolved", "fallback": return raw
        default: return nil
        }
    }

    /// An hc session name: `c11`, `c11-s3`, `c11-<tag>-s3`.
    private static func shardSessionToken(_ raw: String) -> Bool {
        raw.range(of: #"^c11[A-Za-z0-9._-]{0,60}$"#, options: .regularExpression) != nil
    }

    private static func safeLogValue(_ raw: String) -> Bool {
        guard !raw.isEmpty, !raw.contains(" "), !raw.contains("\n"), !raw.contains("=") else { return false }
        if HCDiagnosticTokens.token(raw) != nil || pinToken(raw) != nil || terminalToken(raw) != nil || ttyToken(raw) != nil {
            return true
        }
        if raw.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil { return true }
        if coreToken(raw) != nil { return true }
        if shardSessionToken(raw) { return true }
        if raw == "headless_send_refused" || headlessSendStatuses.contains(raw) { return true }
        if raw.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// UTC, millisecond precision. The Pathfinder log uses this shape.
    private static func timestamp(_ date: Date) -> String {
        var milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        if milliseconds < 0 { milliseconds = 0 }
        let fraction = Int(milliseconds % 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(milliseconds / 1000))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            fraction
        )
    }
}

extension TerminalController {
    /// Off-main. Reads the lock-guarded recorder. No AppKit and no main hop.
    nonisolated func v2HCDiagnostics() -> V2CallResult {
        var response = HCDiagnosticRecorder.shared.diagnosticsResponse(appInfo: Bundle.main.infoDictionary ?? [:])
        response.merge(HCAbandonedDiagnostics.shared.fields()) { current, _ in current }
        return .ok(response)
    }
}

/// C11H-352: `hc.diagnostics`' abandoned-session fields. The scan reads a few
/// state files and the process table, on the caller's socket thread, at most
/// once per `ttl`; never on main and never on an input or render path.
final class HCAbandonedDiagnostics: @unchecked Sendable {
    static let shared = HCAbandonedDiagnostics()
    static let ttl: TimeInterval = 30

    private let lock = NSLock()
    private var cached: (at: TimeInterval, fields: [String: Any])?

    func fields(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any] {
        // A test process never reads the machine it runs on.
        guard !QALaunchPolicy.currentProcessIsHostedTest else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        if let cached, now - cached.at < Self.ttl { return cached.fields }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tag = SocketControlSettings.hcLaunchTag()
        let own = (try? HCLaunchPolicy.configuration(home: home, tag: tag, inherited: [:]).session) ?? HCShardID.base(tag: tag)
        let context = HCAbandonedSessions.Context.local(home: home, ownSessions: [own, HCShardID.base(tag: tag)],
                                                       environment: ProcessInfo.processInfo.environment)
        let fields = HCAbandonedSessions.diagnostics(HCAbandonedSessions.scan(context, host: HCKernelAbandonedHost()))
        cached = (now, fields)
        return fields
    }
}
