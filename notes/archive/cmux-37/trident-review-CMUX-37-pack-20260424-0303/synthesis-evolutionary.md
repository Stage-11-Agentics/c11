# Synthesis — Evolutionary Review, CMUX-37 Phase 0

- **Branch:** `cmux-37/phase-0-workspace-apply-plan`
- **Latest commit:** `e4f60b98`
- **Sources:**
  - `notes/trident-review-CMUX-37-pack-20260424-0303/evolutionary-claude.md` (Claude Opus 4.7)
  - `notes/trident-review-CMUX-37-pack-20260424-0303/evolutionary-codex.md` (Codex / GPT-5)
  - `notes/trident-review-CMUX-37-pack-20260424-0303/evolutionary-gemini.md` (Gemini Experimental)
- **Review type:** Evolutionary / exploratory — how does this primitive want to grow?

---

## Executive Summary — The Biggest Opportunities

All three models converge on one thesis, expressed in three different vocabularies:

- **Claude:** "c11 is acquiring a declarative IR for workspace state." `WorkspaceApplyPlan` is the AST, `WorkspaceLayoutExecutor` is the interpreter, the socket handler is the REPL. Pattern name: **Plan / Executor / Reconciler** — "one reconciler short of being a small, focused Kubernetes for operator workspaces."
- **Codex:** "The first version of a **c11 room compiler** — a declarative JSON shape becomes a live workspace." The primitive is "materialize an operator/agent room from intent," and future layers (Blueprints, Snapshots, welcome-quad, default-grid, agent-authored rooms) should all target the same creation kernel.
- **Gemini:** "Terraform for Desktop Environments" — a **declarative, one-shot Native UI Reconciler** with emerging Virtual-DOM semantics (plan-local ids → live refs).

The same architectural move underlies every concrete suggestion: **protect and name the IR before more callers land, then give it one clean front door (executor) and one clean validator (off-main, Foundation-only).** Everything else — Snapshots, Blueprints, reconcile, `--all`, agent-authored rooms, remote plans — composes over that kernel for free. The cost of *not* doing this now is Phase 1/2/3 each growing their own parallel layout path, and `mailbox.*`-style metadata rules living in three places by Phase 5.

The top five opportunities, ranked by leverage-to-effort, collected across all three reviews:

1. **Factor steps 3-8 of `apply(...)` into an `applyToWorkspace(Workspace, seedPanel, ...)` private method**, with both `apply(...)` (creation) and a future `applyToExistingWorkspace(...)` as thin wrappers. All three models call this out. Claude and Codex explicitly; Gemini as "Idempotent Updates." It is a ~40-line reversible refactor that prevents Phase 1 from copy-pasting the metadata + layout walks. See `Sources/WorkspaceLayoutExecutor.swift:36-39`, `:82-94`.
2. **Promote `planSurfaceIdToPanelId` (Claude) / the plan-local-id → live-ref bridge (Codex) / the Virtual DOM identity map (Gemini) to a named `PlanResolution` type**, returned on `ApplyResult` or as a sidecar. This is the single load-bearing piece of mutable state in the walk; naming it now unblocks Phase 1 reconcile, Phase 2 diff, and agent manifests.
3. **Typed `ApplyFailureCode` enum (String-backed) replacing the stringly-typed `ApplyFailure.code`.** Claude flags this explicitly; Codex and Gemini touch on "stable failure codes" implicitly via the negative-fixtures and observable-failures suggestions. Wire shape unchanged (`rawValue: String`), but callers branch on a typed enum and the set is enumerable. `Sources/WorkspaceApplyPlan.swift:239-244`.
4. **Extract a reusable, Foundation-only `WorkspaceApplyPlanValidator`** (Codex; echoed by Claude's PlanKit framing and Gemini's "compile off-main" note). Moves the pure validation block at `Sources/WorkspaceLayoutExecutor.swift:222` into a pure validator. One front door for CLI `--check`, Blueprint parse, Snapshot restore preflight, and tests — all three models want this, though they frame it differently.
5. **`Workspace.currentPlan: WorkspaceApplyPlan { get }` computed property — the inverse executor.** Claude calls this "the move that turns Phase 0 from Blueprints preamble into c11 has a declarative workspace IR"; Codex frames it as the Snapshot-convergence converter; Gemini gets there via idempotent reconcile. Once this exists, Snapshot capture is one line (`fs.write(workspace.currentPlan)`), Blueprint export is the same line with a markdown skin, and plan-as-agent-sidebar-artifact becomes a live capability.

