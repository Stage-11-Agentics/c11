# Review: C11-297 (keep the control socket ready before restored agents call it), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-297**. PR https://github.com/Stage-11-Agentics/c11/pull/516, head `ac1f8260eb4f36bda585c01b357779c0adcf65f0`, base = merge-base with origin/main.
- Title `C11-297 Review Sol`. Actor `agent:codex-review-297`. Owner was Codex Astra.
- Plan: the ticket's plan file. Validation `ev_01M3XQAQ1XMDHRCS11WVHYCDX9`, evidence `art_01M3XQA3E0NB7K7R92H7S7MFSC` (19 Atlas tests; numbered Validator scenario for the batch). CI pending.
- Focus: on startup with restored agents, the control socket is bound and answering before any restored agent process can call it (no lost first calls, no "socket not found" for restored hooks/wrappers), without delaying first paint or blocking main beyond a bound; startup ordering stays correct on a cold launch and after a crash; the C11-257 send/mailbox paths that now live on main are unchanged; the accept loop and per-connection threads keep the autoreleasepool rule; no runModal; tests behavioral.
- When done, send VERDICT and wait.
