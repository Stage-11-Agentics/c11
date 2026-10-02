# C11-311 plan

## Release independence

P2. The 1.0 release ships with this ticket still open. No P0 or P1 ticket depends on it. C11-216 and C11-270 are validation gates for the slices that get attempted, not merge gates for the release. Each slice below is its own PR, branched `c11-1.0/C11-311-<slug>` from `origin/main`, with no stack. A slice does not edit a P0/P1 contract, and skipping it leaves the others mergeable. Groups that are not attempted stay listed on this ticket. Do not mark the ticket done while a group is still unattempted and unrecorded.

Order when the run has time: browser cookies and state load, then resume directory, then the in-app double resume, then any S slice. One group per PR. Do not land the sweep as one diff.

## Astra, not planned here

**B075.** `WorkspaceManager.restoreSessionSnapshot` (`Sources/WorkspaceManager.swift:5658-5731`) builds a new workspace array and assigns `workspaces = newTabs` without retiring the previous graph. Closing that graph means tearing down live Ghostty surfaces. That is the 2026-08-25 `Surface.deinit` mailbox deadlock (known problem 1). The ticket already says to do this only after the Ghostty mailbox work, so teardown can abort. This seat does not plan that teardown. B075 has a proposed Astra slice in this ticket's notes; leave it deferred unless the Orchestrator confirms admission and its owner. This seat does not implement it. Do not add a `teardownAllPanels` call on the restore path in any slice below.

## Citations (base `0ff8887e`)

Re-found. Ledger lines from before C11-248 that disagree with the list below are stale.

