## Code Review
- **Date:** 2026-04-27T05:17:20Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6ed68713d5cd20a1026b6225fb285b2210a43787
- **Linear Story:** C11-23
---

Validation note: I did not run the local test suite. This is a Swift/XCTest project and the repo policy says tests run via CI/VM, not locally. `origin/dev` is not present in this checkout, so I reviewed against `origin/main...HEAD`; local `HEAD` matches `origin/c11-23-ai-usage-monitoring`. I also did not `git pull` because this prompt is explicitly read-only.

The architectural pivot is directionally right: usage data now comes from Claude Code JSONL and Codex's local SQLite database, with status-page polling as the only live network path. The poller flow is straightforward:

1. `AIUsageAccountStore.load()` reads saved accounts and auto-registers Claude/Codex if local artifacts exist.
2. `AIUsagePoller.runTick()` resolves each provider, bypasses Keychain for credential-free providers, and calls the provider fetcher.
3. `ClaudeLocalUsageFetcher` aggregates assistant JSONL entries over 5-hour and 7-day windows.
4. `CodexLocalUsageFetcher` aggregates `threads.tokens_used` over the same windows.
5. `AIUsageFooterView` renders either utilization bars or cost labels, then status incidents from the two allowlisted status hosts.

The main implementation still has a couple of merge-blocking issues. The biggest one is that the Claude local reader currently skips normal Claude Code log entries, so the new local Claude feature will silently report zero usage.

### Blockers

**1.** ✅ Confirmed — **Claude JSONL timestamps with fractional seconds are dropped, so Claude usage reads as empty.**

`Sources/AIUsage/ClaudeLocalUsageFetcher.swift:86` creates a default `ISO8601DateFormatter`, then `Sources/AIUsage/ClaudeLocalUsageFetcher.swift:107`-`108` requires it to parse each JSONL timestamp. Claude Code JSONL files in `~/.claude/projects/` use fractional seconds, e.g. `2026-01-11T20:50:39.428Z`. A default `ISO8601DateFormatter` does not parse that form unless `.withFractionalSeconds` is configured. I validated this with a Swift one-liner using a writable module cache: fractional input returned `nil`, while non-fractional input parsed.

This means valid assistant entries are skipped by the guard, `entries` stays empty, and users see zero tokens/cost/utilization even though local Claude logs exist. The repo already has `AIUsageISO8601DateParser.parse` and tests for fractional seconds at `c11Tests/AIUsageTests.swift:144`-`146`; the local reader should use that parser or equivalent dual-format parsing.

**2.** ✅ Confirmed — **The AI usage tests are stale/non-hermetic after the credential-free pivot and will not provide a valid CI signal.**

There are three independent problems in `c11Tests/AIUsageTests.swift`:

- `c11Tests/AIUsageTests.swift:533`-`588` still tests `CodexAIUsageFetcher`, but `Sources/AIUsage/CodexAIUsageFetcher.swift` is only a project file reference (`GhosttyTabs.xcodeproj/project.pbxproj:571`, `:716`) and is not in the app target's Sources list (`GhosttyTabs.xcodeproj/project.pbxproj:1137`). The test target imports `c11`, so these references should fail to compile unless the old remote fetcher is re-added.
- `c11Tests/AIUsageTests.swift:53`-`59` adds a Claude account through the credentialed `add(...)` path and then expects a Keychain secret. `Sources/AIUsage/ClaudeAIProvider.swift:8` now makes Claude credential-free, and `Sources/AIUsage/AIUsageAccountStore.swift:55`-`57` intentionally skips Keychain writes for credential-free providers, so `store.secret(for:)` throws.
- `c11Tests/AIUsageTests.swift:271`, `:426`, and `:434`-`436` assert that Claude/Codex/UI providers have credential fields, while `Sources/AIUsage/ClaudeAIProvider.swift:8` and `Sources/AIUsage/CodexAIProvider.swift:8` intentionally set `credentialFields: []`.