The tight second tier (all three models mention, slightly less unanimous):

6. **Make `perStepTimeoutMs` executable or remove the decorative promise.** Codex calls this out as an "anti-pattern: decorative contract fields"; Claude's `Clock` helper suggestion is adjacent. Currently `ApplyOptions.perStepTimeoutMs` promises warnings on overrun but the executor only records timings (`Sources/WorkspaceApplyPlan.swift:196`, `Sources/WorkspaceLayoutExecutor.swift:55, :60, :207`).
7. **Generalize `applyDividerPositions` into `zipPlanWithLiveTree(plan:live:visit:)`** — Claude explicitly; Gemini implicit in the reconciler framing. `Sources/WorkspaceLayoutExecutor.swift:716-744` is the first "walk two trees in lockstep" in the file and the template for Phase 1 reconcile + Phase 2 diff.
8. **Freeze CLI grammar + update the c11 skill before the primitive becomes public muscle memory.** Codex calls out the socket/CLI naming split (`workspace.apply` vs `workspace-apply` vs the plan doc's `c11 workspace apply --file`). `CLAUDE.md:37` treats CLI/socket/schema changes as incomplete without skill updates.

The wildest mutation all three touch, in different colors: **plans as coordination artifacts.** An agent emits its `currentPlan` to the sidebar or to stdout; the operator (or another agent) pastes it into `c11 workspace apply` on a different machine. Claude calls this "one step removed from time-travel debugging"; Gemini calls it "Agent Swarm Playbooks" and the (riskier) `<<<CMUX_APPLY_PLAN...>>>` stdout intercept; Codex frames it as "agents ask c11 to create a named team room and receive refs + mailbox routes + metadata in one response."

Two caveats flagged for the delegator at the end of this document, under **Constraint Watch**: some evolutionary suggestions would partially un-do deliberate Phase 0 constraints (async, scope creep, tenant-config writes). None of the top-tier suggestions trip them.

---

## 1. Consensus Direction — Evolution Paths Multiple Models Identified

The following themes appear in at least two of the three reviews, often all three, with distinct vocabularies that converge on the same architectural move.

### 1.1 Separate the executor from the "creates a new workspace" step

All three reviews independently identify this as the single most valuable refactor.

- **Claude** (`evolutionary-claude.md` Concrete #1, confirmed ✅): "Factor steps 3-8 into `applyToWorkspace(_:seedPanel:...) -> ApplyResult`; have `apply(_:options:dependencies:) -> ApplyResult` call `addWorkspace + applyToWorkspace`." Split point: `Sources/WorkspaceLayoutExecutor.swift:82-94`. Doc comment at `:37-39` already announces the direction.
- **Codex** (`evolutionary-codex.md` Concrete #4, confirmed ✅): "Add `applyToExistingWorkspace` as the migration bridge." Cites both welcome-quad and default-grid TODOs at `Sources/c11App.swift:4000` and `:4089`. Hard parts named: focus preservation, seed replacement. Keep `focus: false` on internal calls (per `Sources/WorkspaceLayoutExecutor.swift:503`); let the public option decide only final selection.
- **Gemini** (`evolutionary-gemini.md` Concrete #2, ❓ Needs exploration): "Idempotent Updates (`applyTo(existing:)`)." Frames it as a diff step — if a pane with the same `SurfaceSpec.id` already exists, update metadata/title instead of recreating. Flags that `ExternalTreeNode` (Bonsplit) and `LayoutTreeSpec` have different node identities; stable-ID tracking on re-apply is the real work.

**Consensus direction:** do the refactor now (creation + existing-workspace overload sharing one core walk). Keep the "reconcile rather than close-then-reopen" flavor as an explicit Phase 1+ stretch goal — it's the right direction but has ID-tracking design work none of the three would attempt blind.

### 1.2 The plan IR wants to be first-class

All three converge on "the shape `WorkspaceApplyPlan` has is bigger than the Blueprints ticket framing."

- **Claude:** "workspace-as-value" — shareable, diffable, mutatable off-app, version-controllable, agent-authored.
- **Codex:** "Room IR" — "the canonical room IR with converters" between `SessionWorkspaceLayoutSnapshot` (`Sources/SessionPersistence.swift:394`) and `LayoutTreeSpec` (`Sources/WorkspaceApplyPlan.swift:115`), plus a canonical JSON encoder.
- **Gemini:** "Virtual DOM for the workspace." Plan-local `SurfaceSpec.id` translated to `surface:N` live refs is the dawn pattern.

**Consensus direction:** name and protect the IR (**PlanKit**, per Codex) before more callers land. Built-in welcome/default-grid migrate to plans; Snapshot restore compiles through the same executor path; Blueprints are plans + light macros. The poor path all three explicitly warn against: Snapshot-specific restore + Blueprint-specific renderer + direct-split built-ins + a second socket/CLI naming convention.

### 1.3 Extract pure validation off-main, Foundation-only

- **Codex** (Concrete #1, confirmed ✅): "Extract a reusable `WorkspaceApplyPlanValidator`." Move `validate(plan:)` + `validateLayout` out of the executor (`Sources/WorkspaceLayoutExecutor.swift:222`). Add `version == 1` check (`Sources/WorkspaceApplyPlan.swift:13`) and out-of-range `dividerPosition` check before the executor silently clamps (`Sources/WorkspaceLayoutExecutor.swift:724`).
- **Claude:** the "PlanKit layer" framing; plan validation as one front door for CLI `--check`, Blueprint parse, Snapshot preflight.
- **Gemini:** "Pushing the parsing and AST compilation entirely off-main thread (leaving only strict AppKit `addSubview`/`insert` calls for the main actor) will make the next 10 features scalable."

**Consensus direction:** Foundation-only validator, runs off-main, returns structured diagnostics. This is the correct cleave plane between schema policy (validation, canonicalization, diffing) and AppKit mutation (the executor itself).

### 1.4 Plan-local id → live-ref map deserves a name

- **Claude** (Concrete #4, confirmed ✅): "Promote `planSurfaceIdToPanelId` to a named `PlanResolution` type, returned as part of `ApplyResult` (or carried as a sidecar)."
- **Codex:** framed as "plan-local identity in, live refs out" — the strongest emerging pattern in the branch. `Sources/WorkspaceApplyPlan.swift:56` (plan-local id) + `:256` (`ApplyResult.surfaceRefs`/`paneRefs`).
- **Gemini:** "Virtualization of Identity" — the Virtual-DOM pattern.

**Consensus direction:** surface this as a first-class concept, likely `PlanResolution { surfaces: [PlanSurfaceId: LiveSurfaceRef]; panes: ... ; workspace: ... }`. Phase 1 reconcile and agent manifests both want it.

### 1.5 Metadata as the capability bus, with rules in one registry

- **Claude** (Concrete #5, confirmed ✅): `MetadataNamespaceRegistry` with `mailbox.*` as first entry. Shape: `struct MetadataNamespace { prefix, validate, droppedCode }`. The `Sources/WorkspaceLayoutExecutor.swift:631-642` guard becomes one iteration over the registry.
- **Codex:** "Metadata as the capability bus… a room is born with its routing, role, status, and mailbox affordances already attached." Warns against metadata rules living in three places.
- **Gemini:** "The Metadata Bus as State" — `mailbox.*` strings-only dictionary is formalized as the primary communication bus.

**Consensus direction:** registry before Phase 1 adds `claude.*` session keys / Phase 2 adds `snapshot.*` source keys / Phase 5 adds `codex.*`, `opencode.*`. Without it, the executor accumulates branches; with it, tickets declare their prefix + validator.

### 1.6 Observable / reproducible failures

- **Gemini** (Concrete #4, confirmed ✅): "`ApplyResult.failures` State Serialization — write failures back into `Workspace.metadata["apply_failures"]`." Step 9 in `apply` injects into `workspace.setOperatorMetadata` before returning.
- **Codex:** "Replayable rooms — persist the exact applied plan and the executor's `ApplyResult` as provenance. A room becomes reproducible."
- **Claude:** "Partial-failure with stable codes (good, but beware silent failure)." Extends this via the typed `ApplyFailureCode` enum.

**Consensus direction:** (a) typed codes, (b) persist failures into the workspace metadata so recovery agents / the sidebar can see them, (c) optionally persist the applied plan as provenance. All three line up; worth doing as one small commit.

### 1.7 Streaming / progress events

- **Claude:** "From plan to plan-stream" — wrap per-step timings in `AsyncStream<StepTiming>`; socket streams events; sidebar renders "materializing 3/5."
- **Codex:** `StepTiming` is "already present" (`Sources/WorkspaceApplyPlan.swift:221`); one helper turns timings into enforceable diagnostics. Suggests this powers dry-run materialization traces too.
- **Gemini:** indirectly via "The Phase 0 acceptance fixture as a performance guardrail (< 2_000ms)" — pushing the AST compilation off-main makes the next 10 features scalable.

**Consensus direction:** `perStepTimeoutMs` becomes executable (Codex Concrete #2) first; streaming is the Phase 3 `--all` payoff (Claude Concrete #12). Short-term, this is a plumbing win; long-term it's the agent-telemetry integration.

---

## 2. Best Concrete Suggestions — Most Actionable Across All Three

Ranked by leverage-to-effort, flagged with origin and verification state.

### Tier A — ship on this branch or as the Phase 0-to-1 bridge commit

**A1. Factor `apply(...)` into `addWorkspace + applyToWorkspace(workspace, seedPanel, ...)`.**
- Source: Claude #1 (✅), Codex #4 (✅), Gemini #2 (❓ deeper variant).
- ~40 lines of movement, zero behavior change.
- Directly enables Phase 1's `applyToExistingWorkspace` without copy-paste.
- File: `Sources/WorkspaceLayoutExecutor.swift:82-94`; doc comment at `:36-39` already points at it.

**A2. Typed `ApplyFailureCode: String` enum replacing `ApplyFailure.code: String`.**
- Source: Claude #2 (✅).
- Wire shape unchanged (`rawValue: String`). Callers switch on an enumerable set.
- File: `Sources/WorkspaceApplyPlan.swift:239-244`.
- Codex Concrete #2 ("new failure code `step_timeout`") and Concrete #3 (negative fixtures) both assume this lands.

**A3. Extract `WorkspaceApplyPlanValidator` (Foundation-only, off-main).**
- Source: Codex #1 (✅); converges with Claude's PlanKit framing and Gemini's off-main note.
- Move `validate(plan:)` + `validateLayout` out of the executor (`Sources/WorkspaceLayoutExecutor.swift:222`) into a pure validator returning structured diagnostics.
- Add `version == 1` check (`Sources/WorkspaceApplyPlan.swift:13`) and out-of-range `dividerPosition` check (before the clamp at `Sources/WorkspaceLayoutExecutor.swift:724`).
- Single front door for future `--check`, Blueprint parse, Snapshot preflight, and tests.

**A4. Promote the plan-local id → live-ref map to a named `PlanResolution` type.**
- Source: Claude #4 (✅), Codex pattern observation, Gemini Virtual-DOM framing.
- Surface as first-class concept on `ApplyResult` or a sidecar.
- File: today buried in `WalkState` inside `Sources/WorkspaceLayoutExecutor.swift:315-698`.
- Phase 1 reconcile and agent manifests both need exactly this shape.

**A5. Make `perStepTimeoutMs` executable, or remove the promise.**
- Source: Codex #2 (✅); Claude's `Clock` helper suggestion is adjacent.
- Add a private `recordTiming(step:clock:)` helper that appends `StepTiming` and, when nonzero budget is exceeded, appends an `ApplyFailure` with code `step_timeout`.
- File: `Sources/WorkspaceLayoutExecutor.swift:55, :60, :207`; `Sources/WorkspaceApplyPlan.swift:196`.
- Depends on A2 (typed enum) for clean extension.

**A6. Add negative executor fixtures for mailbox and metadata collisions.**
- Source: Codex #3 (✅).
- One fixture where `mailbox.retention_days` is a number → expect `mailbox_non_string_value` failure code.
- One fixture where `SurfaceSpec.description` collides with metadata `description` → expect `metadata_override` (per `Sources/WorkspaceLayoutExecutor.swift:570`).
- Balances the positive round-trip at `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:79`.
- Behavior-level tests (decode fixture, apply, inspect result/stores) — not source-text assertions. Consistent with the project's Test Quality Policy.

**A7. Freeze CLI grammar + update the c11 skill.**
- Source: Codex #6 (✅); directly called out by the worktree `CLAUDE.md:37` ("the skill is the agent's steering wheel").
- Socket: `workspace.apply` (`Sources/TerminalController.swift:2105`).
- CLI today: `workspace-apply` (`CLI/c11.swift:1713`). Plan doc names `c11 workspace apply --file`.
- Pick the long-term shape, add compat if needed, update the skill. Agents learn command shapes from the skill; stale examples make the primitive less useful.

**A8. Persist `ApplyResult.failures` into `workspace.metadata["apply_failures"]`.**
- Source: Gemini #4 (✅); adjacent to Codex's replayable-rooms idea.
- Step 9 in `apply` injects into `workspace.setOperatorMetadata` before returning.
- Gives recovery agents / the sidebar something to query after a partial failure.
- Cheap; composes with A2 (typed codes make the serialized value useful).

**Rough ordering for a single PR:** A1 + A2 land together as a cleanup commit on this branch. A3 + A4 together as a Phase 0-to-1 bridge commit. A5 + A6 + A8 as a "failures are observable" commit. A7 as its own (doc + CLI) commit. None of these require leaving the Phase 0 scope envelope.

### Tier B — strategic, queue for Phase 1 PR

**B1. `MetadataNamespaceRegistry`** with `mailbox.*` as first entry (Claude #5 ✅). ~80 lines. Beats the three-places outcome.

**B2. Generalize `applyDividerPositions` into `zipPlanWithLiveTree(_:_:visit:)`** (Claude #7 ✅). `Sources/WorkspaceLayoutExecutor.swift:716-744`. Unlocks reconcile + diff visitors.

**B3. `WorkspaceApplyPlan` canonical encoder + translators between `SessionWorkspaceLayoutSnapshot` and `LayoutTreeSpec`** (Codex #5 ❓). The Snapshot/Blueprint convergence point.

**B4. `Workspace.currentPlan: WorkspaceApplyPlan { get }` computed property** (Claude #8 ❓). The single highest-leverage Phase 1 move. Snapshot capture becomes `fs.write(workspace.currentPlan)`.

**B5. `v2MainSync<T>(...) -> Result<T, V2Error>`** generic socket-handler template (Claude #6 ❓). `Sources/TerminalController.swift:4346-4417`. Every future executor-backed primitive shrinks to ~15 lines.

**B6. Apply-to-existing-workspace that diffs rather than recreates** (Gemini #2 ❓). Requires B4 + A4 to be real first. Pays for itself in hot-reload blueprint UX and "watch" agent reconcile loops.

### Tier C — experimental, revisit once B-tier is real

**C1. Dry-run materialization trace** (Codex #7 ❓). `workspace.apply --dry-run`. Needs A3 + B4.
**C2. Plan composition / inheritance** — `planA + planB` with an explicit merge strategy (Claude mutation #2). Revisit after Phase 2 Blueprint usage shakes out the merge rules.
**C3. `c11 workspace diff <plan-a> <plan-b>`** (Claude #9). ~150 lines; uses B3.
**C4. Streaming `workspace.apply.stream` via socket event channel** (Claude #12). Phase 3 `--all` payoff.

---

## 3. Wildest Mutations — Creative Directions Worth Exploring

### 3.1 Plan as coordination artifact (all three)

Agents emit their `currentPlan` as a live sidebar artifact (or a fenced stdout block). Operators — or other agents — can, at any point, `c11 workspace apply` that plan on a different machine and resume from exactly that context.

- Claude: "one step removed from time-travel debugging" (Wild Idea #3).
- Codex: "agents can ask c11 to create a named team room and receive refs, mailbox routes, and manifest metadata in one response" (agent team manifests).
- Gemini: "First-Class Plan Emitting by Agents — define a sequence like `<<<CMUX_APPLY_PLAN...>>>` that the terminal controller intercepts" (⚠ flagged under Constraint Watch, see §5).

Why it matters for the flywheel: workspaces become a communication primitive ("here's my shape") and a restore primitive ("start me there") using the same value type. Loop-closing.

### 3.2 Agent Swarm Playbooks / Room Macros (Gemini + Codex)

Blueprints compile to a plan plus simple macros: `agent_triplet(role:)`, `watcher(topic:)`, `review_matrix(models:)`, `agent_swarm(dispatcher:)`. Dispatcher pane + N subscribers pre-wired via `mailbox.*` at creation. The executor does not know macros; it consumes the expanded plan.

### 3.3 Composable blueprints via `$import` (Gemini #3, Claude Wild #2)

`$import: "path/to/other/plan.json"` within `WorkspaceApplyPlan`. Shared tool configurations (a standardized debug split, a cc-overlay) inject into any workspace. Claude frames it as plan composition with an explicit merge strategy (`base-welcome.json + cc→codex-overlay.json`).

### 3.4 Blueprint as code (Claude Wild #1)

`*.swift` files evaluated in a sandbox that produce a `WorkspaceApplyPlan` value. Safer variants: restricted DSL (Cue / Starlark) or `*.json.template + env substitution`. Markdown stays the default skin; code is the escape hatch for power users who want `makePlan(repo: "auth", agent: "cc")`.

### 3.5 Remote plans (Claude Wild #6)

`WorkspaceApplyPlan` references no local-machine-specific state. Routing a plan over `ssh` to a remote c11 instance's socket is not architectural work — it's a socket-forwarding decision. "Open the auth-debug workspace on my laptop from this machine."

### 3.6 Headless executor (Gemini #2 Mutations)

Execute `WorkspaceLayoutExecutor` without a visible window. Generate a headless virtual session, snapshot output, destroy. Requires decoupling the executor from `TabManager` + AppKit (which A1 + A3 already push toward). Unlocks server-side rendering, lint-check of blueprints in CI, and mass-test of complex split trees without Ghostty surfaces.

### 3.7 Event-sourced workspace (Claude Wild #5)

Every operator action (split, close, rename) emits a plan *delta* to a log. The log is a replay of the session. Overkill for Phase 0, but the shape today is compatible.

### 3.8 Layout optimizer (Codex Wild)

Preflight pass normalizes split trees, clamps / rejects divider positions, estimates pane counts, warns when the plan is too dense for the current screen. Especially relevant for operators running many agents in parallel.

### 3.9 Blueprint library as social artifact (Claude Wild #7)

Once plans are shareable JSON, a `cmux-blueprints` repo emerges: community-curated debug layouts, agent-coordination patterns, operator starter kits. The Phase 2 picker pulls from local + `~/.config` + optional library URL. Long-tail but strategic — this is where the operator-agent pair community ossifies into shared patterns.

### 3.10 Plan diffing as a UI primitive (Claude Wild #4)

Structural diff over two `WorkspaceApplyPlan` values renders as a visual tree. "Welcome quad vs default grid: 2 surfaces different, 3 titles different." Sidebar's "what changed when I applied this" view. ~60 lines of recursive function; whole new class of agent-operator communication.

---

## 4. Leverage Points and Flywheel Opportunities

### 4.1 Small-change / high-leverage points

All three reviews agree on the surface area where a tiny code change unlocks disproportionate downstream value.

1. **The plan-local id → live-ref map.** (§1.4, A4.) `Sources/WorkspaceLayoutExecutor.swift:315-698` WalkState. Name it, promote it, and reconcile + manifests + diff are one visitor each.
2. **The `AnchorPanel` abstraction in `WalkState`** (Gemini Leverage Point). Binds directly to AppKit (`TerminalPanel`, `newXSplit`). Extract to a `WorkspaceSurfaceDriver` interface and in-memory tests run without XCTest performance budgets. Enables Gemini's headless executor and Claude's plan-composition testing.
3. **The `Clock` helper** (Claude Leverage Point). `Sources/WorkspaceLayoutExecutor.swift:751-757` is minimal but perfect. Promote from `fileprivate` once any other function needs timing. Future agent-reporting code wants this shape.
4. **`applyDividerPositions` as the first "walk two trees in lockstep."** (§B2.) `Sources/WorkspaceLayoutExecutor.swift:716-744`. Template for Phase 1 reconcile + Phase 2 diff.
5. **The socket handler is thinner than it looks.** (§B5.) `Sources/TerminalController.swift:4346-4417`. Generalize `v2MainSync<T>` once; every future executor-backed primitive shrinks to ~15 lines.
6. **The CLI `workspace-apply` subcommand is a template.** Extract `runPlanSubcommand(method:, args:)` from `CLI/c11.swift:1713` and Phase 1's 3-4 CLI commands each become one line.
7. **The acceptance fixtures are the contract documentation.** `c11Tests/Fixtures/workspace-apply-plans/*.json` define the wire shape more concretely than any doc comment. Treat them as canonical examples, not just test fodder.

### 4.2 Flywheels

The three reviews independently describe four overlapping compounding loops:

**Loop 1 — Agent ↔ Plan (Claude).** Agents learn (via the skill) to emit their workspace state as a `WorkspaceApplyPlan`. Operators can restore any agent's context. More plans emitted → better restore → operators trust agents more → agents run longer → more plans emitted.

**Loop 2 — Blueprint ↔ Operator (Claude + Codex).** Operators build blueprints once, run them often. Each run exposes friction (missing commands, wrong cwd). Blueprint gets refined. Refined blueprint shared across machines / team members / public repo. More blueprints → easier to start new work → more starts → more blueprints.

**Loop 3 — Plan ↔ Platform (Claude).** Blueprints become the canonical starter for Stage 11 projects. The Entrance Interview emits a blueprint. `c11 workspace new` becomes "pick from recency-sorted library." Library grows. Library becomes the on-ramp for new operators.

**Loop 4 — Plan ↔ Everywhere (Claude + Codex).** Plans flow through Zulip messages, Lattice tickets, sidebar artifacts. "Here's my workspace shape" becomes a new communication primitive.

**Gemini's Infrastructure-as-Code flywheel** is a tighter restatement:
1. Declarative CLI (`c11 workspace apply`).
2. Agents write JSON plans to structure their environment.
3. Richer environments → harder problems solved.
4. Complex playbooks → saved as Snapshots.
5. Operators inherit a library of highly optimized agent-created environments.

**Codex's condensed version:** declarative room plans → executable fixture coverage → reusable built-in templates → agent-authored workspaces → richer metadata/mailbox conventions → better plans.

### 4.3 Starter motor — what sets the flywheel spinning

Claude: "A crisp early demo where *one plan JSON*, pasted into the socket, produces a working multi-surface workspace with an agent already running." The acceptance fixture is 80% there — `welcome-quad.json` fully materializes, including launching `claude` in the BR pane. Ship this, operators notice, agents notice, loops start.

The single highest-leverage move now (Claude, closing paragraph): **make `workspace-apply` the first thing the operator thinks of when they want a workspace with a specific shape.** Not when they want to debug the executor. Happens when (a) Phase 2 blueprints ship, (b) the CLI output is polished. Invest in the demo experience of applying one good plan, and the flywheel has a starter motor.

---

## 5. Constraint Watch — Evolutionary Suggestions That Would Un-Do Phase 0 Decisions

Per the delegator's instruction, flagging suggestions that partially regress deliberate Phase 0 constraints. None of the Tier A suggestions trip these; most of the mutations are safe if scoped; a handful of Gemini and Claude wild ideas need care.

**5.1 Terminal output scraping (`<<<CMUX_APPLY_PLAN...>>>`).** Gemini Concrete #3 (❓ Needs exploration) explicitly flags this: "requires terminal output scraping which might violate the unopinionated about the terminal principle." Per the worktree `CLAUDE.md`'s "unopinionated about the terminal" section: **c11 does not reach into an agent's stdout to intercept sequences.** The right version is skill-driven self-emission — agents call `c11 workspace apply --file -` on their own initiative. Path: keep the mutation (agents emit plans), reject the transport (stdout interception).

**5.2 Blueprint-as-code via Swift playground.** Claude Wild #1. Sandboxing Swift execution is non-trivial and smells like scope creep beyond "unopinionated about the terminal." Safer variants (restricted DSL, JSON template + env substitution) are fine. Full Swift evaluation should stay parked until there's a demonstrated need and a real sandbox story — Phase 6+ material if ever.

**5.3 Anything that pushes `mailbox.*` to structured values before C11-13 is ready.** Claude's evolution note "from strings-only mailbox to schema evolution" is correct long-term but explicitly conditional: "delete ~12 lines, add a `schema_version` field, the migration is done in one commit across both tickets." The Phase 0 strings-only guard (`Sources/WorkspaceLayoutExecutor.swift:631-642`) is the contract; do not soften it until C11-13 is ready. Codex and Gemini both observe this correctly and do not propose removing the guard early.

**5.4 Re-introducing async on the executor hot path.** None of the three reviews propose this directly, but a naive reading of Claude's "plan-stream" suggestion (wrap per-step timings in `AsyncStream<StepTiming>`) could invite async creep inside the `@MainActor` walk. The project's **Socket command threading policy** in `CLAUDE.md` applies: telemetry parses off-main, UI mutation on-main. Streaming is plumbing *around* the executor (the socket event channel), not *inside* it. Land it that way or not at all.

**5.5 Writing to tenant tool configs.** None of the three reviews propose this. Explicitly called out in `CLAUDE.md` as a hard constraint: the one outgoing touch is the skill file. No agent-install hooks into `~/.claude/settings.json`, `~/.codex/*`, `~/.kimi/*`, shell rc files. If a future mutation (e.g., "auto-inject c11 skill awareness into agent configs on blueprint apply") is proposed, reject it on sight.

**5.6 Test-quality policy on "source text" tests.** All three reviews correctly stay behavior-level. Codex explicitly flags: "Keep [validation] Foundation-only so it can run off-main and outside AppKit. Do not turn this into source-text tests; exercise it through decoded plan values." Preserve this discipline on the negative fixtures (A6) and the validator tests (A3).

**5.7 Scope creep into Snapshot / Blueprint implementation on this branch.** Phase 0 is declarative IR + creation executor + socket + CLI + fixtures. All three reviews are careful to frame evolutionary ideas as Phase 1+ work. The Tier B and Tier C items should not land on this branch. A1, A2, A3, A4, A5, A6, A7, A8 can. Keep the Phase-0-to-1 bridge commit tight.

---

## Closing Note

The unusual thing about these three reviews is how much they agree, and how cleanly their vocabularies map onto each other. "Plan / Executor / Reconciler" (Claude), "Room Compiler + PlanKit" (Codex), and "Terraform for Desktop + Native UI Reconciler" (Gemini) are three names for the same primitive. The convergence is a signal that the architectural direction is sound and the next moves are knowable — not guesses.

The cost of acting on the Tier A list is small, reversible, and strictly additive to the Phase 0 shape. The cost of *not* acting is the poor-path outcome all three models explicitly name: Phase 1 adds a Snapshot-specific restore path; Phase 2 adds a Blueprint-specific renderer; built-ins keep direct split code; the socket/CLI grows a second naming convention; metadata rules live in three places.

The operator-agent pair benefits most when the IR is named and guarded before more callers land. That's what this branch's next cleanup commit should do.
