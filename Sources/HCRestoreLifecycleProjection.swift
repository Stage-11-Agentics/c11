import Foundation
import Darwin

/// The root can exit before hc drains the PTY and stamps `finished_ms`.
/// Observe that boundary while the known agent is still running its end hook.
/// Kernel probes stay on the socket worker; host tests supply every process fact.
enum HCSessionEndRootWitness {
    static func capture(draft: JournalDraft, interactivePID: Int32?, callerPID: Int32?) -> JournalRootExitWitness? {
        guard draft.kind == .sessionEnded, draft.source == .hook, draft.adapter == .claudeHook,
              draft.agentKind == "claude-code",
              let panelID = draft.panelID, let entry = HCPanelRestoreState.shared.entry(for: panelID) else { return nil }
        let witness = resolve(draft: draft, interactivePID: interactivePID, callerPID: callerPID,
            prior: JournalCoordinator.shared.snapshot(panelID: panelID),
            conversation: ConversationStorePanelRefCache.shared.snapshot(surfaceId: panelID)?.active,
            entry: entry, processInfo: MailboxAgentForeground.processTerminalInfo,
            isAbsent: { kill($0, 0) == -1 && errno == ESRCH })
        guard HCPanelRestoreState.shared.entry(for: panelID)?.identity.key == entry.identity.key else { return nil }
        return witness
    }

    static func resolve(draft: JournalDraft, interactivePID: Int32?, callerPID: Int32?,
                        prior: JournalSnapshot?, conversation: ConversationRef?, entry: HCPanelRestoreState.Entry,
                        processInfo: (pid_t) -> MailboxAgentForeground.ProcessTerminalInfo?,
                        isAbsent: (pid_t) -> Bool) -> JournalRootExitWitness? {
        guard draft.kind == .sessionEnded, draft.source == .hook, draft.adapter == .claudeHook,
              draft.agentKind == "claude-code",
              !draft.isChild, let owner = draft.owner, prior?.owner == owner,
              let expected = prior?.runtimeIdentity, expected.pid == interactivePID,
              let ref = conversation, ref.kind == owner.agentKind, ref.id == owner.sessionID,
              ref.hasCausalExactEvidence, !ref.isQuarantined, ref.sessionEndedAt == nil,
              ref.state == .alive || ref.state == .suspended,
              ref.identityCaptureTime <= Date(timeIntervalSince1970: Double(draft.emittedAtMs) / 1000),
              entry.identity.panelID == owner.panelID, entry.identity.persistence == .persistent,
              case .live(let record) = entry.lifecycle, record.state == .running, record.machineName == nil,
              record.key == entry.identity.key, let rootPID = record.pid, rootPID > 1,
              let callerPID, let agent = processInfo(expected.pid), !agent.isZombie,
              agent.startTime == expected.startTimeMicroseconds, agent.startTime > 0 else { return nil }

        // HUP removes the controlling tty. Authenticate by the process birth
        // already verified while live, plus the hook peer's current ancestry.
        var chain: [(pid_t, MailboxAgentForeground.ProcessTerminalInfo)] = []
        var seen: Set<pid_t> = []
        var pid = callerPID
        var reachedAgent = false
        for _ in 0..<128 {
            guard pid > 1, seen.insert(pid).inserted, let process = processInfo(pid),
                  !process.isZombie, process.startTime > 0 else { return nil }
            chain.append((pid, process))
            if pid == expected.pid { reachedAgent = process == agent; break }
            guard let parent = processInfo(process.parentPID), parent.startTime <= process.startTime else { return nil }
            pid = process.parentPID
        }
        guard reachedAgent, chain.allSatisfy({ processInfo($0.0) == $0.1 }) else { return nil }
        if let root = processInfo(rootPID) {
            guard root.isZombie else { return nil }
        } else {
            // A denied/unreadable query is not proof that the root exited.
            guard isAbsent(rootPID) else { return nil }
        }
        return JournalRootExitWitness(coreID: record.key.owningCoreID, terminalAddress: record.key.localAddress)
    }
}

