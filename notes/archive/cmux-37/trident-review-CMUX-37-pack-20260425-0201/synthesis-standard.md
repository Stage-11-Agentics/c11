## Synthesis: Standard Code Review — CMUX-37
- **Date:** 2026-04-25
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8
- **Models reviewed:** Claude Sonnet 4.6, Codex (GPT-5), Gemini

---

## Executive Summary

All three models independently assessed the branch architecture as sound. `WorkspacePlanCapture` extraction, the three-source Blueprint store design, and the socket threading model each received unambiguous praise. No model found fundamental structural problems.

**Merge verdict: NOT READY.** Three confirmed blockers exist, two of which are unanimous across all three models (the per-repo blueprint CWD miss and the `--all` silent failure). The third blocker (Codex restart command form) was raised independently by Codex and Gemini and is verified against the actual CLI. There are also two Important-level issues unique to Codex that need resolution before the branch is shippable.

---

## 1. Consensus Issues (2+ models agree — highest confidence)

### Blockers

1. **`workspace new` picker silently omits all per-repo blueprints** (Claude + Codex + Gemini all confirm)
   - The CLI calls `workspace.list_blueprints` with `params: [:]`, never passing `cwd`. The socket handler only activates `.cmux/blueprints/` discovery when `params["cwd"]` is present. Per-repo blueprints are entirely non-functional from the primary user-facing command.
   - Fix: `CLI/c11.swift` line 2793 — pass `["cwd": FileManager.default.currentDirectoryPath]`.

2. **`snapshot --all` reports partial write failures as `OK`** (Claude + Codex confirm; Gemini confirms via AgentRestartRegistry focus but the `--all` behavior is implicit in their finding)
   - The socket returns error entries mixed with success entries; the CLI prints `OK path=?` for failed writes with no error signal. Automation consumers will misread a partially-failed `--all` run as fully successful.
   - Fix: `CLI/c11.swift` lines 2947-2952 — check for `snap["error"]` and emit an `ERROR:` prefixed line; exit non-zero if any entry has an error.

3. **Agent restart registry uses invalid/unverified CLI flags** (Codex + Gemini both flag as blocker; Claude flags as Potential)
   - Codex confirmed via `codex --help` that `codex --last` is not a valid invocation; the correct form is `codex resume --last`. The `opencode --continue` and `kimi --continue` flags are unverified and likely do not exist.
   - Tests in `AgentRestartRegistryTests.swift` (lines 252, 263) lock in the wrong behavior.
   - Fix: Update `Sources/AgentRestartRegistry.swift` to use `codex resume --last\n`. Verify or remove `opencode --continue` / `kimi --continue`; fall back to bare launch if flags are unconfirmed.

### Important

4. **`.md` blueprint files appear in picker but fail on apply** (Claude flags Important; Codex flags Important; Gemini flags Potential)
   - The store discovers `.md` files and surfaces them as selectable options. The apply path requires JSON with a top-level `plan` key. A user who picks a genuine Markdown file gets a confusing error only after committing to the selection.
   - Options: remove `.md` from discovery for this JSON-only release, or implement the markdown/frontmatter parser first.

5. **`selectedIndex > 0` guard silently skips re-selection of tab 0** (Claude confirms; others did not raise)
   - See Section 3 for the unique finding detail. Consensus: two models missed this; one confirmed it. Worth fixing regardless.

---

## 2. Divergent Views

### Blocker severity of the restart registry issue

- **Codex** and **Gemini** rate the invalid restart command as a blocker. The tests asserting the wrong command form make this a committed regression.
- **Claude** rates it Potential / best-effort, noting the failure is visible to the operator (not silent) and is consistent with the "best-effort" framing in the registry comments.
- **Synthesis:** Codex's verification against the actual CLI is dispositive. `codex --last` exits 2 with an error; `codex resume --last` is the documented form. The test fixture locks in a known-wrong string. Treat as blocker.

