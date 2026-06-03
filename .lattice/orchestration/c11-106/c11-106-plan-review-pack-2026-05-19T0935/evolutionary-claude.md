# Evolutionary Plan Review — C11-106 follow-up to PR #181

**Plan:** c11-106-plan
**Model:** Claude
**Date:** 2026-05-19T0935
**Reviewer mode:** Evolutionary (where could this go, not just is-it-correct)

---

## Executive Summary

C11-106 reads as a cleanup ticket — "wire the coordinator, add four tests, fix enum names" — and if it ships as written it'll close the gaps the Phase 4 audit found. But that framing undersells what's actually on the table.

PR #181 quietly landed three things the cleanup mindset hides:

1. **A typed source-precedence ladder for metadata**, with `derived` now a first-class tier between `osc` and `heuristic`, gated against external socket writes and excluded from snapshot capture.
2. **A `MetadataDeriver` protocol + `DerivationCoordinator` runtime** that nobody has plugged anything else into yet.
3. **A canonical-keys surface in the sidebar** that is no longer "label : value text" but rich, projector-rendered, theme-aware chips with dim states and palette colors.

C11-106 will be the first follow-up to touch all three. The evolutionary question is not "how do we close the test gaps cleanly" — it's **"do we treat C11-106 as the moment the coordinator becomes load-bearing, and what does that unlock?"**

The biggest opportunity here is to stop thinking of `worktree`/`branch` as the feature, and start thinking of **the derived-metadata seam as the feature**. Once you treat the seam as the product, this ticket evolves from "5–7 cleanup items" into "the launching pad for an entire family of canonical, derived, agent-glanceable signals that nobody has to write code to produce." Host (SSH target / container / kubectl context / AWS profile), running-process classification (claude vs codex vs bash vs vim), workspace health (gh PR queue, CI status, build dirty), nearest-Lattice-ticket — all of these become cheap to ship once the coordinator is wired, the cache is real, and the precedence/snapshot/socket rules are settled.

The follow-up that lands is in many ways more architecturally important than the parent. Treat it that way.

---

## What's Really Being Built

The plan says: "follow-up cleanup — wire DerivationCoordinator, add tests, rename enums, optional polish."

What it's actually building, beneath the surface:

### The Derived-Metadata Subsystem

After PR #181 + C11-106, c11 will have, for the first time, **a runtime that asks the environment "what are you?" and writes the answers into the same metadata store agents write to**. That's a category shift, not a feature.

Before: every canonical key was either (a) declared by an agent via the skill, (b) heuristically guessed from terminal_type, or (c) populated by OSC sequences. All three have human-readable provenance — somebody told c11 the value or somebody guessed it.

After C11-106 (with the coordinator actually wired): c11 has a **structured way to compute facts about a pane from outside the pane's process tree** — independent of what the agent inside that pane is doing, what protocol it speaks, or whether it's an agent at all. A bash session, a vim instance, an `htop` — all get the same derived chips because the derivation is environmental.

That's not a worktree chip. That's a **second source of truth about every pane**. The first source is "what the agent claims" (declare/osc). The second is "what c11 can observe." Reconciling those two is the actual primitive.

### The Coordinator as Cache-Invalidation Substrate

`DerivationCoordinator` is currently described as a "seam for future derivers." That undersells it. What it actually is: **a deterministic, off-main, gen-token-protected, cache-aware execution layer for any environment probe c11 wants to run**. Most of the hard work in this space is not "shell out to git" — it's:

- Coalescing duplicate probes when ten panes all OSC-7 into the same cwd at once.
- Invalidating caches on the right signal (mtime, FSEvents, time interval, explicit kick).
- Dropping stale results when the user navigated away mid-probe.
- Preserving hot-path discipline so no probe ever runs on the main thread.
- Snapshotting cleanly (exclude derived; restore warmly from snapshot until fresh deriver completes).

