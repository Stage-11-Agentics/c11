# Review: C11-304 (ignore spinner-only terminal titles), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-304**. PR https://github.com/Stage-11-Agentics/c11/pull/513, head `84acb43ce6d1d5f1589512b1ede45f1d0341dd0c`, base = merge-base with origin/main.
- Title `C11-304 Review Astra`. Actor `agent:astra-review-304`. Owner was Codex Sol.
- Plan `.lattice/plans/task_01M3X6K2J58A33757GFVV35204.md`; validation `ev_01M3XMEW9FRC1QV9XMPXYEGRBD` (11 Atlas tests; runtime in the batch). CI pending; the captain gates on it.
- Focus: titles made only of spinner glyphs (the incident's braille/dots frames) no longer churn the tab title or sidebar, while real titles that contain such glyphs plus text still update; no new per-keystroke or per-frame work on the title path beyond a cheap check; title churn that previously caused sidebar re-render is actually reduced; tests behavioral.
- When done, send VERDICT and wait.
