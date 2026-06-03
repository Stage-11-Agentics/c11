# Trident Critical Review Synthesis — CMUX-37 Phase 0

- **Date:** 2026-04-24
- **Branch:** `cmux-37/phase-0-workspace-apply-plan`
- **Commit:** `e4f60b98`
- **Sources:**
  - `notes/trident-review-CMUX-37-pack-20260424-0303/critical-claude.md` (Claude Opus 4.7)
  - `notes/trident-review-CMUX-37-pack-20260424-0303/critical-codex.md` (Codex)
  - `notes/trident-review-CMUX-37-pack-20260424-0303/critical-gemini.md` (Gemini)
- **Scope:** Phase 0 — `WorkspaceApplyPlan` types, `WorkspaceLayoutExecutor`, 5 acceptance fixtures, optional `workspace.apply` socket handler + `c11 workspace-apply` CLI.

---

## Executive Summary

All three critical reviewers converged on the same core judgment: **the schema/metadata/socket layers are solid, but the layout walker is architecturally broken.** `WorkspaceLayoutExecutor.materializeSplit` composes nested splits bottom-up by splitting a *leaf* of the first subtree to produce what should be a sibling of that entire subtree. Because bonsplit's `splitPane` is leaf-only, this approach cannot build a correct tree for any plan with more than one split. Four of the five acceptance fixtures (welcome-quad, default-grid, mixed-browser-markdown, deep-nested-splits) will materialize malformed trees.

Compounding the defect: the acceptance test is structurally blind. It asserts that refs exist and that the run finishes under 2s — it does not compare the live bonsplit tree to the plan's `LayoutTreeSpec`. The broken walker passes CI today. Gemini: "allowing a broken layout engine to pass CI." Claude: "a fake regression guard." Codex: "it looks successful at the API boundary while silently corrupting the workspace shape."

Three reviewers also agreed on: (a) `SurfaceSpec.workingDirectory` is silently dropped for split-created terminals and for the seed terminal, (b) the CLI ships as `c11 workspace-apply` while plan/docs specify `c11 workspace apply`, and (c) validation runs on `MainActor` when it could trivially run off-main.

## Production-Readiness Verdict

**FAIL-IMPL-REWORK.**

Not a plan rework — the plan's intent and scope are sound, and the types/metadata/socket/CLI surfaces are on-target. But the central primitive has a design-level defect in its traversal order that does not resolve with a localized patch: you cannot split a leaf of `split.first` to produce a sibling of `split.first` against bonsplit's leaf-only API. The walker must either (a) split top-down (inject the empty split first, then recurse with pre-allocated pane ids, matching `Workspace.restoreSessionLayoutNode`), or (b) build outer-first with explicit split-id tracking. Either option is an algorithm rewrite of `materializeSplit`, not a line edit. The accompanying acceptance-test rewrite to assert tree topology is also mandatory — without it, the fix cannot be validated.

The working-directory drop (silent data loss on a documented plan field) and the CLI/docs drift are independent of the walker rewrite and must land alongside it.

