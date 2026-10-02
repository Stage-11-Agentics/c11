# Review: C11-258 (launch-agent: deliver long prompts by file reference and report startup), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-258**. PR https://github.com/Stage-11-Agentics/c11/pull/512, head `0541d26b1d1505afc736d25028008c22e8b0caf2`, base = merge-base with origin/main.
- Title `C11-258 Review Astra`. Actor `agent:astra-review-258`. Owner was Codex Sol.
- Plan: the ticket's plan file; validation comment plus artifacts `art_01M3XKPWR9EHKGYEQ10NNKYYT7`, `art_01M3XKPWTRM2MP82XEA05W4D9Q` (187 targeted Atlas tests; native ingestion is a batch Validator scenario; judge whether it would prove the acceptance). CI pending; the captain gates on it.
- Incident: a ~1 KB inline launch prompt left a Codex seat dead on arrival (no session) in this very run; long argv prompts can strand a shell at a continuation prompt. Focus: long prompts reach every agent kind (argv, flag, and post-boot delivery kinds such as Kimi/Copilot) intact via a file reference, the file is private (permissions, location, cleanup) and never contains secrets beyond the prompt; startup reporting is truthful (does not claim "started" when the agent never ran); short prompts keep today's behavior; skill docs updated to match (do not sync installed skills); C11-257's send/mailbox code untouched; tests behavioral.
- When done, send VERDICT and wait.
