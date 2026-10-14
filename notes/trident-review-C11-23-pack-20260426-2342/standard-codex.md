## Code Review
- **Date:** 2026-04-27T03:47:56Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** e7987ee9276344d36e41f12478164929aded792c
- **Linear Story:** C11-23
---

## General Assessment

This second pass verifies the requested rework set against the current branch. The fixes for B1, B2/I7, I1-I6, I8, EW1, and the named style/docs items are present in the diff: the missing test imports are in place, the sidebar footer popover now drives `AIUsageEditorSheet`, Codex `used_percent` decoding no longer silently treats missing/non-numeric values as zero, the reset countdown renders in footer bars, account pruning snapshots before awaits, malformed account-index loads are logged without deleting the blob, status fetches are timeout-wrapped, missing Codex `secondary_window` degrades to a synthetic empty week window, force refresh coalescing tracks `pendingForce`, and the app-owned error marker is now the top-level `C11AppOwnedError`.

Architecturally, the feature is scoped reasonably: credentials stay in Keychain, usage/status fetching is provider-driven, status hosts are allowlisted, and UI integration is opt-in because the footer renders nothing when no accounts exist. The branch also adds a meaningful unit-test suite for model parsing, validators, storage round trips, color settings, and poller lifecycle.

One blocker remains. It is tied directly to the M5 rework: the new remove order makes the UI/index report that an account was removed while a failed Keychain deletion is swallowed. For a credential-management feature whose docs and confirmation dialog promise Keychain deletion, silent credential retention is not acceptable.

## Rework Verification

- B1: fixed. `c11Tests/AIUsageTests.swift` imports both `Security` and `SwiftUI`.
- B2 + I7: fixed. `AIUsageEditorRequest` exists and the footer popover wires Add/Edit into the sheet.
- I1: fixed. `CodexAIUsageFetcher.parseWindow` rejects nil, `NSNull`, bool, fractional, and non-numeric `used_percent`.
- I2: fixed. `AIUsageFooterView.bar` renders reset countdown text via `providerUsageResetLabel`.
- I3: fixed. `pruneOrphanAccountsIfNeeded()` snapshots accounts before async Keychain probes and filters the current account list after the awaits.
- I4: fixed. Malformed account-index decode logs with `os_log(.error)` and leaves the UserDefaults blob intact.
- I5: fixed. Provider status fetches are wrapped in `runWithTimeout(perFetchTimeout)`.
- I6: fixed. Missing Codex `secondary_window` returns a zero-utilization 604800-second week window.
- I8: fixed. `AIUsagePoller` records `pendingForce` while a tick is already in flight.
- M1-M4, M6-M8, EW1, S2/S6/S11/S13: fixed based on direct inspection.
- M5: not fixed safely. The implemented order creates the blocker below.

## Blockers

1. ✅ Confirmed - `AIUsageAccountStore.remove()` can leave credentials behind while reporting success.

   In `Sources/AIUsage/AIUsageAccountStore.swift:105`, the method removes the account from the persisted index and assigns `accounts = next` before attempting Keychain deletion. The deletion is then executed as `try? await AIUsageKeychain.delete(...)` at `Sources/AIUsage/AIUsageAccountStore.swift:113`, so any Keychain error is discarded after the UI has already removed the row. That means a user can click Remove, see the account disappear, and still have the credential retained in Keychain.

   This is part of the branch rework (`8425b14a`, M5). It also contradicts the confirmation copy in `Sources/c11App.swift:5025` saying saved credentials will be deleted from Keychain, and the current test at `c11Tests/AIUsageTests.swift:69` does not catch the retention case because `store.secret(for:)` returns `notFound` once the account row is gone without directly verifying the Keychain item was deleted.

   Recommended fix: make Keychain deletion part of the success path instead of best-effort cleanup. Prefer deleting the Keychain item first, then removing the index row; if index persistence later fails, the stale row can be pruned because the credential is gone. Add a test seam for delete failure, or at minimum a direct post-remove Keychain probe/load assertion that verifies the credential bytes are absent.

## Important

None found after validation.

## Potential

None beyond the blocker-specific test coverage gap noted above.

## Validation Notes

- Did not run `npm run type-check`, `npm run lint`, or `npm test`: this is a Swift/macOS repo, those commands are not applicable, and the project policy says not to run tests locally.
- Did not fetch/pull remote refs because this review prompt is explicitly read-only and the environment has restricted network access.
- Reviewed only the branch diff against `origin/main...HEAD` and the files called out in the second-pass prompt.
