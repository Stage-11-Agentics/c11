# Review: C11-302 (coalesce terminal wakeups so streaming output cannot flood main), cycle 1 — Grok

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. You are Grok: read-only, no edits, no builds or tests, no subagents.

- Ticket **C11-302** (risk list). PR https://github.com/Stage-11-Agentics/c11/pull/526, head `2f63e9b3c88265aa61879ceca70fc345fc610b7b`, base = merge-base with origin/main (includes C11-294's Ghostty patch set).
- Title `C11-302 Review Grok`. Actor `agent:grok-review-302`. Owner was Codex Astra.
- Plan: the ticket's plan file. Evidence `art_01M3XZRX18WYB2HX7NBPSGRFWS` (9 focused tests; matched 30-stream / 100-input sample; font/color/config/final output observed) and gap `art_01M3Y0BXQ292814QFQA76YK51V`. Orchestrator ruling on the ticket: scrollbar drag under streaming is a named residual for the sign-off script, not a blocker here.
- Focus: wakeups are coalesced so a flood of PTY output schedules a bounded amount of main-thread work, and the final frame is never lost (the last output always renders; no stuck stale frame when the stream stops); keystroke echo latency does not regress (forceRefresh stays allocation-free, no new display link or manual draw loop per CLAUDE.md); timers/debounces are bounded and cancelled on surface teardown (no use-after-free after C11-294's abortable teardown); tests behavioral. Read every changed hunk; cite file:line for each finding.
- When done, send VERDICT and wait.
