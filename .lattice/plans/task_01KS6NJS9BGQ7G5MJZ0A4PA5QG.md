# C11-114: Port upstream PR #4233 — fix offscreen terminal PTY wedge

## Problem

Offscreen surfaces created via `c11 new-surface --no-focus` never call `ghostty_surface_new` because SwiftUI never mounts the unselected tab. `c11 send` then silently drops bytes (returns OK, queues into `pendingTextQueue`, never flushes). Breaks the lattice-orchestrator pattern.

## Root cause (verified by research at /tmp/c11-pty-wedge-research.md)

`surface.create` is not in `focusIntentV2Methods` → `v2FocusAllowed` clamps focus to false → tab is added without selection → view never enters a window → `attachToView`'s `view.window != nil` guard keeps `ghostty_surface_t` nil indefinitely.

c11's recovery hook (`waitForTerminalSurfaceOffMain` → `requestBackgroundSurfaceStartIfNeeded` → `createSurface(for: view)` on an off-window view) is the path upstream concluded is unreliable and retreated from.

## Upstream fix

`manaflow-ai/cmux` PR #4233, commit `5cb4715a8`, 2026-05-16. Creates a borderless headless NSWindow at `TerminalSurface.init` for surfaces with startup work; attaches the view to that window so `view.window != nil` is satisfied; `ghostty_surface_new` runs cleanly. Replaces the c11-style off-window `createSurface(for: view)` in `requestBackgroundSurfaceStartIfNeeded` with delegation to `scheduleHeadlessRuntimeStartIfNeeded(reason:)`.

Sub-commits squashed into 5cb4715a8:
1. `test: cover offscreen terminal helper startup`
2. `fix: start offscreen terminal helpers before attach`
3. `fix: isolate offscreen startup helpers`
4. `Keep headless terminal bootstrap out of health window state`
5. `test: cover direct AppKit terminal view startup`
6. `fix: keep plain terminal hosted views surface-bound`
7. `fix: remove dead main-thread branch in force refresh`
8. `fix: annotate headless window helpers main actor`
9. `fix: ignore headless window in force refresh`

## Plan

1. **Worktree** at `code/c11-worktrees/c11-114-pty-wedge` on branch `c11-114/pty-wedge-port` off `main`.
2. **Inspect the upstream diff per file.** Categorize each hunk as: (a) load-bearing fix, (b) upstream-only rename / project rename (skip — c11 has its own naming), (c) needs c11-side adaptation. Pay extra attention to typing-latency-sensitive paths (`forceRefresh`, `attachToView`, `hitTest`) per `code/c11/CLAUDE.md` Pitfalls.
3. **Attempt cherry-pick of `5cb4715a8`** in the worktree. Conflicts expected on: `PendingSocketInput` (upstream renamed cases), `requestBackgroundSurfaceStartIfNeeded`, `Localizable.xcstrings`, possibly `AppDelegate.swift` and `TabManager.swift`.
4. **Resolve conflicts by hand**, preserving c11-specific divergences:
   - Keep c11's `PendingSocketInput.text(Data)` if rename hasn't been done here (we have to introduce upstream's split if their fix relies on it).
   - Keep c11's off-main socket policy (per `code/c11/CLAUDE.md` "Socket command threading policy").
   - Keep c11-specific telemetry (sidebar status reporting hooks).
   - Skip upstream's GhosttyTabs→cmux rename pieces — c11 has already diverged here.
5. **Build via `./scripts/reload.sh --tag c11-114-pty`** (tagged build, never untagged `c11 DEV.app`).
6. **Run c11-logic tests** (`xcodebuild -scheme c11-logic test`) — safe locally per CLAUDE.md.
7. **Manual reproduction & smoke test** of the orchestrator pattern against the tagged build:
   ```
   c11 new-surface --pane <DV> --no-focus  →  c11 send "echo TOKEN"  →  c11 read-screen
   ```
   Must show TOKEN. Stress version: 30+ surfaces in a loop, all must materialize.
8. **Port upstream regression test** `tests_v2/test_cli_background_terminal_helpers_start_pty.py` into c11's `tests_v2/`. Adapt CLI invocation from `cmux` to `c11` (or use the cmux compat alias). Run against the tagged build's socket.
9. **Commit** with a clear message referencing PR #4233 + commit `5cb4715a8` so provenance is preserved.
10. **Open PR**.

## Validation gates

- [ ] `xcodebuild -scheme c11-logic test` green
- [ ] Tagged build launches via `./scripts/reload.sh --tag c11-114-pty`
- [ ] Manual repro: zombie surface materializes within ~1s of first `c11 send`
- [ ] Stress repro: 30 surfaces in loop all return SENTINEL on read-screen
- [ ] Ported `test_cli_background_terminal_helpers_start_pty.py` green against tagged build socket
- [ ] No typing-latency regression noticed in dogfood
- [ ] PR open and CI green

## Out of scope (separate tickets if pursued)

- Eager headless bootstrap for command-less `new-surface` (defense in depth, optional)
- Honest error from `v2SurfaceSendText` queueing fallback when surface never materializes
- v2 handle registry pruning on `surface.close` (known leak, separate concern)
- Orchestrator skill workaround doc (no longer needed once fix lands)

## Risk register

- **Conflict resolution risk** on `PendingSocketInput`. The rename touches many call sites. Strategy: introduce upstream's two-case form (`pasteText`/`inputText`) and update every call site, since the fix relies on this split for the headless path. Verify via build, not just grep.
- **Typing latency risk**. `forceRefresh` is on the hot path; upstream's "remove dead main-thread branch in force refresh" sub-commit must be applied carefully. The "ignore headless window in force refresh" sub-commit is also load-bearing — without it, the headless NSWindow would receive unnecessary refresh wakeups.
- **Test host risk**. Per CLAUDE.md "Don't run xcodebuild test on c11 locally" memory — the host scheme launches a `c11 DEV.app` that crashes the user's running c11. Use `c11-logic` scheme (safe) for local iteration; defer `c11-unit` to CI or use `scripts/test-unit-local.sh`.

## Scope decision (2026-05-21)

Decided on **minimal viable port** after seeing upstream/c11 divergence: c11 lacks the pre-PR `PendingKeyEvent` struct, `PendingSocketInput`-with-keys enum, `pendingSocketInputQueue`, `sendNamedKey` on `TerminalSurface`, `liveSurfaceForGhosttyAccess`, and `allowsRuntimeSurfaceCreation`. Full verbatim port would require backfilling 200-300 lines of pre-PR scaffolding before applying #4233.

Minimal port scope:
- Headless `NSWindow` machinery on `TerminalSurface`
- `uiWindow` / `isViewInWindow` / `isHeadlessStartupWindow` API additions
- Eager headless bootstrap at `init` when `hasStartupWork`
- `requestBackgroundSurfaceStartIfNeeded` retreats from off-window `createSurface`; delegates to headless path
- `attachToView` releases headless when real window arrives
- `forceRefresh` uses `uiWindow` (ignores headless) — typing-latency safe
- `viewDidMoveToWindow` calls `reconcileAttachedWindowIfNeeded`
- `GhosttySurfaceScrollView.uiWindow` + focus/visibility callsite updates
- Caller updates in AppDelegate/Workspace/Panels/TerminalPanel/TabManager for `hostedView.window` → `surface.isViewInWindow`/`.uiWindow`

Excluded from this ticket (future work):
- `sendInputResult` / `sendNamedKey` enum-returning API
- `PendingKeyEvent` / `PendingSocketInput`-with-keys queueing
- Localized error strings for socket send failures
- TerminalController send-path refactor
- The "honest error from queueing fallback" improvement
