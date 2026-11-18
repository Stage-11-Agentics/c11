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
        coordinator.requestEnd([identity], origin: origin)
        C11TipCenter.noteSessionsEnded(count: endsLiveSession ? 1 : 0, window: hostedView.window)
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
        var liveEnds = 0
        let identities = panelIds.compactMap { panelId -> HCPanelIdentity? in
            guard let panel = terminalPanel(for: panelId), let identity = panel.hcEndIdentity else { return nil }
            if panel.hcEndsLiveSession { liveEnds += 1 }
            panel.hcClosingForEnd = true
            return identity
        }
        coordinator.requestEnd(identities, origin: origin)
        let window = panelIds.lazy.compactMap { self.terminalPanel(for: $0)?.hostedView.window }.first
        C11TipCenter.noteSessionsEnded(count: liveEnds, window: window)
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
