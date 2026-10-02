# Review: C11-305 (stop shell helpers from outliving the shell and locking git), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-305**. PR https://github.com/Stage-11-Agentics/c11/pull/515, head `06854ad370893b1348ec279e719428f6f9c1c9e1`, base = merge-base with origin/main.
- Title `C11-305 Review Astra`. Actor `agent:astra-review-305`. Owner was Codex Sol (the owner's own Codex check does not count as this review).
- Plan `.lattice/plans/task_01M3X6K2MVM6SVXP7QQGCN26ZC.md`; validation `ev_01M3XQCSFKC5JMRXQ5E0NNA89K` (11 behavioral tests on source and the tagged bundle), Validator steps `ev_01M3XQ8HCXZ3VC204GGVDP1CCV`. CI pending.
- Focus: background helpers started by c11's shell integration (git status/prompt helpers and similar) exit when their shell exits and can no longer hold `.git/index.lock`; no orphaned process on tab close, shell exit or c11 quit; no new latency in the prompt path or per-keystroke work; works for zsh/bash/fish as the plan scopes; does not write into users' dotfiles or agent tool config (doctrine); tests behavioral.
- When done, send VERDICT and wait.
