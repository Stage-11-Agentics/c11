## Critical Code Review
- **Date:** 2026-04-27T01:07:00Z
- **Model:** Claude Sonnet 4.6 (claude-sonnet-4-6)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6ed68713
- **Linear Story:** C11-23
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

This is a third-pass review of a credential-free local data reader, and the architecture is sound. Replacing remote API calls with local file/SQLite reads was the right call — it eliminates auth complexity, removes billing-endpoint exposure, and makes both providers work offline. The prior fixes (B1 Keychain-first remove, B2 ghost task guard, I1-I4) are all still intact and correctly implemented.

That said, there are two genuine blockers and several important issues that need fixing before this ships. The blockers are not exotic edge cases — they are "normal user on a normal machine" scenarios that will produce wrong behavior for a meaningful percentage of users from day one. One will silently zero out all Codex data for everyone whose Codex CLI writes timestamps in milliseconds. The other blocks the main thread during JSONL I/O on every 60-second poll tick, guaranteed, for every user with a large Claude project history.

The docs issue is real and will confuse users who hit problems, because the troubleshooting section gives them instructions that no longer apply.

---

## What Will Break

**B1 — SQLite timestamp epoch units (CodexLocalUsageFetcher.swift:109)**

`Date(timeIntervalSince1970: Double(ts))` assumes `created_at` is stored as Unix epoch seconds. The Codex CLI is a Node.js/TypeScript application. Node.js's `Date.now()`, `new Date().getTime()`, and most JS SQLite libraries store timestamps as milliseconds since epoch — not seconds. A `ts` value of `1745700000000` (milliseconds) passed to `timeIntervalSince1970` produces a date in the year 57,285. That entry fails the session/week window filter (it's in the future by ~55k years) and is silently discarded. Result: every Codex user whose DB was written by JS code sees zero tokens, zero cost, zero utilization. No error is logged. No error is shown. It just reads as empty.

The fix is one line: check the magnitude of `ts` and divide by 1000.0 if `ts > 1e10`. This is a blocker.

**B2 — Synchronous blocking I/O on the main thread (CodexLocalUsageFetcher.swift:83-114, ClaudeLocalUsageFetcher.swift:67-122)**

`CodexLocalUsageFetcher.allEntries()` is a synchronous throwing function. It is called directly from `fetchUsage(account:)` at line 37: `let entries = try allEntries()`. `fetchUsage` is `async throws` but the synchronous `allEntries()` call is NOT awaited across a suspension point — it runs inline on the calling thread/actor. The caller, `AIUsagePoller`, is `@MainActor`. This means every 60-second tick blocks the main thread for the duration of the SQLite open, prepare, step, and close sequence. On a slow disk or an I/O-saturated machine this could be tens to hundreds of milliseconds, causing visible frame drops and UI jank.

`ClaudeLocalUsageFetcher.allEntries()` is `async throws` but uses synchronous APIs throughout: `FileManager.default.fileExists`, `FileManager.default.enumerator`, and `String(contentsOf:file, encoding:.utf8)`. The `async` keyword does not move work off the main thread — it only allows suspension points. Since there are no `await` calls inside `allEntries()`, the entire function body runs synchronously on the `@MainActor`. For a user with 50 JSONL files totaling 100MB of conversation history, this is a guaranteed main-thread stall of multiple seconds every 60 ticks.

Both need to be dispatched to a background actor or `Task.detached` context. This is a blocker.

---

## What's Missing

**Stale troubleshooting docs (docs/ai-usage-monitoring.md:91-94)**

The Troubleshooting section still reads:

```
- **401 / 403:** the sign-in expired. Open the editor and paste a fresh credential.
- **Codex returns 404:** the token does not have access to the WHAM endpoint (no Codex subscription).
```

Neither Claude nor Codex makes network calls for usage data anymore. Neither has credentials. A user seeing unexpected empty data will read this, look for a credential to refresh, find there is none, and give up. The 401/403 and 404 guidance is not just unhelpful — it actively misdirects. It needs to be replaced with actionable local-reader troubleshooting: "If usage shows zero, check that `~/.claude/projects/` contains `.jsonl` files" and "If Codex shows zero, verify `~/.codex/state_5.sqlite` exists and is non-empty."

**`gpt-4o-mini` cost misclassification (CodexLocalUsageFetcher.swift:121-122)**

`hasPrefix("gpt-4o")` matches both `gpt-4o` and `gpt-4o-mini`. The mini model runs at roughly $0.15/$0.60 per million tokens (input/output) — about 6-8x cheaper than gpt-4o at $5.00 blended. Any user running gpt-4o-mini as their Codex model will see cost estimates inflated by ~6-8x. The fix is to check `hasPrefix("gpt-4o-mini")` before `hasPrefix("gpt-4o")`.

**No streaming / chunked read for large JSONL files (ClaudeLocalUsageFetcher.swift:91-94)**

