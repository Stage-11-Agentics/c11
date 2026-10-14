# Trident Standard Code Review Synthesis — C11-23

- **Story:** C11-23 (AI usage monitoring)
- **Branch:** `c11-23-ai-usage-monitoring`
- **Reviewers:** Claude Opus 4.7, Codex (GPT-5), Gemini 1.5 Pro
- **Pack date:** 20260426-2246

---

## Executive Summary

All three reviewers find the architecture sound and the security/privacy posture strong: ephemeral `URLSession` (no cookies, no cache), Keychain credentials with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `kSecAttrSynchronizable = false`, off-main Keychain access, hard host allowlist for status pages, header sanitization, redacted secret types, an `AIUsageAppOwnedError` gate that prevents generic `URLError` strings from leaking to the UI, and confirmed avoidance of typing-latency hot paths (`hitTest`, `TabItemView`, `forceRefresh`).

The shared concern across all three reviews is **incomplete UI wiring**: the popover's Add/Edit menu actions are no-ops, and the reset-countdown logic exists in `AIUsageResetLabel.swift` but is never rendered. Both gaps directly contradict the documented feature set. Beyond that, reviewers flag a Codex parser that silently shows `0%` on malformed payloads, a possible "stuck refreshing" state when ticks are dropped during occlusion, and a duplicate-rendering bug for orphan accounts in Settings.

### Merge Verdict

