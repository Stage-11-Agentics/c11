import Darwin
import Foundation

/// Positive local facts only. Applying one never changes terminal lifecycle,
/// attention, delegation or saved status. The consumer rechecks its panel/key
/// binding on main, then registers the tty with its existing observers.
struct HCAgentRecoveryObservation: Equatable, Sendable {
    let panelID: UUID
    let key: HCTerminalKey
    let rootProcessIdentity: HCProcessIdentity
    let ttyName: String
    let revision: HCRevision
    /// The connection generation of the key's own shard (C11H-77). On one
    /// session it is that session's; on the pool's merged view it moves only
    /// when this terminal's shard reconnects, never when another shard does.
    var connectionGeneration: UInt64

    init(panelID: UUID, key: HCTerminalKey, rootProcessIdentity: HCProcessIdentity, ttyName: String,
         revision: HCRevision, connectionGeneration: UInt64? = nil) {
        self.panelID = panelID
        self.key = key
        self.rootProcessIdentity = rootProcessIdentity
        self.ttyName = ttyName
        self.revision = revision
        self.connectionGeneration = connectionGeneration ?? revision.connectionGeneration
    }
}

struct HCAgentRecoveryProcessFacts: Equatable, Sendable {
    let identity: HCProcessIdentity
    let controllingTTYDevice: UInt32?
}

enum HCAgentRecoveryKernel {
    static func readProcess(_ pid: Int32) -> HCAgentRecoveryProcessFacts? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(),
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return HCAgentRecoveryProcessFacts(
            identity: HCProcessIdentity(pid: pid,
                startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec),
            controllingTTYDevice: info.e_tdev == UInt32.max ? nil : info.e_tdev
        )
    }

    static func ttyName(for device: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard devname_r(dev_t(bitPattern: device), mode_t(S_IFCHR), &buffer, Int32(buffer.count)) != nil else {
            return nil
        }
        let name = String(cString: buffer)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        var info = stat()
        guard stat("/dev/\(name)", &info) == 0, info.st_mode & S_IFMT == S_IFCHR,
              UInt32(bitPattern: info.st_rdev) == device else { return nil }
        return name
    }
}

/// Queue-confined reducer, separately executable with injected kernel reads.
/// A pin survives inventory gaps, lost claims, and removals: observing the same
/// numeric PID again must never adopt another incarnation under that key.
struct HCAgentRecoveryState {
    typealias ProcessReader = @Sendable (Int32) -> HCAgentRecoveryProcessFacts?
    typealias TTYName = @Sendable (UInt32) -> String?

    private struct ResolvedFacts {
        let process: HCProcessIdentity
        let ttyName: String
        let connectionGeneration: UInt64
    }

    private let readProcess: ProcessReader
    private let ttyName: TTYName
    private var latest: HCInventorySnapshot?
    private var claims: [UUID: HCTerminalKey] = [:]
    private var pins: [HCTerminalKey: HCProcessIdentity] = [:]
    private var resolved: [HCTerminalKey: ResolvedFacts] = [:]
    private(set) var observations: [HCAgentRecoveryObservation] = []
    private(set) var needsRetry = false

    init(readProcess: @escaping ProcessReader = HCAgentRecoveryKernel.readProcess,
         ttyName: @escaping TTYName = HCAgentRecoveryKernel.ttyName) {
        self.readProcess = readProcess
        self.ttyName = ttyName
    }

    @discardableResult
    mutating func accept(_ snapshot: HCInventorySnapshot) -> Bool {
        if let revision = latest?.revision {
            guard snapshot.revision.connectionGeneration > revision.connectionGeneration
                || (snapshot.revision.connectionGeneration == revision.connectionGeneration
                    && snapshot.revision.sequence >= revision.sequence) else { return false }
        }
        latest = snapshot
        recover()
        return true
    }

    /// Includes restored/Recovered panels whose identity is already known by
    /// the consumer, even if they were constructed after the initial snapshot.
    mutating func setClaims(_ claims: [UUID: HCTerminalKey]) {
        for (panelID, key) in claims where self.claims[panelID] != key {
            resolved.removeValue(forKey: key)
        }
        self.claims = claims
        recover()
    }

