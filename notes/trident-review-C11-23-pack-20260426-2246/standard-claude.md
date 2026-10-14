## Code Review
- **Date:** 2026-04-26T22:46:00Z
- **Model:** Claude Opus 4.7 (claude-opus-4-7)
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** d5d99f609fd9575b3435aa47dcb1e80ded667587
- **Linear Story:** C11-23
---

## Phase 0–2: Setup, branch, and tests

- Branch is `c11-23-ai-usage-monitoring`, 12 commits ahead of `origin/main` (the context doc lists 10; two later commits are translation passes for `zh-Hant` and `ru`).
- Per repo policy (`CLAUDE.md` Testing policy: "Never run tests locally"), test execution is deferred to CI. The Swift project has no `npm`/`pyproject.toml` at root, so the prompt's `npm`-based steps don't apply.
- Static review of the test file (`c11Tests/AIUsageTests.swift`) is included in the tactical findings below.

## Phase 3: What this branch does

A self-contained `Sources/AIUsage/` module:

1. **Storage layer.** `AIUsageAccountStore` (MainActor, `ObservableObject`) keeps an index of accounts in `UserDefaults` under `c11.aiusage.accounts.index` and stores per-account secrets (Cookie / JWT) in macOS Keychain (`com.stage11.c11.aiusage.<provider>-accounts`) with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable = false`. Keychain ops are funneled through `Task.detached` (off-main).
2. **Polling layer.** `AIUsagePoller` (MainActor, singleton) drives a `DispatchSourceTimer` on a utility queue at 60s with 2s leeway, plus a forced tick on start, on occlusion-state-becomes-visible, and on `refreshNow()`. Per-fetch timeout is 20s via a `withThrowingTaskGroup`. A status-page poll runs on every 5th tick (or on `force`) per provider via `AIUsageStatusPagePoller`.
3. **Providers.** Two registered: `Providers.claude` (`claude.ai/api/organizations/<orgId>/usage` with `Cookie: sessionKey=…`) and `Providers.codex` (`chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <jwt>` + optional `chatgpt-account-id`). Each has its own validator + `AIUsageAppOwnedError` localized error type.
4. **Network plumbing.** `AIUsageHTTP.makeSession` produces an ephemeral `URLSession` (no cookie storage, no `URLCache`, `reloadIgnoringLocalCacheData`, configurable timeout). Per-request headers run through `sanitizeHeaderValue` which strips control chars (`< 0x20`, `0x7F`) and `;` / `,`.
5. **Status page.** `AIUsageStatusPagePoller` enforces a hard host allowlist (`status.claude.com`, `status.openai.com`), rejects `/` or `:` in the host, and parses `incidents.json` filtering on the configured component name set.
6. **UI.** `AIUsageFooterView` is mounted inside `SidebarFooter` (above dev/help footer in DEBUG/Release respectively). Returns `EmptyView()` when there are no accounts; otherwise renders per-provider sections with collapsible state persisted in `UserDefaults` (`c11.aiusage.collapsed.<id>`). `AIUsagePopover` and `AIUsageEditorSheet` provide the action menu and add/edit form. `AIUsageSettingsSection` adds a Settings → Agents & Automation card (account list + colors). `AIUsageColorSettings` persists low/mid/high palette and thresholds.
7. **Lifecycle.** Wired in `AppDelegate.applicationDidFinishLaunching`: `AIUsagePoller.shared.start()` runs only when not under `XCTest`. `applicationWillTerminate` stops it.
8. **Docs.** `docs/ai-usage-monitoring.md` (user-facing) and `docs/privacy-endpoints.md` (outbound host catalog).

## Architectural assessment

**Overall:** the design is clean and pragmatic. It is correctly scoped as an opt-in feature with a hard "no accounts → no network, no UI" floor. The provider abstraction (`AIUsageProvider` + `Providers.{claude,codex}` namespace + `AIUsageRegistry`) is the right shape: it isolates per-provider quirks (JWT vs cookie, primary/secondary window names, status component filters) behind a small protocol-by-struct seam without overengineering. Privacy/security defaults are good: ephemeral session, hard allowlist for status hosts, redacted secret type, Keychain-only storage with no iCloud sync.

The lifecycle integration is tasteful: a single MainActor singleton, timer paused while the window is occluded, polling not started under XCTest, status-page polling rate-limited to every 5th tick. The `AIUsageAppOwnedError` marker protocol that gates whether `errorDescription` is safe to surface is a nice touch — it stops generic `URLError` wording from leaking through the UI.

Hot-path verification: the diff does **not** touch `Sources/TerminalWindowPortal.swift`, `Sources/GhosttyTerminalView.swift`, or any file under `Sources/Panels/`. The only typing-latency-adjacent change is `Sources/ContentView.swift` `SidebarFooter` (lines 9468–9491), which wraps the existing footer in a `VStack` with a single new child (`AIUsageFooterView`), and `AIUsageFooterView` early-returns `EmptyView()` when `providerSections.isEmpty`. That is the correct shape. SwiftUI-side, nothing here enters `hitTest`, `TabItemView`, or `forceRefresh`.

The architectural choice that I'd most like to surface for discussion (not block on) is **the dual hard-coded singleton + DI seam pattern**: `AIUsageAccountStore`/`AIUsagePoller`/`AIUsageColorSettings` all expose `static let shared` plus a fully injectable `init`. The UI consistently uses the singletons (`AIUsageFooterView`, `AIUsagePopover.refreshNow`, `AIUsageEditorSheet`), but the Settings page passes them through `@ObservedObject` bindings — minor inconsistency, harmless. More notably, `AIUsagePopover.refreshNow` ignores the injected `poller` and reaches for `AIUsagePoller.shared` (line 99). That's a minor footgun for testing; not a blocker.

## Tactical assessment

A handful of correctness and UX issues, plus a couple of test-quality nits. No security blockers found. See numbered list below.

---

## Numbered findings

### Blockers

*(none)*

### Important

1. **Orphan accounts render twice in Settings.** `AIUsageSettingsSection.body` ForEach iterates `store.accounts` (line 21), which includes accounts whose `providerId` is no longer in the registry. `orphanAccounts` (lines 71–74) then re-renders those same accounts as separate "Unknown provider" cards. Net effect: an orphan shows up in the main account list with a broken Edit button (sets `editorProvider = nil`, sheet never opens) AND as an orphan card. The fix is to filter the main `ForEach` to only known providers (or to gate `accountRow` rendering on `provider(for: account) != nil`). File: `Sources/AIUsage/UI/AIUsageSettingsSection.swift:21`. ✅ Confirmed.

2. **`AIUsageRegistry.ui` set built from provider IDs but compared against `account.providerId`.** Same file, line 72: `Set(AIUsageRegistry.ui.map { $0.id })` — this is correct (provider IDs). I verified by reading both sides; mentioning here only because the readability could be improved with `providerIds` as a local. **Withdraw — false positive on closer read.** ❌ ~~The set is built correctly.~~

3. **`AIUsagePopover.refreshNow` calls `AIUsagePoller.shared.refreshNow()` instead of the injected `poller`** (`Sources/AIUsage/UI/AIUsagePopover.swift:99`). Currently harmless because `AIUsageFooterView` always wires `AIUsagePoller.shared` in, but it defeats the DI seam that `AIUsagePoller`'s public `init` was clearly designed to support, and will silently break any future preview/test that injects a non-shared poller. ✅ Confirmed; ⬇️ low priority.

4. **`AIUsagePoller.refreshNow()` is silently inert before `start()`** (`Sources/AIUsage/AIUsagePoller.swift:121–124`). The guard `guard hasStarted else { return }` is defensible (we don't want UI taps to spin the poller before AppDelegate wires it), but combined with the XCTest gate this means in any UI-test or SwiftUI-preview scenario the popover's "Refresh now" button is silently a no-op with no signal to the user. Consider either logging at `info` or surfacing a tiny "polling paused" string. ✅ Confirmed; ⬇️ low priority.

5. **Generation guard does not unwind partial UI state.** `AIUsagePoller.runTick` checks `if generation != taskGeneration { return }` after each per-account fetch (lines 187, 197, 216, 222) and after each per-provider status fetch. When generation changes, the function returns **without** assigning the partial `newSnapshots`/`newErrors` it has accumulated. That's the correct shape. However, the outer `scheduleTick` then calls `scheduleTick(force: false)` again (because `hasPendingTick` was set), which immediately rebuilds from a clean state. Net result is fine. Not a bug; flagging because the comment density is low and this pattern will trip the next maintainer. ⬇️ low priority.

6. **`AIUsageFooterView.providerSection` reads `UserDefaults.standard.bool(...)` on every body re-evaluation** (`Sources/AIUsage/UI/AIUsageFooterView.swift:50`). The fallback is `collapsed[section.provider.id] ?? UserDefaults.standard.bool(forKey: collapsedKey)`. This view body re-runs whenever `store.accounts`, `poller.snapshots`, `poller.fetchErrors`, or `colorSettings` change, which on a tick is up to once a minute. `UserDefaults.standard.bool` is cheap but it's also called in a `String(format:)`-flavoured hot loop (per-section, per-tick). Cache the read into a `@State var` initialized once per provider, or just write the initial value back into `collapsed` in `.onAppear`. ✅ Confirmed; ⬇️ low priority — not a typing-latency hot path, but an avoidable per-tick UserDefaults read.

7. **Status-page tick rhythm depends on `tickCounter % 5`, but `tickCounter` is also reset by `stop()`.** Actually no — `stop()` does **not** reset `tickCounter` (`Sources/AIUsage/AIUsagePoller.swift:107–119`). It resets `inFlightTask`, `hasPendingTick`, `isRefreshing`, `hasStarted`. That's fine for re-start, since the counter wraps with `&+=`. ❌ ~~Withdrawn.~~ Not an issue.

8. **`AIUsageFooterView` accountRow visual flicker on first refresh.** While `poller.snapshots[id]` is empty and `poller.isRefreshing` is true, the account row shows "Loading status…". Once the first fetch fails (e.g., bad creds), `fetchErrors[id]` is set and the message appears. But if the user opens the sheet to fix creds and saves, `AIUsagePoller.shared.refreshNow()` runs another tick; the previous error stays in `fetchErrors` until the **new** tick reassigns the dict (`fetchErrors = newErrors.filter…` at line 207). Between save and next tick completion, the user still sees the stale error message. Minor; one option is to clear `fetchErrors[id]` on `store.update`. ⬇️ low priority.

9. **`AIUsageEditorSheet.canSave` allows whitespace-only secrets.** `displayName` is trimmed before the empty-check (line 102), but `values[field.id]` is not trimmed in the `field.isSecret && value.isEmpty` branch (line 107). A user who pastes `"  "` into the secret field bypasses the empty-check and the validator is then called with the untrimmed value. `ClaudeAIValidators.isValidSessionKey(" ")` returns false (leading space `0x20` rejected), but a long whitespace token in the middle of a paste might pass shapes that don't strictly require trimming. **Action:** trim every value in `canSave` and in `save()` before validation, not just `displayName`. (`save()` does trim the values at line 148 — `mapValues { $0.trimmingCharacters... }`. The fix is only to mirror that trim in `canSave`.) ✅ Confirmed.

10. **Test sleeps in `AIUsagePollerLifecycleTests`** (`c11Tests/AIUsageTests.swift:477, 481`). Two `Task.sleep(nanoseconds: 50_000_000)` (50ms) calls. These are not the forbidden "60s timer-tick sleep" pattern (`CLAUDE.md`'s "no sleeping 60s in timer tests"), but they are exactly the kind of small async-yield sleeps that should be replaced with explicit awaits. Practically: `start()` schedules a `scheduleTick(force: true)` Task, and the test wants to drain that before measuring. A cleaner pattern is to expose an `await drainPendingTicks()` test seam, or to inject the `tickBody` (already supported) and use `await Task.yield()` once. ✅ Confirmed; ⬇️ low priority — these are short, deterministic-enough waits, but they will be flaky on a loaded CI runner.

11. **`AIUsageColorSettingsTests.testInterpolationOffMatchesDiscreteBuckets` does not actually assert "matches discrete buckets".** It asserts that `color(for: 10) ≈ color(for: 20)` to 0.001 tolerance, which only works because both fall in the same bucket. The test name promises something more meaningful (e.g., that `color(for: 84)` and `color(for: 86)` straddle the threshold). Consider adding the cross-bucket assertion. ✅ Confirmed; ⬇️ low priority.

12. **The marker protocol `AIUsageAppOwnedError` is misused in `localizedFetchErrorMessage`** (`Sources/AIUsage/AIUsagePoller.swift:253–258`). The cast chain is:
    ```swift
    if let local = error as? LocalizedError,
       let isAppOwned = (error as? AIUsageAppOwnedError)?.isAppOwned,
       isAppOwned,
       let description = local.errorDescription { ... }
    ```
    Both `ClaudeAIUsageFetchError` and `CodexAIUsageFetchError` declare `var isAppOwned: Bool { true }` — the constant is never false, so the protocol exists only as a typecheck. This is fine, but the field is decorative. Either drop `isAppOwned` and rely on the conformance alone, or document that `false` is reserved for "wrap our error but don't surface its description." ⬇️ low priority — code smell only.

13. **`Providers.codex` and `Providers.claude` `helpDocURL` point at `Stage-11-Agentics/c11/blob/main/docs/ai-usage-monitoring.md#claude` (and `#codex`)**. The doc file does not contain headings with those slugs (`## Add a Claude account` would render `#add-a-claude-account`). The fragment links are broken. Either rename the doc headings to `## Claude` / `## Codex` or fix the URLs. Low priority because the URLs aren't used by any rendered UI element I can find — `AIUsageProvider.helpDocURL` is set but I see no consumer in the changed code. **Action:** confirm the link is wired to a button in a follow-up commit, or drop `helpDocURL` for now. ✅ Confirmed; ⬇️ low priority.

