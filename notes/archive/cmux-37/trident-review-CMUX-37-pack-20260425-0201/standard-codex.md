## Code Review
- **Date:** 2026-04-25T06:35:12Z
- **Model:** Codex (GPT-5)
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8b1531bfc77529bc3663cdafeaa5cb11e
- **Linear Story:** CMUX-37
---

## General Feedback

This branch has the right architectural direction: extracting `WorkspacePlanCapture` is a good consolidation point, and layering Blueprints/Snapshots over `WorkspaceApplyPlan` keeps the persistence model understandable. The implementation is also mostly scoped to the new surfaces, CLI/socket handlers, and runtime-style tests.

The merge is not ready yet. There are two concrete blockers: the new Codex restart command is invalid for the installed CLI, and the schema/key-format story is inconsistent enough to produce a failing committed test and docs that direct users toward JSON the socket does not decode. I also found several important feature gaps around per-repo blueprint discovery, `snapshot --all` error handling, and test target coverage.

Validation notes: I did not run local XCTest, per this repo's `CLAUDE.md` testing policy. I also did not run `git pull` because the review prompt required no existing-file modifications beyond this review file. I reviewed `origin/main...HEAD`, inspected the changed source, and validated restart CLI flags with `codex --help`, `codex --last --help`, `opencode --help` with cache redirected to `/tmp`, and `kimi --help`.

## Findings

### Blockers

1. ✅ Confirmed - `Sources/AgentRestartRegistry.swift:123` returns an invalid Codex restart command. The row emits `codex --last\n`, but the installed Codex CLI rejects that form: `codex --last --help` exits 2 with `unexpected argument '--last' found`. `codex --help` shows the supported resume path is the `resume` subcommand with `--last`, so restored Codex panes will fail at the shell prompt instead of resuming. The tests currently lock in the wrong behavior at `c11Tests/AgentRestartRegistryTests.swift:252` and `c11Tests/AgentRestartRegistryTests.swift:263`; update the row and tests to use the real command form, likely `codex resume --last\n`.

2. ✅ Confirmed - `docs/workspace-apply-plan-schema.md:3` says the plan JSON uses snake_case wire names, but `v2WorkspaceApply` decodes with a plain `JSONDecoder()` at `Sources/TerminalController.swift:4368` and the structs use synthesized camelCase keys such as `workingDirectory`, `filePath`, `paneMetadata`, `surfaceIds`, and `selectedIndex` at `Sources/WorkspaceApplyPlan.swift:29`, `Sources/WorkspaceApplyPlan.swift:68`, `Sources/WorkspaceApplyPlan.swift:75`, `Sources/WorkspaceApplyPlan.swift:84`, and `Sources/WorkspaceApplyPlan.swift:153`. JSON following the docs examples for `working_directory`, `file_path`, or `pane_metadata` will silently lose optional fields or fail on required fields like `surface_ids`. The new test at `c11Tests/WorkspaceBlueprintFileCodableTests.swift:94` also uses an invalid snake_case layout shape and should fail in CI. Pick one wire convention, implement explicit `CodingKeys` or decoder strategy if snake_case is intended, then update the shipped blueprints, docs, and tests to match.

### Important

3. ✅ Confirmed - `c11 workspace new` does not send the CLI working directory to `workspace.list_blueprints`, so per-repo blueprints are omitted from the default picker. The store only scans repo blueprints when `merged(cwd:)` receives a non-nil cwd (`Sources/WorkspaceBlueprintStore.swift:122`), and the socket handler only sets that from `params["cwd"]` (`Sources/TerminalController.swift:4472`). The CLI picker calls the method with `params: [:]` at `CLI/c11.swift:2793`. Result: `.cmux/blueprints` discovery works in tests and for direct socket callers that know to pass `cwd`, but the primary user command only shows user and built-in blueprints. Pass `FileManager.default.currentDirectoryPath` from the CLI.

4. ✅ Confirmed - `c11 snapshot --all` reports partial write failures as successful `OK` lines. The socket appends per-workspace error dictionaries but still returns `.ok(["snapshots": results])` at `Sources/TerminalController.swift:4597` and `Sources/TerminalController.swift:4605`. The CLI then prints `OK snapshot=... path=?` without checking `error` at `CLI/c11.swift:2947`. Automation and users will believe all snapshots were written even when some failed. Return an error when any workspace write fails, or have the CLI surface failures and exit non-zero.

5. ✅ Confirmed - `.md` blueprint files are listed as selectable even though the apply path requires a JSON envelope. `WorkspaceBlueprintStore` admits every `.md` file at `Sources/WorkspaceBlueprintStore.swift:197` and indexes markdown entries by filename without decoding at `Sources/WorkspaceBlueprintStore.swift:223`. The picker/direct apply path then runs `JSONSerialization` and requires a top-level `plan` key at `CLI/c11.swift:2841`, so a markdown blueprint can appear in the picker and then fail only after selection. Either remove `.md` discovery for this JSON-only implementation, or implement the documented markdown/frontmatter parser before listing those files.

6. ✅ Confirmed - `WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift` is added to the project group but not to the test target's sources build phase. The file reference appears in the group, but the test sources list at `GhosttyTabs.xcodeproj/project.pbxproj:1251` only includes `WorkspaceBlueprintFileCodableTests.swift` and `WorkspaceBlueprintStoreTests.swift` from this batch. That means the new browser/markdown round-trip coverage will not compile or run in CI. Add the `D8016... in Sources` build file to the `c11Tests` sources phase.

### Potential

7. ✅ Confirmed - `--json` output for `c11 workspace new` can be contaminated by the interactive picker. `workspaceBlueprintPicker` accepts `jsonOutput` but prints the menu and prompt to stdout unconditionally at `CLI/c11.swift:2804` and `CLI/c11.swift:2818`. If a caller runs `c11 --json workspace new` without `--blueprint`, the output is not parseable JSON. Consider printing picker UI to stderr, or rejecting `--json` unless `--blueprint` is supplied.

8. ❓ Uncertain - The new browser snapshot tests explicitly do not verify URL round-tripping because `BrowserPanel.currentURL` is nil in the headless harness. That leaves the highest-value browser persistence behavior unverified. If there is a small runtime seam to seed or observe browser URLs without WebKit navigation callbacks, add it; otherwise call out this residual CI gap in the PR notes.
