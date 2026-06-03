## Evolutionary Code Review
- **Date:** 2026-04-24T00:00:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** e4f60b987d5b0477cd4b172878152450a9965a84
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory

---

## What's Really Being Built

On the surface this is "the Phase 0 primitive for Blueprints + Snapshots." Look at the shape and something bigger is lurking: **c11 is acquiring a declarative IR for workspace state.** `WorkspaceApplyPlan` is the AST; `WorkspaceLayoutExecutor` is the interpreter; the socket handler is a REPL. Every later phase — Snapshots (emit), Blueprints (parse from markdown), picker (browse a library of), `--all` (fan out across) — is a different frontend over the same IR.

The deeper capability being unlocked isn't "save and restore." It's **workspace-as-value**. Once a workspace shape is a plain Codable struct that the app can execute in one transaction, it becomes:

- **Shareable** — paste a JSON plan into Zulip, an agent downloads it and spawns the layout.
- **Diffable** — `workspace.apply` becomes `workspace.reconcile`; the executor computes what to add/remove.
- **Mutatable off-app** — transforms over plans (rename surfaces, swap models, substitute paths) become pure functions with no AppKit dependency.
- **Version-controllable** — `.cmux/blueprints/*.md` is just the markdown skin; the underlying value is already in repo-compatible JSON.
- **Agent-authored** — a clear agent can hand the operator a full layout without a single CLI round-trip.

The subtler thing: the executor is **the first place in c11 where a declarative creation path exists**. Everything else is imperative (`c11 split`, `c11 new-surface`, etc.). This primitive, if its edges are kept clean, is where the center of gravity shifts from "command sequence" to "desired state." That's a bigger deal than the ticket framing suggests.

Name for the pattern that nobody's named yet: **Plan/Executor/Reconciler**. c11 is one reconciler short of being a small, focused Kubernetes for operator workspaces. Not a joke — the shape is there.

## Emerging Patterns

Four patterns have just been born in this branch. Three are good; one is worth catching now.

**1. Dependencies injection for main-actor primitives (good, formalize it).**
`WorkspaceLayoutExecutorDependencies` (`Sources/WorkspaceLayoutExecutor.swift:12-30`) is the first `@MainActor struct` in the codebase that explicitly brokers the boundary between the executor and (a) the socket ref layer, (b) the tab manager, (c) the test harness. Every future "app-side primitive that needs to be driven from socket + tests" should use this shape. It's a small, load-bearing pattern. Worth turning into a convention before the next similar primitive shows up and invents its own.

**2. `mailbox.*`-style reserved-prefix metadata as "namespace convention for cross-ticket coordination" (good, but name it).**
The alignment doc is the contract; the executor's strings-only guard at `Sources/WorkspaceLayoutExecutor.swift:631-642` is the enforcement point. This is actually a *pattern* — a ticket can reserve a metadata prefix, document its value shape, and the executor becomes the validator. Future phases will want this for `claude.session_id`, `codex.session_id`, `sidebar.status`, `snapshot.source`, etc. Worth extracting a small registry: `MetadataNamespaceRegistry` that tickets declare into, and the executor iterates on write. Today it's a single if/else; tomorrow there are six.

**3. `WalkState`-threaded DFS with per-leaf result stitching (good, will want to generalize).**
`WorkspaceLayoutExecutor.WalkState` (`Sources/WorkspaceLayoutExecutor.swift:315-698`) is a clean pattern for traversing a Codable tree while mutating live state and accumulating diagnostics. Snapshots (Phase 1) will want the inverse — walk the live bonsplit tree and emit a plan. Blueprints (Phase 2) will want the parallel form — walk a markdown AST and emit a plan. If the walk shape is shared, a lot of Phase 1/2 code collapses into a few visitor protocols. Don't abstract prematurely, but notice that all three walks share skeleton: anchor + dispatch + accumulate.

**4. Partial-failure with stable codes (good, but beware the silent failure mode).**
`ApplyFailure.code` is a keyword namespace (`validation_failed`, `surface_create_failed`, `mailbox_non_string_value`, ...). This is exactly what a Phase 1 restore needs to branch on. One anti-pattern to catch early: *code proliferation without a schema*. Today there are eight codes. In two phases there will be twenty. Before Phase 1, put the codes in a single enum (`enum ApplyFailureCode: String`) with a stable doc comment and a `code` computed property — not a free-form string. Stringly-typed codes are easy to mistype in restore logic and hard to grep when the set grows.

