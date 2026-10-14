## Code Review
- **Date:** 2026-04-27T02:58:00Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6d1089d45dafd5c4494ddfb37cbf5c0269b4a61c
- **Linear Story:** C11-23
---

This branch adds a self-contained AI usage monitoring module for Claude and Codex accounts: Settings stores account metadata in `UserDefaults`, credentials are saved per account in Keychain, `AppDelegate` starts a main-actor poller outside XCTest, provider fetchers call hardcoded usage endpoints with ephemeral sessions, and `AIUsageFooterView` renders provider/account rows in the sidebar footer when accounts exist.

The architectural direction is sound for a first implementation. The store/poller/color settings are main-actor isolated, Keychain work is moved off-main, status-page hosts are allowlisted, and the changed sidebar mount does not touch the known typing-latency hot paths (`hitTest`, `TabItemView`, `forceRefresh`). The main concerns are not with the security baseline; they are with incomplete UI wiring and a few correctness gaps that can show misleading quota state.

Validation notes: I did not run `git fetch`, `git pull`, or any tests. The standard prompt asks for fetch/pull and npm commands, but the wrapper prompt explicitly made this a read-only review with the only write being this file, and repo policy says not to run local tests. This is also a Swift/Xcode project, not an npm project.

Reviewed branch changes: `Sources/AIUsage/**`, `Sources/AppDelegate.swift`, `Sources/ContentView.swift`, `Sources/c11App.swift`, `c11Tests/AIUsageTests.swift`, `docs/ai-usage-monitoring.md`, `docs/privacy-endpoints.md`, and project/localization wiring.

### Findings

**Blockers**

None found.

**Important**

1. ✅ Confirmed - Sidebar popover Add/Edit actions are wired to no-ops.
   `Sources/AIUsage/UI/AIUsagePopover.swift:79` and `Sources/AIUsage/UI/AIUsagePopover.swift:89` call `onAdd()` / `onEdit(account)`, but the only call site passes empty closures at `Sources/AIUsage/UI/AIUsageFooterView.swift:95-108`. The docs explicitly say the ellipsis menu can add another account or edit an existing one (`docs/ai-usage-monitoring.md:20-21`), so this ships visible controls that dismiss the popover and do nothing. Either route these callbacks to the Settings editor state, expose an "Open AI Usage Settings" action instead, or remove the dead actions from the footer popover.

2. ✅ Confirmed - Codex usage parsing can silently display `0%` when the upstream payload is malformed or missing `used_percent`.
   `Sources/AIUsage/CodexAIUsageFetcher.swift:120-122` reads `used_percent` and clamps the result of `toNumber`; `toNumber` returns `0` for `nil`, `Bool`, and any non-number at `Sources/AIUsage/CodexAIUsageFetcher.swift:152-156`. That means an API schema drift or partial response can be shown as "0%" instead of surfacing a decoding error. Claude's parser rejects bad utilization, so Codex should do the same: require an integer/number value, reject booleans and missing/non-numeric fields, then clamp only after successful parsing.

3. ✅ Confirmed - Reset timing is parsed and has a helper, but the footer never renders it.
   `AIUsageWindow.resetsAt` is populated by both fetchers (`Sources/AIUsage/ClaudeAIUsageFetcher.swift:126`, `Sources/AIUsage/CodexAIUsageFetcher.swift:131-140`), and `Sources/AIUsage/UI/AIUsageResetLabel.swift:10-27` defines reset-label logic. The visible footer rows, however, only render label, bar, and percent in `Sources/AIUsage/UI/AIUsageFooterView.swift:150-170`; the `isSession` parameter is unused. This misses the story/docs promise that each account row shows the next reset window (`docs/ai-usage-monitoring.md:15-18`). Render the reset label or remove the unused helper/docs claim.

4. ✅ Confirmed - A skipped pending tick can leave `isRefreshing` stuck true.
   When a tick is already in flight, `scheduleTick` marks `hasPendingTick = true` (`Sources/AIUsage/AIUsagePoller.swift:130-132`). After the current tick completes, the task clears the pending flag and calls `scheduleTick(force: false)` (`Sources/AIUsage/AIUsagePoller.swift:141-143`). If the app is no longer visible, that call returns early at `Sources/AIUsage/AIUsagePoller.swift:126-128`, and the original task never reaches the `else { isRefreshing = false }` branch at `Sources/AIUsage/AIUsagePoller.swift:144-145`. This can leave the footer in a stale loading/refreshing state after a long poll plus occlusion. Have `scheduleTick` report whether it actually scheduled, or explicitly clear `isRefreshing` when a pending non-forced tick is dropped.

**Potential**

5. ✅ Confirmed - Test coverage misses the highest-risk provider parsing and UI wiring paths.
   `c11Tests/AIUsageTests.swift` covers Keychain round trips, redaction, validators, HTTP session config, status host rejection, colors, and basic poller lifecycle. It does not exercise Claude/Codex payload parsing, Codex malformed `used_percent`, footer popover callbacks, reset-label rendering, or the pending-tick `isRefreshing` path above. The current fetchers hardcode network calls, so extracting pure payload parsers would make the most important behavior testable without live network.

6. ⬇️ Lower priority - The two poller lifecycle tests use short real sleeps.
   `c11Tests/AIUsageTests.swift:477` and `c11Tests/AIUsageTests.swift:481` sleep for 50 ms to wait for the forced tick. This is not the prohibited 60-second timer sleep, but it is still scheduler-dependent. Since the poller already has a `tickBody` seam, prefer an expectation/continuation or a direct deterministic hook so CI load does not make these tests flaky.

### Security and Privacy Notes

Keychain storage uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable = false` on add/update (`Sources/AIUsage/AIUsageKeychain.swift:89-119`), lookups include non-synchronizable filters, and tests use unique services. `AIUsageSecret` redacts description, debugDescription, and mirror output. Network sessions are ephemeral with no cookie storage/cache (`Sources/AIUsage/AIUsageHTTP.swift:11-19`), status polling rejects unlisted hosts (`Sources/AIUsage/AIUsageStatusPagePoller.swift:11-23`), and fetch-error logging only exposes the NSError domain (`Sources/AIUsage/AIUsagePoller.swift:199-200`). I did not find credential logging or an obvious non-allowlisted status-page escape.

### Test Status

Not run locally due repo policy. CI should run the unit suite and any relevant app-build checks before merge.
