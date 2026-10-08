# Review: C11-331 incremental remote staging

Read `reviewer-common.md` beside this file first and follow it.

- Ticket: C11-331. PR: Stage-11-Agentics/c11#587. Head: `05fe7671bf`. Base (merge base with main): `6e2c1dc47f`.
- Your review worktree (detached at the head): `/Users/atin/Projects/Stage11/code/review-worktrees/c11-587`. Board: `LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`.
- Owner's brief (what was asked): `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/c11-331.md`.
- Write your review to: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/../reviews/c11-331-r1.md`.
- Focus: exact-head provenance (the tree built on Atlas must equal the requested head, including submodules), concurrency between two stagings of the same or different heads, the fallback when Atlas holds no shared base, and that a failed or partial upload can never be taken for a good one. Proving staging on Atlas is fine (stage only, never launch an app); at most one Atlas build at a time.
