# C11-104 Standard Review Synthesis

- **Plan:** `c11-104-plan` (Surface worktree + branch as derived canonical metadata chips in the sidebar)
- **Lens:** PlanReview-Standard (analytical/architectural)
- **Timestamp:** 2026-05-18T22:28
- **Models reviewed:** Claude (Opus 4.7), Codex
- **Models missing:** Gemini

> **NOTE — Gemini was rate-limited.** The third Standard review (Gemini) failed with "exhausted capacity on this model" and is not part of this synthesis. The consensus below reflects **2 of 3** planned standard reviewers. Treat single-model insights with that in mind: where only one of two surfaced a finding, it is roughly half as corroborated as a typical 3-model synthesis.

---

## Executive Summary

1. Both Claude and Codex agree the **product intent is correct** (derive worktree/branch from cwd; surface in the sidebar; do not depend on agent self-reporting) and that the **hot-path discipline** baked into the plan is appropriate and well-placed.
2. Both reviewers **converge on a single load-bearing gap**: the plan does not reconcile the new resolver/chip with the **existing** git infrastructure in c11 (`TabManager.initialWorkspaceGitMetadataSnapshot`, `panelGitBranches`, `panelDirectories`, the `sidebarShowBranchDirectory` Settings toggle, and the current Branch + Directory row). Without that reconciliation, c11 ends up with two parallel pipelines, two near-identical Settings toggles, and the operator sees duplicated or flickering chips.
3. They **diverge on severity / readiness**:
   - **Claude:** Ready to execute *after* the delegator produces an "Integration map" in plan phase. Architecture survives intact.
   - **Codex:** *Needs revision before execution.* The plan blurs three distinct subsystems (canonical metadata, sidebar rendering, branch/directory telemetry) and needs sharper architectural rules before the delegator starts.
4. Both reviewers independently flag the same concrete defects: **wrong test path** (`Tests/c11LogicTests/` does not exist; should be `c11Tests/` + target membership), **`.git/HEAD` mtime is the wrong cache key for linked worktrees and submodules**, **submodule resolution is under-specified**, **the color-hash test's "high probability" hedge is weak**, and **the new `derived` source needs an explicit internal-vs-public policy**.
5. Synthesized verdict: **Ready to execute with mandatory revisions in the delegator's plan phase.** The core architecture is sound but cannot be handed to a coder unchanged — at minimum the integration map, persistence rule, stale-result guards, submodule algorithm, and cache-key correction must be specified.

---

## 1. Where the Models Agree (Highest-Confidence Findings)

1. **Product intent is correct.** Deriving worktree/branch from cwd rather than agent self-reporting is the right move. Both reviews open with this.
2. **Hot-path discipline is appropriate.** Calling out `TerminalSurface.forceRefresh()` and `WindowTerminalHostView.hitTest()` in three places (SPEC, BUILDPLAN, AC11) is correctly proportional to typing-latency risk.
3. **Existing c11 git infrastructure is not named in the plan.** Both reviewers independently surface the same five reuse-or-replace gaps:
   - `TabManager.initialWorkspaceGitMetadataSnapshot` (off-main git probe with generation tokens and PR enrichment).
   - `panelGitBranches` (per-panel `SidebarGitBranchState` with `branch` + `isDirty`).
   - `panelDirectories` (OSC-7 cwd update path).
   - The existing **Branch + Directory** sidebar row.
   - The existing `@AppStorage("sidebarShowBranchDirectory")` Settings toggle that already gates that row.
   The plan does not specify whether the new work **reuses, replaces, or coexists with** any of these.
4. **Two Settings toggles will collide.** "Show Branch + Directory in Sidebar" (existing, default-on) and "Show worktree/branch chips" (new, default-on) are too close in name and behavior. Both reviewers flag this independently.
5. **Test target path is wrong.** Plan says `Tests/c11LogicTests/<NewFile>.swift`. The actual layout is `c11Tests/<NewFile>.swift` with target membership in `c11LogicTests`. AC15's *target* claim is correct; the *directory* mention is not.
6. **`.git/HEAD` is not a correct cache invalidation key.** Both reviewers, with slightly different framings:
   - **Claude:** Drop the timer-based TTL; invalidate on cwd change AND `.git/HEAD` mtime AND explicit refresh command.
   - **Codex:** `.git` is often a *file* (linked worktrees, submodules) — use `git rev-parse --git-path HEAD` and stat the resolved path; do not assume a literal `.git/HEAD` exists.
   Codex's correction is the stronger of the two (it explains *why* the naive path is broken in exactly the worktree/submodule cases this ticket is about). Both reviewers converge that the plan's current cache key is wrong.
