# Plan Review: C11-228

## 1. Verdict

**PASS**

Conditional on the implementer folding in the two major items below (handoff timing decision, and applying visibility at panel registration). Neither changes the approach; both are one-paragraph additions. Sending the ticket back to `in_planning` would cost more than it saves with the release held on this fix.

## 2. Summary

The plan is the task description verbatim, but that description already carries a mechanism, a concrete fix, a validation procedure, and a test requirement. I verified every code claim in it against the tree: `TabManager.selectedTabId.didSet` is at `Sources/TabManager.swift:945` and every selection route (socket, keyboard, close-fallback, direct assignments in AppDelegate/ContentView) lands there; `Workspace.panels`, `bonsplitController.allPaneIds`, `selectedTab(inPane:)`, and `panelIdFromSurfaceId` exist; `TerminalPanel.applyVisibility` / `BrowserPanel.applyVisibility` are idempotent and preserve `hibernated`. The approach is sound and small. The key concern is that the plan does not decide *when* in the switch to throttle the old workspace relative to the retiring-handoff window, and it leaves one initial-state gap (panels created into a hidden workspace) that the same one-line call would close.

## 3. Issues

**[MAJOR] Fix — Throttle timing vs. the retiring-workspace handoff is undecided**
`selectedTabId.didSet` fires synchronously, but the old workspace stays on screen as the *retiring* workspace until `completeWorkspaceHandoff` runs (`Sources/ContentView.swift:3378` / `:3467`), which waits for the new workspace to have a loaded terminal surface (or a fallback task). Calling `applyVisibility(false)` in `didSet` sets occlusion on the old surfaces while they are still visible, and with C11-225 an occluded surface now skips `updateFrame`, so the retiring workspace freezes its last frame for the handoff duration. That is probably acceptable (it is on its way out) but it is a visible behavior change and the plan should say so and validate it. The alternative, applying at handoff completion, is later and less deterministic (the socket test would need to poll). There is also a small reverse hazard: during the handoff window `isWorkspaceVisible` is still `true` for the retiring workspace, so a bonsplit tab-selection change in it would let the view path call `applyVisibility(true)` and undo the model's throttle.
**Recommendation:** Decide explicitly. I recommend throttling synchronously in `didSet` (deterministic, the socket test can assert immediately after `workspace.select` returns, and the handoff fallback guarantees the window is bounded), and add a "no flash / no stale frame on switch-back" check to the validation step. Also re-apply from `completeWorkspaceHandoff` (cheap, idempotent) so any view-path un-throttle during the window is corrected.

**[MAJOR] Fix — Only switch edges are covered; panels created into a hidden workspace start and stay `active`**
`WorkspaceMountPolicy.maxMountedWorkspaces` is 1 (`Sources/ContentView.swift:1333`), so every non-selected workspace is unmounted and has no `TerminalPanelView` at all. A surface created into a hidden workspace via the socket (`surface.create`/`surface.split` with a workspace ref, which is exactly how orchestrators seed delegator panes) is constructed with `initial: .active`, never gets `.onAppear`, and the plan's `didSet` hook only touches it on the *next* select/deselect of that workspace. Until then it renders at full rate, the same failure this ticket is fixing.
**Recommendation:** Call the new `Workspace.applyPanelVisibility(workspaceVisible:)` (or the per-panel equivalent) from the panel-registration path as well (the `panels[...] = ` sites in `Sources/Workspace.swift`, ideally funneled through one helper). `Workspace` has no selected-state flag today, so either have `TabManager` stamp `workspace.isSelectedInWindow` from `didSet`, or route creation through a `TabManager` helper that knows. Add one socket-test case: create a surface into a non-selected workspace, read `lifecycle_state == throttled` without ever selecting it.

**[MAJOR] Plan structure — No file list, no test design, no sequencing**
The plan is the ticket text copied verbatim. It names the anchor (`TabManager.swift ~945`) but does not enumerate what changes, and "add a runtime test through the socket" has no shape.
**Recommendation:** State the touch list: `Sources/TabManager.swift` (didSet, and `completeWorkspaceHandoff` re-apply per the first item), `Sources/Workspace.swift` (new `applyPanelVisibility`, plus the registration hook), `Sources/Panels/TerminalPanel.swift:64` and the `applyVisibility` doc comments in both panels (they currently say visibility is driven from the view), `tests_v2/test_surface_lifecycle.py` or a sibling file for the socket assertion, and the C11-228 entry in `docs/`/changelog if the release notes are curated. State the order: model hook → registration hook → doc comments → socket test → tagged Debug validation → Release staging validation.

