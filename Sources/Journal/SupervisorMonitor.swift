import Foundation

/// Structural observations only. The journal still owns lifecycle and attention.
/// This projection is deliberately process-local and does not write the journal.
struct SupervisorProjection {
    struct Progress: Equatable {
        var outputAt: Date?
        var turnStartedAt: Date?
        var tokens: Int
        var sessionTokens: Int?

        init(_ signals: TranscriptSignals) {
            outputAt = signals.lastOutputAt
            turnStartedAt = signals.turnStartedAt
            tokens = signals.turnTokens
            sessionTokens = signals.sessionTokens
        }

        var hasCoverage: Bool { turnStartedAt != nil || outputAt != nil || tokens > 0 || sessionTokens != nil }
    }

    struct Edge {
        let type: EventEnvelope.EventType
        let payload: [String: Any]
    }

    var snapshot: JournalSnapshot
    private(set) var waitKind: String?
    private(set) var waitSource: String?
    private(set) var waitSince: Int64?
    private(set) var stalledSince: Int64?
    private(set) var lastProgressAt: Int64?
    private(set) var progress: Progress?
    private(set) var interruptionReason: String?
    private(set) var interruptedAt: Int64?
    private(set) var interruptionSource: String?
    private var claudeApprovalAnswered = false

    init(snapshot: JournalSnapshot) { self.snapshot = snapshot }

    static func thresholdMinutes(_ value: Double) -> Double {
        value.isFinite && value > 0 && value <= 1440 ? value : 10
    }

    static func isIdlessClaudeApproval(_ snapshot: JournalSnapshot) -> Bool {
        !snapshot.isHistorical && snapshot.owner.agentKind == "claude-code"
            && snapshot.phase == .blocked && snapshot.reason == .approval && snapshot.requestID == nil
    }

    /// Claude's native permission hook has no answer id. Only that blocked
    /// approval needs screen confirmation; its identified asks remain native.
    static func needsScreen(_ snapshot: JournalSnapshot) -> Bool {
        isIdlessClaudeApproval(snapshot) ||
            (!snapshot.isHistorical && [.working, .blocked].contains(snapshot.phase)
                && ["codex", "pi"].contains(snapshot.owner.agentKind))
    }

    var observesAsWorking: Bool {
        !snapshot.isHistorical && (snapshot.phase == .working ||
            (Self.isIdlessClaudeApproval(snapshot) && claudeApprovalAnswered))
    }

    static func interruptionReason(_ draft: JournalDraft, result: JournalAppendResult, observedSince: Int64) -> String? {
        guard result.receipt.projectionEffect == .applied,
              let from = result.fromPhase, [.working, .blocked].contains(from),
              draft.source != .transcript || (draft.occurredAtMs ?? 0) >= observedSince else { return nil }
        switch draft.kind {
        case .errorReported: return "provider_error"
        case .turnInterrupted: return draft.reasonCode == .observation ? "unknown" : "cancelled"
        default: return nil
        }
    }

