# C11-104 Plan Review — Evolutionary Lens

- **PLAN_ID:** c11-104-plan
- **MODEL:** Claude
- **Timestamp:** 20260518-2228
- **Lens:** Evolutionary (what this becomes, what it unlocks, what mutates from here)

---

## Executive Summary

On the surface, C11-104 is a small UI win: two chips and a colored dot in the sidebar so the operator can tell which worktree a pane lives in. That framing **drastically undersells what this plan is actually doing**.

The load-bearing move is not the chips. It is **the introduction of `derived` as a first-class precedence tier in the canonical-keys system**, and the establishment of a **derivation pipeline** (OSC 7 → off-main background resolver → cached projection → sidebar chip) that turns the workspace's *ambient environment state* into agent-readable, operator-glanceable metadata.

Once `derived` exists as a tier, and once a (cwd → external resolver → chip) pipeline is proven on git, **every other piece of ambient environment context becomes a candidate for the same treatment**: container name, hostname/SSH target, language/runtime version, daemon identity, kubernetes context, AWS profile, active python venv, nix shell, etc. C11-104 is the wedge for "c11 reads the room you are in and shows the operator + agents what they need to see, without anyone having to type it."

The biggest evolutionary risk in the current plan is that **the resolver is being built for git, not built as a derivation framework that happens to ship git first**. That is a sequencing choice with consequences for everything that follows. The plan's deliverables are right; the **shape of the internal abstractions** is the lever worth pulling now, before the second derived key arrives and the first one's shape becomes load-bearing.

The biggest evolutionary win the plan does not yet name: the `worktree:branch` chip pair, combined with the per-worktree color hash, is the **first spatial-metadata primitive** in c11. Once chips reveal worktree state, an obvious next layer is "all surfaces colored X belong to worktree X" — which is the seed for Option E (grouping), clipboard handoff between worktrees, "jump to worktree" commands, sidebar filtering, and eventually a workspace topology that knows about parallel worktrees as first-class entities. C+D bundling makes E **easier**, not harder, to land later — provided the color hash is exposed as a model property and not buried inside the chip's rendering code.

---

## What's Really Being Built

Three layered things, stacked, each more strategic than the one above it:

### 1. The chips (surface deliverable)

Two new canonical metadata keys, rendered in the sidebar, with a colored dot for worktree color. This is what the ticket says.

### 2. The `derived` precedence tier and derivation pipeline (architectural deliverable)

A new source tag in the precedence chain — `explicit > declare > osc > derived > heuristic` — and the supporting infrastructure to compute a metadata key from ambient process state (cwd) asynchronously, cache it, invalidate on the right signals, and project it through the same renderer the explicit/declare/osc keys use. This is what makes C11-104 *infrastructure*, not just a feature.

This is the actual lever. Future keys that derive from environment rather than agent declaration will all sit on this rail.

### 3. Spatial metadata for parallel workflows (positional deliverable)

The combination of `worktree:branch` + per-worktree color hash establishes that **c11 surfaces have a "where am I working" identity that is separate from their "what am I doing" identity** (task/role/status/progress). Today's c11 metadata vocabulary is heavy on the latter and silent on the former. C11-104 quietly opens that second axis.

Once a surface has both a task identity *and* a spatial identity, the workspace acquires a second dimension to organize on. Today's sidebar is a single ordered list. Tomorrow's sidebar can group, filter, color-band, and route by either axis — and the operator's choice between them becomes a UX decision rather than a "no such information exists" gap.

---

## How It Could Be Better

### 1. Name `derived` as the deliverable, not the chips

Right now the plan reads as "ship two chips; oh, and add a precedence tier as part of it." Invert the framing in the PR description, the code comments, and (most importantly) the module shape:

- Create `Sources/Metadata/Derivation/` (or equivalent) as a **derivation framework**, not a git resolver. Define a small `MetadataDeriver` protocol: input is some environment trigger (cwd-changed, env-changed, ssh-target-changed); output is one or more `(MetadataKey, MetadataValue, source: .derived)` updates.
- Ship `GitContextDeriver` as the first implementation of that protocol.
- Wire the OSC 7 handler to a `DerivationCoordinator` that holds the registered derivers and dispatches work off-main with per-deriver caches.

