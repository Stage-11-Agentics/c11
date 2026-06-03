## Critical Code Review

- **Date:** 2026-05-03T18:00:00Z
- **Model:** Claude Opus 4.7 (1M context) — `claude-opus-4-7[1m]`
- **Branch:** `c11-24/health-cli`
- **Latest Commit:** `cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92`
- **Base:** `origin/crash-visibility/launch-sentinel` @ `5402d3fcd69c3ecb54ff440664fad51abf59f0e7`
- **Lattice Story:** C11-24
- **Review Type:** Critical / Adversarial

---

## The Ugly Truth

This is, honestly, in better shape than most code I'd see in a "first pass at four scanners + a CLI" PR. The four hot rails (`Sources/HealthCommandCore.swift`, all of it the new code) honor the "passive only" contract: no `SentrySDK.capture*`, no notifications, no socket touches, no AppDelegate modifications, no `LaunchSentinel` enum changes, no AppDelegate hooks. I verified that directly against the diff. The em-dash policy is honored (zero `—`/`–` in the new code or golden files). The pbxproj-pattern is real — the dual-target add is correctly registered in both the `c11` and the `c11-cli` build phases. Nothing in the new tests greps `c11.swift` or reads `project.pbxproj`. That's the easy part.

But the moment you put on the adversarial hat, the rails start to bleed. The IPS and Sentry walks recurse into directories that are not under c11's control on a real Mac, with no symlink protection. Mtime-based windowing on IPS reports is a known-broken anti-pattern (Apple writes the file with a stamp from when the crash happened, but the **mtime is when CrashReporter finished writing**, which can lag by minutes to days). The `mostRecentSentinelMarker` helper has a subtle ordering bug where `active.json` from a *previous* version (stale, never cleaned up) can be selected as the "most recent prior version," producing a misleading warning on a fresh install or after a downgrade. The flag parser allows `--rail` to be specified multiple times silently keeping only the last, which contradicts the help text and surprises the user. The JSON output format has a `[String: Any]` event payload built via `JSONSerialization` without explicit key ordering on the **inner** event dictionary (the outer payload has `.sortedKeys`, which does cover nested dicts — but the contract is fragile to a refactor that changes options).

Also: telemetry-ambiguity-footer hardcodes the production bundle id `com.stage11.c11` and ignores `com.stage11.c11.debug.*` entirely. That is a real bug on the operator's primary debug build. And the `metricKitBaselineWarning` is silent for the most likely real-world condition (operator just installed for the first time → no marker → no warning), but the user-facing copy says "may not deliver for ~24h" which presumes the Sentry rail ran on the prior boot — a fact we don't actually know.

**Bottom line:** ship-able after the Blockers and the two Important items get patched, with the caveat that the four scanners are doing real I/O against real user data and the test coverage of "what does this do in the wild" is thin. The unit/runtime tests are fine. They aren't field tests. Don't mistake them.

---

## What Will Break

### 1. IPS scan and "since" window will silently drop legitimate crashes
- File: `Sources/HealthCommandCore.swift:101`, `ipsEventIfRecent` lines 124–144
- The window check uses `mtime >= since`. Apple's `ReportCrash` daemon writes the `.ips` file **after** the crash, sometimes minutes later (and on heavy systems, much longer). The `timestamp` field *inside* the IPS first-line JSON is the actual incident time. So a crash at 23:55 yesterday that finished writing at 00:05 today will be present (mtime newer than `since=now-24h`), but a crash at 00:05 today whose write got delayed to 00:30 will also be present — not wrong. The real failure is the inverse: the user runs `c11 health --since 30m` after a crash that happened 35 min ago but whose mtime is "now." We will surface a 35-minute-old crash and label it *just now* in the table. Conversely, a crash that happened 25 min ago but whose mtime is from a delayed write 35+ min in the past won't appear. **The mtime filter is not "since the crash" — it's "since CrashReporter finished writing" and we present it to the user as the former.**

