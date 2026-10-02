# Review: C11-314 (delete flaky timing tests), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-314**. PR https://github.com/Stage-11-Agentics/c11/pull/532, head `d1d6cee460baa0c913832709c5af4142bb4ab029`, base = merge-base with origin/main.
- Title `C11-314 Review Astra`. Actor `agent:astra-review-314`. Owner was Grok (check every claim against evidence; Grok has skipped rows before).
- Plan `.lattice/plans/task_01M3YH5C70Z9PJSB25MS3VQ0AR.md`; validation `ev_01M3YJ0W4XF10KEMTHGN5KZ7D0`.
- Atin's ruling: delete flaky tests rather than fix them. Focus: only tests the run recorded as flaky are removed (WorkspaceRemoteConnectionTests timing/relay cases, MessagesPageTests writer-max-wait, others with recorded evidence); no product code changed; no deterministic test of real behavior deleted along with them; project file/target membership stays consistent; the Atlas logic suite passes without the old exclusions (check the evidence). Blocking if a deleted test was the only coverage of a shipped acceptance criterion and a cheap deterministic replacement already existed.
- When done, send VERDICT and wait.