Cost: maybe 1–2 extra hours of plumbing in Phase 2. Payoff: the second derived key (container name, ssh host, kubernetes context, …) takes a day, not a week, and the third takes an afternoon. The cost of getting this wrong is paying the abstraction tax in arrears, in a second PR, after a real shape conflict has emerged.

### 2. Expose the worktree color as model state, not chip-internal state

The plan currently treats the colored dot as a rendering detail of the worktree chip. That is the wrong layer.

**Compute and store `worktreeColor: Color?` as a property of the surface model** alongside `worktree` and `branch`. The chip reads it; **everything else can also read it**. This is what makes Option E (sidebar grouping by worktree), the "jump to worktree" command, color-band borders on terminal panes, and color-keyed clipboard handoffs **trivial future PRs** instead of "we have to redo the color hash in three places."

If the dot is the only consumer in c11-104, fine — but the data lives on the surface, not inside the chip view.

### 3. Make the resolution result a structured value, not a flattened pair

The plan describes resolver output as roughly `(worktree, branch, kind: .linkedWorktree | .mainCheckout | .submodule | ...)`, but the submodule case needs *two* contexts (outer + inner), which gets awkward if `(worktree, branch)` is the canonical shape.

Define an explicit `GitContext` value type:

```swift
struct GitContext: Equatable {
  enum Kind { case mainCheckout, linkedWorktree, submodule, detached, notInRepo, bareClone, brokenWorktree }
  var outer: RepoContext?     // worktree+branch+kind for the superproject layer
  var inner: RepoContext?     // worktree+branch+kind when in a submodule
  // … colorSeed: AbsolutePath?  // so anything else can re-derive the color without re-hashing
}
```

The chip projection then becomes a pure function `(GitContext) -> [ChipRow]` and is trivially testable. The plan's "row 1 / row 2" model maps cleanly. And future derived chips that want to know "am I in a worktree?" without re-running git can ask the `GitContext` directly.

### 4. Pre-warm the cache on workspace restore

The plan correctly defers persisting `worktree`/`branch` in snapshots, on the reasoning that restored panes re-derive on resume. True — but **the re-derivation is async**, and on a workspace with 30 surfaces, the operator will watch the chips populate one-by-one for the first second or two after launch. Cheap fix: on workspace restore, walk all surfaces' last-known cwd and pre-warm the derivation cache in parallel before the UI renders. Failing that, render the chip with the last-known value optimistically and let the async result reconcile.

This is the kind of small thing that decides whether the feature feels solid or feels like it lags. Worth doing once, not patching later.

### 5. The 30-second coarse-interval cache invalidation is a smell

Plan says: "Invalidate on cwd change or coarse interval (~30s post-checkout for branch renames)." A 30-second window during which the chip is wrong is invisible to the agent but visible to the operator who just ran `git checkout -b foo` and is watching the sidebar.

Better: watch `.git/HEAD` with an `FSEventStream` (or `DispatchSource.makeFileSystemObjectSource`) **once per cached cwd**. The cache becomes event-driven, not interval-polled. Cost: a per-cwd file watcher object. Benefit: the chip updates the moment the operator switches branches, which is the moment they care.

Polling is fine as a fallback; event-driven should be the primary path.

### 6. Decouple "what gets derived" from "what gets rendered"

The plan ties the new keys 1:1 to chips. But once `derived` exists, an obvious near-future use is **agents reading derived metadata** without rendering it in the sidebar. (Example: a sub-agent wants to know "am I in the same worktree as my parent?" — `c11 get-metadata --key worktree` is much simpler than `pwd | xargs git ...`.) Make sure the wiring lets a derived key exist *without* being rendered, controlled by the canonical-keys table, not by being on a special "render this too" list inside the sidebar code. This is a tiny code-organization point; missing it costs a refactor in PR #2.

---

## Mutations and Wild Ideas

### M1. `derived` as the foundation for an ambient-environment intel layer

Once the `derived` rail exists, c11 surfaces become a place to project *all* of the ambient stuff agents currently have to spend cycles discovering. Concrete derived keys that would each be a 1–2 day follow-up:

