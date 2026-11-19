import Foundation
import Bonsplit

enum PanelActivityResolver {
    static func resolve(
        hasExactSurfaceNotification: Bool,
        hasJournalAttention: Bool = false,
        derivedActivity: SidebarActivityState?,
        isCold: Bool = false,
        terminalType: String?,
        flagged: Bool = false,
        suppressed: Bool = false
    ) -> BonsplitTabActivityState? {
        if hasExactSurfaceNotification || hasJournalAttention {
            if suppressed && !flagged { return .idle }
            return .waiting
        }
        guard AreaSizePolicy.isAgentKind(terminalType) else {
            return nil
        }
        // Cold only ever describes an agent at rest; a sweep that landed after
        // the agent started working again cannot show it cold.
        if isCold, derivedActivity != .working {
            return .cold
        }
        switch derivedActivity {
        case .working:
            return .running
        case .idle:
            return .idle
        case nil:
            // A live agent without liveness evidence has not crossed the
            // configured dormancy threshold. Keep it warm until the
            // reconciler has an actual last-touch timestamp to compare.
            return .idle
        }
    }
}

/// Where an agent lifecycle edge came from. The sidebar treats them alike;
/// the mailbox stdin gate trusts only `reported` prompt edges and `submit`
/// Returns, because a notification-inferred idle can be a permission prompt.
enum AgentLifecycleSource: Equatable {
    /// An explicit lifecycle report from the agent's hooks or wrapper
    /// (`report_agent_activity`, the Codex turn-complete notify).
    case reported
    /// A submit Return typed into the tab.
    case submit
    /// Inferred from a notification or other indirect evidence.
    case inferred
    /// A report from an agent that never reads its terminal (`claude -p`,
    /// `--bg`, a piped run, or any report without the interactive marker):
    /// the tab is an agent, but never one resting at a prompt.
    case headless
}

enum PanelActivityTerminalKindResolver {
    static func resolve(
        detectedTerminalType: String?,
        declaredTerminalType: String?
    ) -> String? {
        if detectedTerminalType == "shell" {
            return "shell"
        }
        if AreaSizePolicy.isAgentKind(detectedTerminalType) {
            return detectedTerminalType
        }
        return declaredTerminalType
    }
}

/// C11-162 (Telemetry truth) — TEL-3/4.
///
/// Derives a surface's sidebar liveness truth (`working` / `idle`) from its
/// shell-activity ground state and persists it as the canonical `activity`
/// metadata key at the `.derived` precedence tier, then mirrors it onto the
/// owning `Workspace`'s published `derivedActivityBySurface` for the sidebar.
///
/// The metadata store is the durable *truth*; the Workspace published dict is
/// a fast-read projection of it. Both are kept in sync here.
///
/// Threading: all compute + store writes are off-main-safe (the store is its
/// own serialised queue). The only main-actor work is the
/// `Workspace.setDerivedActivity` mirror, which is dispatched explicitly via
/// `DispatchQueue.main.async` + `MainActor.assumeIsolated`. Nothing here ever
/// runs on the typing hot paths.
enum PanelLivenessDeriver {

    /// Off-main compute queue for the realtime transition path. Keeps the
    /// caller's thread (which may be the main actor, since
    /// `Workspace.updatePanelShellActivityState` is `@MainActor`) off the
    /// metadata store's serialised queue.
    private static let queue = DispatchQueue(
        label: "com.stage11.c11.surface-liveness",
        qos: .utility
    )

    /// Recency threshold, in seconds, past which a surface still recorded as
    /// `working` with no fresh `SurfaceActivityTracker` activity decays to
    /// `idle` on the coarse reconcile sweep. Chosen comfortably larger than
    /// the 10 s sweep interval so a single missed sweep never trips a decay.
    static let idleDecayThreshold: TimeInterval = 45

    /// An agent panel's `working` that only its shell wrote (the agent TUI is
    /// the shell's running command) and nothing has touched for this long
    /// decays to unknown (C11-398). A resumed session that never reports an
    /// edge would otherwise read as working for hours.
    static let agentShellWorkingDecay: TimeInterval = 120

    /// Journal-backed agents this deriver last published with an expired
    /// prompt cache. Touched only on `queue`.
    private nonisolated(unsafe) static var journalCacheExpiredSurfaceIds = Set<UUID>()

    /// Surfaces whose current derived `working` came from the shell path and
    /// no agent edge since. Touched only on `queue`.
    private nonisolated(unsafe) static var shellWorkingSurfaceIds = Set<UUID>()

    /// hc's last word for a local agent terminal, raw and with hc's own time:
    /// the agent's own OSC 7501 report, which hc keeps across a c11 relaunch
    /// (C11H-323). Every use judges it again (`admitHCWord`). Touched only on
    /// `queue`.
    private nonisolated(unsafe) static var hcStatusWords: [UUID: HCStatusWord] = [:]