**Anti-pattern watch: the "creation-centric executor" assumption.**
The comment at `Sources/WorkspaceLayoutExecutor.swift:37-39` mentions Phase 1 adding `applyToExistingWorkspace`. The plan section 5 calls this out. But the *shape* of `apply(_:options:dependencies:)` closes over `dependencies.tabManager.addWorkspace(...)` at step 2 — "create workspace" is a hardwired step. If Phase 1 naively adds `applyToExistingWorkspace` as a sibling function, the metadata + layout walks diverge into two copies. Catch this now: **factor steps 3-8 into a `@MainActor` method that takes a `Workspace` and `seedPanel`**; `apply` becomes `addWorkspace + seedPanel + applyToExistingWorkspace`. This is a trivial refactor today and saves a painful one in three weeks.

## How This Could Evolve

**From one-shot applier to reconciler.** The executor today creates; it does not diff. `ApplyResult` carries enough info (`surfaceRefs`, `paneRefs`) that a hash-and-compare pass becomes natural. `workspace.apply` takes a plan and an existing workspace ref; the executor computes {add, remove, update} and executes the minimum set. This is what Phase 1 restore will *want* to be — "restore the live workspace to this state" — but the naive Phase 1 path will probably close-then-reopen. A reconciler is a few hundred lines more and unlocks hot-reload-style blueprint editing.

**From plan to plan-stream.** The socket response is currently one JSON blob with timings. For a 5-workspace `--all` restore, the operator wants progress. The executor already emits per-step timings; wrap them in an `AsyncStream<StepTiming>` and the socket can stream progress events. The CLI prints a little progress bar. The sidebar can render a "materializing 3/5" indicator. This is ~50 lines of code and turns the executor into a first-class citizen of the agent telemetry surface.

**From creation to mutation.** The locked contract in the alignment doc says `workspace.apply` is a creation primitive and `c11 mailbox configure` is a mutation primitive. Fine for Phase 0. But the *value type* `WorkspaceApplyPlan` is a perfectly good description of the current state — nothing about its shape says "only at creation." In Phase 2+ it's worth revisiting: **one primitive that takes `(plan, mode: .create | .reconcile | .mutate_in_place)` is cleaner than three primitives with overlapping semantics**. The composition path stays the same; the execution strategy changes.

**From JSON plan to source-of-truth.** Today the plan is ephemeral — it's what you apply, then throw away. Phase 1 Snapshots invert this. Phase 2 Blueprints invert it further. The natural next step is `Workspace.currentPlan: WorkspaceApplyPlan { get }` — a computed property that reads the live state and emits the plan that would recreate it. Once that exists, **Snapshot capture is one line**: `fs.write(workspace.currentPlan)`. Export-blueprint becomes the same line with a markdown skin. This is what the plan doc section 2 hints at with "Phase 1 Snapshot capture becomes a one-line assignment."

**From strings-only mailbox to schema evolution.** The `mailbox.*` strings-only guard is a Phase 0 carve-out pending a joint migration. The executor's decode path (`PersistedMetadataBridge.decodeValues`) already round-trips arrays/objects — the guard is the only thing blocking structured values. When C11-13 is ready, delete ~12 lines, add a `schema_version` field on the plan, the migration is done in one commit across both tickets.

**From per-workspace to multi-workspace.** Nothing in `WorkspaceApplyPlan` stops it from being a `WorkspaceSetApplyPlan` (array of plans). `--all` restore + Phase 3 comes almost for free if the executor is stateless and the dependencies struct is cheap to reuse. The current shape is compatible; don't regress it by sneaking in cross-workspace state into `WalkState`.

## Mutations and Wild Ideas

**1. Blueprint as code, not just markdown.** The plan doc hints at markdown + YAML frontmatter. Fine. But: what if blueprints can be `*.swift` files that produce a `WorkspaceApplyPlan` value? A shipped Swift playground runner evaluates it in a sandbox and returns the plan. Now operators can parameterize: `makePlan(repo: "auth", agent: "cc")`. Markdown is the default skin; code is the escape hatch. The executor doesn't care — it takes a plan. Wild, probably gold for power users. (Risk: sandboxing Swift execution is hard. A safer variant: blueprints in a restricted DSL like Cue or Starlark. Even safer: just `*.json.template` + env substitution.)

**2. Blueprint inheritance / composition.** Blueprints are values; values compose. A `base-debug.md` blueprint + a `cc-overlay.md` that overrides one surface's command. The executor takes a stack of plans and layers them. `c11 workspace new --blueprint base-debug,cc-overlay` — last write wins, with an explicit merge strategy in frontmatter. Lattice's "inheritance chain" concept fits perfectly here. This is the kind of primitive that the operator-agent pair actually uses once it exists.

