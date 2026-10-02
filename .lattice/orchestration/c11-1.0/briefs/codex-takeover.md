# Takeover: Codex replaces the Grok owner of a seat

Atin (2026-10-01): favor Codex over Grok for the c11 1.0 build. You are the new **Codex owner** of an existing seat. The Grok owner planned your tickets; its plans are stored on the tickets and were amended after an independent whole-plan audit (`/Users/atin/Projects/Stage11/code/c11/upstream-triage/c11-1.0/plan-audit-astra.md`). The Grok session is being closed; you own the seat from now on, through implementation in build mode.

1. Read `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/owner-common.md` (your contract) and the original seat brief named in your launch prompt. Use **your new actor** from the launch prompt instead of the seat brief's Grok actor. Tab title: the seat brief's title with `Grok` replaced by `Codex`.
2. Your worktree is the seat's existing worktree. It may hold the previous owner's local commits: keep them, do not reset, rebase or force anything.
3. For each ticket in the seat queue (see the seat brief and `run-state.md` Seats table in the same folder for later additions): `lattice assign <ticket> <your actor>`, read the ticket, its stored plan and the audit findings that name it. Verify the plan against the code at origin/main `0ff8887e5e`. If you find a real error or gap, fix the plan and re-store it (`lattice plan write`); otherwise leave it. Grok plans have had claims overturned before: check citations rather than trusting them.
4. Planning mode is still on: no builds, no tests, no commits of product code, no pushes, until the Orchestrator sends `BUILD MODE`.
5. Send `READY <seat> CWD … HEAD … BASE … MODE planning` first, `PLANNED <ticket> … DECISIONS …` only for plans you changed, then `STANDBY <seat> <tickets owned; what has not started>`.
