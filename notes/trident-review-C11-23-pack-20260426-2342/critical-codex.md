## Critical Code Review
- **Date:** 2026-04-27T03:48:35Z
- **Model:** Codex / GPT-5
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** e7987ee9276344d36e41f12478164929aded792c
- **Linear Story:** C11-23
- **Review Type:** Critical/Adversarial
---

## Scope And Validation Notes

- Branch sync was **not** performed. The wrapper prompt for this pass says read-only and permits only this output file; `git fetch`/`git pull` would mutate repository metadata and/or the worktree.
- Local tests were **not** run. The project policy says never to run tests locally for this repo; C11 validation is expected through CI/VM workflows.
- Reviewed branch commits from `origin/main..HEAD`, the branch stat, `Sources/AIUsage/`, `c11Tests/AIUsageTests.swift`, `Sources/Errors/C11AppOwnedError.swift`, and the app/settings/sidebar wiring touched by this branch.

## The Ugly Truth

The first-pass rework is mostly present, and the B2 editor path is no longer a no-op. The dangerous part is that the credential lifecycle is still optimistic in the exact place where optimism is not acceptable: removal. The code can tell the user an account was removed while silently leaving its secret in Keychain with no durable retry path. That is not a harmless edge case; it is a privacy/security failure in a feature that stores user session tokens.

The status-page fix also has a stale-state trap. A timeout or later network failure after one successful status fetch can still render a green "normal" status from old state. That is not an incident by itself, but it is the kind of telemetry lie that makes operators stop trusting the panel.

## What Will Break

1. When `AIUsageKeychain.delete` fails during account removal, `AIUsageAccountStore.remove` has already persisted the account out of the index and updated memory, then swallows the Keychain failure. The UI proceeds as if credentials were deleted, but the secret remains in Keychain.
2. When a provider status fetch succeeds once and later fails or times out, the popover suppresses the failure state because `statusHasSucceeded` remains true. If the previous incident list was empty, the user sees green "all normal" during an outage or network failure.
3. If the missing-Keychain case reaches the edit sheet before prune removes it, the user cannot repair the credential through Edit: `loadExistingIfNeeded` can recover UI control after `notFound`, but `store.update` uses `SecItemUpdate` and fails again when the item is missing.

## What's Missing

- No test covers Keychain delete failure on account removal. This is the highest-risk missing test because it verifies user intent around credential deletion.
- No test covers I8's `pendingForce` behavior. The implementation looks plausible, but the suite only checks start/stop idempotence.
- No UI or view-model-level test covers B2 footer popover Add/Edit causing `AIUsageEditorSheet` presentation.
- No test covers status fetch failure after a prior success, which is where the stale green status appears.

## The Nits

- The comment in `AIUsageAccountStore.remove` says the next prune cycle removes an orphaned in-memory entry after Keychain delete failure. That is wrong: the account has already been removed from memory and persisted out of the index.
- `AIUsageStatusPagePoller` includes incidents with empty `components` even when a component filter is supplied. That may show unrelated provider-wide incidents if Statuspage returns an uncomponented incident.
- The project file diff is mechanically noisy with long comma-packed PBX entries. It is not a behavioral bug, but it makes future project-file conflicts harder to review.

## Blockers

1. ✅ Confirmed — `AIUsageAccountStore.remove` can silently leave credentials in Keychain after "Remove".

   `Sources/AIUsage/AIUsageAccountStore.swift:105` removes the account from the next index, `Sources/AIUsage/AIUsageAccountStore.swift:107` persists that index, and `Sources/AIUsage/AIUsageAccountStore.swift:108` publishes it to the UI. Only after that does `Sources/AIUsage/AIUsageAccountStore.swift:113` call `try? await AIUsageKeychain.delete(...)`, swallowing every non-`errSecItemNotFound` failure.

   Execution path: user confirms remove in settings at `Sources/c11App.swift:4995`; the app calls `try await aiUsageStore.remove(id:)` at `Sources/c11App.swift:4998`; if `SecItemDelete` returns a real Keychain error, `remove` still returns success because of `try?`. The confirmation copy at `Sources/c11App.swift:5025` promises saved credentials will be deleted. That promise is false on this path, and the account UUID has been removed from the saved index, so the app has no normal retry handle for that orphaned secret.

   Required fix: do not swallow delete failure. Either delete first and preserve/restorable index state on persistence failure, or persist a pending-delete state and surface retry/error until Keychain deletion succeeds. At minimum, removal must return an error when the credential could not be deleted.