**3. Plan as coordination artifact.** A clear agent running a long task can emit a `WorkspaceApplyPlan` JSON to the sidebar every N minutes — "here's the workspace shape you'd get if you restored my state right now." The operator, at any point, can `c11 apply` that plan into a new workspace and resume from exactly the agent's context. This is one step removed from time-travel debugging. The primitive already supports it; the missing piece is the "emit current plan" computed property above.

**4. Plan diffing as a UI primitive.** Two plans, diff them, render the diff as a visual tree. "Welcome quad vs default grid: 2 surfaces different, 3 titles different, 0 metadata different." This is the sidebar's "what changed when I applied this" view. Structural diff over `WorkspaceApplyPlan` is a 60-line recursive function. The resulting UI surface is a whole new class of agent-operator communication.

**5. The inverse executor: plan-from-operator-action.** Phase 2 talks about `c11 workspace export-blueprint` — capture the current workspace as a blueprint. Take this one step further: every operator action (split, close, rename) emits a plan *delta* to a log. The log is a replay of the session. The workspace becomes its own event-sourced entity. This is overkill for Phase 0 but the shape of today's code allows it — the executor is a pure function from plan to side effects, and every action's effect is expressible as a plan delta.

**6. Remote plans.** The alignment doc shows `$C11_STATE/workspaces/<ws>/mailboxes/<surface-name>/`. Imagine a plan that describes a workspace on a *different* c11 instance. The socket accepts it, routes it via `ssh` to the target, the remote executor materializes it. "Open the auth-debug workspace on my laptop from this machine." The primitive is already remote-capable — nothing in `WorkspaceApplyPlan` references this machine.

**7. Blueprint library as social artifact.** Once blueprints are shareable JSON, a `cmux-blueprints` repo becomes obvious. Community-curated debug layouts, agent-coordination patterns, operator starter kits. The picker (Phase 2) pulls from local + `~/.config` + optionally a configured library URL. This is where the operator-agent pair community ossifies into patterns others can adopt. Strategic, long-tail, worth thinking about now even if it ships in Phase 6.

## Leverage Points

**1. The plan-local ID → live ref map (`planSurfaceIdToPanelId`).** This is the single most load-bearing piece of mutable state in the walk. Today it's a `[String: UUID]` buried inside `WalkState`. If it graduates to a `PlanResolution` struct with `surfaces: [PlanSurfaceId: LiveSurfaceRef]` + `panes: ...` + `workspace: ...`, it becomes the unit Phase 1 restore and Phase 2 reconciler both need, plus the natural return value of a future "plan a → plan b diff" function. Tiny change; enormous downstream leverage.

**2. The `Clock` helper.** Timing is everywhere in this code. The helper at `Sources/WorkspaceLayoutExecutor.swift:751-757` is minimal but perfect. If one more function needs timing — literally any — promote it out of `fileprivate` and put it next to the other telemetry helpers. Future agent-reporting code will want this shape.

**3. `applyDividerPositions` as a second pass.** The current shape walks the plan tree against the live bonsplit tree to apply dividers (`Sources/WorkspaceLayoutExecutor.swift:716-744`). It's a small function but it's the first "walk two trees in lockstep" code in the file. This exact shape is what Phase 1 reconcile needs (plan tree vs live tree, emit deltas). If you generalize it to `zipPlanWithLiveTree(plan:live:visitor:)` now, reconcile is a matter of writing one visitor.

**4. The socket handler is thinner than it looks.** `v2WorkspaceApply` at `Sources/TerminalController.swift:4346-4417` is ~70 lines; most is plumbing (decode, wrap in v2MainSync, encode back). If `v2MainSync` could be generic over the result type and the encode/decode step extracted, the handler shrinks to ~15 lines. More importantly, every future executor-backed primitive (Phase 1 `workspace.snapshot`, `workspace.restore`; Phase 2 `workspace.new_from_blueprint`) can use the same skeleton. Extract it once, reuse five times.

**5. The CLI `workspace-apply` subcommand.** Phase 0 ships one subcommand. Phase 1 will ship 3-4 more. If the CLI grows a "plan subcommands" convention — read `--file` or `-`, POST to socket, pretty-print `ApplyResult`-shaped responses — all of them share 80% of the code. Extract `runPlanSubcommand(method:, args:)` from `workspace-apply` now and the next four subcommands are one line each.

