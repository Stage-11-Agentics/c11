import Foundation

/// Why an hc session is being ended. Only explicit operator/CLI closes reach
/// this type: restore retirement, native surface disposal, cross-window moves
/// and application Quit detach and never construct an origin.
enum HCEndOrigin: String, Codable, Sendable {
    case panelClose
    case areaClose
    case workspaceClose
    case windowClose
    /// An operator "end all" over several workspaces or windows (C11H-5).
    case endAll
}

/// C11H-417: an owed end began or stopped being held by a c11 app that carries
/// its terminal's token. `held` is reported once per end, however it got there
/// (a fresh close, a late hold after a reconnect, a record restored at launch);
/// `released` when that end settles.
enum HCCarrierHoldChange: Equatable, Sendable {
    case held(UUID)
    case released(UUID)
}

/// What an explicit close did to one panel's hc terminal, as far as the
/// backend has proved it. `pending` is never a claim that the processes died.
enum HCPanelEndOutcome: Equatable, Sendable {
    /// The backend reported the terminal ended (confirmed end, or a later
    /// authoritative resolve said ended/absent).
    case ended
    /// The terminal had already ended before the close asked.
    case alreadyEnded
    /// Authoritatively nothing to end (no record and no pending creation).
    case none
    /// The end was requested but not yet confirmed; the coordinator keeps the
    /// identity and finishes it on a later ready inventory revision.
    case pending(HCUnavailableReason?)
    /// C11H-46: refused. Another live panel still shows this terminal, so
    /// closing this one detached it and the terminal kept running.
    /// C11H-103: names that panel when the app could say which it is.
    case kept(HCEndHolder?)

    var wireName: String {
        switch self {
        case .kept: return "kept"
        case .ended: return "ended"
        case .alreadyEnded: return "already_ended"
        case .none: return "none"
        case .pending: return "pending"
        }
    }

    var isSettled: Bool {
        if case .pending = self { return false }
        return true
    }
}

/// C11H-103: the live panel that still shows a terminal a close asked to end,
/// so the refusal can name it (ref, title, workspace).
struct HCEndHolder: Equatable, Sendable {
    let panelID: UUID
    /// `panel:N`, when the socket has minted one.
    let panelRef: String?
    let title: String
    let workspaceID: UUID
    let workspaceTitle: String

    var wire: [String: Any] {
        ["panel_id": panelID.uuidString, "panel_ref": panelRef ?? NSNull(), "title": title,
         "workspace_id": workspaceID.uuidString, "workspace_title": workspaceTitle]
    }
}

/// C11H-46/C11H-103: what the app says about a terminal's other holders.
enum HCHolderAnswer: Equatable, Sendable {
    /// The startup graph is not complete; an end waits.
    case unknown
    /// No other live panel shows it.
    case none
    /// This live panel shows it.
    case held(HCEndHolder)
}

/// One explicit end the app still owes. Persisted so a close that hc has not
/// yet confirmed survives an app restart and is finished, not recovered.
struct HCPendingEndRecord: Codable, Equatable, Sendable {
    let identity: HCPanelIdentity
    var key: HCTerminalKey?
    let origin: HCEndOrigin
}

protocol HCPendingEndStore: Sendable {
    func load() -> [HCPendingEndRecord]
    func save(_ records: [HCPendingEndRecord])
}

/// Atomic, private (0600) JSON file of the ends still owed, under the app's
/// own state root (`MailboxLayout.defaultStateURL`, which C11H-2 makes
/// c11's). Holds identities and keys only, never terminal content or
/// environment.
struct HCPendingEndFileStore: HCPendingEndStore {
    static let fileName = "hc-pending-ends.json"

    /// nil when the state root cannot be resolved: nothing is persisted and
    /// pending ends live only for this process.
    let url: URL?

    static func defaultURL() -> URL? {
        guard let state = try? MailboxLayout.defaultStateURL() else { return nil }
        return state
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    init(url: URL? = HCPendingEndFileStore.defaultURL()) {
        self.url = url
    }

    func load() -> [HCPendingEndRecord] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HCPendingEndRecord].self, from: data)) ?? []
    }

    func save(_ records: [HCPendingEndRecord]) {
        guard let url else { return }
        do {
            if records.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try PrivateFileWriter.write(data, to: url)
        } catch {
#if DEBUG
            NSLog("hc.end.store.saveFailed error=%@", String(describing: error))
#endif
        }
    }
}

