# Plan Review — C11-104 (Standard)

- **Plan:** `c11-104-plan` (Surface worktree + branch as derived canonical metadata chips in the sidebar)
- **Model:** Claude (Opus 4.7)
- **Lens:** PlanReview-Standard — expert architectural read, not a checkbox pass
- **Timestamp:** 2026-05-18T22:28

---

## Executive Summary

This is a **fundamentally sound plan that solves a real, well-named problem with a small, well-scoped, hot-path-aware design**. The bundle (Option C + D) is the right unit; the precedence-tier extension (`derived` between `osc` and `heuristic`) is the *correct* place to add this rather than birthing a new render path. The hot-path discipline is repeated in three places (SPEC, BUILDPLAN, AC11) which is exactly proportional to the typing-latency risk it carries.

What is weak is mostly **integration with the c11 code that already exists**, not the design itself. The plan reads like a greenfield "add a resolver, add a chip, add a toggle" plan, but c11 already has:

- a `panelDirectories` + OSC-7-driven cwd update path (`Workspace.updatePanelDirectory`, `TerminalView.hostCurrentDirectoryUpdate`),
- a per-panel `SidebarGitBranchState` ("branch + isDirty") *already* shown in the sidebar's "Branch + Directory" row,
- an `InitialWorkspaceGitMetadataSnapshot` probe runner with delay schedule, dedicated background queue, generation-keyed cancellation, and PR enrichment (`TabManager.scheduleInitialWorkspaceGitMetadataRefresh` + `applyWorkspaceGitMetadataSnapshot`),
- a `Settings → Sidebar → Show Branch + Directory` toggle (`@AppStorage("sidebarShowBranchDirectory")`, default `true`) that already gates the existing branch row.

The plan does not name any of these — neither to reuse them, deprecate them, nor disambiguate the new toggle from the existing one. This is the single most important gap. If the delegator builds the resolver fresh without seeing the existing probe runner, the result will be two parallel git-resolution pipelines per panel writing into different render paths, and an operator with two near-identical "show git info in sidebar" toggles in Settings. Both are recoverable in review, but cheaper to flag now.

**Verdict:** Ready to execute *after* one round of "stitch this to the code that already exists" clarification. The core architecture survives that pass intact; the integration map needs a paragraph that the delegator-as-planner is now responsible for producing.

## The Plan's Intent vs. Its Execution

**Intent (correctly named):** Operators running parallel agents across many worktrees can't see at a glance which worktree a pane is in. Make it glanceable in the sidebar. Don't make the agent write it (then non-c11-aware processes lose the signal). Don't put it in the title (constrained real estate). Use the existing canonical-keys infrastructure so the chip joins the family naturally.

**Execution (mostly faithful, two drifts):**

1. *Drift toward "derived metadata key" vs "extension of the existing sidebar branch row."* The plan picks the former. That's defensible — it produces a uniform render surface — but it leaves a question unanswered: do `branch` (the new canonical key) and the existing sidebar branch row (which reads `panelGitBranches[panelId].branch`) coexist, or does one replace the other? If both render, the operator sees duplicate info. If the new one replaces the old, the plan should say so and accept that AC18 becomes a regression-test surface (the existing row's behaviors — dirty marker, PR pill, vertical layout — need to be preserved or explicitly retired).

2. *Drift in the test-target path.* The plan repeatedly says `Tests/c11LogicTests/<NewFile>.swift`. In this repo the `c11LogicTests` target's source files live under `c11Tests/` (shared directory, target-membership distinguishes them). The path in the plan does not exist as a directory. AC15 ("Tests live in `c11LogicTests`") is correct as a *target* claim; the file path is wrong. Minor, but a delegator following the plan literally will create a new top-level directory the project doesn't use.

Everything else (the dialogue decisions, the render-rule table, the resolution sequence, the cache-key shape) is well-mapped to intent. The hot-path callouts are correct and in the right places.

## Architectural Assessment

### The right decomposition for this problem

Three modules: resolver (off-main, cached), chip projection (pure, `Resolver.Output → ChipModel`), renderer (mounts chip on existing sidebar surface). This is the canonical *pure-function-in-the-middle* shape and it's what the plan describes. AC10/AC11/AC12 audit exactly this seam. Good.

### Two structural questions the plan does not answer

**Q1 — Where does the resolver live, and what is its single source of truth?**

c11 already has *two* places that resolve git context:

- `TabManager.initialWorkspaceGitMetadataSnapshot(for:)` — nonisolated static, runs `git branch --show-current` + `git status --porcelain` + a `gh pr view`. Updates `panelGitBranches`.
- The new C11-104 resolver — runs `git rev-parse --show-superproject-working-tree` + `--show-toplevel` + `--git-common-dir` + `git symbolic-ref --short HEAD`. Updates the new canonical-key metadata.

These overlap. The new resolver returns the branch; the existing snapshot also returns the branch. If they run independently, you have two queues, two caches, two debouncers, and two ways for them to disagree (e.g., one fires for a directory change, the other for a sidebar refresh, the operator sees the chip flicker between two values). The plan should answer: does the new resolver subsume the existing snapshot? Does it run *in addition* and feed the canonical keys while the existing snapshot continues to feed `panelGitBranches`? Or do we merge — let one resolver produce both shapes (legacy `SidebarGitBranchState` for the old row, new canonical-key blob for the new chips)? **Merge is the right answer**, but the plan should commit to it.

**Q2 — Is the new toggle a third toggle, or does it replace the existing one?**

`@AppStorage("sidebarShowBranchDirectory")` already controls "Show Branch + Directory in Sidebar," default on, gates the existing per-panel branch row. The plan adds "Settings → Sidebar → Show worktree/branch chips," default on, single master toggle. Two toggles named almost identically and both default-on will confuse the operator. The plan should commit to one of:

