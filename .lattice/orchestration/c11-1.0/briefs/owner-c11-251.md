# Owner: C11-251 (backlog-review admission, Atin approved 2026-10-02)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (you may be on Sol rather than Luna; everything else applies).

- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-251`, branch `c11-1.0/C11-251-sidebar-target` (on current origin/main). Provision submodules and GhosttyKit before the first build.
- Actor `agent:luna-251`; tab title `C11-251 Luna`; `lattice assign` and link the branch first. The ticket is in backlog: move it backlog → in_planning → planned → in_progress as you go.
- Read the ticket and its plan (`lattice show C11-251`); the plan is a stub from triage. Re-check every claim against current main (much has merged today), write a concise plan with `lattice plan write`, then implement. No separate plan review.
- Focus: bare-shell `clear-*` and `list` sidebar commands must require an explicit target (or resolve from `$C11_WORKSPACE_ID` inside c11) and never act on the operator's selected workspace. Update CLI help and the c11 skill (do not sync installed skills; the captain does). Behavioral tests through the CLI/socket.
- Atlas builds only under tag `c11-251` (one tag per ticket). Push only at handoff. Then `HANDOFF C11-251 REVIEW <head> <PR> <validation>` to tab:210.