Every one of those is a hard problem to solve once. C11-104 solved them once for git. **C11-106's wiring step is what makes that solution reusable for every future probe c11 wants to run.** Until the coordinator is actually load-bearing for at least one production caller, every claim "the seam is ready for the next deriver" is unverified.

### The `.stale` State as a Lifecycle Signal

The plan treats `.stale` as a deferred edge case. It's not — it's **the first member of a category**. A pane's derived metadata can be:

- **Fresh** — we just derived it, value is current.
- **Stale** — we derived it once, the world changed, our value is suspect.
- **Unknown** — we couldn't derive it (timeout, not-in-context).
- **Pending** — derivation is in flight.

`fresh`/`stale`/`unknown`/`pending` is a state machine. Currently nothing else in c11 carries that state, but **once it exists for git context, the same machine is reusable for every other derived signal**. The chip render can vary by state (solid / dimmed / hollow / spinner). The socket can expose state. Snapshots can carry "this was fresh as of T" so restore is informed about staleness, not just blind.

Naming `.stale` properly in C11-106 is the difference between "edge case for worktrees" and "first instance of a general lifecycle model for derived values."

---

## How It Could Be Better

The plan as written is good — it correctly identifies the highest-leverage gap (cache + coordinator wiring) and the cheapest wins (four missing tests + enum names). But there are structural improvements worth considering.

### 1. Reframe scope item #1 as the spine of the ticket

The plan lists "wire DerivationCoordinator" as one of seven scope items, with "document seam as forward-looking-only" as an acceptable fallback. **The fallback is a trap.** If C11-106 ships with the seam still un-wired and a doc-comment saying "this is forward-looking," the next agent inheriting this code will hit the same drift the Phase 4 audit hit: classes that look load-bearing aren't, and `TabManager.swift:1724` is still the real call site. Doc-comments don't compound; wired code does.

**Suggestion:** delete the "document as forward-looking" branch from the plan. Make wiring non-negotiable. Move the "modest cost" framing to the front. The cost of *not* wiring is recurring confusion across every future review of metadata code.

### 2. Add a second deriver in the same ticket — even a trivial one

Right now `MetadataDeriver` is a protocol with one conformer. A protocol with one conformer is not a protocol; it's a refactored class with extra syntax. To validate that the seam is actually generic, add one more deriver in C11-106:

- **`terminal_type` deriver.** Currently terminal_type is set via heuristic (from `report_pwd`/OSC and shell-integration env vars). Refactor it through `MetadataDeriver` so the precedence chain becomes uniform. Now you have two conformers exercising the coordinator's API.
- OR **`host` deriver.** Computes `host` = "local" vs `ssh://target` vs `container://name` vs `tailscale://machine`. Even a one-line "always returns 'local' for now" is enough to prove the seam is generic.

The second-deriver cost is small (a stub conformer). The payoff is that the abstraction is exercised, not just declared. Every reviewer of every future ticket will see that the coordinator runs N derivers, not one.

### 3. Decide the enum naming question by reference to the future, not the past

The plan presents enum naming as "SPEC says X, impl says Y, pick one." The right tiebreaker is: **which case names will read correctly when there are five derivers in this enum, not one?**

`.notInRepo` / `.stale` / `.bare` make sense when the only deriver is git. When the next deriver is `host`, those case names are meaningless. The right model is probably:

- The **lifecycle** state (`.fresh` / `.stale` / `.unknown` / `.pending` / `.timeout`) belongs to a generic `DerivedValue<T>` enum or to the coordinator's result envelope, not to git-specific cases.
- The **domain** state (`.linkedWorktree` / `.mainCheckout` / `.detached` / `.notInRepo` / `.bare`) belongs to the git-context-specific value type.

Renaming the impl to match the SPEC literally (just adding `.notInRepo` and `.stale` to `GitContextKind`) is a tactical win that locks in a structural mistake. The structural answer is: **separate lifecycle from domain.** A future `host` deriver will want `.fresh`/`.stale`/`.pending` too but will never want `.linkedWorktree`. Make the chip projector, snapshot logic, and socket layer aware of lifecycle independently from domain.

