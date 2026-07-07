# C11-165 — P0 Correctness Plan (COR-1..COR-4)

**Ticket:** C11-165 · Wave 2 · Truth & Stability · stops at `pr_open` (operator merges).
**Delegator:** `agent:ts-cor-delegator` (Opus). Reports to `ts-orchestrator`.
**Contract:** `docs/cycles/2026-07-truth-and-stability/{SPEC,EVALUATION,BUILDPLAN}.md`.
**Design input:** `notes/c11-audit-merged-2026-06-09.md` §P0.2, §P0.4.
**Layout basis:** POST-extraction (C11-159), dispatch now under `Sources/SocketHandlers/`. All line numbers below are from branch `ts/dx-dispatcher-extraction` as read during planning; re-anchor against merged `origin/main` at RESUME (plan-revalidation step).

> **Phase note:** written during PLANNING-ONLY (wave barrier holds; C11-159 not yet merged). No branch/worktree/build/source edits made. This plan reads the other delegator's worktree read-only.

---

## 0. Problem shape (what the audit found, verified in the extracted tree)

**COR-1 — empty/absent surface refs misroute writes to the *focused* surface.**
Root cause: the v2 parse helper `v2String` (TerminalController.swift:2434) trims then returns `nil` for empty/whitespace — it *collapses "absent" and "explicitly-empty" into the same `nil`*. Every write handler then does `v2UUID(params,"surface_id") ?? <focused>`, so `--surface ""` (or an exported-but-empty `CMUX_SURFACE_ID`) silently lands on whatever surface the operator is focused on — a peer agent's tab — returning an identical-looking `OK`. Confirmed live at 13 `?? …focusedPanelId` fallback sites; the write-family subset is the 10 commands below.

**COR-3 — three socket paths run their blocking wait on the main thread.**
The v2 execution policy (`TerminalController.swift:1947 executionPolicy(forV2Method:)`) routes only 4 methods (`surface.send_text/send_key/read_text/clear_history`, set at :1901 `socketWorkerV2Methods`) to the off-main socket worker. **Everything else falls through `processCommandUsingSocketExecutionPolicy` (SocketDispatch.swift:82) into `DispatchQueue.main.sync { processV2Command }`, i.e. runs on main.** Three handlers are written *off-main-safe* (they block a semaphore / spin a nested run loop) but are dispatched *on main*, so they deadlock or beachball:
- `pane.confirm` → `v2PaneConfirm` (PaneHandlers.swift:884) `assert(!Thread.isMainThread)` + `semaphore.wait(300s)` → on main this asserts in Debug / beachballs ≤300s in Release.
- `feedback.submit` → `v2FeedbackSubmit` (MarkdownFeedbackHandlers.swift:56): `Task { … }` inherits `@MainActor`, then `semaphore.wait(35s)` on main → the Task can never start → always times out ~35s.
- browser blocking commands → `v2AwaitCallback` (BrowserHandlers.swift:310): the **main-thread branch** spins `CFRunLoopRun()` (:337). Reached on main under the outer `main.sync`, nested run loops can only be stopped innermost-first → wedge. Callers: `browser.eval` (:286,292), download/wait/condition (BrowserQueryHandlers.swift:808,869,918-934), snapshot (BrowserHandlers.swift:1764).

The **unifying fix for all three** is the execution-policy seam: move these methods onto the socket-worker policy so their *already-present* off-main branch is the one that runs. The nested-`CFRunLoopRun` branch and the `main.sync` fallback then become unreachable for them.

---

## 1. COR-1 — reject empty/absent surface refs on all 10 write commands

### 1.1 The 10 commands and their real transport (verified)

| CLI command | Transport | Server resolver chokepoint (post-extraction) |
|---|---|---|
| `set-metadata` | v2 `surface.set_metadata` / `pane.set_metadata` | `v2ResolveSurfaceForMetadata` SurfaceHandlers.swift:1306 · `v2ResolvePaneForMetadata` TerminalController.swift:3351 |
| `set-agent` | v2 `surface.set_metadata` (agent.* keys) | `v2ResolveSurfaceForMetadata` |
| `set-title` | v2 `surface.set_metadata` (title key) | `v2ResolveSurfaceForMetadata` |
| `set-description` | v2 `surface.set_metadata` (description key) | `v2ResolveSurfaceForMetadata` |
| `clear-metadata` | v2 `surface.clear_metadata` / `pane.clear_metadata` | `v2ResolveSurfaceForMetadata` / `v2ResolvePaneForMetadata` |
| `trigger-flash` | v2 `surface.trigger_flash` | `v2ResolveTargetSurface` (via `v2SurfaceTriggerFlash` SurfaceHandlers.swift:1230; also `cancel_flash` :1279) |
| `rename-tab` | v2 `surface.action` (`--action rename`) | `v2TabAction` MiscHandlers.swift:57 (`… ?? workspace.focusedPanelId`) |
| `set-status` | **v1** `set_status` | `upsertSidebarMetadata` → shared mutation closure TerminalController.swift:~7166-7192 (`surfaceIdFromOptions ?? tab.focusedPanelId`) + `explicitSocketScope` :627 |
| `set-progress` | **v1** `set_progress` | `setProgress` :7589 → same shared resolver |
| `log` | **v1** `log` | `appendLog` :7509 → same shared resolver |