/// Ends hc terminals for explicit closes, by exact key, and keeps every end the
/// backend has not confirmed until a later ready revision proves it.
///
/// Threading: every entry point is callable from main and returns without
/// waiting; state lives on a private serial queue and the backend calls run in
/// tasks whose results hop back onto it. Reads for other owners (Recovered
/// reconciliation) use a lock-protected published copy, so they never wait on
/// the queue or its disk writes.
final class HCExplicitEndCoordinator: @unchecked Sendable {
    private struct Entry {
        var record: HCPendingEndRecord
        var phase: Phase
        var inFlight = false
        /// Revision of the inventory snapshot current when the last attempt
        /// started; a retry needs a newer ready revision.
        var lastAttemptRevision: HCRevision?
        /// C11H-46: the last attempt could not tell whether another panel
        /// holds the key; a change in that answer retries without waiting
        /// for a new inventory revision.
        var awaitingHolders = false
        /// `holderGeneration` when the last attempt started.
        var attemptHolderGeneration: UInt64 = 0
        /// C11H-313: one of the panel's creations settled with no run while
        /// an attempt was in flight; retry when it completes.
        var settledDuringAttempt = false
        /// C11H-415: the live recheck of an end a c11 app holds; an older one is void.
        var carrierRecheck: UInt64 = 0
        /// C11H-417: when this end first became held (monotonic), and whether
        /// `held` was reported, so `released` follows exactly once.
        var heldSince: UInt64?
    }

    private enum Phase {
        /// End not yet accepted (lookup or end unresolved).
        case needsEnd(HCUnavailableReason?)
        /// Backend accepted the end; waiting for authoritative evidence.
        case awaitingEvidence(HCTerminalKey)
    }

    private enum AttemptResult {
        case settled(HCPanelEndOutcome)
        /// The holder lookup could not answer yet (startup graph incomplete).
        case awaitingHolders(HCTerminalKey)
        case needsEnd(key: HCTerminalKey?, reason: HCUnavailableReason?)
        case awaitingEvidence(HCTerminalKey)
    }

    private final class Waiter {
        let panelIDs: Set<UUID>
        let continuation: CheckedContinuation<[UUID: HCPanelEndOutcome], Never>
        init(panelIDs: Set<UUID>, continuation: CheckedContinuation<[UUID: HCPanelEndOutcome], Never>) {
            self.panelIDs = panelIDs
            self.continuation = continuation
        }
    }

    private let session: any HCSession
    private let store: any HCPendingEndStore
    /// C11H-46 backstop: true when a live panel other than the ones being
    /// closed is bound to this key, nil while the app cannot tell yet (its
    /// panels are not restored). Asked before every end a close requests.
    private let heldElsewhere: @Sendable (HCTerminalKey) async -> HCHolderAnswer
    private let queue: DispatchQueue
    private var entries: [UUID: Entry] = [:]
    private var settled: [UUID: HCPanelEndOutcome] = [:]
    private var settledOrder: [UUID] = []
    private var waiters: [UUID: Waiter] = [:]
    private var latestRevision: HCRevision?
    private var latestReady = false
    /// Bumped by `holdersChanged`; an attempt that started before a bump
    /// and could not tell retries at once.
    private var holderGeneration: UInt64 = 0
    private var observation: HCObservation?
    /// C11H-313: the session's creation channel, when it has one: closes
    /// decline their creations through it, and no-run settlements wake ends.
    private let settling: (any HCCreationSettling)?
    private var settlementObservation: HCObservation?
    /// C11H-417: the session's carrier releases.
    private var releaseObservation: HCObservation?

    private let publishedLock = NSLock()
    private var publishedPanelIDs: Set<UUID> = []
    private var publishedKeys: Set<HCTerminalKey> = []
    /// C11H-103: closes requested on the caller's thread and not yet entered
    /// on `queue`. A close removes its panel at once, and Recovered
    /// reconciliation can run in that gap; without these it saw a running
    /// terminal with no panel and re-created the closed panel in Recovered,
    /// whose end then refused as "kept" because of that very re-creation.
    private var requestedPanelIDs: Set<UUID> = []
    private var requestedKeys: Set<HCTerminalKey> = []

    private static let settledMemory = 256

