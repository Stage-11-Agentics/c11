import Foundation
import OSLog

/// What the relay needs from c11's hc session: the remote machine's
/// document store, its manifest file, machine facts and the inventory.
protocol C11RelayHost: Sendable {
    func relayDocGet(machine: String, name: String) async throws -> (value: Any?, version: UInt64)
    /// Throws `C11RelayStoreError.conflict` on a stale version.
    func relayDocSet(machine: String, name: String, value: Any?, version: UInt64) async throws -> UInt64
    func relayFileRead(machine: String, path: String) async throws -> String
    /// hc's machine list: name -> (host, session on that machine).
    func relayMachines() async throws -> [String: (host: String, session: String?)]
    func snapshot() async -> HCInventorySnapshot
    /// C11H-176: the creation c11 itself made for the panel's current
    /// terminal, from its own records, not hc's labels.
    func relayCurrentCreation(panel: UUID) async -> C11RelayCreationAnswer
}

/// What c11's own records say about a panel's current terminal.
enum C11RelayCreationAnswer: Equatable, Sendable {
    /// Its current creation, and the machine it was made on (nil: an older record).
    case live(UUID, machine: String?)
    /// No current terminal: never made by this session, or ended.
    case none
    /// The records could not be read just now.
    case unknown
}

/// Runs one admitted request. Production executes it through the socket
/// command processor; tests record it.
protocol C11RelayExecutor: Sendable {
    func execute(_ admitted: C11RelayPolicy.Admitted, caller: C11RelayPolicy.VerifiedCaller,
                 originHost: String, machines: Set<String>, snapshot: HCInventorySnapshot) async -> String
}

/// One machine-link transition. `up` is connected, `down` is disconnected or
/// gone from the snapshot, `reconnecting` is unknown (the panels say
/// Reconnecting). The previous state's duration is none until a state has
/// been seen.
enum HCMachineLinkJournal {
    enum State: String, Equatable { case up, down, reconnecting }

    struct Record: Equatable {
        var states: [String: State]
        var since: [String: Int64]
        var lines: [String]
    }

    static func state(for availability: HCMachineAvailability) -> State? {
        switch availability {
        case .connected: return .up
        case .disconnected: return .down
        case .unknown: return .reconnecting
        case .local: return nil
        }
    }

    static func changes(from previous: [String: State], since: [String: Int64],
                        to machines: [String: HCMachineAvailability], at now: Int64) -> Record {
        var states = previous
        var clocks = since
        var lines: [String] = []
        var seen = Set<String>()
        for (machine, availability) in machines.sorted(by: { $0.key < $1.key }) {
            guard let state = state(for: availability) else { continue }
            seen.insert(machine)
            append(&lines, machine: machine, state: state, previous: previous[machine],
                   since: clocks[machine], at: now, into: &states, clocks: &clocks)
        }
        for machine in previous.keys.sorted() where !seen.contains(machine) && previous[machine] != .down {
            append(&lines, machine: machine, state: .down, previous: previous[machine],
                   since: clocks[machine], at: now, into: &states, clocks: &clocks)
        }
        return Record(states: states, since: clocks, lines: lines)
    }

    private static func append(_ lines: inout [String], machine: String, state: State, previous: State?,
                               since started: Int64?, at now: Int64,
                               into states: inout [String: State], clocks: inout [String: Int64]) {
        if let previous, previous == state { return }
        let prior = previous?.rawValue ?? "none"
        let held: String
        if previous != nil, let started {
            let delta = now - started
            held = String(delta < 0 ? 0 : delta)
        } else {
            held = "none"
        }
        lines.append("link-\(state.rawValue) machine=\(machine) previous=\(prior) previous_ms=\(held)")
        states[machine] = state
        clocks[machine] = now
    }
}

