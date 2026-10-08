# Review: LAT-395 orchestrated review lifecycle

Read `reviewer-common.md` beside this file first and follow it.

- Ticket: LAT-395. PR: Stage-11-Agentics/lattice#147. Head: `9232862a1f`. Base (merge base with main): `7cb18be31e`.
- Your review worktree (detached at the head): `/Users/atin/Projects/Stage11/code/review-worktrees/lattice-147`. Board: `LATTICE_ROOT=/Users/atin/Projects/Stage11/code/Lattice`.
- Owner's brief (what was asked): `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/lattice-review-lifecycle.md`.
- Write your review to: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/../reviews/lattice-147-r1.md`.
- Focus: the review-cycle limit stays a hard stop on the auto-review path and becomes advisory otherwise; nothing else in the lifecycle loosened by accident; `in_validation → done` is allowed only with completion evidence; the new `lattice migrate validation-done` step is safe on existing boards (idempotent, no data loss, dry-run behavior); the hosted server path enforces the same rules as the local CLI. PR CI already ran the full suite green; run only the test files the PR touches (`uv run pytest <files>`) on Hyperion.