**Estimated rework:** ~1 day of focused work (Claude's estimate), consistent with Codex and Gemini's scope framing.

---

## 1. Consensus Risks (flagged by 2 or 3 models — highest priority)

### Blocker C1 — Layout walker builds wrong trees for nested splits *(all 3 models)*

- **Location:** `Sources/WorkspaceLayoutExecutor.swift:448-501` (`WalkState.materializeSplit`) — with referenced bonsplit call sites at `Sources/Workspace.swift:7250`, `:7439`, `:7588`.
- **Defect:** The walker materializes `split.first`, captures `firstAnchorPanelId` (the *head* leaf of the first subtree), then calls `splitFromPanel(firstAnchorPanelId, ...)` for `split.second`. Bonsplit's `splitPane` is leaf-only (`vendor/bonsplit/Sources/Bonsplit/Internal/Controllers/SplitViewController.swift:137-162`), so this splits a single leaf inside `split.first` rather than creating a sibling of the first subtree as a whole.
- **Trace (welcome-quad / default-grid, from Claude + Codex, agree):**
  - Plan: `H(V(tl, bl), V(tr, br))`.
  - Walker builds: `V(tl, bl)` first, then splits `tl`'s pane horizontally for `tr`, then splits `tr`'s pane vertically for `br`.
  - Result: asymmetric three-level tree nested under the top-left pane, not a 2×2 quad.
- **Breadth:** Four of five fixtures hit this (welcome-quad, default-grid, mixed-browser-markdown, deep-nested-splits). Only `single-large-with-metadata` (no splits) escapes.
- **Plan-vs-impl note (Claude):** The plan at `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:380` called for the "tail" of the first subtree; impl uses the head. But even the tail would not work against bonsplit's leaf-only API — the correct fix is to invert traversal order (top-down injection) or preallocate splits.
- **Classification:** **Architectural reshape → FAIL-IMPL-REWORK.** This is a design defect in the traversal strategy, not a line-level typo. Gemini recommends matching `Workspace.restoreSessionLayoutNode`'s top-down approach as the reference implementation.

### Blocker C2 — Acceptance tests do not verify layout topology *(all 3 models)*

- **Location:** `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:106-147` (`runFixture`).
- **Defect:** Assertions only check (a) `workspaceRef` non-empty, (b) `surfaceRefs.keys == expectedSurfaceIds`, (c) `paneRefs.keys == expectedSurfaceIds`, (d) no `validation_failed` failures, (e) `total` timing under 2000ms. They do not compare tree shape, split orientation, pane order, divider positions, `selectedIndex`, browser URL, markdown file path, or terminal cwd.
- **Quote (Gemini):** "the acceptance fixture `runFixture` is structurally blind … allowing a broken layout engine to pass CI."
- **Quote (Claude):** "a fake regression guard."
- **Quote (Codex):** "the test can report success for a malformed layout."
- **Required fix:** Convert `workspace.bonsplitController.treeSnapshot()` to a normalized shape (orientation + recursive pane grouping + leaf surface ids) and compare against plan `LayoutTreeSpec`. Extend single-large-with-metadata's round-trip style (peek into `SurfaceMetadataStore` / `PaneMetadataStore`) to every fixture.
- **Classification:** **Localized change → MINOR FIXES in isolation**, but the test rewrite is a prerequisite for validating the C1 fix, so it must ship together.

### Important C3 — `SurfaceSpec.workingDirectory` silently dropped *(Claude + Codex)*

- **Location:** `Sources/WorkspaceLayoutExecutor.swift:506-537` (`splitFromPanel`) → `Sources/Workspace.swift:7250-7276` (`newTerminalSplit`); seed-terminal path at `Sources/WorkspaceLayoutExecutor.swift:361`; additional-tab path correctly passes cwd at `:676`.
- **Defect:** `newTerminalSplit` has no `workingDirectory` parameter and derives cwd from `panelDirectories[panelId]` or the workspace default. The walker forwards only `(panelId, orientation, insertFirst, focus, url, filePath)`. The seed terminal path similarly reuses the seed without applying `firstSurface.workingDirectory`. No `ApplyFailure` or warning is emitted — the data disappears.
- **Quote (Codex):** "Any plan that expects `tests` in repo A and `logs` in repo B will run commands in the wrong directory."
- **Quote (Claude):** "silent data loss on a documented plan field is not acceptable."
- **Fix options:** (a) plumb `workingDirectory:` through `newTerminalSplit` (and apply to the seed-reuse path), or (b) record an `ApplyFailure` / warning when `workingDirectory` is non-nil and unappliable.
- **Classification:** **Localized change → MINOR FIXES** on its own (adding a parameter + threading it, or emitting a warning). Ships alongside the walker rewrite.

### Important C4 — CLI name drift from plan/docs *(Claude + Codex)*

- **Location:** `CLI/c11.swift:1713` ships `case "workspace-apply"`. Plan at `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:83` and `docs/c11-snapshot-restore-plan.md:164` specify `c11 workspace apply --file <path>` (subcommand under `workspace`).
- **Impact:** Operators and scripts following documented contract get an unknown command; later convergence will force churn.
- **Classification:** **Localized change → MINOR FIXES.** Add the `workspace apply` subcommand route (can alias `workspace-apply` for back-compat, or reshape to the documented form).

### Important C5 — Validation runs on MainActor when it could be off-main *(Claude + Gemini)*

- **Location:** `Sources/TerminalController.swift:4385-4399` (`v2MainSync` wraps the full `apply` call); `Sources/WorkspaceLayoutExecutor.swift:63-64` (`validate(plan:)` called inside `apply`, itself inside `v2MainSync`).
- **Defect:** The header comment at `TerminalController.swift:4347-4348` promises "Validation failures never touch the main actor," but in practice only decoding is off-main. Validation is pure (no AppKit state) and blocks the socket thread up to the full 2s `perStepTimeoutMs` window.
- **Claude flags:** contract breach between comment and implementation; Phase-0-tolerable but should be a `// TODO(CMUX-37 Phase 1+)` at minimum.
- **Gemini flags:** violates socket command threading policy; easy to lift.
- **Classification:** **Localized change → MINOR FIXES.** Hoist `validate(plan:)` above the `v2MainSync` block.

---

## 2. Unique Concerns (single-model — worth investigating)

### Claude-only

- **U-Claude-1 — `bonsplitController.selectTab` steals focus.** `Sources/WorkspaceLayoutExecutor.swift:436-443`. `selectTab` unconditionally calls `internalController.focusPane(...)` (`vendor/bonsplit/.../BonsplitController.swift:269-278`). Breaches CLAUDE.md socket focus policy when `options.select: false`. Lower blast radius in Phase 0 because no fixture sets `selectedIndex > 0`, but Phase 1 snapshot restore will trip it the first time a captured workspace has a non-zero selected tab.
- **U-Claude-2 — Seed-panel replacement path unexercised.** `Sources/WorkspaceLayoutExecutor.swift:369-391`. Force-closing a freshly-minted seed `TerminalPanel` whose Ghostty surface may not yet be active — potentially dangling surface handle / subscription. No fixture has a browser-root or markdown-root plan to exercise this. Likely benign but needs a fixture.
- **U-Claude-3 — `ApplyOptions.autoWelcomeIfNeeded` is intentional no-op that invites caller confusion.** (Codex flagged the same pattern as a nit; Claude keeps it in his list too.)
- **U-Claude-4 — `Dictionary(uniqueKeysWithValues:)` crashes on duplicate keys if validation regresses.** `Sources/WorkspaceLayoutExecutor.swift:115-117`. Belt-and-braces: use `uniquingKeysWith` form.
- **U-Claude-5 — Fixtures not in test bundle resources.** `project.pbxproj` omits `Fixtures/workspace-apply-plans/`; test loads via `#filePath`. Works on CI; fragile for ad-hoc runs.
- **U-Claude-6 — Missing executor-level negative-path coverage:** no test for `mailbox_non_string_value` guard, `duplicate_surface_id`, `unknown_surface_ref`, `split_failed`, `metadata_override`, `metadata_write_failed`. No socket-handler end-to-end test (~80 LOC of `v2WorkspaceApply` is uncovered).
- **U-Claude-7 — Plan file still says `async func apply`.** `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:58` out of sync with the shipped sync signature. Future agents will implement the wrong shape in Phase 1.
- **U-Claude-8 — Duplicate `paneIdForPanel` on `Workspace`.** `:5611` (new) and `:7761` (preexisting). Untidy, not a bug.
- **U-Claude-9 — `v2EnsureHandleRef` fallback format divergence.** `Sources/TerminalController.swift:4388-4396`. Fallback returns `workspace:<uuidString>` vs canonical `workspace:<ordinal>`. Dead code in practice; foot-gun if copied.

### Codex-only

- **U-Codex-1 — `ApplyOptions.perStepTimeoutMs` is dead configuration.** `Sources/WorkspaceApplyPlan.swift:196` documents a per-step deadline warning; `apply()` never compares `durationMs` to `options.perStepTimeoutMs`. Slow steps return clean. Plan promised named step warnings.
- **U-Codex-2 — Unsupported `WorkspaceApplyPlan.version` values silently accepted.** `Sources/WorkspaceApplyPlan.swift:13` declares the field; `Sources/WorkspaceLayoutExecutor.swift:222` never validates it. Survivable in Phase 0 but becomes a compatibility trap once snapshots exist.
- **U-Codex-3 — `metadata_override` is a *failure* rather than a *warning*.** `Sources/WorkspaceLayoutExecutor.swift:570-574`. Executor lets raw `metadata["title"]` / `metadata["description"]` win after canonical setters but files it under `failures`, weakening the human-readable warning channel. Decide the semantics before Phase 1 consumers grow around it.
- **U-Codex-4 — Same-pane `paneMetadata` merges silently.** If multiple surfaces in the same pane carry different `paneMetadata`, they collapse into one bonsplit pane record in creation order. Easy for Blueprint authors to misread as per-surface.

### Gemini-only

- **U-Gemini-1 — Duplicate surface id references in `plan.layout` go undetected.** `Sources/WorkspaceLayoutExecutor.swift:192-205` (`validateLayout`) verifies refs exist in `plan.surfaces` but not that each is referenced exactly once. Duplicate refs cause `materializePane` to clone the surface; `ApplyResult.surfaceRefs` keeps only the latest. Silent cloning.
- **U-Gemini-2 — `applyDividerPositions` silently swallows mismatches.** `Sources/WorkspaceLayoutExecutor.swift:551-574`. Traverses plan and live trees in lockstep; when the walker's malformed tree doesn't match plan structure, the `default: return` case eats the failure. Divider positions silently dropped for any fixture affected by C1.
- **U-Gemini-3 — Metadata writes thrash disk / events.** `Sources/WorkspaceLayoutExecutor.swift:425-523` (`writeSurfaceMetadata`). Each key triggers a single-key `.merge` on `SurfaceMetadataStore` / `PaneMetadataStore`. Should accumulate into one dict per store and write once.
- **U-Gemini-4 — Seed panel lookup relies on fragile focus state.** `Sources/WorkspaceLayoutExecutor.swift:133-149`. Uses `workspace.focusedTerminalPanel`; Gemini recommends `workspace.panels.values.first(where: { $0 is TerminalPanel })` or `bonsplitController.allPaneIds.first` for robustness, especially with `select: false`.

---

## 3. Ugly Truths (recurring hard messages)

1. **"API shape OK, engine broken." (all 3)** — The part everyone sees (Codable JSON, refs in the result, socket wire) works. The part that actually produces operator value (faithful tree materialization) doesn't. Claude: "looks successful at the API boundary." Codex: "it looks successful at the API boundary while silently corrupting the workspace shape." Gemini: "the layout engine itself is flawed and incapable of generating the expected bonsplit tree topology."
2. **"Fake regression guard." (all 3)** — The 5-fixture harness was explicitly invested in to prevent layout regressions. As shipped, it provides effectively zero layout coverage — it can ratify a broken walker. Without structural assertions, the harness is theater.
3. **"Silent data loss is not acceptable." (Claude + Codex)** — The `workingDirectory` drop is the canonical case, but Codex (`perStepTimeoutMs` dead), Codex (`version` unchecked), Gemini (divider positions swallowed), and Gemini (duplicate surface refs silently cloned) all repeat the same pattern: the executor has multiple paths where plan data quietly goes missing without `ApplyFailure` or warning. Phase 0's whole contract was "writes happen at creation, not after" — silent drops are the failure mode that contract was meant to eliminate.
4. **"The algorithm doesn't fit the API." (Claude + Gemini)** — Both explicitly state the depth-first-from-leaves approach is incompatible with bonsplit's leaf-only `splitPane`. Gemini names the correct reference: `Workspace.restoreSessionLayoutNode`'s top-down injection. Claude enumerates the same fix plus a two-pass / bottom-up alternative. Codex agrees on the symptom, doesn't name an algorithm fix.
5. **"Do not mass deploy." (all 3 closings)** — Unanimous. Claude: "Absolutely not." Codex: "I would not mass deploy this to 100k users." Gemini: "Do not merge until the layout engine correctly yields a 2x2 grid."

---

## 4. Consolidated Production-Blocker List

Numbered by severity and rework shape. "MINOR FIXES" = localized patch; "FAIL-IMPL-REWORK" = algorithmic/architectural change.

| # | Blocker | Location | Models | Rework shape |
|---|---|---|---|---|
| B1 | Layout walker builds wrong trees for nested splits | `Sources/WorkspaceLayoutExecutor.swift:448-501` + `Sources/Workspace.swift:7250,7439,7588` | C+X+G | **FAIL-IMPL-REWORK** — rewrite `materializeSplit` to top-down injection (match `Workspace.restoreSessionLayoutNode`) or two-pass preallocation |
| B2 | Acceptance tests assert no layout topology | `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:106-147` | C+X+G | MINOR FIXES in isolation, but **gated with B1** — needed to validate the fix |
| B3 | `SurfaceSpec.workingDirectory` silently dropped | `Sources/WorkspaceLayoutExecutor.swift:361,506-537` + `Sources/Workspace.swift:7250-7276` | C+X | MINOR FIXES — plumb cwd through `newTerminalSplit` or emit `ApplyFailure` |
| B4 | CLI command drift from docs/plan | `CLI/c11.swift:1713` vs `docs/c11-snapshot-restore-plan.md:164`, `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:83` | C+X | MINOR FIXES — add `workspace apply` subcommand route |
| B5 | Validation runs on MainActor despite comment promise | `Sources/TerminalController.swift:4347-4399` + `Sources/WorkspaceLayoutExecutor.swift:63-64` | C+G | MINOR FIXES — hoist `validate(plan:)` above `v2MainSync` |
| B6 | Divider positions silently swallowed on tree mismatch | `Sources/WorkspaceLayoutExecutor.swift:551-574` | G | MINOR FIXES — emit `ApplyFailure` on `default:` case; largely moot once B1 is fixed |
| B7 | Duplicate surface-id references undetected | `Sources/WorkspaceLayoutExecutor.swift:192-205` | G | MINOR FIXES — add once-per-tree reference check in `validateLayout` |
| B8 | `perStepTimeoutMs` unenforced | `Sources/WorkspaceApplyPlan.swift:196` + `Sources/WorkspaceLayoutExecutor.swift` (apply) | X | MINOR FIXES — compare each timing entry and emit named warning |
| B9 | Plan `version` unchecked | `Sources/WorkspaceApplyPlan.swift:13` + `Sources/WorkspaceLayoutExecutor.swift:222` | X | MINOR FIXES — add version guard in validate |
| B10 | Plan file `async` signature out of sync with shipped sync API | `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:58` | C | MINOR FIXES — plan-doc edit |

### Also required (below blocker threshold but must land with the rework pass)

- Seed-panel replacement path fixture (browser-root or markdown-root plan) — Claude U-2.
- `PaneSpec.selectedIndex > 0` fixture + focus-steal fix — Claude U-1.
- `metadata_override` semantics decision (failure vs warning) — Codex U-3.
- Negative-path executor tests (`mailbox_non_string_value`, `duplicate_surface_id`, `unknown_surface_ref`, `split_failed`, `metadata_write_failed`) — Claude U-6.
- Socket-handler end-to-end test covering `v2WorkspaceApply` encode/decode — Claude U-6.
- Seed panel lookup robustness (away from `focusedTerminalPanel`) — Gemini U-4.
- Batched metadata writes — Gemini U-3.

---

## 5. Production-Readiness Assessment

**Verdict: FAIL-IMPL-REWORK.**

### Why not PASS

Four of five acceptance fixtures materialize malformed trees (B1). The test harness cannot detect it (B2). Documented plan fields silently disappear (B3, B8, B9, and — on tree mismatch — divider positions via B6). This is below the "ship it" bar by every reviewer's stated criterion.

### Why not MINOR FIXES

B1 is not a localized patch. Claude and Gemini independently identify that the chosen traversal order is incompatible with bonsplit's leaf-only `splitPane` API — you cannot take a leaf inside `split.first` and split it to produce a sibling of the entire subtree. The fix requires inverting the algorithm: either top-down injection (split the empty pane first, recurse with new pane ids — Gemini's `restoreSessionLayoutNode` reference), or outer-first two-pass preallocation. This is rewriting `materializeSplit`, not patching it. Once B1 is done, the remaining blockers (B2–B10) collapse to MINOR FIXES and can ride along in the same branch.

