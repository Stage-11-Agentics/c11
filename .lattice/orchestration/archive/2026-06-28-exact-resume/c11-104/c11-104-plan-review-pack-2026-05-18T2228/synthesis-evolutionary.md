# C11-104 Plan Review — Evolutionary Synthesis

> **Coverage note:** The Gemini evolutionary review was **not produced** — that model exhausted capacity / was rate-limited during the review pack run. This synthesis is therefore a **2-model consensus (Claude + Codex)**, not the planned 3-model triangulation. Treat consensus signal here as "both reviewers said it" rather than the stronger "all three reviewers said it" the pack was designed to produce.

- **PLAN_ID:** c11-104-plan
- **Lens:** Evolutionary / exploratory — what this becomes, what it unlocks, what mutates from here
- **Models synthesized:** Claude (evolutionary-claude.md), Codex (evolutionary-codex.md)
- **Timestamp:** 2026-05-18T2228

---

## Executive Summary

Both reviewers — independently and using different vocabulary — arrived at the same load-bearing claim:

> **C11-104 is not really a "two chips in the sidebar" feature. It is c11's first ambient-context inference system, and the architectural choices made inside this PR decide whether that system spins as a flywheel or stalls as a one-off.**

Claude calls the new capability "the `derived` precedence tier and derivation pipeline." Codex calls it "an ambient context inference system" / "spatial metadata." Same primitive, different names. Both agree the visible deliverable (worktree chip + branch chip + colored dot) is a small surface over a much more strategic substrate: c11 reading the room each surface lives in and projecting that context as operator-glanceable, agent-readable metadata.

The strongest shared recommendation is to **build a typed context object first, then project it into chips** — not the other way around. The flat `(worktree, branch)` shape implied by the current plan already strains under the submodule two-row case and will strain harder when the second derived key (host, container, kubectx, runtime, …) arrives. A small structural change made now ("`GitContext` / `SurfaceSpatialContext` as a value type with `label` / `path` / `groupKey` / `colorKey`") costs hours; making it later costs days plus a migration.

The strongest shared mutation is **worktree-as-spatial-primitive**: once a surface has a stable, queryable worktree identity (not just a display string), almost every interesting follow-up — sidebar grouping (Option E), jump-to-worktree, color-keyed visual scanning, cross-worktree clipboard handoff, context-aware agent spawning, Lattice-side "surfaces by ticket" queries — becomes a small follow-up rather than an architectural argument.

The biggest under-investment both reviewers flagged: **the abstraction layer**. Ship the chips as currently scoped, but invest the marginal hours now to make the abstraction shape correct, because the cost of getting it wrong is paid in arrears by every future derived key.

---

## 1. Consensus Direction — Evolution Paths Both Models Identified

Both reviewers converged on the same set of evolutionary moves. Numbered for reference:

1. **`derived` is a tier, not a special case.** Both reviewers want `derived` shaped as a general-purpose precedence rail for ambient-environment metadata, not a one-off scaffolding around git. Claude: "the resolver is being built for git, not built as a derivation framework that happens to ship git first." Codex: "leave the extension point obvious in code and docs so the next derived context does not feel like a one-off."

2. **Build the typed context object before projecting into chips.** Both reviewers independently sketch a structured value type (Claude: `GitContext` with `Kind`, optional `outer` / `inner` `RepoContext`, `colorSeed`; Codex: `SurfaceSpatialContext` / `DerivedSurfaceContext` with `primary` / `secondary` / `groupKey` / `colorKey`). Same instinct: a flat metadata pair will fail on submodules and on grouping. Render layer becomes a pure projection over the structured value.

3. **Worktree identity must be stable and queryable, not just renderable.** Both reviewers want a normalized identity triple: display label (basename) + stable identity (absolute path) + group key. Color should derive from the stable identity, not from the display label, so that same-basename worktrees in different physical locations are visually distinguishable.

4. **Color is a property of the surface model, not of the chip view.** Both reviewers (Claude explicitly, Codex implicitly via "color key" / "groupKey") want worktree color hoisted up the stack to be queryable and reusable by future consumers (sidebar grouping, terminal accent borders, jump commands, command palette filters). If the color hash function lives inside the chip's rendering code, every future consumer re-derives it and drift is guaranteed.

5. **The chip's strategic value is spatial metadata, not visual decoration.** Both reviewers identified that the colored dot is teaching the operator's peripheral vision to recognize worktrees as spatial objects. That cognitive shift is the precondition for grouping (Option E), filtering, jump commands, and any cross-surface operation keyed on worktree identity.

