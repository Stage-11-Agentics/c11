# Action-Ready Synthesis: C11-23

## Verdict

**fix-then-merge**

Reviewers disagree on severity. Standard-gemini approved outright. Standard-claude and standard-codex confirmed rework resolution but standard-codex flagged a new blocker from the M5 fix. Critical-claude rated it "shippable with caveats" (two importants, no blockers). Critical-codex rated it not mass-deployable (one blocker). Critical-gemini rated it not production-ready (multiple blockers). The Standard lens is the most optimistic; the Critical lens is the most useful ground truth here because the contested issues are code-level, not preference-level.

On direct code inspection:
- The Keychain-silent-failure bug (B1 below) is confirmed in `AIUsageAccountStore.remove()`: credentials survive silently after the user clicks Remove. Multi-reviewer, code-confirmed. This is a merge blocker.
- The ghost-task concurrency issue (B2 below) is confirmed in `AIUsagePoller.scheduleTick()`: a cancelled task's cleanup closure can nil out a newly spawned task's reference, breaking the in-flight limiter. Single-reviewer but code-confirmed.
- All first-pass rework items (original B1/B2/I1-I8/M1-M8/EW1) are confirmed resolved by three reviewers with no substantive dispute.

Bias toward the cautious verdict: fix B1 and B2 below, then merge.

---

## Apply by default

### Blockers (merge-blocking)

- **B1: `AIUsageAccountStore.remove()` silently retains Keychain credential after index removal**
  - Location: `Sources/AIUsage/AIUsageAccountStore.swift:107-113`
  - Problem: `remove()` calls `try persist(next)` and `accounts = next` before attempting Keychain deletion. The deletion at line 113 is `try? await AIUsageKeychain.delete(...)`, so any Keychain error is discarded after the UI has already removed the account row. A user who clicks Remove will see the account disappear but their credential remains in Keychain with no retry handle -- the account UUID is gone from the index. The inline comment claims "the next prune cycle removes the now-orphaned in-memory entry," but that is backward: prune only cleans accounts whose index entry exists but whose Keychain item is missing, not the inverse.
  - Fix: Attempt Keychain deletion first. If it succeeds, persist the updated index and update `accounts`. If Keychain deletion fails (and the failure is not `errSecItemNotFound`), throw the error so the caller can surface it and the account row remains visible. `errSecItemNotFound` on delete should be treated as success (idempotent). This preserves the user's visibility into the account until the credential is actually gone.
  - Sources: standard-codex (blocker), critical-codex (blocker, cited `AIUsageAccountStore.swift:105-113`), critical-gemini (potential/nit -- cited the backward comment, correctly identified the semantic error)

- **B2: Ghost task in `AIUsagePoller.scheduleTick()` can nil out a live in-flight task reference**
  - Location: `Sources/AIUsage/AIUsagePoller.swift:142-155`
  - Problem: The `Task { ... }` closure unconditionally executes `self.inFlightTask = nil` after `runTick` returns (line 145), including when `runTick` returned early due to `generation != taskGeneration`. If `stop()` cancels the old task and sets `inFlightTask = nil`, and then `start()` spawns a new task and assigns it to `inFlightTask`, the old task's cleanup eventually executes and writes `self.inFlightTask = nil` again -- nulling out the new live task's reference. Subsequent `scheduleTick` calls see `inFlightTask == nil` and spawn overlapping concurrent tick tasks, defeating the one-in-flight limiter.
  - Fix: Guard the cleanup write: only write `self.inFlightTask = nil` if `self.inFlightTask` is the task that is currently completing (compare by identity or use a generation check). The simplest correct fix: capture the task and compare before nulling: inside the Task closure, after `runTick` returns, check `if self.taskGeneration == generation` before writing `self.inFlightTask = nil` and before chaining the pending tick. If generations do not match, the task has been superseded -- skip all cleanup and return immediately.
  - Sources: critical-gemini (blocker, execution path traced); code confirmed on direct inspection of `AIUsagePoller.swift:142-155`

