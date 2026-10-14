## Critical Code Review
- **Date:** 2026-04-27T05:19:41Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6ed68713d5cd20a1026b6225fb285b2210a43787
- **Linear Story:** C11-23
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

The local-reader direction is right, but this branch is not in a shippable state. The most serious problem is not subtle: the unit tests are stale against the credential-free architecture and the Codex legacy fetcher is not even in the app target anymore, while tests still reference it. CI will not protect this feature because the suite is currently broken by the migration itself.

On the product side, the Claude local fetcher will silently skip normal fractional-second ISO timestamps. That is exactly the kind of bug that makes a local usage panel look "empty" while everything appears healthy. The Codex SQLite reader is also too trusting of schema details: timestamp units and `sqlite3_step` failures are not validated, so bad reads degrade into convincing but wrong usage numbers.

The privacy cleanup is incomplete. The docs say local-only usage, but the app target still compiles the legacy Claude network fetcher containing the `claude.ai` usage endpoint. Even if it is currently unreferenced, shipping dead network code in the binary is not a clean removal.

## What Will Break

- CI/unit validation breaks because [c11Tests/AIUsageTests.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:543) still references `CodexAIUsageFetcher`, while [GhosttyTabs.xcodeproj/project.pbxproj](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/GhosttyTabs.xcodeproj/project.pbxproj:1137) includes `CodexLocalUsageFetcher.swift` but not `CodexAIUsageFetcher.swift` in the app target sources. The same test file still expects Claude/Codex providers to have credentials and to round-trip Keychain secrets, which is now false by design.
- Claude usage shows zero when JSONL timestamps include fractional seconds. [ClaudeLocalUsageFetcher.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:86) uses a plain `ISO8601DateFormatter`; that formatter rejects `2026-04-26T12:34:56.789Z`, while the project already has [AIUsageISO8601DateParser.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageISO8601DateParser.swift:7) specifically to handle fractional seconds.
- Codex usage can be wildly wrong if `threads.created_at` is milliseconds instead of seconds. [CodexLocalUsageFetcher.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:108) blindly passes the integer to `Date(timeIntervalSince1970:)`. Millisecond values become dates tens of thousands of years in the future, so entries never age out of the session/week filters.
- SQLite read errors after prepare are ignored. [CodexLocalUsageFetcher.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:101) loops only while `sqlite3_step` returns `SQLITE_ROW`, then returns whatever was accumulated. `SQLITE_BUSY`, `SQLITE_IOERR`, and `SQLITE_CORRUPT` all collapse into partial or empty usage with no error.
- Heavy Claude users get repeated memory spikes because [ClaudeLocalUsageFetcher.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:92) reads each JSONL file into one `String` and [line 96](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:96) splits the whole file into an array of lines. This is the target user base: lots of agents, lots of logs.

## What's Missing

- Local fetcher tests. There are no tests for fractional Claude timestamps, malformed JSONL lines, large-file behavior, Codex timestamp unit normalization, SQLite step failures, or missing local data paths.
- Updated account-store tests for credential-free providers. The current tests still assume Claude and Codex require Keychain credentials.
- A privacy cleanup pass that removes or excludes the legacy Claude usage endpoint from the shipped target.
- Local-reader troubleshooting docs. [docs/ai-usage-monitoring.md](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/docs/ai-usage-monitoring.md:91) still tells users to refresh credentials and references the old Codex WHAM endpoint.
- Validation of Codex schema assumptions. The SQL query assumes a `threads(created_at, model, tokens_used)` schema and a specific epoch unit, but the code does not assert or document that contract.

## The Nits

- `CodexAIUsageFetchError.network` in [CodexLocalUsageFetcher.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:5) now means "local database unavailable." The name sends maintainers looking for a network path that no longer exists.
- [AIUsageEditorSheet.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/UI/AIUsageEditorSheet.swift:195) accepts negative token limits and silently treats them like zero later. That will not crash, but it is sloppy input handling.
- [AIUsageAccountStore.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageAccountStore.swift:189) silently drops auto-registration persistence failures. That is probably acceptable for UserDefaults, but it makes duplicate/reappearing auto-registration behavior hard to diagnose.
- [ClaudeLocalUsageFetcher.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:86) recreates a date formatter per poll. Not the biggest problem here, but unnecessary.