Coverage crosses **three layers**: v2 surface/pane metadata resolvers, the v2 tab-action resolver, and the v1 sidebar-metadata resolver. A single validator is reused by all three so the contract is defined once.

### 1.2 Approach — one pure validator + strict resolver seams

**(a) New pure type `Sources/Metadata/SocketSurfaceRefValidator.swift`** — mirrors the C11-106 precedent `SocketMetadataSourceValidator` (same directory, same shape), so the rejection contract is unit-testable in the logic suite *without* a socket loop.

```
enum SocketSurfaceRefValidator {
  struct Rejection { let code: String; let message: String }
  // Keys that name a surface/pane/tab/workspace target, in the caller's raw form.
  // Rejects (1) any listed key PRESENT-but-empty/whitespace  -> code "empty_ref"
  //         (2) NONE of `requiredAnyOf` present & non-empty   -> code "missing_ref"
  static func rejection(rawValues: [String: Any?],
                        targetKeys: [String],
                        requiredAnyOf: [String]) -> Rejection?
}
```

Operates on raw param values (presence + emptiness), so it distinguishes absent from empty — the exact gap `v2String` erases. Pure, `nonisolated`, no app state → lands in a target the logic suite links (see §4.1).

**(b) v2 write handlers** call the validator at entry, before resolution:
- `v2SurfaceSetMetadata` (1330), `v2SurfaceClearMetadata` (1435): `targetKeys/requiredAnyOf = ["surface_id","pane_id","tab_id","workspace_id"]` (require an explicit target; no focused fallback). Then call resolution.
- `v2SurfaceTriggerFlash` (1230) / `v2SurfaceCancelFlash` (1279): same, keys `["surface_id","pane_id","workspace_id"]`.
- `v2PaneSetMetadata`/`v2PaneClearMetadata` (PaneHandlers.swift:706,808): keys include `pane_id`.
- `v2TabAction` rename branch (MiscHandlers.swift): keys `["surface_id","tab_id","workspace_id"]`.
- Replace the trailing `?? <focused>` in the write-family resolvers (`v2ResolveSurfaceForMetadata` fallback at 1319-1326; `v2ResolvePaneForMetadata` focused fallback at 3367-3370; `v2ResolveWorkspace` selected-tab fallback at 2750-2751 **only on the write path** — gate via a `strict:` parameter so query/focus/split callers keep their fallback).

**(c) v1 sidebar-metadata path** (`set_status`/`set_progress`/`log`): the shared mutation closure (TerminalController.swift:~7166-7192) currently: tries `explicitSocketScope` (needs `--tab`+`--panel`), else falls to `surfaceIdFromOptions ?? tab.focusedPanelId`. Fix: parse the raw `--surface`/`--panel`/`--tab` option strings, run the same validator (present-but-empty → error; none present → error), and **remove the `?? tab.focusedPanelId` fallback for these three commands**. Return the rejection as the v1 `ERROR: …` string (v1 wire convention). Keep non-write v1 commands (`report_pwd`, etc.) untouched — they legitimately track the focused/active surface.

**(d) CLI defense-in-depth (`CLI/c11.swift`)** — authoritative fix is server-side (covers direct socket clients), but the CLI should not manufacture the ambiguity:
- Reject an **explicitly-passed empty** `--surface`/`--tab`/`--panel ""` at parse time with a clear CLI error (before send).
- When `CMUX_SURFACE_ID`/`C11_SURFACE_ID` is exported-but-empty, **do not inject it** (treat as absent) rather than sending `surface_id:""` — the server then returns the clear `missing_ref` error instead of a confusing `empty_ref`. Touch the env-injection sites (e.g. :1786, :2051, and the write-subcommand param builders) + `normalizeSurfaceHandle`.

