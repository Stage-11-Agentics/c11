# Delta re-review: C11-271 (PR #495), cycle 3 of 3 (FINAL)

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-271**. PR https://github.com/Stage-11-Agentics/c11/pull/495. Branch `c11-1.0/C11-271-lifecycle-fixtures`. New head `27ebd59619d09a916d1412fd8527b2aee96c71b7`. Previous reviewed head `ece3cf255b598ba49c8f17993d72012f444caadf`. Base origin/main `0ff8887e5e`.
- Title `C11-271 Final Review`. Actor `agent:codex-review-271`.

**Delta-only, final cycle.** Read the cycle-2 review (comment `ev_01M3XA06BFBY5WGBF8XD1BT2V7`) and verify its two blocking findings against `git diff ece3cf25..27ebd596`: (1) the sibling replay assertion now requires tab A's after-oracle to be A's, still waiting, with A's unread count preserved, and a regression where A flips to working fails; (2) the bypass-ask oracle's time/order no longer contradicts its recorded sequence (real time restored, or marked unknown/inferred without asserting observed order). New blocking findings only if this delta introduced them. The known tagged-build recapture gaps (ExitPlanMode, real restart, Codex child notify) are recorded residuals for build mode, not blocking for this review. Re-run the disclosure scan on changed files.
