# Evolutionary Review Synthesis — C11-106 follow-up plan

**Lens:** Evolutionary (where could this go, not just is-it-correct)
**Sources:** Claude, Codex
**Date:** 2026-05-19
**Missing third input:** A Gemini Evolutionary review was attempted but Gemini's API was at quota at run time, so this synthesis is across 2 of 3 intended perspectives. Treat consensus weight with that caveat — two-of-two agreement is strong evidence but not as triangulated as a full three-model pass.

---

## Executive Summary

Both Claude and Codex converge on a single, load-bearing strategic claim: **C11-106 is mis-framed as a cleanup ticket.** What looks like "wire the coordinator, fix four tests, rename enums" is actually the moment c11 commits to a derived-metadata subsystem as a first-class primitive. Worktree and branch are exhibit A, not the destination.

The reviews agree, with very high overlap, on:

1. The "document seam as forward-looking-only" fallback in scope item #1 is a trap and should be deleted from the plan. Wiring `DerivationCoordinator` into production must be non-negotiable.
2. A protocol with one conformer is not a protocol. Genericity is unverified until a second deriver exists (Claude pushes harder on adding one inside C11-106; Codex pushes harder on making the result envelope deriver-agnostic).
3. `.stale` is not an enum-naming nit — it is the first member of a category (lifecycle states distinct from domain states). Both reviewers want it modeled structurally, not as a worktree-edge-case.
4. The cache invalidation story (mtime today) must remain explicitly evolutionary. FSEvents is the eventual answer; the plan should signal that in code (TODOs) and in deferred-ticket follow-ups.
5. Once the seam is real, the obvious next derivers are roughly the same list across both reviewers: host/SSH/container/kubectl/AWS profile, PR state, CI state, dirty count, Lattice task identity.
6. The sidebar is evolving from "tab list with chips" into an **operator HUD / context strip** for the whole workspace. Both reviewers reach this framing independently.

The single highest-leverage edit to the plan: rewrite scope item #1 so it commits to a load-bearing coordinator, add a "leave breadcrumbs" scope item (TODO comments, deriver howto, follow-up tickets), and treat the `.stale` decision as structural rather than naming.

Missing-perspective caveat: with Gemini absent, we have less coverage on the "wild mutation" axis. Claude carried that load heavily in its review; Codex was more sober. A third independent voice on the bolder mutations (cross-language plugin derivers, cross-pane content-addressed queries, derivation replay harness) would have helped calibrate ambition vs. risk.

---

## 1. Consensus Direction (Both Models)

Both reviewers identified the same evolutionary spine. Numbered for clarity:

1. **The coordinator must be load-bearing in production after C11-106.** Both kill the "document forward-looking" branch. Claude: "doc-comments don't compound; wired code does." Codex: "a half-real coordinator creates ambiguity."
2. **Derived metadata is c11's internal sensor bus.** Claude calls it "a second source of truth about every pane." Codex calls it "a trusted derivation layer between raw surface state and the c11 metadata manifest." Same concept, different vocabulary.
3. **The cache is the unlock, not the chip.** Both reviewers identify cache wiring as the structurally important step — Claude as "the framework doing more work," Codex as "the discipline that makes adding the next deriver not scary."
4. **`.stale` is a lifecycle state, not a git case.** Both want lifecycle separated from domain, though they disagree on how aggressively to do it now (see section 5, question 3).
5. **The sidebar becomes a HUD / context strip.** Claude: "the operator's HUD, not just a tab list." Codex: "an operations board for the whole room." Identical framing, independently arrived at.
6. **Cache invalidation today is mtime polling; FSEvents is the eventual answer.** Both flag this. Neither wants FSEvents in C11-106. Both want the code to acknowledge the upgrade path.
7. **Derived metadata should be externally queryable** (via socket / CLI), not just sidebar-rendered. Both flag AC17 (socket reads for derived keys) as contract-level, not just test hygiene. Codex pushes Lattice as the immediate downstream consumer.
8. **The plan should leave breadcrumbs for the next agent** — TODO comments at the load-bearing seams, a "how to add a deriver" guide either in code or in `skills/c11/references/metadata.md`, follow-up tickets opened explicitly rather than implied.
9. **Validation-plan annotation is the required closing move**, not optional. Both treat the v2 validation plan as a living artifact whose drift caused this ticket to exist in the first place.
10. **The plan's current sequencing is roughly right, but it under-emphasizes the importance of step 1.** Both reviewers want the wiring step front-loaded and explicitly non-negotiable.

Areas of mild divergence:

- **Adding a second deriver inside C11-106:** Claude pushes for it ("even a stub `HostDeriver` returning `local`"). Codex doesn't require it, but does want the *result envelope* (`DerivedMetadataSnapshot`) to be deriver-agnostic. Both are getting at the same thing — verified genericity — through different means.
- **Aggressiveness on enum refactor:** Claude offers a three-option framing where (c) is "split lifecycle from domain now." Codex prefers a typed `GitContextResolution` enum that consolidates degradation states but doesn't insist on full lifecycle/domain separation in this ticket.

