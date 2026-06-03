## Code Review
- **Date:** 2026-05-04T15:43:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** cmux-37/final-push
- **Latest Commit:** aea6eaa8
- **Linear Story:** CMUX-37
---

## Summary

Nine commits across five workstreams (W1–W5) closing the 2026-05-03 smoke-test gaps for the CMUX-37 workspace persistence ticket. The bulk of new code is `Sources/WorkspaceBlueprintMarkdown.swift` (a hand-rolled YAML/Markdown parser and writer, ~795 lines) plus the `snapshot --all` manifest envelope (`WorkspaceSnapshotSet.swift`, +163), the polymorphic `restore <id>` dispatch in `CLI/c11.swift`, two new v2 socket methods (`workspace.parse_blueprint`, `snapshot.restore_set`, `snapshot.list_sets`), and a CLI-side classifier that demotes "expected" `failure:` lines to `info:`. Test additions are pure value-level Codable/parser tests under `c11Tests/` — no AST-shape checks.

The work is well-factored: the markdown parser stays Foundation-only and lives outside the CLI binary's link surface (the CLI calls it via the v2 socket method `workspace.parse_blueprint`); the snapshot manifest is purely a pointer file so each inner snapshot stays independently restorable; capture-side metadata stripping fixes the `metadata_override` warning at the source rather than relying solely on the CLI classifier; legacy `~/.cmux-snapshots/` and `~/.config/cmux/blueprints/` paths still read for backwards-compat; `C11_SOCKET` env var is honored with a documented precedence chain.

The smoke gaps are addressed end-to-end. W1: blueprint export defaults to `.md` under `~/.config/c11/blueprints/`. W2: `snapshot --all` writes both per-workspace files AND a manifest at `~/.c11-snapshots/sets/<set_id>.json`; `restore <id>` is polymorphic. W3: capture-side metadata dedup + CLI classifier surfaces expected diagnostics under an `info:` heading. W4: `c11 workspace <sub> --help` two-level dispatch routes correctly. W5: `C11_SOCKET` is honored with a stderr breadcrumb when auto-discovery picks a non-default path.

No CI status was checked (per CLAUDE.md "Never run tests locally"). Local tests are forbidden; CI is the authority.

## Architecture

**Markdown blueprint format.** The choice to ship a hand-rolled YAML subset rather than depend on Yams (or another vendored YAML library) is defensible: the schema is intentionally small (mappings, dash-prefixed lists with mapping/scalar items, `"…"`/`'…'` quoting, `# comment` lines), and the parser doc-comments call out exactly what's NOT supported (multi-document streams, tags, anchors, flow-style, block scalars). Foundation-only means no link-surface bloat in the CLI binary. The writer + parser round-trip on the value level (the new `WorkspaceBlueprintMarkdownTests` covers the schema example end-to-end).

**Manifest envelope is a pointer file, not a bundle.** `WorkspaceSnapshotSetFile` carries no plan data — only inner snapshot ids, ordering, and selection metadata. This is the right call: each inner snapshot remains independently restorable through `c11 restore <inner-id>`, manifests don't duplicate the bytes that drive layout, and atomic-write semantics on the manifest don't have to coordinate with N inner writes.

**Polymorphic `c11 restore <id>`.** The dispatch probes `~/.c11-snapshots/sets/<id>.json` first and falls back to single-snapshot. ULIDs share a grammar so shape alone can't disambiguate; the filesystem probe is the correct strategy. The CLI code also handles the case where a user passes `restore /path/to/set-manifest.json` — the `importSnapshotOrSetFileForRestore` helper classifies by envelope shape (`set_id` + `snapshots` list vs `snapshot_id` + `plan`) and stages into the right subdir.

**Capture-side metadata strip + CLI classifier (W3).** The right call is the capture-side fix in `WorkspacePlanCapture.strippingRedundantCanonicalFields` — strip `metadata["title"]` only when it agrees with `SurfaceSpec.title` (so divergent values still produce a real conflict warning). The CLI-side classifier is the belt for the suspenders. The classifier is fragile in one specific way (substring match on `"seed terminal reuse"`); the commit message and code comment both flag this. See finding #2 for a structural fix.

