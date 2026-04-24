import Foundation

/// Dependencies that `WorkspaceLayoutExecutor.apply` does not own — passed in
/// so the executor stays decoupled from the socket layer (for tests) and the
/// v2 ref layer (for the future socket handler in commit 8b).
///
/// `workspaceRefMinter`/`surfaceRefMinter`/`paneRefMinter` map a live UUID to
/// its v2 ref string (`workspace:N` / `surface:N` / `pane:N`). The socket
/// handler wires these to `TerminalController.v2Ref`; tests can supply a
/// synthetic minter that derives a stable string from the UUID.
@MainActor
struct WorkspaceLayoutExecutorDependencies {
    var tabManager: TabManager
    var workspaceRefMinter: (UUID) -> String
    var surfaceRefMinter: (UUID) -> String
    var paneRefMinter: (UUID) -> String

    init(
        tabManager: TabManager,
        workspaceRefMinter: @escaping (UUID) -> String,
        surfaceRefMinter: @escaping (UUID) -> String,
        paneRefMinter: @escaping (UUID) -> String
    ) {
        self.tabManager = tabManager
        self.workspaceRefMinter = workspaceRefMinter
        self.surfaceRefMinter = surfaceRefMinter
        self.paneRefMinter = paneRefMinter
    }
}

/// App-side executor for `WorkspaceApplyPlan`. One `apply` call materializes
/// an entire workspace — workspace create, layout tree, titles, descriptions,
/// surface/pane metadata, terminal initial commands — in one transaction.
///
/// The executor runs on the main actor (AppKit/bonsplit state). Phase 0
/// ships only the creation-centric path; Phase 1 adds
/// `applyToExistingWorkspace(_:_:_:)` for Snapshot restore over a live
/// workspace + seed panel.
///
/// Partial-failure semantics: validation failures short-circuit before any
/// UI state mutates (`ApplyResult.workspaceRef` stays empty). Anything after
/// workspace creation appends `ApplyFailure` records but leaves the workspace
/// on-screen — matching `DefaultGridSettings.performDefaultGrid`'s
/// truncate-on-failure behavior rather than silent disappearance.
@MainActor
enum WorkspaceLayoutExecutor {

    /// Execute `plan`. Returns an `ApplyResult` with timings and any
    /// partial-failure warnings. Never throws.
    static func apply(
        _ plan: WorkspaceApplyPlan,
        options: ApplyOptions = ApplyOptions(),
        dependencies: WorkspaceLayoutExecutorDependencies
    ) async -> ApplyResult {
        let total = Clock()
        var timings: [StepTiming] = []
        var warnings: [String] = []
        var failures: [ApplyFailure] = []

        // Step 1 — validate the plan locally before any AppKit state changes.
        let validateClock = Clock()
        if let failure = validate(plan: plan) {
            timings.append(StepTiming(step: "validate", durationMs: validateClock.elapsedMs))
            failures.append(failure)
            warnings.append(failure.message)
            timings.append(StepTiming(step: "total", durationMs: total.elapsedMs))
            return ApplyResult(
                workspaceRef: "",
                surfaceRefs: [:],
                paneRefs: [:],
                timings: timings,
                warnings: warnings,
                failures: failures
            )
        }
        timings.append(StepTiming(step: "validate", durationMs: validateClock.elapsedMs))

        // Step 2 — create the workspace. The executor always opts out of
        // welcome/default-grid auto-spawns so the layout walker owns the
        // tree shape entirely; the `autoWelcomeIfNeeded` field on options
        // is informational for future callers.
        let createClock = Clock()
        let workspace = dependencies.tabManager.addWorkspace(
            workingDirectory: plan.workspace.workingDirectory,
            initialTerminalCommand: nil,
            select: options.select,
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false
        )
        if let title = plan.workspace.title {
            workspace.setCustomTitle(title)
        }
        if let color = plan.workspace.customColor {
            workspace.setCustomColor(color)
        }
        timings.append(StepTiming(step: "workspace.create", durationMs: createClock.elapsedMs))

        // Step 3 — apply workspace-level metadata (operator-authored).
        if let entries = plan.workspace.metadata, !entries.isEmpty {
            let metaClock = Clock()
            workspace.setOperatorMetadata(entries)
            timings.append(StepTiming(
                step: "metadata.workspace.write",
                durationMs: metaClock.elapsedMs
            ))
        }

        // Phase 0 commit 3 stub: workspace created, layout walker and
        // surface/pane metadata writes land in commits 4-6. `surfaceRefs`
        // and `paneRefs` stay empty until then. The debug CLI / acceptance
        // fixture only exercises the later commits, so the stub result
        // here is never user-visible in shipped builds.
        let workspaceRef = dependencies.workspaceRefMinter(workspace.id)
        timings.append(StepTiming(step: "total", durationMs: total.elapsedMs))
        return ApplyResult(
            workspaceRef: workspaceRef,
            surfaceRefs: [:],
            paneRefs: [:],
            timings: timings,
            warnings: warnings,
            failures: failures
        )
    }

    // MARK: - Plan validation

    /// Returns the first validation failure encountered, or `nil` if the plan
    /// is structurally sound. Pure; no AppKit access.
    private static func validate(plan: WorkspaceApplyPlan) -> ApplyFailure? {
        // Duplicate surface ids.
        var seen = Set<String>()
        for surface in plan.surfaces {
            if !seen.insert(surface.id).inserted {
                return ApplyFailure(
                    code: "duplicate_surface_id",
                    step: "validate",
                    message: "duplicate SurfaceSpec.id '\(surface.id)'"
                )
            }
        }

        // Every id referenced from the layout tree must exist in `surfaces`.
        let known = Set(plan.surfaces.map(\.id))
        if let failure = validateLayout(plan.layout, knownSurfaceIds: known) {
            return failure
        }
        return nil
    }

    private static func validateLayout(
        _ node: LayoutTreeSpec,
        knownSurfaceIds: Set<String>
    ) -> ApplyFailure? {
        switch node {
        case .pane(let pane):
            if pane.surfaceIds.isEmpty {
                return ApplyFailure(
                    code: "validation_failed",
                    step: "validate",
                    message: "LayoutTreeSpec.pane.surfaceIds must not be empty"
                )
            }
            for surfaceId in pane.surfaceIds where !knownSurfaceIds.contains(surfaceId) {
                return ApplyFailure(
                    code: "unknown_surface_ref",
                    step: "validate",
                    message: "LayoutTreeSpec references unknown surface id '\(surfaceId)'"
                )
            }
            if let idx = pane.selectedIndex, idx < 0 || idx >= pane.surfaceIds.count {
                return ApplyFailure(
                    code: "validation_failed",
                    step: "validate",
                    message: "PaneSpec.selectedIndex=\(idx) out of range for \(pane.surfaceIds.count) surfaces"
                )
            }
            return nil
        case .split(let split):
            if let failure = validateLayout(split.first, knownSurfaceIds: knownSurfaceIds) {
                return failure
            }
            if let failure = validateLayout(split.second, knownSurfaceIds: knownSurfaceIds) {
                return failure
            }
            return nil
        }
    }

    // MARK: - Timing helper

    /// Thin wrapper around `DispatchTime` for timing a step without the
    /// noise of `DispatchTime.now()` arithmetic at every call site. One per
    /// step; read `elapsedMs` when the step ends.
    fileprivate struct Clock {
        let start: DispatchTime = .now()
        var elapsedMs: Double {
            let ns = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            return Double(ns) / 1_000_000.0
        }
    }
}
