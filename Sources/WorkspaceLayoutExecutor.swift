import Foundation
import Bonsplit

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
    ///
    /// Synchronous in Phase 0 — the walk has no await points. Phase 1's
    /// readiness pass (awaiting `ready` on each surface) will upgrade this
    /// to `async`, at which point callers gain real backpressure.
    static func apply(
        _ plan: WorkspaceApplyPlan,
        options: ApplyOptions = ApplyOptions(),
        dependencies: WorkspaceLayoutExecutorDependencies
    ) -> ApplyResult {
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

        // Index the plan's surfaces by id so the walker can look up each leaf
        // without a linear search. Validation already rejected duplicates.
        let surfacesById = Dictionary(
            uniqueKeysWithValues: plan.surfaces.map { ($0.id, $0) }
        )

        // Steps 4-5 — walk the layout tree and materialize splits/surfaces.
        //
        // The walker maintains a `planSurfaceIdToPanelId` map so later
        // commits can translate plan-local ids to live UUIDs for metadata
        // writes (commit 5) and ref assembly (commit 6).
        var walkState = WalkState(
            workspace: workspace,
            surfacesById: surfacesById,
            warnings: warnings,
            failures: failures,
            timings: timings
        )

        // Resolve the seed panel that `addWorkspace` produced in the root
        // pane. Every path below expects at least one seed; if it isn't
        // available yet, record a partial failure and return what we have.
        guard let seedPanel = workspace.focusedTerminalPanel,
              let rootPaneId = workspace.paneIdForPanel(seedPanel.id) else {
            let failure = ApplyFailure(
                code: "seed_panel_missing",
                step: "layout.walk",
                message: "TabManager.addWorkspace did not provide a resolvable seed terminal panel"
            )
            failures.append(failure)
            warnings.append(failure.message)
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

        walkState.materialize(
            plan.layout,
            intoPane: rootPaneId,
            anchor: .seedTerminal(seedPanel)
        )

        // Apply divider positions by walking the plan tree alongside the
        // live bonsplit tree. Same shape as
        // `Workspace.applySessionDividerPositions`; a no-op for trees with
        // only default 0.5 dividers. A plan/live shape mismatch (e.g., a
        // pane on the live side where the plan expected a split — which
        // would indicate a walker fault or an unsupported plan) now emits
        // a typed ApplyFailure instead of being dropped silently (I4c).
        let dividerFailures = applyDividerPositions(
            planNode: plan.layout,
            liveNode: workspace.bonsplitController.treeSnapshot(),
            workspace: workspace
        )
        for failure in dividerFailures {
            walkState.failures.append(failure)
            walkState.warnings.append(failure.message)
        }

        // Step 7 — terminal initial commands. TerminalPanel.sendText
        // auto-queues pre-ready and flushes when the Ghostty surface comes
        // up, so the executor does not need to await readiness here.
        //
        // Phase 0 parity rule: whether a command is "present" is decided
        // from the **raw** `SurfaceSpec.command`, not a trimmed copy.
        // Phase 0 sent the raw string to the terminal as long as it was
        // non-nil — a command of `" "` (whitespace-only) was delivered
        // verbatim. Trimming before the presence check would silently
        // route whitespace-only commands into the registry, which
        // returns `nil`, and the terminal would never receive the
        // space. This matters for fixtures and blueprints that use a
        // space to "kick" the shell into printing a prompt.
        //
        // Phase 1: when `options.restartRegistry` is non-nil **and**
        // `SurfaceSpec.command` is genuinely `nil`, consult the registry
        // with `(terminal_type, claude.session_id, surface.metadata)`
        // and use the returned command. A registry miss (types matched
        // but session id absent, etc.) emits a `restart_registry_declined`
        // ApplyFailure for observability without aborting the walk.
        for surfaceSpec in plan.surfaces {
            guard surfaceSpec.kind == .terminal,
                  let panelId = walkState.planSurfaceIdToPanelId[surfaceSpec.id],
                  let terminalPanel = workspace.panels[panelId] as? TerminalPanel else {
                continue
            }
            let effectiveCommand: String?
            if let rawCommand = surfaceSpec.command {
                // Explicit command — Phase 0 rule: deliver verbatim,
                // including whitespace-only strings. Registry is not
                // consulted when the plan declared a command at all.
                effectiveCommand = rawCommand
            } else if let registry = options.restartRegistry {
                let surfaceMeta = stringMetadata(surfaceSpec.metadata)
                let terminalType = surfaceMeta[SurfaceMetadataKeyName.terminalType]
                let sessionId = surfaceMeta[SurfaceMetadataKeyName.claudeSessionId]
                let synthesized = registry.resolveCommand(
                    terminalType: terminalType,
                    sessionId: sessionId,
                    metadata: surfaceMeta
                )
                if synthesized == nil, (terminalType != nil || sessionId != nil) {
                    // Registry saw inputs but declined — make it visible.
                    let message = "restart registry declined for terminal_type=\(terminalType ?? "nil") sessionId=\(sessionId?.prefix(8).description ?? "nil")"
                    walkState.warnings.append(message)
                    walkState.failures.append(ApplyFailure(
                        code: "restart_registry_declined",
                        step: "surface[\(surfaceSpec.id)].command.resolve",
                        message: message
                    ))
                }
                effectiveCommand = synthesized
            } else {
                effectiveCommand = nil
            }
            // Genuinely empty commands (`""`) are a no-op under Phase 0
            // too — sendText of zero bytes would write nothing. Skip
            // them to avoid a noisy timing entry. Whitespace-only
            // commands are NOT empty; they reach sendText unchanged.
            guard let cmd = effectiveCommand, !cmd.isEmpty else { continue }
            let cmdClock = Clock()
            terminalPanel.sendText(cmd)
            walkState.timings.append(StepTiming(
                step: "surface[\(surfaceSpec.id)].command.enqueue",
                durationMs: cmdClock.elapsedMs
            ))
        }

        // Step 8 — assemble refs. The executor mints refs for every surface
        // and pane that was successfully created; plan-local surface ids map
        // 1:1 to live `surface:N` / `pane:N` refs via the injected minters.
        let refsClock = Clock()
        var surfaceRefs: [String: String] = [:]
        var paneRefs: [String: String] = [:]
        for (planSurfaceId, panelId) in walkState.planSurfaceIdToPanelId {
            surfaceRefs[planSurfaceId] = dependencies.surfaceRefMinter(panelId)
            if let paneId = workspace.paneIdForPanel(panelId) {
                paneRefs[planSurfaceId] = dependencies.paneRefMinter(paneId.id)
            }
        }
        let workspaceRef = dependencies.workspaceRefMinter(workspace.id)
        walkState.timings.append(StepTiming(
            step: "refs.assemble",
            durationMs: refsClock.elapsedMs
        ))

        timings = walkState.timings
        warnings = walkState.warnings
        failures = walkState.failures

        // Enforce the per-step timeout as a soft limit (I4a). Any step that
        // exceeded options.perStepTimeoutMs emits a typed warning; the
        // executor never aborts — partial-failure semantics per the plan's
        // "truncate-on-failure" principle. A value of 0 disables the
        // check. The synthetic "total" step is exempt; its budget is the
        // acceptance fixture's concern, not per-step.
        if options.perStepTimeoutMs > 0 {
            let threshold = Double(options.perStepTimeoutMs)
            for timing in timings where timing.step != "total" && timing.durationMs > threshold {
                let message = "step '\(timing.step)' took \(String(format: "%.2f", timing.durationMs))ms, exceeding perStepTimeoutMs=\(options.perStepTimeoutMs)ms"
                warnings.append(message)
                failures.append(ApplyFailure(
                    code: "per_step_timeout_exceeded",
                    step: timing.step,
                    message: message
                ))
            }
        }

        timings.append(StepTiming(step: "total", durationMs: total.elapsedMs))
        return ApplyResult(
            workspaceRef: workspaceRef,
            surfaceRefs: surfaceRefs,
            paneRefs: paneRefs,
            timings: timings,
            warnings: warnings,
            failures: failures
        )
    }

    // MARK: - Plan validation

    /// Plan schema versions this executor understands. Bumping the format
    /// (new required fields, breaking semantics) adds a version here and
    /// at the same time updates callers that emit plans (Blueprint parser,
    /// Snapshot reader). Phase 0 ships only version 1.
    nonisolated static let supportedPlanVersions: Set<Int> = [1]

    /// Returns the first validation failure encountered, or `nil` if the plan
    /// is structurally sound. Pure — safe to call off the main actor before
    /// dispatching to `apply(_:options:dependencies:)`. Per review cycle 1 I3,
    /// the v2 socket handler pre-checks via this entry point so validation
    /// never rides the main actor.
    nonisolated static func validate(plan: WorkspaceApplyPlan) -> ApplyFailure? {
        // Schema version (I4b). Unsupported versions short-circuit before
        // we inspect surfaces or the layout tree — a mis-versioned plan has
        // no guarantees about the rest of the shape.
        if !supportedPlanVersions.contains(plan.version) {
            let supported = supportedPlanVersions.sorted()
            return ApplyFailure(
                code: "unsupported_version",
                step: "validate",
                message: "WorkspaceApplyPlan.version=\(plan.version) unsupported (Phase 0 accepts \(supported))"
            )
        }

        // Duplicate surface ids in plan.surfaces.
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

        // Every id referenced from the layout tree must exist in `surfaces`,
        // and no id may be referenced from more than one PaneSpec (I4d).
        let known = Set(plan.surfaces.map(\.id))
        var referencedIds = Set<String>()
        if let failure = validateLayout(
            plan.layout,
            knownSurfaceIds: known,
            referencedIds: &referencedIds
        ) {
            return failure
        }
        // Every SurfaceSpec must be referenced from the layout tree.
        // Orphan entries otherwise silently vanish — cycle 2 finding
        // (Codex). Sorting keeps the error message deterministic.
        let orphans = known.subtracting(referencedIds).sorted()
        if !orphans.isEmpty {
            return ApplyFailure(
                code: "orphan_surface",
                step: "validate",
                message: "SurfaceSpec id(s) not referenced from layout tree: \(orphans.joined(separator: ","))"
            )
        }
        return nil
    }

    nonisolated private static func validateLayout(
        _ node: LayoutTreeSpec,
        knownSurfaceIds: Set<String>,
        referencedIds: inout Set<String>
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
            var paneSeen = Set<String>()
            for surfaceId in pane.surfaceIds {
                if !knownSurfaceIds.contains(surfaceId) {
                    return ApplyFailure(
                        code: "unknown_surface_ref",
                        step: "validate",
                        message: "LayoutTreeSpec references unknown surface id '\(surfaceId)'"
                    )
                }
                if !paneSeen.insert(surfaceId).inserted {
                    return ApplyFailure(
                        code: "duplicate_surface_reference",
                        step: "validate",
                        message: "LayoutTreeSpec.pane.surfaceIds contains '\(surfaceId)' twice in the same pane"
                    )
                }
                if !referencedIds.insert(surfaceId).inserted {
                    return ApplyFailure(
                        code: "duplicate_surface_reference",
                        step: "validate",
                        message: "surface id '\(surfaceId)' referenced by more than one pane"
                    )
                }
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
            if let failure = validateLayout(
                split.first,
                knownSurfaceIds: knownSurfaceIds,
                referencedIds: &referencedIds
            ) {
                return failure
            }
            if let failure = validateLayout(
                split.second,
                knownSurfaceIds: knownSurfaceIds,
                referencedIds: &referencedIds
            ) {
                return failure
            }
            return nil
        }
    }

    // MARK: - Layout walk

    /// Anchor passed into `materialize`. Either the workspace's seed terminal
    /// panel (at the root call), or the panel returned by a `newXSplit` that
    /// introduced the current subtree.
    fileprivate enum AnchorPanel {
        /// The seed `TerminalPanel` created by `TabManager.addWorkspace`. If
        /// the subtree's first leaf is not a terminal, the walker replaces it
        /// with the target kind in the same pane and closes the seed.
        case seedTerminal(TerminalPanel)
        /// A panel returned by `newXSplit`. Type is matched to the first leaf
        /// of the subtree by construction — no replacement needed.
        case anyExisting(panelId: UUID, kind: SurfaceSpecKind)

        var panelId: UUID {
            switch self {
            case .seedTerminal(let panel): return panel.id
            case .anyExisting(let panelId, _): return panelId
            }
        }

        var kind: SurfaceSpecKind {
            switch self {
            case .seedTerminal: return .terminal
            case .anyExisting(_, let kind): return kind
            }
        }
    }

    /// Mutable walk state — threaded through the DFS traversal so individual
    /// method signatures stay small. `planSurfaceIdToPanelId` is the output
    /// used by commits 5-6 to write metadata and mint refs.
    @MainActor
    fileprivate struct WalkState {
        let workspace: Workspace
        let surfacesById: [String: SurfaceSpec]
        var warnings: [String]
        var failures: [ApplyFailure]
        var timings: [StepTiming]
        /// plan-local SurfaceSpec.id → live panel UUID. Populated as surfaces
        /// materialize. Commits 5-6 consume this for metadata writes and
        /// ref assembly.
        var planSurfaceIdToPanelId: [String: UUID] = [:]
        /// Split-index counter used for step timing labels.
        var splitIndex: Int = 0

        /// Materialize `node` into `paneId`. Top-down: at a split node the
        /// walker splits the **current pane** into two sibling panes (first
        /// stays in the original pane with the inbound anchor, second
        /// inhabits a newly-minted pane), then recurses into each subtree
        /// with its own pane context. Leaves populate their target pane with
        /// the spec'd surfaces, replacing the anchor if kind doesn't match.
        ///
        /// This mirrors `Workspace.restoreSessionLayoutNode` — the proven
        /// top-down pattern the Snapshot restore path uses, which composes
        /// correctly against bonsplit's leaf-only `splitPane` API.
        mutating func materialize(
            _ node: LayoutTreeSpec,
            intoPane paneId: PaneID,
            anchor: AnchorPanel
        ) {
            switch node {
            case .pane(let paneSpec):
                materializePane(paneSpec, intoPane: paneId, anchor: anchor)
            case .split(let splitSpec):
                materializeSplit(splitSpec, intoPane: paneId, anchor: anchor)
            }
        }

        private mutating func materializePane(
            _ paneSpec: LayoutTreeSpec.PaneSpec,
            intoPane paneId: PaneID,
            anchor: AnchorPanel
        ) {
            guard let firstSurfaceId = paneSpec.surfaceIds.first,
                  let firstSurface = surfacesById[firstSurfaceId] else {
                failures.append(ApplyFailure(
                    code: "validation_failed",
                    step: "layout.walk",
                    message: "PaneSpec with no surfaces reached the walker"
                ))
                return
            }

            let leafClock = Clock()
            let firstPanelId: UUID
            if anchor.kind == firstSurface.kind {
                firstPanelId = anchor.panelId
                // Anchor reuse cannot honor an explicit workingDirectory —
                // either the seed already launched with the workspace cwd
                // (seedTerminal case), or the panel was created by a split
                // primitive in the enclosing materializeSplit and its cwd
                // is already baked in (anyExisting case). Emit a typed
                // warning so callers see the cwd didn't apply, matching
                // review cycle 1 I1.
                if let cwd = firstSurface.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !cwd.isEmpty,
                   case .seedTerminal = anchor {
                    reportWorkingDirectoryNotApplicable(
                        firstSurface,
                        context: "seed terminal reuse (cwd fixed at workspace creation)"
                    )
                }
            } else {
                // Kind mismatch: replace the anchor with the target kind in
                // the same pane, then close the old anchor. This handles the
                // root case (plan's first leaf is browser/markdown) and any
                // nested case where the anchor inherited from the enclosing
                // split disagrees with this leaf's kind.
                guard let replacement = createSurface(
                    firstSurface,
                    inPane: paneId,
                    focus: false
                ) else {
                    failures.append(ApplyFailure(
                        code: "surface_create_failed",
                        step: "surface[\(firstSurface.id)].create",
                        message: "failed to replace anchor with \(firstSurface.kind.rawValue) surface"
                    ))
                    return
                }
                firstPanelId = replacement
                _ = workspace.closePanel(anchor.panelId, force: true)
            }
            timings.append(StepTiming(
                step: "surface[\(firstSurface.id)].create",
                durationMs: leafClock.elapsedMs
            ))
            planSurfaceIdToPanelId[firstSurface.id] = firstPanelId

            // Apply the first surface's title via the canonical setter so
            // SurfaceMetadataStore["title"] stays in sync. Description and
            // the rest of surface + pane metadata land immediately after,
            // during creation (no post-hoc socket loop).
            if let title = firstSurface.title {
                workspace.setPanelCustomTitle(panelId: firstPanelId, title: title)
            }
            writeSurfaceMetadata(firstSurface, panelId: firstPanelId)

            // Additional surfaces in the same pane (tab-stacked).
            for additionalSurfaceId in paneSpec.surfaceIds.dropFirst() {
                guard let spec = surfacesById[additionalSurfaceId] else { continue }
                let addClock = Clock()
                guard let newPanelId = createSurface(spec, inPane: paneId, focus: false) else {
                    failures.append(ApplyFailure(
                        code: "surface_create_failed",
                        step: "surface[\(spec.id)].create",
                        message: "failed to add \(spec.kind.rawValue) surface to pane"
                    ))
                    continue
                }
                timings.append(StepTiming(
                    step: "surface[\(spec.id)].create",
                    durationMs: addClock.elapsedMs
                ))
                planSurfaceIdToPanelId[spec.id] = newPanelId
                if let title = spec.title {
                    workspace.setPanelCustomTitle(panelId: newPanelId, title: title)
                }
                writeSurfaceMetadata(spec, panelId: newPanelId)
            }

            // Apply selectedIndex. Default is the first surface, which
            // bonsplit selects on creation; only deviate if the plan picks
            // another.
            if let selectedIndex = paneSpec.selectedIndex,
               selectedIndex > 0,
               selectedIndex < paneSpec.surfaceIds.count {
                let selectedSurfaceId = paneSpec.surfaceIds[selectedIndex]
                if let selectedPanelId = planSurfaceIdToPanelId[selectedSurfaceId],
                   let selectedTabId = workspace.surfaceIdFromPanelId(selectedPanelId) {
                    workspace.bonsplitController.selectTab(selectedTabId)
                }
            }
        }

        private mutating func materializeSplit(
            _ splitSpec: LayoutTreeSpec.SplitSpec,
            intoPane paneId: PaneID,
            anchor: AnchorPanel
        ) {
            // Pick the right split primitive based on `split.second`'s first
            // leaf so the newly-minted pane is seeded with a panel of the
            // correct kind. If second's leaf is terminal we use
            // newTerminalSplit; browser uses newBrowserSplit; markdown uses
            // newMarkdownSplit. This saves a replace-in-new-pane round-trip
            // when the second subtree's first leaf matches the split's seed.
            guard let secondFirstSurfaceId = firstLeafSurfaceId(splitSpec.second),
                  let secondFirstSurface = surfacesById[secondFirstSurfaceId] else {
                failures.append(ApplyFailure(
                    code: "validation_failed",
                    step: "layout.walk",
                    message: "split's second subtree has no discoverable first surface"
                ))
                // Best-effort: populate first in the current pane, drop second.
                materialize(splitSpec.first, intoPane: paneId, anchor: anchor)
                return
            }

            let orientation: SplitOrientation = splitSpec.orientation == .vertical
                ? .vertical
                : .horizontal
            let label = splitIndex
            splitIndex += 1
            let splitClock = Clock()
            let newPanelId = splitFromPanel(
                anchor.panelId,
                orientation: orientation,
                spec: secondFirstSurface
            )
            timings.append(StepTiming(
                step: "layout.split[\(label)].create",
                durationMs: splitClock.elapsedMs
            ))

            guard let newPanelId,
                  let newPaneId = workspace.paneIdForPanel(newPanelId) else {
                failures.append(ApplyFailure(
                    code: "split_failed",
                    step: "layout.split[\(label)].create",
                    message: "newXSplit rejected split from panel for \(secondFirstSurface.kind.rawValue)"
                ))
                // Best-effort: populate first in the current pane, drop second.
                materialize(splitSpec.first, intoPane: paneId, anchor: anchor)
                return
            }

            // Recurse:
            //   first → current pane, inherits the inbound anchor
            //   second → newly-minted pane, anchored on the split primitive's new panel
            materialize(splitSpec.first, intoPane: paneId, anchor: anchor)
            materialize(
                splitSpec.second,
                intoPane: newPaneId,
                anchor: .anyExisting(panelId: newPanelId, kind: secondFirstSurface.kind)
            )
        }

        /// Dispatch to the right `Workspace.newXSplit` primitive. Always
        /// passes `focus: false` — the executor does not steal focus per
        /// CLAUDE.md socket focus policy. Terminal splits honor
        /// `spec.workingDirectory` via the overload added in R3 of the
        /// review cycle 1 rework.
        private mutating func splitFromPanel(
            _ panelId: UUID,
            orientation: SplitOrientation,
            spec: SurfaceSpec
        ) -> UUID? {
            switch spec.kind {
            case .terminal:
                return workspace.newTerminalSplit(
                    from: panelId,
                    orientation: orientation,
                    insertFirst: false,
                    focus: false,
                    workingDirectory: spec.workingDirectory
                )?.id
            case .browser:
                if spec.workingDirectory != nil {
                    reportWorkingDirectoryNotApplicable(spec, context: "browser split")
                }
                let url = spec.url.flatMap { URL(string: $0) }
                return workspace.newBrowserSplit(
                    from: panelId,
                    orientation: orientation,
                    insertFirst: false,
                    url: url,
                    focus: false
                )?.id
            case .markdown:
                if spec.workingDirectory != nil {
                    reportWorkingDirectoryNotApplicable(spec, context: "markdown split")
                }
                return workspace.newMarkdownSplit(
                    from: panelId,
                    orientation: orientation,
                    insertFirst: false,
                    filePath: spec.filePath,
                    focus: false
                )?.id
            }
        }

        /// Emit a typed ApplyFailure when a caller sets
        /// `SurfaceSpec.workingDirectory` on a path that cannot honor it
        /// (browser/markdown creation, or reusing a seed terminal whose
        /// shell has already launched). Keeps cwd loss non-silent per
        /// review cycle 1 I1.
        mutating func reportWorkingDirectoryNotApplicable(
            _ spec: SurfaceSpec,
            context: String
        ) {
            let cwd = spec.workingDirectory ?? ""
            let message = "surface[\(spec.id)] workingDirectory='\(cwd)' ignored: \(context) path does not accept an explicit cwd"
            warnings.append(message)
            failures.append(ApplyFailure(
                code: "working_directory_not_applied",
                step: "surface[\(spec.id)].create",
                message: message
            ))
        }

        /// Apply `spec.description`, the rest of `spec.metadata`, and
        /// `spec.paneMetadata` for a just-created surface. Writes happen
        /// during creation (not post-hoc), all with source `.explicit`.
        /// The `mailbox.*` namespace in pane metadata is enforced
        /// strings-only per docs/c11-13-cmux-37-alignment.md.
        mutating func writeSurfaceMetadata(_ spec: SurfaceSpec, panelId: UUID) {
            let surfaceClock = Clock()
            let workspaceId = workspace.id

            // Surface description — reserved key validated by the store.
            if let raw = spec.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                do {
                    _ = try SurfaceMetadataStore.shared.setMetadata(
                        workspaceId: workspaceId,
                        surfaceId: panelId,
                        partial: ["description": raw],
                        mode: .merge,
                        source: .explicit
                    )
                } catch {
                    let message = "surface[\(spec.id)] description write failed: \(error)"
                    warnings.append(message)
                    failures.append(ApplyFailure(
                        code: "metadata_write_failed",
                        step: "metadata.surface[\(spec.id)].write",
                        message: message
                    ))
                }
            }

            // Rest of surface metadata. title/description collisions with
            // the dedicated setters above emit a `metadata_override` warning
            // but the explicit metadata value still wins (it's written last
            // with merge mode + explicit source).
            if let metadata = spec.metadata, !metadata.isEmpty {
                for (key, value) in metadata {
                    if key == "title", spec.title != nil {
                        failures.append(ApplyFailure(
                            code: "metadata_override",
                            step: "metadata.surface[\(spec.id)].write",
                            message: "surface[\(spec.id)] sets both SurfaceSpec.title and metadata[\"title\"]; metadata value wins"
                        ))
                    }
                    if key == "description", spec.description != nil {
                        failures.append(ApplyFailure(
                            code: "metadata_override",
                            step: "metadata.surface[\(spec.id)].write",
                            message: "surface[\(spec.id)] sets both SurfaceSpec.description and metadata[\"description\"]; metadata value wins"
                        ))
                    }
                    let decoded = PersistedMetadataBridge.decodeValues([key: value])
                    do {
                        _ = try SurfaceMetadataStore.shared.setMetadata(
                            workspaceId: workspaceId,
                            surfaceId: panelId,
                            partial: decoded,
                            mode: .merge,
                            source: .explicit
                        )
                    } catch {
                        let message = "surface[\(spec.id)] metadata[\"\(key)\"] write failed: \(error)"
                        warnings.append(message)
                        failures.append(ApplyFailure(
                            code: "metadata_write_failed",
                            step: "metadata.surface[\(spec.id)].write",
                            message: message
                        ))
                    }
                }
            }
            timings.append(StepTiming(
                step: "metadata.surface[\(spec.id)].write",
                durationMs: surfaceClock.elapsedMs
            ))

            // Pane metadata. mailbox.* is strings-only in v1.
            guard let paneMetadata = spec.paneMetadata, !paneMetadata.isEmpty else {
                return
            }
            let paneClock = Clock()
            guard let paneId = workspace.paneIdForPanel(panelId) else {
                let message = "surface[\(spec.id)] pane metadata skipped: no bonsplit pane resolved for panel"
                warnings.append(message)
                failures.append(ApplyFailure(
                    code: "metadata_write_failed",
                    step: "metadata.pane[\(spec.id)].write",
                    message: message
                ))
                return
            }
            let paneUUID = paneId.id
            for (key, value) in paneMetadata {
                if key.hasPrefix("mailbox."), case .string = value {
                    // string — OK
                } else if key.hasPrefix("mailbox.") {
                    let message = "surface[\(spec.id)] pane metadata[\"\(key)\"] dropped: mailbox.* values must be strings in v1"
                    warnings.append(message)
                    failures.append(ApplyFailure(
                        code: "mailbox_non_string_value",
                        step: "metadata.pane[\(spec.id)].write",
                        message: message
                    ))
                    continue
                }
                let decoded = PersistedMetadataBridge.decodeValues([key: value])
                do {
                    _ = try PaneMetadataStore.shared.setMetadata(
                        workspaceId: workspaceId,
                        paneId: paneUUID,
                        partial: decoded,
                        mode: .merge,
                        source: .explicit
                    )
                } catch {
                    let message = "surface[\(spec.id)] pane metadata[\"\(key)\"] write failed: \(error)"
                    warnings.append(message)
                    failures.append(ApplyFailure(
                        code: "metadata_write_failed",
                        step: "metadata.pane[\(spec.id)].write",
                        message: message
                    ))
                }
            }
            timings.append(StepTiming(
                step: "metadata.pane[\(spec.id)].write",
                durationMs: paneClock.elapsedMs
            ))
        }

        /// Create an in-pane surface of the right kind. Returns the new
        /// panel id. `focus: false` always. Terminal honors
        /// `spec.workingDirectory` via `newTerminalSurface(inPane:workingDirectory:)`;
        /// browser/markdown cannot accept cwd and emit a typed
        /// `working_directory_not_applied` failure when one is declared
        /// (cycle 2: R3 left this in-pane path silent; split path was
        /// already covered).
        private mutating func createSurface(
            _ spec: SurfaceSpec,
            inPane paneId: PaneID,
            focus: Bool
        ) -> UUID? {
            switch spec.kind {
            case .terminal:
                return workspace.newTerminalSurface(
                    inPane: paneId,
                    focus: focus,
                    workingDirectory: spec.workingDirectory
                )?.id
            case .browser:
                if spec.workingDirectory != nil {
                    reportWorkingDirectoryNotApplicable(spec, context: "browser in-pane creation")
                }
                let url = spec.url.flatMap { URL(string: $0) }
                return workspace.newBrowserSurface(
                    inPane: paneId,
                    url: url,
                    focus: focus
                )?.id
            case .markdown:
                if spec.workingDirectory != nil {
                    reportWorkingDirectoryNotApplicable(spec, context: "markdown in-pane creation")
                }
                return workspace.newMarkdownSurface(
                    inPane: paneId,
                    filePath: spec.filePath,
                    focus: focus
                )?.id
            }
        }
    }

    /// Find the first leaf's first surface id in a subtree. Returns nil only
    /// when the tree is malformed (pre-validated away before this is called,
    /// but the nil branch keeps the call site total).
    fileprivate nonisolated static func firstLeafSurfaceId(_ node: LayoutTreeSpec) -> String? {
        switch node {
        case .pane(let pane): return pane.surfaceIds.first
        case .split(let split): return firstLeafSurfaceId(split.first)
        }
    }

    // MARK: - Divider positions

    /// Bonsplit enforces its own divider bounds (hard-clamped inside
    /// `setDividerPosition`). Plan schema allows `0...1`; the executor
    /// reports a typed warning when the plan's value falls outside this
    /// window so the fidelity loss is visible to Phase 1 Snapshot and
    /// Phase 2 Blueprint authors — cycle 2 IM3.
    private static let bonsplitDividerFloor: Double = 0.1
    private static let bonsplitDividerCeiling: Double = 0.9

    /// Walk plan tree and live bonsplit tree in lockstep, applying each
    /// plan-side `dividerPosition`. Same shape as
    /// `Workspace.applySessionDividerPositions` — plan tree replaces the
    /// session snapshot side.
    ///
    /// Returns any `ApplyFailure` records produced when the plan and live
    /// trees disagree on shape (plan expected a split but live has a pane,
    /// or vice versa), or when a plan-side `dividerPosition` was outside
    /// bonsplit's acceptable `0.1...0.9` clamp. Pane-vs-pane is a
    /// legitimate no-op (no dividers to apply), not a failure.
    private static func applyDividerPositions(
        planNode: LayoutTreeSpec,
        liveNode: ExternalTreeNode,
        workspace: Workspace,
        path: String = "layout"
    ) -> [ApplyFailure] {
        switch (planNode, liveNode) {
        case (.split(let planSplit), .split(let liveSplit)):
            var out: [ApplyFailure] = []
            if let splitID = UUID(uuidString: liveSplit.id) {
                let requested = planSplit.dividerPosition
                let clamped = min(max(requested, bonsplitDividerFloor), bonsplitDividerCeiling)
                if abs(requested - clamped) > 0.0001 {
                    out.append(ApplyFailure(
                        code: "divider_clamped",
                        step: "\(path).dividerPosition",
                        message: "plan dividerPosition=\(requested) at \(path) clamped to bonsplit's acceptable range [\(bonsplitDividerFloor), \(bonsplitDividerCeiling)] (applied \(clamped))"
                    ))
                }
                _ = workspace.bonsplitController.setDividerPosition(
                    CGFloat(clamped),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            out.append(contentsOf: applyDividerPositions(
                planNode: planSplit.first,
                liveNode: liveSplit.first,
                workspace: workspace,
                path: "\(path).first"
            ))
            out.append(contentsOf: applyDividerPositions(
                planNode: planSplit.second,
                liveNode: liveSplit.second,
                workspace: workspace,
                path: "\(path).second"
            ))
            return out
        case (.split, .pane):
            return [ApplyFailure(
                code: "divider_apply_failed",
                step: "\(path).dividerPosition",
                message: "plan/live tree shape mismatch at \(path); plan expected split, live has pane — dividerPosition cannot be applied"
            )]
        case (.pane, .split):
            return [ApplyFailure(
                code: "divider_apply_failed",
                step: "\(path).dividerPosition",
                message: "plan/live tree shape mismatch at \(path); plan expected pane, live has split — divider slot is unexpected"
            )]
        case (.pane, .pane):
            return []
        }
    }

    // MARK: - Metadata helpers

    /// Flatten a `[String: PersistedJSONValue]?` surface-metadata blob to
    /// `[String: String]`, keeping only `.string(...)` entries. The
    /// restart-registry contract takes string-valued inputs only —
    /// `terminal_type` and `claude.session_id` are both strings in v1 —
    /// so non-string values (numbers, booleans, arrays, objects) are
    /// silently dropped here rather than surfaced as warnings; a
    /// non-string `terminal_type` would have been caught by
    /// `SurfaceMetadataStore.validateReservedKey` at write time.
    fileprivate nonisolated static func stringMetadata(
        _ metadata: [String: PersistedJSONValue]?
    ) -> [String: String] {
        guard let metadata else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in metadata {
            if case .string(let s) = value {
                out[key] = s
            }
        }
        return out
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
