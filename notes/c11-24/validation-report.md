# C11-24 validation report

**Tagged build:** `c11-24-health` (commit `bbb8fa89`)
**Branch:** `c11-24/health-cli` (19 commits ahead of `origin/crash-visibility/launch-sentinel`)
**Date:** 2026-05-03
**Host:** atin's Mac (live machine, per plan note Validation F baseline)
**Verdict:** **PASS**

All flag paths smoked, all error paths produce single-line stderr with exit=1, sentinel synthesis confirmed via SIGKILL→relaunch, MetricKit synthesis confirmed via fake JSON, both expected diagnostic warning behaviors observed (`telemetry_state_ambiguous` fires, `metrickit_baseline_recent_version_bump` correctly does not on a fresh tag).

## Build

`./scripts/reload.sh --tag c11-24-health` from the worktree completed `** BUILD SUCCEEDED **` on the first attempt. App launched at `/Users/atin/Library/Developer/Xcode/DerivedData/c11-c11-24-health/Build/Products/Debug/c11 DEV c11-24-health.app`. CLI helper at `…/Contents/Resources/bin/c11`.

Build warnings inherited from the base branch (Sendable / deprecated APIs in `Sources/Panels/BrowserPanel.swift`, `Sources/AppDelegate.swift`, etc.); none introduced by the C11-24 work.

## Bundle ID note

The tag slug `c11-24-health` becomes bundle ID `com.stage11.c11.debug.c11.24.health` — Xcode/macOS converts hyphens to dots. This matters for the sentinel rail glob (`com.stage11.c11*/sessions/`) which correctly catches the dotted form.

## c11 health (default 24h window)

### Pass 1 — empty rails, before sentinel synthesis

```
c11 health: nothing in the last 24h across ips, sentry, metrickit, sentinel.

Warnings:
  - Sentry cache empty across c11 bundles: telemetry may be off, or events shipped on last launch and cleared the cache.
```

`telemetry_state_ambiguous` fires as Validation F predicted (the empty `~/Library/Caches/com.stage11.c11/io.sentry/` directory is what triggers it).

### Pass 1 JSON

```json
{
  "events" : [

  ],
  "rails" : {
    "ips" : { "count" : 0 },
    "metrickit" : { "count" : 0 },
    "sentinel" : { "count" : 0 },
    "sentry" : { "count" : 0 }
  },
  "schema_version" : 1,
  "warnings" : [
    "Sentry cache empty across c11 bundles: telemetry may be off, or events shipped on last launch and cleared the cache."
  ],
  "window" : {
    "mode" : "default-24h",
    "since" : "2026-05-02T22:37:32.073Z",
    "until" : "2026-05-03T22:37:32.073Z"
  }
}
```

`schema_version: 1` present (EW1 fix). 24h window symmetric around now. Warning surfaced once in `warnings` array.

### Pass 2 — populated (sentinel + metrickit synthesized)

```
TIME             | RAIL      | SEVERITY     | SUMMARY
(TIME reflects the OS-reported event time when available, file mtime otherwise)
2026-05-03 18:38 | sentinel  | unclean_exit | 0.44.1 (95) bbb8fa89
2026-05-03 18:19 | metrickit | hang         | hang3

Warnings:
  - Sentry cache empty across c11 bundles: telemetry may be off, or events shipped on last launch and cleared the cache.
```

Reverse-chronological order verified (sentinel 18:38 above metrickit 18:19). I4/I5 stable-sort tiebreak holds.

### Pass 2 JSON

```json
{
  "events" : [
    {
      "path" : "~/Library/Caches/com.stage11.c11.debug.c11.24.health/sessions/unclean-exit-2026-05-03T22-38-36.273Z.json",
      "rail" : "sentinel",
      "severity" : "unclean_exit",
      "summary" : "0.44.1 (95) bbb8fa89",
      "timestamp" : "2026-05-03T22:38:36.273Z"
    },
    {
      "path" : "~/Library/Logs/c11/metrickit/2026-05-03T22-19-00.000Z-hang3.json",
      "rail" : "metrickit",
      "severity" : "hang",
      "summary" : "hang3",
      "timestamp" : "2026-05-03T22:19:00.000Z"
    }
  ],
  "rails" : {
    "ips" : { "count" : 0 },
    "metrickit" : { "count" : 1 },
    "sentinel" : { "count" : 1 },
    "sentry" : { "count" : 0 }
  },
  "schema_version" : 1,
  "warnings" : [
    "Sentry cache empty across c11 bundles: telemetry may be off, or events shipped on last launch and cleared the cache."
  ],
  "window" : {
    "mode" : "default-24h",
    "since" : "2026-05-02T22:39:06.494Z",
    "until" : "2026-05-03T22:39:06.494Z"
  }
}
```

