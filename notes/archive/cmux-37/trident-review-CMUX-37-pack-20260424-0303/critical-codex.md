## Critical Code Review
- **Date:** 2026-04-24T07:09:08Z
- **Model:** Ucodex
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** e4f60b98
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial
---

**The Ugly Truth**

The value types and metadata plumbing are mostly coherent, but the executor is not production-ready. The core layout walker does not faithfully materialize nested `LayoutTreeSpec` trees. It can return all the right refs while producing the wrong geometry, and the acceptance tests are too shallow to catch it. For a primitive that is supposed to become the common path for Blueprints, Snapshots, and restore, that is the wrong failure mode: it looks successful at the API boundary while silently corrupting the workspace shape.

I did not run tests locally. `CLAUDE.md` and the CMUX-37 review packet explicitly forbid local test execution for this worktree. I also did not fetch/pull because this was a read-only review with one allowed output file; local branch metadata already shows `HEAD` and `origin/cmux-37/phase-0-workspace-apply-plan` at `e4f60b98`.

**What Will Break**

1. Nested split plans will materialize into the wrong tree. A declared 2x2 like `split(horizontal, split(vertical, tl, bl), split(vertical, tr, br))` is built by first making `split(vertical, tl, bl)`, then splitting the `tl` leaf horizontally for `tr`, then splitting `tr` vertically for `br`. That yields a nested shape under the top-left pane, not two columns with two rows each.
2. Terminal `workingDirectory` is ignored for the seed terminal and for terminal split panes. Commands in restored/applied plans can run in the workspace default directory or inherited source cwd instead of the per-surface cwd in the plan.
3. The documented debug CLI shape is not implemented. Docs and the Phase 0 plan say `c11 workspace apply --file <path>`; the code adds a top-level `c11 workspace-apply --file <path>`.
4. `ApplyOptions.perStepTimeoutMs` is dead configuration. The type documents timeout warnings, but `apply()` never checks step durations against the option, so slow steps do not produce the named warning path the plan promises.

**What's Missing**

The acceptance harness needs to assert observable layout shape, not just that every plan-local id got a ref. It should compare the live bonsplit tree orientation/order against the decoded fixture tree and verify divider positions. It also needs at least one fixture that uses distinct terminal `workingDirectory` values and asserts the resulting `TerminalPanel.requestedWorkingDirectory` or equivalent runtime state. The CLI test surface should be covered at the command parser level, especially because the implemented command name already diverged from the plan.

**The Nits**

`metadata_override` records are appended to `failures` but not to `warnings` in `WorkspaceLayoutExecutor.writeSurfaceMetadata` (`Sources/WorkspaceLayoutExecutor.swift:574`). That weakens the human-readable warning channel, even though the machine-readable failure exists. `ApplyOptions.autoWelcomeIfNeeded` is intentionally ignored; the comments explain it, but carrying a no-op public option in Phase 0 still invites caller confusion.

**Blockers**

