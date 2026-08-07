# C11-191: the Sentry "main thread hang" signature — identification, and the telemetry that makes it readable

STATUS: delivered and merged as b2fb5caa5 (#411) on 2026-08-07. This plan file was rewritten at
that point; the previous contents described the tab-bar preference-loop hypothesis, which the
evidence refuted. Kept short deliberately — the reasoning lives in the ticket comments, which are
the durable record.

## What the ticket actually turned out to be

The ticket's premise had three defects, each measured rather than argued:

1. **Sentry C11-30 is a bucket, not a bug.** Fingerprint `{{ default }}`, one hash; a 1,500-event
   sample spans eleven release strings and every stack shape. Sentry groups message events by the
   *reporting* thread's stack, which for a hang report is the watchdog's own loop, identical every
   time. No single root cause can close it. C11-192 (#402) fixed the grouping.
2. **"2335 ms" is the detection threshold.** v0.58.0 reported at the 2 s trip point and `gapMs` is
   the gap at detection, so the median is pinned just above 2 s. Real episode length (from
   `hang.end`): median 6.7 s, p90 49 s.
3. **The quoted frames were noise.** `stack.prefix(24)` cut above our own frames; the named
   symbols were Sentry's demangling of the generic SwiftUI update spine.

The candidate root cause from plan review (bonsplit `TabBarView.swift` 730-749 / 794-809) is
refuted: `swiftui-update/preferences` is 13 of 5,311 episodes (0.2%); `updatePreferences` and
`TabBarView` co-occur in 12 (0.23%); and the `onPreferenceChange` -> `@State` -> `.frame(width:)`
path is idempotent, not divergent — the state feeds a sibling backdrop, not the measured subtree.

## What shipped

- `runloop-idle` (46.5% of episodes — the largest slice of the volume) no longer emits a Sentry
  event from behind an unwatched window. A late heartbeat ack is not a wedge; off-screen it is App
  Nap and timer coalescing. Watched still reports; the local log and PostHog keep everything.
- `MainThreadHangSignature.reportedStack` replaces `prefix(24)`: top window plus the own-module
  frames below it, true indices, elided run marked. Lifts busy reports that name our code from
  18.0% to 21.0%.
- `hang.app_active` / `hang.window_visible` tags; `cause=`/`active=`/`visible=` in the local log
  header; matching `cause` on the PostHog event.

Behavioral tests in `c11LogicTests` (so CI's `build` job runs them) cover the stack-window
selection and the reporting rule. Deep review: merge as-is, nothing blocking.

## What remains, and where

**C11-202** owns the real user-visible freeze: `swiftui-update/*`, 28.2% of episodes across 38-39
pids. Its approach is corrected there — ~79% of those episodes name none of our code at any stack
depth, so it needs a profiler against a driven repro, not more frames.

Verification for this ticket lands on the first release carrying #402 + #411: C11-30 should stop
accumulating and split per cause, with `runloop-idle` a fraction of its former volume. Judge by
issue presence and user count per bucket, not total event count.
