# Evolutionary Synthesis — CMUX-37 Cycle 2

- **Date:** 2026-04-24
- **Sources:** `evolutionary-claude.md`, `evolutionary-codex.md`, `evolutionary-gemini.md`
- **Branch:** `cmux-37/phase-0-workspace-apply-plan` @ `bf802101`
- **Frame:** Read-only synthesis. The three models converge almost completely on what Phase 0 actually built and what the next moves should be. The divergence is in vocabulary and in which wild mutation each reaches for.

---

## Executive Summary — Biggest Opportunities

1. **Name the primitive.** All three reviews independently identified that Phase 0 didn't just ship "workspace persistence" — it shipped a **declarative layout compiler / workspace materialization kernel / DOM-for-a-terminal-multiplexer**. Claude calls it "the workspace compiler," Codex calls it "the workspace materialization kernel," Gemini frames it as "a declarative display protocol for agentic interfaces." Same primitive, three names. Pick one, put it in the skill, and the roadmap reshapes around it.
2. **Update `skills/c11/SKILL.md` now.** Single highest-leverage action. Without it, agents keep composing with `c11 split` / `c11 surface open` one-at-a-time. With it, plans become the unit of agent environment negotiation. Per repo CLAUDE.md, the skill *is* the contract.
3. **Collapse the three workspace-construction code paths into one.** Welcome-quad, default-grid, and the new executor all do the same job today. Ship `applyToExistingWorkspace(_:_:_:)` (the TODOs at `Sources/c11App.swift:3997, :4087` already call this out) and migrate both legacy paths into plan builders. Then there is exactly one way workspaces get built.
4. **Build the capture / snapshot round-trip early.** All three reviews land on this: `apply → capture → apply` as the north-star invariant. Once `WorkspaceApplyPlan.capture(from:)` exists, every live workspace becomes a shareable Blueprint, a CI fixture, a snapshot, and a proof-of-correctness against the executor. The flywheel can't spin without this.
5. **Make "no silent intent loss" a plan invariant.** Codex's sharpest observation: validation checks every layout ref resolves to a surface but never checks the converse (every declared surface is referenced). Kind-specific fields (`workingDirectory` for browser/markdown, `command` for non-terminal, invalid URLs) can still be silently ignored on the creation path. Closing this perimeter is the last Phase 0 correctness move.

---

## 1. Consensus Direction (Evolution Paths All Three Models Named)

