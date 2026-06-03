## Evolutionary Code Review
- **Date:** 2026-04-24T10:11:21Z
- **Model:** Claude Opus (claude-opus-4-7)
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** bf80210115017744f4eb5cf11d096bb88e336116
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary / Exploratory (Cycle 2)
---

## TL;DR — Cycle 2 Stance

Cycle 1's blockers (B1 walker, B2 harness) and the four Importants (I1–I4) are all addressed by R1–R7. The rework is coherent; the walker is now top-down and composes correctly against bonsplit's leaf-only API, the harness asserts tree shape + metadata round-trip on every fixture, and the silent-failure gaps are closed with typed `ApplyFailure` codes. What's really interesting isn't the fix itself — it's that **CMUX-37 has just invented the primitive that the rest of c11 has been improvising without.** The evolution surface is very large. This review is about naming that primitive, spotting what it unlocks, and calling out the places where momentum will carry the codebase somewhere interesting or somewhere painful.

---

## What's Really Being Built

Not "Phase 0 of workspace persistence." What just landed is **c11's first declarative layout compiler** — a closed-form translator from `(WorkspaceApplyPlan) → (live bonsplit tree + metadata stores + terminal processes)`. Every capability that has been written imperatively against `Workspace`/`TabManager`/`bonsplit` for the last several releases — welcome-quad, default-grid, Session restore, v2 `workspace.create`, even operator-driven "open these four panes for me" splits — has a reduction to this one function. That is a strictly bigger win than "we can now restore a JSON plan."

Name it: **the workspace compiler**. Frontend = JSON (Phase 0), Markdown/YAML Blueprint (Phase 2), Session snapshot (Phase 1), mailbox bootstrap bundle (C11-13 adjacent). Backend = bonsplit + metadata stores + Ghostty surfaces. Middle IR = `WorkspaceApplyPlan`. Once you see it this way, the roadmap reshapes: everything that creates a workspace shape — welcome-quad, default-grid, Blueprint materialization, Snapshot restore, operator-authored `c11 workspace apply`, C11-13 bootstrap — becomes a different *source language* for the same IR. The executor becomes the One True Code Path for workspace construction.