/// Identity survives a login root, a missing foreground and process teardown.
/// A SessionEnd caused by that teardown is not proof the conversation was
/// already gone when hc's root ended. Compare facts, with no grace interval.
enum HCOutsideSignalConversation {
    static func resolve(panelID: UUID, evidence: HCEndEvidence,
                        conversation: ConversationRef?, journal: JournalSnapshot?) -> ConversationRef? {
        guard HCRestoreLifecycleProjection.outsideSignal(evidence) != nil,
              var ref = conversation, !ref.placeholder, !ref.isQuarantined,
              AgentIdentityPolicy.isAgentKind(ref.kind) else { return nil }
        // A replacement shell's later conversation never belongs to this end.
        if let rootEnd = evidence.endedAt, ref.identityCaptureTime > rootEnd { return nil }
        var sessionEnd = ref.sessionEndedAt
        var witnessedRootExit = false
        if let journal, journal.owner.panelID == panelID,
           journal.owner.agentKind == ref.kind, journal.owner.sessionID == ref.id,
           let endedMs = journal.sessionEndedAtMs {
            let ended = Date(timeIntervalSince1970: TimeInterval(endedMs) / 1000)
            // A newly captured live session can resume the same id. Its old
            // end is not evidence about the new invocation.
            if ref.identityCaptureTime <= ended {
                sessionEnd = min(sessionEnd ?? ended, ended)
                if sessionEnd == ended, let witness = journal.sessionEndedRootExit, let key = evidence.key {
                    witnessedRootExit = witness.coreID == key.owningCoreID && witness.terminalAddress == key.localAddress
                }
            }
        }
        if let sessionEnd {
            // hc's finish time follows PTY drain, not the root's death. A
            // verified hook can already have seen that exact root gone.
            guard witnessedRootExit || evidence.endedAt.map({ sessionEnd >= $0 }) == true else { return nil }
        }
        switch ref.state {
        case .alive, .suspended: break
        case .unknown:
            // Only an exact live ref downgraded by SessionEnd is recoverable;
            // a generic unknown, stale placeholder or tombstone is not.
            guard ref.sessionEndedAt != nil, ref.hasCausalExactEvidence else { return nil }
        case .tombstoned, .unsupported: return nil
        }
        ref.state = .suspended
        return ref
    }
}

/// App-side projection of HCSession's decisions. It never resolves absence,
/// creates a terminal, or consumes end evidence on behalf of the backend.
/// A native surface is deliberately not an input to this state.
struct HCRestoreLifecycleProjection: Sendable {
    private(set) var identity: HCPanelIdentity
    private(set) var lifecycle: HCLifecycle
    private(set) var replacementKey: HCTerminalKey?
    private var creation: Creation?

    private struct Creation: Sendable {
        let id: UUID
        let replacing: HCEndEvidence?
    }

    init(identity: HCPanelIdentity) {
        self.identity = identity
        lifecycle = .unresolved(identity, .inventoryPending)
    }

    var isPersistent: Bool { identity.persistence == .persistent }

    /// Holder loss is a terminal end, not permission to remove its UI. Keep
    /// this distinct from ordinary shell exit so the recovery remains visible.
    enum Notice: Equatable {
        case holderLost, resourceExhausted
        /// C11H-205: a fresh shell replaced a session the host ended, and no
        /// host-end banner explains it (agent resume off, a no-resume launch).
        case previousSessionEnded

        var message: String {
            switch self {
            case .holderLost:
                return String(localized: "terminal.restore.holderLost",
                    defaultValue: "The terminal host stopped and ended this session. This panel is kept for recovery.")
            case .previousSessionEnded:
                return String(localized: "terminal.restore.previousSessionEnded",
                    defaultValue: "The terminal host stopped and ended this panel's previous session. This is a new shell.")
            case .resourceExhausted:
                return String(localized: "terminal.restore.resourceExhausted",
                    defaultValue: "The terminal could not start because the host has no file handles available. This panel is waiting for recovery.")
            }
        }
    }