- `host` — hostname or SSH target (derive from `SSH_CONNECTION` / `who am i` / mosh-context). Operators running across Atlas + Hyperion + remote dev boxes get instant "where is this terminal really running" signal.
- `container` — derived from `/proc/1/cgroup` or `docker inspect`-style probes when applicable; surfaces docker-attached panes and devcontainers.
- `language` / `runtime` — Python version + active venv, Node version + nvm context, Ruby + rbenv, Go toolchain. Derived from `which python && python --version` style probes, cached and event-watched on `pyvenv.cfg` / `.tool-versions`.
- `kubectx` — current kubectl context. Derived from `~/.kube/config`'s `current-context`. Watched for change.
- `awsprofile` — current AWS_PROFILE / aws sso state.
- `nix` — active nix-shell / flake.
- `daemon` / `service` — for panes that are running a service, the service name (derived from process tree).

The combined effect is that **the sidebar becomes a live readout of where each agent's hands are**. That is qualitatively different from today, where the operator has to ask.

### M2. Color-as-key-axis ("rainbow worktrees")

The per-worktree color is currently a peripheral hint on one chip. Mutate it into **a workspace-wide visual primitive**:

- Color-bandthe left edge of terminal panes belonging to a worktree.
- Color the sidebar tab's hover/active state with a tint of the worktree color.
- Color the title bar accent.
- When the operator opens the workspace-overview "switcher" (cmd-K-style), surfaces from the same worktree visually clump.

Once the operator's brain learns "blue = c11-99, green = c11-103," they navigate by color faster than by reading labels. This is a 1-day follow-up that compounds the C11-104 investment substantially.

### M3. The `worktree:branch` chip as a clipboard / handoff routing key

Today's clipboard is global. With worktree-as-spatial-metadata, c11 could ship a "scoped pasteboard" — a per-worktree clipboard ring. Operator copies a path inside worktree A, switches to worktree B, gets the worktree-A clipboard available under a `c11 paste --from-worktree c11-99` (or a sidebar UI affordance), independent of system pasteboard contention.

This is the kind of feature that *only makes sense* once worktree identity is first-class. C11-104 is the prerequisite.

### M4. "Jump to worktree" and Lattice-aware navigation

Once worktree is metadata, `c11 jump --worktree c11-103` becomes obvious: focus the most recently active surface in that worktree. Combine with Lattice (which already knows the ticket↔worktree mapping in `.lattice/orchestration/`) and you get `c11 jump --ticket C11-103`. The operator switches between in-flight tickets the way a tmux user switches between sessions, except c11 figured out the mapping from environment, not from a config file the operator had to write.

### M5. Spatial-metadata-aware agent spawning

If the orchestrator knows which worktree a delegator was spawned for, the next-level move is **agents that won't run in the wrong worktree by accident**. The `c11 launch` (or whatever spawns sub-agents) could carry a `--worktree` constraint that refuses to execute in a different worktree than specified. Today, an orchestrator typing `cd ~/Projects/Stage11/code/c11-worktrees/c11-103-… && claude --dangerously-skip-permissions` is uncoupled from c11's awareness. Tomorrow, the worktree identity is part of the spawn contract, and the wrong-pane-wrong-worktree class of bug disappears.

### M6. "Heatmap" / time-in-worktree telemetry

If `worktree` is a metadata key with timestamps in `metadata_sources`, then **time spent in each worktree** is derivable from history. Surface that to the operator: "you spent 4h in c11-103 yesterday, 1h in c11-99." Aggregate to Lattice → Lattice gets a passive measure of ticket effort without anyone logging hours.

This is the kind of data flywheel that compounds *because* a single PR put the primitive in place.

### M7. A "stale worktree" surface signal

If a surface's `worktree` chip shows a worktree whose underlying directory has been deleted (a stale resume), the sidebar can flag the pane as zombie/stale. Operators routinely have panes still pointing at deleted worktrees after merging and cleaning up. Today there's no signal — the operator finds out by typing into the pane and getting an error. With `derived` resolution, the chip itself becomes the signal.

### M8. Per-worktree sidebar filtering as a 1-day follow-up to E