7. **Submodule handling is under-specified.** Both reviewers flag this:
   - **Claude:** Nesting depth not specified (what about sub-submodules?).
   - **Codex:** The two-row algorithm is not just under-specified, it's *partly wrong*. `git rev-parse --show-toplevel` from a submodule cwd returns the submodule root, not the superproject root. Producing two rows needs **two passes** — one at the superproject path, one at the submodule path.
8. **The `derived` source tier needs an internal-vs-public policy.** Should socket/CLI clients be allowed to write `source=derived`? If yes, the spec's "derived is not agent-written" claim is false. If no, the socket parser must reject it. The plan does not commit.
9. **The color-hash test's "high probability" hedge is weak.** Both reviewers flag AC4's "two different worktree paths produce different colors with high probability" as the wrong shape of test for a finite palette. Use deterministic inputs that are known not to collide; do not bake a probabilistic assertion into the test suite.
10. **Bundling C+D in one PR is acceptable but the design risk in D (palette, contrast, collisions) is decoupled from the engineering risk in C.** Both reviewers reach this from different angles. Neither argues for splitting the PR; both argue for being explicit that D's palette is the soft iteration surface.
11. **Edge-case table is exhaustive and a strength.** Detached HEAD, deleted branch, bare clone, not-in-git, submodule, etc. Both reviewers call this out as unusually concrete.
12. **Default-on with an opt-out is the right Settings posture** for the operator workflow.
13. **Correctly out of scope.** Sidebar tab grouping by worktree (Option E), persistence of derived keys in snapshots (mostly), cross-process visibility. Both reviewers endorse the deferrals.

---

## 2. Where the Models Diverge (the Disagreement Is Signal)

1. **Readiness verdict is the biggest divergence.**
   - **Claude:** *Ready to execute* with one constraint — the delegator's plan phase must produce an "Integration map" before coding starts. Architecture survives the pass.
   - **Codex:** *Needs revision before execution.* Specific changes (persistence rule, sidebar aggregation rule, two-pass submodule algorithm, stale-result guards, cache-key correction, localization plan) must land in the plan, not in the delegator's head.
   This is a real disagreement about *who* produces the missing detail. Claude trusts the delegator to fill it in during plan phase under the lattice-orchestrator workflow; Codex wants it in the plan artifact itself before delegation. The disagreement itself is signal: both reviewers see the same gaps, but disagree about whether the planner or the delegator owns closing them.

2. **The metadata-vs-runtime question.**
   - **Claude:** Accepts canonical metadata keys (`worktree`, `branch`) as the right surface, argues for **merging** the new resolver with the existing snapshot pipeline so one resolver feeds both legacy `SidebarGitBranchState` and the new canonical-key blob.
   - **Codex:** Prefers a **runtime-only typed model first**, with optional metadata mirror only if external socket readers actually need these values. Treats canonical metadata as "too broad a hammer" for what is fundamentally a UI projection.
   This is the deepest architectural disagreement. Claude thinks "uniform render surface across `role`/`status`/`task`/`model`/`branch`/`worktree`" is the winning property and worth the metadata-store surface area. Codex thinks the metadata store is public-API-shaped and exposing internal derived state through it creates persistence, source-precedence, and snapshot blast-radius without commensurate operator benefit.

3. **Submodule diagnosis is differently specific.**
   - **Claude:** Names "nesting depth" as the gap (one level deep? two? what about sub-submodules?).
   - **Codex:** Names a *correctness bug in the command sequence* — `--show-toplevel` from a submodule cwd does not return the superproject root, so the listed sequence cannot produce both rows. Calls for an explicit two-pass algorithm (outer pass at superproject path, inner pass at submodule path).
   Codex's diagnosis is the stronger one technically; Claude's is the more user-facing one (depth-limit policy). Both should be answered.

4. **Stale-result protection emphasis.**
   - **Codex:** Calls out the rapid-cd race explicitly: OSC 7 reports cwd A → resolver A starts → user/agent immediately `cd`s to B → resolver B starts and returns → resolver A returns *later* and overwrites B. Requires per-surface generation tokens and expected-cwd checks. Cites the existing `TabManager` git probe as the pattern to follow.
   - **Claude:** Implicitly covered under "reuse the existing snapshot infrastructure" (which already has generation-keyed cancellation), but does not enumerate the specific race.
   Codex's framing is more actionable for the delegator.

