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
    private var panelsReady = false
    private var drainStarted = false
    private var sink: (@Sendable (UUID, JournalSnapshot?, JournalMailboxBoundary?, UUID?) -> Void)?

    init(store: JournalStore? = nil) {
        self.store = store
    }

    func register(panelID: UUID, workspaceID: UUID) {
        lock.lock(); let changed = targets[panelID] != workspaceID; targets[panelID] = workspaceID; lock.unlock()
        if changed { refreshOwners([panelID]) }
    }
    func remove(panelID: UUID) {
        lock.lock()
        targets.removeValue(forKey: panelID)
        let hadProjection = snapshots.removeValue(forKey: panelID) != nil
        turnStartedMs.removeValue(forKey: panelID)
        openAsks.removeValue(forKey: panelID)
        responseGate.clear(panel: panelID)
        let callback = sink
        lock.unlock()
        // A removed tab is a real close. The sink queues its own work and does not wait on UI.
        if hadProjection { callback?(panelID, nil, nil, nil) }
    }
    /// Called synchronously by the existing conversation actor after a real identity change.
    /// Snapshot readers never wait on that actor, including the typing/notification paths.
    func setOwner(panelID: UUID, owner: JournalOwner?) {
        lock.lock()
        guard owners[panelID] != owner else { lock.unlock(); return }
        owners[panelID] = owner
        let hadProjection = snapshots.removeValue(forKey: panelID) != nil
        turnStartedMs.removeValue(forKey: panelID)
        openAsks.removeValue(forKey: panelID)
        responseGate.clear(panel: panelID)
        let callback = sink
        lock.unlock()
        if hadProjection { callback?(panelID, nil, nil, nil) }
        if let owner, owner.agentKind == "codex" {
            registerCodexHookGap(owner)
        }
        refreshOwners([panelID])
    }

    /// Codex currently has only the root `notify` completion rail. Record that
    /// bounded provider gap only after ConversationStore has established an
    /// exact causal owner; a wrapper claim or a sessionless observer must not
    /// create a live projection. The control event changes health only and is
    /// intentionally kept off the actor, socket and typing paths.
    private func registerCodexHookGap(_ owner: JournalOwner) {
        startupQueue.async { [self] in
            guard isEligible(owner), let workspaceID = target(panelID: owner.panelID) else { return }
            var draft = JournalDraft(
                kind: .stateChanged,
                emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                panelID: owner.panelID,
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
    func refreshOwners(_ panelIDs: [UUID]? = nil) {
        lock.lock(); let ids = panelIDs ?? Array(targets.keys); let ready = started; lock.unlock()
        guard ready, !ids.isEmpty else { return }
        startupQueue.async { [self] in
            guard let store = try? storage() else { return }
            for id in ids {
                guard let owner = exactOwner(panelID: id), let baseline = try? store.current(owner: owner) else { continue }
                let attached = baseline.appInstanceID == store.instanceID ? baseline : JournalReplayPolicy.restored(baseline)
                publish(attached)
                try? hydrateCaches(store: store, snapshot: attached)
            }
        }
    }
    func snapshot(panelID: UUID) -> JournalSnapshot? {
        lock.lock(); defer { lock.unlock() }; return snapshots[panelID]
    }
    func target(panelID: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }; return targets[panelID]
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
        let panelIDs = Array(snapshots.keys)
        snapshots.removeAll()
        storageError = nil
        let callback = sink
        lock.unlock()
        for panelID in panelIDs { callback?(panelID, nil, nil, nil) }
    }

    /// Existing metadata readback can expose this value without consulting SQLite.
    func readback(panelID: UUID, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [String: Any] {
        lock.lock(); let state = snapshots[panelID]; let error = storageError; lock.unlock()
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
    func startupPanelsReady() { lock.lock(); panelsReady = true; lock.unlock(); beginDrainIfReady() }
    private func beginDrainIfReady() {
        lock.lock()
        guard started, seedReady, panelsReady, !drainStarted else { lock.unlock(); return }
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

    func isEligible(_ owner: JournalOwner) -> Bool { exactOwner(panelID: owner.panelID) == owner }
    func exactOwner(panelID: UUID) -> JournalOwner? {
        lock.lock(); defer { lock.unlock() }
        return targets[panelID] == nil ? nil : owners[panelID]
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
            let eligible = draft.owner.map { isEligible($0) && target(panelID: $0.panelID) == draft.workspaceID } ?? false
            let model = draft.panelID.flatMap { panelID in target(panelID: panelID).flatMap { workspaceID in
                PanelMetadataStore.shared.metadataValue(workspaceId: workspaceID, surfaceId: panelID, key: MetadataKey.model) as? String
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
                let boundary = JournalMailboxBoundary.make(draft: draft, result: result, historical: historical,
                                                           pid: interactivePID,
                                                           verifiedNativeClock: context.verifiedNativeClock)
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
        guard targets[value.owner.panelID] != nil, owners[value.owner.panelID] == value.owner else { lock.unlock(); return }
        let old = snapshots[value.owner.panelID]
        guard old?.owner != value.owner || (old?.lastSequence ?? -1) <= value.lastSequence else { lock.unlock(); return }
        snapshots[value.owner.panelID] = value
        let callback = sink
        lock.unlock()
        callback?(value.owner.panelID, value, boundary, eventID)
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
    func cachedTurnStartedMs(panelID: UUID) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return turnStartedMs[panelID]
    }

    func registeredTargets() -> [UUID: UUID] {
        lock.lock(); defer { lock.unlock() }
        return targets
    }

    /// One lock lookup. Draft building happens on the startup queue, never here.
    func noteOperatorSubmit(panelID: UUID, keyCode: UInt16, modifierRaw: UInt, isRepeat: Bool, synthesizing: Bool, hasMarkedText: Bool) {
        lock.lock()
        guard let ask = openAsks[panelID] else { lock.unlock(); return }
        let accepted = AgentRoster.isOperatorSubmit(
            keyCode: keyCode, modifierRaw: modifierRaw, isRepeat: isRepeat,
            synthesizing: synthesizing, hasMarkedText: hasMarkedText,
            requiresPickerCommit: ask.requiresPickerCommit,
            pickerKeyCode: ask.pickerKeyCode, pickerModifierRaw: ask.pickerModifierRaw)
        guard accepted, responseGate.begin(panel: panelID, ask: ask.eventID) else { lock.unlock(); return }
        let captured = ask
        lock.unlock()
        startupQueue.async { [self] in enqueueResponse(panelID: panelID, ask: captured) }
    }

    func noteTextBoxSubmit(panelID: UUID) {
        lock.lock()
        guard let ask = openAsks[panelID], responseGate.begin(panel: panelID, ask: ask.eventID) else { lock.unlock(); return }
        let captured = ask
        lock.unlock()
        startupQueue.async { [self] in enqueueResponse(panelID: panelID, ask: captured) }
    }

    func rosterDocument(live: [AgentRoster.LivePanel], now: Int64) -> [String: Any] {
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

    private func enqueueResponse(panelID: UUID, ask: JournalOpenAsk) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let draft = JournalDraft(
            kind: .stateChanged, emittedAtMs: now, panelID: ask.owner.panelID, workspaceID: ask.workspaceID,
            sessionID: ask.owner.sessionID, agentKind: ask.owner.agentKind, source: .c11, adapter: .c11,
            nativeEvent: "operator_response", requestID: ask.requestID ?? ask.eventID.uuidString, signal: .operatorResponse)
        do {
            _ = try append(draft)
            lock.lock(); responseGate.succeed(panel: panelID, ask: ask.eventID); lock.unlock()
        } catch {
            lock.lock(); responseGate.fail(panel: panelID, ask: ask.eventID); lock.unlock()
        }
    }

    private func emitLifecycle(draft: JournalDraft, result: JournalAppendResult) {
        guard let panel = draft.panelID, let workspace = draft.workspaceID,
              let payload = AgentRoster.lifecyclePayload(
                effect: result.receipt.projectionEffect, from: result.fromPhase, to: result.toPhase,
                panel: panel, agent: draft.agentKind, reason: result.changedSnapshot?.reason) else { return }
        EventEmitter.shared.emitLifecycleChanged(workspace: workspace, panel: panel, payload: payload)
    }

    private func rememberApplied(draft: JournalDraft, result: JournalAppendResult) {
        guard result.receipt.projectionEffect == .applied, let panel = draft.panelID, let snap = result.changedSnapshot else { return }
        lock.lock()
        defer { lock.unlock() }
        if draft.kind == .turnStarted, snap.turnID == nil || snap.turnID == draft.turnID {
            let ms = draft.timeQuality == .nativeLocal ? (draft.occurredAtMs ?? result.receipt.committedAtMs) : result.receipt.committedAtMs
            turnStartedMs[panel] = ms
        }
        if snap.phase == .blocked, AgentRoster.isAsk(draft.kind), let ask = JournalOpenAsk.make(draft: draft, snapshot: snap, committedAtMs: result.receipt.committedAtMs) {
            responseGate.clear(panel: panel)
            openAsks[panel] = ask
        } else if snap.phase != .blocked {
            openAsks.removeValue(forKey: panel)
            responseGate.clear(panel: panel)
        } else if let current = openAsks[panel], snap.requestID != nil, current.requestID != snap.requestID {
            openAsks.removeValue(forKey: panel)
        }
    }

    private func cacheClocks(_ store: JournalStore) throws {
        lock.lock()
        let rows = snapshots
        lock.unlock()
        for (panel, snap) in rows {
            guard panel == snap.owner.panelID else { continue }
            try hydrateCaches(store: store, snapshot: snap)
        }
    }

    private func hydrateCaches(store: JournalStore, snapshot snap: JournalSnapshot) throws {
        guard isEligible(snap.owner), target(panelID: snap.owner.panelID) == snap.workspaceID else { return }
        let panel = snap.owner.panelID
        let page = try store.retainedOwnerEvents(
            owner: snap.owner, throughSequence: snap.lastSequence, limit: AgentRoster.restoreLimit)
        let turn = AgentRoster.turnStartMs(turnID: snap.turnID, throughSequence: snap.lastSequence, eventsNewestFirst: page.events)
        let restored = AgentRoster.restoredAsk(snapshot: snap, eventsNewestFirst: page.events)
        lock.lock()
        defer { lock.unlock() }
        guard owners[panel] == snap.owner, targets[panel] == snap.workspaceID,
              snapshots[panel]?.owner == snap.owner,
              (snapshots[panel]?.lastSequence ?? Int64.max) <= snap.lastSequence else { return }
        if turnStartedMs[panel] == nil, let turn { turnStartedMs[panel] = turn }
        if openAsks[panel] == nil, let restored, let workspace = snap.workspaceID {
            openAsks[panel] = JournalOpenAsk(
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
        for value in degraded { snapshots[value.owner.panelID] = value }
        let callback = sink
        lock.unlock()
        for value in degraded { callback?(value.owner.panelID, value, nil, nil) }
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

/// A live turn edge the mailbox stdin gate acts on. Hook and plugin turn edges
/// count at commit time. A transcript turn end counts too, stamped with the
/// agent's own clock: the 10 s transcript poll can fold a Codex turn end before
/// its notify hook lands (the hook then folds as duplicate evidence), and a
/// transcript is Grok's only journal turn source (C11-365). The gate ignores a
/// turn end older than the newest Return typed into the panel, so a late poll
/// cannot reopen it over a newer turn. A transcript turn start is not a
/// boundary: the Return that started the turn already closed the gate.
struct JournalMailboxBoundary: Sendable {
    let working: Bool
    let pid: Int32?
    let at: Date
    /// A hook or plugin edge without an interactive PID came from a headless
    /// run nested in the panel. A transcript edge follows the panel's exact
    /// owner and never carries a PID.
    let headless: Bool
    /// `verifiedNativeClock` is the append route's own evidence (only the
    /// in-process transcript reader sets it); a draft's fields alone never
    /// qualify a transcript turn end.
    static func make(draft: JournalDraft, result: JournalAppendResult, historical: Bool, pid: Int32?,
                     verifiedNativeClock: Bool = false) -> Self? {
        guard !historical, !result.receipt.replayed, result.receipt.projectionEffect == .applied,
              !draft.isChild, let state = result.changedSnapshot, state.confirmation == .confirmed else { return nil }
        let committedAtMs = result.receipt.committedAtMs
        switch draft.source {
        case .hook, .plugin:
            guard (draft.kind == .turnStarted && state.phase == .working)
                    || (draft.kind == .turnCompleted && state.phase == .idle) else { return nil }
            return Self(working: state.phase == .working, pid: pid,
                        at: Date(timeIntervalSince1970: Double(committedAtMs) / 1000),
                        headless: pid == nil)
        case .transcript:
            guard draft.kind == .turnCompleted, state.phase == .idle, verifiedNativeClock,
                  let endedAtMs = draft.occurredAtMs else { return nil }
            // Never later than c11 recorded it: a skewed agent clock must not
            // stamp the gate in the future.
            return Self(working: false, pid: nil,
                        at: Date(timeIntervalSince1970: Double(min(endedAtMs, committedAtMs)) / 1000),
                        headless: false)
        default:
            return nil
        }
    }

    /// Whether this boundary still describes the panel after a newer snapshot
    /// replaced its own: same owner, and the current phase agrees with the
    /// edge. Appends for one panel finish on several threads, so an older edge
    /// can arrive after a newer state; one that disagrees is dropped.
    func stillHolds(projected: JournalSnapshot?, current: JournalSnapshot?) -> Bool {
        guard let projected, let current, current.owner == projected.owner else { return false }
        return working ? [.working, .blocked, .error].contains(current.phase) : current.phase == .idle
    }
}