14. **Naming hygiene check passes.** `grep -rn "cmux\|CMUX" Sources/AIUsage/` returns no results. UserDefaults keys are all `c11.aiusage.*`; Keychain services are all `com.stage11.c11.aiusage.*`; OSLog subsystem is `com.stage11.c11`. ✅ Confirmed clean.

15. **Localization coverage looks complete in Swift code**, but I did not verify every string exists in `Resources/Localizable.xcstrings`. The translator pass commits (`b146d20d`, `d5d99f60`) suggest English-then-translate flow per `CLAUDE.md`. Spot check: `aiusage.error.timeout`, `aiusage.error.fetchFailedGeneric`, `aiusage.window.session/week`, `aiusage.add.button`, `aiusage.remove.confirm.*`, `aiusage.colors.*` are all referenced. ❓ I did not confirm 1:1 between call sites and the xcstrings catalog; recommend a quick `grep` audit before tagging.

### Potential / Nice-to-have

16. **`AIUsageHTTP.sanitizeHeaderValue` strips `=` characters?** No — only `< 0x20`, `0x7F`, `;`, `,`. The test `testSanitizeHeaderValueStripsControlAndSeparators` confirms `Bearer sk-ant-abc=` survives. Good. The character class is conservative-enough for cookie and bearer values; matches what RFC 7230 says about CTLs and separators. ✅ Confirmed correct.