1. **Plan-as-IR with many frontends, one backend.** Every model articulated this: `WorkspaceApplyPlan` is the middle IR; frontends are debug JSON (shipped), Snapshot capture (Phase 1), Blueprint markdown (Phase 2), welcome-quad, default-grid, Lattice task plans, operator YAML, C11-13 mailbox bootstrap. Backend is `WorkspaceLayoutExecutor` driving bonsplit + metadata stores + Ghostty. The rule that falls out: no frontend bypasses the executor during workspace construction.
2. **Retire welcome-quad and default-grid into plan builders.** Claude (#L3, #2), Codex (#6), and Gemini (implicit in the virtual-DOM framing) all flag the two TODOs at `Sources/c11App.swift:4000-4005` and `:4089-4093` as the next real proving ground. Consensus: ship `applyToExistingWorkspace`, rewrite both legacy flows as tiny plan builders, collapse three code paths into one.
3. **`ApplyResult` is not just output — it's a structured execution ledger.** Claude names the reusable shape `StepLog<Failure>`; Codex calls it an `ApplyTrace` / `actions: [ApplyAction]`; Gemini frames telemetry as "first-class output." All three want: timings + warnings + failures + (Codex adds) structured action records (`workspace.created`, `surface.reusedSeed`, `split.created`, `metadata.written`, `divider.clamped`). Extract it as a reusable type before Snapshot/Blueprint/C11-13 reinvent it three times.
4. **Typed failures must stay typed — and grow a taxonomy before they sprawl.** Claude, Codex, and Gemini all treat `ApplyFailure.code` as the feature that makes the whole system trustworthy (Gemini calls it the "self-healing agent" flywheel). Claude warns against the code list becoming a stringly-typed junk drawer — group by phase (`.validation`, `.creation`, `.metadata`, `.layout`, `.finalize`) now while there are 9 codes, not when there are 40.
5. **Capture / round-trip is the next invariant.** Claude (#14, M6), Codex (#5), and Gemini (time-traveling snapshots) all converge: `apply → capture → apply` must be idempotent, and `capture` reuses the same schema as `apply` — not a parallel SnapshotFormat that drifts.
6. **Close the no-silent-intent perimeter.** Codex (#1) names it, Claude acknowledges it in the "evolved badly" path, Gemini warns about strings-only metadata becoming a parsing nightmare. Every declared field either gets applied, rejected at validate-time, or emits a typed warning. Nothing silently dropped.
7. **The executor must go async eventually — but deliberately.** Claude warns in the "evolved badly" view against `async` growth without frontends awaiting; Codex (#7) calls out readiness state machines as a Phase 1 prerequisite. Both converge: introduce readiness as an internal state before Snapshot restore makes command-timing correctness load-bearing.

---

## 2. Best Concrete Suggestions (Most Actionable Across All Three)

1. **Update `skills/c11/SKILL.md` with the `workspace.apply` story.** (Claude #1, implied by Codex/Gemini agent-facing framings.) 20-line section, one fixture pointer, one CLI invocation. Cost: 30 minutes. Value: every future agent session. *This is the single highest-ROI action post-merge.*
2. **Ship `applyToExistingWorkspace(_:workspace:seedPanel:options:)` and migrate welcome-quad + default-grid.** (Claude #2/#L3, Codex #6.) The walker is already parameterized on `Workspace` + `AnchorPanel` — this is API extraction, not redesign. Collapses three construction paths into one. Gate under CI with behavioral-equivalence fixtures.
3. **Extract `StepLog<Failure>` / `ApplyTrace` as a reusable type.** (Claude #4/#L2, Codex #3.) Pull the `[StepTiming] + warnings + [ApplyFailure]` triple out of `ApplyResult` into a standalone type. ~30 LOC. Snapshot restore, Blueprint export, and C11-13's dispatcher all consume the same shape.
4. **Enforce plan graph closure: every `SurfaceSpec.id` referenced exactly once.** (Codex #1, consensus with Claude's "no silent drop" framing.) Today `validate(plan:)` checks `referencedIds ⊆ known` but never `known.subtracting(referencedIds)`. Orphan surfaces disappear silently. Add the check, emit a typed warning or failure depending on policy.
5. **Add typed warnings for kind-specific fields ignored on the creation path.** (Codex #1, Claude #I.) `createSurface` silently accepts browser/markdown `workingDirectory` without the warning `splitFromPanel` emits; invalid URLs fall through `URL(string:)` returning nil; command enqueue silently skips non-terminal specs. Match `splitFromPanel`'s policy uniformly.
6. **Document the `WorkspaceApplyPlan` JSON schema.** (Claude #5/#L4.) One-page `docs/workspace-apply-plan-schema.md` with `deep-nested-splits.json` as canonical example. Unblocks operator-authored plans months before Phase 2 Blueprints formally ship.
7. **Rename `firstLeafSurfaceId` to `leftmostLeafSurfaceId` + add doc comment.** (Claude #3/#6.) The walker at `Sources/WorkspaceLayoutExecutor.swift:833-837` is correct today but the name invites misreading. Micro-refactor; prevents a future seed-kind regression.
8. **Add negative acceptance fixtures for policy gaps.** (Codex #4.) Orphan surfaces, invalid URLs, non-terminal `command`, browser/markdown `workingDirectory`. Also fix the mailbox-assertion smell at `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:423-428` (assertion string shape doesn't match executor output and the branch appears unexercised with current fixtures).
9. **Add a mixed-kind deep-nested fixture.** (Claude #7.) Current `deep-nested-splits.json` is all-terminal; a plan with terminal at root, markdown at depth 3 on the left spine, browser at depth 5 actually exercises the seed-kind / replace-on-mismatch path. Test-only; ship before Phase 1.
10. **Introduce stable `SurfaceSpec.name` separate from display title.** (Codex #2.) Per the C11-13 alignment doc, surface names are durable mailbox/Blueprint identities. Conflating them with `title` means mailbox identity changes when a user renames a tab. Add as optional in v1 with fallback `title ?? id`; make required in v2.
11. **Ship `c11 workspace verify --file plan.json` (dry-run).** (Claude #10 / M4, Codex #9.) Because `validate(plan:)` is already `nonisolated`, this is ~20–40 LOC on top. Safe "check before apply" mode. Great for CI, Blueprint authors, operators, and agents. Ships any time.
12. **Short-circuit or tag cascading failures after `split_failed`.** (Claude cycle-2 note.) When bonsplit rejects a split, the downstream divider walker emits `divider_apply_failed` for every mismatched slot. Tag follow-on failures with `causedBy: "split_failed"` so operators see one root cause, not N+ records.
13. **Make `WorkspaceApplyPlan.version` explicit at the CLI layer.** (Claude #9/#L5.) Document "plans are versioned; emit `"version": 1`." Once v2 plans exist, a stale c11 should loudly reject them, not silently add a warning.
14. **Finish migrating metadata to `PersistedJSONValue` before string-dialects proliferate.** (Gemini leverage #3.) The executor already decodes JSON-typed values; finishing the backend migration alongside C11-13 prevents `"true"` / `"1"` / `"stdin,watch"` parsing bugs from multiplying across agents.
15. **Start an executor decisions log.** (Claude #11.) A short inline-doc "Decisions" block in `Sources/WorkspaceLayoutExecutor.swift` capturing: why top-down, why sync, why `Dependencies` injection, why soft-limit timeouts. Compounds for every future agent.

---

## 3. Wildest Mutations (Creative / Ambitious Ideas Worth Exploring)

1. **The Virtual DOM for terminal multiplexers.** (Gemini's core frame, echoed by Claude M1 and Codex "plan diff mode.") Add `WorkspaceLayoutExecutor.reconcile(target:current:)` — diff the incoming plan against the live bonsplit tree, emit the minimal set of split/close/replace/resize operations. Agents continuously push desired state; `c11 split` and `c11 set-metadata` become implementation details of the reconciler. This is the biggest mutation on the table.
2. **Surface upgrading / downgrading as a public primitive.** (Gemini #1.) Extract the internal "Anchor Panel Replacement" logic (used to swap seed terminal → markdown/browser) into a public `c11 surface replace --kind markdown`. An agent starts as a terminal, computes a result, replaces itself with a browser pointing at the output — without disturbing the operator's layout.
3. **Reversible apply / `c11 workspace undo`.** (Claude M2.) Every `apply()` produces a paired `unapply()` trace. Store it on the workspace. `c11 workspace try --file plan.json` applies speculatively with a 10-second auto-revert timer unless confirmed. This is the tmux "session" model played forward for the operator:agent pair.
4. **Plans as inter-agent coordination protocol.** (Claude M3, Codex #10.) When agent A finishes a bootstrap, it emits a `WorkspaceApplyPlan` representing "the environment I want my downstream agents to inherit." Piped through a C11-13 mailbox, agent B applies it. "Spawn 10 parallel reviewers with identical layouts" becomes one declarative plan — a core c11 use case.
5. **Agent-room choreography Blueprints.** (Codex "Agent Choreography Plans," Gemini "Layout-as-Code Generators.") A Blueprint declares not just surfaces but roles: `driver`, `reviewer`, `test runner`, `docs watcher` — plus mailbox subscriptions and inter-surface wiring. c11 stays within its host-and-primitive boundary (no intelligence), just materializes the room.
6. **Topology fuzzer.** (Codex.) Because `LayoutTreeSpec` is small and recursive, generate random valid plans and assert `apply → capture → compare`. Pressure-tests bonsplit integration vastly better than handpicked fixtures.
7. **Workspace provenance / append-only apply log.** (Codex + Gemini "time-traveling snapshots.") Persist each `ApplyTrace` as workspace metadata; build an append-only log of applied plans. Operator can ask "why is this pane here?" and c11 answers from its own ledger. Scrub back and forth through workspace configurations during a debugging session.
8. **Workspace recipes (plan composition).** (Codex.) Plans merge: `base-repo-room` + `debug-overlay` + `review-overlay` compose into one apply graph. Workspaces become reusable recipes rather than static templates.
9. **Graceful degradation instead of hard-fail.** (Gemini #3.) If a Markdown surface's `filePath` doesn't exist, downgrade to a terminal running `tail -f` on an error log, or render a placeholder. An agent's requested layout shouldn't hard-fail on one missing file.
10. **Parallelize surface creation within independent subtrees.** (Claude M7.) bonsplit splits must stay sequential, but surface creation across independent subtrees is parallelizable. Park until a real perf case (30-pane agent swarms) hits a per-step timeout; it would need careful structured-concurrency design to stay off the typing-latency hot paths.
11. **`WorkspaceApplyPlan` as a workspace query language.** (Claude M8.) Extend plan-style addressing to queries: `c11 surface matching-plan <selector>` — select surfaces by metadata fragments and plan-local positions. Probably too clever to ship, but worth marking as a direction: today plans are write-only, reading them is an unexplored dimension.
12. **`StepTiming` exposed to agents as a throttling signal.** (Gemini leverage #2.) Stream executor perf data to agents through the socket. A smart agent throttles its layout mutations when `TabManager` is slow. Self-tuning host + agent pair.

---

## 4. Leverage Points and Flywheel Opportunities

### Leverage points (small change → disproportionate value)

1. **The skill file.** (Claude #L1.) ~20 lines in `skills/c11/SKILL.md` teaches every future agent to author plans instead of sequencing CLI calls. Absolutely highest-leverage move.
2. **`applyToExistingWorkspace` + welcome-quad/default-grid migration.** (Claude #L3, Codex #6.) ~80 LOC extraction collapses three construction paths into one and turns the acceptance suite into the golden test for welcome-quad behavior.
3. **The `validateLayout` preflight.** (Gemini leverage #1.) Small enhancement — return partial validity masks instead of one `ApplyFailure` — makes the whole system graceful-degradation-capable. Plus: close the "no silent intent loss" perimeter here (Codex #1). The validator is the place where intent either survives or is named.
4. **One-page JSON schema doc.** (Claude #L4.) 30 minutes of writing unlocks operator-authored Blueprints before Phase 2 ships. Every fixture is already a canonical example.
5. **`Dependencies`-shaped socket handlers as the default pattern for new v2 handlers.** (Claude Emerging #3, #8.) Don't retrofit everything, but make the `WorkspaceLayoutExecutorDependencies` shape the default for every Phase 1/2 handler. Over a year, the acceptance-fixture harness becomes reusable across every v2 surface.
6. **Strings-only metadata → `PersistedJSONValue` migration.** (Gemini leverage #3.) Finish the backend migration alongside C11-13. The executor already decodes JSON values; finishing the store prevents string-encoding dialects proliferating across every consumer.

### Flywheels (self-reinforcing loops worth spinning deliberately)

1. **Fixture-corpus flywheel.** (Claude F1, Codex "more plans become fixtures.") Every layout bug adds a fixture. Every fixture tightens the executor contract. Six months in, "rewrite the walker" is safe because 30 fixtures catch regressions. *Spin by:* landing fixtures for every new layout idiom, even when the current walker already handles it.
2. **Skill → agent competence → plan-native authoring → skill refinement.** (Claude F2.) Better skill → more capable agents → richer plan usage → schema edges surface → skill sharpens. *Spin by:* landing the first skill section and actively inviting agents to author plans in real tasks.
3. **Structured failures → operator trust → more ambitious plans.** (Claude F3, Gemini "Self-Healing Agent.") Typed `ApplyFailure.code` values build trust over months. Agents read failures and stop re-emitting the same invalid configs. *Spin by:* surfacing failure records in the CLI output (already done in R4) and in the sidebar debug UI when applicable.
4. **Plan-as-IR → frontend variety → backend pressure → executor hardening.** (Claude F4, Codex's three-stage pipeline.) Each new frontend (Blueprint, Snapshot, C11-13 bootstrap, operator YAML) exercises a different corner. Corner cases fixed; executor hardens; frontends cross-check each other. *Spin by:* actively porting frontends to the executor rather than composing against bonsplit directly.
5. **Capture / round-trip flywheel.** (Codex #5, Claude M6/#14.) Once `capture(from:)` exists, every live workspace is a candidate Blueprint, fixture, and correctness witness. Operator says "this layout is good, save it" → c11 emits a `.blueprint.md` → another operator/agent recreates it exactly. This is the Dockerfile-for-workspaces moment.
6. **Self-healing agent flywheel.** (Gemini.) Agent applies plan → reads `ApplyResult` → identifies failures → learns not to emit the invalid config again OR issues targeted recovery commands. Agents get better at negotiating their environments over time, and the executor becomes a teacher.

---

## Final Framing

All three models reached the same strategic stance: **Phase 0's fix isn't the interesting story — the interesting story is that Phase 0 accidentally shipped the primitive the rest of c11 has been improvising without**. Naming it, updating the skill, collapsing welcome-quad/default-grid into it, and building the capture round-trip are the moves that turn one primitive into a flywheel. Miss those moves and Phase 0 becomes "one more format." Hit them and the next six months of c11 reshape around declarative workspace materialization.

*Recommended next four actions, in order:*
1. Update `skills/c11/SKILL.md` with the `workspace.apply` story.
2. Ship `applyToExistingWorkspace` and migrate welcome-quad + default-grid.
3. Extract `StepLog<Failure>` / `ApplyTrace` as a reusable type; close the no-silent-intent perimeter in `validate(plan:)`.
4. Prototype `WorkspaceApplyPlan.capture(from:)` and make `apply → capture → apply` idempotent on all five existing fixtures.
