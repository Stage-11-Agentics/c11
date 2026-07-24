import Foundation
import Bonsplit

enum SurfaceTabActivityResolver {
    static func resolve(
        hasExactSurfaceNotification: Bool,
        derivedActivity: SidebarActivityState?,
        terminalType: String?
    ) -> BonsplitTabActivityState? {
        if hasExactSurfaceNotification {
            return .waiting
        }
        guard PaneSizePolicy.isAgentKind(terminalType) else {
            return nil
        }
        switch derivedActivity {
        case .working:
            return .running
        case .idle:
            return .idle
        case nil:
            return .cold
        }
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
enum SurfaceLivenessDeriver {

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
        let derived = activityState(for: state)
        queue.async {
            // NOTE (C11-162 m5 / C11-163): this realtime path runs on `Self.queue`
            // while `reconcile(...)` runs on the AgentDetector sweep queue — two
            // different serial queues. The store itself is internally serialized,
            // but this `prior`→write→`after` read-modify-read is NOT atomic against
            // an interleaved reconcile write, so `prior != after` can occasionally
            // misfire. Harmless today (the transition seam is a DEBUG no-op); the
            // future EVT-2 hook must add a shared serialization point before it
            // relies on the transition edge.
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
        activity: SidebarActivityState
    ) {
        queue.async {
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
                    guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                          let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                        return
                    }
                    workspace.setDerivedActivity(mirrored, forSurface: surfaceId)
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
        now: Date = Date()
    ) {
        let snap = SurfaceMetadataStore.shared.getMetadata(
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
        // Only act on our own derived truth; leave externally-set values alone.
        guard let record = snap.sources[MetadataKey.activity],
              (record["source"] as? String) == MetadataSource.derived.rawValue,
              let current = snap.metadata[MetadataKey.activity] as? String else {
            return
        }
        // Only `working` can decay; `idle` is already the resting truth.
        guard current == SidebarActivityState.working.rawValue else { return }

        let last = SurfaceActivityTracker.shared.lastActivity(for: surfaceId.uuidString)
        let isStale = last.map { now.timeIntervalSince($0) >= idleDecayThreshold } ?? true
        guard isStale else { return }

        applyToStore(derived: .idle, workspaceId: workspaceId, surfaceId: surfaceId)
        emitLivenessTransition(
            from: SidebarActivityState.working.rawValue,
            to: SidebarActivityState.idle.rawValue,
            surfaceId: surfaceId,
            workspaceId: workspaceId
        )
        // Mirror onto the Workspace projection if it is currently resident.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                      let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                    return
                }
                workspace.setDerivedActivity(.idle, forSurface: surfaceId)
            }
        }
    }

    // MARK: - Store application

    /// Read the current raw `activity` value (nil when unset). Off-main-safe.
    private static func currentActivityRaw(workspaceId: UUID, surfaceId: UUID) -> String? {
        let snap = SurfaceMetadataStore.shared.getMetadata(
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
        surfaceId: UUID
    ) {
        if let derived {
            SurfaceMetadataStore.shared.setInternal(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                key: MetadataKey.activity,
                value: derived.rawValue,
                source: .derived
            )
        } else {
            _ = try? SurfaceMetadataStore.shared.clearMetadata(
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