5. **Localization scope.**
   - **Codex:** Explicitly calls out that new Settings strings must use `String(localized:defaultValue:)`, `Resources/Localizable.xcstrings` needs an English entry, and the project policy expects a translation pass across six locales. Adds this to the readiness criteria.
   - **Claude:** Does not mention localization at all.
   This is a real Codex-only catch and aligns with the c11 CLAUDE.md policy.

6. **Branch-name length handling.**
   - **Codex:** Real git branch names can exceed 64 characters and contain inconvenient characters. Should the resolver truncate, the projection truncate, or should the 64-char constraint be raised?
   - **Claude:** Does not address.

7. **OSC 7 handler synchronicity audit.**
   - **Claude:** AC10's "no `git` Process invocation on main" doesn't catch the case where the handler is on-main and *synchronously waits* on a Task-detached result. Wants the criterion strengthened to "the OSC 7 handler returns synchronously without awaiting the resolver."
   - **Codex:** Does not address with this level of specificity (Codex covers stale results, Claude covers the on-main wait).

8. **Hot-path audit scope (`TabItemView`).**
   - **Claude:** Notes the new chip will likely be rendered inside `TabItemView`, which is typing-latency-sensitive via its `Equatable` body-skip. Wants `TabItemView`'s body and `Equatable` added to the AC11 audit, or chip data routed through pre-computed state.
   - **Codex:** Does not surface this c11-specific tripwire.

9. **Rollback lever.**
   - **Claude:** What happens if AC20 (no typing-latency regression) fails post-merge? Names this as a missing rollback policy and recommends "Settings toggle defaults to off via a code change shipped in the next nightly."
   - **Codex:** Does not address.

10. **The "alternatives considered" decomposition.**
    - **Claude:** Frames four major architectural choices (canonical key vs sidebar row extension; new resolver vs extension of existing snapshot; bundle C+D vs ship C then D; submodule two-row vs single row vs leaf-only) and reaches a per-choice recommendation. Recommends *merging* the new resolver with the existing snapshot.
    - **Codex:** Frames four alternatives (extend existing row; runtime model with optional mirror; full canonical implementation; ship chips without color) and recommends the **runtime-model-first** path.
    Both decompositions are useful and largely non-overlapping.

---

## 3. Unique Insights (Surfaced by Only One Model)

### Claude-only insights

