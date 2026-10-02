# Owner: C11-250 (backlog-review admission, Atin approved 2026-10-02)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (you may be on Sol rather than Luna; everything else applies).

- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-250`, branch `c11-1.0/C11-250-close-safety` (on current origin/main). Provision submodules and GhosttyKit before the first build.
- Actor `agent:luna-250`; tab title `C11-250 Luna`; `lattice assign` and link the branch first. The ticket is in backlog: move it backlog → in_planning → planned → in_progress as you go.
- Read the ticket and its plan (`lattice show C11-250`); the plan is a stub from triage. Re-check every claim against current main (much has merged today), write a concise plan with `lattice plan write`, then implement. No separate plan review.
- Focus: real safety fixes 2, 5 and 6 from the #469 shutdown-snapshot review, as the ticket lists them. Shutdown and snapshot paths: prove each with a test that goes red without the fix. If a fix touches app termination, runtime proof on an Atlas tagged build is required before merge (risk list).
- Atlas builds only under tag `c11-250` (one tag per ticket). Push only at handoff. Then `HANDOFF C11-250 REVIEW <head> <PR> <validation>` to tab:210.