---

## 2. Best Concrete Suggestions (Most Actionable Ideas)

Ranked by leverage (impact relative to cost):

1. **Rewrite scope item #1 to delete the "forward-looking doc-comment" fallback.** Make production wiring of `DerivationCoordinator` into `TabManager` non-negotiable. Add an explicit acceptance criterion: "Production code outside `GitContextResolver.swift` and `DerivationCoordinator.swift` must reference both classes by end of PR." (Both reviewers, Claude's Suggestion 1.)
2. **Add typed degradation states to the resolver outcome** instead of overloading `nil`. Codex's proposed enum:
   ```swift
   enum GitContextResolution: Equatable, Sendable {
       case resolved(ResolvedGitContext)
       case notInRepo
       case bare
       case stale
       case timeout
   }
   ```
   This is cheaper than full lifecycle/domain split and still captures the structural intent. (Codex; Claude agrees in spirit via Suggestion 3 option a/c.)
3. **Add a `DerivedMetadataSnapshot` result envelope** (or equivalent) so the next deriver doesn't have to invent its own plumbing for logging, stale guards, write policy, and provenance. (Codex.)
4. **Add a "how to add a deriver" section** — either as a 30-line doc-block at the top of `DerivationCoordinator.swift` (Claude) or as a section in `skills/c11/references/metadata.md` (Codex). Both reviewers want this artifact. Either location works; both is best.
5. **Add `TODO(c11-followup):` breadcrumbs** at the load-bearing seams: cache (FSEvents), coordinator (N>1 derivers), `GitContextKind` (lift lifecycle), `WorktreeChipProjector` (generalize to N chip rows). ~5 minutes to write, saves the next agent hours. (Claude's Suggestion 4.)
6. **Open follow-up Lattice tickets explicitly** for: FSEvents-based invalidation, second deriver (host or terminal_type), lifecycle/domain enum separation (if deferred), AC19 restore warm-path. Reference them from C11-106's body. (Claude's Suggestion 5.)
7. **One end-to-end pipeline test without SwiftUI:** fake cwd A → derive → apply to `SurfaceMetadataStore` → socket-get `worktree` and `branch`. Closes AC17 and proves the UI/store dual-write contract in one shot. (Codex.)
8. **Add a lightweight diagnostic counter** for cache hit/miss/stale/timeout. No UI yet — the value is that future performance issues are explainable without instrumenting from scratch. (Codex.)
9. **Reframe the deferred work as a *positive* design decision** instead of an audit log of skipped items. New "consciously chose not to build" section in the validation plan with reasoning. (Claude's "document deferred is decay" point.)
10. **For AC20 (fatal preconditions):** if deterministic precondition-crash testing is awkward in XCTest, add a subprocess test harness *or* explicitly mark the pattern as deferred. Do not add another weak sentinel. (Codex.)
11. **Check `SidebarBranchOrdering` before deletion** — if the helper is now only legacy, delete it; if any non-sidebar consumer (command palette, workspace search) still benefits, rename it away from "sidebar" to avoid false cleanup later. (Codex.)
12. **For AC14 (timeout):** decide whether timeout is a typed state or just a nil clear. The SPEC says `.timeout`; if the impl returns nil, the test locks in less information than future risk chips will want. Prefer typed timeout. (Codex.)

---

## 3. Wildest Mutations (Most Creative / Ambitious)

Ranked by ambition. These are not C11-106 work; they are evolutionary endpoints the seam enables.

1. **Cross-language plugin derivers.** (Claude, mutation 5.) Define a JSON-line protocol over the c11 socket so any external process — including agents — can register as a deriver. `nix_shell`, `python_venv`, `nvm_node_version`, `docker_compose_project`, anything. The coordinator's gen-token + cache + precedence rules apply uniformly. Far beyond C11-106, but the wiring shape done in C11-106 is the same shape the plugin model needs. **Implication for now:** don't bake `git`-isms into the coordinator's protocol API.
2. **Content-addressed pane queries.** (Claude, mutation 2.) `c11 panes --where "worktree=c11-106"`, `c11 send --where "agent=codex" "ping"`. Changes c11's addressing model from name-based to fact-based. Codex independently called this "room queries" (mutation 3 in its review). Strong two-model agreement on the *idea*, more divergence on *how soon*.
3. **The Lattice task deriver.** (Claude, mutation 3.) If a pane's worktree corresponds to a Lattice ticket's branch, derive `task` from it. The agent stops writing status; existing in the right worktree writes the status itself. Codex echoes this as "Lattice can consume derived metadata as normal metadata — the bridge from visual sidebar feature to orchestration primitive." This is arguably the single highest-value derived signal for the operator-running-30-agents use case.
4. **Risk chips.** (Codex.) `.stale`, dirty worktree, detached HEAD, production kubectl context, mismatched branch-vs-ticket render as subtle risk hints. Derived metadata stops being passive context and becomes operator safety infrastructure. Pairs naturally with mutation 5 below.
5. **Operator policies on derived state.** (Codex.) "Highlight any surface on main with dirty state," "flag kubectl production," "flag stale worktree," "flag branch not matching Lattice task." Policy-aware context chips. Downstream of mutation 4, but C11-106 preserves the option by keeping derived states *typed* instead of collapsing them to empty strings.
6. **Derived = telemetry source (local, opt-in).** (Claude, mutation 4.) Internal, never network'd. Sidebar "recent" panel sorts by most-recently-active branches across sessions. Personal heatmap: "you spent N hours in feature/foo this week." Time-aware "what was I working on" view for operators with 30 parallel agents.
7. **Self-healing prompts.** (Codex.) A c11-aware agent launcher includes a derived-context preamble: cwd, branch, worktree, host/container, ticket, stale warnings. Agents start with situational awareness without persistent writes to their own config — fits c11's "no tenant config writes" principle.
8. **Derivation replay harness.** (Codex.) Capture `cwd` transitions and derivation outputs as a trace. Replay the trace to regression-test cache invalidation, stale-result dropping, and UI updates without launching the app or depending on real git timing. This is a *testing* mutation — it makes future evolution cheaper rather than adding a user-facing feature.
9. **The "context strip."** (Codex.) Worktree/branch chips become the first row in a compact context strip for each surface, eventually showing repo/worktree, branch, dirty state, host, container, kube context, AWS profile, task. The sidebar is the operations board for the whole room. (Claude's mutation 1 is the same idea.)

---

## 4. Flywheel Opportunities (Self-Reinforcing Loops)

Both models identified flywheels, mostly the same one but with different framings:

1. **The deriver cost-drop flywheel** (Claude, explicit in The Flywheel section):
   ```
   Wire coordinator → second deriver shipped cheap → third deriver cheaper
                                 ↓
   Each deriver adds a glance-able signal to the sidebar
                                 ↓
   Sidebar becomes operator HUD, not just a tab list
                                 ↓
   Operator runs more parallel agents (visibility scales)
                                 ↓
   Operator demand for new derivers grows
                                 ↓
   Coordinator becomes c11's most important seam
   ```
   Spins only if: coordinator is *actually* wired in C11-106, a second deriver lands soon, and the protocol stays generic.

2. **The cache-invalidation flywheel** (Codex):
   ```
   Reliable derivation path → ambient context becomes cheap to add
                            → sidebar and socket become more truthful
                            → operators and orchestrators depend on derived metadata
                            → tests and traces cover more state transitions
                            → adding the next deriver gets safer and faster
   ```
   Especially powerful if cache keys are explicit and tests use real linked-worktree/submodule HEAD paths: **every weird repo encountered in the wild becomes a regression fixture.** The system improves as edge cases hit it.

3. **The "agent-proposed deriver" flywheel** (Claude's acceleration move): once the seam is cheap, the c11 skill grows a section: "If you find yourself reading the same env signal across multiple panes, propose a deriver." Operators and agents become the deriver-proposing surface, not the c11 team alone. The coordinator becomes a community substrate.

4. **The Lattice ↔ c11 feedback loop** (implicit in Claude mutation 3 + Codex's "Lattice can consume derived metadata"): once `worktree` → `task` derivation works, Lattice tickets and c11 panes become bidirectionally aware. Operators in c11 see Lattice state automatically; Lattice dashboards can show which surfaces are on which tickets. The two systems compound rather than coexist.

5. **The validation-plan-hygiene flywheel** (Codex, less prominent but real): if every C11-X follow-up annotates the v2 validation plan with what it resolved, validation drift stops being a recurring rediscovery. The plan becomes a true living document of contract status. C11-106 exists because that hygiene was missing; closing that loop in C11-106 is the seed of the loop.

---

## 5. Strategic Questions for the Plan Author (Deduplicated, Numbered)

The two reviews produced 20 questions total. Deduplicated to the distinct strategic decisions:

1. **Is C11-106 the moment to commit to `DerivationCoordinator` being load-bearing in production?** (Claude Q1, Codex Q1.) If yes, scope item #1's "forward-looking doc-comment" branch should be deleted. If no, what's the trigger that does commit to it?

2. **Should a second deriver land inside C11-106 itself?** (Claude Q2.) Even a stub `HostDeriver` returning `"local"` (~30 LOC) verifies protocol genericity. A protocol with one conformer is not a protocol; it's a refactored class.

3. **What's the right shape for degradation states — typed enum, or full lifecycle/domain split?** (Claude Q3, Codex Q2.) Three options:
   - (a) Rename impl to match SPEC literally (`BranchValue.noBranch`, add `GitContextKind.notInRepo` + `.stale`). Cheapest, locks in git-specific naming.
   - (b) Typed `GitContextResolution` enum (Codex's proposal) — consolidates degradation states without full lifecycle/domain separation. Middle path.
   - (c) Split generic `DerivationLifecycle` (`.fresh` / `.stale` / `.unknown` / `.pending` / `.timeout`) from domain-specific `GitContextKind`. Most evolutionary, largest scope.

4. **Should `.stale` be externally visible** through socket metadata or diagnostics, or only an internal state that clears chips? (Codex Q3.) Affects whether the metadata store carries a derived-diagnostics surface separate from rendered canonical strings (Codex Q8).

5. **Where does cache policy live** — inside `GitContextResolverCache`, inside `DerivationCoordinator`, or at the `TabManager` call site? (Codex Q4.) Determines how easy the second deriver will be.

6. **Are FSEvents-based cache invalidation and FSEvents-based deriver triggers on the roadmap?** (Claude Q4.) Mtime works as a starter; FSEvents is the natural next step. Even acknowledging it in the plan body with a TODO in code shapes the cache API differently than if mtime is permanent.

7. **Is the chip projector generic enough for N derivers, or implicitly worktree+branch only?** (Claude Q5.) `WorktreeChipProjector` is named after worktrees. If host/container/kube chips ship next, does the projector generalize, or does each deriver need its own? Worth deciding while the code is fresh.

8. **Is the 2s timeout a product requirement, or was 5s an intentional reliability tradeoff** for slow disks and large repos? (Codex Q5.) The number is meaningless if the path isn't load-bearing, but the tradeoff is real.

9. **Should AC19 (restore warm-path) stay out of C11-106?** (Codex Q6.) It's a lifecycle/restore problem, not a derivation-correctness problem. Both reviewers lean defer.

10. **What's the operator's appetite for cross-pane content-addressed queries** (`c11 panes --where worktree=X`)? (Claude Q6.) Small CLI addition, large addressing-model change. Decide whether agents should script via predicates.

11. **Should derived metadata be a first-class CLI/socket read primitive** beyond `get-metadata`? Affects whether the metadata store needs a queryable index. (Claude Q7.)

12. **Is the `*` dirty marker the right long-term model?** (Claude Q8.) Single character collapses modified count, untracked count, conflict state. Structured chips could carry richer dirty representation — but only if that rabbit hole is being opened.

13. **Is the Lattice task deriver on the roadmap explicitly,** or should it be flagged as a post-C11-106 follow-up? (Claude Q9.) Codex independently raises this as Q9: "does Lattice intend to consume `worktree`/`branch` through `c11 get-metadata` soon?" Same question, different framing.

14. **Should stale/risk states become visual warnings in the sidebar,** or is the design principle that derived chips remain context-only and non-alarming? (Codex Q10.) Affects how `.stale` and dirty/detached states render long-term.

15. **Are host/SSH/container/kubectl/AWS derivers expected soon enough** that C11-106 should add a "how to add a deriver" guide now? (Codex Q7.) Both reviewers want the guide; this question is *when*.

16. **What's on the operator's "I wish c11 would just show me X" wishlist?** (Claude Q10.) The plan author has been driving C11-99 / C11-103 / C11-104; the lived experience of running parallel agents likely already has the answer. Capturing that list in the PR body footnote turns "what's next" from speculative to operator-driven.

---

## Closing Synthesis

Both reviewers — independently, from different model lineages — reached the same verdict: **C11-106 looks like cleanup but is actually load-bearing infrastructure work for a new c11 subsystem.** The minimum-viable evolutionary edit to the plan is small:

- Kill the "document forward-looking" fallback in scope item #1.
- Add typed degradation states (at minimum Codex's `GitContextResolution`, ideally Claude's lifecycle/domain split if scope permits).
- Add a "how to add a deriver" guide.
- Add TODO breadcrumbs and follow-up tickets.
- Annotate the validation plan as a required closing step.

The maximum-viable edit adds a stub second deriver (Claude's `HostDeriver` returning `"local"`) and a `DerivedMetadataSnapshot` result envelope (Codex), proving genericity and saving the next deriver from re-inventing plumbing.

The Phase 4 audit said "merge with eyes open." Both reviewers agree C11-106's job is to convert that into "load-bearing infrastructure with verified genericity." Anything less and the next audit finds the same drift.

Missing third perspective (Gemini) caveat: the wild-mutation surface is under-triangulated. If a Gemini pass becomes available later, prioritize re-running the mutation and flywheel sections — those are where a third independent voice would most likely surface ideas Claude and Codex both missed.