`String(contentsOf: file, encoding: .utf8)` reads the entire file into a single String allocation. A heavy Claude Code user can accumulate multi-MB JSONL files per project. With many projects, the total in-memory allocation during a single `allEntries()` call can reach hundreds of MB — all on the main thread (see B2 above), all at once, with no backpressure. The correct approach is line-by-line streaming using `FileHandle`/`AsyncBytes` or at minimum a `Data` read with a rolling line scanner. Not a crash risk in most cases, but a memory spike that the system will notice.

**`ISO8601DateFormatter` recreated per poll tick, not per file (ClaudeLocalUsageFetcher.swift:86)**

`let iso = ISO8601DateFormatter()` is created once per `allEntries()` call. `ISO8601DateFormatter` is an expensive object to initialize (it wraps `NSDateFormatter` which loads ICU locale data). Across a 60-second polling loop with many JSONL files, this is recreated every tick. It should be a `static let` on the type.

**Week window `resetsAt` is not computed for Codex (CodexLocalUsageFetcher.swift:73-79)**

Both fetchers set `weekWindow.resetsAt = nil`. For Claude, the session `resetsAt` is computed from `sessionEntries.first`. For the week window, `resetsAt` is left nil. This is a UI gap: if the user cares about their 7-day reset, the display shows nothing. Not a correctness bug, but a feature gap that users will notice.

**Auto-registration persists even when the local directory/DB is later deleted**

`load()` registers accounts when the local path exists. But `pruneOrphanAccountsIfNeeded()` only prunes accounts whose Keychain item is missing — credential-free accounts are explicitly skipped at line 214: `if provider?.credentialFields.isEmpty == true { continue }`. If a user uninstalls Codex or removes `~/.claude/projects/`, the auto-registered account persists in UserDefaults forever, showing "Could not fetch" errors on every tick. There is no cleanup path for stale credential-free accounts. Users will need to manually remove them, and there is nothing in the UI or docs telling them this.

---

## The Nits

**`CodexAIUsageFetchError.network` is a semantic lie**

The error case is named `network` and the error type is named `CodexAIUsageFetchError`. Since Codex no longer uses a network call, `.network` now means "local database not found or unreadable." Callers inspecting the error type will be misled. Should be `.databaseUnavailable` or `.localReadFailed`. This is cosmetic but it will confuse the next engineer who touches this code.

**`allEntries()` on Codex is not `async` but `fetchUsage` is (CodexLocalUsageFetcher.swift:37, 83)**

The `async` on `fetchUsage` serves no purpose — there are no `await` calls inside it. Its only function is to satisfy the `fetchUsage: (AIUsageAccount, AIUsageSecret) async throws -> AIUsageWindows` provider closure signature. This is fine for API conformance but the `async` keyword creates a false impression that the work is off-actor. A comment explaining why it's synchronous under the hood would help.

**`SQLITE_OPEN_NOMUTEX` with `SQLITE_OPEN_READONLY` is redundant**

`SQLITE_OPEN_READONLY` already implies single-connection non-writing access. WAL mode works fine without `NOMUTEX` for a read-only connection because the WAL reader lock is acquired at the pager level, not the mutex level. `NOMUTEX` disables the per-connection mutex, which is only meaningful in a multi-threaded SQLite usage scenario. Since this connection is opened and closed synchronously within a single call, the flag has no practical effect. Remove it to avoid implying thread-safety properties that aren't being relied upon.

**`cost(for:)` uses `contains` for Claude but `hasPrefix` for Codex — inconsistent**

Claude's `cost(for:)` uses `model.contains("opus-4")` and `model.contains("haiku-4")`. Codex uses `model.hasPrefix("gpt-5.5")`. If Anthropic releases a model like `claude-opus-4-5-turbo`, `contains("opus-4")` still matches. If OpenAI releases something like `extended-gpt-4o`, `hasPrefix("gpt-4o")` would miss it. The matching strategies should be consistent and their assumptions documented.

---

## Numbered Findings

### Blockers

**1. SQLite timestamp epoch units — all Codex data silently zeroed for JS-originated DBs** ✅ Confirmed

`CodexLocalUsageFetcher.allEntries()` line 109: `Date(timeIntervalSince1970: Double(ts))` where `ts = sqlite3_column_int64(stmt, 0)`. The Codex CLI is Node.js. `Date.now()` in Node returns milliseconds. If `state_5.sqlite` was created by the Codex CLI (the only source of truth here), timestamps are almost certainly milliseconds. A value of `1745700000000` ms = year 57,285. The window filter at lines 43-44 compares against `now.addingTimeInterval(-18000)` (≈ year 2026). All entries with millisecond timestamps are in the "future" relative to a 5-hour window and are discarded. Result: `sessionEntries = []`, `weekEntries = []`, all counts zero, no error reported.

To confirm: open `~/.codex/state_5.sqlite` in any SQLite browser and inspect `created_at` values. Values > 1e12 are milliseconds.

**2. Main-thread blocking I/O on every 60-second poll tick** ✅ Confirmed

`AIUsagePoller` is `@MainActor`. `runTick` calls `provider.fetchUsage(account, secret)` at line 198, which resolves to `ClaudeLocalUsageFetcher.fetchUsage` or `CodexLocalUsageFetcher.fetchUsage`. Neither dispatches I/O to a background thread. `async` without `await` does not hop threads.

