import Foundation
import Darwin
import OSLog

/// Kernel facts are local evidence, never hc wire fields. No remote pid is read.
struct HCLocalProcess: Equatable, Sendable {
    let identity: HCProcessIdentity
    let parentPID: Int32
    /// Effective uid. Every process on the admission walk must match ours.
    let uid: UInt32
    /// Real uid. Read only for the matched terminal root (see `admitsAsTerminalRoot`).
    let realUID: UInt32

    init(identity: HCProcessIdentity, parentPID: Int32, uid: UInt32, realUID: UInt32? = nil) {
        self.identity = identity
        self.parentPID = parentPID
        self.uid = uid
        self.realUID = realUID ?? uid
    }

    /// A terminal opened before C11H-232 roots at `/usr/bin/login -flp <user> ...`
    /// (newer ones root at the login shell itself). login is setuid root, so the record's own process has euid 0 while its
    /// real uid stays the user who started it. Only that process, the one
    /// hc recorded for a terminal, may be root-effective, and only when its
    /// real uid is ours. Every other process on the walk keeps the effective check.
    func admitsAsTerminalRoot(uid expected: UInt32) -> Bool {
        uid == expected || (uid == 0 && realUID == expected)
    }

    static func read(_ pid: Int32) -> HCLocalProcess? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            // PROC_PIDTBSDINFO refuses another effective uid's process, which
            // includes hc's setuid-root login terminal root. sysctl still
            // reads it, with the same start time (both come from p_start).
            return readKernelProcess(pid)
        }
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        return HCLocalProcess(
            identity: HCProcessIdentity(pid: pid, startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec),
            parentPID: Int32(info.pbi_ppid), uid: info.pbi_uid, realUID: info.pbi_ruid
        )
    }

    /// The same facts from `sysctl(KERN_PROC_PID)`, readable for any process.
    static func readKernelProcess(_ pid: Int32) -> HCLocalProcess? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid,
              info.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        let start = info.kp_proc.p_starttime
        return HCLocalProcess(
            identity: HCProcessIdentity(pid: pid, startTimeMicroseconds: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)),
            parentPID: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid, realUID: info.kp_eproc.e_pcred.p_ruid
        )
    }

    /// The executable of one process on the caller's own chain, read only to
    /// explain a refusal (never on the admission path itself).
    static func executable(_ pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 { return String(cString: path) }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}

/// Why a caller was refused or held, about the caller's OWN process chain only:
/// the step where its ancestry walk stopped and which check failed. It never
/// names another panel, terminal, address or pid outside that chain.
enum HCAdmissionStop: Equatable, Sendable {
    case backendNotInstalled
    case inventoryTimeout
    case callerUnknown
    case inventoryNotReady
    case coreUnknown
    case birthRefreshPending
    case terminalStarting
    case callerChanged(pid: Int32)
    /// One step of the walk; `depth` 0 is the caller itself.
    case walk(Step, pid: Int32, depth: Int, exe: String?)

    enum Step: Equatable, Sendable {
        case gone
        case effectiveUID(euid: UInt32, want: UInt32)
        case terminalRootUID(euid: UInt32, ruid: UInt32, want: UInt32)
        case startedAfterChild
        case rootIdentityChanged
        case changedDuringWalk
        case noTerminalRoot
        case depthLimit
    }

    /// Diagnostic tokens, like the error code and the gate log line; not prose.
    var text: String {
        switch self {
        case .backendNotInstalled: return "stop=backend_not_installed"
        case .inventoryTimeout: return "stop=inventory_timeout budget_ms=50"
        case .callerUnknown: return "stop=caller_identity_unknown"
        case .inventoryNotReady: return "stop=inventory_not_ready"
        case .coreUnknown: return "stop=core_identity_unknown"
        case .birthRefreshPending: return "stop=birth_refresh_pending"
        case .terminalStarting: return "stop=own_terminal_starting"
        case .callerChanged(let pid): return "stop=caller_changed pid=\(pid)"
        case .walk(let step, let pid, let depth, let exe):
            let at = "pid=\(pid) exe=\"\(exe ?? "?")\" depth=\(depth)"
            switch step {
            case .gone: return "stop=process_gone \(at)"
            case .effectiveUID(let euid, let want): return "stop=euid \(at) euid=\(euid) want=\(want)"
            case .terminalRootUID(let euid, let ruid, let want):
                return "stop=terminal_root_uid \(at) euid=\(euid) ruid=\(ruid) want=\(want)"
            case .startedAfterChild: return "stop=started_after_child \(at)"
            case .rootIdentityChanged: return "stop=terminal_root_changed \(at)"
            case .changedDuringWalk: return "stop=changed_during_walk \(at)"
            case .noTerminalRoot: return "stop=no_terminal_root \(at)"
            case .depthLimit: return "stop=depth_limit \(at)"
            }
        }
    }
}