### Important (land in same PR)

- **I1: Stale incident data shown as "all clear" after a post-success status timeout**
  - Location: `Sources/AIUsage/AIUsagePoller.swift:230-234`, `Sources/AIUsage/UI/AIUsagePopover.swift:42-50`
  - Problem: When `fetchStatus()` times out or fails and `statusHasSucceeded[provider.id]` is already `true`, the catch block at lines 230-234 sets `statusFetchFailed = true` but does NOT clear `incidents[provider.id]`. `AIUsagePopover.swift` only shows "Could not load status" when `failed && !succeeded` (line 42). After a prior success, that branch is unreachable. If prior `incidents` was empty, the popover renders a green "all normal" status during an active outage or network failure. The user sees false confidence.
  - Fix: On timeout/failure in the catch block, set `incidents[provider.id] = nil` (clearing the stale data) so the popover falls through to the "failed but not succeeded" branch correctly -- or alternatively add a `statusFetchedAt[provider.id]: Date?` and show a staleness indicator. The simplest fix is clearing `incidents` on any post-load failure.
  - Sources: critical-claude (IMP-A, confirmed), critical-codex (important, cited `AIUsagePoller.swift:226-234` and `AIUsagePopover.swift:42-50`)

- **I2: `isRefreshing` permanently stuck `true` if chained pending tick is dropped by occlusion**
  - Location: `Sources/AIUsage/AIUsagePoller.swift:130-156`
  - Problem: When an in-flight task completes and `hasPendingTick` is true, the code clears `hasPendingTick` and calls `scheduleTick(force: nextForce)`. If `visibilityProvider()` returns `false` at that moment (app occluded), `scheduleTick` returns early at lines 131-133 without setting `isRefreshing = false`. The spinner visible to the user stays in the "refreshing" state indefinitely until the next visibility change fires. If the app stays minimized or occluded, this is the permanent state for the session.
  - Fix: When `scheduleTick` returns early due to occlusion (the `!force && !visibilityProvider()` branch), set `isRefreshing = false` before returning. Alternatively, set `isRefreshing = false` in `stop()` (it already does -- but the stuck state occurs before `stop()` is called).
  - Sources: critical-claude (IMP-B, confirmed); code confirmed on direct inspection of `AIUsagePoller.swift:130-133`

- **I3: `AIUsageEditorSheet.loadExistingIfNeeded()` overwrites intentional field clear**
  - Location: `Sources/AIUsage/UI/AIUsageEditorSheet.swift:139-142`
  - Problem: `loadExistingIfNeeded()` fills only blank fields: `if (values[key] ?? "").isEmpty { values[key] = value }`. If a user opens Edit, clears a credential field to blank (intentionally, to re-enter it), and the async Keychain load completes before they finish typing, the blank guard silently repopulates the cleared field with the old value. The user's intentional delete is overwritten. This is the most user-visible regression introduced by the B2/I7 fix: it occurs on a security-sensitive surface (credential entry).
  - Fix: Track which fields the user has touched (a `@State private var touchedFields: Set<String>`). In `bindingFor(_:)`, add the field ID to `touchedFields` on any set. In `loadExistingIfNeeded()`, skip population for any field in `touchedFields`.
  - Sources: critical-claude (IMP-C, confirmed)

- **I4: `update()` cannot repair a missing Keychain item through the edit flow**
  - Location: `Sources/AIUsage/AIUsageAccountStore.swift:82`, `Sources/AIUsage/AIUsageKeychain.swift:124-125`
  - Problem: `AIUsageAccountStore.update()` always calls `AIUsageKeychain.update()`, which uses `SecItemUpdate`. If the Keychain item is missing (e.g., orphaned by a prior failed delete or migrated device), `SecItemUpdate` returns `errSecItemNotFound`, which surfaces as `AIUsageStoreError.notFound`. The user can open Edit, type a valid new credential, and still cannot save -- the sheet shows an error with no recourse short of Remove + re-Add. This leaves users stranded when the Keychain item is absent but the index entry exists.
  - Fix: In `AIUsageKeychain.update()` (or in `AIUsageAccountStore.update()`), if `SecItemUpdate` returns `errSecItemNotFound`, fall through to `SecItemAdd` to create the item. This makes update idempotent with respect to item existence.
  - Sources: critical-codex (important, cited `AIUsageAccountStore.swift:66-96` and `AIUsageKeychain.swift:124-125`)