Second capability nobody has named yet: **typed partial-failure telemetry**. `ApplyFailure.code ∈ { unsupported_version, duplicate_surface_id, unknown_surface_ref, duplicate_surface_reference, surface_create_failed, metadata_write_failed, metadata_override, split_failed, mailbox_non_string_value, working_directory_not_applied, divider_apply_failed, per_step_timeout_exceeded, seed_panel_missing, validation_failed }` — that's not just error handling, it's a **structured observability stream** over workspace construction. The `StepTiming[]` alongside it turns apply() into a self-instrumenting operation. This is infrastructure that C11-13, Snapshot restore, CI acceptance, and operator debugging all consume. It deserves a name and a shape of its own (see Concrete Suggestions #3).

Third — and this is the biggest unstated win: **the executor is the coordination ground-truth for the operator:agent pair.** Once Blueprints exist and an agent can author one, `c11 workspace apply --file plan.json` becomes the way an agent asks c11 to give it a working environment — "I need two terminal panes, a markdown scratch, and a browser pointed at localhost:3000." Today agents call `c11 split` and `c11 surface open` imperatively, one at a time, with the CLI as the composition layer. `WorkspaceApplyPlan` makes the plan itself the unit of work. That's a phase shift in how agents negotiate their environment. The skill (`skills/c11/SKILL.md`) doesn't know about this yet; when it does, agents get dramatically more capable in one step.

---

## Emerging Patterns (and what to formalize)

### 1. The "middle IR with frontends and backends" pattern

`WorkspaceApplyPlan` is the IR, `LayoutTreeSpec` is the middle-end, the bonsplit/metadata/Ghostty stack is the backend. This pattern will repeat. The right response is to **formalize the contract** early so each frontend lands cleanly:

- **Frontends today / future:** debug CLI JSON (shipped), Session snapshot (Phase 1), Blueprint Markdown (Phase 2), existing welcome-quad/default-grid (migration gated on apply-to-existing), C11-13 mailbox bootstrap (potential), operator-authored YAML (imaginable).
- **Backend contract:** everything goes through `WorkspaceLayoutExecutor.apply`. No frontend may bypass the executor to mutate bonsplit or the metadata stores directly during workspace construction. (Runtime mutation — `c11 set-metadata`, `c11 mailbox configure` — stays on its own path, by design; the alignment doc locks this.)

The formalization step: publish `WorkspaceApplyPlan` schema with semver, `LayoutTreeSpec` as a public type with docs, and a one-paragraph rule in `skills/c11/SKILL.md` saying "to construct a workspace, author a plan and apply it — don't sequence split CLI calls." Once that's in the skill, future agents naturally converge on the primitive.

### 2. The "timed step + typed failure" pattern

`StepTiming[]` + `ApplyFailure[]` as co-returned channels is not a one-off. It's exactly the right shape for any **long-running composite operation with partial-failure semantics** (restore, export, sync, teardown, migration). Name the pattern `StepLog` (or `OperationResult<T>`) and extract it:

```swift
struct StepLog<Failure: StepFailure> {
  var timings: [StepTiming]
  var warnings: [String]
  var failures: [Failure]
}
```

Phase 1 Snapshot restore will reach for this shape. Phase 2 Blueprint export will too. C11-13's mailbox dispatcher sweep already wants something like it. Extracting it now costs 30 lines and pays off every composite operation added over the next year.

### 3. The "injected minter" dependency shape

`WorkspaceLayoutExecutorDependencies` cleanly decouples the executor from `TerminalController`'s v2 ref minting. This is the right pattern — the socket handler is a thin adapter, the executor is pure domain logic over injected dependencies, tests inject synthetic minters. **Formalize this** as the default shape for everything-else-that-the-socket-wraps. Today, most v2 handlers reach into `self` / `TabManager.shared` / singletons directly, which makes them untestable without the full AppKit stack. If the rest of the v2 layer migrates to the `Dependencies` pattern that `workspace.apply` just established, the acceptance-fixture harness (real TabManager, synthetic minters) becomes reusable for every handler. Big leverage.

### 4. Anti-pattern to catch early: `ApplyResult` as a catch-all

Nine `ApplyFailure.code` values already, more are likely (`cwd_rejected_by_shell`, `command_queue_overflow`, `remote_workspace_guard_tripped`, …). Without a taxonomy, the code list becomes a stringly-typed junk drawer. **Fix before it sprawls:** group failures by phase (`.validation`, `.creation`, `.metadata`, `.layout`, `.finalize`) and make `ApplyFailure.code` a nested enum per phase. The JSON wire format can stay flat strings; the Swift type gains exhaustiveness checks. This is the kind of shape where doing it when there are 9 codes is a 20-minute chore; doing it when there are 40 is a week.

### 5. Anti-pattern to catch early: the `firstLeafSurfaceId` heuristic

`materializeSplit` picks the split's seed-panel kind by walking `split.second`'s first leaf (`WorkspaceLayoutExecutor.swift:554-555, 833-837`). This works for every fixture but subtly **privileges the `second` subtree's left spine** — if `split.second` is itself a `split(browser-pane, terminal-pane)`, the inner left is browser and the walker commits to `newBrowserSplit`, but if the plan has nested splits where the left spine diverges, the seed kind is increasingly disconnected from the subtree it's placed into. Today it works because the walker then replaces the seed if kind mismatches at the pane leaf. But that "replace + close" round-trip is the flash risk called out in plan §9.1, and it will fire more as plans get deeper. Either: (a) always seed terminal and replace on mismatch (simpler, uniform flash), or (b) walk to the actual leaf the seed will inherit in `materializePane` — no guessing. Recommend (b). See Concrete Suggestion #6.

---

## How This Could Evolve

### Six-month "evolved well" view

- `WorkspaceLayoutExecutor.apply` is the only code path that creates workspaces. Welcome-quad, default-grid, Session restore, Blueprints — all compile to `WorkspaceApplyPlan` and hand off.
- `applyToExistingWorkspace(_:_:_:)` shipped in Phase 0.1; the two TODOs in `Sources/c11App.swift` are deleted.
- `WorkspaceApplyPlan.version = 2` with structured metadata values (no strings-only constraint); migration transparent via `PersistedMetadataBridge`.
- `c11 workspace snapshot --to plan.json` exports a Blueprint-compatible plan from a live workspace. Round-trip: `apply (plan) → snapshot → apply` is idempotent. This is the bare-minimum Phase 1 artifact and it's already achievable with ~50 LOC of reverse-walker once you have `treeSnapshot()` + the stores.
- `skills/c11/SKILL.md` documents "author a plan → apply" as the idiom; agents stop sequencing `c11 split`/`c11 surface open` calls imperatively.
- C11-13's mailbox bootstrap piggy-backs on `paneMetadata` in plans; "start a mailbox from a Blueprint" is free once C11-13 ships its dispatcher.

### Six-month "evolved badly" view

- `WorkspaceApplyPlan` stays v1, strings-only, because nobody wanted to do the joint schema migration. Every consumer invents string-encoding dialects (`"true"`, `"1"`, `7, 8, 9` in comma lists). The round-trip stops being clean.
- Welcome-quad and default-grid never migrate. Two code paths for workspace construction persist indefinitely. Every new layout feature has to implement it in both.
- `ApplyFailure.code` grows to 25 stringly-typed values. Callers start matching on substrings of `.message`.
- Phase 1 Snapshot ships a parallel `SessionWorkspaceLayoutSnapshot → WorkspaceApplyPlan` translator that slowly drifts from the Codable shape the executor accepts. The invariant "Snapshot capture = structural copy" from plan §1 silently breaks.
- The executor grows `async` in Phase 1 but no frontend actually awaits; readiness-gated commands stack up in the command-enqueue queue and fire in the wrong order on cold starts. This one bites quietly — no test fails, it just produces the occasional "command ran before surface was ready" bug that's hard to reproduce.

The difference between the two paths is maybe 3–5 carefully-chosen follow-ups over the next month.

---

## Mutations and Wild Ideas

### M1 — Plan as diff / plan composition

`WorkspaceApplyPlan` today is "here's a workspace." What if it were **additive**? `applyDiff(_ plan: WorkspaceApplyPlan, onto: Workspace)` — the plan declares surfaces and splits, the executor reconciles against what's already there. This is what the welcome-quad/default-grid migration actually needs (apply-to-existing). It's also what "open a mailbox pane into my current workspace" becomes. And it's what Session restore needs for the gnarly "restore into a window the operator has been fiddling with" case. Not required for Phase 0; recognize it's the underlying operation.

### M2 — Reversible apply / transactional workspaces

Every `apply()` produces a matching `unapply()` trace — the list of creations that would undo the operation. Store it on the workspace. Now: `c11 workspace undo` rolls back the last `apply` (including the welcome-quad spawn). `c11 workspace try --file plan.json` applies speculatively with a 10-second revert timer unless confirmed. This is the tmux "session" model played forward for the operator:agent pair: try a layout, if it's wrong, undo it. The `ApplyFailure` telemetry already knows what succeeded; inverting those records is mechanical.

### M3 — Plan as agent coordination protocol

When agent A finishes a bootstrap, what if it emits a `WorkspaceApplyPlan` representing "the environment I want my downstream agents to inherit"? Pipe it into a named-pipe / mailbox message / whatever. Agent B reads it and applies. Now workspaces compose between agents. Today agents coordinate through shell commands; plans are a higher-bandwidth channel. Combined with C11-13's mailbox primitive, this is how you'd build "spawn 10 parallel reviewers with identical layouts" from one declarative plan — a core c11 use case.

### M4 — Plan verification mode

`c11 workspace verify --file plan.json` — dry-run without mutating anything. Run validate, trace what would happen, print the `ApplyResult` as if we had applied. Invaluable for CI fixtures, Blueprint authors, and debugging. Because `validate(plan:)` is already pure and `nonisolated`, this is maybe 40 LOC of "trace mode" on top.

### M5 — Plans as golden tests

The acceptance fixtures (`c11Tests/Fixtures/workspace-apply-plans/*.json`) are already a golden-test corpus. Formalize: any future layout bug lands a fixture first, then the fix. The tree-shape-comparison harness makes this trivial. Within a year this corpus becomes the authoritative answer to "what layouts does c11 support?"

### M6 — Plan → Markdown reverse mapping (Blueprint generation)

Once Blueprints (Phase 2) ship as Markdown, the executor becomes half of the picture. The other half is **emitting** a Blueprint from a live workspace. Combined with M4 verification and M5 goldens, this turns every workspace into a shareable artifact. Operator says "this layout is good, save it" → c11 writes a `.blueprint.md` → another operator (or an agent) can recreate the exact environment. This is the Dockerfile-for-workspaces move.

### M7 — The executor as an optimization target

Today `apply()` runs sequentially, main-actor. Per-step timings go up with depth (5-level nested splits ~N split operations). But creation primitives are independent across subtrees once the tree shape is locked. Future: parallelize surface creation (not bonsplit splits — bonsplit is sequential) across subtrees. Per-step timings stay sub-budget as plans get ambitious (30-pane agent swarms). Don't do this now — flag as a perf lever once a concrete case hits the budget.

### M8 — "Plan-as-selector" for operations

Extend `WorkspaceApplyPlan`-like addressing to queries and mutations: `c11 surface matching-plan <selector>` — select surfaces by metadata fragments, plan-local structural positions, etc. This turns the plan structure into a query language over workspaces. Probably too clever, but mark it as a direction: plans today are write-only; making them readable-as-selectors unlocks a lot.

---

## Leverage Points (small change → disproportionate value)

### L1 — Get the skill updated (highest leverage, lowest cost)

Nothing in `skills/c11/SKILL.md` knows `workspace.apply` exists. Adding a 20-line section — "to create a workspace, author a plan" + the fixture directory as reference — will change how every future agent interacts with c11. The cost is reading the skill once and editing it. The payoff compounds across every agent session from then on. **This is the single highest-leverage action post-merge.** Per the repo CLAUDE.md: "every change to the CLI … is incomplete until the skill is updated to match." The CLI subcommand `c11 workspace apply` shipped; the skill is the missing half.

### L2 — Extract `StepLog<Failure>`

Naming and extracting the `[StepTiming] + [Failure] + [String]` triple (see Emerging Patterns #2) takes an afternoon and becomes the idiom for every composite operation going forward. Snapshot restore will use it. Export will use it. Any future reconciler will use it. Costs ~30 LOC, saves much more over a year.

### L3 — `applyToExistingWorkspace(_:_:_:)`

Unblocks welcome-quad + default-grid migration. Once both are `WorkspaceApplyPlan` consumers, workspace construction has one code path instead of three. The acceptance fixture suite then becomes the golden test for welcome-quad behavior — today that's drift-prone. Estimated size: ~80 LOC on the executor side + matching migrations at `Sources/c11App.swift:3997` and `:4087`. Risk is real (startup-sequencing changes) but gated behind CI.

### L4 — Publish `WorkspaceApplyPlan` as a user-facing schema

Once the JSON shape is documented (even just "here's what the fields mean" in a markdown doc), Blueprints become trivial to author by hand. Right now an operator who wants a custom workspace has to read the Swift types. One-page doc + `deep-nested-splits.json` as canonical example = unlocks operator-authored Blueprints months before Phase 2 formally ships.

### L5 — Enforce plan-version-aware loading at the CLI layer

`CLI/c11.swift` `runWorkspaceApply` passes the JSON through unchecked; the executor's `validate()` catches unsupported versions. Fine today. But once there are v2 plans in the field, shipping a stale c11 that can only handle v1 should produce a loud error, not a silent "version=2 unsupported" in `ApplyResult.warnings`. Small now; would bite later.

---

## The Flywheel

Four self-reinforcing loops worth spinning deliberately:

### F1 — Fixture corpus → confidence → bolder evolution

Every layout bug fix adds a fixture. Every fixture's structural + metadata assertions tighten the executor's contract. As the corpus grows, the confidence to refactor grows with it. Six months in, "rewrite the walker" is safe because 30 fixtures will catch regressions. **Spin this by:** landing fixtures for every new layout idiom, even if the current walker already handles it. Cheap insurance.

### F2 — Skill → agent competence → plan-native authoring → skill refinement

When the skill documents plans, agents author plans. When agents author plans, weird corners of the schema surface. Those become skill examples or fixture additions. Better skill → more capable agents → richer plan usage → sharpens the skill. **Spin this by:** the first-drafted skill section, and actively inviting agents to author plans in real tasks.

### F3 — Structured failures → operator trust → more ambitious plans

Every `ApplyFailure.code` that operators see, name, and trust means they'll push harder on the primitive. Silent failures degrade trust in minutes; typed failures build trust over months. **Spin this by:** surfacing `ApplyFailure` records in the CLI output (the R4 `workspace apply` does this — good) and in the sidebar debug UI when applicable.

### F4 — Plan-as-IR → frontend variety → backend pressure → executor hardening

Each new frontend (Blueprint, Snapshot, C11-13 bootstrap, operator YAML) exercises a different corner of the executor. Corner cases fixed; executor hardens; frontends cross-check each other. **Spin this by:** actively porting frontends to the executor rather than having them compose against bonsplit directly.

---

## Concrete Suggestions

### High Value (do now / soon)

**#1 — Update `skills/c11/SKILL.md` with the workspace.apply story.** ✅ Confirmed — the skill is c11's contract with agents; this is the single most leveraged post-merge action per the repo CLAUDE.md's "the skill is the agent's steering wheel" principle. Add a section explaining plan structure, the fixture directory as reference, and the `c11 workspace apply --file` invocation. Cost: 30 minutes. Value: every agent session.

**#2 — Ship `applyToExistingWorkspace(_:_:_:)` and migrate welcome-quad + default-grid.** ❓ Needs exploration — the TODOs at `Sources/c11App.swift:3997` and `:4087` call this out. The executor design explicitly anticipates it (plan §5). Risk is real (startup-sequencing), so do it under CI with the acceptance-fixture suite extended to cover welcome-quad-as-plan vs. welcome-quad-as-function-call behavioral equivalence. Once this lands, the codebase has exactly one workspace-construction code path.

**#3 — Fix the seed-kind guess in `materializeSplit`.** ✅ Confirmed — at `Sources/WorkspaceLayoutExecutor.swift:554-555`, `firstLeafSurfaceId(splitSpec.second)` returns the **first** leaf of the **left spine of `split.second`**, then uses that leaf's kind to pick the split primitive (`newTerminalSplit` / `newBrowserSplit` / `newMarkdownSplit`). If `split.second` is itself a split, the seed-kind decision is based on a leaf that may not be the actual panel the new pane ends up hosting. In the shipped fixtures this happens to work because the corresponding leaf on the left-spine *is* the one that gets placed in the new pane (the recursive `materialize` on `split.second` anchors on the split's return panel and descends into `split.second`'s first subtree). But the dependency is subtle. **Fix:** either (a) pick the seed kind from the leftmost leaf of `split.second` traced all the way down (which is what the walker currently assumes); make that intent explicit with a method named `leftmostLeafSurfaceId` and a doc comment; or (b) uniformly seed terminals and always replace on mismatch — simpler, accepts the flash. I recommend (a) with a renamed helper and a clarifying comment explaining why the left-spine leaf is the seed kind.

**#4 — Extract `StepLog<Failure>` as a reusable type.** ✅ Confirmed — the pattern already exists in `ApplyResult` (timings + warnings + failures). Pull it out to its own type so Phase 1 Snapshot restore, future Blueprint export, and C11-13's dispatcher sweep all consume the same shape. ~30 LOC; big compounding win.

**#5 — Document the `WorkspaceApplyPlan` JSON schema.** ✅ Confirmed — one-page reference doc at `docs/workspace-apply-plan-schema.md` describing the JSON shape, pointing at `c11Tests/Fixtures/workspace-apply-plans/` as canonical examples. Unblocks operator-authored plans before Phase 2 Blueprints formalize. Cost: 30 minutes. Value: unblocks a whole authoring surface.

**#6 — Make `firstLeafSurfaceId` recurse on `split.first.first.first…` explicitly rather than `split.first`.** ✅ Confirmed — current implementation at `Sources/WorkspaceLayoutExecutor.swift:833-837` is correct today because `.split(let split)` recurses into `split.first` (which is itself recursive). But the name suggests "first leaf" ambiguously. Rename to `leftmostSurfaceId` for clarity and add a one-line doc. Micro-refactor; prevents a future misreading from corrupting the walker.

**#7 — Verify the split-kind decision logic one more time against the deep-nested-splits fixture trace.** ✅ Confirmed — the deep-nested-splits fixture is the canary. Its left-spine descent should produce `terminal, terminal, terminal, terminal, terminal` seed kinds (all fixture surfaces are terminal), which is fine. Adding a mixed-kind deep-nested fixture (terminal at root, markdown three levels down on the left spine, browser at depth 5) would exercise the walker against a genuine worst case. This is a test-only addition. Worth doing before Phase 1.

### Strategic (sets up future advantages)

**#8 — Formalize the `Dependencies`-shaped socket handler pattern.** ⬇️ Lower priority than initially thought — while the pattern is great, retrofitting every v2 handler is out of Phase 0 scope and risky. Instead, make it the **default for every new v2 handler** going forward, starting with anything Phase 1/2 ships. Add a one-line note to the TerminalController comment header explaining the pattern, and let existing handlers migrate opportunistically.

**#9 — Make `WorkspaceApplyPlan.version` a first-class CLI-surfaced field.** ✅ Confirmed — the R6 fix handles the executor side. On the authoring side, document "plans are versioned; emit `"version": 1` explicitly — the executor will start rejecting unversioned plans in v1.1+." Small doc addition; prevents a class of "I thought this was still supported" bugs.

**#10 — Build `c11 workspace verify --file plan.json` (M4).** ❓ Needs exploration — pure validation with no side effects. Because `validate(plan:)` is already `nonisolated`, the CLI surface is ~20 LOC. Gives agents and operators a safe "check before you apply" mode. Ships any time; doesn't block Phase 1. Consider for Phase 0.1.

**#11 — Start an executor evolution log.** ✅ Confirmed — `Sources/WorkspaceLayoutExecutor.swift` is going to be a load-bearing file for years. A short `DECISIONS.md` section or inline-doc "Decisions" block capturing "why walker is top-down, why sync, why Dependencies injection, why soft-limit timeouts" will save every future agent context-reconstruction time. Small now; compounds.

**#12 — Plan as a coordination primitive between agents (M3).** ❓ Needs exploration — tied to C11-13's mailbox delivery. An agent could send another agent a plan via mailbox stdin delivery; the receiver invokes `c11 workspace apply --file -`. That's arguably already possible today (mailbox can carry any text). Worth prototyping once C11-13 lands. Do not block CMUX-37 on it.

### Experimental (worth exploring, uncertain payoff)

**#13 — `apply()` returns a ReversalTrace; implement `c11 workspace undo` (M2).** ❓ Needs exploration — exciting but possibly scope-creep. The telemetry for reversal already exists in `ApplyResult.surfaceRefs`/`paneRefs`. What's missing is the "undo recipe" structure. Prototype in Phase 1 or later; probably worth it.

**#14 — `c11 workspace snapshot --to plan.json` — reverse mapping live → plan.** ❓ Needs exploration — the Phase 1 Snapshot work will produce something shaped like this. The interesting move is to make the output **the same schema as the input** (not a separate SnapshotFormat). Round-trip `apply (plan) → snapshot → apply` should be idempotent. Named as a concrete Phase 1 success criterion, this is the "workspace-as-Dockerfile" win.

**#15 — Parallelize surface creation within independent subtrees (M7).** ⬇️ Lower priority — don't touch until a concrete case exceeds the per-step timeout. The typing-latency hot-path rules in CLAUDE.md make "parallelize on main actor" a no-go; this would need careful structured-concurrency design. Park until there's an actual perf problem.

**#16 — Turn `WorkspaceApplyPlan` into a query language over workspaces (M8).** ⬇️ Lower priority — intellectually interesting but probably not worth the complexity. Reserve as a possibility for a future "advanced operator workflow" ticket. Skip for now.

---

## Cycle-2 Verification Pass on the Cycle-1 Blockers

Quick cross-check that the rework actually landed what it claims, since the evolutionary frame only works if the foundation is sound:

- **B1 walker (top-down):** ✅ `WorkspaceLayoutExecutor.materializeSplit` (`Sources/WorkspaceLayoutExecutor.swift:543-603`) now splits the **anchor** panel — the panel carried forward by the enclosing pane context — and descends into both subtrees with their own (pane, anchor) pair. `split.first` stays in the current pane with the inbound anchor; `split.second` inhabits the newly-minted pane. This is top-down, matches `Workspace.restoreSessionLayoutNode` in shape, and composes correctly against bonsplit's leaf-only `splitPane` — each `newXSplit` operates on a single leaf panel, not a subtree.
- **B2 harness (structural assertions):** ✅ `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:compareStructure` (`:202-253`) and `comparePane` (`:255-297`) walk plan and live trees in lockstep, asserting orientation, dividerPosition (within `dividerTolerance: 0.001`), pane tab ordering, and `selectedTabId`. `assertMetadataRoundTrip` (`:343-446`) runs on every fixture, not just `single-large-with-metadata`. The harness is genuinely structural now.
- **I1 cwd plumbing:** ✅ `Workspace.newTerminalSplit` now accepts `workingDirectory: String? = nil` (`Sources/Workspace.swift:7246-7256`). The executor plumbs it for terminal splits, and emits `working_directory_not_applied` for browser/markdown/seed-terminal reuse cases. The fixture-level harness (`assertWorkingDirectoriesApplied`) ensures either the cwd landed or a typed failure was emitted — silent drop no longer possible.
- **I2 CLI subcommand:** ✅ `CLI/c11.swift:1713` handles `c11 workspace apply` under the `workspace` subcommand dispatcher; the alias `c11 workspace-apply` is preserved. Docs alignment: plan §2 says `c11 workspace apply`, docs say the same — both match.
- **I3 validate off-main:** ✅ `Sources/TerminalController.swift:4385` calls `WorkspaceLayoutExecutor.validate(plan:)` **before** `v2MainSync`. The `validate` function is `nonisolated static` (`Sources/WorkspaceLayoutExecutor.swift:263`), so it's provably off-main. The preflight path encodes a failing `ApplyResult` and returns without touching `TabManager` or AppKit.
- **I4a perStepTimeoutMs:** ✅ Enforced at `Sources/WorkspaceLayoutExecutor.swift:226-237` — soft-limit, appends `per_step_timeout_exceeded` failure, never aborts. Total step exempt (correct — it's the synthesis, not a measured step).
- **I4b version validation:** ✅ `Sources/WorkspaceLayoutExecutor.swift:267-274` — unsupported versions short-circuit with `unsupported_version` before any workspace is created.
- **I4c divider mismatch:** ✅ `Sources/WorkspaceLayoutExecutor.swift:851-896` — `applyDividerPositions` returns `ApplyFailure` records for `(plan split, live pane)` and `(plan pane, live split)` mismatches instead of silently no-op'ing.
- **I4d duplicate refs:** ✅ `validateLayout` at `:302-365` maintains a `referencedIds: inout Set<String>` across the walk. Duplicates both within a pane and across panes emit `duplicate_surface_reference` at validation time — short-circuits before workspace creation.
- **I5 plan sync:** ✅ Verified against plan `:58` — shows the sync signature now.

No new regressions observed. Nothing on the typing-latency hot paths (`TerminalWindowPortal.hitTest`, `TabItemView`, `GhosttyTerminalView.forceRefresh`). No terminal-opinion creep. No tests run locally (per repo policy; rework agent only ran `xcodebuild -scheme c11-unit build`).

**One minor note that isn't a cycle-2 blocker but is worth capturing:** the `applyDividerPositions` walker runs *after* `materialize`, not interleaved with it. For trees where the walker had to fall through a `split_failed` best-effort path (`Sources/WorkspaceLayoutExecutor.swift:584-591`), the live tree will not match the plan tree shape, and the divider walker will emit `divider_apply_failed` for every mismatched slot. This is arguably correct — cascading failures *should* cascade — but in the rare case where `split_failed` happens (bonsplit rejects a split), the operator gets N+ failure records for a single root cause. Consider either (a) short-circuiting the divider pass once a `split_failed` has been recorded in the current walk, or (b) tagging the follow-on `divider_apply_failed` records with a `causedBy: "split_failed"` field. Not a blocker; a polish item for Phase 1.

---

## Final Framing

Cycle 1's consensus was right — the walker was broken and the harness couldn't see it. Cycle 2's rework fixes both cleanly and closes the silent-failure perimeter. What I want to communicate in this review is: **the interesting question is no longer "did Phase 0 land?" — it's "do we name and harvest what just shipped?"** The workspace compiler, the structured operation telemetry pattern, the skill update, the migration of welcome-quad — these are the moves that turn a single primitive into a flywheel. Phase 0 built the foundation; the next month's decisions determine how much of c11 gets reshaped around it.

**Recommended cycle-2 verdict:** PASS. Ship it, then start harvesting.

---

*Most exciting opportunities in priority order:*
1. **Update the c11 skill** (highest leverage, tiny cost) — plan authoring becomes an agent primitive.
2. **Migrate welcome-quad + default-grid** to the executor — one workspace-construction code path instead of three.
3. **Extract `StepLog<Failure>`** — names a pattern that will repeat and saves code across Phase 1, Phase 2, C11-13.
4. **Document the plan JSON schema** — unlocks operator-authored Blueprints before Phase 2 formally ships.
5. **Prototype `c11 workspace snapshot`** — enables the "workspace-as-Dockerfile" vision with ~50 LOC on top of Phase 1 Snapshot.
