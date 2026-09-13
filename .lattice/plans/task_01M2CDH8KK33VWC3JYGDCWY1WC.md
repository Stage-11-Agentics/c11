# C11-220: hang.log has no rotation or size cap: ~23 MB/min during a stall, 238 MB observed

## Problem

`MainThreadHangMonitor.appendToLog` (Sources/MainThreadHangMonitor.swift, ~line 669) appends every `hang.begin` / `hang.persist` / `hang.end` capture to `~/Library/Logs/c11/hang.log` (or `/tmp/c11-debug-<tag>-hang.log` for tagged builds, or `$C11_HANG_LOG`) with no cap and no rotation. A persist capture is a 96-frame symbolicated backtrace every 5 s, and during a sustained stall the C11-209 delegator measured ~23 MB/min (~1.3 GB/hr). On this machine `~/Library/Logs/c11/hang.log.wedged-20260911` is 238 MB from a single wedge. Nothing prunes it; a multi-hour stall on a shipped install eats the operator's disk.

Found by the C11-209 delegator; explicitly out of scope there.

## Fix

Cap the log with rotation, cheaply, on the watchdog thread (which is where `appendToLog` already runs):

- Track bytes written since process start plus one `stat` on first open; do not `stat` on every append.
- When the file would exceed a cap (suggest 32 MB), rotate: `hang.log` -> `hang.log.1`, keeping at most 2 archived generations (`hang.log.1`, `hang.log.2`), oldest deleted. Rotation happens at an episode boundary where possible (`hang.end`) so a single episode's timeline is not split; but a single episode that exceeds the cap on its own must still rotate mid-episode. Write a one-line `=== c11 hang.rotated <ts> ===` header at the top of the new file that says the previous file was rotated.
- Total on-disk footprint must stay under roughly 3x the cap.
- No allocation inside the `thread_suspend` / `thread_resume` window (there is none today because `appendToLog` runs after resume; keep it that way).
- Rotation must never run on the main thread and must never throw or trap; if rename fails, truncate.

## Tests

Pure-logic tests in `c11LogicTests`: factor the size/rotation decision into a testable seam (e.g. a small `HangLogRotator` struct that takes a path + cap and exposes `appendAndRotateIfNeeded`), then test: writes under cap do not rotate; crossing the cap rotates once; generations shift and the oldest is deleted; footprint bound holds after many rotations. Use a temp directory. No source-text or plist assertions.

## Validation

CI is the gate. Do NOT run `xcodebuild` locally on this machine (one build per machine rule; another build may hold the lock). Push the branch, open the PR, watch `gh pr checks`, iterate until green.