    /// Surfaces whose current derived activity hc's word wrote, with no shell,
    /// agent or journal edge since. Touched only on `queue`.
    private nonisolated(unsafe) static var hcWrittenSurfaceIds = Set<UUID>()

    /// Surfaces whose current derived activity a journal projection wrote,
    /// with no edge since: the claim the journal withdraws once its row is
    /// historical. Touched only on `queue`.
    private nonisolated(unsafe) static var journalWrittenSurfaceIds = Set<UUID>()

    // MARK: - Mapping (TEL-3/4)

    /// Ground shell-activity state → sidebar activity truth.
    ///
    /// - `.commandRunning` ⇒ `.working`
    /// - `.promptIdle`     ⇒ `.idle`
    /// - `.unknown`        ⇒ `nil` (no truth; the key is cleared)
    static func activityState(
        for shell: Workspace.PanelShellActivityState
    ) -> SidebarActivityState? {
        switch shell {
        case .commandRunning: return .working
        case .promptIdle:     return .idle
        case .unknown:        return nil
        }
    }

    // MARK: - Realtime transition (TEL-3/4)

    /// Called on every applied `PanelShellActivityState` transition (from
    /// `Workspace.updatePanelShellActivityState`, main actor). Computes the
    /// derived activity truth, writes/clears the canonical `activity` key at
    /// the `.derived` tier, and mirrors it onto the Workspace.
    ///
    /// - Note: The compute + store write are hopped onto `Self.queue` so the
    ///   (possibly main-actor) caller never blocks on the store queue.
    static func onShellActivityChanged(
        surfaceId: UUID,
        workspaceId: UUID,
        state: Workspace.PanelShellActivityState,
        workspace: Workspace
    ) {
        onShellActivityChanged(surfaceId: surfaceId, workspaceId: workspaceId, state: state) { mirrored in
            workspace.setAgentCold(false, forSurface: surfaceId)
            workspace.setDerivedActivity(mirrored, forSurface: surfaceId)
        }
    }

    /// The same transition with the main-actor mirror passed in. Tests drive
    /// the store side through it without constructing a `Workspace`.
    static func onShellActivityChanged(
        surfaceId: UUID,
        workspaceId: UUID,
        state: Workspace.PanelShellActivityState,
        mirror: @escaping @MainActor (SidebarActivityState?) -> Void
    ) {
        let derived = activityState(for: state)
        PanelActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        queue.async {
            guard JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
            // Reconcile and realtime writes share this queue with journal projection.
            let prior = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            applyToStore(derived: derived, workspaceId: workspaceId, surfaceId: surfaceId)
            // Fire the seam on the *actual* post-write truth, not the intended
            // value: a higher-tier (`.explicit`/`.osc`) value can precedence-
            // reject the derived write, in which case no real transition
            // happened.
            let after = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            if derived == .working, after == SidebarActivityState.working.rawValue {
                shellWorkingSurfaceIds.insert(surfaceId)
            } else {
                shellWorkingSurfaceIds.remove(surfaceId)
            }
            hcWrittenSurfaceIds.remove(surfaceId)
            journalWrittenSurfaceIds.remove(surfaceId)
            if prior != after {
                emitLivenessTransition(from: prior, to: after, surfaceId: surfaceId, workspaceId: workspaceId)
            }
            // Mirror the *post-write* store truth (not the intended `derived`)
            // onto the main-actor Workspace projection, so the sidebar can never
            // show a value the store precedence-rejected. "Store is truth."
            let mirrored = after.flatMap { SidebarActivityState(rawValue: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
                    mirror(mirrored)
                }
            }
        }
    }