### 1.3 Error contract (machine-facing; matches existing socket convention)
v2: `.err(code:"empty_ref", message:"surface ref was provided but empty — pass a concrete surface/pane/tab id")` and `.err(code:"missing_ref", message:"no surface target — pass --surface (no focused-surface fallback for writes)")`. v1: `ERROR: empty_ref …` / `ERROR: missing_ref …`. **Not** `String(localized:)` — these are agent-parsed protocol strings, consistent with every existing `v2Error`/`ERROR:` site (see §6 localization).

---

## 2. COR-2 — update the c11 skill footgun + sync

**File:** `skills/c11/SKILL.md:36` (the footgun blockquote). Current text says the CLI "defaults a missing `--surface` to whatever surface the operator is currently focused on … silently writes to the wrong surface." Rewrite to the new contract: **a missing or empty ref now errors loudly (`missing_ref`/`empty_ref`); silent misrouting is no longer possible.** Keep "pass `--surface "$C11_SURFACE_ID"` explicitly" as the recommended habit (it avoids the error), list the same command set, and drop the "writes to the wrong surface" claim.
- Also scan `skills/c11/` refs (`references/*.md`) for the same stale claim; update in the same PR.
- **HARD RULE:** after editing, run `scripts/sync-installed-skills.sh c11` and verify the installed copy (`~/.claude/skills/c11/SKILL.md`) reflects the change. A skill edit without the sync ships a fix that isn't live.

---

## 3. COR-3 — eliminate main-thread-reachable socket paths

### 3.1 Approach — move the blocking methods onto the socket-worker policy