### Straightforward mediums

- **M1: `AIUsagePoller.localizedFetchErrorMessage(_:)` has redundant specific-type guards before the `C11AppOwnedError` catch-all**
  - Location: `Sources/AIUsage/AIUsagePoller.swift:255-268`
  - Problem: The function first checks `error as? AIUsageStoreError`, then `error is AIUsageFetchTimeoutError`, then checks `C11AppOwnedError`. Both `AIUsageStoreError` and `AIUsageFetchTimeoutError` already conform to `C11AppOwnedError`, so the first two guards add no behavior -- they are subsumed by the third. When a fourth conforming error type is added, a developer may cargo-cult another specific guard, growing the maintenance surface unnecessarily.
  - Fix: Remove the `AIUsageStoreError` and `AIUsageFetchTimeoutError` specific guards. The `C11AppOwnedError` + `LocalizedError` check handles all conforming types uniformly. Verify the fallback string remains the same.
  - Sources: evolutionary-claude (concrete suggestion #2, confirmed the redundancy at lines 255-268 with conformance citations)

- **M2: `ClaudeAIUsageFetcher.parseUtilization` lacks explicit nil/NSNull guard (asymmetric with Codex fix)**
  - Location: `Sources/AIUsage/ClaudeAIUsageFetcher.swift`, `parseUtilization(_:)` function
  - Problem: Codex's `parseUtilization` (fixed in I1) explicitly checks `if raw == nil || raw is NSNull { throw .decoding }`. Claude's version relies on the final `throw` to handle nil/NSNull implicitly (neither `as? Int` nor `as? NSNumber` matches nil, so the throw fires). The behavior is correct, but the asymmetry makes the intent non-obvious and a future developer adding a case before the final throw could silently introduce a zero-return for nil.
  - Fix: Add `if raw == nil || raw is NSNull { throw ClaudeAIUsageFetchError.decoding }` at the top of Claude's `parseUtilization`, mirroring the Codex fix.
  - Sources: standard-claude (P1), critical-claude (POT-1)

### Evolutionary clear wins

None. All evolutionary findings expand scope or require design discussion. See "Evolutionary worth considering" below.

---

## Surface to user (do not apply silently)

- **S1: Critical-gemini's claim that `pruneOrphanAccountsIfNeeded()` silently discards concurrent edits**
  - Why deferred: disagreement + design-needed. Critical-gemini claims that if a user edits an account while prune is suspended on Keychain probes, the edit's in-memory changes will be overwritten when prune writes `accounts = keep`. Critical-claude analyzed the same code and concluded the race is safe: `remove()` deletes the Keychain entry, so the account appears in `removeIds` and is excluded from `keep` correctly; concurrent `add()` adds a new ID not in `removeIds` and survives the filter. The two reviewers reached opposite conclusions. On code reading: the prune `keep` computation reads `self.accounts` (current, post-edit) and filters out only IDs in `removeIds`. An edit (which modifies `displayName` or `keychainService` on an existing account) does not change the account's `id`, so a concurrently edited account would still appear in the freshly-read `self.accounts` and would NOT be in `removeIds` (its Keychain entry is still present). The critical-gemini blocker appears to be a misread of what "edit" does: editing updates the Keychain item to a new value (not deleting it), so `probePresenceAsync` would return `errSecSuccess`, not `errSecItemNotFound`, and the account would not enter `removeIds`. The race is likely safe. Surface to user for final call before closing.
  - Summary: Critical-gemini rated this a data-loss blocker; critical-claude rated it resolved. Code analysis favors critical-claude's reading. No data loss occurs in the edit-during-prune scenario unless the edit simultaneously removes the Keychain item (which `update()` does not do).
  - Sources: critical-gemini (blocker), critical-claude (downgraded to resolved)

- **S2: Data loss on schema migration: `load()` decode failure + subsequent `add()` overwrites UserDefaults blob**
  - Why deferred: design-needed. Critical-gemini flags that after a failed `JSONDecoder` call, `accounts = []` in memory, and the first `add()` persists `[newAccount]` -- permanently overwriting the old blob and orphaning existing accounts' Keychain items. Critical-claude and standard-claude confirmed the log-without-delete fix for I4 but did not raise the "first add after decode failure overwrites blob" scenario. The fix for I4 was specifically to not delete the blob on load error -- but the blob is still overwritten by the first successful `persist()` call. This is a legitimate concern for schema migrations. However, fixing it requires either schema versioning (add a migration path), a "read-only mode until the user acknowledges corruption", or refusing to persist until the blob is manually cleared. None of these are in-scope without design discussion.
  - Summary: Real risk for schema evolution; not triggered in current deployment because the schema has not changed. Warrants a design decision on migration strategy before the module's account schema evolves.
  - Sources: critical-gemini (important)

- **S3: `AIUsageEditorRequest.id` uses `"|"` separator that could theoretically collide**
  - Why deferred: subjective. Critical-claude (N2) flags that if a provider ID ever contained `|`, the composite key `provider.id + "|" + account.id.uuidString` could collide. In practice, provider IDs are hardcoded as `"claude"` and `"codex"`. Standard-claude and others did not flag this. A UUID-based ID would be more robust, but this is an architectural preference, not a live bug.
  - Summary: Real theoretical issue; not a live concern with current controlled provider IDs. A UUID would be safer if provider IDs ever expand to user-supplied strings.
  - Sources: critical-claude (N2)

- **S4: `AIUsageISO8601DateParser.parse` allocates two `ISO8601DateFormatter` instances on every call**
  - Why deferred: scope-creep. Critical-claude (POT-4) flags that the two formatters are created fresh per call. If the status page response contains many incidents, this is a perf cost. Standard-claude and others did not raise it. The fix (cache as static properties) is mechanical but was not confirmed by a second reviewer.
  - Summary: Minor perf issue; not a correctness concern. Fix is easy (static let formatters) but single-reviewer and not critical path.
  - Sources: critical-claude (POT-4)

---

## Evolutionary worth considering (do not apply silently)

- **E1: Promote `AIUsageKeychain` to a shared `C11Keychain` in `Sources/Security/`**
  - Summary: `AIUsageKeychain` contains zero AIUsage-specific logic -- it operates only on `UUID`, `String`, and `Data`. Moving it to `Sources/Security/C11Keychain.swift` makes secure Keychain storage available to any future c11 feature without reimplementing the pattern.
  - Why worth a look: The next feature requiring credentials would otherwise duplicate this work. The rename is confirmed zero-risk by two reviewers, test coverage exists, and the call sites are limited to `AIUsageAccountStore`.
  - Sources: evolutionary-claude (concrete suggestion #1, confirmed), evolutionary-codex (suggestion #1), evolutionary-gemini (suggestion #1)

- **E2: Add socket read commands exposing AI usage state (`c11 aiusage status`)**
  - Summary: The poller's typed snapshots and provider health data are already in memory. Exposing a read-only socket command (returning JSON with utilization and incident state, never raw credentials) would let agents self-throttle before spawning heavy tasks and close the operator-observability loop without requiring a human to read the sidebar.
  - Why worth a look: This is the highest-leverage flywheel step identified by all three evolutionary reviewers. The socket command shape already exists in the codebase; the threading policy is documented. Product boundary decision needed: what gets exposed, what is redacted, opt-in vs. always-on.
  - Sources: evolutionary-claude (strategic suggestion #4), evolutionary-codex (strategic suggestion #5), evolutionary-gemini (strategic suggestion #2)
