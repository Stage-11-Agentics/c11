# C11-209 — Plan: browser JS await on a never-loaded WKWebView freezes the socket control plane

Delegator: C11-209-Delegator-1 · worktree `code/c11-worktrees/c11-209-browser-await-wedge` · base `origin/main` @ 6b551c0ea

---

## 0. Baseline re-measured (this machine, 2026-09-11, before any change)

`tools/await-wedge-repro/` is **untracked in the main checkout** (`?? docs/c11-browser-await-main-wedge.md`, `?? tools/await-wedge-repro/`) — it exists on disk at `code/c11/` but is in no commit and therefore not in this worktree. Both harnesses re-run from the main checkout:

`AwaitDeadlock.swift` (synthetic delivery, 3.0 s timeout):

| case | delivery | fired? | elapsed | note |
|---|---|---|---|---|
| `timer` | CFRunLoop timer source | yes | 0.53 s | pump slices = 8 |
| `mainqueue` | `DispatchQueue.main.async` | **NO** | 3.01 s → nil | pump slices = **1,566,040** |
| `never` | never invoked | no | 3.01 s → nil | pump slices = 3,165,821 |

`WebKitDelivery.swift` (real `WKWebView`, 3.0 s timeout):

| case | page state | fired? | elapsed |
|---|---|---|---|
| `loaded` | document committed | yes | 0.05 s |
| `deadport` | load issued, connection refused (`url=nil isLoading=false committed=false`) | yes | 0.05 s |
| `uncommitted` | **no load ever issued** | **NO** | **3.12 s → nil** |

Two findings I am treating as authoritative, both of which narrow the ticket's own framing:

1. **The ticket's headline claim is too strong.** It says "EVERY browser JS eval reaching that branch is guaranteed to fail." That is false and the doc's own "Correction" section says so: WebKit does **not** deliver `evaluateJavaScript` completions through the main dispatch queue, it delivers through the main **run loop**, which the nested pump *does* service. Only a WKWebView that has **never been asked to load anything** fails — it has no web process, so nothing is ever delivered at all.
2. **`url == nil` is not a usable predicate.** `deadport` reports `url=nil, isLoading=false, committed=false` and still evaluates JS fine in 0.05 s. The distinguishing fact is whether a load was ever *issued* on this webView instance, not whether one succeeded.

Also observed and worth recording: the failing cases **busy-spin**. 1.5 M pump slices in 3 s means `CFRunLoopRunInMode(.defaultMode, 0.05, false)` returns immediately every iteration, because the main queue has a pending block the nested pump is structurally unable to drain. So a wedge is not merely a stall, it is a stall at 100% of one core.

---

## 1. Root cause, restated precisely

Socket commands reach handler bodies through `v2MainSync` (`TerminalController.swift:2336`) → `DispatchQueue.main.sync` → an in-progress `_dispatch_main_queue_drain`. Browser handlers run inside that drain (`v2BrowserWithPanel`, `BrowserHandlers.swift:190-216`, wraps every one in `v2MainSync`). `v2RunJavaScript` therefore sees `Thread.isMainThread == true` and takes `v2AwaitCallback`'s main-thread branch (`BrowserHandlers.swift:310-347`), which pumps `CFRunLoopRunInMode` in 50 ms slices.

libdispatch will not re-enter a main-queue drain already on the stack. So **any callback delivered via the main dispatch queue can never land inside that pump**, and the await burns its entire timeout holding main — during which every `v2MainSync` socket command and the whole UI is frozen.

There are exactly two ways to reach that state in the shipped code:

**(A) The production trigger — nothing to deliver at all.** A never-navigated `WKWebView` has no assigned web process; `evaluateJavaScript`'s completion handler is simply never invoked. Matches the incident: the WebContent process spawned at 18:27:44 had opened zero page resources. This is not a delivery-route problem, it is an absence-of-delivery problem, and no change to the await mechanism can fix it.

