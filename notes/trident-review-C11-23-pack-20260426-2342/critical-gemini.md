## Critical Code Review
- **Date:** 2026-04-26T23:42:00Z
- **Model:** Gemini 2.5 Pro
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** HEAD
- **Linear Story:** C11-23
- **Review Type:** Critical/Adversarial
---

**The Ugly Truth**
The "fixes" for the previous review have layered new concurrency bugs over the old ones. While the UI mapping and basic network wrappers appear cleaner, the state management in `AIUsagePoller` and `AIUsageAccountStore` fundamentally misunderstands Swift concurrency primitives and UserDefaults persistence. The attempt to debounce fetch requests introduced a state-corrupting race condition under cancellation, and the "safe" account load/prune routines silently cause data loss or orphan keychain items when hit with timing edge cases. This is not production-ready; it will swallow user data and spam provider endpoints under poor network conditions.

**What Will Break**
- **Poller Runaway:** If the app is hidden and immediately shown, or if `AIUsagePoller.stop()` is quickly followed by `start()`, the background task cancellation mechanism fails. The orphaned task will nullify the *new* `inFlightTask` reference, detaching the poller from its limiter. Subsequent ticks will spawn unbounded concurrent fetch operations.
- **Account Data Loss:** If a user edits an account while the asynchronous `pruneOrphanAccountsIfNeeded()` loop is suspended waiting on the Keychain, the edit will be silently discarded from memory and permanently overwritten in `UserDefaults` when the loop finishes.
- **Permanent Index Wipe:** If a future app update alters the `AIUsageAccount` schema and `JSONDecoder` throws an error, the store sets `accounts = []`. The moment the user tries to "add back" an account, the entire historical `UserDefaults` blob is overwritten, permanently stranding the previous accounts' secrets in the Keychain as un-garbage-collected zombies.

**What's Missing**
- True task lifecycle management in `AIUsagePoller`. Setting a reference to `nil` while a detached `Task` continues to run and mutate state is dangerous.
- Safe `UserDefaults` migration handling. You cannot blindly assign `[]` on decode failure without user consent or schema versioning.
- Unique identifiers for `AIUsageEditorRequest`. Reusing string identifiers across structurally distinct modal presentations is a known anti-pattern in SwiftUI that leads to flaky sheet triggers.

**The Nits**
- `RelativeDateTimeFormatter` is heavily stateful and fundamentally not thread-safe. Defining it as a static property without `@MainActor` or thread-local confinement is a latent crash waiting for a background formatting call.
- The comment in `AIUsageAccountStore.remove(id:)` is backward. It claims that if the Keychain delete fails, the *next* prune cycle will catch it. It won't. The prune cycle only iterates over *existing* in-memory accounts.

### 1. Blockers

1. **Ghost Tasks Break Concurrency Limiter in `AIUsagePoller.swift`**
   - **Location:** `AIUsagePoller.scheduleTick(force:)` and `runTick(force:generation:)`
   - **Issue:** When `stop()` is called, `inFlightTask` is cancelled and set to `nil`. However, Swift's `Task.cancel()` is cooperative; the task keeps running. If `start()` or `refreshNow()` is immediately called, a new task is spawned and assigned to `inFlightTask`. Meanwhile, the original task resumes from an `await`, notices `generation != taskGeneration`, and returns early. The closure block then continues execution and runs `self.inFlightTask = nil`. This nullifies the *new*, actively running task.
   - **Impact:** The poller state becomes completely disconnected from the running task. All subsequent `scheduleTick` calls will see `inFlightTask == nil` and spawn overlapping polling tasks, defeating the concurrency limiter and spamming providers.
   - ✅ Confirmed — verified execution path trace; cancellation does not preempt the `self.inFlightTask = nil` cleanup.

### 2. Important

