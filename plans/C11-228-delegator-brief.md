# C11-228 delegator brief

You are the delegator for Lattice ticket **C11-228** in the c11 repo
(`/Users/atin/Projects/Stage11/code/c11`). Load the `lattice` skill, run
`lattice show C11-228` and read the whole description first; it carries the
evidence and the probable mechanism. Work only in your own worktree, open a PR,
drive it to green CI, and report back. Do not touch the main checkout.

## The bug in one paragraph

When a workspace is deselected, its selected-in-pane terminal is supposed to go
`active → throttled` (which calls `ghostty_surface_set_occlusion(false)` so the
engine stops rendering it; since C11-225 the engine also skips the frame rebuild).
That transition is driven from the view: `TerminalPanelView` calls
`panel.applyVisibility(isVisibleInUI)` from `.onAppear` / `.onChange`, with
`isVisibleInUI` computed in `WorkspaceContentView` from
`MountedWorkspacePresentationPolicy.isPanelVisible` (ContentView.swift ~1411).
The deselected workspace's subtree sits inside `AppKitHiddenWrapper`
(ContentView.swift ~28, an `NSHostingController` whose view is set `isHidden`),
and the `false` edge is frequently lost: on production 7 of 9 hidden workspaces'
selected terminals read `lifecycle_state = active`, and on the v0.66.1 Release
staging build the transition never happened at all after `select-workspace`.
Non-selected tabs (tab switch inside a pane) throttle reliably.

## The fix

Drive the lifecycle from the model so it cannot depend on a hidden SwiftUI
subtree updating:

1. Add `Workspace.applyPanelVisibility(workspaceVisible: Bool)` in
   `Sources/Workspace.swift`: for every panel in `panels`, compute
   `isSelectedInPane` via `bonsplitController.selectedTab(inPane:)` for the pane
   that contains the panel's surface (see how `WorkspaceContentView` derives it),
   then call `panel.applyVisibility(workspaceVisible && isSelectedInPane)` on
   `TerminalPanel` and `BrowserPanel` (both already implement it; markdown panels
   have no lifecycle). `applyVisibility` already preserves operator-pinned
   `hibernated` and is idempotent, so double-firing with the view path is safe.
2. Call it from `TabManager.selectedTabId.didSet` (`Sources/TabManager.swift`
   ~945): `previous?.applyPanelVisibility(workspaceVisible: false)` and
   `selected.applyPanelVisibility(workspaceVisible: true)`. Put it in the
   synchronous part of `didSet`, not the queued async block, so it cannot be
   superseded. Resolve workspaces by id from `tabs`.
3. Leave the view-driven path in place.
4. Check the pane-tab selection path has no equivalent gap: after
   `focus-surface`/`select-surface` inside a *hidden* workspace, the newly
   selected tab must stay `throttled` (workspace not visible) and the old one too.
   If the view path flips it to `active`, gate on workspace visibility there as
   well.

Keep it small. No new state, no timers, no per-keystroke work (typing-latency
paths in CLAUDE.md Pitfalls are off limits).

## Tests

Add a behavioral test in `c11Tests` (host-required target; CI runs it): build a
`TabManager` with two workspaces each holding a terminal panel, select the
second, assert the first's terminal panel lifecycle state is `.throttled` and
the second's is `.active` (read via `SurfaceLifecycleController.state` or the
`lifecycle_state` metadata key); select back and assert the inverse. Existing
lifecycle tests live in `c11Tests/SurfaceLifecycleTests.swift`; follow their
construction pattern. No source-text tests (CLAUDE.md test quality policy).

**Do not run `xcodebuild` locally in any form.** The machine is in Low Power
Mode with half its cores derecommended and a Release build already starved
for 20 minutes today. CI's `build` job compiles and runs the logic gate;
`c11-unit` runs on CI. Push and read CI.

## Worktree

```bash
cd /Users/atin/Projects/Stage11/code/c11
git worktree add ../c11-worktrees/c11-228-throttle-on-deselect -b fix/C11-228-throttle-on-deselect origin/main
cd ../c11-worktrees/c11-228-throttle-on-deselect
git submodule update --init --recursive ghostty vendor/bonsplit
```

`origin/main` already contains C11-224 and C11-225. You do not need the
GhosttyKit symlink because you will not build locally.

## Lattice discipline

- `lattice status C11-228 in_progress` when you start (write the plan file
  first; the CLI rejects the transition on a scaffold plan), `review` when the
  PR is open, `pr_open` after you have self-reviewed the diff; attach the PR URL
  as an artifact and comment with the CI run URL when green.
- Do not merge. The orchestrator merges and validates on a nap-free staging
  build (that procedure is recorded on C11-225).
- Report completion and recoverable blockers to your parent (the
  "Load Diagnosis" surface in workspace `c11`, `surface:115`, via
  `c11 send --workspace workspace:5 --surface surface:115 "<one-line status>"`).
  Raise a c11 flag only when operator action is required.

## PR description

State the mechanism (view-driven transition lost inside a hidden hosting
controller), the model-driven fix, and the prod 7-of-9 evidence. End with the
attribution lines your harness supplies.
