# Verdicts: batch `browser` (135 rows)

Read-only sweep of upstream cmux browser fixes against c11 `main`. Evidence is from reading the code; nothing was built or run. Items marked (inferred) are reasoning, not observation. Two caveats: the three sub-verifiers I launched died on an API spend limit, so all verification below was done directly, and the 49 `verify-skipped` rows are low-severity UX or CLI edge cases I did not read in depth.

## Verified

| bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence (upstream file + c11 path:line) | notes |
|---|---|---|---|---|---|---|---|---|
| Browser portal refresh forces synchronous AppKit layout and a whole-window `displayIfNeeded()` from inside SwiftUI update and geometry stacks. Upstream traced a garbage-SerialExecutorRef main-thread crash to an ObjC exception swallowed across Swift Concurrency, and showed the pass drives layout of the surrounding SwiftUI hosting hierarchy and sibling terminals. | 9773, 9774 | portal / SwiftUI | shared-confirmed | high | M | reimplement | upstream `Sources/BrowserWindowPortal.swift`, `Sources/Panels/BrowserPanelView.swift` (defer presentation work to a later main turn, flush only the portal-owned subtree). c11 `Sources/BrowserWindowPortal.swift:3300-3312` (`layoutSubtreeIfNeeded`, `displayIfNeeded` on container, webview and `(webView.window ?? hostView.window)?.displayIfNeeded()`), `:2473-2492`, `:2856-2859`, `:3744`; `Sources/Panels/BrowserPanelView.swift:6048,6077,6170-6173` (sync layout inside `updateNSView`). | Plausible contributor to known problem 2 and to C11-197 / C11-202 (SwiftUI update/layout passes wedging main 2.5-3 s): whole-window display from a browser refresh walks SwiftUI-owned ancestors (inferred). Crash path matters on macOS 26. Not proven to be the cause of any specific recorded hang. |
| WebContent process termination: c11 tears down and replaces the WKWebView synchronously inside `webViewWebContentProcessDidTerminate`. On macOS 26 this can overlap WebKit's provisional-page attach path and crash the whole app (`finishAttachingToWebProcess` to `updateActivityState`). Upstream moved to an explicit recoverable-termination state and replaces only on explicit reload. | 12519 | WebKit lifecycle | shared-probable | high | M | reimplement | upstream `Sources/Panels/BrowserPanel+WebContentTermination.swift`. c11 `Sources/Panels/BrowserPanel.swift:2912` (callback), `:3490-3560` (`replaceWebViewPreservingState` creates the replacement immediately). | Upstream could not reproduce deterministically either; Sentry shows 1.9k events on one release. c11's own June kill experiment (`notes/browser-freeze-triage-20260612/`) survived, so probable, not confirmed. A host crash kills every agent session on the box. |
| Closing a browser pane, window or quitting the app while the Web Inspector is open crashes in WebKit (`WKWebInspectorUIProxyObjCAdapter inspectorViewControllerDidBecomeActive:`, KERN_INVALID_ADDRESS). Fix closes inspectors synchronously before host teardown. | 3835 | Web Inspector | shared-confirmed | med | S | port | upstream `WebViewInspectorTeardown` called from pane, popup, window and app-quit close paths. c11 has no such helper (`git grep WebViewInspectorTeardown` empty); `Sources/Panels/BrowserPanel.swift:3621-3650` `close()` never hides DevTools; `Sources/Workspace.swift:1187` restores DevTools visible on session restore. | Needs the inspector open. c11 restores inspector visibility from session snapshots, raising exposure after restarts. |
| Related Web Inspector lifecycle bugs: detached inspector window close and redock crashes, inspector re-reveal after layout reentry, and inspector reopening itself after a manual close because `noteDeveloperToolsHostAttached` resets the grace timestamp on every update. | 4182, 6559, 2621, 5180 | Web Inspector | shared-probable | low | S | watch | c11 `Sources/Panels/BrowserPanel.swift:4649-4690` (willClose observer), `:4958-4964` (unconditional `developerToolsLastAttachedHostAt = Date()`, same as 5180 pre-fix). | Inspector use by agents is rare. Take with 3835 if that is ported. |
| Popup navigation delegate returns without ever calling the WebKit `decisionHandler` when its controller is gone (`controller?.presentInsecureHTTPAlert`). WebKit aborts when a policy handler is destroyed uncalled. Upstream also adds an exactly-once guard around every action/response handler. | 10567 | WebKit delegates | shared-confirmed | med | S | port | upstream `Sources/Panels/BrowserNavigationDecisionHandler.swift`. c11 `Sources/Panels/BrowserPopupWindowController.swift:564-568` (insecure-HTTP branch with optional-chained controller). | Trigger: popup torn down while it navigates to an insecure HTTP URL. Rare but it is a hard abort. Small fix: call `decisionHandler(.cancel)` when `controller` is nil. |
| Context-menu download resolution traps (`Duplicate values for key`) on a Google-host URL that repeats a query parameter or has keys that collide after lowercasing, killing the app. | 10480 | context menu download | shared-confirmed | med | S | port | upstream `BrowserDownloadURLNormalizer` (uniquingKeysWith, supported Google domains only). c11 `Sources/Panels/CmuxWebView.swift:578` `Dictionary(uniqueKeysWithValues:)`; `host.contains("google.")` at `:573` is also loose. | Triggered by right-click Download on a link or image on any `*google.*` host with duplicate params (Gmail `permmsgid`). Two-line fix. |
| Omnibar typing is slow with many workspaces or large history: every keystroke rebuilds a `SuggestionCandidate` (URL parse plus 5 lowercases) for every history entry (cap 5000), scans every panel in every workspace for open-tab matches, and runs the whole suggestion pipeline synchronously with no debounce. | 3422, 4647, 5397 | omnibar | shared-confirmed | med | S (5397, 4647), M (3422) | port | upstream `BrowserHistoryStore` match-field cache, `OmnibarSuggestionRefreshScheduler` (80 ms debounce), per-`TabManager` open-tab index. c11 `Sources/Panels/BrowserPanel.swift:1202-1215,1348-1366` (candidate rebuilt per entry per call), `Sources/Panels/BrowserPanelView.swift:2066-2100` (sync refresh), `:2180-2240` (`for tab in tabManager.tabs`). | Human typing in a browser pane only, but cost scales with workspace count (upstream: 137 ms per keystroke at 140 workspaces). Related in spirit to C11-141 (typing hot path, unbounded stores) but a different path (inferred). |
| `browser fill`, `type` and `select` assign `el.value` directly, so React/Vue/Angular controlled inputs keep their old state and the form submits empty. Fix uses the native prototype value setter. | 2059 | agent browser automation | shared-confirmed | med | S | port | upstream `TerminalController.swift` (native setter via prototype chain, fallback to assignment). c11 `Sources/SocketHandlers/BrowserHandlers.swift:2016` (type), `:2042` (fill), `:2178` (select). | Directly hits agent-driven form automation on modern SPAs. JS-only change. |
| `browser cookies clear --url X` (or `--path`) ignores the filter and clears every cookie in the shared profile, because `clearAll` is true whenever `all`, `name` and `domain` are absent. Upstream also requires an explicit scope. | 10626 | agent browser automation | shared-confirmed | med | S | port | upstream `Sources/TerminalController.swift`, `Sources/Panels/CmuxWebView+ScriptedDownloads.swift`. c11 `Sources/SocketHandlers/BrowserQueryHandlers.swift:1046-1056`; CLI passes `url` at `CLI/c11.swift:7686,7693` but the handler never reads it. | Silent loss of every logged-in session in the default profile. Agents are the main callers. |
| `browser state load` starts navigation and immediately writes localStorage/sessionStorage into the still-committed old document, then reports `loaded: true`; cookies are installed after the navigation starts. | 16204, 16205 | agent browser automation | shared-confirmed | med | M | reimplement | upstream `Packages/macOS/CmuxBrowser/.../BrowserStateLoadTransaction.swift`. c11 `Sources/SocketHandlers/BrowserQueryHandlers.swift:1559-1601` (navigate at `:1562`, cookies `:1565`, storage script `:1591` result discarded). | Breaks the `c11-browser` authenticated-session skill flow: restored state lands on the wrong origin. Needs a navigation-commit wait. |
| `browser.eval` on pages whose CSP forbids `unsafe-eval` fails with an opaque JS exception; upstream retries in an isolated content world and reports the real `WKJavaScriptExceptionMessage`. The main-actor wait/eval starvation half of this PR is already fixed in c11. | 5778 | agent browser automation | shared-probable (CSP half); already-fixed (main-actor wait/eval half) | med | M | reimplement | c11 `Sources/SocketHandlers/BrowserHandlers.swift:1561-1582` (`useEval` default true, no isolated retry; retry exists only for `!useEval` at `:716-735`). Already fixed by c11 commits `423e55479f` (C11-209) and `24acd3b423` (C11-217). | CSP-strict sites (Hacker News, GitHub) are common eval targets. Not run, so probable. |
| Screenshots of hidden or background browser panes can be stale, blank or partial: upstream adds an offscreen host, a render lease, layout/CA flush, double-rAF barrier and frame attestation with `screenshot_mismatch`. | 5424, 9281 | agent browser automation | shared-probable | med | L | watch | c11 `Sources/Panels/BrowserPanel.swift:5181-5191` (`takeSnapshot` with default config), `Sources/SocketHandlers/BrowserHandlers.swift:2262-2300` (5 s await, no presentation handling). | Agents screenshot browsers in background workspaces regularly. Do the cheap part first: report an explicit error when the surface is not visible. The full pipeline is large. |
| Find-overlay key routing scans `entriesByWebViewId.values` on each query, copying `Entry` structs with three weak refs each (objc_copyWeak under the global weak-table lock); upstream hit a stack-exhaustion SIGSEGV with 166 panes. Fix walks the slot subviews instead. | 5755 | portal / find | shared-confirmed | low | S | port | c11 `Sources/BrowserWindowPortal.swift:3581-3599`; callers `Sources/Panels/BrowserPanel.swift:5536,5554` (`ownedFocusIntent`/`yieldFocusIntent`). | c11 pane counts are far below 166 and the call is on focus handoff, not per keystroke (inferred), so low. Easy win. |
| `BrowserPanelView.onAppear` re-fires on portal-hosted panes and re-runs one-time setup (register defaults, five `@AppStorage` writes, empty-state browser detection task). Upstream measured 39% main-thread CPU. In upstream the loop also re-navigated the webview via discard-restore, which c11 lacks. | 5311 | SwiftUI / browser view | shared-probable | low | S | port | c11 `Sources/Panels/BrowserPanelView.swift:604,679-720`. | Settings-write churn feeds SwiftUI invalidation (C11-202 flavor, inferred). Re-navigation half is n/a in c11. |
| Closing a browser panel does not detach its portal entry; detach happens in `deinit` via a Task, which a retaining omnibar/suggestion callback can block, leaving a stale portal slot and stuck omnibar dropdown. | 7487 | portal / memory | shared-probable | med | S | port | upstream `BrowserPanel.close()` clears portal overlays and detaches first. c11 `Sources/Panels/BrowserPanel.swift:3621-3650` (no detach), `:4336-4342` (deinit Task detach). | A leaked WKWebView plus slot per closed browser is the memory shape Atin cares about under frequent surface create/close. Verify with a leak check before porting. |
| Session restore creates every browser panel eagerly, so restore with many browser tabs starts many WebContent processes at once; upstream stages restore with placeholders until visible. | 11006 | session restore / memory | shared-probable | med | L | watch | c11 has no placeholder materialization (`git grep` for deferred/placeholder browser empty); restore path at `Sources/Workspace.swift:1175-1190`. | c11 has operator-driven hibernate (C11-25) which can ease this. Inferred from absence of staging; not measured. |
| `window.close()` from a page does nothing in a normal browser pane (no `webViewDidClose` in the main UI delegate), so OAuth/pop-out pages leave blank panes behind. | 4070 | WebKit delegates | shared-confirmed | low | S | port | c11 `Sources/Panels/BrowserPopupWindowController.swift:381` is the only `webViewDidClose`. | Cosmetic leftover pane. |
| Cmd+Shift+T reopen retargets a closed browser snapshot to the selected workspace when its own workspace is gone, resurfacing stale URLs in unrelated workspaces. | 4961 | tab manager | shared-confirmed | low | S | port | c11 `Sources/TabManager.swift:4201-4208` (`?? selectedWorkspace ?? tabs.first`), stack never pruned per workspace (only reset at `:5678`). | Stack capacity 20, so bounded. |
| `cookies set` ignores `httpOnly`, and `cookies get` does not report it. | 10628 | agent browser automation | shared-confirmed | low | S | port | c11 `Sources/SocketHandlers/BrowserQueryHandlers.swift:925-998`. | Matters only when an agent seeds an auth cookie that the page must not read from JS. |
| Local browser panes leave `proxyConfigurations` empty, so WebKit sends `localhost`/`127.0.0.1` through the macOS system proxy (Clash/Surge) and dev servers fail. | 5915 | networking | shared-probable | low | M | watch | c11 `Sources/Panels/BrowserPanel.swift:3077-3092` (only remote workspaces set a proxy). | Hits only if Atin runs a global system proxy. |
| Browser file drops hang on "Uploading": `FileDropOverlayView` forwards the drop without `prepareForDragOperation` / conclude to the web view. | 1843 | drag and drop | shared-probable | low | S | watch | c11 `Sources/ContentView.swift:483` (no prepare/conclude overrides). | Human-only action; Atin says no drag automation on Hyperion. |
| No `window.showOpenFilePicker` support (upstream adds a polyfill/handler). | 4122 | WebKit delegates | shared-probable | low | M | skip | c11 `git grep showOpenFilePicker` empty. | Rare web API. |
| `browser.eval` returning a DOMRect crashes the host on macOS 15.5 during WebKit deserialization. | 12237 | agent browser automation | shared-probable | low | S | watch | upstream `BrowserControlService+EvaluationScript.swift`. c11 `BrowserHandlers.swift:1561-1582` returns raw values. | Atin is on macOS 26; matters for c11 users on 15. |
| Portal geometry hangs, flicker and drift (coalesced refreshes, split-resize stutter, divider resize). | 2353, 2214, 2513, 2574, 1969, 1852, 7038 | portal | n/a-diverged | n/a | n/a | skip | c11 reworked this under C11-132 / C11-133 (`e7510a65bd`, `9f7884c55c`: dirty-ID batching, settled-layout deferral, hosted-inspector divider cache, pointer-event gating). | Upstream symptoms tied to pre-rework code (inferred). The forced-layout issue above is the part that still applies. |
| Browser keyDown stack overflow and replay loops through `performKeyEquivalent`. | 5899, 5891 | keyboard | n/a-diverged | n/a | n/a | skip | c11 lacks the printable-Option and arrow forwarding paths; Return forwarding has a re-entry guard (`Sources/AppDelegate.swift:14107,14477`). | |
| Copy Image JS completion arrives off-actor and trips an actor assertion. | 10665 | WebKit | n/a-diverged | n/a | n/a | skip | c11 has no `BrowserOmnibarPageFocusAdapter`; Swift 5 language mode (`SWIFT_VERSION = 5.0`). | |
| mTLS client-certificate challenges. | 7040 | WebKit | n/a-diverged | n/a | n/a | skip | c11 `Sources/Panels/BrowserPanel.swift:6420-6424` returns `.performDefaultHandling`, so the keychain answers. | |
| Portal for deselected Bonsplit tabs stays visible above the new tab. | 2000 | portal | already-fixed | n/a | n/a | skip | c11 `Sources/Workspace.swift:11030-11046` hides the portal when a browser panel is not in the visible set. | |

