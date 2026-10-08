# Review: C11-332 un-quarantine host tests

Read `reviewer-common.md` beside this file first and follow it.

- Ticket: C11-332. PR: Stage-11-Agentics/c11#588. Head: `ff6b4ada98`. Base (merge base with main): `6e2c1dc47f`.
- Your review worktree (detached at the head): `/Users/atin/Projects/Stage11/code/review-worktrees/c11-588`. Board: `LATTICE_ROOT=/Users/atin/Projects/Stage11/code/c11`.
- Owner's brief (what was asked): `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/c11-332.md`.
- Write your review to: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/../reviews/c11-332-r1.md`.
- Focus: no product code (`Sources/`) changed; every class removed from quarantine actually runs and passes in the hourly gate; tests moved to c11LogicTests still exercise runtime behavior (no source-text tests, per CLAUDE.md test policy); each test fixed as "stale" was stale and not hiding a real bug; every class left quarantined has a true reason.
