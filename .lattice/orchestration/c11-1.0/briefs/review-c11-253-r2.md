# Review: C11-253 + C11-256 round 2 (delta)

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `C11-253 Review Astra`. Actor `agent:astra-review-253`. Owner: Claude Sonnet (rolled over from Codex Sol).

- PR https://github.com/Stage-11-Agentics/c11/pull/552, new head `6170a03a737830b8b99c45ec79cad321b181487f`. Round-1 FAIL head `34a59fead009690c3605140e4222fa4828d1166d`, verdict `ev_01M3Z1VBDW2R2X1SXRKZY9NA35` (read it; C11-256's CI wiring passed there).
- Owner evidence: Atlas run d3ee7be942534f779d6a7787042378d5, 1,583 tests, 0 failures, 15 exclusions; exact-head cheap CI green; validation comments on both tickets.
- Delta: `git diff 34a59fead0 6170a03a73` (confirm any main merges add nothing beyond main).
- Check the two round-1 blockers: (1) the terminal Find focus, search-overlay lifetime and queued-layout hit-region assertions are restored with real waits; (2) the collapsed-divider pass-through tests for browser and terminal portals are restored with a dispatched pointer event. Any that remain quarantined must be on the named skip list with a reason and a numbered Validator or sign-off scenario. Production pointer guards unchanged.
- Count the 15 exclusions: each one named, with a reason, in the triage note and the workflow skip list; none silent.
- Break one restored guard and confirm its test goes red.
- Reply `VERDICT C11-253 PASS|FAIL <head> <artifact>` to tab:210.
