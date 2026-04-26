# C11-23: Upstream cmux PR 2827, AI provider usage monitoring (Claude + Codex)

> **Origin reminder:** this ticket tracks an open **PR**, not an issue, in the upstream parent project [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux). The PR is [#2827 by @tranquillum](https://github.com/manaflow-ai/cmux/pull/2827). All `#NNNN` references in this note point at upstream, not c11.

**Sibling tickets:** C11-20, C11-21, C11-22 (open-issue bundles). This one is different in shape since the cherry-pick path goes straight from a community-authored PR rather than from an unfixed issue.

---

## Credits

| Reporter / Author | Contribution |
|-------------------|--------------|
| **@tranquillum** | Sole author of upstream PR #2827. The implementation, tests, docs, and screenshots are all theirs. |

When this lands as a c11 PR, the commit metadata must preserve @tranquillum as the author (`git cherry-pick` does this automatically). Add a trailer referencing the upstream PR:

```
Cherry-picked-from: manaflow-ai/cmux#2827 by @tranquillum
```

If the c11 work substantially modifies the upstream change (rename pass, sidebar integration, locale work), use `Co-Authored-By:` for the c11-side contributor and keep @tranquillum as primary author of the original commits.

---

## What the PR adds

- **Sidebar footer panel** that tracks AI subscription usage per account, with two windows: Session (5-hour rate limit) and Week.
- **Two providers shipped:** Claude (`claude.ai` rate limits) and Codex (ChatGPT/Codex rate limits).
- **Multi-account per provider** (Personal + Work patterns supported).
- **Generic abstraction:** `UsageProvider` and `ProviderRegistry` so new providers slot in without UI changes.
- **Status page integration:** surfaces incidents from `status.claude.com` and `status.openai.com` next to the usage bar.
- **macOS Keychain only** for credentials. Never on disk in plaintext, never logged, only sent to the provider's own API.
- **New settings section:** Settings → AI Usage Monitoring (add, edit, remove accounts; configurable usage-bar color thresholds).
- **Documentation:** `docs/usage-monitoring-setup.md` plus README link, with step-by-step credential acquisition instructions per provider.
- **Tests:** `cmuxTests/ProviderTests.swift` (+609 lines) covering provider registry, credential validators, color threshold settings, ISO8601 parsing.

## Diff scale

```
+15055 -155 across 37 files
```

Note that **10278 of the +15055 lines are in `Resources/Localizable.xcstrings`** (the new English strings the feature introduces). The "real" code diff is closer to +5000 lines. Significant but reviewable.

## Why this fits c11

- **Strategic alignment.** c11's mission per the project CLAUDE.md is "the operator running eight, ten, thirty agents at once." Operators running many agents against Claude/Codex subscriptions hit 5-hour and weekly rate limits constantly and right now have no in-app visibility. This PR addresses exactly that pain.
- **Architecturally sympathetic.** The Provider abstraction is extensible. c11 can add Stage 11 specific providers (or whatever else) without touching the UI.
- **Privacy posture matches c11.** Keychain-only, no plaintext, no logging, calls only the provider's own APIs and (allowlisted) statuspage hosts. Aligns with the recent c11 privacy sweep that cut upstream-domain leaks.
- **Tests come included.** Reduces the verification burden on landing.

## Integration concerns (read before starting)

1. **Mergeable is CONFLICTING upstream as of 2026-04-26.** The PR is two-plus weeks old against an active main branch. Cherry-picking into c11 will likely surface its own conflicts; expect to do real merge work, not a clean apply.
2. **Localization ripple.** The 10K-line `Localizable.xcstrings` change adds many new English strings. Per `code/c11/CLAUDE.md`, c11 ships in 6 non-English locales (ja, uk, ko, zh-Hans, zh-Hant, ru) and the convention is "write English only, then delegate translation to a sub-agent in a new c11 surface." After the cherry-pick, run a translator pass for all six locales (parallelizable, one sub-agent per locale).
3. **CMUX→C11 rename.** Per the operator memory, residual "cmux"/"CMUX"/"cmuxterm" inside the c11 tree is wrong unless it is lineage talk or the deliberate `cmux` CLI compat alias. Several files in this PR will need renaming: `Sources/cmuxApp.swift`, the test file `cmuxTests/ProviderTests.swift`, and any user-facing copy that mentions the upstream brand. **Do the rename at integration time, not at cherry-pick time**, so the cherry-pick math stays clean (per the upstream-pull pattern set by C11-20/21/22).
4. **Sidebar architecture overlap.** c11's sidebar already carries Lattice integration, agent telemetry, and status reporting. The footer-panel approach in this PR may need to coexist with or replace existing footer affordances. Read `Sources/Sidebar/` in c11 first; the upstream `ProviderAccountsFooterPanel.swift` (+723 lines) is the central piece to fit in.
5. **`cmuxApp.swift` (+97 lines).** The PR's hooks into the app entry need to land in c11's equivalent (`Sources/c11App.swift` or whatever the renamed entry is). Background polling (60-second timer) is started on launch and stopped on quit; verify the lifecycle wiring matches c11's app delegate pattern.
6. **Outbound HTTP allowlist.** The PR introduces calls to `claude.ai`, `chatgpt.com` (or wherever the Codex API lives), `status.claude.com`, `status.openai.com`. None of these are in c11's current outbound surface. Confirm the privacy policy is comfortable with these explicit, user-opted endpoints, then list them in any privacy doc that enumerates outbound calls.
7. **Bot-review velocity.** Upstream PR has 137 reviews and 105 comments, mostly from AI bots (cubic, coderabbit, greptile). Author has been responsive on 2026-04-13. If we wait, the upstream PR may land in a cleaner shape; if we cherry-pick now, we own the merge work but ship sooner.

## Recommended cherry-pick path

1. **Fetch the PR locally.**
   ```bash
   cd /Users/atin/Projects/Stage11/code/c11
   git fetch upstream pull/2827/head:cmux-pr/2827-ai-usage-monitoring
   ```
2. **Inspect the diff against c11 main.** Expect conflicts in `GhosttyTabs.xcodeproj/project.pbxproj` (always conflicts on file additions), `Sources/AppDelegate.swift`, `Sources/ContentView.swift`, `Sources/cmuxApp.swift`, and possibly `Sources/Sidebar/`.
3. **Cherry-pick or merge into a c11 feature branch:**
   ```bash
   git checkout -b feat/ai-usage-monitoring origin/main
   git cherry-pick <range-of-PR-commits>
   ```
   Use cherry-pick with `-x` to record the upstream SHA in each commit message. If individual cherry-picks fight, fall back to applying as a squash from the diff.
4. **Resolve the rename pass.** Rename `cmuxApp.swift` references, test file paths, and user-facing copy to c11/C11. Keep Provider abstraction names as-is (no need to rename `ClaudeProvider.swift` etc., they are already provider-named).
5. **Delegate translation.** Spawn one sub-agent per locale (six in parallel) to fill `Localizable.xcstrings` for ja, uk, ko, zh-Hans, zh-Hant, ru. Translator pulls the new English strings, emits each locale, writes back.
6. **Wire into c11 sidebar.** Mount `ProviderAccountsFooterPanel` into the c11 sidebar footer. Resolve any conflicts with existing footer affordances. Verify Lattice integration and agent telemetry are not displaced.
7. **Run the full test suite plus the new provider tests.** `cmuxTests/ProviderTests.swift` becomes `c11Tests/ProviderTests.swift`.
8. **Manual verification.** Add at least one Claude account and one Codex account, confirm Session/Week bars render, the 60-second timer refreshes them, Keychain round-trip works, status-page incidents surface, removing one provider does not affect the other.
9. **Land as a single c11 PR** titled "Add AI provider usage monitoring (cherry-picked from manaflow-ai/cmux#2827 by @tranquillum)" with the credit trailer above.
10. **Surface back upstream if applicable.** If the c11 integration produces fixes to the upstream code (conflict resolutions, bug catches, improvements), open a PR against `manaflow-ai/cmux` per the c11 CLAUDE.md "c11 → upstream (suggest)" guidance, so @tranquillum's PR benefits from c11's review work.

## Post-landing follow-ups

- Add a c11-specific provider for Anthropic API direct usage (separate from claude.ai subscription) if the operator wants to track API-key spend alongside subscription quota.
- Consider adding an OpenAI API direct provider similarly.
- Wire usage signals into the sidebar status entry so a "near limit" workspace can flash, matching the c11 sidebar telemetry pattern.
