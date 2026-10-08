# C11-335: macOS CI backstop runs once per batch of main changes, on the free runner

## Why
GitHub bills only the macOS XLarge runners on this public repo ($0.102/min); standard macOS and Linux runners are free. The hourly native CI (`ci-hourly.yml`, from C11-315) ran a ~10-minute XLarge build every hour whether or not main changed: about $25/day. October hit the spending limit in five days ($350). Atin approved (2026-10-05): stop paying for idle runs; Atlas stays the per-PR exact-head gate and the place for any self-hosted compute, no rented machines.

## Done when
- The native backstop runs when main changes, not on a clock: `push` to `main` plus `workflow_dispatch`, with a concurrency group that never cancels the running job, so a burst of merges (say 20 in three hours) collapses to one run at a time, each testing the newest main.
- A run skips at once when its commit was already tested green (absorbs C11-321).
- It runs on the free standard runner (`macos-15`), with a job timeout that fits that runner's slower build. The compat workflow already builds the app there.
- Release, signing and nightly stay on XLarge (rare, and the nightly already skips unchanged main).
- The c11 `CLAUDE.md` and skills that mention hourly CI describe the new trigger.
- Proof: one dispatched run on the PR branch green on `macos-15`, and its wall time recorded.

Lands after 1.0 releases; main is frozen.
