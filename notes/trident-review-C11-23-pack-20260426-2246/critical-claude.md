## Critical Code Review
- **Date:** 2026-04-26T22:50:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6d1089d45dafd5c4494ddfb37cbf5c0269b4a61c
- **Linear Story:** C11-23
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

This is a careful, well-shaped piece of work. The author actually thought about Keychain attributes, ephemeral sessions, header sanitization, redacted secret printing, an allowlist for status hosts, occlusion-based polling pauses, and a test gate so XCTest doesn't kick off real network. The privacy doc and the redaction tests show the right instincts. Most of what's here is solid.

But it's not bulletproof, and a few things are actively broken or fragile:

1. The popover's "Add account" and "Edit" buttons are wired to no-op closures (`onAdd: {}`, `onEdit: { _ in }`). The popover dismisses but nothing opens. This is a dead UI surface in the sidebar — the very surface most agents and operators will touch first. The Settings flow works; the popover does not.
2. The editor sheet leaks state across consecutive edits of two accounts on the same provider (`.sheet(item: $aiUsageEditorProvider)`). Provider id is the sheet identity, so swapping the editing account does not re-create the sheet view; the user sees the previous account's name/values until the async load completes (and the load only fills empties, so stale displayName persists outright).
3. There is a real race in `AIUsageAccountStore.pruneOrphanAccountsIfNeeded` that can silently destroy a freshly-added account if the prune awaits Keychain probes while the user is adding through the editor — both in-memory list and the persisted UserDefaults blob get rewritten from a stale snapshot.
4. `AIUsageAccountStore.load()` silently resets `accounts = []` on any decode failure. A malformed UserDefaults blob orphans every Keychain credential with no log, no warning, no recovery path.
5. `AIUsagePoller.stop()` does not wait for the in-flight task it just cancelled, and the cancelled fetches' `CancellationError` is mapped to "Could not fetch usage." in `fetchErrors` because `localizedFetchErrorMessage` has no special case for it. App teardown is fine; user-driven stop/restart is not.

Privacy and Keychain attributes themselves are correct. Thread safety is *mostly* correct because everything important lives on `@MainActor`. The typing-latency hot paths are not touched. The localization shape is right. Tests are real-ish but a couple are smoke-tests that assert nothing meaningful.

I would not mass-deploy this to 100k users today. The dead popover buttons alone would generate a wave of "the thing doesn't work" reports.

---

## What Will Break