**(B) A live second instance of the main-queue-delivery hazard.** `v2BrowserDownloadWait` (`BrowserQueryHandlers.swift:774-895`) awaits through three main-queue routes inside `v2AwaitCallback`:
  - `DispatchSource.makeFileSystemObjectSource(..., queue: .main)` (line ~818)
  - `DispatchQueue.main.asyncAfter(...)` for its timeout work item (line ~836)
  - `NotificationCenter.addObserver(forName: .browserDownloadEventDidArrive, queue: .main)` (line ~869) — `OperationQueue.main` enqueues onto the main dispatch queue

  Every one of these is the harness's `mainqueue` row. `browser.download.wait` on main is therefore a **guaranteed** full-`timeout_ms` control-plane freeze whenever the download is not already complete. This is not hypothetical and not covered by fix (A); it is the ticket's fix #1 hazard, shipping today, in a second handler.

Ticket fix #1 as literally written ("keep the JS-eval await off the main-thread branch, or complete the socket command asynchronously") would require moving `browser.*` into `socketWorkerV2Methods` (`TerminalController.swift:1992`). Those handlers are `@MainActor`-isolated (the production stack shows `MainActor.assumeIsolated` immediately above `v2BrowserWait`), so that is the browser-handler-family refactor the delegator brief explicitly puts out of scope. I am not doing it. It is the correct long-term remedy and I will recommend it as a follow-up ticket in the completion comment.

---

## 2. The guarantee this change delivers

Stated exactly, so it can be falsified:

> **G1.** A `browser.eval` / `browser.wait` / `browser.snapshot` (and every other `browser.*` JS path) issued against a surface whose `WKWebView` has never been asked to load a document returns a structured `no_document` error in **under 250 ms**, regardless of the requested `timeout_ms`, and a concurrent `c11 ping` issued during that window answers in its normal time (< 250 ms) rather than stalling.
>
> **G2.** A callback delivered from **off** the main thread now resolves `v2AwaitCallback`'s main-thread branch. `browser.download.wait`'s three awaits are moved onto that route, so a `browser.download.wait` that must actually wait no longer holds main for its full timeout — it resolves when the event arrives or unwinds at its deadline, whichever is first, and is interruptible in between.
>
> **G3.** No single browser socket command can request a main-thread hold longer than a documented cap (`timeout_ms` clamped to 120 000 ms at both parse sites).
>
> **G4.** A loaded page's JS eval still returns its value, and `browser.wait --timeout-ms N` on a loaded page still waits up to N ms for its condition (no truncation of legitimate waits).

Explicitly **not** claimed: "browser commands never block main." A `browser.wait` against a live page still holds main for the duration of the wait — that is pre-existing designed behavior of the main-thread branch, now bounded by G3, and only the off-main handler move (out of scope) removes it.

---

## 3. Implementation steps, each with its observable

### Step 1 — `CmuxWebView.hasIssuedLoad`, the fail-fast predicate
**File:** `Sources/Panels/CmuxWebView.swift`

Add `private(set) var hasIssuedLoad = false` to `CmuxWebView`. Set it to `true` by overriding every load entry point the app can reach: `load(_:)`, `load(_:mimeType:characterEncodingName:baseURL:)`, `loadHTMLString(_:baseURL:)`, `loadFileURL(_:allowingReadAccessTo:)`, `loadFileRequest(_:allowingReadAccessTo:)` (macOS 12+), `loadSimulatedRequest` variants (macOS 12+), `reload()`, `reloadFromOrigin()`, `go(to:)`, `goBack()`, `goForward()`, and `restoreInteractionState(_:)` where available. Each override sets the flag then calls `super`.

Belt for anything that bypasses those (session restore, in-page navigation, popup adoption): also set it from `BrowserNavigationDelegate.webView(_:didStartProvisionalNavigation:)` (`Sources/Panels/BrowserPanel.swift:6093`), which already runs on main.