    mutating func recover() {
        observations = []
        needsRetry = false
        // Amendment 1: on the shard pool's merged view a terminal is judged by
        // its own shard (ready, owned by that shard's core, that shard's
        // connection generation), so one shard's outage leaves the others' observers.
        guard let snapshot = latest, snapshot.hasReadyPart,
              snapshot.isMerged || snapshot.buildIdentity != nil else {
            resolved.removeAll()
            return
        }
        resolved = resolved.filter { key, facts in
            guard let record = snapshot.records[key] else { return false }
            return record.state == .running && record.machineAvailability == .local
                && snapshot.ownsLocal(key) && snapshot.isReady(for: key) && record.pid == facts.process.pid
                && (record.localProcessIdentity == nil || record.localProcessIdentity == facts.process)
        }

        var bindings = snapshot.panelBindings
        for (panelID, key) in claims {
            if let bound = bindings[panelID], bound != key {
                bindings.removeValue(forKey: panelID)
            } else {
                bindings[panelID] = key
            }
        }
        // Several panels can refer to one key. Read that process at most once
        // per pass, including when a missing fact needs another attempt later.
        var attempted: Set<HCTerminalKey> = []
        for (panelID, key) in bindings {
            guard snapshot.ownsLocal(key), snapshot.isReady(for: key),
                  let record = snapshot.records[key], record.key == key,
                  record.machineAvailability == .local, record.state == .running,
                  let pid = record.pid, pid > 0 else { continue }
            if let expected = record.localProcessIdentity {
                guard expected.pid == pid, pins[key] == nil || pins[key] == expected else { continue }
                pins[key] = expected
            }
            guard pins[key] == nil || pins[key]?.pid == pid else { continue }

            if attempted.insert(key).inserted {
                if let facts = resolved[key], facts.connectionGeneration == snapshot.connectionGeneration(for: key),
                   facts.process.pid == pid, facts.process == pins[key] {
                    // Existing detectors own steady-state polling. Recovery
                    // performs no additional kernel reads once facts resolve.
                } else {
                    resolved.removeValue(forKey: key)
                    resolve(key: key, pid: pid, generation: snapshot.connectionGeneration(for: key))
                }
            }
            guard let facts = resolved[key], facts.process == pins[key], facts.process.pid == pid,
                  facts.connectionGeneration == snapshot.connectionGeneration(for: key) else { continue }
            observations.append(HCAgentRecoveryObservation(panelID: panelID, key: key,
                rootProcessIdentity: facts.process, ttyName: facts.ttyName, revision: snapshot.revision,
                connectionGeneration: facts.connectionGeneration))
        }
    }

    private mutating func resolve(key: HCTerminalKey, pid: Int32, generation: UInt64) {
        guard let before = readProcess(pid) else { needsRetry = true; return }
        guard before.identity.pid == pid, pins[key] == nil || pins[key] == before.identity else { return }
        pins[key] = before.identity
        guard let device = before.controllingTTYDevice, let name = ttyName(device), !name.isEmpty else {
            needsRetry = true
            return
        }
        guard let after = readProcess(pid) else { needsRetry = true; return }
        guard after.identity == before.identity else { return }
        guard after.controllingTTYDevice == device else { needsRetry = true; return }
        resolved[key] = ResolvedFacts(process: before.identity, ttyName: name, connectionGeneration: generation)
    }
}

/// Observes the one inventory off-main; retries only unresolved eligible local
/// facts, once a second for at most 30 attempts. A later inventory/claim update
/// can start another bounded attempt. There is no timer after resolution.
final class HCAgentRecovery: @unchecked Sendable {
    typealias ObserveInventory = @Sendable (DispatchQueue, @escaping @Sendable (HCInventorySnapshot) -> Void) -> HCObservation
    private let queue = DispatchQueue(label: "com.stage11.c11.agent-recovery", qos: .utility)
    private let observeInventory: ObserveInventory
    private let handler: @Sendable ([HCAgentRecoveryObservation]) -> Void
    private let retryInterval: TimeInterval
    private let maximumRetryAttempts: Int
    private var state: HCAgentRecoveryState
    private var subscription: HCObservation?
    private var subscriptionGeneration: UInt64 = 0
    private var retryTimer: DispatchSourceTimer?
    private var remainingRetries = 0

    // Only positive validation values cross queues. Main never waits for the
    // recovery queue or a kernel read; pending snapshots revoke them promptly.
    private let validationLock = NSLock()
    private var validObservations: [UUID: HCAgentRecoveryObservation] = [:]
    private var acceptsPublications = false

