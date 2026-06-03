## Evolutionary Code Review
- **Date:** 2026-04-24T07:08:15Z
- **Model:** Ucodex (Codex, GPT-5)
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** e4f60b98
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

Scope note: this is a Phase 0 review only. Blueprint parser, Snapshot writer, restart registry, and resume behavior are intentionally out of scope. Per the outer prompt, I did not fetch, pull, run tests, commit, or write outside this file. `origin/dev` is not available in this worktree, so branch scope was checked against `origin/main...HEAD` and the provided `notes/.tmp/trident-CMUX-37/full.diff`.

**What's Really Being Built**

This is not just a workspace layout feature. It is the first version of a c11 room compiler: a declarative JSON shape becomes a live workspace with panes, tabs, surface kinds, metadata, mailbox configuration, initial commands, and refs. The important new primitive is not "make a quad." It is "materialize an operator/agent room from intent."

That matters because c11's higher layers need one shared intermediate representation. `WorkspaceApplyPlan` already mirrors session layout structures (`Sources/WorkspaceApplyPlan.swift:111`, `Sources/SessionPersistence.swift:394`) and reuses persisted metadata values (`Sources/WorkspaceApplyPlan.swift:76`, `Sources/SessionPersistence.swift:327`). If this evolves well, Blueprints, Snapshots, welcome/default-grid, and agent-authored rooms can all target the same creation kernel instead of each inventing its own layout path.

**Emerging Patterns**

The strongest pattern is "plan-local identity in, live refs out." `SurfaceSpec.id` is deliberately temporary (`Sources/WorkspaceApplyPlan.swift:56`) and `ApplyResult.surfaceRefs`/`paneRefs` become the live bridge (`Sources/WorkspaceApplyPlan.swift:256`). That gives future systems a clean boundary: persistent plans do not leak process-local `surface:N` handles, while runtime callers still get handles immediately.

The second pattern is metadata as the capability bus. Surface metadata, pane metadata, and `mailbox.*` are being applied at creation time, not via post-hoc socket loops (`Sources/WorkspaceLayoutExecutor.swift:539`). That is the right direction: a room is born with its routing, role, status, and mailbox affordances already attached.

The anti-pattern to catch early is decorative contract fields. `version` exists but is not validated (`Sources/WorkspaceApplyPlan.swift:13`), and `ApplyOptions.perStepTimeoutMs` promises deadline warnings but is not consumed by the executor (`Sources/WorkspaceApplyPlan.swift:196`, `Sources/WorkspaceLayoutExecutor.swift:55`). These are easy to fix now; if they spread into Blueprint/Snapshot phases as comments-only contracts, later migrations get vague.

The socket/CLI surface is also forming a naming split: the socket method is `workspace.apply` (`Sources/TerminalController.swift:2105`), while the CLI command is `workspace-apply` (`CLI/c11.swift:1713`) even though the plan text names `c11 workspace apply --file`. Before this becomes public muscle memory, it is worth freezing the grammar.

**How This Could Evolve**

The natural next architecture is a small PlanKit layer around `WorkspaceApplyPlan`: validation, canonicalization, diffing, conversion from snapshots, conversion from built-in templates, and a dry-run materialization trace. The executor then becomes only the AppKit/Bonsplit mutator, not the place where schema policy accumulates.

Six months from now, the good version is:

- `WorkspaceApplyPlan` is the canonical room IR.
- Built-in welcome/default-grid are expressed as plans.
- Snapshot restore compiles a captured room back through the same executor path.
- Blueprints are just authored plans plus light macros.
- Agents can ask c11 to create a named team room and receive refs, mailbox routes, and manifest metadata in one response.

The poor version is:

- Phase 1 adds a Snapshot-specific restore path.
- Phase 2 adds a Blueprint-specific renderer.
- Built-ins keep direct split code.
- Socket/CLI gets a second naming convention.
- Metadata rules live in three places.

This branch is close to the good path. The main move is to name and protect the IR before more callers land.

**Mutations and Wild Ideas**

Room macros: let a Blueprint compile to a `WorkspaceApplyPlan` plus simple macros like `agent_triplet(role:)`, `watcher(topic:)`, or `review_matrix(models:)`. The executor does not know macros; it only consumes the expanded plan.

Layout optimizer: add a preflight pass that can normalize split trees, clamp or reject divider positions, estimate pane counts, and warn when a plan will create a layout too dense for the current screen. This is especially relevant for the operator running many agents at once.