**Core change (`Sources/TerminalController.swift`):** add to `socketWorkerV2Methods` (:1901): `pane.confirm`, `feedback.submit`, and the blocking browser methods (`browser.eval`, `browser.state.save`, `browser.state.load`, `browser.download.wait`, `browser.wait*`, `browser.snapshot` — the exact set = every method whose handler reaches `v2AwaitCallback`/`v2WaitForBrowserCondition`; enumerate from the fresh sweep, don't guess).

**Wire the worker path (`Sources/SocketHandlers/SocketDispatch.swift`):** `socketWorkerV2Response` (:45) currently switches only the 4 send/read methods. Extend it to route the newly-added methods to their handlers. To avoid a second dispatch table, prefer routing the worker path through the existing `v2DispatchExtracted` seam for these prefixes — but that seam and the domain dispatchers are `@MainActor func`; calling them from the `nonisolated` worker requires the handler chain be `nonisolated`. So:

**Make the handler chains `nonisolated`:**
- `v2PaneConfirm` (PaneHandlers.swift:884) — body is already off-main-safe (`v2MainSync` for the present hop, blocks off-main). Mark `nonisolated`; its `assert(!Thread.isMainThread)` becomes true and load-bearing.
- `v2FeedbackSubmit` (MarkdownFeedbackHandlers.swift:56) — mark `nonisolated`; change `Task {` → `Task.detached {` (mirror `conversationStoreSync` at TerminalController.swift:3468) so the async body no longer inherits `@MainActor` and runs while the worker blocks. FeedbackComposerBridge main-actor work then proceeds on the free main thread.
- Browser blocking handlers + `v2AwaitCallback`/`v2WaitForBrowserCondition` (BrowserHandlers.swift:310,358) — `v2AwaitCallback`'s off-main branch (:341 semaphore) is already correct; ensure the callers are `nonisolated` and dispatched off-main so the main-thread `CFRunLoopRun` branch (:314-338) is **unreachable from the socket**. Given the breadth of `@MainActor` WebKit calls in browser handlers, wrap each main-touching slice in `v2MainSync` (bounded hop) rather than making the entire file nonisolated. **This is the largest/riskiest slice — see §5.**

**Guard against regression:** the `invalid_dispatch` guard already exists in `processV2Command` (SocketDispatch.swift:830) for worker-policy methods that wrongly reach the main path. It will now protect the three genres too. Optionally tighten `v2AwaitCallback` so the main-thread branch `assert`s/`preconditionFailure`s in DEBUG ("browser await reached on main — must be socket-worker policy"), converting a silent future regression into a loud one.

### 3.2 Fresh sweep (deliverable artifact)
Produce `notes/c11-165-mainthread-sweep.md`: grep the *merged* dispatch layer for `CFRunLoopRun`, `DispatchSemaphore`/`.wait(`, `DispatchQueue.main.sync`, `semaphore.wait` reachable from a `.mainActor`-policy v2 method or a v1 main handler; map each to fix-commit or "benign (already off-main / bounded async)". This is the COR-3 audit evidence (EVALUATION COR-3 row).

---

## 4. COR-4 — regression tests (two genres)

### 4.1 Empty-ref rejection — **logic suite** (`c11LogicTests`)
New `c11LogicTests/SocketSurfaceRefValidatorTests.swift` exercising `SocketSurfaceRefValidator.rejection(...)` directly (the seam), matrix:
- present-but-empty `surface_id`/`pane_id`/`tab_id`/`workspace_id` (incl. whitespace `" "`) → `empty_ref`.
- all target keys absent → `missing_ref`.
- a valid concrete ref present → `nil` (accept).
- mixed (one valid + one empty) → still `empty_ref` (empty is never ignored).
**Target membership (must confirm):** `SocketMetadataSourceValidator` compiles into the main `c11` target (pbxproj build phase at line ~1656) which `c11-logic` depends on — place `SocketSurfaceRefValidator.swift` in the **same target** so the logic suite links it. Verify with `xcodebuild -scheme c11-logic … test -only-testing:c11LogicTests/SocketSurfaceRefValidatorTests` (no host, ~30s). This honors the test-quality policy (behavioral test of a runtime seam, not a source-grep).

*(Optional companion in `c11Tests`, mirroring `SocketDerivedSourceRejectionTests`, that drives one real handler to prove the validator is wired — only if it stays host-light.)*

### 4.2 Socket-flood — **fails on reintroduced main-thread sync work** (`tests_v2`)
New `tests_v2/test_socket_flood_mainthread.py` against a **tagged build socket** (`C11_SOCKET=/tmp/c11-debug-<tag>.sock`), C11-156 reproduction shape:
- Concurrent flood: N threads spamming hook/telemetry (`set_status`, `report_shell_state`) + fire a `pane.confirm` and a `browser.eval`-shaped blocking call.
- **Liveness oracle:** a separate thread issues a cheap probe (e.g. `surface.list` / a ping-class method) on a strict deadline; the test FAILS if the probe latency exceeds a bound (main was monopolized) or if `pane.confirm`/`feedback.submit` beachball. Cross-check `MainThreadHangMonitor` output (`~/Library/Logs/c11/hang.log`) stays clean for the run window.
- **Flake mitigation:** generous but bounded deadline; assert *relative* degradation (probe latency under flood vs. baseline), retry the baseline, not the assertion. Document that this is a socket/host test (not the fast logic loop) → runs in CI's socket lane, not the inner loop.

Regression semantics: if a future change puts `pane.confirm`/`feedback.submit`/browser-await back on the `.mainActor` policy, the blocking wait re-lands on main → probe deadline blown → red.

---

## 5. Test plan per EVALUATION row

| Row | Tag | How this plan proves it |
|---|---|---|
| **COR-1** | autonomous | `tests_v2` matrix: each of the 10 commands with empty ref → error, **no write lands** (follow with a `get-metadata`/`get-titlebar-state` read showing the focused surface unchanged); with absent ref → error. Plus §4.1 logic test on the validator. |
| **COR-2** | autonomous | Skill diff in the same PR; `sync-installed-skills.sh c11` run and installed copy verified. |
| **COR-3** | autonomous | Sweep artifact `notes/c11-165-mainthread-sweep.md` (audit list → fix-commit map); `hang.log` clean during the §4.2 flood on the tagged build. |
| **COR-4** | autonomous + external-oracle | Both tests present & green: logic empty-ref test (fast suite / CI), socket-flood test (CI socket lane). |

**Validation bar (operator 2026-07-06):** tagged build + recorded scenario proof, CI green necessary-not-sufficient. At RESUME: `./scripts/reload.sh --tag cor-post`, drive the empty-ref rejection live (screenshot: peer surface untouched after `set-status --surface ""`), record the flood-liveness run; attach ALL evidence `--role validation`.

---

## 6. Risks / seams / localization

**Risks & seams:**
1. **Behavior change (intended):** the 10 write commands no longer honor the focused-surface default. In-pane callers are unaffected (the CLI injects `$C11_SURFACE_ID`); only truly ref-less callers (cron/launchd/fresh shell, or exported-empty env) now get an error instead of a silent write. COR-2 documents this; call it out in the PR + a ticket comment (deviate-with-flag). Confirm no internal caller (skills/hooks/`Resources/bin/`) relies on the implicit default — grep the repo for ref-less `set-status`/`set-title` invocations.
2. **Shared resolvers:** `v2ResolveWorkspace` (2743) and `v2ResolveSurfaceForMetadata` (1306) are used by both write and non-write (query/focus/split) callers. **Gate strictness by a `strict:` parameter — do not remove the focused fallback globally** or you break `surface.split`/`surface.focus`/`surface.list`. This is the single most error-prone edit; enumerate every caller before changing signatures.
3. **COR-3 browser slice is the biggest blast radius.** Making browser blocking handlers `nonisolated` touches many `@MainActor` WebKit calls; each needs a bounded `v2MainSync` hop. If the full move proves too invasive for a P0 ticket, fall back to the **minimal safe variant**: move only `pane.confirm` + `feedback.submit` to the worker policy now (contained, high-value), and for the browser genre harden `v2AwaitCallback` so it *cannot* run its nested-`CFRunLoopRun` branch on a `main.sync`-held thread (DEBUG precondition + route the specific blocking browser methods off-main). Decide at implementation; log the call in the decision trail. **Flag for plan-review.**
4. **`@MainActor` isolation correctness:** the 4 existing worker methods are the reference for the `nonisolated` + `v2MainSync` pattern. `feedback.submit`'s `Task` → `Task.detached` change must not lose `@MainActor` where the bridge genuinely needs it — verify FeedbackComposerBridge's own isolation.
5. **CLAUDE.md hot paths untouched:** none of these edits touch `hitTest`/`TabItemView`/`forceRefresh`. `dlog` additions (sweep diagnostics) must be `#if DEBUG`-gated. Socket-threading policy is *advanced* by this work, not violated.
6. **Line-number drift:** all anchors are pre-merge (worktree). First RESUME step = re-anchor against merged `origin/main`; if C11-159 shifted a resolver, update the change map (amendment block) before editing.

**Localization:** effectively none. New rejection strings are agent-facing protocol errors (`code`+`message`), matching every existing `v2Error`/`ERROR:` site — not `String(localized:)`. `pane.confirm`'s user-visible OK/Cancel labels are already localized (PaneHandlers.swift:914-917) and unchanged. No new SwiftUI/alert strings → no six-locale translation pass required. (If review insists rejection messages are user-visible via a surfaced CLI error, they're still CLI protocol text, consistent with the rest of `CLI/c11.swift`.)