    /// The panel's terminal ended: nothing runs there, so it has no lifecycle.
    /// A `working` restored from the last session, or the last one seen before
    /// the end, must not outlive its process (C11H-321). An agent that died
    /// with its terminal (a reboot, a crash, a kill) sends no SessionEnd, so
    /// its journal can still read live: that connection ends first, through
    /// the reducer's `connection_lost`, as a lost remote link does, and no
    /// later projection of it can paint working. The clear is then the
    /// terminal's own word and passes the live-journal veto; store precedence
    /// still keeps an explicit or OSC activity. A live survivor or a
    /// reconnecting terminal never comes here.
    static func onTerminalEnded(
        surfaceId: UUID,
        workspaceId: UUID,
        mirror: @escaping @MainActor (SidebarActivityState?) -> Void
    ) {
        queue.async {
            let journal = JournalCoordinator.shared
            if journal.snapshot(panelID: surfaceId)?.connection == .live,
               let owner = journal.exactOwner(panelID: surfaceId) {
                let lost = JournalDraft(kind: .stateChanged,
                    emittedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    panelID: surfaceId, workspaceID: workspaceId, sessionID: owner.sessionID,
                    agentKind: owner.agentKind, source: .c11, adapter: .c11,
                    nativeEvent: "connection_lost", signal: .connectionLost)
                _ = try? journal.append(lost)
            }
            shellWorkingSurfaceIds.remove(surfaceId)
            journalCacheExpiredSurfaceIds.remove(surfaceId)
            hcStatusWords.removeValue(forKey: surfaceId)
            hcWrittenSurfaceIds.remove(surfaceId)
            journalWrittenSurfaceIds.remove(surfaceId)
            let prior = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            applyToStore(derived: nil, workspaceId: workspaceId, surfaceId: surfaceId, journal: true)
            let after = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            if prior != after {
                emitLivenessTransition(from: prior, to: after, surfaceId: surfaceId, workspaceId: workspaceId)
            }
            let mirrored = after.flatMap(SidebarActivityState.init(rawValue:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Like every mirror here: a journal still live (its disconnect
                    // was not written) owns the projection.
                    guard JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
                    mirror(mirrored)
                }
            }
        }
    }

    /// Which lifecycle edges reach the mailbox gate for a panel whose journal
    /// connection is live. Notification-inferred and headless edges never do.
    static func forwardsToMailboxGateWhileJournalLive(_ source: AgentLifecycleSource) -> Bool {
        source == .submit || source == .reported
    }

    /// Exact agent-loop lifecycle signal. Claude/Codex wrappers and terminal
    /// completion/input seams use this when they know whether the agent is at
    /// its prompt or actively handling a turn. This deliberately updates the
    /// same derived truth as the shell fallback, without pretending the outer
    /// shell's long-running TUI process is itself useful activity.
    static func onAgentLifecycleChanged(
        surfaceId: UUID,
        workspaceId: UUID,
        activity: SidebarActivityState,
        source: AgentLifecycleSource = .inferred,
        at eventAt: Date = Date(),
        agentPid: pid_t? = nil
    ) {
        PanelActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        queue.async {
            if JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection == .live {
                // The journal owns the sidebar, but neither a Return nor an explicit
                // wrapper report (interactive PID: Grok's turn watcher, the Codex
                // launch seed) can invent a journal turn. Both still reach the
                // mailbox gate; for Grok they are its only native edges (C11-365).
                if forwardsToMailboxGateWhileJournalLive(source) {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId)?
                                .workspaces.first(where: { $0.id == workspaceId })?
                                .noteMailboxAgentLifecycle(surfaceId: surfaceId, source: source, activity: activity,
                                                           at: eventAt, agentPid: agentPid)
                        }
                    }
                }
                return
            }
            shellWorkingSurfaceIds.remove(surfaceId)
            hcWrittenSurfaceIds.remove(surfaceId)
            journalWrittenSurfaceIds.remove(surfaceId)
            let prior = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            applyToStore(
                derived: activity,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            let after = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            if prior != after {
                emitLivenessTransition(
                    from: prior,
                    to: after,
                    surfaceId: surfaceId,
                    workspaceId: workspaceId
                )
            }
            let mirrored = after.flatMap { SidebarActivityState(rawValue: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let workspaceManager = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                          let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else {
                        return
                    }
                    guard JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
                    workspace.setAgentCold(false, forSurface: surfaceId)
                    workspace.setDerivedActivity(mirrored, forSurface: surfaceId)
                    workspace.noteMailboxAgentLifecycle(
                        surfaceId: surfaceId,
                        source: source,
                        activity: activity,
                        at: eventAt,
                        agentPid: agentPid
                    )
                }
            }
        }
    }

    /// Committed immutable projection. The main hop only mirrors current cache data.
    ///
    /// Snapshots coalesce; mailbox turn edges mostly do not. A boundary whose
    /// snapshot a newer one already replaced still reaches the gate when the
    /// current state agrees with it (`JournalMailboxBoundary.stillHolds`): a
    /// Codex notify can refresh the transcript's turn end 25 ms later, and
    /// dropping that projection must not drop the turn end (C11-365).
    static func onJournalProjection(panelID: UUID, snapshot: JournalSnapshot?, boundary: JournalMailboxBoundary?) {
        queue.async {
            let coordinator = JournalCoordinator.shared
            guard let workspaceID = coordinator.target(panelID: panelID) else { return }
            guard coordinator.snapshot(panelID: panelID) == snapshot else {
                if let boundary, boundary.stillHolds(projected: snapshot, current: coordinator.snapshot(panelID: panelID)) {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard coordinator.target(panelID: panelID) == workspaceID,
                                  boundary.stillHolds(projected: snapshot, current: coordinator.snapshot(panelID: panelID)),
                                  let workspace = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceID)?
                                    .workspaces.first(where: { $0.id == workspaceID }) else { return }
                            workspace.noteMailboxBoundary(boundary, panelID: panelID)
                        }
                    }
                }
                return
            }
            if let snapshot, !snapshot.isHistorical {
                PanelActivityTracker.shared.recordActivity(surfaceId: panelID.uuidString,
                    at: Date(timeIntervalSince1970: Double(snapshot.observedAtMs) / 1000))
            }
            let prior = currentActivityRaw(workspaceId: workspaceID, surfaceId: panelID)
            // A row from an earlier process, or one whose connection ended,
            // says nothing about the process running now. It withdraws only
            // the journal's own claim; hc's word for the terminal is then
            // admitted by the same rule as on its own path, so the result does
            // not depend on which of the two arrived first (C11H-323).
            if let snapshot, snapshot.isHistorical, !snapshot.paintsAttention {
                let withdrawsJournal = journalWrittenSurfaceIds.remove(panelID) != nil
                let admission = admitHCWord(hcStatusWords[panelID], turnEndMs: CodexTurnAuthority.turnEndMs(snapshot),
                                            prior: withdrawsJournal ? nil : prior,
                                            claim: withdrawsJournal ? nil : claim(of: panelID))
                switch admission {
                case .write(let activity):
                    applyToStore(derived: activity, workspaceId: workspaceID, surfaceId: panelID, journal: true)
                    noteHCWrite(activity, surfaceId: panelID, workspaceId: workspaceID)
                case .withdraw:
                    applyToStore(derived: nil, workspaceId: workspaceID, surfaceId: panelID, journal: true)
                    noteHCWrite(nil, surfaceId: panelID, workspaceId: workspaceID)
                case .keep:
                    if withdrawsJournal {
                        applyToStore(derived: nil, workspaceId: workspaceID, surfaceId: panelID, journal: true)
                    }
                }
            } else {
                let derived: SidebarActivityState? = snapshot.flatMap {
                    $0.phase == .unknown ? nil : ($0.phase == .working ? .working : .idle)
                }
                applyToStore(derived: derived, workspaceId: workspaceID, surfaceId: panelID, journal: true)
                shellWorkingSurfaceIds.remove(panelID)
                hcWrittenSurfaceIds.remove(panelID)
                if snapshot != nil,
                   currentActivityRaw(workspaceId: workspaceID, surfaceId: panelID) == derived?.rawValue {
                    journalWrittenSurfaceIds.insert(panelID)
                } else {
                    journalWrittenSurfaceIds.remove(panelID)
                }
            }
            let after = currentActivityRaw(workspaceId: workspaceID, surfaceId: panelID)
            if prior != after { emitLivenessTransition(from: prior, to: after, surfaceId: panelID, workspaceId: workspaceID) }
            let mirrored = after.flatMap(SidebarActivityState.init(rawValue:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard coordinator.target(panelID: panelID) == workspaceID,
                          let workspace = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceID)?
                            .workspaces.first(where: { $0.id == workspaceID }) else { return }
                    guard coordinator.snapshot(panelID: panelID) == snapshot else {
                        if let boundary, boundary.stillHolds(projected: snapshot, current: coordinator.snapshot(panelID: panelID)) {
                            workspace.noteMailboxBoundary(boundary, panelID: panelID)
                        }
                        return
                    }
                    if journalEdgeClearsCold(prior: workspace.journalByPanel[panelID], next: snapshot) {
                        workspace.setAgentCold(false, forSurface: panelID)
                    }
                    workspace.setDerivedActivity(mirrored, forSurface: panelID)
                    workspace.setJournalSnapshot(snapshot, forPanel: panelID)
                    workspace.noteJournalProjectionForMailbox(snapshot, boundary: boundary, panelID: panelID)
                }
            }
        }
    }

    // MARK: - hc status (C11H-323)

    /// hc's OSC 7501 word as a lifecycle: working is mid-turn; idle, done,
    /// blocked and error are not working (a journal shows blocked and error
    /// the same way, beside its own attention); anything else claims nothing.
    static func hcActivity(status: String?) -> SidebarActivityState? {
        switch status {
        case "working": return .working
        case "idle", "done", "blocked", "error": return .idle
        default: return nil
        }
    }

    /// hc's word for a terminal: its status and hc's own time for it.
    struct HCStatusWord: Equatable {
        let status: String
        let stampMs: Int64?
    }

    /// Who wrote a panel's current derived activity, as far as hc's word is
    /// concerned. nil: nothing, or a writer hc never moves (an agent edge, the
    /// shell's idle, an explicit or OSC value).
    enum ActivityClaim: Equatable { case hc, shellWorking, journal }

    enum HCAdmission: Equatable { case write(SidebarActivityState), withdraw, keep }

    /// The one rule for hc's word, on both of its paths (`onHCStatus`, and
    /// `onJournalProjection` for a historical row), judged against the state
    /// at the time of use. A stale word (Codex's own signal ended a turn after
    /// hc's `working` was stamped; C11H-123), an unknown word or no word is no
    /// word: it withdraws only an activity hc wrote. A word fills an empty
    /// activity and replaces hc's own or only the shell's `working` (an agent
    /// TUI's lifetime, not a turn; C11-398); any other writer keeps its value.
    static func admitHCWord(_ word: HCStatusWord?, turnEndMs: Int64?, prior: String?, claim: ActivityClaim?) -> HCAdmission {
        let activity = word.flatMap {
            CodexTurnAuthority.hcWordIsStale($0.status, hcStampMs: $0.stampMs, turnEndMs: turnEndMs)
                ? nil : hcActivity(status: $0.status)
        }
        guard let activity else { return claim == .hc ? .withdraw : .keep }
        return prior == nil || claim == .hc || claim == .shellWorking ? .write(activity) : .keep
    }

    private static func claim(of surfaceId: UUID) -> ActivityClaim? {
        if hcWrittenSurfaceIds.contains(surfaceId) { return .hc }
        if journalWrittenSurfaceIds.contains(surfaceId) { return .journal }
        return shellWorkingSurfaceIds.contains(surfaceId) ? .shellWorking : nil
    }

    /// hc's word was written (nil: withdrawn): hc owns what the store took.
    private static func noteHCWrite(_ activity: SidebarActivityState?, surfaceId: UUID, workspaceId: UUID) {
        shellWorkingSurfaceIds.remove(surfaceId)
        journalWrittenSurfaceIds.remove(surfaceId)
        if let activity, currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId) == activity.rawValue {
            hcWrittenSurfaceIds.insert(surfaceId)
        } else {
            hcWrittenSurfaceIds.remove(surfaceId)
        }
    }

    /// hc reported a local terminal's agent status (nil: no agent in front,
    /// or no word). hc keeps that status across a c11 relaunch, so it is a
    /// survivor's real read where nothing newer speaks for the panel: no live
    /// journal, and `admitHCWord` against the journal as it is now. An agent,
    /// shell or journal edge owns the activity from then on.
    static func onHCStatus(
        surfaceId: UUID,
        workspaceId: UUID,
        word: HCStatusWord?,
        mirror: @escaping @MainActor (SidebarActivityState?) -> Void
    ) {
        queue.async {
            if let word { hcStatusWords[surfaceId] = word } else { hcStatusWords.removeValue(forKey: surfaceId) }
            let journal = JournalCoordinator.shared.snapshot(panelID: surfaceId)
            guard journal?.connection != .live else { return }
            let prior = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            let activity: SidebarActivityState?
            switch admitHCWord(word, turnEndMs: CodexTurnAuthority.turnEndMs(journal), prior: prior,
                               claim: claim(of: surfaceId)) {
            case .keep: return
            case .withdraw: activity = nil
            case .write(let written): activity = written
            }
            applyToStore(derived: activity, workspaceId: workspaceId, surfaceId: surfaceId)
            noteHCWrite(activity, surfaceId: surfaceId, workspaceId: workspaceId)
            let after = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            // An unchanged word is no edge: it leaves a cold mark alone.
            guard prior != after else { return }
            emitLivenessTransition(from: prior, to: after, surfaceId: surfaceId, workspaceId: workspaceId)
            let mirrored = after.flatMap(SidebarActivityState.init(rawValue:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
                    mirror(mirrored)
                }
            }
        }
    }

    // MARK: - Coarse reconcile (TEL-4/5)

    /// Coarse recompute entry point invoked from the AgentDetector 10 s sweep,
    /// once per swept surface, on that sweep's utility queue (already off-main).
    ///
    /// Backstop only: the realtime path keeps liveness current on every real
    /// transition. This catches the case where a `working` surface finished
    /// its command without a `prompt` report ever arriving — it decays to
    /// `idle` once `SurfaceActivityTracker` recency for the surface goes stale.
    ///
    /// Cheap and side-effect-light: it never fabricates a truth for a surface
    /// that has none (absent key stays absent), and never overrides an
    /// externally-owned (`.explicit`/`.osc`) `activity` value.
    static func reconcile(
        surfaceId: UUID,
        workspaceId: UUID,
        detectedTerminalType: String? = nil,
        now: Date = Date(),
        coldAfterSeconds: TimeInterval = SidebarAgentColdSettings.thresholdSeconds()
    ) {
        queue.sync {
            reconcileOnQueue(surfaceId: surfaceId, workspaceId: workspaceId,
                detectedTerminalType: detectedTerminalType, now: now, coldAfterSeconds: coldAfterSeconds)
        }
    }

    private static func reconcileOnQueue(surfaceId: UUID, workspaceId: UUID,
        detectedTerminalType: String?, now: Date, coldAfterSeconds: TimeInterval) {
        // The transcript c11 reads or a report over the socket, whichever is newer.
        let promptCache = PromptCacheSources.reading(forPanel: surfaceId, now: now)
        if let journal = JournalCoordinator.shared.snapshot(panelID: surfaceId), journal.connection == .live {
            // The journal owns a live agent's activity and has no dormancy
            // rule: only prompt cache evidence can make it cold.
            let state = journalPromptCacheState(
                phase: journal.phase,
                restingSince: Date(timeIntervalSince1970: Double(journal.sinceMs) / 1000),
                promptCache: promptCache,
                now: now
            )
            // Journal projections clear cold on every edge, so a warm sweep
            // hops to main only to undo what this deriver published.
            if state.cacheExpired || journalCacheExpiredSurfaceIds.contains(surfaceId) {
                publishJournalCold(state, workspaceId: workspaceId, surfaceId: surfaceId, observed: journal)
            }
            if state.cacheExpired {
                journalCacheExpiredSurfaceIds.insert(surfaceId)
            } else {
                journalCacheExpiredSurfaceIds.remove(surfaceId)
            }
            return
        }
        journalCacheExpiredSurfaceIds.remove(surfaceId)
        let snap = PanelMetadataStore.shared.getMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        let last = PanelActivityTracker.shared.lastActivity(for: surfaceId.uuidString)
        guard snap.metadata[MetadataKey.activity] != nil else {
            // No lifecycle truth, which the resolver draws as idle: a resumed
            // agent whose journal has not reconnected, or whose shell-only
            // working decayed. Cold still follows its prompt cache (C11H-321);
            // with no cache evidence it stays warm.
            let cacheCold = isPromptCacheCold(promptCache, restingSince: last, now: now) == true
            publishCold(cacheCold, promptCacheExpired: cacheCold, workspaceId: workspaceId,
                        surfaceId: surfaceId, observedLastTouchedAt: last ?? .distantPast)
            return
        }
        // Only act on our own derived truth; leave externally-set values alone.
        guard let record = snap.sources[MetadataKey.activity],
              (record["source"] as? String) == MetadataSource.derived.rawValue,
              let current = snap.metadata[MetadataKey.activity] as? String else {
            publishCold(false, workspaceId: workspaceId, surfaceId: surfaceId)
            return
        }

        let metadataTouch = (record["ts"] as? Double).map(Date.init(timeIntervalSince1970:))
        let lastTouched = [last, metadataTouch].compactMap { $0 }.max()

        if current == SidebarActivityState.idle.rawValue {
            // Cold follows the prompt cache where the transcript describes it;
            // otherwise it is the dormancy threshold.
            let cacheCold = isPromptCacheCold(promptCache, restingSince: metadataTouch, now: now)
            publishCold(
                cacheCold ?? Self.isCold(
                    activity: .idle,
                    lastTouchedAt: lastTouched,
                    now: now,
                    coldAfterSeconds: coldAfterSeconds
                ),
                promptCacheExpired: cacheCold == true,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                observedLastTouchedAt: lastTouched
            )
            return
        }

        publishCold(false, workspaceId: workspaceId, surfaceId: surfaceId)

        // Only `working` can decay to idle. Any other externally-restored
        // vocabulary is left untouched.
        guard current == SidebarActivityState.working.rawValue else { return }

        // A foreground agent TUI is itself live evidence. Its outer shell
        // remains in one long-running command for the entire session, while
        // SurfaceActivityTracker only sees input and lifecycle edges—not
        // ongoing model work or tool output. Decaying that sparse evidence
        // after 45 seconds makes a visibly-working Codex (and other agent
        // TUIs) render idle. Exact lifecycle completion signals own the
        // working→idle transition for detected agents; retain the timeout
        // only as the fallback for ordinary shell commands.
        //
        // That holds only for a `working` some agent edge wrote. One only the
        // shell wrote is the TUI's lifetime, not a turn: with nothing newer
        // for `agentShellWorkingDecay` it decays to unknown (C11-398). A
        // prompt cache read cold after its last touch ends it at once: no
        // request since, so no turn (C11H-321: a resume c11 typed after a
        // reboot drew working for the whole window).
        guard !AreaSizePolicy.isAgentKind(detectedTerminalType) else {
            let cacheCold = isPromptCacheCold(promptCache, restingSince: lastTouched, now: now) == true
            guard shellWorkingSurfaceIds.contains(surfaceId),
                  cacheCold || lastTouched.map({ now.timeIntervalSince($0) >= agentShellWorkingDecay }) ?? true
            else { return }
            shellWorkingSurfaceIds.remove(surfaceId)
            applyToStore(derived: nil, workspaceId: workspaceId, surfaceId: surfaceId)
            if cacheCold {
                publishCold(true, promptCacheExpired: true, workspaceId: workspaceId, surfaceId: surfaceId,
                            observedLastTouchedAt: lastTouched ?? .distantPast)
            }
            #if DEBUG
            dlog("surface.liveness.agentShellWorkingDecayed surface=\(surfaceId.uuidString.prefix(5))")
            #endif
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let workspace = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId)?
                            .workspaces.first(where: { $0.id == workspaceId }) else { return }
                    guard JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
                    workspace.setDerivedActivity(nil, forSurface: surfaceId)
                }
            }
            return
        }

        let isStale = last.map { now.timeIntervalSince($0) >= idleDecayThreshold } ?? true
        guard isStale else { return }

        applyToStore(derived: .idle, workspaceId: workspaceId, surfaceId: surfaceId)
        PanelActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString, at: now)
        emitLivenessTransition(
            from: SidebarActivityState.working.rawValue,
            to: SidebarActivityState.idle.rawValue,
            surfaceId: surfaceId,
            workspaceId: workspaceId
        )
        // Mirror onto the Workspace projection if it is currently resident.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let workspaceManager = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                      let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else {
                    return
                }
                guard JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
                workspace.setAgentCold(false, forSurface: surfaceId)
                workspace.setDerivedActivity(.idle, forSurface: surfaceId)
            }
        }
    }

    /// Pure live-agent dormancy classifier. Missing touch evidence fails warm:
    /// absence of telemetry is not enough to claim that a live agent has been
    /// untouched for the configured interval.
    static func isCold(
        activity: SidebarActivityState?,
        lastTouchedAt: Date?,
        now: Date,
        coldAfterSeconds: TimeInterval
    ) -> Bool {
        guard activity == .idle, let lastTouchedAt else { return false }
        return now.timeIntervalSince(lastTouchedAt) >= max(0, coldAfterSeconds)
    }

    /// Whether the agent's prompt cache has gone cold, or nil when c11 has no
    /// cache evidence and the caller falls back to dormancy. A reading taken
    /// before the agent came to rest may predate its last request, so it fails
    /// warm until the next sweep reads the transcript again.
    static func isPromptCacheCold(
        _ reading: PromptCacheReading?,
        restingSince: Date?,
        now: Date,
        estimateOverride: TimeInterval? = PromptCachePolicy.estimateOverride
    ) -> Bool? {
        guard let reading, let observation = reading.observation else { return nil }
        if let restingSince, reading.scannedAt < restingSince { return false }
        return observation.isCold(at: now, estimateOverride: estimateOverride)
    }

    /// A journal-backed agent has no dormancy rule. At rest (idle, or blocked
    /// on the operator) its cache can expire; only an idle one shows cold, and
    /// a blocked one keeps its waiting mark with the expiry in text.
    static func journalPromptCacheState(
        phase: JournalPhase,
        restingSince: Date,
        promptCache: PromptCacheReading?,
        now: Date,
        estimateOverride: TimeInterval? = PromptCachePolicy.estimateOverride
    ) -> (cold: Bool, cacheExpired: Bool) {
        guard phase == .idle || phase == .blocked else { return (false, false) }
        let expired = isPromptCacheCold(
            promptCache, restingSince: restingSince, now: now, estimateOverride: estimateOverride
        ) == true
        return (phase == .idle && expired, expired)
    }

    /// Whether a journal projection is an edge that clears cold. One that
    /// leaves the agent resting where it was (a health or evidence publish)
    /// keeps it.
    static func journalEdgeClearsCold(prior: JournalSnapshot?, next: JournalSnapshot?) -> Bool {
        guard let prior, let next else { return true }
        return !(isResting(prior.phase) && prior.phase == next.phase && prior.sinceMs == next.sinceMs)
    }

    /// Whether the journal still shows the resting state a sweep read.
    static func journalStillRests(_ current: JournalSnapshot?, as observed: JournalSnapshot) -> Bool {
        guard let current, current.connection == .live, isResting(current.phase) else { return false }
        return current.phase == observed.phase && current.sinceMs == observed.sinceMs
    }

    private static func isResting(_ phase: JournalPhase) -> Bool {
        phase == .idle || phase == .blocked
    }

    /// Forget published state for surfaces the sweep no longer sees.
    static func retainSurfaceState(forLiveSurfaces live: Set<UUID>) {
        queue.sync {
            journalCacheExpiredSurfaceIds.formIntersection(live)
            shellWorkingSurfaceIds.formIntersection(live)
            // hc's word belongs to every open panel, not only those the sweep
            // sees with a tty: a hidden survivor may have none yet. A closed
            // panel leaves the journal's registry.
            let open = JournalCoordinator.shared.registeredTargets()
            hcWrittenSurfaceIds = hcWrittenSurfaceIds.filter { open[$0] != nil }
            journalWrittenSurfaceIds = journalWrittenSurfaceIds.filter { open[$0] != nil }
            hcStatusWords = hcStatusWords.filter { open[$0.key] != nil }
        }
    }

    /// A journal-backed agent's cache state, published only while the journal
    /// still shows the resting state this sweep read.
    private static func publishJournalCold(
        _ state: (cold: Bool, cacheExpired: Bool),
        workspaceId: UUID,
        surfaceId: UUID,
        observed: JournalSnapshot
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let workspace = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId)?
                        .workspaces.first(where: { $0.id == workspaceId }) else { return }
                if state.cacheExpired {
                    guard journalStillRests(JournalCoordinator.shared.snapshot(panelID: surfaceId), as: observed) else { return }
                }
                workspace.setAgentCold(state.cold, promptCacheExpired: state.cacheExpired, forSurface: surfaceId)
            }
        }
    }

    #if DEBUG
    /// Test seam: each cold verdict the sweep reaches for a panel without a
    /// live journal, seen on the deriver's queue before the main hop applies it.
    nonisolated(unsafe) static var coldVerdictObserver: ((_ surfaceId: UUID, _ cold: Bool, _ promptCacheExpired: Bool) -> Void)?

    /// Test seam: returns once every write queued on the deriver so far has run.
    static func drainForTesting() { queue.sync {} }
    #endif

    private static func publishCold(
        _ isCold: Bool,
        promptCacheExpired: Bool = false,
        workspaceId: UUID,
        surfaceId: UUID,
        observedLastTouchedAt: Date? = nil
    ) {
        #if DEBUG
        coldVerdictObserver?(surfaceId, isCold, promptCacheExpired)
        #endif
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let workspaceManager = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                      let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else {
                    return
                }
                guard JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
                if isCold,
                   let observedLastTouchedAt,
                   let currentLastTouchedAt = PanelActivityTracker.shared.lastActivity(
                       for: surfaceId.uuidString
                   ),
                   currentLastTouchedAt > observedLastTouchedAt {
                    // A lifecycle/input signal landed after this sweep read its
                    // snapshot. Never let that stale sweep re-cold the agent.
                    workspace.setAgentCold(false, forSurface: surfaceId)
                    return
                }
                workspace.setAgentCold(isCold, promptCacheExpired: promptCacheExpired, forSurface: surfaceId)
            }
        }
    }

    // MARK: - Store application

    /// Read the current raw `activity` value (nil when unset). Off-main-safe.
    private static func currentActivityRaw(workspaceId: UUID, surfaceId: UUID) -> String? {
        let snap = PanelMetadataStore.shared.getMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        return snap.metadata[MetadataKey.activity] as? String
    }

    /// Write (or clear) the canonical `activity` key at the `.derived` tier.
    /// `nil` clears; both operations are precedence-gated by the store so a
    /// higher-tier (`.explicit`/`.osc`) value is never clobbered.
    private static func applyToStore(
        derived: SidebarActivityState?,
        workspaceId: UUID,
        surfaceId: UUID,
        journal: Bool = false
    ) {
        guard journal || JournalCoordinator.shared.snapshot(panelID: surfaceId)?.connection != .live else { return }
        if let derived {
            PanelMetadataStore.shared.setInternal(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                key: MetadataKey.activity,
                value: derived.rawValue,
                source: .derived
            )
        } else {
            _ = try? PanelMetadataStore.shared.clearMetadata(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                keys: [MetadataKey.activity],
                source: .derived
            )
        }
    }

    // MARK: - EVT transition seam (C11-163 / EVT-2 hook point)

    /// Single internal hook fired only on an *actual* working↔idle change
    /// (including to/from the absent/"unknown" state, represented by `nil`).
    /// This is the derived-liveness transition point EVT-2's taxonomy needs.
    ///
    /// SEAM (C11-162 ↔ C11-163), wired in C11-167: EVT (#318) ships the
    /// `liveness.derived` event type + `EventEmitter.emitDerivedLiveness(...)`;
    /// this method IS its call site. A `liveness.derived` event fires whenever
    /// the derived truth settles on a concrete state (`working`/`idle`); a
    /// transition *to* the absent/"unknown" state (`to == nil`) emits nothing,
    /// since it is not one of the derived liveness states the stub carries.
    /// Firing only on a real post-write transition — see the caller — is
    /// intentional so the event stream never emits a phantom transition for a
    /// precedence-rejected write.
    private static func emitLivenessTransition(
        from: String?,
        to: String?,
        surfaceId: UUID,
        workspaceId: UUID
    ) {
        #if DEBUG
        dlog(
            "surface.liveness.transition surface=\(surfaceId.uuidString.prefix(5)) " +
            "from=\(from ?? "-") to=\(to ?? "-")"
        )
        #endif
        // EVT-2 derived-liveness event. Emit only for a concrete destination
        // state; `emit` is internally locked + non-blocking (EVT-3), so this is
        // safe on the off-main queues both callers run on.
        if let to {
            EventEmitter.shared.emitDerivedLiveness(
                workspace: workspaceId,
                surface: surfaceId,
                state: to
            )
        }
    }
}
