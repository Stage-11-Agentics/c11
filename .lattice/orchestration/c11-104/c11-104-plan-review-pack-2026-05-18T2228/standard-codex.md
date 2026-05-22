# C11-104 Plan Review - Standard Codex

PLAN_ID: c11-104-plan  
MODEL: Codex

## Executive Summary

The plan is aiming at the right product outcome: worktree and branch context should be visible without asking an agent or reading orchestration artifacts. The high-level choice to derive from terminal cwd rather than asking agents to self-report is also correct.

I would not hand this plan to a delegator unchanged. The main issue is not the UI idea; it is that the plan blurs three separate systems that are currently distinct in the codebase: per-surface canonical metadata, workspace-level sidebar rendering, and the existing branch/directory telemetry path. That blur creates real risks around persistence drift, duplicated UI, stale async resolver results, and tests that pass while the actual sidebar behavior is wrong.

Verdict: **Needs revision before execution.** It is close, but the delegator needs a sharper architecture for derived runtime state, cache invalidation, submodule resolution, and sidebar integration.

## The Plan's Intent vs. Its Execution

The intent is specific: operators running many panes across many worktrees need to know "which worktree is this pane in?" at a glance. That is a per-terminal-surface question.

The execution drifts toward "add canonical metadata keys that render in the sidebar." In the current app, the left sidebar row is workspace-oriented (`TabItemView` over `tabManager.tabs`), while a workspace can contain multiple surfaces and panes. There is already a branch/directory row that aggregates `panelDirectories` and `panelGitBranches` across ordered panels. The plan does not decide whether the new chips:

- replace the existing Branch + Directory row,
- supplement it,
- render only for the focused surface,
- aggregate all surfaces in the workspace,
- or render somewhere else in pane/tab chrome.

That decision is load-bearing. If the implementation simply reads canonical metadata for the focused surface, the operator still cannot see non-focused pane worktrees. If it aggregates every surface, the chip model and two-row submodule layout need to be workspace-level display models, not just per-surface canonical metadata values.

The other intent/execution mismatch is "derive, don't store" versus "same write path, same precedence model." In this repo, `SurfaceMetadataStore` is the surface manifest path and is also persisted into snapshots/restores. Writing `worktree` and `branch` into that store as ordinary canonical keys will store them unless the implementation adds explicit exclusion logic. The plan says not to persist them, but does not define the mechanism that prevents persistence.

## Architectural Assessment

The strongest architecture would separate the domain model from the metadata transport:

- `GitWorktreeContextResolver`: pure/off-main resolver that returns a typed model.
- `SurfaceGitContextCache`: runtime-only per-surface cache with generation tokens and HEAD-path invalidation.
- `SidebarGitChipProjection`: transforms typed context plus settings/theme into rows/chips.
- Optional metadata bridge only if external socket readers truly need `worktree` and `branch`.

The current plan instead makes the canonical metadata store carry both external agent-authored data and internal derived git context. That may be viable, but only if the plan defines:

1. Whether `source: derived` is accepted over the socket or internal-only.
2. Whether derived keys are excluded from session/workspace snapshot persistence.
3. How derived keys are cleared when cwd leaves a repo or a surface closes.
4. How stale derived writes are prevented after rapid cwd changes.
5. How the existing `panelGitBranches` and `panelDirectories` path will be reconciled.

Without those rules, the implementation is likely to work in a happy-path demo while accumulating stale chips during real multi-agent use.

The resolver design also needs revision. The cache key `(cwd, mtime-of-.git/HEAD)` is not correct for linked worktrees or submodules, where `.git` is often a file pointing elsewhere. The plan should use Git's own path resolution, for example `git rev-parse --git-path HEAD`, then stat that resolved HEAD path. The validation plan currently says to mutate `.git/HEAD`; that will be the wrong file or nonexistent in exactly the worktree/submodule cases this ticket is about.

Submodule handling is under-specified and partly wrong. In a submodule, `git rev-parse --show-superproject-working-tree` identifies the outer worktree, but `git rev-parse --show-toplevel` from the same cwd returns the submodule root, not the superproject root. To produce two rows, the resolver needs an explicit outer pass run at the superproject path and an inner pass run at the submodule path. It also needs a defined way to compute the submodule display name.

## Is This the Move?

Yes, adding glanceable worktree signal is the move. Bundling the colored dot with the chips is probably acceptable because the dot is a projection detail, not a second data model.

The risky bet is making this a canonical metadata feature before proving the derived git context model. Canonical keys are public API, persisted in some paths, exposed through CLI/socket docs, validated through reserved-key rules, and rendered in hot sidebar rows. This raises the blast radius.

I would revise the plan to ship a runtime git-context model first, with a projection into the sidebar. Then decide deliberately whether `worktree` and `branch` should also become socket-visible canonical metadata. If they do become canonical, the plan should state that `derived` is an internal writer source and that persistence excludes derived keys, unless the operator explicitly wants restored stale values.

## Key Strengths

