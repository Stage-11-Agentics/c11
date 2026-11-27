import Foundation

extension TerminalPanel {
    /// This panel's hc identity, or nil when the panel is exec/fallback and
    /// hc holds nothing for it. Production reads the panel's own persistent
    /// identity; the lookup is a test seam and answers nil by default.
    var hcEndIdentity: HCPanelIdentity? {
        hcIdentity ?? HCSessionEnd.identity(forPanel: id)
    }

    /// Explicit-end entry point. Called only by operator and CLI closes of a
    /// panel, area, workspace or window, never by `close()`, which detaches.
    /// Returns true when an end was requested from hc.
    @discardableResult
    func endSession(origin: HCEndOrigin) -> Bool {
        guard let identity = hcEndIdentity, let coordinator = HCSessionEnd.coordinator else { return false }
        let endsLiveSession = hcEndsLiveSession
        hcClosingForEnd = true
        hcRequestedEnd = origin
        coordinator.requestEnd([identity], origin: origin)
        // C11H-415: the tip and any hold notice follow the end's outcome, not the request.
        HCCloseOutcomeReport.observe(panelIDs: [identity.panelID], live: endsLiveSession ? [identity.panelID] : [],
                                     coordinator: coordinator, workspaceID: workspaceId, window: hostedView.window)
        return true
    }

    /// C11H-127: closing this panel ends a session that is still running, so
    /// the End Session tip is true. A panel whose terminal already ended is not.
    var hcEndsLiveSession: Bool {
        if case .ended? = hcSession?.lifecycle { return false }
        return true
    }

    /// C11H-46: every terminal key this panel holds, registered or not.
    var hcBoundKeys: Set<HCTerminalKey> {
        HCLiveBinding.boundKeys(identityKey: hcSession?.identity.key, lifecycle: hcSession?.lifecycle,
                                restoredKey: HCPanelRestoreState.shared.entry(for: id)?.identity.key)
    }

    /// C11H-46: true while this panel shows `key` live and is not being closed.
    func hcShowsLive(_ key: HCTerminalKey) -> Bool {
        HCLiveBinding.shows(key, boundKeys: hcBoundKeys, lifecycle: hcSession?.lifecycle, closing: hcClosingForEnd)
    }
}

extension Workspace {
    /// C11H-46/C11H-103: the first live panel, not being closed, that shows
    /// `key`, named by its ref, title and workspace.
    static func hcHolder(of key: HCTerminalKey, in workspaces: [Workspace],
                         ref: (UUID) -> String?) -> HCHolderAnswer {
        for workspace in workspaces {
            for panel in workspace.panels.values {
                guard let terminal = panel as? TerminalPanel, terminal.hcShowsLive(key) else { continue }
                return .held(HCEndHolder(
                    panelID: terminal.id,
                    panelRef: ref(terminal.id),
                    title: workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title))
            }
        }
        return .none
    }

    /// Explicit close of these panels ends their hc sessions. Non-terminal and
    /// exec panels are skipped. Detach paths (restore retirement, moves, Quit)
    /// never call this.
    func endSessionsForExplicitClose(panelIds: [UUID], origin: HCEndOrigin) {
        guard hcExplicitEndSuppressionDepth == 0, let coordinator = HCSessionEnd.coordinator else { return }
        var live = Set<UUID>()
        let identities = panelIds.compactMap { panelId -> HCPanelIdentity? in
            guard let panel = terminalPanel(for: panelId), let identity = panel.hcEndIdentity else { return nil }
            if panel.hcEndsLiveSession { live.insert(identity.panelID) }
            panel.hcClosingForEnd = true
            panel.hcRequestedEnd = origin
            return identity
        }
        coordinator.requestEnd(identities, origin: origin)
        let window = panelIds.lazy.compactMap { self.terminalPanel(for: $0)?.hostedView.window }.first
        // C11H-415: the tip and any hold notice follow the ends' outcomes, not the request.
        HCCloseOutcomeReport.observe(panelIDs: identities.map(\.panelID), live: live, coordinator: coordinator,
                                     workspaceID: id, window: window)
    }

    /// True when any of these panels is an hc terminal, so closing it sends
    /// hc an end request (socket replies report it as `session_end`).
    func closeHoldsHCSession(panelIds: [UUID]) -> Bool {
        panelIds.contains { terminalPanel(for: $0)?.hcEndIdentity != nil }
    }

    /// The confirmation copy's question: true when any of these panels is an hc
    /// terminal whose session may still be running. C11H-205: a panel kept
    /// after its session ended (a host end kept for recovery) has nothing left
    /// to end, so "ends its terminal session" was false; it takes the plain
    /// close copy, while its close still sends the end request.
    func closeEndsHCSession(panelIds: [UUID]) -> Bool {
        closeEndsHCSessionCount(panelIds: panelIds) > 0
    }

