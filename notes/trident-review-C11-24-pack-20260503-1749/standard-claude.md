## Code Review

- **Date:** 2026-05-03T17:49:00Z
- **Model:** Claude (claude-opus-4-7[1m])
- **Branch:** c11-24/health-cli
- **Latest Commit:** cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92
- **Base:** origin/crash-visibility/launch-sentinel @ 5402d3fcd69c3ecb54ff440664fad51abf59f0e7
- **Linear Story:** C11-24
- **Lens:** Standard (code quality, correctness, design, tests, style)

---

## What this branch does

Adds a new read-only CLI subcommand `c11 health` that summarises crash and reliability evidence on the local machine across four independent rails:

1. **IPS** — Apple `.ips` reports under `~/Library/Logs/DiagnosticReports`, scoped to entries owned by the c11 family of bundle IDs.
2. **Sentry queued** — file count under `~/Library/Caches/com.stage11.c11*/io.sentry/` (no envelope parsing; just "something is queued").
3. **MetricKit** — JSON files under `~/Library/Logs/c11/metrickit` whose filename grammar is `<filename-safe-ISO>-<kind>.json` (where `<kind>` is `metric` / `diagnostic` / one or more of `crash<n>`, `hang<n>`, `cpu<n>`, `disk<n>`). `metric` rows are skipped (telemetry baselines, not diagnostics).
4. **Sentinel** — `unclean-exit-*.json` archives written by `LaunchSentinel.recordLaunchAndArchivePrevious()` from PR #109, which catches Force-Quit / SIGKILL where Sentry and `.ips` cannot.

The design is clean: a single core (`Sources/HealthCommandCore.swift`) with no UI, socket, or `SentrySDK` calls, plus a thin shim (`CLI/HealthCommand.swift`) for argument plumbing. Output supports both a fixed-width table and a structured JSON form (`renderHealthJSON`). Two diagnostic warnings (MetricKit baseline still establishing after a recent version bump; Sentry cache empty/ambiguous) are appended as footer lines.

The work also adds two compile-time configurations of the same source file: it lives in both the main `c11` target and the `CLI` build, exposed under `@testable import c11_DEV` / `@testable import c11`.

### Logic trace (default invocation)

```
c11 health
  -> CLI/c11.swift dispatch:
     `--json` global flag is stripped to `jsonOutput`,
     `commandArgs = []`,
     command == "health" routes to runHealth().
  -> runHealth() (CLI/HealthCommand.swift)
     parseHealthCLIArgs([]) -> mode=.defaultLast24h, rail=nil, json=false
     since = now - 24h
     home  = NSHomeDirectory()
     events = collectHealthEvents(window, allRails, home)
       -> scanIPS / scanSentryQueued / scanMetricKit / scanLaunchSentinel
       -> sorted by timestamp descending
     warnings = [metricKitBaselineWarning?, telemetryAmbiguityFooter?]
     renderHealthTable(events, warnings) -> stdout
```

### Architectural shape

- The split between core (pure, testable) and shim (I/O, dispatch) is the right structure for a non-trivial CLI surface and matches the project's existing patterns. The dual-target Swift file is unusual but justified by the constraint that the standalone `c11` CLI binary is a separate Mach-O target from the app, and the shared logic is genuinely useful in both.
- The contract with the upstream sentinel producer is correct: the consumer treats the **filename** as the source of truth for the timestamp and the body as best-effort metadata. This is the right side of the bargain to be on, since the producer always writes a filename-safe ISO stamp and the body might be partially written or fail to parse.
- Privacy-by-default and read-only-by-default are honoured: the CLI never calls `SentrySDK.capture*`, never posts notifications, never touches the c11 socket, and never reaches into tenant config. It strictly reads files c11 itself produced, plus Apple's own crash reports.

Overall the work is solid. The headline issues below are mostly tactical, with one architectural concern around the `metricKitBaselineWarning` data source.

---

## General feedback

**Strengths**