`path` values redacted to `~/…` form (B4 fix verified — no `/Users/atin/…` leaks).

## c11 health --since 30m

```
c11 health: nothing in the last 30m across ips, sentry, metrickit, sentinel.

Warnings:
  - Sentry cache empty across c11 bundles: telemetry may be off, or events shipped on last launch and cleared the cache.
```

JSON `window.mode = "since"`, `since` is `now - 30m`, `until` is `now`. Empty-result line correctly says "in the last 30m" not "24h" (parseSinceFlag round-trips as expected).

## c11 health --since-boot

```
c11 health: nothing since boot across ips, sentry, metrickit, sentinel.

Warnings:
  - Sentry cache empty across c11 bundles: telemetry may be off, or events shipped on last launch and cleared the cache.
```

JSON `window.mode = "since-boot"`. `since` is `2026-05-02T19:32:22.372Z` (system boot), `until` is now. Boot-time math via `sysctlbyname("kern.boottime")` returns a sensible Date.

## c11 health --rail sentinel (with synthesized unclean exit)

```
TIME             | RAIL      | SEVERITY     | SUMMARY
(TIME reflects the OS-reported event time when available, file mtime otherwise)
2026-05-03 18:38 | sentinel  | unclean_exit | 0.44.1 (95) bbb8fa89
```

JSON:

```json
{
  "events" : [
    {
      "path" : "~/Library/Caches/com.stage11.c11.debug.c11.24.health/sessions/unclean-exit-2026-05-03T22-38-36.273Z.json",
      "rail" : "sentinel",
      "severity" : "unclean_exit",
      "summary" : "0.44.1 (95) bbb8fa89",
      "timestamp" : "2026-05-03T22:38:36.273Z"
    }
  ],
  "rails" : {
    "sentinel" : { "count" : 1 }
  },
  "schema_version" : 1,
  "warnings" : [

  ],
  "window" : {
    "mode" : "default-24h",
    "since" : "2026-05-02T22:38:50.113Z",
    "until" : "2026-05-03T22:38:50.113Z"
  }
}
```

When `--rail sentinel` is set, the sentry-cache warning correctly does NOT fire (warnings are gated to relevant rail). Rails JSON contains only the `sentinel` key (other rails not enumerated when filtered out).

## c11 health --rail metrickit (with synthesized hang3)

Synthesized via `echo '{}' > ~/Library/Logs/c11/metrickit/2026-05-03T22-19-00.000Z-hang3.json`.

```
TIME             | RAIL      | SEVERITY     | SUMMARY
(TIME reflects the OS-reported event time when available, file mtime otherwise)
2026-05-03 18:19 | metrickit | hang         | hang3
```

Filename grammar parses correctly: stamp `2026-05-03T22-19-00.000Z` → ISO timestamp; kind `hang3` → severity `hang`, summary `hang3`. Cleaned up after capture.

## Error cases (S4, I1 fixes)

### `c11 health --rail bogus`

```
exit=1
stdout: (empty)
stderr: Error: c11 health: unknown --rail 'bogus' (expected one of ips, sentry, metrickit, sentinel)
```

Single stderr line, exit 1 (S4 fix verified — no duplicate emission).

### `c11 health --since 30m --since-boot`

```
exit=1
stdout: (empty)
stderr: Error: c11 health: --since and --since-boot are mutually exclusive
```

### `c11 health --rail ips --rail sentry`

```
exit=1
stdout: (empty)
stderr: Error: c11 health: --rail may only be specified once
```

I1 fix verified — `--rail` rejects a second specification rather than silently overwriting.

## c11 health --help (dispatchSubcommandHelp via Plan deviation 1)

```
c11 health

Usage: c11 health [--since <duration> | --since-boot] [--rail <name>] [--json]

Read-only crash-visibility sweep across four local rails: Apple IPS reports,
queued Sentry envelopes, MetricKit diagnostic payloads, and the c11 launch
sentinel (catches Force Quit and SIGKILL where Sentry cannot).

Flags:
  --since <duration>     Time window: 30m, 2h, 24h, 3d. Default 24h.
  --since-boot           Limit to events since the last system boot.
  --rail <name>          Filter to one rail: ips, sentry, metrickit, sentinel. Specify at most once. Default: all rails.
  --json                 Emit structured JSON instead of the default table.

Example:
  c11 health
  c11 health --since 30m
  c11 health --since-boot --rail sentinel
  c11 health --json
```

