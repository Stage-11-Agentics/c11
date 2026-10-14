## Critical Code Review
- **Date:** 2026-04-27T02:57:54Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6d1089d45dafd5c4494ddfb37cbf5c0269b4a61c
- **Linear Story:** C11-23
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

The feature is structurally close, but it is not production-ready. The storage and privacy basics are mostly there: Keychain uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, sessions are ephemeral, status hosts are allowlisted, and the hot typing paths were not touched. The problems are in the places production actually hurts: the new unit test file appears not to compile, the sidebar's advertised account-management menu is wired to no-ops, and Codex malformed usage payloads can be displayed as "0% used" instead of failing closed.

I did not run local tests. Repo policy says never run tests locally, and the wrapper prompt explicitly made this a read-only review with one allowed file write. I also did not fetch/pull because that would violate the wrapper prompt; `origin/dev` is not present locally, so I reviewed `origin/main...HEAD`, which matches the Trident context.

## What Will Break

1. `c11Tests/AIUsageTests.swift` will fail in CI before exercising any behavior. The file uses Security constants and SwiftUI `Color` without importing `Security` or `SwiftUI` ([c11Tests/AIUsageTests.swift:1](../../c11Tests/AIUsageTests.swift#L1), [c11Tests/AIUsageTests.swift:12](../../c11Tests/AIUsageTests.swift#L12), [c11Tests/AIUsageTests.swift:388](../../c11Tests/AIUsageTests.swift#L388)). I found no `@_exported import SwiftUI` or equivalent re-export in the repo. Other test files explicitly import AppKit/SwiftUI when they use those types.

2. The sidebar footer popover's "Add account" and per-account "Edit" buttons do nothing. `AIUsageFooterView` constructs `AIUsagePopover` with `onAdd: {}` and `onEdit: { _ in }` ([Sources/AIUsage/UI/AIUsageFooterView.swift:95](../../Sources/AIUsage/UI/AIUsageFooterView.swift#L95), [Sources/AIUsage/UI/AIUsageFooterView.swift:107](../../Sources/AIUsage/UI/AIUsageFooterView.swift#L107)). The popover delegates the button actions entirely to those closures ([Sources/AIUsage/UI/AIUsagePopover.swift:79](../../Sources/AIUsage/UI/AIUsagePopover.swift#L79), [Sources/AIUsage/UI/AIUsagePopover.swift:89](../../Sources/AIUsage/UI/AIUsagePopover.swift#L89)). This directly contradicts `docs/ai-usage-monitoring.md`, which says the ellipsis menu can add and edit accounts.

3. Codex usage can silently report fake safe values. `parseWindow` calls `clamp(toNumber(usedRaw))`, and `toNumber` returns `0` for missing, boolean, or non-number values ([Sources/AIUsage/CodexAIUsageFetcher.swift:120](../../Sources/AIUsage/CodexAIUsageFetcher.swift#L120), [Sources/AIUsage/CodexAIUsageFetcher.swift:152](../../Sources/AIUsage/CodexAIUsageFetcher.swift#L152)). If OpenAI changes `used_percent`, returns `null`, or returns an error-shaped payload with the window keys still present, c11 will show 0% utilization instead of an error. Usage monitoring must fail closed, not tell the user they are fine.

4. The documented reset countdown is not rendered. `ProviderUsageResetLabel` exists ([Sources/AIUsage/UI/AIUsageResetLabel.swift:3](../../Sources/AIUsage/UI/AIUsageResetLabel.swift#L3)), and the docs promise "the next reset window when known", but `AIUsageFooterView.bar` only renders the label, bar, and percent ([Sources/AIUsage/UI/AIUsageFooterView.swift:150](../../Sources/AIUsage/UI/AIUsageFooterView.swift#L150)). Users will not see the reset information this feature claims to provide.

## What's Missing

- A compile-clean test file import set: `Security` for Keychain symbols and `SwiftUI` for `Color`.
- End-to-end or unit coverage that taps the sidebar popover add/edit actions. The Settings page path is wired, but the footer menu path is not.
- Parser tests for `ClaudeAIUsageFetcher` and `CodexAIUsageFetcher` using controlled payloads. The current tests cover validators and registry shape, but not the provider payload behavior that can misreport usage.
- A fail-closed Codex parser. Missing or invalid `used_percent` should throw `.decoding`, matching the Claude parser's stricter behavior.
- A rendered reset label/countdown in the footer row or a deliberate removal of the helper/docs if that requirement was dropped.
- A scalability story for multiple slow/offline accounts. `AIUsagePoller` fetches accounts serially ([Sources/AIUsage/AIUsagePoller.swift:172](../../Sources/AIUsage/AIUsagePoller.swift#L172)); 10 dead accounts can turn a 60s tick into roughly 200s of refresh state.

## The Nits

- `AIUsageHTTP.makeSession(timeout:)` is wrapped by a 20s poller timeout, but both provider fetchers create sessions with a hard-coded 10s timeout ([Sources/AIUsage/ClaudeAIUsageFetcher.swift:82](../../Sources/AIUsage/ClaudeAIUsageFetcher.swift#L82), [Sources/AIUsage/CodexAIUsageFetcher.swift:82](../../Sources/AIUsage/CodexAIUsageFetcher.swift#L82)). The docs say 20s per fetch.
- `CodexAIValidators.isValidAccountId` allows commas and semicolons, while `AIUsageHTTP.sanitizeHeaderValue` strips them later. That can mutate a user-supplied account id rather than rejecting it.
- `AIUsageEditorSheet.canSave` validates some raw values before the save path trims them. A leading/trailing whitespace paste can be rejected even though the stored value would be valid after trimming.

## Blockers

1. ✅ Confirmed — `c11Tests/AIUsageTests.swift` is missing required framework imports and appears to break the test target build.

   Proof path: the file imports only `XCTest` and `@testable import c11` ([c11Tests/AIUsageTests.swift:1](../../c11Tests/AIUsageTests.swift#L1)). It directly references `kSecClass`, `kSecClassGenericPassword`, `kSecAttrService`, `SecItemDelete`, and `CFDictionary` in the cleanup helper ([c11Tests/AIUsageTests.swift:12](../../c11Tests/AIUsageTests.swift#L12)), and directly extends/uses `Color` ([c11Tests/AIUsageTests.swift:388](../../c11Tests/AIUsageTests.swift#L388), [c11Tests/AIUsageTests.swift:394](../../c11Tests/AIUsageTests.swift#L394)). There is no repo-level SwiftUI re-export. This needs `import Security` and `import SwiftUI` before CI can trust any of these tests.

## Important

1. ✅ Confirmed — footer popover add/edit actions are no-ops.

   Trace: clicking the ellipsis sets `presentedProviderId` and opens `AIUsagePopover` ([Sources/AIUsage/UI/AIUsageFooterView.swift:76](../../Sources/AIUsage/UI/AIUsageFooterView.swift#L76)). The footer passes empty closures for add/edit ([Sources/AIUsage/UI/AIUsageFooterView.swift:107](../../Sources/AIUsage/UI/AIUsageFooterView.swift#L107)). The popover's buttons close the popover and call only those closures ([Sources/AIUsage/UI/AIUsagePopover.swift:79](../../Sources/AIUsage/UI/AIUsagePopover.swift#L79), [Sources/AIUsage/UI/AIUsagePopover.swift:89](../../Sources/AIUsage/UI/AIUsagePopover.swift#L89)). There is no alternate state mutation, so the user gets a dead menu.

2. ✅ Confirmed — Codex malformed utilization is displayed as 0% instead of a decoding failure.

   Trace: `parseWindow` does not guard that `used_percent` exists or is numeric; it converts through `toNumber` ([Sources/AIUsage/CodexAIUsageFetcher.swift:120](../../Sources/AIUsage/CodexAIUsageFetcher.swift#L120)). `toNumber(nil)`, `toNumber(NSNull())`, `toNumber(true)`, and `toNumber("bad")` all return `0` ([Sources/AIUsage/CodexAIUsageFetcher.swift:152](../../Sources/AIUsage/CodexAIUsageFetcher.swift#L152)). The returned `AIUsageWindow` then renders normally in the footer. This is false telemetry.

3. ✅ Confirmed — reset countdown UI is missing from the footer despite helper/docs.

   Trace: reset labeling logic exists only as a standalone function ([Sources/AIUsage/UI/AIUsageResetLabel.swift:10](../../Sources/AIUsage/UI/AIUsageResetLabel.swift#L10)). `AIUsageFooterView.accountRow` calls `bar` for Session and Week ([Sources/AIUsage/UI/AIUsageFooterView.swift:135](../../Sources/AIUsage/UI/AIUsageFooterView.swift#L135)), and `bar` renders only the label, bar, and percent ([Sources/AIUsage/UI/AIUsageFooterView.swift:150](../../Sources/AIUsage/UI/AIUsageFooterView.swift#L150)). No call site uses `providerUsageResetLabel`.

## Potential

1. ❓ Likely but workload-dependent — serial polling will age badly with many accounts or slow networks.

   `runTick` fetches each account one after another ([Sources/AIUsage/AIUsagePoller.swift:172](../../Sources/AIUsage/AIUsagePoller.swift#L172)). The public docs explicitly allow as many accounts as the user wants. With per-fetch timeout at 20s, a handful of expired/offline accounts can keep `isRefreshing` true for minutes and make the "every 60s" promise false.

2. ⬇️ Real but lower priority — the 20s timeout guarantee is inconsistent.

   The poller wraps provider fetches in `runWithTimeout(perFetchTimeout)` where the default is 20s ([Sources/AIUsage/AIUsagePoller.swift:51](../../Sources/AIUsage/AIUsagePoller.swift#L51), [Sources/AIUsage/AIUsagePoller.swift:184](../../Sources/AIUsage/AIUsagePoller.swift#L184)), but provider sessions are hard-coded to 10s. This is not dangerous, but the docs and code disagree.

3. ⬇️ Real but lower priority — account id validation should reject characters that will be stripped from the header.

   `CodexAIValidators.isValidAccountId` rejects whitespace/control/null only ([Sources/AIUsage/CodexAIProvider.swift:23](../../Sources/AIUsage/CodexAIProvider.swift#L23)). `AIUsageHTTP.sanitizeHeaderValue` later strips `;` and `,` ([Sources/AIUsage/AIUsageHTTP.swift:22](../../Sources/AIUsage/AIUsageHTTP.swift#L22)). Silent mutation is the wrong behavior for an identifier header.

## Closing

No, I would not mass deploy this to 100k users yet. The app-side privacy and Keychain direction is sound, but the branch needs at least the test compile fix, the footer popover wiring fix, and the Codex parser fail-closed fix before it is production-ready. After that, add real fetcher parsing tests and either render the reset countdown or remove the claim from the product/docs.
