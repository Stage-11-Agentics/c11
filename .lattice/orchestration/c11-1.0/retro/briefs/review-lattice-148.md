# Review: LAT-420 auto-review off by default

Read `reviewer-common.md` beside this file first and follow it (note the rule on temp roots and `LATTICE_ROOT`).

- Ticket: LAT-420. PR: Stage-11-Agentics/lattice#148 (base `v2`). Head: `2676e5308a`. Base (merge base with v2): `f3eb00ebf3`.
- Your review worktree (detached at the head): `/Users/atin/Projects/Stage11/code/review-worktrees/lattice-148`. Read the ticket with `LATTICE_ROOT=/Users/atin/Projects/Stage11/code/Lattice lattice show LAT-420`.
- Owner's brief: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/lattice-autoreview-default.md`.
- Write your review to: `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/retro/briefs/../reviews/lattice-148-r1.md`.
- Focus: new boards start with auto-review off and can still turn it on; an existing board that set it explicitly keeps its setting; a board that only inherited the old default keeps behaving as before (or the PR says clearly what changes and why) and `lattice doctor` points at the new default; the hosted server and local paths agree; the skill and docs say who triggers reviews, timelessly. PR CI ran the full suite green; run only touched test files on Hyperion.
