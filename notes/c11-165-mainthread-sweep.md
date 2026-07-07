# C11-165 COR-3 — main-thread-reachable socket path sweep

Fresh sweep of the post-extraction dispatch layer (`Sources/SocketHandlers/` + `Sources/TerminalController.swift`) on branch `ts/cor-p0-correctness` (cut from merged `origin/main` incl. C11-159). Goal: eliminate socket paths that block or wedge the main thread. Genres swept: `DispatchQueue.main.sync`, `DispatchSemaphore.wait`, `CFRunLoopRun`, and (added per plan §8.10) off-main WebKit touches.

## Threading model recap

`processCommandUsingSocketExecutionPolicy` (SocketDispatch.swift) runs on the socket **worker** thread. A v2 method in `TerminalController.socketWorkerV2Methods` is dispatched off-main via `socketWorkerV2Response`; every other method falls through to `DispatchQueue.main.sync { processV2Command }`, i.e. runs **on main**. So a handler that blocks (semaphore/CFRunLoopRun) is a main-thread freeze **iff** it is NOT on the socket-worker policy.

## Findings → resolution

| # | Path | Genre | Pre-C11-165 | Fix |
|---|------|-------|-------------|-----|
| 1 | `pane.confirm` (`v2PaneConfirm`, PaneHandlers.swift) | `semaphore.wait` ≤300s | **NOT** in `socketWorkerV2Methods` → dispatched on main → the wait froze the whole app (audit P0.4). The handler was written off-main-safe (`assert(!Thread.isMainThread)`) but never wired to the worker policy. | Added to `socketWorkerV2Methods` + explicit case in `socketWorkerV2Response`. Rewrote `nonisolated`: all main-actor work (tabManager/panel resolution, dialog present, race-time cancel) runs inside bounded `Task { @MainActor } + semaphore` hops (v2MainSync is itself `@MainActor` and unusable off-main). The ≤300s wait now blocks a worker thread. |
| 2 | `feedback.submit` (`v2FeedbackSubmit`, MarkdownFeedbackHandlers.swift) | `semaphore.wait` 35s | NOT on worker policy → on main. Its signaling `Task` inherited `@MainActor` from the enclosing method and could never start while main was blocked → **always** froze main ~35s then failed (audit P0.4). | Added to worker policy + case. Marked `nonisolated`, so the `Task` runs on the global executor and the wait blocks the worker. `FeedbackComposerBridge.submit` is `static async` (not main-actor), so no main hop needed. |
| 3 | Browser await (`v2AwaitCallback` main-thread branch, BrowserHandlers.swift) | nested `CFRunLoopRun` | Browser commands run on main (WKWebView is main-thread-only). The wait used `CFRunLoopRun` + `CFRunLoopStop`. Under **concurrent** browser commands the loops nest, and `CFRunLoopStop` only stops the *innermost* loop — an outer invocation's stop was swallowed and its socket thread wedged permanently (audit P0.4). | **Not** moved off-main — that would call WKWebView/WKHTTPCookieStore off their required thread → crash, strictly worse than the wedge, and would activate the P1.4 per-surface-dict race. Instead the main-thread branch now **pumps the run loop in 50 ms slices** (`CFRunLoopRunInMode`), checking its own `resolved` flag + deadline each slice. Each nested invocation unwinds on its own state; no cross-loop `CFRunLoopStop`. The loop still pumps events/callbacks/rendering, so main is not frozen and WebKit stays on main. |

### Why the browser genre is handled differently
`pane.confirm`/`feedback.submit` use `semaphore.wait`, which **freezes** main → they must leave main. `v2AwaitCallback`'s main branch used `CFRunLoopRun`, which **pumps** main (UI stays live) and only broke under nested concurrency → the correct fix keeps WebKit on main and makes the nesting robust. This avoids the off-main WebKit crash and the data race flagged in plan §8.8.

## Post-fix sweep results (verification)

- `CFRunLoopRun` / `CFRunLoopStop`: **0** remaining in the dispatch layer; only the sliced `CFRunLoopRunInMode(.defaultMode, 0.05, true)` at BrowserHandlers.swift.
- `semaphore.wait` sites: all now execute on the socket worker — the four pre-existing send/read workers (SurfaceHandlers), plus `pane.confirm`, `feedback.submit`, and `v2AwaitCallback`'s off-main branch. None reachable on main.
- `DispatchQueue.main.sync`: only the dispatch seam (SocketDispatch.swift:89) for genuinely main-actor methods — unchanged, correct.
- Off-main WebKit touches: none — browser handlers were deliberately left on the main path, so `WKHTTPCookieStore` / `takeSnapshot` / `evaluateJavaScript` still run on main.
- Regression guard: `v2PaneConfirm` keeps its `assert(!Thread.isMainThread)`; a mismatch between `socketWorkerV2Methods` and the `socketWorkerV2Response` switch would surface as `method_not_found` (worker path) or trip the existing `invalid_dispatch` DEBUG `assertionFailure` (main path).

## Out of scope (same genre, not socket-dispatch-reachable) — flagged for follow-on
- `TabManager` git-probe pipe-buffer deadlock (audit P0.4, `TabManager.swift`) — a workspace probe, not reachable from socket dispatch.
- The deeper "move all browser.* off-main" architecture (worker policy + marshal every WebKit `start`-closure to main + serialize the per-surface dicts) is a larger follow-on; the slice-pump fix removes the P0 wedge without it.