This is a non-trivial refactor and may not fit in C11-106. But the plan should at least **mark the decision as load-bearing for future derivers**, not just a search-and-replace.

### 4. The cache invalidation flywheel: mtime is a starter, not the answer

The current plan keys the cache on `(cwd, mtime(headPath))`. mtime works but is a polling model — every probe re-stats the HEAD file. For one pane in one worktree, that's nothing. For 30 panes spanning a dozen worktrees, all OSC-7-ing on every prompt, you're stat()-ing the same HEAD file dozens of times per second.

**FSEvents-based invalidation** (already deferred in the v2 validation plan as "E2") is the right next step, and it's the single most powerful unlock the coordinator gives you. Here's why:

- One FSEvents stream per unique `(common-dir, worktree)` pair, regardless of how many panes are looking at it.
- Cache invalidation becomes *event-driven*: when HEAD or refs/heads changes, all derived chips for that worktree refresh. No polling.
- This naturally extends to every future deriver: a `kubectl_context` deriver watches `~/.kube/config`, an `aws_profile` deriver watches `~/.aws/credentials`, etc.
- The coordinator becomes the central place to register `(watch path → invalidate cache key)` rules.

C11-106 should at least **leave a TODO comment in the cache implementation marking FSEvents as the intended replacement**, so the mtime version doesn't accidentally become a permanent ceiling. Better: spin up a follow-up ticket explicitly and link it from C11-106's body.

### 5. The "document deferred" pattern is decay

Scope item #7 says "annotate the v2 validation plan in-place to note which ACs were deferred-then-resolved-here." That's good practice but it's defensive — it documents what got skipped.

The more powerful move is to **add a new validation plan section** to C11-106 itself listing the things this round *consciously chose not to build* (FSEvents, separate lifecycle/domain enums, second deriver, etc.) with reasoning. That turns each deferral into a positive design decision, not a checkbox skipped. The next round of work has a clear list of "what's next" instead of an audit log of "what was skipped."

---

## Mutations and Wild Ideas

### Mutation 1: Treat the sidebar chip as the operator's HUD, not just a worktree indicator

The sidebar today shows: title, description, role/status/task/model chips (canonical metadata), worktree/branch chips (now derived), PR pill, notification dot. That's a HUD — a continuously-updated, environmentally-derived, multi-source readout of every pane's state.

If you accept that framing, the next derivers become obvious:

- **`pr_state`** — open / merged / draft / closed / no-pr, derived from `gh pr view`. Already partially present as the PR pill; promote it to a derived metadata key so other surfaces (markdown, browser) can read it.
- **`ci_state`** — green / red / running / unknown, derived from `gh run list`. Now the chip glows when CI breaks under you.
- **`task_state`** — when in a lattice-tracked dir, derive nearest open Lattice ticket and its status. Auto-populates the `task` chip without the agent writing it.
- **`dirty_lines`** — count of changed lines in the worktree. The `*` dirty marker becomes a number you can sort by.
- **`agent_idle_ms`** — derived from `report_pwd` activity. Highlights stalled agents. Pairs powerfully with the sidebar.
- **`network_state`** — last network hit, latency, error rate. Surfaces flaky-network suffering.

Each of these is a 20–100 line deriver once the coordinator exists. The chip layer is already there. The settings toggle pattern is already there. C11-106's wiring step is the **enabling** step for all of them.

### Mutation 2: Use derivation as the basis for cross-pane queries

Once metadata is derived and stored, the socket can answer questions like:

- "List all panes in worktree X."
- "List all panes on branch feature/foo."
- "List all panes whose PR is in draft state."
- "Focus the pane that's running codex."

This is not currently a c11 capability. The CLI today lets you target panes by surface ID, name, or position. After C11-106 + coordinator wiring, you can target panes by **derived facts about them**. That's a different kind of addressing — **content-addressed panes, not just name-addressed**.

