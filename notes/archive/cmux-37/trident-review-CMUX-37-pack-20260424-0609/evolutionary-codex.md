## Evolutionary Code Review
- **Date:** 2026-04-24T10:11:12Z
- **Model:** CODEX / GPT-5
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** bf802101
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

Note: the review prompt requested fetch/pull, but the controlling task wrapper explicitly made this a read-only review and forbade mutating git state. I reviewed the existing local branch state only.

## What's Really Being Built

This is not just workspace persistence. CMUX-37 Phase 0 is creating a **workspace materialization kernel**: a single app-side path that can turn declarative intent into live c11 topology, surfaces, metadata, commands, refs, and diagnostics.

That is a bigger primitive than Blueprints or Snapshots. If it matures well, it becomes the shared creation substrate for:

- restoring user state after restart,
- spinning up reproducible agent rooms,
- onboarding new repos into known working layouts,
- generating workspaces from Lattice plans,
- validating c11's own layout engine with a declarative fixture language.

The rework moves in the right direction. The top-down walker in `Sources/WorkspaceLayoutExecutor.swift:413`-`603` now matches the shape of the existing restore idiom instead of fighting Bonsplit's leaf split API. The test harness in `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:125`-`147` has also crossed an important threshold: it now compares live tree structure, not just ref coverage.

The interesting next mutation is to stop thinking of `WorkspaceApplyPlan` as "input JSON" and start treating it as a **typed intent graph with an execution ledger**.

## Emerging Patterns

1. **Plan-local handles are becoming compiler IR.** `SurfaceSpec.id` is currently a temporary apply-time handle (`Sources/WorkspaceApplyPlan.swift:56`-`84`), while live refs are emitted afterward (`Sources/WorkspaceLayoutExecutor.swift:198`-`210`). That already looks like a compiler lowering pass: source identifiers become runtime symbols.

2. **Metadata is the real extension bus.** Surface metadata, pane metadata, mailbox config, titles, status, and future restart keys all flow through stores rather than bespoke fields (`Sources/WorkspaceLayoutExecutor.swift:669`-`797`). This is c11's strongest architectural move: layouts can stay narrow while behavior composes through namespaced metadata.

3. **The executor is split between declarative semantics and UI plumbing.** Validation is pure and nonisolated (`Sources/WorkspaceLayoutExecutor.swift:263`-`365`); materialization is `@MainActor` (`Sources/WorkspaceLayoutExecutor.swift:46`-`59`). That boundary should become more explicit, because Phase 1/2 will otherwise keep adding "just one more field" to the main-actor path.

4. **Warnings are becoming policy.** `ApplyFailure.code` already has stable codes for non-fatal outcomes (`Sources/WorkspaceApplyPlan.swift:235`-`257`). This can evolve into a real policy layer: `strict`, `bestEffort`, `snapshotRestore`, `blueprintPreview`, `testFixture`.

5. **Welcome quad and default grid are legacy compilers waiting to be retired.** The TODOs in `Sources/c11App.swift:4000`-`4005` and `Sources/c11App.swift:4089`-`4093` are more than cleanup notes. They identify existing ad hoc layout languages that should compile to the same primitive.

## How This Could Evolve

The natural destination is a three-stage pipeline:

1. **Compile:** Blueprint markdown, Snapshot capture, welcome quad/default grid settings, Lattice task plans, or CLI JSON all compile into `WorkspaceApplyPlan`.
2. **Validate:** A pure validator checks graph closure, schema version, kind-specific fields, name stability, metadata policy, and environment constraints before UI mutation.
3. **Materialize:** The main-actor executor applies a verified plan and emits a durable `ApplyTrace`.

Right now stages 2 and 3 exist, but only partly. The biggest opportunity is making the boundary crisp enough that future features add new compilers, not new workspace constructors.

Six months from now, the good version looks like this:

- `WorkspaceApplyPlan.capture(from:)` creates a plan from any live workspace.
- `WorkspaceLayoutExecutor.apply(plan)` and `capture(from:)` form a round-trip contract.
- Welcome quad/default grid are tiny plan builders.
- Blueprint parsing is a frontend over the same graph.
- Snapshot restore is just "load plan, apply with restore policy."
- CI owns a growing corpus of plans that can be replayed across layout, metadata, and readiness changes.