    /// C11H-415: seconds between attempts of an end a c11 app holds. The app
    /// quitting changes nothing hc reports, so no inventory revision would
    /// wake the end; this does, on the coordinator's own queue.
    static let carrierRecheckSeconds: TimeInterval = 3
    /// C11H-417: after the first minute of a hold, the recheck slows to this.
    /// An older c11 app may stay open for days; each recheck scans the process table.
    static let carrierBackoffAfterSeconds: TimeInterval = 60
    static let carrierBackedOffSeconds: TimeInterval = 30
    private let carrierRecheckSeconds: TimeInterval
    private let carrierBackoffAfterSeconds: TimeInterval
    private let carrierBackedOffSeconds: TimeInterval
    /// C11H-417: told on the coordinator's queue when an end becomes or stops being held.
    private let onCarrierHold: (@Sendable (HCCarrierHoldChange) -> Void)?

    /// C11H-417: the wait before the next recheck of an end held `heldFor` seconds.
    static func carrierRecheckDelay(heldFor: TimeInterval, base: TimeInterval = carrierRecheckSeconds,
                                    backoffAfter: TimeInterval = carrierBackoffAfterSeconds,
                                    backedOff: TimeInterval = carrierBackedOffSeconds) -> TimeInterval {
        heldFor < backoffAfter ? base : max(base, backedOff)
    }

    init(session: any HCSession, store: any HCPendingEndStore,
         heldElsewhere: @escaping @Sendable (HCTerminalKey) async -> HCHolderAnswer = { _ in .none },
         queue: DispatchQueue = DispatchQueue(label: "c11.hc.explicit-end", qos: .userInitiated),
         carrierRecheckSeconds: TimeInterval = HCExplicitEndCoordinator.carrierRecheckSeconds,
         carrierBackoffAfterSeconds: TimeInterval = HCExplicitEndCoordinator.carrierBackoffAfterSeconds,
         carrierBackedOffSeconds: TimeInterval = HCExplicitEndCoordinator.carrierBackedOffSeconds,
         onCarrierHold: (@Sendable (HCCarrierHoldChange) -> Void)? = nil) {
        self.carrierRecheckSeconds = carrierRecheckSeconds
        self.carrierBackoffAfterSeconds = carrierBackoffAfterSeconds
        self.carrierBackedOffSeconds = carrierBackedOffSeconds
        self.onCarrierHold = onCarrierHold
        self.queue = queue
        self.session = session
        self.settling = session as? any HCCreationSettling
        self.store = store
        self.heldElsewhere = heldElsewhere
        // Ends owed from the previous run are visible before init returns, so
        // Recovered, which reads them without waiting right after install,
        // never resurrects a terminal the operator closed. One small file read
        // at install time; nothing else here touches disk.
        for record in store.load() where entries[record.identity.panelID] == nil {
            entries[record.identity.panelID] = Entry(record: record, phase: .needsEnd(nil))
        }
        publishLocked()
        // C11H-329: both subscriptions are made here, not on the queue. The
        // feed's first delivery (the session's current snapshot) is then queued
        // ahead of every attempt, including a close requested right after init;
        // an attempt that started before it recorded no real revision, and that
        // delivery then read as newer and started a second, redundant attempt.
        // C11H-313: a creation that settles with no run produces no hc event,
        // so no inventory revision: its settlement wakes the end. Subscribed
        // first, so one published while the first delivery's attempt is in
        // flight is never lost.
        settlementObservation = settling?.observeCreationSettlements(on: queue) { [weak self] panelID in
            self?.creationSettled(panelID)
        }
        observation = session.observe(on: queue) { [weak self] snapshot in
            self?.handleSnapshot(snapshot)
        }
        // C11H-417: a held end that goes ahead is no longer the app's, whatever
        // the kill then does: reported now, not when the end settles.
        releaseObservation = (session as? any HCCarrierReleaseReporting)?.observeCarrierReleases(on: queue) { [weak self] key in
            self?.carrierReleased(key)
        }
        queue.async { [self] in
            for panelID in entries.keys { attempt(panelID) }
        }
    }

    deinit {
        observation?.cancel()
        settlementObservation?.cancel()
        releaseObservation?.cancel()
    }

    // MARK: - Public API

