# Handoff: eliminate the c11 main-thread freezes (Swift-only scope)

You are the implementation agent for the 2026-08-25 freeze investigation. The
diagnosis is complete and evidence-backed; your job is to land the fixes. Work in
`~/Projects/Stage11/code/c11` on a branch per workstream, PRs per repo convention.

## Required reading, in order

1. `notes/2026-08-25-freeze-surface-deinit-deadlock.md` — the full root-cause
   report. Everything below assumes you've read it; this handoff does not repeat
   the evidence chains.
2. `notes/evidence-2026-08-25-sample-pid4759-deadlock.txt` — raw `sample` of the
   deadlocked process (main thread + all 333 threads).
3. Repo `CLAUDE.md` — especially: typing-latency-sensitive paths, socket command
   threading policy, test quality policy, tagged-build rules (`reload.sh --tag`,
   `C11_QA_LAUNCH`, never launch untagged DEV builds).
4. `~/Library/Logs/c11/hang.log` — 13 days of classified hang captures; your
   before/after metric source. `Sources/MainThreadHangMonitor.swift` documents the
   cause taxonomy (`lock-wait`, `runloop-idle` = late heartbeat at the outermost
   loop, `swiftui-update/*`, etc.).

## The two pathologies (summary)

**P-A. Teardown deadlock (terminal freeze).** `teardownSurface()`
(`Sources/GhosttyTerminalView.swift:3286`) frees the ghostty surface on the main
actor → ghostty `Surface.deinit` joins the surface's io thread → io thread joins the
PTY read thread → read thread is parked in a `.forever` push into the **shared
64-slot app mailbox whose only consumer is the main thread**. Three-way join cycle;
unrecoverable. Fired 2026-08-25 2:25 PM ET (19+ min stall, restart required).

**P-B. Congestion storms (the beachballs).** Recovering main-thread hangs, 50
episodes in 2h on the post-restart instance, up to 352s. Faces: SwiftUI
AttributeGraph `propagate_dirty` storms; `runloop-idle` late heartbeats (main-queue
backlog minutes deep — largest bucket, 28/50); a 120s `mouseMoved` hover hit-test
recursion; and a 62-minute stall from a `DispatchQueue.sync` inside SwiftUI body
evaluation.

**Causal link:** P-B fills the shared mailbox → readers park → P-A's trap is armed;
any surface close then springs it. Reducing P-B *is* P-A prevention.

## Hard constraint

**No changes to the ghostty submodule in this pass.** The ghostty-level fixes
(mailbox capacity bump, termio quit-flag patch) are specified in the notes doc as a
documented fallback — do not implement them. Everything here is c11 Swift.

## Workstreams

### WS1 (P0) — Remove the sync-from-body metadata read

`Workspace.surfaceTitleBarState(panelId:)` (`Sources/Workspace.swift:7703`) calls
`SurfaceMetadataStore.shared.getMetadata(...)` — a `DispatchQueue.sync` hop —
from inside `VerticalTabsSidebar.body` ForEach (call site
`Sources/ContentView.swift:8668`), per agent surface per body evaluation. Evidence:
the 62-minute stall (notes doc, "Second finding") with main in
`__DISPATCH_WAIT_FOR_QUEUE__` under this exact path.

Fix shape: the metadata store publishes a main-actor snapshot (pushed async on
write); body-reachable code reads only main-actor state. Audit
`surfaceTitleBarState` fully — the `TerminalController.shared.surfaceOrdinal` call
inside it must not hide another lock/queue hop. Then sweep for other
`DispatchQueue.sync`/lock acquisitions reachable from any SwiftUI `body` and fix or
ticket each (this class of bug held main for an hour; zero tolerance).

Acceptance: no synchronous cross-queue/lock hops reachable from view bodies on the
sidebar render path; sidebar renders current title/description with async update
latency ≤ 1 frame under normal load.

### WS2 (P0) — Teardown guard + deadlock tripwire

Swift-side risk reduction for P-A (the race cannot be fully closed from the
embedder — see notes doc — so shrink the window and instrument the residual):

1. Route all `ghostty_surface_free` calls (three sites in
   `Sources/GhosttyTerminalView.swift`: ~3289, ~4256, ~4300) through a main-actor
   teardown scheduler. Per free: only proceed when the main loop is currently
   responsive (reuse `MainThreadHangMonitor`'s heartbeat freshness — a stalled or
   lagging main means the app mailbox may be full and readers parked); tick the
   ghostty app (drain the mailbox) immediately before the free; free at most one
   surface per run-loop turn. While the monitor reports an active stall, defer
   frees (bounded queue of zombie surfaces — each costs ~3 idle threads + memory,
   vastly cheaper than a permanent freeze). Design the bounds/backoff yourself;
   justify them in the PR.
2. Tripwire: when the hang monitor classifies `cause=lock-wait` with
   `Surface.deinit` in the top frames, emit a distinct escalated log line + Sentry
   event (tag it clearly, e.g. `teardown-deadlock`). This is the signal that the
   Swift-only strategy is insufficient — see Escalation below.

Acceptance: repro harness (see Validation) runs surface churn under output flood
with zero `lock-wait`/`Surface.deinit` occurrences; teardown latency under normal
conditions remains imperceptible; tripwire fires correctly when simulated (unit
test the classifier path — behavioral, per test policy).

