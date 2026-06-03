## Critical Code Review
- **Date:** 2026-05-04T15:43:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** cmux-37/final-push
- **Latest Commit:** aea6eaa8
- **Linear Story:** CMUX-37
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

The shape is right. Markdown blueprints, the manifest envelope, the `info:` reclassification, the two-level `--help` dispatch, and the `C11_SOCKET` env precedence all do what the smoke gaps demanded. The diff stays inside the bundle; nothing reaches into `~/.claude` or `~/.codex`; the security pre-checks on snapshot ids carry over to the new set path. Several pieces show real care — the comment block over `failureSeverity` actually names the executor line + symbol the matcher depends on, and the per-snapshot envelope still works through the legacy bare-id path. That's the half that earned trust.

The other half hasn't earned it yet.

This PR ships three primitives whose runtime behavior is not exercised by a single test: the new manifest writer (`WorkspaceSnapshotStore.writeSet` / `readSet` / `listSets` / `setManifestExists`), the `failureSeverity` substring classifier, and the `C11_SOCKET` env-precedence resolver. The Codable round-trip tests on `WorkspaceSnapshotSetFile` cover the wire shape and nothing else. There are even debug test seams exposed for `failureSeverity` (`debugFailureSeverityForTesting`, `debugPartitionFailuresForTesting`) that are dead — they're called from the CLI binary alone, no XCTest target uses them. That's not "tests we couldn't write" — it's tests we wired up and forgot to write.

The hand-rolled YAML subset under `## Layout` is the next time bomb. It's adequate for what `serialize()` emits, and the parser-fragility tests cover three negative cases. It is not adequate for hand-authored input. Trailing `# comment` after a value isn't stripped (it gets glued onto the value); negative split ratios pass the guard (`-50/100` → `-1.0`); split at the boundaries (`100/0`, `1.0`) bypasses validation. Operators are explicitly invited to hand-author these files, so the parser should be loud, not lenient.

The biggest live runtime concern is `v2SnapshotRestoreSet` blocking the main actor inside the loop. Each entry calls `v2MainSync` (unbounded), which is `DispatchQueue.main.sync` — no deadline. Five workspaces × ~1s each cleanly exceeds the CLI's 10s receive timeout, leaving the CLI to surface "timeout" while the server keeps applying. If a workspace hangs the executor, the whole set hangs the main actor.

Net: this PR is close but not done. Land it once the manifest, classifier, env-resolver, and parser-fragility gaps are tested, and the restore_set main-actor pattern is bounded. The smoke fixes are real; I'd ship them. I would not ship them without the gaps closed.

## What Will Break

### Blockers

1. **`v2SnapshotRestoreSet` blocks the main actor for the full duration of an N-workspace restore.**
   - File: `Sources/TerminalController.swift` lines 5101–5187 (the for-loop), 5145–5159 (per-iteration `v2MainSync`).
   - Each entry runs the executor inside `v2MainSync { ... }`. Unlike `v2MainSyncWithDeadline` (TerminalController.swift:3258), `v2MainSync` (line 3246) has no timeout. A set with five workspaces, each taking ~2 s in the executor, blocks main for ~10 s — which is exactly the CLI's `SocketClient.configuredDefaultDeadlineSeconds`. The CLI fails with a receive timeout while the server keeps applying. The executor's `kTier1MainThreadDeadlineSeconds = 8.0` constant exists *because* this matters; restore_set ignores it.
   - Compounding: every entry in the loop also runs `WorkspaceSnapshotConverter.applyPlan` and `WorkspaceLayoutExecutor.validate` in the loop body off-main, but only after `read(byId:)`. If the inner snapshot file hangs on `Data(contentsOf:)` (slow disk), the loop accumulates main-actor blocking through subsequent iterations.
   - Fix candidates: (a) move executor calls to `v2MainSyncWithDeadline` and convert per-entry timeouts into per-entry failure rows; (b) batch the apply work into a single main-actor closure but yield between entries; (c) cap manifest size with a hard limit and reject larger sets at write time.

