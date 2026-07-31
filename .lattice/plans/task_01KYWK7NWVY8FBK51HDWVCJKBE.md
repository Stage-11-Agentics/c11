# C11-189: Guard legacy Codex notify: only the captured root thread may mutate surface attention

### Problem (observed incident GAF-13, 2026-07-30)

A Codex child collaboration agent completed and Codex fired the legacy `notify` callback for that child turn. c11 treated the callback as the root agent finishing: `TerminalNotificationStore` forced the surface lifecycle to `idle`, created/replaced an unread notification, and `SurfaceLivenessDeriver` projected `waiting` — while the root agent was still visibly working. Four false waiting transitions were recorded on workspace 424A3DE0/surface 5D42C06C (c11 0.61.0), each 1-7s after a child FINAL_ANSWER.

The callback payload the wrapper currently discards already contains `thread-id` and `turn-id`. The surface's captured root conversation (ConversationStore, via `c11 conversation capture-runtime`) gives the root thread to compare against.

### Fix (incident-scoped)

In the legacy Codex notify ingest path only: parse the callback payload, and mutate surface attention (lifecycle, notification, liveness projection) ONLY when the payload `thread-id` matches the captured root conversation thread for that surface. Non-matching, missing, or unparseable thread-ids leave attention state untouched (a bounded debug log line is fine). No new subsystems: the guard lives at the existing ingest point in the wrapper/`TerminalNotificationStore` seam.

### Acceptance criteria (closed list — reviews judge against these and regressions only)

1. GAF-13 regression fixture: replayed child `agent-turn-complete` callbacks while a root is captured produce zero waiting edges, zero idle transitions, zero notifications.
2. A callback whose thread-id matches the captured root behaves exactly as today (notification + waiting when the root is done).
3. A surface with no captured root conversation keeps current (pre-guard) behavior, so Claude/Kimi/shell and uncaptured Codex surfaces are unaffected; existing liveness tests stay green.
4. One tagged-build smoke check: drive a real Codex child completion on a tagged build and observe the surface stay `working` (computer-use approval requested before it runs).

### Non-goals (explicit, binding)

No provider-neutral attention reducer. No launch epochs, ownership keys, or fencing. No crash-durable markers or transactional coordinators. No typed hooks adapter, no App Server adapter, no new ingestion CLI seam. No changes to C11-183 marks or C11-184 flag/suppression. If the fix appears to need any of these, STOP and escalate to the operator — that is the C11-188 failure signature (see docs/aar-c11-188-attention-loop.md).

### Process guardrails (binding on any orchestration)

- Maximum 2 fix/review cycles, then mandatory operator escalation; the limit may not be overridden for any reason, including "no human decision required".
- Diff budget ~300 lines including tests; exceeding it is itself an escalation trigger.
- No merge to main before a PASS review. Single implementer; no fleet.

### History

Replaces C11-188 (deleted after eight non-converging fix/review cycles; post-mortem: docs/aar-c11-188-attention-loop.md). The old ticket's reducer architecture is deliberately NOT preserved as a roadmap; future hardening tickets must be driven by observed incidents.