Agent team manifests: pair `workspace.apply` with a returned manifest that maps plan ids to surface refs, pane refs, titles, mailbox routes, and metadata. Agents could consume that manifest directly instead of scraping `c11 tree`.

Replayable rooms: persist the exact applied plan and the executor's `ApplyResult` as provenance. A room becomes reproducible: "this workspace came from plan X, materialized at time Y, with these warnings." That opens the door to rollback-like recreation without rolling back live partial failures.

Surface name ledger: C11-13 says messaging addresses surfaces by name (`docs/c11-13-cmux-37-alignment.md:22`) and `mailbox.*` lives in pane metadata (`docs/c11-13-cmux-37-alignment.md:28`). Today title/name/display identity are closely coupled. A future explicit `name` field might be useful if the product wants stable mailbox identity independent from display title, but this needs design care because Phase 0 intentionally uses title as the surface-name bridge.

**Leverage Points**

Small changes with high downstream leverage:

- Extract validation now. The current pure validation block is already isolated (`Sources/WorkspaceLayoutExecutor.swift:222`), so it can become reusable without touching AppKit paths.
- Make the timing budget real. `StepTiming` is already present (`Sources/WorkspaceApplyPlan.swift:221`); one helper can turn timings into enforceable diagnostics.
- Add negative executor fixtures. The positive mailbox round-trip is covered (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:79`), but the future contract needs explicit failure-code coverage.
- Add an apply-to-existing-workspace overload. Both TODO sites already point at it (`Sources/c11App.swift:4000`, `Sources/c11App.swift:4089`); this is the bridge from "debug primitive" to "all built-in room creation uses the same compiler."
- Update the c11 skill when the command shape stabilizes. The repo contract says CLI/socket/schema changes are incomplete until the skill is updated (`CLAUDE.md:37`).

**The Flywheel**

The flywheel is: declarative room plans -> executable fixture coverage -> reusable built-in templates -> agent-authored workspaces -> richer metadata/mailbox conventions -> better plans.

Every new room shape added as JSON improves tests and future Blueprint examples. Every migrated built-in reduces bespoke split code. Every metadata convention attached at creation time makes agents more capable without c11 reaching into their process. That is a strong compounding loop if the plan format stays small, explicit, and validated.

**Concrete Suggestions**

1. **High Value — Extract a reusable `WorkspaceApplyPlanValidator`.** ✅ Confirmed — verified this would work.

   Move `validate(plan:)` and `validateLayout` out of `WorkspaceLayoutExecutor` (`Sources/WorkspaceLayoutExecutor.swift:222`) into a pure validator that returns structured diagnostics. Add checks for `version == 1` (`Sources/WorkspaceApplyPlan.swift:13`) and out-of-range `dividerPosition` before the executor silently clamps it (`Sources/WorkspaceLayoutExecutor.swift:724`). This creates one front door for CLI `--check`, Blueprint parse, Snapshot restore preflight, and tests.

   Dependency/risk: keep it Foundation-only so it can run off-main and outside AppKit. Do not turn this into source-text tests; exercise it through decoded plan values.

2. **High Value — Make `perStepTimeoutMs` executable or remove the promise.** ✅ Confirmed — verified this would work.

   `ApplyOptions.perStepTimeoutMs` says overruns append warnings (`Sources/WorkspaceApplyPlan.swift:196`), but the executor currently only records timings (`Sources/WorkspaceLayoutExecutor.swift:60`, `Sources/WorkspaceLayoutExecutor.swift:207`). Add a private `recordTiming(step:clock:)` helper that appends `StepTiming` and, when the option is nonzero and elapsed exceeds the budget, appends a warning/failure such as `step_timeout`.

   Dependency/risk: adding a new failure code is backward-compatible, but update the known-code comment in `ApplyFailure` (`Sources/WorkspaceApplyPlan.swift:238`) and add a focused test that injects an intentionally tiny timeout.

3. **High Value — Add negative executor fixtures for mailbox and metadata collisions.** ✅ Confirmed — verified this would work.

   The Codable tests intentionally prove non-string `mailbox.*` values can survive the wire (`c11Tests/WorkspaceApplyPlanCodableTests.swift:93`), and the executor has the guard (`Sources/WorkspaceLayoutExecutor.swift:631`). The acceptance fixture only checks the positive round-trip (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:79`). Add one executor-level fixture where `mailbox.retention_days` is a number and assert `mailbox_non_string_value`, and one where `SurfaceSpec.description` collides with metadata `description` and assert `metadata_override` (`Sources/WorkspaceLayoutExecutor.swift:570`).

   Dependency/risk: no local test run per `CLAUDE.md`; this should be assessed in CI. Keep the tests behavior-level: decode fixture, apply plan, inspect `ApplyResult` and stores.

