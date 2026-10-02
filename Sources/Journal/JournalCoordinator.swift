import Foundation

/// Bridges immutable target facts and the existing exact conversation identity to disk.
/// The socket worker waits for storage, never for the main actor or a UI repaint.
final class JournalCoordinator: @unchecked Sendable {
    static let shared = JournalCoordinator()
    private let lock = NSLock()
    private let startupQueue = DispatchQueue(label: "com.stage11.c11.journal-startup", qos: .utility)
    private var owners: [UUID: JournalOwner] = [:]
    private var targets: [UUID: UUID] = [:]
    private var snapshots: [UUID: JournalSnapshot] = [:]
    private var store: JournalStore?
    private var storageError: JournalError?
    private var started = false
    private var seedReady = false
    private var tabsReady = false
    private var drainStarted = false
    private var sink: (@Sendable (UUID, JournalSnapshot?, JournalMailboxBoundary?, UUID?) -> Void)?

    init(store: JournalStore? = nil) {
        self.store = store
    }

    func register(tabID: UUID, workspaceID: UUID) {
        lock.lock(); let changed = targets[tabID] != workspaceID; targets[tabID] = workspaceID; lock.unlock()
        if changed { refreshOwners([tabID]) }
    }
    func remove(tabID: UUID) {
        lock.lock()
        targets.removeValue(forKey: tabID)
        let hadProjection = snapshots.removeValue(forKey: tabID) != nil
        let callback = sink
        lock.unlock()
        // A removed tab is a real close. The sink queues its own work and does not wait on UI.
        if hadProjection { callback?(tabID, nil, nil, nil) }
    }
    /// Called synchronously by the existing conversation actor after a real identity change.
    /// Snapshot readers never wait on that actor, including the typing/notification paths.
    func setOwner(tabID: UUID, owner: JournalOwner?) {
        lock.lock()
        guard owners[tabID] != owner else { lock.unlock(); return }
        owners[tabID] = owner
        let hadProjection = snapshots.removeValue(forKey: tabID) != nil
        let callback = sink
        lock.unlock()
        if hadProjection { callback?(tabID, nil, nil, nil) }
        if let owner, owner.agentKind == "codex" {
            registerCodexHookGap(owner)
        }
        refreshOwners([tabID])
    }

