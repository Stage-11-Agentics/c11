# Review: C11-287 (replace a crashed web view on the next turn and stop forced layout), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-287**. PR https://github.com/Stage-11-Agentics/c11/pull/501, branch `c11-1.0/C11-287-webview-crash`, head `bb693f159b3d3a98e4f327f5f689e5cd0cbab83f`, base = merge-base with origin/main.
- Title `C11-287 Review Astra`. Actor `agent:astra-review-287`. Owner was Codex Sol.
- Plan `.lattice/plans/task_01M3X4FNR43RVWK5EDEGFBRQYF.md`; validation `ev_01M3XJVPZTQPEJ5T8SY9F82739` (27 targeted tests passed on Atlas; CI still running, the captain gates on it). Batch validation applies: judge whether its Validator scenario would prove the acceptance criteria.
- Focus: a crashed WKWebView content process is replaced on the next turn without losing the tab, its URL/history or profile; no replacement loop; the forced-layout removal does not regress rendering, inspector or focus; nothing new on main-thread hot paths; no runModal; strings localized; tests behavioral.
- When done, send VERDICT and wait.