- **B006.** `v2AwaitCallback` (`Sources/SocketHandlers/BrowserHandlers.swift:580`) still pumps `CFRunLoopRunInMode` on main (`:739-830`). C11-209 already capped caller timeouts at 120s (`Sources/TerminalController.swift:334-339`) and refuses a WebView that has never loaded (`BrowserHandlers.swift:459`, `v2BrowserWebViewHasIssuedLoad`). `browser.eval`, `browser.wait`, and `download.wait` already wait on the worker. What is left on main is the cookie-store waits (`BrowserQueryHandlers.swift:908-929`), called from `v2BrowserWithPanel` → `v2MainSync`, and `waitForTerminalSurface` (`TerminalController.swift:6460-6483`), whose observer is `queue: .main` and so cannot fire during the pump. Do not port the upstream fast-fail that returns nil and drops the work.
- **B018.** `ContentView` holds `@State private var observedWindow: NSWindow?` (`Sources/ContentView.swift:1482`), assigned at `:2963`. That is a strong window reference. `MainWindowContext.window` is already weak (`AppDelegate.swift:2113`).
- **B069, probable.** `unregisterMainWindow` (`AppDelegate.swift:13312-13376`) drops the routing context and forgets seen stamps. It does not mark the manager retired, and it does not stop a later callback from creating a surface. `TerminalTab.close` (`Sources/Tabs/TerminalTab.swift:245`) only runs when something still calls it.
- **B046.** History of 10 already exists (`SessionPersistence.swift:586-631`, #467). `save` (`:557`) still overwrites the live file after that one archive. There is no poorer-write hold-back and no load path from `session-history/`.
- **B193.** `applicationWillResignActive` (`AppDelegate.swift:3147-3153`) calls `saveSessionSnapshot` on main on every deactivate.
- **B050.** `applicationWillTerminate` (`AppDelegate.swift:3139-3140`) calls `PostHogAnalytics.flush` (`PostHogAnalytics.swift:77-81`), which `workQueue.sync`s and then flushes the SDK. Quit waits.
- **B247, probable.** `resumeOwnership` (`Workspace.swift:572-588`) returns `.unique` for an unquarantined ref. `executeResumeAction` (`:666`) types the command. No live-process check.
- **B248, probable.** `ClaudeCodeStrategy.resume` (`Sources/Conversation/Strategies/ClaudeCode.swift:46-58`) and `CodexStrategy.resume` (`Codex.swift:107-132`) type the resume in the terminal's current directory. `OpencodeStrategy` already prefixes `cd`. The terminal snapshot stores `tabDirectories` (`Workspace.swift:835`), which is the drifted cwd.
- **B032.** The focus post is still synchronous inside the selection mutation (`Workspace.swift:11328-11336`). The ContentView observer (`ContentView.swift:2623-2628`) does not call `focusTab`. It calls `attemptCommandPaletteFocusRestoreIfNeeded` (`:6987`), which calls `focusWorkspace` only when a palette-dismiss target is pending (`:7000`). There is no general 426-second cycle on this SHA.
- **B093.** `ensureSurfaceReadyForInput` (`GhosttyTerminalView.swift:4950-4958`) returns the surface and does not reassert Ghostty focus. `keyDown` (`:5633`) uses it. The hidden/tiny branch only logs (`:8687-8696`). `reassertTerminalSurfaceFocus` (`:8833`) always `setFocus(true)` and can `forceRefresh`.
- **B114.** Bonsplit is not checked out in this worktree. Read-only verification via the main checkout's object database at the parent-pinned `c17c6f41cd71066bda9bec82c54465fe34821c75` confirms `Sources/Bonsplit/Internal/Controllers/SplitViewController.swift:260-276`: `SplitViewController.closePane` sets `focusedPaneId` to the sibling unconditionally, and `Workspace.splitTabBar(_:didClosePane:)` (`Workspace.swift:11832`) applies the close. Do not retarget focus in `didClosePane`. Fix it in bonsplit.
- **B049.** `bind` (`TerminalWindowPortal.swift:1512`) calls `ensureInstalled` (`:1519`), and `ensureInstalled` calls `synchronizeLayoutHierarchy` (`:1283`), which is `layoutSubtreeIfNeeded` (`:1036-1040`). External geometry is already deferred (`:1017-1032`). Bind is not.
- **B160.** `paneId(forPanelId:)` (`Workspace.swift:8858-8862`) and `ensureFocus` (`GhosttyTerminalView.swift:8708-8709`) scan every pane's tabs. `WorkspaceContentView` (`:73` and `:85`) reads `selectedTab(inPane:)` in `body`. The spinner filter is a different ticket.
- **B078.** `v2BrowserCookiesClear` (`BrowserQueryHandlers.swift:1046-1060`) sets `clearAll` when `all`, `name`, and `domain` are absent. It never reads `url` or `path`. The CLI already passes `url` (`CLI/c11.swift` near 7686).
- **B080.** `v2BrowserStateLoad` (`BrowserQueryHandlers.swift:1559-1601`) calls `navigate`, then writes cookies and storage, then returns `loaded: true`. Storage runs against the document that is still committed.
- **B083.** `NSColor.darken` (`GhosttyConfig.swift:644-655`) calls `getHue` on `self`. `luminance` just above converts with `usingColorSpace(.sRGB)` first. Split dividers call `darken` at `:60`.
- **B137.** `GHOSTTY_ACTION_PWD` (`GhosttyTerminalView.swift:2237-2246`) calls `AppDelegate.shared?.workspaceManager?.updateSurfaceDirectory`. `updateSurfaceDirectory` (`WorkspaceManager.swift:2461`) only searches that manager's workspaces. `GHOSTTY_ACTION_GOTO_SPLIT` (`:2118-2126`) uses the same key-window manager. `GHOSTTY_ACTION_NEW_SPLIT` (`:2107`) already uses `workspaceManagerFor(workspaceId:)`.
- **B148.** `keyDown` (`GhosttyTerminalView.swift:5633-5638`) calls `super.keyDown` when the surface is not ready.
- **B064.** `Resources/bin/claude:47-56` skips only its own directory, then execs at `:235` and `:238`. `Resources/bin/codex:74-83` has the same finder. The banners are `c11 claude wrapper` and `c11 codex wrapper`.

## Slices

Each slice names what makes it releasable on its own.

### `cookie-state` — B078, B080

`browser cookies clear` with a url or path clears only cookies that match that scope. `name` and `domain` keep working. Explicit `all: true` still clears the profile. A call with none of those is `invalid_params` and removes nothing. `browser state load` sets cookies against the file's target URL, starts navigation, and writes localStorage and sessionStorage only after that navigation has committed on that origin. Until then `loaded` is false and the old document is not written. Do not edit `replaceWebViewPreservingState` (C11-287).

Incident: B078 wipes the shared profile; B080 reports loaded on the wrong origin (the `c11-browser` skill). Test: a pure matcher for the clear filter in `c11LogicTests`, plus `tests_v2` on Atlas for one url-scoped clear that leaves another origin's cookie, and one state load whose storage script runs only after the committed URL matches. No new UI strings.

Independent behavior, but BrowserQueryHandlers is a shared integration file; refresh and serialize against browser/await owners. A release without this PR keeps today's commands.

### `resume-cwd` — B248

Claude and Codex resume commands gain the same `cd <ref.cwd> &&` prefix Opencode already uses, when `ref.cwd` is non-empty. Empty cwd stays the command they type today. Do not change the terminal's ordinary start directory for a non-resume shell.

Incident: probable resume into a drifted `tabDirectories` cwd. Test: `c11LogicTests` on the strategy. Fixture ref cwd `/proj`, no assertion that a live shell moved. If a strategy's text already contains `cd`, do not add a second one. Atlas: start from a different synthetic directory and execute the actual generated resume command through the tagged terminal with a fake harness that records its cwd/argv. Assert it ran in the ref cwd; a command-string prefix alone is not runtime proof. Cover a quoted/spaced cwd and a missing directory so the agent is not started in the wrong directory.

Independent: resume command text only. Ships without the writer check.

### `resume-owner` — B247

Before `executeResumeAction` types a command, skip when another live surface in this process already has that conversation id and its terminal process is still alive. That is the trigger we can establish. A session with no c11-owned live pid still resumes, which is today's behavior. Do not scan the process table and do not read or write `~/.claude` or `~/.codex`. If that outside-writer case cannot be shown from c11's own pid, the PR says so. A missing outside reproducer is not a fake lock file.

Incident: probable second resume of a session this process still owns. Test: two plans, same id, first surface's pid alive, second decision is skip. Dead pid resumes.

Independent: a skip in front of the existing command. Ships without the `cd` prefix.

### `wrapper-reentry` — B064

`find_real_claude` and `find_real_codex` skip any PATH entry whose first 512 bytes contain that wrapper's banner, not only `$self_dir`. Set a reentry variable before exec. If it is already set, do not exec another wrapper. No real binary: the existing not-found exit. Wrappers stay in the bundle. No writes to `~/.claude` or `~/.codex`.

Incident: prod and a tagged build on PATH exec each other. Test: a shell fixture with two banner-marked fakes and one real binary. The real binary runs once. Same fixture shape for Codex.

Independent: two bundle scripts. No app binary.

### `theme-darken` — B083

`darken` converts with `usingColorSpace(.sRGB)` before `getHue`, as `luminance` does. If conversion fails, return `self`. Divider call site stays.

Incident: catalog or grayscale `getHue` raises and aborts. Test: `c11LogicTests` calls `darken` on a grayscale color and a catalog color and gets a color back.

Independent: one color function. No theme rewrite.

### `quit-telemetry` — B050

`applicationWillTerminate` does not call `PostHogAnalytics.flush`. Quit does not wait on `workQueue` or the SDK. Capture on the worker can still flush asynchronously. Telemetry on quit is best-effort.

Incident: quit blocked on a flush that can need main. Test: a worker double that blocks until a flag set after the call returns. The terminate-path method returns while that flag is still clear.

Independent: quit stops waiting. Session save on terminate stays.

### `resign-snapshot` — B193

`applicationWillResignActive` does not call `saveSessionSnapshot`. Autosave and the terminate path keep saving. Resign returns without encoding the fleet.

Incident: every deactivate snapshots every session on main. Test: the resign function's save decision is observable and false. Atlas: deactivate a tagged app. The main thread is not inside `saveSessionSnapshot` for that call.

Independent: one call site. The hold-back slice still works if this never lands.

### `snapshot-holdback` — B046

On save, if the new snapshot has fewer workspaces or fewer surfaces than the live file, keep the live file and do not replace it for 5 minutes. An explicit operator save still writes. After 5 minutes a poorer save may replace it. Add a load of one file from that snapshot's own `session-history/` directory, rejecting paths outside it. No new picker UI. Any new error string uses `String(localized:)` and is handed to the translation ticket. Prefer reusing an existing error so there is no new string.

Incident: a poorer relaunch overwrites the only good layout. History already keeps the previous process's file, which is not the hold-back. Test: `c11LogicTests` against a temp directory. A smaller snapshot does not replace the bytes inside the window. A history load reads the archived file and refuses a path outside the directory.

Independent: the store only. Resign can keep calling save.

### `focus-post` — B032

Post `.ghosttyDidFocusSurface` on the next main turn, one pending post per workspace and surface. Do not add a focus broadcaster and do not change `focusTab`. The palette observer stays. A short before/after sample is enough. C11-270 is the soak.

Incident: the synchronous post. The 426-second cycle is not on this SHA. Test: a focus change publishes one note after the caller returns, and two changes of the same surface publish one.

Independent: one notification. Focus behavior stays.

### `focus-reassert` — B093

First establish the native-focus mismatch as described in the takeover correction below. The existing lastFocusState dedupe can suppress setFocus(true); repair the demonstrated first-responder transition with a narrow native reassertion. Do not add unconditional per-key focus or forceRefresh work. The hidden/tiny path stays a defer.

Incident: typed input held while AppKit and Ghostty disagree. Test: a runtime focus-transition seam observes the native reassertion only for the admitted mismatch; an actual Atlas tagged UI pass proves typed text reaches the intended terminal after focus transitions. A call-count fake alone does not prove native focus.

Independent: the keyDown guard only. The focus post can ship separately.

### `bonsplit-close-focus` — B114

In bonsplit `closePane`, set `focusedPaneId` to the sibling only when the closed pane is the focused pane. Closing any other pane leaves `focusedPaneId` as it was. Push that commit to the bonsplit fork's `main` before the parent pointer. Do not commit a detached submodule. `didClosePane` does not gain its own focus assignment.

Incident: closing a background pane steals focus. Test: a bonsplit unit test with at least three panes: A focused, B and C siblings, close C, focus stays A instead of jumping to B. The inherited two-pane case cannot expose the defect because the chosen sibling would already be A. Also cover closing the focused pane and a nested split. Atlas: close an unfocused pane in a tagged window and the focused surface is unchanged.

Independent: the submodule and the pointer. No app focus rewrite.

### `portal-bind` — B049

`ensureInstalled` does not call `layoutSubtreeIfNeeded` when `bind` is the caller. The layout flush runs on the existing deferred sync (`scheduleDeferredFullSynchronizeAll`). Do not add a display link. Constraint installation can stay. If a crash stack from this path is inside the Ghostty renderer, stop and hand that stack to Astra. Do not patch the renderer here. Short sample. C11-270 is the soak.

Incident: nested layout from `bind` during a SwiftUI turn. Test: a bind-path seam that records layout flushes and shows the synchronous flush did not run.

Independent: portal install only. No Ghostty SHA change.

### `pane-identity` — B160

Pane membership and the selected-tab check used by `WorkspaceContentView.body` and `ensureFocus` read ids only. They do not read tab titles. Do not wait on the spinner-filter ticket. Short sample. C11-270 is the soak.

Incident: a title change refreshes portal content. Test: an executed ID lookup returns the pane/selected identity through split, reparent and close; an observer or tagged view instrumentation shows title-only updates do not cause portal selection/layout recomputation. Do not assert source/body fragments or treat an ID-returning unit test alone as proof of view subscription behavior.

Independent: lookup shape. Titles keep their own ticket.

### `pwd-routing` — B137

`GHOSTTY_ACTION_PWD` and `GHOSTTY_ACTION_GOTO_SPLIT` use `workspaceManagerFor(workspaceId:)` the way `GHOSTTY_ACTION_NEW_SPLIT` does. Do not retarget resize, equalize, or zoom in that switch.

Incident: a background window's directory is applied through the key window's manager, or dropped. Test: a routing seam. A workspace id that is not in the key-window manager still updates that workspace's surface directory.

Independent: two action cases. Resume cwd does not depend on it.

### `early-keydown` — B148

When `keyDown` has no surface yet, consume the event. Do not call `super`. Once the surface exists, the current path is unchanged, including the B093 reassert.

Incident: early keys beep or insert into another view during surface create. Test: the no-surface branch does not forward. The with-surface branch still returns the surface.

Independent: the nil-surface branch. Ships without the reassert.

### `socket-await` — B006

Keep the pump, the 120s cap, and the never-loaded refusal. Do not return nil instead of starting the work. Move the cookie-store get, set, and delete waits onto the worker, same pattern as `download.wait`. Point `waitForTerminalSurface`'s observer at a queue the pump can actually deliver, or wait off main. Trace any other `v2AwaitCallback` entered from main. Leave a caller on the pump only when its callback is a run-loop source and the comment says why.

Incident: C11-209, 2026-08-12, 25 minutes. The cap and the no-document guard are already on this SHA. Test: `BrowserAwaitPolicyTests` still bounds the pump. A cookie wait started off main completes when the store calls back, and a never-loaded WebView still fails without entering the pump.

Independent: the wait site. The cookie filter slice can land without it. Do not edit `BrowserQueryHandlers.swift` in both slices at once.

### `window-retain` — B018

On main-window close, clear `observedWindow` so the closed window is not held by `ContentView`. Prefer a weak box if `@State` would otherwise keep the strong reference across the close notification. Do not tear surfaces down here.

Incident: a closed window's SwiftUI content stays alive. Test: after the close signal, the state's window is nil. A live window still resolves.

Independent: one `ContentView` reference. The retire flag does not depend on it.

### `window-retire` — B069

On `unregisterMainWindow`, mark that manager retired. A retired manager refuses new terminal surface and PTY creation. Existing close of panels stays on the paths that already close them. Do not call `teardownAllPanels` from unregister. If the only way to stop the late PTY is that teardown, stop and hand the row to Astra with the repro, instead of widening this slice.

Incident: probable. A callback after the routing refs are gone can still create a PTY. Test: a retired manager rejects `newTerminalSurface`. An unretired manager still creates one. The late-callback trigger has to be this test or an explicit disproof in the PR.

Independent: a refuse flag. B075 stays with Astra.

## Hot path

`keyDown` (B148, B093): no allocation and no `forceRefresh` on the already-focused path. Portal `bind` (B049): remove synchronous `layoutSubtreeIfNeeded`, do not add a display link. Focus post (B032): one deferred post, not work inside the mutation. Pane lookup (B160): do not subscribe the portal body to titles. Everything else is off the typing path.

## Cut

Every tier-1 row. The ride-alongs named in the ticket, including B074, B014, B113, B120, B162, and `replaceWebViewPreservingState`. Tier 3, including the rows already fixed on this SHA (B051, B073, B081). B044. B075's teardown. Ghostty renderer and mailbox edits. A new focus system. A new snapshot picker UI. Tenant config writes. Split resize, equalize, and zoom routing. The spinner filter.

## Dependencies

None inside ws:bugs as a code dependency. Attempt slices after the Ghostty patch set and the app-half ticket are in review when the slice touches `TerminalWindowPortal` or `GhosttyTerminalView`, so the diff does not collide. C11-287 owns the browser host crash. Validation of tagged slices waits on C11-216. The short samples are not a substitute for C11-270.

## Decisions

None. Owner calls: poorer-snapshot hold-back is 5 minutes. Outside-c11 session writers are not blocked unless c11 already holds the pid. B075 remains deferred for this seat; the notes propose agent:astra-crashes as owner, but admission/ownership must be confirmed by Orchestrator before work. Do not count it fixed or started.

## Codex takeover corrections and gates (base 0ff8887e5e)

No build/test/reproducer/product change performed. All slices remain optional. Plan-audit-astra finding 13 accepts the P2 cut and requires explicit B075 deferral. Its notes describe a proposed independent Astra implementation with **C11-294 merged** as a hard prerequisite; do not weaken that to merely in review. This launch seat owns the holding ticket and only its admitted non-B075 slices. Reconcile the notes' old Grok-seat wording at handoff without rewriting another owner's evidence.

**B006 / B078 / B080.** Cookie waits are source-confirmed inside `v2BrowserWithPanel` main closures. State load also calls `v2RunBrowserJavaScript` there after starting navigation. Refactor these attempted paths to capture the WebView/store and invoke each WebKit operation in short main hops, then await on the socket worker with a deadline. A new navigation-commit wait must never block main or pump main-dispatch callbacks. Associate the completion with the same live browser tab/WebView and expected origin; wrong-origin redirect, failed navigation or timeout writes no storage and returns a bounded failure. Install cookies against the intended URL before navigation, preserve cookie domain/path attributes, and assert successful storage application before returning loaded true. No new general navigation framework. For a url cookie scope, use exact/subdomain cookie rules and applicable path/secure constraints, not a substring match that includes an unrelated host. Reject explicit-all plus filter ambiguity. Test real WK stores on two distinct loopback origins, with a delayed target page and untouched old-page storage, plus navigation failure/redirect. Update c11-browser API wording and sync installed c11-browser/c11 copies if edited. Existing raw `all: false` with no filters can also select every cookie; the repaired filter decision rejects that case.

**B093.** `TerminalSurface.setFocus` (`GhosttyTerminalView.swift:3909-3915`) deduplicates using `lastFocusState`; simply calling it again can be a no-op even when native Ghostty lost focus. Establish the real first-responder/native-focus mismatch before admitting this slice. Repair the observed focus transition with a narrowly forced native reassertion, rather than assuming lastFocusState is an authoritative native query or adding unconditional per-key focus work. Validate actual typed text after area/workspace focus transitions on the Atlas display; a fake seam only counting calls is insufficient. If no trigger is established, label the row unattempted/probable. Preserve C11-270's typing sample and the hidden/tiny guard.

**B046 / B050 / B193 / B018 / B069.** Tests invoke the affected save/quit/resign/window-close path through a runtime seam or host-required tests on Atlas. Hold-back tests include time-window expiry, explicit override and clean quit/update save so intentional deletions are not indefinitely suppressed. The history loader must be reachable by an explicit runtime action with path confinement and a behavioral restore check; an unused store helper is not a restore feature. A proposed observer test that merely asserts a save-decision constant is false does not prove the resign call stopped saving. Window-retain proof uses a weak reference that actually deallocates after close; window-retire proof drives a queued callback through the creation entry point after unregister, rather than only testing a stand-alone retired boolean. Keep probable late-callback defects separate from source-confirmed absence of a retirement flag.

**B247.** A live shell PID is not evidence that the agent still writes that conversation. Use this process's attributable live agent/conversation evidence, recheck immediately before sending, and retain the outside-c11-writer limitation. Exercise the real resume decision/submission seam, with same provider+session and a live attributed agent causing skip versus dead/unrelated shell cases allowing resume. Respect C11-273/C11-297's ownership/startup changes rather than creating a second ownership policy.

**All slices.** C11-257-owned CLI/dispatch/send/mailbox/wrapper files remain off-limits until it lands. Do not rely on “different hunks” for permission. Refresh against C11-259/260/262/273/294/295/297/299/301/303 and browser seat changes where files overlap; one slice/branch/PR at a time after explicit BUILD MODE and admission. New modules/test target membership use the same integration sequencing. C11-291 is mandatory for any admitted new localized strings before final sign-off. Every attempted visual/focus slice gets actual Atlas computer use on a verified tagged window/display with screenshots, hard timer and proven dismissal; socket setup/oracles complement that path. Unattempted groups, probable triggers and disproofs remain explicit on the ticket. No additional human decisions introduced.

## Reset 2026-10-02 by agent:codex-launch

## Reset 2026-10-02 by agent:codex-launch

## Reset 2026-10-02 by agent:codex-launch
