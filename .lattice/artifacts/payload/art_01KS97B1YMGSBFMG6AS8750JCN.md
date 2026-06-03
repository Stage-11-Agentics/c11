# C11-111 code review

**Verdict:** APPROVE

Plan and implementation are tightly aligned; all four amendments from `art_01KS951AQKH3689XHP626A6E9W` landed; tests cover meaningful behavior; localization is complete with all 7 locales; no policy violations.

## A. Correctness against the plan
- `SkillInstaller.readFrontmatterValue` + `readSkillDescription` + `SkillInstallerPackage.description` threaded through `discoverPackages` at `Sources/SkillInstaller.swift:222,260,266-272`. Clean refactor of the prior `readSkillVersion` into a shared key-driven helper.
- `AgentSkillsOnboarding.dismissalsKey` / `dontAskAgainKey` / `legacyOnboardingShownKey` all present with the documented semantics at `Sources/AgentSkillsView.swift:1342-1362`.
- `loadDismissals` is tolerant of missing key and non-String values (filters via `if let s = v as? String`); `saveDismissals` removes the key when dict is empty. Good.
- `recordDismissalsForUncheckedRows(offered:selectedKeys:defaults:)` — signature differs from plan (`offered:` + `selectedKeys:` instead of `rows:`) but is cleaner; it iterates `offered where shouldRowOffer($0)` and skips selected entries. Records bundled hash, never clobbers selected entries with stale data.
- `clearDismissal(for:skillName:defaults:)` and the `install`-path clear at `Sources/AgentSkillsView.swift:163-165` correctly invoke per `result.installed + result.refreshed`. Only packages actually written get cleared.
- `shouldPresent` rewrite at `Sources/AgentSkillsView.swift:1521-1551` matches the documented order: dontAskAgain → _dismissedThisLaunch → resolve sourceDir → migrateLegacyDismissalsIfNeeded → iterate. `sourceDir: URL?` injection seam present.
- `migrateLegacyDismissalsIfNeeded` at `Sources/AgentSkillsView.swift:1478-1499` writes only `.installedCurrent` entries, gated on (a) dismissals dict absent and (b) legacy flag set, and always persists (even an empty dict) to mark the migration done.
- `AgentSkillsRowVariant.classify` at `Sources/AgentSkillsView.swift:381-396` correctly distinguishes the local-edits sub-case via `record.sourceContentHash == status.sourceContentHash`.
- `applySelection` at `Sources/AgentSkillsView.swift:1028-1052`: records dismissals for unchecked rows BEFORE running installs, force=true so `.installedNoManifest` and `.schemaMismatch` pass. install-path clears dismissals for installed/refreshed packages.
- Primary-action label flip via `allOfferedSelected` at `Sources/AgentSkillsView.swift:680-693`. "Update all" when everything's selected, "Update selected" when operator has narrowed.
- Celebratory branch present in `headerTitle` (1338-1346), `headerBody` (1349-1361 in 746-752), `primaryActionTitle` (669-679), and "Refresh all" button (975-983).
- Per-skill `skillSubRow` (819-907) renders icon + name + version chip + Reveal + description + warning. Hides Reveal for `.notInstalled` rows.
- Help → "Re-enable agent skills install prompts" at `Sources/ContentView.swift:10571-10580` calls `presentAgentSkillsOnboarding(onCompletion: nil)` UNCONDITIONALLY (not `IfNeeded`), preceded by `clearAllSilencing()`. Visibility gated on `hasSilencedState()` at `ContentView.swift:10463`.
- `BundledSkillsManifestTests.testEveryBundledSkillDescriptionFitsOnOneLine` enforces the single-line contract.

## B. Acceptance criteria coverage
| AC | Where covered |
|---|---|
| v0.47 → v0.49 re-surfaces "Update available" | `testDismissedEntryAgainstOldHashAllowsPresent` + `shouldPresent` rewrite |
| "Update all" silences until next change | `recordDismissalsForUncheckedRows` skips selected; install-path clears |
| "Maybe later" re-fires next launch | `installLater()` only flips in-memory bool; window-close observer in AppDelegate also routes to `markDismissedThisLaunch()` |
| "Don't ask again" survives content change | `dontAskAgainKey` checked first in `shouldPresent`; `testDontAskAgainBeatsDriftedContent` |
| Decline Codex, only re-fires when Codex content changes | `testRecordDismissalsForUncheckedRowsCapturesBundledHash` + per-(target,skill) hash store |
| Local edits flagged | `AgentSkillsRowVariant.classify` + `skillSubRowWarning` |
| `c11 doctor` parity | DEFERRED per plan; not required for this PR |