- The plan correctly rejects agent-authored descriptions/titles as the primary mechanism. Derived state should not depend on every agent remembering a convention.
- The hot-path warning is prominent. Calling out `TerminalSurface.forceRefresh()` and `WindowTerminalHostView.hitTest()` is exactly the right kind of project-specific constraint.
- The acceptance criteria are unusually concrete. Temp-dir git repos, detached HEAD, bare clone, deleted branch, submodule, and setting toggle coverage are the right test shape.
- The design keeps Option E, sidebar grouping by worktree, out of scope. That avoids turning a focused visibility fix into a sidebar architecture rewrite.
- Default-on with an opt-out setting fits the operator workflow. This is core signal for this product, not a niche debug display.

## Weaknesses and Gaps

### 1. Derived metadata persistence is unresolved

The plan says "store nothing" while also saying "same write path" and adding a source precedence tier. In the current code, `SurfaceMetadataStore` feeds snapshots and persistence. If derived keys land there, they need explicit pruning from:

- workspace/session snapshot capture,
- restore paths,
- possibly `get-metadata` if derived is supposed to be render-only,
- and stale source sidecars after cwd changes.

If the intent is that `get-metadata --sources` exposes them, then "do not write them to the surface manifest" is false and should be removed. If the intent is render-only, do not model them as canonical metadata keys in the main store.

### 2. The plan conflicts with existing sidebar branch/directory behavior

The repo already has:

- `panelDirectories`,
- `panelGitBranches`,
- `SidebarBranchOrdering`,
- a Branch + Directory setting,
- branch/directory display in `TabItemView`,
- and an off-main git probe in `TabManager`.

The plan does not say whether to reuse, replace, or retire any of this. A delegator could easily add a second branch display beside the existing one, making the sidebar noisier and confusing the settings model. The plan should explicitly map old behavior to new behavior.

### 3. Stale async results are not addressed

"Run off-main" is necessary but not sufficient. The resolver needs per-surface generation tokens or expected-cwd checks before applying results. Otherwise this sequence can render wrong chips:

1. OSC 7 reports cwd A.
2. Resolver A starts.
3. User/agent immediately `cd`s to cwd B.
4. Resolver B starts and returns.
5. Resolver A returns later and overwrites B.

The existing `TabManager` git probe already uses generation/expected-directory checks. The plan should require the same pattern.

### 4. Cache invalidation is wrong for worktrees and submodules

`.git/HEAD` is not a reliable path. The plan should use resolved git paths from Git itself, probably `git rev-parse --git-path HEAD` for each context row. For linked worktrees, also consider that branch refs can live under the common dir while HEAD is a symref in the per-worktree git dir. For branch rename/delete cases, the cache may need to include both HEAD mtime and the referenced ref path mtime/existence.

### 5. Submodule resolution needs a real algorithm

The plan says "resolve to superproject context" in one place, "stacked two rows" in another, and the listed command sequence does not actually compute both contexts correctly. It should define:

- how to detect cwd is inside a submodule,
- how to resolve the superproject worktree path,
- how to resolve the submodule root,
- how to name the submodule,
- how to represent detached or missing branch independently for outer and inner rows,
- and how cache invalidation works for both HEAD files.

### 6. `derived` as a public source tier needs policy

Adding `MetadataSource.derived` to the enum will make it available to parsing paths unless guarded. If CLI/socket clients can write `source=derived`, then agent-written "derived" metadata is possible despite the spec saying derived is not agent-written. If it is internal-only, the socket parser and docs need to reject or omit it. The plan needs to choose.

There is also an ordering question: `explicit > declare > osc > derived > heuristic` is mechanically fine, but `osc` currently means terminal title OSC writes. It is odd for OSC to outrank derived `branch`/`worktree` unless arbitrary `source=osc` writes remain allowed. The practical answer may be "source precedence is global, but only internal writers use derived." That should be stated.

### 7. Tests target path is inconsistent with the repo

The plan repeatedly says tests live under `Tests/c11LogicTests/`. This repo currently has Swift tests under `c11Tests/`, with a `c11LogicTests` target/scheme selecting a subset/target from the Xcode project. The plan should specify the actual source location and target membership, not a nonexistent directory.

### 8. Settings and localization are under-planned

The new Settings string must use `String(localized:defaultValue:)`, and `Resources/Localizable.xcstrings` needs an English source entry. Project policy also expects translation sync for six locales after adding/changing user-facing strings. The plan mentions Settings but not localization or the translation pass.

### 9. Color tests should avoid probabilistic assertions

AC4 says two different worktree paths should produce different colors "with high probability." That is a weak test for a finite palette. If the palette is 8-12 colors, collisions are expected. Test stability should assert same input is stable and that the hash chooses from the palette. If distinct-color behavior is required for same-basename siblings, the algorithm must guarantee collision avoidance within a displayed set, which is a different design than simple hashing.

### 10. Branch text constraints are under-specified

Git branch names can exceed 64 characters and can contain characters that are not convenient for compact chips. The plan says `branch` is `<=64` but does not say whether the resolver truncates, rejects, abbreviates, or stores full text and lets the view truncate. A derived resolver should not fail to render because a real branch name is long.

