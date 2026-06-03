# C11-111 plan review (single reviewer)

**Verdict:** APPROVE WITH AMENDMENTS

Plan is well-grounded, matches existing code shape, and the test seams (especially `AgentSkillsRowVariant` + `AgentSkillsShouldPresentTests`) follow the C11-27 logic-split convention. The amendments below are precise fixes, not rewrites.

## Amendments

1. **"Maybe later" must NOT write to the dismissal store.** The plan's `recordDismissals(rows:, defaults:)` is described as firing on "Maybe later or close" — that directly contradicts AC #3 ("Maybe later → re-fires next launch, in-memory dismissal only"). The persistent per-(target, skill) hash is only written when the operator *explicitly* declines a row via the "Update selected" path (i.e., unchecks Codex and clicks Update selected). The ticket text in the *Per-target dismissed-against-hash memory* section is internally inconsistent with its own ACs; the plan should resolve in favor of the ACs. Fix in plan: rename `recordDismissals` to `recordDismissalsForUncheckedRows`, fire it only from the "Update selected" branch, and have "Maybe later" + window close call only `markDismissedThisLaunch()`. Adjust `AgentSkillsDismissalStoreTests` and `AgentSkillsShouldPresentTests` accordingly.

2. **Help → "Re-enable agent skills install prompts" needs unconditional present.** Plan calls `presentAgentSkillsOnboardingIfNeeded()`, which short-circuits via `shouldPresent` → false when everything is current. Operator clicks "Re-enable" and sees nothing, which is the exact dead-end amendment #2 is meant to fix. Fix: after clearing the flag + dismissals, call `presentAgentSkillsOnboarding()` (unconditional), so the celebratory branch renders if there's no action needed. Note this in *Touch points* and bump the AppDelegate touch from "confirm it still works" to "add/expose an unconditional present hook for the Help action."

3. **Row variant helper: name the consumer.** `AgentSkillsRowVariant(for: status, bundledHash:)` is the right seam, but the plan should explicitly state that the SwiftUI row reads through this helper too (not just the test). Otherwise it reads as test-only API, which the *Test quality policy* rightly rejects. One sentence in §"Per-row content" pointing at the helper closes it.

4. **Description multi-line behavior is a real product call, not just a parser quirk.** `testDescriptionWithMultilineIsTruncatedToFirstLine` documents the limitation, but several existing SKILL.md frontmatters in `skills/` use multi-line `description:` values via YAML continuation. Plan should either (a) parse YAML folded/literal scalars, or (b) explicitly call out that we'll edit the bundled SKILL.md files to single-line descriptions as part of this PR. Pick one; current plan silently truncates working content.

## Nits (do, don't redo plan-review)

- `loadDismissals` / `saveDismissals` / `key(for:skillName:)` don't need MainActor isolation — they're pure `UserDefaults` reads/writes. Keep `shouldPresent` on MainActor for `_dismissedThisLaunch`; let the helpers be `nonisolated`.
- Orphan dismissal entries (operator removes `~/.codex`, or a skill is renamed): plan is silent. Acceptable to defer for v1 — entries are inert noise — but a one-liner under *Out of scope* would close the question.

## Approvals

- A. Acceptance-criteria coverage: covered modulo amendment #1.
- B. Amendments coverage: covered modulo amendments #2 and #3.
- C. Data-model correctness: key shape unambiguous; orphan deferral acceptable (call it out per nit).
- D. Test design: classes test runtime behavior, suite-named `UserDefaults`, no source-text greps. Good.
- E. Localization completeness: 10 new keys enumerated; reuses existing keys for "Will update/install/Already current"; the per-skill description text is content (not localized), correctly excluded.
- F. Migration safety: bounded — worst case is "re-prompt once per skill", which is the v0.49 → v0.50 upgrade path the ticket already promises. Gate on `c11SkillDismissals` absent is sufficient.
- G. Out-of-scope discipline: defers `c11 skills status` CLI (ticket "Maybe"); adds per-row Reveal and Refresh-all (justified under amendments). Clean.
- H. Touch-point sanity: AgentSkillsView, SkillInstaller, ContentView Help popover, Localizable.xcstrings. AppDelegate gets a real touch per amendment #2, not just "confirm."

Ready to implement once amendments #1–#4 land in the plan.