Concrete sketch: `c11 panes --where "worktree=c11-104-sidebar-chips"` returns a list of surface IDs. `c11 send --where "agent=codex" "ping"` broadcasts to all codex panes. The agent skill grows a "find panes by predicate" primitive.

This is a big mutation — it changes how agents script c11 — but it's enabled almost entirely by C11-106's wiring step. The data is there; the predicate layer is small.

### Mutation 3: The metadata store as a Lattice mirror

Lattice tracks tasks. c11 derives `worktree` / `branch` from panes. The bridge is obvious: **if a pane's worktree corresponds to a Lattice ticket's branch, derive `task` from it.**

```
worktree = "feat-c11-106-followup"
→ Lattice ticket search by branch
→ task = "C11-106"
→ status = "in-progress" (from Lattice)
```

Now the sidebar shows the Lattice ticket for every pane that's working on one, automatically, with no agent writing it. The agent's job stops being "remember to update your sidebar chip" because c11 derived it from the worktree. This is the **maximally agent-friendly version** of c11's task tracking — agents don't write status; they just exist in the right git worktree and the status writes itself.

Mutation cost: a `LatticeTaskDeriver` that runs `lattice ticket find --branch <name>` on cwd change. The Lattice CLI is fast enough to call frequently. Cache by branch name. Done.

### Mutation 4: Derived = telemetry source

Right now c11 has no telemetry — no "what's this user doing" signal back to anything (which is good, c11 is privacy-default). But internally, derived metadata is *exactly the kind of signal* that would let:

- Sidebar "recent" panel sort by most-recently-active branches across all c11 sessions.
- Workspace snapshot restore preserve "which branches were live" even across machine reboots.
- An optional, opt-in personal heatmap: "you spent N hours in feature/foo, M in main, K in ghostty submodule this week."

This is operator-only, never network'd. But the coordinator is the foundation for any time-aware view of "what was I working on" — which is something operators with 30 parallel agents start needing very fast.

### Mutation 5: Derivers as cross-language plugins

The `MetadataDeriver` protocol is currently Swift-internal. The wild version: define a JSON-line protocol over the socket, where any external process can register as a deriver.

```
{"derive": ["worktree", "branch"], "cwd": "..."} ↔ {"worktree": "foo", "branch": "bar"}
```

Now a third-party plugin (or even an agent itself) can register custom derivations: `nix_shell`, `python_venv`, `nvm_node_version`, `docker_compose_project`. The coordinator's gen-token + cache + precedence rules apply to all of them uniformly.

This is far beyond C11-106's scope, but **the wiring done in C11-106 is exactly the same shape as what the plugin model would need**. The protocol surface for Swift-internal derivers is the same protocol surface for external derivers. Plan accordingly: don't bake `git`-specific knowledge into the coordinator's API. Keep the `MetadataDeriver` protocol fully generic.

---

## What It Unlocks

Once C11-106 ships with the coordinator actually wired:

| New capability | What enables it | Estimated effort to add next |
|---|---|---|
| Second deriver (host/ssh/container) | Coordinator is real | 1 ticket, ~200 LOC |
| FSEvents-based cache invalidation | Cache is real | 1 ticket, ~150 LOC |
| `c11 panes --where <predicate>` | Derived metadata is queryable | 1 ticket, ~100 LOC |
| Lattice task deriver | Coordinator + cwd-change trigger | 1 ticket, ~80 LOC |
| `pr_state` / `ci_state` derived chips | Same as worktree chips, new deriver | 1 ticket each, ~150 LOC |
| Sidebar grouping by worktree (option E from C11-104) | Worktree is now first-class structured data | 1 ticket, ~300 LOC |
| Snapshot warm-restore (AC19 from v2) | Lifecycle states + snapshot integration | 1 ticket, ~200 LOC |
| External plugin derivers | Protocol genericity preserved | Larger, but the seam is ready |

