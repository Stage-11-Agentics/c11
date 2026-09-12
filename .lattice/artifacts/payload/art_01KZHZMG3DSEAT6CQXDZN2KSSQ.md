# Plan Review: C11-203 — Launch Agents rework

## 1. Verdict

**FAIL (plan-level)** — the plan contradicts the task description on Part G, encoding the superseded operator direction. Return to `in_planning` for a targeted revision; everything else is in strong shape.

## 2. Summary

The plan is a near-verbatim copy of the task description (which is itself unusually plan-shaped: root causes traced to exact lines, live-verified CLI facts, per-part file anchors — all of which I spot-checked against the codebase and found accurate). The disqualifying problem is Part G and acceptance criterion 9: the task records the operator's 2026-08-08 call to **remove the launch-stats UI entirely** — no new display, no menu entry — while the plan instead directs the implementer to **build a standalone Usage Statistics display with a menu-bar item**. The plan is a stale copy of an earlier task revision and was never refreshed after the operator's call.

## 3. Issues

**[CRITICAL] Part G / Acceptance criterion 9 — Plan directs building a surface the operator explicitly de-scoped**
The task's Part G says: "remove the launch-stats **UI** entirely for now. No new display, no Settings page, no popover row… if it comes back it comes back as a deliberate design." The plan's Part G says the opposite: "New standalone display (own window/surface), titled Usage Statistics" plus a menu item (G1/G2), and its AC 9 requires that display to open from a menu item. A diff of the two documents shows they are byte-identical *except* this section — the plan preserved the pre-revision direction. Implementing per the plan ships exactly the unearned surface the operator removed from scope. The plan's Part G also silently drops the task's G3 requirement to remove `controller.onStats` and its wiring in `Workspace.presentAgentPicker` (`Sources/Workspace.swift:12781` on the current branch), so a stats hook would survive in the picker controller.
**Recommendation:** Replace the plan's Part G and AC 9 with the task's current text verbatim (G1–G4: remove popover stats row + `statsHeadline` plumbing, remove `statsMode`/`AgentConfigEditorFocus.stats` and the stats view, remove `controller.onStats` wiring, keep `AgentLaunchStatsStore` / `agent-launch-stats.json` / `agent-launches.jsonl` recording). Since the rest of the plan matches the task exactly, this is a small, surgical revision.

**[MAJOR] Acceptance criterion 10 (in both plan and task) — smoke pass demands a screenshot of a display that must not exist**
AC 10 requires "screenshots of the popover, the editor, and the Usage Statistics display." Under the current Part G there is no Usage Statistics display anywhere in the app. This clause is residue of the same superseded revision, and it lives in the task description too, not just the plan. Left as-is it either makes the smoke pass unsatisfiable or — worse — reads as license to build the removed surface in order to screenshot it.
**Recommendation:** In the plan, replace the clause with negative verification: screenshots proving no stats UI in the popover, the config editor, or Settings, plus a check that `agent-launches.jsonl` gained entries from the smoke launches (verifying G4's "rail keeps recording"). Flag the task-side copy to the board owner so the task description gets the same fix.

**[MAJOR] Part D — no implementation strategy for live catalog enumeration beyond the task text**
Part D is the largest new subsystem in the ticket (subprocess enumeration of four CLIs, caching, a generated offline snapshot, a 432-entry searchable list, openrouter provider flattening), and the plan adds zero shape on top of the requirement. Unanswered: *when* enumeration runs (app launch? editor open? background refresh?) and with what timeout; behavior on a machine where a CLI is missing or hangs; where the generated snapshot lives and what produces it (a committed script output? a build phase?); and how it's tested — the repo's test-quality policy forbids tests that merely assert checked-in metadata, so the pipeline needs a runtime seam (e.g., injectable enumerator output) to be testable in `c11-logic`.
**Recommendation:** Add a short design paragraph: e.g., a repo script (`scripts/generate-model-catalogs.sh` or similar) produces the snapshot resource; at runtime the editor refreshes asynchronously off-main with a bounded timeout, caching results under Application Support; enumeration failure or missing CLI falls back to cache then snapshot; catalog parsing and flattening tested through an injected-output seam in `c11-logic`.

**[MINOR] Part B4 — cross-reference typo (in both plan and task)**
"Remove the 'Launch stats' footer row… See Part F." Part F is editor UX; stats is Part G.
**Recommendation:** Change to "See Part G" in the plan; note it for the task as well.

**[MINOR] Whole plan — no sequencing or dependency ordering**
The ticket is deliberately one pass (operator's call, not re-litigated here), but the plan states no order of operations. Some edges matter: the corrupted `agent-configs.json` must be copied as a fixture *before* any A2 repair code runs on the operator's machine; the B2 schema drop (`followRecent` removal) must land in the same change as the `config.*` socket family and `skills/c11/references/api.md` updates or the CLI can write a mode the app no longer reads; the localization + skill-sync passes come last.
**Recommendation:** Add a brief ordered sequence, e.g.: fixture capture → A2 heal + A1 feedback → B/G popover removals + schema migration (with socket/skill docs) → C/D/E editor rework → F polish → localization pass → tagged-build smoke.

## 4. Positive Observations

- **Every code anchor is real.** I verified the load-bearing references on the current branch: the silent guard `guard !launch.command.isEmpty else { return false }` (`Sources/Workspace.swift:12546`), `factorySeedConfigId = "0000000000AGENTOPUSDEEP001"` (`Sources/AgentConfigLibraryStore.swift:260`), `reconcileHarnessSwitch` (`Sources/AgentConfigEditorModel.swift:187`), `routerModelCatalog` / `freeformSuggestions` (`:161`/`:171`), `AgentConfigAxes.providerClass` (`:79`), the `onStats` / `statsHeadline` plumbing, `AgentConfigEditorFocus.stats`, and the `followRecent` picker wiring. A plan whose line numbers survive contact with the tree is rare and valuable.
- **Defect-class framing.** A1 treats "silent no-op on decline" as the class, with the specific data corruption as one instance — the right altitude for a fix that has to cover three entry points.
- **Live-verified facts, dated.** Every model/flag claim carries its verification method and date (2026-08-08, live CLIs on Hyperion), including a correction of a prior wrong read (Kimi effort) and an explicitly flagged open question (E3, opencode `--variant` in the interactive TUI) rather than a silent assumption.
- **Preservation instincts.** Keeping the stats data rail while removing its UI, keeping the `recent` record as telemetry after it stops driving resolution, and preserving the corrupted `agent-configs.json` as a migration-test fixture all protect accumulated state from UI-level decisions.
- **Cross-surface schema discipline.** The notes correctly extend the follow-recent schema drop to the `config.*` socket family and the skill reference doc, which is exactly the seam where a Swift-only change would rot.
