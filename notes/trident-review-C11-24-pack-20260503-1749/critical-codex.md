## Critical Code Review
- **Date:** 2026-05-03T21:58:08Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-24/health-cli
- **Latest Commit:** cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92
- **Linear Story:** C11-24
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

The core scanner design is mostly sane: it is passive, local, socket-free, and it does not parse or upload Sentry envelope contents. The parser tests are behavioral fixture tests, not grep tests, and the launch sentinel producer was left alone.

The weak spot is the diagnostic-warning layer. The new `c11 health` command ships a MetricKit-baseline warning that looks useful in tests but is unlikely to fire in the real CLI path. There is also a privacy footgun in JSON mode: it serializes full local paths for every health event.

I did not run local tests. Project policy says never run tests locally for this repo; the prompt's npm test commands do not apply to this Swift/Xcode project.

## What Will Break

1. When a newly version-bumped c11 has zero MetricKit diagnostics, `c11 health` will usually omit the intended baseline warning. `runHealth` reads the current version from `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` in [CLI/HealthCommand.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/CLI/HealthCommand.swift:37), but the `c11-cli` target build settings do not define a generated Info.plist or marketing version for that command-line target in [GhosttyTabs.xcodeproj/project.pbxproj](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/GhosttyTabs.xcodeproj/project.pbxproj:1498). Even if that is fixed, `mostRecentSentinelMarker` considers `active.json` a candidate in [Sources/HealthCommandCore.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/Sources/HealthCommandCore.swift:502), so the current launch marker can mask the previous-version marker and make [Sources/HealthCommandCore.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/Sources/HealthCommandCore.swift:555) return nil.

2. When an operator runs `c11 health --json` and shares the output, it includes full absolute paths from `ev.path` in [Sources/HealthCommandCore.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/Sources/HealthCommandCore.swift:719). That leaks the macOS username and exact local cache/report layout. The table output avoids paths; JSON should not silently become the privacy-regressing mode.

## What's Missing

- A runtime test that simulates the real post-upgrade sentinel state: an old `unclean-exit-*.json` plus a newer current-version `active.json`, with zero MetricKit diagnostics, should still produce the baseline warning if the product wants a "prior session marker" comparison.
- A CLI-version-source test or seam. The current test injects `bundleVersion` directly, so it never exercises `runHealth`'s real version lookup.
- A JSON privacy contract test. The JSON shape test asserts keys exist but does not assert that paths are redacted, relative, or intentionally present behind an explicit flag.

## The Nits

- `telemetryAmbiguityFooter` probes only `~/Library/Caches/com.stage11.c11/io.sentry` while `scanSentryQueued` scans every `com.stage11.c11*` bundle. That may be intentional for production-only wording, but it means debug or suffixed bundles get different ambiguity behavior than the scanner itself.
- `parseMetricKitFilename` accepts kind token order that the comment says the producer will not emit. Low risk, but the grammar and tests disagree on whether order is fixed.

## Findings

### Blockers

None found.

### Important

1. ✅ Confirmed: MetricKit baseline warning is effectively dead in realistic CLI use.

   The changed CLI code depends on `Bundle.main.infoDictionary` for `CFBundleShortVersionString`, but the command-line target configuration shown around [GhosttyTabs.xcodeproj/project.pbxproj](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/GhosttyTabs.xcodeproj/project.pbxproj:1498) does not provide the app target's Info.plist/version settings to `c11-cli`. The warning guard at [Sources/HealthCommandCore.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/Sources/HealthCommandCore.swift:550) exits on nil or empty current version.

   Execution path: `c11 health` dispatches before socket connection in [CLI/c11.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/CLI/c11.swift:1560), `runHealth` passes `bundleVersion` from the CLI bundle, `metricKitBaselineWarning` exits before comparing markers. If a version is supplied, `mostRecentSentinelMarker` still picks the newest marker including `active.json`, so the current active marker can suppress the old-version archive the warning is meant to compare against.

2. ✅ Confirmed: JSON output leaks absolute local filesystem paths.

   `renderHealthJSON` writes `"path": ev.path` for every event at [Sources/HealthCommandCore.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-health-cli/Sources/HealthCommandCore.swift:725). Those paths include locations under `/Users/<operator>/Library/...`. This is a direct privacy issue for support/debug output. Either redact the home prefix, make paths opt-in, or replace with a stable local-relative location such as `~/Library/...`.

### Potential

1. ⬇️ Real but lower priority: Sentry ambiguity warning checks a narrower bundle path than Sentry scanning.

   `scanSentryQueued` accepts all cache directories with `com.stage11.c11` prefix, but `telemetryAmbiguityFooter` probes only the exact production path. If a suffixed debug/beta bundle has an empty Sentry cache, `c11 health --rail sentry` can report zero queued events with no ambiguity warning. This is only a production incident if suffixed bundle IDs are expected in operator support flows.

## Closing

I would not call this ready to mass deploy unchanged. The scanners themselves are acceptable for v1, but the MetricKit warning needs to be made real in the actual CLI path, and JSON path exposure needs an explicit privacy decision before operators are encouraged to share machine-local diagnostic output.
