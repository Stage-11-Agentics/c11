# Action-Ready Synthesis: C11-23

## Verdict

**fix-then-merge**

Five reviewers across all three lenses called this not production-ready. The blockers are concrete, the fixes are well-scoped, and the architectural direction is unanimously praised. After the blockers and importants are resolved this is a clean merge.

---

## Apply by default

### Blockers (merge-blocking)

**B1: Claude JSONL timestamps with fractional seconds are dropped — Claude usage shows zero**
- Location: `Sources/AIUsage/ClaudeLocalUsageFetcher.swift:208` (the `let iso = ISO8601DateFormatter()` line, used at line 230 `iso.date(from: timestampStr)`)
- Problem: A plain `ISO8601DateFormatter` rejects fractional-second timestamps like `2026-01-11T20:50:39.428Z`, returning `nil`. Claude Code JSONL files in `~/.claude/projects/` consistently use fractional seconds. Every valid assistant entry fails the `guard … let timestamp = iso.date(from: timestampStr)` check, so `entries` stays empty and users see zero tokens, zero cost, zero utilization. The repo already has `AIUsageISO8601DateParser` (in `Sources/AIUsage/AIUsageISO8601DateParser.swift`) which tries fractional seconds first — it exists precisely for this case.
- Fix: Replace `iso.date(from: timestampStr)` with `AIUsageISO8601DateParser.parse(timestampStr)`. The `ISO8601DateFormatter` local variable can be removed entirely; the static parser handles both forms.
- Sources: standard-codex (blocker #1), critical-codex (blocker #2). Cross-check: confirmed in diff — default `ISO8601DateFormatter` is used at line 208/230; `AIUsageISO8601DateParser.swift` is present in the diff as a 17-line file.

**B2: Stale tests will fail and cannot provide CI signal for this branch**
- Location: `c11Tests/AIUsageTests.swift:271`, `:427`, `:434–436` (credentialFields assertions); also lines `:53–59` (Keychain round-trip for Claude) and `:533–588` (CodexAIUsageFetcher references)
- Problem: Three independent failures. (1) Lines 271 and 427 assert `credentialFields.isEmpty == false` for Claude and Codex, but both providers now have `credentialFields: []`. (2) Lines 434–436 (`testUIProvidersAllHaveCredentialFields`) iterates all UI providers and asserts non-empty credential fields — fails for both providers. (3) Lines 53–59 add a Claude account through the credentialed path and expect a Keychain secret, but `AIUsageAccountStore.add()` now skips Keychain writes when `credentialFields.isEmpty`. Additionally, lines 533–588 reference `CodexAIUsageFetcher` and `CodexAIValidators` which are not in the app target's Sources list (confirmed in `GhosttyTabs.xcodeproj/project.pbxproj:1137`). The test suite gives a false safety signal and CI cannot validate the branch.
- Fix: Update lines 271, 427 to `XCTAssertTrue(claude?.credentialFields.isEmpty ?? false)` (and same for codex). Update the `testUIProvidersAllHaveCredentialFields` test to either remove it or invert it to confirm credential-free providers have empty fields. Fix or remove the Keychain round-trip test at lines 53–59 to match the new credential-free flow. Remove or stub out the `CodexAIUsageFetcher`/`CodexAIValidators` references at lines 533–588 (these reference removed/untargeted code).
- Sources: standard-claude (blocker #1), standard-codex (blocker #2), critical-codex (blocker #1). Cross-check: confirmed — `ClaudeAIProvider.swift` has `credentialFields: []`; project.pbxproj does not include `CodexAIUsageFetcher.swift` in app target sources.

**B3: Synchronous blocking I/O on @MainActor during every 60-second poll**
- Location: `Sources/AIUsage/ClaudeLocalUsageFetcher.swift:211–244` (`allEntries()` body); `Sources/AIUsage/CodexLocalUsageFetcher.swift:361–385` (`allEntries()` body)
- Problem: `AIUsagePoller` is `@MainActor`. It calls `provider.fetchUsage` which resolves to `ClaudeLocalUsageFetcher.fetchUsage` or `CodexLocalUsageFetcher.fetchUsage`. Claude's `allEntries()` is declared `async throws` but contains no `await` calls — it runs entirely on the main actor performing `FileManager.default.enumerator`, `String(contentsOf: file, encoding: .utf8)` for every JSONL file. Codex's `allEntries()` is synchronous (`throws`, not `async throws`) and is called inline with `try allEntries()` — all SQLite open/prepare/step/close runs on the main actor. Per CLAUDE.md, typing-latency-sensitive paths are a critical concern. A developer with months of Claude Code history and many JSONL files will experience a multi-second main-thread stall every 60 seconds.
- Fix: In `ClaudeLocalUsageFetcher.fetchUsage`, wrap the `allEntries()` call in a detached task: `let entries = try await Task.detached(priority: .utility) { try await allEntries() }.value`. Same pattern for `CodexLocalUsageFetcher.fetchUsage`: make `allEntries()` `async throws` and wrap: `let entries = try await Task.detached(priority: .utility) { try allEntries() }.value`. The `runWithTimeout` task group in `AIUsagePoller` composes cleanly with this pattern.
- Sources: standard-claude (blocker #2), standard-gemini (blockers #1 and #2), critical-claude (blockers B1/B2), critical-gemini (blockers B1/B2), evolutionary-claude (concrete suggestion #1), evolutionary-codex (concrete suggestion #2), evolutionary-gemini (concrete suggestion #1). Cross-check: confirmed — `AIUsagePoller` is annotated `@MainActor` (line 17 per codex review); both fetchers perform synchronous I/O.

**B4: SQLite timestamp unit unverified — Codex usage silently zeroed for all users**
- Location: `Sources/AIUsage/CodexLocalUsageFetcher.swift:381` (`Date(timeIntervalSince1970: Double(ts))`)
- Problem: The Codex CLI is a Node.js/TypeScript application. `Date.now()` in Node returns milliseconds since epoch. If `created_at` in `state_5.sqlite` stores milliseconds (a value like `1745700000000`), passing it to `timeIntervalSince1970` produces a date in approximately year 57,285. The window filter at lines 316–317 only keeps entries within `sessionCutoff` (5 hours ago) and `weekCutoff` (7 days ago). All millisecond-timestamped entries appear to be far in the future and are silently discarded. Result: zero tokens, zero cost, zero utilization with no error. The context document itself flags this at line 571 as a known concern. No defensive check or logging exists.
- Fix: Add a magnitude check before constructing the Date: `let interval = ts > 1_000_000_000_000 ? Double(ts) / 1000.0 : Double(ts)` then `Date(timeIntervalSince1970: interval)`. Add a comment explaining the check (JS/Node timestamps are milliseconds; SQLite epoch seconds are typically < 1e10). Alternatively, verify the actual schema by inspecting a real `state_5.sqlite` and add a comment with the confirmed unit.
- Sources: standard-claude (important #4), critical-claude (blocker B1), critical-codex (important #4), critical-gemini (blocker B2), standard-gemini (important #3). Cross-check: confirmed in diff — `Date(timeIntervalSince1970: Double(ts))` is present at line 381 with no guard on magnitude.

**B5: SQLite handle leaked on open failure**
- Location: `Sources/AIUsage/CodexLocalUsageFetcher.swift:361–364`
- Problem: `sqlite3_open_v2` can partially succeed (allocate a handle) even when it returns an error code. The code declares `var db: OpaquePointer?`, calls `sqlite3_open_v2(dbPath, &db, ...)`, and immediately throws if the return code is not `SQLITE_OK`. The `defer { sqlite3_close(db) }` is placed after the guard, so it only runs on the success path. A manually added Codex account pointing at a missing or unreadable database will leak a SQLite handle every 60-second poll tick.
- Fix: Call `sqlite3_close(db)` before throwing in the failure branch. Either restructure with a deferred close before the guard, or add an explicit `sqlite3_close(db)` before the `throw` on the failed path.
- Sources: critical-codex (important #8). Cross-check: confirmed in diff — `defer { sqlite3_close(db) }` appears after the guard statement at line 364; a failed `sqlite3_open_v2` skips the defer.

---

### Important (land in same PR)

**I1: gpt-4o-mini priced at gpt-4o rate — cost estimates inflated ~6-8x for mini users**
- Location: `Sources/AIUsage/CodexLocalUsageFetcher.swift:394` (`} else if model.hasPrefix("gpt-4o") {`)
- Problem: `"gpt-4o-mini".hasPrefix("gpt-4o")` is `true`. The mini model matches the `gpt-4o` branch and receives a blended rate of $5.00/M tokens. The correct mini rate is approximately $0.15/$0.60 per million tokens (input/output). This overstates cost by roughly 6-8x for any Codex user running `gpt-4o-mini` (a popular cost-saving model choice).
- Fix: Add a `gpt-4o-mini` branch before the `gpt-4o` branch: `} else if model.hasPrefix("gpt-4o-mini") { ratePerMillion = 0.60 } else if model.hasPrefix("gpt-4o") {`. The blended 0.60 rate is a reasonable approximation for mini given the single-rate model approach.
- Sources: standard-claude (important #3), critical-claude (important #3), critical-gemini (important I1), standard-gemini (potential #5), evolutionary-claude (concrete suggestion #6). Cross-check: confirmed in diff — the `hasPrefix("gpt-4o")` branch is present with no prior `gpt-4o-mini` check.

**I2: Stale troubleshooting docs actively misdirect users**
- Location: `docs/ai-usage-monitoring.md:91–94`
- Problem: The Troubleshooting section tells users "401 / 403: the sign-in expired. Open the editor and paste a fresh credential" and "Codex returns 404: the token does not have access to the WHAM endpoint (no Codex subscription)." Neither Claude nor Codex makes any network call for usage data. There are no credentials, no auth headers, no endpoints. A user seeing zero data (e.g., from B4 above) will follow this guidance, find no credential to refresh, and conclude the feature is broken.
- Fix: Remove the 401/403 and 404/WHAM entries. Replace with local-reader troubleshooting: "Claude shows zero usage: check that `~/.claude/projects/` exists and contains `.jsonl` files. Codex shows zero usage: verify `~/.codex/state_5.sqlite` exists and is readable (check with `ls -la ~/.codex/state_5.sqlite`). If permission errors occur, check file permissions."
- Sources: standard-claude (important #5), critical-claude (important #4), critical-codex (important #7), critical-gemini (important I2), standard-gemini (important #4), evolutionary-gemini (concrete suggestion #4). Cross-check: confirmed in context document at line 615–620.

**I3: SQLite step errors silently collapse into partial/empty data**
- Location: `Sources/AIUsage/CodexLocalUsageFetcher.swift:374–385` (the `while sqlite3_step(stmt) == SQLITE_ROW` loop)
- Problem: The loop exits whenever `sqlite3_step` returns anything other than `SQLITE_ROW` — including `SQLITE_BUSY`, `SQLITE_LOCKED`, `SQLITE_IOERR`, and `SQLITE_CORRUPT`. A live Codex process writing to the DB concurrently, a transient I/O error, or a corrupt page will cause the loop to terminate early and return partial or empty data with no error surfaced. The code treats `SQLITE_DONE` (normal completion) and `SQLITE_BUSY` (contention) identically.
- Fix: Capture the final step result: `let finalResult = sqlite3_step(stmt)` after the loop exits (restructure the loop to capture it), then `guard finalResult == SQLITE_DONE else { throw CodexAIUsageFetchError.decoding }`. Alternatively, capture it in the loop: `var stepResult: Int32; while (stepResult = sqlite3_step(stmt)) == SQLITE_ROW { ... }; guard stepResult == SQLITE_DONE else { throw ... }`.
- Sources: standard-codex (important #3), critical-codex (important #5). Cross-check: confirmed in diff — loop exits on any non-SQLITE_ROW result with no check of the exit code.

**I4: ISO8601DateFormatter recreated on every poll call**
- Location: `Sources/AIUsage/ClaudeLocalUsageFetcher.swift:208` (`let iso = ISO8601DateFormatter()`)
- Problem: `ISO8601DateFormatter` wraps `NSDateFormatter` and loads ICU locale data on initialization — it is an expensive object to create. It is instantiated fresh on every `allEntries()` call (every 60-second poll tick). On a machine with many JSONL files, this is recreated once per poll for no benefit. Note: this item only matters if B1 is fixed (i.e., the formatter is replaced by `AIUsageISO8601DateParser`). If B1's fix removes the formatter entirely, this item is automatically resolved.
- Fix: If the formatter is retained after the B1 fix, promote it to `private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()`. If B1's fix removes the formatter in favor of `AIUsageISO8601DateParser`, this item is no longer needed.
- Sources: standard-claude (important #6), critical-claude (potential #6), critical-gemini (nit P2), standard-gemini (potential #6). Cross-check: confirmed in diff.

**I5: Legacy ClaudeAIUsageFetcher.swift remains compiled into the app target despite privacy claim**
- Location: `Sources/AIUsage/ClaudeAIUsageFetcher.swift:115` (constructs `https://claude.ai/api/organizations/.../usage`); `GhosttyTabs.xcodeproj/project.pbxproj` (includes it in app target Sources)
- Problem: `docs/privacy-endpoints.md` explicitly states that Claude usage is read locally and no network call is made. However, `ClaudeAIUsageFetcher.swift` — which contains the `claude.ai` usage endpoint URL — is still compiled into the app target. It is not currently wired through `Providers.claude`, but it is live compiled code in the shipped binary. For a privacy audit, dead compiled network code referencing `claude.ai` is inconsistent with the privacy claim. `docs/privacy-endpoints.md:28–34` also still describes Keychain/header behavior as if it applies to the current Claude path (per codex critical review).
- Fix: Either remove `ClaudeAIUsageFetcher.swift` from the app target's Sources build phase in `project.pbxproj` (and optionally from the project entirely), or add a clear header comment marking it as intentionally dormant future code and update the privacy doc accordingly. Update `docs/privacy-endpoints.md` to remove references to Keychain/credential behavior for the Claude usage path.
- Sources: critical-codex (blocker #3), standard-codex (important #5). Cross-check: confirmed — context document lists `ClaudeAIUsageFetcher.swift` at 191 lines in the diff; critical-codex cites `project.pbxproj:1137` for app target inclusion.

---

### Straightforward mediums

**M1: CodexAIUsageFetchError.network is semantically wrong for a local reader**
- Location: `Sources/AIUsage/CodexLocalUsageFetcher.swift:5–16` (error enum definition and line 362 where `.network` is thrown)
- Problem: The error case is named `.network` and the error type `CodexAIUsageFetchError` implies a network-facing failure. Since Codex no longer makes network calls, `.network` now means "local database not found or unreadable." Engineers reading a `.network` error thrown from a credential-free local reader will waste time looking for a network call that does not exist.
- Fix: Rename `CodexAIUsageFetchError.network` to `.databaseUnavailable` (or `.localReadFailed`). Update the throw site at line 362, the switch in `errorDescription`, and any callers.
- Sources: critical-claude (nit), critical-codex (nit), critical-gemini (nit), standard-codex (important #5 tangentially). Cross-check: confirmed in diff — `.network` is thrown at line 362 for `sqlite3_open_v2` failure; the error description says "Codex local database not found or unreadable."

---

### Evolutionary clear wins

**EW1: Add isLocalProvider computed property to AIUsageProvider**
- Location: `Sources/AIUsage/AIUsageProvider.swift` (wherever the struct is defined)
- Problem: The `credentialFields.isEmpty` check is used as a discriminant for local-vs-credentialed behavior in at least four call sites across `AIUsageAccountStore`, `AIUsagePoller`, and `add()`/`remove()`/`update()`. The concept has no named representation.
- Fix: Add `var isLocalProvider: Bool { credentialFields.isEmpty }` to the `AIUsageProvider` struct. Replace all four `credentialFields.isEmpty` (and `credentialFields.isEmpty != true`) checks with `provider.isLocalProvider`. This is a pure refactor — no behavior change.
- Sources: evolutionary-claude (leverage point #2, concrete suggestion #2), evolutionary-codex (leverage point #2, concrete suggestion #3). Cross-check: confirmed — the pattern is verifiable in the diff at `AIUsageAccountStore.swift:55`, `AIUsagePoller.swift:497`, `add()`, `remove()`.

---

## Surface to user (do not apply silently)

**S1: Test isolation — load() reads real home directory during tests**
- Why deferred: design-needed
- Summary: `AIUsageAccountStore.load()` is called from `init()` and performs real filesystem probes (`FileManager.default.fileExists`) for auto-registration. On any developer machine with `~/.claude/projects/` or `~/.codex/state_5.sqlite`, test instances are no longer hermetic — they auto-register providers and don't start from an empty store. Standard-codex raised this as part of its stale-test blocker, suggesting an injectable home/artifact resolver or an `autoRegisterLocalProviders` seam. This is the right long-term fix but it requires API surface changes to `AIUsageAccountStore` and touches the test harness. Scope is larger than the other test fixes in B2 and warrants explicit user acknowledgment before an agent restructures the store API.
- Sources: standard-codex (blocker #2).

**S2: No cleanup path for stale credential-free auto-registered accounts**
- Why deferred: design-needed
- Summary: `pruneOrphanAccountsIfNeeded()` explicitly skips credential-free accounts (`if provider?.credentialFields.isEmpty == true { continue }`). If a user uninstalls Codex or removes `~/.claude/projects/`, the auto-registered account persists in UserDefaults forever, showing "Codex local database not found or unreadable" errors on every poll tick. There is no self-healing path and no UI affordance explaining that the account needs manual removal. Critical-claude (important #5) raised this as an important item; it is confirmed valid but the correct fix (auto-prune on fetch error? UI hint? prune-on-path-missing?) requires a design decision before implementation.
- Sources: critical-claude (important #5), critical-codex (potential #10 tangentially).

**S3: 0% utilization bar hidden even when a session token limit is configured**
- Why deferred: ambiguous
- Summary: When a `sessionTokenLimit` is configured and usage is low but nonzero, `utilization` rounds down to 0 via integer truncation. `AIUsageFooterView` switches to cost-only display whenever `window.utilization == 0 && window.costUSD > 0` (line 71). This means the configured utilization bar is hidden even though the user has a limit set. Standard-codex (important #4) raised this as a confirmed bug; standard-claude (potential #9) noted it but called it likely intentional. Reviewers disagree on whether this is a bug or design. Requires user input on intended behavior before applying a fix.
- Sources: standard-codex (important #4), standard-claude (potential #9).

**S4: No direct tests for ClaudeLocalUsageFetcher or CodexLocalUsageFetcher**
- Why deferred: scope-creep
- Summary: Multiple reviewers noted that the two newest, most critical code paths (the local fetchers) have no direct test coverage. Adding meaningful fixture-driven tests requires injecting configurable paths into the fetchers (they currently hardcode `NSHomeDirectory()`), which means an API change. This is the right long-term investment but is a larger scope addition than the other fixes in this PR. The project's no-local-tests policy means these would be CI-only fixtures. Standard-claude (validation notes), critical-codex (potential #9), evolutionary-codex (concrete suggestion #5) all raised this.
- Sources: standard-claude (validation notes), critical-codex (potential #9), evolutionary-codex (concrete suggestion #5).

**S5: Codex cost approximation not disclosed in UI or docs**
- Why deferred: design-needed
- Summary: The Codex cost model uses a single blended rate per model family with no input/output split. The resulting dollar figures imply two-decimal-place accuracy that the model doesn't have. Standard-claude (important #7) and standard-codex (potential #11) both flagged that the docs don't call this out and the UI shows `$X.XX` without qualification. The correct fix (tooltip? docs note? UI label?) and the right language ("approximate," "estimated," "blended") are design choices. Evolutionary-codex (concrete suggestion #6) suggested a `AIUsagePricingCatalog` with accuracy metadata — a more complete but larger solution.
- Sources: standard-claude (important #7), standard-codex (potential #11).

---

## Evolutionary worth considering (do not apply silently)

**E1: Generalize auto-registration to a provider-declared autoDetect closure**
- Summary: `AIUsageAccountStore.load()` currently has hardcoded detection blocks for Claude and Codex. Each new local provider requires a dedicated block in `load()`. Moving the detection predicate (`FileManager.default.fileExists(atPath:...)`) onto `AIUsageProvider` itself (as an optional `@Sendable () -> Bool` closure named `autoDetect`) would make adding a third provider a single-file change with no modification to `AIUsageAccountStore`. The closure must stay cheap since `load()` is synchronous.
- Why worth a look: The flywheel for this feature (more providers = more aggregate value) breaks down if each provider requires two-file changes. This is the leverage point that makes the third, fourth, and fifth providers trivially cheap to add.
- Sources: evolutionary-claude (pattern #1, concrete suggestion #3), evolutionary-codex (concrete suggestion #3), evolutionary-gemini (leverage point — Provider struct).

**E2: Add aggregate session cost/token computed properties to AIUsagePoller**
- Summary: `AIUsagePoller.snapshots` already holds per-account usage data. A pair of computed properties — `aggregateSessionTokens: Int` and `aggregateSessionCostUSD: Double` — summing across all active accounts would take roughly 4 lines and expose a cross-tool total that no vendor dashboard can provide. The UI could display a "total" line in the footer when more than one provider is active.
- Why worth a look: This is the first step toward the budget-enforcement and burn-rate features, and it requires zero new model types or state — only a projection on existing data.
- Sources: evolutionary-claude (concrete suggestion #3), evolutionary-codex (concrete suggestion #4).
