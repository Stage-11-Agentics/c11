## Synthesis: Standard Code Review — C11-23
- **Date:** 2026-04-27
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6ed68713
- **Models:** Claude Sonnet 4.6, Codex (GPT-5), Gemini
- **Linear Story:** C11-23

---

## Executive Summary

All three reviewers agree: the architectural pivot to local-first data fetching (Claude JSONL + Codex SQLite) is the right call. The privacy footprint reduction is genuine, the provider abstractions held up well, and the auto-registration design is clean. The reviewers are also in strong agreement that the branch is **not ready to merge** — two to four blockers remain depending on how conservatively you count, with one critical finding (Claude fractional-second timestamps) raised exclusively by Codex that would cause the entire Claude local reader to silently report zero usage.

**Merge Verdict: Hold.** Fix the four blockers before landing. The important items can follow in a fast-follow or be addressed alongside, but the blockers are genuine regressions or silent failure modes.

---

## 1. Consensus Issues (2+ Models Agree)

### Blockers

**1. Stale test assertions will fail CI — credentialFields now empty.**

All three reviewers flagged this. `AIUsageTests.swift` lines 271 and 427 assert `credentialFields` is non-empty for Claude and Codex. Line 435 (`testUIProvidersAllHaveCredentialFields`) iterates all UI providers and fails on both. Both providers now have `credentialFields: []`. These are guaranteed CI failures. Additionally, Codex (the reviewer) identified that the test file still references `CodexAIUsageFetcher` (the removed remote fetcher) in lines 533-588 — a type that is no longer compiled into the app target, which may also cause a compile error. The test for the credential flow at lines 53-59 similarly assumes Keychain writes for Claude that are now intentionally bypassed.

**Fix:** Update all three assertion blocks, remove or rewrite the orphaned `CodexAIUsageFetcher` test section, and update the credential-flow test to reflect credential-free behavior. Consider adding an injectable seam or test flag to suppress `load()`'s auto-registration side effect on machines with real Claude/Codex artifacts.

**2. Synchronous I/O on the main actor blocks the UI.**

Claude and Gemini raised this as a blocker; Codex raised it as a performance concern. Both `ClaudeLocalUsageFetcher.allEntries()` and `CodexLocalUsageFetcher.allEntries()` perform blocking I/O (file reads and SQLite queries respectively) on the calling thread. The call chain terminates at `AIUsagePoller`, which is `@MainActor`. On machines with months of Claude Code history this is a real typing-latency risk — directly in conflict with the CLAUDE.md typing-latency sensitivity warnings.

**Fix:** Dispatch both fetchers' I/O to a detached background task (matching the pattern already used in `AIUsageKeychain.detached`).

### Important

**3. Stale troubleshooting docs reference HTTP errors that can no longer occur.**

All three reviewers confirmed this. `docs/ai-usage-monitoring.md` lines 91-94 still advise users to refresh credentials for 401/403 errors and explains a Codex WHAM 404. Neither local fetcher makes credential-bearing HTTP calls. The 404/WHAM reference is particularly confusing since WHAM was the removed remote billing endpoint. Codex (the reviewer) also flagged that `docs/privacy-endpoints.md` lines 28-34 and surrounding doc sections still describe Keychain/header behavior as if it applied to the current local-only Claude/Codex path.

**Fix:** Replace the stale troubleshooting entries with relevant local-reader failure modes (JSONL directory not found, SQLite file not readable, no entries in window, etc.).

**4. SQLite `created_at` timestamp unit (seconds vs. milliseconds) is unverified.**

Claude and Gemini both raised this as important. `CodexLocalUsageFetcher.allEntries()` interprets `created_at` as Unix epoch seconds. JavaScript-originated SQLite databases (and some CLI tools) commonly store milliseconds. If Codex CLI stores milliseconds, all timestamps parse to the year ~2035-2040 and every entry falls outside the 7-day window — users see zero usage with no error or log. There is no sanity check or logging.

**Fix:** Verify the actual schema of `~/.codex/state_5.sqlite`. If it uses milliseconds, divide by 1000. At minimum add a defensive check (e.g., `if ts > 1_000_000_000_000 { ts /= 1000 }`) and a log statement when entries are unexpectedly empty.

**5. `gpt-4o-mini` priced at `gpt-4o` rate — 10-30x overstatement.**

Claude and Gemini both confirmed. `CodexLocalUsageFetcher.cost(for:)` uses `hasPrefix("gpt-4o")` which matches `gpt-4o-mini` before the mini-specific branch. Mini is priced at approximately $0.15/M input vs $5/M for gpt-4o — a ~33x overstatement for input tokens.

**Fix:** Check `hasPrefix("gpt-4o-mini")` before `hasPrefix("gpt-4o")`.

---

## 2. Divergent Views

**Blocker vs. Important: Main-thread I/O severity.**