    /// Request explicit ends. Returns immediately; outcomes arrive through
    /// `outcomes(for:timeout:)`. A panel already being ended is not ended twice.
    func requestEnd(_ identities: [HCPanelIdentity], origin: HCEndOrigin) {
        guard !identities.isEmpty else { return }
        // C11H-103: pending from this moment, before the queue hop.
        let ids = Set(identities.map(\.panelID))
        let keys = Set(identities.compactMap(\.key))
        // C11H-313: every creation of a closing panel that has not claimed yet
        // declines to start: the one it carries and any other under way (a
        // reveal's start queued behind a hidden one's). Here, before the queue
        // hop, so it lands before the close's own cancel, in the same turn.
        for identity in identities {
            settling?.declineCreations(panelID: identity.panelID, carrying: identity.creationID)
        }
        publishedLock.lock()
        requestedPanelIDs.formUnion(ids)
        requestedKeys.formUnion(keys)
        publishedLock.unlock()
        queue.async { [self] in
            defer {
                // Entered (or already pending): the published sets carry them now.
                publishedLock.lock()
                requestedPanelIDs.subtract(ids)
                requestedKeys.subtract(keys)
                publishedLock.unlock()
            }
            var changed = false
            for identity in identities {
                let panelID = identity.panelID
                guard entries[panelID] == nil else { continue }
                forgetSettled(panelID)
                let record = HCPendingEndRecord(identity: identity, key: identity.key, origin: origin)
                entries[panelID] = Entry(record: record, phase: .needsEnd(nil))
                changed = true
            }
            if changed { persistAndPublish() }
            for identity in identities { attempt(identity.panelID) }
        }
    }