---

## 7. Validation-artifact plan (what gets attached to C11-165)

- `notes/c11-165-mainthread-sweep.md` — COR-3 fresh sweep (audit list → fix map). `--role validation`.
- Empty-ref rejection matrix output (tests_v2 log) + before/after `get-metadata` reads showing the peer surface untouched. Screenshot of a live `set-status --surface ""` erroring on the tagged build.
- Flood-liveness run recording + `hang.log` excerpt (clean) for the run window.
- CI green (logic + socket lanes) — necessary, not sufficient.
- Skill diff + `sync-installed-skills.sh` confirmation.
- Tagged build: `./scripts/reload.sh --tag cor-post`; build lock acquired via `lattice resource acquire xcodebuild` per boot §3.

---

## 8. Plan-Review Cycle 1 Resolutions (AUTHORITATIVE — overrides earlier text on conflict)

The board's auto triple/trident plan-review could not spawn (interactive c11-pane spawn failed: `pane_too_small` in the review workspace, and an earlier socket-write error). Re-triggered inline → self-review; supplemented with **three independent read-only review agents** (correctness, threading, test/scope lenses) against the extracted tree. Their load-bearing findings and the resulting authoritative changes:

### 8.1 COR-1 — v1 mapping was wrong (CRITICAL). Retarget the fix.
`set-status`/`set-progress`/`log` do **not** flow through the `?? focusedPanelId` closure named in §1.1/§1.2(c). Real path (extracted tree): `upsertSidebarMetadata` (TerminalController.swift:7194) / `setProgress` (7589) / `appendLog` (7509) → `resolveTabForReport` → **`?? tabManager.selectedTabId` (7091-7092)** via `resolveTabIdForSidebarMutation` (7095). These entries are **tab(workspace)-scoped** (`tab.statusEntries[key]`), not surface-scoped. The closure at ~7139-7192 (`schedulePanelMetadataMutation`) is used only by `report_pr`/`clear_pr` — **not** in the 10.
**Authoritative fix:** for the v1 trio, reject in `resolveTabForReport:7091-7092` / `resolveTabIdForSidebarMutation:7095` when no `--tab`/`--workspace` is resolvable, instead of defaulting to `selectedTabId`. The pinned ref for these three is `--tab`/`--workspace` (not `--surface`). In-pane callers stay safe (the CLI injects `--tab` from `CMUX_WORKSPACE_ID` via `forwardSidebarMetadataCommand`/`workspaceFromArgsOrEnv`); the residual bug is the **absent-env** (cron/launchd) case, fixable only server-side. §1.1's "all 10 within the 13 `?? focusedPanelId` sites" claim is retracted for these three.