### Why not FAIL-PLAN-REWORK

The plan itself is sound. The types, metadata store routing, socket handler shape, CLI surface, TODO comments at migration sites, acceptance-fixture concept, and `mailbox.*` strings-only guard are all on-target and pass reviewer scrutiny. No reviewer challenged the plan's intent — all three point at implementation defects against a correct plan. Claude notes one plan-doc drift (async signature, B10) and one plan-vs-impl CLI drift (B4); both are minor corrections, not a plan overhaul.

### What the rework pass must contain

1. **Rewrite `materializeSplit`** (B1). Preferred reference: `Workspace.restoreSessionLayoutNode`'s top-down injection. Trace-validate against welcome-quad and default-grid before landing.
2. **Add structural assertions to the acceptance test** (B2). Convert `workspace.bonsplitController.treeSnapshot()` to a normalized shape, compare against plan `LayoutTreeSpec` (orientation + pane grouping + leaf surface ids + divider positions + `selectedIndex`). Extend metadata round-trip pattern from `single-large-with-metadata` to every fixture.
3. **Fix `workingDirectory` propagation** (B3). Plumb through `newTerminalSplit` and apply to the seed-reuse path, or emit an `ApplyFailure`.
4. **Align CLI with docs** (B4). Add `c11 workspace apply` route.
5. **Hoist validate() off-main** (B5).
6. **Close silent-failure gaps** (B6, B7, B8, B9).
7. **Sync plan doc** (B10) to shipped sync signature.
8. **Add unexercised-path fixtures** (browser-root, markdown-root, `selectedIndex > 0`) and negative-path executor tests to guard the reshaped walker from regression.