The bad version is a thicket: Blueprints, Snapshots, welcome quad, default grid, restart registry, and mailbox setup each get their own partial creation path, and `WorkspaceApplyPlan` becomes one more format rather than the kernel.

## Mutations and Wild Ideas

**Workspace Recipes.** Make plans composable: "base repo room" + "debug overlay" + "review overlay" merge into one apply graph. This turns workspaces into reusable recipes rather than static templates.

**Plan Diff Mode.** Add a dry-run that compares a plan to a live workspace and returns operations: create pane, add surface, rename, apply metadata, resize divider. Even if Phase 0 only creates new workspaces, the diff engine would become the substrate for future "reconcile" features.

**Agent Choreography Plans.** A Blueprint could declare not just surfaces but roles and mailbox wiring: `driver`, `reviewer`, `test runner`, `docs watcher`. c11 would not run intelligence itself; it would stage the room so agents can self-report and communicate through the metadata/mailbox layer.

**Topology Fuzzer.** Because `LayoutTreeSpec` is small and recursive, c11 can generate random valid plans and assert `apply -> capture -> compare`. That would pressure-test Bonsplit integration far better than handpicked fixtures.

**Workspace Provenance.** Persist an `ApplyTrace` in workspace metadata: which plan created this workspace, which compiler emitted it, which warnings occurred. The operator could later ask "why is this pane here?" and c11 could answer from its own ledger.

## Leverage Points

The highest leverage move is to treat every ignored field as either a validation error or a typed warning. Phase 0 already fixed several silent drops, but the pattern is not complete.

For example, validation proves every referenced surface exists (`Sources/WorkspaceLayoutExecutor.swift:288`-`299`), but it does not prove every declared surface is referenced. A `SurfaceSpec` can be present in `plan.surfaces`, never appear in `LayoutTreeSpec`, and disappear without a warning. Similarly, kind-specific fields can still be ignored: `createSurface` handles browser/markdown `workingDirectory` without the warning that `splitFromPanel` emits (`Sources/WorkspaceLayoutExecutor.swift:621`-`647`, `Sources/WorkspaceLayoutExecutor.swift:801`-`825`), and command enqueue silently skips non-terminal specs (`Sources/WorkspaceLayoutExecutor.swift:179`-`196`).

Small change, large value: make "no silent intent loss" an invariant of the plan validator.

## The Flywheel

CMUX-37 can create a compounding loop:

1. More features compile into `WorkspaceApplyPlan`.
2. More plans become fixtures.
3. More fixtures exercise the same executor.
4. Better executor diagnostics make failed workspace creation explainable.
5. Explainable creation makes agents and humans trust declarative workspaces.
6. More trust pushes more features onto the primitive.

The rework already starts this flywheel by adding structural fixture checks. The next spin is capture/round-trip: once c11 can capture any live workspace into a plan and reapply it, every manually arranged workspace becomes a potential test case and Blueprint seed.

## Concrete Suggestions

1. **✅ Confirmed — High Value — Enforce plan graph closure and no-silent-intent validation.**

   Add validation that every `SurfaceSpec.id` is referenced exactly once by the layout, not merely that every layout reference is known. Today `validate(plan:)` builds `known` and `referencedIds` and returns success after walking the layout (`Sources/WorkspaceLayoutExecutor.swift:288`-`299`), but it never checks `known.subtracting(referencedIds)`. Unreferenced surfaces are neither created nor warned about because the walker only visits layout leaves (`Sources/WorkspaceLayoutExecutor.swift:423`-`541`).

   Extend this same pass into kind-specific intent checks:
   - terminal: `url`/`filePath` ignored unless rejected or warned,
   - browser: `command`, `filePath`, and `workingDirectory` need policy,
   - markdown: `command`, `url`, and `workingDirectory` need policy,
   - all kinds: invalid `url` should produce a typed failure rather than `URL(string:)` becoming nil (`Sources/WorkspaceLayoutExecutor.swift:628`, `Sources/WorkspaceLayoutExecutor.swift:814`).

   Compatibility: this fits the existing nonisolated validator and `ApplyFailure` model. Risk: old hand-authored plans with harmless extra surfaces would start warning or failing; make the policy explicit via `ApplyOptions` if needed.