- **Sidebar popover Add / Edit are dead.** `AIUsageFooterView.swift:107-108` passes `onAdd: {}` and `onEdit: { _ in }` to `AIUsagePopover`. When the user clicks "Add account" or one of the edit-per-account rows, `isPresented = false` runs, the popover disappears, and the closure is a no-op. The only way to reach the editor is `Settings → Agents & Automation → AI Usage Monitoring → Add`. Users will repeatedly click and nothing will happen. **Blocker** for the user-facing surface.
- **Editor sheet shows stale data when editing a second account of the same provider.** `c11App.swift` sets `.sheet(item: $aiUsageEditorProvider)`. `AIUsageProvider.id` is the provider id (`"claude"`/`"codex"`). If the user edits Account A, then closes, then edits Account B (same provider), `aiUsageEditorProvider` is set to the same value, so the sheet's identity is unchanged. SwiftUI keeps the existing view and its `@State`. Inside `AIUsageEditorSheet.loadExistingIfNeeded()` the code only fills empties (`if (values[key] ?? "").isEmpty`), and `displayName = account.displayName` runs but the user's previous typed value lives on through `@State`. Net effect: stale displayName flashes; if the user types between edits, secrets persist across the boundary. **Important.**
- **`pruneOrphanAccountsIfNeeded` racing user `add()`.** `AIUsageAccountStore.swift:135-151`: copies `accounts` into a local closure variable, awaits `probePresenceAsync` per account, then writes `accounts = survivors` and persists. Because `@MainActor` suspends across awaits, a user's `add(...)` between the read and the write inserts an account that is then erased by the prune's `accounts = survivors`. Both the in-memory list and the UserDefaults blob are clobbered with the stale survivors set; the new Keychain credential lives on as garbage. Prune runs on init and `reload()`; if reload is triggered (e.g., from a future SwiftUI lifecycle path) while the editor is in flight, the user loses the account they just added. **Important.**
- **`AIUsageAccountStore.load()` swallows decode failures silently.** `AIUsageAccountStore.swift:118-128`: if the UserDefaults blob is corrupt, every account vanishes from the in-memory list, the user sees an empty AI Usage panel, and every existing Keychain entry is now an orphan. There's no `os_log`, no error surfaced to UI, nothing. A bad write or a forward-incompatible schema bump silently hides accounts. **Important.** Also makes orphan prune worse: if the prune fires next, it'll see zero accounts and not even probe the keychain.
- **`AIUsagePoller.stop()` produces user-visible "Could not fetch usage." errors.** `AIUsagePoller.swift:107-119` cancels `inFlightTask` but does not increment `taskGeneration` or wait for the task. `runTick` continues iterating its `for account in accountsBefore`; the URLSession data tasks throw `URLError(.cancelled)`. Fetchers map that to `.network`, and `.network` is an `AIUsageAppOwnedError` with localized "Network error while contacting...". The poller's `localizedFetchErrorMessage` does not special-case `CancellationError` either, so a user-driven stop (or anything that triggers `stop()` mid-tick — there isn't a code path for it today, but it's a foot-gun) writes "Network error" / "Could not fetch usage." into `fetchErrors`. The state survives because `stop()` does not clear `snapshots`/`fetchErrors`, only `isRefreshing`. **Important** — and easy to fix by bumping `taskGeneration` in `stop()` and by catching `CancellationError` early in `runTick`'s per-account catch.
- **`refreshNow()` silently demotes to non-forced when a tick is already in flight.** `AIUsagePoller.swift:121-149`: `scheduleTick(force: true)` enters, sees `inFlightTask != nil`, sets `hasPendingTick = true` and returns. The follow-up `scheduleTick(force: false)` ignores `force`, so the user's manual "Refresh now" tap never refreshes status pages and may even be skipped if visibility flips off in between. The fix is to track a `pendingForce` flag, or to always force when refreshNow is asked. **Potential.**
- **Codex parseWindow accepts garbage `used_percent`.** `CodexAIUsageFetcher.swift:117-150`: `toNumber` returns `0` for any unknown type (string, dict, missing). So a malformed payload silently shows "0%" instead of throwing `.decoding`. Combined with `limit_window_seconds` being required, this means a partial outage where the upstream returns a string in `used_percent` shows the user a happy 0% — actively misleading right when they need to know they're capped. **Important.** Either treat missing/typed-wrong as decoding error, or surface "Unknown" to the UI.
- **`AIUsageHTTP.sanitizeHeaderValue` silently drops `;` and `,` from header values.** `AIUsageHTTP.swift:22-35`: this is fine for the tokens we send today (cookies and JWTs), but it is a foot-gun. If a future provider's token legitimately contains `;` or `,`, the sanitizer corrupts it without any signal. At minimum, leave a comment that this is whitelist-of-providers-tested behaviour, not a generic header sanitizer. **Nit.**
- **`AIUsageISO8601DateParser` allocates two formatters per call.** `AIUsageISO8601DateParser.swift`: `ISO8601DateFormatter` is documented as expensive to construct. The parser is called in a tight per-incident loop in `AIUsageStatusPagePoller`. Not a hot path (every 5 min) so not a real perf bug, but easy to cache as `static let`. **Nit.**
- **`Color.rgbComponents` always falls back to black on `usingColorSpace(.sRGB)` failure.** `AIUsageColorSettings.swift:146-156`: a `nil` from `usingColorSpace` returns `(0,0,0)` silently. Interpolation will then yank toward black. The catalog colors all parse fine so this is theoretical; a custom user color in a weird color space could surface it. **Potential.**
- **`AIUsagePopover` and `AIUsageFooterView` both call `AIUsagePoller.shared.refreshNow()` directly** rather than using the `@ObservedObject` `poller` they already have. Functionally correct (same singleton), but if anyone tries to test or stub the poller via DI later, these direct shared accesses defeat it. **Nit.**
- **Editor `canSave` skips validation for non-secret optional fields when empty, but accepts empty `displayName.trimmed` too — actually that path is guarded — yet the sheet allows saving when a Codex `accountId` is empty even though `isValidAccountId("")` returns true.** That's intended (account id is optional). The hidden gotcha: `validate` for an optional non-secret returns true for empty, but the editor logic at `AIUsageEditorSheet.swift:108-111` is convoluted and reads like "if invalid AND (secret OR non-empty), block save". It works but is brittle — a future refactor of credential field semantics will break it. **Nit / refactor.**
- **`AIUsagePollerLifecycleTests.testStartIsIdempotent` under-asserts.** It compares `ticks` after second start to `ticks` after first start, but `start()` schedules the forced tick in a `Task { @MainActor }` that has not run yet by the time the assertion fires. Since `tickBody` is invoked from `runTick` *only* via the Task, `ticks` is almost certainly `0` at both reads. The test will pass even if `start()` is broken. The same critique applies to relying on second `start()`'s `guard timer == nil`. **Potential.**
- **`AIUsageColorSettingsTests.testColorForPercentBoundsAreClamped` asserts nothing.** It just calls `color(for:)` with various values and discards the result. It's a code-coverage prop, not a behavior test. Per `CLAUDE.md` test policy, this is on the edge of "fake regression test." **Potential.**
- **`AIUsagePoller.runTick` reads `store.accounts` twice** (once at start to drive iteration, once at end via `store.accounts.map { $0.id }` to filter) without re-checking generation in between. If the store mutated during the loop (account removed mid-tick), the second read produces a different `liveAccounts` set than the first, but the loop already produced a snapshot/error keyed by the now-dead account.id. The filter at `:204-207` handles this — fine. But the code reads as if it doesn't, and any future refactor that drops the filter introduces a leak. **Nit / clarity.**
- **Codex JSON `reset_after_seconds` parsing accepts `NSNull` and missing as `nil`, but throws `.decoding` for any other unrecognized type.** Reasonable. But a number stored as a string (some statuspage-style APIs do this) will throw decoding errors and show "Could not read Codex usage payload." while the rest of the payload is healthy. The other fields would still have parsed. Tightening or loosening this is a judgment call; flagging it. **Potential.**