    /// Ends the backend caused, not the shell: its host died, stopped, or was
    /// shut down or restarted. The panel survives so the session can be
    /// recovered; only an `exited` or `killed` terminal is an ordinary close.
    static let hostEndReasons: Set<String> = [
        "holder_lost", "server_stop", "host_shutdown", "stopped_by_restart"
    ]

    static func isHostEnd(_ reason: String?) -> Bool {
        reason.map(hostEndReasons.contains) ?? false
    }

    /// C11H-232: the signal that ended a terminal's root from outside c11,
    /// or nil. hc reports its own `terminal.kill` (End Session, End All) as
    /// `killed`; `exited` with a signal is a signal c11 never sent, such as a
    /// broad `pkill -f` that matched the root (2026-11-06: 44 panels). SIGINT
    /// and SIGQUIT are the keyboard's own stop keys, so a program run as the
    /// root and stopped with Ctrl-C still closes like any exit.
    static func outsideSignal(_ evidence: HCEndEvidence) -> Int32? {
        guard evidence.kind == .finished else { return nil }
        return outsideSignal(reason: evidence.hcReason, signal: evidence.exitSignal)
    }

    static func outsideSignal(reason: String?, signal: Int32?) -> Int32? {
        guard reason == "exited", let signal, signal > 0, signal != SIGINT, signal != SIGQUIT else { return nil }
        return signal
    }

    /// An ended terminal never comes back, so `.live` after a host end is its
    /// replacement, and a live terminal never says its session ended. When the
    /// panel's host-end record explains the end (`hostEndCovered`) the notice
    /// clears; without one (agent resume off, a no-resume launch) it says, in
    /// the past tense, that the previous session ended and this is a new shell.
    /// C11H-205: it used to keep "ended this session ... kept for recovery" on
    /// the working shell; panel 408 carried it for a day under h8.
    static func notice(for lifecycle: HCLifecycle, retaining previous: Notice? = nil,
                       hostEndCovered: Bool = true) -> Notice? {
        switch lifecycle {
        case .ended(let evidence) where isHostEnd(evidence.hcReason): return .holderLost
        case .unresolved(_, .fileDescriptorLimit): return .resourceExhausted
        case .live where !hostEndCovered && (previous == .holderLost || previous == .previousSessionEnded):
            return .previousSessionEnded
        case .live: return nil
        default: return previous
        }
    }

    /// A newly attached surviving shell is not a fresh shell for --resume.
    /// Only a replacement whose creation followed authoritative end evidence
    /// may reach the existing conversation/prompt/once-only guards.
    var permitsConversationResume: Bool {
        guard isPersistent else { return true }
        guard case .live(let record) = lifecycle else { return false }
        return replacementKey == record.key
    }

    /// Saved origin is never permission to create on a subsequent launch.
    var snapshotIdentity: HCPanelIdentity {
        HCPanelIdentity(panelID: identity.panelID, key: identity.key,
                        persistence: identity.persistence, creationID: identity.creationID,
                        origin: .restored)
    }

