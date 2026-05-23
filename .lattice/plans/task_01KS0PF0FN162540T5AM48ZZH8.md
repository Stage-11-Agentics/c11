# C11-111 Plan: state-aware skill install/update UX with "Update all" default

Branch: `c11-111-skill-onboarding`
Worktree: `code/c11-worktrees/c11-111-skill-onboarding/`
Base: `1ff6e07aa8fae3f80c050dc650b9183c7e48d209` (`origin/main` tip 2026-05-22)
Delegator actor: `agent:claude-c11-111-d1`

## What this delivers

A single PR that fixes the v0.49.0 short-circuit (operator updates c11 → never sees revised skills), adds the "Update all" default, and rolls in the two amendments from the 2026-05-22 design comment (per-skill description rendering + celebratory all-current state when the wizard is invoked manually).

All work stays in `Sources/AgentSkillsView.swift` + `Sources/SkillInstaller.swift`, with one tiny addition to the sidebar Help popover in `Sources/ContentView.swift` for "Re-enable agent skills install prompts." Localizable.xcstrings gets a small batch (~10–14) of new keys, fanned out to the six locales at the end via parallel translator sub-agents.

## Behavior matrix (per detected target × bundled skill)

| State                  | Trigger                                                              | Row icon | Default checked? | Row warning            |
| ---------------------- | -------------------------------------------------------------------- | -------- | ---------------- | ---------------------- |
| `.installedCurrent`    | dest hash == bundled hash                                            | ✓        | n/a (no action)  | —                      |
| `.installedOutdated`   | dest hash != bundled hash, manifest's `sourceContentHash` != bundled | ⚠ Update | yes              | "Update available"     |
| `.installedOutdated`   | dest hash != bundled hash, manifest's `sourceContentHash` == bundled | ⚠ Update | yes              | "Local edits will be overwritten" |
| `.installedNoManifest` | dir exists, no `.c11-skill.json`                                     | ⚠ Replace | yes             | "Local edits will be overwritten" |
| `.schemaMismatch`      | manifest's `c11_skill_schema` != current                             | ⚠ Replace | yes             | "Local edits will be overwritten" |
| `.notInstalled`        | dest dir absent                                                      | ◯ Install | yes (detected) | —                      |

The "bundled vs destination drift" sub-case is detected by comparing `record.sourceContentHash` against the bundled `sourceContentHash`: if those match but the destination on-disk hash diverges, the operator hand-edited the local copy.

## Data model: per-(target, skill) dismissed-against-hash store

New UserDefaults shape:

```
"c11SkillDismissals": {
  "claude.c11":         "sha256:<bundled hash at dismissal>",
  "claude.c11-browser": "sha256:<bundled hash>",
  "codex.c11":          "sha256:<bundled hash>",
   ...
}
```

Plus a separate, narrower `"c11SkillDontAskAgain": Bool` global never-show flag (the explicit "Don't ask again" button), kept independent so changing skill content does NOT silently re-prompt once the operator has explicitly opted out.

Legacy `cmuxAgentSkillsOnboardingShown: Bool` stays in code as a migration breadcrumb only — see "Atomic migration" below.

### Helper API in `AgentSkillsOnboarding` (private/static, MainActor)

- `dismissalsKey = "c11SkillDismissals"`
- `dontAskAgainKey = "c11SkillDontAskAgain"`
- `legacyOnboardingShownKey = "cmuxAgentSkillsOnboardingShown"` (renamed local constant; same string value)
- `loadDismissals(_ defaults:) -> [String: String]`
- `saveDismissals(_:, _ defaults:)`
- `key(for target: SkillInstallerTarget, skillName: String) -> String` returning `"<rawValue>.<name>"`
- `recordDismissals(rows:, defaults:)` — write current bundled hashes for every `(target, skill)` pair whose state is `.notInstalled` or `.installedOutdated` (i.e., the rows that were unactioned). Skips `.installedCurrent` (no signal).
- `clearDismissal(for:skill:, defaults:)` — called after successful install of that pair, so the entry doesn't shadow future drift.
- `migrateLegacyDismissalsIfNeeded(home:source:fileManager:defaults:)` — see "Atomic migration."

### `shouldPresent` rewrite

```
1. if dontAskAgain { return false }                       // explicit opt-out
2. if _dismissedThisLaunch { return false }               // in-memory
3. let source = SkillInstaller.defaultSourceURL(...)      // bail false if nil
4. migrateLegacyDismissalsIfNeeded(...)                   // one-shot
5. let dismissals = loadDismissals(defaults)
6. for target in detected targets:
     statuses = try? SkillInstaller.status(target, ...)
     for status in statuses where shouldRowOffer(status):
       let entry = dismissals[key(target, status.package.name)]
       if entry == status.sourceContentHash { continue }    // skipped by dismissal
       return true                                          // at least one row not silenced
   return false
```