## Top findings

**1. Forced synchronous layout in the browser portal (9773, 9774).** c11's `runHostedWebViewRefreshPass` calls `layoutSubtreeIfNeeded` on the slot, scroll view and web view, then `displayIfNeeded()` on the whole window (`BrowserWindowPortal.swift:3300-3312`). `BrowserPanelView.updateNSView` does the same inline (`:6170-6173`). Upstream showed two consequences: an Objective-C exception crossing Swift Concurrency on main, which corrupts the executor state and crashes later, and a refresh that drags the surrounding SwiftUI `NSHostingView` and sibling terminal panes through layout. With many agents plus a few browser panes, this fits the shape of C11-197/C11-202 and the main-thread congestion problem. Whether it caused a specific recorded hang is not shown. The port is a deferral (coalesce per webview, run on a later main turn, flush only the portal-owned subtree) and sits on top of c11's existing C11-132 batching.

**2. WebContent termination replaces the web view in the delegate callback (12519).** c11 builds the replacement WKWebView inside `webViewWebContentProcessDidTerminate` (`BrowserPanel.swift:2912, 3490-3560`). Upstream attributes a macOS 26 whole-app crash (WebKit attach IPC against a half-replaced view) to exactly this, with thousands of Sentry events. Atin runs macOS 26 and sleeps and wakes the machine for days; WebContent processes die on memory pressure and wake. A host crash takes every terminal session down. Reimplement as a recoverable-termination state: record the URL, detach callbacks, withhold portal mount, replace only on explicit reload.