2. **`v2SnapshotCreate --all` is not atomic across the per-workspace + manifest writes, but the CLI exits non-zero only when "one or more writes failed".**
   - File: `CLI/c11.swift` lines 3294–3317; `Sources/TerminalController.swift` lines 4762–4818.
   - On a partial-write failure, the manifest still ships, listing only successful entries (by design per the comment). The CLI reports `anyFailure` based on `error` rows in the per-snapshot list, but if those wrote successfully and only the *manifest* failed, the CLI sets `anyFailure = true` from `set_error` — that part's fine. However: when an inner write fails AND the manifest succeeds, the manifest is silently truncated. An operator running `c11 snapshot --all` then `c11 restore <set-id>` recovers a partial workspace topology with no warning that they lost workspaces. The successful inner snapshots are still on disk and discoverable via `c11 list-snapshots`, but the *set* lies about being a complete capture.
   - Fix candidates: (a) abort manifest write on any inner failure and surface as a hard error; (b) annotate the manifest entry with an "incomplete: true" field and have `restore_set` warn loudly; (c) keep current behavior but make the CLI's success message say "OK set=X workspaces=K (Y failed, set lists only K successes)".

3. **No tests for the new `WorkspaceSnapshotStore` set-IO surface.**
   - Files added: `Sources/WorkspaceSnapshotStore.swift` lines 196–335 (writeSet, readSet, setManifestExists, listSets, defaultSetsDirectory, sets-dir filtering rationale).
   - Tests added: `c11Tests/WorkspaceSnapshotSetCodableTests.swift` — only exercises `Codable` on the value types. None of `writeSet` (atomicity, dir creation, snapshot-id safety check), `readSet` (notFound, decode failure on legacy date format, path-escape guard), `setManifestExists` (false on missing, true on present, false on unsafe id), or `listSets` (sort order, malformed-row skipping, empty dir, missing parent dir) is tested at the runtime-behavior level the project policy requires.
   - The closest comparable surface, `WorkspaceSnapshotStoreSecurityTests.swift`, exists for the per-snapshot path and demonstrates the right shape. The new manifest path needs the equivalent.
   - This is the single highest-leverage gap to close before landing.

### Important

