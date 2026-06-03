## Code Review
- **Date:** 2026-04-24T07:10:52Z
- **Model:** Ucodex
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** e4f60b987d5b0477cd4b172878152450a9965a84
- **Linear Story:** CMUX-37
---

### Scope and Validation

Reviewed the Phase 0 branch against `origin/main...HEAD`, the Phase 0 plan section in `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md`, `docs/c11-13-cmux-37-alignment.md`, and the provided full diff. I did not run local tests, `xcodebuild`, or app/socket validation because this worktree's `CLAUDE.md` explicitly forbids local test execution for this repo. I also did not fetch/pull because the review prompt's wrapper constrained this run to read-only inspection plus this single output file.

The branch is well scoped to Phase 0: value types, executor, metadata stores, fixture tests, TODOs at the welcome/default-grid migration sites, and the optional `workspace.apply` socket/CLI debug surface. The `mailbox.*` Codable shape and executor string guard are aligned with C11-13. Hot-path files and terminal-opinion areas are not changed.

### Findings

#### Blockers

1. ✅ Confirmed — `WorkspaceLayoutExecutor` does not preserve nested split-tree shape when `split.first` is itself a split.  
   Files: `Sources/WorkspaceLayoutExecutor.swift:155`, `Sources/WorkspaceLayoutExecutor.swift:448`  
   The walker fully materializes `split.first` before creating the parent split, then calls `splitFromPanel(firstAnchorPanelId, ...)` for `split.second`. Because `newXSplit(from:)` splits the pane containing that one panel, not the entire already-built first subtree, plans like `welcome-quad.json` and `default-grid.json` cannot produce the intended root split with two vertical child groups. For welcome/default grid, the code first builds the left vertical pair, then splits only the first panel's pane horizontally, so the right subtree is attached inside the wrong part of the tree. This breaks the core Phase 0 contract: reproducing welcome-quad/default-grid shapes and enabling Snapshot restore from `LayoutTreeSpec`.

   The acceptance test does not catch this because it only checks that all expected surface refs and pane refs exist, not that the live bonsplit tree matches the fixture structure. The fix should make split creation respect the plan tree's hierarchy, likely by creating the current split before recursively filling both child subtrees, or by using a bonsplit primitive that can split a subtree/container rather than a leaf pane if one exists.

#### Important

2. ✅ Confirmed — Acceptance tests do not assert the structural layout fingerprint required by the plan.  
   Files: `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:49`, `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:106`, `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:452`  
   The Phase 0 plan says `welcome-quad.json` should assert that the resulting pane tree matches a structural fingerprint, and `deep-nested-splits.json` should exercise divider position application and parent-panel bookkeeping. The harness only checks populated refs, absence of `validation_failed`, and total duration. That leaves the executor free to create the wrong split topology while still passing the tests. Add a normalized tree assertion from `workspace.bonsplitController.treeSnapshot()` for each fixture, including orientation, child nesting, leaf surface ids/titles, selected tab, and divider positions where practical.

3. ✅ Confirmed — `metadata["title"]` override writes the store but leaves live title state stale.  
   Files: `Sources/WorkspaceLayoutExecutor.swift:403`, `Sources/WorkspaceLayoutExecutor.swift:576`, `Sources/Workspace.swift:5873`, `Sources/TerminalController.swift:6523`  
   The executor first applies `SurfaceSpec.title` through `workspace.setPanelCustomTitle`, then if `spec.metadata["title"]` also exists it writes that value directly to `SurfaceMetadataStore` and records `metadata_override`. The comment says the metadata value wins, but this direct store write does not call the title side-effect path (`syncPanelTitleFromMetadata`) used by the socket metadata API. Result: `SurfaceMetadataStore["title"]` can differ from `panelCustomTitles`/bonsplit tab title. If metadata title overrides are supported, route them back through `setPanelCustomTitle` or call the same title sync after a successful metadata write. If they are not supported, reject/drop the duplicate instead of claiming metadata wins.

4. ✅ Confirmed — `ApplyOptions.perStepTimeoutMs` is documented but unused.  
   Files: `Sources/WorkspaceApplyPlan.swift:196`, `Sources/WorkspaceLayoutExecutor.swift:68`, `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:140`  
   `ApplyOptions` promises a per-step deadline warning when any `StepTiming` exceeds the configured threshold, with zero disabling it. The executor records timings but never compares them against `options.perStepTimeoutMs`; the tests only assert total fixture time. This makes the debug socket/CLI less useful for the "named timeout" behavior described in the plan. Either implement the per-step warning/check path or remove the option/comment until Phase 1 readiness introduces real deadline semantics.

#### Potential

5. ✅ Confirmed — `SurfaceSpec.workingDirectory` is not honored for the root reused terminal or split-created terminal surfaces.  
   Files: `Sources/WorkspaceLayoutExecutor.swift:88`, `Sources/WorkspaceLayoutExecutor.swift:399`, `Sources/WorkspaceLayoutExecutor.swift:512`, `Sources/Workspace.swift:7250`  
   In-pane additional terminal surfaces pass `spec.workingDirectory` to `newTerminalSurface`, but the first root terminal reuses the seed created with `plan.workspace.workingDirectory`, and terminal splits call `newTerminalSplit`, which inherits cwd from the source panel rather than accepting the target spec's `workingDirectory`. The Phase 0 fixtures do not currently exercise per-surface cwd, so this may be acceptable if per-surface cwd is deferred, but the schema comment says terminal `workingDirectory` is passed to the creation primitive. Clarify the contract or add support before Snapshot/Blueprint phases depend on per-surface cwd fidelity.

### Summary

The main implementation risk is the split walker. It creates all requested surfaces, but for nested split plans it does not create the requested tree. Because CMUX-37 is explicitly about app-side layout restore, I would not merge Phase 0 until that topology issue and the corresponding structural assertions are fixed. The metadata path is otherwise mostly aligned: store writes use `PersistedMetadataBridge.decodeValues`, `.explicit` source, canonical title setter for normal title, and the `mailbox.*` strings-only guard.