    /// Wait (never on main's behalf: callers are socket workers or tasks) until
    /// each panel's end settles or `timeout` passes, then report what is known.
    /// A panel the coordinator never saw reports `.none`.
    func outcomes(for panelIDs: [UUID], timeout: TimeInterval) async -> [UUID: HCPanelEndOutcome] {
        let ids = Set(panelIDs)
        guard !ids.isEmpty else { return [:] }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let waiter = Waiter(panelIDs: ids, continuation: continuation)
                if allSettled(waiter) {
                    continuation.resume(returning: currentOutcomes(ids))
                    return
                }
                waiters[token] = waiter
                queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                    self?.finishWaiter(token)
                }
            }
        }
    }

    /// C11H-46: the holder lookup's answer may have changed (the app's
    /// startup graph completed). Ends that were waiting on it retry now, at
    /// the current inventory revision.
    func holdersChanged() {
        queue.async { [self] in
            holderGeneration &+= 1
            for (panelID, var entry) in entries where entry.awaitingHolders && !entry.inFlight {
                entry.awaitingHolders = false
                entry.lastAttemptRevision = nil
                entries[panelID] = entry
                attempt(panelID)
            }
        }
    }

    /// True while an explicit close of this panel is owed but unconfirmed.
    /// Recovered reconciliation must not resurrect such a terminal.
    func isEndPending(panelID: UUID) -> Bool {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedPanelIDs.contains(panelID) || requestedPanelIDs.contains(panelID)
    }

    func pendingEndPanelIDs() -> Set<UUID> {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedPanelIDs.union(requestedPanelIDs)
    }

    func pendingEndKeys() -> Set<HCTerminalKey> {
        publishedLock.lock()
        defer { publishedLock.unlock() }
        return publishedKeys.union(requestedKeys)
    }

    // MARK: - Queue-confined machinery

    /// C11H-313: a creation of this panel was recorded as never run. Retry its
    /// end now, at the current revision; one in flight retries as it completes.
    private func creationSettled(_ panelID: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var entry = entries[panelID] else { return }
        if entry.inFlight {
            entry.settledDuringAttempt = true
            entries[panelID] = entry
            return
        }
        entry.lastAttemptRevision = nil
        entries[panelID] = entry
        attempt(panelID)
    }

    private func handleSnapshot(_ snapshot: HCInventorySnapshot) {
        dispatchPrecondition(condition: .onQueue(queue))
        latestRevision = snapshot.revision
        if case .ready = snapshot.readiness { latestReady = true } else { latestReady = false }
        guard latestReady else { return }
        for panelID in entries.keys { attempt(panelID) }
    }

    /// Start one attempt for a panel unless one is in flight or nothing new
    /// has happened since the last one (retries need a newer ready revision).
    private func attempt(_ panelID: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var entry = entries[panelID], !entry.inFlight else { return }
        if let last = entry.lastAttemptRevision {
            guard latestReady, let latest = latestRevision, latest != last else { return }
        }
        entry.inFlight = true
        entry.awaitingHolders = false
        entry.settledDuringAttempt = false
        entry.attemptHolderGeneration = holderGeneration
        entry.lastAttemptRevision = latestRevision ?? HCRevision(connectionGeneration: 0, sequence: 0)
        let phase = entry.phase
        let record = entry.record
        entries[panelID] = entry
        let session = self.session
        let settling = self.settling
        let heldElsewhere = self.heldElsewhere
        Task { [weak self] in
            let result = await Self.run(phase: phase, record: record, session: session, settling: settling,
                                        heldElsewhere: heldElsewhere)
            self?.queue.async { self?.complete(panelID, result: result) }
        }
    }

    private static func run(
        phase: Phase,
        record: HCPendingEndRecord,
        session: any HCSession,
        settling: (any HCCreationSettling)?,
        heldElsewhere: @Sendable (HCTerminalKey) async -> HCHolderAnswer
    ) async -> AttemptResult {
        switch phase {
        case .awaitingEvidence(let key):
            return await confirmEvidence(key: key, record: record, session: session)
        case .needsEnd:
            let key: HCTerminalKey
            if let known = record.key {
                // C11H-313: durable evidence first. A replacement recorded as never
                // run, over the ended terminal whose key the close still carries,
                // needs no fresh lookup of that key, which a catch-up, a lost core
                // or a record hc already dropped would keep from answering.
                if let requested = record.identity.creationID, let settling,
                   let proof = await settling.recordedNeverRun(HCPanelIdentity(panelID: record.identity.panelID,
                        key: known, persistence: record.identity.persistence, creationID: requested,
                        origin: record.identity.origin)),
                   proof.creationID == requested {
                    return .settled(.ended)
                }
                key = known
            } else {
                switch await session.resolve(record.identity) {
                case .live(let terminal):
                    key = terminal.key
                case .new:
                    return .settled(.none)
                case .ended:
                    return .settled(.alreadyEnded)
                case .unresolved(_, let reason):
                    return .needsEnd(key: nil, reason: reason)
                }
            }
            // C11H-46: closing one panel never ends a terminal another live
            // panel shows. End All ends every terminal by design.
            if record.origin != .endAll {
                switch await heldElsewhere(key) {
                case .unknown: return .awaitingHolders(key)
                case .none: break
                case .held(let holder):
                    NSLog("hc.end.refused reason=key_shown_by_live_panel panel=%@ core=%@ terminal=%@ origin=%@ held_by=%@ held_by_workspace=%@",
                          record.identity.panelID.uuidString, key.owningCoreID, key.localAddress, record.origin.rawValue,
                          holder.panelID.uuidString, holder.workspaceID.uuidString)
                    return .settled(.kept(holder))
                }
            }
            switch await session.end(key) {
            case .confirmed(let evidence):
                return await followCurrentCreation(record: record, ended: key, evidence: evidence, session: session,
                                                   heldElsewhere: heldElsewhere)
            case .pending(let pendingKey):
                return .awaitingEvidence(pendingKey)
            case .unresolved(let unresolvedKey, let reason):
                return .needsEnd(key: unresolvedKey, reason: reason)
            }
        }
    }

    /// C11H-308: a panel replacing a terminal that already finished keeps the
    /// old key while its new creation runs, so ending that key ends nothing
    /// live. The close then follows the creation it was asked to end, by its
    /// creationID and never the old key: the panel's live terminal is ended once
    /// listed (that creation's, or one that ran ahead of it), and
    /// the end settles only on evidence about that creation (it ended, or was
    /// rejected with no run). An earlier creation's end, or a lookup that cannot
    /// answer yet (still unclaimed, unlisted, resnapshotting, a lost link),
    /// keeps the end open; the creation runs to its own answer and its events
    /// wake the end. When the key just ended was that creation's, it settles at once.
    private static func followCurrentCreation(
        record: HCPendingEndRecord,
        ended key: HCTerminalKey,
        evidence: HCEndEvidence,
        session: any HCSession,
        heldElsewhere: @Sendable (HCTerminalKey) async -> HCHolderAnswer
    ) async -> AttemptResult {
        guard let requested = record.identity.creationID, evidence.creationID != requested else { return .settled(.ended) }
        let current = HCPanelIdentity(panelID: record.identity.panelID, persistence: record.identity.persistence,
                                      creationID: requested, origin: record.identity.origin)
        let resolved = await session.resolve(current)
        // A live terminal the resolver gives for this panel is its current one: the requested
        // creation's, or one that ran ahead of it (C11H-313: a reveal's start queued behind a
        // hidden start's creation, which claimed before the close). Either way the close ends it.
        if case .live(let terminal) = resolved, terminal.key != key,
           terminal.labels["c11.panel"]?.lowercased() == record.identity.panelID.uuidString.lowercased() {
            if record.origin != .endAll {
                switch await heldElsewhere(terminal.key) {
                case .unknown: return .awaitingHolders(terminal.key)
                case .none: break
                case .held(let holder): return .settled(.kept(holder))
                }
            }
            switch await session.end(terminal.key) {
            case .confirmed: return .settled(.ended)
            case .pending(let pendingKey): return .awaitingEvidence(pendingKey)
            case .unresolved(let unresolvedKey, let reason): return .needsEnd(key: unresolvedKey, reason: reason)
            }
        }
        switch resolved {
        case .ended(let proof) where proof.creationID == requested:
            return .settled(.ended)
        case .unresolved(_, let reason):
            return .needsEnd(key: key, reason: reason)
        default:
            // Evidence about another creation: the requested one is still to come.
            return .needsEnd(key: key, reason: .creationPending)
        }
    }

    /// The backend's resolver decides whether the accepted end has happened;
    /// acceptance alone never does.
    private static func confirmEvidence(
        key: HCTerminalKey,
        record: HCPendingEndRecord,
        session: any HCSession
    ) async -> AttemptResult {
        let identity = HCPanelIdentity(
            panelID: record.identity.panelID,
            key: key,
            persistence: record.identity.persistence,
            creationID: record.identity.creationID,
            origin: record.identity.origin
        )
        switch await session.resolve(identity) {
        case .ended, .new:
            return .settled(.ended)
        case .live, .unresolved:
            return .awaitingEvidence(key)
        }
    }

    private func complete(_ panelID: UUID, result: AttemptResult) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var entry = entries[panelID] else { return }
        entry.inFlight = false
        switch result {
        case .settled(let outcome):
            entries.removeValue(forKey: panelID)
            if entry.heldSince != nil { onCarrierHold?(.released(panelID)) }
            remember(panelID, outcome)
            persistAndPublish()
            notifyWaiters()
            return
        case .awaitingHolders(let key):
            entry.phase = .needsEnd(.inventoryPending)
            if entry.record.key != key {
                entry.record.key = key
                entries[panelID] = entry
                persistAndPublish()
            }
            if entry.attemptHolderGeneration != holderGeneration {
                // The answer changed while this attempt ran: ask again now.
                entry.lastAttemptRevision = nil
                entries[panelID] = entry
                notifyWaiters()
                attempt(panelID)
                return
            }
            entry.awaitingHolders = true
        case .needsEnd(let key, let reason):
            if let key, entry.record.key != key {
                entry.record.key = key
                entries[panelID] = entry
                persistAndPublish()
            }
            entry.phase = .needsEnd(reason)
            if reason == .appCarriesScope {
                // C11H-417: reported once, however the end came to be held.
                if entry.heldSince == nil {
                    entry.heldSince = HCMonotonic.now
                    onCarrierHold?(.held(panelID))
                }
                // C11H-415: its own wake-up; a later result replaces it.
                entry.carrierRecheck &+= 1
                let heldFor = Double(HCMonotonic.now &- (entry.heldSince ?? HCMonotonic.now)) / 1_000_000_000
                scheduleCarrierRecheck(panelID, generation: entry.carrierRecheck,
                    after: Self.carrierRecheckDelay(heldFor: heldFor, base: carrierRecheckSeconds,
                                                    backoffAfter: carrierBackoffAfterSeconds,
                                                    backedOff: carrierBackedOffSeconds))
            }
        case .awaitingEvidence(let key):
            let keyChanged = entry.record.key != key
            entry.record.key = key
            entry.phase = .awaitingEvidence(key)
            entries[panelID] = entry
            if keyChanged { persistAndPublish() }
        }
        entries[panelID] = entry
        notifyWaiters()
        // C11H-313: a no-run settlement arrived while this attempt was in flight.
        if entry.settledDuringAttempt {
            entry.settledDuringAttempt = false
            entry.lastAttemptRevision = nil
            entries[panelID] = entry
            attempt(panelID)
            return
        }
        // A ready revision may have arrived while this attempt was in flight.
        if latestReady, let latest = latestRevision, latest != entry.lastAttemptRevision {
            attempt(panelID)
        }
    }

    /// C11H-417: the session let this key's held end go ahead.
    private func carrierReleased(_ key: HCTerminalKey) {
        dispatchPrecondition(condition: .onQueue(queue))
        for (panelID, var entry) in entries where entry.heldSince != nil && entry.record.key == key {
            entry.heldSince = nil
            entries[panelID] = entry
            onCarrierHold?(.released(panelID))
        }
    }

    /// C11H-415: attempts an end a c11 app holds again after
    /// `carrierRecheckSeconds`, whatever hc reports meanwhile. Void once the end
    /// settles, moves on, or a newer result schedules its own. A record restored
    /// at launch gets one the same way, from its first attempt's result.
    private func scheduleCarrierRecheck(_ panelID: UUID, generation: UInt64, after delay: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(queue))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, var entry = self.entries[panelID], entry.carrierRecheck == generation,
                  case .needsEnd(.appCarriesScope?) = entry.phase else { return }
            entry.lastAttemptRevision = nil
            self.entries[panelID] = entry
            self.attempt(panelID)
        }
    }

    private func outcome(for panelID: UUID) -> HCPanelEndOutcome {
        if let entry = entries[panelID] {
            switch entry.phase {
            case .needsEnd(let reason): return .pending(reason)
            case .awaitingEvidence: return .pending(nil)
            }
        }
        return settled[panelID] ?? .none
    }

    private func currentOutcomes(_ ids: Set<UUID>) -> [UUID: HCPanelEndOutcome] {
        var result: [UUID: HCPanelEndOutcome] = [:]
        for id in ids { result[id] = outcome(for: id) }
        return result
    }

    private func allSettled(_ waiter: Waiter) -> Bool {
        waiter.panelIDs.allSatisfy { entries[$0] == nil }
    }

    private func notifyWaiters() {
        for (token, waiter) in waiters where allSettled(waiter) {
            finishWaiter(token)
        }
    }

    private func finishWaiter(_ token: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(returning: currentOutcomes(waiter.panelIDs))
    }

    private func remember(_ panelID: UUID, _ outcome: HCPanelEndOutcome) {
        forgetSettled(panelID)
        settled[panelID] = outcome
        settledOrder.append(panelID)
        if settledOrder.count > Self.settledMemory {
            let dropped = settledOrder.removeFirst()
            settled.removeValue(forKey: dropped)
        }
    }

    private func forgetSettled(_ panelID: UUID) {
        guard settled.removeValue(forKey: panelID) != nil else { return }
        settledOrder.removeAll { $0 == panelID }
    }

    private func persistAndPublish() {
        dispatchPrecondition(condition: .onQueue(queue))
        store.save(entries.values.map(\.record).sorted { $0.identity.panelID.uuidString < $1.identity.panelID.uuidString })
        publishLocked()
    }

    private func publishLocked() {
        let ids = Set(entries.keys)
        let keys = Set(entries.values.compactMap(\.record.key))
        publishedLock.lock()
        publishedPanelIDs = ids
        publishedKeys = keys
        publishedLock.unlock()
    }
}