**[MINOR] Validation — Socket test venue and helper API**
`tests_v2/` runs only on the c11-vm via `scripts/run-tests-v2.sh` (it is not wired into `ci.yml`), and CLAUDE.md forbids running it against an untagged local app. The Python helper `tests_v2/cmux.py` has `new_workspace`, `select_workspace`, `new_surface` but no metadata wrapper; the existing lifecycle test uses `_call("surface.get_metadata", ...)` directly.
**Recommendation:** Say where the test runs (VM runner, plus the manual tagged-build and staging passes) so "add a runtime test" is not mistaken for CI coverage. Model the test on `_run_legal_values` in `test_surface_lifecycle.py`: create workspace A with a surface, create workspace B, `select_workspace(B)`, assert A's surface reads `throttled` (poll up to 1 s only if the implementer chooses handoff-completion timing), `select_workspace(A)`, assert `active`. Note that a fresh surface has *no* `lifecycle_state` key until its first transition, so assert on the value, not just on a change.

**[MINOR] Alignment — Browser panels get metadata-only throttling from the model path**
`BrowserPanel.dispatchLifecycleTransition` does nothing for `active ↔ throttled`; the WKWebView detach is driven by the view's `shouldAttachWebView` gate, which has the same lost-edge exposure. The model-driven call will make browser `lifecycle_state` correct but does not by itself detach the web view.
**Recommendation:** Keep browsers in scope for the metadata call (cheap, and keeps `c11 tree` honest) but say explicitly in the plan and PR that this ticket fixes terminal renderer throttling; browser detach reliability is out of scope unless the validation shows it is also affected.

**[MINOR] Mechanism — A second, simpler cause is likely and worth recording**
The plan attributes the lost edge to a hidden `NSHostingController` deferring its body update. With `maxMountedWorkspaces = 1`, there is a more direct path: clearing `retiringWorkspaceId` both flips the old workspace to `isPanelVisible = false` and lets `reconcileMountedWorkspaceIds` unmount it. If both land in one SwiftUI transaction the panel view is *removed* rather than updated, and `.onChange` never fires for a removed view. Whether the unmount lands one tick later decides whether the edge is seen, which matches the 7/2 split. Both causes are fixed by the model-driven approach, so this does not change the plan.
**Recommendation:** Record both mechanisms in the PR description so the next reader does not re-derive them, and do not spend implementation time proving which one dominates.

**[MINOR] Feasibility — Pane-tab selection path**
`surface.focus` resolves to `TabManager.focusSurface` → `Workspace.focusPanel` and does not select the workspace, so a hidden-workspace tab switch is a real path. Inside a hidden workspace both old and new tabs should already be `throttled`, and the view path cannot flip either to `active` because `isWorkspaceVisible` is `false`, so the exposure is low.
**Recommendation:** Keep the plan's "verify with get-metadata after focus-surface" step; if it does show a gap, `Workspace.applyTabSelectionNow` (`Sources/Workspace.swift:11494`) is the hook, and it needs the workspace's selected-state flag from the second major item.

## 4. Positive Observations

- **Diagnosis is evidence-backed and reproducible.** Debug-vs-Release comparison, production counts (7 active / 2 throttled selected surfaces; 24 throttled non-selected tabs), and the `sample` render-thread counts isolate the failure to the workspace-deselect edge and rule out the engine. That is exactly the shape of evidence a reviewer wants.
- **The fix goes to the right layer.** Driving lifecycle from the model in the single choke point every selection route already passes through, instead of patching the view, is the correct architectural call and matches the existing model-driven `Workspace.hibernate()` / `resume()` pattern. The chosen API (`Workspace.applyPanelVisibility(workspaceVisible:)`) fits the codebase and reuses idempotent, pin-preserving `applyVisibility`.
- **Idempotence is understood.** Keeping the view path as a fallback is safe precisely because `SurfaceLifecycleController.transition` treats same-state calls as no-ops; the plan says so.
- **Validation is concrete and nap-proof.** Specifying `NSAppSleepDisabled`, a parked window, a 1 s metadata deadline, and a 0-render-sample assertion under a streaming loop on both Debug tagged and Release staging builds makes "throttled" a measurable claim, not a metadata read.
- **Release framing is explicit.** Naming the ship vehicle (v0.66.1 held, or 0.66.2 immediately after) tells the implementer how much scope discipline the change needs.
