# Review: C11-300 (refuse to close a workspace from the wrong window), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-300**. PR https://github.com/Stage-11-Agentics/c11/pull/505, branch `c11-1.0/C11-300-close-ownership`, head `b689c0d514359930e383071380fd78b66620a479`, base = merge-base with origin/main.
- Title `C11-300 Review Sol`. Actor `agent:codex-review-300`. Owner was Astra.
- Plan `.lattice/plans/task_01M3X6K27F339MM9F9WPCCZEEA.md`; validation `ev_01M3XFPKCV1WETF473ZEM6DSD6` (includes a six-step Validator scenario; runtime proof is deferred to the batch, per Atin's batch-validation ruling, so judge whether that scenario would prove the acceptance criteria).
- Focus: a close request routed to a window that does not own the workspace is refused (no crash, no closing the wrong workspace, no orphaned state), while every legitimate close path (menu, shortcut, socket/CLI, last tab, multi-window) still works; no focus stealing from socket paths; no runModal on agent-reachable paths; user-facing strings localized; tests are behavioral.
- When done, send VERDICT and wait; the Orchestrator may send a delta re-review.