enum HCAdmissionDecision: String, Sendable {
    case admitted
    case pending = "hc_inventory_pending"
    case notOwned = "hc_caller_not_owned"
}

/// Facts proven by the admission walk, never supplied by socket parameters.
struct HCVerifiedTerminal: Equatable, Sendable {
    let key: HCTerminalKey
    let rootIdentity: HCProcessIdentity
    let peerIdentity: HCProcessIdentity
}

struct HCAdmissionCheck: Sendable {
    let decision: HCAdmissionDecision
    let inventory: HCInventorySnapshot?
    /// Set on every refusal or hold the engine decides; nil when admitted.
    var stop: HCAdmissionStop? = nil
    /// SH3: the shard a hold waits on (`s<N>`), named in the reason.
    var shard: HCShardID? = nil
    var verifiedTerminal: HCVerifiedTerminal? = nil
    static let pending = HCAdmissionCheck(decision: .pending, inventory: nil)
}

/// This restores same-user functionality, NOT a security boundary: hc permits
/// any process of that user to drive terminals. Never authorize from panel env,
/// a UI surface, remote pids, or a coalesced UI observation.
final class HCProcessAdmission: @unchecked Sendable {
    static let shared = HCProcessAdmission()
    private let lock = NSLock()
    private var engine: HCAdmissionEngine?
    private var identities: [UUID: HCPanelIdentity] = [:]

    /// Called once by backend composition, before accepting hc terminal reports.
    func install(inventory: any HCInventorySource) {
        lock.lock()
        engine = HCAdmissionEngine(inventory: inventory)
        lock.unlock()
        HCAgentRecoveryController.shared.install(inventory: inventory)
    }

    /// Retain unresolved identities too; nil explicitly registers an exec panel.
    func setPanelIdentity(_ identity: HCPanelIdentity?, panelID: UUID) {
        lock.lock()
        identities[panelID] = identity
        lock.unlock()
        HCAgentRecoveryController.shared.setPanelIdentity(identity, panelID: panelID)
    }

    func panelIdentity(_ panelID: UUID) -> HCPanelIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identities[panelID]
    }

    /// The existing line server owns a worker thread per connection. Only that
    /// worker bridges to async inventory, for at most 50 ms; the accept loop,
    /// main, inventory reducer and output lanes never wait. Slow inventory gets
    /// an explicit pre-dispatch pending response within short hook budgets.
    func checkOnSocketWorker(peer: HCProcessIdentity?, requiresOwnership: Bool) -> HCAdmissionCheck {
        precondition(!Thread.isMainThread)
        lock.lock()
        let engine = engine
        lock.unlock()
        guard let engine else {
            return requiresOwnership ? HCAdmissionCheck(decision: .pending, inventory: nil, stop: .backendNotInstalled)
                : HCAdmissionCheck(decision: .admitted, inventory: nil)
        }
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            let result = await engine.check(peer: peer, requiresOwnership: requiresOwnership)
            reply.set(result)
            done.signal()
        }
        guard done.wait(timeout: .now() + .milliseconds(50)) == .success else {
            task.cancel()
            return requiresOwnership ? HCAdmissionCheck(decision: .pending, inventory: nil, stop: .inventoryTimeout)
                : HCAdmissionCheck(decision: .admitted, inventory: nil)
        }
        return reply.get()
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var value = HCAdmissionCheck.pending
        func set(_ value: HCAdmissionCheck) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> HCAdmissionCheck { lock.lock(); defer { lock.unlock() }; return value }
    }

    enum CaptureLiveness: Equatable { case live, ended, pending, unmanaged }
    static func captureLiveness(identity: HCPanelIdentity?, panelID: UUID,
                                inventory: HCInventorySnapshot?) -> CaptureLiveness {
        guard identity?.persistence != .nonpersistent else { return .unmanaged }
        guard let inventory else { return identity == nil ? .unmanaged : .pending }
        let key = identity?.key ?? inventory.panelBindings[panelID]
        // An explicit persistent identity remains persistent while unresolved.
        guard identity != nil || key != nil else { return .unmanaged }
        // Amendment 1: the readiness of the shard that holds this key, so
        // another shard's outage never holds a healthy panel's capture.
        guard let key, inventory.isReady(for: key), let record = inventory.records[key] else { return .pending }
        return record.state == .finished ? .ended : record.state == .running && record.pid != nil ? .live : .pending
    }
}

