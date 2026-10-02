# Review: C11-274 (widen Claude lifecycle observations through per-process hooks), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-274**. PR https://github.com/Stage-11-Agentics/c11/pull/533, head `5393670a60b4d6580252fbcbc7e8d555092a1475`, base = merge-base with origin/main (C11-273's journal is on main).
- Title `C11-274 Review Astra`. Actor `agent:astra-review-274`. Owner was Grok (verify every acceptance row against real evidence; Grok has skipped rows before).
- Plan `.lattice/plans/task_01M3X3XPRNFH2Y3DG9T9GZDM3T.md`; validation comment on the ticket. Note: C11-273 already took the PostToolUse AskUserQuestion|ExitPlanMode subscription and resolution event (Orchestrator attestation on C11-273); this PR must not duplicate or conflict with it.
- Doctrine axis (CLAUDE.md "unopinionated about the terminal"): hooks only per process at launch via Resources/bin/claude; no writes to ~/.claude or any tenant config. Focus: each new hook maps to the attested C11-272 event types with privacy allowlists (no prompt/tool body text), correct turn and tool correlation; a missing or failing hook degrades gracefully; hook latency stays off the agent's critical path (no blocking calls); the C11-271 fixture corpus replays to its oracles; tests behavioral.
- When done, send VERDICT and wait.
