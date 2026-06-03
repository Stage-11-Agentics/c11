## Standard-Lens Synthesis — CMUX-37 Phase 0

- **Date:** 2026-04-24
- **Branch:** cmux-37/phase-0-workspace-apply-plan
- **Latest Commit:** e4f60b987d5b0477cd4b172878152450a9965a84
- **Inputs:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`
- **Lens:** Standard (senior engineer, full-scope review)
- **Scope reminder:** Phase 0 only — `WorkspaceApplyPlan` + `WorkspaceLayoutExecutor` + acceptance fixture + optional `workspace.apply` v2 handler & `c11 workspace-apply` CLI. Missing Blueprint parser, Snapshot writer, session resume, welcome-quad migration are **not** gaps.

---

### Executive summary

All three models converge on a single high-confidence correctness blocker and a matching test-coverage blocker:

1. The `WorkspaceLayoutExecutor` split walker is **post-order** (fully materializes `split.first`, then splits off the first anchor for `split.second`). Bonsplit's `splitPane` wraps the **source pane** locally — it cannot split a whole subtree. Any nested-split plan (welcome-quad, default-grid, deep-nested-splits, mixed-browser-markdown) materializes the wrong tree geometry.
2. The acceptance fixture only checks ref-set membership, absence of `validation_failed`, and timing. It does **not** assert the live `bonsplit` tree matches the plan's `LayoutTreeSpec` — which is why blocker #1 ships undetected. The plan document (section 6) explicitly calls for a structural fingerprint assertion.

These two blockers are tightly coupled: fix the test first so the geometry bug becomes a visible, failing assertion; then rewrite the walker as pre-order.

Beyond these, the branch is clean. Claude and Codex both praise the fidelity to the plan (value shapes, `PersistedJSONValue` reuse, `.explicit` writer source, `mailbox.*` strings-only guard, no hot-path edits, no terminal-opinion creep, clean commit boundary). Gemini raises two additional concerns (an alleged optional-dictionary compile error and a main-thread socket data race) that are much weaker — likely false positives — and are examined in the Divergent Views section below.

### Merge verdict recommendation: **FAIL-IMPL-REWORK**

Rationale: the primitive's core contract is "materialize the requested pane tree" and the walker does not do that for any nested split. That is an implementation bug (not a plan defect), and the acceptance harness needs a structural assertion before the rewrite can be validated. Neither demands re-planning — the shapes, schema, and strategy are right. Two focused commits should clear this: (a) add structural fingerprint assertions to `WorkspaceLayoutExecutorAcceptanceTests`; (b) rewrite `materializeSplit` as pre-order. Important items 3–6 below can land as follow-ups post-merge.

If the operator prefers a softer verdict, MINOR FIXES is defensible **only** if the fix is made + CI-validated in the same merge window; the geometry bug is not cosmetic.

---

### 1. Consensus issues (2+ models agree)

1. **[BLOCKER] Walker produces wrong pane-tree geometry for nested splits.**
   - Agreed by: Claude (Blocker 1), Codex (Blocker 1). Gemini does not raise it explicitly but does not contradict.
   - Files: `Sources/WorkspaceLayoutExecutor.swift:155`, `Sources/WorkspaceLayoutExecutor.swift:448-501`.
   - Mechanism: DFS recurses into `split.first` first, then calls `splitFromPanel(firstAnchorPanelId, ...)` for the outer split. Bonsplit's `splitPane` (at `Sources/Workspace.swift:7315-7327`) wraps only the source pane, so the outer split lands on a single leaf rather than the whole first subtree.
   - Welcome-quad trace produces `V{H{tl, V{tr, br}}, bl}` instead of `H{V{tl, bl}, V{tr, br}}`.
   - Reference implementation is outer-first: `performQuadLayout` at `Sources/c11App.swift:4007-4046`.
   - Fix shape (Claude): pre-order traversal — split anchor first to produce `(firstAnchor, secondAnchor)`, then recurse into both subtrees with pre-computed anchors, then apply `split.dividerPosition`. `applyDividerPositions` (`:716-744`) becomes correct once the live tree structurally matches the plan tree.

2. **[BLOCKER] Acceptance fixture does not assert pane-tree geometry.**
   - Agreed by: Claude (Blocker 2), Codex (Important 2).
   - Files: `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:49, 106-147`; plan at `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:452-453`.
   - Current assertions: `workspaceRef` non-empty, `surfaceRefs.keys == expectedSurfaceIds`, `paneRefs.keys == expectedSurfaceIds`, no `validation_failed`, total < 2_000 ms.
   - Missing: "Asserts the resulting pane tree matches a structural fingerprint" (per plan section 6). `deep-nested-splits.json` should exercise divider position application; no assertion does.
   - Fix shape: walk `workspace.bonsplitController.treeSnapshot()` and compare orientation + leaf surface-ids in depth-first order against an expected fingerprint embedded per-fixture (or derived from the plan's `LayoutTreeSpec`). Use `ExternalTreeNode` (same type `applyDividerPositions` consumes).

3. **[IMPORTANT] `SurfaceSpec.workingDirectory` silently dropped for split-created surfaces and the reused root seed.**
   - Agreed by: Claude (Important 3), Codex (Potential 5).
   - Files: `Sources/WorkspaceLayoutExecutor.swift:88, 399, 506-537`; primitive at `Sources/Workspace.swift:7250-7276`.
   - Only in-pane tabs via `createSurface` (`:671-697`) honor `spec.workingDirectory`. Splits inherit from source; root reuses seed cwd (`plan.workspace.workingDirectory`).
   - Docstring at `Sources/WorkspaceApplyPlan.swift:67-68` claims "passed to the creation primitive's `workingDirectory:`" — contract mismatch.
   - Fix options: (a) extend `Workspace.newTerminalSplit` to accept `workingDirectory:` (preferred); (b) document the limitation explicitly in the spec docstring and plan section 3; (c) fall back to a one-shot `cd` in the initial command for split-created terminals.

4. **[LOWER] `ApplyOptions` has fields that are inert in Phase 0.**
   - Codex (Important 4) flags `ApplyOptions.perStepTimeoutMs` as documented-but-unused: the executor records timings but never compares them against the threshold or emits a warning.
   - Gemini (Tactical 4) flags `ApplyOptions.autoWelcomeIfNeeded` as overwritten by a hard-coded `false` in the internal `TabManager.addWorkspace` invocation.
   - Both are shape-right/behavior-absent. Either implement the per-step warning now or tighten the docstrings until Phase 1 readiness lands. Not a blocker for Phase 0 correctness.

---

### 2. Divergent views (where models disagree — signal worth examining)

1. **Gemini Blocker 1 — "optional dictionary subscripting compile error" in `Workspace.setOperatorMetadata`.**
   - Gemini claims `var next = metadata` followed by `next[key] = trimmed` will fail to compile if `Workspace.metadata` is `[String: String]?`, and proposes `var next = metadata ?? [:]`.
   - Claude's Potential 8 examines the same setter at `Sources/Workspace.swift:6051-6074` and describes it as "write path is fine — trims keys/values, drops empties, compares before assigning." Codex does not raise this at all.
   - **Resolution:** the setter is a `@Published var metadata: [String: String]` per Claude's read (non-optional). If it were optional, the branch would fail to build and neither CI nor local compile would be green. Treat this as a **likely false positive** from Gemini unless a quick `grep` of `class Workspace` reveals a genuine optional declaration. Recommend: verify the declaration, dismiss if non-optional.

2. **Gemini Blocker 2 — "main-thread socket data race" in the `WorkspaceApply` handler.**
   - Gemini claims `WorkspaceLayoutExecutorDependencies` minters invoke `v2EnsureHandleRef` on the main actor, and that `v2EnsureHandleRef` mutates off-main socket-handler state, creating races with independent handlers. Proposes that the executor return bare UUID mappings and have off-main socket logic mint refs.
   - Claude's review at `Sources/TerminalController.swift:4337+` describes the handler as a **textbook off-main decode → v2MainSync for AppKit mutation** implementation, with no spurious `Task {}` wrap. Codex does not raise threading at all.
   - **Resolution:** `v2EnsureHandleRef` (called at `Sources/TerminalController.swift:3278`) is part of the v2 ref registry; Claude's read is that it is designed for main-actor ownership (refs are ordinals minted per-window from AppKit state). The executor explicitly runs `@MainActor from entry` (Claude Architectural Assessment), matching every downstream dependency. Gemini's concern would be valid only if `v2EnsureHandleRef` is itself thread-unsafe off the main actor, which contradicts the existing pattern. Treat as **likely false positive** unless the registry's ownership model is different from what Claude describes. Recommend: confirm `v2EnsureHandleRef`'s actor isolation with a quick read.

3. **Seed-panel replacement — option (a) chosen.**
   - Claude: acceptable for Phase 0 (brief terminal flash before replacement for browser/markdown roots); worth considering option (b) `TabManager.addWorkspaceWithoutSeed` for Phase 1.
   - Gemini (Important 3): raises concern about cascading `bonsplit` tree destruction on single-pane arrays if the force-close fires before replacement binds (flagged as ❓ Uncertain).
   - Codex: silent.
   - **Resolution:** Claude's framing — aesthetic flash, not correctness — is the likely-correct read given the implementation writes the replacement panel before `closePanel(seed.id, force: true)`. Gemini's concern is worth a one-line sanity check but is not a blocker.

4. **Tone / fidelity assessment.**
   - Claude: "reads like someone who understood the plan, followed it line-for-line, and made disciplined in-session calls on open questions."
   - Codex: "well scoped to Phase 0… aligned with C11-13. Hot-path files and terminal-opinion areas are not changed."
   - Gemini: more skeptical overall, raising two alleged blockers (see #1 and #2 above) that the other two models either contradict or implicitly dismiss. Signal: Gemini's concerns are worth a 5-minute sanity check but should not drive the merge verdict on their own.

---

### 3. Unique findings (only one model raised)

**From Claude only:**

- **[IMPORTANT] `metadata_override` for reserved keys routes around canonical writers.** Covered in Claude Important 3 and Codex Important 3 — actually consensus, see below in section 1 note. *(Correction: this is consensus; moved.)*
- **[IMPORTANT 4] `applyDividerPositions` silent `default: return` fallback on shape mismatch.** `Sources/WorkspaceLayoutExecutor.swift:716-744`. After blocker 1 is fixed, residual shape divergences (e.g., mid-walk failure) should emit a `dividerPosition.dropped` warning rather than silently no-opping.
- **[IMPORTANT 5] `SurfaceMetadataStore.reservedKeys` enforces kebab-case on `role`/`model`/`terminal_type`.** Not introduced by this branch, but plan authors who submit `"role": "Driver"` get `reservedKeyInvalidType` → `metadata_write_failed`. Consider a negative acceptance fixture that locks this behavior.
- **[IMPORTANT 6] Acceptance test `panelId(forSurfaceRef:)` depends on synthetic ref format.** `c11Tests/...AcceptanceTests.swift:114-117, 159-166`. The test parses `surface:{UUID}` to find the panel — only works under the synthetic `workspaceRef: { "workspace:\($0.uuidString)" }` minter. Under the real socket handler, refs are ordinals (`surface:1`) and this parse breaks. Document the dependency.
- **[POTENTIAL 7] "Kind mismatch" branch at `materializePane` (:363-392) assumes only root-level mismatch.** Re-verify during the walker rewrite; pre-order traversal should preserve the invariant but worth a second look.
- **[POTENTIAL 8] `Workspace.setOperatorMetadata` persistence hook.** `Sources/Workspace.swift:6051-6074`. No explicit "commit to persistence" call; relies on `@Published` observer. Confirm the Phase 1 Snapshot writer will see the writes.
- **[POTENTIAL 9] `v2WorkspaceApply` scope — no `workspaceRef` / `windowId` binding.** Fine for creation-only Phase 0; will need attention when Phase 1 adds "apply to existing workspace."
- **[POTENTIAL 10] `LayoutTreeSpec` Codable redundancy.** `{"type":"pane","pane":{...}}` — could be flattened. Not a correctness issue; style call.
- **[POTENTIAL 11] CLI naming convention.** `c11 workspace-apply` (hyphen) vs socket `workspace.apply` (dot). Consistent with existing `claude-hook session-start` precedent.
- **[POTENTIAL 12] No `mailbox_non_string_value` failure-path fixture.**
- **[POTENTIAL 13] No `metadata_override` failure-path fixture.**
- **[POTENTIAL 14] `ApplyFailure.code` strings are string literals scattered across emit sites.** Consider a central namespace (`extension ApplyFailure { static let mailboxNonStringValue = "mailbox_non_string_value" }`) for typo-proofing.

**From Codex only:**

- **[IMPORTANT 3] `metadata["title"]` override writes the store but leaves live title state stale.** `Sources/WorkspaceLayoutExecutor.swift:403, 576`; see also `Sources/Workspace.swift:5873` and `Sources/TerminalController.swift:6523`. Executor applies `SurfaceSpec.title` via `workspace.setPanelCustomTitle`, then if `spec.metadata["title"]` also exists, writes it directly to `SurfaceMetadataStore` and records `metadata_override`. The comment says "metadata wins" — but the direct store write skips `syncPanelTitleFromMetadata` (the title side-effect path used by the socket metadata API). Result: `SurfaceMetadataStore["title"]` can diverge from `panelCustomTitles` / bonsplit tab title. Fix: either route metadata-title through `setPanelCustomTitle`, call the title sync after the metadata write, or reject the duplicate if overrides are not supported.

  *Claude flagged the override contract generally (Tactical assessment) but did not catch the title-sync miss. This is a legitimate unique find.*

**From Gemini only:**

- **[ARCH] `Task.yield()` checkpoints for Phase 1.** Synchronous `apply()` holds the main actor for the full walk; budget is 2_000ms per fixture. Acceptable for Phase 0 per the Impl-deviation note. Phase 1 will need yield points.
- **[TACTICAL 1] Alleged compile error — see Divergent Views #1 (likely false positive).**
- **[TACTICAL 2] Alleged main-thread socket data race — see Divergent Views #2 (likely false positive).**
- **[TACTICAL 5] `PaneID` struct vs UUID typealias.** Aesthetic; confirmed working.

---

### 4. Consolidated findings (deduplicated, prioritized)

#### Blockers (must fix before merge)

- **B1.** Rewrite `WorkspaceLayoutExecutor.materializeSplit` as pre-order: split the anchor first to produce `(firstAnchor, secondAnchor)`, then recurse into both subtrees using the pre-computed anchors, then apply divider positions. Files: `Sources/WorkspaceLayoutExecutor.swift:448-501` (walker), `:716-744` (divider walker becomes correct naturally). Reference: `performQuadLayout` at `Sources/c11App.swift:4007-4046`. **(Claude B1 + Codex B1)**
- **B2.** Add structural fingerprint assertions to all five fixture tests. Walk `workspace.bonsplitController.treeSnapshot()` post-apply; compare orientation + leaf surface-ids in DFS order against an expected fingerprint derived from the plan's `LayoutTreeSpec`. Include divider position checks for `deep-nested-splits`. Files: `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift`. **(Claude B2 + Codex I2)**

Fix order: land B2 first → watch all five fixtures fail → land B1 → watch all five pass.

#### Important (should land in follow-up commits)

- **I1.** Resolve `SurfaceSpec.workingDirectory` contract. Either extend `Workspace.newTerminalSplit` to accept `workingDirectory:` (preferred), document the limitation in the spec docstring and plan section 3, or fall back to a one-shot `cd` in the initial command. Files: `Sources/WorkspaceLayoutExecutor.swift:88, 399, 506-537`; `Sources/Workspace.swift:7250-7276`; `Sources/WorkspaceApplyPlan.swift:67-68`. **(Claude I3 + Codex P5)**
- **I2.** Fix `metadata["title"]` override path: route through `setPanelCustomTitle` OR call `syncPanelTitleFromMetadata` after the direct store write OR reject the duplicate. Files: `Sources/WorkspaceLayoutExecutor.swift:403, 576`; `Sources/Workspace.swift:5873`; `Sources/TerminalController.swift:6523`. **(Codex I3)**
- **I3.** `ApplyOptions.perStepTimeoutMs` is documented but inert. Either implement the per-step warning emission or tighten the docstring until Phase 1. File: `Sources/WorkspaceApplyPlan.swift:196`; executor at `:68`. **(Codex I4)**
- **I4.** `applyDividerPositions` silent `default: return` — emit a `dividerPosition.dropped` warning instead of silently no-opping. Applies after B1 lands. File: `Sources/WorkspaceLayoutExecutor.swift:716-744`. **(Claude I4)**

#### Lower priority (nice-to-have; tracked for Phase 1)

- **L1.** Kebab-case validation for `role` / `model` / `terminal_type` — consider a negative acceptance fixture. (Claude I5)
- **L2.** `panelId(forSurfaceRef:)` test-only parse depends on synthetic UUID minter — document dependency. (Claude I6)
- **L3.** Re-verify kind-mismatch invariant after walker rewrite. (Claude P7)
- **L4.** Confirm `Workspace.setOperatorMetadata` persistence hook for Phase 1 Snapshot writer. (Claude P8)
- **L5.** `v2WorkspaceApply` scope — no `workspaceRef` / `windowId` today; document for Phase 1. (Claude P9)
- **L6.** `LayoutTreeSpec` Codable redundancy — leaner encoding possible. (Claude P10)
- **L7.** CLI `workspace-apply` hyphen vs socket `workspace.apply` dot — intentional convention, worth a note in the skill. (Claude P11)
- **L8.** Add fixtures for `mailbox_non_string_value` (Claude P12) and `metadata_override` (Claude P13) failure paths.
- **L9.** Central `ApplyFailure.code` constant namespace for typo-proofing. (Claude P14)
- **L10.** `ApplyOptions.autoWelcomeIfNeeded` overwritten by hard-coded `false` — dead parameter today, tighten or keep for Phase 1 shape. (Gemini T4)
- **L11.** `Task.yield()` points for Phase 1 budget. (Gemini Arch)
- **L12.** Seed-panel force-close — add a single sanity check that cascading bonsplit destruction is impossible on single-pane arrays. (Gemini T3)
- **L13.** Sanity-verify the two Gemini alleged blockers (optional-dict compile, main-thread race) with a quick read; dismiss if false positives. (See Divergent Views #1, #2.)

---

### What everyone agrees is NOT a concern

- `PersistedJSONValue` reuse (correct call per plan rationale; no new JSON flavor).
- Writer `source = .explicit` used consistently across all store writes.
- Reserved keys (`title`, `description`) routed through canonical setters in the normal path (`setPanelCustomTitle`; partial-merge setter for description). The title-override edge case noted in I2 is the exception.
- `mailbox.*` strings-only guard at `Sources/WorkspaceLayoutExecutor.swift:631-643`. Accepts `.string(_)` only, emits `mailbox_non_string_value` otherwise, lets non-mailbox keys through with full JSON values. Matches `docs/c11-13-cmux-37-alignment.md` locked convention #3.
- Partial-failure semantics (workspace never rolled back; warnings + failures surface without blowing up the apply).
- 8-commit boundary hygiene — each commit buildable, each message cites its plan section.
- Hot paths untouched: `TerminalWindowPortal.hitTest`, `TabItemView`, `GhosttyTerminalView.forceRefresh` all unchanged per diff scan.
- Terminal-opinion creep: zero. No `Resources/bin/claude` edits. No `c11 install <tui>` revival. No tenant-config writes.
- Localization: new strings are operator-facing debug text (CLI usage, failure codes, warnings). No SwiftUI `Text()` / `Button()` labels added. Acceptable per existing convention.
- Async drop from `apply()`: well-justified by the Impl deviation note; no trailing awaits; socket handler calls executor synchronously via `v2MainSync`, no spurious `Task {}` wrap.
- CLI `c11 workspace-apply` implementation at `CLI/c11.swift:1713-1760` — minimal, matches precedent.
- v2 socket handler at `Sources/TerminalController.swift:4337+` — off-main decode, main-sync AppKit mutation, clean envelope.

---

### Recommended merge path

1. **Add structural fingerprint assertion** to `WorkspaceLayoutExecutorAcceptanceTests` (Blocker B2). All five fixtures gain an expected pane-tree fingerprint derived from their `LayoutTreeSpec`. Deep-nested-splits fixture also asserts divider positions.
2. **Run `gh workflow run test-e2e.yml` with `test_filter=WorkspaceLayoutExecutorAcceptanceTests`.** Confirm all five fixtures fail structurally (this is the visible proof of B1).
3. **Rewrite `materializeSplit` as pre-order** (Blocker B1). Split the anchor first, then recurse with pre-computed `(firstAnchor, secondAnchor)`.
4. **Re-run the workflow.** Confirm all five pass.
5. **Merge.** Follow up with Important I1–I4 in separate commits.
6. **Before the rewrite, take 10 minutes** to sanity-check the two Gemini alleged blockers (Divergent #1 and #2). If either is real (it would fail to compile or show in existing threading tests), fold into the fix commits; otherwise dismiss.

---

### Final verdict

**FAIL-IMPL-REWORK.** Two coupled blockers (walker geometry + missing test assertion) prevent the primitive from fulfilling its Phase 0 contract. The rework is localized — one test file and one function — and the surrounding architecture, schema, commit hygiene, and integration with existing stores are right. Plan does not need revisiting; implementation does.