`shouldRowOffer(status)` is true for `notInstalled`, `installedOutdated`, `installedNoManifest`, `schemaMismatch`. Stays false for `installedCurrent`.

The existing `shouldOffer(for: [TargetRow])` and `shouldOffer(for: [SkillInstallerPackageStatus])` are kept for tests/callers but each gets a small update to consult dismissals when a `defaults:` is threaded through. The currently-`UserDefaults.standard`-coupled `shouldPresent` keeps its main-actor isolation, since it reads the legacy + new defaults atomically.

## Sheet UX changes (`AgentSkillsOnboardingSheet`)

### Primary action: "Update all"

- Title becomes `"Update all"` when any row needs install/update, kept disabled if zero rows would be acted on.
- Click → for every row in `detectedRows.flatMap(\.packages).filter(shouldRowOffer)`, call `model.install(target:force:true)` (force=true so `.installedNoManifest` and `.schemaMismatch` pass the safety gate). After every install, that `(target, skill)`'s dismissal entry is cleared.
- Once installs run, sheet closes via existing `onDismiss`.

Existing per-target checkbox UX is repurposed as the "Update selected" path: if the operator toggles individual checkboxes, the primary button label shifts to `"Update selected"`. This is a small relabel, not a parallel control surface.

### Per-row content (amendment #1)

Each row now renders:

1. Target name (existing)
2. Version chip (existing)
3. **New**: per-skill description line, pulled from SKILL.md YAML `description:` (or `defaultDescription:` per-skill if absent — fallback to empty so we never block on missing metadata)
4. State sub-label (`Will update`, `Will install`, `Already current`, `Local edits will be overwritten`)
5. **New**: per-skill "Reveal in Finder" affordance

Implementation gates:

- `SkillInstaller.readSkillDescription(from:fileManager:)`: parses YAML frontmatter, symmetric with the existing `readSkillVersion(...)`. Same error model (returns nil if not present). Strip surrounding quotes; trim whitespace.
- `SkillInstallerPackage` gains `description: String?` (Equatable still derived).
- `SkillInstallerPackageStatus` carries it implicitly via `package.description`.
- `AgentSkillsModel.TargetRow` doesn't need a new property — descriptions are per-package, read from `row.packages[i].package.description`.

Because the sheet currently lists targets-as-rows (not skills-as-rows), we either:

(A) Keep targets-as-rows and expand each row to a stacked skill list inside the row (preferred — minimal layout churn, matches the per-`(target, skill)` dismissal grain).

(B) Switch to skills-as-rows (bigger refactor, defers other things).

