# Review: C11-295 (stop autosave and screen reads from stalling main; start cold terminals), cycle 1 — Fable

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. You are Claude Fable in Claude Code: **read-only**, no subagents of any kind, no edits, no builds or tests on this Mac.

- Ticket **C11-295** (P0, risk list). PR https://github.com/Stage-11-Agentics/c11/pull/530, head `d3fa43c1c8a90e2aa8bac7a587e9cc756af34fbc`, base = merge-base with origin/main (C11-294's abortable Ghostty waits, C11-296's cold-read helper and C11-302's wakeup coalescing are on main).
- Title `C11-295 Review Fable`. Actor `agent:fable-review-295`. Owner was Codex Astra.
- Plan: the ticket's plan file. Recorded ruling: B086 is bounded lock acquisition only; full off-main native formatting is a 1.0 residual (C11-294 SEAM no); the PR must not claim more. Evidence `art_01M3Y40AQPGR0SRWMNDNVANJV0` (final keyboard proof: 40 streams, 100 observations, zero misses) and `art_01M3Y1Z6EDRFX4KZ8RH2GE3GEZ`.
- Focus: autosave serialization and screen reads no longer hold main across unbounded work (bounded lock acquisition with a deadline, fallback behavior when the bound hits is safe and never loses or corrupts a snapshot); no deadlock between the new bounded wait and C11-294's teardown or C11-302's coalescer; long-lived threads drain an autoreleasepool per iteration; socket threading and focus policy respected; the incident bug rows the plan maps to this ticket (B003/B086/B010 part) are each covered by a behavioral test or runtime proof; residuals honestly named.
- When done, send VERDICT and wait.
