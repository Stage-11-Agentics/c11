# C11-332: Un-quarantine the host test classes that now guard 1.0 fixes

## Why
The hourly CI host gate skips a quarantine list (`.github/workflows/ci-hourly.yml`, `HOST_TEST_QUARANTINE`). During the c11 1.0 run, fixes landed whose regression tests sit in quarantined classes, so CI never runs them:
- `c11Tests/GhosttyConfigTests` holds the regression test for C11-311 B083.
- The close-guard class quarantined by C11-253 holds the test for C11-250's close fix.
- `c11Tests/AppDelegateShortcutRoutingTests` had 17 failures on main as a baseline (confirmed 2026-10-02 18:20), so it is quarantined rather than fixed.

## Done when
- Each class above is either back in the host gate and green, or its new-fix tests move to `c11LogicTests` where they run.
- The 17 baseline failures in `AppDelegateShortcutRoutingTests` are fixed or each one is deleted with a reason.
- The quarantine list carries a comment naming why each remaining class is there.

Source: c11 1.0 run retro, run-state entries 16:03, 16:30 and 18:20 on 2026-10-02.

## Reset 2026-10-06 by agent:cairn-retro