    mutating func observe(
        _ next: JournalSnapshot, progress nextProgress: Progress?,
        prompt: PromptInputClassification? = nil, now: Int64, thresholdMs: Int64
    ) -> [Edge] {
        var edges: [Edge] = []
        let wasWorking = observesAsWorking
        let turnChanged = snapshot.turnID != next.turnID
        let idlessApproval = Self.isIdlessClaudeApproval(next)
        if !idlessApproval || turnChanged { claudeApprovalAnswered = false }
        if idlessApproval, let prompt {
            if prompt.state == .dialog { claudeApprovalAnswered = false }
            else if [.empty, .suggestion, .draft].contains(prompt.state) { claudeApprovalAnswered = true }
            // Unknown does not revoke a previously confirmed continuation.
        }
        let advanced = nextProgress.map { value in
            guard let old = progress else { return false }
            return (value.outputAt.map { $0 > (old.outputAt ?? .distantPast) } ?? false)
                || value.tokens > old.tokens
                || (value.sessionTokens ?? 0) > (old.sessionTokens ?? 0)
        } ?? false
        snapshot = next
        progress = nextProgress
        let working = observesAsWorking
        let newTurn = turnChanged || (!wasWorking && working)

        if newTurn || advanced {
            lastProgressAt = now
            interruptionReason = nil; interruptedAt = nil; interruptionSource = nil
        }
        if working && lastProgressAt == nil { lastProgressAt = now }

        var kind = waitKind
        var source = waitSource
        if next.isHistorical || ![.working, .blocked].contains(next.phase) {
            kind = nil; source = nil
        } else if next.phase == .blocked, !(idlessApproval && claudeApprovalAnswered),
                  let native = AgentRoster.waitingReason(next.reason) {
            kind = native == "approval" ? "permission" : native
            source = "journal"
        } else if waitSource == "journal" {
            kind = nil; source = nil
        }
        if Self.needsScreen(next), let prompt {
            if prompt.state == .dialog {
                kind = prompt.dialogKind ?? "choice"; source = "active_screen"
            } else if [.empty, .suggestion, .draft].contains(prompt.state), source == "active_screen" {
                kind = nil; source = nil
            }
            // Unknown/unavailable is not proof that a dialog was answered.
        }
        if waitKind == nil, let kind {
            waitSince = now
            edges.append(edge(.supervisorWaitingOnPermission,
                              ["kind": kind, "source": source ?? "unknown", "since_ms": now]))
        } else if waitKind != nil, kind == nil {
            let reason = next.isHistorical ? "coverage_changed" :
                (working ? "answered" : "turn_ended")
            edges.append(edge(.supervisorPermissionCleared,
                              ["kind": waitKind!, "source": waitSource ?? "unknown",
                               "since_ms": waitSince ?? now, "reason": reason]))
            waitSince = nil
            lastProgressAt = now
        }
        waitKind = kind; waitSource = source

        if let stalledSince, advanced || newTurn || !working || kind != nil {
            let reason = advanced ? "progress" : (kind != nil ? "waiting" : "turn_ended")
            edges.append(edge(.supervisorStallCleared,
                              ["since_ms": stalledSince, "reason": reason]))
            self.stalledSince = nil
        }
        if kind != nil || !working {
            lastProgressAt = nil
        } else if stalledSince == nil, progress?.hasCoverage == true,
                  let lastProgressAt, now >= lastProgressAt, now - lastProgressAt >= thresholdMs {
            stalledSince = now
            edges.append(edge(.supervisorStalled,
                              ["last_progress_at_ms": lastProgressAt,
                               "threshold_seconds": Double(thresholdMs) / 1000,
                               "source": "transcript"]))
        }
        return edges
    }

    mutating func interrupt(reason: String, source: String, now: Int64, nativeEvent: String) -> Edge {
        interruptionReason = reason; interruptedAt = now; interruptionSource = source
        return edge(.supervisorTurnInterrupted,
                    ["reason": reason, "source": source, "observed_at_ms": now,
                     "native_event": nativeEvent, "session_id": snapshot.owner.sessionID,
                     "turn_id": snapshot.turnID as Any? ?? NSNull()])
    }

    mutating func resetProgressClock(now: Int64) { lastProgressAt = now }

    func retirementEdges(reason: String) -> [Edge] {
        var edges: [Edge] = []
        if let waitKind {
            edges.append(edge(.supervisorPermissionCleared,
                              ["kind": waitKind, "source": waitSource ?? "unknown",
                               "since_ms": waitSince as Any? ?? NSNull(), "reason": reason]))
        }
        if let stalledSince {
            edges.append(edge(.supervisorStallCleared, ["since_ms": stalledSince, "reason": reason]))
        }
        return edges
    }

    var metadata: [String: Any] {
        ["phase": snapshot.phase.rawValue,
         "source": snapshot.source.rawValue,
         "coverage": snapshot.isHistorical ? "historical" : "observed",
         "screen_confirmed_continuation": claudeApprovalAnswered,
         "waiting_on_permission": waitKind != nil,
         "wait_kind": waitKind as Any? ?? NSNull(),
         "wait_source": waitSource as Any? ?? NSNull(),
         "wait_since_ms": waitSince as Any? ?? NSNull(),
         "stalled": stalledSince != nil,
         "stall_since_ms": stalledSince as Any? ?? NSNull(),
         "last_progress_at_ms": lastProgressAt as Any? ?? NSNull(),
         "progress_coverage": progress?.hasCoverage == true ? "transcript" : "unavailable",
         "interruption_reason": interruptionReason as Any? ?? NSNull(),
         "interrupted_at_ms": interruptedAt as Any? ?? NSNull(),
         "interruption_source": interruptionSource as Any? ?? NSNull()]
    }

