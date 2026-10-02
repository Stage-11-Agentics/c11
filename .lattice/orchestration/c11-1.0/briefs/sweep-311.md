# C11-311 tier-2 sweep: parallel worker

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory; they bind you (you may be on Sol; everything else applies).

C11-311 is one ticket swept by several workers in parallel, each with its own groups, branch and PRs. Your groups and worktree are in your launch prompt. Other workers own the other groups; do not touch them. Already merged: B078/B080. In flight elsewhere: B018, B046, B050.

- Read the ticket description (`lattice show C11-311`): each group's row, mechanism in `upstream-triage/c11-1.0/05-bug-sweep-data/LEDGER.md`, corrections in `audit-fable.md` and `audit-astra.md`. Ledger lines older than C11-248 are stale.
- Re-find every line on current main. Establish the trigger or record an explicit disproof. A missing reproducer is not a fix. A disproof is a valid outcome: post it as a lattice comment and move on.
- One PR per group, or per tightly related pair, each its own branch from current origin/main (`c11-1.0/C11-311-<group>`). Before starting a group, post `C11-311 <worker>: starting <group>` as a lattice comment.
- If a group turns out to touch a typing path (`TabItemView`, `WindowTerminalHostView.hitTest`, `TerminalSurface.forceRefresh`) or needs the C11-270 soak, stop that group and say so in a comment; skip to the next.
- Do not change the ticket's status (other workers share it). Do not run `lattice complete`.
- Tests must go red without the fix. Each PR carries numbered Validator scenarios for its runtime behavior.
- Atlas builds only under your own tag, given in your launch prompt. Push only at handoff. Then `HANDOFF C11-311 REVIEW <head> <PR> <validation>` to tab:210, naming the group(s).