4. **Strategic — Add `applyToExistingWorkspace` as the migration bridge.** ✅ Confirmed — verified this would work.

   The executor comments already name this Phase 1 direction (`Sources/WorkspaceLayoutExecutor.swift:36`), and both built-in migration TODOs are waiting for it (`Sources/c11App.swift:4000`, `Sources/c11App.swift:4089`). Make the internal walker accept an injected `Workspace` plus seed panel, then expose creation and existing-workspace entry points over the same core.

   Dependency/risk: focus preservation and seed replacement are the hard parts. Keep `focus: false` on internal split/surface calls as Phase 0 does (`Sources/WorkspaceLayoutExecutor.swift:503`) and let the public option decide only final selection.

5. **Strategic — Promote `WorkspaceApplyPlan` into canonical room IR with converters.** ❓ Needs exploration — promising but needs prototyping.

   Add explicit translators between `SessionWorkspaceLayoutSnapshot` and `LayoutTreeSpec` (`Sources/SessionPersistence.swift:394`, `Sources/WorkspaceApplyPlan.swift:115`) plus a canonical JSON encoder. This makes Snapshot capture/restore and Blueprint expansion converge on one schema instead of parallel structures.

   Dependency/risk: snapshot panel UUIDs and plan-local surface ids need a deterministic mapping. This should be a small converter with tests around identity mapping, not a broad persistence refactor.

6. **Strategic — Freeze CLI grammar and skill docs before this becomes public.** ✅ Confirmed — verified this would work.

   The socket method is correctly registered as `workspace.apply` (`Sources/TerminalController.swift:2105`) and supported in the v2 method list (`Sources/TerminalController.swift:2536`). The CLI currently ships `workspace-apply` (`CLI/c11.swift:1713`), while the Phase 0 plan names `c11 workspace apply --file`. Pick the long-term command shape, add compatibility if needed, and update the c11 skill because the repo explicitly treats CLI/socket/schema changes as incomplete without skill updates (`CLAUDE.md:37`).

   Dependency/risk: this is mostly product/API polish, but it compounds. Agents learn command shapes from the skill; stale examples make the primitive less useful.

7. **Experimental — Add dry-run materialization traces.** ❓ Needs exploration — promising but needs prototyping.

   `workspace.apply --dry-run` could decode and validate a plan, then return the planned workspace title, pane count, surface count by kind, metadata writes, mailbox warnings, and a split-tree trace without mutating AppKit. The existing pure validation and `StepTiming` concepts are enough to start; the executor should not be responsible for this once PlanKit exists.

   Dependency/risk: dry-run must not pretend it can predict all Bonsplit failures. Report it as "static materialization trace," not a guarantee.

8. **Experimental — Consider stable `name` separate from display title.** ❓ Needs exploration — promising but needs prototyping.

   C11-13 aligns mailbox identity around surface names (`docs/c11-13-cmux-37-alignment.md:22`) and Phase 0 currently routes `SurfaceSpec.title` through the canonical title setter (`Sources/WorkspaceApplyPlan.swift:61`, `Sources/WorkspaceLayoutExecutor.swift:399`). If display titles become operator-facing and mutable while mailbox identity wants to be durable, a separate stable name may be worth adding before Blueprints freeze.

   Dependency/risk: this can easily fight the current alignment doc, so treat it as a design question, not a Phase 0 change.

**Validation Notes**

Read and grounded in: root `CLAUDE.md`, the Phase 0 plan section, C11-13 alignment doc, full diff hunk index, `WorkspaceApplyPlan`, `WorkspaceLayoutExecutor`, metadata stores, socket/CLI entry points, acceptance tests, and all five fixture summaries.

Branch shape matches the provided context: 9 code commits plus 1 plan-doc commit, latest `e4f60b98`, with changes limited to the expected 15 files. Hot-path files named in the policy (`TerminalWindowPortal.swift`, `ContentView.swift`/`TabItemView`, `GhosttyTerminalView.swift`) are not in `git diff --name-only origin/main...HEAD`. No terminal-opinion creep was found in changed paths: `Resources/bin/claude` and tenant tool config paths are untouched.

Tests were not run locally, per policy.