1. ✅ Confirmed — Nested layouts are built from the wrong anchor, so plan fidelity is broken.

   `WorkspaceLayoutExecutor.WalkState.materializeSplit` first materializes `splitSpec.first`, receives `firstAnchorPanelId`, and then calls `splitFromPanel(firstAnchorPanelId, ...)` for `splitSpec.second` (`Sources/WorkspaceLayoutExecutor.swift:448`). Because `Workspace.new*Split` splits a concrete bonsplit pane (`Sources/Workspace.swift:7250`, `Sources/Workspace.swift:7439`, `Sources/Workspace.swift:7588`), this splits the first leaf pane inside the already-built first subtree, not the subtree boundary represented by the plan node.

   Static trace against `c11Tests/Fixtures/workspace-apply-plans/default-grid.json:7`: expected root is horizontal with a vertical left subtree and vertical right subtree. Actual construction path is vertical split `tl/bl`, then horizontal split of `tl` for `tr`, then vertical split of `tr` for `br`. The current test only checks `Set(result.surfaceRefs.keys)` and timing (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:124`), so it can pass while the visible layout is wrong.

**Important**

1. ✅ Confirmed — Per-surface terminal cwd is ignored for first surfaces in panes.

   `SurfaceSpec.workingDirectory` is documented as terminal creation input (`Sources/WorkspaceApplyPlan.swift:67`). The executor only passes it in `createSurface(... inPane:)` for additional same-pane terminal tabs (`Sources/WorkspaceLayoutExecutor.swift:676`). The root seed terminal path reuses the seed without applying `firstSurface.workingDirectory` (`Sources/WorkspaceLayoutExecutor.swift:361`), and terminal split creation calls `workspace.newTerminalSplit(... focus: false)` with no cwd parameter (`Sources/WorkspaceLayoutExecutor.swift:511`). `newTerminalSplit` then inherits cwd from the source panel/workspace (`Sources/Workspace.swift:7260`), not the target `SurfaceSpec`. Any plan that expects `tests` in repo A and `logs` in repo B will run commands in the wrong directory.

2. ✅ Confirmed — The CLI command does not match the documented Phase 0 surface.

   The plan and companion doc specify `c11 workspace apply --file <path>` (`docs/c11-snapshot-restore-plan.md:164`). The implementation adds `case "workspace-apply"` (`CLI/c11.swift:1713`) and `rg` finds no `case "workspace"` route for this command. Operators following the documented contract get an unknown command, and scripts written for Phase 0 will need churn later.

3. ✅ Confirmed — `ApplyOptions.perStepTimeoutMs` is never enforced.

   The option promises a per-step deadline warning (`Sources/WorkspaceApplyPlan.swift:196`), and the plan says slow fixtures should surface named step warnings. In `WorkspaceLayoutExecutor.apply`, timings are appended but no code compares any `durationMs` to `options.perStepTimeoutMs`. A slow metadata write or split therefore returns as clean unless the test happens to fail only on total duration.

4. ✅ Confirmed — Acceptance tests do not verify the acceptance fixture's core behavior.

   The five fixture files exist and decode, and the harness checks refs and a narrow metadata round-trip. It does not assert live tree shape, split orientation, pane order, selected index, divider positions, browser URL, markdown file path, or terminal cwd. The blocker above proves why this matters: the test can report success for a malformed layout.

**Potential**

1. ⬇️ Real but lower priority — Unsupported `WorkspaceApplyPlan.version` values are accepted. `version` is part of the schema (`Sources/WorkspaceApplyPlan.swift:13`), but validation never checks it (`Sources/WorkspaceLayoutExecutor.swift:222`). That is survivable in Phase 0 but becomes a compatibility trap once snapshots exist.
2. ⬇️ Real but lower priority — `metadata_override` is classified as a failure, but the executor intentionally lets raw `metadata["title"]` / `metadata["description"]` win after canonical setters (`Sources/WorkspaceLayoutExecutor.swift:570`). That may be acceptable, but it conflicts with the review axis that reserved keys should go through canonical paths, and it deserves an explicit decision before Phase 1 depends on it.
3. ⬇️ Real but lower priority — Same-pane `paneMetadata` is stored once per bonsplit pane. If multiple `SurfaceSpec`s in the same pane carry different `paneMetadata`, they merge into the same pane record in creation order. That may be the current model, but it is easy for Blueprint authors to interpret `SurfaceSpec.paneMetadata` as per-surface metadata.

**Validation Notes**

No hot-path edits were found in `TerminalWindowPortal.hitTest`, `TabItemView`, or `GhosttyTerminalView.forceRefresh` in the supplied full diff. I also found no `Resources/bin/claude` change, no `c11 install <tui>` revival, and no tenant tool config writes. Socket handler parsing is off-main before the main-actor executor call; the main sync is justified by AppKit/bonsplit mutation.

**Closing**

I would not mass deploy this to 100k users. The API shape is promising, but the executor currently violates the main promise of `WorkspaceApplyPlan`: faithfully materializing the declared workspace tree. Fix the split construction algorithm first, then strengthen the acceptance harness so it fails on the current implementation. After that, fix terminal cwd propagation and align the CLI command with the documented `c11 workspace apply --file` surface.