### 8.2 COR-1 — `requiredAnyOf` must pin the resolved granularity (HIGH). Narrow it.
As written (`["surface_id","pane_id","tab_id","workspace_id"]`), a coarser ref passes the validator yet the resolver still falls to focused: `v2ResolveSurfaceForMetadata` (SurfaceHandlers.swift:1319-1326) → `v2ResolveWorkspace(workspace_id)` → `workspace.focusedPanelId`; `v2ResolvePaneForMetadata` (3361-3371) → `focusedPaneId`; `v2ResolveTargetSurface` (1207-1218) reads only `surface_id`. So `set-title --workspace X` / `trigger-flash --workspace X` still misroute.
**Authoritative fix — `requiredAnyOf` = the key that pins granularity, nothing coarser:**
- surface metadata (`set_metadata`/`clear_metadata`/`set-title`/`set-description`/`set-agent`): `["surface_id"]`
- pane metadata (`pane.set_metadata`/`pane.clear_metadata`): `["pane_id"]`
- flash (`trigger_flash`/`cancel_flash`): `["surface_id"]` (resolver ignores `pane_id` — do **not** list it)
- rename (`surface.action`/`tab.action` rename, MiscHandlers.swift:57): `["surface_id","tab_id"]` (here `tab_id` IS a surface id)
`empty_ref` still applies to **any** target key present-but-empty (whether or not it's in `requiredAnyOf`).

### 8.3 COR-1 — drop the `strict:` resolver parameter (MEDIUM). Validator-at-entry suffices.
`v2ResolveWorkspace` has ~45 callers across 11 files; threading a `strict:` flag is the highest-risk edit and is **unnecessary**: rejecting at each write-handler entry makes the resolver's focused-fallback dead for writes without any signature change, and read handlers (`get_metadata` at SurfaceHandlers.swift:1402, PaneHandlers.swift:744) stay lenient for free because reads never call the validator. **Remove §6 risk-2's `strict:` plan; keep validator-at-entry only.** Shared write+read resolvers to guard by "validator only on the write entry": `v2ResolveSurfaceForMetadata` (set 1358 / get 1402 / clear 1463), `v2ResolvePaneForMetadata` (706 / 744 / 808).

### 8.4 COR-1 — validator classifies three raw states (LOW). 
`SocketSurfaceRefValidator` must treat: **missing key → absent**; **`NSNull` → absent** (→ `missing_ref`); **`""`/whitespace (trim first) → empty** (→ `empty_ref`); valid string → accept. This is the whole point of reading raw params instead of `v2String` (which trims-then-nils, collapsing all three).

### 8.5 COR-1 — CLI hardening is mostly pre-existing (LOW-MED). Reduce §1.2(d) scope.
The CLI already rejects explicit-empty refs: `resolveSurfaceId` throws on empty `--surface` (CLI/c11.swift:7727), `resolveWorkspaceId` on empty `--workspace` (7688), and `resolveMetadataTarget` (11018) only reads `CMUX_SURFACE_ID` absent a flag — so exported-empty env still hits the 7727 throw. **Net-new CLI work is minimal;** the genuine residual vector is **absent** ref/env reaching a direct socket client or the v1 path, which is the server-side reject (§8.1, §1.2). Mark the empty-ref CLI guards pre-existing; don't re-implement them.

### 8.6 COR-1 — out-of-scope same-genre note (LOW). 
`surface.close` (SurfaceHandlers.swift:465) and the other `surface.action` verbs (close_left/right/others, duplicate, pin) share the identical `?? focusedPanelId` footgun but are **not** in the SPEC's enumerated 10 — correctly out of scope. Add a one-line ticket note flagging `surface.close` as same-severity for a follow-on (it silently closes the operator's focused surface on a ref-less call).