---

## What's Missing

- **No test for the popover dead-button bug.** No UI/integration test exercises Add/Edit through the popover. If there were one, the no-op closures would have been caught.
- **No test for `AIUsageAccountStore.load()` decode failure path.** Hand-write a malformed blob to UserDefaults and assert the store either logs or recovers — not silently drops everything.
- **No test for `pruneOrphanAccountsIfNeeded` racing `add()`.** Inject a delay into `probePresenceAsync` (a test seam), call `add()` mid-prune, assert the new account survives.
- **No test for `AIUsagePoller.stop()` mid-tick.** Trigger a tick, stop, assert no leftover error message in `fetchErrors`. As written, the test would fail.
- **No test for header sanitization round-trip through a real `URLRequest`.** The unit tests pass strings to `sanitizeHeaderValue`; nothing verifies that the sanitized value survives `URLRequest.setValue` and the underlying CFNetwork stack without re-mutating it. Low-risk but the sanitizer is the privacy seam.
- **No test for the Codex `parseWindow` "string in `used_percent`" misleading-zero case.** Testing this would have surfaced the silent-zero behavior.
- **No test for `AIUsagePoller`'s status-fetch cadence (`tickCounter % 5 == 0`).** Easy to break with an off-by-one in a future refactor.
- **No assertion that the AppDelegate gate `if !isRunningUnderXCTest { ... }` actually prevents the poller from starting under XCTest.** A behavioral seam test (or at least an `assertNetworkAccess()` style trap inside `runTick`) would catch a regression that accidentally lets tests reach the network.
- **No `os_log` of `pruneOrphanAccountsIfNeeded` decisions.** Operations debugging will be impossible if a user reports "my accounts vanished after restart."