**6. The acceptance fixture *is* the contract document.** Five JSON files + one test file define the wire shape more concretely than any doc comment. Phase 2 blueprint authors will read these fixtures first. Make sure they're committed under a clear name and treated as canonical examples — they're load-bearing documentation, not just test fodder. Add a README in the fixtures directory cross-linking to the alignment doc.

## The Flywheel

The flywheel isn't spinning yet, but all four bearings are installed. Here's how to set it spinning.

**Loop 1 (agent ↔ plan):** Agents learn (via the skill) to emit their workspace state as a `WorkspaceApplyPlan`. Operators can restore any agent's context from its last emitted plan. More plans emitted → better restore → operators trust agents more → agents run longer → more plans emitted.

**Loop 2 (blueprint ↔ operator):** Operators build blueprints once, run them often. Each run exposes friction (missing commands, wrong cwd, wrong surface types). Blueprint gets refined. Refined blueprint shared across machines / team members / public repo. More blueprints → easier to start new work → more starts → more blueprints.

**Loop 3 (plan ↔ platform):** Blueprints become the canonical starter for Stage 11 projects. The Entrance Interview (per the global CLAUDE) emits a blueprint. `c11 workspace new` becomes "pick from recency-sorted library." Library grows. Library becomes the on-ramp for new operators.

**Loop 4 (plan ↔ everywhere):** Plans flow through Zulip messages, Lattice tickets, sidebar artifacts. "Here's my workspace shape" becomes a new communication primitive. The operator-agent pair has a shared vocabulary for "this is where I am."

**What sets them spinning:** a crisp early demo where *one plan JSON*, pasted into the socket, produces a working multi-surface workspace with an agent already running. That's the "aha" moment. The acceptance fixture is 80% of the way there — `welcome-quad.json` fully materializes, including launching `claude` in the BR pane. Ship this, operators notice, agents notice, the loops start.