2. **✅ Confirmed — High Value — Introduce stable `SurfaceSpec.name` separate from display title.**

   The C11-13 alignment doc says surface names are stable mailbox and Blueprint identities (`docs/c11-13-cmux-37-alignment.md:17`-`24`). Current Phase 0 has `SurfaceSpec.id` as a plan-local temporary handle and `SurfaceSpec.title` as display metadata (`Sources/WorkspaceApplyPlan.swift:56`-`84`). The plan notes say title is effectively the stable address, but that conflates human display label, metadata override behavior, and durable identity.

   Add `name: String?` or promote `id` into a durable `name` while keeping an internal apply handle. Then make the executor write that name through the same canonical metadata path as title/nameable panes. This prevents mailbox identity from changing because a user edits a tab label.

   Compatibility: can ship as optional in version 1 with fallback to `title ?? id`, then become required in version 2. Risk: needs coordination with existing nameable-pane conventions so "title" and "surface name" do not become two competing UI concepts.

3. **✅ Confirmed — High Value — Turn `ApplyResult` into a real execution ledger.**

   `ApplyResult` already returns refs, timings, warnings, and failures (`Sources/WorkspaceApplyPlan.swift:259`-`289`). That is close to a trace, but it cannot yet answer "what exactly happened?" The divider pass, for example, can append failures (`Sources/WorkspaceLayoutExecutor.swift:169`-`177`) but has no timing step, no record of successful divider applications, and no record of clamping at `Sources/WorkspaceLayoutExecutor.swift:861`.

   Add a structured `actions: [ApplyAction]` or `trace: ApplyTrace` with records like:
   - `workspace.created`,
   - `surface.reusedSeed`,
   - `surface.created`,
   - `surface.replacedSeed`,
   - `split.created`,
   - `metadata.written`,
   - `field.ignored`,
   - `divider.applied`,
   - `divider.clamped`.

   Compatibility: this can be additive on `ApplyResult`. Risk: keep payload compact for socket output; allow `traceLevel` in options.

4. **✅ Confirmed — High Value — Add negative acceptance fixtures for policy gaps.**

   The acceptance tests are now strong on positive structure (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:125`-`147`) and metadata round-trip (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:340`-`445`). They do not yet exercise orphan surfaces, invalid URLs, non-terminal commands, or browser/markdown `workingDirectory` through `createSurface`.

   There is also a small harness smell: the non-string mailbox assertion checks `message.contains("[\(key)")` at `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:423`-`428`, but executor messages are shaped like `pane metadata["mailbox.retention_days"] dropped` (`Sources/WorkspaceLayoutExecutor.swift:765`). The current fixture set only uses string mailbox values, so that branch appears unexercised.

   Compatibility: add one or two focused negative plans rather than broad source-shape tests, preserving the repo's test quality policy. Risk: none beyond deciding strict-vs-warning policy first.

