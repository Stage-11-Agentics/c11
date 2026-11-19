import Foundation
import CryptoKit

/// Facts from the single hc inventory. Classification shares the local detector;
/// no remote PID is ever passed to a local process or transcript lookup.
enum HCRemoteStatus {
    static func classification(_ foreground: HCForeground?) -> String? {
        guard let foreground else { return nil }
        let name = foreground.name ?? foreground.argv?.first ?? ""
        guard !name.isEmpty else { return nil }
        return AgentDetector.classify(.init(comm: name, args: (foreground.argv ?? [name]).joined(separator: " ")))
    }

    static func owner(panelID: UUID, key: HCTerminalKey, agentKind: String) -> JournalOwner {
        // Opaque, bounded and stable across machine alias changes/relaunches.
        // This identifies hc evidence, not a provider conversation/session.
        let encoded = try! JSONEncoder().encode([key.owningCoreID, key.localAddress])
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return JournalOwner(panelID: panelID, agentKind: agentKind, sessionID: "hc-\(digest)")
    }

    static func draft(record: HCTerminalRecord, owner: JournalOwner, workspaceID: UUID,
                      observedAtMs: Int64) -> JournalDraft? {
        let signal: JournalSignal
        switch record.status {
        case "working": signal = .hcWorking
        case "blocked": signal = .hcBlocked
        case "idle": signal = .hcIdle
        case "done": signal = .hcDone
        case "error": signal = .hcError
        default: return nil
        }
        let timestamp = record.statusTimestampMilliseconds.flatMap { $0 >= 0 ? $0 : nil }
        return JournalDraft(kind: .stateChanged, emittedAtMs: observedAtMs,
                            occurredAtMs: timestamp, timeQuality: timestamp == nil ? .missing : .observed,
                            panelID: owner.panelID, workspaceID: workspaceID,
                            sessionID: owner.sessionID, agentKind: owner.agentKind,
                            source: .plugin, adapter: .hcStatus, nativeEvent: "session.status",
                            turnID: record.turn.flatMap { $0 >= 0 ? "hc-\($0)" : nil }, signal: signal)
    }

    static func reachable(_ snapshot: HCInventorySnapshot, key: HCTerminalKey) -> HCTerminalRecord? {
        // C11H-78: a record's availability comes from its own shard's line
        // (each shard's reducer decodes it against that shard's routes). The
        // merged view's machine map keeps one entry per name, so with shard
        // pairs it can name another shard's line; it is not consulted.
        guard case .ready = snapshot.readiness, let record = snapshot.records[key],
              record.machineAvailability == .connected else { return nil }
        return record
    }
}

/// C11H-98: the agent running in the foreground of a terminal hc reports as
/// running, from hc's own record (the same foreground C11H-87 reads). Nil for
/// no record, a finished terminal, or a plain shell. A terminal with a live
/// agent is never a resume candidate: the agent never stopped.
enum HCLiveAgent {
    static func kind(_ record: HCTerminalRecord?) -> String? {
        guard let record, record.state == .running,
              let kind = HCRemoteStatus.classification(record.foreground),
              AgentIdentityPolicy.isAgentKind(kind) else { return nil }
        return kind
    }
}

/// C11H-87: who reads a terminal on another machine, for the mailbox doorbell.
/// A remote terminal has no local tty or PID, so the local kernel check is
/// always false there. Ownership comes from that machine's own core: the
/// foreground program hc reports for the terminal. Only a reachable, running
/// record counts; a lost link or a missing mirror never owns. The doorbell's
/// composer, draft and trust-dialog guards still decide whether to type.
enum HCRemoteMailboxForeground {
    static func agentOwnsTerminal(_ record: HCTerminalRecord?) -> Bool {
        HCLiveAgent.kind(record) != nil
    }

    /// An OSC 7501 status change as a turn edge: `true` reached its prompt,
    /// `false` started working or is blocked on a question. Nil is no edge
    /// (unchanged, an error, no status).
    static func turnEdge(previous: String?, current: String?) -> Bool? {
        guard let current, current != previous else { return nil }
        switch current {
        case "idle", "done": return true
        case "working", "blocked": return false
        default: return nil
        }
    }
}

