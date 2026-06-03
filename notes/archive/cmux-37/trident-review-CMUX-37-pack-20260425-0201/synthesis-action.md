# Action-Ready Synthesis: CMUX-37

## Verdict

**fix-then-merge**

Reviewer agreement breakdown: Standard-Codex and Critical-Codex/Critical-Gemini rate this not-merge-ready; Standard-Claude rates it merge-ready with two confirmed bugs; Critical-Claude calls it "production-ready with one caveat" (the unverified CLI flags). The schema doc/implementation mismatch produces a committed failing test (confirmed independently) and would silently corrupt user-authored plans — that alone justifies fix-then-merge. The invalid `codex --last` command is confirmed by running `codex --help` directly. Bias toward the more cautious verdict.

---

## Apply by default

### Blockers (merge-blocking)

**B1: `codex --last` is not a valid Codex CLI command — restored Codex panes will fail**
- Location: `Sources/AgentRestartRegistry.swift:127`
- Problem: The registry emits `"codex --last\n"`. Running `codex --help` confirms there is no top-level `--last` flag; the supported form is `codex resume --last`. Every Codex surface restored with `C11_SESSION_RESUME=1` will type an invalid command into the terminal. The test at `c11Tests/AgentRestartRegistryTests.swift:252` and `:263` locks in this wrong string, so CI passes while the behavior is broken.
- Fix: Change the `codex` row to return `"codex resume --last\n"`. Update the two corresponding test assertions to match.
- Sources: Standard-Codex (finding 1, verified with `codex --help`); Critical-Codex (finding 1, same verification); independently verified in this synthesis pass.

**B2: Schema doc says snake_case; Codable types use synthesized camelCase — user-authored plans silently drop fields**
- Location: `docs/workspace-apply-plan-schema.md:5` plus examples at lines 30–31, 76, 79, 81, 91–96`; `Sources/WorkspaceApplyPlan.swift:25–84`; `Sources/TerminalController.swift:4369`
- Problem: The doc states "All fields use snake_case wire names" and shows `working_directory`, `file_path`, `pane_metadata`, `surface_ids`. The `WorkspaceApplyPlan` structs (`WorkspaceSpec`, `SurfaceSpec`, `LayoutTreeSpec.PaneSpec`) use synthesized Codable keys (camelCase), and `v2WorkspaceApply` decodes with `JSONDecoder()` (no `keyDecodingStrategy`). JSON following the docs silently loses `workingDirectory`, `filePath`, `paneMetadata`, and surfaceIds would not decode at all (non-optional, missing-key throw). The test at `c11Tests/WorkspaceBlueprintFileCodableTests.swift:94` encodes a plan using `"surface_ids"` (snake_case) inside the JSON literal — because `PaneSpec.surfaceIds` is non-optional, this test throws a `DecodingError.keyNotFound` in CI.
- Fix: Either (a) fix the doc to show camelCase throughout (simpler, preserves implementation as-is), or (b) add explicit `CodingKeys` with snake_case names to `WorkspaceSpec`, `SurfaceSpec`, and `LayoutTreeSpec.PaneSpec` and update the starter blueprints and tests to match. Option (a) is lower-risk since it touches only docs and the one test. Fix the test at line 94 regardless of which option is chosen — change `"surface_ids"` to `"surfaceIds"`.
- Sources: Standard-Codex (finding 2, with specific field citations); Critical-Codex (finding 3, with same citations); independently verified by reading `WorkspaceApplyPlan.swift` and `TerminalController.swift:4369`.

### Important (land in same PR)

**I1: `workspace new` picker never sends `cwd` — per-repo blueprints are invisible to the primary user command**
- Location: `CLI/c11.swift:2793`
- Problem: `workspaceBlueprintPicker` calls `workspace.list_blueprints` with `params: [:]`. The socket handler `v2WorkspaceListBlueprints` only activates per-repo discovery (`WorkspaceBlueprintStore.merged(cwd:)`) when `params["cwd"]` is present. Result: `.cmux/blueprints/` directories are never discovered from `c11 workspace new`, even though the priority-order documentation lists repo blueprints first.
- Fix: Pass `FileManager.default.currentDirectoryPath` in the params: `let params: [String: Any] = ["cwd": FileManager.default.currentDirectoryPath]` at line 2793.
- Sources: Standard-Claude (finding 1, cited line); Standard-Codex (finding 3); Critical-Codex (finding 2); all three models flagged this independently.

**I2: `snapshot --all` CLI prints `OK path=?` for failed workspace writes — partial failures appear as success**
- Location: `CLI/c11.swift:2947–2952`
- Problem: The socket handler appends `{snapshot_id, error, workspace_ref}` entries (no `path`, no `surface_count`) for workspaces where the write failed, but still returns `.ok(...)`. The CLI loop reads all entries through `?? "?"` fallbacks and unconditionally prints `OK snapshot=... path=?`. An operator running `--all` across N workspaces where 1 fails sees `OK path=?` with no indication of failure.
- Fix: Check for `snap["error"]` in the loop at line 2947; print an `ERROR:` prefixed line (e.g., `ERROR workspace=\(wsRef) reason=\(err)`) and exit non-zero when any entry has an error key.
- Sources: Standard-Claude (finding 2, with line citations); Standard-Codex (finding 4); Critical-Claude (finding 6); Critical-Codex (finding 4). Four independent confirmations across two lenses and three models.

**I3: `WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift` is not in the test target's sources build phase — it does not compile in CI**
- Location: `GhosttyTabs.xcodeproj/project.pbxproj:1240–1253`
- Problem: The file reference `D8016BF1A1B2C3D4E5F60718` appears in the project group (line 884) and a build file entry exists at line 46, but the `c11Tests` `PBXSourcesBuildPhase` (lines 1240–1253) does not include `D8016BF0A1B2C3D4E5F60718`. The four browser/markdown round-trip tests will not compile or run in CI.
- Fix: Add `D8016BF0A1B2C3D4E5F60718 /* WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift in Sources */` to the test sources build phase list (inside the section ending at line 1253).
- Sources: Standard-Codex (finding 6, with pbxproj line citation); independently confirmed by reading the build phase contents.

**I4: Stale path comment in `WorkspaceBlueprintFile.swift` — `Source.user` documents a non-existent directory**
- Location: `Sources/WorkspaceBlueprintFile.swift:33`
- Problem: The `Source.user` enum case comment says `// ~/.c11-blueprints/` but the actual path used throughout is `~/.config/cmux/blueprints/` (confirmed in `TerminalController.swift:4525`, `WorkspaceBlueprintStore.swift:93`). Operators or agents reading the type documentation will search for `~/.c11-blueprints/` and not find their blueprints.
- Fix: Change the comment to `// ~/.config/cmux/blueprints/`.
- Sources: Standard-Claude (finding 4); Critical-Claude (nit 1, with cited location); Critical-Codex (nit); Standard-Codex (nit). Four models confirmed this.