1. **`Sources/Sidebar/` doesn't exist either.** BUILDPLAN says chip rendering lives there; the repo has chip code across `AgentChip.swift`, `AgentChipBadge.swift`, and large spans of `ContentView.swift`. The delegator following the plan literally will not find what they're looking for. Same shape as the test-path bug but for source code.
2. **PR enrichment regression risk.** The existing snapshot calls `gh pr view` to resolve PR number/state. The new resolver doesn't. If the new chips *replace* the existing row, PR pills go away. If they coexist, there are two git pipelines per panel.
3. **Dirty-marker regression risk.** The existing row shows a dirty indicator; the new chip's render-rules table doesn't. Decide: preserve via `branch: feature/foo •` or accept the loss.
4. **Cache TTL should be dropped entirely.** Claude argues against any timer-based invalidation — replace with cwd-change + `.git/HEAD` mtime change + explicit `c11 metadata refresh` socket command. (Codex agrees the cache key is wrong but doesn't take a position on whether timer-based TTL should exist.)
5. **`TabItemView`'s `Equatable` body-skip is a typing-latency tripwire** for any new data added to the workspace row.
6. **The Refined SPEC's explicit "where conflicts with original ticket text exist, refined wins" sentence is a strength.** Many planning artifacts let the two versions silently coexist and the implementer picks whichever they noticed first.
7. **Rollback policy is missing.** No code-level "default off in nightly" path if AC20 fails post-merge.

### Codex-only insights

1. **Sidebar aggregation rule is undefined and load-bearing.** A workspace contains multiple surfaces and panes. The plan does not specify whether the chip renders for the focused surface only, for every surface, for all pane tabs, or as an aggregate summary. If the implementation reads canonical metadata for the focused surface, the operator *still cannot see non-focused pane worktrees* — which is the original product complaint.
2. **`SurfaceMetadataStore` feeds snapshots.** Writing `worktree`/`branch` to that store will persist them unless an explicit exclusion is added. The plan says "do not persist" but does not define the mechanism.
3. **Stale-async race is explicit and named.** OSC 7 → resolver A → cd → resolver B → resolver B returns → resolver A returns late and overwrites. Requires per-surface generation tokens (the existing probe already does this; reuse it).
4. **Localization is missing from the plan entirely.** New Settings strings need `String(localized:defaultValue:)`, an English entry in `Resources/Localizable.xcstrings`, and a six-locale translation pass per project policy.
5. **Long branch names (>64 chars) are not addressed.** Resolver truncates, projection truncates, or constraint is raised — pick one.
6. **`.git` is often a file, not a directory** (linked worktrees, submodules). The plan's test/validation idea of mutating `.git/HEAD` will be the wrong file or nonexistent in exactly the cases this ticket is about. Use `git rev-parse --git-path HEAD`.
7. **The submodule command sequence has a real bug.** `--show-toplevel` from a submodule cwd returns the submodule root, not the superproject. Two-row rendering needs a deliberate two-pass algorithm.
8. **Source-precedence ordering question.** `explicit > declare > osc > derived > heuristic` is mechanically fine, but `osc` currently means terminal title OSC writes. It's odd for OSC to outrank derived `branch`/`worktree` unless arbitrary `source=osc` writes remain allowed. Worth stating that "source precedence is global, but only internal writers use derived."
9. **Suggested Plan Patch (concrete one-paragraph BUILDPLAN insert)** that, if adopted, would remove most of the implementation ambiguity without changing the product decision.
10. **Remote workspaces / SSH surfaces** — should the resolver run local `git`, skip entirely, or use remote-reported shell-integration data only? Edge case but real.
11. **Bare repository policy.** Should bare repos always omit chips even if git can report a branch?
12. **Operator-facing-only vs Lattice-readable.** Does the operator want external consumers like Lattice to read `worktree`/`branch`, or is the whole value of this ticket visual/operator-facing? This is the question that resolves whether canonical-metadata-vs-runtime-model is the right call.

---

## 4. Consolidated Questions for the Plan Author

The two reviews produced ~38 raw questions (Claude: 18, Codex: 20). The consolidated, deduplicated, numbered list:

### A. Integration with existing infrastructure (highest-leverage)

1. **Resolver consolidation.** Does the new resolver subsume `TabManager.initialWorkspaceGitMetadataSnapshot`, run alongside it, or merge with it? Claude's recommendation: merge. Codex's recommendation: a runtime model that may or may not mirror into the metadata store. The plan must pick.
2. **Existing Branch + Directory row.** Does it stay, get retired, or get rewritten to render via the new chips? If retired, this is a much bigger UI change than the plan implies. If it stays, what differentiates the two surfaces?
3. **Settings toggle reconciliation.** Existing `sidebarShowBranchDirectory` ("Show Branch + Directory in Sidebar", default-on) vs new "Show worktree/branch chips" (default-on). Replace, extend, or coexist? If coexist, what does the operator see as the differentiator?
4. **Dirty-marker preservation.** The existing row shows a dirty indicator; the new chip's render-rules table doesn't. Preserve via `branch: feature/foo •` or accept the regression?
5. **PR enrichment preservation.** Existing snapshot runs `gh pr view` for PR number/state. New resolver doesn't. Preserve, drop, or accept two parallel pipelines?
6. **Reuse of existing probe infrastructure.** Should the resolver reuse `TabManager`'s `runGitCommand`-style runner with timeout/failure handling and generation-keyed cancellation, or introduce a separate resolver/cache?

### B. Metadata model and persistence

7. **Canonical metadata vs runtime-only.** Are `worktree`/`branch` true canonical metadata keys visible through `c11 get-metadata`, or sidebar-only derived UI state? (This is the Claude-vs-Codex axis; the plan must pick.)
8. **Persistence policy.** If canonical, should `derived` values persist in session/workspace snapshots? If not, where exactly does snapshot capture filter them out?
9. **`source=derived` write policy.** Should socket/CLI clients be allowed to write `source=derived`, or is it internal-only? If the parser accepts it, the spec's "derived is not agent-written" claim is false.
10. **Source-precedence semantics.** `explicit > declare > osc > derived > heuristic` — is OSC outranking derived `branch`/`worktree` intentional? Document the practical rule (e.g., "source precedence is global, but only internal writers use derived").
11. **Clear-on-stale behavior.** How are derived keys cleared when cwd leaves a repo or a surface closes?

### C. Resolver correctness

12. **Cache key.** Replace `.git/HEAD` mtime with resolved git paths via `git rev-parse --git-path HEAD`. Confirm.
13. **Stale-async guard.** Require per-surface generation tokens + expected-cwd check before applying resolver results. Confirm.
14. **Cache invalidation triggers.** Drop the 30-second TTL? Use cwd change + resolved HEAD/ref mtime change + explicit `c11 metadata refresh` socket command only?
15. **OSC 7 handler synchronicity.** Strengthen AC10 to "the OSC 7 handler returns synchronously without awaiting the resolver" (catches the on-main `await`-on-result case, which AC10's current wording misses).
16. **Submodule two-pass algorithm.** Define explicitly: outer pass at superproject path (`--show-superproject-working-tree` + run again from that path), inner pass at submodule path; how to compute submodule display name; how to represent detached/missing branch independently for each row; cache invalidation on both HEAD files.
17. **Submodule nesting depth.** c11 has `ghostty` and `vendor/bonsplit`. If sub-submodules exist, render three rows, cap at two, or show only outermost + leaf?
18. **Branch text length.** Branch names can exceed 64 chars. Does the resolver truncate, the projection truncate, or is the constraint raised? Whichever — the resolver must not fail to render long names.

### D. Sidebar rendering model

19. **Multi-surface aggregation.** A workspace contains multiple surfaces. Does the sidebar show focused surface only, all visible surfaces, all pane tabs, or an aggregate summary? Without this answer, the chip model and submodule two-row layout may need to be workspace-level display models, not per-surface canonical metadata values.
20. **`TabItemView` hot-path scope.** The chip will likely be rendered in the workspace row's body. Add `TabItemView`'s body and `Equatable` conformance to the AC11 audit, or route chip data through pre-computed state so `TabItemView` doesn't read it from `@EnvironmentObject`.

### E. Color hint (Option D)

21. **Palette owner.** Who picks the 8–12-color palette — the delegator, or the operator before delegator spawn? Bind to which theme-system primitive so colors stay correct across Light/Dark slot switches?
22. **Hash collision behavior.** Two parallel worktrees that hash to the same color — accept silently (cwd path is in the chip text), apply an in-workspace tiebreaker like `(hash + index) mod N`, or guarantee non-collision within a displayed set?
23. **AC4 test determinism.** Replace "with high probability" with a deterministic test using known-distinct inputs that don't collide for the chosen palette.
24. **Dimming primitive.** "15–25% alpha" applied how? Alpha multiplier on the chip's existing color, a different `ThemeKey`, blend with background? Must remain correct across Light/Dark theme slots.

### F. Edge cases and platform

25. **Deleted-branch worktree.** What exact user-visible branch text is expected — empty, `(no branch)`, the stale symbolic name, or something else?
26. **Submodule label.** Path from superproject root, basename, `.gitmodules` name, or something else?
27. **Basename collisions.** Two visible worktrees with the same basename — same text + different color sufficient, or disambiguate text?
28. **Bare repository.** Always omit chips even if git can report a branch, or render?
29. **Remote / SSH surfaces.** Run local `git` resolution, skip entirely, or use remote-reported shell-integration data only?
30. **External consumers.** Does the operator want Lattice or other external readers to consume `worktree`/`branch` via the socket, or is this entirely operator-facing visual? (This question, more than any other, resolves whether canonical metadata or runtime-only is the right model.)

### G. Plan artifacts and execution discipline

31. **Test source location.** `c11Tests/<NewFile>.swift` with target membership in `c11LogicTests` (current repo layout) vs `Tests/c11LogicTests/<NewFile>.swift` (what the plan says, which doesn't exist as a directory).
32. **Source location for chip rendering.** Plan says `Sources/Sidebar/`, which doesn't exist. Existing chip code is in `Sources/AgentChip.swift`, `Sources/AgentChipBadge.swift`, and `Sources/ContentView.swift`. Create new directory or extend in place?
33. **Localization.** New Settings strings need `String(localized:defaultValue:)`, an English entry in `Resources/Localizable.xcstrings`, and a six-locale translation pass per project policy. Add to plan or treat as closeout?
34. **Rollback lever.** If AC20 (no typing-latency regression) fails post-merge, what's the code-level rollback path (e.g., Settings toggle defaults to off in next nightly)?
35. **Result Validator scope.** Does the Validator audit the integration-map answers (questions 1–6 above) and localization, or only the static AC rows? If not, who does?
36. **Pre-merge projection test for submodule.** Are post-merge smoke checks enough for the visible two-row submodule layout, or should a pre-merge projection test cover the exact row model?
37. **Deletion/migration scope.** If the existing branch row is being deleted, does that touch `WorkspacePullRequestSidebarTests` or other tests against `panelGitBranches`? Are those updates in scope?

---

## 5. Overall Readiness Verdict (Synthesized)

1. **Synthesized verdict: Ready to execute with mandatory revisions in the delegator's plan phase, NOT in code.**
   This sits between Claude's "ready, just produce an integration map" and Codex's "needs revision before execution." The revisions are non-negotiable, but the lattice-orchestrator workflow's Phase 3 (delegator reads repo and produces refined plan) is the appropriate gate — so long as the orchestrator ensures the delegator does not start coding until the questions in Section 4.A, 4.B, and 4.C are answered in the refined plan artifact.

2. **The core architecture survives.** Both reviewers agree the `derived` precedence-tier extension, the pure-projection seam, the edge-case table, and the hot-path discipline are all correctly shaped. None of the revisions require redesigning the plan; they require *specifying* details the plan currently leaves ambiguous.

3. **Mandatory before coding starts (consensus across both models):**
   - Integration map covering the existing `TabManager` snapshot, `panelGitBranches`, `panelDirectories`, Branch + Directory row, and `sidebarShowBranchDirectory` toggle (Section 4.A).
   - Decision on canonical-metadata vs runtime-only model, with persistence rule and `source=derived` write policy (Section 4.B).
   - Corrected cache key (resolved git paths, not `.git/HEAD`), stale-async generation guard, OSC 7 synchronicity rule, two-pass submodule algorithm (Section 4.C).
   - Sidebar multi-surface aggregation decision (Section 4.D Q19) — this one is load-bearing and surprisingly absent from the plan.
   - Fix the wrong file/directory paths (`Tests/c11LogicTests/`, `Sources/Sidebar/`) so the delegator doesn't create directories the project doesn't use and trigger pbxproj normalization churn.
   - Add localization to the plan (xcstrings entry + six-locale translation pass).

4. **Strongly recommended before coding starts (single-model insights worth adopting):**
   - Add `TabItemView`'s body/`Equatable` to the AC11 hot-path audit (Claude).
   - Strengthen AC10 to "OSC 7 handler returns synchronously without awaiting the resolver" (Claude).
   - Tighten AC4 from probabilistic to deterministic with known-distinct inputs (both).
   - Name a rollback lever for AC20 failure post-merge (Claude).
   - Decide branch-name truncation policy (Codex).
   - Decide remote/SSH surface behavior (Codex).
   - Decide submodule nesting depth policy (Claude).

5. **Acceptable to defer to PR-time iteration:** the exact color palette, the exact dim percentage, the exact submodule label format. These are review-iteration-friendly surfaces and bundling C+D is fine as long as the operator understands D's palette is the soft iteration surface and C is the hard one.

6. **Correctly out of scope and should stay out:** sidebar tab grouping by worktree, snapshot persistence of derived keys (assuming the canonical-vs-runtime decision lands on "runtime" or "canonical-but-non-persistent"), cross-process visibility, markdown-pane visibility.

7. **Final disposition:** Approve the plan to enter delegator Phase 3 (plan refinement). Require the refined plan artifact to contain (a) the integration map, (b) the canonical-vs-runtime decision with persistence rule, (c) the corrected resolver/cache/submodule design, and (d) the sidebar aggregation rule **before** the delegator starts coding. The orchestrator (or Result Validator) should audit the refined plan against this synthesis before unlocking implementation.

---

## Coverage Caveat

This synthesis represents consensus across **2 of 3** intended standard reviewers. Gemini was rate-limited and produced no review. Where Section 1 (Agreements) reflects 2 of 2 models, treat those findings with normal high confidence. Where Section 3 (Unique Insights) reflects 1 of 2 models, the corroboration ratio is weaker than a typical 3-model synthesis would provide; weight those findings against the plan author's own judgement rather than treating them as quorum-validated.