/// One birth attempt per kernel process incarnation. Retry requests reuse its
/// refresh for two seconds; fresh events are read on every decision. No negative
/// decision survives a new inventory generation, missing event, or reconnect.
actor HCAdmissionEngine {
    private let inventory: any HCInventorySource
    private let process: @Sendable (Int32) -> HCLocalProcess?
    private let now: @Sendable () -> TimeInterval
    private let executable: @Sendable (Int32) -> String?
    private let uid: UInt32
    private struct Attempt {
        let peer: HCProcessIdentity
        let generation: UInt64
        let started: TimeInterval
        let token: UUID
        var refreshed: HCRevision?
    }
    private var attempts: [Int32: Attempt] = [:]
    private var roots: [HCTerminalKey: HCProcessIdentity] = [:]
    /// SH3 (Amendment 1): one birth refresh per caller and set of shard
    /// connection generations, recording each shard's refreshed revision.
    private struct ShardAttempt {
        let peer: HCProcessIdentity
        let generations: [HCShardID: UInt64]
        let started: TimeInterval
        let token: UUID
        var refreshed: [HCShardID: HCRevision] = [:]
        var completed = false
    }
    private var shardAttempts: [Int32: ShardAttempt] = [:]

    init(inventory: any HCInventorySource,
         process: @escaping @Sendable (Int32) -> HCLocalProcess? = { HCLocalProcess.read($0) },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         executable: @escaping @Sendable (Int32) -> String? = { HCLocalProcess.executable($0) },
         uid: UInt32 = getuid()) {
        self.inventory = inventory
        self.process = process
        self.now = now
        self.executable = executable
        self.uid = uid
    }

    func check(peer: HCProcessIdentity?, requiresOwnership: Bool = true) async -> HCAdmissionCheck {
        let snapshot = await inventory.snapshot()
        guard !Task.isCancelled else { return .pending }
        if !requiresOwnership {
            // Permissive socket policies still carry a proof when available.
            // Failure to prove membership never changes their admission rule;
            // commands needing an exact caller can require the separate fact.
            let verified = peer.flatMap { captureVerifiedTerminal(peer: $0, snapshot: snapshot) }
            return HCAdmissionCheck(decision: .admitted, inventory: snapshot, verifiedTerminal: verified)
        }
        guard let peer else { return HCAdmissionCheck(decision: .pending, inventory: snapshot, stop: .callerUnknown) }
        // The shard pool's merged view (Amendment 1): decide per shard.
        if !snapshot.shardReadiness.isEmpty { return checkShards(peer: peer, snapshot: snapshot) }
        let peerIsCurrent = process(peer.pid)?.identity == peer
        let ready: Bool
        if case .ready(let revision) = snapshot.readiness { ready = revision == snapshot.revision }
        else { ready = false }
        var walkStop: HCAdmissionStop = .callerChanged(pid: peer.pid)
        var verifiedTerminal: HCVerifiedTerminal?
        if ready, peerIsCurrent, let coreID = snapshot.buildIdentity?.coreID {
            guard let stop = walk(peer: peer, snapshot: snapshot, ownCoreIDs: [coreID], verifiedTerminal: &verifiedTerminal) else {
                attempts.removeValue(forKey: peer.pid)
                return HCAdmissionCheck(decision: .admitted, inventory: snapshot, verifiedTerminal: verifiedTerminal)
            }
            walkStop = stop
        }
        let time = now()
        let previous = attempts[peer.pid]
        // refresh() itself revokes readiness. The source owns gap recovery:
        // pending never authorizes absence, and ready again means an authoritative
        // snapshot after recovery. Do not recursively refresh our own pending
        // transition, or turn an overlapping check into a second birth refresh.
        let refreshWasUnavailable = previous.map { time - $0.started >= 2 && $0.refreshed == nil } ?? false
        if previous?.peer != peer || previous?.generation != snapshot.revision.connectionGeneration || refreshWasUnavailable {
            // A bounded set of in-flight birth checks. Eviction causes pending,
            // never a false denial. A normal 200-panel burst fits comfortably.
            attempts = attempts.filter { time - $0.value.started < 10 }
            if attempts.count >= 1024, let oldest = attempts.min(by: { $0.value.started < $1.value.started })?.key {
                attempts.removeValue(forKey: oldest)
            }
            let token = UUID()
            attempts[peer.pid] = Attempt(peer: peer, generation: snapshot.revision.connectionGeneration,
                                         started: time, token: token, refreshed: nil)
            Task {
                let fresh = await inventory.refresh()
                self.didRefresh(pid: peer.pid, token: token, snapshot: fresh)
            }
        }
        guard ready else { return HCAdmissionCheck(decision: .pending, inventory: snapshot, stop: .inventoryNotReady) }
        guard snapshot.buildIdentity != nil else {
            return HCAdmissionCheck(decision: .pending, inventory: snapshot, stop: .coreUnknown)
        }
        guard let attempt = attempts[peer.pid], let refreshed = attempt.refreshed,
              refreshed.connectionGeneration == snapshot.revision.connectionGeneration,
              refreshed.sequence <= snapshot.revision.sequence else {
            return HCAdmissionCheck(decision: .pending, inventory: snapshot, stop: .birthRefreshPending)
        }
        // An own terminal still waiting for its pid is not authoritative absence.
        if snapshot.records.values.contains(where: {
            $0.key.owningCoreID == snapshot.buildIdentity?.coreID && $0.machineAvailability == .local &&
            ($0.state == .starting || ($0.state == .running && $0.pid == nil))
        }) { return HCAdmissionCheck(decision: .pending, inventory: snapshot, stop: .terminalStarting) }
        return HCAdmissionCheck(decision: .notOwned, inventory: snapshot, stop: walkStop)
    }

    private func didRefresh(pid: Int32, token: UUID, snapshot: HCInventorySnapshot) {
        guard attempts[pid]?.token == token,
              case .ready(let revision) = snapshot.readiness, revision == snapshot.revision else { return }
        attempts[pid]?.refreshed = revision
    }

    /// nil when the caller descends from an own live terminal root; otherwise
    /// the step of the caller's own chain where the walk stopped.
    /// SH3 (Amendment 1, "Merged inventory and admission"): the frozen birth
    /// rule applied across shards.
    /// 1. A live terminal of a ready shard's own core in the caller's chain admits.
    /// 2. On a miss, one birth refresh on every started shard, ready or not, per
    ///    caller and shard connection generation; pending until each completed
    ///    with a ready revision of that generation, no later than the current one.
    /// 3. Pending while any started shard has an own local terminal starting or PID-less.
    /// 4. Refused only when every started shard is ready, refreshed, and holds no owner.
    private func checkShards(peer: HCProcessIdentity, snapshot: HCInventorySnapshot) -> HCAdmissionCheck {
        let started = snapshot.shardReadiness.keys.sorted()
        func readyRevision(_ shard: HCShardID) -> HCRevision? {
            guard case .ready(let revision) = snapshot.shardReadiness[shard],
                  revision == snapshot.shardRevisions[shard] else { return nil }
            return revision
        }
        let readyCores = Set(started.compactMap { shard in readyRevision(shard).flatMap { _ in snapshot.shardCoreIDs[shard] } })
        let peerIsCurrent = process(peer.pid)?.identity == peer
        var walkStop: HCAdmissionStop = .callerChanged(pid: peer.pid)
        var verifiedTerminal: HCVerifiedTerminal?
        if peerIsCurrent, !readyCores.isEmpty {
            guard let stop = walk(peer: peer, snapshot: snapshot, ownCoreIDs: readyCores, verifiedTerminal: &verifiedTerminal) else {
                shardAttempts.removeValue(forKey: peer.pid)
                return HCAdmissionCheck(decision: .admitted, inventory: snapshot, verifiedTerminal: verifiedTerminal)
            }
            walkStop = stop
        }
        let time = now()
        let generations = Dictionary(uniqueKeysWithValues: started.compactMap { shard in
            snapshot.shardRevisions[shard].map { (shard, $0.connectionGeneration) }
        })
        let previous = shardAttempts[peer.pid]
        let refreshWasUnavailable = previous.map { time - $0.started >= 2 && !$0.completed } ?? false
        if previous?.peer != peer || previous?.generations != generations || refreshWasUnavailable {
            // The same bounded table as the single-core path: eviction is pending, never a denial.
            shardAttempts = shardAttempts.filter { time - $0.value.started < 10 }
            if shardAttempts.count >= 1024, let oldest = shardAttempts.min(by: { $0.value.started < $1.value.started })?.key {
                shardAttempts.removeValue(forKey: oldest)
            }
            let token = UUID()
            shardAttempts[peer.pid] = ShardAttempt(peer: peer, generations: generations, started: time, token: token)
            Task {
                // The pool refreshes every started shard, ready or not.
                let fresh = await inventory.refresh()
                self.didRefreshShards(pid: peer.pid, token: token, snapshot: fresh)
            }
        }
        func hold(_ stop: HCAdmissionStop, _ shard: HCShardID?) -> HCAdmissionCheck {
            var check = HCAdmissionCheck(decision: .pending, inventory: snapshot, stop: stop)
            check.shard = shard
            return check
        }
        if let unready = started.first(where: { readyRevision($0) == nil }) { return hold(.inventoryNotReady, unready) }
        let attempt = shardAttempts[peer.pid]
        if let unrefreshed = started.first(where: { shard in
            guard let done = attempt?.refreshed[shard], let current = snapshot.shardRevisions[shard] else { return true }
            return done.connectionGeneration != current.connectionGeneration || done.sequence > current.sequence
        }) { return hold(.birthRefreshPending, unrefreshed) }
        let shardOfCore = Dictionary(snapshot.shardCoreIDs.map { ($0.value, $0.key) }) { first, _ in first }
        if let waiting = snapshot.records.values.first(where: {
            shardOfCore[$0.key.owningCoreID] != nil && $0.machineAvailability == .local &&
            ($0.state == .starting || ($0.state == .running && $0.pid == nil))
        }) { return hold(.terminalStarting, shardOfCore[waiting.key.owningCoreID]) }
        return HCAdmissionCheck(decision: .notOwned, inventory: snapshot, stop: walkStop)
    }

    private func didRefreshShards(pid: Int32, token: UUID, snapshot: HCInventorySnapshot) {
        guard shardAttempts[pid]?.token == token else { return }
        for (shard, readiness) in snapshot.shardReadiness {
            if case .ready(let revision) = readiness, revision == snapshot.shardRevisions[shard] {
                shardAttempts[pid]?.refreshed[shard] = revision
            }
        }
        shardAttempts[pid]?.completed = true
    }

    private func captureVerifiedTerminal(peer: HCProcessIdentity, snapshot: HCInventorySnapshot) -> HCVerifiedTerminal? {
        guard process(peer.pid)?.identity == peer else { return nil }
        let cores: Set<String>
        if snapshot.isMerged {
            cores = Set(snapshot.shardCoreIDs.compactMap { shard, core in
                guard case .ready(let revision) = snapshot.shardReadiness[shard],
                      revision == snapshot.shardRevisions[shard] else { return nil }
                return core
            })
        } else {
            guard case .ready(let revision) = snapshot.readiness, revision == snapshot.revision,
                  let core = snapshot.buildIdentity?.coreID else { return nil }
            cores = [core]
        }
        guard !cores.isEmpty else { return nil }
        var verified: HCVerifiedTerminal?
        guard walk(peer: peer, snapshot: snapshot, ownCoreIDs: cores, verifiedTerminal: &verified) == nil else { return nil }
        return verified
    }

    private func walk(peer: HCProcessIdentity, snapshot: HCInventorySnapshot, ownCoreIDs: Set<String>,
                      verifiedTerminal: inout HCVerifiedTerminal?) -> HCAdmissionStop? {
        roots = roots.filter { key, identity in
            guard let record = snapshot.records[key] else { return false }
            return record.state == .running && record.pid == identity.pid
        }
        // Walk the caller once, then validate only a matching root. Reading
        // every terminal's kernel facts per telemetry request scales poorly.
        var candidates: [Int32: HCTerminalRecord] = [:]
        for record in snapshot.records.values where ownCoreIDs.contains(record.key.owningCoreID) &&
            record.machineAvailability == .local && record.state == .running {
            if let pid = record.pid { candidates[pid] = record }
        }
        var current = peer.pid
        var childStart = peer.startTimeMicroseconds
        for depth in 0..<128 {
            func stop(_ step: HCAdmissionStop.Step) -> HCAdmissionStop {
                .walk(step, pid: current, depth: depth, exe: executable(current))
            }
            guard let facts = process(current) else { return stop(.gone) }
            guard facts.identity.startTimeMicroseconds <= childStart else { return stop(.startedAfterChild) }
            let record = candidates[current]
            // Root-effective is accepted only for the recorded terminal root.
            if let record {
                guard facts.admitsAsTerminalRoot(uid: uid) else {
                    return stop(.terminalRootUID(euid: facts.uid, ruid: facts.realUID, want: uid))
                }
                let root = record.localProcessIdentity ?? roots[record.key] ?? facts.identity
                guard root == facts.identity else { return stop(.rootIdentityChanged) }
                roots[record.key] = root
                // Recheck both ends after the walk; a cached pid is not identity.
                guard process(peer.pid)?.identity == peer, process(current)?.identity == root else {
                    return stop(.changedDuringWalk)
                }
                verifiedTerminal = HCVerifiedTerminal(key: record.key, rootIdentity: root, peerIdentity: peer)
                return nil
            }
            guard facts.uid == uid else { return stop(.effectiveUID(euid: facts.uid, want: uid)) }
            guard facts.parentPID > 1, facts.parentPID != current else { return stop(.noTerminalRoot) }
            childStart = facts.identity.startTimeMicroseconds
            current = facts.parentPID
        }
        return .walk(.depthLimit, pid: current, depth: 128, exe: executable(current))
    }
}


