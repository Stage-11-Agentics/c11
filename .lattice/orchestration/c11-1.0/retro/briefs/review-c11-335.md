# Review: C11-335 macOS CI backstop

Read `reviewer-common.md` beside this file first and follow it.

- Ticket: C11-335. PR: Stage-11-Agentics/c11#589. Head: `e36108ee34`. Base (merge base with main): `6e2c1dc47f`.
- Your review worktree (detached at the head): `/Users/atin/Projects/Stage11/code/review-worktrees/c11-589`. Board: `LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`.
- Owner's brief: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/c11-335.md`.
- Write your review to: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/../reviews/c11-335-r1.md`.
- Proof run in progress: GitHub Actions run 37393070106 (workflow_dispatch on the PR branch, `macos-15`). Read its result and timing with `gh run view 37393070106`; do not dispatch or re-run workflows yourself, and never enable or disable a workflow.
- Focus: a burst of merges collapses to one running plus one pending run of the newest main and never cancels a running job; the already-green skip cannot skip an untested commit (how is "tested green" recorded and read, and can a failed or cancelled run count as green?); the job fits the free runner's time and memory; the workflow cannot be triggered by fork pull requests; nothing else in CI lost coverage it had before; docs and skills match.
