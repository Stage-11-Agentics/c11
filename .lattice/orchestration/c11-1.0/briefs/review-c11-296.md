# Review: C11-296 (start a cold terminal when an agent reads its screen), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-296**. PR https://github.com/Stage-11-Agentics/c11/pull/511, head `e49dd2754ba4fa87dae5db591328440d3fcf96f1`, base = merge-base with origin/main.
- Title `C11-296 Review Sol`. Actor `agent:codex-review-296`. Owner was Codex Astra.
- Plan `.lattice/plans/task_01M3X6K1X04S08YS80HNASRCMN.md`; validation comment on the ticket (runtime proof deferred to the batch Validator; judge whether its scenario would prove the acceptance). CI pending; the captain gates on it.
- Focus: reading the screen of a never-started (cold) terminal starts it exactly once and returns real content, instead of hanging or returning empty; no duplicate PTY start under concurrent reads; the read path keeps its threading contract (no new blocking main-thread wait without a bound; socket telemetry stays off main); no focus stealing; the helper is reusable by C11-295 as the plan says; tests behavioral.
- When done, send VERDICT and wait.