**I5: `selectedIndex > 0` guard skips `selectTab` when the captured tab is index 0**
- Location: `Sources/WorkspaceLayoutExecutor.swift:601`
- Problem: The guard `selectedIndex > 0` means a plan that captures pane tab index 0 as selected never calls `selectTab`. In practice index 0 is the construction default so no wrong tab is shown today, but the spec contract (`validate()` at line 401 accepts `idx >= 0` as valid) promises fidelity that the executor does not deliver. This is a latent correctness violation: any future change to bonsplit's initial selection order will silently restore the wrong tab.
- Fix: Change `selectedIndex > 0` to `selectedIndex >= 0` (removing the lower-bound guard entirely, relying on the existing `selectedIndex < paneSpec.surfaceIds.count` upper-bound check).
- Sources: Standard-Claude (finding 3); Critical-Claude (finding 1 / important 1, with rationale); Critical-Codex (implicit in its correctness notes). Two models independently raised this with specific line citation.

### Straightforward mediums

**M1: `snapshot --all` missing from `c11 snapshot` help text**
- Location: `CLI/c11.swift:8451–8467`
- Problem: The help text at line 8453 shows `Usage: c11 snapshot [--workspace <ref>] [--out <path>] [--json]` and the Flags list omits `--all`. The feature shipped in Phase 3b but is undiscoverable from `c11 snapshot --help`.
- Fix: Add `--all` to the usage line and flags section: `--all  Capture all open workspaces (mutually exclusive with --workspace and --out)`.
- Sources: Standard-Codex (finding 5); Critical-Codex (finding 5). Two models, concrete location.

**M2: Picker output field order inconsistency — `--all` output includes `workspace=`, single-workspace output does not**
- Location: `CLI/c11.swift:2952` (all) vs `CLI/c11.swift:2993` (single)
- Problem: The `--all` path prints `OK snapshot=ID surfaces=N workspace=WSREF path=PATH`. The single-workspace path prints `OK snapshot=ID surfaces=N path=PATH` (no `workspace=`). The socket response for the single case includes `workspace_ref` but the CLI does not print it. Scripts parsing both modes get inconsistent field sets.
- Fix: Add `workspace=\((payload["workspace_ref"] as? String) ?? "?")` to the single-workspace print statement at line 2993 to match the `--all` format.
- Sources: Standard-Claude (finding 5, with line citations). Single reviewer, but concrete and checkable; fixing it is a one-liner with no blast radius.

### Evolutionary clear wins

None. All evolutionary content is either scope-expanding or design-dependent. See "Evolutionary worth considering" below.

---

## Surface to user (do not apply silently)