### WS3 (P1) — AttributeGraph invalidation storms

Evidence buckets: `swiftui-update/hosting-begin-transaction` with
`AG::Graph::propagate_dirty` up to ~278s. Known implicated surfaces from capture
frames: `VerticalTabsSidebar.body` (one enormous body — the mangled symbol in the
notes doc is a single expression), `SurfaceTitleBarView.headerRow`,
`WorkspacePulseAgent` rows.

Approach: measure first (hang.log buckets + Instruments/SwiftUI body counts on a
tagged build under the repro harness). Then: coalesce agent-driven invalidations
(agents write status/metadata at high frequency across 30+ surfaces — batch to a
bounded update rate per surface; the socket threading policy in CLAUDE.md already
mandates off-main coalescing for telemetry — verify actual compliance and extend it
to the model-object fan-out); decompose the sidebar body so a one-surface change
does not re-evaluate the world; preserve the `TabItemView` Equatable contract
(CLAUDE.md pitfalls — it is load-bearing for typing latency).

Acceptance: under the repro harness, `swiftui-update/*` hang episodes ≥5s drop to
zero; no typing-latency regression (the CLAUDE.md-listed hot paths untouched or
re-validated).

### WS4 (P1) — Hover/hit-test cost

Evidence: 120s hang ending 2026-08-25 5:00:22 PM ET — `mouseMoved` →
`HoverEventDispatcher` → deep `MultiViewResponder.containsGlobalPoints` recursion +
generic-metadata instantiation. Mouse movement over the 29-surface hierarchy held
main for two minutes.

Approach: inventory `onHover`/tracking-area/hover-effect modifiers across the tab
bar, sidebar, and surface chrome; reduce responder depth/count (hover state at leaf
scope, not broadcast); consider degrading hover affordances when surface count is
high or the hang monitor reports lag. Measure before/after with the same harness.

Acceptance: continuous mouse movement across the full window under harness load
produces no hang episode ≥2s attributable to hover dispatch.

### WS5 (P2) — Main-queue backlog audit

`runloop-idle` (late heartbeat) was the largest bucket: 28/50 episodes, up to 352s
— proof of a minutes-deep main-queue backlog independent of any single slow body.
Audit main-queue producers: socket command handlers (`v2MainSync` users), metadata
fan-out, portal/geometry sync, notification stores. Instrument (count/attribute
main-queue enqueues per second per source under harness load), then coalesce or
move off-main per the socket threading policy. File follow-up tickets for anything
too large for this pass.

Acceptance: attribution data captured and in the PR description; top two backlog
sources fixed or ticketed with data.

### WS6 (P2) — hang.log rotation

`~/Library/Logs/c11/hang.log` is 232MB and growing unbounded
(`MainThreadHangMonitor.persist`). Add size-based rotation (e.g. rotate at 32MB,
keep 2-3 generations). Keep the format stable — it is parsed forensically.

## Escalation fallback (do not implement now)

If the WS2 tripwire ever fires post-landing, the pre-approved next steps live in
the notes doc ("Fix plan" A/B and "Fork topology"): first the one-line ghostty
`App.zig` mailbox bump (64→2048), then the termio quit-flag patch, both with exact
landing steps. Record any tripwire hit as a Lattice ticket referencing the notes
doc so no re-diagnosis is needed.

## Validation (hard gates)

- **Repro harness** (build it first; check `tests_v2/` and `scripts/` for prior
  art): on a tagged build (`./scripts/reload.sh --tag freeze-fix`, launch via
  `./scripts/launch-tagged-automation.sh freeze-fix --qa fresh`), open 25-30
  terminal surfaces; flood them with output including title/pwd OSC churn (e.g.
  loops emitting `printf '\033]0;title-%d\007'` + bulk text); continuously close
  and reopen surfaces; run ≥15 min. Tagged builds write their hang log to a
  tag-derived `/tmp` path (see `MainThreadHangMonitor.resolveLogURL()`), so each
  run gets a clean metric file.
- **Metrics**: parse the tagged hang log before/after each workstream — episode
  count, max `stalledMs`, cause buckets. The notes doc's numbers (50 episodes/2h,
  max 352s) are the baseline shape to beat. Include the numbers in every PR.
- **Zero tolerance**: any `lock-wait` + `Surface.deinit` capture during harness
  runs is a failed gate.
- **Real-artifact smoke** per repo policy: drive the tagged app's actual UI
  (socket + computer-use per `c11-computer-use` conventions) — typing stays
  responsive during the flood, surfaces close cleanly, sidebar updates live.
- Tests: behavioral only (repo test policy); local loop via the `c11-logic` scheme
  where applicable.

## Working style

Bias to action; PRs per workstream, mergeable when green and validated. WS1 + WS2
first — they remove the catastrophic failure mode and the worst single stall class.
If WS3-WS5 grow beyond one agent's comfortable scope, split them into Lattice
tickets per the repo's orchestrator workflow rather than letting them sprawl.
Update `notes/2026-08-25-freeze-surface-deinit-deadlock.md` with a results appendix
when done: what landed, before/after numbers, anything the next investigator needs.