## Alternatives Considered

### Alternative A: Extend existing Branch + Directory row

This is the lowest-risk implementation path. The current sidebar already knows per-panel directories and branches and has settings for branch/directory visibility. The feature could add worktree labeling and colored dots to that existing projection rather than introducing canonical `worktree`/`branch` keys. This avoids metadata persistence questions.

Downside: external socket consumers do not get canonical `worktree`/`branch` values. If that is required, this is not enough.

### Alternative B: Runtime derived context plus optional metadata mirror

This is my preferred framing. Keep the resolver/cache as runtime state owned by the app. Render from that state. If external visibility matters, mirror the result into `SurfaceMetadataStore` with explicit "derived is non-persistent and internal-only" rules.

This preserves the product behavior while containing API and persistence blast radius.

### Alternative C: Full canonical metadata implementation

This is the plan's current direction. It can work, but only if the plan adds persistence filtering, public/private source semantics, clear-on-stale behavior, and render aggregation rules. Without those, canonical metadata is too broad a hammer for this feature.

### Alternative D: Ship chips without color first

The original plan's C-only path would reduce UI review surface, but I do not think color is the main risk. The hard parts are resolver correctness and state ownership. The colored dot is acceptable if it stays a projection detail and tests do not demand impossible collision-free hashing from a small palette.

## Readiness Verdict

**Needs revision.**

Changes required before execution:

1. Decide whether `worktree` and `branch` are true canonical metadata keys or runtime-derived sidebar projection data.
2. If canonical, specify persistence exclusion or explicitly accept persistence.
3. Define how the sidebar handles multiple surfaces in one workspace.
4. Reconcile the new UI with the existing Branch + Directory row and setting.
5. Replace `.git/HEAD` cache invalidation with resolved Git HEAD/ref paths.
6. Define a correct two-pass submodule algorithm.
7. Require stale-result guards for async resolver completion.
8. Correct the Swift test target/source-location guidance.
9. Add localization/xcstrings/translation work to the plan.

After those revisions, the plan is execution-ready.

## Questions for the Plan Author

1. Should `worktree` and `branch` be visible through `c11 get-metadata`, or are they sidebar-only derived UI state?
2. If they are canonical metadata keys, should `derived` values persist in session/workspace snapshots?
3. If derived values should not persist, where exactly should snapshot capture filter them out?
4. Should socket/CLI clients be allowed to write `source=derived`, or is `derived` internal-only?
5. In a workspace with multiple terminal surfaces, should the sidebar show the focused surface's worktree only, all visible surfaces, all pane tabs, or an aggregate summary?
6. Should this feature replace the existing Branch + Directory row, or coexist with it?
7. How should the existing "Show Branch + Directory in Sidebar" setting relate to the new "Show worktree/branch chips" setting?
8. Is the branch chip for main checkout meant to supersede the existing branch summary text?
9. For long branch names over 64 characters, should the resolver truncate, the projection truncate, or the canonical constraint be raised?
10. For deleted branch worktrees, what exact user-visible branch text is expected: empty, `(no branch)`, the stale symbolic branch name, or something else?
11. For submodules, what should the submodule label be: path from superproject root, basename, `.gitmodules` name, or something else?
12. In a linked worktree whose basename collides with another visible worktree, is same text plus different color sufficient, or should the UI disambiguate text?
13. Is color collision acceptable for different worktree paths when the palette is small?
14. Should bare repositories always omit chips even if Git can report a branch?
15. Should remote workspaces/SSH surfaces run local `git` resolution, skip entirely, or use remote-reported shell integration data only?
16. Should the resolver reuse the existing `TabManager` git probe infrastructure or introduce a separate resolver/cache?
17. What is the expected source directory for new Swift tests, given the repo has `c11Tests/` and a `c11LogicTests` scheme/target but no `Tests/c11LogicTests/` directory?
18. Should the Result Validator check localization updates, or is that part of closeout audit?
19. Are post-merge smoke checks enough for the actual visible two-row submodule layout, or should there be a pre-merge projection test that covers the exact row model?
20. Does the operator want external consumers like Lattice to read these values, or is the whole value of this ticket visual/operator-facing?

## Suggested Plan Patch

Before delegating implementation, I would add this short architectural rule to the BUILDPLAN:

> Implement git context as a typed, runtime-only per-surface model first. The resolver runs off-main, returns a generation-tagged result for the cwd that triggered it, and applies only if the surface still exists and its current cwd matches. Cache entries are keyed by resolved cwd plus resolved Git HEAD/ref paths, not by `.git/HEAD`. The sidebar renders chips from this model, reconciled with the existing Branch + Directory row. If `worktree`/`branch` are mirrored into `SurfaceMetadataStore`, `source=derived` is internal-only and derived keys are excluded from snapshot persistence unless explicitly overridden by a higher-precedence source.

That rule would remove most of the implementation ambiguity without changing the product decision.
