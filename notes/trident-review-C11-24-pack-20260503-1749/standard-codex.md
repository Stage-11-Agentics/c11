## Code Review
- **Date:** 2026-05-03T21:58:41Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-24/health-cli
- **Latest Commit:** cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92
- **Linear Story:** C11-24
---

General assessment: the branch is well scoped for the `c11 health` MVP. The four evidence rails are implemented as passive filesystem scanners, the CLI dispatch is placed after subcommand help so `c11 health --help` should work, and the tests exercise parser behavior and a sandboxed all-rails collection path rather than source-text checks. I did not run local tests per project policy, and I did not fetch/pull because this review was explicitly read-only and pulling could mutate the worktree.

The main concern is in one of the two required diagnostic warnings. The MetricKit baseline warning exists and is unit-tested in isolation, but the real CLI path has two runtime-state mismatches that can prevent it from firing when the operator needs it.

### Blockers

1. ✅ Confirmed: MetricKit baseline warning can be suppressed by the current session marker and by CLI bundle-version lookup.
   - Files: `Sources/HealthCommandCore.swift:502`, `Sources/HealthCommandCore.swift:531`, `Sources/HealthCommandCore.swift:550`, `CLI/HealthCommand.swift:37`, `GhosttyTabs.xcodeproj/project.pbxproj:1498`
   - `mostRecentSentinelMarker` treats both `unclean-exit-*.json` and `active.json` as comparable markers, then picks the newest timestamp. In the real producer, `active.json` is the current app launch marker, not a prior-session marker. When c11 is running after a version bump, the current `active.json` is newer than any archived prior marker and usually has the same version as the CLI/app, so `metricKitBaselineWarning` exits at `marker.version != curr` and hides the baseline warning.
   - The CLI also derives `bundleVersion` from `Bundle.main.infoDictionary` in `CLI/HealthCommand.swift:37`. The CLI target config shown at `GhosttyTabs.xcodeproj/project.pbxproj:1498-1534` does not define an Info.plist, `MARKETING_VERSION`, or `CURRENT_PROJECT_VERSION` for the command-line binary. Existing CLI Sentry code already has a custom app-bundle discovery helper for this reason. If `Bundle.main` is the standalone CLI bundle, `bundleVersion` is nil and the warning never evaluates.
   - This is branch-introduced and affects the C11-24 contract because the MVP explicitly includes the MetricKit baseline diagnostic warning. The fix should compare against a prior marker, not the current active marker, and resolve the version from the containing app bundle or another established CLI version source.

### Important

None found.

### Potential

2. ✅ Confirmed: Sentry ambiguity warning only checks the exact production cache path.
   - File: `Sources/HealthCommandCore.swift:565`
   - The Sentry scanner covers every `com.stage11.c11*` cache directory, including tagged debug and legacy `c11mux` bundles, but `telemetryAmbiguityFooter` only probes `~/Library/Caches/com.stage11.c11/io.sentry`. That matches the current warning copy ("Production Sentry cache empty") and the plan's live-machine baseline, so I am not treating this as a defect. If the operator expects `c11 health` from tagged debug builds to warn on empty debug Sentry caches too, this helper should use the same bundle-directory iteration as `scanSentryQueued`.

### Validation Notes

Reviewed branch diff against `origin/crash-visibility/launch-sentinel` as requested. Verified the changed files are limited to the new health CLI/core, dispatch/help wiring, project target wiring, fixtures, and health tests. I did not run `npm`, XCTest, or local build/test commands; the project instructions say tests run in CI, and the handoff explicitly described this as a read-only review.