## Numbered Findings

### Blockers

1. **The AI usage tests are stale and cannot validate this branch** ✅ Confirmed

   The test target still references removed/untargeted remote Codex code: [c11Tests/AIUsageTests.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:283) uses `CodexAIValidators`, and [line 543](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:543) uses `CodexAIUsageFetcher.parseWindow`. In the project file, `CodexAIUsageFetcher.swift` is only a file reference at [line 571](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/GhosttyTabs.xcodeproj/project.pbxproj:571); it is absent from the app target source list at [line 1137](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/GhosttyTabs.xcodeproj/project.pbxproj:1137).

   The tests also assert old credential behavior: [line 54](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:54) adds a Claude secret and [line 58](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:58) expects to load it from Keychain, but [ClaudeAIProvider.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeAIProvider.swift:8) now declares `credentialFields: []`, so [AIUsageAccountStore.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageAccountStore.swift:55) intentionally skips Keychain. Registry assertions at [c11Tests/AIUsageTests.swift:271](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:271), [426](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:426), and [436](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:436) also require non-empty credential fields.

   This is a blocker because the branch's test suite is no longer aligned with the architecture. I did not run the tests locally per project policy, but the references and assertions are enough to prove failure.

2. **Claude JSONL parsing rejects fractional-second timestamps and silently drops usage** ✅ Confirmed

   [ClaudeLocalUsageFetcher.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:86) creates a default `ISO8601DateFormatter`, and [line 108](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:108) requires it to parse the JSONL timestamp. I verified with a Swift one-liner that this formatter returns `nil` for `2026-04-26T12:34:56.789Z` and parses `2026-04-26T12:34:56Z`. The repository already has [AIUsageISO8601DateParser.parse](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageISO8601DateParser.swift:4), which tries fractional seconds first and plain ISO second.

   Execution path: `AIUsagePoller.runTick` calls the Claude provider at [AIUsagePoller.swift:198](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsagePoller.swift:198), [ClaudeAIProvider.swift:16](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeAIProvider.swift:16) calls the local fetcher, and each fractional timestamp line falls through the guard at [ClaudeLocalUsageFetcher.swift:103](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:103). The UI then shows empty or undercounted usage with no error.

3. **The shipped target still includes the legacy Claude remote usage endpoint** ✅ Confirmed

   [docs/privacy-endpoints.md](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/docs/privacy-endpoints.md:16) says Claude usage is local-only and no network call is made. But [GhosttyTabs.xcodeproj/project.pbxproj](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/GhosttyTabs.xcodeproj/project.pbxproj:1137) still includes `ClaudeAIUsageFetcher.swift in Sources`, and that file still constructs `https://claude.ai/api/organizations/.../usage` at [ClaudeAIUsageFetcher.swift:115](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeAIUsageFetcher.swift:115).

   It is not wired through `Providers.claude` today, so I am not claiming the sidebar currently calls it. The blocker is the privacy/removal claim: the remote usage endpoint was not removed from the shipped code. For a privacy endpoint audit, dead compiled network code is still a bad answer.

### Important

4. **Codex timestamp units are unvalidated, so session/window math can be wrong forever** ❓ Likely but hard to verify

   [CodexLocalUsageFetcher.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:102) reads `created_at` as an integer and [line 108](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:108) treats it as Unix seconds. If the Codex DB stores milliseconds, a 2026 timestamp becomes a date around year 57,000. Since [lines 43-44](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:43) only filter `timestamp >= cutoff`, future rows remain in both session and week windows indefinitely. Session totals become all-time totals, and `resetsAt` becomes a useless future date.

   This needs a magnitude check or a schema-backed proof with a test fixture. Without that, the UI can be confidently wrong.

