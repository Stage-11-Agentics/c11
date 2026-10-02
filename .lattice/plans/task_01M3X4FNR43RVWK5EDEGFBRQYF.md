# C11-287 plan

Verified on `0ff8887e5e`. The seat brief's "callback around :3515" is the replacement entry, not the WebKit callback. `Sources/Panels/BrowserPanel.swift` does not exist.

## What is wrong

`BrowserNavigationDelegate.webViewWebContentProcessDidTerminate` (`Sources/Tabs/BrowserTab.swift:6451-6455`) calls `didTerminateWebContentProcess` synchronously. The tab wires that to `replaceWebViewAfterContentProcessTermination` (`:2935-2937`, `:3515-3520`), which calls `replaceWebViewPreservingState` (`:3523-3603`) on the same stack. That calls `makeWebView` (`:2718-2762`, `:3562-3565`) before the callback returns.

`runHostedWebViewRefreshPass` (`Sources/BrowserWindowPortal.swift:3265-3320`) marks needsLayout/needsDisplay, then forces `layoutSubtreeIfNeeded` and `displayIfNeeded`, including `(webView.window ?? hostView.window)?.displayIfNeeded()` at `:3312`. Both the immediate and the async phase of `refreshHostedWebViewPresentation` (`:3337-3358`) do this. `BrowserTabView.updateUsingLocalInlineHosting` (`:6080`, `:6170-6173`) forces three `layoutSubtreeIfNeeded` calls during attach. It does not call `displayIfNeeded`.

`isCurrentWebView` is `:2860-2864`. The `:3491` cite is the canGoForward observer, not this path. `replaceWebViewPreservingState` only guards `oldWebView === webView` (`:3528`). `debugSimulateWebContentProcessTermination` (`:3606-3609`, DEBUG only) calls the replacement directly. `c11Tests/BrowserConfigTests.swift:1723-1745` asserts the new identity before the calling function returns. `makeWebView` still sets `BrowserTab.sharedProcessPool` (`:2723`). Leave that. `popupControllers` (`:1972`) are closed only from `close()` (`:3651-3659`).

## Change

Add `WebContentReplacementGate` in `BrowserTab.swift` (no new app file, no pbxproj for the type).

- `enqueue(instanceID) -> Bool`. Same instance while a turn is pending returns false. One turn.
- `beginTurn(currentInstanceID) -> Bool`. True only for the pending instance. Clears pending.
- `outcome(url:now:) -> restoreURL | errorPage | drop`. First termination of a non-blank URL inside 10 seconds is `restoreURL`. The next one for that same URL inside the window is `errorPage`. Another one inside the window is `drop` and does not call `makeWebView`. A different URL or a time past 10 seconds starts a new bounded window. Nil/blank URLs use a stable blank-page key and obey the same cap; they must not reset the counter on every crash. The existing `shouldRestoreURL` rules still apply on the restore path.

`webViewWebContentProcessDidTerminate` only forwards to the closure. The closure calls `scheduleWebViewReplacementAfterContentProcessTermination` and returns. That method checks `isCurrentWebView`, enqueues, and on success does `DispatchQueue.main.async` (not `Task`, not `DispatchQueue.main.sync`). The async block captures self and the terminated view weakly, calls `beginTurn`, checks `isCurrentWebView` and a tab-closed flag again, then:

- `drop`: return.
- `restoreURL`: existing `replaceWebViewAfterContentProcessTermination`.
- `errorPage`: add a defaulted restore-navigation option to `replaceWebViewPreservingState`, false on this path only. After binding the new view, call a narrow internal crash-error wrapper on `BrowserNavigationDelegate`; its existing `loadErrorPage` at :6458 is private and cannot be called directly from BrowserTab. Reuse that renderer with NSURLErrorUnknown. No new localized string.

Before detach, and only for reason `webcontent_process_terminated`, resign first responder when it is the old web view, and close `popupControllers` with the same three-step loop `close()` uses. Do not close popups on `workspace_reattach` (`:3306`).