    private func edge(_ type: EventEnvelope.EventType, _ fields: [String: Any]) -> Edge {
        var payload = fields
        payload["agent"] = snapshot.owner.agentKind
        return Edge(type: type, payload: payload)
    }
}

/// All bookkeeping and emission runs on this utility queue. Main only copies
/// bounded Ghostty cells, asynchronously, with a measured per-sweep budget.
final class SupervisorMonitor: @unchecked Sendable {
    static let shared = SupervisorMonitor()
    private let queue = DispatchQueue(label: "com.stage11.c11.supervisor", qos: .utility)
    private let lock = NSLock()
    private var published: [UUID: [String: Any]] = [:]
    private var projections: [UUID: SupervisorProjection] = [:]
    private var timer: DispatchSourceTimer?
    private var sampling = false
    private var sleeping = false
    private var cursor = 0
    private let startedAt = SupervisorMonitor.nowMs
    private let emitter: (SupervisorProjection.Edge, JournalSnapshot) -> Void
    private let latestSnapshot: (UUID) -> JournalSnapshot?
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let captureBudgetNs: UInt64 = 2_000_000
    // Leave one millisecond for the last bounded capture and its bookkeeping.
    static let captureAdmissionLimitNs = captureBudgetNs - 1_000_000

    init(latestSnapshot: @escaping (UUID) -> JournalSnapshot? = { JournalCoordinator.shared.snapshot(panelID: $0) },
         emitter: @escaping (SupervisorProjection.Edge, JournalSnapshot) -> Void = { edge, snapshot in
        guard let workspace = snapshot.workspaceID else { return }
        EventEmitter.shared.emitSupervisor(edge.type, workspace: workspace,
                                           panel: snapshot.owner.panelID, payload: edge.payload)
    }) {
        self.emitter = emitter
        self.latestSnapshot = latestSnapshot
    }

    #if DEBUG
    func drainForTesting() { queue.sync {} }
    #endif