5. **SQLite step errors collapse into partial success** ✅ Confirmed

   The loop at [CodexLocalUsageFetcher.swift:101](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:101) exits for anything other than `SQLITE_ROW`, and [line 113](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:113) returns `entries`. It never checks for `SQLITE_DONE` versus `SQLITE_BUSY`, `SQLITE_IOERR`, `SQLITE_CORRUPT`, or another failure. A live Codex process writing the DB, a transient I/O error, or a corrupt page can produce empty/partial usage with no user-visible error. The fix is to capture the final `sqlite3_step` result and throw unless it is `SQLITE_DONE`.

6. **Claude JSONL reader scales badly for the exact users c11 targets** ✅ Confirmed

   [ClaudeLocalUsageFetcher.swift:92](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:92) reads each file fully into memory, and [line 96](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:96) creates a second all-lines representation. A c11 operator running many agents can accumulate large `~/.claude/projects/**/*.jsonl` histories. Polling every minute means repeated full rescans and repeated peak allocations. Even if the current `TaskGroup` keeps this off the main actor in the sidebar path, it can still cause memory pressure and unnecessary disk churn.

7. **Troubleshooting docs describe the removed remote-auth design** ✅ Confirmed

   [docs/ai-usage-monitoring.md:91](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/docs/ai-usage-monitoring.md:91) still says `401 / 403` means the sign-in expired and tells the user to paste a fresh credential. [Line 93](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/docs/ai-usage-monitoring.md:93) still talks about the Codex WHAM endpoint. Neither applies to credential-free local readers. Users with empty local data, permission errors, or schema drift will follow instructions for a system that no longer exists.

8. **Open-failure SQLite handles are not closed** ✅ Confirmed

   [CodexLocalUsageFetcher.swift:87](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:87) declares `db`, and [line 88](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:88) throws immediately when `sqlite3_open_v2` fails. SQLite can still allocate a handle on failed open; the code only installs `defer { sqlite3_close(db) }` after success at [line 91](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:91). A manually added Codex account with a missing/unreadable DB can leak a handle every poll. Close `db` before throwing when it is non-nil.

### Potential

9. **Local-reader behavior has no direct regression coverage** ✅ Confirmed

   `rg` found no tests for `ClaudeLocalUsageFetcher` or `CodexLocalUsageFetcher` in [c11Tests/AIUsageTests.swift](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:1). The current tests cover the old remote Codex parser and old credential assumptions. Add fixtures for JSONL and SQLite rather than source-shape tests.

10. **Manual local account creation can create duplicates indefinitely** ⬇️ Real but lower priority than initially thought

   [AIUsageAccountStore.addLocalAccount](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageAccountStore.swift:72) always appends. The docs say multiple accounts per provider are allowed, so this is not automatically wrong. For local providers, though, every Claude account reads the same `~/.claude/projects` tree and every Codex account reads the same `~/.codex/state_5.sqlite`, so duplicates show the same usage repeatedly. At minimum, the UI should make that explicit or discourage duplicate local accounts.

11. **Cost estimates are under-specified for Codex model variants** ❓ Likely but hard to verify

   [CodexLocalUsageFetcher.cost](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:116) uses one blended rate per model prefix. That may be acceptable as an approximation, but docs do not clearly say the Codex cost is approximate and not billing-grade. This will matter when users compare the sidebar to real subscription/billing numbers.

## Closing

This is not ready for production, and I would not mass deploy it to 100k users.

The architecture is correct: local data, no credentials, no remote billing APIs. But the branch needs a cleanup pass before it is trustworthy: fix the stale tests, use the existing fractional ISO parser for Claude JSONL, remove or exclude the legacy Claude remote fetcher from the shipped target, validate Codex timestamp units, check SQLite step results, and replace the remote-auth troubleshooting docs with local-reader guidance.

After those are fixed, the remaining performance work is straightforward: stop full rescanning large JSONL files on every poll and add fixture-backed local fetcher tests.