5. **✅ Confirmed — Strategic — Build `WorkspaceApplyPlan.capture(from:)` early and make round-trip the north-star invariant.**

   The snapshot plan already calls for capture from live workspace state (`docs/c11-snapshot-restore-plan.md:179`-`188`). Implementing capture soon would turn the executor from one-way materializer into a reversible representation. Then CI can assert `plan -> apply -> capture -> equivalent plan` for the five fixtures and future fuzz cases.

   Compatibility: the current `LayoutTreeSpec` intentionally mirrors session layout snapshots (`Sources/WorkspaceApplyPlan.swift:111`-`187`), and the live tree is already available through `workspace.bonsplitController.treeSnapshot()` in tests (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:125`-`139`). Risk: snapshot-vs-blueprint abstraction levels differ; solve with normalized comparison modes rather than one universal equality.

6. **✅ Confirmed — Strategic — Retire welcome quad/default grid into plan builders via `applyToExistingWorkspace`.**

   `WelcomeSettings.performQuadLayout` and `DefaultGridSettings.performDefaultGrid` still hand-roll split choreography and carry TODOs to migrate once an existing-workspace apply overload exists (`Sources/c11App.swift:4000`-`4005`, `Sources/c11App.swift:4089`-`4093`). This is the best proving ground for the kernel because those flows are real product behavior, not just fixtures.

   Add `WorkspaceLayoutExecutor.applyToExistingWorkspace(_:workspace:seedPanel:options:)` and make welcome/default-grid compile tiny plans into it. The executor then owns both new-workspace and seed-workspace materialization.

   Compatibility: the current walker is already written around an injected `Workspace` and `AnchorPanel` (`Sources/WorkspaceLayoutExecutor.swift:124`-`160`, `Sources/WorkspaceLayoutExecutor.swift:372`-`394`), so this is more API extraction than redesign. Risk: remote-workspace guard in default grid must remain at call site or become an executor policy.

7. **❓ Needs exploration — Strategic — Replace synchronous apply with an async readiness pipeline before Phase 1 grows around it.**

   Phase 0 intentionally ships sync apply (`Sources/WorkspaceLayoutExecutor.swift:49`-`59`), and the socket handler runs materialization inside `v2MainSync` (`Sources/TerminalController.swift:4411`-`4426`). That is acceptable for creation-only Phase 0. But Snapshots and restart registry semantics want "created, attached, rendered, ready" states, and the snapshot plan explicitly names readiness as a future model (`docs/c11-snapshot-restore-plan.md:247`-`249`).

   Introduce readiness as an internal state machine before restore depends on command timing. Terminal command enqueue currently trusts `sendText` auto-queue (`Sources/WorkspaceLayoutExecutor.swift:179`-`196`); that may be fine, but the executor should eventually know whether a terminal is merely created or actually ready.

   Compatibility: will likely require async socket bridging rather than only `v2MainSync`. Risk: this touches socket scheduling, so it should be done as a narrow infrastructure change, not mixed into Blueprint parsing.

8. **❓ Needs exploration — Strategic — Make pane identity first-class in the plan.**

   Current `ApplyResult.paneRefs` maps plan surface id to live pane ref (`Sources/WorkspaceApplyPlan.swift:263`-`268`). That works for Phase 0 but makes a pane with multiple surface tabs appear as duplicate pane refs attached to surfaces. The older snapshot plan sketch included `PaneSpec.id` and pane-level metadata (`docs/c11-snapshot-restore-plan.md:75`-`80`), while the shipped value type moved pane metadata onto `SurfaceSpec.paneMetadata` (`Sources/WorkspaceApplyPlan.swift:79`-`84`).

   Consider restoring a lightweight pane id in `PaneSpec`. It would make pane-level metadata, pane refs, selected tab, mailbox placement, and future layout diffs cleaner. Surfaces belong to panes; pane identity should not have to be inferred through whichever surface happens to host the metadata.

   Compatibility: can be optional for v1 and synthesized during decode. Risk: it enlarges the schema, so do it only if Phase 1 capture/restore starts tripping over pane-vs-surface ownership.

9. **❓ Needs exploration — Experimental — Add a plan diff / dry-run mode.**

   Before mutating AppKit state, a dry-run could return the operations the executor intends to perform and the warnings it would emit. This would be valuable for Blueprint previews, CI debugging, and future reconcile-in-place. The current pure validation layer (`Sources/WorkspaceLayoutExecutor.swift:263`-`365`) is the seed; the next layer would be a pure planner that emits operations without touching `Workspace`.

10. **❓ Needs exploration — Experimental — Treat plans as agent-room choreography.**

   Once names and mailbox metadata are stable, a Blueprint can describe an agent room: driver, implementer, reviewer, test runner, docs pane, browser pane, and mailbox subscriptions. This stays within c11's "host and primitive" boundary because c11 is only materializing surfaces and metadata, not deciding agent behavior.

## Final Read

The rework appears to have fixed the cycle-1 architectural center: the walker is now top-down, and the harness can detect the malformed-tree class that slipped through before. The most valuable next step is not more polish on the walker; it is making `WorkspaceApplyPlan` a closed, typed intent graph where every declared bit of intent is either applied, rejected, or reported.

Name the primitive now: **workspace materialization kernel**. Once the team starts designing around that name, the next phases become cleaner: compilers in, validated plan graph, traced materialization out.