/// C11H-46: which terminals a panel holds, as pure decisions the app and the
/// tests share.
enum HCLiveBinding {
    /// Every key a panel is bound to: its identity's, its live record's, and
    /// the one restore seeded for it before its session registered.
    static func boundKeys(identityKey: HCTerminalKey?, lifecycle: HCLifecycle?,
                          restoredKey: HCTerminalKey?) -> Set<HCTerminalKey> {
        var keys = Set([identityKey, restoredKey].compactMap { $0 })
        switch lifecycle {
        case .live(let record): keys.insert(record.key)
        case .unresolved(let identity, _): if let key = identity.key { keys.insert(key) }
        case .ended, .new, .none: break
        }
        return keys
    }

    /// A panel still shows `key` when it is bound to it, its terminal has not
    /// ended, and it is not itself being closed.
    static func shows(_ key: HCTerminalKey, boundKeys: Set<HCTerminalKey>, lifecycle: HCLifecycle?,
                      closing: Bool) -> Bool {
        guard !closing, boundKeys.contains(key) else { return false }
        if case .ended = lifecycle { return false }
        return true
    }
}

/// Composition point. The hc backend composition (ticket 2C) installs the
/// live session at launch, before any hc panel exists; until then the
/// unavailable runtime answers and no panel has an hc identity to end.
/// Panel identity comes from ticket 3A's lifecycle projection through
/// `identityLookup`; nil means the panel is exec/fallback and is not hc's.
enum HCSessionEnd {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed: HCExplicitEndCoordinator?
    private nonisolated(unsafe) static var lookup: @Sendable (UUID) -> HCPanelIdentity? = { _ in nil }

