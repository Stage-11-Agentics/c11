# CLI seat takeover (Codex)

Follow `codex-takeover.md` in this folder. Your seat brief is `cli.md`. Your actor is `agent:codex-cli`. Tab title: `CLI Batch Codex`.

Your queue (from run-state.md): C11-284 first, then C11-279, 283, 280, 282, 281, 308, 309, 285, 286.

The previous Grok owner did NOT apply its audit fixes. You must, in plan text, from `/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/plan-audit-astra.md`:
- **Finding 8 (C11-284):** C11-284 lands first; each later command enables its feature flag as it lands; verify capabilities on the integrated artifact.
- **Finding 9 (C11-282):** not a bounded off-main read. Adopt the C11-294/295 policy (try-lock, bounded worker wait), record native capture on main as an explicit residual, and plan a large-selection measurement.
- **Finding 5 (C11-281):** send logging and mailbox hunks wait for C11-257 to MERGE (the board edge exists); different hunks is not the barrier.

Re-store C11-284, C11-282 and C11-281 and send PLANNED for each (plus any other plan you change), then STANDBY.