**Do not merge as-is.** Two reviewers independently elevate the disconnected popover actions to a blocker-class issue (Codex labels Important; Gemini labels Blocker; Claude labels Important). Combined with the missing reset countdown (Gemini Blocker; Codex Important; Claude implicit via #26 dead code), the visible UX promised by `docs/ai-usage-monitoring.md` is not actually shipped. Recommend addressing the consensus-blocker UI wiring + the Codex `0%` parser fallback before merge; remaining items can land as polish follow-ups.

---

## 1. Consensus Issues (2+ Models Agree)

1. **Disconnected popover Add/Edit actions** (Claude — not raised; Codex Important #1; Gemini Blocker #2). `AIUsageFooterView` passes empty closures to `AIUsagePopover` for `onAdd: {}` and `onEdit: { _ in }` (lines 77-78 / 95-108). Clicking these visible menu items dismisses the popover with no effect. Docs (`docs/ai-usage-monitoring.md:20-21`) explicitly promise add/edit from this menu. Two-of-three consensus; treat as the dominant blocker. Fix: route callbacks to the editor sheet or to "Open Settings".

2. **Reset countdown is computed but never rendered** (Codex Important #3; Gemini Blocker #1; Claude Low-priority #26). `AIUsageWindow.resetsAt` is populated by both fetchers, and `Sources/AIUsage/UI/AIUsageResetLabel.swift` defines `providerUsageResetLabel`, but no UI surface consumes it. The `isSession` parameter in `AIUsageFooterView` rows is unused. Docs claim each row shows the next reset window (`docs/ai-usage-monitoring.md:15-18`). Fix: render the reset label in footer rows or remove the docs/code claim.

3. **50ms `Task.sleep` calls in poller lifecycle tests** (Claude Important #10; Codex Potential #6). `c11Tests/AIUsageTests.swift:477,481`. Not the prohibited 60s sleep, but scheduler-dependent and a CI-flake risk. Both reviewers recommend using the existing `tickBody` DI seam, an explicit `await drainPendingTicks()` test seam, or a continuation/expectation pattern.

4. **Test coverage gap on highest-risk paths** (Claude #11/#15 spot-checks; Codex Potential #5). The suite covers Keychain, redaction, validators, HTTP config, status host rejection, colors, and basic poller lifecycle. It does not exercise: Claude/Codex payload parsing, Codex malformed `used_percent`, popover callback wiring, reset-label rendering, or the pending-tick `isRefreshing` path. Recommendation: extract pure payload parsers from the network-coupled fetchers and test them deterministically.

5. **Strong security/privacy baseline confirmed** (Claude Quick scan; Codex Security and Privacy Notes; Gemini General Feedback). All three independently verified: ephemeral `URLSession`, Keychain attributes, secret redaction (`description`/`debugDescription`/`customMirror`/`dump`/interpolation), header sanitization (control chars + `;` + `,` stripped, `=` preserved), status-page host allowlist (`status.claude.com`, `status.openai.com`), `https://` enforced via constructed URL plus `:`-rejecting host validator, no credential or response-body logging.

6. **Hot-path discipline holds** (Claude Phase 3 + Quick scan; Codex paragraph 2). The diff does not touch `WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh`, or any file under `Sources/Panels/`. The only adjacent change is `SidebarFooter` wrapping the existing footer in a `VStack` with a single new child that early-returns `EmptyView()` when no accounts exist.

---

## 2. Divergent Views

1. **Severity of the popover wiring issue.** Gemini calls it a Blocker; Codex calls it Important; Claude does not raise it as a numbered finding (likely an oversight given Claude's depth of coverage elsewhere). Recommendation: treat as blocker since it ships visible-but-broken controls.

2. **Severity of the missing reset countdown.** Gemini calls it a Blocker; Codex calls it Important; Claude calls the orphaned helper Low-priority dead code (#26) without explicitly tying it to the docs promise. Recommendation: treat as Important (visible feature gap, not a security/correctness defect).

3. **`AIUsagePoller` timer subsystem.** Gemini suggests modernizing `DispatchSourceTimer` to a long-running `Task` with `Task.sleep` for simpler lifecycle. Claude and Codex view the current shape as fine. Divergence is stylistic — current implementation is correct and tested.

4. **JSON decode failure recovery in `AIUsageAccountStore.load()`.** Gemini calls out (Important #3) that an empty array on decode failure could silently drop accounts on schema changes. Claude and Codex did not flag this. Worth considering: log + preserve raw data, or rely on schema versioning. Note: Keychain credentials remain even if the index is dropped, but the user-visible inventory disappears.

---

## 3. Unique Findings (Single Reviewer)

### Claude-only

1. **#1 Orphan accounts render twice in Settings** (Important). `AIUsageSettingsSection.body` ForEach iterates all `store.accounts` including those with unknown `providerId`, and `orphanAccounts` re-renders them as a separate "Unknown provider" card. The duplicate row in the main list has a broken Edit button. Fix: gate `accountRow` on `provider(for: account) != nil`.

2. **#3 `AIUsagePopover.refreshNow` ignores its injected `poller`** and reaches for `AIUsagePoller.shared` directly (`AIUsagePopover.swift:99`). Defeats the DI seam.

3. **#4 `AIUsagePoller.refreshNow()` is silently inert before `start()`** (under XCTest or previews). Consider a log line or "polling paused" UI string.

4. **#6 `UserDefaults.standard.bool` read on every footer body re-eval** (`AIUsageFooterView.swift:50`). Per-tick re-read; cache into `@State` on first appear.

5. **#8 Stale fetch error after credential update** persists in `fetchErrors` until the next tick reassigns the dict. Fix: clear `fetchErrors[id]` on `store.update`.

6. **#9 `AIUsageEditorSheet.canSave` does not trim secret values before validation** (`AIUsageEditorSheet.swift:107`), though `save()` does. Whitespace-only secrets bypass the empty-check. Mirror the trim in `canSave`.

7. **#11 `testInterpolationOffMatchesDiscreteBuckets` is misnamed** — it asserts `color(for: 10) ≈ color(for: 20)` (same bucket) rather than verifying behavior across the threshold boundary.

8. **#12 `AIUsageAppOwnedError.isAppOwned` is decorative** — both concrete error types return `true`; the field never branches behavior. Either drop or document the reserved-for-future case.

9. **#13 `helpDocURL` fragments are broken**. URLs reference `#claude` / `#codex` but the doc would render `#add-a-claude-account`. Also: no consumer found in the diff. Either rename headings, fix URLs, or drop the field.

10. **#14 Naming hygiene clean** — no `cmux`/`CMUX` in `Sources/AIUsage/`; UserDefaults keys all `c11.aiusage.*`; Keychain services all `com.stage11.c11.aiusage.*`; OSLog subsystem `com.stage11.c11`.

11. **#19 Bool-as-percent inconsistency.** Claude's parser throws on `Bool`; Codex's parser returns `0`. Cross-reviewer link: this is the same root cause as Codex's #2 finding.

12. **#20 `AIUsageAccountStore.remove()` deletes Keychain before `persist(next)`** — if persist throws, the secret is already gone but the index still references it. Self-heals via `pruneOrphanAccountsIfNeeded` on next launch, but worth swapping order.

13. **#21 Pruning races first render** — `pruneOrphanAccountsIfNeeded` fires from `init` via a Task; UI may briefly show orphan accounts before pruning runs.

14. **#15 Localization 1:1 audit deferred** — recommends a pre-tag spot-check of `Localizable.xcstrings` against call sites.

### Codex-only

1. **#4 Pending-tick + occlusion can leave `isRefreshing` stuck true.** When a tick is in flight and `hasPendingTick = true`, the post-completion call to `scheduleTick(force: false)` returns early if the window is occluded (`AIUsagePoller.swift:126-128`), and the original task never reaches the `else { isRefreshing = false }` branch (lines 144-145). The footer can be left in a stale loading/refreshing state after a long poll plus occlusion. Fix: have `scheduleTick` report whether it actually scheduled, or explicitly clear `isRefreshing` when a non-forced pending tick is dropped. **This is a behavioral bug not flagged by the other two reviewers and warrants attention.**

2. **#2 Codex `used_percent` parsing falls back to `0`.** `toNumber` returns `0` for `nil`, `Bool`, or non-number values (`CodexAIUsageFetcher.swift:152-156`). API drift or partial responses display as "0%" instead of surfacing a decoding error. Claude's parser already rejects bad utilization; bring Codex into parity.

### Gemini-only

1. **#3 `AIUsageAccountStore.load()` resets to `[]` on JSON decode failure** (lines 111-120). Schema changes can silently drop the visible account inventory. Suggest preserving raw data and logging non-fatally.

2. **#4 Timeout layering.** `AIUsagePoller` uses a 20s `perFetchTimeout`; `ClaudeAIUsageFetcher`'s `URLSession` uses a 10s timeout. The session almost always wins. Defense-in-depth is fine, but unifying values would clarify intent.

3. **#5 Stylistic: prefer `Task` + `Task.sleep` over `DispatchSourceTimer`** for simpler lifecycle. Stylistic-only — current shape is correct.

---

## 4. Consolidated Action Items (Deduplicated)

### Blockers (resolve before merge)

1. **Wire popover Add/Edit callbacks** (Codex #1 / Gemini #2). Either present `AIUsageEditorSheet` from the popover or route to "Open AI Usage Settings". Current state ships visible-but-broken controls.

2. **Render the reset countdown** (Gemini #1 / Codex #3 / Claude #26). Mount `providerUsageResetLabel` in the footer rows; remove the unused `isSession` param if not used post-fix; keep docs and code aligned.

### Important (fix in this branch or as a fast follow)

3. **Fix orphan duplicate-render in Settings** (Claude #1). Filter the main `ForEach` to known providers so orphans render only once with a working code path.

4. **Reject malformed Codex `used_percent`** (Codex #2). Match Claude's stricter parser: reject `Bool`, `nil`, and non-numeric values rather than silently returning `0`.

5. **Fix stuck `isRefreshing` after occlusion** (Codex #4). Have `scheduleTick` signal whether it actually scheduled, or clear `isRefreshing` when a non-forced pending tick is dropped during occlusion.

6. **Trim secret values in `canSave`** (Claude #9). Mirror the existing trim in `save()`.

7. **Preserve raw data on `AIUsageAccountStore.load()` decode failure** (Gemini #3). Avoid silent inventory loss on schema drift; log non-fatally.

### Polish / Low-priority

8. **Replace 50ms `Task.sleep`s in lifecycle tests** with the existing `tickBody` seam, a continuation/expectation, or an explicit drain hook (Claude #10 / Codex #6).

9. **Add tests for payload parsing, popover wiring, reset-label rendering, and the pending-tick path** (Codex #5; complements Claude #11/#15). Consider extracting pure parsers from the fetchers so they can be tested without live network.

10. **Use the injected `poller` in `AIUsagePopover.refreshNow`** instead of `AIUsagePoller.shared` (Claude #3).

11. **Cache `UserDefaults.standard.bool(forKey: collapsedKey)` into `@State`** to avoid per-tick re-reads (Claude #6).

12. **Clear `fetchErrors[id]` on `store.update`** so saved credentials don't show stale errors until the next tick (Claude #8).

13. **Rename `testInterpolationOffMatchesDiscreteBuckets`** or extend it to cross a threshold boundary (Claude #11).

14. **Fix or drop `helpDocURL` fragments** (Claude #13). Either rename doc headings to match `#claude` / `#codex` or drop the field; also confirm the consumer exists.

15. **Either drop `AIUsageAppOwnedError.isAppOwned` or document its reserved usage** (Claude #12).

16. **Swap `AIUsageAccountStore.remove()` order** to persist-then-delete-Keychain (Claude #20).

17. **Spot-check `Localizable.xcstrings` 1:1 with call sites** before tagging (Claude #15).

18. **Surface a "polling paused" hint** when `refreshNow()` is inert under XCTest/previews (Claude #4).

19. **Unify `perFetchTimeout` (20s) with `URLSession.timeoutIntervalForRequest` (10s)** or document why both exist (Gemini #4).

20. **Audit `AIUsageResetLabel` consumer** — wire it (per item #2) or delete (Claude #26). Should be resolved by the blocker fix.

---

## 5. Confirmed Clean (Cross-Reviewer Validated)

1. Hot paths untouched: `WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh`, `Sources/Panels/*`.
2. Naming hygiene: no `cmux`/`CMUX` leakage in `Sources/AIUsage/`.
3. Keychain attributes: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `kSecAttrSynchronizable = false`.
4. Ephemeral `URLSession`: no cookies, no `URLCache`, `reloadIgnoringLocalCacheData`.
5. Header sanitization strips control chars + `;`/`,`; preserves `=`.
6. Status host allowlist enforced; `:` rejected; HTTPS guaranteed by URL construction.
7. Secret redaction across `description`, `debugDescription`, `customMirror`, `dump`, interpolation.
8. XCTest gate on poller start; clean stop on terminate.
9. No URL/header/body logging — only NSError domain via `os_log` with `%{public}@`.
10. Privacy doc (`docs/privacy-endpoints.md`) reflects the code.