- The four-rail core is clearly factored. Each `scan*` function is independently testable, gracefully handles missing directories, and respects the `since` window.
- `HealthCLIError` is a `CustomStringConvertible` enum with meaningful messages — much better than throwing generic strings.
- Tests are runtime-behavioural: tmp-home scaffolds + real file I/O + assertions on returned `HealthEvent` arrays. Zero `grep-the-source` smell. The CLAUDE.md test policy is well respected.
- Golden snapshots use a `timeZone:` injection seam rather than mocking `Date()`, which is a clean way to make wall-clock-sensitive output deterministic.
- The "list of footers" approach (`warnings: [String]`) is straightforward and renders identically in table and JSON output.

**Weaknesses**

- Several places duplicate the same `ISO8601DateFormatter()` configuration (5 instances). Minor but worth a small helper.
- The `metricKitBaselineWarning` reads `active.json` and `unclean-exit-*.json` written by `LaunchSentinel`, but only treats `version` (not `build`) as the change signal. A build-only bump (e.g. nightly with same `0.44.1` MarketingVersion) won't trigger the warning even though MetricKit's baseline does reset on each Mach-O bundle change. This is a Potential, not a Blocker — see #6.
- A few rendering-correctness edge cases around overlong content (#3, #4 below) that golden tests miss because the fixture data is short.
- Help-text content has a small fidelity issue with the `--rail` filter description (#5).

---

## Numbered findings

> Severity legend: **Blocker** must fix before merge; **Important** should fix, not blocking; **Potential** nice-to-have or uncertain.

### Blockers

_None._ The code is correct on the happy paths, the tests exercise real behaviour, and nothing here looks like it would fail review on a serious project.

### Important

**1. ✅ `--rail` accepts only one value; multiple `--rail` flags silently overwrite the previous one. (Sources/HealthCommandCore.swift:574, CLI/c11.swift:7735)**

`HealthCLIOptions.railFilter` is `HealthEvent.Rail?` (a single optional), and `parseHealthCLIArgs` overwrites `rail` on every `--rail` occurrence. Help text (`Filter to one rail: ips, sentry, metrickit, sentinel`) implicitly suggests one rail at a time, but the natural operator instinct given four rails is `c11 health --rail ips --rail sentinel`. Today that silently keeps only the last one with no error.

Two acceptable fixes:
- Tighten: throw `HealthCLIError.unknownFlag` (or a new `.duplicateFlag`) on a second `--rail` so the operator gets an error rather than silent loss.
- Loosen: change `railFilter` to `Set<HealthEvent.Rail>?` and accumulate. Help text and `runHealth` both compose cleanly with this since the call-site already does `Set<HealthEvent.Rail> = opts.railFilter.map { [$0] } ?? allRails`.

Tightening is the smaller change and keeps the v1 contract honest. Recommend tighten now, loosen later if real usage demands it.

**2. ✅ `bootTime()` falls back to "24h ago" on `sysctlbyname` failure, but `--since-boot` then becomes a synonym for the default 24h window. (Sources/HealthCommandCore.swift:402)**

```swift
func bootTime() -> Date {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    let result = sysctlbyname("kern.boottime", &tv, &size, nil, 0)
    if result == 0 { ... }
    return Date(timeIntervalSinceNow: -24 * 3600)
}
```

The doc comment says "Falls back to 24h ago on failure so callers do not have to handle nil for a value the kernel always exposes on macOS" — the practical realism here is fine, but on a machine where `sysctlbyname` actually does fail, the operator who explicitly asked for "since boot" silently gets a 24h window with no warning. Recommend either:

- Print a single-line warning to stderr in this fallback path (e.g. `c11 health: kern.boottime unavailable, falling back to 24h window`), so the operator can tell their explicit ask was downgraded; or
- Throw a `HealthCLIError` from this code path and let `runHealth` surface it. (Less attractive — it makes the "harmless degradation" case feel like an error.)

The first is cheaper and matches the read-only ethos.

**3. ⬇️ Lower priority: `renderHealthTable` does not truncate long `summary` values, which will visually break the fixed-width table on long bundle/envelope names. (Sources/HealthCommandCore.swift:644-672)**

The table format uses `padding(toLength:withPad:startingAt:)` for the rail and severity columns, but the summary is unbounded and gets concatenated as-is. A long sentry envelope name like `com.stage11.c11.debug.runtime/legacy-envelope-with-a-really-really-long-suffix` will produce a wrapping line on standard 100-col terminals and visually break alignment of subsequent rows. The IPS path also can produce summaries that include UUID-like incident IDs.

Recommend truncating `summary` to ~80 chars with a `…` ellipsis (or to terminal width minus the prefix length) for the table form. JSON output should keep full strings.

Marking this as ⬇️ because it doesn't break correctness; it's a polish issue and the v1 demo paths produce short summaries. Worth a follow-up.

**4. ⬇️ Lower priority: `renderHealthTable` always emits a trailing newline even when both events and warnings are empty. (Sources/HealthCommandCore.swift:670-672)**

```swift
return lines.joined(separator: "\n") + "\n"
```

That is fine, but the `runHealth` shim also calls `print(...)` with `terminator: ""`, which combined with the always-appended `\n` is correct. The only nit: the empty-results path becomes a single-line message followed by a newline. The "four-events" golden expects a trailing newline too. It is consistent, just worth a comment that the rendered string is **already terminated** so callers can use `terminator: ""`. A one-line comment above `return` would prevent future "let's just print it normally" regressions.

Not blocking. ⬇️ for follow-up.

**5. ✅ `--rail <name>` help text omits the "all rails by default" note. (CLI/c11.swift:7741)**

```
--rail <name>          Filter to one rail: ips, sentry, metrickit, sentinel.
```

A reader of `--help` cannot tell from this whether omitting `--rail` defaults to all rails or to a specific rail. It does default to all four (correctly), so add "Default: all rails." or "Omit to query all four rails."

Trivial wording fix.

### Potential

**6. ❓ `metricKitBaselineWarning` reads `version` only, ignoring `build`. (Sources/HealthCommandCore.swift:558)**

```swift
guard marker.version != curr else { return nil }
```

`LaunchSentinel.recordLaunchAndArchivePrevious()` records both `CFBundleShortVersionString` (version) and `CFBundleVersion` (build) in the JSON body. The current consumer compares only `version` against `bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"]`. In practice MetricKit's baseline reset is keyed on the bundle's signed Mach-O (so build bumps with the same MarketingVersion can also reset the baseline). For nightly builds where the version stays at e.g. `0.44.1` but the build increments per-build, an operator could see "0 MetricKit events" after a fresh build and not get the warning even though the explanation is exactly the same.

This is a behaviour question, not a defect. Two reasonable answers:
- v1 scope is "version bump = warn"; build-only bumps are out of scope. State this in a code comment so a future maintainer doesn't mistakenly think it's a bug.
- v1 should also detect `build` mismatches. Then change the consumer to read both fields and trigger if either differs.

Flagging for operator/PM judgement, not a blocker.

**7. ❓ `metricKitBaselineWarning` will misbehave if the most-recent marker on disk has a clock skew (system clock turned back). (Sources/HealthCommandCore.swift:567)**

```swift
let age = now.timeIntervalSince(marker.timestamp)
guard age >= 0, age <= 24 * 3600 else { return nil }
```

The `age >= 0` guard silently suppresses the warning if `marker.timestamp` is in the future relative to `now`. That is a defensive choice and probably the right one (don't show a warning we can't justify), but it does mean an operator who ran with a future-dated clock and bumped the version will lose this signal forever for that marker. Probably fine — clock skew is exotic — but worth a code comment.

**8. ✅ `mostRecentSentinelMarker` reads every `unclean-exit-*.json` and `active.json` under every c11 bundle, doing one JSON parse per file. (Sources/HealthCommandCore.swift:486)**

This is O(n) where n is the count of marker files across all bundle dirs (debug, debug.runtime, prod, …). For a typical operator that's small (single digits), but if `unclean-exit-*.json` accumulate (no GC mentioned in the producer), this could grow to hundreds and noticeably slow `c11 health` to compute the warning. Two cheap mitigations:

- Sort by filename (the filename's ISO stamp is a total ordering) and read only the newest one; fall back to body parsing only if that file's `version` field is missing.
- Limit to the N most recent (e.g. last 10) per bundle directory.

The current code's `best == nil || best!.timestamp < timestamp` does pick the right answer, just with O(n) reads. Probably fine for v1; revisit when sentinel housekeeping ships.

**9. ✅ Five duplicate `ISO8601DateFormatter` configurations. (Sources/HealthCommandCore.swift:288, 291, 502, 515, 711, 712)**

Same five-line dance is repeated. Extract a small helper:

```swift
private func isoFormatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}
```

Cosmetic, but reduces drift risk. Note that `LaunchSentinel` already has an identical private `isoFormatter()` helper in `Sources/SentryHelper.swift` — could even hoist this to a shared `Sources/IsoTime.swift` or similar, since both files use the same format. That said, sharing across files has its own cost; one-file extraction is the safer move.

**10. ✅ `parseFilenameSafeISO` accepts but doesn't validate fractional-seconds format strictness. (Sources/HealthCommandCore.swift:275-291)**

```swift
guard stamp.count == 24, stamp.last == "Z" else { return nil }
var chars = Array(stamp)
guard chars[10] == "T",
      chars[13] == "-",
      chars[16] == "-",
      chars[19] == "."
else { return nil }
```

The structural checks are correct for the `YYYY-MM-DDTHH-MM-SS.fffZ` shape. However, this accepts non-numeric characters in the digit positions (e.g. `20XX-05-03T15-19-00.123Z` will be replaced to `20XX-05-03T15:19:00.123Z` and then tossed to `ISO8601DateFormatter`, which will reject it; so the failure surfaces, just one layer late). That's defensible because `ISO8601DateFormatter` is the source of truth for date validity. Worth a one-line comment that says exactly this so a maintainer doesn't add redundant validation.

**11. ✅ `scanSentryQueued` walks `io.sentry/` recursively and emits one event per regular file, including any non-envelope side files Sentry-Cocoa might write. (Sources/HealthCommandCore.swift:411-428)**

The doc comment acknowledges this: "any regular file inside `io.sentry/` is treated as a queued event." That is conservative and matches v1 scope (file count, not envelope semantics). The risk is over-counting if Sentry-Cocoa writes `installation.id` or similar metadata files inside `io.sentry/`. In a sample install I'd expect one or two such files at most, so the ambiguity is small.

Recommend adding to the doc comment: "Sentry-Cocoa may write small bookkeeping files (e.g. `installation.id`) under `io.sentry/`; v1 over-counts these by ≤2 per bundle. Acceptable for the count-only signal." Then `telemetryAmbiguityFooter`'s "0 events" check will still be the more meaningful one in practice.

**12. ✅ `parseUncleanExitFile` defaults to `commit = "????????"` when missing. (Sources/HealthCommandCore.swift:643)**

The string `"????????"` is rendered into the table summary, which is accurate when the marker JSON lacks a commit field. However, on a machine where every marker lacks the field (e.g. local dev builds without `C11Commit` set in Info.plist), every sentinel row will end with `????????` which reads as eight visually-identical question marks. Suggest using `"unknown"` or similar so the rendered output is more legible, and so operators can search for "unknown" rather than a glob-active sequence of `?`. Cosmetic; not blocking.

**13. ❓ `HealthEvent.Severity` is a flat enum with values `crash`, `queued`, `metrickit`, `hang`, `resource`, `mixed`, `diagnostic`, `unclean_exit`. The `.metrickit` case is defined but never produced. (Sources/HealthCommandCore.swift:18-25)**

`metricKitSeverity` returns one of `.crash`, `.hang`, `.resource`, `.mixed`, `.diagnostic`. The `.metrickit` raw case is dead. Either remove it (preferred — it confuses future maintainers about what valid severity values are) or document why it's reserved for a future case. Cosmetic.

**14. ✅ `HealthEvent.Severity.unclean_exit` uses a snake_case raw value, while every other severity uses lowercase single-word values. (Sources/HealthCommandCore.swift:24)**

This is also the value emitted in JSON (`"severity": "unclean_exit"`) and in the table summary. Mixing snake_case with lowercase tokens in the same enum's raw values is inconsistent for downstream JSON consumers. Two equally good options:
- Rename to `.uncleanExit` and rawValue `"unclean-exit"` (kebab-case to mirror the filename convention).
- Or keep `unclean_exit` but document the inconsistency once in a comment.

Not blocking; downstream consumers are presumably c11-internal for v1.

**15. ❓ `parseHealthCLIArgs` accepts `--help`/`-h` mid-args but does nothing with them. (Sources/HealthCommandCore.swift:430-434)**

```swift
case "-h", "--help":
    // Help is dispatched upstream via dispatchSubcommandHelp; tolerate here.
    i += 1
```

In practice the upstream dispatch (`dispatchSubcommandHelp` in CLI/c11.swift line 1553) intercepts these before `runHealth` is ever called. The "tolerate here" branch is defensive code for a path that can't be reached. Not wrong; just dead in the integrated CLI. Fine to keep for direct unit-testing of `parseHealthCLIArgs`. The comment is accurate.

### Test coverage

Coverage is good. Specifically:

- Each rail has its own parser-test file that exercises happy paths, malformed inputs, missing directories, and the `since` window. ✓
- `CLIHealthRuntimeTests` scaffolds a tmp HOME containing one event per rail, asserts the count and ordering, asserts JSON shape, and asserts golden table rendering. ✓
- `HealthFlagsTests` exercises the full grid of `--since` / `--since-boot` / `--rail` / `--json` combinations, including mutual exclusion and unknown values. ✓
- The MetricKit `metric` skip and the IPS top-level vs subdir rules are explicitly tested. ✓
- Both warnings (`metricKitBaselineWarning` and `telemetryAmbiguityFooter`) have positive and negative tests. ✓

Coverage gaps that would be worth follow-ups (not blockers):

- No test for `metricKitSeverity` mapping a multi-category kind (e.g. `crash1-hang2` → `.mixed`) — the production path is hit indirectly via filename parsing, but a focused unit test on `metricKitSeverity` would lock the contract.
- No test for the JSON-output's `rails` map when `--rail` filters to a single rail (does the JSON still include zero-count entries for the others, or only the queried one?). Looking at `renderHealthJSON` line 715: it iterates `HealthEvent.Rail.allCases where rails.contains(rail)`, so filtered rails are omitted from the JSON output. That's a behavioural choice worth pinning with a test so it doesn't silently regress.
- No test for the ordering tie-break when two events share the same timestamp. Probably fine to accept "stable sort by inputs" semantics; just be aware it's not tested.

### Style / project-conventions

- ✓ No em-dashes in user-facing strings (`"(prev to curr)"`, `"telemetry may be off, or events shipped on last launch and cleared the cache."`).
- ✓ No grep-the-source tests; everything is runtime-behavioural per CLAUDE.md.
- ✓ No `SentrySDK.capture*`, no socket access, no notification posting in the health code paths.
- ✓ `LaunchSentinel` and `AppDelegate` lines 2347 / 2795 are not modified — verified by `git diff origin/crash-visibility/launch-sentinel..HEAD -- Sources/SentryHelper.swift`. `Sources/SentryHelper.swift` is only added to the `CLI` build target via pbxproj if needed; check below confirms it isn't.
- ✓ The Sources/HealthCommandCore.swift dual-target wiring in `project.pbxproj` (DH001BF0…0718 and DH001BF0…0719) is the correct shape: the file is added to both target's Sources build phases via the same fileRef.

Ran a quick re-check of all 7 commits and confirmed:

- No edit to `LaunchSentinel`, `applicationDidFinishLaunching`, `applicationWillTerminate`, or any sentinel call site in `Sources/SentryHelper.swift`.
- No new socket commands, no new sidebar telemetry, no new `report_*` calls.
- No edit to typing-latency-sensitive paths (`WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh`).

The Impl deviation list is reasonable:
1. `.lattice/*` — correct, scratch belongs to the delegator.
2. Dual-target file — correct, the CLI binary needs the core; main-only-with-shim was never going to compile.
3. `(prev to curr)` instead of `(prev → curr)` — correct per CLAUDE.md no-em-dash policy. (Note: `→` is technically not an em-dash, it's a rightwards arrow; the substitution is still fine because the policy is "default to colons/commas/periods" and the AI-tells reading favours plain text. No issue.)
4. Optional `timeZone:` parameter — correct, harmless seam, nil in production.
5. Tests not run locally — correct per CLAUDE.md.

---

## Validation pass

Re-read each Important and Potential item against the actual diff and project state:

- #1 `--rail` overwrite — confirmed by reading `parseHealthCLIArgs`. ✅ Confirmed.
- #2 `bootTime()` silent fallback — confirmed by reading `bootTime()` at HealthCommandCore.swift:402. ✅ Confirmed.
- #3 Long summary truncation — confirmed by reading `renderHealthTable`. The padding is only on rail/severity columns; summary is unbounded. ⬇️ Lower priority, but valid.
- #4 Trailing newline contract — verified `print(renderHealthTable(...), terminator: "")` in CLI/HealthCommand.swift. ⬇️ Lower priority, valid as a comment-only follow-up.
- #5 `--rail` help omits default — confirmed in CLI/c11.swift:7735-7748. ✅ Confirmed.
- #6 `version`-only baseline check — confirmed by reading `metricKitBaselineWarning` and `LaunchSentinel.recordLaunchAndArchivePrevious()`. The producer writes both; the consumer reads only `version`. ❓ Behaviour question — not a defect.
- #7 Future-dated clock — confirmed by reading the `age >= 0` guard. Defensive, fine, just worth a comment. ❓
- #8 O(n) marker reads — confirmed; no early-exit on filename ordering. ✅ Confirmed (acceptable for v1).
- #9 Duplicate ISO formatters — confirmed via `grep` (5 hits). ✅ Confirmed (cosmetic).
- #10 Loose digit-position validation — confirmed; `ISO8601DateFormatter` does the real check downstream. ✅ Confirmed (acceptable; comment helps).
- #11 Sentry walker over-counts side files — confirmed; doc comment already acknowledges. ✅ Confirmed (acceptable; expand comment).
- #12 `"????????"` placeholder — confirmed at HealthCommandCore.swift:625. ✅ Confirmed (cosmetic).
- #13 `.metrickit` severity case is dead — confirmed by reading `metricKitSeverity`. ✅ Confirmed (cosmetic).
- #14 `unclean_exit` rawValue style — confirmed; rest of the enum is single-token lowercase. ✅ Confirmed (cosmetic).
- #15 Defensive `--help` in `parseHealthCLIArgs` — confirmed; upstream dispatch intercepts first. ❓ Acceptable as written.

No findings flipped to ❌ false-positive on the validation pass.

---

## Summary

**Blockers:** none.

**Important:** four — and only #1 and #2 are functional issues that should be addressed before merge. #3 and #4 are flagged as ⬇️ (lower priority). #5 is a one-line help-text wording fix.

**Potential:** ten items, mostly cosmetic / minor / questions for the operator. None block merge.

The branch is in good shape. The architecture is sound, the rails are independently testable, the producer/consumer boundary with `LaunchSentinel` is respected, and the test coverage is appropriately runtime-behavioural. The two functional fixes worth doing pre-merge are: (1) decide what `--rail X --rail Y` means and either error or accumulate; (2) emit a stderr note when `bootTime()` falls back. Everything else is fine to land and address in follow-ups.

### Quick-scan list

- [Important] **#1** `--rail` silent overwrite on multi-flag — error or accumulate.
- [Important] **#2** `bootTime()` silent 24h fallback when sysctl fails — log to stderr.
- [Important] **#5** `--rail` help text omits "default: all rails."
- [Important ⬇️] **#3** `summary` not truncated; long values break table alignment.
- [Important ⬇️] **#4** `renderHealthTable` always trailing-newlines; add a contract comment.
- [Potential] **#6** baseline warning checks `version` only, ignores `build` (intentional?).
- [Potential] **#7** `age >= 0` clock-skew guard suppresses warning silently.
- [Potential] **#8** O(n) `unclean-exit-*.json` parses; could short-circuit on newest filename.
- [Potential] **#9** Five duplicated `ISO8601DateFormatter` configs; extract helper.
- [Potential] **#10** `parseFilenameSafeISO` defers digit validation to `ISO8601DateFormatter`.
- [Potential] **#11** Sentry walker counts non-envelope side files.
- [Potential] **#12** `commit = "????????"` placeholder reads as visual noise.
- [Potential] **#13** `HealthEvent.Severity.metrickit` is a dead case.
- [Potential] **#14** `unclean_exit` rawValue is the only snake_case in the severity enum.
- [Potential] **#15** Defensive `--help` branch in `parseHealthCLIArgs` is dead in integrated CLI.
