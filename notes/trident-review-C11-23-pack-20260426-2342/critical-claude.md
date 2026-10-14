## Critical Code Review
- **Date:** 2026-04-26T23:42:00Z
- **Model:** Claude Sonnet 4.6 (claude-sonnet-4-6)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** e7987ee9
- **Linear Story:** C11-23
- **Review Type:** Critical/Adversarial — Second Pass (verify rework items, check regressions)

---

## The Ugly Truth

This is a genuine upgrade from the first pass. The fixes for I1, I3, I4, I5, I6, and I8 are mechanically correct and I verified each one. B2 is wired. I7 is implemented properly. The code is not fragile in the ways it was before.

That said, several fixes introduced new subtleties that deserve scrutiny. Two items are concerning enough to flag as Important, not minor. The remaining issues are real but lower stakes. No clear Blockers remain -- the code is broadly shippable if you accept the caveats below.

---

## What Will Break

### B2 / Editor Wiring: Double-population race in `loadExistingIfNeeded`

**Where:** `AIUsageEditorSheet.swift`, `loadExistingIfNeeded()` lines 130-154.

When a user opens an edit sheet, `loadExistingIfNeeded()` fires via `.task` and awaits `store.secret(for:)`. The code intentionally "only fills blanks" to avoid clobbering user keystrokes that land before the load completes:

```swift
for (key, value) in secret.fields {
    if (values[key] ?? "").isEmpty {
        values[key] = value
    }
}
```

This logic is sound for the keyboard case. But there is a second scenario: the user taps Edit on an account, the sheet appears, the load is still in flight, the user taps Cancel, SwiftUI dismisses the sheet, and then the async load resumes and mutates `values`. Because `AIUsageEditorSheet` is a value type (struct), SwiftUI likely already discarded it -- but `.task` holds a strong capture of the async work. In practice the mutation lands into released state, which is benign but creates an observable `isLoadingExisting = false` write after dismiss that could briefly flash "loading" state if the sheet were re-opened immediately.

More importantly: if the user opens Edit, clears a field to blank (intentional), and the load completes before they finish typing, the "only fill blanks" guard will re-populate the field with the old value. The user's intentional delete is silently overwritten.

**Confirmed:** ✅ The guard `if (values[key] ?? "").isEmpty` treats an intentional clear the same as an unset field.

### I3 Fix: Prune race is partially mitigated but a new gap exists

**Where:** `AIUsageAccountStore.swift`, `pruneOrphanAccountsIfNeeded()` lines 144-162.

The fix snapshots `accounts` at the start, computes `removeIds` from the snapshot, then re-reads live `accounts` to compute `keep = accounts.filter { !removeIds.contains($0.id) }`. This correctly avoids clobbering a concurrent `add()`.

However: after the await loop completes, the re-read of `self.accounts` is an actor-isolated read on @MainActor, which is correct. The assignment `accounts = keep` and the subsequent `try? persist(keep)` are safe.

The new gap: the prune and a concurrent `remove()` can race. If the user manually removes account A between the probe-loop and the final filter, `removeIds` will include A (probe found its key missing), and `keep` is computed from the current (post-remove) `accounts` which already excludes A. So A is not in `keep`, and `accounts = keep` is still correct. This path is safe.