The flywheel effect: each new deriver is cheaper to ship than the last, because the framework is doing more of the work. Today, the cost of a single deriver includes the coordinator scaffolding. After C11-106, the cost is just the deriver itself.

---

## Sequencing and Compounding

The plan's seven scope items are listed but not strongly ordered. The right order to compound learning is:

### Phase A (must land first, blocks everything else)

1. **Wire DerivationCoordinator into TabManager.** This is the load-bearing step. Until this is real, every other step is decorative.
2. **Add the cache wiring tests (AC12 with real worktree + submodule fixtures).** These verify the wiring step did what it claimed.

### Phase B (high-leverage, low-cost, do in parallel with A)

3. **Add the four missing tests (AC14, AC16, AC17, AC20).** These are independent of the wiring step and harden the contracts. They can be written in parallel with the wiring work.
4. **Decide enum naming.** Cheap. Affects test code. Lock it before writing tests if possible.

### Phase C (the structurally important move, do after A is stable)

5. **Add a second deriver (even a stub).** Validates the protocol genericity. Forces the API to be honest about what's git-specific vs deriver-generic.
6. **`.stale` state introduction.** Once a second deriver exists, the lifecycle states become obviously general, not git-specific. Easier to design correctly.

### Phase D (polish, do last)

7. **Timeout 5s → 2s.** Tweak after the wiring is stable. The number is meaningless if the path isn't load-bearing.
8. **ThemeKey-backed dim opacity.** Tiny.
9. **Dead-code cleanup.** Tiny.
10. **Validation plan annotation.** Last, after everything else is settled.

The plan's current implicit order (wire first, then tests, then naming, then polish) is roughly right, but the addition of step 5 (second deriver) is the critical evolutionary move. Without it, the protocol genericity is unverified.

### Where to defer aggressively

- **FSEvents-based invalidation.** Tempting to bundle into C11-106. Don't. Mtime works. Make FSEvents a separate ticket so it gets the attention it deserves.
- **Lattice task deriver / pr_state deriver / etc.** These are tempting follow-ups. Sequence them after C11-106 demonstrates the coordinator is solid, not as part of it.

### Where to under-invest deliberately

- **AC19 (restore warm-path).** Plan correctly defers this. Keep it deferred. The lifecycle state model needs to settle first; warm-path restore depends on `.pending` / `.fresh` being well-defined.
- **AC10 (`.stale` state).** Plan offers it as optional. Promote it to non-optional IF the enum-naming decision settles toward separating lifecycle from domain. Otherwise defer.

---

## The Flywheel

Currently c11's value-per-deriver is roughly:

- First deriver (git): high cost (build the coordinator, the cache, the precedence rules, the snapshot integration, the socket guards), high value (worktree chips).
- Each subsequent deriver: ??? — unproven, but the *expectation* is that cost drops fast.

The flywheel C11-106 can engineer:

```
Wire coordinator → second deriver shipped cheap → third deriver shipped cheaper
                                ↓
              Each deriver adds a glance-able signal to the sidebar
                                ↓
              Sidebar becomes the operator's HUD, not just a tab list
                                ↓
              Operator runs more parallel agents (visibility scales)
                                ↓
              Operator demand for new derivers grows (CI, PR, task, host, container, ...)
                                ↓
              Coordinator becomes the most important seam in c11
```

The flywheel turns only if:

1. **The coordinator is actually wired in C11-106** (not "documented as forward-looking").
2. **At least one second deriver gets added soon** (in C11-106 or the immediate follow-up) to prove the cost-drop is real.
3. **The protocol stays generic** (don't bake git-isms into the coordinator's API).

If any of those three fails, the flywheel doesn't spin and the coordinator stays as a stub forever. C11-106 is the single moment where all three are decidable.

### The acceleration move

Once the flywheel is spinning, the acceleration move is **making it cheap for agents to propose new derivers**. The skill should have a section: "If you find yourself reading the same env signal across multiple panes, propose a deriver." That turns operators-and-agents into the deriver-proposing surface, and the coordinator becomes a community substrate, not a c11-team-only thing.