Plan goes with (A). Each target row gets an inner `VStack` of skill mini-rows: name (gold chip if version available), description (caption, 1–2 lines truncated), state pill, Reveal button. Existing per-target checkbox stays at the target level (one tick toggles all the target's skills together). Per-skill granularity for the dismissal store is invisible UX-side until the operator clicks "Update selected" with mixed states.

### Celebratory all-current state (amendment #2)

When `detectedRows` exists, `hasActionNeeded == false`, and the sheet was opened from Settings ("Run Onboarding Wizard…") OR no rows are dismissed-against-hash silenced:

- Title: `"Your agent is current with c11."`
- Body: short confirmation + skill list (same per-row content as above).
- Primary action: `"Done"`, kind `.success`, always enabled. Closes the sheet.
- Hide `"Don't ask again"` and `"Later"` (nothing being asked).
- Optional small `"Refresh all"` text button below the skill list that force-rewrites every skill (force=true). This addresses the "I think I touched a file but the hashes match because I undid it" recovery path. Implementation reuses the Update-all code path with a force toggle.

We don't add a new boolean for "wizard opened from Settings" — the celebratory branch fires whenever `hasActionNeeded == false`, regardless of trigger. The on-launch auto-trigger never fires in that case (filtered earlier by `shouldPresent`), so the only way to reach the celebratory branch is via Settings/Help, which is the intended entry point.

## Help menu: "Re-enable agent skills install prompts"

Adds a new `SidebarHelpMenuAction.reEnableSkillPrompts` case in `Sources/ContentView.swift`, surfaced in the help popover with the localized title `"Re-enable agent skills install prompts"`. Handler clears the `dontAskAgain` flag AND the `c11SkillDismissals` dict, then calls `AppDelegate.shared?.presentAgentSkillsOnboardingIfNeeded()`. The button is gated to be visible only when `dontAskAgain == true` OR `c11SkillDismissals` is non-empty — no UI clutter for operators who never opted out.

(Visibility gate evaluated at render time. The popover already conditionally hides Docs/Changelog/GitHub when URLs are nil, so the precedent is in place.)

## Atomic migration of the legacy `cmuxAgentSkillsOnboardingShown` flag

When `c11SkillDismissals` is absent on first launch of this version AND `cmuxAgentSkillsOnboardingShown == true`:

- Compute the current bundled hashes for every (target, skill) pair the user has detected.
- Pre-populate `c11SkillDismissals` with those hashes for the (target, skill) pairs that are presently `.installedCurrent` (silences ONLY what's truly already in sync — outdated/uninstalled rows still need to surface, which is exactly the bug we're fixing).
- Do NOT set `dontAskAgain` from the legacy flag — the legacy flag was set on first install too, not just explicit opt-out, so it would over-suppress.

This is roughly 25 lines in `migrateLegacyDismissalsIfNeeded` and dovetails with the existing test seam (`status(for:home:sourceDir:fileManager:)` already accepts a custom `FileManager`).

## Test strategy

All tests go into `c11Tests/SocketControlPasswordStoreTests.swift` (existing pattern — file is in `c11Tests/` on disk but its target membership is `c11LogicTests` per the C11-27 logic-split convention). Fast loop is `xcodebuild -scheme c11-logic test`.

Per the c11/CLAUDE.md *Test quality policy*: tests verify runtime behavior, not source-text patterns. No grep tests, no plist-membership assertions.

### New test classes

1. `SkillInstallerDescriptionParsingTests`
   - `testDiscoverPackagesReadsFrontmatterDescription` — write a temp SKILL.md with `description: "foo"`, assert `package.description == "foo"`.
   - `testMissingDescriptionYieldsNil`.
   - `testDescriptionWithQuotesIsUnquoted`.
   - `testDescriptionWithMultilineIsTruncatedToFirstLine` (per current YAML semantics — we only read the same line as the key).

2. `AgentSkillsDismissalStoreTests`
   - `testRecordDismissalsCapturesBundledHashForOfferedRows` — three rows, two offered, one current; only the two offered are recorded.
   - `testRecordDismissalsClobbersStaleEntriesForSameKey`.
   - `testClearDismissalRemovesOnlyTargetSkillEntry`.
   - `testLoadDismissalsTolerantOfMissingKey` (returns empty dict).
   - `testLoadDismissalsTolerantOfMalformedValue` (returns empty dict, no crash).

3. `AgentSkillsShouldPresentTests`
   - `testDontAskAgainBeatsDriftedContent` — set `dontAskAgain`, drift the bundled hash → returns false.
   - `testDismissedEntryMatchingBundledHashSuppressesPresent` — drift + dismissed against same hash → false.
   - `testDismissedEntryAgainstOldHashAllowsPresent` — drift + dismissed against older hash → true (this is the v0.49.0 bug fix).
   - `testInMemoryDismissedThisLaunchSuppressesPresent`.
   - `testNoDetectedTargetsReturnsFalse`.
   - `testAllCurrentAcrossAllTargetsReturnsFalse`.
   - `testMissingPackageOnDetectedTargetReturnsTrue` — basic notInstalled path still works.

4. `AgentSkillsLegacyMigrationTests`
   - `testLegacyFlagSetAndNoDismissalsPopulatesCurrentOnly` — legacy=true, two installed-current and one outdated; dismissals end up with only the two current pairs, outdated still surfaces.
   - `testLegacyFlagUnsetIsNoOp`.
   - `testMigrationRunsOnceEvenAcrossRepeatedCalls` — second call finds dismissals dict present and skips.

5. `AgentSkillsRowStateClassificationTests` (new, light)
   - `testBundledDriftIsClassifiedAsLocalEditsWillBeOverwrittenWhenManifestMatchesBundled` — uses a stub `SkillInstallerPackageStatus` and tests a pure helper `AgentSkillsRowVariant(for: status, bundledHash:) -> .upToDate/.update/.localEditsWillBeOverwritten/.notInstalled` so the row label decision is testable without SwiftUI.

All cases use temp dirs (`FileManager.default.temporaryDirectory`) for filesystem-touching tests, scoped with `UUID()` and torn down in `defer`. UserDefaults tests use `UserDefaults(suiteName:)` — never `.standard` — to keep tests hermetic. The existing tests in this file already follow these conventions.

### What we explicitly do NOT test

- The SwiftUI view body itself (`AgentSkillsOnboardingSheet`). Per the c11 test policy, layouts are verified via the runtime end-to-end, not by reading SwiftUI source.
- Help menu visibility — the gate is a simple condition; a runtime test buys nothing beyond confirming the flag plumbing. The flag plumbing IS tested above.
- `xcodebuild test` against `c11-unit` locally is **NOT** in this plan. Per c11/CLAUDE.md and a known operator memory, that crashes the operator's running c11. Use `scripts/test-unit-local.sh` only if a host-bound test slips in (it shouldn't here), and rely on CI for the full `c11Tests` suite.