## Important

1. ✅ Confirmed — status-page failures after a prior success are hidden behind stale success UI.

   `Sources/AIUsage/AIUsagePoller.swift:226` stores incidents on success, `Sources/AIUsage/AIUsagePoller.swift:229` sets `statusHasSucceeded[provider.id] = true`, and the catch path at `Sources/AIUsage/AIUsagePoller.swift:230` through `Sources/AIUsage/AIUsagePoller.swift:234` sets `statusFetchFailed` without clearing stale incidents or marking stale data. Then `Sources/AIUsage/UI/AIUsagePopover.swift:42` only shows "Could not load status" when `failed && !succeeded`. After any previous success, that branch is skipped. If stale `incidents` is empty, `Sources/AIUsage/UI/AIUsagePopover.swift:47` through `Sources/AIUsage/UI/AIUsagePopover.swift:50` renders green normal status.

   Required fix: after a later failure, either show a stale/fetch-failed state alongside last-known incidents, or clear/age the status data. Do not render green normal while the latest status fetch failed.

2. ✅ Confirmed — missing Keychain rows cannot be repaired through the edit flow.

   `Sources/AIUsage/UI/AIUsageEditorSheet.swift:136` loads the existing secret. If it is missing, the sheet shows an error but eventually enables fields. Saving calls `Sources/AIUsage/AIUsageAccountStore.swift:66` through `Sources/AIUsage/AIUsageAccountStore.swift:96`; `Sources/AIUsage/AIUsageAccountStore.swift:82` always uses `AIUsageKeychain.update`, and `Sources/AIUsage/AIUsageKeychain.swift:124` through `Sources/AIUsage/AIUsageKeychain.swift:125` turns a missing item into `AIUsageStoreError.notFound`. The user can type a new token and still cannot save it through Edit.

   Required fix: if `previousSecret` is nil or `SecItemUpdate` returns `notFound`, create the Keychain item instead of failing, or force the UI into a remove/re-add flow with explicit copy.

## Potential

1. The I8 `pendingForce` rework appears logically correct on inspection: `Sources/AIUsage/AIUsagePoller.swift:134` through `Sources/AIUsage/AIUsagePoller.swift:150` coalesces in-flight ticks and preserves a forced refresh for the follow-up tick. The missing piece is test coverage for force coalescing and status fetch cadence.
2. B2 footer editor wiring appears real: `Sources/AIUsage/UI/AIUsageFooterView.swift:203` through `Sources/AIUsage/UI/AIUsageFooterView.swift:208` sets `AIUsageEditorRequest`, and the sheet is mounted at `Sources/AIUsage/UI/AIUsageFooterView.swift:33` through `Sources/AIUsage/UI/AIUsageFooterView.swift:39`. I do not see the previous no-op bug.
3. I1 and I6 are implemented as described: `Sources/AIUsage/CodexAIUsageFetcher.swift:160` through `Sources/AIUsage/CodexAIUsageFetcher.swift:173` rejects nil, bool, fractional, and string `used_percent`; `Sources/AIUsage/CodexAIUsageFetcher.swift:118` through `Sources/AIUsage/CodexAIUsageFetcher.swift:122` degrades missing `secondary_window` to a zero week window. The remaining risk is product semantics: a synthetic `0%` week can look like real usage rather than degraded data.

## Closing

I would not mass deploy this to 100k users until the Keychain removal path is fixed. A credentials feature must not silently fail deletion. After that, the stale status UI should be fixed or explicitly marked stale, and CI should cover removal failure, pending forced refresh, post-success status failure, and the footer Add/Edit sheet path.