A more subtle case: a concurrent `remove()` succeeds after the probe but before the final filter. `remove()` does `try persist(next); accounts = next`. Then prune runs `accounts = keep`. If `keep` happens to contain the just-removed account (it can't, because probe found it missing and it went into `removeIds`), it would re-add it -- but since `probePresence` returns `errSecItemNotFound` for genuinely missing keys, an account that was manually removed (which also deleted the keychain entry) will show up in `removeIds` and be excluded from `keep`. This is actually correct behavior.

**Downgraded:** ⬇️ The I3 race is genuinely resolved. The concurrent-remove edge is safe.

### I5 Fix: Status timeout fires `statusFetchFailed` but previous `incidents` survive

**Where:** `AIUsagePoller.swift`, `runTick()` lines 217-235.

When `fetchStatus()` times out, the code sets:
```swift
statusLoaded[provider.id] = true
statusFetchFailed[provider.id] = true
```

It does NOT clear `incidents[provider.id]`. This means stale incident data from a previous successful fetch persists in the UI while `statusFetchFailed` is true. The popover UI checks `failed && !succeeded` to show "Could not load status" -- but only on the first failure after the app launched without a prior success. Once `statusHasSucceeded` is true, a timeout shows nothing (the failed+succeeded path falls through to the incident list, which shows stale incidents as if they were fresh).

The UI code in `AIUsagePopover.swift` lines 38-55:
```swift
} else if failed && !succeeded {
    Text("Could not load status.")
} else if incidents.isEmpty {
    ...
} else {
    ForEach(incidents) { ... }
}
```

After a prior success, a timeout leaves the user looking at potentially hours-old incident data with no staleness indicator. This is a real UX regression introduced by I5: before I5, a stalled fetch held the tick indefinitely, but at least did not produce false confidence via stale incidents.

**Confirmed:** ✅ The incidents dictionary is never cleared on timeout.

### I8 Fix: `pendingForce` coalescing is correct, but `isRefreshing` stays true across chained ticks

**Where:** `AIUsagePoller.swift`, `scheduleTick()` lines 130-156.

After the in-flight task completes:
```swift
self.inFlightTask = nil
if self.hasPendingTick {
    self.hasPendingTick = false
    let nextForce = self.pendingForce
    self.pendingForce = false
    self.scheduleTick(force: nextForce)
} else {
    self.isRefreshing = false
}
```

When there is a pending tick, `isRefreshing` stays true (never set to false before the chained `scheduleTick`). Inside `scheduleTick`, `isRefreshing = true` is set again before the new task. This is fine -- the flag stays true throughout chained ticks.

But: if `scheduleTick` exits early because `!visibilityProvider()` (the non-force path), `hasPendingTick` is never set and `isRefreshing` is never set to false if the chained call drops the tick. Trace: in-flight completes, `hasPendingTick = true`, `pendingForce = false`, we call `scheduleTick(force: false)`. At line 131: `if !force, !visibilityProvider()` -- app is occluded -- returns early. `isRefreshing` is now stuck at `true` forever until the next visibility change triggers another tick.

**Confirmed:** ✅ If the chained pending tick is dropped due to occlusion and no future visibility event fires, `isRefreshing` stays `true` permanently.

---

## What's Missing

### No test for the `loadExistingIfNeeded` blank-overwrite scenario

The test suite covers store round-trips, malformed blob survival, lifecycle idempotency, and parse edge cases. No test exercises the "user clears a field, async load overwrites it" path in the editor. This is a UI-layer behavior so unit testing is harder, but a targeted test with a slow mock store could catch this.

### No test for stale incidents after a status timeout

The test suite does not cover the case where `statusHasSucceeded` is true and a subsequent status fetch times out. This would require a mock tick body to simulate, but the poller's injectable `tickBody` makes it tractable.

### `ClaudeAIUsageFetcher.parseUtilization` does not reject nil

**Where:** `ClaudeAIUsageFetcher.swift`, `parseUtilization()` lines 136-150.

Compare with `CodexAIUsageFetcher.parseUtilization` (which I1 explicitly fixed):
```swift
// Codex - fixed in I1:
if raw == nil || raw is NSNull { throw CodexAIUsageFetchError.decoding }
```

Claude's version:
```swift
private static func parseUtilization(_ raw: Any?) throws -> Int {
    if raw is Bool { throw ClaudeAIUsageFetchError.decoding }
    if let int = raw as? Int { return clamp(int) }
    if let number = raw as? NSNumber { ... }
    throw ClaudeAIUsageFetchError.decoding
}
```

If `raw` is `nil` or `NSNull`, neither `as? Int` nor `as? NSNumber` matches, so the final `throw` fires. This is correct -- nil/NSNull do throw `.decoding`. But there is no explicit guard mirroring I1, making the behavior implicit and harder to verify. This is a documentation/symmetry gap, not a functional bug.

**Downgraded:** ⬇️ Functionally correct but asymmetric with the Codex fetcher.

### `AIUsageStatusPagePoller` creates a new `URLSession` on every fetch call

**Where:** `AIUsageStatusPagePoller.swift` lines 28-29:
```swift
let session = AIUsageHTTP.makeSession(timeout: 10)
defer { session.invalidateAndCancel() }
```

Each `fetch()` call allocates a fresh ephemeral session and invalidates it on exit. Same pattern is used in both fetchers. This is intentional (isolation), but means no HTTP/2 connection reuse. On a 60s tick with 2 providers plus 2 status fetches, that is 4 session allocations per tick. For a desktop app this is fine, but it is worth knowing.

---

## The Nits

**N1:** `AIUsageColorSettings.color(for:)` line 107 interpolates `high` to `high`:
```swift
return Color.usageInterpolate(high, high, t: t)
```
This is the above-`midHighThreshold` zone. Interpolating `high` to itself produces a constant `high` color, which is correct behavior but the interpolation is wasted computation. A simple `return high` would be clearer and faster.

**N2:** `AIUsageEditorRequest.id` uses string concatenation `provider.id + "|" + account?.id.uuidString`:
```swift
self.id = provider.id + "|" + (account?.id.uuidString ?? "new")
```
If a provider id ever contains `|`, the composite key could collide with another account's id. Provider IDs are controlled strings (`"claude"`, `"codex"`) with no pipe character, so this is not a live bug. But a separator that cannot appear in either component (e.g. a null byte or UUID-format separator) would be safer.

**N3:** `AIUsageFooterView.relativeFormatter` is a static stored property initialized via a closure. It is referenced in both `resetCountdownText` (static func) and the inline bar view. The `RelativeDateTimeFormatter` is not `Sendable` in all configurations, but since this is accessed only on the main thread (SwiftUI body and the `@MainActor` path) it is safe in practice. Worth a comment.

**N4:** `providerUsageResetLabel` (in `AIUsageResetLabel.swift`) returns `.awaitingRefresh` when `resetsAt` is non-nil but in the past. This happens legitimately (the reset has already fired, next poll will clear it). The `resetCountdownText` function returns `nil` for this case (only emits text for `.resetsAt`), so no stale countdown is shown. Correct, but the "resets at a past date" state produces a confusing `awaitingRefresh` label that is never surfaced to the UI -- dead state that a future contributor might be confused by.

**N5:** `AIUsageHTTP.sanitizeHeaderValue` strips `;` and `,` from the session key before it reaches the `Cookie` header. The comment says "a future token type with legitimate separators must add a provider-specific sanitizer." The Codex JWT path (`Authorization: Bearer <token>`) passes through the same sanitizer. JWTs use `.` as a segment separator and base64url encoding, which the sanitizer does not strip -- fine. But if a JWT payload ever contained a `;` or `,` character (unlikely in standard JWTs but possible in non-standard claims), the bearer token would be silently corrupted. The validator (`CodexAIValidators.isValidAccessToken`) rejects those characters, so the sanitizer would never see them -- the layers are consistent.

---

## Numbered List

### Blockers
None.

### Important

**IMP-A: Stale incident data after status timeout with no staleness indicator** (I5 regression)
When `statusHasSucceeded[provider.id]` is true and a subsequent `fetchStatus()` times out, the UI continues displaying the old `incidents` array as if it were current. The popover shows incident rows without any indication they may be hours old. Before I5, a stalled fetch held the tick but at least did not produce false confidence. The fix: on timeout, either clear `incidents[provider.id] = nil` (no incidents shown) or add a `statusFetchedAt[provider.id]: Date?` dictionary and show a staleness warning in the popover when `statusFetchFailed` is true and `statusHasSucceeded` is also true. The simplest fix is clearing incidents on timeout.

**IMP-B: `isRefreshing` permanently stuck true if chained pending tick dropped by occlusion**
If `hasPendingTick` is true when an in-flight task completes and `visibilityProvider()` returns false at that moment, `scheduleTick(force: false)` exits early, `isRefreshing` is never reset to false, and the spinner in the sidebar shows indefinitely until the next visibility event fires. If the app stays occluded (e.g., minimized), this is the permanent state. Fix: set `isRefreshing = false` before early return in `scheduleTick`, or reset it in `stop()` (it already does -- but the stuck state occurs before stop is called).

**IMP-C: Editor `loadExistingIfNeeded` overwrites intentional field clear**
If a user opens Edit, immediately clears a credential field (to re-enter it), and the async keychain load completes before they finish typing, the guard `if (values[key] ?? "").isEmpty` will repopulate the cleared field with the old credential. The user's intentional delete is silently overwritten. Fix: track whether the user has touched each field (a `Set<String>` of modified field IDs) and skip load-population for any touched field.

### Potential

**POT-1:** `ClaudeAIUsageFetcher.parseUtilization` rejects nil/NSNull implicitly via the final `throw` but lacks an explicit guard. A future maintainer adding a new case before the throw could silently introduce a zero-return for nil. Add explicit nil/NSNull rejection at the top to match I1's fix in the Codex path.

**POT-2:** The timeout race in `runWithTimeout` uses `withThrowingTaskGroup` with two tasks. When the fetch wins, `group.cancelAll()` cancels the sleep task. When the sleep wins, the fetch task continues running until its next suspension point. In the HTTP layer, `session.data(for:)` is cancellable, so this resolves quickly. But if a provider's `fetchUsage` closure does CPU-bound work before an `await` (unlikely now, but possible for a future provider), the cancellation would be delayed. Not a current bug but worth documenting.

**POT-3:** `AIUsagePoller.start()` registers an occlusion observer under `if occlusionObserver == nil` guard, but `stop()` removes and nils the observer. If `start()` is called after `stop()` (which `refreshNow()` correctly guards against, but direct `start()` calls do not), a second observer is registered. The guard prevents double-registration on the first call, but after stop+start, a new observer is registered -- this is correct. No bug, but the lifecycle is subtle.

**POT-4:** `AIUsageISO8601DateParser.parse` allocates two `ISO8601DateFormatter` instances on every call. These formatters are expensive to create. If parsing is called in a tight loop (e.g., many incidents in the status page response), this is a hidden perf cost. Recommend caching as static properties like the `relativeFormatter` in `AIUsageFooterView`.

---

## Closing

**Production ready?** Yes, with caveats.

The blockers from pass one are resolved. The core data path (fetch, parse, store, display) is now defensively correct. Keychain operations are isolated, secrets are redacted in all reflection paths, and the session key is sanitized before entering HTTP headers.

The two Important issues (IMP-A stale incidents, IMP-B stuck isRefreshing) are real but not data-loss and not crash-path. IMP-C (editor overwrite) is the most user-visible regression introduced by the B2 fix: a user actively re-entering credentials in the edit sheet could have their cleared field silently repopulated. That is confusing enough to warrant a fix before wide rollout.

Would I mass-deploy to 100k users right now? Not before fixing IMP-A and IMP-C. IMP-A creates false confidence about provider status. IMP-C creates a silent data mutation in the credential editor -- a security-sensitive surface. Both are fixable in a single short commit.