**Two-level help dispatch (W4).** The change to `dispatchSubcommandHelp` is small and clean: pass `commandArgs` through to `subcommandUsage`, switch on the first non-flag arg under `case "workspace":`, emit `c11 workspace <sub>` in the header. No behavior change for any other subcommand. The unknown-subcommand fallback prints a useful error rather than silently dispatching.

**Socket env var precedence (W5).** `C11_SOCKET → CMUX_SOCKET_PATH → CMUX_SOCKET → auto-discovery`. The resolution is applied at three sites (`run`, `claudeTeamsResolvedSocketPath`, the breadcrumb attribution). The auto-discovery stderr breadcrumb is suppressible via `C11_QUIET_DISCOVERY=1` — a reasonable escape hatch for scripts that grep stderr.

## Notable strengths

- **Path-traversal hardening.** `WorkspaceSnapshotStore.assertPathUnderSnapshotRoots` resolves both target and roots through `standardized.resolvingSymlinksInPath()` and uses prefix-with-trailing-separator containment. `isSafeSnapshotId` is enforced on both write and read paths; `resolvePath(byId:)` is called by `read(byId:)`. The `snapshot.restore_set` socket method explicitly rejects a caller-supplied `path` parameter and only accepts `set_id`.
- **`writeToDefaultDirectory(_:)` vs `write(_:to:)` separation.** The doc comment on `write(_:to:)` calls out the arbitrary-file-write hazard explicitly and points socket handlers at the safer entry point. The new `writeSet` follows the same pattern (id-only, `isSafeSnapshotId` gate, no caller-supplied path).
- **Capture-side metadata dedup is precise.** `strippingRedundantCanonicalFields` strips only on exact value match. An operator who deliberately writes a divergent metadata title via `set-metadata --key title --value "Foo"` while the surface title is `"Bar"` still triggers the `metadata_override` warning — that's a real conflict and worth surfacing.
- **Test discipline.** All new tests are runtime/value tests: parser round-trips, Codable encode/decode, filesystem store I/O against per-test temp directories with `directoryOverride:`. No grep-style source-text checks. Conforms to the CLAUDE.md test-quality policy.
- **`WorkspaceSnapshotSetFile.Entry.encode(to:)` omits `selected: false` on the wire.** Minimizes JSON bloat for the common case; round-trip via `decodeIfPresent ?? false` is symmetric. Clean Codable design.
- **`v2WorkspaceParseBlueprint` is the right boundary.** The CLI reads the file (with the user's real FS permissions) and forwards bytes via `content:`; the socket handler does no path resolution. This keeps the parse path immune to the arbitrary-file-read class that `snapshot.restore` already guards against.

## Findings

1. **[Important]** `formatSplitRatio` round-trip can introduce a small-but-detectable drift for arbitrary `dividerPosition` values, breaking `XCTAssertEqual` in the existing tests for non-integer ratios. Currently the writer rounds to `N/100` integer ratios when within `0.001` of a clean integer percent and otherwise emits `%.4f`. The four-digit decimal can lose information vs the original `Double`. The existing tests only round-trip values that round cleanly (`0.5`, `0.6`), so this won't fail in CI today, but a future test that pokes `0.55555` will regress. Either tighten the writer to always emit a high-precision form (e.g., `%.6f` or the raw representation) or add a code comment + targeted parser test that documents the lossy round-trip explicitly. (`Sources/WorkspaceBlueprintMarkdown.swift:485-494`)

2. **[Important]** `failureSeverity` substring match on `"seed terminal reuse"` is the fragility the commit comment already flags. If `WorkspaceLayoutExecutor.swift:658` ever changes the `context:` argument (e.g., reword to `"seed terminal cwd ignored"`), the classifier silently regresses to surfacing the line as a real failure again, and there's no test that would catch it. The ergonomic fix is structural: have the executor classify at emission time (e.g., add a `severity: .info|.failure` field to `ApplyFailure`, or split into a separate `infos:` array on `ApplyResult`) so the CLI just maps over what the executor already decided. If that's too invasive for the close-out, at least add a CI guard test that asserts the executor's emitted message for the seed-terminal case still contains the substring the classifier matches on. (`CLI/c11.swift:173-180`, `Sources/WorkspaceLayoutExecutor.swift:656-658`)

3. **[Important]** Markdown writer does not detect or escape triple-backticks embedded in surface titles, URLs, file paths, or commands. `quoteIfNeeded` catches a leading backtick (it's in `reservedFirst`) but not embedded ones. A surface title containing ``` ``` ``` (anywhere except the first character) would terminate the YAML fence early and produce a corrupt blueprint. The risk surface is small — operators don't usually put triple-backticks in titles — but if it ever happens, the file is broken and the parse error doesn't point at the title. Either reject titles containing ` ``` ` at write time with a clear error, or use a longer fence (e.g., `````` `````yaml `` ... `` `````` ``````) when content contains triple-backticks. (`Sources/WorkspaceBlueprintMarkdown.swift:500-523`)

4. **[Important]** `restore_set` output formatting in the CLI does not partition inner failures into the `info:` bucket the way single-snapshot restore does. The single-snapshot `runSnapshotRestore` calls `Self.partitionFailures(failures)` and prints `failures: N` and `info: M` separately; `restore_set` prints inner snapshot results as bare `OK snapshot=...` / `ERROR snapshot=...` rows with no per-inner failure partitioning. Operators restoring a set will still see the seven-failure noise from each inner restore, just in a different shape — but the v2 socket payload for inner workspaces doesn't include the per-inner `failures` array (the encoded `ApplyResult` is inlined into each row). The fix path is to either (a) include the per-inner partitioned counts in the row (`failures: N, info: M`) or (b) accept that `restore_set` is noisier than `restore` and document it. The smoke-test goal (no spurious `failure:` lines on a clean restore) holds for single restore but is incomplete for set restore. (`CLI/c11.swift:3475-3504`, `Sources/TerminalController.swift:5168-5179`)

5. **[Important]** `v2SnapshotRestoreSet` re-establishes selection only when `allowFocus` is true. `snapshot.restore_set` is NOT in `focusIntentV2Methods` (lines 130-145 of `TerminalController.swift`), so `v2FocusAllowed(requested: true)` always returns false for this method. The selection re-establishment block at lines 5192-5198 is dead code under the current focus policy. This matches the existing `snapshot.restore` behavior (also not focus-intent), so it isn't a regression — but the comment "Re-establish selection on a best-effort basis" is misleading because best-effort means "never" today. Either add `snapshot.restore_set` (and `snapshot.restore`) to `focusIntentV2Methods` if reselecting after a user-initiated restore is intentional, or strip the dead branch and update the comment. The CLI's `c11 restore` is plausibly a focus-intent command from the operator's perspective. (`Sources/TerminalController.swift:5189-5198`, `Sources/TerminalController.swift:130-145`)

6. **[Potential]** The YAML parser is forgiving of malformed input in subtle ways. `parseSimpleMapping` silently skips lines without a colon; `parseValue` returns `.scalar("")` when at-or-below the parent indent; `parseMapping`'s `findKeyColonRange` returns nil silently if no colon-followed-by-space exists. There's no central "I parsed nothing useful" error for cases where a hand-edited blueprint has a typo deeper in the tree. The schema-level errors (`missingType`, `unknownNodeType`, `wrongChildCount`) catch the leaf cases, but a malformed split node (e.g., `direction: horiz` instead of `horizontal`) silently degrades to `.horizontal` because of the `(direction == "vertical") ? .vertical : .horizontal` fallback at line 302. Suggest tightening orientation parsing to throw on unknown values; same for the split format (no fallback to `50/50` if `split:` is malformed). The plan plot says "human-authored blueprints must fail loudly with a useful error on malformed input." (`Sources/WorkspaceBlueprintMarkdown.swift:301-305`)

7. **[Potential]** `snapshot.restore_set` does not validate that `manifest.snapshots` is non-empty. An empty manifest would produce an empty `workspaces:` array with `selected_workspace_ref` unset and no error. This is a degenerate input (you'd have to hand-craft it; the writer never produces an empty manifest because of the `!entries.isEmpty` guard in `v2SnapshotCreate`), but defending against it costs a single early-exit. (`Sources/TerminalController.swift:5071-5078`)

8. **[Potential]** `formatSplitRatio` uses `String(format: "%.4f", p)`. On some locales this could emit `0,5000` (comma decimal separator) — but Swift's `String(format:)` is locale-agnostic by default, so this isn't actually a hazard. Still worth a code comment for future maintainers tempted to reach for `Formatter`. (`Sources/WorkspaceBlueprintMarkdown.swift:493`)

9. **[Potential]** The `c11_version` field in the manifest is set via `LiveWorkspaceSnapshotSource.defaultVersionString()`. If that returns the empty string (e.g., bundle missing version keys), the manifest persists with `c11_version: ""`. A defensive default (`"unknown"`) would make the manifest self-describing in pathological build configs. Low priority — only matters for non-shipping builds. (`Sources/TerminalController.swift:4801-4805`)

10. **[Potential]** The new auto-discovery stderr breadcrumb writes via `FileHandle.standardError.write(Data((line + "\n").utf8))`. This is fine, but the write is fire-and-forget — if stderr is closed (rare; e.g., daemonized callers), the write throws. Wrapping in a `try?` on FileHandle would silence the warning more cleanly than relying on `Data.write`'s error swallowing. Minor. (`CLI/c11.swift:111`)

11. **[Potential]** `CLISocketPathResolver.discoverySourceHint` reads `last-socket-path` synchronously inside the resolver. This file is small (a single path) and read once per CLI invocation, so not a hot path — but the helper is called from `emitAutoDiscoveryNotice` which already runs late in the CLI's startup sequence; co-locating both reads in a single helper would avoid the duplicate read of `last-socket-path` (one in `resolve`, one in `discoverySourceHint`). Minor caching opportunity. (`CLI/c11.swift:30-65`, `CLI/c11.swift:97-111`)

12. **[Potential]** The `selectedWorkspaceIndex` field on `WorkspaceSnapshotSetFile` is computed at write time from the in-memory `entries.count - 1` after each successful write. If the last successful write happens to be the selected workspace, that's correct. But if a workspace earlier in the iteration is selected and a later write succeeds, the selected workspace's index is `entries.count - 1` at the moment of insertion — which is correct. The variable name `selectedIndex` is slightly misleading because it shadows the field name and the manifest field is `selectedWorkspaceIndex`. Minor naming nit; the logic is correct. (`Sources/TerminalController.swift:4780, 4804`)

13. **[Potential]** `WorkspaceBlueprintStore.indexEntries` for `.md` files reads the whole file (parses frontmatter + layout + YAML) just to populate the picker's name/description. For a directory with many blueprints this is more work than the JSON path (`JSONDecoder().decode`). A future optimization: have a `parseFrontmatterOnly(_:)` entry point on the markdown module that stops after the second `---`. Not urgent. (`Sources/WorkspaceBlueprintStore.swift:251-265`)

14. **[Potential]** The smoke report flagged that `restore` returned exit 0 with seven `failure:` lines in scenario 1. Post-fix: six metadata_override warnings should be gone (capture-side strip), and the one seed-terminal cwd warning is now classified as `info:`. That matches the W3 acceptance criteria. However, the smoke report's scenario 3 mentions blueprint materialization "also returned non-fatal `failure:` diagnostics for ignored terminal cwd and metadata title overrides" — confirm that `runWorkspaceNew` (the blueprint-materialize path) is also using `partitionFailures` (yes, lines 3043-3055 of the diff). Confirmed working.

## Validation Pass

1. ✅ Confirmed — `formatSplitRatio` round-trip lossy for non-integer ratios. Re-read `Sources/WorkspaceBlueprintMarkdown.swift:485-494`. The `%.4f` format truncates after four decimal digits; the rounded check uses `0.001` threshold which means `0.5005` would emit `0.5005` (not the integer form) and parse as `0.5005`, but a `Double` like `1.0/3.0 == 0.3333333…` would emit `"0.3333"` and parse back as `0.3333` — a mismatch from the original. Tests don't catch it because no test uses a non-cleanly-divisible ratio. Severity remains Important — it's a latent bug, not a current test failure.

2. ✅ Confirmed — `failureSeverity` substring fragility. `WorkspaceLayoutExecutor.swift:658` emits the literal `"seed terminal reuse (cwd fixed at workspace creation)"`. The classifier matches `message.contains("seed terminal reuse")`. If the executor's `context:` ever changes, classification breaks silently. The code comment in `failureSeverity` already flags this. Important.

3. ✅ Confirmed — embedded triple-backticks in surface titles would break the YAML fence. `quoteIfNeeded` catches leading backtick via `reservedFirst` but not embedded ones. A pathological title `"foo ``` bar"` (anywhere) would close the markdown fence early and the rest of the YAML body would be parsed as Markdown prose. Important — corrupted-on-disk artifact.

4. ✅ Confirmed — `restore_set` CLI output does not partition inner failures into `info:` lines. Re-read `CLI/c11.swift:3447-3504` and the `v2SnapshotRestoreSet` socket method. The socket payload `workspaces[*]` rows do contain encoded `ApplyResult.failures`, but the CLI's set-restore output prints only `OK snapshot=… surfaces=N` per row without unpacking. Important — partial closeout of the W3 acceptance criteria for set restore.

5. ✅ Confirmed — `snapshot.restore_set` is not in `focusIntentV2Methods`. The dead-code branch at lines 5192-5198 doesn't trip the policy guard but never executes either. Important — code-clarity issue, not a regression vs `snapshot.restore`.

6. ⬇️ Lower priority — orientation/split fallback silently degrades on typos. Lower priority because (a) the schema is small and the writer round-trip never produces a typo, (b) the parser would still produce a structurally valid layout, just not the one intended. Worth tightening but not blocking.

7. ⬇️ Lower priority — empty manifest defensiveness; `v2SnapshotCreate` guards against it on the write side, so `readSet` never sees an empty manifest in practice. Defense-in-depth nice-to-have.

8. ❌ Locale-decimal hazard struck through — Swift `String(format:)` is locale-agnostic by default. Not a real issue.

9. ⬇️ Lower priority — `c11_version: ""` cosmetic.

10. ⬇️ Lower priority — stderr write error handling. Foundation's `FileHandle.write(Data:)` already swallows in non-throwing form on macOS; no fix needed unless we want to be explicit.

11. ⬇️ Lower priority — duplicate `last-socket-path` read; one extra small read per CLI invocation.

12. ⬇️ Lower priority — naming nit on `selectedIndex` local var.

13. ⬇️ Lower priority — markdown frontmatter-only parse optimization.

14. ✅ Confirmed working — `runWorkspaceNew` does call `Self.partitionFailures(failures)` (CLI diff lines 254-266).

## Blockers / Important issues at a glance

No blockers. Five Important items:

1. `formatSplitRatio` lossy round-trip for non-integer ratios (latent, not currently failing tests)
2. `failureSeverity` substring match on `"seed terminal reuse"` is fragile; recommend executor-side classification or a CI guard test
3. Markdown writer does not handle embedded triple-backticks; could produce corrupt blueprints if a surface field contains them
4. `restore_set` CLI output does not partition inner failures into `info:` lines the way single-restore does — partial W3 closeout
5. `snapshot.restore_set` not in `focusIntentV2Methods`; selection re-establishment is dead code under current policy

Pragmatic recommendation: ship as-is for the close-out, file follow-up tickets for items 2 (executor-side severity field), 4 (set-restore output parity), and 5 (focus-intent registration). Item 1 is a latent paper-cut worth tightening when convenient. Item 3 is a hardening item that's only relevant if operators put triple-backticks in titles, which is unusual.