`close()` invalidates pending replacement work and marks the tab closed before teardown. Object identity alone is insufficient: close currently leaves `webView` pointing to the old view (:3661-3665), so a retained closed tab would otherwise recreate it on the queued turn. `debugSimulateWebContentProcessTermination` calls the scheduler. It must not call `replaceWebViewPreservingState`.

DEBUG-only socket method `debug.browser.simulate_web_content_termination`, registered beside `debug.browser.favicon` in `Sources/SocketHandlers/SystemHandlers.swift` and dispatched in `Sources/SocketHandlers/DebugHandlers.swift`. Body uses `v2BrowserWithPanel` (`Sources/SocketHandlers/BrowserHandlers.swift:240`) only to call the scheduler and return `{scheduled: true}`. The replacement stays on the later turn, after `v2MainSync` returns. Do not activate the app. One line in `docs/socket-api-reference.md` next to `debug.browser.favicon`, and a DEBUG-only maintainer entry in `skills/c11-browser/references/commands.md`. After merge, sync c11-browser on the landing machine and verify the installed entry. No user-facing string.

Layout:

- In `runHostedWebViewRefreshPass`, keep the needsLayout/needsDisplay marks and `browserPortalReattachRenderingState` (`:79-113`). Delete every `layoutSubtreeIfNeeded` and `displayIfNeeded` from the immediate call, including the window call at `:3312`.
- The async phase of `refreshHostedWebViewPresentation` may call `layoutSubtreeIfNeeded` once on the container, scroll view, and web view. It must not call `displayIfNeeded`.
- `invalidateHostedWebViewGeometry` stays marks-only.
- Delete the three `layoutSubtreeIfNeeded` calls in `updateUsingLocalInlineHosting` (`:6171-6173`). Keep `needsLayout = true`.
- If the tagged-build check shows a blank page after a split resize or a simulated replacement, add one `layoutSubtreeIfNeeded` on the next turn and write why in the PR. Do not put `displayIfNeeded` back. No app-level display link. No `ghostty_surface_draw` loop.

## Acceptance

1. Incident: in-callback `WKWebView` creation killed the process (cmux ~1,900 times on macOS 26; c11 still swaps inside the callback). Tagged Debug build, `C11_QA_LAUNCH=fresh`. Open `https://example.com` in a browser tab next to a terminal. Socket-call the debug method. After one turn the same URL is loaded, the web view identity changed, and the terminal accepts a key. Ghostty log has no crash. Screenshot.
2. Incident: the callback returns only after `makeWebView`. Behavioral tests, not source greps.
   - `c11LogicTests` (add `WebContentReplacementGateTests` to the existing logic-test target by a hand edit of `project.pbxproj`, not the xcodeproj gem): two `enqueue`s of one instance before `beginTurn` produce one turn; outcomes across three calls inside 10 seconds are restore, error page, drop; a later call outside the window restores again.
   - `c11Tests/BrowserConfigTests.swift`: update the two tests at `:1723` and `:1739` to drain one main turn. After `debugSimulate` returns, identity and an internal replacement count are unchanged. After the turn, count is 1 and identity changed. Two calls before the turn still count 1.
3. Incident: `displayIfNeeded` on the window during portal refresh. No grep test. Tagged build: browser beside a terminal still paints after a split resize and after the simulated replacement. Screenshots. The window `displayIfNeeded` call is gone; say so in the PR from the diff, not from a test.
4. Incident: a crash loop pins a core. Gate test above is the behavioral proof. On the tagged build, invoke the debug method, wait, invoke it again within 10 seconds. The second turn ends on the existing error page and does not navigate back to the crashing URL. Document the cap in the PR: one URL-restoring replacement per URL per 10 seconds; the next termination in that window installs the existing error page; a further one does not call `makeWebView`; a termination while a turn is pending is ignored.
5. Neighbor check: `c11 browser snapshot` on a live page still returns a tree. One check. Do not change cookie, state-load, fill, eval, or screenshot code (H-E).

