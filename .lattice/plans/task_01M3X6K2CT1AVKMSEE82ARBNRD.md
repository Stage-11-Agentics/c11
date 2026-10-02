# C11-302 — coalesce Ghostty callback work

Build mode; reassigned by Orchestrator to agent:astra-ghostty. Base `b6f239bd077164d2ff2e7aa18d5464d4e885fd35` includes merged C11-294; branch `c11-1.0/C11-302-ghostty-wakeups`. Original design retained, with callback-thread contracts rechecked below.

## Evidence and design

Read ticket/seeded plan, `05-bug-sweep.md`, ledger B030/B033, Fable C5 and Astra section 2. Confirmed `Sources/GhosttyTerminalView.swift:1069-1072` queues one tick per wakeup; `GhosttyApp.tick` at `:1575` calls the native tick. Scrollbar/cell-size mutate and notify inline (`:2161-2180`); surface color/config paths do likewise (`:2282-2328`). Congestion relates to C11-197/202/205; no measured c11 queue-depth or black-frame result is claimed. Color/config currently traverse the main-drained native app mailbox; reverify on C11-294 rather than copying upstream hops mechanically.

Change `GhosttyApp` wakeup scheduling in `Sources/GhosttyTerminalView.swift` to a small lock-protected queued bit. The first request immediately enqueues main work. Clear the bit under the lock **before** entering native tick, then release the lock: wakeups during that tick, including C11-294's explicit re-wake after a partial drain, can schedule one successor. Never hold the lock across Ghostty or AppKit calls. At most one block is queued, in addition to one executing tick; no timer, debounce delay, run-loop pumping or display link. Use runtime callback userdata for the existing app instance where appropriate, avoiding new singleton initialization reentry.

For scrollbar updates, copy the scalar payload during the callback into a latest-value slot per live surface, with one queued main flush. Take and clear slots before publishing so racing arrivals schedule the next flush. Validate the weak target/current runtime generation before applying to a closed or replaced surface. Apply `noteScrollbar` and its notification together on main. Copy cell-size payload before any off-main hop. Preserve synchronous main-thread color/config handling when native delivery is already main; any required off-main publication copies owned values before returning, never retains a borrowed config pointer. Preserve color/config reset order and final state; coalesce only demonstrated high-rate scalar updates, not arbitrary action events. Leave title handling untouched.

The coalescer may be a tiny internal pure type in the same file, exercised by `c11Tests/TerminalAndGhosttyTests.swift`; extract only if needed for a no-NSApp test target. Avoid a general callback framework.

## Acceptance → fixture → validation

| Criterion | Incident/fixture | Behavioral test and real proof |
|---|---|---|
| AC1, one pending tick | B030 concurrent producer burst | Deterministic scheduler fixture: many simultaneous requests queue once; executing tick requests again and leaves exactly one successor; a final bounded-drain re-wake executes without any later user input. Stress the production scheduler from several controlled streaming terminals on Atlas; DEBUG counters show maximum pending=1 and eventual final output. |
| AC2, paint and input | C11-197/202/205 streaming congestion | Tagged native artifact after C11-294: several bounded `yes`-like streams, final sentinel, then real focused keystrokes. CUA captures paint/input and a short paired latency sample. Compare exact same workload against post-bump baseline and C11-270 budgets; report p50/p95/p99 and maximum rather than only averages. |
| AC3, scrollbar/callbacks | B033 callback thread and last-value fixtures | Concurrent updates to two surfaces retain each final scrollbar; update during flush schedules follow-up; closed generation does not publish. Main-thread assertion in apply path. Tagged CUA drags scrollbar, changes font/cell size, OSC background and reloads config; final reset/color and pointer tracking remain correct. |

All builds/tests on Atlas after C11-216 and BUILD MODE. Use C11-270 soak when available, otherwise label the shorter paired sample preliminary and state the regression margin/budgets before running the candidate. No full soak owned here. Tagged QA launch, verified display, hard termination timer, synthesized dismissal, readable-area screenshots. DEBUG-gated counters only; no source-grep tests.

## Impact, dependencies, cut line

Depends on C11-294 and its final re-wake guarantee, C11-216 for execution; measurement uses C11-270. Shared `GhosttyTerminalView.swift` edits rebase serially with C11-295 and the title owner through Orchestrator only. No changes to mailbox drain, title filtering, layout flush, mount cap, sidebar or `forceRefresh`. `hitTest`, `TabItemView`/row equality and telemetry paths remain untouched. No new long-lived thread; preserve existing autoreleasepools. Main publication is async from a native background callback, never sync. No new strings, skill/API changes, persistence migration or tenant config. Open decisions: none. One PR; max three review cycles; Orchestrator owns review and Merge Captain owns merge.

## Post-bump implementation clarifications and predeclared sample budget

Native 5830d1976 sends scrollbar via renderer → app mailbox → Surface.updateScrollbar; it is currently main-thread delivery, but bursts still coalesce. Cell size is synchronously delivered during Surface.init before Swift receives the native surface handle; preserve that inline main update. Color/config remain ordered inline on main, and borrowed config pointers never cross an async boundary. New asynchronous scalar publication validates the exact retained callback-context identity, not a surface UUID or reused native pointer.

Use a small lock-protected latest-value coalescer in GhosttyTerminalView.swift for ticks and per-context scrollbar updates; injected scheduling makes concurrent behavior deterministic in tests. Tests live in the existing TerminalAndGhosttyTests.swift host target, selected narrowly on Atlas. Add DEBUG-only tick/scrollbar scheduling snapshots to existing debug.terminal.render_stats through TerminalController.swift; no release API or installed skill change.

Before candidate measurements: compare 100 PID-scoped Return-to-PTY samples with 30 existing fixture streams at 20Hz each, same driver/workload and machine, baseline b6f239bd07 versus candidate. Accept zero misses and candidate p95 and p99 each no greater than baseline plus max(5 ms, 20% of that baseline percentile). Report p50/p95/p99/max and load averages. This is a preliminary paired sample, not the deferred C11-270 fleet soak. Production scheduler counters must show maxPending=1 with coalesced requests and eventual final output without extra input. Font/cell-size, scrollbar pointer drag, OSC background plus config reset, and close/recreate callbacks get their named runtime/unit proofs. Atlas builds only; authorized Hyperion UI uses the shared slot, verified display/PID/window, 20-minute hard cap and synthesized dismissal.

## Reset 2026-10-02 by agent:astra-ghostty