    /// Codex currently has only the root `notify` completion rail. Record that
    /// bounded provider gap only after ConversationStore has established an
    /// exact causal owner; a wrapper claim or a sessionless observer must not
    /// create a live projection. The control event changes health only and is
    /// intentionally kept off the actor, socket and typing paths.
    private func registerCodexHookGap(_ owner: JournalOwner) {
        startupQueue.async { [self] in
            guard isEligible(owner), let workspaceID = target(tabID: owner.tabID) else { return }
            var draft = JournalDraft(
                kind: .stateChanged,
                emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                tabID: owner.tabID,
                workspaceID: workspaceID,
                sessionID: owner.sessionID,
                agentKind: owner.agentKind,
                source: .c11,
                adapter: .c11,
                nativeEvent: "adapter_gap"
            )
            draft.signal = .adapterGap
            _ = try? append(draft)
        }
    }
    func refreshOwners(_ tabIDs: [UUID]? = nil) {
        lock.lock(); let ids = tabIDs ?? Array(targets.keys); let ready = started; lock.unlock()
        guard ready, !ids.isEmpty else { return }
        startupQueue.async { [self] in
            guard let store = try? storage() else { return }
            for id in ids {
                guard let owner = exactOwner(tabID: id), let baseline = try? store.current(owner: owner) else { continue }
                publish(baseline.appInstanceID == store.instanceID ? baseline : JournalReplayPolicy.restored(baseline))
            }
        }
    }
    func snapshot(tabID: UUID) -> JournalSnapshot? {
        lock.lock(); defer { lock.unlock() }; return snapshots[tabID]
    }
    func target(tabID: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }; return targets[tabID]
    }
    func health() -> JournalError? {
        lock.lock(); defer { lock.unlock() }; return storageError
    }

    func runtimeStatus() throws -> [String: Any] {
        let store = try storage()
        let coverage = try store.coverage()
        return ["writer_instance_id": store.instanceID.uuidString,
                "first_available_sequence": coverage.first,
                "high_water_sequence": coverage.highWater,
                "last_observation_ms": coverage.lastObservation,
                "health": health()?.rawValue ?? "ok"]
    }

    func clear() throws {
        try startupQueue.sync {
            try storage().clear()
        }
        lock.lock()
        let tabIDs = Array(snapshots.keys)
        snapshots.removeAll()
        storageError = nil
        let callback = sink
        lock.unlock()
        for tabID in tabIDs { callback?(tabID, nil, nil, nil) }
    }

    /// Existing metadata readback can expose this value without consulting SQLite.
    func readback(tabID: UUID, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [String: Any] {
        lock.lock(); let state = snapshots[tabID]; let error = storageError; lock.unlock()
        guard let state else {
            return ["phase": "unknown", "health": error == nil ? "ok" : "degraded",
                    "connection": "unknown", "confirmation": "unconfirmed", "coverage": "unavailable",
                    "error_code": error?.rawValue as Any? ?? NSNull()]
        }
        return [
            "phase": state.phase.rawValue, "reason": state.reason?.rawValue as Any? ?? NSNull(),
            "turn_outcome": state.turnOutcome as Any? ?? NSNull(),
            "source": state.source.rawValue, "confidence_rank": state.rank,
            "since_ms": state.sinceMs, "observed_at_ms": state.observedAtMs, "sequence": state.lastSequence,
            "confirmation": state.confirmation.rawValue, "connection": state.connection.rawValue,
            "health": error == nil ? state.health.rawValue : "degraded",
            "freshness": state.isFresh(at: now) ? "fresh" : "stale",
            "coverage": state.isHistorical ? "historical" : (state.timingUncertain ? "timing_uncertain" : "observed"),
            "error_code": error?.rawValue as Any? ?? NSNull()
        ]
    }
    func start(onProjection: @escaping @Sendable (UUID, JournalSnapshot?, JournalMailboxBoundary?, UUID?) -> Void) {
        lock.lock()
        sink = onProjection
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        startupQueue.async { [self] in
            do {
                let store = try storage()
                for baseline in try store.baselines() {
                    if isEligible(baseline.owner) {
                        publish(baseline.appInstanceID == store.instanceID ? baseline : JournalReplayPolicy.restored(baseline))
                    }
                }
                beginDrainIfReady()
            } catch { setError(error) }
        }
    }

    func startupSeedReady() { lock.lock(); seedReady = true; lock.unlock(); beginDrainIfReady() }
    func startupTabsReady() { lock.lock(); tabsReady = true; lock.unlock(); beginDrainIfReady() }
    private func beginDrainIfReady() {
        lock.lock()
        guard started, seedReady, tabsReady, !drainStarted else { lock.unlock(); return }
        drainStarted = true
        lock.unlock()
        startupQueue.async { [self] in
            do { drain(store: try storage(), first: true) } catch { setError(error) }
        }
    }

    // A single lock protects lazy initialization; no UI code takes this path.
    private let openLock = NSLock()
    private func storage() throws -> JournalStore {
        openLock.lock(); defer { openLock.unlock() }
        lock.lock(); let existing = store; lock.unlock()
        if let existing { return existing }
        let layout = try JournalStorageLayout.resolve(bundleID: Bundle.main.bundleIdentifier)
        let created = try JournalStore(layout: layout)
        lock.lock(); store = created; storageError = nil; lock.unlock()
        return created
    }

    func isEligible(_ owner: JournalOwner) -> Bool { exactOwner(tabID: owner.tabID) == owner }
    func exactOwner(tabID: UUID) -> JournalOwner? {
        lock.lock(); defer { lock.unlock() }
        return targets[tabID] == nil ? nil : owners[tabID]
    }

    func append(_ draft: JournalDraft, historical: Bool = false, interactivePID: Int32? = nil) throws -> JournalAppendResult {
        try append(draft, historical: historical, interactivePID: interactivePID, transcriptClockEvidence: false)
    }

    /// Transcript observations arrive only from the bounded in-process reader,
    /// which assigns the registered adapter version after parsing native time.
    func appendTranscript(_ draft: JournalDraft) throws -> JournalAppendResult {
        try append(draft, historical: false, interactivePID: nil, transcriptClockEvidence: true)
    }

    private func append(
        _ draft: JournalDraft,
        historical: Bool,
        interactivePID: Int32?,
        transcriptClockEvidence: Bool
    ) throws -> JournalAppendResult {
        do {
            let eligible = draft.owner.map { isEligible($0) && target(tabID: $0.tabID) == draft.workspaceID } ?? false
            let model = draft.tabID.flatMap { tabID in target(tabID: tabID).flatMap { workspaceID in
                TabMetadataStore.shared.metadataValue(workspaceId: workspaceID, surfaceId: tabID, key: MetadataKey.model) as? String
            } }.flatMap { value in
                !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
                } ? value : nil
            }
            let context = transcriptClockEvidence
                ? JournalContext.forTranscriptAppend(draft: draft, eligible: eligible,
                                                     historical: historical, modelID: model)
                : JournalContext.forAppend(draft: draft, eligible: eligible,
                                           historical: historical, modelID: model)
            let result = try storage().append(
                draft: draft,
                context: context
            )
            if let changed = result.changedSnapshot {
                let boundary = JournalMailboxBoundary.make(draft: draft, result: result, historical: historical, pid: interactivePID)
                let opensAsk = [JournalKind.questionRequested, .planReviewRequested, .approvalRequested].contains(draft.kind)
                let eventID = opensAsk && !historical && !result.receipt.replayed && result.receipt.projectionEffect == .applied
                    ? result.receipt.eventID : nil
                // Publish before the receipt returns. The display note follows this receipt on the
                // same caller, and a queued publish drops that note. The sink only enqueues its own
                // work; this does not wait on the UI.
                publish(changed, boundary: boundary, eventID: eventID)
            }
            lock.lock(); storageError = nil; lock.unlock()
            return result
        } catch { setError(error); throw error }
    }

    private func publish(_ value: JournalSnapshot, boundary: JournalMailboxBoundary? = nil, eventID: UUID? = nil) {
        lock.lock()
        guard targets[value.owner.tabID] != nil, owners[value.owner.tabID] == value.owner else { lock.unlock(); return }
        let old = snapshots[value.owner.tabID]
        guard old?.owner != value.owner || (old?.lastSequence ?? -1) <= value.lastSequence else { lock.unlock(); return }
        snapshots[value.owner.tabID] = value
        let callback = sink
        lock.unlock()
        callback?(value.owner.tabID, value, boundary, eventID)
    }

    private func drain(store: JournalStore, first: Bool) {
        let counts = autoreleasepool {
            JournalSpool(layout: store.layout).drain(limit: first ? 1000 : 100, durationMs: first ? 2000 : 200,
                now: Int64(Date().timeIntervalSince1970 * 1000)) { [self] draft in
                    _ = try append(draft, historical: true)
                }
        }
        if counts.remaining {
            startupQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in drain(store: store, first: false) }
        }
    }
    private func setError(_ error: Error) {
        let code = (error as? JournalError) ?? .unavailable
        guard [.busy, .full, .unavailable, .unsupportedVersion].contains(code) else { return }
        lock.lock()
        storageError = code
        let degraded = snapshots.values.map { value -> JournalSnapshot in
            var copy = value; copy.health = .degraded; return copy
        }
        for value in degraded { snapshots[value.owner.tabID] = value }
        let callback = sink
        lock.unlock()
        for value in degraded { callback?(value.owner.tabID, value, nil, nil) }
    }
}

struct JournalMailboxBoundary: Sendable {
    let working: Bool
    let pid: Int32?
    let at: Date
    static func make(draft: JournalDraft, result: JournalAppendResult, historical: Bool, pid: Int32?) -> Self? {
        guard !historical, !result.receipt.replayed, result.receipt.projectionEffect == .applied,
              !draft.isChild, [.hook, .plugin].contains(draft.source),
              let state = result.changedSnapshot, state.confirmation == .confirmed,
              (draft.kind == .turnStarted && state.phase == .working)
                || (draft.kind == .turnCompleted && state.phase == .idle) else { return nil }
        return Self(working: state.phase == .working, pid: pid,
                    at: Date(timeIntervalSince1970: Double(result.receipt.committedAtMs) / 1000))
    }
}
