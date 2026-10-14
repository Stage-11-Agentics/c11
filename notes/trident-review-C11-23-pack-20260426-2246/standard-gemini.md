## Code Review
- **Date:** 2026-04-26T22:46:00Z
- **Model:** Gemini 1.5 Pro
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 88d6b540
- **Linear Story:** C11-23
---

### General Feedback
This is a comprehensive, well-structured, and pragmatically designed implementation of AI usage monitoring. The architecture correctly scopes providers behind protocols (`AIUsageProvider`), isolates credentials into a highly secure Keychain module (`AIUsageKeychain`), and separates logic out from the main SwiftUI thread via well-placed `Task.detached` calls and background-bound `URLSession` operations. The rigorous privacy controls—specifically the strict URL host allowlists in `AIUsageStatusPagePoller`, the ephemeral `URLSession` configuration (no cookies, no cache), header sanitization, and the `AIUsageAppOwnedError` localization gatekeeping—demonstrate an excellent defensive posture aligned with project policies.

However, there are critical omissions specifically related to the SwiftUI integration. While the backend logic accurately models the data and lifecycle, the UI implementation is functionally disconnected from key product requirements (the reset countdown is not displayed, and the popover actions are non-functional).

---

### Tactical Review Findings

1. **Blocker** — Missing Reset Countdown UI (✅ Confirmed)
   - **Location:** `Sources/AIUsage/UI/AIUsageFooterView.swift` & `Sources/AIUsage/UI/AIUsagePopover.swift`
   - **Details:** The mission requirements state the feature must render a "reset countdown". While the logic to compute this is fully implemented in `Sources/AIUsage/UI/AIUsageResetLabel.swift` (via `providerUsageResetLabel`), it is never instantiated, called, or displayed anywhere in the UI. Neither the compact footer nor the popover renders the time until the quota resets, meaning the user has no visibility into this metric.

2. **Blocker** — Disconnected Popover Actions (✅ Confirmed)
   - **Location:** `Sources/AIUsage/UI/AIUsageFooterView.swift` (Lines 77-78)
   - **Details:** `AIUsageFooterView` initializes `AIUsagePopover` with empty closures for `onAdd: {}` and `onEdit: { _ in }`. Consequently, when a user clicks "Add account" or the edit button for a specific account inside the popover, the popover simply dismisses and no action is taken. These callbacks must be wired to present the `AIUsageEditorSheet` (or trigger navigation to the correct Settings section) so the popover is functional.

3. **Important** — Brittle Account Store Initialization (✅ Confirmed)
   - **Location:** `Sources/AIUsage/AIUsageAccountStore.swift` (Lines 111-120)
   - **Details:** In `load()`, if JSON decoding fails (e.g., due to an added non-optional property in a future schema update), the underlying `accounts` array is unconditionally reset to `[]`, effectively dropping all configured accounts from the store index. While acceptable for a V1 release to establish the baseline, consider preserving the raw data and emitting a non-fatal error log to aid debugging in production and prevent irreversible credential loss due to simple schema changes.

4. **Potential** — Poller Timeout vs Session Timeout (⬇️ Lower priority)
   - **Location:** `Sources/AIUsage/AIUsagePoller.swift` & `Sources/AIUsage/ClaudeAIUsageFetcher.swift`
   - **Details:** `AIUsagePoller` configures an aggressive 20-second `perFetchTimeout` utilizing an explicit task cancellation timeout. However, the concrete fetchers (e.g., `ClaudeAIUsageFetcher`) instantiate their `URLSession` with a 10-second timeout. In practice, the `URLSession` will almost always timeout first. While this accurately prevents unbounded network hangs and represents excellent defense-in-depth against JSON decoding deadlocks, the overlapping timeout values could be unified for clarity.

5. **Potential** — Timer Subsystem (⬇️ Lower priority)
   - **Location:** `Sources/AIUsage/AIUsagePoller.swift`
   - **Details:** The use of `DispatchSourceTimer` mapped to the `MainActor` works perfectly for this use case and does not drift. However, modern Swift Concurrency workflows often favor a long-running unstructured `Task` looping `try await Task.sleep(nanoseconds: ...)` to handle interval ticks. This could simplify lifecycle management (`stop()` could simply cancel the task) without requiring manual tracking of `hasStarted` or implicit memory management overhead via `[weak self]`.