Option E (group by worktree) is the operator's stated future direction. A simpler intermediate step that C11-104 unlocks for almost free: **a sidebar filter**, "show only surfaces in worktree X." That's not a major UI surgery — it's a predicate on the existing list. The grouping comes later; the filtering can ride in on the back of C11-104's data.

---

## What It Unlocks

Concrete capabilities that don't exist before this ships:

1. **Agent self-routing by spatial context.** Sub-agents can query `c11 get-metadata --key worktree` to confirm they're in the worktree they were supposed to be in.
2. **Lattice-side worktree awareness.** Lattice can poll surface metadata and map ticket → worktree → surfaces, enabling "list all surfaces working on ticket X" queries without parsing `agents.md`.
3. **Cross-agent handoff verification.** When agent A hands off to agent B in the same worktree, B can verify the worktree identity matches before accepting state.
4. **Sidebar filtering / search by worktree.** Day-1 feature once the data exists.
5. **Color-keyed visual scanning.** The colored-dot hash lets the operator's peripheral vision do worktree disambiguation. This is real cognitive bandwidth recovered.
6. **The `derived` pipeline for any future ambient-state key.** Each new key is now days, not weeks.
7. **Operator-side workspace topology.** Knowing which surfaces belong to which worktree is the precondition for any "session boundary" or "session scope" feature.
8. **A natural seam for c11 ↔ Lattice integration.** Lattice tickets and c11 worktrees share an identity (the branch / worktree name often *is* the ticket id, like `c11-104-sidebar-chips`). Once chips surface this, every Lattice-c11 integration gets simpler.

---

## Sequencing and Compounding

The plan's phase order (Plan → Implement → Review → Fix → PR) is fine. The sequencing questions are *inside* Phase 2.

### Recommended internal sequence for the delegator

1. **Land the abstraction shape first**, with a `NullDeriver` stub and a faked test fixture. Get the `MetadataDeriver` protocol, the `DerivationCoordinator`, the `GitContext` value type, and the `derived` precedence tier merged or at least PR-ready before any real git work happens. This is the load-bearing move; everything else compounds on top.
2. **Add the resolver as the first concrete deriver.** Now you're filling in a known shape, not inventing one. The "Hot-path discipline" risks live entirely in this step; the fact that the protocol exists means the off-main contract is enforced by the type system, not by reviewer vigilance.
3. **Add the chip projection** as a pure function over `GitContext`. This is trivially testable and trivially extensible to "row 1 + row 2" for submodules.
4. **Wire OSC 7 → coordinator → derived state → chip.**
5. **Add the color hash** as a property on the surface model. Render it in the chip. **Do not** put the hash function inside the chip view.
6. **Settings toggle, palette pick, dimming rules**, etc. — the polish layer.
7. **Tests last**, against the protocol seam, the resolver behavior, the projection, and a precedence-chain unit test.

### Where to over-invest now to compound later

- **`GitContext` as a value type, not a tuple.** Saves rework when the second consumer arrives.
- **`DerivationCoordinator` as a thing**, even with only one deriver registered today. Saves N rewrites when N more derivers arrive.
- **Color-on-surface, not color-on-chip.** Saves rework when Option E (or M2 rainbow worktrees) lands.
- **Event-driven cache invalidation** via FSEvents on `.git/HEAD` rather than 30s polling. Saves a "chip is laggy after checkout" follow-up.

### Where to defer

- Option E (grouping) — correctly deferred.
- Snapshot persistence — correctly deferred.
- Multi-toggle settings (per-chip / per-color) — correctly deferred.

### Where the plan under-invests

- **The abstraction layer.** Risk: ship the chips, then have to refactor when the next derived key arrives, then have a "this is awkward because the first one was special-cased" complaint in PR review. Cost of doing it right now: hours. Cost of doing it later: days plus a migration.
- **Cache event-driven invalidation.** Visible latency-after-checkout is something the operator will absolutely notice and file as a bug. Cheaper to do once.

---

## The Flywheel

There are two flywheels available here, both engineerable from a small change to the current plan.

### Flywheel 1: `derived` as platform for ambient-environment metadata