Claude and Gemini called main-thread I/O a **blocker**. Codex treated it as an important performance concern ("acceptable for small histories"). The distinction matters: on a developer machine with years of Claude Code usage this is a real freeze risk per CLAUDE.md's explicit typing-latency policy. Treating this as a blocker is the conservative and correct call given the project's stated sensitivity.

**Stale remote fetcher in the compiled app target.**

Codex uniquely flagged that `Sources/AIUsage/ClaudeAIUsageFetcher.swift` remains compiled into the app target and still contains the `https://claude.ai/api/organizations/.../usage` endpoint (line 115). Claude and Gemini did not call this out as a blocker — they focused on the docs. Codex's framing is more conservative: either document these as intentionally dormant code for future use, or remove them. The docs say Claude usage is local-only; a compiled remote fetcher with a live URL is potentially confusing and a future maintenance hazard.

**Test isolation / auto-registration side effect.**

Only Codex raised that `load()` reads the real home directory during every test, meaning tests on machines with actual Claude/Codex artifacts no longer start from an empty store. Claude and Gemini noted the credential assertion failures but did not surface the auto-registration contamination. This is a distinct and real test hygiene problem.

**`pruneOrphanAccountsIfNeeded` nil guard.**

Only Claude raised the subtle nil-optional pattern where `provider?.credentialFields.isEmpty == true` evaluates to `false` for unknown (nil) providers, causing them to fall through to Keychain probing unnecessarily. Gemini and Codex did not surface this.

**SQLite error handling during iteration.**

Only Codex raised that the `sqlite3_step` loop exits identically for `SQLITE_DONE` and error codes (`SQLITE_BUSY`, `SQLITE_IOERR`, etc.), turning read errors into silent partial/empty data. Claude and Gemini did not flag this, though it is a real correctness issue for a database Codex may be writing concurrently.

---

## 3. Unique Findings (Single Model Only)

**Codex only:**

**U1. Claude fractional-second timestamps cause the local reader to silently return zero usage.**

This is the most critical unique finding in the review. `ClaudeLocalUsageFetcher.swift` uses a default `ISO8601DateFormatter` that does not parse fractional seconds (e.g., `2026-01-11T20:50:39.428Z`). Claude Code JSONL files in `~/.claude/projects/` use fractional seconds. The date parse returns `nil`, the guard fails, the entry is skipped, and `entries` stays empty — users see zero tokens/cost/utilization even with real local logs. The repo already has `AIUsageISO8601DateParser.parse` with fractional-second support and tests for it; the local reader simply needs to use that parser.

**This should be treated as a blocker.** Without this fix, the core Claude local reader does not work on any real machine.

**U2. SQLite step result not checked after loop exit.**

After the `while sqlite3_step(stmt) == SQLITE_ROW` loop, the code immediately returns `entries` without checking whether the loop exited via `SQLITE_DONE` or an error. Concurrent writes from Codex CLI could produce `SQLITE_BUSY`; the result is silent partial data. Should verify `SQLITE_DONE` on loop exit and throw on any other result.

**U3. Codex thread token attribution to `created_at` overstates old threads.**

The SQLite query assigns the entire thread's `tokens_used` total to the thread's creation timestamp. A thread created 8 days ago but actively used today falls outside the 7-day window entirely; a new thread with accumulated tokens from many days is counted at creation time. This is noted as an approximation limitation, not a correctness flaw, but it is undocumented.

**Claude only:**

**U4. `pruneOrphanAccountsIfNeeded` nil-optional guard obscures intent.**

`provider?.credentialFields.isEmpty == true` evaluates to `false` when `provider == nil`, causing unknown-provider accounts to fall through to Keychain probing. The safer form is `if provider == nil || provider?.credentialFields.isEmpty == true { continue }`. Low risk in practice.

**U5. `weekWindow.utilization` is hardcoded to 0.**

Both local fetchers set `weekWindow.utilization = 0` and `weekWindow.resetsAt = nil`. The week token count and cost propagate correctly, but the utilization bar never shows for the week window. Likely intentional (no standard week quota), but undocumented.

**U6. `SQLITE_OPEN_NOMUTEX` threading constraint is undocumented.**

The read-only open with `SQLITE_OPEN_NOMUTEX` is safe for the current single-connection pattern but will become unsafe if future refactors add concurrent reads. A comment noting the constraint would help.

**U7. Double-negative pattern in `add()` obscures intent.**

`if provider?.credentialFields.isEmpty != true` (to check if Keychain write should proceed) is semantically correct but harder to read than `if provider?.credentialFields.isEmpty == false`. Also silently skips Keychain for unknown providers — correct behavior, obscured intent.

**Gemini only:**

No findings exclusive to Gemini that were not covered by the other two models.

---

## 4. Consolidated Issue List

### Blockers (must fix before merge)