/// One remote panel's subscription. The runtime owns its lifetime alongside the
/// panel binding. All journal/metadata work stays on this serial utility queue;
/// presentation receives immutable facts via an asynchronous main hop.
final class HCRemoteStatusObservation: @unchecked Sendable {
    struct Presentation: Sendable {
        let record: HCTerminalRecord?
        let classification: String?
        let reconnecting: Bool
        let lifecycle: HCLifecycle

        var mailboxOwnsTerminal: Bool {
            HCRemoteMailboxForeground.agentOwnsTerminal(reconnecting ? nil : record)
        }
    }

    private let queue: DispatchQueue
    private var observation: HCObservation?
    private let panelID: UUID
    private let workspaceID: UUID
    private let key: HCTerminalKey
    private let journal: JournalCoordinator
    private let inventory: (any HCInventorySource)?
    private let present: @Sendable (Presentation) -> Void
    private var previousRevision: HCRevision?
    private var lastDraft: JournalDraft?
    private var disconnected = false
    private var lastClassification: String?
    /// C11H-205: the end this terminal reached, once seen. An end is final: a
    /// record hc later prunes (a day on) or a down line never turns it back
    /// into "Reconnecting".
    private var finished: HCEndEvidence?

    init(session: any HCSession, panelID: UUID, workspaceID: UUID, key: HCTerminalKey,
         journal: JournalCoordinator = .shared,
         queue: DispatchQueue = DispatchQueue(label: "com.stage11.c11.remote-status", qos: .utility),
         present: @escaping @Sendable (Presentation) -> Void) {
        self.queue = queue
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.key = key
        self.journal = journal
        self.inventory = session as? any HCInventorySource
        self.present = present
        observation = session.observe(on: queue) { [weak self] snapshot in self?.consume(snapshot) }
    }

    deinit { observation?.cancel() }

    private func consume(_ snapshot: HCInventorySnapshot) {
        if let previousRevision,
           snapshot.revision.connectionGeneration < previousRevision.connectionGeneration ||
            (snapshot.revision.connectionGeneration == previousRevision.connectionGeneration &&
             snapshot.revision.sequence < previousRevision.sequence) { return }
        previousRevision = snapshot.revision
        // A resnapshot has no new availability evidence. Preserve both the
        // live mailbox owner and an already-disconnected presentation.
        if case .pending(.inventoryPending) = snapshot.readiness { return }
        let identity = HCPanelIdentity(panelID: panelID, key: key)
        let lifecycle = HCLifecycleResolver.resolve(identity, snapshot: snapshot, intent: nil)
        let current = snapshot.records[key]
        if case .ready = snapshot.readiness, let current, current.state == .finished {
            finished = HCEndEvidence(id: finished?.id ?? UUID(), key: key, revision: snapshot.revision, kind: .finished,
                hcReason: current.endReason, exitCode: current.exitCode, exitSignal: current.exitSignal,
                endedAtMilliseconds: current.finishedMilliseconds ?? finished?.endedAtMilliseconds)
        }
        guard let record = HCRemoteStatus.reachable(snapshot, key: key) else {
            if let finished, current == nil || current?.state == .finished {
                disconnected = false
                present(.init(record: nil, classification: lastClassification, reconnecting: false,
                              lifecycle: .ended(finished)))
                return
            }
            // Missing mirror and actual connection uncertainty are never
            // an agent's idle/end boundary. Keep its last phase/name.
            if !disconnected, journal.snapshot(panelID: panelID)?.adapter == .hcStatus,
               let owner = journal.exactOwner(panelID: panelID) {
                let lost = JournalDraft(kind: .stateChanged,
                    emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    panelID: panelID, workspaceID: workspaceID, sessionID: owner.sessionID,
                    agentKind: owner.agentKind, source: .c11, adapter: .c11,
                    nativeEvent: "connection_lost", signal: .connectionLost)
                _ = try? journal.append(lost)
            }
            disconnected = true
            present(.init(record: nil, classification: lastClassification, reconnecting: true,
                          lifecycle: .unresolved(identity, .connectionLost)))
            return
        }
        if record.statusTimestampMilliseconds == nil, let status = record.status,
           ["working", "blocked", "idle", "done", "error"].contains(status),
           let turn = record.turn, turn >= 0, let inventory {
            // No loop/timer here: retry only after a later inventory observation.
            Task {
                _ = await inventory.enrichStatusTimestamp(for: key, matchingStatus: status,
                    turn: turn, connectionGeneration: snapshot.revision.connectionGeneration)
            }
        }
        let classification = HCRemoteStatus.classification(record.foreground) ?? lastClassification
        lastClassification = classification
        defer { present(.init(record: record, classification: classification, reconnecting: false,
                              lifecycle: lifecycle)) }
        if classification == "shell" {
            journal.setHCStatusOwner(panelID: panelID, owner: nil)
            lastDraft = nil
        }
        guard let classification, AgentIdentityPolicy.isAgentKind(classification) else { return }
        journal.setHCStatusOwner(panelID: panelID,
            owner: HCRemoteStatus.owner(panelID: panelID, key: key, agentKind: classification))
        guard let owner = journal.exactOwner(panelID: panelID), owner.agentKind == classification,
              var draft = HCRemoteStatus.draft(record: record, owner: owner, workspaceID: workspaceID,
                                               observedAtMs: Int64(Date().timeIntervalSince1970 * 1000)) else { return }
        // The inventory coalesces unrelated activity too. Append only a changed
        // status or a reconnect confirmation, rather than filling the journal.
        if let lastDraft {
            draft.eventID = lastDraft.eventID
            draft.emittedAtMs = lastDraft.emittedAtMs
            if draft == lastDraft && !disconnected { return }
        }
        draft.eventID = UUID()
        draft.emittedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        if (try? journal.appendHCStatus(draft)) != nil {
            lastDraft = draft
            disconnected = false
        }
    }
}

