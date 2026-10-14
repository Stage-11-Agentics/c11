## Code Review
- **Date:** 2026-04-26T23:45:00Z
- **Model:** Gemini
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** e7987ee9
- **Linear Story:** C11-23
---

### Assessment of Changes

This branch implements AI usage monitoring for Claude.ai and Codex (ChatGPT) within the c11 terminal multiplexer. It introduces a modular `AIUsage` system including:
- **Keychain Persistence**: Secure storage for session keys and access tokens.
- **Polling Logic**: Background lifecycle management with occlusion awareness to conserve resources.
- **Provider Fetchers**: Robust HTTP implementations for Claude and Codex usage endpoints.
- **UI Components**: A collapsible sidebar footer section, an editor sheet for account management, and a status page ranking system.
- **Internationalization**: Localized strings for multiple languages.

The rework pass has addressed all previously identified blockers and the majority of important/medium items, significantly hardening the error handling and edge-case management.

### Verification of Rework Items (Second Pass)

The following items from the first-pass review have been verified as resolved:

#### Blockers
- **B1 (Missing Imports):** `c11Tests/AIUsageTests.swift` now correctly imports `Security` and `SwiftUI`. ✅ Confirmed.
- **B2 (No-op Closures):** `AIUsageFooterView` now properly wires `onAdd` and `onEdit` closures to an `AIUsageEditorRequest` state, which drives the `AIUsageEditorSheet`. ✅ Confirmed.

#### Important Items
- **I1 (Codex Silent Zero):** `CodexAIUsageFetcher.parseUtilization` now strictly rejects `nil`, `NSNull`, `Bool`, and non-numeric values, ensuring valid data. ✅ Confirmed.
- **I2 (Reset Countdown):** `AIUsageFooterView` now renders the reset countdown using `AIUsageFooterView.bar` and `providerUsageResetLabel`. ✅ Confirmed.
- **I3 (Prune Race):** `AIUsageAccountStore.pruneOrphanAccountsIfNeeded` now takes a snapshot of the account list before performing async keychain probes, preventing races with concurrent modifications. ✅ Confirmed.
- **I4 (Load Logging):** `AIUsageAccountStore.load()` now logs decoding errors via `os_log` without deleting the underlying `UserDefaults` data, preventing data loss on transient failures. ✅ Confirmed.
- **I5 (Status Timeout):** `AIUsagePoller` wraps status and usage fetches in a `runWithTimeout` helper (20s default). ✅ Confirmed.
- **I6 (Missing Secondary Window):** `CodexAIUsageFetcher` now treats a missing `secondary_window` as a degraded state (0% utilization) instead of throwing a decoding error. ✅ Confirmed.
- **I7 (Editor Sheet Identity):** `AIUsageEditorRequest` is now `Identifiable`, enabling stable sheet presentation. ✅ Confirmed.
- **I8 (Pending Force):** `AIUsagePoller.scheduleTick` now coalesces `force` flags for in-flight requests via `pendingForce`. ✅ Confirmed.

#### Medium & Style
- **M1 (Editor Trim):** `AIUsageEditorSheet` trims whitespace/newlines on all input fields. ✅ Confirmed.
- **M2 (Orphan Dedupe):** The prune cycle correctly identifies and removes index entries whose credentials are gone. ✅ Confirmed.
- **M3 (DI):** `AIUsagePoller` and `AIUsageAccountStore` support dependency injection for tests (UserDefaults, index keys, resolvers). ✅ Confirmed.
- **M5 (Remove Order):** `AIUsageAccountStore.remove` preserves existing account ordering. ✅ Confirmed.
- **M6 (AppStorage):** `AIUsageFooterProviderSection` uses dynamic `@AppStorage` keys for persistence. ✅ Confirmed.
- **EW1 (Error Promotion):** `AIUsageAppOwnedError` was promoted to the top-level `C11AppOwnedError` protocol. ✅ Confirmed.

---

### Architectural Review

The architecture of the `AIUsage` module is commendable for its isolation and security posture. 

1. **Security-First Persistence**: The decision to use macOS Keychain for credentials while keeping only non-sensitive metadata (providerId, displayName) in `UserDefaults` is correct for a desktop application. The use of `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` ensures high security.
2. **Resource Stewardship**: The `AIUsagePoller`’s awareness of window occlusion states is a professional touch, preventing unnecessary network traffic and quota consumption when the user is not actively viewing the panel.
3. **Error Boundary**: The introduction of `C11AppOwnedError` effectively solves the "leaky abstraction" problem where raw framework error messages (like `NSURLError`) might otherwise reach the end user. This ensures a polished, localized experience.
4. **Fetcher Isolation**: Each provider (Claude, Codex) is isolated into its own fetcher and validator logic, making the system easily extensible for future LLM providers.

### Tactical Review

1. **Robust Parsing**: The fetchers use defensive parsing logic (clamping percentages, validating UUIDs/JWTs, handling `NSNull`).
2. **Concurrency Safety**: The use of `@MainActor` on the `AIUsageAccountStore` and `AIUsagePoller` ensures thread-safe UI updates. The `taskGeneration` pattern in `AIUsagePoller` correctly prevents stale data from updating the UI after a task has been cancelled or superceded.
3. **UI Polish**: The `AIUsageFooterView` uses appropriate system fonts and colors, adhering to the project's aesthetic. The use of `RelativeDateTimeFormatter` for reset labels provides human-readable context.

---

### Validation Pass

1. **Blocker: B1 - Missing Imports**
   - File: `c11Tests/AIUsageTests.swift`
   - Verified: Lines 2-3 contain `import Security` and `import SwiftUI`.
   - Result: ✅ Confirmed

2. **Blocker: B2 - View No-ops**
   - File: `Sources/AIUsage/UI/AIUsageFooterView.swift`
   - Verified: `AIUsageFooterProviderSection` popover now calls `onAdd` and `onEdit` which update `editorRequest`. The sheet is correctly bound to `editorRequest`.
   - Result: ✅ Confirmed

3. **Important: I1 - Codex Silent Zero**
   - File: `Sources/AIUsage/CodexAIUsageFetcher.swift`
   - Verified: `parseUtilization` throws `.decoding` for non-integer types and `nil`/`NSNull`.
   - Result: ✅ Confirmed

4. **Important: I3 - Prune Race**
   - File: `Sources/AIUsage/AIUsageAccountStore.swift`
   - Verified: `pruneOrphanAccountsIfNeeded` captures `snapshot = accounts` at the start.
   - Result: ✅ Confirmed

5. **Important: I8 - Poller Coalescing**
   - File: `Sources/AIUsage/AIUsagePoller.swift`
   - Verified: `scheduleTick` handles `pendingForce` correctly during in-flight tasks.
   - Result: ✅ Confirmed

---

### Conclusion

The `c11-23-ai-usage-monitoring` branch is now in a high-quality, stable state. All blockers from the first pass have been addressed, and the implementation is architecturally sound and tactically robust. The addition of localized strings across multiple languages makes this feature ready for a global user base.

**Verdict: Approved.**
