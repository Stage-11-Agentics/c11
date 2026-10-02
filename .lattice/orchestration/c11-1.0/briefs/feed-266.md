# C11-266: next ticket for the Feed seat (critical path, last in the Feed chain)

Your contract is unchanged: owner-common.md and go-owner.md. C11-265 is merged and in batch validation; you are done with it.

- Ticket **C11-266**: keyboard-first ⌘I quick view over your C11-265 projection, fixed row geometry (nothing jumps), finished turns behind a second filter. Read the full ticket (`lattice show C11-266`) and acceptance criteria 1-5.
- Dependencies merged: C11-264 and C11-265. Render the existing projection; do not add another ordering or count.
- ⌘I is today's notifications default (`KeyboardShortcutSettings.swift`). Do not silently rebind a shipped default or a user's custom binding; if the ticket's ⌘I cannot coexist with the notifications shortcut, send `DECISION C11-266 ...` with the options and consequences before changing defaults.
- New branch `c11-1.0/C11-266-quick-view` from current origin/main (fetch first). Actor `agent:sol-feed`. Link the branch.
- Concise just-in-time plan with `lattice plan write`, then implement.
- UI: computer-use proof on an Atlas tagged build (tag `c11-266`, the 30-minute VM lease) covering keyboard navigation, Enter opens the exact tab, Esc restores the originating focus, both filters, and the fixed-geometry cases in criterion 4 including the longest locale strings. Screenshots attached.
- New UI strings localized at the call site, English only; hand off early enough to beat the C11-291 translation freeze.
- Push only at handoff. Then `HANDOFF C11-266 REVIEW <head> <PR> <validation>` to tab:210. Rename your tab `C11-266 Sol`.
