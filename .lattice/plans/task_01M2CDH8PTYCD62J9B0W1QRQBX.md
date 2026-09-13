# C11-221: Hang monitor: repeated same-fingerprint episodes never surface as a precursor warning

## Problem

Before the 25-minute main-thread stall that spawned C11-209, the hang log recorded seven shorter episodes of 2.4 s to 10.7 s with the same cause/fingerprint, spread over the preceding stretch. Each was below or near the Sentry threshold, each was written to the local log, and none of them reached the operator or the events stream. The wedge was predictable from data c11 already had; c11 just never said anything.

`MainThreadHangMonitor` (Sources/MainThreadHangMonitor.swift) already classifies each episode into a `MainThreadHangSignature` with a `fingerprint` array and a `cause` label, and `handleHang` / `handleRecovery` run per episode on the watchdog thread. There is no cross-episode memory.

Found by the C11-209 delegator.

## Fix

Add a small cross-episode tracker on the watchdog thread:

- Keep a rolling record of completed episodes (fingerprint key, cause, duration, end uptime) bounded in size and time (suggest: last 10 minutes, at most 64 entries).
- When N episodes (suggest N=3) with the same fingerprint key complete within the window, and the cause is one `isWorthReporting` would accept (never `runloop-idle`), emit a precursor signal exactly once per fingerprint per window (re-arm after the window slides past).
- The signal must land in all three places: (1) a `=== c11 hang.precursor ... ===` block in hang.log carrying the fingerprint, count, window and durations; (2) the c11 file-first events stream (the `c11 events tail` stream; read `~/.claude/skills/c11/references/events.md` for the envelope and v1 taxonomy, and add a `hang.precursor` event with a payload that names cause, culprit, count, window_ms and the durations); (3) one Sentry event through the existing `SentryEventBudgetGate` path, tagged `hang.precursor=true` with the same fingerprint so it groups with the eventual wedge.
- Off-main only. No modal, no alert, no `runModal`, no UI mutation from the watchdog thread. If you want a visible operator hint, do it via the existing notification store on `DispatchQueue.main.async` and keep it a single non-blocking notification per window; that part is optional.
- Cost: constant time per episode; no allocation in the suspend window.

## Tests

Pure-logic tests in `c11LogicTests` against a `HangPrecursorTracker` (or similar) struct with injectable clock: fewer than N in window does not fire; N fires once; the same fingerprint does not fire again until the window has slid; a different fingerprint fires independently; `runloop-idle` never fires; old entries age out. No source-text assertions.

## Validation

CI is the gate. Do NOT run `xcodebuild` locally on this machine (one build per machine rule). Push, open the PR, watch `gh pr checks`, iterate until green. If a local runtime demonstration is feasible without a build, describe it; otherwise say plainly that validation is tests plus CI.
