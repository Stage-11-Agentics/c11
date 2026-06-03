## Code Review
- **Date:** 2026-05-04T19:57:47Z
- **Model:** Codex / GPT-5
- **Branch:** cmux-37/final-push
- **Latest Commit:** aea6eaa8cf308fa60f69260bec91ffefe2615850
- **Linear Story:** CMUX-37
---

General feedback: the branch is directionally aligned with the five smoke gaps. It keeps the snapshot/apply path app-side, preserves legacy c11/cmux read locations, adds focused value-level tests for the new Markdown and set-manifest types, and does not touch the documented typing-latency hot paths.

Validation note: I did not run local tests because `CLAUDE.md` forbids local test execution. I also did not fetch/pull because the review prompt constrained this to read-only work except for this file. I used the provided merge-base for local diff review and GitHub PR #118 status for CI ground truth. PR head `aea6eaa8` has `Build GhosttyKit` and `CI` green, but `macOS Compatibility` and `Mailbox parity` failing.

### Blockers

1. ✅ Confirmed — CI is red on the PR head and must be resolved before merge.

   `macOS Compatibility / compat-tests (macos-15, 30, true, false)` fails in the `Smoke test` step: the app launches, answers `PONG`, then crashes during the scripted terminal send path with `Trace/BPT trap: 5`; the workflow reports `ERROR: App crashed during 15s stability check`.

   `Mailbox parity / mailbox-unit` fails before tests run because the `c11-unit` target does not compile: `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:480` cannot convert `String` to `TabID`, and `:500` has a generic parameter conflict between `String?` and `TabID`. The log reports 2 Swift compile errors and the xcodebuild summary reports 4 failed build/test commands.

### Important

2. ✅ Confirmed — `workspace export-blueprint --out` can create files whose extension disagrees with their contents.

   In `CLI/c11.swift:3206-3225`, the CLI decides the output format from `--format` or defaults to `md`, asks the socket to write that default-format file, then `CLI/c11.swift:3228-3240` blindly moves it to `--out`. So `c11 workspace export-blueprint --name foo --out /tmp/foo.json` writes Markdown bytes into `foo.json`; later `workspace new --blueprint /tmp/foo.json` dispatches by extension in `CLI/c11.swift:3125-3145` and tries to parse it as JSON. The inverse (`--format json --out foo.md`) has the same problem. Either infer format from `--out`, require extension/format agreement, or rewrite after resolving the final path.

3. ✅ Confirmed — snapshot-set restore hides per-workspace executor failures in human CLI output.

   `TerminalController.v2SnapshotRestoreSet` encodes the full `ApplyResult` for each restored snapshot into each row, including `failures`, at `Sources/TerminalController.swift:5168-5175`. The non-JSON CLI path in `CLI/c11.swift:3489-3500` only checks for a top-level `error`; if the executor created a workspace but emitted real `ApplyFailure` rows, the command still prints `OK snapshot=...` and never renders or partitions those failures. That makes `c11 restore <set-id>` less trustworthy than single-workspace restore and can mask partial materialization failures across a multi-workspace restore.

4. ✅ Confirmed — the Markdown blueprint parser silently coerces invalid split directions to horizontal.

   `WorkspaceBlueprintMarkdown.buildLayoutTree` reads `direction` and maps only `"vertical"` to vertical; every other value becomes horizontal (`Sources/WorkspaceBlueprintMarkdown.swift:301-304`). For a hand-authored format, `direction: diagonal` or a typo like `horiztonal` should fail loudly, not materialize the wrong layout. This is exactly the parser-fragility class the review prompt called out.

5. ✅ Confirmed — the legacy `new-workspace --layout` path still cannot consume Markdown blueprints.

   The new `workspace new --blueprint` command routes `.md` files through `blueprintPlanFromFile` (`CLI/c11.swift:3021-3028`, `:3125-3138`), but the existing `new-workspace --layout` command still calls `resolveBlueprintPlan` (`CLI/c11.swift:1986-2000`), whose direct-path and by-name branches only decode JSON envelopes (`CLI/c11.swift:3151-3175`). Since this branch makes Markdown the default exported blueprint format, the older advertised layout path will fail for the new default artifacts. If `new-workspace` remains supported, it should share the same Markdown-aware resolver.

### Potential

6. ❓ Uncertain — set manifest portability may be lower than operators expect from a "bundle".

   Path-based restore for a set manifest stages only the manifest itself under `~/.c11-snapshots/sets` (`CLI/c11.swift:3420-3428`, `:3607-3612`), and set restore later resolves each inner workspace with `store.read(byId:)` (`Sources/TerminalController.swift:5100-5105`). That works for manifests created on the same machine where the inner per-workspace snapshots are still present, but a copied manifest file alone is not restorable. This may be acceptable because the implementation defines the manifest as a pointer file, but if the user-facing contract says "bundle", document the limitation or include enough path/data to move the set as a unit.

7. ⬇️ Lower priority — `snapshot.restore_set` ignores `selected_workspace_index` and relies only on per-entry `selected`.

   The manifest writes both `selected_workspace_index` and `Entry.selected` (`Sources/TerminalController.swift:4774-4805`), but restore uses only `entry.selected` (`Sources/TerminalController.swift:5174-5177`). That is fine for files produced by this writer, but hand-edited or future manifests with only the set-level index will not restore selection as documented by the schema comments in `Sources/WorkspaceSnapshotSet.swift:53-56`.
