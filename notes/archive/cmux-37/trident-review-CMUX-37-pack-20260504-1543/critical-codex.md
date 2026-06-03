## Critical Code Review
- **Date:** 2026-05-04T19:58:20Z
- **Model:** Codex (GPT-5)
- **Branch:** cmux-37/final-push
- **Latest Commit:** aea6eaa8cf308fa60f69260bec91ffefe2615850
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

This branch closes several smoke gaps, but the new set-restore path has a bad operator contract: it can print `ERROR` rows and still exit successfully, and it can print `OK` rows while suppressing per-workspace executor failures. That is exactly how a restore workflow gets marked green while panes, metadata, commands, or workspace contents are wrong.

I did not run local tests. Project policy forbids local tests for this repo; CI/VM must be the source of truth. I also did not fetch/pull because the wrapper prompt explicitly limited this review to read-only inspection plus writing this single review file.

## What Will Break

1. `c11 restore <set-id>` will return success even when one or more snapshots in the set fail to read, convert, or validate. The CLI prints an `ERROR` line for those entries, then returns normally.
2. `c11 restore <set-id>` will print `OK snapshot=...` for workspaces whose `ApplyResult.failures` contains real executor failures. Users looking at the normal CLI output will not see those failures.
3. `c11 restore /path/to/set.json` only stages the set manifest, not the referenced inner snapshot files. Restoring a set manifest from an archive or alternate directory will fail unless the inner snapshots already happen to exist under `~/.c11-snapshots/`.
4. Hand-authored Markdown blueprints can be malformed and still parse into a different layout than the author wrote. Extra top-level layout roots are silently ignored, and invalid `direction:` values silently become horizontal.

## What's Missing

Missing behavioral coverage for `snapshot.restore_set` through the CLI: one inner read failure should produce a non-zero exit, and one inner `ApplyResult.failures` entry should be rendered with the same failure/info partitioning as single restore.

Missing coverage for path-based set restore from a non-default directory. The implementation should prove either that a set manifest path is intentionally non-portable, or that adjacent/contained inner snapshots are staged with the manifest.

Missing parser rejection tests for malformed Markdown layouts: multiple top-level `layout:` entries and unknown split directions should fail loudly.

## The Nits

`c11 restore --help` says to select a restored workspace with `c11 workspace select <ref>`, but `workspace` only supports `apply`, `new`, and `export-blueprint`. The real command surface is `select-workspace --workspace <ref>` or another existing focus-intent command.

Top-level usage still omits `--format md|json` from the short `workspace export-blueprint` command line, even though the subcommand help includes it.

## Blockers

1. ✅ Confirmed - Set restore hides failures and still exits successfully. In [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-final-push/CLI/c11.swift:3489), the set restore renderer prints embedded `error` rows and continues; it then returns normally at line 3507 with no aggregate failure. For rows without `error`, it prints `OK` using only `workspaceRef` and `surfaceRefs` at lines 3496-3500 and never inspects the row's `failures` array. The server intentionally embeds per-workspace errors/results in an `.ok` payload from [Sources/TerminalController.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-final-push/Sources/TerminalController.swift:5201), so the CLI must promote those errors/failures to a non-zero restore outcome. This can make a partially failed multi-workspace restore look successful.

## Important

1. ✅ Confirmed - Path-based set restore is not actually self-contained. `importSnapshotOrSetFileForRestore` classifies a set manifest and copies only that JSON file into `~/.c11-snapshots/sets/` at [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-final-push/CLI/c11.swift:3607). The restore handler later reads each inner snapshot only by id from the default/legacy snapshot roots at [Sources/TerminalController.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-final-push/Sources/TerminalController.swift:5104). A user restoring `/backup/sets/<id>.json` after moving/copying a snapshot set will get missing-snapshot errors unless the inner files are already staged separately.

2. ✅ Confirmed - The Markdown parser silently accepts malformed layout structure. `parse` takes only `layoutList.first` at [Sources/WorkspaceBlueprintMarkdown.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-final-push/Sources/WorkspaceBlueprintMarkdown.swift:133), so any additional top-level layout nodes are dropped. `buildLayoutTree` treats every non-`vertical` direction as horizontal at line 301. For a human-authored format, this is dangerous: bad input should fail with a useful error, not materialize a truncated or direction-flipped workspace.

## Potential

1. ❓ Likely but hard to verify - `snapshot --all` writes inner snapshots first and the manifest second. If the manifest write fails, the CLI reports failure, but the default snapshot directory is left with successful inner snapshots from a failed set capture. That may be acceptable as partial salvage, but it should be an explicit contract and tested because operators will treat `--all` as one restorable artifact.

2. ⬇️ Real but lower priority than initially thought - `metadata_override` is blanket-classified as info in the CLI. The capture-side fix strips exact duplicate title metadata, so clean round-trips should be quieter. But a truly divergent user-authored `metadata["title"]` conflict is now downgraded in normal output. If this is intentional, the structured payload should carry severity rather than relying on client-side code/message heuristics.

## Validation Pass

I re-read the set restore execution path end to end: `runSnapshotRestore` chooses `snapshot.restore_set`, `v2SnapshotRestoreSet` loops over manifest entries and returns `.ok(["workspaces": workspaceResults])`, then the CLI renderer prints embedded errors without throwing and ignores embedded `failures` on otherwise encoded `ApplyResult` rows. The blocker is real.

I traced path-based set import: the CLI stages only the manifest based on top-level `set_id`; no code walks the manifest entries or stages adjacent inner snapshot files before the socket reads `entry.snapshotId` by id. The important finding is real.

I traced the Markdown parser: the root `layout:` list is not cardinality-checked and direction has no validation branch. The parser findings are real.

## Closing

Not ready for production. I would not mass deploy this to 100k users until set restore reports partial failures with a failing exit status and surfaces inner `ApplyResult.failures` just like single restore. The parser and path-staging issues should be fixed before telling operators that Markdown blueprints and set-manifest paths are dependable.