**S1: `opencode --continue` and `kimi --continue` flags are unverified and may not exist**
- Why deferred: ambiguous + design-needed. The `opencode` CLI could not be verified (sandbox blocked it during Codex's review pass). `kimi --continue` is similarly unverified. The correct fallback per the original plan spec was `opencode\n` (bare, fresh session) and `kimi\n`, not `--continue`. The PR explicitly documents these as "best-effort." Silently applying a fix requires choosing between (a) keeping the guessed flags as-is with added comments, (b) reverting to the plan-spec bare commands, or (c) removing the rows entirely and shipping only the claude-code and codex rows. This choice belongs to the user.
- Summary: Standard-Claude flagged as uncertain; Critical-Claude confirmed as a UX risk (wrong flag → usage error printed in terminal); Critical-Gemini called it a blocker; Critical-Codex treated it as implicit (wrapped into the broader Phase 5 flag concerns). The `codex` row fix (B1) is clear because it was verified; the `opencode`/`kimi` rows need a decision.
- Sources: Standard-Claude (finding 6); Critical-Claude (finding 2); Critical-Gemini (blocker 1); Standard-Gemini (blocker 1).

**S2: `isRegularFileKey` is pre-fetched but never checked in `WorkspaceBlueprintStore.blueprintURLs(in:)` — directories with `.json`/`.md` names pass the filter**
- Why deferred: scope-creep (relative to PR focus) + low user-visible impact. The pre-fetched key is wasted and a directory with a `.json` name silently skips at decode time (not a crash, not wrong data). Fixing it is a one-liner (`try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true`), but it was only raised by one reviewer (Critical-Claude) and the net behavior is already safe (silent skip).
- Summary: Critical-Claude raised this as a confirmed nit. Standard-Codex noted discovery silent-skip behavior but did not specifically call out this bug. User should decide if the extra filter is worth touching.
- Sources: Critical-Claude (finding 3 / potential 3); Critical-Codex (implicit in discovery diagnostics discussion).

**S3: `--json` mode for `c11 workspace new` can be contaminated by the interactive picker — stdout is not parseable JSON**
- Why deferred: design-needed. `workspaceBlueprintPicker` prints the menu and prompt to stdout unconditionally even when `jsonOutput` is true. Fixing this requires either (a) moving picker UI to stderr, or (b) requiring `--blueprint` when `--json` is passed. Both have tradeoffs (stderr changes observability; option (b) is a behavioral restriction). Single reviewer; user should decide.
- Summary: Standard-Codex (finding 7). The problem is real: a `--json workspace new` without `--blueprint` produces non-JSON stdout. The fix direction is a design call.
- Sources: Standard-Codex (finding 7).

**S4: `workspace.export_blueprint` silent overwrite when two names sanitize to the same filename**
- Why deferred: design-needed. When `"my@bp"` and `"my#bp"` both sanitize to `"my-bp.json"`, the second export silently overwrites the first. The correct fix (warn in response payload, or require `--overwrite` flag) is a behavioral design choice. Single reviewer.
- Summary: Critical-Claude (error handling gaps). The behavior is deterministic and safe (atomic write, not corruption), but could surprise operators.
- Sources: Critical-Claude (error handling gaps, point 1).

---

## Evolutionary worth considering (do not apply silently)

**E1: Rename `~/.config/cmux/blueprints/` to `~/.config/c11/blueprints/` with a migration shim**
- Summary: The `cmux` naming in the user-facing blueprints directory is a legacy artifact from before the cmux-to-c11 rename. The path is hardcoded in three places (`WorkspaceBlueprintStore.swift:93`, `TerminalController.swift:4525`, and `runWorkspaceExportBlueprint`). A migration shim would check for the old directory and move contents if present.
- Why worth a look: This will only get more expensive as users accumulate blueprints at the old path. Doing it now (before launch) costs a one-time migration shim; doing it after requires a deprecation period.
- Sources: Evolutionary-Claude (concrete suggestion 1, validated across 3 file locations); Evolutionary-Codex (pattern 3, noted as "anti-pattern to catch early").

**E2: Add a `workspace.get_plan` socket command that returns the current workspace as a `WorkspaceApplyPlan` JSON object without writing to disk**
- Summary: `WorkspacePlanCapture.capture(workspace:)` is already clean and reusable. A new `v2WorkspaceGetPlan` handler would be a thin wrapper: one `v2MainSync` block → `capture` → `JSONEncoder().encode(plan)` → return. Agents could then read workspace topology as structured JSON without side effects.
- Why worth a look: Closes the most obvious gap in the Blueprint/Snapshot API surface — agents can write blueprints via `workspace.export_blueprint` but cannot read the current workspace state as a plan without writing a file first. Low-risk addition (no schema change, follows exact pattern of existing handlers).
- Sources: Evolutionary-Claude (high-value suggestion 2, with implementation sketch and risk assessment).