For Claude: `String(contentsOf: file, encoding: .utf8)` at line 91 is a synchronous blocking read. The `@MainActor` poller awaits the `async fetchUsage` but since `allEntries` has no suspension points, it runs entirely on the main thread before returning.

For Codex: `allEntries()` is not even `async` — it is a synchronous function called inline (`let entries = try allEntries()`).

Both will produce UI jank on any machine with a slow disk or large project history. The fix is to wrap the synchronous I/O in `Task.detached` or a dedicated background actor with `await`.

### Important

**3. `gpt-4o-mini` classified as `gpt-4o` — cost estimates inflated 6-8x** ✅ Confirmed

`CodexLocalUsageFetcher.cost(for:)` line 121: `model.hasPrefix("gpt-4o")` matches `gpt-4o-mini` because `"gpt-4o-mini".hasPrefix("gpt-4o")` is `true`. `gpt-4o-mini` is billed at approximately $0.15/$0.60 per million tokens (input/output). The matched rate of $5.00 blended is ~6-8x higher. Any user whose Codex sessions use `gpt-4o-mini` (a popular cost-saving choice) will see inflated cost estimates. Fix: add `model.hasPrefix("gpt-4o-mini")` as the first branch.

**4. Stale troubleshooting docs actively misdirect users** ✅ Confirmed

`docs/ai-usage-monitoring.md` lines 91-94 instruct users to "paste a fresh credential" on 401/403, and describe a "WHAM endpoint" on 404. Neither error type is possible for local-only providers — there is no network call, no auth header, no endpoint. A user seeing zero data (e.g., from issue B1) will follow this guidance, find no credential to paste, and conclude the feature is broken. Replace with local-reader troubleshooting: check for JSONL files, check SQLite file existence, check for permission errors.

**5. No cleanup of stale credential-free auto-registered accounts** ❓ Likely but hard to verify

`pruneOrphanAccountsIfNeeded()` skips credential-free accounts at line 214. If a user deletes `~/.claude/projects/` or `~/.codex/state_5.sqlite`, the auto-registered account persists in UserDefaults. On every subsequent poll tick, the fetcher opens a nonexistent path, throws `.network`, and the UI displays "Codex local database not found or unreadable" indefinitely. The user has no UI-surfaced way to know this requires a manual remove. Not data loss, but a persistent error state with no self-healing path.

### Potential

**6. `ISO8601DateFormatter` recreated on every poll tick**

`ClaudeLocalUsageFetcher.allEntries()` line 86 creates a new `ISO8601DateFormatter` on every call. This is an expensive allocation. Should be `private static let iso = ISO8601DateFormatter()`.

**7. `CodexAIUsageFetchError.network` semantic mismatch**

The case name implies a network failure. It now covers local database unavailability. Next engineer to see a `.network` thrown from a credential-free local reader will spend time looking for a network call that doesn't exist. Rename to `.databaseUnavailable`.

**8. Full file load into memory for unbounded JSONL files**

`String(contentsOf: file, encoding: .utf8)` at line 91 loads the entire file. Large conversation histories produce large JSONL files. No size cap, no streaming. Not a crash risk for typical users but will cause memory pressure on machines already constrained. Consider a `FileHandle`-based line reader that processes one line at a time.

**9. Week window `resetsAt` is nil for both providers**

The week `AIUsageWindow` is constructed with `resetsAt: nil` in both fetchers. If the UI has a display path for "resets in X days" on the week row, it will always show nothing. Not currently a regression if the UI never showed it, but worth noting as a gap.

**10. `async` on `CodexLocalUsageFetcher.fetchUsage` creates false impression of off-main execution**

The function signature is `async throws` but the body calls the synchronous `allEntries()` inline with no `await`. The `async` label will mislead readers into thinking work is dispatched. Add a comment or — better — fix B2 and make it actually async.

---

## Closing

**Is this code ready for production? No.**

Deploy this to 100k users today and you get:

1. Every Codex user with a JS-originated SQLite database (i.e., every Codex user, since the CLI is Node.js) sees zero usage data, zero cost, zero utilization. Silent. No error. They think the feature is broken.

2. Every Claude user with a large project history stalls the main thread for potentially several seconds every 60 ticks. On slow disks or I/O-saturated machines, this is noticeable UI freeze.

3. Any user whose Codex uses `gpt-4o-mini` sees cost estimates 6-8x too high.

4. Users who try to troubleshoot will read guidance that describes network auth errors that cannot happen with this architecture.

The architectural direction — local reads, no credentials, no remote billing APIs — is correct and solid. The prior fixes are intact. The code structure is clean. But the timestamp unit assumption (B1) and the main-thread I/O (B2) need to land before this ships. The `gpt-4o-mini` cost bug (Important #3) and the docs staleness (Important #4) should ship in the same PR. The rest can follow.

Fix B1, B2, Important #3, and Important #4 first. Then ship.
