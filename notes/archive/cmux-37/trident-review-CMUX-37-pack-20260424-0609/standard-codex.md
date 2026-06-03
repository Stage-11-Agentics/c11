## Code Review
- **Date:** 2026-04-24T10:12:47Z
- **Model:** CODEX (GPT-5)
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** bf802101
- **Linear Story:** CMUX-37
---

Review scope: cycle-2 CMUX-37 Phase 0 branch against `origin/main...HEAD`, focusing on the R1-R7 rework. Per the task prompt, I did not fetch/pull because that mutates git state. Per `CLAUDE.md`, I did not run local tests; CI/VM owns test execution. I inspected the executor, socket/CLI path, fixtures, and acceptance harness.

General assessment: the major cycle-1 blocker appears addressed. `WorkspaceLayoutExecutor` now uses a top-down split walker (`Sources/WorkspaceLayoutExecutor.swift:423`) and the acceptance harness compares the live bonsplit tree shape, split orientation, divider positions, tab order, selected tab, metadata, and terminal cwd handling (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:125`). The socket handler also pre-validates off-main before entering `v2MainSync` (`Sources/TerminalController.swift:4385`), and the CLI exposes the requested `c11 workspace apply` spelling while keeping `workspace-apply` as an alias (`CLI/c11.swift:1713`).

### Blockers

None found.

### Important

1. ✅ Confirmed - Unreferenced `SurfaceSpec`s are still silently dropped.

   `validate(plan:)` checks duplicate surface ids, unknown layout references, duplicate references, and selected-index bounds, but it never verifies that every declared `plan.surfaces` entry is referenced by the layout (`Sources/WorkspaceLayoutExecutor.swift:263`). The executor then only creates surfaces reached by the layout walker; ref assembly iterates `planSurfaceIdToPanelId`, so any unreferenced surface simply disappears from `surfaceRefs` / `paneRefs` (`Sources/WorkspaceLayoutExecutor.swift:202`). The initial command loop also silently `continue`s when a declared terminal has no live panel mapping (`Sources/WorkspaceLayoutExecutor.swift:182`).

   This is still a silent-drop class of failure: a malformed Blueprint/Snapshot can declare a surface and get a successful apply result without that surface ever existing. The acceptance test comment says every plan-local surface id should appear, but the assertion compares against a manually supplied `expectedSurfaceIds` list rather than deriving it from `plan.surfaces` (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:85`), so the harness would not catch a fixture that accidentally omitted a declared surface from the layout.

   Suggested fix: make validation compare `Set(plan.surfaces.map(\.id))` with the layout reference set and return a typed failure such as `unreferenced_surface_spec` for extras. Update the acceptance harness to assert result coverage against the actual plan surface ids.

2. ✅ Confirmed - `workingDirectory` is still silently ignored for browser/markdown surfaces created through the in-pane path.

   The rework added warnings for non-terminal `workingDirectory` when the surface is created via a split seed (`Sources/WorkspaceLayoutExecutor.swift:625`, `Sources/WorkspaceLayoutExecutor.swift:637`). The in-pane creation path does not have the same guard: `createSurface` drops `workingDirectory` for browser and markdown specs without warning (`Sources/WorkspaceLayoutExecutor.swift:801`). That path is used when replacing the root seed with a browser/markdown first leaf, and when adding additional tab-stacked surfaces in an existing pane (`Sources/WorkspaceLayoutExecutor.swift:476`, `Sources/WorkspaceLayoutExecutor.swift:510`).

   The cycle-1 concern was that cwd must not be silently dropped. This path still drops it silently for valid plan shapes. The acceptance harness only checks terminal surfaces with `workingDirectory` (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:301`), so it does not cover the non-terminal warning contract the implementation itself documents in `reportWorkingDirectoryNotApplicable`.

   Suggested fix: in `createSurface`, emit `working_directory_not_applied` for browser/markdown specs with non-empty `workingDirectory`, matching `splitFromPanel`. Add fixtures/tests for a root browser/markdown with `workingDirectory` and a tab-stacked browser/markdown with `workingDirectory`.

### Potential

3. ✅ Confirmed - The non-string `mailbox.*` regression check is present but currently ineffective.

   The executor implementation correctly drops non-string `mailbox.*` pane metadata with a typed `mailbox_non_string_value` failure (`Sources/WorkspaceLayoutExecutor.swift:761`). The acceptance assertion for that case is not exercised by any current fixture, and the substring it checks appears wrong: it searches for `[\(key)` (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:423`), while the emitted message contains `metadata["\(key)"]` (`Sources/WorkspaceLayoutExecutor.swift:765`).

   Suggested fix: add one small fixture or targeted executor test with a non-string `mailbox.*` pane value, and make the assertion match by code plus key rather than the current brittle substring.

### Validation Notes

- Re-read and confirmed both Important items are in files changed by this branch.
- Verified the top-down walker and structural harness address the prior B1/B2 failure mode in design.
- Did not run local tests or mutate refs, per the prompt and repository policy.