    /// C11H-46: whether a live panel the app shows, other than ones being
    /// closed, is bound to this key. nil until the app's startup graph is
    /// complete, so an end owed from the last run waits for restored panels.
    @MainActor static var keyShownByLivePanel: (HCTerminalKey) -> HCHolderAnswer = { _ in .unknown } {
        didSet { coordinator?.holdersChanged() }
    }

    static func install(session: any HCSession, store: any HCPendingEndStore = HCPendingEndFileStore()) {
        let coordinator = HCExplicitEndCoordinator(session: session, store: store, heldElsewhere: { key in
            await MainActor.run { HCSessionEnd.keyShownByLivePanel(key) }
        }, onCarrierHold: { change in
            // C11H-417: the notice follows the hold itself, never a close's report window.
            DispatchQueue.main.async { MainActor.assumeIsolated { HCHeldEndNotices.shared.apply(change) } }
        })
        lock.lock()
        installed = coordinator
        lock.unlock()
    }

    /// The installed coordinator, if the backend composed one.
    static var coordinator: HCExplicitEndCoordinator? {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    static func setIdentityLookup(_ provider: @escaping @Sendable (UUID) -> HCPanelIdentity?) {
        lock.lock()
        lookup = provider
        lock.unlock()
    }

    static func identity(forPanel panelID: UUID) -> HCPanelIdentity? {
        lock.lock()
        let provider = lookup
        lock.unlock()
        return provider(panelID)
    }

    /// Registers explicit end on a backend composition: activation installs
    /// the coordinator, and startup recovery reads its pending ends (which
    /// the coordinator publishes before `install` returns) so a panel whose
    /// end is still pending is never recovered as an orphan.
    @MainActor
    static func compose(
        into composition: HCBackendComposition,
        store: @escaping () -> any HCPendingEndStore = { HCPendingEndFileStore() }
    ) {
        composition.installSessionEnd = { session in
            install(session: session, store: store())
        }
        HCRecoveredTerminalController.pendingEndPanelIDs = {
            coordinator?.pendingEndPanelIDs() ?? []
        }
        HCRecoveredTerminalController.pendingEndKeys = {
            coordinator?.pendingEndKeys() ?? []
        }
    }

#if DEBUG
    static func resetForTesting() {
        lock.lock()
        installed = nil
        lookup = { _ in nil }
        lock.unlock()
    }
#endif
}

extension HCSessionEnd {
    /// Blocking wait for socket workers. Never call on main: the wait is up
    /// to `timeout` seconds. Without an installed coordinator every panel
    /// reports `.none`.
    static func waitForOutcomes(panelIds requested: [UUID], timeout: TimeInterval) -> [UUID: HCPanelEndOutcome] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        // A caller may name a panel twice; every outcome map below is keyed
        // by panel, so repeats collapse here rather than trap.
        let panelIds = uniquePanelIds(requested)
        guard let coordinator = coordinator else {
            return uniformOutcomes(panelIds, .none)
        }
        let box = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = await coordinator.outcomes(for: panelIds, timeout: timeout)
            semaphore.signal()
        }
        // The coordinator answers by its own deadline; the extra second only
        // guards a stalled task scheduler.
        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            return uniformOutcomes(panelIds, .pending(.deadlineExceeded))
        }
        return box.value ?? [:]
    }

    /// Request order kept, repeats dropped.
    static func uniquePanelIds(_ panelIds: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return panelIds.filter { seen.insert($0).inserted }
    }

    /// One outcome for every panel; safe for repeated ids.
    static func uniformOutcomes(_ panelIds: [UUID], _ outcome: HCPanelEndOutcome) -> [UUID: HCPanelEndOutcome] {
        Dictionary(panelIds.map { ($0, outcome) }, uniquingKeysWith: { first, _ in first })
    }

    /// Socket payload rows, in request order.
    static func wireOutcomes(panelIds: [UUID], outcomes: [UUID: HCPanelEndOutcome]) -> [[String: Any]] {
        panelIds.map { panelId in
            let outcome = outcomes[panelId] ?? .none
            var row: [String: Any] = [
                "panel_id": panelId.uuidString,
                "outcome": outcome.wireName,
                "message": HCCloseCopy.endOutcomeMessage(outcome)
            ]
            if case .pending(let reason) = outcome, let reason { row["reason"] = reason.rawValue }
            if case .kept(let holder?) = outcome { row["held_by"] = holder.wire }
            return row
        }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UUID: HCPanelEndOutcome]?
        var value: [UUID: HCPanelEndOutcome]? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}

/// `panel.clear_history` fields for the non-durable branch (X.4: none).
enum HCClearHistoryResult {
    static func fields(isHCTerminal: Bool) -> [String: Any] {
        guard isHCTerminal else { return [:] }
        return [
            "history_durable": false,
            "history_returns_after_restart": true,
            "warning": HCCloseCopy.clearHistoryNotDurable
        ]
    }
}
