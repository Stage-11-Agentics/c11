# Review: C11-282 (read a terminal selection off the main thread), cycle 1 — Grok

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. You are Grok: read-only, no builds or tests, no subagents. Read every changed hunk; cite file:line for each finding.

- Ticket **C11-282**. PR https://github.com/Stage-11-Agentics/c11/pull/529, head `790c98459b836dc754176fc22260ae0f8b40e14b`, base = merge-base with origin/main.
- Title `C11-282 Review Grok`. Actor `agent:grok-review-282`. Owner was Codex Sol.
- Plan: the ticket's plan file. Validation `ev_01M3Y3JKQMCM59MTBM0C81KBCN`, metrics `art_01M3Y3QR2NZQQYZXN3EKYCAR8P` (ten tests; 30 byte-exact 1,045,175-byte native reads; built CLI). Disclosed residuals: native formatting stays on main (p95 6.084 ms, unbounded); several-MiB clipping, live main-stall and integrated typing/switch soak unproven.
- Audit finding 9 is the bar: the PR must NOT claim a bounded off-main native read. Blocking if the docs, help text, skill or capability description overstate it; if the worker wait is unbounded or can deadlock main; if the 1 MiB clip happens before rather than after copying in a way that is misdescribed; if the selection API (ghostty_surface_read_selection) is used outside its safe lifetime (surface freed mid-read, cf. C11-294's teardown); or if the union merge dropped routing/send/RPC/selection features or docs. Tests behavioral.
- When done, send VERDICT and wait.