    /// C11H-309: how many sessions closing these panels ends, for a batch card
    /// that names the count. Same test as `closeEndsHCSession`; panels showing
    /// one terminal count once. A session a panel outside the batch still
    /// shows is kept, not ended, but is still counted here.
    func closeEndsHCSessionCount(panelIds: [UUID]) -> Int {
        var keys = Set<HCTerminalKey>()
        var keyless = 0
        for id in panelIds {
            guard let panel = terminalPanel(for: id), let identity = panel.hcEndIdentity,
                  panel.hcEndsLiveSession else { continue }
            if let key = identity.key { keys.insert(key) } else { keyless += 1 }
        }
        return keys.count + keyless
    }
}

/// C11H-103: what a close leaves behind for the rest of the run. A closed
/// id stays "closing" for Recovered, so no reconcile pass re-creates it, and
/// a panel adopted into Recovered never starts a new terminal in place of a
/// missing one (that is how closed seats came back as fresh local shells).
@MainActor
final class HCCloseTombstones {
    private(set) var adopted: Set<UUID> = []
    private(set) var closed: Set<UUID> = []

    func noteAdopted(_ panelID: UUID) { adopted.insert(panelID) }

    func noteClosedForGood(_ panelIDs: Set<UUID>) {
        closed.formUnion(panelIDs)
        adopted.subtract(panelIDs)
    }

    /// What Recovered treats as closing: pending ends plus every closed id.
    func closingPanelIDs(pending: Set<UUID>) -> Set<UUID> { pending.union(closed) }

    func mayReplaceMissingTerminal(panelID: UUID, inRecoveredWorkspace: Bool) -> Bool {
        !inRecoveredWorkspace && !adopted.contains(panelID)
    }
}

/// C11H-103: keeps a terminal's `c11.title` and `c11.workspace` labels
/// current, debounced per panel (hc saves its state on every label write).
/// Renames and moves note a change; the app supplies each panel's live key
/// and labeling session.
@MainActor
final class HCOwnerLabelSync {
    /// What the app can say about a panel when its labels are due.
    enum Target {
        /// Its live terminal and a session that can label it.
        case ready(HCTerminalKey, any HCTerminalLabeling)
        /// It exists but has no live key yet (its terminal is still being created).
        case notYet
        /// It is in no workspace, or its session cannot label: stop.
        case gone
    }

    static let shared = HCOwnerLabelSync()
    /// A trailing window: each note restarts it.
    var delay: TimeInterval = 2
    /// Attempts for a panel with no key yet, or whose write hc refused
    /// (about a minute at the default delay), before the labels are dropped.
    var maximumAttempts = 30
    var target: (UUID) -> Target = { _ in .gone }
    private var pending: [UUID: [String: String]] = [:]
    private var generation: [UUID: UInt64] = [:]
    private var attempts: [UUID: Int] = [:]
    private var inFlight: Set<UUID> = []

    func note(panelID: UUID, labels: [String: String]) {
        pending[panelID, default: [:]].merge(labels) { _, new in new }
        attempts[panelID] = 0
        schedule(panelID)
    }

    /// Labels are removed only once hc accepted them; a refusal or a missing
    /// key keeps them and tries again after `delay`.
    func flush(_ panelID: UUID) {
        guard !inFlight.contains(panelID), let labels = pending[panelID] else { return }
        switch target(panelID) {
        case .gone:
            forget(panelID)
        case .notYet:
            retry(panelID)
        case .ready(let key, let labeling):
            pending.removeValue(forKey: panelID)
            inFlight.insert(panelID)
            Task { @MainActor [weak self] in
                let sent = await labeling.setLabels(labels, on: key)
                guard let self else { return }
                self.inFlight.remove(panelID)
                if !sent {
                    // Newer notes made while this was in flight win.
                    self.pending[panelID] = labels.merging(self.pending[panelID] ?? [:]) { _, newer in newer }
                    self.retry(panelID)
                } else if self.pending[panelID] != nil {
                    self.schedule(panelID)
                } else {
                    self.attempts.removeValue(forKey: panelID)
                }
            }
        }
    }

    private func schedule(_ panelID: UUID) {
        let next = (generation[panelID] ?? 0) &+ 1
        generation[panelID] = next
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation[panelID] == next else { return }
                self.flush(panelID)
            }
        }
    }

    private func retry(_ panelID: UUID) {
        let count = (attempts[panelID] ?? 0) + 1
        attempts[panelID] = count
        guard count < maximumAttempts else {
            NSLog("hc.labels.dropped panel=%@ attempts=%ld", panelID.uuidString, count)
            forget(panelID)
            return
        }
        schedule(panelID)
    }

    private func forget(_ panelID: UUID) {
        pending.removeValue(forKey: panelID)
        generation.removeValue(forKey: panelID)
        attempts.removeValue(forKey: panelID)
    }
}

/// C11H-103: where Recovered puts an orphan, under the L4 amendment
/// (docs/c11-contract.md). Home, into its own workspace with its title, only
/// when (1) that workspace is in the restored session, (2) the launch did not
/// start fresh, and (3) it is that panel's own terminal with an unshared label.
/// Everything else goes to Recovered, as frozen L3/L4 say.
enum HCRecoveredPlacement: Equatable {
    case home(workspaceID: UUID, title: String?)
    case recovered

