# C11-166 — Fix c11-unit host-lane compile: TerminalAndGhosttyTests missing trigger:

## Finding

`TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows` now
requires `trigger: String` (Sources/TerminalWindowPortal.swift:2447). Two call sites in
`c11Tests/TerminalAndGhosttyTests.swift` (lines 2238, 2389) still call it with no
argument → the c11-unit host lane fails to compile. The ticket's line estimate
(~2238/2296/2389/2468/2613) was stale; only 2 call sites exist on current origin/main.

## Fix

Mechanical: pass `trigger: "test"` at both call sites. Production sites pass a
descriptive event string (e.g. "sidebarWidthChange"); the arg is diagnostic-only, and
these are test-harness invocations.

## Verify

`build-for-testing` on the host scheme proves the test target compiles
(`scripts/test-unit-local.sh` is the safe wrapper). Do NOT run the full host suite
unattended.