### 2. `mostRecentSentinelMarker` can pick a stale `active.json` as the baseline
- File: `Sources/HealthCommandCore.swift:471–540`
- The function iterates **all** `com.stage11.c11*` bundle dirs in `Library/Caches`, looking at both `unclean-exit-*.json` and `active.json`. Picture: operator runs c11 production once at v0.43.0, runs debug build (different bundle id) all day at v0.44.1. Now they run a fresh production at v0.45.0. The most-recent `active.json` for `com.stage11.c11` has `version=0.43.0` from days ago. We call that the "prior version" and fire `MetricKit baseline still establishing after version bump (0.43.0 to 0.45.0)`. Wrong. The user is on the debug build daily; there's no real baseline issue.
- This also bites you when the base branch `LaunchSentinel.recordLaunchAndArchivePrevious()` rotates `active.json` → `unclean-exit-…json` on the *next* launch, but if the user crashed and never re-launched, `active.json` remains. The function correctly looks at both, but doesn't know which one represents "current" vs "prior."
- The "version is non-empty" check (line 517) is the only filter, and it picks the marker with the **largest timestamp**. If the largest timestamp is from a stale active.json, that's what we use.

### 3. `telemetryAmbiguityFooter` ignores debug builds entirely
- File: `Sources/HealthCommandCore.swift:567–588`
- The probe path is hardcoded: `"\(home)/Library/Caches/com.stage11.c11/io.sentry"`. On a developer machine, the running app is `c11_DEV` (`com.stage11.c11.debug.*` bundle id). That production cache path may not even exist. The footer will always be silent on dev builds, which is the population most likely to use this command. Should at minimum probe `com.stage11.c11.debug.*` first if the running app is a debug build, or fold this check into the same per-bundle walk that `scanSentryQueued` already does.

### 4. `--rail` repeats are silently coalesced to the last value
- File: `Sources/HealthCommandCore.swift:391–414` (`parseHealthCLIArgs`)
- `c11 health --rail ips --rail sentinel` parses to `railFilter = .sentinel`, no error. The help text says "Filter to one rail" but the user can reasonably expect either an error ("conflict") or set semantics. Worse: if you intend to remove this surprise later by allowing multiple rails, you've now committed to "one rail or all" as the public contract. Either explicitly reject the duplicate or document it.

### 5. `parseSinceFlag` accepts decimal values like `2.5h` and floats like `1.5d`
- File: `Sources/HealthCommandCore.swift:354–366`
- `Double(head)` accepts decimals. The help text shows only integers (`30m, 2h, 24h, 3d`). `0.5h` returns 1800s. That's fine if intentional, but you've also accepted `1e3h` (`1000h`), `+5h`, `0.0000001h` (rounding to nano-fractions of a second). And `Double` accepts `inf` strings on some locales — though `Double("inf")` in Swift's standard initializer parses to `.infinity`. Multiplying infinity by 60 and handing it to `addingTimeInterval(-)` gives `.distantPast` (or undefined date arithmetic). Edge case but worth the explicit guard.

### 6. The Sentry recursive walk follows symlinks by default
- File: `Sources/HealthCommandCore.swift:206–229` (`walkSentryDir`)
- `FileManager.enumerator(at:..., options: [.skipsHiddenFiles])` does **not** include `.skipsSymbolicLinks` by default — actually, `FileManager.DirectoryEnumerator` follows symlinks unless told otherwise. If anything (a malicious package, a bug in another tool, a developer's mistake) drops a symlink into `~/Library/Caches/com.stage11.c11.foo/io.sentry/` pointing at, say, `/`, this walk runs forever (or until `since` filters everything, which it can't because we filter on mtime *after* enumeration). **Add `.skipsSubdirectoryDescendants`? No, you want the recursion. Add `.skipsPackageDescendants` and consider checking `.isSymbolicLinkKey` on each URL.** Same concern applies to the `telemetryAmbiguityFooter` enumerator and to `scanIPS`'s subdirectory walk (though IPS only descends one level).

### 7. JSON `events` inner dict ordering relies on `.sortedKeys` propagating
- File: `Sources/HealthCommandCore.swift:707–743`
- `JSONSerialization.data(withJSONObject:options:)` with `.sortedKeys` does sort all nested keys, so the per-event keys (`path`, `rail`, `severity`, `summary`, `timestamp`) come out alphabetical. Good. But the `eventsArray` itself preserves insertion order (the order returned by `collectHealthEvents`). That's reverse-chronological by design, which is good. **The hidden risk:** if anyone refactors the renderer to use `JSONEncoder` with a `Codable` `HealthEvent`, the default `JSONEncoder` does **not** sort keys (you have to set `outputFormatting`). This is a footgun for downstream consumers diffing the JSON across runs. Lock it down with a tiny `testJSONOutputIsKeySorted` that diffs full bytes against a fixture, or wrap the renderer in something that asserts.