### 8.7 COR-3 — the `nonisolated + v2MainSync` pattern does NOT compile (CRITICAL). Rewrite to `Task{@MainActor}+semaphore`.
`v2MainSync` (TerminalController.swift:2216) is `@MainActor`-isolated (class is `@MainActor`, :120); a `nonisolated` function cannot call it synchronously (actor-isolation error, enforced even at `SWIFT_VERSION=5.0`). The **real** off-main pattern — used by the existing workers `v2SurfaceSendText`/`SendKey`/`ReadText`/`ClearHistory` (SurfaceHandlers.swift:825+) — is `Task { @MainActor in … }` + `DispatchSemaphore` + `nonisolated(unsafe) var` for the result. **Authoritative fix:** every handler moved to the worker policy is a **rewrite** to that pattern, not a `nonisolated` annotation over a `v2MainSync` body. §3.1 and §6 risk-3's "annotation + bounded hop / minimal" scope estimate is retracted — this is real work per handler.
- **`feedback.submit`** is the one clean conversion: `FeedbackComposerBridge.submit` is `static async throws`, **not `@MainActor`** (ContentView.swift:10271), and `v2FeedbackSubmit` has no un-hopped main-actor calls. The fix is **moving it to the worker policy** (so `semaphore.wait(35s)` no longer blocks main) — *not* the `Task→Task.detached` change in §3.1 (that rationale was wrong; retract it).
- **`pane.confirm`** is **not** a one-liner: `v2PaneConfirm` calls `v2ResolveTabManager` (@MainActor, :2646) and `v2UUID` (@MainActor, :2485) at PaneHandlers.swift:892/895 **outside** its `v2MainSync` block. These must move inside a `Task{@MainActor}+semaphore` hop before it can be `nonisolated`.

### 8.8 COR-3 — moving browser handlers off-main risks a CRASH worse than the hang (CRITICAL). Scope decision required.
`v2AwaitCallback`'s off-main branch (BrowserHandlers.swift:341-355) runs its `start` closure **synchronously on the worker thread**. Several browser `start` closures call main-thread-only WebKit APIs directly — `browser.snapshot` → `browserPanel.takeSnapshot` (1764), `browser.state.save/load` → `WKHTTPCookieStore.getAllCookies/setCookie/delete` (BrowserQueryHandlers.swift:918/926/934). Today they're safe because the command runs on main; **moving them to the worker policy calls WKWebView/WKHTTPCookieStore off-main → thread-affinity violation → crash/UB.** Additionally, the blocking browser handlers read/write per-surface dicts (`v2BrowserElementRefs`, dialog/download/frame maps) that audit P1.4 already flags as raced (written on main, read from socket threads) — the move activates that race.
**Authoritative resolution (recommended, flag to orchestrator):** the correct P0 fix for the nested-`CFRunLoopRun` genre is to (a) move the browser blocking commands to the worker policy, (b) marshal **every** WebKit-touching `start` closure to main via `DispatchQueue.main.async` (the pattern `v2RunJavaScript`:293 already uses correctly), and (c) serialize/hop the per-surface dicts. This keeps the CFRunLoopRun genre eliminated per SPEC. **If during implementation the browser slice exceeds the two-fix-cycle budget, escalate-with-flag** to the orchestrator to split browser into a follow-on ticket, landing pane.confirm + feedback.submit now and adding a hardening guard on `v2AwaitCallback` (below) so the deadlock cannot ship in the interim. This is a scope fork for the Fully-Autonomous orchestrator to ratify; do **not** silently ship a partial browser move.

