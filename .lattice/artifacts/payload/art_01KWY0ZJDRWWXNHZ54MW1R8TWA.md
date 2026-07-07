# C11-165 Code-Review Triage

The board's headless code-review returned an **empty diff** (it ran against the parent checkout on `main`, not the worktree branch `ts/cor-p0-correctness`) — an explicit own-reviewer fallback trigger per the boot. Fallback: two independent adversarial review agents (COR-3 concurrency; COR-1 completeness/regressions) on the real worktree diff, plus self-review.

## COR-3 reviewer findings

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | HIGH(cpu) | `v2AwaitCallback` `CFRunLoopRunInMode(...,0.05,true)` — `returnAfterSourceHandled:true` busy-spins main under active source traffic for the whole timeout. | **FIXED** → `false` (each slice blocks the full 50ms, drains multiple sources). |
| 2 | MED | Deadline used wall-clock `Date()`, vulnerable to NTP/clock jumps. | **FIXED** → monotonic `ProcessInfo.processInfo.systemUptime`. |
| 3 | LOW | pane.confirm error-code precedence changed (title check now before tabManager/panel_id) for doubly-malformed requests. | **WONTFIX (intentional)** — validating an obviously-bad title off-main before the main hop is fail-fast and defensible; only affects the error code of a request malformed in two ways at once. |
| 4 | LOW | Up to ~50ms added resolution latency (finish no longer wakes the loop). | **ACCEPT** — negligible for browser awaits; the wake-based alternative (CFRunLoopStop) is exactly the nesting bug being fixed. |
| — | — | Verified NON-issues: dispatch coherence (double-guarded by `invalid_dispatch`), semaphore/hop ordering, `defer` signal on all paths, isolation of both nonisolated handlers, no double-signal/dealloc trap. | — |

## COR-1 reviewer findings

| # | Sev | Finding | Resolution |
|---|-----|---------|------------|
| 1 | HIGH | CLI client-side resolved the operator-**focused** surface (via `system.identify`) for set-agent/set-metadata/set-title/set-description/rename-tab when the env is fully unset (cron/launchd), sending it as a concrete ref → bypassed the server guard entirely (the exact P0.2 stomp). Only the exported-empty-string case was closed. | **FIXED** — threaded `allowFocused:false` through `resolveMetadataTarget`/`resolveMetadataCommandTarget` for the write callers (reads keep `true`); `set-title`/`set-description` now omit `surface_id` when no ref supplied; `rename-tab` excludes `rename` from the focused fallback. A ref-less external write now sends no ref → server `missing_ref`. New test `test_cor1_cli_focused_fallback.py`. |
| 2 | LOW-MED | `--window`-scoped v1 write without `--workspace` (e.g. `set-status k v --window @2`) now rejected (was: window's selected tab). | **INTENTIONAL (flagged)** — consistent with COR-1's "explicit ref required"; `--window` alone doesn't pin a tab. Operator passes `--workspace`. |
| 3 | LOW | v1 guard runs before the positional/usage check, so a ref-less+valueless call returns `missing_ref` instead of the usage string. | **WONTFIX** — both are errors; cosmetic. |
| 4 | VERY LOW | Pane guard `targetKeys` includes `surface_id`/`tab_id` the pane resolver ignores; a hand-crafted `pane.set_metadata{pane_id:valid, surface_id:""}` is rejected. | **WONTFIX (defensible)** — an explicitly-empty ref is always a bug; unreachable via CLI. |
| — | — | Verified correct: reads/non-write verbs untouched; set-agent/title/description all route to guarded `surface.set_metadata`; `v2RejectUnresolvedPin` main-actor safety; validator NSNull/number/whitespace edges; in-pane `--tab` forwarding (CMUX_WORKSPACE_ID exported to every surface). | — |

## Net
Two HIGH findings fixed (browser CPU spin; **CLI focused-fallback bypass — the important one, closing COR-1's contract for the external-caller case**), one MED fixed (monotonic clock). Remaining items are intentional-per-contract or cosmetic. Rebuild + re-validation follows.
