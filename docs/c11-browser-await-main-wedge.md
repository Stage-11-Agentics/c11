# Browser JS await on a never-loaded WKWebView freezes the socket control plane

Diagnostic writeup from a live production wedge on 2026-08-12. Repro harness:
`tools/await-wedge-repro/`.

## Summary

`v2AwaitCallback`'s main-thread branch runs a nested `CFRunLoopRunInMode` pump inside an
in-progress `_dispatch_main_queue_drain`. Socket commands reach their work through
`v2MainSync`, so for as long as that pump runs, **the entire CLI/socket control plane and
the UI are frozen**.

Normally that window is short: `WKWebView.evaluateJavaScript` delivers its completion
handler on the main *runloop*, which the nested pump does service, so the await resolves in
milliseconds.

**The exception is a `WKWebView` that has never been asked to load anything.** It has no
assigned web process, the completion handler is never invoked, and the await burns its
**entire** `timeout_ms` holding the main queue. `timeout_ms` is uncapped.

The defect is present at `release/v0.64.0` (PR #419) — `v2AwaitCallback` and the uncapped
`timeout_ms` are both unchanged there.

## Correction to an earlier version of this document

An earlier draft claimed *every* main-thread browser JS eval is guaranteed to fail, based on
a harness that modeled delivery with `DispatchQueue.main.async`. **That claim was wrong.**
Testing against a real `WKWebView` disproved it: WebKit does not deliver through the main
dispatch queue, and the common paths all resolve normally. The scope of this bug is much
narrower than that draft stated. The `DispatchQueue.main.async` finding is still true and
still a real latent hazard for anything *else* on this path (see below), but it is not how
WebKit delivers, and it is not what happened in production.

## The measurement

`tools/await-wedge-repro/` holds two harnesses. Both reconstruct the exact frame shape
captured from the wedged process — background queue → `DispatchQueue.main.asyncAndWait` →
verbatim port of `v2AwaitCallback`'s main-thread branch → nested `CFRunLoopRunInMode`.

**`WebKitDelivery.swift`** — real `WKWebView`, varying only the page state:

| Case | Page state | Completion fired? | Elapsed (3.0s timeout) |
|---|---|---|---|
| `loaded` | document committed | yes | 0.05s |
| `deadport` | load issued, connection refused | yes | 0.05s |
| `hanging` | server accepts, never responds | yes | 0.05s |
| `uncommitted` | **no load ever issued** | **NO** | **3.09s → nil** |

Note that `deadport` and `hanging` — the intuitive suspects — both resolve fine. A web
process exists, so JS evaluates against the current `about:blank` document. Only the
never-navigated view wedges. A `url == nil` guard would not distinguish them: `deadport`
also reports `url=nil, isLoading=false` after the navigation fails.

**`AwaitDeadlock.swift`** — synthetic delivery mechanisms, no WebKit:

| Case | Delivery | Fired? | Elapsed |
|---|---|---|---|
| `timer` | CFRunLoop timer source | yes | 0.50s |
| `mainqueue` | `DispatchQueue.main.async` | **NO** | 3.00s → nil |
| `never` | never invoked | no | 3.00s → nil |

The `mainqueue` result is a genuine constraint on this code path: libdispatch will not
re-enter a main-queue drain already on the stack, so **any** callback delivered via
`DispatchQueue.main.async` can never land inside this pump. WebKit happens not to use that
route. Anything added to this path later that does will silently burn its full timeout.

Both harnesses report a verdict and exit with distinct codes. `./run.sh` runs the matrix.

## The incident

~53 agents across the Marquee V2 fleet running browser-proof gates. c11 v0.61.0 (build 123).

- 18:27:44 ET — a browser surface on `127.0.0.1` is created (`surface.created`, seq 8795).
- 18:28:56 ET — the main thread stalls.
- The stall ran **continuous and monotonic for 25+ minutes**, `stalledMs` climbing at
  wall-clock rate, while the longest timeout in any fleet command was 60s.
- The event stream froze mid-write at 18:29:45. Every `c11 …` call died at the CLI's 10s
  client timeout. UI completely unresponsive.

Wedged stack from `sample(1)`:

```
_dispatch_main_queue_drain              <- drain ALREADY IN PROGRESS
  _dispatch_async_and_wait_invoke       <- socket cmd hopped to main
    MainActor.assumeIsolated
      v2BrowserWait -> v2WaitForBrowserCondition
        -> v2RunBrowserJavaScript -> v2RunJavaScript
          -> v2AwaitCallback
            -> CFRunLoopRunInMode       <- the pump; control plane is dead here
```

Corroborating detail: the WebContent process spawned at exactly 18:27:44 (PID 1400) had
opened **zero page resources** — only the WebKit framework itself. That is the signature of
a prewarmed process never assigned a document, matching the `uncommitted` case.

Agents were unaffected throughout — 28 of 53 measurably advancing, `io-reader` threads
draining PTYs normally. Only the control plane and UI died.

## Real-world rate

Agent transcripts, 2026-08-12:

```
205  timeout: method=browser                    (CLI 10s client give-up)
 29  Condition not met before timeout
  3  Timed out waiting for JavaScript result
```

The CLI abandons at 10s while the server keeps burning its timeout, so these are largely
invisible in `ps` and read as agent flakiness rather than a control-plane defect.

Relevant: the c11 skill already warns *"If `get url` is empty or `about:blank`, navigate
first instead of waiting on load state."* That guidance exists because this footgun is
reachable — but it is guidance, not enforcement, and a fleet of agents will hit it.

## Still unexplained

A single un-navigated wait, at the 60s worst case, cannot by itself produce a 25-minute
continuous stall. The leading hypothesis is a serialized backlog: agents retry after their
10s CLI give-up while the server is still burning the previous timeout, enqueueing faster
than the queue drains.

Evidence for: 205 CLI give-ups, all leaving server-side work still running.
Evidence against: SIGSTOPing all 55 agents for 4 minutes did not drain it (`stalledMs`
1,173,349 → 1,353,485, still linear). That was likely too short to clear a 20-minute
backlog, but it did not confirm the theory either.

**Test that settles it:** freeze all agents 20–30 minutes and watch `stalledMs`. Plateau =
backlog confirmed, wedge self-heals given quiet. Still climbing with zero agents = a second
defect.

## Recommended fixes

1. **Cap `timeout_ms`.** `BrowserHandlers.swift:1357` is lower-bounded only
   (`max(1, v2Int(params, "timeout_ms") ?? 5_000)`). Uncapped, it is a direct multiplier on
   control-plane downtime. Cheapest meaningful mitigation.
2. **Fail fast when the view has never loaded a document.** Return an error immediately
   rather than burning the timeout. Requires tracking commit state on `BrowserPanel`
   (`didStartProvisionalNavigation` / `didCommit`) — `url == nil` is not a sufficient
   predicate, per the `deadport` row above.
3. **Move browser JS-eval methods off-main** — the root fix. `socketWorkerV2Methods`
   (`TerminalController.swift:1964`) is the established mechanism, and no `browser.*` method
   is in it. The off-main branch of `v2AwaitCallback` already blocks a worker thread on a
   semaphore while main stays free, which is correct. This is the same remedy the codebase
   already applied to the terminal path in C11-26 — see `waitForTerminalSurfaceOffMain`
   (`TerminalController.swift:3115`), whose comment names this exact deadlock. Needs an
   audit of browser handlers for main-thread assumptions; not a release-branch change.
4. **Correct the comment at `BrowserHandlers.swift:321-324`.** It claims the loop "still
   pumps … main-queue blocks." It does not, and the `mainqueue` harness row proves it.

## Instrumentation

`MainThreadHangMonitor` is what made this diagnosable, and C11-192's stack fingerprinting
attributed the stall to the wedged frame rather than the watchdog. Two gaps:

- `hang.log` grew ~23 MB/min (a ~1.1 MB, 357-thread dump every 5s), reaching 212 MB. Needs
  rotation or a cap; a sustained wedge writes ~1.3 GB/hr.
- Seven precursor episodes (2.4s–10.7s) never surfaced to the operator. A repeated-fingerprint
  signal would have flagged this well before it went terminal.

## Status after C11-209

Re-measured on 2026-09-11 before any change; both tables above reproduced exactly
(`uncommitted` 3.12 s → nil, everything else resolving in ~0.05 s). One addition worth
recording: the failing cases **busy-spin**. `mainqueue` completed 1,566,040 pump slices in
3 s, meaning `CFRunLoopRunInMode(.defaultMode, 0.05, false)` returned immediately every
iteration because a main-queue block was pending that the nested pump structurally cannot
drain. A wedge is therefore a held main thread *and* a saturated core, not just a stall.

What C11-209 changed, against the four recommended fixes above:

1. **Cap `timeout_ms`** — done. `TerminalController.v2ClampBrowserTimeoutMs` clamps to
   `1 ... 120_000` at both parse sites (`browser.wait`, `browser.download.wait`). When a
   request is clamped the error payload carries `requested_timeout_ms` alongside
   `timeout_ms`. Note `browser.wait`'s worst case is 121 s, not 120 s: it passes
   `timeout + 1.0` to the eval as Swift-side grace over the JS-side timer.
2. **Fail fast when the view has never loaded** — done, and the predicate is
   "has a load ever been *issued* on this web view instance", tracked as
   `CmuxWebView.hasIssuedLoad` (set by the `load*`/`go*`/`reload*` overrides and by
   `didStartProvisionalNavigation`). As the `deadport` row above shows, `url == nil` would
   have been wrong. The guard sits in `v2RunJavaScript`, so it covers every browser JS call
   site at once — including `v2BrowserEnsureInitScriptsApplied`, which on a never-loaded
   surface with two init scripts and one style previously burned four sequential 5 s awaits.
   `browser.eval` and `browser.wait` pre-check as well so the caller gets a `no_document`
   code rather than `js_error`/`timeout`, with a message that distinguishes "never
   navigated" from "navigation requested but withheld" (insecure-HTTP prompt, pending
   remote-workspace proxy, hibernated surface).