extension HCAdmissionCheck {
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.admission")

    func rejectionResponse(command: String, pid: Int32?) -> String? {
        guard decision != .admitted else { return nil }
        let retryable = decision == .pending
        let message = retryable
            ? String(localized: "hc.admission.pending", defaultValue: "Terminal inventory is not ready. Retry this request.")
            : String(localized: "hc.admission.notOwned", defaultValue: "Caller is not descended from a live terminal in this c11 session.")
        // The caller's own chain only: the same tokens as the response, never another panel's data.
        let why = (stop?.text ?? "stop=unknown") + (retryable ? (shard.map { " shard=s\($0.index)" } ?? "") : "")
        // No command, environment, prompt or terminal contents enter this log.
        Self.logger.info("gate \(retryable ? "pending" : "refused", privacy: .public) pid=\(pid ?? -1) ancestry=\(retryable ? "pending" : "no_live_local_root", privacy: .public) reason=\(decision.rawValue, privacy: .public) \(why, privacy: .public) generation=\(inventory?.revision.connectionGeneration ?? 0) seq=\(inventory?.revision.sequence ?? 0) trust=same_user_not_security_boundary")
        if let data = command.data(using: .utf8),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           request["method"] is String {
            let response: [String: Any] = ["id": request["id"] ?? NSNull(), "ok": false,
                "error": ["code": decision.rawValue, "message": "\(message) (\(why))",
                          "data": ["retryable": retryable, "pre_dispatch": true, "retry_after_ms": 25, "reason": why]]]
            if let encoded = try? JSONSerialization.data(withJSONObject: response) {
                return String(decoding: encoded, as: UTF8.self)
            }
        }
        return "ERROR: \(decision.rawValue): \(message) (\(why))"
    }
}
