# Resume a c11 1.0 seat after a restart

c11 (and possibly the Mac) was restarted after wave 0. Your seat's earlier session is gone; everything it produced is durable: plans on the tickets, the worktree on disk (including any local commits), and the briefs in this folder. You are the seat's owner again.

1. Read `owner-common.md` (your contract) and your seat brief (named in your launch prompt). Use the actor and title named in `../run-state.md` Seats table (Codex seats: `agent:codex-<seat>`, title `<Seat> Codex`; Astra seats keep their brief's actor and title).
2. Your worktree is the seat's existing worktree. Keep every local commit and file; never reset, rebase, stash, clean or force anything.
3. The Orchestrator's mailbox is in your launch prompt (it replaces the tab named in `owner-common.md`).
4. Re-read each ticket in your queue (`lattice show <ticket>`) and its stored plan. Do not re-plan from scratch; fix only real errors, and re-store any plan you change.
5. Mode is whatever the Orchestrator says. Until it sends `BUILD MODE`, planning-mode rules hold: no builds, tests, product commits or pushes.
6. Send `READY <seat> CWD … HEAD … BASE … MODE <planning|build>`, then `STANDBY <seat> <tickets; what has not started>` and wait.
