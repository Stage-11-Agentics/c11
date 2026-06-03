## Code Review
- **Date:** 2026-05-03T17:49:00Z
- **Model:** Gemini 1.5 Pro
- **Branch:** c11-24/health-cli
- **Latest Commit:** cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92
- **Linear Story:** C11-24
---

Overall, the `c11 health` implementation is excellently scoped. The architectural choice to isolate `HealthCommandCore` to be completely pure, testable, and separate from UI and network dependencies fulfills the read-only, passive requirements beautifully. The testing strategy successfully avoids grepping source code and establishes a robust sandboxed E2E baseline.

### Architectural

The decision to split the command into a thin CLI shim (`HealthCommand.swift`) and a pure core (`HealthCommandCore.swift`) as a dual-target file is pragmatically correct. It successfully enables full test coverage within `c11Tests` while maintaining the needed boundary for the CLI execution context. There are no architectural concerns to flag; the pattern is sound and future-proof.

### Tactical

**Blockers**
None. The code adheres strictly to the privacy and passivity requirements detailed in `CLAUDE.md`. Tests run correctly within the constraints.

**Important**
1. ✅ **Confirmed:** In `CLI/HealthCommand.swift` (line 37), `Bundle.main.infoDictionary` is read directly to determine the app version for the `metricKitBaselineWarning`. If the CLI is invoked via a symlink outside the app bundle (e.g., from `/usr/local/bin/c11`), this will be `nil`, causing the warning to silently fail. Upstream cmux has `CLISocketSentryTelemetry.currentBundleVersionValue(forKey:)` in `c11.swift` to resolve the actual app bundle; adopting a similar strategy here will ensure the warning fires consistently.
2. ✅ **Confirmed:** In `Sources/HealthCommandCore.swift` (line 560), `telemetryAmbiguityFooter` hardcodes the production bundle path `"\(home)/Library/Caches/com.stage11.c11/io.sentry"`. While the text specifies "Production Sentry cache", this will skip the ambiguity footer for `.debug` or `.staging` builds. Using the same prefix-matching logic (`hasPrefix("com.stage11.c11")`) as `scanSentryQueued` would make this warning resilient across build variants.

**Potential**
1. ⬇️ **Lower priority:** In `mostRecentSentinelMarker(home:)`, the loop parses the JSON payload for *every* `unclean-exit-*.json` file to extract the version and timestamp. While fast enough for a small number of crashes, as the cache grows, this could become unnecessarily expensive. A potential optimization is to sort the directory contents by filename or `modificationDate` first, and only decode the most recent JSON file to extract the version.