### 8. `parseFilenameSafeISO` accepts only fractional seconds with exactly 3 digits
- File: `Sources/HealthCommandCore.swift:330–344`
- `parseFilenameSafeISO` checks length == 24 and `chars[19] == "."`. If `SentryHelper.CrashDiagnostics.persist` ever produces `.fff` with anything other than 3 digits (e.g. 6-digit microseconds, or the OS rounds and produces `.000Z` truncating), the parser returns `nil` and the file is silently skipped. The base branch fortunately does write 3 digits — but I'd add a parser test for `.000Z` (zeroes) explicitly to prevent regression. Also the check `chars[19] == "."` is positional: a stamp like `2026-05-03T15-19-001Z` (no dot, 25 chars) is rejected via the length check, but a stamp with `.` at the wrong position fails position check. Brittle, but functionally right for the contract.

### 9. MetricKit kind grammar accepts ill-formed orderings silently
- File: `Sources/HealthCommandCore.swift:267–275` (`isValidMetricKitKind`, `metricKitSeverity`)
- The plan-note grammar says: "joined by `-` in the fixed order crash, hang, cpu, disk." The implementation **only checks each token is well-formed**, not the ordering. So `disk1-crash1` or `hang1-crash1-cpu1` parse cleanly. `metricKitSeverity` doesn't care about ordering either — `categoryCount > 1 → .mixed`. The producer in `SentryHelper.swift` writes them in the canonical order, so this is a soft bug. But anyone reading the test fixture can construct out-of-order names; the parser's relaxed acceptance + silent shrug is not what the docstring promises.
- Also: `crash01` (zero-padded) would pass `allSatisfy { $0.isNumber }` and be accepted. The producer doesn't zero-pad, but the parser's contract isn't tight.

### 10. `parseUncleanExitFile` returns a sentinel commit string `"????????"` when the JSON is unreadable
- File: `Sources/HealthCommandCore.swift:644–662`
- Defaults: `version = "?"`, `build = "?"`, `commit = "????????"`. The `summary` becomes `"? (?) ????????"`. That's *visible to the user* in the table, which is mildly ugly but acceptable as a "we found a sentinel file but couldn't parse the metadata" signal. However, the function will **return a HealthEvent even when the JSON is wholly unparseable** — only the timestamp from the filename matters. That means a corrupt empty file at `unclean-exit-2026-05-03T...json` produces a row with no real data. Compare with IPS where unreadable first-line just falls back to filename in `summary`. The contract is "filename is source of truth for timestamp" — fine — but you might want a comment that explicitly says corrupt body is intentionally surfaced rather than swallowed.

### 11. IPS `incidentID` short-prefix truncation can collide
- File: `Sources/HealthCommandCore.swift:131`, `String($0.prefix(8))`
- 8 hex chars from a UUID is 32 bits. Collision space is small enough that two crashes in a 24h window with the same first 8 chars is exceedingly rare but not impossible. The summary makes them look identical to the operator. Print 8 chars *and* the filename, or print 12. Nit, but the operator may be staring at this list trying to dedupe.

### 12. Empty `events` for filtered-rail run still claims "across ips, sentry, metrickit, sentinel"
- File: `Sources/HealthCommandCore.swift:679` (`healthEmptyResultLine`)
- Run `c11 health --rail sentinel` with no sentinel events. Output: `c11 health: nothing in the last 24h across ips, sentry, metrickit, sentinel.` That's a lie — we only checked `sentinel`. Build the empty line dynamically from `rails` parameter. There's no test catching this because `renderHealthTable([])` doesn't take rails. Surface bug.

### 13. JSON output suppresses the empty-table line and warnings inline differently
- File: `Sources/HealthCommandCore.swift:707–743`
- Table mode emits `Warnings:` block. JSON emits `warnings` as a top-level array. Fine — different mediums. But **JSON warnings list is just `[String]`**, opaque to the consumer. An eventual consumer (a bot, a dashboard, a sidebar widget) will need to grep human prose. Plan for warnings to be `{code, message, details}` from the start; even if we only emit one or two codes today, retrofitting later is a breaking change. Not a Blocker, but a Don't-Ship-Forever landmine.