### 8.9 COR-3 — worker routing must be explicit per-method cases (HIGH).
`socketWorkerV2Response` (SocketDispatch.swift:45) is `nonisolated` and cannot call the `@MainActor` `v2DispatchExtracted` (867) / domain dispatchers. §3.1's "reuse the `v2DispatchExtracted` seam from the worker" is infeasible. **Authoritative fix:** add explicit `case "pane.confirm":`/`case "feedback.submit":`/`case "browser.*":` entries to `socketWorkerV2Response`'s switch (like the existing 4). **Failure mode to avoid:** adding a method to `socketWorkerV2Methods` (:1901) without a matching worker-switch case silently returns `method_not_found` (default at :61) — the `invalid_dispatch` guard (:830) never fires because the worker path already handled it. A test must assert each moved method actually executes off-main (not just that it's in the set).

### 8.10 COR-3 — the §3.2 sweep is too narrow (MEDIUM).
Grepping only `CFRunLoopRun`/`DispatchSemaphore.wait`/`main.sync` catches blocking primitives but **not** the off-main WebKit crash of §8.8. **Add to the sweep's targets:** WKWebView / WKHTTPCookieStore / BrowserPanel touches reachable off-main from any worker-policy handler's `start` closure. (Sweep confirmed the only socket-dispatch-reachable blocking primitives are PaneHandlers.swift:969, MarkdownFeedbackHandlers.swift:97, BrowserHandlers.swift:337/350; the `SurfaceHandlers` waits are the already-off-main workers; the audit's git-probe pipe deadlock is not socket-dispatch-reachable → correctly out of scope.)

### 8.11 COR-3 — Release-safe regression signal (LOW).
`assert(!Thread.isMainThread)` (PaneHandlers.swift:890) and any new browser guard are compiled out in Release. Pair the DEBUG `assertionFailure` with a Release-safe telemetry log (or a bounded-timeout that returns an error) so a future routing regression is observable in Release, not a silent hang.

### 8.12 COR-4 — the tests must be CI-real, not vacuously green (SEVERE, retargets §4/§5).
- **`tests_v2` is not in GitHub CI.** `scripts/run-tests-v2.sh` is guarded to the c11-vm; `ci.yml` runs only the Go daemon, workflow-guards, and the `c11-logic`/`c11-unit` xcode schemes. **Retract the "CI socket lane" claim (§4.2, §5 COR-4 row).** The socket-flood test's home is the **c11-vm run + the recorded tagged-build validation artifact**, which the §5 validation bar already requires. Precedent flood tests `return 0` (green) on SKIP when `C11_SOCKET` is unset — **make the new test FAIL, not skip, when it cannot reach its intended socket.**
- **The logic validator test proves the seam, not the wiring.** A CI-green `SocketSurfaceRefValidatorTests` can coexist with a handler that forgot to call the validator. **Make a handler-driving rejection test mandatory** (not "optional") and place it in **`c11Tests`** (the `c11-unit` scheme runs in CI, advisory) so ≥1 real reject path is CI-gated. **Footgun (CLAUDE.md:131 / C11-105):** a handler-driving test that touches `TerminalController.shared` from a `c11LogicTests`-member file unlinks the prod socket — so the pure-seam test stays in `c11LogicTests` (touching only the plain `SurfaceMetadataStore`/validator singletons is safe), and the handler-driving test goes in **hosted `c11Tests`**.
- **pbxproj membership (CRUX — confirmed achievable):** `c11LogicTests` link-loads the app dylib (`BUNDLE_LOADER=…/c11.debug.dylib`, `TEST_HOST=""`) and the precedent `SocketDerivedSourceRejectionTests` is a `c11LogicTests` member doing `@testable import c11` against `SocketMetadataSourceValidator` (a `c11`-target file). Place `SocketSurfaceRefValidator.swift` in the `c11` target, its pure test in `c11LogicTests`. **After adding, assert the new test appears in the run's named test count** — a `.swift` file on disk but absent from the Sources phase compiles into nothing and the suite passes without running it.
- **Deterministic flood oracle:** prefer the in-repo precedent's **absolute wall-clock probe deadline** (a concurrent cheap probe — `surface.list`/`system.tree` — must return under a fixed bound while the flood + a blocking command run) over the relative-degradation oracle in §4.2 (two noisy measurements). Use `hang.log` only as a hard-hang cross-check, and only with a **positive control** (a deliberate main-stall must appear) so "clean" isn't vacuous.
- **Blocking commands need an answerer:** `pane.confirm` (300s) and `feedback.submit` (35s) block on human UI input. The recorded validation must launch under `C11_QA_LAUNCH=fresh` + a `UI_TEST_MODE`/socket auto-answer (or a socket answer-method); a bare `reload.sh --tag cor-post` build shows a real modal with no clicker → 300s strand. State the exact launch path in the validation-artifact plan.
- **Read-back per command:** §5 COR-1 "no write lands" read-back via `get-metadata`/`get-titlebar-state` covers `set-metadata`/`set-title`/`set-status`; for `log` (`appendLog`) and `set-progress` name the concrete read-back (log-tail / progress read on the peer surface) or rest those two on the error-return alone.

### 8.13 Anchoring
All line numbers here and in §1-§7 are from the extraction branch (or `main` for pbxproj/CI, which are branch-stable). **First RESUME step: re-anchor every handler/resolver line against merged `origin/main`** (the extraction may shift them) before editing; the pbxproj precedent line drifted ~54 lines between branches, so anchor by symbol, not number.

**Net scope after Cycle 1:** COR-1 architecture holds (one validator, reject-at-entry) with corrected targets (v1 → `resolveTabForReport`; `requiredAnyOf` narrowed; no `strict:` param). COR-3 is larger than first scoped: `feedback.submit` clean, `pane.confirm` a real rewrite, **browser off-main is a flagged scope fork** (correct-but-heavy fix vs. split-to-follow-on with a hardening guard — orchestrator ratifies). COR-4 tests retargeted to where CI/VM actually run them, made fail-not-skip, with a mandatory CI-gated wiring test.