    static func destination(record: HCTerminalRecord, panelID: UUID, homeEligible: Bool, startedFresh: Bool,
                            workspaces: [(id: UUID, isRecovered: Bool)]) -> HCRecoveredPlacement {
        guard !startedFresh, homeEligible,
              record.labels["c11.panel"].flatMap(UUID.init(uuidString:)) == panelID,
              let home = record.labels[HCOwnerLabels.workspace].flatMap(UUID.init(uuidString:)),
              workspaces.contains(where: { $0.id == home && !$0.isRecovered }) else { return .recovered }
        let title = record.labels[HCOwnerLabels.title].flatMap { $0.isEmpty ? nil : $0 }
        return .home(workspaceID: home, title: title)
    }
}

struct HCPanelCloseCopy: Equatable {
    let title: String
    let message: String
    /// nil keeps the presenter's default "Close" label.
    let confirmLabel: String?
}

extension Workspace {
    /// Confirmation copy for closing one panel: "End session" naming what
    /// ends for an hc terminal, the plain close copy otherwise.
    static func panelCloseCopy(endsSession: Bool) -> HCPanelCloseCopy {
        if endsSession {
            return HCPanelCloseCopy(
                title: HCCloseCopy.panelTitle,
                message: HCCloseCopy.panelMessage,
                confirmLabel: HCCloseCopy.panelConfirmLabel
            )
        }
        return HCPanelCloseCopy(
            title: String(localized: "dialog.closeTab.title", defaultValue: "Close panel?"),
            message: String(localized: "dialog.closeTab.message", defaultValue: "This closes the panel."),
            confirmLabel: nil
        )
    }
}

/// C11H-434: what a panel kept after its terminal ended says on its face: why
/// and when (local time) it ended, with Start a new shell and Close. Before
/// it, End All left each panel a blank screen with a cursor and nothing else.
/// A host end (a reboot, a lost holder) keeps its own recovery notice; this
/// covers every other end a kept panel shows: End All, End Session, an exit,
/// an outside signal once its host-end banner is closed.
struct HCEndedPanelNotice: Equatable {
    enum Reason: Equatable {
        case endAll
        case endSession
        case outsideSignal(Int32)
        case exited
        /// hc ended it for a reason c11 did not ask for and does not name.
        case stopped
    }

    let reason: Reason
    let endedAt: Date
    let endedKey: HCTerminalKey?

    /// The notice for this lifecycle, or nil when the panel's terminal has not
    /// ended or a host end's recovery owns the panel. `requestedEnd` is what
    /// the operator asked for on this panel; `observedAt` stands in for an end
    /// hc did not time.
    static func make(lifecycle: HCLifecycle?, requestedEnd: HCEndOrigin?,
                     observedAt: Date) -> HCEndedPanelNotice? {
        guard case .ended(let evidence)? = lifecycle,
              !HCRestoreLifecycleProjection.isHostEnd(evidence.hcReason) else { return nil }
        let reason: Reason
        switch requestedEnd {
        case .endAll?: reason = .endAll
        case .panelClose?, .areaClose?, .workspaceClose?, .windowClose?: reason = .endSession
        case nil:
            if let signal = HCRestoreLifecycleProjection.outsideSignal(evidence) { reason = .outsideSignal(signal) }
            else if evidence.hcReason == "exited" { reason = .exited }
            else { reason = .stopped }
        }
        return HCEndedPanelNotice(reason: reason, endedAt: evidence.endedAt ?? observedAt, endedKey: evidence.key)
    }

    /// Stable token for `hc-diagnostics --json`.
    var reasonToken: String {
        switch reason {
        case .endAll: return "end_all"
        case .endSession: return "end_session"
        case .outsideSignal: return "outside_signal"
        case .exited: return "exited"
        case .stopped: return "stopped"
        }
    }

    /// The reason in the headline's parentheses.
    var reasonText: String {
        switch reason {
        case .endAll:
            return String(localized: "terminal.ended.reason.endAll", defaultValue: "End All Sessions")
        case .endSession:
            return String(localized: "terminal.ended.reason.endSession", defaultValue: "End Session")
        case .outsideSignal(let signal):
            return String(format: String(localized: "terminal.ended.reason.outsideSignal",
                defaultValue: "%@ from outside c11"), HCHostEndStatus.signalName(signal))
        case .exited:
            return String(localized: "terminal.ended.reason.exited", defaultValue: "its shell exited")
        case .stopped:
            return String(localized: "terminal.ended.reason.stopped", defaultValue: "stopped by the terminal host")
        }
    }

    /// "Session ended (End All Sessions) at 13:51." Local time, with the date
    /// when it is not today.
    var headline: String {
        String(format: String(localized: "terminal.ended.headline",
            defaultValue: "Session ended (%1$@) at %2$@."), reasonText, HCHostEndStatus.displayTime(endedAt))
    }

    var detail: String {
        String(localized: "terminal.ended.detail",
            defaultValue: "Nothing you type here is sent.")
    }

    static var startShellTitle: String {
        String(localized: "terminal.ended.startShell", defaultValue: "Start a new shell")
    }

    static var closeTitle: String {
        String(localized: "terminal.ended.close", defaultValue: "Close")
    }
}