Reset it to `false` in `webViewWebContentProcessDidTerminate(_:)` — a terminated web process returns the view to the processless state, and routing that back into fail-fast is strictly safer than awaiting into it. (If no such delegate method is currently implemented, add it; it must not change any other behavior.)

Conservative cast rule: the guard reads `(webView as? CmuxWebView)?.hasIssuedLoad ?? true`. A non-`CmuxWebView` (a popup's own view, a future path) is treated as loaded, so the guard can only ever *avoid* a wedge, never introduce a false failure.

**Observable:** unit test — a fresh `CmuxWebView` reports `hasIssuedLoad == false`; after `load(URLRequest(url: URL(string:"about:blank")!))` it reports `true`; after `loadHTMLString("<p>x</p>", baseURL: nil)` on another fresh instance it reports `true`.

### Step 2 — fail fast at the single JS choke point
**File:** `Sources/SocketHandlers/BrowserHandlers.swift`

In `v2RunJavaScript` (line 254), before constructing the evaluator, return
`.failure(Self.v2BrowserNoDocumentMessage)` when the webView has never issued a load.
`v2BrowserNoDocumentMessage` is a new static constant:
`"Browser surface has not loaded a document; navigate first (browser goto <url>)."`

This single guard covers all ~35 `v2RunJavaScript` / `v2RunBrowserJavaScript` call sites across `BrowserHandlers.swift` and `BrowserQueryHandlers.swift` without touching any of them — including `v2BrowserEnsureInitScriptsApplied` (`BrowserHandlers.swift:630-661`), which on a never-loaded surface with two init scripts and one style currently burns **four** sequential 5 s awaits = 20 s of frozen control plane per call.

So that the error the agent sees is accurate rather than `js_error`/`timeout`, add an explicit pre-check in the two handlers that own the production stack:
- `v2BrowserEval` (line 1054) → `.err(code: "no_document", message: …, data: ["surface_id": …])`
- `v2BrowserWait` (line 1355) → same, checked after the webView is resolved (line ~1418) and before `v2WaitForBrowserCondition`, so it does not come back as the misleading `timeout` / "Condition not met before timeout".

**Observable (e2e, phase 4):** on a tagged build, `c11 browser new` (no URL) then `c11 browser wait --load-state complete --timeout-ms 120000` returns `no_document` in < 250 ms; a `c11 ping` issued concurrently returns in its normal time. On `origin/main` the same pair stalls the ping for ~121 s.

### Step 3 — make the main-thread await accept off-main delivery (root fix for the delivery class)
**File:** `Sources/SocketHandlers/BrowserHandlers.swift`, `v2AwaitCallback` (line 309)

Today the main-thread branch's `resolved`/`result` are plain locals mutated only from main, so a callback arriving on another thread would race. Change:
- guard `resolved` / `result` with an `NSLock` (same shape the off-main branch already uses);
- after a resolution that arrives off-main, call `CFRunLoopWakeUp(CFRunLoopGetMain())` so the pump breaks out of its current 50 ms slice instead of waiting it out;
- read `resolved` under the lock in the loop condition.

This makes off-main delivery a *supported* route into the main-thread branch, which is what Step 4 needs. Cost is one uncontended lock acquisition per 50 ms slice.

**Observable:** unit test against a nonisolated static seam (`TerminalController.v2AwaitCallbackMainThreadForTesting`, a thin extraction of the branch body so it is reachable without a `TabManager`): a callback fired from a background queue 100 ms in resolves the await with its value in well under the 3 s timeout; a never-fired callback returns nil at ≈ the timeout.

### Step 4 — take `browser.download.wait` off main-queue delivery
**File:** `Sources/SocketHandlers/BrowserQueryHandlers.swift`, `v2BrowserDownloadWait` (774-895)

- File-system source: `queue: .main` → a dedicated serial `DispatchQueue` (its handler only calls `pathIsReady()`, pure `FileManager` I/O, safe off-main).
- Timeout work item: `DispatchQueue.main.asyncAfter` → the same background queue.
- Download-event observer: `queue: .main` → `queue: nil`, i.e. synchronous delivery on the posting thread. The post originates from the WebKit download delegate on main, driven by a **run-loop** source, so it lands inside the pump. The observer body only reads `note.userInfo` and calls `finish` (now lock-guarded by Step 3).

**Observable:** unit test is not practical here (needs a live WKDownload). E2E in phase 4: `c11 browser download wait --timeout-ms 30000` with no download pending returns its timeout error at ≈30 s **while a concurrent `c11 ping` answers promptly** — on `origin/main` the ping stalls for the full 30 s. I will record both timings.

### Step 5 — cap `timeout_ms`
**Files:** `BrowserHandlers.swift:1357`, `BrowserQueryHandlers.swift:776`

Add `nonisolated static func v2ClampBrowserTimeoutMs(_ raw: Int) -> Int` on `TerminalController`, clamping to `1 ... 120_000` (`v2BrowserMaxTimeoutMs`). Apply at both parse sites. 120 s is above the longest timeout observed in the incident fleet (60 s) so it truncates nothing real, and it converts an uncapped multiplier on control-plane downtime into a bounded one. When a request is clamped, echo `requested_timeout_ms` alongside `timeout_ms` in the error payload so a caller passing 600 000 can see why it returned early.

**Observable:** unit tests — `clamp(-5) == 1`, `clamp(0) == 1`, `clamp(5_000) == 5_000`, `clamp(120_000) == 120_000`, `clamp(600_000) == 120_000`.

### Step 6 — correct the false comment
**File:** `Sources/SocketHandlers/BrowserHandlers.swift:321-324`

Replace the claim that the loop "still pumps events (WebKit completion callbacks, rendering, main-queue blocks), so main is not frozen" with what is true and what the harness measured: the pump services **run-loop** sources (which is how WebKit delivers, and why this path works for a live page) but **cannot** drain main-queue blocks, because libdispatch will not re-enter a main-queue drain already on the stack; while it runs, every `v2MainSync` socket command and the UI are blocked; and a non-delivering callback busy-spins the loop at ~500 k slices/second. Name C11-209 and `docs/c11-browser-await-main-wedge.md`.

### Step 7 — land the repro harness and the writeup
**Files (new, currently untracked in the main checkout):** `docs/c11-browser-await-main-wedge.md`, `tools/await-wedge-repro/{run.sh,AwaitDeadlock.swift,WebKitDelivery.swift}`

The ticket, the plan and the corrected source comment all cite these paths, and today they exist in exactly one person's working copy. Commit them so the citation resolves for anyone else. Copy verbatim from `code/c11/`; append a short "Status after C11-209" section to the doc recording which rows the fix addresses and which residual (a legitimate long `browser.wait` still holds main) is left to the off-main follow-up.

### Step 8 — skill guidance
**File:** `skills/c11-browser/SKILL.md`

The skill already warns "if `get url` is empty or `about:blank`, navigate first." Update it to say the enforcement now exists and names itself: a JS command against a never-navigated surface returns `no_document` immediately. Then run `scripts/sync-installed-skills.sh c11-browser` per the hard rule in `CLAUDE.md`.

### Step 9 — tests
New file `c11Tests/BrowserAwaitPolicyTests.swift`, added to the **`c11LogicTests`** target. I will hand-edit `project.pbxproj` (one `PBXFileReference`, one `PBXBuildFile`, one group child, one `Sources` phase entry) rather than use the `xcodeproj` Ruby gem — per `CLAUDE.md`, the gem normalizes the whole file and turns a 4-line change into a multi-thousand-line diff.

Covering, per the test-quality policy (runtime behavior only, no source-text or metadata assertions):
- `v2ClampBrowserTimeoutMs` boundaries (Step 5).
- `CmuxWebView.hasIssuedLoad` transitions through real `load*` calls (Step 1).
- `v2AwaitCallback` main-thread branch: off-main delivery resolves it; never-fired returns nil at the deadline (Step 3).

No meaningful unit test is practical for Steps 2 (needs a `TabManager` + `Workspace`, host-bound), 4 (needs a live `WKDownload`) or 6/7/8. Those are covered by the phase-4 e2e and I will say so explicitly rather than write shape tests to pad the count.

**Local test policy:** I will not run `xcodebuild test` locally in any scheme (memory: `feedback_no_local_xcodebuild_test`). Local loop is `xcodebuild build` via `./scripts/reload.sh --tag c11-209`; CI's `build` job is the logic-test gate.

---

## 4. Phase-4 validation protocol (tagged build, real socket)

Tag `c11-209`; socket `/tmp/c11-debug-c11-209.sock`; launch with `./scripts/launch-tagged-automation.sh c11-209 --qa fresh` so the Agent-Skills and resume dialogs do not block automation.

Measure **before** on `origin/main` (same tag pipeline, stashed to a `c11-209-baseline` tag) and **after** on the branch head:

| # | probe | before (expect) | after (expect) |
|---|---|---|---|
| V1 | `browser new` (no URL), then `browser wait --load-state complete --timeout-ms 120000`; concurrent `time c11 ping` at t+1 s | ping stalls ~121 s | `no_document` < 250 ms; ping < 250 ms |
| V2 | same, `browser eval "1+1"` | `js_error` after ~10 s, ping stalled | `no_document` < 250 ms; ping < 250 ms |
| V3 | happy path: `browser new https://example.com`, wait for load, `browser eval "1+1"` | `2` | `2` (unchanged) |
| V4 | happy path: loaded page, `browser wait --load-state complete --timeout-ms 30000` | ok, fast | ok, fast (no truncation) |
| V5 | `browser wait --text-contains zzz --timeout-ms 30000` on a loaded page | timeout at 30 s | timeout at 30 s (G4: legitimate wait not truncated) |
| V6 | `browser download wait --timeout-ms 30000` with nothing downloading; concurrent `time c11 ping` | ping stalls ~30 s | ping < 250 ms; wait still errors at ≈30 s |
| V7 | `browser wait --timeout-ms 600000` on a never-loaded surface | 600 s | clamped: payload carries `timeout_ms: 120000`, `requested_timeout_ms: 600000` (and here also short-circuits on `no_document`) |
| V8 | concurrent `c11 tree` and a `read-screen` on a terminal surface during V1 | stalled | prompt |

All timings recorded with `time` and attached verbatim via `lattice attach --type note --role validation`. Kill the tagged app afterwards.

---

## 5. Scope, risks, non-goals

**In scope:** `v2AwaitCallback` delivery mechanism, `v2BrowserDownloadWait`'s three awaits, the never-loaded fail-fast guard, the `timeout_ms` cap, the false comment, harness/doc/skill landing, tests.

**Out of scope (deliberate):**
- Moving `browser.*` into `socketWorkerV2Methods`. The real long-term fix; a `@MainActor` audit of the whole browser handler family; explicitly excluded by the brief. → follow-up ticket, recommended in the completion comment.
- `hang.log` rotation/cap (~23 MB/min, 212 MB observed). Explicitly excluded by the brief. → follow-up ticket, noted in the completion comment.
- The repeated-fingerprint precursor signal (seven 2.4–10.7 s episodes never surfaced). Same: note it, do not build it.
- The "still unexplained" 25-minute stall. My changes remove the per-command burn that the backlog hypothesis is built on, but I cannot confirm or refute the hypothesis without the 20–30 min fleet-freeze experiment described in the doc, which needs a 53-agent fleet I do not have. I will say so plainly rather than imply the fix closes it.
- C11-198 and C11-204: the ticket lists both as unmerged; both have since merged (v0.64.0). Verified, not redone.

**Risks:**
1. *False positive on the fail-fast guard* — a surface that has genuinely loaded but whose flag was missed would now get an immediate error instead of working. Mitigated by covering every load entry point **plus** `didStartProvisionalNavigation`, and by the `?? true` conservative cast. V3/V4/V5 are the e2e check.
2. *Off-main callback bodies in Step 4* — the file-source handler and the notification observer now run off main. Both touch only `FileManager` and `note.userInfo`. Nothing MainActor-isolated moves.
3. *`queue: nil` notification delivery* — relies on the download event being posted from a run-loop-driven main-thread context. If it is ever posted from a `DispatchQueue.main.async`, it would not land in the pump. Checked at implementation time; if so, a background `OperationQueue` is used instead.
4. *Sibling collisions* — C11-212 (ghostty pointer) and C11-207 (insecure-HTTP, `BrowserPanel` + open/navigate handlers) are live. C11-207 overlaps `BrowserPanel.swift` and the browser handlers. `git fetch origin && git rebase origin/main` before opening the PR and again before merge.
5. *pbxproj* — hand-edited, small diff by construction; verified with `xcodebuild -list` and a file-membership count rather than by reading the diff.

---

## 6. Phase arc

1. `in_planning` → plan written → headless `lattice plan-review` → resolutions appended → `planned`. ← **here**
2. `in_progress`: rebase, Steps 1–9, commit with trailers, push, verify push landed, `gh pr create --base main` titled `C11-209: …`, `lattice attach` the PR URL.
3. `review`: headless `lattice code-review`, own-reviewer fallback on timeout/vacuous; fix Critical/Major, cap 2 cycles then escalate; confirm a fresh PASS artifact naming branch HEAD.
4. `in_validation`: the V1–V8 matrix above on a tagged build; attach commands + output.
5. `pr_open`: CI green on final head, rebase if `origin/main` moved, `gh pr merge --squash --delete-branch`, verify merged, completion comment, `c11 send DONE` to the Orchestrator. Orchestrator marks done.

---

# Plan-Review Resolutions (authoritative)

Reviewer artifact: `art_01M298ZAKMBH7092Y4RNFDYVXN` (single-mode headless, verdict **FAIL**). I independently re-verified each MAJOR against source before accepting. All eight findings **accepted**; the sections below supersede §2, §3 and §4 where they conflict.

### R1 — [MAJOR] `c11 ping` is a vacuous main-thread probe. ACCEPTED.
**Verified:** `SocketDispatch.swift:129-135` — `socketWorkerImmediateV1Response` matches head `ping` and returns `"PONG"` on the socket worker, before any main hop (`processCommandUsingSocketExecutionPolicy`, line 96-100). `surface.read_text` is in `socketWorkerV2Methods` (`TerminalController.swift:1995`), so `read-screen` is off-main too. My V1/V2/V6/V8 probes would have passed on a broken build.

**Resolution:** the main-thread health probe for every validation row is **`time c11 tree --no-layout`** (a default-policy v2 method, so it hops to main and is blocked by exactly the drain under test). `read-screen` is dropped from V8; `c11 tree --all` replaces it. One `ping` row is **kept deliberately** (V9 below) to document that it stays fast in both columns — a future validator who reaches for it should see, in the evidence, why it proves nothing. This is recorded in the phase-4 note and in the corrected source comment.

### R2 — [MAJOR] G2 and V6 overclaim what Step 4 delivers. ACCEPTED.
**Verified:** after Step 4, `browser.download.wait` still enters via `v2BrowserWithPanel` → `v2MainSync` → main drain, and still pumps until resolution or deadline. Making a callback *deliverable* is not making the command *non-blocking*. G2 as written contradicted my own §2 closing paragraph.

**Resolution — G2 is replaced by:**

> **G2.** `browser.download.wait` resolves **when its event actually arrives** instead of always burning `timeout_ms`. Today its file-system source, timeout work item and download notification are all main-queue-delivered and therefore can never land inside the nested pump, so the command always runs to its full timeout. While waiting it still holds main — bounded by G3 — and only the out-of-scope off-main handler move removes that.

**V6 is replaced by two rows** (V6a positive, V6b deadline), see the revised matrix in R9.

### R3 — [MAJOR] Step 4's closure state and file descriptor are unsafe once the source moves off main. ACCEPTED — this is a crash path, not a style note.
**Verified:** `BrowserQueryHandlers.swift:807-847`. `finished` / `source` / `timeoutWorkItem` are captured `var`s; the post-`resume()` `if pathIsReady() { finishOnce(true) }` runs on main while the source handler would now run on the new queue — Step 3's lock covers `v2AwaitCallback`'s `resolved`, not this outer `finished`. Separately `defer { close(fd) }` closes the descriptor when the handler returns, but nothing cancels the source when `v2AwaitCallback` unwinds on its own deadline; libdispatch traps on a closed fd still owned by a live source ("BUG IN CLIENT OF LIBDISPATCH: Do not close random Unix descriptors"). Today this is masked only because the source never fires.

**Resolution:** Step 4 is amended to:
1. Perform **all** mutation of `finished` / `source` / `timeoutWorkItem` on the single new serial queue — the initial readiness check is dispatched onto that queue (or run before `resume()`), never concurrently with the handler.
2. Own the fd's lifetime in the source: `close(fd)` moves into the source's **cancel handler**; the `defer` is removed. Every exit path (resolution, timeout, `v2AwaitCallback` unwinding) cancels the source, and the fd is closed exactly once, after libdispatch has released it. If no source was ever created, `close(fd)` still runs on that path.
3. If any of this cannot be made obviously correct in the time available, Step 4 is **dropped** rather than shipped half-safe: G1/G3 stand on their own, and I will say so in the completion comment. Trading a guaranteed timeout burn for an intermittent crash is a bad trade.

**New Step 4 observables:** a `browser.download.wait` that is satisfied by a file arriving mid-wait returns at the arrival time; one that is not returns at its deadline; neither logs a libdispatch fd trap. Risk 2 in §5 is widened to cover fd ownership.

### R4 — [MAJOR] The `no_document` message misdirects on the production path. ACCEPTED.
**Verified:** `BrowserPanel.navigate(to:)` (line 3832) returns without loading when `shouldBlockInsecureHTTPNavigation` fires, and `navigateWithoutInsecureHTTPPrompt` (line 3858-3870) returns after setting `shouldRenderWebView = true` and `currentURL` when a remote-workspace proxy endpoint is still pending. In both, the agent *did* pass a URL, `currentURL` is non-nil, and `hasIssuedLoad` is correctly `false`. "navigate first" would be wrong advice, and the fleet drives `http://127.0.0.1` — precisely the insecure-HTTP branch.

**Resolution:** one guard, two messages, chosen on `browserPanel.currentURL`:
- `currentURL == nil` → `"Browser surface has not loaded a document; navigate first (c11 browser goto <url>)."`
- `currentURL != nil` → `"Navigation to <url> was requested but no load has been issued yet — check the insecure-HTTP prompt, a pending remote-workspace proxy, or a hibernated surface."`

Both handler-level pre-checks (`v2BrowserEval`, `v2BrowserWait`) put `current_url` and `lifecycle_state` in the error `data`. The choke-point guard in `v2RunJavaScript` has no panel in scope, so it keeps the single generic message; only the two handlers that own the production stack branch. I will read C11-207's branch before opening the PR and align wording; I will **not** block on that delegator — if the branches disagree, the later merger reconciles.

### R5 — [MINOR] `hasIssuedLoad` test would be the first `c11LogicTests` case to build a `WKWebView`. ACCEPTED.
**Resolution:** keep it in `c11LogicTests`. If CI's logic run trips on WebKit initialisation without a host app, the **test moves to `c11Tests`** — it is not dropped and not weakened into a source-shape assertion. Recorded here so a later reader knows the move was planned, not a retreat.

### R6 — [MINOR] Notification observer leaks on the timeout path. ACCEPTED.
**Verified:** `BrowserQueryHandlers.swift:868-887` removes the observer only inside its own callback, so a timed-out wait leaves it registered for the process lifetime. Pre-existing, but Step 4 rewrites this block. **Resolution:** capture the observer token outside the await and remove it after `v2AwaitCallback` returns, on every outcome.

### R7 — [MINOR] The effective `browser.wait` cap is `timeout_ms + 1000`. ACCEPTED.
**Verified:** `v2WaitForBrowserCondition` passes `timeout + 1.0` to the eval (`BrowserHandlers.swift:437-443`). **Resolution:** G3 is restated as "≤ 121 s of main-thread hold for `browser.wait` (120 s clamp + the 1 s Swift-side grace over the JS-side timer), ≤ 120 s elsewhere", and the corrected comment in Step 6 names the +1 s so the V7 timing is not read as drift.

### R8 — [MINOR] Availability gates, and the web-process-terminate reset is redundant. ACCEPTED.
**Verified:** `BrowserPanel.swift:6150-6155` → `didTerminateWebContentProcess` → `replaceWebViewAfterContentProcessTermination`, which builds a fresh `CmuxWebView` (line 4198-4204) and sets `shouldRenderWebView = false`. The new instance starts with `hasIssuedLoad == false` on its own. **Resolution:** drop the explicit reset hook from Step 1 — do not add a delegate method that buys nothing. `loadFileRequest`, `loadSimulatedRequest` and `restoreInteractionState` overrides get `@available(macOS 12.0, *)`; overrides are written against what the deployment target actually exposes and the build is the check.

### R9 — Revised phase-4 validation matrix (supersedes §4)

Probe for main-thread health is `time c11 tree --no-layout` throughout, issued ~1 s into each long command from a second shell. Before-column measured on `origin/main` built under tag `c11-209-baseline`; after-column on branch head under tag `c11-209`.

| # | probe | before (expect) | after (expect) |
|---|---|---|---|
| V1 | `browser new` (no URL) → `browser wait --load-state complete --timeout-ms 120000`; concurrent `time c11 tree --no-layout` | tree stalls ~121 s | `no_document` < 250 ms; tree normal |
| V2 | same surface, `browser eval "1+1"`; concurrent `time c11 tree --no-layout` | `js_error` after ~10 s, tree stalled ~10 s | `no_document` < 250 ms; tree normal |
| V3 | `browser new https://example.com`, wait for load, `browser eval "1+1"` | `2` | `2` (unchanged) |
| V4 | loaded page, `browser wait --load-state complete --timeout-ms 30000` | ok, fast | ok, fast (no truncation) |
| V5 | loaded page, `browser wait --text-contains zzz --timeout-ms 30000` | timeout at ~30 s | timeout at ~30 s (G4: legitimate wait not truncated) |
| V6a | `browser download wait --path /tmp/c11-209/out.bin --timeout-ms 30000` while a second shell does `sleep 2; cp <file> /tmp/c11-209/out.bin` | returns at ≈30 s (source never fires in the pump) | returns at ≈2 s |
| V6b | same, nothing ever arrives | ≈30 s | ≈30 s (deadline still honoured, no fd trap in Console) |
| V7 | never-loaded surface, `browser wait --timeout-ms 600000` | 600 s | `no_document` immediately; and on a **loaded** surface with an unmet condition, payload carries `timeout_ms: 120000`, `requested_timeout_ms: 600000`, returns ≈121 s |
| V8 | `c11 tree --all` during V1 | stalled | prompt |
| V9 | `time c11 ping` during V1 | fast (**probe is vacuous** — recorded to document why) | fast |

Timings captured with `time`, attached verbatim via `lattice attach --type note --role validation`. Tagged apps killed afterwards.

### Net effect on the plan
§2 G2/G3, §3 Steps 1/2/4/9, §4 in full, and §5 Risk 2 are amended as above. §0, §1, §3 Steps 3/5/6/7/8 and the rest of §5 stand as written. Proceeding to `planned` → `in_progress`.
