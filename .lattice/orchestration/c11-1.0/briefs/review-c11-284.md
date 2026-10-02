# Review: C11-284 (print the bundled skill and a versioned capabilities.features list), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-284**. PR https://github.com/Stage-11-Agentics/c11/pull/502, branch `c11-1.0/C11-284-guide-features`, head `0e83c435cd40a7f53c43cf22ef070e34303b3727`, base = merge-base with origin/main.
- Title `C11-284 Review Astra`. Actor `agent:astra-review-284`. Owner was Codex Sol.
- Plan `.lattice/plans/task_01M3X4FNEE0AF12PMBE9QV14DR.md`; validation `ev_01M3XG0DF39M0N6AE80DJ8FCK5`. GitHub CI is still running (the captain gates on it); the full smoke and live-server proof run in the batch Validator, so judge whether the recorded scenario would prove the acceptance criteria.
- Focus: the feature registry lands first and the five upcoming features are registered disabled with a clean enable path for their owners (audit finding 8: capabilities must not advertise a feature that is absent, nor hide one that has landed); the printed skill is the bundled copy and its version is truthful; output is stable JSON; C11-257's send/mailbox code untouched; CLI threading/focus rules respected; tests behavioral.
- When done, send VERDICT and wait; the Orchestrator may send a delta re-review.
