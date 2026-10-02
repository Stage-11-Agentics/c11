# C11-265: next ticket for the Feed seat (critical path)

Your contract is unchanged: owner-common.md and go-owner.md. C11-264 is merged (bc915d0509) and in batch validation; you are done with it.

- Ticket **C11-265**: one attention order for Feed and the configured jump (flags first, oldest first, deterministic UUID tie-break), plus flags and the open-ask count in the menu-bar extra. Read the full ticket (`lattice show C11-265`) and its acceptance criteria 1-5.
- Dependencies are merged: C11-263 (attention batch) and C11-264 (your Feed/asks). Build on your own projector; do not add a third independent list.
- New branch `c11-1.0/C11-265-attention-order` from current origin/main in your worktree (fetch first, provision submodules). Actor `agent:sol-feed`. Link the branch on the ticket.
- Just-in-time plan: write it with `lattice plan write` (concise), then implement. No separate plan review.
- Atlas builds only under tag `c11-265` (one tag per ticket). Not on the pre-merge risk list, but it touches menu-bar and focus behavior: include a computer-use check on an Atlas tagged build of the shortcut and the menu bar, and confirm updates never activate c11.
- New UI strings are localized at the call site, English only.
- Push only at handoff. Then `HANDOFF C11-265 REVIEW <head> <PR> <validation>` to tab:210.
- Rename your tab to `C11-265 Sol` and set the description now.
