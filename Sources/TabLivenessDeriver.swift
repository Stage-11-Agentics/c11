import Foundation
import Bonsplit

enum TabActivityResolver {
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

enum TabActivityTerminalKindResolver {
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
enum TabLivenessDeriver {

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

    /// Journal-backed agents this deriver last published with an expired
    /// prompt cache. Touched only on `queue`.
    private nonisolated(unsafe) static var journalCacheExpiredSurfaceIds = Set<UUID>()

    // MARK: - Mapping (TEL-3/4)

    /// Ground shell-activity state → sidebar activity truth.
    ///
    /// - `.commandRunning` ⇒ `.working`
    /// - `.promptIdle`     ⇒ `.idle`
    /// - `.unknown`        ⇒ `nil` (no truth; the key is cleared)
    static func activityState(
        for shell: Workspace.TabShellActivityState
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
        state: Workspace.TabShellActivityState,
        workspace: Workspace
    ) {
        let derived = activityState(for: state)
        TabActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        queue.async {
            guard JournalCoordinator.shared.snapshot(tabID: surfaceId)?.connection != .live else { return }
            // Reconcile and realtime writes share this queue with journal projection.
            let prior = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            applyToStore(derived: derived, workspaceId: workspaceId, surfaceId: surfaceId)
            // Fire the seam on the *actual* post-write truth, not the intended
            // value: a higher-tier (`.explicit`/`.osc`) value can precedence-
            // reject the derived write, in which case no real transition
            // happened.
            let after = currentActivityRaw(workspaceId: workspaceId, surfaceId: surfaceId)
            if prior != after {
                emitLivenessTransition(from: prior, to: after, surfaceId: surfaceId, workspaceId: workspaceId)
            }
            // Mirror the *post-write* store truth (not the intended `derived`)
            // onto the main-actor Workspace projection, so the sidebar can never
            // show a value the store precedence-rejected. "Store is truth."
            let mirrored = after.flatMap { SidebarActivityState(rawValue: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard JournalCoordinator.shared.snapshot(tabID: surfaceId)?.connection != .live else { return }
                    workspace.setAgentCold(false, forSurface: surfaceId)
                    workspace.setDerivedActivity(mirrored, forSurface: surfaceId)
                }
            }
        }
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
        TabActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString)
        queue.async {
            if JournalCoordinator.shared.snapshot(tabID: surfaceId)?.connection == .live {
                // A Return still closes the mailbox prompt gate, but cannot invent a journal turn.
                if source == .submit {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId)?
                                .workspaces.first(where: { $0.id == workspaceId })?
                                .noteMailboxAgentLifecycle(surfaceId: surfaceId, source: .submit, activity: activity, at: eventAt)
                        }
                    }
                }
                return
            }
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
                    guard JournalCoordinator.shared.snapshot(tabID: surfaceId)?.connection != .live else { return }
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
    static func onJournalProjection(tabID: UUID, snapshot: JournalSnapshot?, boundary: JournalMailboxBoundary?) {
        queue.async {
            let coordinator = JournalCoordinator.shared
            guard coordinator.snapshot(tabID: tabID) == snapshot,
                  let workspaceID = coordinator.target(tabID: tabID) else { return }
            let derived: SidebarActivityState? = snapshot.flatMap {
                $0.phase == .unknown || ($0.isHistorical && !$0.paintsAttention) ? nil : ($0.phase == .working ? .working : .idle)
            }
            if let snapshot, !snapshot.isHistorical {
                TabActivityTracker.shared.recordActivity(surfaceId: tabID.uuidString,
                    at: Date(timeIntervalSince1970: Double(snapshot.observedAtMs) / 1000))
            }
            let prior = currentActivityRaw(workspaceId: workspaceID, surfaceId: tabID)
            applyToStore(derived: derived, workspaceId: workspaceID, surfaceId: tabID, journal: true)
            let after = currentActivityRaw(workspaceId: workspaceID, surfaceId: tabID)
            if prior != after { emitLivenessTransition(from: prior, to: after, surfaceId: tabID, workspaceId: workspaceID) }
            let mirrored = after.flatMap(SidebarActivityState.init(rawValue:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard coordinator.snapshot(tabID: tabID) == snapshot,
                          coordinator.target(tabID: tabID) == workspaceID,
                          let workspace = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceID)?
                            .workspaces.first(where: { $0.id == workspaceID }) else { return }
                    if journalEdgeClearsCold(prior: workspace.journalByTab[tabID], next: snapshot) {
                        workspace.setAgentCold(false, forSurface: tabID)
                    }
                    workspace.setDerivedActivity(mirrored, forSurface: tabID)
                    workspace.setJournalSnapshot(snapshot, forTab: tabID)
                    // A coalesced start may already have been superseded by its ask.
                    // Closing a prior prompt gate is safe; only the live boundary below opens it.
                    if let boundary {
                        workspace.noteMailboxAgentLifecycle(surfaceId: tabID,
                            source: boundary.pid == nil ? .headless : .reported,
                            activity: boundary.working ? .working : .idle, at: boundary.at, agentPid: boundary.pid)
                    } else if let snapshot, [.working, .blocked, .error].contains(snapshot.phase) {
                        workspace.noteMailboxAgentLifecycle(surfaceId: tabID, source: .reported,
                            activity: .working, at: Date(timeIntervalSince1970: Double(snapshot.observedAtMs) / 1000))
                    }
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
        let promptCache = AgentModelDetector.shared.promptCacheReading(forSurface: surfaceId)
        if let journal = JournalCoordinator.shared.snapshot(tabID: surfaceId), journal.connection == .live {
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
        let snap = TabMetadataStore.shared.getMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        // Only act on our own derived truth; leave externally-set values alone.
        guard let record = snap.sources[MetadataKey.activity],
              (record["source"] as? String) == MetadataSource.derived.rawValue,
              let current = snap.metadata[MetadataKey.activity] as? String else {
            publishCold(false, workspaceId: workspaceId, surfaceId: surfaceId)
            return
        }

        let last = TabActivityTracker.shared.lastActivity(for: surfaceId.uuidString)
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
        guard !AreaSizePolicy.isAgentKind(detectedTerminalType) else { return }

        let isStale = last.map { now.timeIntervalSince($0) >= idleDecayThreshold } ?? true
        guard isStale else { return }

        applyToStore(derived: .idle, workspaceId: workspaceId, surfaceId: surfaceId)
        TabActivityTracker.shared.recordActivity(surfaceId: surfaceId.uuidString, at: now)
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
                guard JournalCoordinator.shared.snapshot(tabID: surfaceId)?.connection != .live else { return }
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
    static func retainPromptCacheState(forLiveSurfaces live: Set<UUID>) {
        queue.sync { journalCacheExpiredSurfaceIds.formIntersection(live) }
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
                    guard journalStillRests(JournalCoordinator.shared.snapshot(tabID: surfaceId), as: observed) else { return }
                }
                workspace.setAgentCold(state.cold, promptCacheExpired: state.cacheExpired, forSurface: surfaceId)
            }
        }
    }

    private static func publishCold(
        _ isCold: Bool,
        promptCacheExpired: Bool = false,
        workspaceId: UUID,
        surfaceId: UUID,
        observedLastTouchedAt: Date? = nil
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let workspaceManager = AppDelegate.shared?.workspaceManagerFor(workspaceId: workspaceId),
                      let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) else {
                    return
                }
                guard JournalCoordinator.shared.snapshot(tabID: surfaceId)?.connection != .live else { return }
                if isCold,
                   let observedLastTouchedAt,
                   let currentLastTouchedAt = TabActivityTracker.shared.lastActivity(
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
        let snap = TabMetadataStore.shared.getMetadata(
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
        guard journal || JournalCoordinator.shared.snapshot(tabID: surfaceId)?.connection != .live else { return }
        if let derived {
            TabMetadataStore.shared.setInternal(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                key: MetadataKey.activity,
                value: derived.rawValue,
                source: .derived
            )
        } else {
            _ = try? TabMetadataStore.shared.clearMetadata(
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