---

## Concrete Suggestions

### Suggestion 1: Rewrite scope item #1 as the spine of the ticket

Replace:

> Two acceptable resolutions: Wire it in for real. ... OR Document seam as forward-looking-only.

With:

> Wire `DerivationCoordinator` into `TabManager.initialWorkspaceGitMetadataSnapshot` and the `report_pwd` handler. The coordinator runs `[GitContextDeriver]` (with cache). Cache key = `(cwd, mtime(GitContextResolver.headPath(cwd)))`. AC12's linked-worktree + submodule fixture tests verify cache hit/miss correctness against the resolved HEAD path, not `<cwd>/.git/HEAD`. **Production code outside `GitContextResolver.swift` and `DerivationCoordinator.swift` must reference both classes by the end of this PR.** No "forward-looking" doc-comment alternative.

### Suggestion 2: Add a scope item #1b: second deriver

> 1b. Refactor `terminal_type` heuristic-detection through `MetadataDeriver`. Or add a stub `HostDeriver` returning `host = "local"` unconditionally. The goal is to exercise the protocol with two conformers, validating that nothing in the coordinator or its tests bakes git-specific assumptions in.

### Suggestion 3: Reframe enum naming as a structural decision

Replace scope item #3's two-option framing with a three-option framing:

> Decide one of:
>
> (a) Rename impl enum cases to match SPEC literally (`BranchValue.noBranch`, add `GitContextKind.notInRepo` + `.stale`). Cheapest. Preserves git-specific naming.
>
> (b) Rewrite SPEC to match impl. Avoid; the SPEC's names are more self-documenting.
>
> (c) **Refactor toward lifecycle/domain separation.** Introduce a generic `DerivationLifecycle` enum (`.fresh` / `.stale` / `.unknown` / `.pending` / `.timeout`) on the coordinator's result envelope. Keep `GitContextKind` for domain-specific states (`.linkedWorktree` / `.mainCheckout` / `.detached` / `.notInRepo` / `.bare`). Update the projector to read from both.
>
> Option (c) is the most evolutionary; if the team isn't ready, (a) is acceptable but **mark the lifecycle/domain separation as a known follow-up** in C11-106's plan amendments.

### Suggestion 4: Add a scope item for "leave breadcrumbs for the future"

> 8. Add `TODO(c11-followup):` comments at every site where the current design will need to change for the next deriver. Specifically:
>
> - `GitContextResolverCache`: `// TODO(c11-followup): replace mtime polling with FSEvents-driven invalidation.`
> - `DerivationCoordinator`: `// TODO(c11-followup): support N>1 derivers with prioritized scheduling.`
> - `GitContextKind`: `// TODO(c11-followup): if other derivers need lifecycle states, lift .stale to a generic lifecycle enum.`
> - `WorktreeChipProjector`: `// TODO(c11-followup): generalize to N derived chip rows from N derivers.`
>
> These cost ~5 minutes to write and save the next agent hours of re-deriving the intent.

### Suggestion 5: Spin a sibling ticket explicitly

C11-106 should explicitly create (or reference) follow-up Lattice tickets for:

- **C11-?: FSEvents-based invalidation** (depends on C11-106 cache wiring shipping).
- **C11-?: Second deriver (host or terminal_type)** (depends on C11-106 coordinator wiring shipping).
- **C11-?: Lifecycle/domain enum separation** if option (c) above is deferred.
- **C11-?: Restore-warmpath (AC19 from v2)** (depends on lifecycle states being defined).

This makes the deferred work visible and creates a clear "after C11-106" workstream rather than a vague "future enhancements" pile.

### Suggestion 6: A 30-line `MetadataDeriversReadme.swift` (or doc-block) at the top of the file

A short comment block at the top of the coordinator file explaining:

```
//  ## How to add a new MetadataDeriver
//
//  1. Conform to `MetadataDeriver`. Implement `derive(cwd:) async -> [MetadataKey: DerivedValue]`.
//  2. Run off-main; the precondition trip will catch you if you don't.
//  3. Register your deriver in `DerivationCoordinator.defaultDerivers` (or wherever the registry lives).
//  4. Decide your cache key. mtime-of-a-watched-file is the current pattern; FSEvents is the future pattern.
//  5. Update the canonical-keys table in `skills/c11/references/metadata.md`.
//  6. Add a logic test in `c11Tests/` using a temp-dir fixture.
//
//  Existing derivers (live examples): GitContextDeriver.
```

This is the artifact that makes the seam genuinely usable by future agents. Without it, every new deriver re-derives the conventions.

---

## Questions for the Plan Author

1. **Is C11-106 the moment to commit to the coordinator being load-bearing?** If yes, scope item #1's "document as forward-looking" branch should be deleted. If no, what's the trigger that does commit to it? (Another ticket, a different reviewer pass, a usage milestone?)

2. **Do you want to add a second deriver in C11-106 itself?** Even a stub. The protocol genericity is unverified with one conformer. A `HostDeriver` returning `"local"` is ~30 LOC and worth its weight in architectural confidence.

3. **What's your view on lifecycle vs domain separation?** Option (c) from suggestion 3 is the most evolutionary move but the largest in scope. Is C11-106 the right ticket for it, or does it need its own?

4. **Are FSEvents-based cache invalidation, FSEvents-based deriver triggers, or both — on the roadmap?** Currently it's deferred. The mtime-based cache works but is a polling model. If FSEvents is the eventual answer, even acknowledging that in C11-106's plan body (with a TODO in code) shapes the cache API differently than if mtime is the permanent answer.

5. **Is the chip layer generic enough for N derivers, or is it implicitly worktree+branch only?** `WorktreeChipProjector` is named after worktrees. If host/container/kubectl chips ship next, does the projector generalize, or does each deriver need its own projector? Worth deciding now while the code is fresh.

6. **What's the operator's appetite for the "cross-pane query" mutation (mutation 2)?** `c11 panes --where worktree=X` is a small CLI addition but changes the addressing model. Worth thinking about whether agents should be able to script this.

7. **Should derived metadata be exposed to the CLI / socket as a first-class read primitive, or only via `get-metadata`?** Currently agents can `c11 get-metadata --key worktree` (AC17). Should there also be a `c11 list-panes-by-derived` or similar? Affects whether the metadata store needs a queryable index.

8. **Is the `*` dirty marker the right model long-term?** A single `*` collapses a lot of information (modified count, untracked count, conflict state). With chips now being structured, the dirty representation could be richer — but that's a different rabbit hole. Worth knowing if you want to open it or close it.

9. **The Lattice task deriver mutation (mutation 3) is potentially the single highest-value derived signal for the operator-running-30-agents use case.** Is that on the roadmap explicitly, or should it be flagged after C11-106 lands?

10. **Are there any derived signals the operator already wants but doesn't have today?** This is the question that points the flywheel. The plan author has been driving the C11-99 / C11-103 / C11-104 chain — the lived experience of running parallel agents probably already has a "I wish c11 would just *show me* X" wishlist. Capturing that list as the C11-106 PR-body footnote turns "what's next" from speculative into operator-driven.

---

## Closing thought

C11-106 looks like a cleanup ticket. The right way to land it is as **the first ticket that treats the derived-metadata seam as the actual product**, with worktree+branch as exhibit A rather than the totality of what's being built. The cost to take the larger framing is small (a second deriver stub, some TODO comments, a doc-block, a recasting of scope item #1 as non-negotiable). The payoff is that every future deriver becomes a 1-ticket addition rather than a 1-ticket-plus-coordinator-rework.

The Phase 4 audit said "merge with eyes open." C11-106's job is to convert that "eyes open" into "load-bearing infrastructure with verified genericity." Anything less and the next audit will find the same drift.