```
ship derived tier
  → second derived key (host, container, …) takes 1 day
  → third takes hours
  → operators and agents start relying on derived chips for routing
  → "I want to see X about this pane" becomes a deriver request, not a feature ticket
  → c11 becomes the default place to read ambient environment state across agents
  → agents request derived state instead of running probes themselves
  → c11 amortizes the probing across the workspace (1 lookup serves N agents)
```

**Trigger condition for this flywheel to spin:** the abstraction shape lands in PR #1. If C11-104 ships with `derived` as a special case rather than a generic tier, the flywheel doesn't start — each future key gets argued on its own merits.

### Flywheel 2: spatial metadata → workspace topology

```
worktree chips + color
  → operator learns to scan by color
  → sidebar filtering / grouping by worktree (Option E becomes obvious)
  → "jump to worktree" / "jump to ticket" navigation
  → workspace recognized as a 2-axis grid (task × worktree), not a flat list
  → cross-worktree handoff primitives (clipboard, file routing, agent spawn constraints)
  → c11 becomes the multi-worktree IDE-equivalent for parallel agent work
```

**Trigger condition:** color-as-model-property, not color-as-chip-rendering. Without that, every future consumer re-derives the hash and the flywheel stalls on inconsistency.

Both flywheels share a common feature: **the small architectural choices inside C11-104 decide whether the loops spin or stutter**. The visible deliverable is small; the leverage is in the seams.

---

## Concrete Suggestions

These are actionable changes to the plan. Each is small. Together they reshape what C11-104 is *worth* over the next 6 months.

### S1. Reframe the plan around `derived` as the deliverable

Rewrite the scope sentence: "Ship the `derived` precedence tier and derivation pipeline, with `GitContextDeriver` as the first implementation, surfaced via `worktree` and `branch` chips and a per-worktree color hash." This is the same code; the framing tells reviewers and future-readers what the architectural commitment is.

### S2. Introduce a `MetadataDeriver` protocol and a `DerivationCoordinator`

Even with one implementation today. Cost: small. Locks in the shape future derivers will fit into. Without it, future derivers will each invent their own off-main scheduling story, and consistency rot sets in fast.

### S3. Model `GitContext` as a structured value type

Including `Kind`, optional `outer` / `inner` `RepoContext` fields, and a `colorSeed` so consumers can re-derive the worktree color from the same source-of-truth without re-hashing. Render layer becomes pure projection.

### S4. Store `worktreeColor` on the surface model, not in the chip view

Computed from the `colorSeed` on resolution. Exposed via `get-metadata` if we want agents to read it. The chip is one consumer; future consumers (sidebar grouping, jump-to-worktree, color-band borders, terminal accent) reuse the same value.

### S5. Event-driven cache invalidation via `.git/HEAD` file watcher

Replace the 30s coarse-interval fallback with `DispatchSource.makeFileSystemObjectSource(.write | .delete | .rename)` per cached cwd. Keep 30s polling only as belt-and-suspenders.

### S6. Pre-warm the derivation cache on workspace restore

Walk all surfaces' last-known cwd, kick the resolver in parallel, before the sidebar paints. Or render last-known optimistically and reconcile. The "chips populate one-by-one after launch" experience is otherwise inevitable.

### S7. Add an AC for "second deriver fits cleanly"

Sneaky but high-leverage. Add to acceptance criteria: "AC21 — A second `MetadataDeriver` implementation (stub allowed) can be registered and produces a derived metadata key without modifying the resolver pipeline." This is a one-test demonstration that the abstraction holds. Catches accidental special-casing of git before it ossifies.

### S8. Open a second Lattice ticket immediately for `host` as the next deriver

Not to ship in this PR — to validate the abstraction by attempting a second concrete deriver against the new seam right after C11-104 merges. If the second deriver is easy, the abstraction was right; if it's hard, fix it while only one consumer exists.

### S9. Add a sidebar filter input (1-day follow-up ticket)

"Show only surfaces matching worktree X" as the smallest possible exercise of the new metadata key. Validates the data shape and is genuinely useful day-1 to anyone running 8+ panes. The grouping option E is the bigger UI surgery; filtering is small and slots in immediately.