17. **`AIUsageStatusPagePoller.fetch` does not enforce `https://`** — well, it does, since the URL is constructed via `https://\(host)/api/v2/incidents.json`. The host validator rejects `:` so no port override, and the allowlist closes the loop. ✅ Confirmed correct.

18. **`ClaudeAIUsageFetcher.fetch` re-validates inputs even though the editor validates on save.** This is the right defensive shape (Keychain payloads can be edited externally, validators evolve). ✅ Confirmed.

19. **`CodexAIUsageFetcher.parseWindow` rejects `Bool`-typed `used_percent`** via `if value is Bool { return 0 }` (line 153). Reasonable. The Claude variant goes further and `throw`s on Bool (line 135). Slight inconsistency but defensible. ⬇️ low priority.

20. **`AIUsageAccountStore.add` rolls back the Keychain write if `persist` fails** (lines 53–60). Good. **`update` rolls back the secret to its previous value if persist fails** (lines 88–91). Good. **`remove` does not roll back the Keychain delete if persist fails** (lines 102–107). If `persist(next)` throws, the Keychain item is already gone and the index still references it on next launch. The `pruneOrphanAccountsIfNeeded` helper would clean this up next launch, so the consequence is "user sees the orphan briefly" rather than data loss. Worth a comment or a swap of order (persist first, then delete). ✅ Confirmed; ⬇️ low priority.

