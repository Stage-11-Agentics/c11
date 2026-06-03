## Trident Synthesis — CMUX-37 Cycle 2 (Standard Reviews)

- **Date:** 2026-04-24
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** bf802101
- **Linear Story:** CMUX-37
- **Review Cycle:** 2 (post-rework, R1–R7)
- **Sources:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`

---

### Executive Summary

**Merge verdict: MINOR FIXES**

All three models agree that the R1–R7 rework substantively addresses cycle 1's unanimous blockers (B1 walker correctness, B2 structural harness) and the I1–I5 important items (cwd plumb, CLI subcommand, off-main validation, silent-failure gaps, plan sync). No model finds any remaining blocker. Claude and Gemini both recommend advance ("PASS-WITH-NITS" and effectively pass with only potential items). Codex diverges upward on severity: it flags two "Important" items tied to the project's explicit no-silent-drop principle — unreferenced `SurfaceSpec` entries dropped silently, and `workingDirectory` dropped silently for browser/markdown surfaces created through the in-pane path (`createSurface`). These are genuine gaps relative to the implementation's own stated contract, but they are narrowly scoped fixes rather than architectural rework. Recommend landing the two Codex-identified fixes plus the ineffective-substring test-assertion fix before merge; the rest are follow-up polish.

---

### 1. Consensus Issues (2+ models agree)

1. **R1–R7 correctly address cycle 1 blockers.** All three models confirm the top-down walker (R2) produces the expected bonsplit tree across fixtures, and the structural assertion harness (R1) now verifies orientation, divider positions, tab order, and selected tab. Claude hand-traced all five fixtures; Gemini confirmed the pattern matches `restoreSessionLayoutNode`; Codex verified by inspection.
2. **No new regressions introduced.** All three reviewers confirm typing-latency hot paths untouched, socket focus policy preserved, and the `c11 install <tui>` principle respected.
3. **No local test execution.** All three explicitly defer to CI/VM per `CLAUDE.md` testing policy.
4. **`paneIdForPanel` lookup is O(N) and can be tightened.** Claude (Important #1) notes it duplicates the existing `paneId(forPanelId:)` helper and should be consolidated. Gemini (Potential #1) notes the same O(N) iteration and proposes capturing `paneId` alongside `panelId` in `WalkState.planSurfaceIdToPanelId` for O(1) lookup. Different framings (naming hygiene vs. performance), same underlying observation that the lookup is wasteful given `WalkState` already knows the mapping.
5. **Non-string `mailbox.*` handling is intentional/correct in the executor.** Claude (Potential #7) and Codex (Potential #3) agree the executor correctly drops non-string mailbox values with a typed `mailbox_non_string_value` failure. Both agree the Codable-layer round-trip of non-string values is intentional separation between wire and apply semantics.

### 2. Divergent Views

1. **Severity of silent drops for unreferenced `SurfaceSpec` entries.**
   - **Codex (Important #1):** treats this as a confirmed silent-drop class of failure that violates the project's explicit no-silent-drop contract; proposes a typed `unreferenced_surface_spec` failure and that the harness derive expected IDs from `plan.surfaces` instead of a manual list.
   - **Claude (Important #4):** flags the same behavior but classifies it as a specification ambiguity, suggesting a doc-comment note would resolve it.
   - **Gemini:** silent on this item.
   - Signal: Codex is applying the strictest reading of the no-silent-drop principle. The disagreement is about whether orphaned surfaces are "dead data" (Claude) or "a malformed plan that can produce a successful apply result without the surface existing" (Codex). Codex's framing is consistent with cycle 1's posture on silent drops.

2. **Severity of `workingDirectory` drop for browser/markdown via `createSurface`.**
   - **Codex (Important #2):** this is a confirmed silent-drop gap; the split path emits `working_directory_not_applied` but the in-pane creation path (used for root-seed replacement and tab-stacked additions) does not. Proposes emitting the same warning from `createSurface` and adding fixtures covering both.
   - **Claude:** acknowledged R3's cwd plumb as complete without flagging this specific path, but the hand-traced walk of `mixed-browser-markdown` did not exercise a `workingDirectory` on the browser/markdown in-pane spec (fixture does not set one).
   - **Gemini:** did not flag this path; classifies R3 as passing.
   - Signal: this is a real gap and the acceptance harness does not currently cover it, because no fixture sets `workingDirectory` on a browser or markdown surface created through `createSurface`. Codex's catch here is the most valuable finding of the pack.

3. **Off-main contract robustness in `v2WorkspaceApply`.**
   - **Claude (Important #3):** flags that the off-main guarantee is structural rather than compiler-enforced; suggests `precondition(!Thread.isMainThread)` or a `nonisolated` helper refactor.
   - **Codex and Gemini:** confirm the current structure is correct; do not flag.
   - Signal: Claude's concern is about future-proofing, not current correctness. Consensus is the current design is correct.

4. **Overall merge posture.**
   - **Claude:** PASS-WITH-NITS — advance to cycle 3 / Phase 1.
   - **Gemini:** effectively pass — no blockers, no important items, only potential.
   - **Codex:** no blockers, but two Important items that per cycle-1's principle should arguably block.
   - Signal: two out of three reviewers would merge now; Codex's two Important items deserve action before merge to honor the no-silent-drop contract.

### 3. Unique Findings (one model only)

1. **Claude — Per-key metadata writes could be batched.** `writeSurfaceMetadata` calls `SurfaceMetadataStore.setMetadata(partial:)` once per entry; could be batched into a single call. Non-blocking; Phase 1 polish.
2. **Claude — `applyDividerPositions` clamps 0..1 silently.** A `divider_out_of_range` warning would improve observability.
3. **Claude — `dividerTolerance: 0.001` may flake on slower CI runners.** Especially for the 0.7 divider in `deep-nested-splits`.
4. **Claude — 2000 ms per-fixture budget may be tight on busy CI.** Suggests raising to 5000 ms or switching to `XCTMeasureMetric`.
5. **Claude — CLI `workspace apply` lacks positional file-arg fallback.** Friendliness-only; not needed for Phase 0.
6. **Claude — `ApplyResult.workspaceRef = ""` sentinel.** Future `String?` bump optional.
7. **Codex — Acceptance harness substring check `[\(key)` will not match executor's emitted `metadata["\(key)"]`.** This is a concrete bug in `WorkspaceLayoutExecutorAcceptanceTests.swift:423` — the non-string mailbox assertion is present but would not match the actual error message, making the regression check ineffective. Pairs with Codex's suggestion to add a fixture that actually exercises the non-string mailbox path.
8. **Codex — Walker's command loop silently `continue`s when a declared terminal has no live panel mapping** (`WorkspaceLayoutExecutor.swift:182`). Another silent-drop class of failure.
9. **Gemini — `WalkState` already tracks `paneId` during `materializePane`/`materializeSplit`,** so the post-hoc `paneIdForPanel` resolver is avoidable. Unique O(1)-refactor framing.

### 4. Consolidated Issue List (Deduplicated)

#### Blockers
_(none)_

#### Important (recommend fixing before merge)

1. **[Codex] Emit a typed failure for unreferenced `SurfaceSpec` entries.** Validation should compare `Set(plan.surfaces.map(\.id))` against the layout's reference set and emit `unreferenced_surface_spec`. Update acceptance harness to derive `expectedSurfaceIds` from `plan.surfaces` rather than a hand-maintained list. Aligns with the no-silent-drop principle established in cycle 1.
2. **[Codex] Emit `working_directory_not_applied` from `createSurface` for browser/markdown with non-empty `workingDirectory`.** The split path (`splitFromPanel`) already does this; the in-pane creation path (root-seed replacement and tab-stacked additions) does not. Add fixtures for (a) root browser/markdown with cwd, (b) tab-stacked browser/markdown with cwd, and assert the warning.
3. **[Codex] Fix the ineffective non-string `mailbox.*` substring check.** `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:423` searches for `[\(key)` while the executor emits `metadata["\(key)"]`. Match by failure code + key, not by brittle substring. Add a fixture that actually exercises a non-string mailbox value so the check is exercised.
4. **[Codex] Investigate the `continue` on missing live panel mapping in the executor's command loop** (`WorkspaceLayoutExecutor.swift:182`). Either emit a typed failure or justify the silent skip in a code comment.
5. **[Claude + Gemini] Consolidate `paneIdForPanel` / `paneId(forPanelId:)` helpers.** Pick one spelling. Ideally capture the `paneId` alongside `panelId` inside `WalkState.planSurfaceIdToPanelId` during materialization so the post-hoc lookup is unnecessary (Gemini's framing gives this a correctness/perf payoff beyond naming hygiene).

#### Suggestions (non-blocking, follow-up or Phase 1)

6. **[Claude] Add `precondition(!Thread.isMainThread)` or refactor to a `nonisolated` prelude in `v2WorkspaceApply`** to compiler-enforce the off-main validate contract. Ambient risk, pre-dates CMUX-37.
7. **[Claude] Batch `SurfaceMetadataStore.setMetadata(partial:)` calls** in `writeSurfaceMetadata`.
8. **[Claude] Emit `divider_out_of_range` warning** instead of silent 0..1 clamp in `applyDividerPositions`.
9. **[Claude] Widen `dividerTolerance` or force a non-animated set path** if CI flakes on the 0.7 divider comparison.
10. **[Claude] Widen `perFixtureBudgetMs` from 2000 to 5000** or switch to `XCTMeasureMetric` if CI flakes.
11. **[Claude] Accept a positional file argument** in `c11 workspace apply` for friendlier CLI ergonomics.
12. **[Claude] Document `ApplyResult.workspaceRef: String` sentinel convention** or bump to `String?` in a future schema version.

---

### Recommendation

Land the five Important items (1–5) above, then merge. Items 1, 2, 3, and 4 honor the no-silent-drop principle that was the throughline of cycle 1; item 5 is a straightforward cleanup with a performance payoff. The twelve Suggestions are appropriate polish for Phase 1 or a follow-up commit and should not gate the merge.