**3. Agent browser automation has four silent-failure bugs.** `cookies clear --url` wipes the entire default profile (`BrowserQueryHandlers.swift:1046-1056`), `state load` writes storage into the wrong document and says `loaded: true` (`:1559-1601`), `fill`/`type`/`select` do not update React-style controlled inputs (`BrowserHandlers.swift:2016,2042,2178`), and `eval` has no isolated-world fallback on CSP-strict sites. All four are small JS or handler fixes with no AppKit risk, and they hit the c11-browser skill's flows directly. c11 already fixed the larger starvation problem (C11-209, C11-217), which is why these remain the right next tier.

**4. Two cheap hard-abort fixes.** The popup navigation delegate never answers WebKit when its controller is gone (`BrowserPopupWindowController.swift:564-568`), and `resolveGoogleRedirectURL` traps on duplicate query keys (`CmuxWebView.swift:578`). Both are one- to three-line changes that remove a guaranteed crash on a rare trigger. Pair them with closing the Web Inspector before pane, window and app teardown (3835), since c11 also restores the inspector open at session restore.

**5. Omnibar typing cost scales with workspaces and history (3422, 4647, 5397).** Per keystroke c11 rebuilds suggestion candidates for up to 5000 history entries, scans every panel in every workspace, and runs the pipeline synchronously. It only affects a human typing into a browser omnibar, so it is not a hang risk, but at 100+ workspaces it is a visible beachball. The three fixes are independent and small; 5397 and 4647 are a few dozen lines each.