    mutating func receive(_ result: HCLifecycle) {
        switch result {
        case .new:
            guard identity.key == nil, identity.creationID == nil, creation == nil else {
                lifecycle = .unresolved(identity, .staleIdentity)
                return
            }
            lifecycle = .new
        case .unresolved(let reported, let reason):
            guard reported.panelID == identity.panelID,
                  reported.persistence == identity.persistence else {
                lifecycle = .unresolved(identity, .staleIdentity)
                return
            }
            identity = HCPanelIdentity(panelID: identity.panelID,
                key: reported.key ?? identity.key, persistence: identity.persistence,
                creationID: reported.creationID ?? identity.creationID, origin: identity.origin)
            lifecycle = .unresolved(identity, reason)
        case .ended(let proof):
            // resolve may reconcile a newer durable attempt than autosave saw.
            // The session owns proof validation; the UI must not reject that
            // evidence merely because its saved key/attempt is older.
            guard proof.key != nil || proof.creationID != nil else {
                lifecycle = .unresolved(identity, .staleIdentity)
                return
            }
            identity = HCPanelIdentity(panelID: identity.panelID, key: proof.key ?? identity.key,
                persistence: identity.persistence, creationID: proof.creationID ?? identity.creationID,
                origin: identity.origin)
            lifecycle = .ended(proof)
            replacementKey = nil
            creation = nil
        case .live(let record):
            acceptLive(record)
        }
    }

    /// Called immediately before the surface asks HCSession.create. The
    /// backend still owns durable intent admission and one-use end evidence.
    @discardableResult
    mutating func willCreate(_ creationID: UUID) -> Bool {
        let end: HCEndEvidence?
        switch lifecycle {
        case .new:
            guard identity.key == nil, identity.creationID == nil else { return false }
            end = nil
        case .ended(let proof): end = proof
        case .live, .unresolved: return false
        }
        guard creation == nil else { return false }
        creation = Creation(id: creationID, replacing: end)
        identity = HCPanelIdentity(panelID: identity.panelID, key: identity.key,
            persistence: identity.persistence, creationID: creationID, origin: identity.origin)
        lifecycle = .unresolved(identity, .creationPending)
        return true
    }

    /// C11H-313: the attempt was queued behind another creation of this panel
    /// (a reveal while the hidden start's creation was still preparing), and
    /// the session bound it to the terminal that creation made. That creation
    /// is the panel's now; the attempt never ran. Only the runtime's own create
    /// result calls this, never a live record seen in the inventory.
    mutating func adopt(_ made: UUID, for attempt: UUID) {
        guard let current = creation, current.id == attempt else { return }
        creation = Creation(id: made, replacing: current.replacing)
        identity = HCPanelIdentity(panelID: identity.panelID, key: identity.key,
            persistence: identity.persistence, creationID: made, origin: identity.origin)
    }

    mutating func didCreate(_ result: HCCreateResult, creationID: UUID) {
        guard creation?.id == creationID else { return }
        switch result {
        case .bound(let record): acceptLive(record)
        case .unresolved(let reported, let reason): receive(.unresolved(reported, reason))
        case .rejectedBeforeTransmission(let reason):
            // A definite refusal still needs a new resolve from HCSession;
            // this projection cannot authorize another attempt itself.
            lifecycle = .unresolved(identity, reason)
            creation = nil
        }
    }

    private mutating func acceptLive(_ record: HCTerminalRecord) {
        guard record.state == .running, record.pid != nil,
              record.machineAvailability == .local || record.machineAvailability == .connected else {
            lifecycle = .unresolved(identity, .creationPending)
            return
        }
        let matchesAttempt = creation.map { attempt in
            record.labels["c11.panel"].flatMap(UUID.init(uuidString:)) == identity.panelID
                && record.labels["c11.creation"].flatMap(UUID.init(uuidString:)) == attempt.id
        } ?? false
        // A delayed label reconciliation is as authoritative as the original
        // create reply, but neither may bind another/superseded attempt.
        if creation != nil {
            guard matchesAttempt else {
                lifecycle = .unresolved(identity, .staleIdentity)
                return
            }
        }
        if let attempt = creation {
            if let end = attempt.replacing, end.key != record.key {
                replacementKey = record.key
            }
            creation = nil
        }
        identity = HCPanelIdentity(panelID: identity.panelID, key: record.key,
            persistence: identity.persistence,
            creationID: record.labels["c11.creation"].flatMap(UUID.init(uuidString:)) ?? identity.creationID,
            origin: identity.origin)
        lifecycle = .live(record)
    }
}
