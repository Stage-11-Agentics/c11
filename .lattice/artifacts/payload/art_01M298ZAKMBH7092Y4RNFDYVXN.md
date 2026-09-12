# Plan Review: C11-209 — browser JS await wedges the socket control plane

Reviewer: Claude (Fable 5.1), headless plan review. Reviewed against `origin/main` @ `9aa097457` in the main checkout; worktree `c11-209-browser-await-wedge` is at `6b551c0ea` (three commits behind, all non-code: CLAUDE.md + dependabot).

### 1. Verdict

**FAIL (plan-level)**

The engineering content is strong and every code citation checks out. The plan fails on its validation protocol: the main-thread health probe it relies on (`c11 ping`) never touches the main thread, so five of the eight validation rows cannot distinguish a fixed build from a broken one, and one guarantee (G2) plus its row (V6) claims an outcome the change cannot produce. These are cheap to fix but they are the difference between "proven" and "believed", on a ticket that blocks a production release. Revise §2 and §4, address the Step 4 concurrency notes, then proceed.

### 2. Summary

I verified the plan's claims against source: `v2AwaitCallback`'s main-thread branch uses unlocked locals and a 50 ms `CFRunLoopRunInMode` pump; no `browser.*` method is in `socketWorkerV2Methods`, so every browser command runs inside a `DispatchQueue.main.sync` drain; `v2BrowserDownloadWait` awaits through exactly the three main-queue routes named; the two `timeout_ms` parse sites are the only ones and are unbounded; `browser new` with no URL reaches `BrowserPanel(initialURL: nil)` and never loads; C11-198 and C11-204 are squash-merged into main (#413, #417); the harness and doc are untracked. The plan's narrowing of the ticket (never-loaded web view is the production trigger; WebKit delivers via run loop) matches the doc's own correction section and is the right read. The key concern is that the validation matrix is built on a probe that answers on the socket worker before the main hop, and that Step 4 is described as making `browser.download.wait` non-blocking when it only makes it resolvable.

### 3. Issues

**[MAJOR] §4 Phase-4 validation protocol — `c11 ping` never touches the main thread, so V1/V2/V6/V8's "concurrent ping" probes are vacuous**
`cli/c11.swift:1813` sends the v1 text `ping`. On the server, `processCommandUsingSocketExecutionPolicy` (`SocketDispatch.swift:96-100`) answers it via `socketWorkerImmediateV1Response` on the socket worker, deliberately, before any main hop (the comment explains the A-button wrapper needed a probe that survives a busy UI). Consequence: on `origin/main` during a full 121 s wedge, `ping` still returns in milliseconds, so the "before: ping stalls ~121 s" column will not reproduce, and the "after: ping < 250 ms" column passes on any build. The same applies to `read-screen` (V8): it maps to `surface.read_text` (`cli/c11.swift:2758`), which is in `socketWorkerV2Methods` and runs off-main. Of the probes listed, only `c11 tree` (V8) actually hops to main.
**Recommendation:** Replace `ping` everywhere in §4 with a command that takes the default main-actor policy, e.g. `time c11 tree` or `c11 list`, and drop `read-screen` from V8. Add a sentence to the protocol explaining why `ping` is excluded, so a future validator does not reintroduce it. Optionally keep one `ping` row to demonstrate the probe design (it should stay fast in both columns).

**[MAJOR] §2 G2 and §4 V6 — Step 4 does not stop `browser.download.wait` from holding main; it only makes the await resolvable**
After Step 4, `browser.download.wait` still enters through `v2BrowserWithPanel` → `v2MainSync` → main-queue drain, and `v2AwaitCallback`'s main-thread branch still pumps the nested run loop until the event arrives or the deadline passes. During that window every main-hopping socket command is still stuck behind the drain, by exactly the mechanism §1 describes. What Step 4 buys is real and worth having: today the file-system event, the timeout work item, and the download notification are all delivered on the main queue and therefore can *never* land, so the command always burns its full timeout; after Step 4 an actual event resolves it early. But V6 ("nothing downloading, concurrent probe < 250 ms") asserts an outcome the change cannot produce, even with a correct probe, and G2's wording ("no longer holds main for its full timeout") will be read as "non-blocking". The plan's own §2 closing paragraph already states the accurate position for `browser.wait`; G2 contradicts it.
**Recommendation:** Reword G2 to: "`browser.download.wait` resolves when its event arrives instead of always burning `timeout_ms`; while waiting it still holds main, bounded by G3." Replace V6 with a positive probe that does not need a `WKDownload`: run `c11 browser download wait --path /tmp/c11-209/out.bin --timeout-ms 30000` while a shell does `sleep 2; cp somefile /tmp/c11-209/out.bin`. Before: returns at ≈30 s (the `.main` file source never fires inside the pump). After: returns at ≈2 s. Keep a second row for "nothing arrives → unwinds at ≈30 s, not later" as the deadline check.

**[MAJOR] §3 Step 4 — the closure state and the file descriptor are not safe once the source moves off main**
Two concrete hazards in the block the plan is editing (`BrowserQueryHandlers.swift:809-847`):
1. `finished`, `source`, and `timeoutWorkItem` are captured `var`s mutated by `finishOnce`. After Step 4 the source handler and timeout item run on the new serial queue, but the immediate `if pathIsReady() { finishOnce(true) }` after `resume()` still runs on main. Step 3's lock protects `v2AwaitCallback`'s `resolved`/`result`, not this outer `finished` flag, so two threads race on it.
2. `defer { close(fd) }` closes the descriptor when the handler returns, but the `DispatchSource` may still be live: `v2AwaitCallback`'s deadline and the `asyncAfter` timeout item are independent clocks, and if the await unwinds first nothing cancels the source. libdispatch requires the fd to stay open until the cancel handler runs ("BUG IN CLIENT OF LIBDISPATCH: Do not close random Unix descriptors"). Today this is masked because the source's events never fire at all; once they can, it is a real crash path.
**Recommendation:** Do the initial readiness check *before* `resume()` (or dispatch it onto the same serial queue) so every mutation of `finished`/`source` happens on one queue; on every exit path cancel the source and close `fd` from the cancel handler, not from `defer`. Add this to the Step 4 observable list and to Risk 2.

**[MAJOR] §3 Step 2 — the `no_document` message sends agents in circles on the production path**
The fleet drives `http://127.0.0.1`. `navigate(to:)` (`BrowserPanel.swift`) withholds the `load` when the insecure-HTTP gate fires (`presentInsecureHTTPAlert`), when a remote-workspace proxy endpoint is pending (`pendingRemoteNavigation`), and when the panel was constructed `pendingHibernate`. In all three the agent already passed a URL, `currentURL` is set, and `hasIssuedLoad` is correctly `false`. Fail-fast is the right behavior there, but "navigate first (browser goto <url>)" is wrong advice, and the C11-207 delegator is live on exactly the insecure-HTTP branch.
**Recommendation:** Keep the single guard, but have the two handler-level pre-checks include `current_url` and `lifecycle_state` in `data`, and pick the message on `browserPanel.currentURL == nil` ("never navigated; navigate first") versus non-nil ("navigation to <url> was requested but no load has been issued; check the insecure-HTTP prompt, remote proxy, or hibernation state"). Coordinate the wording with C11-207 before opening the PR, since both touch `BrowserPanel`'s navigate path and the skill text.

**[MINOR] §3 Step 9 — the `hasIssuedLoad` test would be the first `c11LogicTests` case to instantiate a `WKWebView`**
The four existing tests that construct a `WKWebView`/`CmuxWebView` (`BrowserPanelTests`, `BrowserConfigTests`, `BrowserCompanionPortalTests`, `WindowAndDragTests`) are all host-only. CLAUDE.md already warns that the bare xctest runner can crash on AppKit-dependent objects locally. The plan's local-test policy means this will first be exercised in CI.
**Recommendation:** Keep the test, but state in the plan that if CI's logic run trips on WebKit init, the test moves to `c11Tests` rather than being dropped. Also give the "never fired returns nil at the deadline" case in the Step 3 test a short timeout (≤ 0.5 s), not the 3 s the plan implies, to keep the logic suite fast.

**[MINOR] §3 Step 4 — observer leak on the timeout path**
In the notification branch (`BrowserQueryHandlers.swift:869-887`) the observer is removed only inside its own callback. When the await times out, the observer is never removed and fires forever for that surface. Pre-existing, but the plan rewrites this block.
**Recommendation:** Remove the observer after `v2AwaitCallback` returns regardless of outcome.

**[MINOR] §2 G3 — the effective cap for `browser.wait` is `timeout_ms + 1000`**
`v2WaitForBrowserCondition` passes `timeout + 1.0` to the JS eval, so a never-delivering wait holds main for 121 s under the 120 s clamp. Not a defect, but G3 should say so or the V7 timing will look off by a second.
**Recommendation:** State the +1 s in G3 and in the corrected comment.

**[MINOR] §3 Step 1 — availability-gated overrides**
`loadFileRequest`, `loadSimulatedRequest`, and `restoreInteractionState` need `@available(macOS 12, *)` overrides; a bare override fails to compile against the deployment target. Also, `webViewWebContentProcessDidTerminate` already replaces the `CmuxWebView` instance (`replaceWebViewPreservingState`), so the "reset to false" step is redundant on that path; the fresh instance starts false and is reloaded only when `shouldRestoreURL`. Harmless, but the plan should not add a delegate hook it does not need.
**Recommendation:** Gate the availability overrides; drop the explicit reset unless a code path keeps the same instance after termination.

### 4. Positive Observations

- **Baseline measured before touching anything, and the ticket's headline claim was falsified rather than inherited.** The plan re-ran both harnesses, found `url == nil` is not a usable predicate (the `deadport` row), and correctly narrowed the root cause to "no load ever issued" plus a separate latent main-queue-delivery hazard. That is exactly the kind of correction that keeps a fix from being a placebo.
- **Every file and line citation is accurate.** `v2MainSync` at 2336, `socketWorkerV2Methods` at 1992, `v2AwaitCallback` at 309, the download-wait routes at ~818/~836/~869, `didStartProvisionalNavigation` at 6093, both `timeout_ms` parse sites. A reviewer can go straight to the code.
- **Falsifiable guarantees.** Stating G1–G4 as claims that can be disproven is the right shape; it is what made the G2/V6 problem visible.
- **Scope discipline.** The off-main handler-family refactor, hang.log rotation, the precursor signal, and the 25-minute fleet experiment are each named, deferred with a reason, and routed to a follow-up rather than silently dropped or silently absorbed.
- **Second instance of the hazard found unprompted.** Identifying `v2BrowserDownloadWait` as a live `mainqueue`-row case in a second handler is genuine root-cause work, not ticket transcription.
- **Conservative cast rule and busy-spin observation.** `?? true` on the guard means the change can only avoid a wedge, never introduce one; noting that the failing case spins at ~500 k slices/s is a useful fact for the corrected comment.
- **Sibling awareness.** C11-207 and C11-212 overlap is called out with a rebase plan; C11-198/C11-204 were verified merged rather than re-done.