21. **`AIUsageAccountStore.pruneOrphanAccountsIfNeeded` is fired from `init` via `Task { ... }`** (line 21) and also called from `reload()`. Fine, but the `init` version captures `[weak self]` via Task and runs on MainActor. Subtle: between `load()` returning and the Task running, `accounts` is populated and the UI may render briefly with orphan accounts before they're pruned. Acceptable startup behavior. ⬇️ low priority.

22. **`AIUsageColorSettings` `@Published` `lowMidThreshold`/`midHighThreshold` are `private(set)`** so external mutation must go through `setThresholds`. Good — this enforces the invariant that `low < high`. The two `Stepper` Bindings in `AIUsageSettingsSection.thresholdRow` correctly use `setThresholds`. ✅ Confirmed.

23. **`AIUsagePoller` mixes `@Published` direct assignment with `&+=` and `taskGeneration` integers**. Generation overflow at `Int.max` is harmless because the comparison is equality, not ordering. ✅ Confirmed.

24. **Documentation accuracy.** `docs/privacy-endpoints.md` says headers are sanitized, which matches code. `docs/ai-usage-monitoring.md` claims "polling pauses when the window is hidden" — verified via the occlusion observer. The doc says "retries every five minutes" for status; the code says every 5th tick (5 minutes at 60s/tick). ✅ Confirmed.