### Scope estimate

Claude estimates ~1 day of focused work for the walker rewrite + harness hardening. The accompanying minor fixes and fixture additions add perhaps another half-day. No architectural reshape of the plan is required — only implementation.

---

## Appendix: What the reviews validated as OK

Consensus positives (worth naming so the rework doesn't regress them):

- Codable round-trips on `WorkspaceApplyPlan` (Claude, Gemini).
- `mailbox.*` strings-only guard location and wire preservation via `PersistedJSONValue` (Claude).
- Metadata routing through `SurfaceMetadataStore` / `PaneMetadataStore` canonical setters (Claude, Gemini).
- Socket handler threading model: parse/decode off-main, main-sync for AppKit/bonsplit mutation (Claude, Codex).
- No hot-path edits (`TerminalWindowPortal.hitTest`, `TabItemView`, `forceRefresh`) — Codex confirmed.
- No `Resources/bin/claude` change, no `c11 install <tui>` revival, no tenant tool-config writes — Codex confirmed.
- TODO comments at welcome-quad and default-grid migration sites are correct and minimal (Claude).
- Five fixture JSON files decode cleanly (Codex).
- `async` drop on `apply()` is cleanly reversible for Phase 1 readiness re-adoption (Claude).

These are load-bearing for Phase 1 and should not be touched during the walker rewrite.