## Localization plan

New keys (all in `Resources/Localizable.xcstrings`, English defaults authored in code via `String(localized:defaultValue:)`):

- `agentSkills.onboarding.updateAll` — "Update all"
- `agentSkills.onboarding.updateSelected` — "Update selected"
- `agentSkills.onboarding.refreshAll` — "Refresh all"
- `agentSkills.onboarding.done` — "Done"
- `agentSkills.onboarding.title.celebratory` — "Your agent is current with c11."
- `agentSkills.onboarding.body.celebratory` — "Every detected agent has the latest c11 skill set."
- `agentSkills.onboarding.row.localEditsWarning` — "Local edits will be overwritten"
- `agentSkills.onboarding.row.willReplace` — "Will replace existing files"
- `agentSkills.onboarding.row.revealInFinder` — "Reveal in Finder"
- `agentSkills.help.reEnablePrompts` — "Re-enable agent skills install prompts"

Implementation order: author English strings in code with `defaultValue:` populated; `Localizable.xcstrings` picks them up the next time the app builds. At the **end** of implementation (before pushing the PR), fan out one translator sub-agent per locale (ja, uk, ko, zh-Hans, zh-Hant, ru) in fresh c11 surfaces, each translating only the new keys for its assigned locale. Six panes in parallel per `c11/CLAUDE.md`'s *Localization* section.

## Out of scope (reaffirmed)

- Auto-install without confirmation. Every install path remains explicit.
- Per-file diff UI. Package-level update is the unit.
- `c11 skills status` CLI subcommand. The ticket calls this "Maybe"; deferring keeps the diff focused on the UX bug fix and the two amendments. If we ship without it, the existing `c11 doctor` already surfaces target detection. A follow-up ticket can add the subcommand once this ships.

## Implementation order (suggested commits)

1. `SkillInstaller`: add `readSkillDescription`, `description: String?` on `SkillInstallerPackage`, threaded through `discoverPackages`. Update `SkillInstallerPackageVersionTests` for description parsing. Logic-only, ~50 lines.
2. `AgentSkillsOnboarding`: dismissal store + new `shouldPresent`. Legacy migration. New test classes 2, 3, 4. ~120 lines source + ~180 lines tests.
3. `AgentSkillsOnboardingSheet`: per-row description rendering + Reveal in Finder per row. ~80 lines view code.
4. `AgentSkillsOnboardingSheet`: "Update all" primary action + warning labels + celebratory all-current state. ~90 lines.
5. `ContentView` Help popover: re-enable action + visibility gate. ~25 lines.
6. `AppDelegate`: only touch is `presentAgentSkillsOnboardingIfNeeded` — confirm it still works with the new `shouldPresent` (it should, the contract is unchanged).
7. New `AgentSkillsRowStateClassificationTests` for the pure row-state helper.
8. Localizable.xcstrings: English keys populate automatically via `String(localized:defaultValue:)`; manual additions if any.
9. **Translator sub-agent fan-out** (six locales in parallel).
10. Final build + `c11-logic` test pass.

## Risk and rollback

- The dismissal store is read-only on first launch (until the operator dismisses something), so a defect that misreads it is recoverable by clearing one UserDefaults key.
- The legacy migration only writes once and is gated on `c11SkillDismissals` being absent; if it goes wrong, the operator's worst case is "re-prompt for every skill once," which is exactly the un-migrated v0.49.0 update path that this ticket already promises.
- The View changes are layout-additive (new rows below existing chips). No risk to the TabItemView / TerminalSurface / WindowTerminalHostView typing-latency hot paths — AgentSkillsView is a modal sheet, not part of a terminal pane.
- Socket policy is not touched (no new socket commands).

## Done definition

- `lattice show C11-111` says `pr_open`.
- One PR open against `Stage-11-Agentics/c11`, title under 70 chars, summary + test plan + Co-Authored-By footer.
- Plan-review verdict attached as a Lattice note.
- Code-review verdict attached as a Lattice note.
- Localization fan-out complete; xcstrings has the new keys filled in for all six locales.
- All sub-agent surfaces closed (`c11 close-surface`).
- Final summary comment on Lattice.
