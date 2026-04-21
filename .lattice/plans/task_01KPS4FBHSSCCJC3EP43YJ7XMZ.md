# C11-7: Automation socket reliability: bounded waits, v2 notify, traceable timeouts

## Problem

A 2026-04-21 dogfood run attempted to create five custom c11 workspaces through automation. The layout work itself was fast, but the batch lost minutes because individual CLI/socket calls could block without obvious attribution. The clearest observed blocker was `c11 notify --workspace ... --surface ...`, which routes through legacy v1 `notify_target`; a later run also blocked while writing surface metadata immediately after a markdown tab was created.

This is a platform reliability issue, separate from CMUX-37's Blueprint/Snapshot feature work. CMUX-37 should provide app-side `workspace.apply` so workspace materialization does not require shell choreography. This ticket hardens the automation substrate so any command, including future bulk commands, fails fast and explains what stalled.

## Scope

1. **Bounded CLI waits by default.** Ordinary socket commands should have a default deadline suitable for automation. Long-running commands (`browser wait`, downloads, explicit waits, pane confirmations) may keep command-specific timeouts.
2. **Named timeout errors.** Timeout output must include method/command, target refs when available, socket path, and elapsed time. A quiet script should make the stuck command obvious.
3. **Trace mode.** Add `C11_TRACE=1` / `CMUX_TRACE=1` (or equivalent) to print per-command start/end/timing lines for CLI socket requests.
4. **Move `notify` to v2.** `c11 notify` should call `notification.create`, `notification.create_for_surface`, or `notification.create_for_target` instead of legacy v1 `notify_target`.
5. **Audit risky socket main-thread hops.** Inventory v1/v2 handlers that use `DispatchQueue.main.sync`; identify which are safe, which need async/deadline-aware wrappers, and which should be migrated off v1.
6. **Deadline-aware main actor bridge.** For handlers that must touch AppKit/SwiftUI state, prefer an async/deadline-aware execution path over unbounded synchronous main-queue waits.
7. **Regression fixture.** Add an automation stress test that rapidly creates/mutates mixed terminal/browser/markdown surfaces and asserts no CLI process can hang indefinitely.

## Non-goals

- Do not implement Blueprints/Snapshots here. That belongs in CMUX-37.
- Do not build the full `workspace.apply` transaction here, except where a small test fixture needs a temporary direct socket call.
- Do not solve all CMUX-25 pane-registry transaction work here. This ticket is narrower: CLI/socket reliability and observability.

## Acceptance criteria

- `c11 notify --workspace <ws> --surface <surface> ...` uses v2 and returns quickly or fails with a named timeout.
- Any ordinary CLI socket request that exceeds its deadline exits non-zero with a message naming the method/command.
- Trace mode shows start/end/timing for each socket request.
- A targeted audit document or code comment lists remaining `DispatchQueue.main.sync` socket handlers and their risk classification.
- Tests cover the prior failure shape: notification and metadata calls during rapid mixed-surface creation cannot hang a shell batch indefinitely.
- CMUX-37 is linked as related work and can rely on these reliability guarantees rather than absorbing them.

## Context

This ticket was split out while grooming CMUX-37. The proposed fix set divides as follows:

- CMUX-37 owns `WorkspaceApplyPlan`, `workspace.apply`, Blueprint materialization, Snapshot restore, creation-time metadata, readiness states for materialization, and the five-workspace fixture as a product/perf acceptance test.
- This ticket owns CLI/socket deadlines, traceability, v1 notification migration, and the broader main-thread/socket hang prevention work.