## Added ledger fixes (verified at takeover)

The ticket's later ride-alongs are binding and were missing from the stored plan:

- B113: BrowserTab.close (:3646) and BrowserPopupWindowController.windowWillClose (:260-281) tear down hosts without closing Web Inspectors. Close each owned view's inspector while still attached, before portal detach/delegate teardown; cancel pending developer-tools restore/transition work so it cannot reopen. Apply the same old-view shutdown during web-content replacement, preserving the existing restore intent for the replacement. Reuse guarded private inspector selectors. No new popup subsystem.
- B120: CmuxWebView.resolveGoogleRedirectURL (:580-585) builds Dictionary(uniqueKeysWithValues:) from lowercased query names. Replace it with a deterministic first-value-wins uniquing rule. Verify repeated and case-varied synthetic query names through the executable download-URL resolver (a narrow runtime seam if needed), plus an ordinary single-key URL. No source-text test.
- B162: PopupNavigationDelegate.decidePolicyFor (:539-568, BrowserPopupWindowController.swift) returns from the insecure-HTTP branch even when its weak controller is nil. Resolve the controller explicitly; nil calls decisionHandler(.cancel) exactly once. Preserve the existing controller-owned asynchronous prompt. Behavioral callback-count checks cover nil-controller cancellation and ordinary allowed navigation; use a narrow policy seam if WKNavigationAction cannot be constructed.

Atlas host tests also cover termination then close before the queued turn (no replacement), a stale old-view callback (no replacement), and blank-page repeated termination (bounded). Run the real navigation delegate callback as well as the DEBUG simulation so the callback-return test covers the production wire. Atlas CUA opens an inspector and closes its owning browser tab/window with a surviving terminal, then repeats crash replacement with the inspector open. Capture before/after screenshots and terminal input proof. All synthetic, tagged, QA launches.

## Hot path, strings, persistence

No change to terminal input. Because inspector teardown changes browser focus, compare a short browser/terminal focus-and-input probe on the tagged Atlas build with a tagged origin/main build under the same scenario, recording both numbers and load average (the C11-270 soak is deferred); no separate soak. The latency change is removing window `displayIfNeeded` from the SwiftUI portal refresh. Replacement stays on the main queue, off the WebKit callback stack and off `v2MainSync`. No new `String(localized:)` keys. No migration. Same `websiteDataStore`. Do not add a `WKProcessPool`.

## Cut

No process pool, passkeys, URL allowlist, popup manager, or H-E automation fixes. No C11-197, C11-202, C11-205. No new crash-trigger page. The debug socket method is DEBUG-only.

## Dependencies

None block this PR. X1 has nothing to translate unless a string is added later. PR body names H-E as untouched and offers the deferral plus the layout flush upstream (cmux #12519, #9773, #9774). Do not open that PR here.

## Decisions

None left open. Cap and layout choices above are the implementation.


## Implementation correction: host teardown

AppDelegate.applicationWillTerminate does not call TabContent.close. In BrowserTab.setupObservers, subscribe to app termination and the owning window closure; close inspectors and owned popups while the host is still attached, invalidate pending recovery, and preserve inspector visibility intent for the persisted snapshot. No AppDelegate or workspace edits. The window-notification behavioral host test observes inspector close before host detachment and no queued recovery afterwards.

## CI-driven corrections

The first host run reported an unexpected exit in repeated blank-page termination. Preserve that regression test and normalize the existing error renderer's empty failedURL to a nil HTML base URL. Also update BrowserWindowPortalLifecycleTests in c11Tests/BrowserTabTests.swift: removal of synchronous display deliberately changes its displayIfNeeded counters. Observe real setNeedsDisplay requests instead; the resize tests also assert that portal synchronization does not force display. Retain the existing reattach/visibility assertions, which also fail in the base CI log. No broad advisory-suite repair.

## Reset 2026-10-02 by agent:codex-browser