## C. Test quality
- All tests verify observable behavior — UserDefaults state, returned dicts, parsed values, classifier outputs. No source-text or plist asserts.
- Hermetic UserDefaults via `makeIsolatedDefaults` with suite name `"c11.tests.<func>.<UUID>"`. No `.standard` writes anywhere in test bodies.
- Tmp dirs scoped with `UUID()` and cleaned up via `defer { try? FileManager.default.removeItem(at: root) }`.
- `BundledSkillsManifestTests` walks `#filePath` to find the repo `skills/` dir; throws `XCTSkip` if it can't (running outside the source tree). Heuristic for multi-line detection catches `>` / `|` / quoted continuations / indented continuation lines. Practical for the bundled-skills contract; not a full YAML parser, by design.

## D. c11 policy compliance
- No `TabItemView`, `TerminalSurface`, or `WindowTerminalHostView.hitTest` modifications. `AgentSkillsView` is a modal sheet; `ContentView` edit is in the sidebar Help popover button.
- All new user-facing strings use `String(localized:defaultValue:)` (verified by grep across diff).
- Test file is in the `c11LogicTests` build phase (`37DDE3B0A6A70E75A7B2BEDF` Sources phase). No host-bound `c11Tests` invocations added.
- No socket commands added — `c11 skills status` deferred per plan.
- All filesystem writes outside c11's own runtime stay inside the existing `SkillInstaller.install` / `remove` surface. No new tenant-config writes.

## E. Localization completeness
- All 9 new keys present with all 7 locales (en, ja, uk, ko, zh-Hans, zh-Hant, ru). Verified with a JSON parse:
  - `agentSkills.onboarding.updateAll`, `updateSelected`, `refreshAll`, `done`, `title.celebratory`, `body.celebratory`, `row.localEditsWarning`, `row.revealInFinder`, `sidebar.help.reEnableSkillPrompts`.
- Plan listed `agentSkills.help.reEnablePrompts` and `agentSkills.onboarding.row.willReplace`. The former was renamed to `sidebar.help.reEnableSkillPrompts` (fits the existing `sidebar.help.*` peer keys); the latter was consolidated — both `localEditsWillBeOverwritten` and `willReplaceUnmanaged` variants reuse `row.localEditsWarning`. Acceptable.
- Spot-checked ja/uk/ko/zh-Hans/zh-Hant/ru translations for `updateAll`, `localEditsWarning`, `reEnableSkillPrompts`, `title.celebratory` — all plausible, register and tone match peer keys.

## F. MainActor / concurrency
- `_dismissedThisLaunch`, `markDismissedThisLaunch`, `dismissedThisLaunch`, and `shouldPresent` correctly marked `@MainActor` (lines 1369, 1371, 1375, 1521).
- `loadDismissals`, `saveDismissals`, `dismissalKey`, `recordDismissalsForUncheckedRows`, `clearDismissal`, `clearAllSilencing`, `hasSilencedState`, `shouldRowOffer`, `migrateLegacyDismissalsIfNeeded` are all on a bare `enum` (no enum-level `@MainActor`), so they're nonisolated by default — pure UserDefaults / filesystem reads, callable from any context. Matches plan amendment #5.

## G. Edge cases
- Target loses detection between launches: `shouldPresent` loop is `where target.isDetected(...)`, so orphans are inert; no crash. Plan defers GC. Verified.
- Empty `description:` value: `readFrontmatterValue` returns nil when trimmed empty. View checks `if let description, !description.isEmpty` — no crash, just no description line. Verified.
- Corrupted dismissals dict (mixed types): `loadDismissals` filters via `if let s = v as? String`. `testLoadDismissalsTolerantOfMalformedValue` covers it.

## H. Diff hygiene
- `Resources/Localizable.xcstrings` is ~19,573-line bulk diff because Python re-serialized with alphabetical key sort — the prior file was "mostly but not strictly" sorted. Mechanical, not semantic. Should be called out in the PR description so reviewers don't try to read it line-by-line.

## Minor gaps (not blocking)
1. Plan listed `testMaybeLaterNeverWritesToDismissalStore` and `testUpdateAllPathNeverWritesToDismissalStore` — neither test made it in. The behavior IS verifiable by inspection (`markDismissedThisLaunch` only flips a bool; `recordDismissalsForUncheckedRows` with all-selected adds nothing to dict), and `testRecordDismissalsForUncheckedRowsCapturesBundledHash` exercises the underlying contract that backs Update-all. Acceptable; consider adding both as one-line assertions next time the file is touched.
2. `testDescriptionWithMultilineIsTruncatedToFirstLine` from the plan is absent — superseded by amendment #4 (multi-line is out-of-scope, enforced by `BundledSkillsManifestTests`). Correct deferral.
3. In `applySelection` the second `for (target, selected) in selections where selected` binds `selected` but only uses the `where` clause filter — minor unused-binding cosmetic.
4. "Update all" / "Update selected" both pass `force: true`. For `.installedOutdated` rows in the local-edits sub-case, this overwrites local edits with no confirmation beyond the row's warning text. This matches the plan, but worth surfacing in the PR description as a behavioral note for operators upgrading from prior `force: false` semantics.

## Ship it
Code is correct against the plan, amendments landed, tests cover the meaningful behavior, localization is complete, no policy violations, no typing-latency hot paths touched, no new socket commands. APPROVE.