1. **Data Loss on Decode Failure (`AIUsageAccountStore.swift`)**
   - **Location:** `AIUsageAccountStore.load()` and `add(providerId:displayName:secret:)`
   - **Issue:** If `JSONDecoder` fails to decode the UserDefaults index (e.g., due to a corrupted schema update or missing fields), it logs an error and sets `accounts = []`. While it avoids immediately zeroing out UserDefaults, the in-memory array is now empty. As soon as the user adds a single new account, `add()` calls `persist(next)`, which unconditionally overwrites the UserDefaults blob with `[newAccount]`.
   - **Impact:** All previously configured accounts are permanently deleted from the index, leaving their secrets orphaned in the Keychain forever.
   - ✅ Confirmed — silent overwrite of `UserDefaults` on the first mutation after a decode failure.

2. **Race Condition in Orphan Pruning (`AIUsageAccountStore.swift`)**
   - **Location:** `AIUsageAccountStore.pruneOrphanAccountsIfNeeded()`
   - **Issue:** The method iterates over a `snapshot` of accounts and performs `await AIUsageKeychain.probePresenceAsync` for each. While suspended, the user might legitimately edit an account (which replaces its secret). If the edit occurs while the prune task was evaluating the *old* service or hit a transient read error, the loop finishes and computes `keep = accounts.filter { !removeIds.contains($0.id) }`. This filter silently removes the user's freshly updated account from the live in-memory array, and `persist(keep)` cements the loss.
   - ✅ Confirmed — mutating shared class state based on asynchronous delta checks against a stale snapshot is inherently unsafe.

### 3. Potential

1. **Brittle Sheet Identity in SwiftUI**
   - **Location:** `AIUsageEditorSheet.swift` (`AIUsageEditorRequest: Identifiable`)
   - **Issue:** `AIUsageEditorRequest` constructs its `id` via `provider.id + "|" + (account?.id.uuidString ?? "new")`. If a user clicks "Add Account", dismisses it, and clicks "Add" again, the ID `[provider]|new` is completely identical. While transitioning a `@State` binding from `.some` to `nil` to `.some` usually resets presentation in newer OS versions, relying on reused string IDs for structurally new interactions is fragile and can lead to un-triggerable sheets on rapid user interaction.
   - ⬇️ Real but lower priority — standard SwiftUI behavior usually masks this, but a `UUID` is the correct approach.

2. **Thread-Unsafe Formatter**
   - **Location:** `AIUsageFooterView.swift`
   - **Issue:** `relativeFormatter` is instantiated as a static constant. `RelativeDateTimeFormatter` is heavily stateful and not thread-safe. While currently only called from SwiftUI view bodies (which run on the MainActor), it lacks the `@MainActor` attribute, meaning a future refactor could easily call it from a background queue and trigger memory corruption or crashes.
   - ❓ Likely but hard to verify without triggering a crash.

3. **Mishandled Keychain Orphans (Backward Logic)**
   - **Location:** `AIUsageAccountStore.remove(id:)`
   - **Issue:** The comment claims that if `AIUsageKeychain.delete` throws an error, "the next prune cycle removes the now-orphaned in-memory entry". This is backwards. The code already ran `accounts.remove(at:)` and `try persist(next)`. The entry is already gone from memory. If the keychain delete fails, the secret sits in the keychain forever because `pruneOrphanAccountsIfNeeded` only iterates over *existing* in-memory accounts.
   - ✅ Confirmed — the cleanup cycle only prunes memory when keychain is missing, not vice-versa.

## Closing

This branch is **NOT ready for production**. While the UI additions and test adjustments function on a happy path, the state management and lifecycle code are riddled with textbook Swift concurrency errors and data integrity hazards. The `AIUsagePoller` ghost-task loop will eventually trigger provider rate-limits, and the `AIUsageAccountStore` will silently corrupt user data during schema evolution or edge-case edits. You cannot deploy this to a 100k user base without first implementing robust task cancellation and safe, atomic state mutations. Fix the `AIUsagePoller` lifecycle and the `pruneOrphanAccountsIfNeeded()` state delta logic before merging.