1. **Claude fractional-second timestamp parsing** — `ClaudeLocalUsageFetcher` uses a default `ISO8601DateFormatter` that rejects fractional seconds, silently returning zero usage on all real machines. Use `AIUsageISO8601DateParser.parse` instead. *(Codex only, highest severity)*
2. **Stale test assertions on `credentialFields`** — Lines 271, 427, 435 in `AIUsageTests.swift` assert non-empty credential fields for both local providers; both now have `credentialFields: []`. These are guaranteed CI failures. Also audit lines 53-59 (Keychain assumption) and 533-588 (orphaned remote fetcher test). *(All three models)*
3. **Main-thread I/O in both local fetchers** — `ClaudeLocalUsageFetcher.allEntries()` and `CodexLocalUsageFetcher.allEntries()` perform blocking file and SQLite I/O on `@MainActor`. Dispatch to a detached background task. *(Claude + Gemini as blocker, Codex as important)*
4. **Fractional-second parsing makes the Claude reader non-functional** — (Same as #1; listed separately to make clear this is distinct from the formatter inefficiency in item 7 below.)

### Important (should fix before or shortly after merge)

5. **`gpt-4o-mini` priced at `gpt-4o` rate** — 10-30x cost overstatement for mini users. Fix ordering in `cost(for:)`. *(Claude + Gemini)*
6. **SQLite timestamp unit unverified** — `created_at` assumed to be seconds; milliseconds would produce far-future dates and zero visible usage. Verify schema or add defensive conversion. *(Claude + Gemini)*
7. **Stale troubleshooting docs** — 401/403/404/WHAM entries in `docs/ai-usage-monitoring.md` and related `docs/privacy-endpoints.md` sections describe a removed credential/HTTP path. Replace with local-reader failure modes. *(All three models)*
8. **SQLite step result unchecked** — Loop exits identically on `SQLITE_DONE` and error codes; concurrent Codex writes can produce silent partial data. Require `SQLITE_DONE` on loop exit. *(Codex only)*
9. **Stale remote fetcher compiled into app target** — `ClaudeAIUsageFetcher.swift` remains in the app target with the old `claude.ai` API URL. Document as intentionally dormant or remove. *(Codex only)*
10. **Test auto-registration side effect** — `load()` reads the real home directory during tests; machines with real Claude/Codex artifacts contaminate test state. Add an injectable seam or `autoRegisterLocalProviders` flag. *(Codex only)*
11. **Codex cost approximation not disclosed** — Blended single-rate model without input/output split is not communicated in the UI or docs. Add "estimated" qualifier. *(Claude only)*
12. **Utilization bar hides configured 0% session** — When `sessionTokenLimit > 0` but actual usage rounds to 0%, the footer switches to cost-only mode, hiding the bar. The `AIUsageWindow` struct does not carry the "limit configured" signal needed to override this. *(Codex + Claude)*

### Suggestions (low priority, non-blocking)

13. **`ISO8601DateFormatter` allocated per poll** — Should be a `static let` at the type level. *(Claude + Gemini)*
14. **Unbounded JSONL file reads** — No per-file size guard or file modification time pre-filter. After fixing the blocker, consider bounding reads to files modified after `weekCutoff`. *(Claude + Codex + Gemini)*
15. **`weekWindow.utilization` hardcoded to 0** — Add a comment explaining the design choice (no standard week quota to compare against). *(Claude only)*
16. **`SQLITE_OPEN_NOMUTEX` threading note** — Add a comment that this is safe only for single-connection reads. *(Claude only)*
17. **`pruneOrphanAccountsIfNeeded` nil guard** — Safer form: `if provider == nil || provider?.credentialFields.isEmpty == true { continue }`. *(Claude only)*
18. **Double-negative in `add()` Keychain guard** — Replace `!= true` with `== false` for clarity. *(Claude only)*
19. **Codex thread token attribution** — Document that all thread tokens are attributed to `created_at`, which skews session windows for long-running threads. *(Codex only)*

---

## 5. Model Agreement Matrix

| Issue | Claude | Codex | Gemini | Confidence |
|-------|--------|-------|--------|------------|
| Stale `credentialFields` test assertions | Blocker | Blocker | (implied by test review) | High |
| Main-thread I/O blocks UI | Blocker | Important | Blocker | High |
| Stale troubleshooting docs | Important | Important | Important | High |
| `gpt-4o-mini` pricing overstatement | Important | (not raised) | Potential | Medium-High |
| SQLite timestamp unit unverified | Important | (not raised) | Important | Medium |
| `ISO8601DateFormatter` per-call allocation | Important | (not raised) | Potential | Medium |
| Unbounded JSONL reads / memory | Potential | Important | Potential | Medium |
| Claude fractional-second timestamp drop | (not raised) | **Blocker** | (not raised) | High (unique but critical) |
| SQLite step result unchecked | (not raised) | Important | (not raised) | Medium |
| Remote fetcher still compiled | (not raised) | Important | (not raised) | Medium |
| Test auto-registration contamination | (not raised) | Important | (not raised) | Medium |
| 0% utilization bar hidden | Potential | Important | (not raised) | Medium |