25. **No analytics/telemetry leakage.** No `os_log` of URL, header, or response body content. `aiusage fetch failed: domain=%{public}@` logs only the NSError domain. ✅ Confirmed.

26. **`Sources/AIUsage/UI/AIUsageResetLabel.swift`** defines `providerUsageResetLabel` but I see no consumer in the diff. May be dead code, or intended for the popover/footer reset countdown that the doc mentions but I don't see rendered. ❓ Recommend either wiring it to display the reset countdown promised by the docs (the README claims "the next reset window when known") or deleting until needed.

---

## Phase 5: Validation summary

Re-read each finding and verified against the source. Status badges applied inline above. The dominant blocker-class issue is **#1 (orphan accounts render twice in Settings)** which is a visible UX bug; everything else is Important or Low Priority polish. **No security or thread-safety blockers.** The hot-path discipline holds: no edits to `WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh`. The XCTest gate on poller start is in place. Keychain access correctly uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `kSecAttrSynchronizable = false` and routes through `Task.detached`. `URLSession` is ephemeral, headers sanitized, hosts hard-allowlisted.

## Quick scan summary

**Blockers:** none.

**Important:**
- #1 Orphan account rendered twice in Settings (real UX bug; broken Edit button on the duplicate row).
- #9 `canSave` doesn't trim whitespace from secret values before validation.
- #15 ❓ Localization catalog 1:1 audit deferred (recommend pre-tag spot check).

**Notable low-priority items:**
- #3 Popover hardcodes `AIUsagePoller.shared` instead of using the injected one.
- #6 `UserDefaults.standard.bool` read on every footer body re-eval.
- #8 Stale fetch error after credential update until next tick.
- #10 50ms sleeps in poller lifecycle tests (CI-flake risk, not policy violation).
- #13 `helpDocURL` fragments don't match the doc headings; consumer may not exist.
- #20 `remove()` deletes Keychain before persist rollback.
- #26 `AIUsageResetLabel` may be dead code.

**Confirmed clean:**
- Hot paths untouched.
- Naming hygiene (no `cmux`/`CMUX` in `Sources/AIUsage/`).
- Keychain attributes (accessibility + non-sync).
- Ephemeral URLSession + header sanitization + status host allowlist.
- Secret redaction (description, debugDescription, customMirror, dump, interpolation).
- XCTest gate on poller start; clean stop on terminate.
- Privacy doc reflects code.
