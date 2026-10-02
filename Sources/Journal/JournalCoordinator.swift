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
    private var turnStartedMs: [UUID: Int64] = [:]
    private var openAsks: [UUID: JournalOpenAsk] = [:]
    private var responseGate = OperatorResponseGate()
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
        turnStartedMs.removeValue(forKey: tabID)
        openAsks.removeValue(forKey: tabID)
        responseGate.clear(tab: tabID)
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
        turnStartedMs.removeValue(forKey: tabID)
        openAsks.removeValue(forKey: tabID)
        responseGate.clear(tab: tabID)
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
                let attached = baseline.appInstanceID == store.instanceID ? baseline : JournalReplayPolicy.restored(baseline)
                publish(attached)
                try? hydrateCaches(store: store, snapshot: attached)
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
                try cacheClocks(store)
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
            rememberApplied(draft: draft, result: result)
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
            if !historical, !result.receipt.replayed {
                emitLifecycle(draft: draft, result: result)
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
    func cachedTurnStartedMs(tabID: UUID) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return turnStartedMs[tabID]
    }

    func registeredTargets() -> [UUID: UUID] {
        lock.lock(); defer { lock.unlock() }
        return targets
    }

    /// One lock lookup. Draft building happens on the startup queue, never here.
    func noteOperatorSubmit(tabID: UUID, keyCode: UInt16, modifierRaw: UInt, isRepeat: Bool, synthesizing: Bool, hasMarkedText: Bool) {
        lock.lock()
        guard let ask = openAsks[tabID] else { lock.unlock(); return }
        let accepted = AgentRoster.isOperatorSubmit(
            keyCode: keyCode, modifierRaw: modifierRaw, isRepeat: isRepeat,
            synthesizing: synthesizing, hasMarkedText: hasMarkedText,
            requiresPickerCommit: ask.requiresPickerCommit,
            pickerKeyCode: ask.pickerKeyCode, pickerModifierRaw: ask.pickerModifierRaw)
        guard accepted, responseGate.begin(tab: tabID, ask: ask.eventID) else { lock.unlock(); return }
        let captured = ask
        lock.unlock()
        startupQueue.async { [self] in enqueueResponse(tabID: tabID, ask: captured) }
    }

    func noteTextBoxSubmit(tabID: UUID) {
        lock.lock()
        guard let ask = openAsks[tabID], responseGate.begin(tab: tabID, ask: ask.eventID) else { lock.unlock(); return }
        let captured = ask
        lock.unlock()
        startupQueue.async { [self] in enqueueResponse(tabID: tabID, ask: captured) }
    }

    func rosterDocument(live: [AgentRoster.LiveTab], now: Int64) -> [String: Any] {
        do {
            let store = try storage()
            let currents = try store.listCurrent().map { row in
                row.appInstanceID == store.instanceID ? row : JournalReplayPolicy.restored(row)
            }
            let unattributed = try store.unattributedCount()
            let coverage = try store.coverage()
            var events: [String: [AgentRoster.RetainedEvent]] = [:]
            var truncated: Set<String> = []
            for row in currents where row.isHistorical {
                let page = try store.retainedOwnerEvents(
                    owner: row.owner, throughSequence: row.lastSequence, limit: AgentRoster.restoreLimit)
                events[row.owner.key] = page.events
                if page.truncated { truncated.insert(row.owner.key) }
            }
            return AgentRoster.document(
                live: live, currents: currents, eventsByOwner: events, truncatedOwners: truncated,
                unattributed: unattributed, storePruned: coverage.first > 1, storageAvailable: true,
                healthDegraded: health() != nil, now: now, liveIdentity: "available")
        } catch {
            return AgentRoster.document(
                live: live, currents: [], eventsByOwner: [:], truncatedOwners: [],
                unattributed: 0, storePruned: false, storageAvailable: false,
                healthDegraded: true, now: now, liveIdentity: "available")
        }
    }

    private func enqueueResponse(tabID: UUID, ask: JournalOpenAsk) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let draft = JournalDraft(
            kind: .stateChanged, emittedAtMs: now, tabID: ask.owner.tabID, workspaceID: ask.workspaceID,
            sessionID: ask.owner.sessionID, agentKind: ask.owner.agentKind, source: .c11, adapter: .c11,
            nativeEvent: "operator_response", requestID: ask.requestID ?? ask.eventID.uuidString, signal: .operatorResponse)
        do {
            _ = try append(draft)
            lock.lock(); responseGate.succeed(tab: tabID, ask: ask.eventID); lock.unlock()
        } catch {
            lock.lock(); responseGate.fail(tab: tabID, ask: ask.eventID); lock.unlock()
        }
    }

    private func emitLifecycle(draft: JournalDraft, result: JournalAppendResult) {
        guard let tab = draft.tabID, let workspace = draft.workspaceID,
              let payload = AgentRoster.lifecyclePayload(
                effect: result.receipt.projectionEffect, from: result.fromPhase, to: result.toPhase,
                tab: tab, agent: draft.agentKind, reason: result.changedSnapshot?.reason) else { return }
        EventEmitter.shared.emitLifecycleChanged(workspace: workspace, tab: tab, payload: payload)
    }

    private func rememberApplied(draft: JournalDraft, result: JournalAppendResult) {
        guard result.receipt.projectionEffect == .applied, let tab = draft.tabID, let snap = result.changedSnapshot else { return }
        lock.lock()
        defer { lock.unlock() }
        if draft.kind == .turnStarted, snap.turnID == nil || snap.turnID == draft.turnID {
            let ms = draft.timeQuality == .nativeLocal ? (draft.occurredAtMs ?? result.receipt.committedAtMs) : result.receipt.committedAtMs
            turnStartedMs[tab] = ms
        }
        if snap.phase == .blocked, AgentRoster.isAsk(draft.kind), let ask = JournalOpenAsk.make(draft: draft, snapshot: snap, committedAtMs: result.receipt.committedAtMs) {
            responseGate.clear(tab: tab)
            openAsks[tab] = ask
        } else if snap.phase != .blocked {
            openAsks.removeValue(forKey: tab)
            responseGate.clear(tab: tab)
        } else if let current = openAsks[tab], snap.requestID != nil, current.requestID != snap.requestID {
            openAsks.removeValue(forKey: tab)
        }
    }

    private func cacheClocks(_ store: JournalStore) throws {
        lock.lock()
        let rows = snapshots
        lock.unlock()
        for (tab, snap) in rows {
            guard tab == snap.owner.tabID else { continue }
            try hydrateCaches(store: store, snapshot: snap)
        }
    }

    private func hydrateCaches(store: JournalStore, snapshot snap: JournalSnapshot) throws {
        guard isEligible(snap.owner), target(tabID: snap.owner.tabID) == snap.workspaceID else { return }
        let tab = snap.owner.tabID
        let page = try store.retainedOwnerEvents(
            owner: snap.owner, throughSequence: snap.lastSequence, limit: AgentRoster.restoreLimit)
        let turn = AgentRoster.turnStartMs(turnID: snap.turnID, throughSequence: snap.lastSequence, eventsNewestFirst: page.events)
        let restored = AgentRoster.restoredAsk(snapshot: snap, eventsNewestFirst: page.events)
        lock.lock()
        defer { lock.unlock() }
        guard owners[tab] == snap.owner, targets[tab] == snap.workspaceID,
              snapshots[tab]?.owner == snap.owner,
              (snapshots[tab]?.lastSequence ?? Int64.max) <= snap.lastSequence else { return }
        if turnStartedMs[tab] == nil, let turn { turnStartedMs[tab] = turn }
        if openAsks[tab] == nil, let restored, let workspace = snap.workspaceID {
            openAsks[tab] = JournalOpenAsk(
                owner: snap.owner, workspaceID: workspace, requestID: restored.requestID,
                eventID: restored.eventID, openedAtMs: restored.openedAtMs,
                requiresPickerCommit: JournalOpenAsk.requiresPickerCommit(draft: restored.draft),
                pickerKeyCode: JournalOpenAsk.pickerKeyCode(draft: restored.draft),
                pickerModifierRaw: 0)
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

struct JournalOpenAsk: Sendable {
    let owner: JournalOwner
    let workspaceID: UUID
    let requestID: String?
    let eventID: UUID
    let openedAtMs: Int64
    /// Exact provider pickers require their own committed key; unknown keys stay unavailable.
    let requiresPickerCommit: Bool
    let pickerKeyCode: UInt16?
    let pickerModifierRaw: UInt

    static func make(draft: JournalDraft, snapshot: JournalSnapshot, committedAtMs: Int64) -> JournalOpenAsk? {
        guard let owner = draft.owner, let workspace = draft.workspaceID ?? snapshot.workspaceID else { return nil }
        let opened = draft.timeQuality == .nativeLocal ? (draft.occurredAtMs ?? committedAtMs) : committedAtMs
        return JournalOpenAsk(owner: owner, workspaceID: workspace, requestID: draft.requestID, eventID: draft.eventID,
                              openedAtMs: opened, requiresPickerCommit: requiresPickerCommit(draft: draft),
                              pickerKeyCode: pickerKeyCode(draft: draft), pickerModifierRaw: 0)
    }

    static func requiresPickerCommit(draft: JournalDraft?) -> Bool {
        guard let draft,
              draft.kind == .questionRequested,
              draft.nativeEvent == "PreToolUse",
              draft.toolClass == .askUserQuestion,
              draft.source == .hook,
              draft.adapter == .claudeHook,
              draft.agentKind == "claude-code" else { return false }
        return true
    }

    static func pickerKeyCode(draft: JournalDraft?) -> UInt16? {
        guard requiresPickerCommit(draft: draft) else { return nil }
        return AgentRoster.pickerCommitKeyCode
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