@MainActor
final class HCRemoteStatusBinding {
    let key: HCTerminalKey
    private var observation: HCRemoteStatusObservation?
    private weak var workspace: Workspace?
    private let panelID: UUID
    private var machineName: String?
    private var appliedClassification: String?

    init(workspace: Workspace, panelID: UUID, session: any HCSession,
         key: HCTerminalKey, machineName: String?) {
        self.workspace = workspace
        self.panelID = panelID
        self.key = key
        self.machineName = machineName
        observation = HCRemoteStatusObservation(session: session, panelID: panelID,
            workspaceID: workspace.id, key: key) { [weak self] value in
                DispatchQueue.main.async { [weak self] in self?.apply(value) }
            }
    }

    private func apply(_ value: HCRemoteStatusObservation.Presentation) {
        guard let workspace, workspace.panels[panelID] != nil else { return }
        if let record = value.record { machineName = record.machineName ?? machineName }
        workspace.noteSessionLifecycle(panelId: panelID, lifecycle: value.lifecycle,
                                       persistence: .persistent, machineName: machineName)
        if let record = value.record {
            workspace.noteHCRemoteForeground(record.foreground, panelID: panelID)
        }
        // C11H-87: the doorbell's foreground owner and turn edges come from
        // that machine's core. Reconnecting owns nothing.
        let live = value.reconnecting ? nil : value.record
        workspace.noteHCRemoteMailbox(panelID: panelID,
                                      ownsTerminal: value.mailboxOwnsTerminal,
                                      status: live?.status, statusMs: live?.statusTimestampMilliseconds,
                                      reconnecting: value.reconnecting)
        guard !value.reconnecting, let classification = value.classification,
              classification != appliedClassification else { return }
        appliedClassification = classification
        _ = PanelMetadataStore.shared.setInternal(workspaceId: workspace.id, surfaceId: panelID,
                                                   key: "terminal_type", value: classification, source: .heuristic)
        workspace.setDetectedTerminalType(classification, forSurface: panelID)
        // C11H-328: no local TTY, so the fleet sweep learns the panel here.
        AgentDetector.shared.noteRemote(workspaceId: workspace.id, panelId: panelID, kind: classification)
    }
}
