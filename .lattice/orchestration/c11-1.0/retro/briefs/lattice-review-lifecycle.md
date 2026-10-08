# Lattice: let an orchestrator drive review and validation without fighting the board

Read `common.md` beside this file first and follow it, with these changes for Lattice: the repo is `Stage-11-Agentics/lattice` (GitHub, public), the board is Lattice's own (`LATTICE_ROOT=/Users/atin/Projects/Stage11/code/Lattice`, actor `agent:opus-lattice-review`), and **you may merge** once Cairn relays a review PASS, following the Lattice `CLAUDE.md` (tests and ruff green). Lattice is not frozen. The global `lattice` is an editable install of the main checkout, so nothing you do in your worktree goes live until merge. Never touch `~/Projects/Stage11/code/Lattice` itself; it is checked out detached at an older commit; leave it as it is.

- Worktree: `/Users/atin/Projects/Stage11/code/Lattice-worktrees/orchestrated-review-lifecycle`, branch `fix/orchestrated-review-lifecycle`, based on `origin/main`. Install it with `uv pip install -e ".[dev]"` in the worktree and use `.venv/bin/lattice` to test.
- File one LAT ticket for this work on Lattice's board first, and reference it in commits and the PR.

## Two frictions from the c11 1.0 run (local board, `lattice-orchestrator-v2`)

1. **The review-cycle limit blocked orchestrated work.** `workflow.review_cycle_limit` (default 3, `core/config.py`, counted by `count_review_rework_cycles` in `core/events.py`, enforced with `REVIEW_CYCLE_LIMIT` in `ops/task_status.py`) rejected `review → in_progress` on two tickets: one carried many small PRs under one ticket (a bug sweep), the other a translation ticket with several passes. The orchestrator already enforces its own review budget (3 rounds, up to 5 with a fresh reviewer), so the board's hard stop only forced seats to stop updating status.
2. **The orchestrator merges before it validates.** Its batch flow is `review → (PR merged) → in_validation → done`, but completing from `in_validation` was refused until the task passed through `pr_open`. Lattice's built-in order assumes validation before the PR opens.

## Direction (Atin)

Atin's inclination: the orchestrator triggers reviews and Lattice observes and records. Lattice-triggered work is hard for him to see. Cairn agrees. So:

- The cycle limit becomes advisory whenever the review was not fired by Lattice's own auto-review: record the count, set `needs_human` or emit a warning event when it passes the limit, and allow the transition. Keep the hard stop only on the auto-review path, where nothing else bounds the loop. If you find a simpler shape that meets the same goal, use it and say why in the PR.
- `done` is reachable from `in_validation` when the task has completion evidence (a merged PR or branch link, or whatever the completion check already accepts), without a detour through `pr_open`.
- Do **not** change the auto-review default or remove auto-review in this PR. Atin decides that separately.

## Done when

- Tests for both changes go red on `origin/main` and green on your branch; the full suite and `ruff check src/ tests/` pass.
- The status-transition docs and the Lattice skill (`src/lattice/skills/lattice/`) describe the behavior as it is now, timelessly.
- PR open with the LAT ticket in the title; after Cairn relays PASS, merge it per the Lattice CLAUDE.md and confirm with `lattice --version`/a transition on a scratch board that the editable install picked it up (`git -C ~/Projects/Stage11/code/Lattice` is NOT yours to move; if the main checkout stays detached, report that the fix is merged but not live and stop).