3. **Move browser JS-eval methods off-main** — **not done**, deliberately. It remains the
   correct root fix. `browser.*` handlers are `@MainActor`-isolated, so moving them into
   `socketWorkerV2Methods` needs a main-thread-assumption audit of the whole handler family;
   that was out of scope for this ticket and is tracked separately. Consequence: a
   `browser.wait` against a *live* page still holds main for the duration of the wait,
   bounded now by the 120 s cap.
4. **Correct the comment** — done, in `v2AwaitCallbackPumpingMainRunLoop` (the main-thread
   branch, extracted from `v2AwaitCallback` so tests can drive it without a `TabManager`).

C11-209 also found and fixed a second live instance of the same hazard that this document
did not cover. `browser.download.wait` awaited through three main-queue routes —
`DispatchSource(queue: .main)`, `DispatchQueue.main.asyncAfter`, and `NotificationCenter`
with `queue: .main` — every one of them the `mainqueue` row, so the command could never be
satisfied early and always ran to its full timeout. The file-system source and its timeout
item moved to a private serial queue (with the watched descriptor's lifetime moved into the
source's cancel handler, since the await can unwind while the source is still live), the
observer moved to synchronous `queue: nil` delivery and is now removed on every outcome, and
the `ready_to_save` notification moved out of the `DispatchQueue.main.async` block that made
it undeliverable at the *posting* side. `v2AwaitCallbackPumpingMainRunLoop` now accepts
off-main delivery: its state is lock-guarded and a resolution wakes the run loop.

Still open, unchanged by this work:

- **The 25-minute stall is still unexplained.** The per-command burn these fixes remove is
  what the serialized-backlog hypothesis rests on, but the deciding experiment — freeze all
  agents 20–30 minutes and watch `stalledMs` — has not been run.
- **`hang.log` rotation.** ~23 MB/min, 212 MB observed, ~1.3 GB/hr sustained.
- **Precursor signalling.** Seven episodes of 2.4–10.7 s never surfaced to the operator.

One note for whoever validates work in this area next: **`c11 ping` is not a main-thread
probe.** `socketWorkerImmediateV1Response` answers it on the socket worker before any main
hop, so it stays fast during a total main-thread wedge. `c11 tree` takes the default
main-actor policy and is the probe that actually detects one.