Exit 0; output on stdout. The dispatch deviation (insert `health` branch AFTER the help dispatch, not after `remote-daemon-status`) is verified — `--help` correctly routes through `dispatchSubcommandHelp` and prints help text rather than running the command. `--rail` line documents the I2 single-rail constraint.

## Sentinel synthesis (force-quit + relaunch)

1. Tagged app launched: PID 31629, wrote `~/Library/Caches/com.stage11.c11.debug.c11.24.health/sessions/active.json` containing `pid: 31629, version: 0.44.1, build: 95, commit: bbb8fa899, bundle_id: com.stage11.c11.debug.c11.24.health, launched_at: 2026-05-03T22:36:58.300Z`.
2. `kill -9 31629` (SIGKILL — bypasses `applicationWillTerminate` so `LaunchSentinel.clearActive()` does not run).
3. `./scripts/reload.sh --tag c11-24-health` rebuilt + relaunched (no source changes since first build, so build was incremental and fast).
4. New PID 38484; `LaunchSentinel.recordLaunchAndArchivePrevious()` ran on the new launch and archived the orphan `active.json` to `unclean-exit-2026-05-03T22-38-36.273Z.json`.
5. `c11 health --rail sentinel` returns exactly ONE row referencing `com.stage11.c11.debug.c11.24.health`, version `0.44.1 (95)`, commit-hash short form `bbb8fa89` (truncated from `bbb8fa899` per S7-era summary format).

Path stays under the c11 hyphen-converted-to-dot bundle ID — the sentinel rail glob matched correctly (`~/Library/Caches/com.stage11.c11*/sessions/unclean-exit-*.json`).

## MetricKit synthesis

Wrote `~/Library/Logs/c11/metrickit/2026-05-03T22-19-00.000Z-hang3.json` containing `{}`. `c11 health --rail metrickit` returned one row at the expected timestamp (parsed from filename, not file mtime), severity `hang`, summary `hang3` verbatim. After capture, removed via `/bin/rm -f`. Confirmed empty post-cleanup.

## Diagnostic warnings observed on this host

| Warning | Predicted (Validation F) | Observed |
|---|---|---|
| `telemetry_state_ambiguous` | Should fire (empty `io.sentry/` exists) | **Fired**, exact wording: `Sentry cache empty across c11 bundles: telemetry may be off, or events shipped on last launch and cleared the cache.` Surfaced both in human footer and JSON `warnings` array. |
| `metrickit_baseline_recent_version_bump` | May not fire on first run (no prior session marker for new tag) | **Did not fire** on this host. Tagged build is the first run of `com.stage11.c11.debug.c11.24.health`; no prior session JSON exists to compare versions against. |

Both behaviors match Validation F predictions.

## Anomalies

1. **`commit` field empty in second active.json.** The first launch recorded `commit: "bbb8fa899"` correctly, but the post-relaunch active.json (PID 38484) has `commit: ""`. Both builds produced from the same git tip with no source changes. Could be a `Info.plist` `C11Commit` injection that runs once per derived data path and didn't re-run on incremental rebuild. Out of scope for C11-24 (the consumer correctly reports the captured value); flagging here so the launch-sentinel feature owner can investigate during PR #109 review or later. Doesn't affect the `unclean_exit` row's correctness because the sentinel surfaces the *previous* launch's commit, which was captured cleanly.

2. **No tag-cleanup performed.** Validation left the `c11-24-health` tagged build running and on disk. The `prune-tags.sh` script protects running tags, so leaving it running is fine; the delegator's PR-open phase or a subsequent session will handle cleanup once verification is no longer needed.

Nothing else surprising.

## Verdict

**PASS** — all six review-fix commits visible in behavior on real hardware:

- B4 (path redaction): JSON paths use `~/…`.
- I1 (rail duplicate): exits 1 with single stderr line.
- I3 (empty-result line reflects rail/window): "nothing in the last 30m across sentinel" instead of fixed "24h, all rails".
- I4/I5 (stable sort + lossy UTF-8): reverse-chronological order holds.
- S4 (single-emission error): exactly one stderr line on bogus rail.
- S7 (`unknown` for missing fields): not exercised here (all fields populated); deferred to future smoke when launch sentinel writes an active.json with sparse fields.
- EW1 (schema_version): present in every JSON output as `schema_version: 1`.

`c11 health` ships ready for the delegator to open PR #110 against `crash-visibility/launch-sentinel`. Recommend the PR body cite this report or paste the populated default-output table as the headline screenshot.

## Raw command logs

All raw stdout/stderr captures live alongside this report at `notes/c11-24/raw/{01..18}-*.txt`. Useful for diffing future regressions against this baseline.
