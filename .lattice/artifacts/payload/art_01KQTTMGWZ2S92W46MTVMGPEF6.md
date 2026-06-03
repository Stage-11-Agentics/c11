All 7 scope items shipped and merged.

PR #80 (merged 2026-04-26) — bounded waits, named timeouts, trace mode, deadline-aware main-actor bridge, stress fixture.
PR #66 (merged 2026-04-23) — c11 notify migrated to v2.

Verified on main:
- notes/c11-7-mainthread-audit-2026-04-24.md (105 DispatchQueue.main.sync sites: 48 SAFE / 38 RISKY / 19 NEEDS_ASYNC; Tier 1 creation handlers fixed here, full async refactor sequenced into C11-4)
- tests_v2/test_socket_reliability_stress.py (20 concurrent CLI calls during rapid surface creation, no indefinite hangs)
- tests/test_cli_socket_deadline.py (deaf-socket harness; verifies named timeout envelope, trace lines, browser.wait opt-out)
- v2MainSyncWithDeadline wired into window.create, workspace.create, surface.create, pane.create, new_workspace, new_split, drag_surface_to_split with cancellation guard (B1) and unified c11: timeout: error envelope (I3).

Acceptance criteria check:
- c11 notify uses v2 and returns quickly or named-fail. PASS (#66).
- Ordinary CLI socket request beyond deadline exits non-zero with method-named message. PASS.
- Trace mode prints start/end/timing per request. PASS.
- Audit doc with classified DispatchQueue.main.sync handlers exists. PASS.
- Tests cover prior failure shape. PASS.
- CMUX-37 can rely on these reliability guarantees. PASS — C11-4 is unblocked, audit doc is its starting point.

No follow-up regressions observed. Deferred items (full async accept-loop refactor, op-id idempotency, latency telemetry, humanInput SocketDeadline case) are explicitly tracked under C11-4 in the PR body.