---

## The Nits

- `AIUsageEditorSheet.save()`: the catch ladder is `AIUsageStoreError` → `LocalizedError` → `Error`. Since `AIUsageStoreError` already conforms to `LocalizedError`, the explicit first branch is redundant. Not wrong; just dead code.
- `AIUsageRegistry.all` is recomputed on every read. Trivial but a `static let all: [AIUsageProvider] = [Providers.claude, Providers.codex]` is the same line count and avoids the recompute. Keep computed if you intend to swap providers in tests; otherwise prefer `let`.
- `AIUsagePoller`'s `tickGeneration &+= 1` uses `&+=` for overflow safety. Fine, but the field is `Int` and even at 1 tick/sec we won't hit overflow in any human lifetime. Mild over-engineering.
- `AIUsageAccountStore.persist(_:)` writes to `UserDefaults` synchronously on the main actor. Fast-typing the editor while pressing Cmd-S won't matter, but if account counts ever grow, batch the write or move to disk. Not today's problem.
- `AIUsageColorSettings.color(for:)` constructs three `Color(usageHex:)` instances every call (once per bar render). With multiple bars and many accounts this is more allocation than needed. Cache.
- `AIUsagePopover.severityColor` returns `.red` for both "critical" and "major". The status ranking distinguishes these with severity 4 vs 3 elsewhere. UI parity bug — minor.
- The CLAUDE.md rule "default to colons/commas/periods; em-dashes read as AI-generated" — the docs and inline comments in this branch use em-dashes liberally (`docs/ai-usage-monitoring.md`, multiple in source comments). Not a code defect, but a style miss against the operator's stated preference.
- `AIUsagePoller.runTick` on empty accounts case: clears `incidents`, `statusLoaded`, `statusFetchFailed`, `statusHasSucceeded` whole-cloth. Correct, but losing the "last successful status" shown in docs as a feature ("The poller retries every five minutes and surfaces the last successful fetch in the meantime") — when the user removes their last account and adds a new one, that last successful status snapshot is gone. Likely fine; flagging.
- `AIUsageFooterView.providerSection` uses `UserDefaults.standard.bool(forKey:)` inside the body for the collapsed-state default. Reading defaults inside a SwiftUI view body is an anti-pattern (no observability, fires on every redraw). Move to `@AppStorage` per provider, or to the store. Doesn't break today.

---

## Numbered Findings

### Blockers (will cause production incidents or data loss)

1. **(B1)** `AIUsageAccountStore.pruneOrphanAccountsIfNeeded` race vs `add(...)` can silently destroy a user-added account and leak its Keychain credential. (`Sources/AIUsage/AIUsageAccountStore.swift:135-151`)
2. **(B2)** `AIUsageAccountStore.load()` silently resets accounts to empty on any decode failure with no log, no recovery, no UI surface. Single bad write = all accounts orphaned. (`Sources/AIUsage/AIUsageAccountStore.swift:118-128`)

### Important (will cause bugs or poor UX)

3. **(I1)** Sidebar popover Add and Edit buttons are no-op stubs. The most prominent user entry point doesn't work. (`Sources/AIUsage/UI/AIUsageFooterView.swift:107-108`)
4. **(I2)** `.sheet(item:)` keyed on provider id leaks `@State` between consecutive edits of two accounts on the same provider; user sees previous account's data. (`Sources/c11App.swift` sheet wiring + `Sources/AIUsage/UI/AIUsageEditorSheet.swift:117-143`)
5. **(I3)** `AIUsagePoller.stop()` does not bump generation or special-case `CancellationError`; in-flight cancelled fetches write "Network error" / "Could not fetch usage." into `fetchErrors`. State persists after stop. (`Sources/AIUsage/AIUsagePoller.swift:107-119, 246-260`)
6. **(I4)** `CodexAIUsageFetcher.parseWindow` returns `0` for any non-numeric `used_percent` (`toNumber` swallows it), silently displaying a misleading "0%" instead of an error. (`Sources/AIUsage/CodexAIUsageFetcher.swift:117-156`)
7. **(I5)** `refreshNow()` is silently demoted to non-forced when a tick is already in flight; manual refresh may not refresh status pages or may be skipped on visibility flicker. (`Sources/AIUsage/AIUsagePoller.swift:121-149`)