6. **Option E (sidebar grouping by worktree) becomes nearly free if C+D is shaped correctly.** Both reviewers want C11-104 to ship the *group key* as data, even though no UI consumes it yet. Codex: "If C+D ships a real group key, E is mostly layout and interaction design." Claude: "filtering can ride in on the back of C11-104's data" as a 1-day follow-up.

7. **Derived metadata must be agent-readable, not just human-visible.** Both reviewers see sub-agents querying `c11 get-metadata --key worktree` to verify their spatial context. This unlocks spatial-context-aware agent coordination (worktree-constrained spawning, handoff verification) that doesn't exist before this ships.

8. **Document the `derived` tier as a future family, not just as plumbing for two new keys.** Both reviewers want `references/metadata.md` to explicitly frame `derived` as the rail for future ambient-environment keys (host, container, runtime, service, repo context) so future contributors find the pattern before they reinvent it.

9. **Defer rendering generalizations, but preserve the architectural seam.** Both reviewers explicitly say: do not ship host/container/language chips in C11-104. Ship git only. But leave the resolver/coordinator/protocol shape in place so those future chips fit cleanly.

10. **Resolver/derivation should never be gated by the rendering toggle.** Codex: "Keep the settings toggle rendering-only. Do not stop deriving context when chips are hidden." Claude implies the same by making derived state available to agents independent of the chip's visibility. Hidden context still powers future automation.

---

## 2. Best Concrete Suggestions — Most Actionable Ideas

The highest-leverage, most actionable changes to the plan, ranked by leverage. Each is small in code cost and large in compounding value.

1. **Introduce a typed context value type (`GitContext` / `SurfaceSpatialContext`)** rather than emitting flat `(worktree, branch)` strings. Both reviewers' single highest-leverage suggestion. Carries `kind` (mainCheckout / linkedWorktree / submodule / detached / notInRepo / bareClone / brokenWorktree), `outer` / `inner` repo contexts for submodules, plus `label` + `path` + `colorSeed` / `groupKey` for stable identity. Chip projection becomes a pure function `(GitContext) -> [ChipRow]`.

2. **Introduce a `MetadataDeriver` protocol and a `DerivationCoordinator`,** even with only `GitContextDeriver` registered today. Locks in the shape future derivers will fit. The off-main scheduling contract becomes type-enforced rather than reviewer-vigilance-enforced.

3. **Store `worktreeColor` (or `colorKey`) as a property of the surface model,** computed once from the stable path, exposed via `get-metadata`, and consumed by the chip dot as one of many possible consumers. Future grouping, borders, jump commands, and filter UIs share the same value.

4. **Make the renderer consume chip rows, not flat strings.** The submodule case already needs two rows; model that directly rather than special-casing the renderer. A "row 1 / row 2" model maps cleanly and avoids the renderer becoming special-case heavy.

5. **Replace the 30-second coarse-interval cache invalidation with event-driven `.git/HEAD` watching** via `DispatchSource.makeFileSystemObjectSource(.write | .delete | .rename)` per cached cwd. Keep 30s polling as belt-and-suspenders only. The operator who just ran `git checkout -b foo` will see the chip update immediately rather than wonder if it's broken.

6. **Pre-warm the derivation cache on workspace restore.** Walk all surfaces' last-known cwd and kick the resolver in parallel before the sidebar paints. Alternative: render last-known optimistically and reconcile when the async result arrives. Without this, a 30-surface workspace will see chips populate one-by-one for the first couple of seconds after launch.

7. **Add AC21 (or equivalent): "a second `MetadataDeriver` (stub allowed) can be registered without modifying the resolver pipeline."** Sneaky but high-leverage. A one-test demonstration that the abstraction holds, before any second consumer arrives to reveal it's actually special-cased.

8. **Define `derived` as c11-internal-only on the socket boundary.** External clients should write `explicit` or `declare`. If any socket caller can claim `source: derived`, the precedence tier loses its meaning. Document the boundary explicitly even if enforcement is light in v1.

9. **Make the settings toggle rendering-only, not derivation-gating.** Keep the resolver running so command palette, agent metadata queries, and future automation can rely on the derived value even when the chip is hidden.

