# Action-Ready Synthesis: C11-24

## Verdict
fix-then-merge

The architecture is sound (passive, read-only, four-rail core + CLI shim, dual-target file, sandboxed runtime tests). LaunchSentinel and AppDelegate hooks were not modified, em-dash policy is honored, no `SentrySDK.capture*` / no socket / no notifications. There are, however, four reviewer-consensus blockers in the diagnostic-warning layer and the JSON output that should be patched before merge: the MetricKit baseline warning is effectively dead in the real CLI path, the sentinel marker selection masks the very signal it is meant to compare against, the Sentry ambiguity footer ignores debug builds entirely, and JSON output leaks absolute home paths. None require redesign; all are localized fixes inside `Sources/HealthCommandCore.swift` or `CLI/HealthCommand.swift`.

## Apply by default

### Blockers (merge-blocking)

- **B1: MetricKit baseline warning is effectively dead in the real CLI path (CLI version lookup returns nil).**
  - Location: `CLI/HealthCommand.swift:37`, `Sources/HealthCommandCore.swift:550`, `GhosttyTabs.xcodeproj/project.pbxproj:1498-1534`
  - Problem: `runHealth` reads `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`, but the `c11-cli` target's build configuration defines no Info.plist, no `MARKETING_VERSION`, and no `CURRENT_PROJECT_VERSION`. When the user runs `c11 health`, `bundleVersion` resolves to nil and `metricKitBaselineWarning` exits at the `let curr = bundleVersion, !curr.isEmpty` guard before doing any work. The warning that the MVP explicitly ships will never fire from the CLI binary in production.
  - Fix: Resolve the running c11 app bundle's version from a stable source instead of relying on the CLI's own `Bundle.main`. The codebase already has a precedent: `CLISocketSentryTelemetry` in `CLI/c11.swift` walks to find the c11 app bundle for Sentry init. Reuse that pattern (or extract a small helper) so `runHealth` passes the *app* version, not the CLI binary's nil version. As a stopgap, threading a non-empty version is non-negotiable for the warning to fire.
  - Sources: standard-codex (Blocker #1), critical-codex (Important #1), standard-gemini (Important #1).

- **B2: `mostRecentSentinelMarker` treats the current launch's `active.json` as a candidate, which masks the prior-version marker the warning compares against.**
  - Location: `Sources/HealthCommandCore.swift:486-540` (`mostRecentSentinelMarker`), `Sources/HealthCommandCore.swift:550-561` (`metricKitBaselineWarning`)
  - Problem: The producer at `Sources/SentryHelper.swift:131` writes `active.json` for the *current* launch. The reader picks the marker with the maximum timestamp from both `unclean-exit-*.json` and `active.json`. After a version bump, the current `active.json` has the *new* version and the newest timestamp, so the warning's `marker.version != curr` guard returns nil. The warning is meant to compare current version against the *prior* session's version, but the helper picks the current session itself.
  - Fix: Exclude `active.json` from the candidate set in `mostRecentSentinelMarker` (the function only needs prior markers). Alternatively, treat `active.json` as "current" and only consider it a "prior" marker when its `version` differs from the running bundle version. The simpler correct behavior is: only enumerate `unclean-exit-*.json` files; `active.json` is by definition the current session and not a baseline. While here, also restrict the bundle-dir walk to the running bundle id (or document why cross-bundle comparison is desired) so a stale `active.json` from a sibling bundle cannot poison the result.
  - Sources: standard-codex (Blocker #1, paired sub-finding), critical-codex (Important #1, paired sub-finding), critical-claude (#2), critical-gemini (Potential #6 cross-bundle variant).

- **B3: `telemetryAmbiguityFooter` hardcodes the production bundle path; debug builds (the dev-machine population) never see this footer.**
  - Location: `Sources/HealthCommandCore.swift:567-588`
  - Problem: The probe path is hardcoded `"\(home)/Library/Caches/com.stage11.c11/io.sentry"`. On a machine where only `c11_DEV` (`com.stage11.c11.debug.*`) ever ran, the probe returns false, the function exits early, and the operator who is in the exact ambiguous state the footer is designed for sees nothing. `scanSentryQueued` uses `hasPrefix("com.stage11.c11")` family iteration; this helper diverged.
  - Fix: Reuse the same family-iteration shape `scanSentryQueued` uses. Walk all `~/Library/Caches/com.stage11.c11*` bundle directories, and fire the footer when *every* sibling's `io.sentry/` directory exists and is empty (or no sibling has any envelopes). At minimum, prefer probing the running bundle's id (`Bundle.main.bundleIdentifier`) instead of the hardcoded production string.
  - Sources: critical-claude (Blocker #1), standard-gemini (Important #2), standard-codex (Potential #2), critical-codex (Potential #1), evolutionary-claude (Concrete suggestion #5).

- **B4: JSON output leaks absolute local filesystem paths (operator macOS username and cache layout).**
  - Location: `Sources/HealthCommandCore.swift:725` (`renderHealthJSON`, `"path": ev.path`)
  - Problem: Every event in `--json` output includes `ev.path`, which is an absolute filesystem path like `/Users/<operator>/Library/Caches/com.stage11.c11.debug.runtime/io.sentry/envelopes/<uuid>`. The diagnostic story for `c11 health` is that operators paste this output into tickets, Zulip threads, GitHub issues, or share with agents. The table form intentionally omits the path; the JSON form should not silently regress that privacy posture.
  - Fix: Redact the home prefix before emitting. Replace `NSHomeDirectory()` (or the `home` parameter threaded through scanners) with the literal `~` in the `path` field of each event prior to serialization. This is a one-line transform at the renderer boundary and does not require changing scanner signatures.
  - Sources: critical-codex (Important #2), critical-gemini (Blocker #1).

### Important (land in same PR)

- **I1: `--rail` repeats are silently coalesced to the last value, contradicting the help text.**
  - Location: `Sources/HealthCommandCore.swift:430-455` (`parseHealthCLIArgs`, the `--rail` arm at line 444)
  - Problem: `c11 health --rail ips --rail sentinel` parses to `railFilter = .sentinel`, no error, no diagnostic. The help text says "Filter to one rail" but the natural operator instinct, given four rails, is that repeating the flag accumulates. Today's behavior silently drops the first rail.
  - Fix: Either (a) reject duplicate `--rail` with a clear error (smaller change, keeps the v1 contract honest) or (b) widen `railFilter` to `Set<HealthEvent.Rail>?` and accumulate. Recommend (a) for v1: throw a new `HealthCLIError.duplicateFlag(String)` (or reuse `unknownFlag`) when `rail != nil` on the second occurrence. Update help text to mention "Specify at most once" if you go with (a).
  - Sources: standard-claude (#1), critical-claude (#6).

- **I2: `bootTime()` silently downgrades `--since-boot` to a 24h window when sysctl fails.**
  - Location: `Sources/HealthCommandCore.swift:402-414` (`bootTime`)
  - Problem: On `sysctlbyname("kern.boottime", ...)` failure, the function returns `Date(timeIntervalSinceNow: -24 * 3600)` with no log, no throw, no marker. `--since-boot` becomes a synonym for the default 24h window without telling the operator. `kern.boottime` is bulletproof on macOS in practice, but when it does fail, the silent lie is worse than a clear diagnostic.
  - Fix: When the sysctl call fails, write a single line to stderr (e.g., `c11 health: kern.boottime unavailable, falling back to 24h window`) before returning the fallback Date. Keep the fallback so the command still produces output; just stop hiding the downgrade.
  - Sources: standard-claude (#2), critical-claude (#7), critical-gemini (Nit).

- **I3: Empty-result line lies about which rails were checked when `--rail` is set.**
  - Location: `Sources/HealthCommandCore.swift:679` (`healthEmptyResultLine`), `Sources/HealthCommandCore.swift:644-672` (`renderHealthTable`)
  - Problem: The constant `healthEmptyResultLine` is hardcoded to `"c11 health: nothing in the last 24h across ips, sentry, metrickit, sentinel."`. When the operator runs `c11 health --rail sentinel` with no sentinel events, the output claims all four rails were checked. Misleading.
  - Fix: Build the empty line dynamically. Add a `rails: Set<HealthEvent.Rail>` parameter to `renderHealthTable` (or pass through a small `HealthRenderContext`) and join the actual rail names from `rails`. Also reflect the actual window mode rather than always saying "last 24h" (e.g., for `--since 30m`, say "last 30m"; for `--since-boot`, say "since boot"). Update the existing CLI shim and tests to thread the new parameter.
  - Sources: critical-claude (Blocker #4), evolutionary-codex (#1 noted indirectly).

- **I4: JSON output is non-deterministic when two events share a timestamp (no tiebreak).**
  - Location: `Sources/HealthCommandCore.swift:74` (`collectHealthEvents` final sort)
  - Problem: `events.sorted { $0.timestamp > $1.timestamp }` only compares timestamps. Swift's `sorted` is not stable, so two events with the same timestamp (entirely possible for batch-written sentinel/MetricKit files at sub-millisecond resolution) produce non-deterministic order. Downstream JSON consumers (`jq` filters, fleet aggregators, future CI gates) will see flapping output even when the underlying disk state is unchanged.
  - Fix: Add secondary and tertiary sort keys. Sort by `timestamp` desc, then `rail.rawValue` asc, then `path` asc. One line change in the sort closure. Add a small unit test that creates two events with identical timestamps across rails and asserts the resulting order.
  - Sources: critical-gemini (Blocker #2).

- **I5: `readFirstLine` strict UTF-8 decoding can drop entire IPS reports on multi-byte boundary truncation.**
  - Location: `Sources/HealthCommandCore.swift` `readFirstLine(of:)` (around lines 196-205 in the diff)
  - Problem: `(try? handle.read(upToCount: 8192))` reads at most 8192 bytes, then `String(data: data, encoding: .utf8)` is strict. If the 8192nd byte sits in the middle of a multi-byte UTF-8 sequence (any `.ips` payload with non-ASCII bundle metadata, app names, localized strings, or unicode in the JSON header), the entire decode returns nil and the IPS row falls back to filename-only summary, dropping the parsed bundle/bug-type/incident-id signal.
  - Fix: Replace `String(data: data, encoding: .utf8)` with `String(decoding: data, as: UTF8.self)`. The latter is lossy and resilient: it inserts replacement characters for malformed bytes rather than returning nil. The first-line parse path doesn't care about the trailing replacement character; it cuts at the first `\n`.
  - Sources: critical-gemini (Important #3).

### Straightforward mediums

- **M1: `--rail <name>` help text omits the "all rails by default" note.**
  - Location: `CLI/c11.swift:7741`
  - Problem: A reader of `--help` cannot tell from the current line whether omitting `--rail` defaults to all rails or to nothing.
  - Fix: Append `Default: all rails.` (or `Omit to query all four rails.`) to the `--rail <name>` line. One word of help text.
  - Sources: standard-claude (#5).

- **M2: Hoist `ISO8601DateFormatter` instantiation out of the per-marker loop in `mostRecentSentinelMarker`.**
  - Location: `Sources/HealthCommandCore.swift:502, 515` and the surrounding loop body in `mostRecentSentinelMarker`
  - Problem: A new `ISO8601DateFormatter` is instantiated per file inside the marker loop, and a separate copy of the same five-line setup is duplicated five times across the file (lines 288, 291, 502, 515, 711, 712 per standard-claude). On a machine with many archived `unclean-exit-*.json` files this becomes measurably slow during health command invocation.
  - Fix: Extract a small private helper `private func isoFormatter() -> ISO8601DateFormatter` with the standard `[.withInternetDateTime, .withFractionalSeconds]` setup, and reuse a single instance per call site. Even better, in `mostRecentSentinelMarker` specifically, parse the timestamp from the filename first (cheap) and only `Data(contentsOf:)` + decode the JSON when the filename's timestamp beats the current best candidate. This drops the function from O(n) full reads to O(1) full reads in the common case.
  - Sources: standard-claude (#9, #8), standard-gemini (Potential #1), critical-gemini (Important #4).

- **M3: Remove the dead `HealthEvent.Severity.metrickit` enum case.**
  - Location: `Sources/HealthCommandCore.swift:18-25` (`HealthEvent.Severity` definition)
  - Problem: `metricKitSeverity(forKind:)` returns one of `.crash`, `.hang`, `.resource`, `.mixed`, `.diagnostic`. The `.metrickit` case is defined but never produced. Confuses future maintainers about what valid severity values can appear in the wire format.
  - Fix: Delete the `case metrickit` line. Re-run tests; nothing should depend on it.
  - Sources: standard-claude (#13).

### Evolutionary clear wins

- **EW1: Add `"schema_version": 1` to the JSON output.**
  - Location: `Sources/HealthCommandCore.swift:707-743` (`renderHealthJSON`'s `payload` dictionary)
  - Problem: The JSON shape has no version key. The first downstream consumer (a `jq` filter, a CI gate, a fleet aggregator, an agent that auto-runs `c11 health --json` on crash) will lock in this shape. Changing the schema later becomes a breaking change with no clean signal for consumers to detect.
  - Fix: Add one key to the `payload` dictionary: `"schema_version": 1`. The existing `testJSONShapeContainsTopLevelKeys` test will need to add this key to its expected set. Cost: one production line, one test line. Locks the contract for every future JSON change to be explicitly versioned.
  - Sources: evolutionary-claude (Concrete suggestion #1), evolutionary-codex (#1 supports a `HealthReport` shape that subsumes this).

## Surface to user (do not apply silently)

- **S1: Sentry walker counts non-envelope side files (only walks `io.sentry/`, not `io.sentry/envelopes/`).**
  - Why deferred: disagreement on the fix direction.
  - Summary: critical-gemini wants both `scanSentryQueued` and `telemetryAmbiguityFooter` scoped to `io.sentry/envelopes/` only, treating any non-envelope file as "false positive queued event." standard-claude and the existing doc comment treat the over-count as an acknowledged trade-off ("any regular file inside `io.sentry/` is treated as a queued event") and suggest only documenting it. The two positions imply different file layouts in production. Sentry-Cocoa's actual on-disk layout (envelopes vs. installation.id vs. metadata files) needs a verification pass before locking the fix. The under-count risk if envelopes ever land outside the `envelopes/` subdir is non-zero.
  - Sources: critical-gemini (Important #5), standard-claude (Potential #11), standard-codex (Potential #2).

- **S2: IPS rail uses file mtime instead of the IPS internal `timestamp`, so "since" filtering is "since CrashReporter finished writing," not "since the crash."**
  - Why deferred: design-needed; this is a documented limitation, not a clear bug.
  - Summary: critical-claude flags that mtime can lag the actual crash timestamp by minutes (or longer on a heavily loaded system), and operators who run `c11 health --since 30m` after a recent crash may miss it. The fix requires parsing the IPS first-line JSON's `timestamp` field instead of (or in addition to) mtime, and choosing what to render in the table column header ("REPORTED" vs "TIME"). Worth deciding before promoting `c11 health` as a precise incident finder, but acceptable for v1 if labelled.
  - Sources: critical-claude (Important #5).

- **S3: Symlink defense in scanners (`scanSentryQueued`, `walkSentryDir`, `telemetryAmbiguityFooter`, `scanIPS` subdir walk).**
  - Why deferred: subjective threat model; single reviewer.
  - Summary: critical-claude flags that `FileManager.enumerator(at:..., options:[.skipsHiddenFiles])` follows symlinks by default. A malicious or buggy symlink under `~/Library/Caches/com.stage11.c11.*/io.sentry/` could lead enumeration into the wider filesystem (or hang). No other reviewer raised this. The blast radius is limited because the operator's own user directory is the trust root and a `c11 health` run is bounded by `since`. Worth a follow-up discussion on whether the read-only sweep should add `.isSymbolicLinkKey` filtering, but not consensus-blocking.
  - Sources: critical-claude (Blocker #3).

- **S4: `runHealth` may double-print error messages (writes to stderr AND throws CLIError with the same message).**
  - Why deferred: ambiguous; reviewer could not verify the CLIError print path inside `CLI/c11.swift` without reading more of that file.
  - Summary: critical-claude notes that `runHealth` writes the error to stderr and then throws `CLIError(message: error.description)`. If the upstream dispatcher prints the thrown CLIError too, the operator sees the same line twice. Needs a 5-minute trace through `CLI/c11.swift`'s top-level error handling to confirm or deny. If confirmed, fix is to drop one of the two emissions.
  - Sources: critical-claude (Important #10).

- **S5: `parseSinceFlag` accepts decimal and scientific-notation values (`1.5h`, `1e3h`).**
  - Why deferred: subjective; the function uses `Double(head)` which permissively accepts these. Could be a feature or a footgun.
  - Summary: critical-claude flags that the parser accepts `1.5h`, `0.5d`, `1e3h`, etc., even though help shows only integer suffixes. Argues for a tighter regex or capping to e.g. 30d. Counter-argument: permissive parsing is the standard CLI behavior for most duration parsers, and an unrealistically long window is harmless because the disk artifacts cap the actual count. Worth surfacing because it's an explicit policy choice.
  - Sources: critical-claude (Important #9).

- **S6: `HealthEvent.Severity.unclean_exit` raw value is the only snake_case in the enum (rest are single-word lowercase).**
  - Why deferred: subjective, downstream-consumer impact unknown.
  - Summary: standard-claude and critical-claude both flag the inconsistency. The rawValue leaks to JSON (`"severity": "unclean_exit"`) and the table column. Renaming to `"unclean-exit"` (kebab-case mirroring filename convention) or `"uncleanExit"` would normalize, but it's a wire-format change that any future consumer would have to cope with. Bundle with the `schema_version` key (EW1) if you want to make a clean v2 cut.
  - Sources: standard-claude (#14), critical-claude (Nit / Potential #12).

- **S7: `parseUncleanExitFile` returns a `HealthEvent` row with `"? (?) ????????"` summary when JSON body is unparseable.**
  - Why deferred: design choice (intentionally surfaces presence of corrupt files).
  - Summary: standard-claude (#12) and critical-claude (Potential #16) note the placeholder. The current behavior is "filename is source of truth for timestamp; corrupt body is intentionally surfaced rather than swallowed." This is correct for crash-survival reasoning, but the rendered output is ugly. Two options: (a) document the intent in a code comment so a future maintainer doesn't "fix" it; (b) replace `"????????"` with `"unknown"` to make the row more legible. Either is fine; needs a call.
  - Sources: standard-claude (#12), critical-claude (Potential #16).

## Evolutionary worth considering (do not apply silently)

- **E1: Promote scanners to a `HealthRail` registry.**
  - Summary: All four scanners share the same `(home, since) -> [HealthEvent]` shape; the dispatcher, help text, JSON `railCounts`, error messages, and warning wiring all enumerate the four rails by name across multiple files. Adding a fifth rail today is ~8 edits in 3 files. A small registry (a struct or a function table mapping `HealthEvent.Rail` to its scanner and optional warning contributor) collapses this to "write one struct, register it." 80-line refactor, no behavior change, dramatically reduces the cost of every future rail.
  - Why worth a look: the value of `c11 health` compounds with every additional rail (workspace snapshot lifecycle, agent crash JSONs, spindump artifacts, log-show queries). The registry investment pays back the first time a fifth rail lands.
  - Sources: evolutionary-claude (Concrete suggestion #3, Leverage point #1), evolutionary-codex (Concrete suggestion #2).

- **E2: Introduce a `HealthReport` value (`window`, `rails`, `events`, `warnings`) consumed by both renderers.**
  - Summary: Today `runHealth` separately constructs the window, rails, events, and warnings, then passes only `events` and `warnings` to `renderHealthTable` while passing all four to `renderHealthJSON`. This is the structural reason behind I3 (the empty-result line lies about rails) and the asymmetry between the two renderers. Promoting a `HealthReport` value with `window`, `rails`, `events`, `warnings` and rendering both table and JSON from it gives both surfaces the same context, lets the table render an honest empty-state line for free, and prepares for a future `--brief` mode or correlation features.
  - Why worth a look: this is the cleanest fix for I3, but doing it as a refactor instead of a point-fix is a v1.1 design pass that the user should sign off on before it lands as part of this PR.
  - Sources: evolutionary-codex (Concrete suggestion #1, Leverage point #1), evolutionary-claude (Mutation list, indirect).

- **E3: Surface `home` as a `--home <path>` CLI flag for fleet/snapshot use cases.**
  - Summary: `collectHealthEvents` already takes `home` as a parameter (the runtime test exercises it). Surfacing a `--home <path>` flag turns `c11 health` into a fleet-mode tool: `c11 health --home /Volumes/c11-fleet/atin-imac/2026-05-03 --since-boot` works on rsynced snapshots without code change. There is a privacy/safety dimension (clearly document that nothing is sent anywhere, the read is purely local), and `--since-boot` semantics need a call (target machine's boot time is not in the snapshot).
  - Why worth a look: high-leverage, low-cost feature that extends the use case from "one machine" to "any disk image of one or more machines" with no architectural change. Aligned with the deferred v1.1 list.
  - Sources: evolutionary-claude (Evolution #5, Concrete suggestion #7), evolutionary-gemini (Wild ideas).
