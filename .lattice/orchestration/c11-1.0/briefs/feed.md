# Seat: Feed Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Feed Grok
- **Actor:** `agent:grok-feed`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-feed` (first branch `c11-1.0/C11-264-feed-asks`; later tickets their own branch from origin/main)
- **Seat id for envelopes:** `feed`

## Queue (each ticket its own branch and PR)
1. **C11-264** typed per-tab asks (`kind, prompt, options, source, opened_at, state`) with `c11 feed list|open|watch` and `ask.opened`/`ask.closed` events. Read-only: no automatic answering (D6).
2. **C11-265** one attention order for ⌥V and the Feed: flags first, then oldest (D7); the menu bar extra shows flags and the open-ask count.
3. **C11-266** keyboard-first ⌘I quick view with fixed row geometry (nothing jumps) and finished turns behind a second filter (D8). New UI strings → localized.

The journal contract is settled: C11-272 spec (`/Users/atin/Projects/Stage11/code/c11/.lattice/plans/task_01M3X3XPJSSY6XSPBYGP6VCSRR.md`, reviewed and attested) and the C11-273 store/append/fold plan (`.lattice/plans/task_01M3X3XPNP88K5250NDJPYK02S.md`). Plan against their exact verbs, kinds, ranks and fields; do not redesign them. If the contract cannot support your ticket, send BLOCKED with the exact gap rather than inventing a second reducer. Your tickets implement only after C11-273 merges (dependencies merge before dependents implement).

C11-263 (attention bug batch, Fixtures seat) lands first and fixes workspace-wide clears, bypass asks, menu-bar flags and notification IDs; build on it, do not duplicate it. Privacy: `prompt` text in asks is shown locally only and never written to the journal (no prompt bodies, per the spec); say how. UI work is validated by computer use on an Atlas tagged build.