### 14. `HealthEvent.Severity.unclean_exit` uses underscore in user-facing rawValue
- File: `Sources/HealthCommandCore.swift:33`
- The rawValue is `"unclean_exit"`. The four-events golden has the literal `unclean_exit` in the table column. That looks ugly to a human (`unclean exit`, `unclean-exit` are both more readable). Minor, and consistent with the JSON wire — but the wire and the table don't have to match. If you want JSON stability and table readability, use a separate display formatter.

### 15. `bootTime()` swallows sysctl failure to "24h ago"
- File: `Sources/HealthCommandCore.swift:373–384`
- Falls back to `Date(timeIntervalSinceNow: -24 * 3600)` on `sysctlbyname` failure. But the function is called from `--since-boot` mode, which the user invoked specifically to get since-boot semantics. Silently downgrading to 24h is wrong: the user will see results but won't know they're 24h-windowed instead of since-boot-windowed. In practice `kern.boottime` is bulletproof on macOS, but: print a stderr warning, or thread the failure up to the caller. The current behavior is "we lied to you, here's an answer."

---

## What's Missing

### Tests that don't exist (in priority order)

1. **Symlink-loop / symlink-escape** test for the Sentry walk and the IPS subdir walk. Drop a symlink to `/` inside a fake `io.sentry/`, prove the scanner doesn't hang. (Use a test timeout.)
2. **mtime vs. timestamp drift** test for IPS. The plan note acknowledges mtime is the only viable source on macOS without sandbox erosion, so this might be a "documented limitation" instead of a fix — but you want a test that documents it: "if mtime is 1 hour from `since` boundary, assert behavior."
3. **`renderHealthTable` empty result with `rails` arg.** Currently impossible to write because the function has no `rails` parameter. Add the parameter.
4. **`telemetryAmbiguityFooter` debug-bundle path.** No test exercises `com.stage11.c11.debug.*`. Currently silently always returns `nil` on debug builds.
5. **`mostRecentSentinelMarker` with `active.json` from a different bundle id.** Build a temp HOME with two bundle dirs (`com.stage11.c11/`, `com.stage11.c11.debug.foo/`), each with a `sessions/active.json` of different versions and timestamps, prove the cross-bundle picking is intentional or a bug.
6. **JSON byte-level golden snapshot.** Lock the JSON output (with a stable-window date passed in) to a fixture. Catches future `JSONEncoder` migrations or option reorderings.
7. **`parseSinceFlag("inf*")`, `("nan*")`, `("1e6h")`, `("0.0001m")`.** The parser accepts these silently.
8. **`--rail` specified twice.** Either codify the "last wins" or reject.
9. **MetricKit kind ordering.** `disk1-crash1` (out of canonical order) — does it parse? Currently yes. Should it?
10. **MetricKit kind with zero-padded count.** `crash01` — parses today. Decide and lock.
11. **IPS first line with byte-order mark, with leading whitespace, with CRLF newline.** `readFirstLine` looks for `\n`; a CRLF report would yield a first line ending in `\r`, which `JSONSerialization` accepts (it's whitespace) — but worth a test.
12. **A real Apple `.ips` file as a fixture.** The hand-rolled fixture has only the keys the parser cares about. The real format has many more keys, sometimes nested objects on the first line. Pull a real (sanitized) .ips file from the team's crash reports as a fixture.

### Error-handling gaps

- `runHealth` in `CLI/HealthCommand.swift` **prints to stderr AND throws CLIError with the same message**. The dispatcher will likely print the throw too, so the user sees the same line twice. Verify with the existing `CLIError` printing path; if both fire, deduplicate.
- The `c11 health --json` mode never includes an `error` field. If a future failure mode is "couldn't read your home dir," we have no machine-readable way to say that. JSON consumers should be able to detect graceful-zero vs. partial-failure.

---

## The Nits

- `HealthEvent.Severity.unclean_exit` snake_case; everything else is single-word. Pick one.
- `metricKitBaselineWarning` says "may not deliver for ~24h" but the actual MetricKit delay is documented as ~24h on first install, not 24h after every version bump. The wording overstates the warning's certainty.
- `HealthCollectionWindow.Mode.defaultLast24h = "default-24h"` and the test uses string comparisons — fine — but the rawValue leaks `default-` prefix to JSON. Consumers will see `"mode": "default-24h"`. That's fine for now; flag it for future schema review.
- `telemetryAmbiguityFooter` says "events shipped on last launch and cleared the cache." This is the kind of multi-clause sentence a tired operator at 3am will misread. Two short sentences would be friendlier.
- Help text says "30m, 2h, 24h, 3d" — gives no upper bound. `c11 health --since 99999d` is parsed and yields a `since` of 273 years ago. That's not wrong but could be capped at 30d with a friendly error.
- The four-events golden has `2026-05-03 15:28 | sentinel  | unclean_exit |...` — note the **two spaces after `sentinel`**. The padding is right, but `sentinel` is 8 chars and the pad is 9 chars. Visually `metrickit` (9 chars) has zero trailing space, `sentinel` has one, `ips` has six. Aesthetic.
- `parseUncleanExitFile`'s commit fallback `"????????"` is also 8 chars by design but becomes silently load-bearing because the table doesn't measure column widths from data — only fixed pads. If the commit ever expands to 12 chars and a `?` row coexists, alignment breaks.
- `CLIError(message: error.description)` — `CLIError` definition outside the diff; verify it doesn't double-print.

---

## Numbered List

### Blockers (will cause production incidents or operator trust loss)

1. **`telemetryAmbiguityFooter` ignores `com.stage11.c11.debug.*` bundles.** On a debug-build dev machine the footer is permanently silent. (file: `Sources/HealthCommandCore.swift:567–588`)
2. **`mostRecentSentinelMarker` cross-bundle picking can lock onto a stale `active.json`** from a different bundle and fire a misleading `MetricKit baseline still establishing` warning. (file: `Sources/HealthCommandCore.swift:471–540`)
3. **Sentry recursive walk has no symlink defense.** A symlink under `~/Library/Caches/com.stage11.c11.*/io.sentry/` can lead the enumerator into the wider filesystem; on a hostile or buggy environment this is a hang vector. Add `.isSymbolicLinkKey` filter or `.skipsPackageDescendants`. (file: `Sources/HealthCommandCore.swift:206–229`, `567–588`, `99–109`)
4. **Empty-result line lies about which rails were checked when `--rail` is set.** The line says "across ips, sentry, metrickit, sentinel" regardless of filter. (file: `Sources/HealthCommandCore.swift:679`, `renderHealthTable`)

### Important (will cause bugs or poor UX)

5. **IPS mtime is not the incident time.** The summary should show the IPS internal `timestamp` (or label the column as "REPORTED" not "TIME"). Today the operator can't trust the times they see. (file: `Sources/HealthCommandCore.swift:124–144`)
6. **`--rail` repeats silently dedupe to last value.** Reject duplicates explicitly. (file: `Sources/HealthCommandCore.swift:391–414`)
7. **`bootTime()` failure silently downgrades `--since-boot` to 24h.** Print a stderr diagnostic when sysctl fails. (file: `Sources/HealthCommandCore.swift:373–384`)
8. **JSON `warnings` are opaque strings.** Make them `{code, message}` from day one. (file: `Sources/HealthCommandCore.swift:730`)
9. **`parseSinceFlag` accepts floats / scientific notation.** Either tighten regex or document. (file: `Sources/HealthCommandCore.swift:354–366`)
10. **`runHealth` prints to stderr **and** throws CLIError with the same message.** Likely double-printed. Verify against `CLIError` printing path. (file: `CLI/HealthCommand.swift:8–13`)
11. **No real `.ips` fixture.** Hand-rolled fixtures pass; production-shaped IPS may not. Pull a sanitized real fixture from `~/Library/Logs/DiagnosticReports/`. (file: `c11Tests/Fixtures/health/ips/`)

### Potential (smells, missing tests, future-bite)

12. **`HealthEvent.Severity.unclean_exit` rawValue with underscore** leaks to user-facing table. (`Sources/HealthCommandCore.swift:33`)
13. **MetricKit kind grammar accepts out-of-order tokens and zero-padded counts** — relaxed parser vs. tight docstring. (`Sources/HealthCommandCore.swift:260–275`)
14. **No JSON byte-level snapshot test.** Future `JSONEncoder` migration could change key ordering. (`c11Tests/CLIHealthRuntimeTests.swift`)
15. **`parseFilenameSafeISO` only accepts 3-digit fractional seconds.** Add a `000Z` test. (`Sources/HealthCommandCore.swift:330–344`)
16. **`parseUncleanExitFile` returns a row even with corrupt JSON** producing `"? (?) ????????"`. Document the intent. (`Sources/HealthCommandCore.swift:644–662`)
17. **IPS incident-id 8-char prefix can collide.** Print more, or include filename. (`Sources/HealthCommandCore.swift:131`)
18. **Help text shows no upper bound on `--since`.** Reasonable to cap at 30d. (`Sources/HealthCommandCore.swift:354–366`)
19. **`metricKitBaselineWarning` copy overstates confidence.** Reword. (`Sources/HealthCommandCore.swift:559`)
20. **No symlink-loop test on any scanner.** (`c11Tests/`)
21. **No test for `mostRecentSentinelMarker` cross-bundle behavior.** (`c11Tests/HealthFlagsTests.swift`)
22. **Table padding looks irregular when rail names span 3..9 chars.** Aesthetic only. (`Sources/HealthCommandCore.swift:687–693`)

---

## Phase 5: Validation Pass

Re-checking each Blocker / Important inline:

- (1) Confirmed. ✅ `telemetryAmbiguityFooter` line 569 hardcodes `com.stage11.c11/io.sentry`. No `.debug` variant probed. The function will return `nil` for all debug-build users 100% of the time. **The plan-note original intent was likely "treat the user's *running* bundle as the probe target." Pull the running bundle id from `Bundle.main.bundleIdentifier` instead.**
- (2) Confirmed. ✅ `mostRecentSentinelMarker` walks all `com.stage11.c11*` bundle dirs and picks the entry with the largest timestamp regardless of which bundle id it came from. The test `testMetricKitBaselineWarningFiresOnRecentVersionBump` passes because there's only one bundle dir. Adversarial scenario (two bundles) is not tested.
- (3) Confirmed. ✅ `FileManager.enumerator(at:..., options:[.skipsHiddenFiles])` does follow symlinks unless `.skipsPackageDescendants` is added. Documented in Apple's docs and confirmed by reading the symbol. Mitigation is simple.
- (4) Confirmed. ✅ The constant `healthEmptyResultLine` is hardcoded with all four rail names. `renderHealthTable` doesn't know what was filtered.
- (5) ❓ Likely but hard to verify without running on a real machine. Apple's documentation on IPS file mtime lag is sparse but anecdotally well-known.
- (6) Confirmed. ✅ `parseHealthCLIArgs` re-assigns `rail` on each `--rail` arg with no check.
- (7) Confirmed. ✅ `bootTime()` line 384 returns `Date(timeIntervalSinceNow: -24 * 3600)` on failure — no log, no throw, no marker.
- (8) ⬇️ Real but lower priority. Today's `[String]` works. Future-proofing.
- (9) Confirmed. ✅ `Double("1.5h")` — `Double("1.5") = 1.5`, returns `1.5 * 3600 = 5400`. `Double("1e3")` returns 1000.
- (10) ❓ Depends on `CLIError` print path. The diff for `CLI/c11.swift` doesn't show how `throw CLIError` is rendered, so I can't fully verify without the rest of `CLI/c11.swift`. Likely double-print.
- (11) ⬇️ Real but lower priority. Hand-rolled fixture covers happy path. Real .ips is a hardening test.

---

## Closing

**Would I mass deploy this to 100k users?** No, not as-is, but only because of (1)/(4): a debug-build dev sees a permanently-broken telemetry footer and a lying "no events" line. Both are 5-minute fixes. (2) is medium-risk: misleading warnings on multi-bundle machines. (3) is "we'd never see it but if we did, we'd never live it down."

**To 100 internal users?** Yes, with (1)/(4) patched today and (2)/(3)/(5) on the post-merge issue list.

**The structural call:** the four-rail design is correct. The dual-target pbxproj layout is correct. The "no `SentrySDK.capture*`, no AppDelegate touches, no LaunchSentinel mods" contract is honored cleanly. The tests are real runtime tests with sandboxed `home` paths, not source-grep theater. That's the win. The losses are at the seams: cross-bundle assumptions, mtime confusion, footer hardcoding, and the symlink-walk attack surface.

**One specific compliment:** the choice to make `home` a parameter on every scanner and `timeZone` a parameter on the renderer is the kind of small, deliberate testability investment that pays off forever. Don't let it rot.

**One specific warning:** the moment a second consumer (sidebar widget, web dashboard, bot) ingests the JSON output, the `warnings: [String]` shape is a problem. Promote to structured warnings before that happens, not after.

— Claude Opus 4.7 (1M context)