## Triage ledger

pr | disposition | one-line reason

1843 | verify: shared-probable | FileDropOverlayView has no prepareForDragOperation/concludeDragOperation forwarding (ContentView.swift:483).
1850 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
1852 | verify: n/a-diverged | c11 reworked portal geometry sync under C11-132/C11-133 (dirty-ID batching, settled-layout deferral); upstream symptoms were tied to the pre-rework code (inferred).
1877 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
1891 | noise | Test-only, CI, skill text, compile fix or help text.
1897 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
1921 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
1969 | verify: n/a-diverged | c11 reworked portal geometry sync under C11-132/C11-133 (dirty-ID batching, settled-layout deferral); upstream symptoms were tied to the pre-rework code (inferred).
2000 | verify: already-fixed | c11 reconciles portal visibility per layout and hides deselected panels (Workspace.swift:11030-11046).
2059 | verify: shared-confirmed | browser fill/type/select set el.value directly (BrowserHandlers.swift:2016,2042,2178); React/Vue state ignores it.
2108 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
2141 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
2214 | verify: n/a-diverged | c11 reworked portal geometry sync under C11-132/C11-133 (dirty-ID batching, settled-layout deferral); upstream symptoms were tied to the pre-rework code (inferred).
2219 | na-feature | Upstream-only setting, Design Mode toolbar or Chrome-parity enhancement.
2346 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
2353 | verify: n/a-diverged | c11 reworked portal geometry sync under C11-132/C11-133 (dirty-ID batching, settled-layout deferral); upstream symptoms were tied to the pre-rework code (inferred).
2356 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
2513 | verify: n/a-diverged | c11 reworked portal geometry sync under C11-132/C11-133 (dirty-ID batching, settled-layout deferral); upstream symptoms were tied to the pre-rework code (inferred).
2574 | verify: n/a-diverged | c11 reworked portal geometry sync under C11-132/C11-133 (dirty-ID batching, settled-layout deferral); upstream symptoms were tied to the pre-rework code (inferred).
2621 | verify: shared-probable | Web Inspector lifecycle (detached close/redock, host-attach timestamp reset) shares c11 code (BrowserPanel.swift:4649-4690, 4958).
2779 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
2780 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
2930 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
3262 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
3299 | na-feature | Browser tab drag to new workspace and sidebar drops use upstream-only files (AppDelegate+MoveTabToNewWorkspace etc.).
3335 | na-feature | Shortcut remap settings UI and config store, upstream-only.
3338 | na-feature | Shortcut remap settings UI and config store, upstream-only.
3381 | na-feature | Browser tab drag to new workspace and sidebar drops use upstream-only files (AppDelegate+MoveTabToNewWorkspace etc.).
3398 | na-feature | Shortcut remap settings UI and config store, upstream-only.
3422 | verify: shared-confirmed | Omnibar does full history rebuild, all-workspace panel scan and suggestion pipeline per keystroke, no debounce (BrowserPanelView.swift:2066-2240, BrowserPanel.swift:1348).
3430 | na-feature | Browser tab drag to new workspace and sidebar drops use upstream-only files (AppDelegate+MoveTabToNewWorkspace etc.).
3460 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
3520 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
3663 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
3694 | noise | Revert pair or terminal IME change, no browser bug fix.
3782 | noise | Revert pair or terminal IME change, no browser bug fix.
3788 | noise | Revert pair or terminal IME change, no browser bug fix.
3835 | verify: shared-confirmed | BrowserPanel.close() (BrowserPanel.swift:3621) and window/app close never close Web Inspector first; WebKit UAF on close.
3842 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
3849 | noise | Revert pair or terminal IME change, no browser bug fix.
4038 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
4047 | noise | Test-only, CI, skill text, compile fix or help text.
4070 | verify: shared-confirmed | Main browser UI delegate has no webViewDidClose; window.close() leaves the pane open (only popup controller implements it).
4122 | verify: shared-probable | No showOpenFilePicker support in c11 (git grep empty).
4126 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
4182 | verify: shared-probable | Web Inspector lifecycle (detached close/redock, host-attach timestamp reset) shares c11 code (BrowserPanel.swift:4649-4690, 4958).
4183 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
4186 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
4226 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
4268 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
4284 | na-feature | Upstream-only setting, Design Mode toolbar or Chrome-parity enhancement.
4397 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
4608 | na-feature | BrowserAppSession, Window overlay host, AppKit sidebar list, report_pwd package or sidebar snapshots; code c11 lacks.
4623 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
4647 | verify: shared-confirmed | Omnibar does full history rebuild, all-workspace panel scan and suggestion pipeline per keystroke, no debounce (BrowserPanelView.swift:2066-2240, BrowserPanel.swift:1348).
4961 | verify: shared-confirmed | reopenMostRecentlyClosedBrowserPanel retargets a snapshot to selectedWorkspace ?? tabs.first when its workspace is gone (TabManager.swift:4201-4208).
5180 | verify: shared-probable | Web Inspector lifecycle (detached close/redock, host-attach timestamp reset) shares c11 code (BrowserPanel.swift:4649-4690, 4958).
5247 | na-feature | File editor, copy mode, terminal link routing, terminal image paste, tmux pane overlay or terminal find; not browser code (terminal batches own these).
5270 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
5311 | verify: shared-probable | handleViewAppear does register(defaults:), five @AppStorage writes and refreshEmptyStateImportBrowsers on every onAppear (BrowserPanelView.swift:679-720).
5315 | na-feature | Hidden-webview discard manager and media playback tracking do not exist in c11 (operator-driven hibernate only).
5328 | na-feature | File editor, copy mode, terminal link routing, terminal image paste, tmux pane overlay or terminal find; not browser code (terminal batches own these).
5352 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
5394 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
5397 | verify: shared-confirmed | Omnibar does full history rebuild, all-workspace panel scan and suggestion pipeline per keystroke, no debounce (BrowserPanelView.swift:2066-2240, BrowserPanel.swift:1348).
5406 | na-feature | File editor, copy mode, terminal link routing, terminal image paste, tmux pane overlay or terminal find; not browser code (terminal batches own these).
5412 | na-feature | Hidden-webview discard manager and media playback tracking do not exist in c11 (operator-driven hibernate only).
5424 | verify: shared-probable | c11 screenshot is a bare takeSnapshot on the possibly hidden webview with no flush/offscreen host (BrowserPanel.swift:5181, BrowserHandlers.swift:2262).
5744 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
5755 | verify: shared-confirmed | searchOverlayPanelId/yieldSearchOverlayFocusIfOwned scan entriesByWebViewId.values, copying weak refs (BrowserWindowPortal.swift:3581-3599).
5778 | verify: shared-probable | Main-actor wait/eval starvation already fixed by C11-209/C11-217; CSP isolated-world retry for browser.eval is missing (BrowserHandlers.swift:1570, retry only when !useEval).
5780 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
5891 | verify: n/a-diverged | c11 has no printable-Option replay or arrow forwarding; Return forwarding already has a depth guard (AppDelegate.swift:14107,14477).
5899 | verify: n/a-diverged | c11 has no printable-Option replay or arrow forwarding; Return forwarding already has a depth guard (AppDelegate.swift:14107,14477).
5915 | verify: shared-probable | Local webviews leave proxyConfigurations empty so loopback goes via system proxy (BrowserPanel.swift:3077); only remote workspaces set it.
5923 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
5938 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
5999 | na-feature | macOS 27 SF Symbol rasterizer; RenderableSystemSymbol does not exist in c11 and Atin is on macOS 26.
6258 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
6559 | verify: shared-probable | Web Inspector lifecycle (detached close/redock, host-attach timestamp reset) shares c11 code (BrowserPanel.swift:4649-4690, 4958).
6566 | na-feature | Hidden-webview discard manager and media playback tracking do not exist in c11 (operator-driven hibernate only).
6580 | noise | Test-only, CI, skill text, compile fix or help text.
6756 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
6818 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
6862 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
7038 | verify: n/a-diverged | c11 reworked portal geometry sync under C11-132/C11-133 (dirty-ID batching, settled-layout deferral); upstream symptoms were tied to the pre-rework code (inferred).
7040 | verify: n/a-diverged | c11 already returns .performDefaultHandling for client-cert challenges (BrowserPanel.swift:6420-6424), letting the keychain answer.
7468 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
7487 | verify: shared-probable | BrowserPanel.close() does not detach the portal; detach waits for deinit (BrowserPanel.swift:4341) which a retaining overlay callback can block.
7533 | na-feature | Hidden-webview discard manager and media playback tracking do not exist in c11 (operator-driven hibernate only).
7634 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
7917 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
8077 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
8079 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
8506 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
8528 | na-feature | BrowserAppSession, Window overlay host, AppKit sidebar list, report_pwd package or sidebar snapshots; code c11 lacks.
8601 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
8705 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
9054 | na-feature | UA policy (Google Sheets) added upstream after the fork; c11 has no BrowserUserAgentPolicy, so the 100% CPU restart loop cannot occur.
9087 | na-feature | File editor, copy mode, terminal link routing, terminal image paste, tmux pane overlay or terminal find; not browser code (terminal batches own these).
9239 | noise | Test-only, CI, skill text, compile fix or help text.
9281 | verify: shared-probable | c11 screenshot is a bare takeSnapshot on the possibly hidden webview with no flush/offscreen host (BrowserPanel.swift:5181, BrowserHandlers.swift:2262).
9296 | na-feature | Shortcut remap settings UI and config store, upstream-only.
9323 | na-feature | BrowserAppSession, Window overlay host, AppKit sidebar list, report_pwd package or sidebar snapshots; code c11 lacks.
9483 | na-feature | UA policy (Google Sheets) added upstream after the fork; c11 has no BrowserUserAgentPolicy, so the 100% CPU restart loop cannot occur.
9536 | na-feature | UA policy (Google Sheets) added upstream after the fork; c11 has no BrowserUserAgentPolicy, so the 100% CPU restart loop cannot occur.
9576 | noise | Test-only, CI, skill text, compile fix or help text.
9744 | noise | Test-only, CI, skill text, compile fix or help text.
9773 | verify: shared-confirmed | Portal refresh does synchronous layoutSubtreeIfNeeded and whole-window displayIfNeeded (BrowserWindowPortal.swift:3300-3312, BrowserPanelView.swift:6170-6173).
9774 | verify: shared-confirmed | Portal refresh does synchronous layoutSubtreeIfNeeded and whole-window displayIfNeeded (BrowserWindowPortal.swift:3300-3312, BrowserPanelView.swift:6170-6173).
9794 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
10177 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
10224 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
10454 | na-feature | File editor, copy mode, terminal link routing, terminal image paste, tmux pane overlay or terminal find; not browser code (terminal batches own these).
10460 | na-feature | Upstream-only setting, Design Mode toolbar or Chrome-parity enhancement.
10480 | verify: shared-confirmed | Dictionary(uniqueKeysWithValues:) traps on duplicate query keys in resolveGoogleRedirectURL (CmuxWebView.swift:578).
10567 | verify: shared-confirmed | Popup nav delegate returns without calling decisionHandler when controller is gone (PopupNavigationDelegate, BrowserPopupWindowController.swift:565-567); WebKit aborts.
10626 | verify: shared-confirmed | cookies clear ignores --url and treats url-only/no-filter as clear-all (BrowserQueryHandlers.swift:1046-1056).
10628 | verify: shared-confirmed | cookies.set ignores httpOnly and cookies.get does not report it (BrowserQueryHandlers.swift:925-998).
10634 | na-feature | Upstream-only setting, Design Mode toolbar or Chrome-parity enhancement.
10665 | verify: n/a-diverged | c11 has no BrowserOmnibarPageFocusAdapter; Swift 5 mode, no actor-assert path.
11006 | verify: shared-probable | c11 restores browser panels eagerly (no deferred placeholder); many WebContent processes spawn at once on restore (inferred).
11088 | noise | Test-only, CI, skill text, compile fix or help text.
11931 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
12237 | verify: shared-probable | browser.eval returns raw WebKit values; DOMRect crash is macOS 15 only (Atin is on macOS 26).
12519 | verify: shared-probable | c11 replaces the WKWebView synchronously from webViewWebContentProcessDidTerminate (BrowserPanel.swift:2912, 3490-3560).
12752 | na-feature | File editor, copy mode, terminal link routing, terminal image paste, tmux pane overlay or terminal find; not browser code (terminal batches own these).
12834 | na-feature | BrowserAppSession, Window overlay host, AppKit sidebar list, report_pwd package or sidebar snapshots; code c11 lacks.
13003 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
13376 | na-feature | BrowserAppSession, Window overlay host, AppKit sidebar list, report_pwd package or sidebar snapshots; code c11 lacks.
14502 | verify-skipped | Low-severity browser UX or CLI edge; not read in depth (guess: shared-probable low).
14646 | na-feature | File editor, copy mode, terminal link routing, terminal image paste, tmux pane overlay or terminal find; not browser code (terminal batches own these).
16098 | noise | Test-only, CI, skill text, compile fix or help text.
16204 | verify: shared-confirmed | state load navigates then writes storage into the old document and always returns loaded:true (BrowserQueryHandlers.swift:1559-1601).
16205 | verify: shared-confirmed | state load navigates then writes storage into the old document and always returns loaded:true (BrowserQueryHandlers.swift:1559-1601).

## Counts

- Rows in batch: 135
- na-feature: 31
- noise: 12
- verify: 92 PR rows, of which 43 were read in depth and 49 are verify-skipped (low-severity UX and CLI edge cases, guess shared-probable low)
- Of the 43 read in depth, collapsed into 28 distinct bugs or groups: 12 shared-confirmed, 11 shared-probable, 1 already-fixed, 4 n/a-diverged groups. PR 5778 is counted once under shared-probable (its main-actor wait/eval half is already fixed by C11-209 and C11-217).