### Severity of the snake_case / camelCase schema mismatch (Codex-unique)

- **Codex** calls the schema/key-format inconsistency a blocker: docs say snake_case, decoder uses camelCase, the new test `WorkspaceBlueprintFileCodableTests.swift:94` will fail in CI with the documented JSON.
- **Claude** and **Gemini** did not raise this finding.
- **Synthesis:** If Codex's read is correct that the existing test uses snake_case keys against a camelCase decoder, it is a CI-failing blocker regardless of the documentation question. This requires independent verification before downgrading. Treat as Important until verified.

### `.md` discovery risk level

- **Codex** rates it Important: the picker shows a file that silently fails, which is a UX defect.
- **Claude** rates it Potential: the design is intentional (JSON-in-disguise), just underdocumented.
- **Gemini** rates it Potential: notes the design is intentional per the context document.
- **Synthesis:** The UX failure mode (file appears in picker, fails after selection) is real even if the design intent is intentional. The error message at minimum needs improvement; removing `.md` discovery is the cleaner fix for this release.

---

## 3. Unique Findings (one model only)

### From Claude only

6. **`selectedIndex > 0` should be `selectedIndex >= 0`** (Important)
   - `WorkspaceLayoutExecutor.swift` line 601 uses `> 0`, which skips `selectTab` when `selectedIndex` is 0. In the normal round-trip this is harmless (tab 0 is the default), but it is semantically wrong and will produce incorrect behavior if bonsplit ever initializes to a non-zero selection. The `validate()` path already guarantees `selectedIndex >= 0` by the time this code runs, so the lower-bound check is purely wrong.
   - Fix: remove the `> 0` lower bound; use `selectedIndex < paneSpec.surfaceIds.count` as the sole guard.

7. **Stale path comment in `WorkspaceBlueprintFile.swift`** (Important)
   - `Source.user` enum case comment at line 33 says `~/.c11-blueprints/`; actual path is `~/.config/cmux/blueprints/`. Will mislead operators and agents reading the type documentation.

8. **`--all` output field ordering differs from single-snapshot output** (Important)
   - `--all` output includes `workspace=WSREF`; single-workspace output omits it despite the socket response including `workspace_ref`. Scripted consumers parsing both modes need to handle inconsistent fields.
   - Fix: add `workspace=` to the single-workspace output for parity.

9. **`WorkspacePlanCapture` silently drops tabs when panel lookup fails** (Lower)
   - Lines 68-69 of `WorkspacePlanCapture.swift` silently skip a tab when `panelID` lookup fails, with no warning in the capture output. Practical risk is low (only live surfaces appear in the tree), but a partial capture produces no diagnostic. A `warnings` array in `WorkspaceApplyPlan` would surface this.

10. **Picker error messages are not localized** (Lower)
    - `workspaceBlueprintPicker` localizes two display strings but leaves cancel, invalid-selection, missing-URL, and file-read-failure errors as bare English. Inconsistent given 7-locale coverage for the display path.

11. **No test for `--all` partial-failure handling** (Lower)
    - No test exercises the case where one workspace write fails in a multi-workspace `--all` run. Finding #2 (silent OK for failures) would have been caught by such a test.

### From Codex only

12. **`WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift` not in test target build phase** (Important — CI-failing)
    - The file reference exists in the Xcode group but the `c11Tests` sources build phase at `project.pbxproj:1251` does not include it. The new browser/markdown round-trip tests will not compile or run in CI.
    - Fix: add the `D8016...` file reference to the `c11Tests` sources phase in `GhosttyTabs.xcodeproj/project.pbxproj`.

13. **`--json` output for `workspace new` contaminated by interactive picker** (Potential)
    - `workspaceBlueprintPicker` prints menu and prompt to stdout unconditionally even when `jsonOutput` is true. `c11 --json workspace new` without `--blueprint` produces unparseable output.
    - Fix: print picker UI to stderr, or reject `--json` when `--blueprint` is not supplied.