10. **Open a follow-up Lattice ticket immediately for the second deriver** (host, container, or kubectx — operator's pick) to land within ~2 weeks of C11-104, as a forcing function on the abstraction. If the second deriver is easy to add, the abstraction was right; if it's painful, fix the seam while only one consumer exists.

11. **Add one resolver test for same-basename / different-absolute-path worktrees at the context level**, not just at the color-projection level. Protects the future grouping identity from accidentally collapsing to display text.

12. **Document the `derived` tier in `references/metadata.md`** with a "future derived keys" list (host, container, runtime, service, kubectx, awsprofile, …) and a two-paragraph "Implementing a new deriver" section. Future contributors find the doc before they find the code.

---

## 3. Wildest Mutations — Most Creative / Ambitious Ideas

Sorted from most-grounded to most-ambitious. Each is a future move enabled by getting C11-104 right.

1. **Rainbow worktrees.** Lift the worktree color from the chip's colored dot into a workspace-wide visual primitive: color-band the left edge of terminal panes belonging to a worktree, tint the sidebar tab's hover/active state, color the title bar accent, cluster same-color surfaces in cmd-K-style switchers. Operator's peripheral vision navigates by color faster than by reading labels. (Claude, M2.)

2. **Spatial command palette.** Once worktree is structured identity, the command palette gets: `Jump to worktree: c11-104-sidebar-chips`, `Focus next surface in this worktree`, `Copy cwd from this worktree`, `Send command to all surfaces in this worktree`, `Open browser/docs beside this worktree`. Chips become the visual handle for targeting. (Codex.)

3. **Worktree clipboard handoff (scoped pasteboards).** A per-worktree clipboard ring lets the operator copy in worktree A, switch to B, and `c11 paste --from-worktree c11-99` (or click a sidebar affordance). Independent of system pasteboard contention. Only makes sense once worktree identity is first-class. (Both reviewers; Claude M3, Codex.)

4. **Context-aware agent launch.** The launcher inherits spatial context from the focused surface: launch into same cwd/worktree, name the tab `<task> :: <worktree> :: Codex`, pre-fill `task` / `role` / derived context. Chip becomes "spawn more work here," not just "where am I?" (Codex.)

5. **Spatial-metadata-aware agent spawning with worktree constraints.** `c11 launch --worktree c11-103` refuses to execute in a different worktree than specified. The "orchestrator typed `cd` in the wrong pane and sub-agent ran in the wrong worktree" class of bug disappears entirely. (Claude, M5.)

6. **Lattice-aware jump.** `c11 jump --ticket C11-103` resolves via Lattice's ticket↔worktree mapping in `.lattice/orchestration/`, then focuses the most recently active surface in that worktree. Operators switch between in-flight tickets the way a tmux user switches between sessions, with the mapping derived from environment instead of hand-maintained config. (Claude, M4.)

7. **Worktree health beacons.** Once branch/worktree is known, attach: dirty state, tests-running indicator, last test result, PR open / CI red, Lattice ticket state. The chip evolves into an operator cockpit row. (Codex.)

8. **Stale-worktree zombie signal.** If a surface's `worktree` chip points at a deleted directory (post-merge cleanup), the chip renders a stale / red / strikethrough variant. Operator gets the signal in the sidebar instead of finding out by typing into the pane and getting an error. (Claude, M7.)

9. **Time-in-worktree heatmap / passive effort telemetry.** With `worktree` as timestamped metadata, time spent per worktree is derivable from history. Lattice gets a passive measure of ticket effort without anyone logging hours. The data flywheel compounds because the primitive exists. (Claude, M6.)

10. **Derived ambient-environment intel layer.** The wildest claim — both reviewers' shared horizon. Once `derived` is a rail, ship 1–2-day follow-ups for: `host` (SSH target / hostname), `container` (docker / devcontainer), `runtime` / `language` (active venv, nvm context, Go toolchain), `kubectx` (current kubectl context), `awsprofile`, `nix` shell / flake, `daemon` / `service` (process-tree-derived). The sidebar becomes a live readout of where each agent's hands are. c11 becomes the default place to read ambient environment state across agents, and individual agents stop running their own probes because c11 amortizes one lookup across N consumers. (Both reviewers; Claude M1, Codex "Derived Environment Stack.")

---

## 4. Flywheel Opportunities — Self-Reinforcing Loops

Both reviewers explicitly identified flywheels. Two distinct loops emerged, with one shared trigger condition.

### Flywheel A — `derived` as platform for ambient-environment metadata

1. C11-104 ships the `derived` tier and `DerivationCoordinator`.
2. Second derived key (host, container, …) takes 1 day instead of a week.
3. Third derived key takes hours.
4. Operators and agents start relying on derived chips for routing and verification.
5. "I want to see X about this pane" becomes a deriver request, not a feature ticket.
6. c11 becomes the default place to read ambient environment state.
7. Agents stop running their own probes; they read c11's derived state instead.
8. c11 amortizes the probing across the workspace — one lookup serves N agents.
9. The flywheel compounds: more keys → more consumers → more value in adding the next key.

> **Trigger condition (Claude):** the abstraction shape must land in PR #1. If C11-104 ships with `derived` as a special case rather than a generic tier, each future key gets argued on its own merits and the flywheel never spins.

### Flywheel B — Spatial metadata → workspace topology

1. C11-104 ships worktree chips with stable color hash.
2. Operator's peripheral vision learns to scan by color.
3. Sidebar filtering / grouping by worktree (Option E) becomes obvious — and easy if `groupKey` is data.
4. "Jump to worktree" / "jump to ticket" navigation gets added.
5. The workspace is recognized as a 2-axis grid (task × worktree), not a flat list.
6. Cross-worktree handoff primitives appear: clipboard, file routing, agent-spawn constraints, command-palette filters.
7. c11 becomes the multi-worktree IDE-equivalent for parallel agent work.

> **Trigger condition (Claude):** color-as-model-property, not color-as-chip-rendering. Without that, every future consumer re-derives the hash and the flywheel stalls on visual inconsistency.

### Flywheel C — Operator trust → agent automation (Codex's framing)

1. c11 derives useful context without agent effort.
2. Operator sees the context in the sidebar.
3. Operator trusts c11 as the spatial map of the work.
4. Agents and commands can target that map.
5. More workflows move from "ask an agent / inspect a terminal" to "operate on visible context."
6. More derived signals become worth adding because they have somewhere coherent to render and something useful to drive.

> **Trigger condition (Codex):** worktree identity must be internally targetable even before target commands ship — stable IDs, not only labels. Otherwise step 4 has nothing to bind to.

### Shared meta-flywheel observation

Both reviewers note that the **small architectural choices inside C11-104 decide whether the loops spin or stutter**. The visible deliverable is small; the leverage is in the seams. Specifically:

- `MetadataDeriver` protocol → Flywheel A spins.
- `worktreeColor` on the surface model → Flywheel B spins.
- Stable `groupKey` / `path` identity → Flywheel C spins.
- Without these, the chips still ship and still work, but each future capability re-litigates the shape of derived state from scratch.

---

## 5. Strategic Questions for the Plan Author (Deduplicated, Numbered)

Both reviewers ended with question lists. The set below merges them, drops duplicates, and renumbers. Where one reviewer asked a more pointed version of a shared question, the more pointed version is kept.

1. **Is `derived` a general-purpose precedence tier** (committed to host, container, kubectx, runtime, … using the same rail) or **purpose-built for git context** (with future similar work inventing its own approach)? The answer changes how much abstraction shape this PR should carry. *(Claude Q1, Codex Q1 — shared.)*

2. **Should `derived` be a publicly writable source via `surface.set_metadata`** (any socket client can claim `source: derived`) or **c11-internal-only** (external clients must use `explicit` or `declare`)? Codex's preference: internal-only. Either way, document the boundary. *(Codex Q1, partial — see also Claude implicit.)*

3. **Should `worktree` be only a display key, or a stable command / grouping identity** for future features? Should `worktreeColor` live on the surface model (queryable, reusable for borders / filter UI / jump commands) or strictly inside the chip rendering code? *(Codex Q2, Claude Q2 — shared.)*

4. **Should sub-agents be able to read `worktree` and `branch` via `c11 get-metadata`** (enabling spatial-context-aware agent spawning, handoff verification, M5) or is the `derived` tier rendering-only? Decision is mostly free now and expensive later. *(Claude Q9.)*

5. **Should a hidden stable worktree ID exist now, before grouping or jump commands ship**, so future command-palette / jump workflows have something to bind to? *(Codex Q5.)*

6. **Option E (sidebar grouping) timeline — someday or next quarter?** If near-term, the design choices in C11-104 should explicitly preserve the grouping affordance (stable color, exposed worktree key, no chip-internal logic the grouping layer would have to reach into). If long-tail, less surface area to preserve. *(Claude Q3.)*

7. **For Option E, should submodule surfaces group under the superproject worktree, the submodule, or both?** This decision shapes whether `GitContext.outer` or `GitContext.inner` provides the group key in the submodule case. *(Codex Q3.)*

8. **Event-driven `.git/HEAD` watching vs. coarse polling for cache invalidation?** A few hours of `DispatchSource.makeFileSystemObjectSource` wiring versus an operator-visible up-to-30s lag after `git checkout`. *(Claude Q4.)*

9. **Should the settings toggle hide only the sidebar chips, or disable derivation entirely?** Codex's preference: rendering-only, so hidden context still powers command palette, agent metadata queries, and future automation. *(Codex Q4.)*

10. **Pre-warm the derivation cache on workspace restore?** Is the "chips populate async after restore" UX acceptable for v1, or worth eliminating? *(Claude Q6.)*

11. **`worktree` chip on non-terminal surfaces (markdown, browser)?** Plan calls cross-process visibility out of scope. Should it be? Markdown surfaces opened from inside a worktree carry implicit worktree identity. *(Claude Q7.)*

12. **Color palette commitment.** Plan defers palette to the delegator. Any preference on character (saturated/accent vs. muted/professional; warm/cool bias; align with existing c11 chrome theme palette or contrast against it)? Easier to set direction once than tune three times. *(Claude Q8.)*

13. **Should same-basename worktrees deliberately look text-identical with only color distinguishing them**, or should hover / titlebar expose the full absolute path? *(Codex Q8.)*

14. **Branch dimming — hardcoded `main/master/trunk`, or follow repo default branch detection** (`git symbolic-ref refs/remotes/origin/HEAD`)? The latter is robust to repos that use non-standard default branch names. *(Codex Q6.)*

15. **Submodule chip verb.** Row 2 prefix: generic `submodule: ghostty` or named-as-worktree `ghostty:`? UX polish, but it gates how readers parse the row. *(Claude Q11.)*

16. **Stale-worktree handling (M7).** When the underlying directory is deleted but a c11 surface still has it as cwd, should the chip render a "stale" / red / strikethrough variant, or should the surface get an unrelated stale-pane treatment elsewhere? *(Claude Q12.)*

17. **SSH'd remote terminals.** Expected behavior when a pane is ssh'd into a remote host and OSC 7 reports a local-looking path that c11 cannot inspect? Render nothing, render a `host:` chip when the `host` deriver lands, or render an explicit "remote" placeholder? *(Codex Q9.)*

18. **Workspace-level aggregate context.** Does c11 want derived metadata to remain per-surface only, or is C11-104 the first reason to introduce workspace-level aggregate context (e.g., "this workspace has surfaces across 4 worktrees")? *(Codex Q7.)*

19. **Long-term chip philosophy.** Are chips purely informational, or should every chip eventually become a command target (click-to-jump, click-to-filter, click-to-send)? *(Codex Q10.)*

20. **Second-deriver follow-up commitment.** Open a Lattice ticket *now* for the second deriver (host, container, or kubectx — operator's pick) to land within ~2 weeks of C11-104, as a forcing function on the abstraction? Or keep `derived` git-only until a real need surfaces? *(Claude Q5.)*

21. **AC21 — explicit acceptance criterion that a second `MetadataDeriver` (stub allowed) fits without resolver-pipeline refactor?** Cheap insurance against accidental special-casing of git before it ossifies. *(Claude Q13.)*

22. **Lattice consumer awareness.** Should C11-104's PR description explicitly call out the Lattice-side opportunity (a future `lattice surfaces --ticket C11-104` query that polls c11 surfaces by `worktree` chip value), or keep this PR strictly scoped to c11 and let Lattice discover the integration later? *(Claude Q10.)*

23. **Post-merge operator-feedback prompt.** Codex suggests adding to smoke tests: "After 30 minutes of parallel work, did the chip answer the question you actually had?" That feedback should decide Option E's shape and surface any abstraction debt while it's cheap to repay. *(Codex, concrete suggestion 10.)*

---

## Closing Note

The two reviews are remarkably aligned despite using different vocabularies. Where Claude says "`derived` precedence tier and derivation pipeline," Codex says "ambient context inference system / spatial metadata layer" — the underlying recommendation is identical. Where Claude proposes `GitContext` with `outer`/`inner`/`Kind`/`colorSeed`, Codex proposes `SurfaceSpatialContext` with `primary`/`secondary`/`groupKey`/`colorKey` — same shape, different field names.

The convergence under independent generation is itself a signal: the load-bearing architectural moves are not preference-driven. They're determined by the structure of the problem (submodules need rows; future derived keys need a shared rail; stable identity must be separable from display label; color must be reusable across consumers).

If a third (Gemini) review had landed, it would most likely have reinforced the same direction rather than opened a new one. The 2-of-3 coverage is not ideal, but the **signal-to-noise on the consensus moves above is high enough to act on without waiting for the missing third opinion.**
