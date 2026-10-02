# Seat: Focus History Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** Focus History Grok
- **Actor:** `agent:grok-history`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-history` (branch `c11-1.0/C11-262-focus-history`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `history`

## Queue
1. **C11-262** seen-based focus history with persistent UUIDs and an agent-readable `c11 history`.

## Specifics
- Built on 'seen' (`TabSeenTracker`, C11-243) with a dwell threshold, not raw focus. `c11 history [--json] [--limit]`; back/forward as commands; keys rebindable; the browser's Cmd+[ and Cmd+] stay untouched (D16 out of scope). Persists across restart keyed by UUID.
- Agents read it (D20): define the JSON shape for agents (Overwatch reads it), and say what is and is not recorded (privacy: titles may contain sensitive text; decide and justify).
- Focus/selection paths are hot: obey the socket focus policy and typing-latency rules; recording must be off the keystroke path.
