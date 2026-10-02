# Seat: Hangs Main Astra

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Hangs Main Astra
- **Actor:** `agent:astra-hangs`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-hangs` (first branch `c11-1.0/C11-295-main-stalls`; later tickets get their own branch from origin/main when you start them)
- **Seat id for envelopes:** `hangs`

## Queue (each ticket its own branch and PR)
1. **C11-295** (P0, L): stop autosave and screen reads from stalling main; start cold terminals (app half of B010; B086; B003; the C11-130/169/235 cold-terminal cluster).
2. **C11-296** (P1, S): start a cold terminal when an agent reads its screen (same cold-start seam; keep it a separate small PR or fold into C11-295 only if they cannot land separately; say which).
3. **C11-302** (P1, S): coalesce Ghostty wakeups so streaming output cannot flood main.
4. **C11-303** (P1, S): stop scroll updates from laying out every window.
5. **C11-301** (P1, S): cap how many background workspaces mount at once.

## Specifics
- Sources: each ticket, `upstream-triage/c11-1.0/05-bug-sweep.md`, `05-bug-sweep-data/LEDGER.md` rows named in the tickets, and the bug audits in that folder.
- C11-294 (Ghostty patch set, another Astra seat) owns the submodule side of the mailbox/freeze cluster; you own the app side. Name the seam in C11-295's plan.
- These are all main-thread and typing-latency adjacent: every plan names the incident, the measurement against the C11-270 soak baseline, and the CLAUDE.md hot-path rules it touches (`forceRefresh`, `hitTest`, `TabItemView`, socket threading, autoreleasepool). Smallest change that removes the observed stall.
