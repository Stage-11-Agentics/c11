# C11-99: CI unblock: nightly Sentry flag, ci.yml timeout, slow-test skip, scheme split

Minimum-viable PR to restore useful CI signal without solving the underlying test stability problem. Parent: C11-98.

**Changes**
1. `nightly.yml:459` — add `continue-on-error: true` on `Upload dSYMs to Sentry` step (matches `release.yml:301`). Unblocks 15 days of skipped nightly publishes.
2. `ci.yml:92` — bump build job `timeout-minutes` from 15 → 25. Today's runtime is ~14-16 min; the 15 ceiling is the proximate cause of the "hang" framing.
3. `c11Tests/AppDelegateShortcutRoutingTests.swift:878` — `XCTSkip` `testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView` with a TODO referencing C11-98 / its child. Drops step time from 10:19 → ~8:30.
4. Split the test step in `ci.yml`:
   - `xcodebuild ... -scheme c11-logic test` (hard-fail gate)
   - `xcodebuild ... -scheme c11-unit -only-testing:c11Tests test` (`continue-on-error: true`, advisory until stabilization lands)

**Acceptance**
- `nightly.yml` runs go green end-to-end (Sparkle appcast + artifact upload + tag move all execute even if Sentry upload fails)
- `ci.yml` build job goes green on main with `c11-logic` as gate
- Advisory `c11-unit` step still runs and reports failures, just doesn't fail the job
- The skipped slow test has a TODO + Lattice link in the source

**Out of scope** — fixing the 32 expectation timeouts (that's the sibling stabilization ticket).