    func readback(panel: UUID) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return published[panel] ?? ["phase": "unknown", "coverage": "unavailable",
                                   "waiting_on_permission": false, "stalled": false]
    }

    func observe(_ snapshot: JournalSnapshot, prompt: PromptInputClassification? = nil) {
        queue.async { [self] in
            // publish releases its lock before enqueueing. An owner change or
            // close can overtake this callback; consult the existing journal.
            guard let current = latestSnapshot(snapshot.owner.panelID),
                  current.owner == snapshot.owner, current.lastSequence >= snapshot.lastSequence else { return }
            guard (projections[snapshot.owner.panelID]?.snapshot.lastSequence ?? -1) <= snapshot.lastSequence else { return }
            startTimer()
            update(snapshot, prompt: prompt, now: Self.nowMs)
        }
    }

    func remove(panel: UUID, reason: String = "closed") {
        queue.async { [self] in
            if let projection = projections[panel] {
                for edge in projection.retirementEdges(reason: reason) { emit(edge, snapshot: projection.snapshot) }
            }
            projections.removeValue(forKey: panel)
            lock.lock(); published.removeValue(forKey: panel); lock.unlock()
            if projections.isEmpty { timer?.cancel(); timer = nil }
        }
    }

    func applied(_ draft: JournalDraft, result: JournalAppendResult) {
        guard let snapshot = result.changedSnapshot,
              let reason = SupervisorProjection.interruptionReason(draft, result: result, observedSince: startedAt) else { return }
        queue.async { [self] in
            let panel = snapshot.owner.panelID
            guard var value = projections[panel], value.snapshot.owner == snapshot.owner,
                  value.snapshot.lastSequence == snapshot.lastSequence else { return }
            emit(value.interrupt(reason: reason, source: draft.source.rawValue,
                                 now: Self.nowMs, nativeEvent: draft.nativeEvent), snapshot: snapshot)
            projections[panel] = value
            publish(value)
        }
    }

    func setSleeping(_ value: Bool) {
        queue.async { [self] in
            guard sleeping != value else { return }
            sleeping = value
            let now = Self.nowMs
            for (panel, var projection) in projections {
                if value, projection.observesAsWorking {
                    emit(projection.interrupt(reason: "host_sleep", source: "c11", now: now,
                                              nativeEvent: "system.sleep"), snapshot: projection.snapshot)
                }
                // Sleeping time never consumes a stall's no-progress interval.
                projection.resetProgressClock(now: now)
                projections[panel] = projection
                publish(projection)
            }
        }
    }

    private func startTimer() {
        guard timer == nil, NSClassFromString("XCTestCase") == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 5, repeating: 5)
        source.setEventHandler { [weak self] in self?.sweep() }
        timer = source
        source.resume()
    }

    private func update(_ snapshot: JournalSnapshot, prompt: PromptInputClassification? = nil, now: Int64) {
        let panel = snapshot.owner.panelID
        var value = projections[panel]
        if value?.snapshot.owner != snapshot.owner {
            if let previous = value {
                for edge in previous.retirementEdges(reason: "owner_changed") { emit(edge, snapshot: previous.snapshot) }
            }
            value = SupervisorProjection(snapshot: snapshot)
        }
        guard var value else { return }
        let signals = AgentModelDetector.shared.signals(forSurface: panel).map(SupervisorProjection.Progress.init)
        let minutes = SupervisorProjection.thresholdMinutes(UserDefaults.standard.double(forKey: "c11.supervisor.stallMinutes"))
        for edge in value.observe(snapshot, progress: signals, prompt: prompt, now: now,
                                  thresholdMs: Int64(minutes * 60_000)) {
            emit(edge, snapshot: snapshot)
        }
        projections[panel] = value
        publish(value)
    }

    private func publish(_ value: SupervisorProjection) {
        lock.lock(); published[value.snapshot.owner.panelID] = value.metadata; lock.unlock()
    }

    private func emit(_ edge: SupervisorProjection.Edge, snapshot: JournalSnapshot) {
        emitter(edge, snapshot)
    }

    private func sweep() {
        guard !sleeping, !sampling else { return }
        let now = Self.nowMs
        var candidates: [JournalSnapshot] = []
        for panel in projections.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let snapshot = JournalCoordinator.shared.snapshot(panelID: panel) else { continue }
            update(snapshot, now: now)
            if SupervisorProjection.needsScreen(snapshot) { candidates.append(snapshot) }
        }
        guard !candidates.isEmpty else { return }
        let offset = cursor % candidates.count
        let ordered = Array(candidates[offset...] + candidates[..<offset])
        sampling = true
        // Ghostty/AppKit ownership requires main for capture only. No waiting
        // thread, parsing, file access, event emission or metadata writes here.
        DispatchQueue.main.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            var captures: [(JournalSnapshot, PromptRegionSnapshot?)] = []
            for candidate in ordered {
                if DispatchTime.now().uptimeNanoseconds - started >= Self.captureAdmissionLimitNs { break }
                guard let current = JournalCoordinator.shared.snapshot(panelID: candidate.owner.panelID),
                      current.owner == candidate.owner, current.turnID == candidate.turnID,
                      SupervisorProjection.needsScreen(current), let workspaceID = current.workspaceID,
                      let manager = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceID),
                      let workspace = manager.workspaces.first(where: { $0.id == workspaceID }),
                      let terminal = workspace.terminalPanel(for: current.owner.panelID) else {
                    captures.append((candidate, nil)); continue
                }
                let region = terminal.surface.surface.flatMap {
                    TerminalController.shared.capturePromptInputRegion(surface: $0, harness: current.owner.agentKind, forSupervisor: true)
                }
                captures.append((current, region))
            }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let captured = captures
            queue.async { [self] in
                sampling = false
                cursor = (offset + max(1, captured.count)) % ordered.count
                for (expected, region) in captured {
                    guard let current = JournalCoordinator.shared.snapshot(panelID: expected.owner.panelID),
                          current.owner == expected.owner, current.turnID == expected.turnID,
                          current.lastSequence == expected.lastSequence,
                          SupervisorProjection.needsScreen(current) else { continue }
                    let prompt = region.map { PromptInputClassifier.classify($0, harness: current.owner.agentKind, forSupervisor: true) }
                    update(current, prompt: prompt, now: Self.nowMs)
                }
                lock.lock()
                for candidate in ordered {
                    published[candidate.owner.panelID]?["capture_sweep_ms"] = elapsedMs
                    published[candidate.owner.panelID]?["capture_budget_exhausted"] = captured.count < ordered.count
                }
                lock.unlock()
            }
        }
    }
}