4. **`failureSeverity` substring matcher is user-influenceable through `cwd`, and is untested at the runtime level.**
   - File: `CLI/c11.swift` lines 2882–2889. Executor message format: `Sources/WorkspaceLayoutExecutor.swift` lines 850–851 — `"surface[\(spec.id)] workingDirectory='\(cwd)' ignored: \(context) path does not accept an explicit cwd"`.
   - The matcher checks `message.contains("seed terminal reuse")`. The `cwd` segment in that message is operator-controlled. A path containing the literal string "seed terminal reuse" silently downgrades a real `working_directory_not_applied` failure to info. Vanishingly unlikely in practice, but the contract leaks: there is no firewall between executor diagnostic context strings and operator-controlled bytes.
   - Two paths: (a) move classification to the executor and ship it as a structured `severity: "info"` field on the failure (the comment block on line 2876–2881 acknowledges this is fragile and asks future readers to update on context changes — that's a maintenance burden by design); (b) tighten the matcher to require an exact suffix or a known sentinel (`context: "seed terminal reuse (cwd fixed at workspace creation)"` is what the executor emits, so `message.hasSuffix("does not accept an explicit cwd")` plus a code/context check on a structured field).
   - Until then: at minimum add unit tests via the existing `debugFailureSeverityForTesting` seam (`CLI/c11.swift:14957`) that lock in the four real-world cases (browser split, markdown split, browser/markdown in-pane, seed terminal reuse) and one adversarial input (cwd containing the marker).

5. **`parseSplitRatio` accepts negative and out-of-range integer ratios.**
   - File: `Sources/WorkspaceBlueprintMarkdown.swift` lines 370–386.
   - `parseSplitRatio("-50/100")` → lhs=-50, rhs=100, sum=50, returns -1.0. Guard requires `(lhs+rhs) > 0`, not non-negativity of each side.
   - `parseSplitRatio("100/0")` → lhs=100, rhs=0, sum=100, returns 1.0. The decimal branch's `v > 0, v < 1` does NOT apply (different code path); integer branch returns the boundary.
   - Both pass downstream into the executor. The split divider is expected to live in (0, 1); 0.0 / 1.0 / negative all break layout assumptions silently. The decimal branch already enforces strict (0, 1); integer branch should match.
   - Fix: extend the integer-branch guard to `lhs > 0, rhs > 0` (and the decimal-branch `v > 0, v < 1` is correct).

6. **YAML subset doesn't strip trailing `# comment` from values; hand-authored blueprints will silently glue comments into titles/cwds.**
   - File: `Sources/WorkspaceBlueprintMarkdown.swift` `YAML.tokenize` (lines 600–615) and `parseMapping` (lines 630–653).
   - `tokenize` only drops *whole-line* comments (`trimmed.hasPrefix("#")`). A line like `cwd: ~/work # legacy` produces a value of `~/work # legacy`. On round-trip via `serialize`, `quoteIfNeeded` will wrap it in quotes (because the value contains `#`), so the output stays valid; but the operator's intent — an inline comment — is lost without warning.
   - This is a hand-author affordance the docstring promises (`# comment` lines). The minimal fix: strip an unquoted, whitespace-prefixed `#...$` tail from values during parse.

7. **`isLocalSnapshotSetId` probes set-first; a stale or hand-deleted manifest can mislead a bare-id restore.**
   - File: `CLI/c11.swift` lines 3434–3439, 3544–3555.
   - The polymorphic `c11 restore <id>` checks `~/.c11-snapshots/sets/<id>.json` first. If a manifest exists for an id but the operator intended the snapshot of the *same* id (theoretically possible if hand-edited or copied), the CLI silently picks set restore. ULIDs prevent practical collisions, but the dispatch makes set-restore irrecoverable from CLI absent flag override.
   - Lower priority because of ULID grammar. Worth noting because: (a) there's no `--set` / `--snapshot` disambiguator, (b) operators can delete the manifest and lose the ability to address the set without re-running snapshot --all.

8. **Localized strings with raw interpolation.**
   - File: `CLI/c11.swift` lines 1484–1492; `Sources/WorkspaceBlueprintMarkdown.swift` lines 73–119.
   - `String(localized: "cli.socket.autoDiscoveredWithSource", defaultValue: "c11: using socket \(resolvedPath) (auto-discovered from \(source))")` will work, but the auto-generated placeholders for translators (`%@`) require the xcstrings to be re-synced. Per CLAUDE.md, "After adding or changing English strings, spawn a translator." I see no evidence the six locale strings were synced; the six target locales (`ja`, `uk`, `ko`, `zh-Hans`, `zh-Hant`, `ru`) need entries for these new keys.
   - Verify `Resources/Localizable.xcstrings` has the new keys. If not, the localization pass is a missing chore.

### Potential

9. **`v2SnapshotRestoreSet` reads the manifest but silently drops entries with malformed ids.** `WorkspaceSnapshotStore.read(byId:)` validates `isSafeSnapshotId` (line 386); a hand-crafted manifest with `snapshot_id: "../foo"` lands as a per-entry error in `workspaceResults` rather than rejecting the whole manifest. That's the safer choice but means a partially-evil manifest gets partially applied. Document this; consider rejecting manifests where any entry id fails the safety check.

10. **`v2SnapshotCreate --all` race window.** Two concurrent `--all` runs (e.g., a CI smoke test and a user) could each generate a set id and write manifests; per-snapshot writes are atomic per file, so no corruption, but the second invocation overwrites neither. Fine in practice; flag if observability matters.

11. **`enumerate` in `WorkspaceSnapshotStore.list()` (line 476) reads the full per-snapshot envelope summary but `listSets` (line 292) uses raw JSONSerialization and silently skips unparseable rows.** Asymmetric: a corrupt per-snapshot file shows up as `unreadable`; a corrupt set manifest disappears. Either both should be loud or both should be best-effort. Lean toward both being best-effort with a count, since manifests are pointers.

12. **`v2WorkspaceListBlueprints` at `Sources/TerminalController.swift:4558` runs `JSONEncoder().encode(entries)` on the socket thread, encoding `Date` as `iso8601` — the rest of the CMUX-37 surface uses `workspaceSnapshotDateFormatter` (fractional seconds). A `modifiedAt` from disk (FS attribute) will round-trip differently between this method and `snapshot.list_sets`. Likely harmless because no caller round-trips through both, but the inconsistency is a future foot-gun.

13. **`WorkspaceBlueprintMarkdown.serialize` drops `selectedIndex == 0` (line 451) and parser returns nil for missing.** A round-trip of `PaneSpec(surfaceIds: [...], selectedIndex: 0)` becomes `selectedIndex: nil`. Edge case (no semantic difference for index 0 of a single-tab pane) but breaks structural equality on the value type.

14. **No test for `C11_SOCKET` precedence over `CMUX_SOCKET_PATH` over `CMUX_SOCKET`.** Three call sites: `CLI/c11.swift:167`, `:1450`, `:1500`, `:12704`. All four hand-roll the same precedence list. One easy refactor away from a single source of truth, and zero tests pinning the order today.

15. **Help text routing assumes `commandArgs.first(where: { !$0.hasPrefix("-") })` is the subcommand.** A future flag with a value that happens to be a known subcommand (e.g., `--workspace apply`) wouldn't trip this because flag values would also lack the `-` prefix. The current dispatch can be confused by `c11 workspace --json apply` (filter strips `--json`, takes `apply`, OK) but breaks on `c11 workspace --target apply` if `--target` is added later. Lock with a positional/flag separator if more flags accrete.

## What's Missing

- **`WorkspaceSnapshotStoreSetTests.swift`** — atomicity, traversal-rejection, dir creation, missing-id, malformed manifest, sort order, sets-dir excluded from per-snapshot enumeration. Pattern is the per-snapshot security tests already in the project.
- **`FailureSeverityClassificationTests.swift`** — exercise the seam already exposed at `CLI/c11.swift:14957`. Lock in the matrix of (code, context, severity).
- **`CLISocketEnvPrecedenceTests.swift`** — one test, four cases: each var alone, all three set, all three empty.
- **`WorkspaceBlueprintMarkdownYAMLEdgeCases.swift`** — negative split ratios, boundary ratios, trailing inline `#` comments, `tabs:` round-trip, `selected:` index, mixed-line-ending input. The current test file covers the happy path and three error cases; the parser fragility lives in the grey zone between.
- **`v2SnapshotRestoreSetTests.swift`** — at minimum a fake `TabManager` exercising the per-entry failure rows and the focus-policy gating. Even one test of "manifest references a missing snapshot id" would catch a regression in the loop's error-row construction.
- **Localization sync** — verify `Resources/Localizable.xcstrings` has entries for all new `String(localized:)` keys across the six required locales.

## The Nits

- `Sources/TerminalController.swift:4642` and `:5067` shadow the variable name `err` in the catch arm — Swift accepts but the convention elsewhere in the file is `error`; consistency matters in a 14k-line file.
- `Sources/WorkspaceSnapshotStore.swift:131` doc comment for `write(_:to:)` says "**Do not call this path from socket handlers**" — but the path is a `func`, not a `// nocommit` lint marker. A doc-only constraint is fine, but a `@available(*, message: "use writeToDefaultDirectory from socket handlers")` would carry the warning into IDE.
- `Sources/WorkspaceBlueprintMarkdown.swift:283` `SurfaceIDGenerator` mints `s1`, `s2`. If a parent capture path (`WorkspacePlanCapture`) also mints `s1`, `s2`, the ids collide between blueprint and capture. They never coexist in the same `WorkspaceApplyPlan`, so this is fine today; flag if `apply` ever merges blueprints.
- `CLI/c11.swift:1494` writes one stderr line via `Data((line + "\n").utf8)`. Operators piping `c11 list-snapshots --json` into `jq` will get this line on stderr and the JSON on stdout. Correct, but the line is suppressible only via `C11_QUIET_DISCOVERY=1`. If automation can't be expected to set that, consider auto-suppressing when stdout is a pipe (`isatty(STDOUT_FILENO) == 0`).
- `Sources/WorkspaceSnapshotStore.swift:60–67` doc comment says `enumerate(directory:source:)` filters non-recursive; verify against `listSets` which uses the same primitive — consistent.

## Validation Pass

1. **Blocker 1 — restore_set blocks main actor:** ✅ Confirmed. `v2SnapshotRestoreSet` calls `v2MainSync` per entry (line 5145). `v2MainSync` (TerminalController.swift:3246) does plain `DispatchQueue.main.sync` with no timeout. A 5-workspace set, each with a slow restore, blocks main for the sum. The CLI deadline is 10s (mentioned at `kTier1MainThreadDeadlineSeconds = 8.0`'s comment). Easy to reproduce: set up a 6-workspace set where one inner snapshot has a hung executor path, and the CLI will time out before the executor finishes the others.

2. **Blocker 2 — `--all` partial atomicity:** ✅ Confirmed by reading TerminalController.swift:4762–4818. Manifest writes on `!entries.isEmpty` regardless of `anyWriteFailed`. The CLI in `CLI/c11.swift:3294–3317` reports `set_error` from manifest failure but does not warn when manifest succeeds with truncated entries.

3. **Blocker 3 — no tests for store set IO:** ✅ Confirmed. `grep -l "writeSet\|listSets\|readSet" c11Tests/*.swift` returns empty. The Codable tests in `WorkspaceSnapshotSetCodableTests.swift` cover wire shape only.

4. **Important 4 — failureSeverity untested + cwd-influenceable:** ✅ Confirmed. `grep -rln "failureSeverity\|partitionFailures" c11Tests/` returns empty despite the debug seam at `CLI/c11.swift:14957`. The cwd-injection scenario is theoretical (operator controls the cwd) but the matcher receives operator-controlled bytes through the executor's interpolated message.

5. **Important 5 — parseSplitRatio negatives:** ✅ Confirmed by reading `Sources/WorkspaceBlueprintMarkdown.swift:370–386`. The integer-branch guard `(lhs + rhs) > 0` admits negative-positive pairs; the decimal-branch guard `v > 0, v < 1` is strict. Asymmetric.

6. **Important 6 — trailing `# comment` not stripped:** ✅ Confirmed by reading `YAML.tokenize` (line 600). Filter is `trimmed.hasPrefix("#")` (whole-line only).

7. **Important 7 — set-id collision priority:** ❓ Likely but hard to verify. ULID grammar makes practical collision impossible; the concern is operational — recovery from a stuck set restore.

8. **Important 8 — localization sync:** ❓ Cannot verify without grepping `Resources/Localizable.xcstrings`. If the CMUX-37 plan's localization step ran, there should be entries; if not, this is a checklist item.

## Closing

Would I deploy this to 100k users? No. The five smoke gaps the PR set out to close are addressed; the *new* surface the PR introduces — manifest envelope, polymorphic restore, hand-authored markdown blueprints, substring-based failure classification — has insufficient runtime test coverage and at least one main-actor blocking pattern that will manifest under load.

What needs to change first:
1. Bound `v2SnapshotRestoreSet`'s per-entry executor work (deadline + per-entry failure row, or yield between entries).
2. Decide on partial-manifest semantics and either fail loud or annotate.
3. Add tests for `writeSet`/`readSet`/`listSets`/`setManifestExists`, `failureSeverity`, env-precedence, and YAML edge cases. The seams are already in the code; this is grunt work.
4. Tighten `parseSplitRatio` integer-branch validation.
5. Strip trailing `# ...$` comments in YAML scalar values, or document the limitation in `WorkspaceBlueprintMarkdown`'s doc block.
6. Confirm the six-locale xcstrings update happened.

Once those are done, this is a clean close-out PR. The commits are well-scoped, the comments are unusually honest about their fragility, and the security-pre-check coverage on the new set path is solid. The author knows where the bodies are buried — the comment block over `failureSeverity` is the giveaway. Just bury them with tests.