/// The serving side of the relay (plan ticket 14). Off-main throughout: doc
/// events arrive from the inventory's queue, every hc call is async with its
/// own deadline, and execution runs on a worker. Requests from one machine
/// are claimed in event order; a pending spool drain finishes before any
/// later request from that machine is claimed.
actor C11RelayService {
    /// C11H-78: one service per local hc session (a shard). Each claims only
    /// its own core's relay slots and verifies a caller against that core's
    /// records alone: addresses restart at t1 in every shard.
    static func service(for session: String) -> C11RelayService { C11RelayServices.shared.service(for: session) }
    /// The release build's legacy session's service.
    static var shared: C11RelayService { service(for: HCAtlasLink.releaseSession) }
    /// The local session this service serves; keys the relay environment.
    nonisolated let localSession: String
    static let maxConcurrent = 8
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.relay")

    private var host: (any C11RelayHost)?
    /// C11H-332: every relayed call, served or refused, is counted here.
    private let audit: C11AuditLog
    /// C11H-332: relay audit lines folded by (machine, panel, method,
    /// outcome, code). The first of a key in a minute is written at once;
    /// the rest of that minute are counted, not written, and one summary
    /// line carries their count when the minute is over. Chatter then never
    /// rotates the link and hc trust records out of the log.
    private struct AuditFold {
        let machine: String
        let panel: String
        let method: String?
        let outcome: String
        let code: String?
        let started: Int64
        var count = 0
        var ids: [String] = []
        /// Request ids already counted this minute: a retransmission never counts twice.
        var seen: Set<String> = []
    }
    private var auditFolds: [String: AuditFold] = [:]
    /// C11H-365 (L12): new refused-call fold keys each machine opened in its
    /// current minute. Past `auditFoldKeysPerMinute`, its refused calls fold
    /// into one key (code `audit_fold_capped`), so no machine can rotate the
    /// log. A call that ran is never capped: it passed verify and
    /// authenticate, so its panel is one of c11's own creations there, its
    /// method one the relay admits and its code c11's own; c11's state bounds
    /// those keys. A refusal carries the request's own method text.
    private var foldKeysOpened: [String: (started: Int64, count: Int)] = [:]
    static let auditFoldKeysPerMinute = 16
    static let auditFoldCappedCode = "audit_fold_capped"
    /// C11H-332: machines whose stored link doesn't check an hc pin and
    /// couldn't be migrated: no relayed call from them is served, and their
    /// spool waits for Update.
    private var unusableMachines: Set<String> = []
    private var unusableGeneration: UInt64?
    static let linkUnusableCode = "relay_link_unusable"

    /// `generation`: the session's count of changes; an older one than the
    /// newest seen is dropped (C11H-391, NB6: two overlapping reviews).
    func setUnusableMachines(_ machines: Set<String>, generation: UInt64? = nil) {
        if let generation {
            if let newest = unusableGeneration, generation < newest { return }
            unusableGeneration = generation
        }
        unusableMachines = machines
    }
    static let auditFoldMilliseconds: Int64 = 60_000
    static let auditFoldLimit = 1024
    static let auditFoldIDs = 5
    static let auditFoldSeenLimit = 64
    /// C11H-332: the codes a dropped spool record is audited with when the
    /// policy gives none.
    static let notSpoolableCode = "relay_not_spoolable"
    static let spoolExpiredCode = "relay_spool_expired"
    /// The newest machines snapshot that arrived before install(host:).
    private var machinesBeforeHost: [String: HCMachineAvailability]?
    private var executor: (any C11RelayExecutor)?
    private var chains: [String: Task<Void, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var connected: Set<String> = []
    private var machineFacts: [String: (host: String, session: String?)] = [:]
    private var lastSlotVersion: [String: UInt64] = [:]
    private var inFlight: Set<String> = []
    /// Machines whose spool waits for a ready inventory; it is never cleared before then.
    private var spoolWaitingForInventory: Set<String> = []
    private(set) var log: [String] = []
    /// Seconds before drain attempt `n` (1-based) after a link-up or a failed drain.
    private let retryDelay: @Sendable (Int) -> TimeInterval
    /// C11H-89: how long a claimed request waits for a ready inventory (a
    /// panel close or creation refreshes it, pending for a few tens of ms),
    /// and how often it looks. Capped at half the request's reply budget.
    private let inventoryWait: TimeInterval
    private let inventoryPoll: TimeInterval
    /// C11H-88: how often c11 refreshes its heartbeat on each linked machine
    /// (0 turns it off), and its wall clock.
    private let heartbeat: TimeInterval
    private let wallMilliseconds: @Sendable () -> Int64
    /// C11H-88: when this service last saw each machine's link go down and
    /// come up (wall ms), from the machine-link monitor's snapshots.
    private var linkDownAt: [String: Int64] = [:]
    /// Last logged link state per machine, and the wall ms it began.
    private var linkState: [String: HCMachineLinkJournal.State] = [:]
    private var linkStateSince: [String: Int64] = [:]
    /// C11H-97: each in-flight claim's event-to-claim time (nil: a rescan), for its served line.
    private var claimMilliseconds: [String: Int?] = [:]
    private var linkUpAt: [String: Int64] = [:]
    /// C11H-88: event-to-claim latency, logged as a summary.
    private var claimLatencies: [Double] = []
    private var rescanClaims = 0
    private var latencySince = ProcessInfo.processInfo.systemUptime
    private let latencyBatch: Int
    static let latencyEvery: TimeInterval = 60
    static let slowClaimMilliseconds = 500.0
    /// After a link-up the spool is read again at these attempts: hc may serve
    /// the remote document a moment after the machine reports connected.
    static let linkUpFollowUps = [1, 3]
    static let maxDrainAttempts = 5
    private nonisolated let scheduled = C11RelayCounter()
    /// C11H-176: the link secrets that credentials are checked against.
    private nonisolated let keyring: any C11RelayLinkSecrets
    /// Nonces issued in each machine's heartbeat, newest last, with when.
    private var nonces: [String: [(value: String, at: Int64)]] = [:]
    /// Live request ids served per machine, with when (the replay window).
    private var usedIDs: [String: [String: Int64]] = [:]
    /// Each terminal's applied spooled record ids, kept across restarts.
    private nonisolated let spoolMarks: C11RelaySpoolMarks
    /// Pickups not yet seen claimed, and credentials refused because theirs never was.
    private nonisolated let pickups: C11RelayPickupLedger
    static let nonceRingLimit = 64
    /// Auth refusals already reported (machine, panel, code) and when, so
    /// each is said once an hour at most; the oldest gives way when full.
    private var reportedRefusals: [String: Int64] = [:]
    static let reportedRefusalWindowMilliseconds: Int64 = 60 * 60 * 1000
    /// C11H-176 part B: the workspace that holds a panel now, from c11's model.
    private let workspaceOf: @Sendable (UUID) -> UUID?
    /// Whether a live panel other than the caller answers to a mail identity.
    private let identityTaken: @Sendable (String, UUID) -> Bool
    /// Where an auth refusal is reported on the Mac (the diagnostics log).
    private let onAuthRefused: (@Sendable (_ machine: String, _ panel: String, _ terminal: String, _ code: String) -> Void)?

    /// Inputs arrive from the inventory queue in hc's event order and are
    /// consumed by one task, so that order is kept.
    private enum Input: Sendable {
        case doc(machine: String, name: String, version: UInt64, received: TimeInterval)
        case resubscribed
        case machines([String: HCMachineAvailability])
        case drain(machine: String, reason: String, attempt: Int)
    }
    private nonisolated let inputs: AsyncStream<Input>.Continuation
    private nonisolated let submitted = C11RelayCounter()
    private var processed = 0

    init(localSession: String = HCAtlasLink.releaseSession,
         retryDelay: @escaping @Sendable (Int) -> TimeInterval = { attempt in [0, 1, 2, 3, 5, 8][min(attempt, 5)] },
         inventoryWait: TimeInterval = 2, inventoryPoll: TimeInterval = 0.02,
         heartbeat: TimeInterval = 2, latencyBatch: Int = 50,
         wallMilliseconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         keyring: any C11RelayLinkSecrets = C11RelayMemoryKeyring(),
         spoolMarks: C11RelaySpoolMarks = C11RelaySpoolMarks(url: nil),
         pickups: C11RelayPickupLedger = C11RelayPickupLedger(url: nil),
         workspaceOf: @escaping @Sendable (UUID) -> UUID? = { JournalCoordinator.shared.target(panelID: $0) },
         identityTaken: @escaping @Sendable (String, UUID) -> Bool = C11RelayService.liveIdentityTaken,
         audit: C11AuditLog = .shared,
         onAuthRefused: (@Sendable (_ machine: String, _ panel: String, _ terminal: String, _ code: String) -> Void)? = nil) {
        self.localSession = localSession
        self.audit = audit
        self.workspaceOf = workspaceOf
        self.identityTaken = identityTaken
        self.keyring = keyring
        self.spoolMarks = spoolMarks
        self.pickups = pickups
        self.onAuthRefused = onAuthRefused
        self.retryDelay = retryDelay
        self.inventoryWait = inventoryWait
        self.inventoryPoll = inventoryPoll
        self.heartbeat = heartbeat
        self.latencyBatch = latencyBatch
        self.wallMilliseconds = wallMilliseconds
        let (stream, continuation) = AsyncStream.makeStream(of: Input.self, bufferingPolicy: .bufferingNewest(1024))
        inputs = continuation
        Task { [weak self] in
            for await input in stream {
                guard let self else { return }
                await self.consume(input)
            }
        }
        if heartbeat > 0 {
            Task { [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: UInt64(heartbeat * 1_000_000_000))
                    guard let self else { return }
                    await self.beatAll()
                }
            }
        }
    }

    /// C11H-88: refresh the heartbeat on every connected machine.
    /// C11H-332: each tick also ends the audit folds whose minute is over.
    private func beatAll() async {
        flushAuditFolds()
        for machine in connected.sorted() { await beat(machine) }
    }

    /// Writes `c11h.relay.seen` on `machine`. A conflict or failure is left
    /// for the next beat; it never touches a slot or the spool.
    /// C11H-176: each beat carries a fresh nonce for that machine's requests.
    private func beat(_ machine: String) async {
        guard let host, connected.contains(machine) else { return }
        let name = C11Relay.seenName
        guard let (_, version) = try? await host.relayDocGet(machine: machine, name: name) else { return }
        let nonce = issueNonce(machine)
        _ = try? await host.relayDocSet(machine: machine, name: name,
                                        value: C11Relay.seenValue(at: wallMilliseconds(), upAt: linkUpAt[machine],
                                                                   downAt: linkDownAt[machine], nonce: nonce),
                                        version: version)
    }

    /// C11H-176: pickups this session wrote on `machine` that were never
    /// settled (c11 quit within the linger time) are settled at link-up.
    private func settlePickups(_ machine: String) async {
        guard let host else { return }
        let cutoff = wallMilliseconds() - Int64(C11RelayAuth.pickupLingerSeconds * 1000)
        for pending in pickups.pending(machine: machine, olderThan: cutoff) {
            await C11RelayPickupDelivery.settle(pending, host: host, ledger: pickups)
        }
    }

    // MARK: Freshness (C11H-176)

    /// A new random nonce for `machine`'s heartbeat, or nil if the system
    /// random source failed (the beat then carries none).
    func issueNonce(_ machine: String) -> String? {
        guard let bytes = C11RelayAuth.randomBytes(16) else { return nil }
        let nonce = C11RelayAuth.hex(bytes)
        var ring = nonces[machine] ?? []
        ring.append((nonce, wallMilliseconds()))
        if ring.count > Self.nonceRingLimit { ring.removeFirst(ring.count - Self.nonceRingLimit) }
        nonces[machine] = ring
        return nonce
    }

    /// The latest nonce issued to `machine` (tests).
    func latestNonce(_ machine: String) -> String? { nonces[machine]?.last?.value }

    /// A live request must carry a nonce issued to its machine within the
    /// nonce lifetime, and an id not served within the replay window.
    /// Checking records nothing: `markServed` records the id once the claim
    /// has won, so a request the CLI cancelled (and then spooled) is not
    /// mistaken for one that ran.
    private func freshness(_ request: C11Relay.Request, machine: String) -> C11RelayPolicy.Refusal? {
        let now = wallMilliseconds()
        usedIDs[machine] = (usedIDs[machine] ?? [:]).filter { now - $0.value <= C11RelayAuth.replayWindowMilliseconds }
        guard !request.nonce.isEmpty,
              let issued = nonces[machine]?.last(where: { $0.value == request.nonce }),
              now - issued.at <= C11RelayAuth.nonceLifetimeMilliseconds else { return C11RelayPolicy.staleRefusal }
        guard usedIDs[machine]?[request.id] == nil else { return C11RelayPolicy.replayRefusal }
        return nil
    }

    /// Records a live request id as served. The claim chain for a machine is
    /// serial, so no copy can be checked between `freshness` and this.
    private func markServed(_ request: C11Relay.Request, machine: String) {
        usedIDs[machine, default: [:]][request.id] = wallMilliseconds()
    }

    /// Says once per (machine, panel, code) on the Mac that a terminal there
    /// was refused for its credential, so a quiet remote agent is visible
    /// here and not only in that machine's stderr.
    private func reportAuthRefusal(machine: String, panel: String, terminal: String, code: String) {
        guard [C11RelayAuth.authMissingCode, C11RelayAuth.authRefusedCode, C11RelayAuth.kitOutdatedCode].contains(code) else { return }
        // What the request claimed, reduced to a UUID and a plain token. An
        // older kit's request is not checked at all, so it is said once per
        // machine, never per claimed panel.
        let unverified = code == C11RelayAuth.kitOutdatedCode
        let panel = unverified ? "unverified" : (UUID(uuidString: panel)?.uuidString.lowercased() ?? "invalid")
        let terminal = !unverified && Self.isToken(terminal) ? terminal : "unverified"
        let key = "\(machine)\u{0}\(panel)\u{0}\(code)"
        let now = wallMilliseconds()
        reportedRefusals = reportedRefusals.filter { now - $0.value < Self.reportedRefusalWindowMilliseconds }
        guard reportedRefusals[key] == nil else { return }
        if reportedRefusals.count >= Self.reportedRefusalLimit,
           let oldest = reportedRefusals.min(by: { $0.value < $1.value })?.key {
            reportedRefusals.removeValue(forKey: oldest)
        }
        reportedRefusals[key] = now
        note("auth-refused machine=\(machine) panel=\(panel) terminal=\(terminal) code=\(code)")
        onAuthRefused?(machine, panel, terminal, code)
    }

    static let reportedRefusalLimit = 1024

    /// Whether any live panel but `caller` has `value` as its mailbox
    /// address, role or title (any letter case), from c11's metadata.
    static func liveIdentityTaken(_ value: String, by caller: UUID) -> Bool {
        let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return false }
        for (_, panels) in PanelMetadataStore.shared.readSnapshot().metadata {
            for (panel, metadata) in panels where panel != caller {
                for key in ["mailbox.address", "mailbox.role", MetadataKey.title] {
                    if let held = metadata[key] as? String,
                       held.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted { return true }
                }
            }
        }
        return false
    }

    static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a)
                || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
        }
    }

    /// C11H-86: a machines snapshot that came before the host is held, not
    /// recorded. Install applies it here, before the stream's next input, so
    /// every machine already connected is announced (its manifest read) and
    /// drained exactly once, and a newer snapshot already queued in the
    /// stream is applied after it, never overwritten by it.
    func install(host: any C11RelayHost, executor: any C11RelayExecutor) async {
        self.host = host
        self.executor = executor
        if let pending = machinesBeforeHost {
            machinesBeforeHost = nil
            await applyMachines(pending)
        }
    }

    // MARK: Inputs

    nonisolated func docEvent(machine: String, name: String, version: UInt64) {
        submit(.doc(machine: machine, name: name, version: version, received: ProcessInfo.processInfo.systemUptime))
    }

    /// The event subscription was renewed, or hc replaced events with a
    /// `missed` snapshot: a spool or slot event may be lost, so drain every
    /// connected machine's spool and claim any request still open in a slot
    /// (C11H-89). A slot already claimed, answered or cancelled runs nothing.
    nonisolated func resubscribed() { submit(.resubscribed) }

    nonisolated func machinesChanged(_ machines: [String: HCMachineAvailability]) { submit(.machines(machines)) }

    private nonisolated func submit(_ input: Input) {
        submitted.increment()
        inputs.yield(input)
    }

    private func consume(_ input: Input) async {
        switch input {
        case .doc(let machine, let name, let version, let received):
            enqueueDoc(machine: machine, name: name, version: version, received: received)
        case .resubscribed:
            drainAllConnected(reason: "resubscribed")
            rescanSlots()
            for machine in connected.sorted() { Task { await self.drainShows(machine) } }
        case .machines(let machines): await applyMachines(machines)
        case .drain(let machine, let reason, let attempt):
            scheduled.decrement()
            if connected.contains(machine) {
                enqueue(machine) { await self.drainSpool(machine: machine, reason: reason, attempt: attempt) }
            }
        }
        processed += 1
    }

    // MARK: Ordering

    private func enqueue(_ machine: String, _ work: @escaping @Sendable () async -> Void) {
        let previous = chains[machine]
        chains[machine] = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits until every submitted input, claim, drain and execution has
    /// finished, then writes every pending audit summary (tests).
    func settle() async {
        defer { flushAuditFolds(all: true) }
        for _ in 0..<5000 {
            for task in Array(chains.values) { await task.value }
            if processed == submitted.value, running == 0, inFlight.isEmpty, scheduled.value == 0 {
                for task in Array(chains.values) { await task.value }
                if processed == submitted.value, running == 0, inFlight.isEmpty, scheduled.value == 0 { return }
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func enqueueDoc(machine: String, name: String, version: UInt64, received: TimeInterval) {
        if name == C11Relay.spoolName {
            enqueue(machine) { await self.drainSpool(machine: machine, reason: "event") }
        } else if let panel = ShowRecord.panel(fromName: name) {
            // C11H-228: a show recorded on that machine. Read off the claim chain.
            Task { await self.drainShows(machine, panel: panel) }
        } else if let slot = C11Relay.slotIndex(name) {
            enqueue(machine) { await self.claim(machine: machine, slot: slot, version: version, received: received) }
        }
    }

    private func applyMachines(_ machines: [String: HCMachineAvailability]) async {
        // C11H-86: with no host yet, nothing is recorded as connected, or the
        // arrival would be spent here and never announced. install() replays it.
        guard host != nil else { machinesBeforeHost = machines; return }
        let now = Set(machines.filter { $0.value == .connected }.keys)
        let arrived = now.subtracting(connected)
        let wall = wallMilliseconds()
        for machine in connected.subtracting(now) {
            linkDownAt[machine] = wall
        }
        for machine in arrived { linkUpAt[machine] = wall }
        let journal = HCMachineLinkJournal.changes(from: linkState, since: linkStateSince, to: machines, at: wall)
        linkState = journal.states
        linkStateSince = journal.since
        for line in journal.lines { note(line) }
        connected = now
        // A ready inventory releases any spool that waited for it.
        for machine in spoolWaitingForInventory.intersection(now).subtracting(arrived).sorted() {
            enqueue(machine) { await self.drainSpool(machine: machine, reason: "inventory_ready") }
        }
        guard !arrived.isEmpty, let host else { return }
        if let facts = try? await host.relayMachines() { machineFacts = facts }
        for machine in arrived.sorted() {
            if let link = host as? any ShowLinkHost {
                // C11H-359 (L3): this shard's link to the machine, usable only
                // with the secret it holds now.
                let keyring = self.keyring, session = localSession
                ShowHosts.shared.set(ShowHosts.Link(host: link, records: ShowHCRecordStore(host: host), currentLinkID: {
                    keyring.secret(session: session, machine: machine)?.id
                }), session: session, machine: machine)
            }
            Task { await self.drainShows(machine) }   // C11H-228: shows recorded while c11 was away
            await announce(machine)
            let sweep = self.settlePickups
            Task { await sweep(machine) }   // never holds the input loop for other machines
            await beat(machine)   // C11H-88: the CLI can tell c11 is answering from link-up on
            enqueue(machine) { await self.drainSpool(machine: machine, reason: "connected") }
            for attempt in Self.linkUpFollowUps { scheduleDrain(machine, reason: "connected", attempt: attempt) }
        }
    }

    /// Submits another drain of `machine`'s spool after `retryDelay(attempt)`.
    private func scheduleDrain(_ machine: String, reason: String, attempt: Int) {
        let delay = retryDelay(attempt)
        scheduled.increment()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            self?.submit(.drain(machine: machine, reason: reason, attempt: attempt))
        }
    }

    /// C11H-89: an inventory refresh (a panel close or creation) closes and
    /// reopens hc's event channel, and a slot's doc event that lands in that
    /// gap is lost. A request the CLI wrote then is still waiting for its
    /// claim, so a renewed subscription reads every slot once and claims any
    /// request in it. A request already claimed, answered or cancelled is
    /// skipped by claim()'s own version and state checks.
    /// The slot reads run in parallel and off the claim chain, so a rescan
    /// over a slow link never holds up a request's claim; only the requests
    /// found are queued on the chain, in slot order.
    private func rescanSlots() {
        guard let host else { return }
        for machine in connected.sorted() {
            scheduled.increment()
            Task {
                defer { self.scheduled.decrement() }
                let found = await withTaskGroup(of: (Int, UInt64)?.self) { group -> [(Int, UInt64)] in
                    for slot in 0..<C11Relay.slotCount {
                        group.addTask {
                            guard let (value, version) = try? await host.relayDocGet(machine: machine, name: C11Relay.slotName(slot)),
                                  C11Relay.Request(value) != nil || C11Relay.legacyRequest(value) != nil else { return nil }
                            return (slot, version)
                        }
                    }
                    var out: [(Int, UInt64)] = []
                    for await item in group { if let item { out.append(item) } }
                    return out.sorted { $0.0 < $1.0 }
                }
                for (slot, version) in found {
                    self.enqueue(machine) { await self.claim(machine: machine, slot: slot, version: version) }
                }
            }
        }
    }

    private func drainAllConnected(reason: String) {
        for machine in connected.sorted() {
            enqueue(machine) { await self.drainSpool(machine: machine, reason: reason) }
        }
    }

    /// Reads the relay manifest the machine's installer wrote and records the
    /// prototype trust once per link-up.
    private func announce(_ machine: String) async {
        guard let host else { return }
        let facts = machineFacts[machine]
        // C11H-78: a pool shard pairs one to one, so its line runs only the
        // remote session of its own name. Shard 0's hand-made link may name
        // any session (the release session when hc does not say).
        let session: String
        if HCAtlasPairing.isShardSession(localSession) {
            if let remote = facts?.session, remote != localSession {
                C11RelayEnvironment.shared.set(nil, for: machine, session: localSession)
                record("trust \(machine) manifest=foreign_session remote=\(remote)")
                C11RelayLog.trust(machine: machine, host: facts?.host ?? machine, session: remote, manifest: "foreign_session")
                return
            }
            session = localSession
        } else {
            session = facts?.session ?? HCAtlasLink.releaseSession
        }
        var manifestState = "absent"
        for path in C11Relay.Manifest.relativePaths(session: session) {
            guard let text = try? await host.relayFileRead(machine: machine, path: path) else { continue }
            if let manifest = C11Relay.Manifest(data: Data(text.utf8), session: session) {
                C11RelayEnvironment.shared.set(manifest, for: machine, session: localSession)
                manifestState = "installed"
                break
            }
            manifestState = "invalid"
        }
        record("trust \(machine) manifest=\(manifestState)")
        C11RelayLog.trust(machine: machine, host: facts?.host ?? machine, session: session, manifest: manifestState)
    }

    // MARK: Shows recorded while away (C11H-228)

    /// Reads the show records of `machine`'s panels (one panel when named)
    /// and hands the ones to surface to Feed. A record counts only for a
    /// panel whose terminal runs on that machine now, and an entry only when
    /// that terminal's own relay credential signed it.
    func drainShows(_ machine: String, panel only: UUID? = nil) async {
        guard let host, connected.contains(machine) else { return }
        // C11H-365 (L10): an unusable link's away shows wait, unread, for its
        // Update, as its spool does.
        if unusableMachines.contains(machine) {
            note("show-records-held \(machine) link_unusable")
            return
        }
        let snapshot = await host.snapshot()
        let link = keyring.secret(session: localSession, machine: machine)
        let store = ShowHCRecordStore(host: host)
        let session = localSession
        let pickups = self.pickups
        var found: [UUID: [ShowAwayEntry]] = [:]
        for record in snapshot.records.values where record.machineName == machine && record.state == .running {
            guard let panel = record.labels["c11.panel"].flatMap(UUID.init(uuidString:)), only == nil || panel == only else { continue }
            let creation = record.labels["c11.creation"].flatMap(UUID.init(uuidString:))
            // C11H-365 (L10): as `standing()` for a live call, c11's own record
            // must still make this creation the panel's terminal on this
            // machine; one it can't read just now doesn't refuse.
            guard Self.showRecordStands(await host.relayCurrentCreation(panel: panel), creation: creation, machine: machine) else {
                continue
            }
            let container = ShowOrigin.container(foregroundName: record.foreground?.name, argv: record.foreground?.argv)
            // The terminal's key, as c11 derives it: verifies its entries and
            // signs c11's own state changes to them.
            let signer = link.flatMap { link in
                creation.map { ShowEntrySigner(linkID: link.id, creation: $0, key: C11RelayAuth.terminalKey(
                    link: link, session: session, machine: machine, panel: panel, creation: $0)) }
            }
            let entries = await ShowRecordDrain.drain(store: store, machine: machine, panel: panel, signer: signer) { entry in
                guard let link, let creation, entry.linkID == link.id,
                      entry.creation == creation.uuidString.lowercased(),
                      !pickups.isRevoked(creation: creation.uuidString.lowercased()) else { return false }
                return entry.isSigned(panel: panel, key: C11RelayAuth.terminalKey(link: link, session: session, machine: machine,
                                                                                  panel: panel, creation: creation))
            }
            // An unreadable record changes nothing; a read one is the truth.
            guard let entries else { continue }
            // Filtered here, off main: the URL check may resolve host names.
            found[panel] = ShowAwayShows.admissible(
                entries.map { ShowAwayEntry(panel: panel, machine: machine, container: container, entry: $0, signer: signer,
                                            link: link.map { C11RelayLinkRef(session: session, machine: machine, linkID: $0.id) }) })
        }
        let surfaced = found.values.reduce(0) { $0 + $1.count }
        if surfaced > 0 { note("show-records machine=\(machine) surfaced=\(surfaced)") }
        await MainActor.run {
            for (panel, items) in found { ShowAwayShows.shared.reconcile(panel: panel, items: items) }
        }
    }

    // MARK: Live requests

    /// `received` is when the slot's doc event reached the service; nil for a
    /// claim found by a rescan (its event was lost).
    private func claim(machine: String, slot: Int, version: UInt64, received: TimeInterval? = nil) async {
        guard let host, let executor else { return }
        // A spool that waited for the inventory is applied before any later request.
        if spoolWaitingForInventory.contains(machine) { await drainSpool(machine: machine, reason: "inventory_ready") }
        let name = C11Relay.slotName(slot)
        let key = "\(machine)\u{0}\(name)"
        if let last = lastSlotVersion[key], last >= version { return }
        guard !inFlight.contains(key) else { return }
        guard let (value, current) = try? await host.relayDocGet(machine: machine, name: name) else { return }
        guard let request = C11Relay.Request(value) else {
            // C11H-176: an older relay kit's request is refused as outdated.
            if let legacy = C11Relay.legacyRequest(value) {
                lastSlotVersion[key] = current
                await refuseLegacy(machine: machine, name: name, key: key, id: legacy.id, at: legacy.at,
                                   panel: (value as? [String: Any])?["panel"] as? String ?? "?",
                                   terminal: (value as? [String: Any])?["term"] as? String ?? "?", version: current)
            }
            return
        }
        lastSlotVersion[key] = current
        let snapshot = await host.snapshot()
        let intended = await intendedCreation(request)
        var decision = decide(request, machine: machine, snapshot: snapshot, intended: intended)
        if case .run(_, _, let credential) = decision, let stale = freshness(request, machine: machine) {
            decision = .refused(code: stale.code, message: stale.message, credential: credential)
        }
        // C11H-89: a pending inventory is about timing, not the request. Claim
        // it now (so the CLI's claim wait is met) and decide off this chain,
        // once the inventory is ready or the wait runs out.
        let waits: Bool
        if case .refused(let code, _, _) = decision, code == C11RelayPolicy.inventoryPendingCode { waits = true } else { waits = false }
        let reply: [String: Any]
        switch decision {
        case .refused(let code, let message, let credential) where !waits:
            reply = C11Relay.refusedValue(request, code: code, message: message, key: credential)
        default: reply = C11Relay.claimedValue(request)
        }
        // Claim (or refuse) by compare-and-set. A conflict means the CLI
        // cancelled first: nothing runs.
        guard let claimedVersion = try? await host.relayDocSet(machine: machine, name: name, value: reply, version: current) else {
            record("cancelled \(machine) \(name)")
            return
        }
        lastSlotVersion[key] = claimedVersion
        if case .run = decision { markServed(request, machine: machine) }
        let latency = noteClaimLatency(machine: machine, name: name, received: received)
        if case .refused(let code, _, _) = decision, !waits {
            note("refused \(machine) \(name) \(code)")
            reportAuthRefusal(machine: machine, panel: request.panel, terminal: request.term, code: code)
            auditRefusal(request, machine: machine, code: code,
                         unverified: refusedBeforeAuthentication(request, machine: machine, snapshot: snapshot))
            return
        }
        claimMilliseconds[key] = latency
        inFlight.insert(key)
        let origin = machineFacts[machine]?.host ?? machine
        let machines = Set(machineFacts.keys).union(connected)
        let budget = min(inventoryWait, Double(request.timeoutMilliseconds) / 2000)
        Task {
            var decided = decision, used = snapshot
            if waits {
                let start = ProcessInfo.processInfo.systemUptime
                while ProcessInfo.processInfo.systemUptime - start < budget {
                    try? await Task.sleep(nanoseconds: UInt64(self.inventoryPoll * 1_000_000_000))
                    used = await host.snapshot()
                    if case .ready = used.readiness { break }
                }
                let intended = await self.intendedCreation(request)
                decided = await self.decide(request, machine: machine, snapshot: used, intended: intended)
                if case .run(_, _, let credential) = decided {
                    if let stale = await self.freshness(request, machine: machine) {
                        decided = .refused(code: stale.code, message: stale.message, credential: credential)
                    } else {
                        await self.markServed(request, machine: machine)   // claimed already, before the wait
                    }
                }
                let waited = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                let ready: Bool
                if case .ready = used.readiness { ready = true } else { ready = false }
                await self.note("inventory-wait \(machine) \(name) waited_ms=\(waited) ready=\(ready)")
            }
            switch decided {
            case .refused(let code, let message, let credential):
                await self.refuseClaimed(machine: machine, name: name, key: key, request: request,
                                         code: code, message: message, credential: credential, version: claimedVersion,
                                         snapshot: used)
            case .run(let admitted, let caller, let credential):
                // A spool that waited on this same inventory goes first, as
                // it would for a request claimed after it (Grok #121 1).
                if waits { await self.applyWaitingSpool(machine) }
                await self.acquireWorker()
                let response = await executor.execute(admitted, caller: caller, originHost: origin, machines: machines,
                                                      snapshot: used)
                await self.finish(machine: machine, name: name, key: key, request: request,
                                  response: response, credential: credential, version: claimedVersion)
            }
        }
    }

    /// C11H-88: one claim's event-to-claim time. A summary goes to the log
    /// every `latencyBatch` claims or `latencyEvery` seconds; a claim slower
    /// than `slowClaimMilliseconds` is logged on its own.
    @discardableResult
    private func noteClaimLatency(machine: String, name: String, received: TimeInterval?) -> Int? {
        let now = ProcessInfo.processInfo.systemUptime
        var result: Int?
        if let received {
            let ms = (now - received) * 1000
            result = Int(ms)
            claimLatencies.append(ms)
            if ms > Self.slowClaimMilliseconds { note("slow-claim \(machine) \(name) ms=\(Int(ms))") }
        } else {
            rescanClaims += 1
            note("rescan-claim \(machine) \(name)")
        }
        guard claimLatencies.count >= latencyBatch || (now - latencySince >= Self.latencyEvery && !claimLatencies.isEmpty) else { return result }
        note(Self.latencySummary(claimLatencies, rescans: rescanClaims))
        claimLatencies.removeAll(); rescanClaims = 0; latencySince = now
        return result
    }

    static func latencySummary(_ samples: [Double], rescans: Int) -> String {
        let sorted = samples.sorted()
        func at(_ q: Double) -> Int { sorted.isEmpty ? 0 : Int(sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q + 0.5))]) }
        return "claim-latency n=\(sorted.count) p50=\(at(0.5)) p95=\(at(0.95)) max=\(Int(sorted.last ?? 0)) rescans=\(rescans)"
    }

    /// Runs the machine's waiting spool to completion through its claim
    /// chain (after any drain already on it) and returns when that is done.
    private func applyWaitingSpool(_ machine: String) async {
        enqueue(machine) {
            if await self.spoolWaitingForInventory.contains(machine) {
                await self.drainSpool(machine: machine, reason: "inventory_ready")
            }
        }
        await chains[machine]?.value
    }

    private enum Decision {
        /// `credential` is the caller's terminal credential; it signs the reply.
        case run(C11RelayPolicy.Admitted, C11RelayPolicy.VerifiedCaller, credential: Data)
        /// `credential` is set once the caller was authenticated: the refusal is signed with it.
        case refused(code: String, message: String, credential: Data? = nil)
    }

    /// Identity, then the credential (C11H-176), then the method policy.
    /// Freshness is checked by the caller, which records the request id.
    private func decide(_ request: C11Relay.Request, machine: String, snapshot: HCInventorySnapshot,
                        intended: C11RelayCreationAnswer, mode: C11Relay.Request.Mode = .live) -> Decision {
        switch C11RelayPolicy.verify(request, machine: machine, snapshot: snapshot) {
        case .failure(let refusal): return .refused(code: refusal.code, message: refusal.message)
        case .success(var verified):
            verified.workspace = workspaceOf(verified.panel)
            let link = keyring.secret(session: localSession, machine: machine)
            switch C11RelayPolicy.authenticate(request, caller: verified, session: localSession, link: link) {
            case .failure(let refusal): return .refused(code: refusal.code, message: refusal.message)
            case .success(let credential):
                verified.link = link.map { C11RelayLinkRef(session: localSession, machine: machine, linkID: $0.id) }
                // C11H-332: an unusable link's calls are refused once the
                // caller is authenticated, so the refusal is signed and the
                // agent there reads why.
                if unusableMachines.contains(machine) {
                    return .refused(code: Self.linkUnusableCode,
                                    message: "c11 won't use this machine's link: it doesn't check c11's hc and c11 couldn't update it. Update or Remove the machine in Settings > Herder Topography.",
                                    credential: credential)
                }
                if let refusal = standing(request, caller: verified, intended: intended, mode: mode) {
                    return .refused(code: refusal.code, message: refusal.message)
                }
                switch C11RelayPolicy.admit(request, caller: verified, identityTaken: identityTaken) {
                case .failure(let refusal): return .refused(code: refusal.code, message: refusal.message, credential: credential)
                case .success(let allowed): return .run(allowed, verified, credential: credential)
                }
            }
        }
    }

    /// c11's own record of the request's panel; `.unknown` for a malformed panel.
    private func intendedCreation(_ request: C11Relay.Request) async -> C11RelayCreationAnswer {
        guard let host, let panel = UUID(uuidString: request.panel) else { return .unknown }
        return await host.relayCurrentCreation(panel: panel)
    }

    /// After the MAC: the request was signed for this path (a slot or the
    /// spool), its credential's pickup was not left unclaimed, and c11's own
    /// records still make that creation the panel's current terminal on this
    /// machine, so a credential dies with its terminal whatever hc's labels
    /// say. Records that cannot be read just now do not refuse.
    private func standing(_ request: C11Relay.Request, caller: C11RelayPolicy.VerifiedCaller,
                          intended: C11RelayCreationAnswer, mode: C11Relay.Request.Mode) -> C11RelayPolicy.Refusal? {
        guard request.mode == mode, !pickups.isRevoked(creation: request.creation) else { return C11RelayPolicy.authRefusedRefusal }
        switch intended {
        case .live(let creation, let recordedMachine):
            guard creation == caller.creation, recordedMachine == nil || recordedMachine == caller.machine else {
                return C11RelayPolicy.authRefusedRefusal
            }
            return nil
        case .none: return C11RelayPolicy.authRefusedRefusal
        case .unknown: return nil
        }
    }

    /// C11H-365 (L10): `standing()`'s creation rule for an away-show record:
    /// the panel's current creation, by c11's own record, is the record's
    /// terminal on this machine. Records that cannot be read just now do not
    /// refuse; a panel with no live creation does.
    static func showRecordStands(_ intended: C11RelayCreationAnswer, creation: UUID?, machine: String) -> Bool {
        switch intended {
        case .live(let current, let recordedMachine):
            return creation == current && (recordedMachine == nil || recordedMachine == machine)
        case .none: return false
        case .unknown: return true
        }
    }

    /// An older relay kit's request: refused by compare-and-set (nothing
    /// runs) with what to do, and reported once on the Mac.
    private func refuseLegacy(machine: String, name: String, key: String, id: String, at: Int64,
                              panel: String, terminal: String, version: UInt64) async {
        guard let host else { return }
        let refusal = C11RelayPolicy.kitOutdatedRefusal
        if let written = try? await host.relayDocSet(machine: machine, name: name,
                                                     value: C11Relay.legacyRefusedValue(id: id, at: at, code: refusal.code,
                                                                                         message: refusal.message),
                                                     version: version) {
            lastSlotVersion[key] = written
            note("refused \(machine) \(name) \(refusal.code)")
            reportAuthRefusal(machine: machine, panel: panel, terminal: terminal, code: refusal.code)
            auditRelay(machine: machine, panel: "unverified", method: "", outcome: "refused", code: refusal.code, id: id)
        }
    }

    /// A claimed request refused after its wait: the slot moves from claimed
    /// to refused, which the CLI reads like any refusal. Nothing ran.
    private func refuseClaimed(machine: String, name: String, key: String, request: C11Relay.Request,
                               code: String, message: String, credential: Data?, version: UInt64,
                               snapshot: HCInventorySnapshot) async {
        claimMilliseconds.removeValue(forKey: key)
        defer { inFlight.remove(key) }
        guard let host else { return }
        if let written = try? await host.relayDocSet(machine: machine, name: name,
                                                     value: C11Relay.refusedValue(request, code: code, message: message,
                                                                                   key: credential),
                                                     version: version) {
            lastSlotVersion[key] = written
        }
        note("refused \(machine) \(name) \(code)")
        reportAuthRefusal(machine: machine, panel: request.panel, terminal: request.term, code: code)
        auditRefusal(request, machine: machine, code: code,
                     unverified: refusedBeforeAuthentication(request, machine: machine, snapshot: snapshot))
    }

    /// C11H-365 (L12): whether a refused request never passed verify and
    /// authenticate. Then nothing it names can be trusted, so its audit key
    /// holds only the machine, the outcome and the code.
    private func refusedBeforeAuthentication(_ request: C11Relay.Request, machine: String,
                                             snapshot: HCInventorySnapshot) -> Bool {
        guard case .success(let verified) = C11RelayPolicy.verify(request, machine: machine, snapshot: snapshot) else { return true }
        let link = keyring.secret(session: localSession, machine: machine)
        guard case .success = C11RelayPolicy.authenticate(request, caller: verified, session: localSession, link: link) else {
            return true
        }
        return false
    }

    /// A refused live call: by its panel and method once it was
    /// authenticated, else (C11H-365, L12) as `unverified` with no method.
    private func auditRefusal(_ request: C11Relay.Request, machine: String, code: String, unverified: Bool,
                              spooled: Bool = false) {
        auditRelay(machine: machine, panel: unverified ? "unverified" : request.panel,
                   method: unverified ? "" : C11RelayTrace.method(framing: request.framing, line: request.line),
                   outcome: "refused", code: code, id: request.id, spooled: spooled)
    }

    private func finish(machine: String, name: String, key: String, request: C11Relay.Request,
                        response: String, credential: Data, version: UInt64) async {
        let claimed = claimMilliseconds.removeValue(forKey: key) ?? nil
        defer { inFlight.remove(key); releaseWorker() }
        // It ran, whether or not the CLI was still waiting for the reply; an
        // error reply is audited as `error` with its code, never its text.
        let result = Self.auditOutcome(framing: request.framing, response: response)
        auditRelay(machine: machine, panel: request.panel, method: C11RelayTrace.method(framing: request.framing, line: request.line),
                   outcome: result.outcome, code: result.code, id: request.id)
        guard let host else { return }
        do {
            let written = try await host.relayDocSet(machine: machine, name: name,
                                                     value: C11Relay.doneValue(request, response: response, key: credential),
                                                     version: version)
            lastSlotVersion[key] = written
            // C11H-97: every served call is persisted, so "served empty" is
            // never confused with "never reached c11".
            note(C11RelayTrace.servedLine(machine: machine, slot: name, request: request, response: response,
                                           claimMilliseconds: claimed, late: false))
        } catch {
            // The CLI gave up after its reply deadline and freed the slot.
            note(C11RelayTrace.servedLine(machine: machine, slot: name, request: request, response: response,
                                           claimMilliseconds: claimed, late: true))
        }
    }

    // MARK: Spool

    private func drainSpool(machine: String, reason: String, attempt: Int = 0) async {
        guard let host, let executor else { return }
        // C11H-332: an unusable link's spool waits, unread, for its Update.
        if unusableMachines.contains(machine) {
            note("spool-held \(machine) \(reason) link_unusable")
            return
        }
        let value: Any?, version: UInt64
        do { (value, version) = try await host.relayDocGet(machine: machine, name: C11Relay.spoolName) }
        catch {
            // The link may be up before hc serves the remote document: try again, a few times.
            let next = attempt + 1
            note("spool-read-failed \(machine) \(reason) attempt=\(attempt)\(next < Self.maxDrainAttempts ? " retry" : "")")
            if next < Self.maxDrainAttempts { scheduleDrain(machine, reason: reason, attempt: next) }
            return
        }
        let raw = (value as? [String: Any])?["records"] as? [Any] ?? []
        guard !raw.isEmpty else { spoolWaitingForInventory.remove(machine); return }
        // Malformed entries are cleared with the rest and never applied.
        let records = C11Relay.spoolRecords(value)
        // Identity is checked against a ready inventory. While it is pending
        // the spool stays as it is, to be drained when the inventory is ready.
        let snapshot = await host.snapshot()
        guard case .ready = snapshot.readiness else {
            spoolWaitingForInventory.insert(machine)
            note("spool-waiting \(machine) \(reason) records=\(records.count)")
            return
        }
        spoolWaitingForInventory.remove(machine)
        // Claim every record at once; a conflict means a CLI appended
        // meanwhile, and its doc event drains again.
        do {
            _ = try await host.relayDocSet(machine: machine, name: C11Relay.spoolName, value: C11Relay.emptySpool, version: version)
        } catch C11RelayStoreError.conflict {
            // A CLI appended meanwhile; its doc event drains again.
            record("spool-conflict \(machine)")
            return
        } catch {
            let next = attempt + 1
            note("spool-claim-failed \(machine) \(reason) attempt=\(attempt)\(next < Self.maxDrainAttempts ? " retry" : "")")
            if next < Self.maxDrainAttempts { scheduleDrain(machine, reason: reason, attempt: next) }
            return
        }
        let origin = machineFacts[machine]?.host ?? machine
        let machines = Set(machineFacts.keys).union(connected)
        var applied = 0
        let now = wallMilliseconds()
        let link = keyring.secret(session: localSession, machine: machine)
        var toApply: [(C11RelayPolicy.Admitted, C11RelayPolicy.VerifiedCaller, key: String, id: String, panel: String,
                       method: String, framing: C11Relay.Framing)] = []
        var seen = Set<String>()
        // C11H-332: every record dropped here is refused, and audited as a
        // spooled refusal with its code. One skipped as a copy already
        // applied, or already seen in this drain, is a retransmission: no line.
        for record in records {
            let request = record.request
            var caller: C11RelayPolicy.VerifiedCaller
            switch C11RelayPolicy.verify(request, machine: machine, snapshot: snapshot) {
            case .failure(let refusal):
                auditSpoolRefusal(request, machine: machine, code: refusal.code, unverified: true)
                continue
            case .success(let verified): caller = verified
            }
            guard C11Relay.isSpoolable(framing: request.framing, line: request.line) else {
                auditSpoolRefusal(request, machine: machine, code: Self.notSpoolableCode, unverified: true)
                continue
            }
            caller.workspace = workspaceOf(caller.panel)
            // C11H-176: signed by the terminal's credential for the spool, its
            // terminal still current, under a day old, and not applied before
            // for that terminal (the ids are kept on disk, across restarts).
            switch C11RelayPolicy.authenticate(request, caller: caller, session: localSession, link: link) {
            case .failure(let refusal):
                reportAuthRefusal(machine: machine, panel: request.panel, terminal: request.term, code: refusal.code)
                auditSpoolRefusal(request, machine: machine, code: refusal.code, unverified: true)
                continue
            case .success:
                caller.link = link.map { C11RelayLinkRef(session: localSession, machine: machine, linkID: $0.id) }
            }
            let intended = await intendedCreation(request)
            let key = C11RelaySpoolMarks.key(machine: machine, panel: request.panel, creation: request.creation)
            if let refusal = standing(request, caller: caller, intended: intended, mode: .spool) {
                auditSpoolRefusal(request, machine: machine, code: refusal.code)
                continue
            }
            // Overflow-safe: `at` is the far end's number.
            let age = now.subtractingReportingOverflow(request.at)
            guard !age.overflow, age.partialValue.magnitude <= C11RelayAuth.spoolMaxAgeMilliseconds.magnitude else {
                auditSpoolRefusal(request, machine: machine, code: Self.spoolExpiredCode)
                continue
            }
            guard seen.insert(request.id).inserted, !spoolMarks.isApplied(key: key, id: request.id) else { continue }
            switch C11RelayPolicy.admit(request, caller: caller, identityTaken: identityTaken) {
            case .failure(let refusal):
                auditSpoolRefusal(request, machine: machine, code: refusal.code)
            case .success(let admitted):
                toApply.append((admitted, caller, key, request.id, request.panel,
                                C11RelayTrace.method(framing: request.framing, line: request.line), request.framing))
            }
        }
        let running = Set(snapshot.records.values.compactMap { record -> String? in
            guard record.machineName == machine, record.state == .running,
                  let panel = record.labels["c11.panel"], let creation = record.labels["c11.creation"] else { return nil }
            return C11RelaySpoolMarks.key(machine: machine, panel: panel, creation: creation)
        })
        // Recorded before anything runs: a crash mid-drain loses telemetry, never repeats it.
        if !toApply.isEmpty {
            spoolMarks.recordApplied(toApply.map { ($0.key, $0.id) }, machine: machine, running: running, now: now)
        }
        for (admitted, caller, _, id, panel, method, framing) in toApply {
            let response = await executor.execute(admitted, caller: caller, originHost: origin, machines: machines, snapshot: snapshot)
            let result = Self.auditOutcome(framing: framing, response: response)
            auditRelay(machine: machine, panel: panel, method: method, outcome: result.outcome, code: result.code,
                       id: id, spooled: true)
            applied += 1
        }
        note("spool \(machine) \(reason) applied=\(applied) of=\(records.count)")
    }

    // MARK: Workers

    private func acquireWorker() async {
        if running < Self.maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseWorker() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    /// C11H-332: one relayed call, served or refused, for the audit: the
    /// machine, the caller's panel (a UUID, else `invalid` or `unverified`),
    /// the method (a plain token), the outcome and its code, and the request
    /// id (a UUID). Never the call's parameters or reply. The first call of a
    /// key in a minute is written at once; the rest are folded into the
    /// key's summary line (`AuditFold`).
    private func auditRelay(machine: String, panel: String, method: String, outcome: String, code: String? = nil,
                            id: String? = nil, spooled: Bool = false) {
        var panelID = panel == "unverified" ? panel : (UUID(uuidString: panel)?.uuidString ?? "invalid")
        var token = String(method.lowercased().filter { $0.isLetter || $0.isNumber || "._-".contains($0) }.prefix(64))
        var code = code
        let requestID: String? = id.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        var key = [machine, panelID, token, outcome, code ?? ""].joined(separator: "\u{0}")
        let now = wallMilliseconds()
        // C11H-365 (L12): a refused call's key this machine has not opened this
        // minute counts toward its cap; past the cap the call folds into the
        // capped key. Calls that ran keep their own keys (see `foldKeysOpened`).
        let open = auditFolds[key].map { fold in now - fold.started < 0 || now - fold.started >= Self.auditFoldMilliseconds } ?? true
        if open, outcome == "refused" {
            var window = foldKeysOpened[machine] ?? (now, 0)
            if now - window.started < 0 || now - window.started >= Self.auditFoldMilliseconds { window = (now, 0) }
            if window.count >= Self.auditFoldKeysPerMinute {
                panelID = "unverified"; token = ""; code = Self.auditFoldCappedCode
                key = [machine, panelID, token, outcome, code ?? ""].joined(separator: "\u{0}")
            } else {
                window.count += 1
            }
            foldKeysOpened[machine] = window
        }
        if var fold = auditFolds[key] {
            let retransmitted = requestID.map { fold.seen.contains($0) } ?? false
            // A wall clock set back ends the minute too, rather than stretching it.
            let elapsed = now - fold.started
            if elapsed >= 0, elapsed < Self.auditFoldMilliseconds {
                guard !retransmitted else { return }
                fold.count += 1
                if let requestID {
                    if fold.ids.count < Self.auditFoldIDs { fold.ids.append(requestID) }
                    if fold.seen.count < Self.auditFoldSeenLimit { fold.seen.insert(requestID) }
                }
                auditFolds[key] = fold
                return
            }
            // The key's minute is over: its summary first, then this call opens the next.
            auditFolds.removeValue(forKey: key)
            writeAuditSummary(fold)
            if retransmitted { return }
        }
        if auditFolds.count >= Self.auditFoldLimit { flushAuditFolds(all: true) }
        let methodField: String? = token.isEmpty ? nil : token
        audit.record(C11AuditRecord(kind: .relay, via: "relay", outcome: outcome, machine: machine, session: localSession,
                                    panel: panelID, method: methodField, code: code,
                                    detail: spooled ? "spooled while the link was down" : nil,
                                    ids: requestID.map { [$0] }))
        auditFolds[key] = AuditFold(machine: machine, panel: panelID, method: methodField, outcome: outcome, code: code,
                                    started: now, seen: requestID.map { Set([$0]) } ?? [])
    }

    /// A spool record dropped before it ran: a refused, spooled call.
    private func auditSpoolRefusal(_ request: C11Relay.Request, machine: String, code: String, unverified: Bool = false) {
        auditRefusal(request, machine: machine, code: code, unverified: unverified, spooled: true)
    }

    /// A fold's summary: how many more calls of its key came within its
    /// minute, and up to five of their ids. Nothing when none came.
    private func writeAuditSummary(_ fold: AuditFold) {
        guard fold.count > 0 else { return }
        audit.record(C11AuditRecord(kind: .relay, via: "relay", outcome: fold.outcome, machine: fold.machine,
                                    session: localSession, panel: fold.panel, method: fold.method, code: fold.code,
                                    detail: "folded within a minute of the first", count: fold.count,
                                    ids: fold.ids.isEmpty ? nil : fold.ids))
    }

    /// Ends every fold whose minute is over (every fold when `all`), each
    /// with its summary.
    private func flushAuditFolds(all: Bool = false) {
        guard !auditFolds.isEmpty else { return }
        let now = wallMilliseconds()
        for key in auditFolds.keys.sorted() {
            guard let fold = auditFolds[key],
                  all || now - fold.started >= Self.auditFoldMilliseconds || now < fold.started else { continue }
            auditFolds.removeValue(forKey: key)
            writeAuditSummary(fold)
        }
    }

    /// C11H-332: what an executor's reply says of the call, for the audit:
    /// `ok`, or `error` with the reply's own error code when that is a plain
    /// code, else the word `error`. A v2 reply is an error when its `ok` is
    /// false; a v1 reply when it starts with `ERROR`, and its code is the
    /// snake_case word of the `ERROR: code: message` form. Nothing else of
    /// the reply is kept.
    static func auditOutcome(framing: C11Relay.Framing, response: String) -> (outcome: String, code: String?) {
        switch framing {
        case .json:
            guard response.contains("false"),
                  let object = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any],
                  let ok = object["ok"] as? Bool, !ok else { return ("ok", nil) }
            let code = (object["error"] as? [String: Any])?["code"] as? String
            let plain: String? = code.flatMap { $0.range(of: C11AuditRecord.tokenPattern, options: .regularExpression) == nil ? nil : $0 }
            return ("error", plain ?? "error")
        case .text:
            guard response.hasPrefix("ERROR") else { return ("ok", nil) }
            let rest = response.dropFirst("ERROR".count).drop(while: { $0 == ":" || $0 == " " })
            guard let colon = rest.firstIndex(of: ":") else { return ("error", "error") }
            let word = String(rest[..<colon])
            let isCode = word.utf8.count <= 64 && word.range(of: #"^[a-z][a-z0-9]*(_[a-z0-9]+)+$"#, options: .regularExpression) != nil
            return ("error", isCode ? word : "error")
        }
    }

    private func record(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// A rare relay event (spool, refusal): kept in `log`, and written where an
    /// operator or the guest kit reads it.
    private func note(_ line: String) {
        record(line)
        C11RelayLog.event(line)
    }
}

final class C11RelayCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func decrement() { lock.lock(); count -= 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Relay env for terminals launched on another machine, from that machine's
/// manifest. Read when a remote panel is created; written by the relay
/// service when the machine connects.
final class C11RelayEnvironment: @unchecked Sendable {
    static let shared = C11RelayEnvironment()
    private struct Route: Hashable { let session: String; let machine: String }
    private let lock = NSLock()
    private var manifests: [Route: C11Relay.Manifest] = [:]

    /// C11H-78: keyed by (local session, machine). Every shard's link to
    /// one machine (`studio`) has that machine's name; each has its own manifest.
    func set(_ manifest: C11Relay.Manifest?, for machine: String, session: String = HCAtlasLink.releaseSession) {
        lock.lock(); manifests[Route(session: session, machine: machine)] = manifest; lock.unlock()
    }

    /// The seam ticket 12's `placed(...)` calls for a remote launch.
    static func forMachine(_ machine: String, session: String? = nil) -> [String: String] {
        shared.environment(for: machine, session: session)
    }

    /// Empty when no relay is installed there (the panel then has no relay
    /// `c11`). With no session named, only an unambiguous route answers: two
    /// shards linked to the machine give nothing rather than the wrong one.
    func environment(for machine: String, session: String? = nil) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let session { return manifests[Route(session: session, machine: machine)]?.terminalEnvironment ?? [:] }
        let matches = manifests.filter { $0.key.machine == machine }
        guard matches.count == 1 else { return [:] }
        return matches.first?.value.terminalEnvironment ?? [:]
    }
}

/// The relay services by local session, made on first use.
final class C11RelayServices: @unchecked Sendable {
    static let shared = C11RelayServices()
    private let lock = NSLock()
    private var services: [String: C11RelayService] = [:]

    /// Every local session that serves a relay. C11H-391: removing a
    /// session's link revokes that machine's secret in that session only,
    /// never in the others listed here.
    var sessions: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(services.keys)
    }

    func service(for session: String) -> C11RelayService {
        lock.lock(); defer { lock.unlock() }
        if let existing = services[session] { return existing }
        let made = C11RelayService(localSession: session, keyring: C11RelayKeyring.shared,
                                    spoolMarks: C11RelaySpoolMarks.shared(session: session),
                                    pickups: C11RelayPickupLedger.shared(session: session),
                                    onAuthRefused: { machine, panel, terminal, code in
            HCDiagnosticRecorder.shared.recordRelayRefused(machine: machine, panel: panel, terminal: terminal, code: code)
        })
        services[session] = made
        return made
    }
}

