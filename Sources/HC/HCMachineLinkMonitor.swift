import Combine
import Foundation

/// An inventory that can take a machine.list result between subscriptions.
protocol HCMachineRouteSink: Sendable {
    func applyMachines(_ value: HCJSONValue) async
}

/// Ticket 12: hc reports a machine's line only through `machine.list`. This
/// polls it off-main while c11's session is connected: every 2 s while any
/// machine is added (so a dropped remote line turns its panels Reconnecting
/// within that bound and their input is refused, not silently dropped), every
/// 10 s otherwise (to notice a machine added later). It never starts a core,
/// never touches main, and stops with the session.
actor HCMachineLinkMonitor {
    static let activeInterval: TimeInterval = 2
    static let idleInterval: TimeInterval = 10

    typealias Poll = @Sendable () async -> [String: HCMachineAvailability]?
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let poll: Poll
    private let sleep: Sleep
    private var task: Task<Void, Never>?

    init(poll: @escaping Poll,
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.poll = poll
        self.sleep = sleep
    }

    static func interval(after machines: [String: HCMachineAvailability]?) -> TimeInterval {
        (machines?.isEmpty ?? true) ? idleInterval : activeInterval
    }

    func start() {
        guard task == nil else { return }
        let poll = poll, sleep = sleep
        task = Task.detached(priority: .utility) {
            var machines: [String: HCMachineAvailability]?
            while !Task.isCancelled {
                // Poll first: machines added before activation are watched
                // at the active interval from the start.
                machines = await poll()
                do { try await sleep(Self.interval(after: machines)) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    var isRunning: Bool { task != nil }
}

extension HCManagedSession {
    /// The production monitor for this session.
    nonisolated func makeLinkMonitor() -> HCMachineLinkMonitor {
        HCMachineLinkMonitor(poll: { [weak self] in
            // C11H-332: the via's refused dials reach the audit log through
            // its one writer, off main, only when link-ssh.log has changed.
            C11AuditLog.shared.ingestLinkLogSoon()
            return await self?.pollMachines()
        })
    }
}

/// C11H-391: which session's link a new terminal on a machine uses. An app
/// that adopted c11h's sessions runs them beside its own links session `L`
/// (`HCShardID.links`), and one machine name can be linked in both: c11h's
/// old link, which c11 won't use, and the one Add Machine made in `L`.
/// Usable wins: a name is refused for new terminals only when the link the
/// creation would use is unusable, and that link is unusable only when no
/// session links the name usably. The `--on` preflight, the machine picker,
/// the File menu, a saved agent config and the pool's `creationTarget` all
/// decide with this one rule.
enum HCMachineRouting {
    struct Link: Equatable, Sendable {
        let shard: HCShardID
        let session: String
        let availability: HCMachineAvailability
        let usable: Bool
    }

    /// The link a new terminal on `machine` (hc's exact name) uses, or nil
    /// when no session links it:
    /// 1. the links session's, when it is usable;
    /// 2. else the lowest shard's (shard 0's hand-made link), when usable;
    /// 3. else any other session's usable link;
    /// 4. else the lowest shard's, unusable (refused up front).
    /// C11H-396: a session that takes no new terminals (a read-only pool
    /// shard) is never a usable route: its link counts as unusable here, so
    /// the preflight never admits a name only such a session links usably.
    /// `HCShardPool.creationTarget` sends a creation to the routed usable
    /// link whenever its own choice doesn't link the machine usably.
    static func route(_ machine: String, sessions: [HCSessionMachines],
                      unusable: [String: Set<String>]) -> Link? {
        func link(_ entry: HCSessionMachines) -> Link? {
            guard let availability = entry.machines[machine] else { return nil }
            return Link(shard: entry.shard, session: entry.session, availability: availability,
                        usable: entry.takesCreations && !(unusable[entry.session]?.contains(machine) ?? false))
        }
        let links = sessions.filter { $0.shard.isLinks }.compactMap(link)
        if let first = links.first, first.usable { return first }
        let others = sessions.filter { !$0.shard.isLinks }.sorted { $0.shard < $1.shard }.compactMap(link)
        if let first = others.first, first.usable { return first }
        if let usable = others.first(where: \.usable) { return usable }
        return others.first ?? links.first
    }

    /// Every linked name's routed link.
    static func view(sessions: [HCSessionMachines], unusable: [String: Set<String>]) -> [String: Link] {
        let names = Set(sessions.flatMap { $0.machines.keys })
        var view: [String: Link] = [:]
        for name in names { view[name] = route(name, sessions: sessions, unusable: unusable) }
        return view
    }
}

/// C11H-391: what `--on`, the picker and the menus see of the linked machines:
/// each name's line and whether c11 will open a terminal through it, both
/// from the link routing picks (`HCMachineRouting`).
struct HCMachineLinkView: Equatable, Sendable {
    var machines: [String: HCMachineAvailability]
    var unusable: Set<String>

    /// A merged pool snapshot is routed per name; a single session's snapshot
    /// (no session list) is that session's own machines, with every session's
    /// unusable names applied.
    static func of(_ snapshot: HCInventorySnapshot, unusableBySession: [String: Set<String>]) -> HCMachineLinkView {
        guard !snapshot.sessionMachines.isEmpty else {
            return HCMachineLinkView(machines: snapshot.machines,
                                     unusable: unusableBySession.values.reduce(into: Set<String>()) { $0.formUnion($1) })
        }
        let routed = HCMachineRouting.view(sessions: snapshot.sessionMachines, unusable: unusableBySession)
        return HCMachineLinkView(machines: routed.mapValues(\.availability),
                                 unusable: Set(routed.filter { !$0.value.usable }.keys))
    }
}

/// Ticket 12: the machines the File menu offers, from the session's inventory.
/// Main-actor state fed by the session's coalesced observer; menus read it.
@MainActor
final class HCMachineDirectory: ObservableObject {
    static let shared = HCMachineDirectory()

    struct Entry: Equatable, Identifiable {
        let machine: String
        let connected: Bool
        /// C11H-274: false when c11 won't use its stored link; listed, never offered.
        var usable: Bool = true
        var id: String { machine }
        var title: String {
            String(format: String(localized: "menu.file.newTerminalOnMachine", defaultValue: "New Terminal on %@"),
                   HCMachineTarget.displayName(machine))
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// C11H-359: machines a session's inventory refused, by roster id, with
    /// the reason. Never offered for new terminals; Settings shows them with Remove.
    @Published private(set) var refused: [String: HCMachineRefusal] = [:]
    private var refusedBySession: [String: [String: HCMachineRefusal]] = [:]
    /// C11H-274: machines whose stored link c11 won't use (`HCStoredLinks`
    /// unusable), by hc machine name. Listed with that reason and never
    /// offered for a new terminal. C11H-391: routed, not a union: a name is
    /// here only when the link a new terminal there would use is unusable, so
    /// a usable link of the same name in another session wins.
    @Published private(set) var unusable: Set<String> = []
    private var unusableBySession: [String: Set<String>] = [:]
    /// C11H-391 (NB6): each session's newest publish; an older one is dropped.
    private var unusableGenerations: [String: UInt64] = [:]
    private var lastSnapshot: HCInventorySnapshot?
    private var observation: HCObservation?

    /// Tests: forget every session's set (and the socket worker's copy).
    func clearUnusable() {
        unusableBySession = [:]
        unusableGenerations = [:]
        HCLinkedMachines.shared.setUnusable(bySession: [:])
        unusable = []
    }

    /// `generation` orders one session's publishes: two overlapping stored-link
    /// reviews can arrive out of order, and only the newest one counts.
    func setUnusable(_ machines: Set<String>, session: String, generation: UInt64? = nil) {
        if let generation {
            if let newest = unusableGenerations[session], generation < newest { return }
            unusableGenerations[session] = generation
        }
        unusableBySession[session] = machines.isEmpty ? nil : machines
        HCLinkedMachines.shared.setUnusable(bySession: unusableBySession)
        if let lastSnapshot { publish(lastSnapshot) }
        else {
            let merged = unusableBySession.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            if merged != unusable { unusable = merged }
        }
    }

    /// The unusable names of each session, as the stored-link reviews published them.
    var unusableSessions: [String: Set<String>] { unusableBySession }

    func setRefused(_ machines: [String: HCMachineRefusal], session: String) {
        refusedBySession[session] = machines.isEmpty ? nil : machines
        var merged: [String: HCMachineRefusal] = [:]
        for (_, byName) in refusedBySession.sorted(by: { $0.key < $1.key }) {
            for (name, reason) in byName {
                guard let id = MachineRoster.normalizedID(name) else { continue }
                merged[id] = merged[id] ?? reason
            }
        }
        if merged != refused { refused = merged }
    }

    func follow(_ session: any HCSession) {
        observation?.cancel()
        observation = session.observe(on: .main) { [weak self] snapshot in
            MainActor.assumeIsolated { self?.apply(snapshot) }
        }
    }

    func apply(_ snapshot: HCInventorySnapshot) {
        // A pending inventory keeps the last list rather than flickering empty.
        guard case .ready = snapshot.readiness else { return }
        lastSnapshot = snapshot
        publish(snapshot)
    }

    /// C11H-391: each name once, from the link a new terminal there uses.
    private func publish(_ snapshot: HCInventorySnapshot) {
        let view = HCMachineLinkView.of(snapshot, unusableBySession: unusableBySession)
        if view.unusable != unusable { unusable = view.unusable }
        let next = Self.entries(view.machines, unusable: view.unusable)
        if next != entries { entries = next }
        HCLinkedMachines.shared.update(view.machines)
        HCLinkedMachines.shared.updateSessions(snapshot.sessionMachines)
    }

    static func entries(_ machines: [String: HCMachineAvailability], unusable: Set<String> = []) -> [Entry] {
        machines.keys.sorted().map { Entry(machine: $0, connected: machines[$0] == .connected, usable: !unusable.contains($0)) }
    }

    /// C11H-391: every session that links `machine` (exact name), in shard
    /// order: Settings' rows and Remove choose among them.
    func links(of machine: String) -> [HCMachineRouting.Link] {
        guard let lastSnapshot else { return [] }
        return lastSnapshot.sessionMachines.sorted { $0.shard < $1.shard }.compactMap { entry in
            entry.machines[machine].map {
                HCMachineRouting.Link(shard: entry.shard, session: entry.session, availability: $0,
                                      usable: !(unusableBySession[entry.session]?.contains(machine) ?? false))
            }
        }
    }
}

/// C11H-126: the machines hc has linked, readable from any thread (the
/// socket worker's `machine.list`). Fed by `HCMachineDirectory.apply`.
final class HCLinkedMachines: @unchecked Sendable {
    static let shared = HCLinkedMachines()

    private let lock = NSLock()
    private var machines: [String: Bool]?
    private var unusableBySession: [String: Set<String>] = [:]
    private var sessions: [HCSessionMachines] = []
    private var starting: Set<String> = []

    /// C11H-396: the names the links session lists (its `machines.json`)
    /// while it starts. Set when an adopted app composes it; cleared by its
    /// first report (`updateSessions`) or a failed start.
    func setStartingLinks(_ names: Set<String>) {
        lock.lock()
        starting = names
        lock.unlock()
    }

    func startingLinks() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return starting
    }

    /// C11H-274, C11H-391: each session's unusable names, fed by
    /// `HCMachineDirectory.setUnusable`; the socket worker's `--on` check and
    /// the pool's routing read them.
    func setUnusable(bySession value: [String: Set<String>]) {
        lock.lock()
        unusableBySession = value
        lock.unlock()
    }

    func unusableSessions() -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return unusableBySession
    }

    /// Every session's unusable names together (a single session's view).
    func unusable() -> Set<String> {
        unusableSessions().values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// C11H-391: each session's own machine lines, from the merged inventory.
    /// C11H-396: the links session's first report ends its start.
    func updateSessions(_ value: [HCSessionMachines]) {
        lock.lock()
        sessions = value
        if value.contains(where: { $0.shard.isLinks }) { starting = [] }
        lock.unlock()
    }

    func sessionMachines() -> [HCSessionMachines] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    func update(_ value: [String: HCMachineAvailability]) {
        lock.lock()
        machines = value.mapValues { $0 == .connected }
        lock.unlock()
    }

    /// Machine name to connected, or nil before hc's inventory was first ready.
    func snapshot() -> [String: Bool]? {
        lock.lock()
        defer { lock.unlock() }
        return machines
    }
}

/// Ticket 12 (T12.7): hc discards DATA relayed into a machine whose line is
/// down (remote.rs), and the poll that notices runs only every few seconds.
/// A remote terminal's channel therefore confirms the line with the local
/// core before each DATA write: keys, paste and programmatic input alike. A
/// down line refuses the write before a byte is sent (`.unavailable`, shown
/// as "not sent while this terminal reconnects"). Controls pass through.
/// Writes stay ordered: the input coordinator drains raw input one at a time.
final class HCRemoteLinkChannel: HCChannel, @unchecked Sendable {
    /// Local IPC to the core that owns the line; generous, never retried.
    static let confirmSeconds: TimeInterval = 1
    private let base: any HCChannel
    private let lineUp: @Sendable () async -> Bool

    init(base: any HCChannel, lineUp: @escaping @Sendable () async -> Bool) {
        self.base = base
        self.lineUp = lineUp
    }

    var channelID: UInt32 { base.channelID }
    var connectionGeneration: UInt64 { base.connectionGeneration }
    func activate() async throws { try await base.activate() }
    func close() { base.close() }
    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int) -> HCReservationOutcome {
        base.reserve(operationID: operationID, attachmentGeneration: attachmentGeneration, encodedByteCount: encodedByteCount)
    }
    func write(_ batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        let carriesInput = batch.frames.contains {
            switch $0 {
            case .data, .submitReturn, .submitReturnAfter: return true
            case .resize, .focus, .facts: return false
            }
        }
        guard carriesInput else { return await base.write(batch, reservation: reservation) }
        guard await lineUp() else {
            base.cancel(reservation)
            return .refused(.unavailable)
        }
        return await base.write(batch, reservation: reservation)
    }
    func cancel(_ reservation: HCWriteReservation) { base.cancel(reservation) }
    func control(_ control: HCControl) async -> HCControlOutcome { await base.control(control) }
}
