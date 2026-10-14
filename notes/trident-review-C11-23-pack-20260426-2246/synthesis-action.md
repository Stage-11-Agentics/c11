# Action-Ready Synthesis: C11-23

## Verdict
fix-then-merge

The 9 reviewers split between "merge-ready with nits" (Standard-Claude, Standard-Codex, Standard-Gemini lean here) and "not production-ready" (Critical-Claude, Critical-Codex, Critical-Gemini explicitly say they would not deploy as-is). Bias toward the more cautious view: there is one strict CI-breaking blocker (test file missing imports), one strict UX blocker (sidebar popover Add/Edit are no-op stubs), and several Important bugs (Codex silent-zero on malformed payloads, missing reset countdown promised by docs, store integrity issues). The architectural foundations are sound (Keychain attributes, ephemeral sessions, host allowlist, redaction, hot-path discipline, XCTest gate). Merge once the items in "Apply by default" are fixed.

## Apply by default

### Blockers (merge-blocking)

- **B1: `c11Tests/AIUsageTests.swift` missing `import Security` and `import SwiftUI` — test target will not build**
  - Location: `c11Tests/AIUsageTests.swift:1-2`
  - Problem: File only imports `XCTest` and `@testable import c11`, but uses Security symbols (`kSecClass`, `kSecClassGenericPassword`, `kSecAttrService`, `SecItemDelete`, `CFDictionary`) at line ~12 and SwiftUI `Color` at lines 388/394-397 (extension `Color` plus `Color(usageHex:)`). No `@_exported` re-export exists in `Sources/`. Sibling test files that use these symbols import them explicitly.
  - Fix: Add `import Security` and `import SwiftUI` immediately after `import XCTest` at the top of the file.
  - Sources: critical-codex (Blocker #1, validated by orchestrator note).

- **B2: Sidebar popover "Add account" and per-account "Edit" buttons are wired to no-op closures**
  - Location: `Sources/AIUsage/UI/AIUsageFooterView.swift:107-108` (`onAdd: {}`, `onEdit: { _ in }`)
  - Problem: `AIUsagePopover` delegates its Add/Edit buttons entirely to these closures (`Sources/AIUsage/UI/AIUsagePopover.swift:79-95`). Clicking dismisses the popover and does nothing. This contradicts `docs/ai-usage-monitoring.md:20-21` ("the ellipsis menu can add another account or edit an existing one"). The footer popover is the most prominent user-facing entry point for this feature.
  - Fix: Wire the closures to present the existing `AIUsageEditorSheet`. The cleanest path is to lift `editorAccount`/`editorProvider` state into `AIUsageFooterView` (mirroring the Settings page pattern at `c11App.swift:4974-4980`) and attach a `.sheet(item:)` modifier to the footer view so Add and Edit actions set the appropriate provider/account. Alternatively, route through a delegate or environment-injected callback that the app can connect to its existing settings sheet binding. Make sure the editor opens for the right provider in both cases (Add: clear `editorAccount`, set `editorProvider = section.provider`; Edit: set both to the tapped account/provider).
  - Sources: standard-codex Important #1, standard-gemini Blocker #2, critical-claude I1, critical-codex Important #1.

### Important (land in same PR)

- **I1: Codex `parseWindow` silently displays "0%" on malformed `used_percent` instead of failing closed**
  - Location: `Sources/AIUsage/CodexAIUsageFetcher.swift:120-121, 152-157`
  - Problem: `parseWindow` calls `clamp(toNumber(usedRaw))`. `toNumber` returns `0` for `nil`, `NSNull`, `Bool`, `String`, or any non-number. If OpenAI changes the schema, returns null, returns a string, or omits the field, c11 shows "0% used" — actively misleading the operator at the moment they most need accurate quota state. Claude's analogous parser already throws `.decoding` for these cases (`ClaudeAIUsageFetcher.swift:134-148`).
  - Fix: Make `parseWindow` reject missing/non-numeric `used_percent` by mirroring `ClaudeAIUsageFetcher.parseUtilization`: throw `CodexAIUsageFetchError.decoding` when the value is missing, `NSNull`, `Bool`, or not convertible to an integer. Clamp only after a successful numeric parse. Add a unit test asserting that `nil`, `NSNull()`, `true`, and `"oops"` all produce `.decoding` rather than a 0% result.
  - Sources: standard-codex Important #2, critical-claude I4, critical-codex Important #2.

- **I2: Reset countdown promised by docs is never rendered in the UI**
  - Location: `Sources/AIUsage/UI/AIUsageFooterView.swift:150-172` (the `bar` function), `Sources/AIUsage/UI/AIUsageResetLabel.swift` (helper exists but is unused)
  - Problem: `docs/ai-usage-monitoring.md:18` promises "the next reset window when known". `AIUsageWindow.resetsAt` is populated by both fetchers (`ClaudeAIUsageFetcher.swift:126`, `CodexAIUsageFetcher.swift:131-140`), and `providerUsageResetLabel` exists at `AIUsageResetLabel.swift:10-27`, but the footer's `bar` view ignores the `isSession` parameter and renders only label/bar/percent. No call site uses the helper.
  - Fix: Either render the reset label or remove the promise from docs. Recommended: render compact reset text under or beside each bar. Use `providerUsageResetLabel(window:, isSession:, now: Date())` and format the result with a localized relative-time formatter (e.g. `RelativeDateTimeFormatter`). Keep refresh granularity at minute-level (do not run a per-second timer that thrashes the sidebar). Suggested layout: append a trailing small-caps secondary `Text` to the `HStack` in `bar`, only when the label resolves to `.resetsAt(date)`. Add a localized string for each `ProviderUsageResetLabel` case.
  - Sources: standard-codex Important #3, standard-gemini Blocker #1, critical-codex Important #3, evolutionary-codex Concrete Suggestion #2.

- **I3: `AIUsageAccountStore.pruneOrphanAccountsIfNeeded` race against `add()` can erase a freshly-added account**
  - Location: `Sources/AIUsage/AIUsageAccountStore.swift:135-151`
  - Problem: The prune iterates `accounts` and `await`s `probePresenceAsync` per account. `@MainActor` suspends across each await; a user's `add()` between read-and-write inserts an account that is then clobbered when the prune writes `accounts = survivors` followed by `try? persist(survivors)`. Both in-memory list and the persisted UserDefaults blob lose the new account; the Keychain credential remains as garbage.
  - Fix: Compute `survivors` from a snapshot taken at start, then do not blindly overwrite `accounts`. Instead, after the awaits complete, take a fresh read of `accounts`, compute `keep = accounts.filter { account in !accountsToRemove.contains(account.id) }` where `accountsToRemove` is the set of ids that came back as `errSecItemNotFound`, and write that filtered list. This way any concurrent additions are preserved. Also add an `os_log(.info, ...)` line when prune actually removes anything, so operations debugging is possible when a user reports "my accounts vanished."
  - Sources: critical-claude B1.

- **I4: `AIUsageAccountStore.load()` silently resets accounts to empty on decode failure**
  - Location: `Sources/AIUsage/AIUsageAccountStore.swift:118-128`
  - Problem: `} catch { accounts = [] }` — if a forward-incompatible schema bump or a bad write corrupts the UserDefaults blob, every account vanishes from memory with no log, no error UI, and every Keychain entry becomes an orphan. The next prune cycle then sees zero accounts and skips its keychain probes. Users lose visibility into their stored credentials with no diagnostic trail.
  - Fix: In the `catch`, emit `os_log(.error, log: log, "aiusage: failed to decode account index, %{public}@", String(describing: error))` (using the same `OSLog` subsystem `com.stage11.c11`, category `aiusage` already in use by the poller). Do not delete the underlying UserDefaults data — leave the raw blob intact so a future migration or manual recovery can read it; just leave `accounts = []` for this run. Add a unit test that writes a deliberately malformed blob to a test `UserDefaults` instance and asserts `load()` does not throw and the malformed bytes are still present afterwards.
  - Sources: standard-gemini Important #3, critical-claude B2.

- **I5: Status-page fetch in `runTick` is not wrapped in `runWithTimeout`, unlike usage fetches**
  - Location: `Sources/AIUsage/AIUsagePoller.swift:210-227`
  - Problem: Per-account usage fetches at line 184 are wrapped in `runWithTimeout(perFetchTimeout)`, but the status-page `fetchStatus()` at line 215 is awaited directly. The underlying `URLSession` timeouts (10s request/resource via `AIUsageHTTP.makeSession`) will catch most stalls, but the divergence from the usage-fetch pattern is fragile: any future change that drops or weakens the URLSession timeout, or any subtle async bug in `fetchStatus`, can hold the tick indefinitely. The 20s `perFetchTimeout` is the documented contract.
  - Fix: Wrap the status fetch in `runWithTimeout(perFetchTimeout)` exactly like the usage fetch above it: `let result = try await runWithTimeout(perFetchTimeout) { try await fetchStatus() }`. Treat `AIUsageFetchTimeoutError` as a status-fetch failure (set `statusFetchFailed[provider.id] = true`).
  - Sources: critical-gemini Blocker #1.

- **I6: Codex `parseWindow` strict-parses `secondary_window` — accounts without a weekly limit will fail entire payload**
  - Location: `Sources/AIUsage/CodexAIUsageFetcher.swift:113`
  - Problem: `let session7d = try parseWindow(rateLimit["secondary_window"] as? [String: Any])`. If `secondary_window` is missing (e.g., free tier, certain enterprise plans), `parseWindow(nil)` throws `.decoding` and the whole Codex payload fails, breaking the UI for those users. Note that primary_window has the same strict treatment, but is more reliably present per docs.
  - Fix: Treat missing `secondary_window` as a soft case. Two reasonable shapes — pick one:
    1. (recommended) Keep `AIUsageWindows.week` non-optional but degrade to a synthetic empty window: `AIUsageWindow(utilization: 0, resetsAt: nil, windowSeconds: 604_800)` when the key is absent. The footer's reset-label logic for `weekResetUnknown` (already implemented at `AIUsageResetLabel.swift:21-24`) would render appropriately once I2 is done.
    2. Make `AIUsageWindows.week` optional (`week: AIUsageWindow?`) and skip the row when nil. This is a wider model change that ripples into the footer; only do it if option 1 produces misleading "0%" displays.
    Add a unit test asserting that a payload with `primary_window` but no `secondary_window` parses successfully.
  - Sources: critical-gemini Blocker #2.

- **I7: Editor sheet leaks state across consecutive edits of two accounts on the same provider**
  - Location: `Sources/c11App.swift:4974` and `Sources/AIUsage/UI/AIUsageEditorSheet.swift:117-143`
  - Problem: `.sheet(item: $aiUsageEditorProvider)` keys identity on `AIUsageProvider.id` (`"claude"` / `"codex"`). Editing Account A then Account B (same provider) sets the same identity value, so SwiftUI reuses the existing sheet view and its `@State`. `loadExistingIfNeeded` only fills empties (`if (values[key] ?? "").isEmpty { values[key] = value }`) by design (to not clobber user keystrokes), which means stale credential field values from the previous edit persist. `displayName` is overwritten unconditionally, but the secret/credential fields leak.
  - Fix: Make the sheet identity composite so SwiftUI re-creates the view per edited account. Cleanest approach: change the sheet binding driver from `aiUsageEditorProvider` to a composite struct, e.g.:
    ```swift
    struct AIUsageEditorRequest: Identifiable {
        let id: String  // provider.id + "|" + (account?.id.uuidString ?? "new")
        let provider: AIUsageProvider
        let account: AIUsageAccount?
    }
    @State private var aiUsageEditorRequest: AIUsageEditorRequest?
    .sheet(item: $aiUsageEditorRequest) { request in
        AIUsageEditorSheet(provider: request.provider,
                           editingAccount: request.account,
                           onClose: { aiUsageEditorRequest = nil })
    }
    ```
    Update all call sites (Settings page edit/add buttons, and the new footer popover wiring from B2) to set/clear `aiUsageEditorRequest` instead of the separate provider/account pair.
  - Sources: critical-claude I2.

- **I8: `refreshNow()` silently demotes to non-forced when a tick is already in flight**
  - Location: `Sources/AIUsage/AIUsagePoller.swift:121-149`
  - Problem: `scheduleTick(force: true)` enters, sees `inFlightTask != nil`, sets `hasPendingTick = true` and returns; the manual force is dropped. The follow-up `scheduleTick(force: false)` at line 143 cannot recover the original force intent — status pages will not be re-fetched and, if visibility flicks off in the brief window, the tick is skipped entirely.
  - Fix: Track pending force separately. Add a `pendingForce: Bool` instance var; in `scheduleTick(force:)` when `inFlightTask != nil`, set `hasPendingTick = true` and `pendingForce = pendingForce || force`. After the in-flight task completes, the follow-up call becomes `self.scheduleTick(force: self.pendingForce)`, then reset `pendingForce = false`.
  - Sources: critical-claude I5, critical-gemini Potential #1, standard-codex Important #4 (related, partially overlapping observation about pending-tick state).

### Straightforward mediums

- **M1: `AIUsageEditorSheet.canSave` does not trim whitespace from credential values before validation, but `save()` does**
  - Location: `Sources/AIUsage/UI/AIUsageEditorSheet.swift:101-115` vs `:148`
  - Problem: `canSave` checks `value.isEmpty` and runs `field.validate(value)` against the raw user-typed string. `save()` then trims the values via `mapValues { $0.trimmingCharacters... }`. A user pasting `"  sk-ant-xxxx  "` may have `canSave` reject the value even though the saved form would be valid; conversely, `"   "` (all whitespace) bypasses the `value.isEmpty` check and goes to validators that may or may not catch it.
  - Fix: In `canSave`, trim each value before the empty-check and before passing to `validate`: `let value = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)`. This mirrors what `save()` already does at line 148.
  - Sources: standard-claude Important #9, critical-codex Nit #3.

- **M2: Orphan accounts render twice in Settings (main account list and orphan card)**
  - Location: `Sources/AIUsage/UI/AIUsageSettingsSection.swift:21, 71-74`
  - Problem: The main `ForEach(store.accounts)` at line 21 iterates every account, including those whose `providerId` is no longer in the registry. `accountRow` then renders the row with a broken Edit button (`editorProvider = nil` because `provider(for: account)` returns nil), and `orphanAccounts` independently renders the same account as a separate "Unknown provider" card. Net: an orphan appears twice with one broken control.
  - Fix: Filter the main `ForEach` to exclude orphans: `ForEach(store.accounts.filter { provider(for: $0) != nil })`. The orphan card path at line 28 continues to handle the unknown-provider case.
  - Sources: standard-claude Important #1.

- **M3: `AIUsagePopover.refreshNow()` button hardcodes `AIUsagePoller.shared` instead of the injected `poller`**
  - Location: `Sources/AIUsage/UI/AIUsagePopover.swift:99`
  - Problem: The view receives `@ObservedObject var poller: AIUsagePoller` but the Refresh button calls `AIUsagePoller.shared.refreshNow()`. Functionally identical today (the only call site passes `.shared`), but defeats the DI seam and will break any future preview/test that injects a non-shared poller.
  - Fix: Replace `AIUsagePoller.shared.refreshNow()` with `poller.refreshNow()`. Same change in `AIUsageEditorSheet.swift:159` (`AIUsagePoller.shared.refreshNow()` after save) — though there the sheet does not currently have a poller binding; either inject one or leave that call alone (lower priority than the popover one).
  - Sources: standard-claude Important #3, critical-claude (final Nits list, item about direct shared accesses).

- **M4: `Providers.helpDocURL` fragments do not match doc headings**
  - Location: `Sources/AIUsage/ClaudeAIProvider.swift` and `Sources/AIUsage/CodexAIProvider.swift` (the `helpDocURL` constants pointing at `...#claude` and `...#codex`)
  - Problem: The doc `docs/ai-usage-monitoring.md` does not contain headings rendering to those slugs (e.g. `## Add a Claude account` renders to `#add-a-claude-account`). The link fragments are dead. Additionally, no UI surface in the diff currently consumes `helpDocURL`.
  - Fix: Either (a) add `## Claude` and `## Codex` heading anchors at the relevant sections of `docs/ai-usage-monitoring.md`, or (b) point `helpDocURL` at the actual existing heading slugs. Since no code currently renders these URLs, option (a) is the minimum-friction path.
  - Sources: standard-claude Important #13.

- **M5: `AIUsageAccountStore.remove()` deletes Keychain item before persisting; if persist fails, Keychain is gone**
  - Location: `Sources/AIUsage/AIUsageAccountStore.swift:95-108`
  - Problem: `remove()` calls `AIUsageKeychain.delete` first, then `accounts = next`, then `try persist(next)`. If `persist` throws, the in-memory list and the Keychain are gone but the UserDefaults blob still references the removed account. The `pruneOrphanAccountsIfNeeded` helper would clean this up next launch, so the failure mode is "user sees stale orphan briefly," not data loss — but the asymmetry with `add()` (which rolls back the Keychain write on persist failure at lines 56-60) is a foot-gun.
  - Fix: Reorder to persist first, delete second. Snapshot the previous list, persist the new list, and only on persist success delete the Keychain item. If the Keychain delete then fails, the next prune will remove the now-orphaned in-memory entry. Or wrap in a do/catch that re-inserts on persist failure (less clean).
  - Sources: standard-claude Important #20.

- **M6: `AIUsageFooterView.providerSection` reads `UserDefaults.standard.bool` from inside the SwiftUI view body**
  - Location: `Sources/AIUsage/UI/AIUsageFooterView.swift:48-50`
  - Problem: `let isCollapsed = collapsed[section.provider.id] ?? UserDefaults.standard.bool(forKey: collapsedKey)`. Reading defaults inside a view body is a SwiftUI anti-pattern: the view re-evaluates whenever `store.accounts`, `poller.snapshots`, `poller.fetchErrors`, `poller.isRefreshing`, or `colorSettings` change (every tick = up to once a minute). The read is cheap but observability is wrong (changing the default does not trigger a redraw) and it executes more often than needed.
  - Fix: Replace with `@AppStorage("c11.aiusage.collapsed.<id>")` per provider. Easiest mechanic: extract the section into its own subview that takes a `provider.id` parameter and uses `@AppStorage(wrappedValue: false, "c11.aiusage.collapsed.\(providerId)")` declared as a `let` parameter. Or hold a `[String: Bool]` `@StateObject` view model that reads UserDefaults once on init. Either eliminates the in-body read.
  - Sources: standard-claude Important #6, critical-claude P8, evolutionary-claude (anti-patterns #4).

- **M7: 50ms `Task.sleep` calls in `AIUsagePollerLifecycleTests` will be flaky on loaded CI**
  - Location: `c11Tests/AIUsageTests.swift:477, 481`
  - Problem: Two `Task.sleep(nanoseconds: 50_000_000)` calls wait for the forced tick to drain. The poller already has a `tickBody` constructor seam (`AIUsagePoller.swift:35-36, 66`) that the tests use to count ticks. Replace the sleeps with deterministic synchronization so CI scheduling jitter cannot make the tests flake.
  - Fix: Convert to `XCTestExpectation`s fulfilled from inside the `tickBody` closure, then `await fulfillment(of: [...], timeout: 1.0)`. Or have `tickBody` signal an `AsyncStream` continuation the test consumes. Either pattern eliminates wall-clock waits while keeping the same coverage.
  - Sources: standard-claude Important #10, standard-codex Potential #6, evolutionary-codex Concrete Suggestion #9.

- **M8: `AIUsagePollerLifecycleTests.testStartIsIdempotent` and `AIUsageColorSettingsTests.testColorForPercentBoundsAreClamped` assert nothing meaningful**
  - Location: `c11Tests/AIUsageTests.swift` (testStartIsIdempotent body, testColorForPercentBoundsAreClamped body)
  - Problem: `testStartIsIdempotent` reads `ticks` synchronously after `start()` returns, but `tickBody` is invoked from a child Task that has not run yet — both readings of `ticks` are 0 regardless of correctness. `testColorForPercentBoundsAreClamped` calls `color(for:)` with various values and discards the result; there are no `XCTAssert*` calls, so it is a code-coverage prop that passes even when the code is broken. Per CLAUDE.md test policy, this is on the edge of "fake regression test."
  - Fix: For the idempotency test, await tick body invocations (after M7 lands, the same expectation pattern works). Assert that `start(); start();` does not double the tick count (only one `tickBody` invocation should occur from the second `start()`). For the color test, pick representative inputs at each boundary (e.g. `color(for: 0)`, `color(for: lowMidThreshold-1)`, `color(for: lowMidThreshold)`, `color(for: midHighThreshold)`, `color(for: 100)`, `color(for: 200)`) and assert the produced colors equal the expected catalog entries (or the interpolated values when interpolation is on).
  - Sources: standard-claude Important #11, critical-claude P3.

### Evolutionary clear wins

- **EW1: Promote `AIUsageAppOwnedError` to a top-level `C11AppOwnedError` and adopt repo-wide for user-facing async pipelines**
  - Location: `Sources/AIUsage/AIUsagePoller.swift:270-277` (currently file-private to AIUsage)
  - Problem: The marker protocol is a load-bearing privacy/UX seam — only errors that opt in via this protocol can have their `errorDescription` surfaced to the UI; everything else falls back to a generic catalog string. This prevents `URLError`'s "The Internet connection appears to be offline" from leaking. The pattern is good and should be the default for any future user-facing error path, not AIUsage-specific.
  - Fix: Move the protocol to its own file `Sources/Errors/C11AppOwnedError.swift`, rename to `C11AppOwnedError`, keep the same single requirement (`var isAppOwned: Bool { get }`). Update `ClaudeAIUsageFetchError`, `CodexAIUsageFetchError`, and `AIUsageStoreError` to conform to the renamed protocol. Update `AIUsagePoller.localizedFetchErrorMessage` to check for `C11AppOwnedError`. This is a 30-line refactor with no behavior change and clears a path for the next user-facing error type that lands.
  - Sources: evolutionary-claude High Value #4 (concrete suggestion), evolutionary-gemini Emerging Patterns (App-Owned Error Masking).

## Surface to user (do not apply silently)

- **S1: Concurrent (TaskGroup) usage polling vs current serial loop**
  - Why deferred: scope-creep
  - Summary: `AIUsagePoller.runTick` iterates accounts serially; with N accounts each up to 20s timeout, refresh time grows linearly. Three reviewers flag it (standard-codex Potential #5, critical-codex Potential #1, evolutionary-codex Concrete Suggestion #3). Today's two-account user has no problem, but the docs explicitly allow many accounts and the `isRefreshing` semantics get muddy when one slow account holds the whole refresh state. The fix is a `withThrowingTaskGroup` fanout that publishes results in a single batch on the main actor; the current generation-tagged cancellation pattern needs a careful port. Worth doing, but not in the same PR as the blocker fixes — it will rewrite the heart of `runTick`.
  - Sources: standard-codex Potential #5, critical-codex Potential #1, evolutionary-codex Concrete Suggestion #3.

- **S2: Path-traversal-shaped concern in Claude org-id URL encoding**
  - Why deferred: design-needed (single reviewer; mitigated by validators)
  - Summary: `ClaudeAIUsageFetcher.swift:75-78` uses `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)`, which does not encode `/` or `.`. `ClaudeAIValidators.isValidOrgId` already restricts the input shape. Critical-Gemini flags this as a defense-in-depth concern: if the validator ever loosens, a tampered Keychain entry could traverse paths. Real fix is to subtract `/` and `.` from the allowed character set or to switch to `URLComponents` path-component construction. Single-reviewer, requires confirming the validator's exact regex, and the threat model is "attacker has Keychain write access" — at which point they have larger problems. Worth the user's eye.
  - Sources: critical-gemini Important (Path Traversal).

- **S3: Stale fetch error after credential update until next tick**
  - Why deferred: subjective UX call
  - Summary: After a user fixes bad credentials in the editor and saves, `refreshNow()` runs another tick, but the previous error remains in `fetchErrors` until the new tick's `fetchErrors = newErrors.filter…` reassignment at `AIUsagePoller.swift:207`. Between save and tick completion the user sees the stale error. Fix candidate: clear `fetchErrors[id]` on `store.update`. Whether this is the right UX (immediate optimistic clear vs honest "we haven't re-fetched yet") is a design call.
  - Sources: standard-claude Important #8.

- **S4: `pruneOrphanAccountsIfNeeded` runs from `init` via `Task` — brief window where UI shows orphans before prune fires**
  - Why deferred: subjective; acceptable startup behavior
  - Summary: Between `load()` returning and the prune Task running, `accounts` is populated and the UI may render briefly with orphan accounts before they're pruned. Standard-Claude flags this as acceptable; it's worth the user knowing the trade-off but not auto-fixing.
  - Sources: standard-claude Important #21.

- **S5: `AIUsageColorSettingsTests.testInterpolationOffMatchesDiscreteBuckets` underclaims (does not actually test cross-bucket boundaries)**
  - Why deferred: low-priority test improvement; could be bundled with M8 if desired
  - Summary: The test asserts `color(for: 10) ≈ color(for: 20)` to 0.001 tolerance, which only works because both are in the same bucket. The name promises something stronger (e.g., that `color(for: 84)` and `color(for: 86)` straddle the threshold).
  - Sources: standard-claude Important #11.

- **S6: `AIUsageHTTP.sanitizeHeaderValue` silently drops `;` and `,`**
  - Why deferred: subjective; safe today, foot-gun for unknown future tokens
  - Summary: Conservative for today's cookies/JWTs but a future provider with legitimate `;` or `,` in a token would have its credential silently corrupted. Critical-Claude suggests at minimum a code comment marking this as "tested-providers-only" rather than a generic header sanitizer; Critical-Codex suggests `CodexAIValidators.isValidAccountId` should reject `;` and `,` so input that would be silently mutated is rejected up front.
  - Sources: standard-claude #16, critical-claude (Nits, sanitize header), critical-codex Potential #3.

- **S7: `AIUsagePoller.stop()` does not bump generation or special-case `CancellationError`**
  - Why deferred: ambiguous severity; today only `applicationWillTerminate` calls `stop()` so user never sees the resulting "Could not fetch usage." messages
  - Summary: Cancelled in-flight fetches throw `URLError(.cancelled)` → `AIUsageHTTP` re-throws as `CancellationError` → `localizedFetchErrorMessage` falls through to the generic "Could not fetch usage." string and writes it to `fetchErrors`. The state survives because `stop()` does not clear snapshots/errors. Today this is invisible (app is exiting); tomorrow if `stop()` gets a non-terminal caller, errors will leak. Fixable in <50 LOC: bump `taskGeneration` in `stop()` and special-case `CancellationError` at the top of `localizedFetchErrorMessage`. Worth the user's call on whether to land now or wait for a non-terminal `stop()` use case.
  - Sources: critical-claude I3.

- **S8: `Color.rgbComponents` falls back to `(0,0,0)` on color-space conversion failure with no log**
  - Why deferred: theoretical (catalog colors all parse fine; only triggered by a custom user color in a weird color space)
  - Summary: `AIUsageColorSettings.swift:146-156` returns `(0,0,0)` when `usingColorSpace(.sRGB)` returns nil. Interpolation will then yank toward black silently. Could log + fall back to a sensible default (e.g., the named color the user picked), but this only matters if user-customized colors actually trip the path.
  - Sources: critical-claude P5.

- **S9: `AIUsageISO8601DateParser` allocates two `ISO8601DateFormatter` instances per call**
  - Why deferred: micro-perf; called every 5 min, not a hot path
  - Summary: `ISO8601DateFormatter` is documented as expensive to construct. Easy `static let` cache. Trivial PR but not on a hot path.
  - Sources: critical-claude P6.

- **S10: `AIUsagePopover.severityColor` collapses `critical` and `major` to the same red**
  - Why deferred: design call — does the user want them distinguished or grouped under "high impact"?
  - Summary: The `AIUsageStatusRanking` system distinguishes severities 4 vs 3 elsewhere; the UI does not. Trivial fix (different shades), but worth the user's design eye.
  - Sources: critical-claude P7.

- **S11: Em-dashes used liberally in docs/comments contrary to operator's stated style preference**
  - Why deferred: stylistic, not behavioral; user has a documented memory note about this
  - Summary: `docs/ai-usage-monitoring.md` and several inline comments use em-dashes. Critical-Claude flags this against the operator's stored preference (default to colons/commas/periods). Not a code defect; worth a sweep before tagging.
  - Sources: critical-claude P10.

- **S12: Test coverage for fetcher payload parsing is light**
  - Why deferred: scope (real coverage requires mocking transport or extracting parser seams)
  - Summary: Three reviewers flag that `c11Tests/AIUsageTests.swift` covers Keychain, redaction, validators, HTTP session config, status host rejection, colors, and basic poller lifecycle but not Claude/Codex payload parsing, footer popover callbacks, prune-vs-add race, `load()` decode-failure, `stop()` mid-tick, or `tickCounter % 5 == 0` cadence. The fix is to extract pure payload parsers (or inject a transport seam) and add fixture-driven tests. Land alongside I1/I3/I4/B2 tests, but the broader suite expansion is its own ticket.
  - Sources: standard-codex Potential #5, critical-claude (What's Missing list), critical-codex What's Missing, evolutionary-codex Concrete Suggestion #8.

- **S13: Localization catalog 1:1 audit deferred (recommend pre-tag spot check)**
  - Why deferred: spot-check task, not a code fix
  - Summary: Standard-Claude recommends a `grep` audit between `String(localized:)` call sites and `Resources/Localizable.xcstrings` keys before tagging a build, to confirm every English string has a catalog entry and every catalog entry has a call site.
  - Sources: standard-claude Important #15.

## Evolutionary worth considering (do not apply silently)

- **E1: Expose `AIUsagePoller.snapshots` (and incidents) via the c11 socket so agents can read their own quota**
  - Summary: The poller already publishes `snapshots`, `incidents`, `fetchErrors` as `@Published` properties. A small read-only socket command (`aiusage.snapshot`, `aiusage.incidents`) would expose this to agents running inside c11 panes. Per the threading policy, parse args off-main, snapshot dictionaries on main, return. This transforms the feature from "pretty numbers in the corner" into a coordination primitive: budget-aware launchers, self-throttling agents, quota-aware model routing.
  - Why worth a look: This is the move that aligns the feature with c11's "operator:agent pair is the unit" mission. Three of the three evolutionary reviewers independently nominate it as the highest-leverage next move.
  - Sources: evolutionary-claude #6 ("the highest-leverage move in the whole branch"), evolutionary-codex Strategic #7, evolutionary-gemini Concrete Suggestions #1.

- **E2: Extract `OcclusionAwareTimer` from `AIUsagePoller` as a reusable primitive**
  - Summary: The `DispatchSourceTimer` + `NSWindow.didChangeOcclusionStateNotification` + `inFlightTask`/`hasPendingTick` machinery at `AIUsagePoller.swift:79-105` is generic. Lift to `Sources/Concurrency/OcclusionAwareTimer.swift`. AIUsagePoller becomes a thin subscriber. Pays for itself the next time someone adds a polling subsystem (browser refresh, Lattice sync, build watcher). ~80 LOC refactor, no behavior change, low risk.
  - Why worth a look: c11 will keep adding polling subsystems; getting the visibility/lifecycle/cancellation contract right once is leverage.
  - Sources: evolutionary-claude High Value #1, evolutionary-codex Emerging Patterns + Leverage Points, evolutionary-gemini Concrete Suggestions #2.

- **E3: Centralize provider endpoint metadata into `AIUsageProvider` and validate `docs/privacy-endpoints.md` against it**
  - Summary: Today the privacy contract is distributed: usage URLs in fetchers, status hosts in `AIUsageStatusPagePoller.allowedHosts`, doc list in `docs/privacy-endpoints.md`. Add `declaredEndpoints: [AIUsageEndpoint]` (or similar) to `AIUsageProvider` so all three can converge on one source of truth. Cheaper while there are only two providers; expensive once a third lands. Could even add a CI check that yells when an outbound URL appears in code but not in the doc.
  - Why worth a look: Makes the "privacy-endpoints.md is the contract" claim enforceable rather than aspirational.
  - Sources: evolutionary-codex Concrete Suggestion #1, evolutionary-claude Leverage Points #3, evolutionary-claude Concrete Suggestions #5 (egress allowlist).