enum C11RelayLog {
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.relay")

    static func trustLine(machine: String, host: String, session: String, manifest: String) -> String {
        "hc.relay up machine=\(machine) host=\(host) session=\(session) manifest=\(manifest) trust=per_terminal_credential: only a c11 terminal's signed calls are served, as its own panel; a process of this user on \(host) that reads a c11 terminal's environment or types into it through hc can still act as that terminal (Settled 9)"
    }

    static func trust(machine: String, host: String, session: String, manifest: String) {
        let line = trustLine(machine: machine, host: host, session: session, manifest: manifest)
        logger.info("\(line, privacy: .public)")
        append(line)
    }

    /// One relay event line (`hc.relay <event>`), logged the same way.
    static func event(_ line: String) {
        logger.notice("hc.relay \(line, privacy: .public)")
        append("hc.relay " + line)
        Sink.shared.emit("hc.relay " + line)
    }

    /// C11H-97: a test's view of exactly what `event` persists (the unified
    /// log itself can't be read back in a test). Nil outside tests.
    final class Sink: @unchecked Sendable {
        static let shared = Sink()
        private let lock = NSLock()
        private var capture: ((String) -> Void)?
        func set(_ handler: ((String) -> Void)?) { lock.lock(); capture = handler; lock.unlock() }
        fileprivate func emit(_ line: String) {
            lock.lock(); let handler = capture; lock.unlock()
            handler?(line)
        }
    }

    // The guest kit and an operator's C11_DEBUG_LOG read the same lines.
    // Internal so the pairing log (`hc.pair`, C11H-78) lands in the same file.
    static func append(_ line: String) {
        if let path = ProcessInfo.processInfo.environment["C11_DEBUG_LOG"], !path.isEmpty,
           let data = (line + "\n").data(using: .utf8) {
            // Never appends through a planted link (C11H-364 L21).
            C11UserRuntime.appendLog(data, to: path)
        }
    }
}
