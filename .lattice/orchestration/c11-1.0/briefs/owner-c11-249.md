# Owner: C11-249 (backlog-review admission, Atin approved 2026-10-02)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (you may be on Sol rather than Luna; everything else applies).

- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-249`, branch `c11-1.0/C11-249-rail-tip` (on current origin/main). Provision submodules and GhosttyKit before the first build.
- Actor `agent:luna-249`; tab title `C11-249 Luna`; `lattice assign` and link the branch first. The ticket is in backlog: move it backlog → in_planning → planned → in_progress as you go.
- Read the ticket and its plan (`lattice show C11-249`); the plan is a stub from triage. Re-check every claim against current main (much has merged today), write a concise plan with `lattice plan write`, then implement. No separate plan review.
- Focus: rail tip follow-ups (Undo copy, count-cell tap, rail-open state after Undo, anchor clear). **Deadline:** new or changed English strings must merge before the C11-291 translation refresh at the string freeze; hand off as early as you can. Localize at the call site, English only. UI: computer-use check on an Atlas tagged build; elements must not jump.
- Atlas builds only under tag `c11-249` (one tag per ticket). Push only at handoff. Then `HANDOFF C11-249 REVIEW <head> <PR> <validation>` to tab:210.
