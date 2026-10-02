# Seat: CLI Batch Grok

Read and follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` first; it is your contract.

- **Tab title:** CLI Batch Grok
- **Actor:** `agent:grok-cli`
- **Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-cli` (branch `c11-1.0/C11-279-routing-keys`, base origin/main `0ff8887e5e`)
- **Seat id for envelopes:** `cli`

## Queue (each ticket is its own branch and PR, created from origin/main when you start it)
1. **C11-279** reject misspelled routing keys (uses C11-248's `LegacyWireAliases` seam; check origin/main for it).
2. **C11-283** scope `--window` without focusing that window.
3. **C11-280** `--command` on new split/area/tab via Ghostty `initial_input` (read the Ghostty source at `/Users/atin/Projects/Stage11/code/c11/ghostty` read-only; do not init submodules in your worktree yet).
4. **C11-282** read a terminal selection off the main thread.
5. **C11-284** print the bundled skill and a versioned `capabilities.features` list.
6. **C11-281** send delivery contract: `--raw`, stdin, unknown-flag errors. **Touches `send`; C11-257 (agent messaging) owns send logging and mailbox delivery.** Read `lattice show C11-257` and plan around it: no edits to the send logging or mailbox delivery code until C11-257 has merged; say in the plan which hunks wait.

Plan all six now, one plan per ticket. These are all `CLI/c11.swift` + socket-handler work: keep each PR small and independent so they land in any order, and note shared-file conflict risk in each plan. P2 follow-ons (C11-285 rpc, C11-286 resize-window) are not in your queue.