There is also a test isolation problem: every injected `AIUsageAccountStore` still calls `load()`, and `load()` reads the real home directory for auto-registration at `Sources/AIUsage/AIUsageAccountStore.swift:177`-`201`. On any machine with `~/.claude/projects/` or `~/.codex/state_5.sqlite`, tests such as `c11Tests/AIUsageTests.swift:51` no longer start from an empty store. Add an injectable home/artifact resolver or an `autoRegisterLocalProviders` test seam, then update tests around the new local-reader behavior.

### Important

**3.** ✅ Confirmed — **SQLite iteration does not check the terminal `sqlite3_step` result, so read errors can be returned as successful partial/empty data.**

`Sources/AIUsage/CodexLocalUsageFetcher.swift:101`-`113` loops while `sqlite3_step(stmt) == SQLITE_ROW` and then immediately returns `entries`. If SQLite returns `SQLITE_BUSY`, `SQLITE_LOCKED`, `SQLITE_IOERR`, or another error during iteration, the loop exits the same way it exits on `SQLITE_DONE`. For a database Codex may be writing concurrently, that turns a read failure into silent zero/partial usage. Store the final step result and require `SQLITE_DONE`; otherwise throw `.decoding` or a local database read error.

**4.** ✅ Confirmed — **A configured session limit can still render as cost-only when usage rounds down to 0%.**

The display requirement says the bar should show when `sessionTokenLimit > 0`, but `AIUsageWindow` only carries `utilization`, not whether a limit exists. The fetchers compute utilization with integer truncation (`Sources/AIUsage/ClaudeLocalUsageFetcher.swift:35`-`40`, `Sources/AIUsage/CodexLocalUsageFetcher.swift:51`-`57`), and the UI switches to cost-only whenever `window.utilization == 0 && window.costUSD > 0` (`Sources/AIUsage/UI/AIUsageFooterView.swift:71`-`75`). With a token limit set and low nonzero usage, the footer hides the 0% bar instead of showing the configured utilization surface.

**5.** ✅ Confirmed — **Docs and leftover remote-fetcher code still describe credentialed remote usage paths.**

`docs/ai-usage-monitoring.md:91`-`94` tells users to refresh credentials for 401/403 and explains a Codex WHAM 404, but neither local usage fetcher uses those credentials/endpoints anymore. `docs/ai-usage-monitoring.md:25`-`27`, `:75`-`77`, and `docs/privacy-endpoints.md:28`-`34` still describe Keychain/header behavior as if it applied to the current Claude/Codex usage path. Also, `Sources/AIUsage/ClaudeAIUsageFetcher.swift:92`-`156` remains compiled into the app target and still contains `https://claude.ai/api/organizations/.../usage` at `Sources/AIUsage/ClaudeAIUsageFetcher.swift:115`, even though the docs say Claude usage is local-only. If the old remote fetchers are intentionally retained as dormant future code, document that clearly; otherwise remove them and update the stale troubleshooting text.

### Potential

**6.** ✅ Confirmed — **Codex session windows are approximate because all thread tokens are assigned to `created_at`.**

`Sources/AIUsage/CodexLocalUsageFetcher.swift:93` selects `created_at, model, tokens_used`, and `Sources/AIUsage/CodexLocalUsageFetcher.swift:108` assigns the whole thread token total to the creation time. That undercounts a current session when a user resumes an older thread and may overcount old tokens for newly created long-running threads. This may be the best available approximation from `threads.tokens_used`, but the limitation should be documented or changed to a more deliberate heuristic.

**7.** ✅ Confirmed — **Claude polling loads every JSONL file in full on every refresh.**

`Sources/AIUsage/ClaudeLocalUsageFetcher.swift:75`-`122` enumerates all `~/.claude/projects/**/*.jsonl`, loads each file with `String(contentsOf:)`, splits all lines, and repeats that work every poll. This is simple and acceptable for small histories, but `~/.claude/projects/` can grow to thousands of JSONL files. After the timestamp blocker is fixed, consider bounding by file metadata, streaming lines, or caching per-file offsets so the sidebar poller does not become a periodic disk-heavy task.
