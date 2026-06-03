# C11-14: CMUX-37 Phase 1 follow-up: polish + hardening

Post-merge follow-up work identified by the Phase 1 trident code review (PR #77, merged 2026-04-24). All four review blockers landed in PR #77; this ticket collects the Important and Potential items that were deferred.

Full review pack: `notes/trident-review-CMUX-37-pack-20260424-1450/` on the `main` branch at the merge commit.

## UX / ergonomics

- **I2 — `c11 restore` has no `--in-place`.** Today `restore` always creates a new workspace. Running `restore` twice produces two duplicate workspaces with no warning. `Sources/WorkspaceLayoutExecutor.swift:37-39` has a doc comment referencing `applyToExistingWorkspace(_:_:_:)` — a method that doesn't exist. Implement the in-place path and add a `--in-place` / `--replace` flag. Until then, tighten the doc comment so it stops promising what isn't there.
- **I8 — `snapshot.list` silently drops malformed files.** `Sources/WorkspaceSnapshotStore.swift:202-203` uses `try? read(from: url); continue`. Surface unreadable entries as an `unreadable` row (with filename + error excerpt) instead of hiding them.
- **P2 — `AgentRestartRegistry.named(_:)` silently falls back to Phase 0 on unknown wire names.** `Sources/AgentRestartRegistry.swift:59-64`. A typo in the `restart_registry` param is currently undetectable. Either emit a warning in `ApplyResult.warnings` or reject the wire value with `invalid_params` at the socket layer.
- **P9 — Capture title comment overclaims `displayTitle` fallback.** `Sources/WorkspaceSnapshotCapture.swift:31, 151`. Implementation only records `panelCustomTitles[panelId]`. Fix the comment, or add the fallback if that was the intent.

## Correctness nits

- **I6 — `claudeSessionId` constant duplicated across app and CLI targets.** `Sources/WorkspaceMetadataKeys.swift:29` defines it; `CLI/c11.swift:12640` spells the literal again. Commit message explicitly admits "kept in lockstep by reader convention." Extract a `Foundation`-only `WorkspaceMetadataKeys` module shared between targets, or add a build-time invariant test that greps for divergence.
- **P3 — `ApplyOptions.==` returns false for two non-nil-but-identical registries.** `Sources/WorkspaceApplyPlan.swift:233-248`. Manual `Codable`/`Equatable` was needed because `AgentRestartRegistry` carries a closure; the `==` implementation treats any two non-nil registries as unequal. Fix: compare by name or by an identifier that the registry exposes.
- **P8 — `WorkspaceSnapshotID.generate` calls the injected clock twice.** `Sources/WorkspaceSnapshotCapture.swift:63, 64`. The ULID time prefix and `created_at` can diverge by a tick. Single clock read, reuse both places.
- **P10 — `AgentRestartRegistry.init(rows:)` does not trim `terminalType`; `resolveCommand` trims the query.** Asymmetric-trim footgun: a future row with trailing whitespace becomes silently un-resolvable. Trim on insert and on lookup.

## Security / hardening — pending operator decision

These two need a policy call before implementation. Split into a child ticket if the answers are "do the work"; otherwise document and close.

- **P5 — Plaintext `claude.session_id` on disk.** `~/.c11-snapshots/` and `~/.cmux-snapshots/` contain session IDs in cleartext. Threat model is narrow (session IDs are transcript-lookup keys, not credentials) but undocumented. Decision: (a) document threat model and ship as-is; (b) redact on capture with a cross-reference table; (c) encrypt at rest via Keychain.
- **P6 — Orphan-socket / wrong-owner errors not in advisory set.** `CLI/c11.swift:23-31`. The claude-hook metadata write falls through to a `failed` breadcrumb when another user owns the c11 socket. If we're strictly single-user, this should be advisory; if multi-user support lands, `failed` is correct.

## Test coverage / observability

- **P1 — `snapshot.list` decodes the entire embedded plan per file.** `Sources/WorkspaceSnapshotStore.swift`. Gets slower as snapshots accumulate. Add a header-only summary decoder (`version` + `snapshot_id` + `created_at` + `c11_version` + `origin` + surface count from an explicit counter, not by parsing the plan).
- **P4 — Acceptance suite is DEBUG-only and fails opaquely in Release.** `c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift:295-301`. Wrap the DEBUG-only pieces so the suite cleanly `XCTSkip`s in Release rather than failing.
- **P7 — No executor end-to-end run for a snapshot whose first surface is browser or markdown.** Phase 1 acceptance puts a terminal first. Add fixtures that put each non-terminal kind first and exercise the capture/restore path — Phase 3 will lean on this.
- **P11 — `pendingInitialInputForTests` test-only accessor is not thread-safe.** `TerminalSurface` — if `pendingTextQueue` is accessed off-main, the accessor races. Add a lock or main-actor gate.
- **I5 follow-up — `c11 list-snapshots` plain-table formatter has no CLI-subprocess test.** The Fix commit (`d683f044`) replaced the broken `%s` printf with native `String` padding but didn't add a test (the c11Tests target can't easily exercise the CLI binary). Add one via the CI integration-test harness or a small subprocess fixture in `tests_v2/`.

## Out of scope for this ticket

Blueprint authoring (CMUX-37 Phase 2), new-workspace picker (Phase 2), browser/markdown Blueprint support (Phase 3), `c11 snapshot --all` (Phase 3), codex/opencode/kimi restart-registry rows (Phase 5). Those remain on CMUX-37.