(a) The new toggle *replaces* the old one (and the existing row is retired — most disruptive but cleanest end state).
(b) The new toggle *extends* the old one (one toggle gates both the existing row and the new chips; the new chips are an aesthetic refresh, not an additive surface).
(c) The new toggle is genuinely separate because the existing row stays for legacy users (rare; in that case the new toggle's wording must clearly differentiate, e.g., "Show worktree color hint and submodule context").

The dialogue picked "single master toggle," but didn't notice the pre-existing toggle. This is the kind of thing a delegator should be told to surface in plan phase, not solve in code.

### The submodule decision is correct but underspecified

Two stacked rows for submodule context is the right call. The git-engineering instinct is "always resolve to superproject," and the plan rightly inverts that — when inside `ghostty/macos/Sources/...` the operator wants to see *both* "c11/main" and "↳ ghostty/<branch>" because they're often working on a coordinated change across both. Good.

What's not specified: **how deep does this nest?** c11 itself has at least two submodules (`ghostty`, `vendor/bonsplit`). What if someone navigates to a submodule-within-a-submodule? Three rows? Truncate at one level? The plan should say "one level of nesting; deeper nesting collapses to the immediately-enclosing superproject + the leaf submodule." That's not a hard call but the delegator shouldn't have to invent it.

### The color-hint choice is well-reasoned but the palette is hand-waved

Hash function: "FNV-1a or SHA-256 truncated; pick whichever already exists in the codebase." Palette: "8–12 c11-themed; delegator picks during plan; flag for operator review." This is the kind of "do whatever, we'll review later" that produces lots of friction at PR time. Two specific risks:

- **Light/Dark theme readability.** The colored dot has to contrast against the chip's background in *both* theme slots. 8–12 hand-picked colors is plausible but not trivial. A delegator who picks "vivid for dark" will discover at PR review that two of them disappear on Light, and the cycle restarts.
- **Hash distribution.** With ~10 colors and a small handful of active worktrees, birthday-paradox collisions kick in fast. Two parallel worktrees with the same color defeats the entire signal. The plan does not address what to do when two adjacent panes hash to the same color. Options: accept collisions (the cwd path is right there in the chip text, so it's recoverable), or assign colors in workspace-order (`hash mod N` then shuffle-on-collide). Either is fine; the plan should pick one.

### What this plan does not have to solve, and correctly leaves out

- Sidebar tab grouping by worktree (Option E). Correctly deferred — that's a much bigger UI surgery.
- Persistence of `worktree`/`branch` in snapshots. Correctly deferred — re-derivation on resume is the right answer.
- Cross-process visibility (markdown panes, etc.). Correctly deferred.

## Is This the Move?

**Yes, with the caveats above.** The operator's complaint ("two parallel orchestrations, can't tell which pane is which") is real and recurring. The fix is a small, localized chip-render change leveraging metadata already being computed. The risk surface is well-bounded (typing-latency-sensitive paths are explicitly out of the diff). The work is shippable in one PR by one delegator.

The single bet I'd flag for sanity-check: **bundling C+D in one PR.** The dialogue produced this decision and there's a defensible logic — the color hint is small, it ships alongside, no harm. But Option D (the color hint) has the *highest visual-design risk* in the plan (palette choice, theme contrast, collision behavior) and the *lowest pure-engineering risk*. If the operator hates the color choice at PR review, the engineering work is already done and the only cost is design iteration. So bundling is fine, but it means the delegator's PR should land C **complete** (resolver, chips, settings, tests, docs) even if D needs another round on the palette. The acceptance criteria already isolate D (AC4 is dot-specific), so this should naturally happen — worth being explicit about in the PR template that D's palette is the soft surface and C is the hard surface.

The one bet I'd *not* take: validating "no typing-latency regression" by AC20's "type a 100-char paste-or-burst and compare subjectively." That's a fine smoke test but it won't catch the regression you actually care about. The regression you care about is "the OSC 7 handler blocks at `git rev-parse` while the agent is mid-burst and the next keystroke stalls 100ms." A *better* smoke-test gate: with a tagged build, instrument the OSC 7 handler with a `signpost` or a log line, drive a heavy `cd`-around script in a pane, and confirm the handler completes synchronously in <1ms while the resolver work fires on the background queue. The plan's AC10 hand-waves this ("reviewer confirms no `git` Process invocation on main") — that's a static-diff audit that misses the case where the handler is on-main but synchronously *waits* on the off-main result. The plan should explicitly disallow `DispatchQueue.global().sync` and `Task` -then-`await`-on-result patterns in the handler.

## Key Strengths

1. **`derived` precedence-tier extension is the *correct* place to add this.** Reusing the existing `MetadataSource` precedence chain — instead of inventing a parallel render path — is exactly the kind of design discipline that keeps c11's metadata layer small and predictable. Future derived keys (e.g., last-commit timestamp, ahead/behind counter) drop in for free at the same tier. AC13 audits this precisely.

2. **Pure-projection seam is testable.** `MetadataValue → ChipModel` as a pure function makes AC3, AC4, AC9 trivial unit tests. This is the right shape for c11LogicTests (which can't host an app). The plan correctly aligns on this.

3. **Edge-case table is exhaustive.** Detached HEAD, deleted branch, bare clone, not-in-git, submodule, same-basename collisions, concurrent `.git/HEAD` edit — this is the list a senior engineer would have written. Most "show git info in UI" features ship without thinking about half of these and discover them in production.

4. **Hot-path discipline is named in three places.** SPEC + BUILDPLAN + AC11 all repeat it. This redundancy is *appropriate* because typing-latency regressions are the single most painful c11 bug class to recover from once shipped (you have to chase ghosts through profilers). Better to repeat than to assume the delegator read the right paragraph.

5. **The dialogue's outputs are clean.** The Refined SPEC explicitly says "where these conflict with the original ticket text above, these win." That single sentence — naming the conflict and resolving it explicitly — is worth a lot. Many planning artifacts let the two versions silently co-exist and the implementer picks whichever they noticed first.

6. **Result Validator is correctly enabled.** Typing-latency + new precedence tier + cache correctness is exactly the surface area that justifies a fresh-eyes audit. Pretty much every other delegated ticket can skip the validator, but this one earns it.

## Weaknesses and Gaps

1. **No reuse map for existing infrastructure** (named at the top of this review). The plan reads as if c11 had no git resolution, no cwd-update path, and no Settings toggle for the existing branch row. All three exist. The delegator's plan phase needs to either reuse them, replace them, or document the parallel.

2. **`Tests/c11LogicTests/` path is wrong.** Files live in `c11Tests/` (target membership decides logic vs host-required). AC15 is correct on target; the path in BUILDPLAN's "Files" section and AC1–AC9's "Tests/c11LogicTests/<NewFile>.swift" is wrong. Small but: a delegator who pattern-matches creates a directory that the project doesn't use, then the Xcode project file rewrites itself (pbxproj gem normalization, per CLAUDE.md) and the diff bloats.

3. **`Sources/Sidebar/` doesn't exist either.** The BUILDPLAN says chip rendering lives in `Sources/Sidebar/`. The repo has chip rendering across `AgentChip.swift`, `AgentChipBadge.swift`, and big spans of `ContentView.swift` (the workspace row view). There's a `Sources/Chrome/` and a `Sources/Panels/` but no `Sidebar/`. Again — small, but a delegator following the plan literally will not find what they're looking for.

4. **The dimming rule is fuzzy.** "15–25% — exact value the delegator's call, with operator review on PR." This is reasonable but produces a guaranteed PR-review iteration round. Tighten to a single value (operator-picked) before the delegator starts, or accept the iteration cost. Bigger issue: "dimmed" needs to be defined in terms of the c11 theme system (alpha multiplier? a different `ThemeKey`? blend with background?) so the chip stays correct when the operator switches Light↔Dark.

5. **AC4 "with high probability — use known-distinct inputs" is hedged.** A deterministic hash with deterministic inputs is testable deterministically. The "high probability" hedge suggests the delegator may pick a hash and palette where two specific known worktree paths in the test collide. Pick a hash that gives non-colliding outputs for at least the two test inputs and the test is fully deterministic. The hedge shouldn't be there.

6. **AC10's "no `git` Process invocation on main" doesn't catch the synchronous-wait case.** A handler can be on-main, dispatch the git work to a global queue, and then call `.wait()` or `await` on the result, blocking the main thread anyway. The audit needs to be "the OSC 7 handler returns synchronously without waiting for the resolver" not "no Process is constructed on main."

7. **No mention of the existing `panelGitBranches[panelId].isDirty` signal.** The current sidebar branch row shows a dirty marker. The new chip text is `branch: feature/foo` (no dirty marker shown in the render-rules table). If the new chip replaces the old row, dirty-marker visibility regresses. The plan should either preserve dirty (`branch: feature/foo •` or `branch: feature/foo*`) or explicitly accept the loss.

8. **No mention of PR enrichment.** The existing snapshot also resolves a PR number/state via `gh pr view`. The new resolver doesn't. If the new chips coexist with the existing row, fine. If they replace it, PR display regresses too. Same shape of question as dirty.

9. **Cache-invalidation TTL is hand-waved.** "Coarse interval (~30s post-checkout for branch renames)" — this is exactly the kind of TTL that, once shipped, the operator hits an edge case in ("I renamed the branch and the chip is wrong for 30 seconds") and someone has to come back and tune. Better: invalidate on cwd change *and* on `.git/HEAD` mtime change *and* on an explicit `c11 metadata refresh` socket command. Drop the timer-based invalidation entirely.

10. **AC18–AC20 are correctly post-merge but the plan provides no rollback gate.** If AC20 (typing latency) fails post-merge, what happens? Revert? Toggle off by default? The plan should name the rollback lever: "If a typing-latency regression is observed post-merge, the Settings toggle defaults to off via a code change and ships in the next nightly." Otherwise the operator is stuck with a regression and a slow-moving fix.

11. **Submodule-detection sequence implicitly assumes git is on PATH.** It is, in practice, but a `runCommand`-style approach (which the existing TabManager uses) handles process failure cleanly. The plan should say "use the existing `runGitCommand`-style runner with timeout + failure handling, not a new `Process()` invocation pattern." (Tied to point 1: reuse the existing infrastructure.)

12. **AC11 audits two specific methods by name but the hot-path family is bigger.** `TabItemView`'s `Equatable` conformance and `TerminalSurface.forceRefresh()` are both called out in `CLAUDE.md` as typing-latency-sensitive. AC11 only names `TerminalSurface.forceRefresh()` and `WindowTerminalHostView.hitTest()`. The chip is rendered in a sidebar tab — that path likely involves `TabItemView`. The plan should add `TabItemView`'s body and its `Equatable` to the AC11 audit (or explicitly route the new chip rendering through pre-computed state so `TabItemView` doesn't read it from `@EnvironmentObject`).

## Alternatives Considered

### Major architectural choice 1 — Canonical metadata key vs Extension of existing sidebar git row

- **Plan's choice:** Add `worktree` and `branch` as canonical metadata keys; render via the canonical-keys chip family.
- **Alternative:** Extend `SidebarGitBranchState` to carry worktree context; modify the existing branch+directory row to render with the new chip styling; no new canonical keys.
- **Trade-off:** The plan's choice gives a uniform render surface (`role`, `status`, `task`, `model`, `branch`, `worktree` all rendered the same way) and a uniform precedence model. The alternative is structurally simpler (no new precedence tier needed, no new keys to document) but creates a *second* render surface for git context that doesn't match how `role`/`status`/`task`/`model` are rendered. **Plan's choice is better** — uniformity wins when the cost is one precedence tier and two metadata keys.

### Major architectural choice 2 — Resolver as new module vs Extension of existing TabManager probe

- **Plan's choice:** New off-main resolver triggered on OSC-7 cwd update.
- **Alternative:** Extend `TabManager.initialWorkspaceGitMetadataSnapshot(for:)` to return worktree + superproject + submodule context alongside branch + isDirty + PR; feed both legacy `SidebarGitBranchState` and new canonical-key blob from the same snapshot.
- **Trade-off:** The plan's choice is cleaner from a "module per concern" standpoint. The alternative cuts the queue/cache/debouncer to one. **Alternative is probably better** for c11 specifically — there's only ever one git-resolution pipeline per panel, and consolidating prevents the two-pipeline-disagree class of bug. If the plan stays with a new resolver, it should be explicit that the legacy snapshot path is now feeding the canonical-key blob *as well as* `panelGitBranches`, not running independently.

### Major architectural choice 3 — Bundle C+D vs Ship C, then D

- **Plan's choice:** Bundle.
- **Alternative:** Ship C first; D as a 1-day follow-up after operator has lived with C for a day or two.
- **Trade-off:** Bundling is faster and simpler in PR-count terms. Shipping separately gives the operator a chance to discover whether C alone is enough (D adds visual cost — more pixels of color in the sidebar — and it's plausible that the chip text alone is sufficient signal). **Plan's choice is fine** but the operator should be aware that "we'll just turn D off if you don't like it" is technically supported via the master toggle, which gates *both* (not a per-feature toggle). If the operator wants only C, they have to toggle off both worktree chip and branch chip. A small concession would be: ship the master toggle, but also ship a hidden `defaults write` key for "color-hint enabled" so iteration is cheaper. The plan considered and rejected per-chip toggles; this is consistent with that decision and probably correct.

### Major architectural choice 4 — Submodule rendered as second row vs Single row with both contexts

- **Plan's choice:** Two stacked rows (superproject on top, submodule indented).
- **Alternative A:** Single row, `c11/main ↳ ghostty/feat/foo`, all on one line.
- **Alternative B:** Show only the leaf context (just the submodule), like every other git tool.
- **Trade-off:** A is denser but bad when either name is long (sidebar width is finite). B is the upstream convention but defeats the c11 use case (the operator *needs* to know they're in the c11 worktree even when they `cd ghostty/macos`). **Plan's choice is correct**, and the upstream-convention break is justified by the operator-workflow context. Worth noting in PR body that this is a deliberate divergence.

## Readiness Verdict

**Ready to execute with one constraint:** the delegator's plan phase output must include an "Integration map" section that names the existing infrastructure to reuse, replace, or coexist with, *before* the delegator starts coding. Specifically:

- How does the new resolver relate to `TabManager.initialWorkspaceGitMetadataSnapshot` / `scheduleWorkspaceGitMetadataRefresh` / `applyWorkspaceGitMetadataSnapshot`?
- How does the new chip relate to the existing `SidebarGitBranchState` render in the branch+directory row?
- How does the new Settings toggle relate to `@AppStorage("sidebarShowBranchDirectory")`?
- Where do new test files actually live (`c11Tests/` directory, `c11LogicTests` target membership), since `Tests/c11LogicTests/` doesn't exist?
- What's the chip-render integration with `TabItemView`'s `Equatable` body-skip (typing-latency-sensitive)?

If the delegator answers those before starting, the rest of the plan is solid and the AC table is the right gate. Without those answers, the implementation drifts toward parallel pipelines and a confused Settings panel.

The plan does NOT need a re-architecture; it needs a "now stitch this to the code that exists" pass. That can happen in the delegator's plan phase (which is the appropriate moment per the lattice-orchestrator workflow — Phase 3 is when the delegator reads the repo and produces a refined plan).

## Questions for the Plan Author

1. **Reuse vs replace, decision 1:** Does the new resolver subsume `TabManager.initialWorkspaceGitMetadataSnapshot`, run alongside it, or merge with it? My recommendation: merge — extend the existing snapshot to return the new shape and feed both legacy `SidebarGitBranchState` and the new canonical-key blob.

2. **Reuse vs replace, decision 2:** Does the existing "Branch + Directory" sidebar row (gated by `sidebarShowBranchDirectory`, today rendering `panelGitBranches[panelId]`) stay, get retired, or get rewritten to render via the new chips? If retired, this is a much bigger UI change than the plan implies and should be called out in the PR body. If it stays, what differentiates the two surfaces to the operator?

3. **Settings toggle name collision:** The existing `sidebarShowBranchDirectory` toggle is labeled "Show Branch + Directory in Sidebar," defaults to on. The new toggle is "Show worktree/branch chips," defaults to on. What's the differentiator the operator sees in Settings? Should the new toggle replace the old one entirely?

4. **PR enrichment:** The existing snapshot calls `gh pr view` to resolve the PR number/state. The new resolver doesn't. If the new chips replace the existing row, do PR pills go away? If they coexist, you have two git pipelines per panel — is that OK?

5. **Dirty marker:** The existing row shows a dirty indicator. The new chips don't, per the render-rules table. Is that a regression you're OK with, or should the new chip carry a `•` / `*` suffix when dirty?

6. **Test path:** The plan says `Tests/c11LogicTests/<NewFile>.swift`. The actual layout is `c11Tests/<NewFile>.swift` with the file added to the `c11LogicTests` target's `Sources` build phase. Did you mean target membership (which is correct in AC15) and the directory mention is a misstatement, or is the plan calling for a new top-level `Tests/c11LogicTests/` directory?

7. **Sidebar source path:** The plan says chip render lives in `Sources/Sidebar/`. That directory doesn't exist; existing chip code is in `Sources/AgentChip.swift`, `Sources/AgentChipBadge.swift`, and `Sources/ContentView.swift`. Is the delegator expected to create `Sources/Sidebar/` and migrate, or extend in place?

8. **Color palette:** Who picks the 8–12-color palette — the delegator (per BUILDPLAN), or the operator before delegator spawn? If the delegator picks, what theme-system primitive do they bind to so the colors stay correct across Light/Dark slot switches?

9. **Hash collision behavior:** Two parallel worktrees that hash to the same color — accept silently, or apply an in-workspace tiebreaker (e.g., `(hash + index) mod N`)?

10. **Dimming primitive:** "15–25%" alpha multiplier on top of the chip's existing color? A different `ThemeKey`? Blend with background? Whatever's chosen must remain correct when the operator switches theme slots.

11. **Submodule nesting depth:** What happens at sub-submodule depth? c11 has `ghostty` and `vendor/bonsplit` as submodules. If a sub-submodule exists, do you render three rows? Cap at two? Show only outermost + leaf?

12. **Hot-path audit scope:** AC11 names `TerminalSurface.forceRefresh()` and `WindowTerminalHostView.hitTest()`. Should `TabItemView`'s body / `Equatable` also be in scope, since the new chip will likely be read from the workspace row's body during typing?

13. **OSC 7 handler synchronicity:** AC10 says "no `git` Process invocation on main." Should AC10 be strengthened to "the OSC 7 handler returns synchronously without awaiting the resolver," to catch the case where the handler is on-main and synchronously waits on a Task-detached result?

14. **Cache invalidation:** The plan says cache invalidates on cwd change AND on `.git/HEAD` mtime change. The earlier ticket text mentions "30s post-checkout to catch branch renames." Is the TTL still in or out? I'd recommend out — explicit invalidation only.

15. **Rollback lever:** If AC20 (no typing-latency regression) fails post-merge in operator testing, what's the rollback? The Settings toggle defaults to on; flipping a single user's setting is fine, but is there a code-level "default off in nightly" path to land fast if needed?

16. **Result Validator scope:** The plan says the Validator walks only `pre-merge-static` rows and audits "test shape matches the criterion, not whether each test currently passes." Does the Validator also audit the integration-map answers (questions 1–3 above)? If not, who does?

17. **Deletion / migration of the existing branch row:** If the existing row is being deleted, does that touch the existing `WorkspacePullRequestSidebarTests` or other tests against `panelGitBranches`? Are those tests in scope to update, or is the existing row staying and there's no cleanup?

18. **`set-metadata --source derived` from agents:** The new `derived` source is described as "for c11-internal use." Should an agent CLI write with `--source derived` be rejected (`invalid_source` for non-c11 writers), or silently accepted? The existing source enum doesn't have agent-vs-c11 partitioning, so this is a new question.

---

**Bottom line:** Architecturally sound, hot-path-aware, well-tested via the AC table. The reuse-map gap is real but recoverable in the delegator's plan phase. Approve to start, ask the delegator to produce an integration map first, then let the autonomous run proceed.