### S10. Document the `derived` tier in `references/metadata.md` with future-key examples

The plan correctly updates the metadata reference for the new tier and keys. Go one step further: include an "Implementing a new deriver" section, even if it's two paragraphs. Future agents adding derivers (and there will be future agents) will find the doc before they find the code.

### S11. Lattice integration probe

Lattice already knows ticket→worktree mappings via `.lattice/orchestration/`. Once C11-104 ships, a future Lattice change can poll surfaces by `worktree` chip value to build "what's in flight on this ticket" views. Worth a one-line note in the C11-104 PR: "this enables a Lattice-side `lattice surfaces --ticket C11-104` follow-up." Cheap to mention, sets the next consumer up.

---

## Questions for the Plan Author

1. **`derived` as a tier vs. as a special case.** Are you committed to `derived` being a general-purpose precedence tier that future ambient-environment keys (host, container, language, kubectx, …) will use? Or is the intent that it's purpose-built for git context and any future similar work invents its own approach? The answer changes how much abstraction shape this PR should carry.

2. **Worktree color as model state vs. view state.** Should `worktreeColor` live on the surface model (queryable, reusable for borders/filter UI/jump commands) or strictly inside the chip rendering code? The plan is ambiguous; the difference compounds.

3. **Option E (sidebar grouping) timeline.** Is grouping a "someday" or a "next quarter" item? If it's near-term, the design choices in C11-104 should explicitly preserve the grouping affordance (stable color, exposed worktree key, no chip-internal logic the grouping layer would need to reach into). If it's truly long-tail, the surface area to preserve is smaller.

4. **Event-driven `.git/HEAD` watching vs. coarse polling.** Are you willing to spend a few hours wiring file watchers, or is 30s polling acceptable for v1? Operator-visible latency-after-checkout is the trade.

5. **Second deriver as a follow-up commitment.** Would you like to open a ticket *now* for the second deriver (host, container, or kubectx — operator's pick) to land within ~2 weeks of C11-104, as a forcing function on the abstraction? Or keep `derived` git-only until a real need surfaces?

6. **Pre-warm on restore.** Is the "chips populate async after workspace restore" UX acceptable for v1, or worth pre-warming?

7. **`worktree` chip on non-terminal surfaces.** Plan calls cross-process visibility out of scope. Should it be? Markdown surfaces opened from inside a worktree carry implicit worktree identity; a chip on those surfaces would unify the spatial-metadata story across surface types. The cost is small if the data layer is right; the cost grows if it isn't.

8. **Color palette commitment.** The plan defers the palette to the delegator and flags it for operator review. Is there a preference for the palette's character (saturated/accent vs. muted/professional; warm/cool bias; align with the existing c11 chrome theme palette or contrast against it)? An 8–12 color palette is the kind of thing that's easier to set direction on once than tune three times.

9. **Agent-readability of derived keys.** Should sub-agents be able to read `worktree` and `branch` via `c11 get-metadata` (which makes M5 "spawn-with-worktree-constraint" easy) or is the `derived` tier rendering-only? The decision is mostly free now and expensive later.

10. **Lattice consumer awareness.** Do you want C11-104's PR description to explicitly call out the Lattice-side opportunity (surface-by-ticket query), or keep this PR strictly scoped to c11 and let Lattice discover the integration later?

11. **Submodule chip verb.** The plan says "submodule:" as the prefix on row 2. For the ghostty case specifically, would you prefer the chip read `submodule: ghostty` (generic) or `ghostty:` (named, like a top-level worktree)? This is more of a UX polish than an architecture question, but it gates how readers parse the row.

12. **Stale worktree handling.** Currently the plan handles "worktree pointing at deleted branch" but doesn't handle "worktree directory itself deleted, but a c11 surface still has it as cwd." Should the chip render a "stale" / red / strikethrough variant in that case (M7), or should the surface get an unrelated stale-pane treatment elsewhere?

13. **AC21 (second deriver fits).** Are you willing to add an explicit acceptance criterion that the resolver pipeline accept a second deriver without refactor, even if that deriver is a test stub? This is a cheap insurance policy against accidental special-casing.