The single highest-leverage move right now: **make the `workspace-apply` CLI the first thing the operator thinks of when they want to create a workspace with a specific shape.** Not when they want to debug the executor. When they want a shape. That happens when (a) Phase 2 blueprints ship, and (b) the CLI output is polished (today's pretty-print is a good start, `Sources/c11App.swift` has the bar). Invest in the demo experience of applying a single good plan, and the flywheel has a starter motor.

## Concrete Suggestions

### High Value — do now

1. **Factor steps 3-8 into `applyToWorkspace(_:seedPanel:...) -> ApplyResult`; have `apply(_:options:dependencies:) -> ApplyResult` call `addWorkspace + applyToWorkspace`.** ✅ Confirmed — `Sources/WorkspaceLayoutExecutor.swift:82-94` is the split point. Phase 1 restore already has the "apply to existing workspace" requirement in the doc comment at `:37-39`; doing the refactor now keeps `apply` and `applyToExistingWorkspace` from diverging. Impact: Phase 1 picks up a ready-made entry point instead of a copy-paste. ~40 lines moved, zero behavior change, one new function signature.

2. **Convert `ApplyFailure.code: String` → `ApplyFailure.code: ApplyFailureCode` (string-backed enum).** ✅ Confirmed — codes are defined as a doc-comment enumeration at `Sources/WorkspaceApplyPlan.swift:239-244`. Today it's a convention; tomorrow it's a bug source. Keep `rawValue: String` so the wire shape is identical, but callers branch on a typed enum. Phase 1 restore will thank you. Add a `@frozen` attribute or a doc note that additions are backwards-compatible additions only.

3. **Add a fixture README cross-linking to the alignment doc.** ❓ Needs exploration — the fixtures at `c11Tests/Fixtures/workspace-apply-plans/*.json` are the clearest wire-format examples in the repo. A short `README.md` pointing at the alignment doc, the plan doc, and a one-sentence summary per fixture makes them doc-as-test. ~15 minutes of work. Only hesitation: the worktree's CLAUDE.md says "NEVER create documentation files unless explicitly requested" — but inside `c11Tests/Fixtures` this is test documentation, which feels in-scope. Flag for operator confirmation rather than ship silently.

4. **Promote `planSurfaceIdToPanelId` to a named `PlanResolution` type, returned as part of `ApplyResult` (or carried as a sidecar).** ✅ Confirmed — today it's only in `WalkState`. Surface it as a first-class concept. Phase 1 reconciler will want exactly this structure. ~30 lines of refactor.

### Strategic — sets up Phases 1-5

5. **Introduce `MetadataNamespaceRegistry` with `mailbox.*` as its first entry.** ✅ Confirmed — today the strings-only guard is a single if/else at `Sources/WorkspaceLayoutExecutor.swift:631-642`. Phase 1 adds `claude.*` session keys. Phase 2 adds `snapshot.*` source keys. Phase 5 adds `codex.*`/`opencode.*`. Without a registry, the executor accumulates branches. With one, tickets register their prefix + validator and the executor iterates. ~80 lines. The shape: `struct MetadataNamespace { prefix: String; validate: (PersistedJSONValue) -> Bool; droppedCode: ApplyFailureCode }`.

6. **Extract `v2MainSync<T>(...) -> Result<T, V2Error>` with decode/encode hooks.** ❓ Needs exploration — `Sources/TerminalController.swift:4346-4417` is the template for every future executor-backed handler. Generalize the "decode JSON → v2MainSync → encode JSON" sandwich. Impact: Phase 1 `workspace.snapshot` and `workspace.restore` handlers each become ~15 lines instead of 70. Risk: generics + existentials on `@MainActor` boundary has footguns; might need a named protocol instead.

7. **Generalize `applyDividerPositions` into `zipPlanWithLiveTree(_:_:visit:)`.** ✅ Confirmed — `Sources/WorkspaceLayoutExecutor.swift:716-744` is the template. The visitor shape opens the door to Phase 1 reconciler (visit split pairs, emit deltas) and Phase 2 diff (visit pairs, emit a patch). ~40 lines of generalization.

8. **Add `Workspace.currentPlan: WorkspaceApplyPlan` computed property.** ❓ Needs exploration — this is the Phase 1 Snapshot capture in disguise. The doc comment at `Sources/WorkspaceApplyPlan.swift:17-19` promises "Phase 1 Snapshot capture is a structural copy"; the natural implementation is this computed property + JSON write. Doing it now lands Snapshot capture effectively for free. Risk: some live state (terminal command history, browser scroll position) doesn't round-trip into a plan — need to decide what's in/out of the plan early, not case-by-case.

### Experimental — worth exploring, uncertain payoff

9. **`c11 workspace diff <plan-a> <plan-b>`.** A recursive structural diff over two `WorkspaceApplyPlan` values, rendered as a tree. Powers "what would change if I applied this?" and "what changed since snapshot?" UX. ~150 lines. Unclear demand; unclear UI surface. But: once it exists, the use cases multiply.

10. **`WorkspaceApplyPlan` composition: `planA + planB` with explicit merge strategy.** Operator wants "welcome-quad but with my cc terminal replaced by a codex one" — today that's two plans hand-edited. With composition, it's `base-welcome.json + cc→codex-overlay.json`. Conceptually clean; the strategy decisions (replace-by-id vs position-based vs tag-based) need real Blueprint usage to shake out. Revisit after Phase 2 ships.

11. **Plan-as-sidebar-artifact: agent emits `current_plan` to sidebar every 5 minutes.** Operator can at any time restore the agent's workspace exactly. Requires the `currentPlan` computed property plus a skill doc update. Speculative but aligned with the "operator-agent pair is the unit" framing. Try after Phase 1 is real and Phase 2 is shaping up — not before.

12. **Streaming `ApplyResult` via socket event channel.** `workspace.apply` returns one blob; `workspace.apply.stream` returns an event stream (`StepTiming` per step + final `ApplyResult`). The executor already emits per-step timings; just tee them. Enables progress bars and "currently materializing pane 3/5" sidebar UI. ~80 lines. Phase 3 `--all` wants this; ship it then, not now.

---

**Validation summary.** The executor's shape is correct for Phase 0 and *almost* correct for Phase 1+. The two concrete moves — (a) factor the workspace-creation step out of `apply` and (b) introduce a typed `ApplyFailureCode` enum — are both reversible, both small, both directly compound into Phase 1 work. If I had to pick one for the operator to act on before Phase 1 kicks off: **do (1) and (2) together as a cleanup commit on this branch.** Everything else can ride with the Phase 1 PR.

The most exciting thing I don't yet see in the code but that the shape invites: **`Workspace.currentPlan` as a computed property**. When that exists, Snapshots are one line, plan-as-coordination-artifact becomes a live capability, and the "workspace-as-value" framing stops being aspirational and starts being how c11 actually thinks. That's the move that turns Phase 0 from "Blueprints preamble" into "c11 has a declarative workspace IR." The code is ten lines of traversal away from it.