    convenience init(inventory: any HCInventorySource,
                     readProcess: @escaping HCAgentRecoveryState.ProcessReader = HCAgentRecoveryKernel.readProcess,
                     ttyName: @escaping HCAgentRecoveryState.TTYName = HCAgentRecoveryKernel.ttyName,
                     handler: @escaping @Sendable ([HCAgentRecoveryObservation]) -> Void) {
        self.init(observeInventory: { queue, callback in inventory.observe(on: queue, handler: callback) },
                  readProcess: readProcess, ttyName: ttyName, handler: handler)
    }

    init(observeInventory: @escaping ObserveInventory,
         readProcess: @escaping HCAgentRecoveryState.ProcessReader = HCAgentRecoveryKernel.readProcess,
         ttyName: @escaping HCAgentRecoveryState.TTYName = HCAgentRecoveryKernel.ttyName,
         retryInterval: TimeInterval = 1, maximumRetryAttempts: Int = 30,
         handler: @escaping @Sendable ([HCAgentRecoveryObservation]) -> Void) {
        self.observeInventory = observeInventory
        self.handler = handler
        self.retryInterval = max(0.001, retryInterval)
        self.maximumRetryAttempts = max(0, maximumRetryAttempts)
        state = HCAgentRecoveryState(readProcess: readProcess, ttyName: ttyName)
    }

    func start() {
        queue.async { [self] in
            guard subscription == nil else { return }
            validationLock.lock()
            acceptsPublications = true
            validationLock.unlock()
            subscriptionGeneration &+= 1
            let generation = subscriptionGeneration
            subscription = observeInventory(queue) { [weak self] snapshot in
                guard let self, self.subscriptionGeneration == generation else { return }
                self.invalidatePublishedFacts()
                guard self.state.accept(snapshot) else { self.publish(); return }
                self.remainingRetries = self.maximumRetryAttempts
                self.publish()
                self.updateTimer()
            }
            updateTimer()
        }
    }

    func stop() {
        validationLock.lock()
        acceptsPublications = false
        validObservations.removeAll()
        validationLock.unlock()
        queue.async { [self] in
            subscriptionGeneration &+= 1
            subscription?.cancel()
            subscription = nil
            retryTimer?.cancel()
            retryTimer = nil
            invalidatePublishedFacts()
        }
    }

    func setClaims(_ claims: [UUID: HCTerminalKey]) {
        queue.async { [self] in
            invalidatePublishedFacts()
            state.setClaims(claims)
            remainingRetries = maximumRetryAttempts
            guard subscription != nil else { return }
            publish()
            updateTimer()
        }
    }

    /// Call immediately before applying on main. An unrelated newer sequence
    /// can keep the same facts current; gaps, a new generation, a changed claim
    /// or root identity revoke them. The consumer still checks its live panel.
    func isCurrent(_ observation: HCAgentRecoveryObservation) -> Bool {
        validationLock.lock()
        defer { validationLock.unlock() }
        guard let current = validObservations[observation.panelID] else { return false }
        return current.key == observation.key && current.rootProcessIdentity == observation.rootProcessIdentity
            && current.ttyName == observation.ttyName
            && current.revision.connectionGeneration == observation.revision.connectionGeneration
            && current.revision.sequence >= observation.revision.sequence
    }

    private func publish() {
        validationLock.lock()
        guard acceptsPublications else { validationLock.unlock(); return }
        validObservations = Dictionary(uniqueKeysWithValues: state.observations.map { ($0.panelID, $0) })
        validationLock.unlock()
        // Replay positive facts after every accepted update, including claims
        // arriving after panel construction. Consumers make registration
        // idempotent; no empty batch is a request to clear persisted state.
        if !state.observations.isEmpty { handler(state.observations) }
    }

    private func invalidatePublishedFacts() {
        validationLock.lock()
        validObservations.removeAll()
        validationLock.unlock()
    }

    private func updateTimer() {
        guard subscription != nil, state.needsRetry, remainingRetries > 0 else {
            retryTimer?.cancel()
            retryTimer = nil
            return
        }
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 100 ms leeway at the 1 s production interval; never more than one
        // interval when a test injects a shorter one.
        timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval,
                       leeway: .nanoseconds(Int(min(0.1, retryInterval) * 1_000_000_000)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.remainingRetries -= 1
            self.invalidatePublishedFacts()
            self.state.recover()
            self.publish()
            self.updateTimer()
        }
        retryTimer = timer
        timer.resume()
    }

    #if DEBUG
    /// Whether a retry timer is armed, read on the recovery queue.
    func retryTimerArmedForTesting() -> Bool { queue.sync { retryTimer != nil } }
    #endif

    deinit {
        subscription?.cancel()
        retryTimer?.cancel()
    }
}