### Potential (code smells, missing tests, things that bite later)

8. **(P1)** No test exercises the popover Add/Edit flow; the dead-button bug shipped because nothing covered it.
9. **(P2)** No test for the `load()` decode-failure path or the prune-vs-add race.
10. **(P3)** `testStartIsIdempotent` under-asserts (timing window where ticks haven't fired yet); `testColorForPercentBoundsAreClamped` asserts nothing. Both pass even if the code is broken.
11. **(P4)** `AIUsageHTTP.sanitizeHeaderValue` quietly drops `;` and `,`. Safe today, foot-gun for future tokens.
12. **(P5)** `Color.rgbComponents` falls back to black on color-space failure, no log; user-customized weird-gamut colors could pull interpolation toward black.
13. **(P6)** `ISO8601DateFormatter` instances allocated per parse call — cheap optimization, easy `static let`.
14. **(P7)** `AIUsagePopover.severityColor` collapses `critical` and `major` to the same color; the rest of the system distinguishes them.
15. **(P8)** `AIUsageFooterView` reads `UserDefaults` from inside the body; should be `@AppStorage`/observable.
16. **(P9)** No `os_log` in `pruneOrphanAccountsIfNeeded` or `load()` — diagnostics-blind when users report "my accounts vanished."
17. **(P10)** Em-dashes are used liberally in docs and inline comments, contrary to the operator's stated style preference.

---

## Phase 5 — Validation Pass

- **(B1) prune race** ✅ Confirmed by reading `AIUsageAccountStore.swift:135-151` and walking the `@MainActor` suspension-point semantics. Each `await probePresenceAsync` suspends; any other main-actor work (including `add()` mutating `accounts`) interleaves. The closing `accounts = survivors; try? persist(survivors)` then writes the stale set. Reproducible by adding a sleep to `probePresenceAsync` and adding via the editor mid-prune.
- **(B2) silent decode reset** ✅ Confirmed at `Sources/AIUsage/AIUsageAccountStore.swift:118-128`: `} catch { accounts = [] }` with no logging.
- **(I1) popover dead buttons** ✅ Confirmed at `Sources/AIUsage/UI/AIUsageFooterView.swift:107-108`. `onAdd: {}, onEdit: { _ in }`. The popover's Add/Edit buttons set `isPresented = false` then call the stub, so the user sees the popover dismiss and nothing else. Reproducible by wiring an account and clicking the ellipsis menu's "Add account" entry.
- **(I2) sheet state leak across edits** ✅ Confirmed by reading `c11App.swift` `.sheet(item: $aiUsageEditorProvider)` and `AIUsageEditorSheet.loadExistingIfNeeded`. The load-only-fills-empties guard (`if (values[key] ?? "").isEmpty`) is explicitly designed to not clobber user keystrokes — but it also means stale values from a prior edit persist when SwiftUI reuses the view (same provider id sheet identity). `displayName = account.displayName` does run unconditionally, so name updates; values do not.
- **(I3) stop() leaves user-visible errors** ✅ Confirmed by tracing `stop()` → `inFlightTask?.cancel()` → URLSession throws `URLError(.cancelled)` → `AIUsageHTTP.getJSONObject` re-throws as `CancellationError` (the explicit URLError check). Wait — re-check: `AIUsageHTTP.swift:51-55` catches `URLError(.cancelled)` and re-throws as `CancellationError()`. Then in `ClaudeAIUsageFetcher.swift:105-106` (and Codex fetcher analogously) `catch is CancellationError { throw CancellationError() }` re-throws. Then in `AIUsagePoller.runTick` per-account catch: `localizedFetchErrorMessage` is called on `CancellationError`. None of its branches match (it's not `AIUsageStoreError`, not `AIUsageFetchTimeoutError`, not an `AIUsageAppOwnedError`). Falls through to `genericFetchFailureString()` → "Could not fetch usage." Written into `newErrors`, then assigned to `fetchErrors`. ⬇️ Real but lower priority than initially thought, because: stop() is currently only called from `applicationWillTerminate`; the user never sees the error. Still important to fix because the seam is fragile and the next caller of stop() will hit it.
- **(I4) Codex zero-on-garbage** ✅ Confirmed at `CodexAIUsageFetcher.swift:152-157`: `toNumber` returns `0` for unrecognized types (no throw, no log).
- **(I5) refreshNow demotion** ✅ Confirmed at `AIUsagePoller.swift:126-133`: when `inFlightTask != nil`, `hasPendingTick = true` and the function returns; force is dropped on the floor. The follow-up scheduled at `:140-145` does not preserve `force`.
- **(P1)** ✅ Confirmed: no test in `c11Tests/AIUsageTests.swift` exercises `AIUsagePopover` actions.
- **(P2)** ✅ Confirmed by reading the test file end-to-end.
- **(P3)** ✅ Confirmed: `testStartIsIdempotent` reads `ticks` synchronously after `start()` returns, but `tickBody` is invoked from a Task that may not have run. `testColorForPercentBoundsAreClamped` has no `XCTAssert*` calls.
- **(P4)** ✅ Confirmed at `AIUsageHTTP.swift:28-31`.
- **(P5)** ✅ Confirmed at `AIUsageColorSettings.swift:148-152`.
- **(P6)** ✅ Confirmed at `AIUsageISO8601DateParser.swift:6-15`: two `ISO8601DateFormatter` instances are constructed per parse call.
- **(P7)** ✅ Confirmed at `AIUsagePopover.swift:109-117`.
- **(P8)** ✅ Confirmed at `AIUsageFooterView.swift:48-50`.
- **(P9)** ✅ Confirmed.
- **(P10)** ✅ Confirmed by spot-reading `docs/ai-usage-monitoring.md` and source comments.

---

## Closing

**Is this code ready for production? Not as-is.** I would not mass-deploy this to 100k users.

**Minimum to land:**
1. Fix the popover Add/Edit no-op stubs (I1). This is user-visible breakage on the most prominent surface; it must work before this ships.
2. Fix the prune-vs-add race (B1) and surface load() decode failures (B2). Either snapshot account ids at start of prune and only filter on those (don't clobber any added during the await), or take a barrier — e.g., set a `pruneInFlight` flag that `add()` can wait on, or compose prune as a sequence of single-account checks each guarded by a fresh read of `accounts`.
3. Fix the editor sheet state leak (I2). Easiest fix: key the sheet on a composite identity like `"\(provider.id)|\(editingAccount?.id ?? UUID())"` so SwiftUI re-creates the view per account. Alternatively, reset `@State` in `.task` regardless of editingAccount.
4. Fix Codex `parseWindow` silent-zero (I4): treat unrecognized `used_percent` as a decode error so the user sees "Could not read Codex usage payload" rather than a misleading 0%.
5. Add tests covering the popover flow, the prune race, the load() decode-failure path, and the Codex garbage-percent case.

**Should also fix before broader release:**
- (I3) and (I5) — the stop() / refreshNow() interaction. Both are fixable in <50 lines.
- (P3) — replace the broken/empty tests with real ones.
- The em-dashes in docs/comments — small, but the operator has flagged this as a recurring style miss.

**What's good and should stay:**
- Keychain attributes (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable=false`).
- `AIUsageSecret` redaction (description / debugDescription / customMirror).
- Ephemeral `URLSession` with cookie/cache off, header sanitization seam.
- The `allowedHosts` allowlist for status pages plus host-shape rejection.
- The `isRunningUnderXCTest` gate on poller start.
- Privacy doc colocated with code (`docs/privacy-endpoints.md`).
- The `AIUsageAppOwnedError` marker so we don't leak raw OS error wording to UI.
- Per-account Keychain item + UUID + per-provider service name; clean removal semantics.
- Localization at every call site with `String(localized:defaultValue:)`.

The bones are right. The flesh has gaps. Get the popover working, fix the two store integrity bugs, fix the editor sheet identity, and add the missing tests; then this is shippable.