14. **Browser snapshot tests do not verify URL round-tripping** (Potential)
    - `BrowserPanel.currentURL` is nil in the headless harness, so the highest-value browser persistence behavior is explicitly not verified. Call out as a residual CI gap or add a runtime seam to seed/observe browser URLs.

### From Gemini only

15. **Schema documentation imprecise on metadata value types** (Important)
    - `docs/workspace-apply-plan-schema.md` is internally inconsistent: `WorkspaceSpec.metadata` says strings only; `SurfaceSpec.metadata` / `pane_metadata` says JSON-serializable; the implementation allows `PersistedJSONValue` for workspace metadata. The docs do not accurately describe the actual behavior.
    - Fix: update `workspace-apply-plan-schema.md` to specify the actual permitted types per metadata location, including the `mailbox.*` string-only restriction.

---

## 4. Consolidated Issue List

### Blockers (must fix before merge)

1. `workspace.list_blueprints` never receives `cwd` from CLI — per-repo blueprints non-functional in picker. Fix: `CLI/c11.swift:2793`.
2. `snapshot --all` prints `OK` for failed workspace writes — silent partial failure. Fix: `CLI/c11.swift:2947-2952`.
3. `codex --last` is not a valid CLI invocation; correct form is `codex resume --last`. Tests assert wrong command. Fix: `Sources/AgentRestartRegistry.swift:123`, `AgentRestartRegistryTests.swift:252,263`.
4. (Verify) snake_case docs vs. camelCase decoder in `WorkspaceApplyPlan.swift` — if `WorkspaceBlueprintFileCodableTests.swift:94` uses snake_case keys it will fail in CI. Needs verification; treat as blocker until confirmed otherwise.
5. `WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift` missing from `c11Tests` build phase — tests do not run in CI. Fix: `GhosttyTabs.xcodeproj/project.pbxproj`.

### Important (fix before or immediately after merge)

6. `.md` blueprint files listed in picker but fail JSON parse on apply. Fix: remove `.md` from discovery or implement frontmatter parser.
7. `selectedIndex > 0` should be `selectedIndex >= 0` (or remove lower bound) in `WorkspaceLayoutExecutor.swift:601`.
8. Stale path comment `~/.c11-blueprints/` in `WorkspaceBlueprintFile.swift:33` — should be `~/.config/cmux/blueprints/`.
9. `--all` output includes `workspace=` field; single-snapshot output omits it — scripting inconsistency.
10. Schema doc imprecise on metadata value types — `workspace-apply-plan-schema.md` does not match implementation.
11. `opencode --continue` / `kimi --continue` flags unverified — verify or fall back to bare launch.

### Potential / Lower priority (defer to follow-up)

12. `--json workspace new` contaminated by picker stdout — should print picker UI to stderr.
13. Browser snapshot tests do not verify URL round-trip — document as known CI gap.
14. `WorkspacePlanCapture` silent tab drop on panel lookup failure — consider `warnings` array in schema.
15. Picker error messages not localized despite 7-locale display string coverage.
16. No test for `snapshot --all` partial-failure path.

---

## 5. CLAUDE.md Constraint Audit (aggregated)

| Constraint | Claude | Codex | Gemini | Status |
|---|---|---|---|---|
| Localization: all 7 locales, `String(localized:)` pattern | Pass | Not audited | Not audited | Pass |
| Socket threading: off-main parse, `v2MainSync` for AppKit | Pass | Not audited | Not audited | Pass |
| Typing-latency paths untouched | Pass | Not audited | Not audited | Pass |
| Test quality: no AST/source-text assertions | Pass | Not audited | Not audited | Pass |
| Test policy: CI-only markers present | Pass | Partial (file not in build phase) | Not audited | FAIL — finding #12 |
| Agent restart registry command correctness | Potential | FAIL | FAIL | FAIL — finding #3 |
